# Capture Quality — Diagnosis and Fix Report

Date: 2026-10-18. Trigger: user screenshot of the capture screen —
"can you solve the capture quality because the image very blur". Scope answer
from the user: the blur is worst **in the captured images** (the saved
photographs), not the preview.

---

## A. Diagnosis — traced, not guessed

A saved photograph is `Frame.acquireCameraImage()` → `YuvJpegEncoder` → JPEG on
disk. Each stage was read, and the stages below were **exonerated** — they are
not the blur:

| Suspect | Verdict | Evidence |
| --- | --- | --- |
| JPEG encoder resampling | Clean | `YuvJpegEncoder.kt` rotates the raw YUV planes and does one `YuvImage.compressToJpeg`, no Bitmap, no resize. |
| JPEG quality | Clean | 95, already (`photo_capture_service.dart`, `jpegQuality`). |
| Preview surface too small | Clean | EGL RGB888 at full physical pixels; size = `logical size × devicePixelRatio` (`ar_capture_screen.dart:83`). |
| OES texture / GL filtering | Clean | `GL_LINEAR` min+mag (`ArGlRenderer.kt:116-125`); camera quad is a passthrough. |
| Flutter `Texture` filter quality | Not the photo path | `FilterQuality.none` only affects an upscaled *preview*; it never touches the saved file. |
| Motion blur at the shutter | Unlikely | The stability gate settles the phone first (≤ 5°/s over 450 ms); exposure at that rate is a fraction of a degree. |

What remained, and what the code showed:

1. **Focus — the prime suspect. `Config.focusMode` was never set.**
   `ArCoreSessionController.start()` configured `updateMode` and
   `planeFindingMode` only. A grep for "focus" across `android/` found one
   hit — a manifest feature flag — so ARCore ran with its default,
   **`FIXED`**: the lens parks near its hyperfocal distance. At the capture
   distance this app is used at (arm's length, wall 30–70 cm away — exactly the
   screenshot), everything outside that narrow depth of field is soft. And it
   softens the **saved photographs**, not just the preview, because
   `acquireCameraImage()` reads the same lens.
2. **Resolution — was unknowable.** ARCore picks the camera config
   automatically; the CPU image that becomes every still is "typically
   640×480 to 1920×1080 depending on the camera config" (already documented in
   `photo_capture_service.dart` lines 37–41). Nothing in the UI stated the
   number per session, so "soft lens" and "small stream" looked identical and
   need opposite fixes. Per-photo dimensions were recorded
   (`CaptureRecord.imageWidth`) but there was no session-level readout of the
   camera config or the focus mode.

## B. What changed

### 1. Autofocus — the fix (`ArCoreSessionController.kt`, `start()`)

```kotlin
try {
    config.focusMode = Config.FocusMode.AUTO
    created.configure(config)
    focusModeName = created.config.focusMode.name.lowercase()
} catch (e: Exception) {
    val fallback = Config(created)
    fallback.updateMode = config.updateMode
    fallback.planeFindingMode = config.planeFindingMode
    created.configure(fallback)
    focusModeName = "fixed"
}
```

Wrapped so a device that refuses `AUTO` (no AF unit, some tablets) **falls back
to the default instead of losing the session** — a focus request must not be
able to black-screen the camera after the buffer bug we already fixed once.
The mode that actually took effect is read back from the session config, not
from what we asked for.

### 2. Camera-config readout — the evidence

`readCameraConfig()` runs once per session (flags reset on every `start()`, so
a retry session re-reports) and adds `stillWidth`, `stillHeight`,
`previewWidth`, `previewHeight`, `fpsMin`, `fpsMax`, `focusMode` to exactly one
pose event. `stillW > 0` guards the send: a session whose config cannot be read
reports nothing rather than a believable-looking 0×0 camera.

Dart side: `ArCameraQuality` (`ar_types.dart`) + `parseCameraQuality`
(`arcore_payload.dart`, `null` when absent — the file's existing convention),
carried on `ArPoseSample.cameraQuality`, mirrored through
`ArSessionService.cameraQuality` into `CaptureState.cameraQuality`
(`clearCameraQuality` on session restart, like `clearStation`).

### 3. The status detail now says it out loud

Expanded status detail on the capture screen, after the GLB line:

```
Photos 1440×1080 · autofocus on
```

or, on the fallback path, `… · focus locked at the default distance`. That
turns "the photos look blurry" into a number and a mode on the user's own
phone, which is the difference between fixing it and guessing.

## C. Deliberately not done (user's "keep automatic" answer)

- **No max-resolution `CameraConfig` selection.** The instrumentation makes
  the next decision an evidence-based one: if the still stream reports
  640×480-class, the follow-up is one line
  (`session.cameraConfig = best-of-supported`) with a real battery/heat cost
  that deserves its own approval. ArCore's automatic choice stays until then.
- **No upscaling or re-encoding of saved photos.** The photograph is the
  camera's own frame at the sensor's CPU resolution; inventing pixels would
  fake quality.

## D. Verification

| Check | Result |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **182 pass** (171 → 182; +11 in `test/camera_quality_test.dart`) |
| `:app:compileDebugKotlin` + `flutter build apk --debug` | Builds — the ARCore 1.57 APIs used (`Config.FocusMode`, `Session.getCameraConfig`, `CameraConfig.imageSize/textureSize/fpsRange`) all resolve |

Test coverage added: payload parsing (complete / missing keys → null / zero
dims → null), describing both focus modes, the pose-event carry-through
(present on the one event that carries it, absent on the rest), and the state
keep/clear semantics across a session restart.

**Not verified — no physical device.** `adb devices` is empty here, so the
following are pending your phone:

1. Install the new APK (already built in this session).
2. Open the capture screen, expand the status line, and read
   `Photos {w}×{h} · autofocus on`.
3. Capture the same subject at ~30 cm and at ~2 m. If focus was the cause,
   the close-range photograph is now sharp.
4. If the readout says 640×480 (or similar), report the number — that is the
   trigger for the camera-config follow-up above.

One caveat worth stating: `Config.focusMode = AUTO` requests autofocus from
the session; the phone decides. The readback reports what ARCore granted, and
the fallback path catches a device that refuses the request outright — but a
phone that accepts the request and still behaves badly would only be visible
in step 3.

## E. Files

- `android/app/src/main/kotlin/com/adaptive360/adaptive_360_capture_app/ar/ArCoreSessionController.kt`
  — `Config.FocusMode.AUTO` with fallback, `readCameraConfig()`, pose-event
  fields, session-restart flag resets.
- `lib/features/virtual_tour/platform/ar_types.dart` — `ArCameraQuality`.
- `lib/features/virtual_tour/platform/arcore_payload.dart` — `parseCameraQuality`.
- `lib/features/virtual_tour/platform/arcore_ar.dart` — `ArPoseSample.cameraQuality`.
- `lib/features/capture/data/services/ar_session_service.dart` — `cameraQuality` field.
- `lib/features/capture/application/capture_state.dart` — field + `copyWith` +
  `clearCameraQuality`.
- `lib/features/capture/application/capture_controller.dart` — mirrors the
  report into state; clears it on `boot`/`retrySession`.
- `lib/features/capture/presentation/screens/ar_capture_screen.dart` — status
  detail line.
- `test/camera_quality_test.dart` — new, 11 tests.
