// Runs the extracted reference JavaScript under Node and prints one JSON
// document on stdout. Everything on stderr is progress noise; stdout is the
// golden file and nothing else.
//
//   node tool/js_reference/run_reference.mjs > test/js_golden.json
//
// Add `--banner` to prefix a `//` provenance header for the committed golden
// file; see REGENERATE near the bottom of this file for the exact command.
//
// Optional: JS_DOWNLOADS_DIR=<dir> points it at another copy of the sources
// (it reads the already-extracted modules, so the directory only matters if you
// re-run extract.mjs first).
//
// Design rules for this file:
//   * It never recomputes what the reference computes. Every number in the
//     output is a value the prototype's own code returned. Where a value is
//     derived here (a comparison, a max) the field name says so.
//   * Errors and garbage are captured as DATA, never rethrown: `attempt()`
//     turns a throw into {threw:true,...} and a NaN into {nan:true,...},
//     because "what does the JS do with fov 0" is a question with an answer,
//     not a reason to crash the harness.
//   * Deterministic: no timestamps, no Math.random, no iteration over object
//     keys whose insertion order could drift. Two runs must be byte-identical.
import { createRequire } from 'node:module';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom } from './dom_shim.mjs';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));

const warn = (m) => process.stderr.write(m + '\n');

// The sphere sample count every coverage section uses. Declared here rather than
// next to section 4 because `sampleGrid` below runs at module scope and needs it
// first — a `const` after its use site is a temporal-dead-zone error, not a
// hoisted declaration.
const SAMPLE_N = 4000;

// ── JSON-safe value encoding ────────────────────────────────────────────────
// JS has three values JSON cannot carry — NaN, ±Infinity and -0 — and all three
// are *findings* here, not nuisances. They get encoded rather than dropped, so a
// change in one of them shows up as a diff instead of a silent `null`.
function enc(v) {
  if (typeof v === 'number') {
    if (Number.isNaN(v)) return { nan: true };
    if (v === Infinity) return { infinity: 1 };
    if (v === -Infinity) return { infinity: -1 };
    // -0 and 0 are === but JSON.stringify collapses them, hiding a sign flip.
    if (v === 0 && 1 / v < 0) return { negativeZero: true, value: 0 };
    return v;
  }
  if (Array.isArray(v)) return v.map(enc);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) o[k] = enc(v[k]);
    return o;
  }
  return v;
}

/** Runs `fn`, turning a throw into data instead of a crashed harness. */
function attempt(fn) {
  try {
    const value = fn();
    return { threw: false, value: enc(value) };
  } catch (e) {
    return {
      threw: true,
      errorName: e && e.name ? String(e.name) : 'unknown',
      errorMessage: e && e.message ? String(e.message).slice(0, 300) : '',
      value: null,
    };
  }
}

const sha = (file) =>
  crypto.createHash('sha256').update(fs.readFileSync(path.join(here, file))).digest('hex');

// ── load the reference ──────────────────────────────────────────────────────
// The prototype's inline scripts run their own `init()` / `recalculate()` at
// load, so the DOM shim has to be installed first. It is removed again before
// any number is collected, so nothing a check measures can depend on it.
const GUIDE_INPUT_DEFAULTS = {
  hfov: '65',
  vfov: '50',
  overlap: '20',
  length: '70',
  width: '22',
  margin: '6',
  spacing: '20',
  pattern: 'rows',
};
const BOARD_INPUT_DEFAULTS = {
  hfov: '75',
  vfov: '55',
  overlap: '20',
  roomL: '70',
  roomW: '22',
  clearance: '4',
  userX: '11',
  userY: '8',
  yawStart: '0',
  extraMove: '8',
};

const shim = installDom({
  inputDefaults: { ...GUIDE_INPUT_DEFAULTS, ...BOARD_INPUT_DEFAULTS },
});

const E = require('./engine_realistic_test.js');
const P = require('./prototype_capture_1.js');
const G = require('./automated_guide.js');
const B = require('./sequence_board.js');

for (const [label, mod, needed] of [
  ['engine_realistic_test.js', E, ['planAll', 'covStats', 'samples', 'BASE', 'runTests', 'basis', 'vec', 'wrap']],
  ['prototype_capture_1.js', P, ['TG', 'ad', 'dirT', 'plan', 'tick', 'startCap', 'mk', 'init', 'near', 'nextIdx']],
  ['automated_guide.js', G, ['makeSteps', 'steps']],
  ['sequence_board.js', B, ['calcPlan', 'plan']],
]) {
  const missing = needed.filter((n) => mod[n] === undefined);
  if (missing.length) throw new Error(`${label}: export(s) unresolved: ${missing.join(', ')}`);
}

warn('reference modules loaded');

