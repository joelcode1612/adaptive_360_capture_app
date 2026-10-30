# Section 1 — Device Failure Fix Report

Diagnosis and repair of the reported symptoms: black AR view, `Tracking paused`,
`0 planes`, disabled Capture button, and
`java.lang.IllegalArgumentException: Must use a native ord…`.

**One root cause explains the black preview, the disabled Capture button and most
of what followed. It was not the assets, not the permissions and not the AR
session.**

---

## 1. Root cause of the black camera preview

**File:** `android/app/src/main/kotlin/.../ar/ArGlRenderer.kt`
**Lines:** 47 and 60 (before the fix)

```kotlin
private val quadCoords = FloatBuffer.allocate(8).apply { … }   // heap buffer
private val cameraUvs = FloatBuffer.allocate(8)                // heap buffer
```

Both were then handed straight to GLES:

```kotlin
GLES20.glVertexAttribPointer(cameraPositionAttr, 2, GLES20.GL_FLOAT, false, 0, quadCoords);
GLES20.glVertexAttribPointer(cameraTexCoordAttr, 2, GLES20.GL_FLOAT, false, 0, cameraUvs);
```

`GLES20.glVertexAttribPointer` resolves the `Buffer` argument to a **native
pointer**. Its JNI implementation rejects a non-direct buffer with exactly:

```
java.lang.IllegalArgumentException: Must use a native order direct buffer
```

`FloatBuffer.allocate(n)` returns a **heap** buffer. `ByteBuffer.allocateDirect(n)
.order(ByteOrder.nativeOrder()).asFloatBuffer()` returns a direct one.

### Why that produced a black screen rather than an error

`drawCamera()` is the first thing the render loop does, so the exception was thrown
on **every frame**, and `renderFrame()`'s `catch` swallowed it before reaching:

```kotlin
EGL14.eglSwapBuffers(eglDisplay, eglSurface)
```

A skipped `eglSwapBuffers` is a skipped frame. The Flutter `Texture` never received
a single buffer, so the widget had nothing to paint: **black**. The camera itself
was running, ARCore was updating, poses were arriving — only the presentation was
dead. That is why the UI could still show a live tracking state and a drift
reading while the view was black.

It also explains the downstream symptoms:

| Symptom | Why |
| --- | --- |
| Black view | no frame ever swapped into the texture |
| `Target not anchored` | the raycast request is consumed *after* `draw()` in the same loop iteration, so it never ran |
| Capture disabled | no anchor ⇒ no target position ⇒ no alignment ⇒ gate closed |
| `0 planes` | the user had no preview to aim with, so ARCore got no parallax across the room |
| GLB models invisible | the whole GL pass aborted before the mesh program |

### The fix

```kotlin
/**
 * Every buffer that reaches glVertexAttribPointer or glBufferData must be
 * direct and in native byte order.
 */
internal fun directFloatBuffer(floats: Int): FloatBuffer =
    ByteBuffer.allocateDirect(floats * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

private val quadCoords = directFloatBuffer(8).apply { … }
private val cameraUvs = directFloatBuffer(8)
```

The mesh upload path was already correct (`ByteBuffer.allocateDirect(…)
.order(nativeOrder())`) and now goes through the same helper, so there is exactly
one way to build a GL buffer in this file.

**This was not a Dart problem and no Dart workaround was applied.** The buffer is
constructed in Kotlin; the asset declaration cannot affect it.

### Two secondary defects fixed in the same file

* The four GLSL shader sources were `const val` raw strings whose first line was a
  newline plus eight spaces of indentation. `#extension GL_OES_EGL_image_external`
  must be the first token of the fragment shader; some drivers reject leading
  indentation. They are now `val … .trimIndent()`.
* `buildModelMatrix` called `Matrix.multiplyMM(modelMatrix, 0, modelMatrix, 0,
  scratch, 0)`, aliasing the result with an input, which `android.opengl.Matrix`
  does not support. It now multiplies from `draw.anchorMatrix` directly.

---

## 2. The exception's origin, and why the message was truncated

**Origin:** `ArGlRenderer.drawCamera()`, called from `ArGlRenderer.draw()`, called
from `ArCoreSessionController.renderFrame()` — all inside this app. Not a
third-party plugin, not a transitive graphics dependency, not ARCore.

**Why the screen showed `Must use a native ord…`:** the old handler collapsed the
exception to a generic event and let it through as a plain string:

```kotlin
} catch (e: Exception) {
    emit(mapOf("type" to "error", "message" to "$e"))
}
```

…which the diagnostics line then clipped with `maxLines: 2`. Neither the class name
nor the frame survived.

**Now:** the render loop reports each *distinct* failure once, intact, and keeps
running:

```kotlin
private fun reportRenderFailure(e: Exception) {
    val signature = "${e.javaClass.name}: ${e.message}"
    if (signature == lastRenderFailure) return
    lastRenderFailure = signature
    emit(mapOf(
        "type" to "error",
        "message" to signature,
        "frame" to e.stackTrace.firstOrNull()?.toString(),
        "fatal" to true,
    ))
}
```

Dart carries it as `ArCoreEvent.message` / `.frame` / `.fatal` into
`CaptureState.arFault` / `.arFaultFrame`, and the screen renders it in a red banner
with the message in a monospace font, the first stack frame, and a **Retry** action.
`lastRenderFailure` is cleared after a successful swap, so a transient fault can be
reported again if it recurs.

Also hardened in the same loop: `measureImageAxis()` and `emitPose()` are each
wrapped in `runCatching`, because both touch ARCore APIs that can throw before
display geometry settles — and a throw there skipped the swap too.

---

## 3. GLB assets

### Declaration

`pubspec.yaml` now names the two files explicitly instead of the directory:

```yaml
assets:
  - assets/models/ar_capture_target.glb
  - assets/models/white_frame_bezel.glb
```

Both forms bundle the same bytes; naming the files makes a rename or a missing asset
a **build failure** rather than a silent omission.

### Files on disk

```
assets/models/ar_capture_target.glb    12608 bytes
assets/models/white_frame_bezel.glb    10088 bytes
```

Verified present, with exact capitalisation, before the build.

### Verified inside the built APK

```
assets/flutter_assets/assets/models/ar_capture_target.glb    12608 bytes
assets/flutter_assets/assets/models/white_frame_bezel.glb    10088 bytes
```

### How they reach the AR scene

There is **one** copy of each model and **one** loader:

1. `GlbMeshSource.load()` reads the two files through `rootBundle` at the exact
   declared paths.
2. The project's existing `parseGlb` parses them into drawables.
3. `buffersFor()` flattens them to `Float32List` positions and RGBA colours —
   `ar_capture_target.glb` without its check-mark meshes, `white_frame_bezel.glb`
   whole.
4. `setMesh` uploads both buffers once per session.
5. `setScene` binds them to one anchor: the bezel at `offset (0, 0, −0.020)` in the
   plate's own frame (the two assets are authored in the same plane and would
   z-fight), the plate at the origin.

**There is deliberately no second copy under `android/app/src/main/assets/`.**
Nothing on the native side parses glTF, so a duplicate could only drift from the
authoritative one. Kotlin receives triangles, not files.

The two models are combined into a single visual target by sharing one anchor and
one local rotation — they cannot separate, and nothing re-creates them per tracking
update: the scene is pushed only when the active target or the anchor changes.

---

## 4. AR tracking and plane detection

`Tracking paused · 0 planes` was reported honestly by the host: it counts only
planes with `trackingState == TRACKING` and `subsumedBy == null`. Nothing was
fabricated.

The states are now separated in the UI rather than collapsed:

| State | What the user is told |
| --- | --- |
| ARCore missing / unsupported | "AR capture needs the Android ARCore host…" |
| Session starting | "Starting AR tracking — move the phone slowly…" |
| Tracking paused | the **actual** `TrackingFailureReason`, translated: `INSUFFICIENT_LIGHT` → "It is too dark…", `EXCESSIVE_MOTION` → "You are moving too fast…", `INSUFFICIENT_FEATURES` → "…point at a textured surface, not a blank wall" |
| Tracking ready, no planes | "Scan this surface" on the target, with the plane count shown |
| Tracking ready, anchored | the alignment instruction |

**Scan again** is now a defined action (`rescan` on the channel):

1. detaches every native anchor (a stale one would keep the marker on a surface the
   user walked away from);
2. re-applies `PlaneFindingMode.HORIZONTAL_AND_VERTICAL` — some devices drop it
   after a tracking pause;
3. forces the display geometry to be re-sent;
4. clears the render-failure latch;
5. re-runs the raycast for the active target.

It deliberately does **not** restart the session (that would give ARCore a new world
origin and invalidate the station pose and all 26 target directions) and does not
touch captured photographs. If tracking is not valid it says so instead of doing
nothing.

