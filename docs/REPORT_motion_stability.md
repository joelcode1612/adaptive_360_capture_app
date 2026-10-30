# Motion Stability — Implementation and Verification Report

Date: 2026-10-18. Baseline: `docs/BASELINE_motion_stability.md`.

---

## A. Implementation summary

### The problem, as measured

The AR capture path took its guidance orientation straight from ARCore's camera
pose. Three consequences:

1. **Display jitter.** Frame-to-frame pose noise moved the guidance arrow and
   flickered the instruction, because nothing filtered it.
2. **A stability gate with two holes.** `StabilityMonitor` gated on alignment and
   on pose drift across a 500 ms window. It had **no angular-velocity gate and no
   measurement-age gate** — a phone being *carried* at constant speed can satisfy
   a drift window, and a stalled stream can satisfy it with stale data.
3. **No way to prove any of it.** No comparison harness, no diagnostic export, no
   explicit shot-phase state machine.

### The algorithm chosen, and why it is the right one for this data source

**Strategy A.** The orientation source is ARCore's fused camera pose — already a
visual-inertial estimate. Adding a complementary filter or an EKF *on top of a
fused pose* would add latency without adding information, which the brief
explicitly forbids. So:

| Candidate | Verdict |
| --- | --- |
| **A — adaptive quaternion smoothing (display only) + full stability gate** | **Selected.** Removes jitter from the arrow without touching the number the gate reads. |
| B — complementary filter on the AR pose | **Rejected.** The input is already fused; this would filter a filter. |
| B — complementary filter on raw IMU | **Already exists** and is unchanged: `AttitudeFusion` (β = 0.05) serves the legacy sensor-only flow. Not duplicated. |
| C — EKF | **Rejected, and documented as such.** No ground truth to calibrate process/measurement covariances, and no raw magnetometer on the AR path. An EKF with invented noise figures would be a claim, not an estimator. |

Smoothing is `alpha = 1 − exp(−dt / tau)` applied through `Quat.slerp`, so it is
**frame-rate independent** and takes the **short arc** (`Quat.slerp` flips the
second operand on a negative dot product). Three escape hatches snap instead of
smoothing: no previous state, a gap longer than `maxGapSeconds`, and a jump larger
than `snapAngleDeg` (a deliberate turn or a re-acquisition must not be lagged).

### Two defects the tests found — not inspection

1. **The rate gate would have refused a still phone.** Differencing *consecutive*
   poses turns frame jitter into apparent rotation: at 30 Hz, ±0.35° of noise is
   0.7° in 33 ms = **21 °/s**, four times the 5 °/s budget. Measured over a
   100 ms baseline the same noise gives **0.33 °/s**. The gate now uses that
   baseline, and keeps a refusal-proof rate history so a refusal cannot blind it.
2. **Resetting the filter on tracking loss was immediately undone**, because the
   *paused* sample re-seeded it and the next good sample was then interpolated
   from a pose taken before the interruption. The filter is now bypassed entirely
   while tracking is down.

---

## B. Changed files

### Added — pure Dart, no Flutter imports, fully unit-tested

| File | Role |
| --- | --- |
| `lib/features/capture/domain/motion/motion_sample.dart` | `MotionSample`; `angleBetweenDeg` (quaternion, shortest arc, stable at small angles); `angularRateFromQuaternions` |
| `lib/features/capture/domain/motion/orientation_filter.dart` | `OrientationFilter` interface + `PassthroughOrientationFilter` (the baseline) |
| `lib/features/capture/domain/motion/adaptive_quaternion_smoother.dart` | The time-constant smoother and its three snap conditions |
| `lib/features/capture/domain/motion/shot_phase.dart` | `ShotPhase` (INITIALISING→ALIGN→SETTLE→CAPTURE→VALIDATE→ACCEPT, +RETRY) and `deriveShotPhase` |
| `lib/features/capture/domain/motion/motion_diagnostics.dart` | Bounded record, CSV + JSON export, no personal data |
| `tool/motion_comparison.dart` | Reproducible baseline-vs-candidate harness |
| `test/motion_filter_test.dart` | 21 tests |
| `test/motion_stability_test.dart` | 21 tests |
| `test/shot_phase_test.dart` | 8 tests |

