# Research — `webcammictest.com/sensors/` methodology

**Scope A + B**: what the page claims, and what its JavaScript actually does.
**No existing code was modified.** This document is the only artefact.

Source examined: `https://webcammictest.com/sensors/` (Next.js/Turbopack build) and
its sensor chunk `/_next/static/chunks/ff2cad39b406c13f.js` (47,634 bytes), which
contains all sensor logic. Everything below marked *verbatim* is copied from that
chunk; everything marked *inferred* is my reading of it.

---

## 1. Why it feels accurate — the short answer

Three properties, none of which is a clever filter:

1. **It never filters attitude.** Pitch, roll and tilt are computed directly from
   the accelerometer on every sample. Gravity is an absolute reference, so those
   angles cannot drift. A bubble level built this way is genuinely accurate —
   unlike an integrated gyro, which is accurate for a second and then wanders.
2. **The two-position calibration removes the device's own offset** from the
   surface tilt with a least-squares solve, instead of trusting one reading.
3. **Heading comes from the operating system's compass**, not from its own
   integration. The magnetometer fusion is done by iOS/Android, and the page just
   reads the result.

What looks like "a very accurate sensor" is therefore mostly *the platform's own
fusion*, plus the page's refusal to smooth anything and its refusal to claim a
sensor before a real value arrives.

---

## 2. Sensor stack and sampling

*Verbatim* — the constructors it probes, in order:

```js
["Accelerometer","LinearAccelerationSensor","GravitySensor","Gyroscope",
 "Magnetometer","AbsoluteOrientationSensor","RelativeOrientationSensor",
 "AmbientLightSensor"]
```

*Verbatim* — construction, and the event fallback:

```js
b = (e, t) => { let s = x(e); if (!s) return null;
                try { return new s({ frequency: t }) } catch { return null } }
```

```js
({ frequency: e = 60, onSample: t, onKind: s }) => { … }
```

So: **Generic Sensor API first at 60 Hz**, falling back to `devicemotion` /
`deviceorientation` events. The chosen path is reported to the UI as
`"sensor"` or `"event"`, and the measured rate is displayed:

```js
n >= 1e3 && (s.value = 1e3 * s.count / n, s.count = 0, s.since = e.t)
```

`rate` is therefore **measured, not assumed** — a 60 Hz request that delivers
18 Hz shows 18.

*Verbatim* — the axis remap from `devicemotion`:

```js
rotation: s && (s.alpha !== null || s.beta !== null || s.gamma !== null)
  ? { x: s.beta ?? 0, y: s.gamma ?? 0, z: s.alpha ?? 0 } : null
```

`beta → x`, `gamma → y`, `alpha → z`, converted to °/s by `f(o, g)` with
`g = 180 / Math.PI`.

---

## 3. Support detection and permission

*Verbatim* — the permission model:

```js
needsPermission: typeof p()?.requestPermission === "function"
```

```js
if (!s.motionEvent && !s.orientationEvent) return void n("unsupported");
if (!s.needsPermission) return void n("granted");

let a = !1,
    r = () => { a || (a = !0, removeListeners(), clearTimeout(i), n("granted")) },
    i = setTimeout(() => { a || (a = !0, removeListeners(), n("prompt")) }, 700);
addEventListener("devicemotion", r); addEventListener("deviceorientation", r);
```

The 700 ms probe is the notable trick: rather than prompting immediately, it
listens first. If an event arrives unaided, permission is already granted; if
nothing arrives in 700 ms, it shows the tap-to-request button. On Android — where
no permission is needed — the user is never shown a button they do not need.

*Verbatim* — support is only asserted on real values:

```js
(e.alpha !== null || e.beta !== null || e.gamma !== null) && (i.orientation = !0)
```

which implements the prose claim that a desktop "fills them with nulls" and must
not be reported as supported.

*Verbatim* — the absolute/relative merge, to stop the compass flapping:

```js
r?.absolute && !n
  ? o.current = { ...a, alpha: r.alpha, absolute: !0,
                  compassHeading: r.compassHeading,
                  compassAccuracy: r.compassAccuracy }
  : o.current = a
```

Once an absolute source has been seen, a later relative event **keeps the old
alpha and stays marked absolute**. That prevents the heading from jumping when
the browser switches sources mid-session.

---

