# 360° capture pipeline — workflow verification & current source

**Purpose:** one document you can read end-to-end to verify what the app actually  
does from *Calibrate Station* through to *next target*, with the current source  
of every file in the chain.

**Status after the REQ-801–805 VIO sphere integration** (measured 2026-10-25)

| Gate                          | Result                                                                                      |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `flutter test`                | **+476 passed, 0 failures** (includes `test/vio_sphere_math_test.dart`: 57)                  |
| `flutter analyze`             | **No issues found!**                                                                        |
| `flutter build apk --debug`   | **Built** — `build/app/outputs/flutter-apk/app-debug.apk`                                    |
| `flutter build apk --release` | **Built** — `build/app/outputs/flutter-apk/app-release.apk`                                  |
| On-device verification        | **NOT DONE — no Android device has ever been attached** (`adb devices` empty every session)  |

> **Numbers superseded since this document was first written.** The body below
> was written for the earlier **26-target / 1.5 m / 450 ms** pipeline. The
> specification this app now implements — and the code now uses — is **30
> targets at 1.0 m, a 600 ms stability window, a 0.20 m station-drift gate,
> rings at ±35° and near-poles at ±85°**. The old figures have been corrected in
> place below. `lib/core/math/vio_sphere_math.dart` (`VioSphereConstants`) is the
> single authority for these numbers, `lib/features/capture/domain/services/target_sphere.dart`
> derives the 30 specs from them, and `test/vio_sphere_math_test.dart` asserts
> them. The stability window itself moved from `stability_monitor.dart` to
> `VioSphereEngine.evaluateFrame`; the old monitor is retained but no longer
> drives the capture shutter. The `file.dart:NNN` line references below predate
> the migration — treat them as pointers into the file, not exact lines.

> **Environment note (worth keeping):** `flutter test` fails in this sandbox with  
> `Unable to connect to flutter_tester process: WebSocketException: Invalid
> WebSocket upgrade request` because `http_proxy`/`https_proxy` point at  
> `127.0.0.1:52577` and the runner's localhost WebSocket goes through it. Run it  
> as  
> `HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flutter test`  
> and it passes. This is a sandbox artefact, not a project defect.

There are **no screenshots in this document** because there is no device to take  
them on. Everything below is source + the numbers the source computes.

---


## 1. The workflow, as a flowchart

```
                    ┌──────────────────────────────────┐
                    │  AR session boots                │
                    │  phase: starting → scanning      │
                    │  "Move the phone slowly…"        │
                    └───────────────┬──────────────────┘
                                    │ TrackingState.tracking
                                    ▼
   ╔════════════════════════════════════════════════════════════════╗
   ║ 1. CALIBRATE STATION            capture_controller.dart:364    ║
   ║    pose must be TRACKING                                       ║
   ║    captureReferenceFromPose(forward, gravityUp = +Y)           ║
   ║        ├─ refuses within 10° of vertical  → message, no station ║
   ║        └─ up = world +Y  (gravity)                             ║
   ║           forward = camera forward projected on horizontal     ║
   ║           R·x̂ = up × forward  (so −R·x̂ = physical right)      ║
   ║    StationFrame(origin = pose.position, orientation = R)       ║
   ║    FROZEN. Never re-derived from a later camera pose.          ║
   ╚═══════════════════════════════┬════════════════════════════════╝
                                   │
                    ┌──────────────┴───────────────┐
                    ▼                              ▼
   ┌────────────────────────────┐   ┌────────────────────────────────┐
   │ 2a. PROBE (information)    │   │ 2b. PLACE ALL 30 TARGETS       │
   │ probeTargets()             │   │ plane_anchor_service.dart:153  │
   │ 30 raycasts, 8 m           │   │ for each spec:                  │
   │ "N directions have a       │   │   resolveTarget(station, spec,  │
   │  surface" — NEVER a gate   │   │                 radius = 1.0 m) │
   └────────────────────────────┘   │   worldPos = P0 + 1.0·d̂        │
                                    │   facing   = −d̂                │
                                    │   rotation = facingRotation(−d̂)│
                                    │   model    = buildModelMatrix(   │
                                    │                worldPos, P0)    │
                                    │   session.createAnchor(         │
                                    │     pos, Quat.identity,         │
                                    │     trackableKey: null)         │
                                    │ idempotent by targetId          │
                                    └───────────────┬────────────────┘
                                                    │
                    ┌───────────────────────────────┴──────────────┐
                    ▼                                              ▼
   ┌────────────────────────────────┐   ┌──────────────────────────────┐
   │ selectTarget(1)                │   │ pushScene(activeId, tint,    │
   │ controller.dart:672            │   │           doneTargets)       │
   │  • demote old active           │   │  • active/done → opacity 1   │
   │  • _engine.resetStability()    │   │  • others    → opacity 0.35  │
   │  • nothing placed/moved here   │   │  • bezel at −0.006 m on      │
   └───────────────┬────────────────┘   │    the plate's own +Z        │
                   │                    └──────────────────────────────┘
                   ▼
   ╔════════════════════════════════════════════════════════════════╗
   ║ 3. POSE LOOP — every AR frame      controller.dart:1194        ║
   ║                                                                ║
   ║  raw pose ──┬─→ alignment        (UNSMOOTHED → gate/instruction)║
   ║             ├─→ displayAlignment (SMOOTHED   → arrow only)      ║
   ║             └─→ driftM = |camPos − station.origin|              ║
   ║                                                                ║
   ║  alignment (alignment_calculator.dart:47)                      ║
   ║    D = targetWorldPos − camPos ;  d = normalize(D)              ║
   ║    dc = camera.orientation.toCameraFrame(d)                     ║
   ║    yawCorr   = atan2(dc.x, dc.z)              + → turn right   ║
   ║    pitchCorr = atan2(dc.y, √(x²+z²))          + → tilt up      ║
   ║    angularErrorDeg = acos(forward · d)         the 3-D error   ║
   ╚═══════════════════════════════┬════════════════════════════════╝
                                   │
              ┌────────────────────┴────────────────────┐
              ▼                                         ▼
   ┌──────────────────────────┐        ┌───────────────────────────────┐
   │ 4. ARROW GUIDANCE        │        │ 5. STABILITY GATE             │
   │ overlay:128              │        │ VioSphereEngine.evaluateFrame  │
   │  p = project(dc, w, h,   │        │  window      = 600 ms         │
   │       hfov, vfov)        │        │  age         ≤ 250 ms         │
   │  dir = p.pixel − centre  │        │  orient drift≤ 1.5°           │
   │  length = 30 +           │        │  pos drift   ≤ 0.03 m         │
   │   (err/90)·0.20·shortSide│        │  rate        ≤ 5 °/s          │
   │  clipped at screen edge  │        │  alignment   ≤ 3° + 2° hyst.  │
   │  hidden when inside      │        │  (hysteresis: window only,    │
   │  tolerance               │        │   shutter is strict 3°)       │
   │                          │        │                               │
   │ instruction text:        │        │                               │
   │  "Aim at the front       │        └───────────────┬───────────────┘
   │   target. Turn right 45°"│                        │
   └──────────────────────────┘                        │
                                                       ▼
   ╔════════════════════════════════════════════════════════════════╗
   ║ 6. SHOT PHASE (derived, never stored)   shot_phase.dart:75     ║
   ║  initialising → align → settle → capture → validate → accept   ║
   ║                     ↑        ↑         │                       ║
   ║                     └────────┴─────────┴── retry               ║
   ║  readyToCapture == (captureBlockReason == null)                ║
   ╚═══════════════════════════════┬════════════════════════════════╝
                                   │ manual press or autoCapture
                                   ▼
   ╔════════════════════════════════════════════════════════════════╗
   ║ 7. CAPTURE           photo_capture_service.dart:94             ║
   ║   takeStill   (6 s timeout)  → write (10 s)                    ║
   ║   → read-back verify (10 s)  → saveRecord (10 s)               ║
   ║   each stage logs: [capture] +Nms stage=…                      ║
   ╚═══════════════════════════════┬════════════════════════════════╝
                                   │
                                   ▼
   ╔════════════════════════════════════════════════════════════════╗
   ║ 8. ADVANCE                controller.dart:1050 (_shoot)         ║
   ║   target → captured; saveTargets + saveStation(count)          ║
   ║   pushScene(activeId, done tint, doneTargets + id)             ║
   ║   _nextPending(list, after: id)  ← POSITION based, not id+1    ║
   ║   selectTarget(next)                                            ║
   ║   all 30 done → phase = complete                               ║
   ╚════════════════════════════════════════════════════════════════╝
```