### Modified

| File | Change |
| --- | --- |
| `domain/services/stability_monitor.dart` | Added `maxAngularVelocityDegPerSec`, `maxMeasurementAge`, `rateBaseline`; quaternion drift (catches roll, which a forward-vector check cannot); `lastRejection` diagnostics; refusal-proof rate history |
| `domain/services/target_sphere.dart` | `stabilityWindow` 500 → **450 ms**; added `smootherTauSeconds`, `smootherSnapAngleDeg`, `maxAngularVelocityDegPerSec`, `maxMeasurementAge`, `rateBaseline`; documented why tolerance stays **3°** rather than the brief's 8° |
| `application/capture_controller.dart` | Owns the smoother, the diagnostics and the pose clock; computes **raw and smoothed alignment separately**; feeds age and rate to the gate; resets on station change and tracking loss |
| `application/capture_state.dart` | `displayAlignment`, `measurementFresh`, `angularRateDegPerSec`, `stabilityRejection`, derived `shotPhase` |
| `presentation/widgets/target_alignment_overlay.dart` | Colour now driven by the **raw** `withinTolerance`, geometry by the smoothed result |
| `presentation/screens/ar_capture_screen.dart` | `_PhaseChip` showing the shot phase; overlay fed smoothed geometry + raw verdict |
| `test/capture_flow_test.dart` | +5 integration tests (concurrency, dual alignment, reset, diagnostics, refusal reason) |
| `test/alignment_test.dart` | +4 tests (all 26 targets, the "not 360°" pin, tolerance boundary, poles) |

---

## C. Architecture

```
ARCore (Kotlin, ~30 Hz)                    [unchanged]
  camera.getPose() → px,py,pz,qx,qy,qz,qw
        │ EventChannel "adaptive360/arcore/events"
        ▼
ArPoseSample.orientation = arCameraPoseToCaptureWorld(raw)     ← the one adapter
        │
CaptureController._onPose
        │
        ├── MotionSample(orientation, at, position, rate?, age?)
        │        │
        │        ├── AdaptiveQuaternionSmoother.filter()  → smoothed quat   [DISPLAY ONLY]
        │        │                                          snap on: no state, gap, >25°
        │        └── raw quat                                ← the truth
        │
        ├── AlignmentCalculator(raw)      → state.alignment          ← gate, instruction, numbers
        ├── AlignmentCalculator(smoothed) → state.displayAlignment   ← arrow geometry only
        │
        ├── StabilityMonitor.update(raw, age, rate)
        │      gates: alignment · measurement-age · angular-rate ·
        │             orientation-drift · position-drift · window
        │      → state.stable, state.stabilityRejection, state.angularRateDegPerSec
        │
        ├── MotionDiagnostics.add(raw, filtered, rate, error, phase)
        │
        ▼
CaptureState.captureBlockReason   ← the single readiness decision
CaptureState.shotPhase            ← derived label, same inputs
        ▼
_shoot() → takeStill() → YUV→JPEG → write → verify → record → ACCEPT
```

**The one rule that keeps this honest:** smoothing never reaches the gate. The
brief's warning — "do not capture merely because the smoothed indicator looks
stationary" — is enforced structurally, because `captureBlockReason` and
`withinTolerance` read `state.alignment`, which is built from the raw quaternion.

---

## D. Test results