## 4. Attitude — gravity only, no fusion

*Verbatim*:

```js
E = (e, t = 1) => {
  let s = w(e);                                  // |a|
  if (!Number.isFinite(s) || s < .5) return null; // no gravity → no attitude
  let n = { x: t*e.x/s, y: t*e.y/s, z: t*e.z/s }; // unit "up"
  return { up: n,
           pitch: Math.asin(k(n.y, -1, 1)) * y,   // y = 180/π
           roll:  Math.asin(k(n.x, -1, 1)) * y,
           tilt:  Math.acos(k(n.z, -1, 1)) * y,
           magnitude: s };
};
```

Points worth noting:

- **Rejection threshold `|a| < 0.5 m/s²`** — free-fall or a dead sensor yields
  `null` attitude rather than nonsense.
- `pitch = asin(up.y)`, `roll = asin(up.x)`, `tilt = acos(up.z)`. All three come
  from the *same* normalised vector, so they are mutually consistent by
  construction.
- **There is no gyroscope integration anywhere in the attitude path.** The only
  integration in the whole chunk is the turn-angle accumulator for the
  calibration test (§6). Yaw is not estimated from motion at all.

*Verbatim* — automatic sign calibration, because browsers disagree about which way
gravity points:

```js
(e, t) => {
  if (t === null || !Number.isFinite(t)) return null;
  let s = Math.sin(t * Math.PI / 180);
  if (.34 > Math.abs(s)) return null;          // |beta| too near 0/180 → ambiguous
  let n = w(e); if (n < .5) return null;
  let a = e.y / n;
  if (.25 > Math.abs(a)) return null;          // |up.y| too small → ambiguous
  return Math.sign(a) === Math.sign(s) ? 1 : -1;
}
```

It compares the sign of the normalised `y` component with `sin(beta)` and latches
the result once. This resolves the "is `+Y` up or down" ambiguity between
platforms without a settings toggle — a genuinely good idea, and cheap.

---

## 5. Heading

*Verbatim*:

```js
heading = compassHeading !== null && Number.isFinite(compassHeading)
            ? S(compassHeading)
            : (absolute && alpha !== null && Number.isFinite(alpha))
                ? S(360 - alpha)
                : null;
```

with `S = e => (e % 360 + 360) % 360`.

Priority: **iOS `webkitCompassHeading`** (already a true heading, and it carries
`webkitCompassAccuracy`), otherwise `360 − alpha` when the source is absolute.
The `360 − alpha` conversion is the standard one: `alpha` increases
counter-clockwise from north, heading increases clockwise.

For the sweep test the heading is **unwrapped** — accumulated wrapped deltas —
so a full turn can be measured without the ±180° discontinuity:

```js
let [n, a] = useState({ last: null, unwrapped: 0 });
… unwrapped: last === null ? e : n.unwrapped + wrapDelta(e - last)
```

Coverage is counted in **16 sectors of 22.5°**. *Verbatim*:

```js
let [t, s] = useState(() => Array(16).fill(false));
let t = Math.round(S(e) / 22.5) % 16;      // sector index for this heading
s(e => { if (e[t]) return e; let s = [...e]; s[t] = !0; return s });
let r = t.filter(Boolean).length;          // distinct sectors visited
```

and the verdict flips to "complete" at `a.count >= 16`. That is what makes "a
heading that jumps rather than sweeping" detectable: a jumping heading leaves
sectors unvisited, so the count stalls below 16 even though the compass reads
every angle.

*Verbatim* — iOS reports a negative accuracy when the compass is uncalibrated, and
the page treats that as a hard failure rather than a number:

```js
let u = o?.compassAccuracy ?? null, d = null !== u && u < 0;
… d ? tone:"bad"   // "uncalibrated" verdict
    : c ? tone:"good"  // 16 sectors covered
    :     tone:"idle"  // still sweeping
```

---

## 6. Two-position accelerometer calibration

Phases: `idle → first → turn → second → done`. Hold still, turn the device end for
end, hold still again. *Verbatim* — the turn requirement:

```js
Math.abs(e) >= 160 && (i(0), a("second"))      // ≥160° of integrated rotation
```

with `R = 180` as the progress-bar maximum. The integrated angle is
`e += rotation.z * ((t - s) / 1e3)` — the only gyro integration in the chunk.