// ══ 1. The fixed 26-point grid, exactly as `TG` builds it ═══════════════════
const fixedGrid = {
  source: 'prototype_capture_1.js (360° Capture Prototype (1).html, script lines 3-6)',
  total: P.TG.length,
  // The prototype's own ring tables, copied not re-derived.
  ringNames: P.RN,
  ringPitches: P.RP,
  cells: P.TG.map((g, i) =>
    enc({
      i,
      yaw: g.y,
      pitch: g.p,
      ringName: g.n,
      // `k` is the prototype's own 1-BASED ordinal ("1 of 8"); `c` its size.
      k: g.k,
      c: g.c,
      ordinalText: g.n + ' · ' + g.k + ' of ' + g.c,
    }),
  ),
  // Order the grid is walked in, and where each ring's block starts.
  order: P.TG.map((g, i) => enc({ i, yaw: g.y, pitch: g.p })),
  ringBlocks: (() => {
    const blocks = {};
    P.TG.forEach((g, i) => {
      const key = g.n + '@' + g.p;
      (blocks[key] = blocks[key] || []).push(i);
    });
    // Sorted so the JSON key order cannot drift between runs.
    return Object.keys(blocks)
      .sort()
      .map((k) => enc({ ring: k, indices: blocks[k], count: blocks[k].length }));
  })(),
  distinctYaws: [...new Set(P.TG.map((g) => g.y))].sort((a, b) => a - b),
  distinctPitches: [...new Set(P.TG.map((g) => g.p))].sort((a, b) => a - b),
  poles: P.TG.map((g, i) => enc({ i, yaw: g.y, pitch: g.p, isPole: Math.abs(g.p) === 90 })).filter(
    (x) => x.isPole,
  ),
};

// ══ 2. The sample grid the reference measures coverage on ═══════════════════
// Read back from the reference's own `samples()`, not reconstructed here: the
// committed coordinates are the only way to tell a storage-precision difference
// from a genuinely different grid, which is the distinction the Dart port has to
// get right — its `fibonacciSamples` quantises every coordinate to float32 on
// store precisely so that these bits come out identical.
const sampleGrid = (() => {
  const S = E.samples(SAMPLE_N);
  const idx = [0, 1, 2, 3, 4, 5, 6, 7, 500, 999, 1000, 1381, 2000, 2718, 3141, 3996, 3997, 3998, 3999];
  let sx = 0,
    sy = 0,
    sz = 0,
    sabx = 0,
    maxR = 0,
    minR = Infinity;
  for (let i = 0; i < S.n; i++) {
    sx += S.x[i];
    sy += S.y[i];
    sz += S.z[i];
    sabx += Math.abs(S.x[i]);
    // `Math.sqrt(x*x + y*y + z*z)` rather than `Math.hypot(x, y, z)`, because
    // this check compares bit for bit with the same expression written in Dart,
    // and hypot's internal scaling differs from it by an ulp. Neither form is
    // something the reference itself computes — the radius only probes that the
    // stored grid is the reference's.
    const r = Math.sqrt(S.x[i] * S.x[i] + S.y[i] * S.y[i] + S.z[i] * S.z[i]);
    maxR = Math.max(maxR, r);
    minR = Math.min(minR, r);
  }
  return enc({
    note: "the reference's own sample grid, read back from samples() — not rebuilt here",
    n: S.n,
    storage: 'Float32Array for x, y and z (the Dart port rounds each coordinate to float32 on store, so the grids are the same bits)',
    radiusNote: 'sqrt(x*x+y*y+z*z), evaluated identically on both sides; not Math.hypot',
    points: idx.map((i) => enc({ i, x: S.x[i], y: S.y[i], z: S.z[i] })),
    sums: { x: sx, y: sy, z: sz, absX: sabx },
    radiusRange: { min: minR, max: maxR },
  });
})();

// The prototype's own angle-difference and wording helpers, as tables.
const prototypeHelpers = {
  ad: [
    [350, 10],
    [10, 350],
    [0, 180],
    [90, 450],
    [0, 0],
    [-179, 179],
    [179, -179],
    [40, 0],
    [0, 40],
    [NaN, 0],
  ].map(([a, b]) => enc({ a, b, ad: P.ad(a, b) })),
  dirT: [
    [10, 0],
    [-10, 0],
    [-10, 5],
    [5, -10],
    [0, 30],
    [0, 10],
    [0, -10],
    [0, -30],
    [0, 0],
    [1, 1],
    [30, 30],
  ].map(([dy, dp]) => enc({ dy, dp, text: P.dirT(dy, dp) })),
  roomPlan: [
    ['small', 'open'],
    ['small', 'part'],
    ['medium', 'open'],
    ['medium', 'part'],
    ['large', 'open'],
    ['large', 'part'],
  ].map(([size, obs]) => {
    P.init();
    P.S.size = size;
    P.S.obs = obs;
    return enc({ size, obs, ...P.plan(), stationCandidates: P.cands().length, firstPos: P.firstPos() });
  }),
};

// ══ 2. The 6-state machine, run for real ═══════════════════════════════════
// `tick()` is the prototype's own source; the only input is `S.auto = true`,
// which is exactly what the page's "Auto-demo" button sets (`ctl('auto')`), and
// the shim, which never feeds the arithmetic.
function freshMachine({ auto = true, targetIndex = 0, fail = false } = {}) {
  P.init();
  P.S.auto = auto;
  P.S.fail = fail;
  P.startCap();
  // startCap() → beginAR() → go(5) → render() → arBind(), which arms
  // `S.tm = setInterval(tick, 50)` and calls tick() once. Kill the timer so the
  // harness drives it step by step; the one eager call is counted as tick 1.
  clearInterval(P.S.tm);
  const ticks = [1];
  const record = [];
  let prev = P.S.cs;
  // The head is recorded with every transition because `tick()` does not reset
  // it between targets: the yaw error a target starts from is whatever the
  // previous convergence left, which is what makes the pole rule observable in
  // a log the frame array alone cannot produce.
  record.push(enc({ tick: 1, state: P.S.cs, targetIndex: P.S.idx, head: { y: P.S.h.y, p: P.S.h.p } }));
  return {
    ticks,
    _record: record,
    _prev: () => prev,
    get state() {
      return P.S.cs;
    },
    get s() {
      return P.S;
    },
    step() {
      const n = ticks[ticks.length - 1] + 1;
      ticks.push(n);
      P.tick();
      if (P.S.cs !== prev) {
        record.push(enc({ tick: n, state: P.S.cs, targetIndex: P.S.idx, head: { y: P.S.h.y, p: P.S.h.p } }));
        prev = P.S.cs;
      }
      return n;
    },
    runUntil(pred, cap = 4000) {
      let guard = 0;
      while (!pred() && guard++ < cap) this.step();
      return { satisfied: pred(), steps: guard };
    },
  };
}

