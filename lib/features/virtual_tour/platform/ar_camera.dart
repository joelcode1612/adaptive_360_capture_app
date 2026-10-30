import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';

/// The AR session's camera, as the capture flow sees it.
///
/// This exists because of one hard platform fact: **ARCore holds the camera
/// device exclusively.** While an AR session is running, `camera_android`,
/// CameraX and `camera2` cannot open the sensor at all — they get a
/// "camera in use" failure, not a slower stream.
///
/// That has a consequence the first draft of this rewrite got wrong. It tore the
/// AR session down at "Set Station Here" and then opened the still camera, which
/// meant the whole capture ran with **no pose at all**: `ALIGN` had nothing to
/// compare against, so the machine sat there forever and not one frame was ever
/// taken. The mistake was invisible in the tests, because the anchor placement
/// was failing for an unrelated reason, so the tear-down never actually ran.
///
/// The brief requires `ALIGN` to use the ARCore pose and the camera's real
/// intrinsics, and requires the tracking-loss recovery to be available *during*
/// capture. Both are impossible without a live pose, so the session has to span
/// the station — and if the session spans the station, the stills have to come
/// through it.
///
/// [ArFrameGrabber] is therefore the AR layer's camera, and [ArCaptureCamera]
/// adapts it to the same [CaptureCamera] interface the still camera implements,
/// so the state machine and the flow engine never learn which one they have.
///
/// **Honest limitation.** The still comes from the ARCore camera image, not from
/// a full-resolution still capture. Its size is whatever the session's
/// `CameraConfig` delivers (typically 640×480 up to 1920×1080, depending on the
/// device and the ARCore camera config that was selected), so it is smaller than
/// a `JPEG` capture from the sensor would be. That is a real quality trade-off
/// and it is recorded in `docs/DEVICE_TEST_CHECKLIST.md` as
/// something to measure on hardware rather than assumed here.
abstract class ArFrameGrabber {
  /// Opens the AR camera for stills and reports what it supports.
  ///
  /// Called once per station, after the AR session is up.
  Future<CameraCapabilities> probe();

  /// The most recent downsampled analysis frame, or `null` before one arrives.
  LiveFrame? grabFrame();

  /// Whether a frame has arrived since the last [grabFrame].
  bool get hasFreshFrame;

  /// A JPEG of the current AR camera image, or `null` when it could not be
  /// produced. The caller treats `null` as "this frame was not written" and
  /// leaves the target pending, so a failed still is retried rather than
  /// silently counted.
  Future<Uint8List?> takeStill();

  /// Exposure compensation, when the AR session exposes a usable range.
  ///
  /// ARCore's `CameraConfig` does not offer one, so the real implementation
  /// reports `exposureOffset: false` and this is a documented no-op. It is on
  /// the interface so the adapter does not have to special-case it.
  Future<void> setExposureOffset(double offset);

  /// Stops delivering frames. The session itself is closed by the AR layer.
  Future<void> release();
}

/// A [CaptureCamera] backed by an AR session.
///
/// Deliberately thin: it holds the capabilities the probe reported and forwards
/// everything else. All the interesting logic — the pose, the anchor, the drift
/// gate — lives in the `ar/` layer, and none of it belongs here.
class ArCaptureCamera implements CaptureCamera {
  final ArFrameGrabber grabber;

  CameraCapabilities _caps = CameraCapabilities.unavailable;

  ArCaptureCamera(this.grabber);

  @override
  CameraCapabilities get capabilities => _caps;

  @override
  Future<CameraCapabilities> initialize() async {
    _caps = await grabber.probe();
    return _caps;
  }

  @override
  LiveFrame? grabFrame() => grabber.grabFrame();

  @override
  bool get hasFreshFrame => grabber.hasFreshFrame;

  @override
  Future<Uint8List?> takeStill() => grabber.takeStill();

  @override
  Future<void> setExposureOffset(double offset) =>
      grabber.setExposureOffset(offset);

  @override
  bool get isRunning => _caps.ready;

  @override
  Future<void> dispose() async {
    await grabber.release();
    _caps = CameraCapabilities.unavailable;
  }

  @override
  String toString() => 'ArCaptureCamera(${_caps.summary()})';
}
