# Baseline — before any change

Recorded 2026-10-18, before modification.

## Toolchain

```
Flutter 3.44.6 • channel stable
Framework ee80f08bbf (2026-07-08)
Engine    d3a3293399 (2026-06-30)
Tools     Dart 3.12.2 • DevTools 2.57.0
```

## Dependencies (pubspec.yaml, unchanged)

```
camera ^0.12.1          sensors_plus ^7.1.1     wakelock_plus ^1.6.1
permission_handler ^12.0.3   path_provider ^2.1.6   path ^1.9.1
panorama_viewer ^2.0.7  cupertino_icons ^1.0.8
dependency_overrides: permission_handler_android ^13.0.1
```

**The brief's names do not all exist here.** `ar_flutter_plugin`,
`camerawesome`, `vector_math`, `PanoramaCaptureScreen`, `ARSessionManager`,
`getCameraPose()`, `CapturePoint`, `_pollCamera()`, `_guideCompass()` and
`_capture()` are absent. The real equivalents:

| Brief | Actual |
| --- | --- |
| `ar_flutter_plugin` + `getCameraPose()` | hand-written native ARCore host: `platform/arcore_ar.dart` (Dart) + `android/.../ar/*.kt` |
| `vector_math` quaternions | the project's own `domain/math/quaternions.dart` (`Quat`) |
| `CapturePoint` + 26 targets | `domain/services/target_sphere.dart` (`CaptureTargetSpec`, `buildCaptureSphere()`) |
| `_pollCamera()` | none — the AR path is **event-driven** (`EventChannel`), not polled |
| `_capture()` | `CaptureController._shoot()` → `PhotoCaptureService.capture()` |
| `_guideCompass()` | `AlignmentCalculator` + `TargetAlignmentOverlay` |

## The two capture paths

1. **AR module** (`features/capture/`) — guidance from the **ARCore camera pose**
   over an event stream. This is Strategy A in the brief.
2. **Legacy sensor flow** (`features/virtual_tour/`) — guidance from a
   **complementary filter over raw IMU** (`sensors_plus` → `AttitudeFusion`,
   β = 0.05). This is Strategy B, and it is already implemented.

Both are live; `main.dart` offers both.

## Data flow, as it actually is (AR path)

```
ARCore (Kotlin, 30 Hz)
  camera.getPose() → px,py,pz,qx,qy,qz,qw
        │  EventChannel "adaptive360/arcore/events"
        ▼
ArPoseSample.orientation  = arCameraPoseToCaptureWorld(raw)     ← one adapter
        │
CaptureController._onPose
        ├─ RigidPose(position, orientation)          ← RAW, unsmoothed
        ├─ AlignmentCalculator.compute(...)          ← gate uses this
        ├─ StabilityMonitor.update(...)              ← pose-drift window
        └─ state.alignment, state.stable, state.driftM
        ▼
CaptureState.readyToCapture  (= captureBlockReason == null)
        ▼
_shoot() → takeStill() → YUV→JPEG → write → verify → record
```

So the pose is **already fused by ARCore**. The brief's warning applies: no
second complementary/Kalman filter may be placed on top of it.

## The 360° yaw tolerance risk — not present

The brief warns that "some target configurations use a yaw tolerance of 360°".
Both paths were checked; neither has it:

- AR path: `AlignmentCalculator` gates on a **3-D geodesic angle**
  (`acos(forward·d)`), not a yaw difference.
- Legacy path: `capture_state_machine.dart:574,636` gates on
  `aimResult.angleDeg < thresholds.alignmentToleranceDeg` with
  `alignmentToleranceDeg = 2.5` (`decision_rules.dart:40`), where `aim()` is also
  a geodesic angle.

There is no per-axis yaw comparison to wrap, and no 360° tolerance anywhere.
This risk is therefore **already absent**; a test will pin it so it stays absent.

## Baseline results (before changes)

| Check | Result |
| --- | --- |
| `flutter analyze` | **No issues found** (21.7 s) |
| `flutter test` | **86 tests pass** (22 s) |
| `flutter build apk --debug` | built earlier in this session; re-run after changes |
| `flutter devices` | **blocked** — sandbox blacklists `reg.exe`, which the Flutter tool invokes |
| `adb devices` | **no devices attached** |

No pre-existing errors. The baseline is clean, which means every failure from here
is mine.

## Known weaknesses this work addresses

1. Guidance uses the **raw** ARCore pose, so the arrow/instruction inherits
   ARCore's frame-to-frame jitter. No display smoothing exists.
2. `StabilityMonitor` gates on pose drift and alignment only — **no angular
   velocity, no measurement age**. A phone being carried can satisfy a 500 ms
   drift window.
3. Stability window is 500 ms, not the 450 ms the brief specifies.
4. There is no comparison harness, no diagnostic export, and no explicit
   shot-phase state machine.