const machineRun = (() => {
  const m = freshMachine();
  m.runUntil(() => m.state === 'done');
  const acceptedTotal = m.s.st[0].f.filter((v) => v === 1).length;

  // Snapshot the first target now. `m._record` is the live log and the loop
  // below keeps stepping the same machine, so reading it afterwards would
  // return all 26 targets under a key that says "first target".
  const firstTarget = m._record.slice();

  // Full station: walk every one of the 26 targets the way the page does.
  let guard = 0;
  while (m.s.st[0].f.filter((v) => v === 1).length < 26 && guard++ < 20000) {
    if (m.state === 'done') m.step();
    else m.step();
  }
  const f = m.s.st[0].f.slice();
  return {
    firstTargetTransitions: firstTarget,
    // The whole station, one row per state change with the target index it
    // happened on. This is what makes the pole rule testable without faking a
    // machine that starts at target 24: the page gets there by accepting the
    // 23 before it, and that is exactly what this log contains.
    transitions: m._record.slice(),
    firstTargetTicks: {
      toSearch: (firstTarget.find((r) => r.state === 'search') || {}).tick ?? null,
      toAlign: (firstTarget.find((r) => r.state === 'align') || {}).tick ?? null,
      toCap: (firstTarget.find((r) => r.state === 'cap') || {}).tick ?? null,
      toDone: (firstTarget.find((r) => r.state === 'done') || {}).tick ?? null,
    },
    // 1.4 s at a 50 ms tick is 28 ticks; the page counts its eager first tick.
    dtSeconds: 0.05,
    statesVisited: [...new Set(firstTarget.map((r) => r.state))],
    acceptedAfterFirstTarget: acceptedTotal,
    fullStation: enc({ accepted: f.filter((v) => v === 1).length, totalTargets: f.length, f }),
    nextIdxFromZero: (() => {
      P.init();
      P.S.st = [P.mk()];
      P.S.idx = 0;
      return P.nextIdx();
    })(),
  };
})();

const machinePole = (() => {
  // Zenith is TG[24]. `near()` is the page's own simulated-head placement:
  // `S.h={y:pole?S.h.y:g.y-40,p:g.p===90?35:...}` — for a pole it keeps the
  // current head yaw and starts the pitch 55° below the target.
  P.init();
  P.S.auto = true;
  P.S.st = [P.mk()];
  P.S.cur = 0;
  P.S.idx = 24;
  P.near(24);
  const head = { y: P.S.h.y, p: P.S.h.p };
  P.S.cs = 'align';
  P.S.t = 0;
  // `tick()` opens with `if(S.scr!==5||S.ovl||S.map)return;` and then
  // `if(S.dr>.3){drift();return}`. Left at the page default the call returns at
  // that guard and "state after one tick" measures the guard instead of the pole
  // rule, so arm the machine the way `beginAR()` does before stepping it.
  P.S.scr = 5;
  P.S.ovl = '';
  P.S.map = false;
  P.S.dr = 0;
  // One manual tick to let tick() recompute dy/dp with the pole rule.
  P.tick();
  // `dy` and `dp` are `let`s inside tick(), so they are not readable here; what
  // the page makes observable is the state, the head it moved, and the direction
  // text built from `dirT(dy, dp)`, which is carried in `S.mk`.
  const mk = P.S.mk;
  return enc({
    // The grid index, recorded so the Dart suite looks the target up instead of
    // assuming which row the zenith sits in.
    targetIndex: 24,
    target: P.TG[24],
    headAfterNear: head,
    headAfterTick: { y: P.S.h.y, p: P.S.h.p },
    stateAfterOneTick: P.S.cs,
    renderKeyAfterOneTick: typeof mk === 'string' ? mk : null,
    note: 'tick() forces dy=0 at a pole, so d=|dp| only',
  });
})();

const machineFailAndMotion = (() => {
  const m = freshMachine({ fail: true });
  m.runUntil(() => m.state === 'fail', 4000);
  // The prototype writes its instruction line into `#ip`. It is a DOM string,
  // but the *text* is generated by tick()'s own arithmetic, so recording it is
  // recording the machine's output, not the shim's.
  const failRow = enc({
    reachedFail: m.state === 'fail',
    ticks: m._record.slice(),
    cellValueAfterFail: m.s.st[0].f[m.s.idx],
    msgFlag: m.s.msg,
    instructionHtml: shim.byId('ip').innerHTML,
    bannerHtml: shim.byId('bn').textContent,
    counter: shim.byId('cnt').textContent,
  });

  // "Phone moving" during cap: tick() exits cap when d>10 and sets S.msg='moving'.
  const m2 = freshMachine();
  m2.runUntil(() => m2.state === 'cap', 4000);
  // Drag the head 30° off target the way arBind()'s pointermove handler does.
  m2.s.auto = false;
  m2.s.h.y = (m2.s.h.y + 30 + 360) % 360;
  m2.step();
  const motionRow = enc({
    stateAfterDrag: m2.state,
    msg: m2.s.msg,
    mt: m2.s.mt,
    acceptedCell: m2.s.st[0].f[m2.s.idx],
    bannerText: shim.byId('bn').textContent,
  });
  return { failPath: failRow, motionDuringCap: motionRow };
})();