### The step sequence in words

1. **Calibrate.** The user stands where the panorama is to be taken from, holds  
   the phone roughly level, and presses *Calibrate station*. The app reads the  
   current ARCore camera pose, refuses if ARCore is not `TRACKING` or if the  
   camera points within **10°** of straight up/down, and otherwise builds a  
   **gravity-aligned** reference (`captureReferenceFromPose`): `up` = world  
   `+Y`, `forward` = the camera's optical axis **projected onto the horizontal  
   plane** (yaw kept, pitch and roll discarded). The result is stored as  
   `StationFrame(origin, orientation)` and is **frozen** — no later camera pose  
   ever replaces it.
2. **Generate targets.** `buildCaptureSphere()` produces 30 `CaptureTargetSpec`s  
   (station-local unit directions). Placement is **arithmetic, not raycast**:  
   `resolveTarget` gives `worldPosition = station.origin + 1.0 m × d̂`,  
   `facingNormal = −d̂`, `localRotation = facingRotation(facing)`, and
   `VioSphereEngine.buildModelMatrix(worldPosition, station.origin)` gives the
   4×4 model basis the renderer consumes. ARCore is asked for a **world-space
   anchor** (`trackableKey: null`) at that position. All 30 are created once and
   kept for the whole session; `placeAll` is idempotent by target id.
3. **Front first.** `selectTarget(_specs.first.targetId)` — id 1 is yaw 0 /  
   pitch 0, the direction the user was already facing when they pressed  
   Calibrate. Selection only moves the highlight; no node is created, moved or  
   released.
