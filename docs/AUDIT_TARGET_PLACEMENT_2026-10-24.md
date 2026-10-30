# Read-only audit — AR target placement, tracking, and renderer

**Date:** 2026-10-24
**Scope:** the 360° capture module (Flutter `features/capture` + native Kotlin `ar/`), with the guided-flow overlay (`features/virtual_tour`) audited only where it can be confused with the capture path.
**Mode:** read-only. No source file was modified, no dependency was added, and no device test was run. This document is the Phase 1 deliverable; implementation starts only after approval.

---

## 0. Executive summary

The transform mathematics of the native capture path is correct. The station frame is self-consistent (including the handedness mirror), the 26 directions are computed once, the 26 world anchors are created once at calibration, and the renderer composes `anchorPose · localRotation · translation · scale` with a standard column-major quaternion matrix. The GLB pivot, orientation and scale are also correct. The target does **not** follow the camera in the capture path.

The reported "target moves / floats / is not positioned correctly" is therefore **not caused by a bad projection or a wrong quaternion**. The audit found four concrete defects and three design gaps:

| # | Finding | Severity | Confidence |
|---|---|---|---|
| RC-1 | `resumeStation()` reuses saved world-space coordinates in a **new ARCore session**, where the world origin is different. Every target is anchored at the wrong physical place. | **P0** | High — deterministic from code; the app itself states the rule it breaks at `capture_controller.dart:1680-1682` |
| RC-2 | Anchors that ARCore reports as `PAUSED` are still drawn, and their frozen pose is still used to compute alignment. ARCore documents that a pose should only be used for rendering while `TRACKING`. | **P0/P1** | High as a contract violation; matches "floats/slides while turning" |
| RC-3 | The per-frame `activeAnchorTracking` value is emitted by Kotlin but ignored by Dart. The app's anchor-tracking state can be up to 500 ms stale, so the shutter gate and the UI can claim "anchored" while ARCore says paused. | **P1** | High — deterministic |
| RC-4 | No depth occlusion, and targets sit at a fixed 1.5 m in mid-air with no relation to surfaces. The marker draws through real objects and can look like it floats in front of a wall. | **P1 (perceptual)** | High — renderer has no depth texture |
| RC-5 | The guided-flow target is camera-relative by design (`markerCentre = camera.position + direction · 1 m`). If the user judged "the target follows the phone" in **Guided flow**, that is expected there and is not evidence about the capture path. | Design difference | High |
| RC-6 | Display rotation is not wired: portrait-up and portrait-down are both allowed, but `setDisplayRotation`/`resize` are not called after boot. | P2 | High |
| RC-7 | The state model is derived (`starting → scanning → capturing`), with no explicit `attemptingRecovery` or `recalibrationRequired` state. Requirement B is only partially visible in the UI. | P2 | High |

**SceneView + Filament decision: do not migrate now.** The current Flutter view is a `Texture` fed by an app-owned EGL surface; SceneView's `ArSceneView` is a View/Compose component that owns its own surface and session, and integrating it would replace the texture path with a PlatformView and duplicate session ownership. The current SceneView release also requires a newer toolchain (AGP 9.4+, Kotlin 2.4, JVM 21) than this project (AGP 9.0.1, Kotlin 2.3.20, JVM 17). It would not fix RC-1/2/3, and it does not add depth occlusion by itself. Depth occlusion is achievable in the existing GLES renderer with a bounded ES 3.0 + depth-texture change.

**One thing this audit cannot do:** prove physical ARCore accuracy. Every device-level claim below is a checklist item, not a result.

**Test baseline (read-only run, 2026-10-24):** `flutter test` reports **297 passed, 8 failed**. All 8 failures are stale fixtures describing behaviour the code intentionally changed in earlier rounds (completed-target hiding, re-aim-before-retry, no re-place on paused anchors, `CaptureState.tracking` defaulting to `initialising`). Details and evidence are in §8.1. No production code was changed to make them pass, and no test was edited.

---

## 1. System map — two AR paths that must not be conflated

### 1.1 Capture path (the 26-target 360° workflow)

Entry: launcher "AR capture" → `CaptureModuleScreen` → `ArCaptureScreen` (`lib/main.dart:82-105`).

```
Flutter CaptureController
  ├─ ArSessionService ── MethodChannel/EventChannel ── ArCoreCapturePlugin
  │                                                     └─ ArCoreSessionController
  │                                                          ├─ ARCore Session (owns camera)
  │                                                          ├─ EGL14 + GLES2 renderer
  │                                                          └─ SurfaceTexture → Flutter Texture
  ├─ PlaneAnchorService  → 26 world anchors (created once at calibration)
  ├─ PhotoCaptureService → ARCore CPU image → JPEG → station.json/records.json
  └─ AlignmentCalculator + StabilityMonitor + StationFrame
```

* ARCore session is created in `ArCoreSessionController.start()` (`android/.../ar/ArCoreSessionController.kt:177`).
* Rendering is a custom GLES 2.0 renderer into an EGL window surface backed by a `SurfaceTexture`; Flutter displays it with `Texture(textureId: ...)` (`ar_capture_screen.dart:222`).
* Targets are world-space anchors at station-relative positions; the renderer reads `anchor.pose` every frame (`ArCoreSessionController.kt:662-689`).
* There is **no SceneView, no Filament, no ARCore Depth API** in this path (`android/app/build.gradle.kts:43-49`, `ArCoreSessionController.kt:1042-1044`).