// ══ 3. The adaptive planner: frame counts ══════════════════════════════════
// The lenses the Dart engine is designed against, plus the JS engine's own
// default. "Default overlap" is BASE.oh/BASE.ov = 0.25/0.25.
const LENSES = [
  { label: 'dart_portrait_default', H: 53.669, V: 68 },
  { label: 'js_engine_default_BASE', H: E.BASE.H, V: E.BASE.V },
  { label: 'lens_60x50', H: 60, V: 50 },
  { label: 'lens_60x45', H: 60, V: 45 },
  { label: 'lens_40x30', H: 40, V: 30 },
  { label: 'lens_90x60', H: 90, V: 60 },
];
const DEFAULT_OVERLAP = { oh: E.BASE.oh, ov: E.BASE.ov };

const planMatrix = LENSES.map((l) => {
  const P_adaptive = E.planAll({ ...E.BASE, H: l.H, V: l.V, ...DEFAULT_OVERLAP, pattern: 'adaptive' });
  const P_uniform = E.planAll({ ...E.BASE, H: l.H, V: l.V, ...DEFAULT_OVERLAP, pattern: 'uniform' });
  const P_norepair = E.planAll({ ...E.BASE, H: l.H, V: l.V, ...DEFAULT_OVERLAP, pattern: 'adaptive', repair: false });
  const shape = (p) =>
    enc({
      frames: p.frames.length,
      rows: p.rows.map((r) => r.n),
      rowPitches: p.rows.map((r) => r.pitch),
      rowSpacings: p.rows.map((r) => r.spacing),
      rowOverlaps: p.rows.map((r) => r.overlap),
      poleFrames: p.stats ? p.stats.poleFrames : null,
      repairs: p.stats ? p.stats.repairs : null,
      baseFrames: p.stats ? p.stats.baseFrames : null,
      minOverlap: p.stats ? p.stats.minOverlap : null,
      time: p.time,
      countCheckMsg: (p.checks.find((c) => c.msg.indexOf('Frame count') === 0) || {}).msg || null,
    });
  return enc({
    label: l.label,
    H: l.H,
    V: l.V,
    overlap: DEFAULT_OVERLAP,
    adaptive: shape(P_adaptive),
    uniform: shape(P_uniform),
    adaptiveNoRepair: shape(P_norepair),
    checks: P_adaptive.checks.map((c) => ({ lv: c.lv, msg: c.msg })),
    frames: P_adaptive.frames.map((f) => ({
      i: f.i,
      yaw: f.yaw,
      pitch: f.pitch,
      row: f.row === undefined ? null : f.row,
      pole: !!f.pole,
      zen: !!f.zen,
      nad: !!f.nad,
      extra: !!f.extra,
      d: f.d,
    })),
  });
});

// ══ 4. Coverage, by the JS's own sampler and its own `covStats` ════════════
const coverageMatrix = LENSES.map((l) => {
  const S = E.samples(SAMPLE_N);
  const mk = (pattern, repair) =>
    E.covStats(
      E.planAll({ ...E.BASE, H: l.H, V: l.V, ...DEFAULT_OVERLAP, pattern, repair }).frames,
      S,
    );
  const toFixed = (st) =>
    enc({
      coveragePct: st.coverage,
      doubleCoveredPct: st.overlapPct,
      singlePct: st.singlePct,
      uncoveredPct: st.uncoveredPct,
      minMarginDeg: st.minMargin,
      frames: st.frames,
      // The JS's own 15°×15° hole clustering, kept whole: Dart must reproduce
      // the bins, not just the totals.
      uncovered: st.uncovered,
    });
  return enc({
    label: l.label,
    H: l.H,
    V: l.V,
    sampleCount: S.n,
    adaptiveRepaired: toFixed(mk('adaptive', true)),
    adaptiveNoRepair: toFixed(mk('adaptive', false)),
    uniformRepaired: toFixed(mk('uniform', true)),
    // And the FIXED 26-point grid, shot with the same lens: the prototype ships
    // a fixed grid, so the brief's "which value does the source generate" question
    // needs both planners side by side.
    fixedGrid26: toFixed(E.covStats(P.TG.map((g) => ({ yaw: g.y, pitch: g.p, H: l.H, V: l.V })), S)),
  });
});