4. **Guide.** Every AR frame the controller computes the alignment from the  
   **raw** pose to the active target's **anchor world position**. The arrow's  
   angle is `atan2(−pitchCorrection, yawCorrection)`; its length grows with the  
   3-D error; it is hidden once the error is inside 3°. The sentence is  
   `Aim at <target name>. Turn right 45°` (poles: the 3-D error only — "turn  
   right" is meaningless at the zenith).
5. **Settle.** The stability window requires 600 ms of continuous holding with  
   age ≤ 250 ms, orientation drift ≤ 1.5°, position drift ≤ 3 cm, angular rate  
   ≤ 5 °/s, a sample gap ≤ 150 ms, and alignment inside 3° **+ 2° hysteresis**.  
   The hysteresis applies to the *window only*; the shutter itself is still  
   strict 3°. (The window is evaluated by `VioSphereEngine.evaluateFrame`.)
6. **Capture.** `readyToCapture` is the single decision; the button, the  
   auto-shutter and the chip all read it. The photograph is taken, written,  
   read back and recorded, each stage under a timeout that names the stage if it  
   stalls.
7. **Advance.** The saved target becomes `captured`, the scene is re-pushed with  
   the done tint, and `_nextPending` walks the list **by position** from the  
   accepted target to the next one that is not done. After the 30th,  
   `phase = complete`.

---

## 2. `sphere.dart` — the direction maths

`lib/features/virtual_tour/domain/math/sphere.dart`

```dart
/// Direction of a (yaw, pitch) pair on the unit sphere.
///
/// `vec(y, p) = (cos p · sin y, sin p, cos p · cos y)`.
///
/// **Note on the yaw convention:** this yaw is *clockwise seen from above*
/// (forward → `+X`). ...
Vec3 directionFromYawPitch(double yawDeg, double pitchDeg) {
  final y = yawDeg * degToRad;
  final p = pitchDeg * degToRad;
  final cp = math.cos(p);
  return Vec3(cp * math.sin(y), math.sin(p), cp * math.cos(y));
}

/// Orthonormal camera basis for a (yaw, pitch) pose.
/// Returns `forward` (the optical axis), `right` and `up`, right-handed, so
/// `right × up == forward`.
({Vec3 forward, Vec3 right, Vec3 up}) orthonormalBasis(
  double yawDeg,
  double pitchDeg,
) {
  final y = yawDeg * degToRad;
  final p = pitchDeg * degToRad;
  final sy = math.sin(y);
  final cy = math.cos(y);
  final sp = math.sin(p);
  final cp = math.cos(p);
  return (
    forward: Vec3(cp * sy, sp, cp * cy),
    right: Vec3(cy, 0, -sy),
    up: Vec3(-sp * sy, cp, -sp * cy),
  );
}
```

Consequences that the rest of the pipeline depends on: yaw 0 → `+Z`,  
yaw +90° → `+X`, `+Y` up, and at pitch ±90° the yaw term vanishes (the poles are  
yaw-degenerate — which is why the guidance uses the 3-D error there).

The rest of the file is `fibonacciSamples(n)`, the equal-area grid used by the  
coverage estimator — not part of the capture loop.

---

## 3. `target_sphere.dart` — the 30 specs, the geometry, `resolveTarget`

`lib/features/capture/domain/services/target_sphere.dart`

### 3.1 Order (front first)

```dart
// 12 horizontal azimuths, every 30°.
const List<double> kCaptureYawsDeg = <double>[0, 30, 60, 90, 120, 150, 180, -150, -120, -90, -60, -30];
// The upper/lower rings' 8 azimuths, every 45°.
const List<double> kCaptureRingYawsDeg = <double>[0, 45, 90, 135, 180, -135, -90, -45];
// Upper, horizontal, lower elevations.
const List<double> kCaptureRingPitchesDeg = <double>[35, 0, -35];
const int kZenithTargetId = 29;
const int kNadirTargetId = 30;
const int kCaptureTargetCount = 30;
```

```dart
List<CaptureTargetSpec> buildCaptureSphere() {
  final out = <CaptureTargetSpec>[];
  var id = 0;
  void add(double yaw, double pitch, String ringName,
      {int? indexInRing, bool pole = false, bool zenith = false, bool nadir = false}) {
    id++;
    out.add(CaptureTargetSpec(
      targetId: id, yawDegrees: yaw, pitchDegrees: pitch,
      direction: directionFromYawPitch(yaw, pitch), ringName: ringName,
      indexInRing: indexInRing, isPole: pole, isZenith: zenith, isNadir: nadir,
    ));
  }

  // Horizontal ring: front first, then the remaining eleven, every 30°.
  for (var i = 0; i < VioSphereConstants.horizontalCount; i++) {
    add(kCaptureYawsDeg[i], 0, kMiddleRingName, indexInRing: i + 1);
  }
  // Upper ring, every 45°, at +35°.
  for (var i = 0; i < VioSphereConstants.upperCount; i++) {
    add(kCaptureRingYawsDeg[i], kCaptureRingPitchesDeg[0], kUpperRingName, indexInRing: i + 1);
  }
  // Lower ring, every 45°, at −35°.
  for (var i = 0; i < VioSphereConstants.lowerCount; i++) {
    add(kCaptureRingYawsDeg[i], kCaptureRingPitchesDeg[2], kLowerRingName, indexInRing: i + 1);
  }
  // The two near-poles close the sequence (+85° / −85°).
  add(0, VioSphereConstants.zenithElevationDeg, kZenithRingName, pole: true, zenith: true);
  add(0, VioSphereConstants.nadirElevationDeg, kNadirRingName, pole: true, nadir: true);
  return out;
}
```

So: **id 1 = front**, 2–12 = rest of the horizontal ring, 13–20 = upper  
(+35°), 21–28 = lower (−35°), 29 = zenith (+85°), 30 = nadir (−85°).

### 3.2 Geometry constants (the numbers the whole pipeline runs on)

```dart
const CaptureGeometryConfig({
  this.targetRadiusM = VioSphereConstants.targetRadiusM,      // 1.0 m
  this.rayDistanceM = 8.0,           // informational probe only — never a gate
  this.hitToleranceM = 0.0,
  this.markerScale = 1.0,            // fine-tune multiplier, not the size
  this.targetDiameterM = 0.22,       // physical plate diameter
  this.bezelSetbackM = 0.006,        // derived: 0.012 − 0.006 (coplanar faces)
  this.alignmentToleranceDeg = 3.0,  // shutter: strict
  this.alignmentHysteresisDeg = 2.0, // window only: 3 + 2 = 5° to break a hold
  this.stabilityWindow = VioSphereConstants.stabilityWindow,   // 600 ms
  this.maxOrientationDriftDeg = 1.5,
  this.maxPositionDriftM = 0.03,
  this.stationDriftWarningM = VioSphereConstants.maxStationDriftM,  // 0.20 m
  this.maxSampleGap = VioSphereConstants.maxSampleGap,             // 150 ms
  this.smootherTauSeconds = 0.12,
  this.smootherSnapAngleDeg = 25,
  this.maxAngularVelocityDegPerSec = 5,
  this.maxMeasurementAge = const Duration(milliseconds: 250),
  this.rateBaseline = const Duration(milliseconds: 100),
});

/// The draw scale for a plate of [modelWidthM] authored metres.
/// 0.22 / 0.54 ≈ 0.407 for the shipped asset.
double markerScaleFor(double modelWidthM) {
  if (modelWidthM <= 0) return markerScale;
  return (targetDiameterM / modelWidthM) * markerScale;
}
```

### 3.3 `resolveTarget` — the single authority for placement

```dart
/// Where one target actually is, in the AR world.
///
/// The position is `station.origin + radius × station.localToWorld(direction)`:
/// gravity-aligned, frozen at calibration, and never derived from the live
/// camera pose.
({Vec3 worldPosition, Vec3 facingNormal, Quat localRotation}) resolveTarget({
  required StationFrame station,
  required CaptureTargetSpec spec,
  required double radiusM,
}) {
  final worldDirection = station.localToWorld(spec.direction).normalized;
  // The plate's face points back at the station.
  final facing = (-worldDirection).normalized;
  return (
    worldPosition: station.origin + worldDirection * radiusM,
    facingNormal: facing,
    localRotation: facingRotation(facing),
  );
}

/// The rotation that takes the model's `+Z` (the plate's face normal) onto [normal].
Quat facingRotation(Vec3 normal) {
  final n = normal.normalized;
  if (n.length == 0) return Quat.identity;
  final dot = clampDouble(Vec3.unitZ.dot(n), -1, 1);
  if (dot > 1 - 1e-9) return Quat.identity;
  if (dot < -1 + 1e-9) return Quat.axisAngle(180, Vec3.unitX);
  final axis = Vec3.unitZ.cross(n);
  final angleDeg = _acosDeg(dot);
  return Quat.axisAngle(angleDeg, axis.normalized);
}
```

---

## 4. `StationFrame` and the calibration reference

`lib/features/capture/domain/services/station_frame.dart`

### 4.1 The frame and its mirror

```dart
class StationFrame {
  final Vec3 origin;      // station origin, AR world metres
  final Quat orientation; // this project's convention

  factory StationFrame.fromArPose({required Vec3 position, required Quat arOrientation}) =>
      StationFrame(origin: position, orientation: arCameraPoseToCaptureWorld(arOrientation));

  Vec3 get rightAxis   => -orientation.rotate(Vec3.unitX);   // physical right
  Vec3 get upAxis      =>  orientation.rotate(Vec3.unitY);
  Vec3 get forwardAxis =>  orientation.rotate(Vec3.unitZ);

  /// Station-local `+X`, `+Y` up, `+Z` forward. The mirror (negated x) is what
  /// makes "yaw +90°" mean *right* instead of left.
  Vec3 localToWorld(Vec3 local) => orientation.rotate(Vec3(-local.x, local.y, local.z));

  Vec3 worldToLocal(Vec3 world) {
    final u = orientation.conjugate.rotate(world);
    return Vec3(-u.x, u.y, u.z);
  }

  double driftOf(RigidPose cameraWorld) => (cameraWorld.position - origin).length;
}
```

### 4.2 The gravity-aligned reference built at *Calibrate station*

```dart
const double kMaxCalibrationVerticalityDeg = 10;

double elevationAboveHorizontalDeg(Vec3 forward, Vec3 up) { ... }  // asin(f · u)
Vec3  projectOntoHorizontal(Vec3 forward, Vec3 up) =>
    forward - u * forward.dot(u);

/// Builds the capture reference orientation from the camera pose at the moment
/// "Calibrate station" was pressed.
///
/// * `up`      — the world's gravity axis (`+Y`);
/// * `forward` — the camera's optical axis projected onto the horizontal plane,
///               which keeps the user's yaw and drops their pitch and roll.
({bool ok, String? reason, Quat? orientation}) captureReferenceFromPose({
  required Vec3 cameraForward,
  Vec3 gravityUp = const Vec3(0, 1, 0),
  double maxVerticalityDeg = kMaxCalibrationVerticalityDeg,
}) {
  final up = gravityUp.normalized;
  if (up.length == 0) { /* …refuse with a reason… */ }
  final f0 = cameraForward.normalized;
  if (f0.length == 0) { /* …refuse with a reason… */ }
  if (elevationAboveHorizontalDeg(f0, up).abs() > 90 - maxVerticalityDeg) {
    return (ok: false,
      reason: 'Hold the phone closer to horizontal before calibrating — the '
              'front direction cannot be measured while the camera points within '
              '${maxVerticalityDeg.toStringAsFixed(0)}° of straight up or down.',
      orientation: null);
  }
  final forward = projectOntoHorizontal(f0, up).normalized;
  if (forward.length < 1e-9) { /* …refuse with a reason… */ }
  // R·x̂ = up × forward, so −R·x̂ is the physical screen-right.
  final right = up.cross(forward);
  final orientation = Quat.fromMatrix3(<double>[
    right.x, up.x, forward.x,
    right.y, up.y, forward.y,
    right.z, up.z, forward.z,
  ]);
  return (ok: true, reason: null, orientation: orientation);
}
```

---

## 5. `projection.dart` — world → camera → screen

`lib/features/virtual_tour/domain/guidance/projection.dart`

```dart
/// Pinhole projection: `fx = (W/2)/tan(hfov/2)`, `fy = (H/2)/tan(vfov/2)`,
/// `u = W/2 + fx·x/z`, `v = H/2 − fy·y/z`.
/// Behind the camera (`dc.z ≤ 0`) there is no projection: the marker is pinned
/// to the screen edge along `atan2(dc.y, dc.x)` — the correct direction.
ScreenProjection project(Vec3 dc, double w, double h, double hfovDeg, double vfovDeg) {
  final fx = (w / 2) / math.tan(hfovDeg * degToRad / 2);
  final fy = (h / 2) / math.tan(vfovDeg * degToRad / 2);

  if (dc.z > 0.0001) {
    return ScreenProjection(
      onScreen: true,
      u: w / 2 + fx * dc.x / dc.z,
      v: h / 2 - fy * dc.y / dc.z,
      fx: fx, fy: fy,
    );
  }
  final a = math.atan2(dc.y, dc.x);
  final ca = math.cos(a);
  final sa = math.sin(a);
  final mx = w / 2 - 16;
  final my = h / 2 - 16;
  final k = math.min(ca.abs() < 1e-6 ? 1e9 : mx / ca.abs(),
                     sa.abs() < 1e-6 ? 1e9 : my / sa.abs());
  return ScreenProjection(
    onScreen: false,
    u: clampDouble(w / 2 + ca * k, 12, w - 12),
    v: clampDouble(h / 2 - sa * k, 12, h - 12),
    fx: fx, fy: fy,
  );
}

/// Alignment error between the camera's forward vector and target direction [d].
/// Great-circle: no yaw special case, correct across the poles.
AimResult aim(Quat q, Vec3 d) {
  final f = q.rotate(Vec3.unitZ);
  final ang = math.acos(clampDouble(f.dot(d), -1, 1)) * radToDeg;
  var ax = f.cross(d);
  final m = ax.length;
  var degenerate = false;
  if (m < 1e-9) {
    degenerate = true;
    ax = f.y.abs() < 0.9 ? f.cross(Vec3.unitY) : f.cross(Vec3.unitX);
  }
  return AimResult(angleDeg: ang, axis: ax.normalized, degenerate: degenerate);
}

/// ARCore / ARKit camera pose → this project's convention.
/// Optical axis on `+ẑ`; the multiply is on the RIGHT (Ry(180) acts in the
/// camera's local frame). Left-multiplying agrees for a pure-yaw pose, which is
/// why the test uses a pitched pose.
Quat arCameraPoseToCaptureWorld(Quat arPose) =>
    (arPose * Quat.axisAngle(180, Vec3.unitY)).normalized;

Quat captureWorldToArPose(Quat captureWorld) =>
    (captureWorld * Quat.axisAngle(-180, Vec3.unitY)).normalized;

/// Human-readable correction, from the signs of `d_cam`.
/// "Turn right" / "Look up" / "Turn around to the left"; 2° dead zone.
String wording(Vec3 dc, double errDeg, double tolDeg) {
  if (errDeg < tolDeg) return 'Target aligned. Hold still.';
  final b = math.atan2(dc.x, dc.z) * radToDeg;
  final e = math.atan2(dc.y, math.sqrt(dc.x * dc.x + dc.z * dc.z)) * radToDeg;
  /* …quadrant wording… */
}
```

### 5.1 The alignment actually used by the guidance

`lib/features/capture/domain/services/alignment_calculator.dart`

```dart
AlignmentResult compute({
  required RigidPose camera,
  required Vec3 targetPosition,
  required double toleranceDeg,
  bool isPole = false,
  double deadZoneDeg = 2,
}) {
  final delta = targetPosition - camera.position;
  final length = delta.length;
  if (length <= 1e-9) {
    return AlignmentResult.unusable(
      distanceM: 0,
      message: 'The target is at the camera; there is no direction to it.',
    );
  }
  final d = delta.normalized;
  final dc = camera.orientation.toCameraFrame(d);

  final yawCorrectionDeg   = math.atan2(dc.x, dc.z) * radToDeg;
  final pitchCorrectionDeg = math.atan2(dc.y, math.sqrt(dc.x * dc.x + dc.z * dc.z)) * radToDeg;

  final forward = camera.forward;
  final angularErrorDeg = math.acos(clampDouble(forward.dot(d), -1, 1)) * radToDeg;

  return AlignmentResult(/* …withinTolerance = angularErrorDeg <= toleranceDeg… */);
}
```

`AlignmentResult.instruction` produces `Turn right 45°` / `tilt up 12°` /  
`Turn around to the right 20°` / `Hold still`, and suppresses the yaw half  
entirely for the poles.

### 5.2 The arrow

`lib/features/capture/presentation/widgets/target_alignment_overlay.dart`

**Changed.** The pointer used to be drawn along `atan2(−pitchCorrection,
yawCorrection)` — an *angle*, while the pixel offset a direction actually
produces is `fx·tan(yaw)` by `fy·tan(pitch)`. On a portrait display
`fy ≈ 1.6·fx`, so the arrow was right in every quadrant and up to ~15° wrong in
every diagonal: it did not point at the GLB. It now projects the target and
draws towards that pixel:
```dart
void paint(Canvas canvas, Size size) {
  final a = alignment;
  if (!anchored || a == null || !a.usable) return;
  if (a.withinTolerance) return;              // hidden once aligned (display only)
  if (size.width <= 0 || size.height <= 0) return;

  // Where the target lands on this viewport: the anchor's world position taken
  // through the current camera pose, through the one projection contract.
  final projection = project(a.directionInCamera, size.width, size.height,
                             displayFov.hfovDeg, displayFov.vfovDeg);

  final centre = Offset(size.width / 2, size.height / 2);
  final toTarget = Offset(projection.u, projection.v) - centre;
  final targetDistance = toTarget.distance;
  if (targetDistance < 1e-6) return;
  final direction = toTarget / targetDistance;

  const wing = 11.0;
  final magnitude = (a.angularErrorDeg / 90).clamp(0.25, 1.0);
  final start = CaptureColors.reticleSize / 2 + 10;
  var wanted = start + 30 + magnitude * (size.shortestSide * 0.20);
  if (projection.onScreen) {
    // Stop at the marker instead of sailing past it.
    wanted = math.max(start + 30, math.min(wanted, targetDistance - wing));
  }
  // Off screen (or behind the camera, which project() pins to the edge along
  // its own bearing) the shaft is clipped there: an edge indicator.
  final tip = math.min(wanted, _distanceToEdge(centre, direction, size));
  /* …draw shaft + two wings… */
}
```

`displayFov` comes from `CaptureState.displayFov` =
`intrinsics?.portraitDisplayFov() ?? ArCameraIntrinsics.fallbackDisplayFov` —
the same pair the projection contract uses everywhere else. Polar targets go
through the same call and have no yaw to get wrong: the behind-camera branch
pins them to the top/bottom edge.

**Deliberate split:** the arrow's geometry comes from `displayAlignment`  
(smoothed) so it does not jitter; the ring's colour and progress come from  
`alignment.withinTolerance` (unsmoothed) so the ring cannot look settled while  
the phone is still moving. See the overlay's own class comment.

---

## 6. `glb_target_scene.dart` and `glb_renderer.dart`

**Important scoping note (verified in the audit):** these two files are the  
**tour-flow screen-space overlay** (a `CustomPainter`-drawn software rasteriser  
for the pre-AR tour UI). The 30-target capture path does **not** draw through  
them — it uploads the two GLB meshes to the native AR renderer and pushes  
`ArSceneDraw`s (see §7.2). The 1.0 m "distance" below is a billboard depth for  
the software renderer, not the capture radius. They share the same pinhole  
contract as `project()`, which is what the tests assert.

### 6.1 `glb_target_scene.dart` (`:151`, `:282`)

```dart
const double arBezelSetbackM  = 0.006; // derived: 0.012 − 0.006 (front faces flush)
const double arTargetDistanceM = 1.0;  // billboard depth for the software renderer
const double arTargetNearM     = 0.05; // matched to project()'s dc.z > 0.0001

class GlbTargetScene implements ArTargetRenderer {
  /// The world point the marker is pinned to: pixel (screenX, screenY) on the
  /// camera's pinhole sphere, at [distanceM]. The inverse pinhole lives in
  /// GlbCamera.pixelDirection, so this agrees with project() by construction.
  Vec3 markerCentre(GlbCamera camera, {double? distanceM}) =>
      camera.position + camera.pixelDirection(_screenX, _screenY) * (distanceM ?? _distanceM);

  GlbTransform plateToWorld(GlbCamera camera, {double? distanceM, double? scale}) =>
      glbBillboardTransform(
        target: markerCentre(camera, distanceM: distanceM),
        camera: camera,
        tiltXDeg: _tiltXDeg, tiltYDeg: _tiltYDeg,
        scale: scale ?? _scale,
      );

  /// Bezel: the plate's pose, recessed along the plate's own normal.
  GlbTransform bezelToWorld(GlbCamera camera, {double? distanceM, double? scale}) =>
      plateToWorld(camera, distanceM: distanceM, scale: scale)
          .then(GlbTransform.trs(translation: Vec3(0, 0, -arBezelSetbackM)));

  /// Projected triangles for the current state, in draw order (far first).
  List<GlbScreenTriangle> triangles({required GlbCamera camera, double? distanceM}) {
    _distanceM = distanceM ?? arTargetDistanceM;
    if (!_visible || !_placed) return const <GlbScreenTriangle>[];
    if (isMarkerBehindCamera(camera, distanceM: _distanceM)) return const <GlbScreenTriangle>[];

    final plate = projectGlb(
      model: targetModel, modelToWorld: plateToWorld(camera, distanceM: _distanceM),
      camera: camera, opacity: _state.targetOpacity, nearM: arTargetNearM,
      recolor: recolorTarget, group: 'target', groupOrder: 1,
    ).where((GlbScreenTriangle t) => _drawnNow(t.drawableIndex));

    final bezel = projectGlb(
      model: bezelModel, modelToWorld: bezelToWorld(camera, distanceM: _distanceM),
      camera: camera, nearM: arTargetNearM,
      recolor: recolorBezel, group: 'bezel', groupOrder: 0,
    );

    final all = <GlbScreenTriangle>[...bezel, ...target];
    all.sort(compareGlbDrawOrder);
    return all;
  }
}
```

### 6.2 `glb_renderer.dart` (`:43`, `:215`, `:339`)

```dart
class GlbCamera {
  final Quat pose; final Vec3 position;
  final double viewportW, viewportH, hfovDeg, vfovDeg;
  final double fx, fy;   // fx = (W/2)/tan(hfov/2) — exactly as project()

  Vec3 toCameraFrame(Vec3 worldPoint) => pose.toCameraFrame(worldPoint - position);

  ({double u, double v}) projectCameraFrame(Vec3 cameraFrame) => (
    u: viewportW / 2 + fx * cameraFrame.x / cameraFrame.z,
    v: viewportH / 2 - fy * cameraFrame.y / cameraFrame.z,
  );

  /// The world direction through pixel (u, v) — the exact inverse.
  Vec3 pixelDirection(double u, double v) {
    final c = cameraFrameOfPixel(u, v);
    return pose.rotate(Vec3(-c.x, c.y, c.z));   // undo toCameraFrame's negated x
  }
}

List<GlbScreenTriangle> projectGlb({
  required GlbModel model, required GlbTransform modelToWorld,
  required GlbCamera camera, required double nearM,
  double opacity = 1.0, bool cullBackFaces = true, double shadeFloor = 0.55,
  GlbRecolor? recolor, String group = '', int groupOrder = 0,
}) {
  /* per drawable, per triangle:
     world → camera frame → drop any corner at/behind nearM → back-face cull
     → project → drop off-viewport → flat shade → emit with depth
     then: out.sort(compareGlbDrawOrder);   // far first, then group, then sequence */
}

/// Billboard pose: the model's +Z (its face) maps onto the direction from the
/// target back to the camera.
GlbTransform glbBillboardTransform({
  required Vec3 target, required GlbCamera camera,
  double tiltXDeg = 0, double tiltYDeg = 0, double scale = 1.0,
}) {
  final toCamera = camera.position - target;
  final face = toCamera.length == 0 ? camera.pose.rotate(Vec3.unitZ) : toCamera.normalized;
  var up = camera.pose.rotate(Vec3.unitY);
  if (up.dot(face).abs() > 0.999) up = Vec3.unitZ;      // degenerate roll guard
  var right = up.cross(face);
  if (right.length < 1e-9) right = Vec3.unitX.cross(face);
  right = right.normalized;
  final orthoUp = face.cross(right).normalized;
  final billboard = Quat.fromMatrix3(<double>[
    right.x, orthoUp.x, face.x,
    right.y, orthoUp.y, face.y,
    right.z, orthoUp.z, face.z,
  ]);
  final tilt = (Quat.axisAngle(tiltXDeg, Vec3.unitX) * Quat.axisAngle(tiltYDeg, Vec3.unitY)).normalized;
  return GlbTransform.trs(translation: target, rotation: (billboard * tilt).normalized,
                          scale: Vec3(scale, scale, scale));
}
```

---

## 7. The capture screen and the target progression logic

### 7.1 `calibrateStation` — `capture_controller.dart:364`

```dart
Future<void> calibrateStation({String? stationId}) async {
  final pose = _session.latest;
  if (pose == null) { /* 'No camera pose yet. Wait for AR tracking.' */ return; }
  if (pose.tracking != TrackingState.tracking) { /* 'AR is not tracking yet…' */ return; }

  // Gravity-aligned, NOT the raw pose: the raw pose carries the pitch and roll
  // the phone happened to be held at.
  final reference = captureReferenceFromPose(
    cameraForward: pose.orientation.rotate(Vec3.unitZ),
  );
  if (!reference.ok) { _emit(state.copyWith(message: reference.reason)); return; }

  final frame = StationFrame(origin: pose.position, orientation: reference.orientation!);
  _frame = frame; _smoother.reset(); _engine.resetStability();

  final station = CaptureStation(stationId: id, referencePosition: frame.origin,
      referenceOrientation: frame.orientation, createdAt: _clock(),
      trackingStatus: pose.tracking, total: _specs.length);

  final targets = <CaptureTarget>[ for (final spec in _specs) CaptureTarget(/* … */) ];

  await _repository.saveStation(station);
  await _repository.saveTargets(targets);
  _savedStationIds = await _repository.stationIds();

  _emit(state.copyWith(phase: CapturePhase.capturing, station: station, targets: targets,
                       activeTargetId: targets.first.targetId, clearAlignment: true));

  await probeTargets();                      // information, never a gate

  // Place the complete arrangement, once. Idempotent by target id.
  final outcome = await _withPlacementSlot<PlacementOutcome>(
      () => _anchors.placeAll(station: frame, specs: _specs));
  /* …emit 'Placed N targets.'… */

  // Start on the first target — yaw 0 / pitch 0, where the user is already looking.
  await selectTarget(_specs.first.targetId);
}
```

### 7.2 Placement and the scene push — `plane_anchor_service.dart:153`, `:274`

```dart
Future<PlacementOutcome> placeAll({
  required StationFrame station, required List<CaptureTargetSpec> specs,
}) async {
  for (final spec in specs) {
    final existing = _placementsById[spec.targetId];
    if (existing != null) { placed[spec.targetId] = existing; continue; }  // idempotent

    final resolved = resolveTarget(station: station, spec: spec, radiusM: geometry.targetRadiusM);

    final anchor = await _host.createAnchor(
      position: resolved.worldPosition,
      orientation: Quat.identity,   // orientation is the engine matrix, not the anchor
      trackableKey: null,           // a WORLD anchor: no plane required
    );
    // The engine's 4×4 model basis, column-major, consumed by the native
    // renderer. Only its rotation is used; the anchor supplies the translation.
    // The engine has its own Vec3 type, so the call site converts.
    final w = resolved.worldPosition, o = station.origin;
    final modelMatrix = vio.VioSphereEngine.buildModelMatrix(
      targetWorldPosition: vio.Vec3(w.x, w.y, w.z),
      stationOriginWorld: vio.Vec3(o.x, o.y, o.z));
    /* …per-target failure recorded, the other 29 still placed… */
    _placementsById[spec.targetId] = AnchoredTarget(
      anchor: anchor, worldPosition: resolved.worldPosition,
      facingNormal: resolved.facingNormal, localRotation: resolved.localRotation,
      modelMatrix: modelMatrix, surfaceType: worldSurfaceLabel);
  }
}

Future<void> pushScene({
  required int activeTargetId,
  ({double r, double g, double b, double a}) bezelTint = kBezelIdleTint,
  double opacity = 1, Set<int> doneTargets = const <int>{},
  Set<int> hiddenTargets = const <int>{}, bool debugMarker = false,
}) async {
  for (final entry in _placementsById.entries) {
    // Hidden: omitted from the draw list. The anchor and the placement stay —
    // only the mesh and the bezel leave the frame.
    if (hiddenTargets.contains(entry.key)) continue;
    final isActive = entry.key == activeTargetId;
    final isDone   = doneTargets.contains(entry.key);
    final targetOpacity = isActive || isDone ? opacity : kInactiveTargetOpacity;  // 0.35
    final Float32List modelMatrix = Float32List.fromList(p.modelMatrix);
    draws.add(ArSceneDraw(meshId: bezelMeshId, anchorId: p.anchor.id,
        localRotation: p.localRotation, modelMatrix: modelMatrix,
        scale: markerScale,
        offset: Vec3(0, 0, -geometry.bezelSetbackM), tint: tint, useTint: true,
        opacity: targetOpacity,
        // A capture target is a WORLD anchor at a position this app computed.
        // ARCore pauses it while its own tracking degrades and resumes it by
        // itself; hiding the mesh meanwhile is what made targets vanish on a
        // turn. The plane-attached flow keeps the strict default.
        requireTracking: false));
    draws.add(ArSceneDraw(meshId: targetMeshId, anchorId: p.anchor.id,
        localRotation: p.localRotation, modelMatrix: modelMatrix,
        scale: markerScale, opacity: targetOpacity,
        requireTracking: false));
  }
  await _host.setScene(draws);
}
```

**How the engine's transform reaches the GPU.** The matrix is not stored in Dart
and ignored natively — it is carried on every draw and used by the renderer:

```
VioSphereEngine.buildModelMatrix(target, stationOrigin)   → Float64List (16, column-major)
  AnchoredTarget.modelMatrix                              → per-target constant
  ArSceneDraw.modelMatrix  (Float32List: the channel decodes it to Kotlin float[])
  → ArCoreCapturePlugin.parseScene → item["modelMatrix"], length-checked == 16
  → ArCoreSessionController.DrawSpec.modelMatrix → buildDraws()
  → ArGlRenderer.DrawRequest.modelMatrix → buildModelMatrix()
      model = anchorMatrix × R_engine(translation zeroed) × translate(offset) × scale
      mvp   = viewProjection × model,  glUniformMatrix4fv(…, transpose = false, …)
```

The anchor is created with an **identity** orientation, so `anchorMatrix` is a
pure world translation; the engine's basis supplies the rotation and its
translation column is dropped. That keeps the marker glued to the anchor ARCore
tracks — the same position the guidance aims at — while the orientation comes
from the frozen sphere maths. Rotation is applied **exactly once**; nothing is
transposed or inverted anywhere, because both matrices are column-major and the
shader upload says `transpose = false`. `localRotation` is retained as the
fallback for any platform, and for the legacy tour caller, that does not read
`modelMatrix`.

**Paused ≠ lost.** `_refreshAnchorIfDue` only re-places an anchor the host no
longer has (bounded by `kAnchorReplacementsMax`). A *paused* anchor is waited
out: the marker keeps its world position and is drawn from `anchor.pose` every
frame, and ARCore resumes it on its own. It used to count ~3 s of pause and
then re-place — the replacement starts paused too, two rounds hit the give-up
latch, and the marker never came back.

**Hidden ≠ placed, and visibility ≠ readiness.** A target is hidden when its
**ring is complete** (`CaptureState.ringComplete` = raw alignment inside
tolerance *and* the stability window elapsed *and* every other capture condition
already holds), while a capture transaction is in flight, or once it is captured
(`isDone`). Tracking, measurement freshness and drift are deliberately **not**
consulted on their own: they flip on their own, and folding them in is what made
the marker flash on and off while the phone was held still. The active target
comes back on `align`/`settle`/`retry` — the hold lost, or the photograph failed.
One scene push per transition, driven by comparing `_hiddenTargetsIn(...)` with
the last pushed set.

**A full ring now means `readyToCapture` — they are the same condition.**
`captureBlockReason` is split in two: `captureBlockReasonBeforeSettle` holds
every condition *except* the stability window, and the ring's fill is gated on
it. Before the split the ring filled on alignment alone and could sit at 100%
while the shutter was blocked on drift or an untracked anchor — a full ring, a
dead shutter, and no stated reason. Now the ring may fill ⟹ every other
condition holds ⟹ a full ring is exactly `readyToCapture`.

**One capture transaction, and one attempt per alignment episode.**
`_shoot` takes a synchronous latch (`_captureInFlight`) before its first await,
so the shutter button, the auto path on the next pose and a re-entrant callback
all see the same flag — `state.capturing` is published state and can be a frame
behind. On failure the state also sets `retryPending`, which
`captureBlockReason` reports and which only a deliberate move off the target
(error past `tolerance + hysteresis`, the same threshold that breaks the
stability window) clears. Before that latch existed, `captureBlockReason` said
nothing about a failed attempt, so a target whose photograph kept failing stayed
"ready" — and with the auto shutter that is fire, fail, fire, fail, forever, with
the interface flickering between "Ready to capture" and "Saving the
photograph…" and the count never leaving 0 of 30.

**The guidance aims at the position the renderer draws.** The controller names
the active anchor (`setActiveAnchor`), and the native render loop puts that
anchor's **current** `pose` translation and tracking state on the pose event it
already emits at 30–60 Hz. `ArPoseSample.activeAnchorPose` is what the alignment
uses; the placement's cached `worldPosition` is the fallback for the frames
before the host reports one. Aiming at a copy refreshed twice a second meant the
arrow pointed a few centimetres off the marker while ARCore refined it — the one
remaining place the two could disagree.

**A paused pose is not a current pose.** While ARCore reports anything other
than `tracking`, the controller derives **no** alignment from that pose and the
drift figure holds its last trustworthy value. Growing drift from a pose ARCore
itself flags as possibly stale is what blamed the user for the tracker's own
uncertainty — "you are 0.9 m from the station, walk back" while they never
moved. The stability window is already reset, the ring's progress goes with it,
and the auto shutter becomes structurally unreachable rather than merely gated.
The 30 targets are untouched throughout: their positions come from the frozen
station, and the renderer keeps drawing them from their anchors whatever the
camera is doing.

**Proof that the arrangement is camera-independent** — `dart run
tool/verify_sphere.dart` places all 30 targets through the real
`resolveTarget` and then moves the camera four ways (at the station, turned 90°,
tilted 40°, walked 2 m). Worst world movement across all four: `0.0e+0 m`.
Worst radius error `2.2e-16 m`, worst yaw error `0.0°`, worst pitch error
`7.1e-15°`. The screen projection moves (dead centre → edge → off-screen), which
is the perspective the user is meant to see; the world position does not move at
all. The same run shows the facing vector staying fixed as the camera walks
(`facing·toCamera` falls from 1.0 to 0.24), which is the marker *not* behaving
as a billboard. `tool/verify_all.dart` is stale — it imports `test/*_checks.dart`
files that no longer exist — so this tool follows the standalone
`tool/measure_glb.dart` pattern instead.

**What the code cannot fix.** When ARCore reports `INSUFFICIENT_FEATURES` (the
screenshots' own message), its world map is unreliable and the anchors move with
ARCore's re-localisation. That is tracker drift, not a transform defect: the
markers are correct in ARCore's world, and ARCore's world is what is sliding.
The app's part is to say so (the tracking guidance carries ARCore's reason), to
keep the targets placed through it, and to block capture — all of which it does.

**The arrow's gates are three separate facts**: the node is in the scene
(`activeAnchored`), a camera pose may be aimed with (`tracking == tracking`),
and the alignment has an answer. **Not** the anchor's tracking state — a paused
anchor keeps its world position and is drawn, so gating on it is what left the
marker on screen while the pointer vanished during every ARCore pause.

**The world scale is constant.** `markerScaleFor(0.54) ≈ 0.407` is applied once
(`_applyMarkerScale`, every `boot`) to both the plate and the bezel, and
`buildDraws` re-reads only `anchor.pose` — never a per-frame scale. A marker
that looks smaller is a marker further away; the status detail now prints the
physical diameter and the current distance so the two are distinguishable on
screen.

**No planes is not a blocker.** Every target is a world anchor
(`trackableKey: null`) at a computed position, so plane detection is advisory
only — the status says so. What *does* block is `TrackingState.paused`: the
instruction line now carries ARCore's own failure reason ("too dark", "moving
too fast", "not enough detail") instead of "Starting the AR session…" forever,
because the phase cannot leave `starting` until a pose with tracking arrives.

### 7.3 `selectTarget` — `:672`

```dart
Future<void> selectTarget(int targetId) async {
  if (_placing) { _pendingSelection = targetId; return; }   // queue, never interleave
  /* … */
  if (targetId != state.activeTargetId) {                    // genuine switch: fresh budget
    _anchorReplacements = 0; _anchorGiveUp = false; _anchorNotTracking = 0;
  }
  _engine.resetStability();
  final placement = _anchors.placementFor(targetId);
  _placement = placement;

  // Demote the target that used to be active — otherwise every visited target
  // keeps `active` and the sphere map stays amber forever.
  final demoted = _demoteActive(state.targets, except: targetId);

  await _anchors.pushScene(activeTargetId: targetId, bezelTint: kBezelIdleTint, /*…*/);

  if (placement == null) {
    _emit(state.copyWith(activeTargetId: targetId, clearAlignment: true, stable: false,
        activeAnchored: false, message: 'This target is not placed — press Scan again.'));
    return;
  }
  final tracking = placement.isTracking;    // placed ≠ drawn: a PAUSED anchor draws nothing
  _emit(state.copyWith(targets: _withAnchorIn(demoted, targetId, placement, setActive: true),
      activeTargetId: targetId, clearAlignment: true, stable: false,
      activeAnchored: true, activeAnchorTracking: tracking,
      message: tracking ? null : 'Waiting for AR to stabilise the target…'));
}
```

### 7.4 The pose loop (the heart of guidance + alignment)

```dart
final rawCamera = RigidPose(position: pose.position, orientation: pose.orientation);
final smoothed = trackingOk ? _smoother.filter(sample) : pose.orientation;

// Only use the placement while it belongs to the ACTIVE target.
final placementIsActive = next.activeAnchored && placement != null &&
                          target != null && !target.status.isDone;
if (placementIsActive) {
  // The guidance aims at the anchor's LIVE pose when the host reports one, and
  // the frozen placement position otherwise (see §7.2's "guidance aims at the
  // position the renderer draws").
  final targetPosition = live != null && live.tracking == TrackingState.tracking
      ? live.position : placement.worldPosition;

  // Two alignments, on purpose:
  //  * `alignment`        — unsmoothed: the gate, the instruction, the numbers.
  //  * `displayAlignment` — smoothed: where the arrow is drawn, and nothing else.
  final alignment = _calculator.compute(camera: rawCamera,
      targetPosition: targetPosition,
      toleranceDeg: state.geometry.alignmentToleranceDeg, isPole: target.isPole);
  final displayAlignment = _calculator.compute(
      camera: RigidPose(position: pose.position, orientation: smoothed),
      targetPosition: targetPosition,
      toleranceDeg: state.geometry.alignmentToleranceDeg, isPole: target.isPole);

  // The 600 ms hold, the drift gate and the pose validation are ALL the
  // engine's — one implementation, not a second copy of the arithmetic here.
  // `canTriggerShutter` is the specification's own expression; the two latches
  // are folded in so the conjunction is written once.
  final gate = _engine.evaluateFrame(
      pose: vioSample, trackingValid: trackingOk,
      activeTargetIndex: target.targetId - 1,
      isSavingInProgress: state.capturing || _captureInFlight,
      isFailureLatched: next.retryPending,
      nowNanoseconds: timing.nowNanoseconds);

  next = next.copyWith(alignment: alignment, displayAlignment: displayAlignment,
      measurementFresh: gate.stabilityRejection != 'measurement-age',
      angularRateDegPerSec: gate.angularVelocityDegPerSec,
      stabilityRejection: gate.stabilityRejection,
      stable: gate.isPoseSteady, stabilityProgress: _stabilityProgressOf(gate),
      driftM: gate.stationDriftM);

  // The auto shutter reads the same gate the button does.
  if (autoCapture && gate.canTriggerShutter && !state.capturing && !_photos.busy) {
    _emit(next); _shoot(); return;
  }
} else {
  next = next.copyWith(clearAlignment: true, stable: false);
}
```

> **Superseded.** This loop previously called `_stability.update(...)` on a
> separate `StabilityMonitor` with a **450 ms** window. The window is now the
> engine's `evaluateFrame` at the specification's **600 ms**, and the drift
> figure is the engine's full-3D `stationDriftM`. `stability_monitor.dart` is
> retained but is no longer in this path.

### 7.5 `_shoot` and `_nextPending` — `:1050`, `:1177`

```dart
Future<void> _shoot() async {
  /* …gates… */
  _emit(state.copyWith(capturing: true));
  final record = await _photos.capture(stationId: station.stationId, target: target,
      camera: RigidPose(position: pose.position, orientation: pose.orientation),
      alignment: alignment, anchored: placement != null,
      toleranceDeg: state.geometry.alignmentToleranceDeg, /* … */);

  final updated = List<CaptureTarget>.of(state.targets);    // never removeWhere on const []
  updated[target.targetId - 1] = updated[target.targetId - 1].copyWith(
      status: CaptureTargetStatus.captured, imagePath: record.imagePath);
  await _repository.saveTargets(updated);
  await _repository.saveStation(station.copyWith(capturedCount: capturedCount));
  _savedStationIds = await _repository.stationIds();

  // The whole arrangement stays in the scene; only the highlight moves.
  await _anchors.pushScene(activeTargetId: target.targetId, bezelTint: kBezelDoneTint,
      doneTargets: <int>{for (final t in updated) if (t.status.isDone) t.targetId});

  if (capturedCount >= updated.length) { _emit(state.copyWith(phase: CapturePhase.complete)); return; }
  if (autoAdvance) {
    final next = _nextPending(updated, after: target.targetId);
    if (next != null) await selectTarget(next);
  }
  /* on CaptureFailure: mark failed, PERSIST it, push the failed tint */
}

int? _nextPending(List<CaptureTarget> targets, {required int after}) {
  // Position-based, not id-arithmetic: the list order *is* the capture order.
  final start = targets.indexWhere((CaptureTarget t) => t.targetId == after);
  if (start < 0) return null;
  for (var step = 1; step <= targets.length; step++) {
    final candidate = targets[(start + step) % targets.length];
    if (!candidate.status.isDone) return candidate.targetId;
  }
  return null;
}
```

### 7.6 The one readiness decision — `capture_state.dart:276`

```dart
bool get readyToCapture => captureBlockReason == null;

String? get captureBlockReason {
  if (arFault != null)              return 'AR is not rendering. See the error above.';
  if (textureId == null)            return 'Waiting for the AR camera.';
  if (phase == CapturePhase.complete) return 'Every target has a photograph.';
  if (phase != CapturePhase.capturing) return 'AR is still starting.';
  if (tracking != TrackingState.tracking) return 'AR tracking is not ready — move the phone slowly.';
  if (station == null)              return 'Calibrate the station first.';
  if (target == null)               return 'Select a target.';
  if (target.status.isDone)         return 'This target is already captured. Use Retake to replace it.';
  if (capturing)                    return 'Saving the photograph…';
  if (stationDrifted)               return 'You are ${driftM.toStringAsFixed(1)} m from the station — '
                                           'walk back to it, or press Recalibrate here.';
  if (!activeAnchored)              return 'The target is not placed — press Scan again.';
  if (!activeAnchorTracking)        return 'Waiting for AR to stabilise the target…';
  if (alignment0 == null || !alignment0.usable) return 'Waiting for a target position.';
  if (!alignment0.withinTolerance)  return alignment0.instruction;
  if (!stable)                      return 'Hold still…';
  return null;                                       // → ready
}
```

### 7.7 The derived shot phase — `shot_phase.dart:75`

```dart
ShotPhase deriveShotPhase({
  required bool trackingValid, required bool measurementFresh,
  required bool targetSelected, required bool targetAnchored,
  required bool withinTolerance, required bool stable, required bool saving,
  required bool lastAttemptFailed, required bool targetAccepted,
  required bool stationDrifted,
}) {
  if (targetAccepted) return ShotPhase.accept;
  if (saving) return ShotPhase.validate;                 // outranks everything but accept
  if (lastAttemptFailed) return ShotPhase.retry;         // outranks align
  if (!trackingValid || !measurementFresh) return ShotPhase.initialising;
  if (!targetSelected || !targetAnchored) return ShotPhase.align;
  if (!withinTolerance) return ShotPhase.align;          // 'Aim at target'
  if (stationDrifted) return ShotPhase.align;
  if (!stable) return ShotPhase.settle;                  // 'Hold still'
  return ShotPhase.capture;                              // 'Ready'
}
```

### 7.8 The screen — `ar_capture_screen.dart:226`, `:596`

```dart
TargetAlignmentOverlay(
  // Smoothed for the arrow's geometry, raw for the ring's verdict.
  alignment: state.displayAlignment ?? state.alignment,
  withinTolerance: state.alignment?.withinTolerance ?? false,
  stabilityProgress: state.stabilityProgress,
  anchored: state.activeAnchored,
  bezel: controller.bezelGeometry,
  completed: state.shotPhase == ShotPhase.accept,
),
```

```dart
onPressed: () => controller.calibrateStation(),          // :596  Calibrate station
onPressed: () => controller.resumeStation(controller.resumableStationId!),  // :607
onPressed: () => controller.captureNow(),                // :617  shutter
label: 'Recalibrate here',                               // :631  shown when stationDrifted
onPressed: () => controller.recalibrateHere(),           // :635
```

---

## 8. What is verified and what is not

**Verified by the suite (no device needed)**

- `VioSphereEngine` — the whole frozen-sphere maths: `f_cam` closed form against
  a reference implementation, `ψ0` extraction and refusal near vertical, the 30
  positions/angles, the inclusive 0.20 m and 3.0° gates, signed yaw wrap, the
  600 ms window (age, monotonicity, 150 ms sample gap, orientation/position
  drift, angular rate), the verbatim shutter expression, and
  `buildModelMatrix`'s orthonormal det-+1 basis with +Z pointing back at the
  station. (`test/vio_sphere_math_test.dart`, 57 cases)
- Equivalence of that engine with the shipped pipeline: the 30 specs "match the
  §7 spherical formula", i.e. `station.localToWorld(directionFromYawPitch(α, θ))`
  equals the engine's `d̂ = [cosθ·sin(ψ0+α), sinθ, −cosθ·cos(ψ0+α)]`, so the
  placement here and the engine's frozen positions cannot disagree.
  (`test/capture_targets_test.dart`)

- `captureReferenceFromPose` — level, pitched and rolled poses; refusal within  
  10° of vertical; the reason string. (`test/capture_reference_test.dart`)
- `resolveTarget` + `facingRotation` — the plate faces the station, the position  
  is `P0 + r·d̂`, degenerate `+Z → −Z` handled. (`test/world_target_test.dart`,  
  `test/capture_targets_test.dart`)
- `project()` against known world points, `arCameraPoseToCaptureWorld` with a  
  *pitched* pose so left- and right-multiply differ. (`test/projection_test.dart`)
- Scale: `markerScaleFor(0.54) ≈ 0.407`, applied on every `boot()`.  
  (`test/target_scale_test.dart`)
- Progression: front-first order, `_nextPending` by position, saved-record-only  
  progress, resume. (`test/capture_progress_test.dart`,  
  `test/target_transition_test.dart`, `test/capture_flow_test.dart`)
- Capture timeouts and stage logging. (`test/photo_capture_service_test.dart`)
- Stability: the window survives tremor, the pose-derived rate beats the biased  
  gyro, measurement age rejects. (`test/motion_stability_test.dart`)

**Not verified — needs a physical phone**

1. That ARCore accepts 30 world anchors at 1.0 m in a real room.
2. That the GLB markers are visible and correctly sized on screen.
3. That the 1 → 2 transition draws the new highlight where the user expects it.
4. That a full 30-photograph station completes without an anchor drop.

No device has been attached in any session (`adb devices` empty;  
`flutter devices` blocked by the sandbox), so none of these have been  
observed. The `--dart-define=glb_debug_marker=true` magenta 3.5× plate at the  
active anchor exists precisely to settle #2 on the first device run: if the  
magenta plate appears, the anchor, the scene push and the projection are all  
correct; if it does not, the problem is the anchor, not the GLB.