### 1.2 Guided-flow path (the tour overlay)

Entry: launcher "Guided flow". The GLB marker is projected in pure Dart at a fixed distance along the camera's aim ray:

```dart
// lib/features/virtual_tour/platform/glb/glb_target_scene.dart:221-227
Vec3 markerCentre(GlbCamera camera, {double? distanceM}) =>
    camera.position +
    camera.pixelDirection(_screenX, _screenY) * (distanceM ?? _distanceM);
```

This is deliberately camera-relative (a screen-pinned guidance overlay), and it does have a separate station anchor used only for drift (`capture_flow_engine.dart:589-710`). **It is not the 26-target capture path.** Any bug report saying "the target follows the phone" must be attributed to one path or the other before changing code.

---

## 2. Audit findings, point by point

### 2.1 ARCore session creation, configuration, frame updates

* `start()` creates a new `Session`, configures `BLOCKING` update mode, plane finding, autofocus with a fixed fallback, and sets the camera texture name (`ArCoreSessionController.kt:148-225`).
* `stop()` closes the session, clears anchors and meshes, and releases EGL (`:227-246`). The plugin then sets `controller = null` (`ArCoreCapturePlugin.kt:166-177`).
* A new `Session` means a **new ARCore world origin**. The world origin is session-scoped; it is not persisted by this app.
* Depth is left at default and reported as unsupported (`capabilitiesMap()` `:1037-1044`). Nothing reads depth.

**Verdict:** session lifecycle is sound; it is the *consumer* of saved coordinates that ignores the new-origin consequence (RC-1).

### 2.2 Camera pose and tracking-state handling

* Per frame: `Session.update()`, `camera.pose`, `camera.trackingState`, `camera.trackingFailureReason`, timestamps, plane counts, and intrinsics are emitted (`ArCoreSessionController.kt:772-877`).
* The current active anchor's pose and tracking state are emitted on the same event (`:793-806`).
* Dart parses them into `ArPoseSample.activeAnchorPose` (`arcore_ar.dart:756-814, 839-847`).
* **The capture controller ignores `activeAnchorPose.tracking`.** It uses only `activeAnchorPose.position` (`capture_controller.dart:1367-1368`) and updates `activeAnchorTracking` only at selection/recovery and at a 2 Hz refresh (`:776, :878, :1548-1596`).

**Verdict:** camera tracking is handled correctly. Anchor tracking is delivered but not consumed per frame (RC-2/RC-3).

### 2.3 Station origin and yaw calibration

* `captureReferenceFromPose()` creates a gravity-aligned basis from the camera forward projected onto the horizontal plane; it refuses a pose within 10° of vertical (`station_frame.dart:185-...`).
* `StationFrame.localToWorld()` mirrors x (`orientation.rotate(Vec3(-x, y, z))`) so station-local +X (right) survives the camera handedness (`:123-134`); `worldToLocal()` is the exact inverse.
* The station is frozen after calibration; camera motion does not change it.

**Verdict:** correct and self-consistent. No action.

### 2.4 The 26 target directions

* `buildCaptureSphere()` builds 8 middle (front first), 8 upper (+45°), 8 lower (−45°), zenith and nadir = 26 (`target_sphere.dart:128-190`).
* Yaws are the §7 order `[0, 45, 90, 135, 180, −135, −90, −45]`; directions come from `directionFromYawPitch` (`:147`).
* `resolveTarget()` is the single placement authority: `worldPosition = station.origin + worldDirection · radiusM`, facing `−worldDirection` (`target_sphere.dart:378-392`).
* Radius is 1.5 m (`CaptureGeometryConfig.targetRadiusM`, `:337`).

**Verdict:** correct and unchanged. No action. The brief's constraint "do not change the 26 directions" is satisfied by the current code.

### 2.5 GLB loading, placement, rotation, scale, rendering

* Both GLBs are parsed in pure Dart (`glb_mesh_source.dart`); node transforms are baked into vertex positions.
* The shipped assets have **identity node transforms**, no normals, no UVs, no vertex colours; colours come from material `baseColorFactor` (`test/glb_pipeline_test.dart`).
* Composition in `PlaneAnchorService.pushScene()`:
  * world anchor at `resolveTarget().worldPosition` (`plane_anchor_service.dart:179-205`);
  * target draw at the anchor origin with `localRotation` that maps +Z to the facing normal;
  * bezel draw offset by `−bezelSetbackM` (6 mm) so the two front faces are flush (`:325-350`);
  * scale = `0.22 / 0.54 ≈ 0.407`, applied to both (`markerScaleFor`).
* Native model matrix: `M = anchorMatrix · R(localRotation) · T(offset) · S(scale)` (`ArGlRenderer.kt:242-250`); quaternion → matrix is standard column-major (`:368-401`).
* GLB pivot: plate/bezel centre x/y = 0; z spans 0…0.006 m (plate) and 0…0.012 m (bezel); the 6 mm offset makes the fronts coplanar. There is no visible pivot error.
* Anchors are created once and are idempotent by target id (`plane_anchor_service.dart:172-205`); selecting a target only changes highlight (`capture_controller.dart:690-793`).

**Verdict:** correct. No pivot/orientation/scale defect. No anchor duplication or per-frame re-creation.

