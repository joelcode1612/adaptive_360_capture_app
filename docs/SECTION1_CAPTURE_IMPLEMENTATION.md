# Section 1 — 360° Capture Module with ARCore, GLB Anchors and Phone Alignment

Implementation report. Scope: the **Capture module only**. No panorama stitching and  
no panorama viewer were added.

---

## 1. What the project already had, and what was missing

The project already contained a complete AR *abstraction* and no AR *host*:

| Already present                                                           | Missing                                                                             |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `ArPoseSource`, `ArStationAnchorSource`, `ArFrameGrabber` interfaces      | any implementation backed by ARCore                                                 |
| `arcore_payload.dart` — parsers for the native payloads                   | the Kotlin host that produces them                                                  |
| `arCameraPoseToCaptureWorld` — the AR→app coordinate adapter, unit-tested | a caller                                                                            |
| `parseGlb` — a full glTF 2.0 reader, and `glb_target_scene.dart`          | a renderer that draws the mesh *in the world* rather than as a screen-space overlay |
| `assets/models/ar_capture_target.glb`, `white_frame_bezel.glb`            | — (both reused byte-for-byte)                                                       |
| `CaptureSessionRepository`, `CapturePaths`, `PermissionService`           | — (the new module follows the same storage and permission conventions)              |

`platform/ar_bootstrap.dart` stated the situation explicitly: *"This build has no  
ARCore host."* It returned `SensorPoseSource`, and the GLB target was projected as a  
pure-Dart triangle overlay pinned to a screen pixel — a HUD, not an anchored model.  
Both are now real.

---

## 2. Files

### Created — Android (Kotlin)

| File                                                            | Role                                                                                                                |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `android/app/src/main/kotlin/.../ar/ArCoreCapturePlugin.kt`     | `FlutterPlugin` + `ActivityAware`; `MethodChannel` `adaptive360/arcore`, `EventChannel` `adaptive360/arcore/events` |
| `android/app/src/main/kotlin/.../ar/ArCoreSessionController.kt` | Owns the AR thread, the `Session`, the EGL surface, raycasts, anchors and stills                                    |
| `android/app/src/main/kotlin/.../ar/ArGlRenderer.kt`            | GLES 2.0: the camera OES texture quad, and the anchored mesh program                                                |
| `android/app/src/main/kotlin/.../ar/YuvJpegEncoder.kt`          | `YUV_420_888` → rotated NV21 → JPEG                                                                                 |

### Created — Dart

| File                                                                      | Role                                                                                                          |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `lib/features/virtual_tour/platform/arcore_ar.dart`                       | The bridge: `ArCoreGateway` interface, `ArCoreHost` implementation, typed session/pose/hit/anchor/still types |
| `lib/features/capture/domain/models/capture_station.dart`                 | `CaptureStation`                                                                                              |
| `lib/features/capture/domain/models/capture_target.dart`                  | `CaptureTarget`, `CaptureTargetStatus`                                                                        |
| `lib/features/capture/domain/models/capture_record.dart`                  | `CaptureRecord`                                                                                               |
| `lib/features/capture/domain/services/station_frame.dart`                 | `RigidPose`, `StationFrame` — **the coordinate adapter**                                                      |
| `lib/features/capture/domain/services/target_sphere.dart`                 | The 26 directions + `CaptureGeometryConfig`                                                                   |
| `lib/features/capture/domain/services/alignment_calculator.dart`          | Phone-to-target alignment                                                                                     |
| `lib/features/capture/domain/services/stability_monitor.dart`             | Steadiness gate                                                                                               |
| `lib/features/capture/application/capture_state.dart`                     | Immutable UI snapshot                                                                                         |
| `lib/features/capture/application/capture_controller.dart`                | The one Flutter-aware piece                                                                                   |
| `lib/features/capture/data/services/ar_session_service.dart`              | Session lifecycle, pose stream, capability probe                                                              |
| `lib/features/capture/data/services/plane_anchor_service.dart`            | Raycast → anchor → scene                                                                                      |
| `lib/features/capture/data/services/photo_capture_service.dart`           | Save → verify → record                                                                                        |
| `lib/features/capture/data/services/glb_mesh_source.dart`                 | GLB → vertex buffers for the native renderer                                                                  |
| `lib/features/capture/data/repositories/capture_repository_impl.dart`     | JSON + JPEG persistence                                                                                       |
| `lib/features/capture/presentation/screens/ar_capture_screen.dart`        | The capture screen                                                                                            |
| `lib/features/capture/presentation/widgets/spherical_target_map.dart`     | The 26-target sphere                                                                                          |
| `lib/features/capture/presentation/widgets/target_alignment_overlay.dart` | Directional arrow + reticle                                                                                   |
| `lib/features/capture/presentation/widgets/capture_progress_widget.dart`  | Progress, overall and per ring                                                                                |

