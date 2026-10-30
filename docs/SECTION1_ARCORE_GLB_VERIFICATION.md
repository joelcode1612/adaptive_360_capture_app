# ARCore Integration and GLB Rendering — Verification Report

Answers the six questions in the task, in order, with the evidence each one rests on.

---

## 1. Was native ARCore already configured?

**Yes.** The project does not use a Flutter AR package, and does not need one.

| Layer | Where | Status |
| --- | --- | --- |
| Gradle dependency | `android/app/build.gradle.kts` → `implementation("com.google.ar:core:1.57.0")` | present |
| Manifest | `AndroidManifest.xml` → `<meta-data android:name="com.google.ar.core" android:value="optional" />` | present |
| Dart imports of an AR package | none — `pubspec.yaml` has no `ar_*` dependency | as intended |
| Session creation | `ArCoreSessionController.start()` | present |
| Camera rendering | `ArGlRenderer` (EGL + OES texture → Flutter `Texture`) | present |

### The exact session-creation code

`android/.../ar/ArCoreSessionController.kt`, inside `start()`:

```kotlin
setupEgl()
renderer.onSurfaceCreated()
renderer.onSurfaceChanged(surfaceWidth, surfaceHeight)

val created = Session(appContext)
val config = Config(created)
config.updateMode = Config.UpdateMode.BLOCKING
config.planeFindingMode = if (withPlanes) {
    Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
} else {
    Config.PlaneFindingMode.DISABLED
}
created.configure(config)
created.setCameraTextureName(renderer.cameraTextureId)
created.resume()
session = created
running = true
startRenderLoop()
```