### 2.6 Anchor creation, attachment, updates, lifecycle

* All 26 are `createAnchor(position: worldPosition, orientation: identity, trackableKey: null)` — pure world anchors, not plane attachments (`plane_anchor_service.dart:179-185`).
* The renderer reads `anchor.pose` each frame and draws if `requireTracking` is false **or** the anchor is `TRACKING` (`ArCoreSessionController.kt:662-689`).
* `pushScene()` passes `requireTracking: false` for both the bezel and target (`:339, :349`).
* The class doc says a paused anchor "draws nothing at all" and cites the ARCore contract (`plane_anchor_service.dart:78-86`). That is **stale**: the code draws it.

**Verdict:** RC-2. The world position is fixed; the *pose used for rendering* may not be trustworthy while the anchor is paused.

### 2.7 Quaternion conversion and coordinate transforms

* Quaternion → column-major matrix is standard (`ArGlRenderer.kt:368-401`).
* `StationFrame` mirror and its inverse are consistent.
* `facingRotation` maps +Z to the facing normal and handles the antiparallel case (`target_sphere.dart:411-422`).
* `AlignmentCalculator` yaw/pitch/error uses `atan2(x, z)`, `atan2(y, hypot(x,z))`, `acos(dot)` (`alignment_calculator.dart`).
* Projection `u = W/2 + fx·x/z`, `v = H/2 − fy·y/z` (`projection.dart`), and the arrow painter now uses it.

**Verdict:** correct. No handedness or multiplication-order defect found.

### 2.8 Alignment and capture readiness

* Raw alignment is authoritative; only the display arrow is smoothed (`capture_controller.dart:1369-1385`).
* Stability monitor: 450 ms window, 3° tolerance with 2° hysteresis, 1.5° orientation drift, 0.03 m position drift, 5°/s, 250 ms freshness (`target_sphere.dart:336-354`).
* Readiness is `captureBlockReason == null`; the gate includes tracking, station, target, not done, not capturing, not drifted, `activeAnchored`, `activeAnchorTracking`, alignment, tolerance and stability (`capture_state.dart:319-...`).
* **`placementIsActive` requires camera tracking but not anchor tracking** (`capture_controller.dart:1354-1359`), so alignment is computed from a paused anchor's pose whenever camera tracking is fine.

**Verdict:** the gate is conservative except for the anchor-pose issue (RC-2/RC-3). No threshold change is proposed by this audit.

### 2.9 Tracking loss and recovery

* Camera tracking loss clears alignment/stability and blocks capture (`capture_controller.dart:1252-1300`).
* Station drift is held while not tracking; `stationDrifted` warns at 0.6 m.
* `_refreshAnchorIfDue()` runs at 2 Hz; `gone` triggers a bounded re-placement (max 2); repeated failure sets `_anchorGiveUp` and tells the user to map more/scan again (`:1501-1602`).
* Backgrounding: `onAppPaused()` stops the session; `onAppResumed()` boots again. If `reused` is true it restores the station; otherwise it discards the station and asks for recalibration (`:1646-1696`). Because `stop()` nulls the controller, a background/foreground cycle normally produces a **new** session, so the discard path is the norm.

**Verdict:** tracking recovery is mostly honest. But `resumeStation()` bypasses this rule (RC-1), and there is no explicit `attemptingRecovery`/`recalibrationRequired` state (RC-7).

### 2.10 Flutter ↔ Kotlin communication

* MethodChannel `adaptive360/arcore`, EventChannel `adaptive360/arcore/events` (`ArCoreCapturePlugin.kt`).
* Methods: availability, start, stop, resize, setDisplayRotation, plane detection, setMesh, setScene, probeDirections, raycast, createAnchor, refreshAnchor, detachAnchor, setActiveAnchor, rescan, takeStill.
* Pose events carry `apx/apy/apz` and `activeAnchorTracking` (`ArCoreSessionController.kt:793-806`).
* Nothing is hardcoded as "tracking OK"; the state comes from ARCore.

**Verdict:** the channel is adequate. The gap is on the Dart side (ignoring a field that is already sent).

### 2.11 Image capture, validation, saving, persistence

* `takeStill` → ARCore CPU image → YUV→JPEG (upright using the measured image axis) → write → verify size → record (`photo_capture_service.dart`).
* Timeouts: still 6 s, save 10 s; failures are retryable and carry a stage.
* Storage: `<appDocs>/ar_capture/<stationId>/station.json`, `targets.json`, `records.json`, `frames/tNN.jpg` (`capture_repository_impl.dart`).
* This pipeline is independent of target placement.

**Verdict:** no placement defect. Preserve unchanged except for tests around a paused anchor.

### 2.12 Renderer technology and ARCore

* GLES 2.0, EGL 14; depth buffer 16-bit; camera drawn as a full-screen OES-texture quad; meshes drawn with `MVP`, per-vertex colour, tint, opacity.
* Depth test exists **between meshes** only (`ArGlRenderer.kt:176-215`). The camera quad does not write depth, and there is no depth texture sampling.
* Shaders: camera `samplerExternalOES`; mesh fragment outputs `base.rgb, base.a * u_Opacity` (`:318-359`). No occlusion.

**Verdict:** RC-4. The renderer is correct for what it does; it cannot occlude against the real world.