### Created — tests

`test/capture_targets_test.dart`, `test/alignment_test.dart`,  
`test/stability_test.dart`, `test/capture_flow_test.dart`,  
`test/capture_test_fakes.dart`.

### Modified

| File                                              | Change                                                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Registers `ArCoreCapturePlugin` in `configureFlutterEngine`                                                   |
| `android/app/build.gradle.kts`                    | `com.google.ar:core` **1.48.2 → 1.57.0** — 1.48.2 was never published, so the build could not resolve it      |
| `lib/main.dart`                                   | Home is now a two-entry launcher: **AR capture** (Section 1) and the existing **Guided flow**, both reachable |
| `analysis_options.yaml`                           | Excludes `tool/**` (see §8)                                                                                   |
| `pubspec.yaml`                                    | **Unchanged.** No new Dart dependency was needed                                                              |

---

## 3. AR and camera packages

**No Flutter AR package was used.** The integration is a hand-written native host.

Selection criteria, in the order they were applied:

1. **An arbitrary world-space raycast.** Section 1 §8 requires a ray from the  
   station origin along a target direction. Screen-tap hit tests (`hitTest(x, y)`)  
   cannot express that. ARCore's  
   `Frame.hitTest(float[] origin, int originOffset, float[] direction, int directionOffset)`  
   can.
2. **An anchor created at that hit**, attached to the *plane* rather than to the  
   world.
3. **The live camera pose**, for the alignment maths.
4. **A photograph taken through the running session.** ARCore holds the camera  
   device exclusively: while a session is live, `camera_android`, CameraX and  
   `camera2` cannot open the sensor at all — they fail with "camera in use", not  
   with a slower stream. Running `camerawesome` alongside would not work.
5. **The two shipped `.glb` assets, unchanged.** The maintained Flutter AR  
   packages render through Sceneform, which would mean re-authoring both models  
   and maintaining a second model pipeline.

`ar_flutter_plugin_plus` and its forks satisfy 1–3 but not 4 or 5;  
`arcore_flutter_plus` likewise. `com.google.ar:core:1.57.0` (Google Maven) is the  
only dependency added.

**Camera preview.** ARCore writes the camera image into an external OES texture,  
which the host draws — together with the anchored mesh — into an EGL window  
surface backed by a Flutter `SurfaceTexture`. Flutter renders it with a plain  
`Texture(textureId:)` widget. One texture, two draw calls, no `platform_view`  
compositing.

---

## 4. The station reference pose

`CaptureStation` stores the AR camera pose **at the instant "Calibrate station"  
was pressed**, and nothing else changes it:

```
referencePosition    : AR world metres
referenceOrientation : a unit quaternion in this project's convention
createdAt, trackingStatus, capturedCount / total
```

`StationFrame` wraps it and is the only thing the rest of the module talks to.  
`T_world_station` is the station pose; the phone's changing pose is  
`T_world_camera`; `StationFrame.cameraInStation` computes

```
T_station_camera = inverse(T_world_station) × T_world_camera
                 = (R_stationᵀ · R_camera ,  worldPointToLocal(cameraPosition))
```

Calibration is refused unless AR is reporting `TRACKING` — a pose captured while  
paused would silently mis-orient all 26 targets.

**Stated limitation:** ARCore's world origin is arbitrary and is re-chosen when a  
session restarts. A station recorded today cannot be walked back to tomorrow  
unless persistent world mapping (a Cloud Anchor or a Geospatial pose) is  
implemented, and it has not been. This is recorded on `CaptureStation` and in  
every `CaptureRecord`.

---

## 5. Anchors and GLB positioning

For the selected target:

1. `worldDirection = stationFrame.localToWorld(spec.direction)`, normalised.
2. `raycast(origin: stationFrame.origin, direction: worldDirection, maxDistanceM: 4.0)`.
3. **No hit → no anchor.** `anchorTarget` returns `null`, the UI shows  
   *"Scan this surface"*, the shutter stays disabled, and no anchor is created.  
   There is no fallback that places the marker at the end of the ray and calls it a  
   surface — a marker floating in mid-air that the guidance reports as a wall is  
   worse than no marker.