// ══ 5. Zenith / nadir handling ═════════════════════════════════════════════
const zenithNadir = (() => {
  const YIS = [0, 45, 90, 135, 180, -135, -90, -45, 17, 200];
  const plan = E.planAll({ ...E.BASE, H: 53.669, V: 68, ...DEFAULT_OVERLAP });
  const zen = plan.frames.find((f) => f.zen);
  const nad = plan.frames.find((f) => f.nad);

  // Does the JS's own frustum test depend on the yaw term at the pole?
  const coverAtPole = YIS.map((y) => {
    const st = E.covStats([{ yaw: y, pitch: 90, H: 60, V: 60 }], E.samples(SAMPLE_N));
    return enc({ yaw: y, coveragePct: st.coverage });
  });
  const spread = Math.max(...coverAtPole.map((c) => c.coveragePct)) - Math.min(...coverAtPole.map((c) => c.coveragePct));

  // `ensureD` is the JS's pole special case for the direction vector.
  const ensureDCopy = [];
  const frames = [{ yaw: 123, pitch: 90, pole: true, zen: true }, { yaw: 55, pitch: -90, pole: true, nad: true }, { yaw: 55, pitch: 89 }];
  E.ensureD(frames);
  for (const f of frames) ensureDCopy.push(enc({ yaw: f.yaw, pitch: f.pitch, pole: !!f.pole, d: f.d }));

  // Guidance arithmetic at the pole.
  const ad = (a, b) => ((a - b + 540) % 360) - 180;
  const guidancePole = YIS.map((y) => {
    const g = { y, p: 90 };
    const pole = Math.abs(g.p) === 90;
    return enc({
      targetYaw: y,
      targetPitch: g.p,
      headYaw: 0,
      headPitch: 0,
      dyIfPoleRuleApplied: pole ? 0 : ad(g.y, 0),
      dyWithoutPoleRule: ad(g.y, 0),
      dEuclidean: Math.hypot(pole ? 0 : ad(g.y, 0), g.p - 0),
    });
  });

  // The `aim()` axis degenerates when forward and target are parallel.
  const aimPole = YIS.map((y) => {
    const q = E.qFromYawPitch(y, 88);
    const a = E.aim(q, [0, 1, 0]);
    return enc({ yaw: y, pitch: 88, angleDeg: a.angle, axis: a.axis, degenerate: a.degenerate });
  });
  const aimSpread = Math.max(...aimPole.map((r) => r.angleDeg)) - Math.min(...aimPole.map((r) => r.angleDeg));

  // qFromYawPitch straight to the pole, and slerp through it.
  const poleSweep = [];
  let prevQ = null;
  let maxJump = 0;
  let flips = 0;
  for (let p = 85; p <= 95.0001; p += 0.1) {
    const q = E.qFromYawPitch(0, p);
    if (prevQ) {
      const dd = E.qDot(prevQ, q);
      maxJump = Math.max(maxJump, 1 - Math.abs(dd));
      if (dd < 0) flips++;
    }
    prevQ = q;
    if (Math.abs(p - 90) < 1e-9) poleSweep.push(enc({ pitch: p, q }));
  }

  return enc({
    note: 'yaw the plan stores for the pole frames, and every way the JS reads it back',
    zenithFrame: { yaw: zen.yaw, pitch: zen.pitch, pole: zen.pole, zen: zen.zen, d: zen.d },
    nadirFrame: { yaw: nad.yaw, pitch: nad.pitch, pole: nad.pole, nad: nad.nad, d: nad.d },
    basisAtPole: YIS.map((y) => enc({ yaw: y, pitch: 90, basis: E.basis(y, 90) })).concat(
      YIS.map((y) => enc({ yaw: y, pitch: -90, basis: E.basis(y, -90) })),
    ),
    coverageIndependenceOfYaw: { samples: coverAtPole, coverageSpreadAcrossYaw: spread },
    ensureDIsFunction: typeof E.ensureD === 'function',
    ensureDSamples: ensureDCopy,
    guidancePoleRule: guidancePole,
    aimAtPole: aimPole,
    aimAngleSpreadAcrossYaw: aimSpread,
    poleSweep: { exact: poleSweep, maxQuaternionJump: maxJump, hemisphereFlips: flips },
    qYawPitchAtPole: [90, 89.9, -90, -89.9].map((p) =>
      enc({ pitch: p, recovered: E.qYawPitch(E.qFromYawPitch(37, p)) }),
    ),
  });
})();