---

## 3. Target lifecycle trace (capture path)

1. **Boot.** Probe ARCore → start session → upload GLB meshes → subscribe to pose events (`capture_controller.dart:267-326`).
2. **Calibrate.** A tracked, non-vertical camera pose creates a `StationFrame`; 26 `CaptureTargetSpec`s are saved; `resolveTarget()` computes 26 world positions; `placeAll()` creates 26 world anchors once; the first target is selected (`:384-510`).
3. **Draw.** `pushScene()` sends `ArSceneDraw`s (bezel + target) with `requireTracking:false`; native `buildDraws()` reads `anchor.pose` each frame and multiplies by the local rotation/offset/scale (`ArCoreSessionController.kt:662-689`, `ArGlRenderer.kt:242-250`).
4. **Aim.** Each pose event reads the active anchor's live position and computes alignment; the display arrow uses a smoothed pose, the gate uses the raw pose (`capture_controller.dart:1367-1414`).
5. **Gate.** `captureBlockReason` requires tracking, station, target, not done, not saving, no drift, anchored, anchor tracking, tolerance and stability (`capture_state.dart:319-...`).
6. **Capture.** Button or auto-shutter → `takeStill` → JPEG → verify → record → advance to the next pending target (`capture_controller.dart`, `photo_capture_service.dart`).
7. **Resume.** `resumeStation()` loads `station.json`/`targets.json`/`records.json` and **re-anchors at the saved world positions** (`:525-604`).

Steps 2–6 are world-fixed and do not recompute from the camera. Step 7 is the break: it treats a coordinate from a previous ARCore world as if it still meant the same physical point.

---

## 4. Root-cause report

### RC-1 (P0) — Cross-session resume places all 26 targets in a stale world frame

**Evidence**

* `resumeStation()` reconstructs `StationFrame(origin: station.referencePosition, orientation: station.referenceOrientation)` from disk (`capture_controller.dart:534-537`), then calls `placeAll()` at those coordinates (`:575-580`).
* The comment at `:575` says "the map is empty in a fresh session, so this creates exactly one node per target" — it notices the fresh session but assumes the coordinates are still valid.
* `boot()` always starts a session and stores `session.reused` (`:309-310`); a cold launch always creates a new `Session` (`ArCoreSessionController.kt:177`). `ArCoreCapturePlugin.stop` disposes the controller and sets it to null (`:166-177`), so even a background/foreground cycle produces a new session.
* The controller already knows the rule: `onAppResumed()` says "A new session means a new world origin. Keeping the old station would aim every one of the 26 targets at the wrong place" (`:1680-1682`) — then discards the station. `resumeStation()` does the opposite.
* `resumableStationId` is offered whenever any saved station exists (`capture_controller.dart:243-244`), and the button is shown under "Calibrate station" (`ar_capture_screen.dart:618-628`), with no check of `_lastSessionReused`.

**Effect.** After a relaunch (or after backgrounding), tapping "Resume last capture" anchors targets at arbitrary positions in the new world frame. The 26 markers can appear scattered, at different apparent sizes, and the station drift can read metres. This is a deterministic "target is not positioned correctly in the real environment" cause, independent of tracking quality.

**Not proven for the reported session.** No logcat export was supplied with this audit, so it is not possible to say the user tapped Resume. It is, however, the only code path that intentionally reuses world coordinates across sessions, and it must be fixed regardless.

**Fix direction (not implemented).** Do not reuse a saved world frame across sessions. Options, in order of preference:
1. Guard `resumeStation()` with `_lastSessionReused` and, when false, disable it and offer "Recalibrate and continue" — calibrate a new station at the current pose, mark targets that have records as done, and continue from the first pending target. This preserves progress and photographs without pretending the old world frame survived.
2. If the product requires true cross-session persistence, that is a different feature (ARCore Cloud Anchors or Geospatial), out of scope for this brief.

### RC-2 (P0/P1) — Paused anchor poses are rendered and used as authoritative

**Evidence**

* `pushScene()` sets `requireTracking: false` for both draws (`plane_anchor_service.dart:339, :349`).
* `buildDraws()` therefore draws every anchor, tracked or not, from `anchor.pose` (`ArCoreSessionController.kt:667-669`).
* `alignment` is computed from `pose.activeAnchorPose.position` whenever camera tracking is OK (`capture_controller.dart:1354-1368`), without checking `activeAnchorPose.tracking`.
* The ARCore contract is quoted in the service's own doc: a pose should only be used for rendering while `TRACKING` (`plane_anchor_service.dart:78-86`). The doc is now contradicted by the code.

**Effect.** When ARCore pauses an anchor (fast turn, featureless wall, partial occlusion), the app keeps drawing its frozen pose while the camera's own world pose may be refined. The marker can appear to slide or lag relative to the real environment — the exact "floats when I rotate" symptom. The guidance can also aim at a marker ARCore says is not currently tracked.

**Why `false` was chosen.** An earlier defect re-placed paused anchors and eventually gave up, making the marker vanish permanently. The fix was to stop re-placing on pause. That part is correct; `requireTracking:false` was an over-correction. Hiding the marker on every pause would reintroduce the UX complaint; drawing it as a **ghost** (frozen last pose, visibly dimmed, never authoritative) preserves continuity without lying.

