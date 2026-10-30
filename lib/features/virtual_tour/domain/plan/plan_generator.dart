import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/coverage.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';

/// Plan generation.
///
/// Ported from `planAll` and its helpers (`checkParams`, `QMIN`, `estTime`) in
/// `/*ENGINE*/`.
///
/// The frame count is **derived** from the camera field of view and the
/// requested overlap. There is no hardcoded 26 anywhere: the prototype's 26 was
/// an example produced by one particular FOV/overlap combination.

/// Minimum per-row overlap (as a fraction) implied by each quality preset.
const Map<String, double> qualityMinOverlap = <String, double>{
  'draft': 0.15,
  'standard': 0.25,
  'high': 0.35,
};

/// Inputs to [planAll].
class PlanParams {
  final double hfovDeg;
  final double vfovDeg;

  /// Requested horizontal overlap, 0…0.8.
  final double overlapH;

  /// Requested vertical overlap, 0…0.8.
  final double overlapV;

  /// `adaptive` (iso-latitude rings sized per row) or `uniform` (one column
  /// count for every row).
  final String pattern;

  final double yaw0Deg;

  /// When false, the greedy gap filler is skipped. Used by the tests to prove
  /// the row layout alone is already almost complete.
  final bool repair;

  /// `draft` | `standard` | `high`.
  final String quality;

  /// Time budget in minutes; 0 means no budget check.
  final double budgetMinutes;

  final double turnSpeedDegPerSec;
  final int settleMs;
  final int maxRetry;

  /// Minimum clearance from walls used by the viewpoint suggestion, in metres.
  final double clearanceM;

  const PlanParams({
    required this.hfovDeg,
    required this.vfovDeg,
    this.overlapH = 0.25,
    this.overlapV = 0.25,
    this.pattern = 'adaptive',
    this.yaw0Deg = 0,
    this.repair = true,
    this.quality = 'standard',
    this.budgetMinutes = 0,
    this.turnSpeedDegPerSec = 40,
    this.settleMs = 400,
    this.maxRetry = 3,
    this.clearanceM = 0.5,
  });

  PlanParams copyWith({
    double? hfovDeg,
    double? vfovDeg,
    double? overlapH,
    double? overlapV,
    String? pattern,
    double? yaw0Deg,
    bool? repair,
    String? quality,
    double? budgetMinutes,
    double? turnSpeedDegPerSec,
    int? settleMs,
    int? maxRetry,
    double? clearanceM,
  }) => PlanParams(
    hfovDeg: hfovDeg ?? this.hfovDeg,
    vfovDeg: vfovDeg ?? this.vfovDeg,
    overlapH: overlapH ?? this.overlapH,
    overlapV: overlapV ?? this.overlapV,
    pattern: pattern ?? this.pattern,
    yaw0Deg: yaw0Deg ?? this.yaw0Deg,
    repair: repair ?? this.repair,
    quality: quality ?? this.quality,
    budgetMinutes: budgetMinutes ?? this.budgetMinutes,
    turnSpeedDegPerSec: turnSpeedDegPerSec ?? this.turnSpeedDegPerSec,
    settleMs: settleMs ?? this.settleMs,
    maxRetry: maxRetry ?? this.maxRetry,
    clearanceM: clearanceM ?? this.clearanceM,
  );
}

/// One iso-latitude ring of the plan.
class PlanRow {
  final double pitchDeg;
  final double longitudeWidthDeg;

  /// Minimum column count that covers this ring.
  int need = 1;

  /// Column count actually used.
  int count = 1;

  double spacingDeg = 0;
  double overlap = 0;

  PlanRow({required this.pitchDeg, required this.longitudeWidthDeg});

  @override
  String toString() =>
      'row(pitch ${pitchDeg.toStringAsFixed(2)}°, '
      '$count×${spacingDeg.toStringAsFixed(1)}°, '
      'overlap ${(overlap * 100).toStringAsFixed(0)}%)';
}

/// One line of the plan's self-check report.
class PlanCheck {
  /// `ok` | `warn` | `fail`.
  final String level;
  final String message;

  const PlanCheck(this.level, this.message);

  @override
  String toString() => '[$level] $message';
}

/// The generated plan, with its own verification report.
class CapturePlan {
  final PlanParams params;
  final List<PlanFrame> frames;
  final List<PlanRow> rows;
  final CoverageStats? stats;
  final List<PlanCheck> checks;

  /// Estimated capture time in seconds.
  final double timeSeconds;

  /// Non-empty when the parameters were rejected; [frames] is then empty.
  final List<String> errors;

  const CapturePlan({
    required this.params,
    required this.frames,
    required this.rows,
    required this.stats,
    required this.checks,
    required this.timeSeconds,
    required this.errors,
  });

  bool get isValid => errors.isEmpty;

  @override
  String toString() =>
      'CapturePlan(${frames.length} frames, '
      '${rows.length} rows, coverage '
      '${stats == null ? 'n/a' : stats!.coveragePct.toStringAsFixed(2)}%)';
}