So **both** horizontal and vertical plane detection are requested. The session is created with the *application* context (ARCore's documented recommendation for avoiding Activity leaks), configured, given the OES texture id, then resumed.

### The exact camera-rendering code

`renderFrame()`, per frame, on the AR thread:

```kotlin
val frame = s.update()
val camera = frame.getCamera()
emitPose(frame, camera)

val uvs = FloatArray(8)
frame.transformCoordinates2d(
    Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, NDC_QUAD,
    Coordinates2d.TEXTURE_NORMALIZED, uvs)
renderer.setCameraUvs(uvs)

camera.getViewMatrix(view, 0)
camera.getProjectionMatrix(projection, 0, 0.05f, 50f)
renderer.setViewProjection(view, projection)
renderer.draw(buildDraws())
EGL14.eglSwapBuffers(eglDisplay, eglSurface)
```

`renderer.draw()` draws the camera image first (full-screen quad sampling the
external OES texture ARCore writes into), then the anchored meshes with
`projection × view × anchorPose × localRotation × scale`.

**No second AR session and no second camera was introduced.** ARCore owns the
camera device; the still-capture path reads `Frame.acquireCameraImage()` from the
same session.

---

## 2. The actual cause of the zero-plane / unanchored state

Two defects, one certain and one environmental, plus a reporting gap that made
them indistinguishable.

### 2a. Defect (certain, code-level): the pose event could be lost entirely

`emitPose()` read the camera intrinsics **before** `emit(event)`:

```kotlin
event["planeCount"]   = planes.size      // built…
event["planesTracked"] = tracked
…
val intrinsics = camera.imageIntrinsics  // …then this could throw
…
emit(event)                              // …and this never ran
```

If anything in that intrinsics block throws, **no pose event is emitted at all**.
The Dart side then keeps its initial state forever: `planesTracked` stays `0`,
the tracking state never advances, and no target can ever be anchored. In the UI
that is *exactly* "0 planes · Target not anchored", and it is indistinguishable
from a room where ARCore genuinely found nothing.

The previous build wrapped this call in `runCatching`, which hid the failure
completely — a worse outcome than the exception itself.

**Fixed.** The pose and the plane counts are now built first and always emitted;
the intrinsics are attached best-effort inside their own `try`. A pose without
intrinsics costs one field, not the whole frame. And a pose failure is now
*reported* through `reportRenderFailure` instead of swallowed.

### 2b. Defect (certain): the ray was too short for the room

`CaptureGeometryConfig.rayDistanceM` was **4.0 m**. An empty commercial unit is
commonly 5–7 m across, so the ray from the station fell short of every wall and
the target reported "no surface" in a room ARCore had already mapped.

**Fixed:** 8.0 m. The ray still stops well inside one unit while reaching its far
wall.

### 2c. Reporting gap: "not anchored" had no cause

`raycast` returned `null` for both "ARCore returned no hits" and "hits existed but
none was a plane within range". The UI could not tell the user which.

**Fixed.** The host now returns a reason (`no_candidates` / `no_plane_within_range`),
and the user is told accordingly — "move the phone slowly across the room" is a
different instruction from "point at that wall".

### 2d. What is *not* claimed

Whether ARCore was reporting planes on your device at that moment cannot be
settled from the screenshot. If tracking was healthy and the room genuinely had no
detectable surfaces (white walls, glossy floor — normal in an empty unit), 0 planes
was the truthful answer and no code change can conjure one. What has changed is
that the answer is now **trustworthy and specific**: the UI shows
`0 planes · 0 walls · 0 floors · 0 ceilings` versus `3 planes · 2 walls · 1 floor · 0 ceilings`,
and says which instruction applies.

---

## 3. Were both GLB models loaded and parsed?

**Yes — verified by executing the real pipeline against the real files**, not by
inspection. `test/glb_pipeline_test.dart` loads `assets/models/*.glb` from disk,
runs them through `GlbMeshSource` → `parseGlb` → `buffersFor`, and asserts the
counts:

| | Target | Bezel |
| --- | --- | --- |
| drawables | 4 | 1 |
| triangles parsed | 536 (256 + 256 + 12 + 12) | 512 |
| triangles uploaded | 512 (check marks excluded) | 512 |
| vertices uploaded | 1536 | 1536 |
| buffers uploaded | positions `Float32List(4608)`, colours `Float32List(6144)` | same shape |

The uploaded total is reported in the app as **1048 triangles in the scene**, and
shown on the capture screen's diagnostics line.

Both asset path constants match the `pubspec.yaml` declarations and the files on
disk, and both files are present in the built APK at
`assets/flutter_assets/assets/models/` (12608 / 10088 bytes).

---

## 4. Which original GLB features the previous renderer omitted

The glTF JSON chunks were read directly. **Nothing is omitted.**

```
ar_capture_target.glb
  nodes 4, meshes 4, materials 4, accessors 8, bufferViews 8
  extensionsUsed: none      textures: none      images: none      samplers: none
  every primitive: attributes = {POSITION}, indexed, mode 4 (TRIANGLES)
  every node: no translation, no rotation, no scale, no matrix
  every material: baseColorFactor only, metallic 0.0, roughness 0.5,
                  doubleSided true, alphaMode default (OPAQUE)

white_frame_bezel.glb
  nodes 1, meshes 1, materials 1, accessors 2, bufferViews 2
  256 verts / 512 tris, POSITION only, indexed, baseColor 0.95 grey, doubleSided
```

Specifically **absent from the assets themselves**: no `TEXCOORD_0`, no `NORMAL`,
no `COLOR_0`, no `baseColorTexture`, no `normalTexture`, no PBR texture chain, no
`KHR_*` extensions, no node transforms, no animation, no skinning.

That means the previous custom renderer's representation — expanded positions plus
one flat colour per vertex taken from `baseColorFactor` — is a **complete**
representation of these two files, not an approximation. There is no texture to
lose and no normal to shade with. `test/glb_pipeline_test.dart` asserts each of
those absences explicitly, so if a future asset gains a texture the test fails
rather than the model silently rendering untextured.

### Indexed geometry

The assets are indexed (130 vertices → 256 triangles). `parseGlb` expands indices
into a triangle soup at parse time, so the native renderer needs no index buffer.
The test asserts `triangleCount == 256` **and** `vertexCount == 768` for the plate,
which is only true if the expansion happened.

### The `skipCheckMarks` filter

The previous condition was `if (skipCheckMarks && drawable.meshIndex >= 2) continue;`.

It happens to be correct for this asset — meshes 2 and 3 are the two 8-vertex,
12-triangle cuboids — but it is a raw index standing in for a semantic name, and
the asset's nodes are unnamed, so there is nothing better to key on. It is now
expressed through `GlbTargetTopology.isCheckMarkPart()`, which only classifies a
drawable as a check mark when the asset still has the four-part layout it was
written against. On a changed asset nothing is skipped, rather than the wrong
geometry being dropped.

---

## 5. Files changed

| File | Change |
| --- | --- |
| `android/.../ar/ArCoreSessionController.kt` | `emitPose` rebuilt so the pose always emits (root cause 2a); plane counts by type (walls/floors/ceilings); raycast miss reasons; `getProjectionMatrix` near 0.05 / far 50 for depth precision |
| `lib/features/virtual_tour/platform/arcore_ar.dart` | `ArRaycastOutcome` + `ArRaycastMiss` (miss with a cause); `walls`/`floors`/`ceilings` on `ArPoseSample` |
| `lib/features/capture/data/services/plane_anchor_service.dart` | `anchorTarget` returns `AnchorAttempt` (hit / miss-with-reason / anchor-refused) |
| `lib/features/capture/domain/services/target_sphere.dart` | `rayDistanceM` 4 → **8**; `bezelSetbackM` 20 → **14 mm**, derived from the assets' own 6 mm plate depth |
| `lib/features/capture/data/services/glb_mesh_source.dart` | check-mark selection by topology instead of a raw index; `describe()` diagnostics |
| `lib/features/capture/application/capture_state.dart` | plane breakdown, `planeSummary`, block reason that distinguishes "no planes" from "ray missed" |
| `lib/features/capture/application/capture_controller.dart` | passes the plane breakdown through; uses the anchor attempt's reason |
| `lib/features/capture/presentation/screens/ar_capture_screen.dart` | diagnostics line shows the plane breakdown and the in-scene triangle count |
| `test/glb_pipeline_test.dart` | **new** — 11 tests against the real assets |
| `test/capture_flow_test.dart`, `test/capture_test_fakes.dart` | updated for the raycast outcome and the new miss wording |

### One correction made mid-task

The bezel setback was first set to 2 mm on the reasoning that a depth buffer makes
a large setback unnecessary. That is wrong: the bezel is 12 mm deep and the plate
6 mm, both authored around the same origin, so any setback under ~6 mm puts the
bezel's front face **in front of** the plate and it would cover the green centre.
It is now **14 mm** — enough to clear the plate by 8 mm, small enough that the two
meshes do not touch (coplanar contact z-fights too).

---

## 6. Verification

| Check | Result |
| --- | --- |
| `flutter pub get` | resolved |
| `dart format lib test` | applied |
| `flutter analyze` | **No issues found** |
| `flutter test` | **74 tests pass** (63 → 74; +11 GLB pipeline) |
| `flutter build apk --debug` | **built** |
| GLB assets in APK | both present, 12608 / 10088 bytes |

### Are the models visible and correctly anchored?

**Not verified.** I have no ARCore-capable device, so I will not claim it. What is
established is that the geometry, colours and proportions that *should* be drawn
are correct and reach the native renderer (measured, §3/§4), and that the path
that was silently dropping the pose event — the one that made anchoring impossible
— is fixed.

The remaining unknowns are all device-side: whether ARCore finds planes in your
room, whether the anchor is created, and whether the marker appears where the
surface is.

### Re-test order, and what to look for

1. Launch → **AR capture**. The diagnostics line now reads e.g.
   `Tracking tracking · 2 planes · 1 wall · 1 floor · 0 ceilings · GLB 1048 tris in the scene`.
   `GLB 1048 tris` means both models parsed and were uploaded.
2. If it says `0 planes · 0 walls · 0 floors · 0 ceilings` while tracking, ARCore
   has found no surfaces: move slowly across the floor with the phone tilted down,
   then press **Scan again**.
3. If it says `2 planes · 2 walls · …` but the target stays unanchored, the ray
   missed — the target message now says which of the two it was.
4. Once anchored, the plate (0.54 m, light grey, green centre) and the 0.70 m bezel
   behind it should appear on the surface and stay put as the phone moves.
5. If the AR view is black again, the red banner carries the exception's class,
   message and first Kotlin frame.

### Remaining limitations

* ARCore world coordinates are per-session; a station cannot be revisited across
  app restarts.
* iOS has no ARKit host; the module reports that rather than degrading silently.
* The still's resolution is ARCore's CPU image size, recorded per photograph.
* Planes are the only accepted surface type. A ray that hits only feature points
  is reported as `no_plane_within_range`, not silently anchored to a point.