// ══ 6. Accepted ranges and invalid inputs ═════════════════════════════════
const invalidInputs = (() => {
  const cases = [
    { label: 'fov_0_H', patch: { H: 0 } },
    { label: 'fov_0_V', patch: { V: 0 } },
    { label: 'fov_180_H', patch: { H: 180 } },
    { label: 'fov_180_V', patch: { V: 180 } },
    { label: 'fov_10_min_ok', patch: { H: 10, V: 10 } },
    { label: 'fov_150_max_ok', patch: { H: 150, V: 150 } },
    { label: 'fov_9_min_rejected', patch: { H: 9, V: 9 } },
    { label: 'fov_151_rejected', patch: { H: 151, V: 90 } },
    { label: 'overlap_1_0_H', patch: { oh: 1.0 } },
    { label: 'overlap_1_0_V', patch: { ov: 1.0 } },
    { label: 'overlap_negative_H', patch: { oh: -0.5 } },
    { label: 'overlap_negative_V', patch: { ov: -0.5 } },
    { label: 'overlap_0_ok', patch: { oh: 0, ov: 0 } },
    { label: 'overlap_0_8_max_ok', patch: { oh: 0.8, ov: 0.8 } },
    { label: 'overlap_0_81_rejected', patch: { oh: 0.81 } },
    { label: 'fov_NaN_H', patch: { H: NaN } },
    { label: 'overlap_NaN', patch: { oh: NaN } },
    { label: 'fov_negative', patch: { H: -30 } },
    { label: 'fov_Infinity', patch: { H: Infinity } },
    { label: 'yaw0_1e9', patch: { yaw0: 1e9 } },
    { label: 'turn_0_falsy_default', patch: { turn: 0 } },
    { label: 'settle_0_falsy_default', patch: { settle: 0 } },
    { label: 'quality_unknown_key', patch: { q: 'ultra' } },
  ];

  const planResults = cases.map((c) => {
    const r = attempt(() => {
      const p = E.planAll({ ...E.BASE, ...c.patch });
      return {
        errs: p.errs,
        frames: p.frames.length,
        checkLevels: p.checks.map((x) => x.lv),
        checkMsgs: p.checks.map((x) => x.msg),
        coverage: p.stats ? p.stats.coverage : null,
        minOverlap: p.stats ? p.stats.minOverlap : null,
        time: p.time,
      };
    });
    return enc({ label: c.label, patch: c.patch, plan: r });
  });

  // Direct calls that bypass checkParams — this is where the garbage lives.
  const direct = attempt(() => ({
    lonWidth_H0: E.lonWidth(0, 0, 0),
    lonWidth_H180: E.lonWidth(0, 180, 180),
    lonWidth_HNaN: E.lonWidth(0, NaN, NaN),
    lonWidth_V0: E.lonWidth(0, 60, 0),
    lonWidth_polePitch: E.lonWidth(90, 60, 60),
    wrap_NaN: E.wrap(NaN),
    wrap_Infinity: E.wrap(Infinity),
    wrap_negativeZero: E.wrap(-0),
    angle_NaN: E.angle({ yaw: NaN, pitch: 0 }, { yaw: 0, pitch: 0 }),
    clamp_reversedBounds: E.clamp(5, 10, 1),
    qAxis_zeroLengthAxis: E.qAxis(90, [0, 0, 0]),
    qN_zeroQuaternion: E.qN([0, 0, 0, 0]),
    project_zeroDepth: E.project([0, 0, 0], 270, 360, 55, 70),
    project_NaN: E.project([NaN, NaN, NaN], 270, 360, 55, 70),
    project_fov180: E.project([0, 0, 1], 270, 360, 180, 180),
    project_fov0: E.project([0, 0, 1], 270, 360, 0, 0),
    aim_opposite: E.aim(E.qFromYawPitch(0, 0), [0, 0, -1]),
    aim_zeroTarget: E.aim(E.qFromYawPitch(0, 0), [0, 0, 0]),
    wording_NaN: E.wording([NaN, NaN, NaN], 90, 2.5),
    cover_NaNfov: (() => {
      const st = E.covStats([{ yaw: 0, pitch: 0, H: NaN, V: NaN }], E.samples(SAMPLE_N));
      return { coverage: st.coverage, uncovered: st.uncoveredPct };
    })(),
    cover_zeroFov: (() => {
      const st = E.covStats([{ yaw: 0, pitch: 0, H: 0, V: 0 }], E.samples(SAMPLE_N));
      return { coverage: st.coverage, uncovered: st.uncoveredPct };
    })(),
    samples_zero: (() => {
      const s = E.samples(0);
      return { n: s.n };
    })(),
    fill_NaNfov: (() => {
      const frames = [{ yaw: 0, pitch: 0, H: NaN, V: NaN }];
      return E.fill(frames, E.samples(200), NaN, NaN, 3).length;
    })(),
  }));

  // The gate itself, so the accepted range is recorded as data, not prose.
  const range = {
    H: [],
    V: [],
    oh: [],
    ov: [],
  };
  for (const h of [0, 1, 9, 9.999, 10, 150, 150.001, 151, 180, 360, -1, NaN]) {
    range.H.push(enc({ value: h, errors: E.checkParams({ ...E.BASE, H: h }) }));
  }
  for (const o of [-1, -0.001, 0, 0.8, 0.8001, 1, NaN]) {
    range.oh.push(enc({ value: o, errors: E.checkParams({ ...E.BASE, oh: o }) }));
    range.ov.push(enc({ value: o, errors: E.checkParams({ ...E.BASE, ov: o }) }));
  }

  return enc({ planResults, directCalls: direct, rangeProbe: range });
})();