*Verbatim* — the solve, which separates surface tilt from device offset:

```js
let r = Math.cos(a*I), i = Math.sin(a*I),      // a = turn angle, I = π/180
    l = e.pitch - t.pitch, o = e.roll - t.roll, // second − first
    c = 2*(1 - r),
    u = ((1 - r)*o + i*l) / c,                 // surfaceRoll
    d = (-i*o + (1 - r)*l) / c,                // surfacePitch
    m = e.pitch - d, x = e.roll - u;           // offsetPitch, offsetRoll
return { offsetPitch: m, offsetRoll: x,
         surfacePitch: d, surfaceRoll: u,
         offset:  Math.hypot(m, x),
         surface: Math.hypot(d, u),
         turn: a };
```

This is the part that makes the level result trustworthy. A single reading cannot
distinguish "the table is tilted" from "the sensor is offset"; two readings 180°
apart can, because the offset stays fixed in the device frame while the surface
tilt flips sign. The 2×2 solve above is the closed form of that.

*Verbatim* — verdict thresholds, applied to `offset` in degrees:

```js
P = e => e <= .3 ? "accurate" : e <= 1 ? "slight" : e <= 2.5 ? "off" : "bad"
```

And "flat" is `tilt <= 0.5°`.

---

## 7. Drift at rest — 20 s, with disturbance gating

*Verbatim* — the window and the two disturbance gates:

```js
if (w(t.rotation) > 4) e.disturbed = true;                 // > 4 °/s
if (Math.abs(n - 9.80665) > .6) e.disturbed = true;        // |a| off by > 0.6 m/s²
```

```js
i(Math.min(1, t / 2e4));
if (t >= 2e4) { … }
```

So: **20 s (2 × 10⁴ ms)**, and the run is flagged disturbed if the phone rotates
faster than 4 °/s or the acceleration magnitude deviates from standard gravity by
more than 0.6 m/s². That second gate is far tighter than the 14 m/s² shake
threshold used in the live panel — deliberately, because a drift measurement is
worthless if the phone moved at all.

*Verbatim* — the statistics, computed as population mean and standard deviation
per axis:

```js
mean = sum / count
deviation[axis] = Math.sqrt(Math.max(0, sumSquares/count - mean²))
bias = meanAccel - 9.80665
tiltRange = Math.hypot(maxPitch - minPitch, maxRoll - minRoll)
```

Reporting per-axis σ rather than a single "drift" number is the right choice: it
tells you *which* axis is noisy.

### The acceptance table

This is the part most worth reusing — *verbatim*, and the closest thing the page
has to a published spec:

```js
gyroVerdict: c <= .1 ? "steady" : c <= .5 ? "slight" : c <= 2 ? "noticeable" : "severe"

accelVerdict: (x = Math.abs(gravityError)) <= .06 && gravityNoise <= .05 ? "steady"
            : x <= .2  && gravityNoise <= .15 ? "slight"
            : x <= .6  && gravityNoise <= .5  ? "noticeable"
            :                                    "severe"
```

with `c = biasMagnitude` (the magnitude of the mean rotation vector, in °/s) and
`gravityError = mean|a| − 9.80665` in m/s².

In words:

| Verdict | Gyro bias | Gravity error | Gravity noise |
| --- | --- | --- | --- |
| steady | ≤ 0.1 °/s | ≤ 0.06 m/s² | ≤ 0.05 m/s² |
| slight | ≤ 0.5 °/s | ≤ 0.20 m/s² | ≤ 0.15 m/s² |
| noticeable | ≤ 2.0 °/s | ≤ 0.60 m/s² | ≤ 0.50 m/s² |
| severe | > 2.0 °/s | > 0.60 m/s² | > 0.50 m/s² |

A phone that reaches "steady" has a gyro bias under 0.1 °/s, i.e. **6 °/min** —
which is why the page's numbers look credible: it is measuring the right quantity
and holding it to a defensible bound. The full result object also carries
`count`, `seconds`, `bias` (per axis), `noise` (per axis), `gravity`,
`tiltWander` (`hypot(pitchRange, rollRange)`), and `disturbed`.

---

## 8. Live shake / peak metrics

*Verbatim*:

```js
(linear ? w(linear) : Math.abs(t - 9.80665)) > 14
  && t - z.current > 400 && (z.current = t, k.current++)   // shakes++
peakG = peakAccel / 9.80665
```