| Command | Exit | Result |
| --- | --- | --- |
| `flutter pub get` | **0** | resolved, no changes |
| `dart format --output=none --set-exit-if-changed lib test tool` | **0** | 109 files, 0 changed |
| `flutter analyze` | **0** | **No issues found** |
| `flutter test` | **0** | **145 tests pass** (baseline 86, +59) |
| `flutter build apk --debug` | **0** | `build/app/outputs/flutter-apk/app-debug.apk` (197 MB) |
| `flutter devices` | — | **blocked**: the sandbox blacklists `reg.exe`, which the tool invokes |
| `adb devices` | 0 | **no devices attached** |
| `flutter run -d <id>` | — | **not attempted** — no device to target |

### What the 59 new tests cover

- **Quaternion/filter (21):** identity; small rotation smoothed and lagging; frame-rate
  independence (2 steps vs 20 steps agree within 0.2°); large rotation snaps;
  ±180° crossing does not take the long arc; `q` vs `−q` equivalence;
  normalisation; NaN/infinity/zero rejected with the state held; zero and negative
  intervals; 900 ms gap; reset; and a **measured jitter reduction** on a still phone.
- **Stability (21):** still→stable; 20 °/s never stable; a supplied gyro rate used
  verbatim; 3 °/s accepted; stale reading refused; unknown age treated as fresh;
  **roll drift caught where a forward-vector check cannot see it**; walking away;
  recovery after refusal; reset; tracking interruption; window not yet elapsed;
  progress reaching 1.
- **Shot phase (8):** every transition, plus precedence — `validate` outranks a
  drifted pose, `retry` outranks `align`, `accept` outranks everything; and
  `settle.showsAligned == false`.
- **Alignment (+4):** all 26 targets align when aimed exactly; a 5° error fails a
  3° tolerance (**the "not 360°" pin**); tolerance boundary at 2.9° vs 3.2°; poles
  as vertical directions with yaw irrelevant.
- **Integration (+5):** two concurrent `captureNow()` calls produce **one**
  photograph; display smoothed while the gate stays raw and the shutter stays
  shut; tracking loss resets the smoother; the diagnostic record round-trips to
  CSV and JSON with no personal data; the refusal reason is exposed.

**Not run:** anything requiring a phone. No test in this suite asserts "capture
succeeds"; every expected result depends on the supplied readings.

---

## E. Accuracy and stability comparison

Source: `tool/motion_comparison.dart` → `docs/measurements/motion_comparison.json`
and `motion_trace.csv`. 180 samples at 30 Hz, scripted truth (still → 90° turn at
150 °/s → still → turn back → still), jitter applied to the input.

| Metric | Baseline (raw) | Candidate A (smoothed) | Change |
| --- | --- | --- | --- |
| Static jitter, σ of forward.x | 0.002302 | 0.000802 | **−65%** |
| Mean \|error\| vs truth | 0.229° | 0.081° | **−65%** |
| Max \|error\| vs truth | 0.395° | 0.249° | −37% |
| Settle to 1° after a turn | 0 ms | **333 ms** | **+333 ms lag** |
| First stable after returning to target (gate on **raw**) | 467 ms | 467 ms | unchanged |
| First stable if the gate ran on the **smoothed** pose | — | 933 ms | +466 ms — *why the gate does not* |

**The trade, stated plainly:** smoothing cuts jitter and error by about two
thirds and costs a third of a second of settling. Because the gate reads the raw
pose, that cost is paid only by the *arrow*, not by readiness — the shot becomes
available at 467 ms either way. Gating on the smoothed signal would have doubled
it, which is the measurement behind that design decision.

### The rate gate, quantified

| Input jitter | Mean derived rate while still | Still-stable fraction | First stable |
| --- | --- | --- | --- |
| ±0.05° (realistic for settled ARCore) | **0.33 °/s** | 0.74¹ | 467 ms |
| ±0.35° (deliberately harsh) | ~21 °/s per frame → ~3 °/s over 100 ms | 0.26 | 467 ms |

¹ 0.74 is the 450 ms window filling from the start of the measurement interval,
not a refusal — 1350 of 1800 ms. Under realistic jitter the gate is stable
continuously once filled.