/// Validates the tunable inputs. Returns a list of human-readable problems.
List<String> checkPlanParams(PlanParams p) {
  final e = <String>[];
  if (!(p.hfovDeg >= 10 && p.hfovDeg <= 150)) {
    e.add('Horizontal FOV must be 10 to 150 degrees');
  }
  if (!(p.vfovDeg >= 10 && p.vfovDeg <= 150)) {
    e.add('Vertical FOV must be 10 to 150 degrees');
  }
  if (!(p.overlapH >= 0 && p.overlapH <= 0.8)) {
    e.add('Horizontal overlap must be 0 to 80%');
  }
  if (!(p.overlapV >= 0 && p.overlapV <= 0.8)) {
    e.add('Vertical overlap must be 0 to 80%');
  }
  return e;
}

/// Rough capture-time estimate: turn time between consecutive targets plus a
/// fixed settle-and-shoot cost per frame.
double estimateTimeSeconds(List<PlanFrame> frames, PlanParams p) {
  var t = 0.0;
  PlanFrame? prev;
  final turn = p.turnSpeedDegPerSec == 0 ? 40.0 : p.turnSpeedDegPerSec;
  for (final f in frames) {
    if (prev != null) {
      t +=
          geodesicAngleDeg(
            (yawDeg: prev.yawDeg, pitchDeg: prev.pitchDeg),
            (yawDeg: f.yawDeg, pitchDeg: f.pitchDeg),
          ) /
          turn;
    }
    t += (p.settleMs == 0 ? 400 : p.settleMs) / 1000 + 0.6;
    prev = f;
  }
  return t;
}