// ══ 7. The vector / quaternion helpers the guidance runs on ════════════════
const vectorHelpers = (() => {
  const yaws = [-180, -135, -90, -45, 0, 37, 45, 90, 135, 180, 200, 360];
  const pitches = [-90, -89, -40, -10, 0, 10, 40, 89, 90];
  const poses = [];
  for (const y of yaws) for (const p of pitches) {
    const q = E.qFromYawPitch(y, p);
    const b = E.basis(y, p);
    const qb = E.qBasis(q);
    poses.push(
      enc({
        yaw: y,
        pitch: p,
        q,
        basis: b,
        qBasis: qb,
        yawPitchRecovered: E.qYawPitch(q),
        // Does qFromYawPitch agree with basis() at all? The engine's own header
        // comment claims it does "exactly (verified in the automated tests)".
        // Nothing in runTests() actually compares them, so it is measured here:
        // basis() rows [r,u,f] vs the quaternion's rotated axes.
        basisVsQuaternionMaxComponentDiff: Math.max(
          ...[0, 1, 2].map((k) =>
            Math.max(
              Math.abs(qb[0][k] - b.r[k]),
              Math.abs(qb[1][k] - b.u[k]),
              Math.abs(qb[2][k] - b.f[k]),
            ),
          ),
        ),
      }),
    );
  }

  // dCam / wording / turn-direction rule.
  // The tolerance the wording switches on is the reference's own `T0.tol`, read
  // from the module rather than typed in, and recorded in the golden so the Dart
  // suite passes the same number in instead of hard-coding one.
  const DC_TABLE_TOL = E.T0.tol;
  // The projection viewport the Dart suite pins, hoisted here because both this
  // table and the fixtures below use it. Not chosen by this harness: it is the
  // argument list the reference's own `runTests()` projection assertion uses
  // (`engine_realistic_test.js`: `project(dCam(qFromYawPitch(0,0),[0,0,1]),270,360,55,70)`),
  // so the Dart suite compares against the same numbers the JS asserts about
  // itself, and no expected value lives only in the test.
  const viewport = { w: 270, h: 360, hfovDeg: 55, vfovDeg: 70 };
  const V = (dc) => E.project(dc, viewport.w, viewport.h, viewport.hfovDeg, viewport.vfovDeg);
  const dcTable = [];
  for (const yaw of [-90, -40, -10, 0, 10, 40, 90, 170, 180, -170]) {
    for (const pitch of [-60, -20, 0, 20, 60]) {
      const q = E.qFromYawPitch(0, 0);
      const d = E.vec(yaw, pitch);
      const dc = E.dCam(q, d);
      const err = E.aim(q, d).angle;
      const pr = V(dc);
      dcTable.push(
        enc({
          targetYaw: yaw,
          targetPitch: pitch,
          d,
          dCam: dc,
          aimAngleDeg: err,
          wording: E.wording(dc, err, DC_TABLE_TOL),
          // The prototype's own turn rule: sign of the horizontal camera axis.
          turnFromCrossProduct: (() => {
            const f = E.qRot(q, [0, 0, 1]);
            const u = E.qRot(q, [0, 1, 0]);
            return E.dot3(E.cross3(f, d), u);
          })(),
          screenU: pr.u,
          screenV: pr.v,
          onScreen: pr.onScreen,
        }),
      );
    }
  }

  // Dead code, measured anyway so the claim is checked rather than asserted.
  const deadCode = (() => {
    const q = E.qFromYawPitch(30, -20);
    return enc({
      qConj: E.qConj(q),
      qBasis: E.qBasis(q),
      qSlerp_mid: E.qSlerp(E.qFromYawPitch(0, 0), E.qFromYawPitch(90, 0), 0.5),
      qSlerp_endpoints: [
        E.qSlerp(E.qFromYawPitch(0, 0), E.qFromYawPitch(90, 0), 0),
        E.qSlerp(E.qFromYawPitch(0, 0), E.qFromYawPitch(90, 0), 1),
      ],
      note: 'qConj / qBasis / qSlerp are never called by the page or by runTests()',
    });
  })();

  // Round trips that the Dart port claims at 1e-9.
  const roundTrips = enc({
    quatMatrixQuat: [
      [37, -62],
      [0, 90],
      [180, -90],
      [-135, 45],
    ].map(([y, p]) => {
      const q = E.qFromYawPitch(y, p);
      const back = E.matToQ(E.qToMat(q));
      const d1 = Math.max(...[0, 1, 2, 3].map((i) => Math.abs(q[i] - back[i])));
      const d2 = Math.max(...[0, 1, 2, 3].map((i) => Math.abs(q[i] + back[i])));
      return { yaw: y, pitch: p, q, back, maxAbsDiff: d1, maxNegatedDiff: d2, error: Math.min(d1, d2) };
    }),
    slerpIsIdentityAtEndpoints: (() => {
      const a = E.qFromYawPitch(-40, 20);
      const b = E.qFromYawPitch(120, -70);
      return { at0: E.qSlerp(a, b, 0), at1: E.qSlerp(a, b, 1), a, b };
    })(),
    deviceOrientation: [
      [0, 0, 0, 0],
      [90, 0, 0, 0],
      [0, 90, 0, 0],
      [0, 0, 90, 0],
      [0, 0, 0, 90],
      [45, -30, 15, 0],
    ].map(([al, be, ga, scr]) => ({
      alpha: al,
      beta: be,
      gamma: ga,
      screenDeg: scr,
      q: E.qFromDevice(al, be, ga, scr),
      yawPitch: E.qYawPitch(E.qFromDevice(al, be, ga, scr)),
    })),
  });

  // The projection fixtures the Dart port pins, verbatim from the JS — see the
  // `viewport` note above for where its arguments come from. Each case carries its
  // own input direction, so the Dart test never has to guess one.
  const projCases = [
    {
      name: 'straightAhead',
      dc: E.dCam(E.qFromYawPitch(0, 0), [0, 0, 1]),
    },
    {
      name: 'tenRightVec10_0',
      dc: E.dCam(E.qFromYawPitch(0, 0), E.vec(10, 0)),
    },
    ...[
      [0, 0, -1],
      [-1, 0, -1],
      [0, 1, -1],
    ].map((dc) => ({ name: `behindCamera_${dc.join('_')}`, dc })),
  ].map((c) => ({ ...c, projected: V(c.dc) }));
  const fixtures = enc({
    viewport,
    projCases,
    viewportNote:
      'the viewport and fields come from the reference runTests() projection '
        + 'assertion, not chosen by this harness',
    tenRightExpected: (() => {
      const fx = viewport.w / 2 / Math.tan(viewport.hfovDeg * E.D2R / 2);
      return viewport.w / 2 + fx * Math.tan(10 * E.D2R);
    })(),
    ninetyDegreeFrustumSolidAngle: (() => {
      const st = E.covStats([{ yaw: 0, pitch: 0, H: 90, V: 90, d: [0, 0, 1] }], E.samples(SAMPLE_N));
      return { measuredPct: st.coverage, exactPct: 100 / 6, delta: st.coverage - 100 / 6 };
    })(),
  });

  return enc({
    poses,
    dcTable,
    dcTableTol: DC_TABLE_TOL,
    roundTrips,
    deadCode,
    fixtures,
    sampleCount: SAMPLE_N,
  });
})();