**Fix direction.** Keep rendering the frozen pose only as an explicitly non-authoritative ghost; set `activeAnchorTracking` from the per-frame event; when it is not `TRACKING`, stop feeding alignment and the shutter from `anchor.pose` (use the immutable `placement.worldPosition` or clear alignment, and show "waiting for AR to re-track the target").

### RC-3 (P1) — Anchor-tracking state is stale by up to 500 ms

**Evidence**

* Kotlin emits `activeAnchorTracking` on every pose (`ArCoreSessionController.kt:793-806`).
* Dart parses it (`arcore_ar.dart:780-790, 839-847`).
* `_onPose()` never copies it. It only reads `activeAnchorPose.position` (`capture_controller.dart:1367`).
* `activeAnchorTracking` is updated at selection (`:776`), after re-placement (`:878`), and in the 2 Hz refresh (`:1548-1596`).

**Effect.** The UI and `readyToCapture` can read `true` for up to half a second after ARCore paused the anchor; conversely they can read `false` after it resumed. The shutter gate is therefore not a real-time reflection of ARCore.

**Fix direction.** One line in `_onPose()`, before `placementIsActive`: set `activeAnchorTracking` from `pose.activeAnchorPose?.tracking == TrackingState.tracking`; keep `activeAnchored` as "the placement exists". The 2 Hz refresh remains for `gone` detection only.

### RC-4 (P1, perceptual) — No depth occlusion and no surface relationship

**Evidence**

* No depth mode is configured (`ArCoreSessionController.kt:179-183`); capabilities hardcode `"depth" to false` (`:1042-1044`).
* EGL requests OpenGL ES 2.0 and a 16-bit depth buffer (`:1049-1077`); that buffer holds virtual geometry only.
* Camera quad is drawn with depth test disabled; mesh shader only applies colour/tint/opacity; no depth texture is sampled (`ArGlRenderer.kt:176-215, 318-359`).
* Targets are anchored at 1.5 m in mid-air with `trackableKey: null`; no plane association.

**Effect.** A marker behind a real chair, table edge or person still draws on top of it. Perceptually it "floats" even when its world position is fixed. This is a renderer/design gap, not a transform error.

**Fix direction.** Phase 3 below: ARCore Depth API + depth texture + shader comparison, gated by device support, with the current rendering as fallback.

### RC-5 (design difference) — Guided flow is camera-relative

`GlbTargetScene.markerCentre` is `camera.position + pixelDirection · distance` (`glb_target_scene.dart:221-227`). That is correct for a screen-pinned guidance overlay and **wrong** as a world target. It is not used by `features/capture`. Any symptom report must state which entry was used.

### RC-6 (P2) — Display rotation is unwired

* `main.dart:24-26` allows `portraitUp` **and** `portraitDown`.
* `ArCaptureScreen` handles lifecycle but has no `didChangeMetrics`; it never calls `resize` or `setDisplayRotation` after boot (`ar_capture_screen.dart:97-124`).
* Native `setDisplayRotation()` only sets a pending flag (`ArCoreSessionController.kt:278-283`) and is called at start; a 180° flip changes the display orientation without telling ARCore.

**Effect.** A 180° flip can leave the camera feed and projection rotated relative to the display, and saved photographs may be upside down on such a device. Latent on most portrait use, but real on foldables/tablets and on any app that permits portrait-down.

**Fix direction.** Either lock to `portraitUp` only, or add a `didChangeMetrics` handler that sends `resize` and `setDisplayRotation` and recomputes intrinsics. The latter is the correct fix; the former is the smallest safe one.

### RC-7 (P2) — State model is derived, not explicit

`CapturePhase` has only `idle/checking/unavailable/starting/scanning/capturing/complete/failed` (`capture_state.dart:11-35`). "Tracking temporarily lost", "Attempting recovery" and "Recalibration required" exist only as messages/block reasons. Requirement B asks for these as states. The UI does reflect the underlying values (tracking, failure reason, drift, anchor state), but not as a single, testable state machine.

**Fix direction.** Add a derived `CaptureRecoveryState` enum computed from existing fields; do not add new sensor logic. Map it to the status chip/instruction. Keep the existing `CapturePhase` for lifecycle.

### 4.1 Non-causes verified and cleared

These were checked and found correct; do not change them while fixing the above:

* Station basis, x-mirror, `localToWorld`/`worldToLocal` inverse.
* 26 directions and `resolveTarget` as the single authority.
* Anchor creation once, idempotent, no per-frame position updates.
* GLB pivot (centre x/y = 0), identity node transforms, scale 0.407, flush bezel setback.
* Quaternion → matrix, MVP order, projection and alignment math.
* Capture pipeline and storage layout.
* No duplicate anchors, no camera-relative placement in the capture path.

### 4.2 Documentation that must be corrected

`plane_anchor_service.dart:78-86` says paused anchors draw nothing; the code draws them. `docs/SECTION1_DEVICE_FIX_REPORT.md` still describes a surface/raycast architecture and a 500 ms stability window that no longer match the code. These are stale docs, not runtime defects, but they mislead the next fix.

---

## 5. SceneView + Filament decision

**Decision: keep the existing custom GLES renderer; do not migrate to SceneView + Filament in this task.**

Reasons, in order of weight:

1. **Surface and session ownership.** The Flutter capture view consumes a `Texture` created by `ArCoreSessionController` and rendered into an app-owned EGL window surface. SceneView's `ArSceneView` is an Android View / Compose component with its own rendering surface and, in AR mode, its own ARCore `Session` (`ArCoreSessionController` is the only session owner today). There is no documented SceneView API for rendering into an externally-owned EGL `SurfaceTexture`. Adopting it would mean replacing the `Texture` with a PlatformView and moving session ownership — a rewrite of the native view boundary, not the "smallest safe migration" the brief requires.
2. **Toolchain mismatch.** SceneView 4.62.0 (released 2026-10-22) states minSdk 24, AGP 9.4+, Kotlin 2.4 and JVM 21. This project uses AGP 9.0.1, Kotlin 2.3.20 and JVM 17 (`android/settings.gradle.kts:20-24`, `android/app/build.gradle.kts:10-15, 37-41`). Upgrading the whole build for a renderer that does not fix placement is not justified.
3. **It would not fix RC-1/2/3.** Those are station/anchor-state bugs in Dart; a different renderer sees the same `anchor.pose` and the same stale flag.
4. **Depth is not automatic.** Filament does not consume ARCore depth for occlusion unless the app feeds a depth texture/material; SceneView does not remove that work. The existing GLES renderer can implement the same comparison with a much smaller change (Phase 3).
5. **Current renderer is sufficient for this scene.** Two untextured, flat-shaded meshes, ~1 000 triangles, one camera quad, no lighting. Filament's PBR, shadows and scene graph would add cost without addressing the reported symptom.

**When to revisit.** If the product later needs textured/PBR models, lighting, reflections, large scenes, or a unified 3D scene with many nodes, design a PlatformView-backed SceneView screen with SceneView owning the session, and move the capture controller to that surface. That is a separate, planned migration — not a bug fix.

**Verification sources (checked 2026-10-24):** SceneView GitHub repository and releases (v4.62.0), SceneView docs (v4.60.0), Maven artifact `io.github.sceneview`. See §12.

---

## 6. Depth API occlusion — feasibility and blocker

### 6.1 Current blocker

The app cannot occlude today: depth mode is not configured, the capability is hardcoded false, the EGL context is ES 2.0, and the mesh shader has no depth texture. Enabling `Config.DepthMode` alone would not change a pixel.

### 6.2 Minimal implementation (Phase 3, after placement fixes)

1. **Capability.** On session configure, check `session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)`; set `config.depthMode = AUTOMATIC` only when supported. Report the real value in `capabilitiesMap()` instead of hardcoding false.
2. **Context.** Request an ES 3.0 context (`EGL_CONTEXT_CLIENT_VERSION = 3`); existing GLES 2.0 calls remain valid. Keep the 16-bit depth buffer.
3. **Per frame.** After `Session.update()`, `frame.acquireDepthImage16Bits()`; verify the image format (`DEPTH16`), upload the depth plane to a `GL_TEXTURE_2D` with `GL_R16UI` / `GL_RED_INTEGER` / `GL_UNSIGNED_SHORT`, and close the image immediately. Cache the depth UV transform (the same `transformCoordinates2d` mechanism used for camera UVs) so the depth sample aligns with the display.
4. **Shader.** In the mesh fragment shader, compute the fragment's camera-space depth (or reconstruct from `gl_FragCoord.z` with the near/far planes) and compare with the sampled real-world depth; `discard` when the virtual fragment is behind the real surface plus a small bias. Treat depth 0 / invalid as "no data" and do not occlude.
5. **Fallback.** If unsupported or the depth image is unavailable for a frame, draw exactly as today. Never fail the session because depth is missing.
6. **Limits.** ARCore depth is not ground truth: it has a range (roughly 0.2–5 m, device-dependent), holes, and latency. It can occlude a chair edge but will not produce perfect silhouettes. Device verification is mandatory.

**Why not SceneView for this:** the same depth texture + compare work is required in any renderer; doing it in the existing pipeline avoids the migration risks above.

---

## 7. Proposed minimal-change plan (pending approval)

### Phase 0 — Restore a green baseline (test-only, no production change)

| File | Change |
|---|---|
| `test/target_scale_test.dart` | Set `tracking: TrackingState.tracking` in the `stateWith` fixture; keep the assertions. |
| `test/capture_flow_test.dart` | After a failed attempt, break the hold and restore it before retrying; add an assertion that the retry is refused while `retryPending`. |
| `test/target_transition_test.dart` | Expect a completed target to be absent/hidden (opacity 0), not full opacity. |
| `test/world_target_test.dart` | Replace the "paused anchor is re-placed" expectation with "paused anchor is waited on and reported"; keep the existing `gone` re-placement test. |

Run `flutter test` until green, then add the new Phase 1 tests below.

### Phase 1 — Correct world placement (must ship first)

