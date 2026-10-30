import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_sources.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The null objects for devices where a capability genuinely does not exist.
///
/// Split out of `ar_fakes.dart` on purpose: that file is test scaffolding, and
/// production must not depend on it. A real phone with no ARCore and no motion
/// sensors is handed the classes below, which is a product behaviour, not a
/// fixture.
///
/// Having a real null object — rather than `null` itself — is what keeps the
/// flow free of `if (ar != null)`. The UI asks for a pose, gets `null`, and
/// shows the manual path; the tier ladder has already said why.

/// A pose source that never produces a pose.
class NoArPoseSource implements ArPoseSource {
  final ArCapabilities _caps;
  final String _reason;

  NoArPoseSource({String? reason})
    : _reason = reason ?? 'AR is not available on this device.',
      _caps = ArCapabilities(
        supported: false,
        reason: reason ?? 'AR is not available on this device.',
      );

  @override
  ArCapabilities get capabilities => _caps;

  @override
  TrackingState get tracking => TrackingState.unavailable;

  @override
  ArPose? get latest => null;

  @override
  Stream<ArPose> get poses => const Stream<ArPose>.empty();

  @override
  Future<ArCapabilities> start() async => _caps;

  @override
  Future<void> stop() async {}

  @override
  String toString() => 'NoArPoseSource($_reason)';
}

/// An anchor source that never places an anchor.
///
/// [hitTestCentre] returning `null` is the important part: a station button that
/// reads it stays disabled rather than appearing to work. This is also what a
/// sensor-only build uses — the motion sensors give a direction, never a point on
/// the floor, so there is nothing to anchor to and nothing to measure drift
/// against.
class NoArStationAnchorSource implements ArStationAnchorSource {
  @override
  bool get ready => false;

  @override
  Future<bool> beginStationScan() async => false;

  @override
  PlaneHit? hitTestCentre() => null;

  @override
  Future<PlaneHit?> refreshHitTest() async => null;

  @override
  Future<ArAnchorHandle?> createAnchor(PlaneHit hit) async => null;

  @override
  Future<ArAnchorHandle?> refreshAnchor(String id) async => null;

  @override
  Future<Vec3?> cameraPosition() async => null;

  @override
  Future<void> detachAnchor(String id) async {}

  @override
  Future<void> endStationScan() async {}
}