// ══ 8. The two other planners in the reference set ════════════════════════
const otherPlanners = (() => {
  const guideSteps = attempt(() => {
    const steps = G.makeSteps();
    return {
      count: steps.length,
      yawDistinct: [...new Set(steps.map((s) => s.yaw))].sort((a, b) => a - b),
      tiltDistinct: [...new Set(steps.map((s) => s.tilt))].sort((a, b) => b - a),
      first: steps.slice(0, 3),
      last: steps.slice(-3),
    };
  });
  const board = attempt(() => {
    B.calcPlan();
    const rows = B.plan.filter((f) => f.type === 'row');
    return {
      count: B.plan.length,
      rowFrames: rows.length,
      nYaw: rows.length ? rows[0].nYaw : null,
      nRows: [...new Set(rows.map((f) => f.row))].length,
      rowPitches: [...new Set(rows.map((f) => f.pitch))].sort((a, b) => b - a),
      yaws: [...new Set(rows.map((f) => Math.round(f.yaw)))].sort((a, b) => a - b),
      poles: B.plan.filter((f) => f.type === 'pole'),
      firstFrames: B.plan.slice(0, 4),
    };
  });
  return {
    automatedGuide_makeSteps_default: guideSteps,
    sequenceBoard_calcPlan_default: board,
    note:
      'defaults come from the value= attributes of each file\'s own inputs ' +
      '(guide hfov 65 / vfov 50 / overlap 20; board hfov 75 / vfov 55 / overlap 20), ' +
      'injected through the DOM shim rather than assumed',
  };
})();

// ══ 9. The prototype's own self-test ══════════════════════════════════════
const engineSelfTests = (() => {
  const out = E.runTests();
  return enc({
    total: out.length,
    passed: out.filter((t) => t.pass).length,
    failed: out.filter((t) => !t.pass).map((t) => t.name),
    checks: out.map((t) => ({ name: t.name, pass: t.pass, detail: t.detail })),
  });
})();

// ══ emit ══════════════════════════════════════════════════════════════════
shim.uninstall();

const REGENERATE =
  'node tool/js_reference/extract.mjs && node tool/js_reference/run_reference.mjs --banner > test/js_golden.json';
// `--banner` is the freeze mode: it prefixes the document with `//` lines so the
// committed golden file carries its own provenance. JSON has no comment syntax,
// so the reader (`test/js_parity_checks.dart`) drops any line that starts with
// `//` before parsing. Without the flag stdout is pure JSON, so piping into
// `jq` or diffing two runs still works.
const banner = () =>
  [
    '// js_golden.json — values produced by the ORIGINAL reference JavaScript,',
    '// extracted verbatim into tool/js_reference/*.js and executed under Node.',
    '//',
    `// Regenerate with exactly this command, from the project root:`,
    `//   ${REGENERATE}`,
    '//',
    '// Do not hand-edit, and do not "fix" a number here to make a Dart check',
    '// pass: this file is the reference, the Dart engine is the thing under test.',
    '// Where Dart and these values disagree, the disagreement belongs in',
    '// docs/JS_PARITY_DISCREPANCIES.md and the check asserts the JS value.',
    '//',
    '// Contents: one section per question the brief asks — the fixed 26-point',
    '// grid, the prototype state machine, the adaptive plan matrix, the coverage',
    '// matrix, the poles, invalid inputs, the vector helpers and the other',
    '// planners. Deterministic: two runs are byte-identical, so a diff of this',
    '// file is a real change in the reference, not noise.',
    '',
  ].join('\n');

const golden = {
  meta: {
    generator: 'tool/js_reference/run_reference.mjs',
    regenerateCommand: REGENERATE,
    node: process.version,
    platform: process.platform,
    modules: {
      'engine_realistic_test.js': sha('engine_realistic_test.js'),
      'prototype_capture_1.js': sha('prototype_capture_1.js'),
      'automated_guide.js': sha('automated_guide.js'),
      'sequence_board.js': sha('sequence_board.js'),
    },
    defaultOverlap: DEFAULT_OVERLAP,
    defaultPlanParams: E.BASE,
    coverageSampleCount: SAMPLE_N,
    fixedGridTotal: P.TG.length,
  },
  fixedGrid,
  sampleGrid,
  prototypeHelpers,
  machineRun,
  machinePole,
  machineFailAndMotion,
  planMatrix,
  coverageMatrix,
  zenithNadir,
  invalidInputs,
  vectorHelpers,
  otherPlanners,
  engineSelfTests,
};

process.stdout.write(
  (process.argv.includes('--banner') ? banner() : '') +
    JSON.stringify(golden, null, 1) +
    '\n',
);
warn('golden document written to stdout');