14 m/s² ≈ 1.43 g above gravity, debounced to at most one count per 400 ms, and
peak G expressed in g.

---

## 9. What it does not do

Stated plainly, because "accurate" has a boundary:

| Not present | Consequence |
| --- | --- |
| Gyro fusion for attitude | pitch/roll are instantaneous and **noisy under motion** (no smoothing at all), though they never drift |
| Any yaw estimate from motion | yaw exists only as the platform compass; tilt-compensated heading is not computed |
| Magnetometer access beyond the heading | no hard/soft-iron handling of its own |
| Position, planes, anchors | none — it is a sensor test, not tracking |
| Low-pass / Kalman filtering | every reading is raw; a shaky hand moves the bubble |

The absence of smoothing is why it feels *responsive* and *honest*: what you see
is the sensor, not a filter's opinion of it. It is also why it would be a poor
foundation for guidance, which needs continuity more than it needs rawness.

---

## 10. Comparison with this project

`lib/features/virtual_tour/platform/sensor_pose_source.dart` +
`domain/math/attitude_fusion.dart` (β = 0.05, error applied as
`atan2(|axis|, dot) · β` per step).

| | webcammictest | this app |
| --- | --- | --- |
| Attitude source | accelerometer only | accelerometer **+ gyro integration**, gravity-corrected |
| Filtering | none | complementary, β = 0.05 |
| Pitch / roll | absolute, drift-free, noisy | smoothed, lag on fast motion |
| Yaw | platform compass (`360 − alpha`) | integrated from gyro, **drifts** |
| Sample rate | 60 Hz requested, measured and shown | 20 ms (50 Hz) requested, throttled to 66 Hz max push |
| Rate honesty | displayed | `ArPose.timestampNs` |
| Failure detection | null payloads + 700 ms probe | 800 ms deadline per sensor |
| Sensor sign | auto-calibrated from `beta` | assumed from the Android sensor frame |
| Offset calibration | two-position solve | none |

**The key difference is yaw.** The page has no yaw from motion, so it cannot
drift — but it also cannot give continuous rotation between compass updates. The
app integrates the gyro, so its yaw is smooth but accumulates bias. That is the
correct trade for this application: every target direction is measured *relative*
to the heading locked at "Set Station Here", so continuity matters more than
absolute north.

---

## 11. Can it be used?

**As a library: no.** It is a Next.js diagnostic page. The sensor logic is
minified inside a hashed Turbopack chunk with no published API, no source map
guarantee, and chunk hashes that change on deploy. Nothing here is importable, and
embedding the page in the app would give you a web view that reports *different*
quantities from the app's own pipeline.

**As a reference: yes, and three ideas are worth taking.**

1. **Sensor-sign auto-calibration** (§4). The app assumes the Android sensor
   frame; the page derives the gravity sign from `beta` and latches it. This is
   the standard fix for the "bubble moves the wrong way" class of bug.
2. **Two-position offset calibration** (§6). The app has no equivalent. If the
   station heading ever looks biased, this is the method to distinguish device
   offset from a genuinely tilted surface.
3. **Disturbance gating for the steadiness check** (§7). The app's
   `StabilityMonitor` uses orientation and position drift over a 500 ms window;
   the page additionally gates on `|ω| > 4 °/s` and `||a| − g| > 0.6 m/s²`. Those
   two are cheap and would catch "the phone is being carried" earlier than a pose
   delta does.

**As a validation oracle: only for pitch, roll and heading.** Those are absolute
quantities on both sides, so agreement is meaningful. Comparing the app's yaw with
the page's compass would be comparing an integrated relative angle with an
absolute one — they should *not* agree, and a mismatch would not indicate a fault.

---

## 12. Caveats on this research

- The bundle is minified; identifier names (`E`, `P`, `R`, `S`, `w`) are mine to
  read, and I have quoted the expressions rather than paraphrased them.
- Thresholds are current as of this fetch and may change on the next deploy; the
  chunk hash `ff2cad39b406c13f` identifies exactly what was read.
- I did not execute the page on a device. Every claim above is from source, not
  from observed behaviour, so the *runtime* values (actual sample rate, whether
  Chrome Android picks the Generic Sensor path) are unverified.