| File | Change | Why |
|---|---|---|
| `lib/features/capture/application/capture_controller.dart` | In `_onPose()`, copy `pose.activeAnchorPose?.tracking` into `activeAnchorTracking` every frame; compute alignment only when the anchor is `TRACKING`; otherwise fall back to the immutable `placement.worldPosition` or clear alignment. | RC-2, RC-3 |
| `lib/features/capture/application/capture_controller.dart` | Guard `resumeStation()` with `_lastSessionReused`; if false, do not create anchors from saved world coordinates. Add "Recalibrate and continue" that calibrates a new station and carries captured flags from records. | RC-1 |
| `lib/features/capture/data/services/plane_anchor_service.dart` | Keep `requireTracking:false` only as an explicit ghost policy: set a non-authoritative tint/opacity for a paused active anchor; correct the stale doc. (Alternative: `requireTracking:true`; choose after device testing.) | RC-2 |
| `lib/features/capture/application/capture_state.dart` | Add a derived recovery/anchor state (e.g. `anchorPaused`) so the UI can say "waiting for AR to re-track the target" instead of showing a normal ring. | RC-3, RC-7 |
| `lib/features/capture/presentation/screens/ar_capture_screen.dart` | Wire `didChangeMetrics` → `resize` + `setDisplayRotation`, or lock to `portraitUp`; update the resume button copy/state. | RC-1, RC-6 |
| `lib/main.dart` | If locking instead of wiring: keep only `portraitUp`. | RC-6 |

### Phase 2 — Tracking/recovery states

| File | Change | Why |
|---|---|---|
| `lib/features/capture/application/capture_state.dart` | Add `CaptureRecoveryState` (initializing, scanning, waitingForTracking, calibrating, ready, trackingLost, recovering, recalibrationRequired, complete) derived from existing fields. | Requirement B |
| `lib/features/capture/presentation/screens/ar_capture_screen.dart` | Show the recovery state in the chip/instruction; keep the existing numeric diagnostics. | Requirement D |
| `lib/features/capture/application/capture_controller.dart` | On `_anchorGiveUp`, set `recalibrationRequired` as an explicit state, not only a message. | Requirement B |

### Phase 3 — Depth occlusion (device-gated)

| File | Change |
|---|---|
| `android/.../ar/ArCoreSessionController.kt` | Depth capability check, `Config.DepthMode`, ES 3.0 EGL, per-frame depth image acquisition and upload, real capability reporting. |
| `android/.../ar/ArGlRenderer.kt` | Depth texture, sampler, fragment-shader comparison, bias, invalid-data handling, fallback path. |
| `lib/features/virtual_tour/platform/ar_types.dart` / `arcore_ar.dart` | Parse the real depth capability (replace the hardcoded false on the Dart side if surfaced). |
| `lib/features/capture/application/capture_state.dart` + screen | Show "Occlusion unavailable on this device" only where useful; no blocking. |

### Phase 4 — Tests and verification

| File | Change |
|---|---|
| `test/world_target_test.dart` | Per-pose anchor tracking; paused anchor never ready; alignment fallback; resume refused across sessions. |
| `test/capture_controller_*` (existing fakes) | Recovery state mapping; ghost/paused draw policy at the scene level. |
| Kotlin unit/instrumented test | `buildDraws` honours the chosen tracking policy; depth capability fallback. |
| `test/glb_pipeline_test.dart` | Unchanged; must keep passing. |
| Device checklist | §10. |

**Explicitly unchanged:** the 26 directions, radius, calibration rules, stability thresholds, storage format, capture order, JPEG encoding, navigation, and the existing public APIs.

**Rollback:** Phase 1 is a small Dart-only change plus docs; Phase 3 is isolated behind a capability check and can be disabled by returning `depth=false`.

---

## 8. Test coverage and gaps

Existing coverage (22 test files) is strong on:

* Station geometry, target directions, world position invariance under camera motion (`test/world_target_test.dart`).
* Projection and alignment math (`test/projection_test.dart`, `test/alignment_*`).
* Stability hysteresis, window, drift (`test/stability_test.dart`, `test/motion_stability_test.dart`).
* Target transitions, shot phase, scale, verdicts.
* Persistence, photo capture timeouts, real GLB geometry (`test/glb_pipeline_test.dart`, `test/photo_capture_service_test.dart`).

Gaps this audit found:

1. No test that `activeAnchorTracking` follows the **per-pose** anchor state.
2. No test that a paused anchor's pose is **not** used for alignment/readiness.
3. No test that `resumeStation()` refuses a new ARCore session (the current tests only exercise the same-session restore).
4. No native test for `buildDraws()` tracking/ghost policy (the existing tests assert the Dart scene request, not the Kotlin filter).
5. No test for 180° display rotation / metrics changes.
6. No depth/occlusion test; it cannot be meaningfully run without a supported device.
7. No physical-device test result exists in the repository. The current `docs/` verification documents are source-level, not device-level.

### 8.1 Baseline run (read-only)

`flutter test` was run on 2026-10-24 with the proxy workaround required in this sandbox:

```
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flutter test
```

Result:

```
+297 -8: Some tests failed.
```

The 8 failures are **not caused by this audit** (no file was changed). They are stale fixtures that still describe behaviour the production code intentionally changed in earlier rounds:

| Failing test | Actual | Why it is stale |
|---|---|---|
| `capture_flow_test.dart` — "a failed save can be retried, and the retry succeeds" | target stays `failed` | Production now requires re-aiming after a failure (`retryPending`, `capture_state.dart:378-382`; `capture_controller.dart:1449-1462`). The test calls `captureNow()` again without breaking and restoring the hold. |
| `target_scale_test.dart` — 5 instruction tests | `Starting AR tracking — move the phone slowly.` | The fixture omits `tracking`, and `CaptureState.tracking` now defaults to `TrackingState.initialising` (`capture_state.dart:54`). `instruction` correctly reports the ARCore state first (`:502-504`). The fixture must set `tracking: TrackingState.tracking`. |
| `target_transition_test.dart` — "capturing target 1 activates target 2…" | opacity of target 1 = 0 | Completed targets are now always hidden (`_hiddenTargetsIn`, `capture_controller.dart:1785-1796`); the test expects the old full-opacity done marker. |
| `world_target_test.dart` — "a persistently paused anchor is re-placed, then reported" | creations = 26, not >26 | Production now only re-places a **gone** anchor; a paused anchor is waited on (`capture_controller.dart:1528-1600`). The test still expects the removed re-place-on-pause policy. |

These must be fixed as part of Phase 1 so the gate is green before new tests are added. None of them justifies changing production behaviour; the retry path in particular should gain a test that re-aims and then succeeds.

No test was added or changed during this audit.

---

## 9. Physical-device verification checklist (not performed)

Record for every test: device model, Android version, ARCore version, lighting, distance to walls, and a screen recording or screenshots.

1. **Cold launch, calibrate, single target.** Place one target at a known station-relative position. Rotate ~90° yaw slowly without moving; the target must stay on the same real-world feature. Repeat with a 45° tilt up/down and a 1 m sideways move and return.
2. **Tracking loss.** Cover the camera or point at a blank wall until ARCore reports a failure reason. Confirm: capture blocked, station preserved, UI names the reason, and the target is marked paused/ghost rather than silently authoritative. Uncover and confirm recovery without a new station.
3. **Anchor pause during rotation.** Rotate quickly enough to pause the active anchor; confirm the marker does not slide relative to the environment and that the shutter is blocked while paused.
4. **Resume across sessions.** Force-stop the app, relaunch, and verify "Resume last capture" can no longer place targets in the old world frame; verify the recalibrate-and-continue path carries captured flags and photographs.
5. **Background/foreground.** Background the app mid-station and return; confirm the station is either restored only with the same session or explicitly discarded with a clear message (no silent wrong placement).
6. **180° rotation / foldable.** Flip the device and, if applicable, fold/unfold; confirm the preview, projection, arrow, and saved JPEG are upright.
7. **Depth (supported device only).** Place a target behind a chair/table edge; confirm the real edge occludes the virtual marker. Then test an unsupported/disabled-depth path: rendering must fall back without errors.
8. **Full 26-target run.** Capture all 26, confirm every JPEG is saved, `records.json` is complete, and the ring logic is unchanged.
9. **Station drift.** Walk 2 m away and back; confirm the warning and the "Recalibrate here" recovery still work.
10. **No hardcoded success.** Verify the UI never shows "ready" while tracking, anchor state, alignment, or stability is invalid.

---

## 10. Status: implemented / simulated / unverified

| Item | Status |
|---|---|
| Audit, code trace, transform verification | **Done** — read-only at the time of writing |
| Root causes RC-1…RC-3 | **Fixed in Phase 1** (approved option 1): cross-session resume refused, paused anchors ghosted and excluded from alignment, per-pose anchor tracking drives the gate and the ghost. RC-4 (depth) remains open; RC-5 is by design; RC-6 locked to portrait-up; RC-7 deferred to Phase 2 |
| SceneView/Filament decision | **Done** — do not migrate; reasons in §5 |
| Depth occlusion | **Not implemented** — deferred until after device verification; feasibility in §6 |
| Existing test suite | **309 pass / 0 fail** — the 8 stale fixtures listed in §8.1 were corrected first, then the Phase 1 tests were added |
| Automated tests for the new defects | **Written** — per-pose anchor pause/resume, paused alignment fallback, ghost opacity, stale-resume refusal, recalibrate-and-continue |
| Physical-device verification | **Not performed** — checklist in §9 |
| Code changes | **Phase 0 + Phase 1 implemented** in `capture_controller.dart`, `plane_anchor_service.dart`, `ar_capture_screen.dart`, `main.dart`, and the tests named in §7.5 |

---

## 11. What needs your decision

1. Approve Phase 1 (RC-1/2/3 + rotation) as a small Dart-only change, or ask for a different resume policy.
2. Choose the paused-anchor render policy: **ghost** (recommended; keeps the marker visible but dimmed and non-authoritative) vs **hidden** (strict ARCore contract, but the marker briefly disappears on rotation).
3. Decide whether Phase 3 (depth) is in scope now or after the placement fix is verified on the Xiaomi.
4. Provide a logcat export from the reported session if you want RC-1 vs RC-2 ranked against the actual symptom; without it, both are fixed because both are real.

---

## 12. Sources for the SceneView evaluation

* SceneView GitHub repository: <https://github.com/sceneview/sceneview>
* SceneView releases (latest v4.62.0, 2026-10-22): <https://github.com/sceneview/sceneview/releases>
* SceneView documentation: <https://sceneview.github.io/>
* Maven artifact: <https://mvnrepository.com/artifact/io.github.sceneview>

SceneView's own documentation describes `ArSceneView` as a View/Compose component with ARCore + Filament; it does not document rendering into an externally-owned Flutter `Texture`/EGL surface. The compatibility numbers above are from the repository/release metadata read on 2026-10-24.

---

*End of audit. §10 was updated on 2026-10-24 after Phase 0 + Phase 1 were implemented; the findings and evidence above are unchanged.*