/// Generates the capture plan and verifies it.
///
/// Rows are iso-latitude rings. The pitch ladder runs symmetrically from
/// `−half` to `+half`, where `half = 90 − rc(1 − ov) − V/2` and
/// `rc = min(H, V)/2`, so the top and bottom rings stay inside the
/// pole-capable band and the pole frames have no gap to bridge.
CapturePlan planAll(PlanParams p, [SphereSamples? samplesOverride]) {
  final s = samplesOverride ?? fibonacciSamples(4000);
  final errs = checkPlanParams(p);
  if (errs.isNotEmpty) {
    return CapturePlan(
      params: p,
      frames: const <PlanFrame>[],
      rows: const <PlanRow>[],
      stats: null,
      checks: errs.map((m) => PlanCheck('fail', m)).toList(),
      timeSeconds: 0,
      errors: errs,
    );
  }

  final rc = math.min(p.hfovDeg, p.vfovDeg) / 2;
  final b = 90 - rc * (1 - p.overlapV);
  final half = b - p.vfovDeg / 2;
  final nR = half <= 0
      ? 1
      : (2 * half / (p.vfovDeg * (1 - p.overlapV)) - 1e-9).ceil() + 1;

  final pitches = <double>[];
  if (nR == 1) {
    pitches.add(0);
  } else {
    for (var i = 0; i < nR; i++) {
      pitches.add(-half + i * 2 * half / (nR - 1));
    }
  }

  final info = pitches
      .map(
        (q) => PlanRow(
          pitchDeg: _round2(q),
          longitudeWidthDeg: longitudeWidth(q, p.hfovDeg, p.vfovDeg),
        ),
      )
      .toList();

  for (final r in info) {
    r.need = math.max(
      1,
      (360 / (r.longitudeWidthDeg * (1 - p.overlapH)) - 1e-9).ceil(),
    );
  }

  final nU = info.map((r) => r.need).reduce(math.max);

  for (final r in info) {
    r.count = p.pattern == 'uniform' ? nU : r.need;
    r.spacingDeg = 360 / r.count;
    r.overlap = r.count == 1
        ? 1
        : math.max(
            0,
            (r.longitudeWidthDeg - r.spacingDeg) / r.longitudeWidthDeg,
          );
  }

  // Nearest ring to the horizon first, so the user shoots outward from the
  // easiest targets. Ties go to the higher pitch.
  final order = List<PlanRow>.from(info)
    ..sort((a, c) {
      final byAbs = a.pitchDeg.abs().compareTo(c.pitchDeg.abs());
      return byAbs != 0 ? byAbs : c.pitchDeg.compareTo(a.pitchDeg);
    });

  var frames = <PlanFrame>[];
  for (var ri = 0; ri < order.length; ri++) {
    final r = order[ri];
    for (var k = 0; k < r.count; k++) {
      frames.add(
        PlanFrame(
          yawDeg: _round2(wrapDeg(p.yaw0Deg + k * r.spacingDeg)),
          pitchDeg: r.pitchDeg,
          hfovDeg: p.hfovDeg,
          vfovDeg: p.vfovDeg,
          row: ri,
        ),
      );
    }
  }

  frames.add(
    PlanFrame(
      yawDeg: p.yaw0Deg,
      pitchDeg: 90,
      hfovDeg: p.hfovDeg,
      vfovDeg: p.vfovDeg,
      isPole: true,
      isZenith: true,
    ),
  );
  frames.add(
    PlanFrame(
      yawDeg: p.yaw0Deg,
      pitchDeg: -90,
      hfovDeg: p.hfovDeg,
      vfovDeg: p.vfovDeg,
      isPole: true,
      isNadir: true,
    ),
  );

  final base = frames.length;
  var repairs = 0;
  if (p.repair) {
    final add = fillGaps(frames, s, p.hfovDeg, p.vfovDeg);
    repairs = add.length;
    frames = frames.toList()..addAll(add);
  }

  for (var i = 0; i < frames.length; i++) {
    frames[i].index = i;
  }

  final stats = coverageStats(frames, s);
  final poles = frames.where((f) => f.isPole).length;
  final time = estimateTimeSeconds(frames, p);
  final minOv = info
      .where((r) => r.count > 1)
      .map((r) => r.overlap)
      .fold<double>(1, math.min);

  stats
    ..rows = info.length
    ..repairs = repairs
    ..baseFrames = base
    ..poleFrames = poles
    ..minOverlap = minOv
    ..timeSeconds = time;

  // ── self-checks ─────────────────────────────────────────────────────────
  final checks = <PlanCheck>[];
  void ck(String lv, String msg) => checks.add(PlanCheck(lv, msg));

  ck('ok', 'FOV and overlap inputs are valid');

  final spacingOk = info.every(
    (r) => r.spacingDeg <= r.longitudeWidthDeg * (1 - p.overlapH) + 0.01,
  );
  ck(
    spacingOk ? 'ok' : 'fail',
    spacingOk
        ? 'Angle spacing is consistent with the requested overlap'
        : 'A row spacing is wider than the requested overlap allows',
  );

  ck(
    stats.uncoveredPct <= 0.001 ? 'ok' : 'fail',
    stats.uncoveredPct <= 0.001
        ? 'No uncovered spherical regions (numerical estimate)'
        : 'Uncovered regions: ${stats.uncoveredPct.toStringAsFixed(2)}% of the sphere',
  );

  final qm = qualityMinOverlap[p.quality] ?? 0.25;
  ck(
    minOv >= qm ? 'ok' : 'fail',
    minOv >= qm
        ? 'Minimum row overlap ${(minOv * 100).toStringAsFixed(0)}% meets the '
              '${p.quality} target'
        : 'Minimum row overlap ${(minOv * 100).toStringAsFixed(0)}% is below the '
              '${p.quality} target of ${(qm * 100).toStringAsFixed(0)}%',
  );

  if (minOv < p.overlapH * 0.8) {
    ck('warn', 'Actual overlap is much lower than requested');
  }

  var dup = 0;
  for (var a = 0; a < frames.length; a++) {
    for (var b2 = a + 1; b2 < frames.length; b2++) {
      if (geodesicAngleDeg(
            (yawDeg: frames[a].yawDeg, pitchDeg: frames[a].pitchDeg),
            (yawDeg: frames[b2].yawDeg, pitchDeg: frames[b2].pitchDeg),
          ) <
          1) {
        dup++;
      }
    }
  }
  ck(
    dup > 0 ? 'warn' : 'ok',
    dup > 0
        ? '$dup duplicate targets (closer than 1 degree)'
        : 'No duplicate targets',
  );

  final total = cover(frames, s);
  var unnecessary = 0;
  for (final f in frames) {
    final c = cover(<PlanFrame>[f], s).counts;
    var needed = false;
    for (var i = 0; i < s.n; i++) {
      if (c[i] > 0 && total.counts[i] < 2) {
        needed = true;
        break;
      }
    }
    if (!needed) unnecessary++;
  }
  ck(
    unnecessary > 0 ? 'warn' : 'ok',
    unnecessary > 0
        ? '$unnecessary frames add no unique coverage. They exist to meet the '
              'overlap target; fewer frames need a lower overlap.'
        : 'Every frame adds unique coverage',
  );

  final sum = info.fold<int>(0, (acc, r) => acc + r.count) + poles + repairs;
  ck(
    sum == frames.length && stats.frames == frames.length ? 'ok' : 'fail',
    'Frame count is consistent: '
    '${info.map((r) => r.count).join('+')} + $poles poles + $repairs repair '
    '= ${frames.length}',
  );

  if (p.budgetMinutes > 0) {
    ck(
      time / 60 <= p.budgetMinutes ? 'ok' : 'fail',
      'Estimated time ${(time / 60).toStringAsFixed(1)} min vs budget '
      '${p.budgetMinutes.toStringAsFixed(0)} min',
    );
  }

  return CapturePlan(
    params: p,
    frames: frames,
    rows: order,
    stats: stats,
    checks: checks,
    timeSeconds: time,
    errors: const <String>[],
  );
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