4. Hit → `createAnchor` at the hit pose, **attached to the plane** that was hit  
   (`trackable.createAnchor(pose)`), so it is refined as ARCore maps more of the  
   room.
5. The marker's face direction is the surface normal, **flipped if it points away  
   from the station**, so the plate is always visible from the station.
6. `facingRotation(normal)` — the rotation taking the model's own `+Z` onto that  
   normal — is computed in Dart, not Kotlin, so it is unit-tested.
7. Only the active target is in the scene. All 26 are shown in the spherical  
   overview, which is a pure Flutter widget and costs nothing on the AR thread.

**How the GLB is drawn.** `GlbMeshSource` parses the shipped assets with the  
project's existing `parseGlb` and flattens them into `Float32List` positions and  
colours; the host uploads them once per session via `setMesh` and draws them with  
`projection × view × anchorPose × localRotation × scale`. The **anchor pose is  
ARCore's, re-read every frame** — the marker drifts with the room rather than being  
recomputed from screen coordinates. `ar_capture_target.glb` supplies the plate and  
centre square (its check-mark meshes are excluded, as in the prototype);  
`white_frame_bezel.glb` supplies the bezel, recessed 20 mm along the plate's normal  
because the two assets are authored in the same plane and would otherwise z-fight.

Kotlin contains **no glTF loader**: one model pipeline, one set of unit tests.

---

## 6. Alignment calculation and coordinate conventions

### The three frames

1. **ARCore world** — right-handed, `+Y` roughly up, metres.
2. **The project's quaternion convention** — `q·ẑ` is the optical axis, `q·ŷ` up.  
   The AR→app conversion is `arCameraPoseToCaptureWorld`, the project's existing  
   single adapter, applied in exactly one place (`ArPose.captureWorld`).
3. **Station-local** — the frame Section 1 §6 asks for: **`+X` right, `+Y` up,  
   `+Z` forward, positive yaw turns right, positive pitch looks up.**

### Why station-local is left-handed, deliberately

A rotation's image `(q·x̂, q·ŷ, q·ẑ)` satisfies `right × up == forward`. A physical  
camera satisfies `right × up == −forward`. No rotation can do both — which is why  
OpenGL, ARCore and ARKit all put the optical axis on `−Z`. If station-local `+X`  
were `q·x̂`, then "yaw +90°" would point to the user's **left** while the number said  
right: a sign error that is invisible until someone follows an instruction and turns  
the wrong way.


`StationFrame` therefore takes `+X` from the *physical* right, `−q·x̂`. The mirror  
lives in exactly two functions, `localToWorld` and `worldToLocal`, which are  
inverses of each other and are unit-tested as such.

### The calculation

```
D_world = targetWorldPosition − cameraWorldPosition
d       = normalize(D_world)
D_cam   = (x, y, z) = (right, up, forward) of d in the camera's own frame

yawCorrection   = atan2(x, z)                     positive → turn right
pitchCorrection = atan2(y, √(x² + z²))            positive → tilt up
angularError    = acos(clamp(forward · d, −1, 1))
```

`D_cam` is `Quat.toCameraFrame`, which already returns `(right, up, forward)` —  
the handedness argument above is why it negates the `x` component.

`targetWorldPosition` is the **anchor's** world position, not the point at the end  
of the theoretical ray. `atan2` is wrapped by construction, so `+179°` and `−179°`  
give a 2° correction, not 358°; `AlignmentCalculator.shortestAngleDeg` is exposed for  
the cases that compare two angles.

**Zenith and nadir.** Yaw is undefined there, so the wording suppresses the  
horizontal component and the 3-D error alone decides readiness. The poles still  
report `angularError`, which is the quantity the gate uses everywhere.

### The required validation case

Target at yaw 0 / pitch 0, phone turned 20° to the left (station-local yaw −20°):

| Quantity             | Value              |
| -------------------- | ------------------ |
| `yawCorrectionDeg`   | `+20.0`            |
| `pitchCorrectionDeg` | `0.0`              |
| `angularErrorDeg`    | `20.0`             |
| `instruction`        | `"Turn right 20°"` |