---

## 5. Capture button enablement

`CaptureState.readyToCapture` is now defined as `captureBlockReason == null`, so the
button state and the explanation cannot disagree. Eight conditions, in the order the
UI explains them:

1. no `arFault`, and a texture id exists;
2. `TrackingState.tracking`;
3. station calibrated;
4. a target is selected and not already captured;
5. the target is anchored to a real surface;
6. `angularErrorDeg ≤ 3°`;
7. steady for the full 500 ms window;
8. no photograph being saved.

Condition 7 was **missing** before this fix — the button enabled on alignment alone.
It now requires the stability window too, as §7 of the brief specifies.

The reason is printed under the buttons in amber, e.g. *"Target not anchored — point
at a wall, floor or ceiling and press Scan again."*, *"Hold still…"*, *"AR tracking
is not ready — move the phone slowly."*

The secondary button is always present and always defined: **Scan again** while the
target is uncaptured, **Retake** once it is captured. It used to disappear when the
target was anchored, leaving no way to rescan.

**Retry** (on the fault banner) restarts the session and explicitly warns that the
station must be recalibrated, because a new session has a new world origin.

---

## 6. Layout

The instruction banner and the mini-map were at `top: 12` inside a full-screen
`Stack`, i.e. under the system clock and battery icons. Both now sit at
`MediaQuery.paddingOf(context).top + 8`.

---

## 7. Files changed

| File | Change |
| --- | --- |
| `android/.../ar/ArGlRenderer.kt` | **direct buffers** (root cause), `trimIndent()` shaders, `multiplyMM` aliasing |
| `android/.../ar/ArCoreSessionController.kt` | `reportRenderFailure` with class + frame, `runCatching` around `measureImageAxis`/`emitPose`, `rescan()`, `takeStill` answers when there is no session |
| `android/.../ar/ArCoreCapturePlugin.kt` | `rescan` method |
| `pubspec.yaml` | explicit GLB asset paths |
| `lib/features/virtual_tour/platform/arcore_ar.dart` | `ArCoreGateway.rescan`, `ArCoreEvent.frame`/`.fatal`, `ArCoreEvent.fault` |
| `lib/features/capture/data/services/ar_session_service.dart` | `rescan()` |
| `lib/features/capture/application/capture_state.dart` | `arFault`, `arFaultFrame`, `captureBlockReason`; `readyToCapture` now requires stability |
| `lib/features/capture/application/capture_controller.dart` | fault handling, `rescanActive()` semantics, `retrySession()`, surface-size memory |
| `lib/features/capture/presentation/screens/ar_capture_screen.dart` | fault banner + Retry, SafeArea offsets, tracking-failure advice, block-reason line, always-defined secondary button |
| `test/capture_flow_test.dart`, `test/capture_test_fakes.dart` | `rescan` fake, fault injection, stability-aware capture, 3 scan-again tests, 2 fault tests |

---

## 8. Verification

| Check | Result |
| --- | --- |
| `flutter pub get` | resolved |
| `dart format lib test` | applied |
| `flutter analyze` | **No issues found** |
| `flutter test` | **63 tests pass** (was 58; +3 scan-again, +2 fault) |
| `flutter build apk --debug` | **built** — `app-debug.apk` |
| GLB assets in APK | **both present**, byte-for-byte (12608 / 10088) |

### Verified by build only — **not** verified on a device

I do not have the physical device, so the following remain unconfirmed and must be
checked on hardware:

1. That the camera preview is now visible (the direct-buffer fix is the cause, but
   only a device can show the frame).
2. That ARCore reaches `TRACKING` and reports planes.
3. That both GLB models render on the anchored surface.
4. That the Capture button enables only when all eight conditions hold.
5. That a saved photograph is upright, contains no overlay, and reopens correctly.

### Device re-test order

1. Launch → **AR capture**. Expect a live camera view within ~1 s.
2. If the view is still black, the red banner now names the exception **and the
   Kotlin file and line** — that is the next thing to send.
3. Move slowly until the tracking banner clears and planes appear.
4. Calibrate, confirm the marker sits on a real surface and stays put when the phone
   rotates.
5. Turn until the instruction reads *"Hold still…"*, then *"Ready to capture"*.
6. Capture, then open `tNN.jpg` and confirm it is upright and free of the marker.
7. Check `adb logcat | grep -E "IllegalArgument|ArCore|GL"` for residual errors.
