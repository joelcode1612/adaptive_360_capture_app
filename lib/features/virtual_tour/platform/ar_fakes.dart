import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/testkit/simulated_room.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_sources.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The scripted implementations every test drives the flow with.
///
/// The objects a device with no AR actually gets live in `ar_null_sources.dart`,
/// so that nothing in production has to import this file.

/// A scripted pose source, for tests and for the simulator.
///
/// It stores the pose as this project's world orientation and converts *into*
/// the AR convention on the way out, so a test can assert about yaw and pitch
/// in the same terms the engine uses. The conversion is the exact inverse of
/// [ArPose.captureWorld], which is the point: if the pair ever disagrees, the
/// guidance tests fail rather than the app pointing the wrong way.
class ScriptedArPoseSource implements ArPoseSource {
  @override
  ArCapabilities capabilities;

  @override
  TrackingState tracking;

  ArPose? _pose;

  ScriptedArPoseSource({
    this.capabilities = const ArCapabilities(
      supported: true,
      serviceInstalled: true,
      planes: true,
      anchors: true,
      intrinsics: null,
    ),
    this.tracking = TrackingState.tracking,
  });

  @override
  ArPose? get latest => _pose;

  @override
  Stream<ArPose> get poses => const Stream<ArPose>.empty();

  @override
  Future<ArCapabilities> start() async {
    // Re-opening resets tracking, which is what a real session does: a stopped
    // session that is started again begins in the initialising state, not in
    // the state it stopped in.
    tracking = TrackingState.tracking;
    return capabilities;
  }

  @override
  Future<void> stop() async {
    tracking = TrackingState.stopped;
    _pose = null;
  }

  /// Publishes a pose given in this project's world convention.
  void publishWorld({
    required Quat world,
    Vec3 position = Vec3.zero,
    double? angularRateDegPerSec,
  }) {
    _pose = ArPose(
      position: position,
      orientation: captureWorldToArPose(world),
      tracking: tracking,
      angularRateDegPerSec: angularRateDegPerSec,
    );
  }

  /// Publishes a raw AR-convention pose.
  void publishRaw(ArPose pose) => _pose = pose;

  void setTracking(TrackingState s) {
    tracking = s;
    if (s != TrackingState.tracking) _pose = null;
  }

  void setCapabilities(ArCapabilities c) => capabilities = c;

  @override
  String toString() => 'ScriptedArPoseSource($tracking)';
}

/// A scripted anchor source, for tests.
class ScriptedArStationAnchorSource implements ArStationAnchorSource {
  @override
  bool ready;

  PlaneHit? _hit;
  int _nextId = 1;
  final Map<String, ArAnchorHandle> _anchors = <String, ArAnchorHandle>{};
  Vec3? _camera;
  bool _refuseAnchors = false;

  ScriptedArStationAnchorSource({this.ready = true});

  /// Makes [createAnchor] return `null`, for the "the platform refused" path.
  set refuseAnchors(bool v) => _refuseAnchors = v;

  set hit(PlaneHit? h) => _hit = h;

  set camera(Vec3? v) => _camera = v;

  @override
  Future<bool> beginStationScan() async => ready;

  @override
  PlaneHit? hitTestCentre() => _hit;

  @override
  Future<PlaneHit?> refreshHitTest() async => _hit;

  @override
  Future<ArAnchorHandle?> createAnchor(PlaneHit hit) async {
    if (!ready || _refuseAnchors) return null;
    final a = ArAnchorHandle(
      id: 'a${_nextId++}',
      worldPosition: hit.worldPosition,
      tracking: TrackingState.tracking,
    );
    _anchors[a.id] = a;
    return a;
  }

  @override
  Future<ArAnchorHandle?> refreshAnchor(String id) async => _anchors[id];

  @override
  Future<Vec3?> cameraPosition() async => _camera;

  @override
  Future<void> detachAnchor(String id) async => _anchors.remove(id);

  @override
  Future<void> endStationScan() async => ready = false;

  /// Moves an anchor, for the drift tests.
  void driftAnchor(String id, Vec3 delta) {
    final a = _anchors[id];
    if (a == null) return;
    _anchors[id] = ArAnchorHandle(
      id: a.id,
      worldPosition: a.worldPosition + delta,
      tracking: a.tracking,
    );
  }

  /// Degrades an anchor's tracking state.
  void setAnchorTracking(String id, TrackingState s) {
    final a = _anchors[id];
    if (a == null) return;
    _anchors[id] = ArAnchorHandle(
      id: a.id,
      worldPosition: a.worldPosition,
      tracking: s,
    );
  }
}

/// The AR session's camera, scripted.
///
/// Renders the same procedural room [FakeCaptureCamera] does, so a flow test
/// exercises the AR path — session up, stills through the session, pose live —
/// with the same genuine image statistics the still-camera path produces.
///
/// It is a separate class rather than a flag on the fake camera because the two
/// stand for different things: one is "the sensor, owned by us", the other is
/// "the sensor, owned by ARCore". A test that mixes them up would pass while the
/// real app failed with "camera in use".
class ScriptedArFrameGrabber implements ArFrameGrabber {
  /// The scene to render, so a test can reproduce the blank-wall and
  /// poor-lighting cases.
  SimScene scene;

  /// The pose to render. The flow's rig keeps this in step with the target.
  double yawDeg;
  double pitchDeg;

  final double hfovDeg;
  final double vfovDeg;
  final int seed;

  /// Scripted still failures, consumed in order, for the retry path.
  final List<bool> failStills;

  bool _released = false;
  bool _fresh = false;
  LiveFrame? _latest;
  int _stillCalls = 0;

  /// The number of stills requested.
  int get stillCalls => _stillCalls;

  ScriptedArFrameGrabber({
    this.scene = const SimScene(),
    this.yawDeg = 0,
    this.pitchDeg = 0,
    this.hfovDeg = 55,
    this.vfovDeg = 70,
    this.seed = 3,
    this.failStills = const <bool>[],
  });

  @override
  Future<CameraCapabilities> probe() async {
    _released = false;
    // A real session has a camera image as soon as it is up, so the fake does
    // too. Without this, the first target of a station could be aimed at exactly
    // the pose the grabber already had, `refresh` would be skipped as redundant,
    // and the capture would fail on a null frame — a test-only trap.
    refresh();
    // `exposureOffset: false` is the honest answer, and the one the real
    // implementation gives: ARCore's camera config exposes no exposure
    // compensation, so the flow must fall back to asking the user to move.
    return const CameraCapabilities(
      ready: true,
      preview: true,
      stillCapture: true,
      imageStream: true,
      exposureOffset: false,
      focusPoint: false,
      exposurePoint: false,
      sensorOrientation: false,
      limitation: 'Exposure compensation is not adjustable through ARCore.',
    );
  }

  /// Re-renders the frame for the current pose.
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
    if (_released) return null;
    _fresh = false;
    return _latest;
  }

  @override
  bool get hasFreshFrame => _fresh;

  @override
  Future<Uint8List?> takeStill() async {
    if (_released) return null;
    final index = _stillCalls++;
    if (index < failStills.length && failStills[index]) return null;
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
  Future<void> setExposureOffset(double offset) async {}

  @override
  Future<void> release() async {
    _released = true;
    _latest = null;
    _fresh = false;
  }

  @override
  String toString() => 'ScriptedArFrameGrabber($_stillCalls stills)';
}
