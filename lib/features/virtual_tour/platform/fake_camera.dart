import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/testkit/simulated_room.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';

/// A camera that renders the procedural room instead of using hardware.
///
/// This is what lets the whole live path — sensor source, analysis, validation,
/// storage — be exercised end to end in a test with no device. It produces
/// **real frames**: the same `renderSim` the engine's tests use, at the same
/// analysis resolution, so the quality metrics the flow sees are genuine
/// measurements of a genuine image rather than canned numbers.
///
/// It is explicitly not a camera: [takeStill] returns a tiny placeholder rather
/// than a photograph, because nothing in the tested flow inspects the JPEG's
/// pixels — the panorama is stitched by the backend, and asserting on a fake
/// JPEG's bytes would only test the fake.
class FakeCaptureCamera implements CaptureCamera {
  /// The scene to render. `blank` and `light` let a test reproduce the blank-wall
  /// and poor-lighting cases from the reference's scenarios.
  SimScene scene;

  /// The pose the fake camera is pointing at. The test (or the flow's sensor
  /// source) sets this; [grabFrame] renders what that pose would see.
  double yawDeg = 0;
  double pitchDeg = 0;

  final double hfovDeg;
  final double vfovDeg;

  /// Seed for the render noise, so a test is reproducible.
  final int seed;

  /// Scripted failures, consumed in order. Each entry makes the corresponding
  /// `takeStill` call fail, which is how the retry path is driven.
  final List<bool> failStills;

  /// When set, [setExposureOffset] is refused, mimicking a device that reports a
  /// range and then ignores it.
  bool refuseExposure;

  CameraCapabilities _caps = CameraCapabilities.unavailable;
  LiveFrame? _latest;
  bool _fresh = false;
  int _stillCalls = 0;

  /// The exposure offsets that were successfully applied, for assertions.
  final List<double> appliedExposure = <double>[];

  /// The number of stills requested.
  int get stillCalls => _stillCalls;

  FakeCaptureCamera({
    this.scene = const SimScene(),
    this.hfovDeg = 55,
    this.vfovDeg = 70,
    this.seed = 3,
    this.failStills = const <bool>[],
    this.refuseExposure = false,
  });

  @override
  CameraCapabilities get capabilities => _caps;

  @override
  bool get isRunning => _caps.ready;

  @override
  bool get hasFreshFrame => _fresh;

  @override
  Future<CameraCapabilities> initialize() async {
    _caps = CameraCapabilities(
      ready: true,
      preview: true,
      stillCapture: true,
      imageStream: true,
      exposureOffset: !refuseExposure,
      minExposureOffset: refuseExposure ? null : -4,
      maxExposureOffset: refuseExposure ? null : 4,
      focusPoint: true,
      exposurePoint: true,
      sensorOrientation: true,
      limitation: refuseExposure
          ? 'exposure compensation is not adjustable'
          : null,
    );
    refresh();
    return _caps;
  }

  /// Re-renders the frame for the current pose. Call after moving the pose.
  void refresh() {
    _latest = LiveFrame(
      rgba: renderSim(
        analysisWidth,
        analysisHeight,
        yawDeg,
        pitchDeg,
        hfovDeg,
        vfovDeg,
        scene,
        Mulberry32(seed),
      ),
      w: analysisWidth,
      h: analysisHeight,
    );
    _fresh = true;
  }

  @override
  LiveFrame? grabFrame() {
    _fresh = false;
    return _latest;
  }

  @override
  Future<Uint8List?> takeStill() async {
    final index = _stillCalls++;
    if (index < failStills.length && failStills[index]) return null;
    // A 1×1 baseline JPEG is more than the tested flow needs, but it is a real
    // JPEG header, so anything that sniffs the magic bytes keeps working.
    return Uint8List.fromList(<int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0xFF,
      0xD9,
    ]);
  }

  @override
  Future<void> setExposureOffset(double offset) async {
    if (refuseExposure || !_caps.exposureOffset) return;
    appliedExposure.add(offset);
  }

  @override
  Future<void> dispose() async {
    _latest = null;
    _fresh = false;
    _caps = CameraCapabilities.unavailable;
  }
}