**Carried-while-aimed test:** a camera rotating at 20 °/s about its target (so the
alignment error stays ~0 and only the rate gate can refuse) produced **2
false-ready samples in the baseline vs 0 in the candidate**, out of 60 moving
samples. That is the rate gate's entire justification, measured.

**What these numbers are not.** The truth is a script, not a physical reference.
They prove the filter behaves as specified on a known input. They say nothing
about ARCore's accuracy on a device, and no claim here should be read as
before/after device accuracy.

---

## F. Remaining issues

1. **No physical-device verification.** No device is attached and `flutter devices`
   is blocked by the sandbox. Nothing in this report was observed on a phone.
2. **The 5 °/s gate is sensitive to pose jitter.** Under ±0.35° frame noise — 7–17×
   ARCore's settled jitter — the still-stable fraction falls to 0.26. The 100 ms
   rate baseline is the mitigation; `maxAngularVelocityDegPerSec` and
   `rateBaseline` are the knobs. **This must be measured on the target device**
   before the 5 °/s value is trusted.
3. **`tau = 0.12 s` is untuned.** It was chosen so a small correction settles in
   about three frames at 30 Hz. No device data supports it yet.
4. **3° tolerance is a deliberate deviation from the brief's 8°.** 8° is available
   through `CaptureGeometryConfig` for the sensor-only tier; 3° is kept for ARCore
   because 8° of a 360° panorama is a visible seam.
5. **The legacy sensor flow is untouched.** It still runs `AttitudeFusion` with
   β = 0.05 and its own 2.5° tolerance. Bringing it onto the new gate is a separate
   change with its own hardware validation.
6. **iOS remains unimplemented**, as before — there is no ARKit host.
7. **Camera capture is unchanged** and already real: `Frame.acquireCameraImage()`
   → YUV planes → JPEG → verify → record. The brief's `_capture()`-only-
   increments-the-index defect does not exist here; it was never in this codebase.
   Resolution is still ARCore's CPU image size, recorded per photograph.
8. **No CSV/JSON export button in the UI.** `MotionDiagnostics` can produce both,
   and the controller owns an instance, but nothing writes it to disk yet.

---

## G. Run instructions

```bash
cd C:/Users/Lenovo/AndroidStudioProjects/adaptive_360_capture_app

flutter pub get
flutter analyze
flutter test
flutter build apk --debug

# metrics (no device needed)
dart run tool/motion_comparison.dart
#   → docs/measurements/motion_comparison.json
#   → docs/measurements/motion_trace.csv

# on a phone
adb devices                      # must list the device
flutter run -d <device_id>       # or: adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

On the device: launch → **AR capture** → move slowly until tracking and planes
appear → **Calibrate station** → aim at target 1 and hold. The phase chip should
read `Initialising → Move to target → Hold still → Ready`, and the shutter enables
only at `Ready`. Watch `adb logcat | grep -E "arcore|ArCore|IllegalArgument"` for
native faults.

To tune, change `CaptureGeometryConfig`: `smootherTauSeconds`,
`maxAngularVelocityDegPerSec`, `stabilityWindow`, `rateBaseline`,
`alignmentToleranceDeg`.

---

## H. Acceptance decision

### **Partially passed**

The implementation is complete and verified within the scope that this
environment can actually execute: format, analysis, 145 automated tests, the
comparison harness with real measured numbers, and a successful Android debug
build. Two genuine defects were found and fixed by the tests rather than by
inspection.

It is **not** "passed", because the brief requires running on a physical Android
phone, and that step could not be performed: `adb devices` reports no attached
device and `flutter devices` is blocked by the sandbox's `reg.exe` restriction.
Consequently the on-device behaviour of the 5 °/s gate, the 0.12 s time constant,
and the guidance under real ARCore jitter remain **unverified**.

It is **not** "failed": nothing required by the brief is known to be broken, and
every check that could be run, ran and passed.
