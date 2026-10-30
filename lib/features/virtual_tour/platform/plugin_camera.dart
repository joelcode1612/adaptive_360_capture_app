import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/analysis_pipeline.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/camera_preview.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';

/// The live camera, on the official `camera` plugin (CameraX on Android).
///
/// One stack for preview, stills and analysis. `startImageStream` hands us YUV
/// planes, and plane 0 of a YUV_420_888 frame is the luma plane — the grayscale
/// buffer the quality analysis wants, already at preview resolution and already
/// downsampled by the sensor. That is why this plugin was chosen over the
/// previous one, which has no image stream and would have forced a
/// full-resolution still plus a JPEG decode for every single validation.
///
/// ## What is honestly not here
///
/// * **No exposure lock.** The plugin exposes exposure *compensation*
///   (`setExposureOffset`) where the device supports it. It does not expose
///   locking exposure time or ISO, so the brief's "exposure control where the
///   device allows" is satisfied to exactly that extent and no further — see
///   [CameraCapabilities.exposureOffset]. A drifting auto-exposure between
///   frames is a real cause of stitching seams, and this class does not claim to
///   prevent it.
/// * **No focus lock either.** `setFocusPoint` is a request, not a lock.
/// * **No verification on hardware.** This class is written against the plugin's
///   documented API; nothing in this repository has run it on a phone. The
///   device checklist in `docs/DEVICE_TEST_CHECKLIST.md` is what
///   closes that gap.
class PluginCaptureCamera implements CaptureCamera, CameraPreviewSource {
  CameraController? _controller;
  CameraCapabilities _caps = CameraCapabilities.unavailable;

  LiveFrame? _latest;
  bool _fresh = false;
  bool _streaming = false;

  @override
  CameraCapabilities get capabilities => _caps;

  @override
  bool get isRunning => _controller?.value.isInitialized ?? false;

  @override
  bool get hasFreshFrame => _fresh;