Asserted in `test/alignment_test.dart`. The target does not move when the phone  
turns: the camera pose changes and the correction changes with it.

### Alignment tolerance and stability

Readiness requires **all** of: AR tracking valid; station calibrated; the active  
target anchored; `angularErrorDeg ≤ toleranceDeg` (default 3°); the pose steady for  
the whole stability window (default 500 ms); and no photograph already being saved  
for that target. Moving outside tolerance returns the state to not-ready.

`StabilityMonitor` requires two things at once: the alignment stayed inside  
tolerance, **and** the pose itself did not move (orientation within 1.5°, position  
within 0.03 m of the oldest sample in the window). The second condition is what  
stops a phone swinging through the target at speed from firing.

Both are `CaptureGeometryConfig` fields, documented as development parameters to be  
validated on hardware, not universal thresholds.

---

## 7. How photographs are captured and saved

`frame.acquireCameraImage()` → a `YUV_420_888` `Image` → `YuvJpegEncoder` →  
JPEG bytes.

- **It is a real camera frame of the room.** The image comes from the AR session's  
  camera, not from the Flutter widget tree.
- **It contains none of the app.** No GLB marker, no alignment overlay, no UI —  
  none of that exists in the camera image. It is never a screenshot.
- **The rotation is measured, not assumed.** The encoder takes the direction, in  
  display coordinates, that the image's own `+x` axis points along, read from  
  ARCore's own `transformCoordinates2d(IMAGE_PIXELS → VIEW)`. That makes a 0/90/180/  
  270° sensor, or an unusual mounting, a measured input. The rotation is applied on  
  the raw planes, so there is a single JPEG encode and no intermediate `Bitmap`.

Order of operations, enforced in `PhotoCaptureService.capture`:

```
takeStill → size sanity floor → write → verify exists → verify length → read back
          → build CaptureRecord → save record
```

The caller marks the target captured **only after** this returns. A failure at any  
step leaves the target retryable and the previous photograph untouched. A target is  
never marked captured on the strength of a request.

Storage, under the app's private documents directory:

```
<appDocs>/ar_capture/<stationId>/
  station.json     the calibrated reference pose
  targets.json     the 26 targets, with anchor + status
  records.json     one entry per saved photograph
  frames/t01.jpg … t26.jpg
```

`CaptureRecord` carries the image path, timestamp, target yaw/pitch, the camera pose  
at capture, the alignment error, anchor status and surface type, image dimensions,  
format, rotation applied and the tolerance in force.

**Resolution is recorded per photograph, not asserted once.** ARCore's CPU image  
size is the session's camera-config image size — typically 640×480 to 1920×1080  
depending on the device and the config ARCore chose. This is **not** a full-sensor  
still and is not claimed to be; every record states what it actually got.

---

## 8. Verification results

| Check                       | Result                                                    |
| --------------------------- | --------------------------------------------------------- |
| `flutter pub get`           | resolved, no changes needed                               |
| `dart format lib test`      | applied                                                   |
| `flutter analyze`           | **No issues found**                                       |
| `flutter test`              | **58 tests pass**                                         |
| `flutter build apk --debug` | **built** — `build/app/outputs/flutter-apk/app-debug.apk` |

### What the tests cover

All twelve cases Section 1 §16 requires, plus the geometry:

1. yaw 0 / pitch 0 → forward `(0, 0, 1)`
2. the 26 targets, ids 1–26, ring pitches ±45/0, the specified yaw set, unit length,  
   the §7 formula, and a minimum angular separation of 31.4° (45° of yaw on a 45°  
   ring)
3. phone 20° left of a straight-ahead target → `+20°` / *"Turn right 20°"*
4. target to the right → right turn; to the left → left turn
5. target above → `+30°` *"Tilt up"*; below → *"Tilt down"*
6. `+179° ↔ −179°` → 2°, and every correction is inside `(−180, 180]`
7. moving the phone changes the direction to an anchored target (1 m sideways on a  
   3 m wall → `−atan(1/3)`); the distance is recomputed from the new position
8. rotating the phone changes the alignment while the station pose is unchanged
9. invalid tracking prevents capture — no still is requested, nothing is marked done
10. a missed raycast creates **no** anchor, pushes **no** scene, and cannot capture
11. a failed save (no image / not a photograph / record write failure) never marks  
    the target captured; the retry succeeds
12. a successful save updates only its own target and station; a second capture adds  
    a second record and leaves the first alone; `retake` clears one target only