  @override
  Future<CameraCapabilities> initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _caps = CameraCapabilities.unavailable;
        return _caps;
      }

      // The back camera: the panorama is of the room, not of the user.
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        // 4:3, not the 16:9 default: the plan's FOV model is derived from the
        // sensor's long side, and a 16:9 crop throws away vertical field, which
        // is the expensive direction for a 360° set.
        ResolutionPreset.high,
        enableAudio: false,
        // YUV so that the analysis gets the luma plane directly.
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _controller = controller;
      _streamFailed = false;
      await controller.initialize();

      final caps = await _probe(controller, back);
      _caps = caps;

      // Unconditional. `caps.imageStream` is the *outcome* of this call, not a
      // precondition of it — `_probe` always reports `false`, so a guard on it
      // meant the stream never started on any device, `grabFrame()` returned
      // null forever, and every live capture failed with "Camera frame
      // unavailable" before a shutter was ever pressed.
      await _startStream(controller);
      return _caps;
    } on CameraException catch (e) {
      _caps = CameraCapabilities(
        ready: false,
        preview: false,
        stillCapture: false,
        imageStream: false,
        exposureOffset: false,
        focusPoint: false,
        exposurePoint: false,
        sensorOrientation: false,
        limitation: 'Camera unavailable: ${e.description ?? e.code}.',
      );
      return _caps;
    }
  }

  /// Establishes each capability by asking, not by assuming.
  Future<CameraCapabilities> _probe(
    CameraController controller,
    CameraDescription description,
  ) async {
    final notes = <String>[];

    var exposureOk = false;
    double? minOff;
    double? maxOff;
    try {
      final lo = await controller.getMinExposureOffset();
      final hi = await controller.getMaxExposureOffset();
      minOff = lo;
      maxOff = hi;
      // A device that reports min == max accepts the call and ignores it.
      // Reporting that as "exposure control available" would be a lie, so the
      // range has to be non-degenerate as well as present.
      exposureOk = hi > lo;
      if (!exposureOk) {
        notes.add('exposure compensation is not adjustable');
      }
    } on CameraException {
      notes.add('exposure compensation is not reported');
    } on UnimplementedError {
      // Some platform implementations simply do not implement the call.
      notes.add('exposure compensation is not reported');
    }

    final hasSensorOrientation = description.sensorOrientation != 0;

    return CameraCapabilities(
      ready: true,
      preview: controller.value.isInitialized,
      stillCapture: controller.value.isInitialized,
      // Reported only by `_startStream`, which is the capability itself. This is
      // not a precondition for starting the stream — nothing can know the stream
      // works before it is started.
      imageStream: false,
      exposureOffset: exposureOk,
      minExposureOffset: minOff,
      maxExposureOffset: maxOff,
      focusPoint: true,
      exposurePoint: true,
      sensorOrientation: hasSensorOrientation,
      limitation: notes.isEmpty ? null : notes.join('; '),
    );
  }

  Future<void> _startStream(CameraController controller) async {
    try {
      await controller.startImageStream(_onFrame);
      _streaming = true;
      _caps = _caps.copyWith(imageStream: true);
    } on CameraException catch (e) {
      // Recorded, not thrown — but this is not a harmless downgrade. In live
      // mode the state machine reads every validated frame out of this stream,
      // so a device that refuses it cannot complete a capture at all; it reports
      // "Camera frame unavailable" and fails. The limitation text is the only
      // trace of that, which is why it names the consequence.
      _caps = _caps.copyWith(
        imageStream: false,
        limitation:
            'Live analysis is unavailable (${e.code}); captures cannot complete '
            'until the camera offers an image stream.',
      );
    }
  }

  /// Downsample every incoming frame to the analysis size.
  ///
  /// The work is a strided box average over 19,200 output pixels. It runs on the
  /// platform's stream callback, which is a Dart isolate but *not* the UI
  /// isolate's frame pipeline, and it does not allocate more than one buffer per
  /// frame. The heavy analysis — the Laplacian pass — is a separate step that
  /// runs off-thread; see [analyzeOffThread].
  ///
  /// The buffer geometry comes from the device's HAL, so a device that lays the
  /// luma plane out differently than assumed is handled here rather than left to
  /// throw once per frame into the platform channel.
  void _onFrame(CameraImage image) {
    if (image.planes.isEmpty) return;
    if (_streamFailed) return;
    try {
      final plane = image.planes.first;
      final gray = downsampleLuma(
        plane.bytes,
        image.width,
        image.height,
        plane.bytesPerRow,
        analysisWidth,
        analysisHeight,
      );
      _latest = LiveFrame(
        rgba: grayToRgba(gray),
        w: analysisWidth,
        h: analysisHeight,
      );
      _fresh = true;
    } catch (e) {
      _streamFailed = true;
      _streaming = false;
      _caps = _caps.copyWith(
        imageStream: false,
        limitation:
            'The camera delivered frames this build cannot read ($e); live '
            'analysis is off and captures cannot complete.',
      );
      final controller = _controller;
      if (controller != null) {
        unawaited(controller.stopImageStream().catchError((Object? _) {}));
      }
    }
  }

  bool _streamFailed = false;

  @override
  LiveFrame? grabFrame() {
    _fresh = false;
    return _latest;
  }

  @override
  Future<Uint8List?> takeStill() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      // The image stream and `takePicture` contend for the same pipeline on some
      // devices, so the stream is paused for the duration of the shot. Failing to
      // stop it is not fatal: `takePicture` will either work or throw, and both
      // outcomes are handled.
      final wasStreaming = _streaming;
      if (wasStreaming) {
        try {
          await controller.stopImageStream();
        } on CameraException {
          // Ignored on purpose; see above.
        }
      }
      try {
        final file = await controller.takePicture();
        return await file.readAsBytes();
      } finally {
        if (wasStreaming && _controller != null) {
          try {
            await controller.startImageStream(_onFrame);
          } on CameraException {
            _streaming = false;
          }
        }
      }
    } on CameraException {
      return null;
    }
  }

  @override
  Future<void> setExposureOffset(double offset) async {
    final controller = _controller;
    if (controller == null || !_caps.exposureOffset) return;
    final min = _caps.minExposureOffset ?? 0;
    final max = _caps.maxExposureOffset ?? 0;
    final clamped = offset < min ? min : (offset > max ? max : offset);
    try {
      await controller.setExposureOffset(clamped);
    } on CameraException {
      // The device accepted the probe and refused the set. Record it rather than
      // throwing into the capture flow: the frame is still worth taking.
      _caps = _caps.copyWith(
        exposureOffset: false,
        limitation: 'Exposure compensation was refused by the device.',
      );
    }
  }

  /// A single tap-to-meter point, in viewfinder coordinates.
  ///
  /// Exposed as a separate method rather than part of [CaptureCamera] because the
  /// flow only needs it if the user asks; nothing in the state machine depends on
  /// it.
  Future<void> focusAt(Offset point, Size viewfinder) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final x = (point.dx / viewfinder.width).clamp(0.0, 1.0) * 2 - 1;
    final y = (point.dy / viewfinder.height).clamp(0.0, 1.0) * 2 - 1;
    final target = Offset(x, y);
    try {
      await controller.setFocusPoint(target);
      await controller.setExposurePoint(target);
    } on CameraException {
      // Tap-to-meter is a convenience; losing it does not stop a capture.
    }
  }

  @override
  Widget previewWidget() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  @override
  double? get previewAspectRatio {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    final size = controller.value.previewSize;
    if (size == null || size.height == 0) return null;
    // `previewSize` is reported landscape-first; the app is portrait-locked, so
    // the ratio the layout wants is the reciprocal.
    return size.height / size.width;
  }

  @override
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    _latest = null;
    _fresh = false;
    // Reset with the rest of the state. `ready` is the flag the flow checks
    // before it re-opens, so leaving the old record in place here means it never
    // re-opens and the screen shows a closed camera — which is a black box, with
    // no message and no way to take a photo.
    _caps = CameraCapabilities.closed;
    if (controller == null) return;
    if (_streaming) {
      try {
        await controller.stopImageStream();
      } on CameraException {
        // Disposal is best-effort; the OS reclaims the camera either way.
      }
      _streaming = false;
    }
    await controller.dispose();
  }
}