Also: `StationFrame` round-trips, station-local `+X` is the physical right  
(`right × up == −forward`), `cameraInStation` is the documented inverse transform,  
`headingOf` reports a positive yaw as a heading to the right, `facingRotation` for  
walls/floors/ceilings and the anti-parallel case, and the stability gate including  
"a slow pan never becomes stable".

### Two defects found and fixed by the tests

- `StabilityMonitor` pruned with `removeWhere(at.isBefore(cutoff))`, which deletes  
  exactly the sample that proves the window elapsed — `heldFor` could never reach  
  500 ms and the shutter would never fire on its own. Fixed by keeping the newest  
  sample at or before the cutoff.
- `ArGlRenderer.buildModelMatrix` aliased `Matrix.multiplyMM`'s result with its  
  input. Fixed by reading the anchor matrix from Dart's own array.

### One pre-existing issue, scoped rather than hidden

`tool/verify_*.dart` are standalone verification harnesses that import a  
`test/*_checks.dart` family of files **which is not present in this workspace**, so  
they cannot resolve their imports and produced 39 permanent analyzer errors.  
`analysis_options.yaml` now excludes `tool/**` with that reason written inline. This  
is an exclusion, not a fix: the harnesses remain unrunnable here. The capture  
module's own coverage lives in `test/`, which is in the workspace and does run.

---

## 9. Hardware and platform limitations

**Build-verified (no device needed):** the module compiles, the Kotlin host  
compiles and links against ARCore 1.57.0, the APK is produced, all Dart logic is  
covered by 58 passing tests.

**Requires a physical ARCore-capable Android device — not yet verified:**

1. **Anchors stay fixed in the room** while the phone moves. No simulator or mock  
   can prove this.
2. **Plane detection quality** in a real commercial unit — how quickly walls, floor  
   and ceiling are found, and whether the 4 m ray length reaches a surface in a  
   large open-plan space.
3. **The still's actual resolution and sharpness.** ARCore's CPU image size and  
   JPEG quality need measuring against what a stitching step will need.
4. **The JPEG rotation quarter-turn.** It is derived from ARCore's own transform, but  
   the *sign* convention can only be confirmed by looking at a photograph. If a  
   device disagrees, `imageAxisXInView` is the single value to correct, and it is  
   reported in every record.
5. **The 3° tolerance and 500 ms window** on real hands.
6. **`CameraConfig` selection.** The host does not call `setCameraConfig`, so ARCore  
   picks the config. Selecting the highest-resolution config that still supports a  
   CPU image is the obvious next step if stills prove too small.

**iOS is not implemented.** There is no ARKit host and the module does not claim  
one. `ArSessionService.probe()` detects the missing host (`MissingPluginException`)  
and the screen reports *"This build has no ARCore host. AR capture needs Android."*  
rather than degrading silently. The Dart layer is platform-neutral — the 26-target  
sphere, the station frame, the alignment calculator and the stability gate are pure  
Dart — so an ARKit host implementing the same `ArCoreGateway`-shaped contract would  
be additive.

**Not implemented, by design:** panorama stitching and the panorama viewer.

---

## 10. Device test checklist

1. Install `app-debug.apk` on a device with Google Play services for AR.
2. Launch → **AR capture**. Confirm the camera feed appears and the tracking banner  
   clears within a few seconds.
3. Move the phone slowly until *"Move the phone slowly…"* is replaced by plane  
   counts; confirm walls, floor and ceiling are all detected.
4. Press **Calibrate station** while tracking. Confirm target 1 becomes active.
5. Confirm the GLB marker appears **on a real surface**, stays fixed when the phone  
   is rotated, and does not follow the camera like a HUD.
6. Turn the phone and confirm the arrow and the wording agree: the arrow points the  
   way you must turn, and *"Turn right N°"* counts down as you turn right.
7. Hold still and confirm *"Hold still…"* → *"Ready to capture"* → an automatic  
   capture, and that a target that is aimed at but still moving does **not** fire.
8. Open a saved `tNN.jpg` and confirm it is upright, is a photograph of the room, and  
   contains no marker or overlay.
9. Point at a blank wall until the ray misses and confirm *"Scan this surface"* with  
   the shutter disabled.
10. Background the app mid-station and confirm the camera is released; return and  
    confirm it restarts.
11. Press **Retake** on a captured target and confirm only that target resets.

