import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// Where the camera pose comes from.
///
/// The capture flow only ever asks two questions — "what is the pose now" and
/// "is tracking healthy" — so this interface is deliberately no wider than
/// that. Both the ARCore implementation and the "no AR" implementation satisfy
/// it, which is what lets the flow run, degrade or refuse without any `if
/// (isAndroid)` in the UI.
abstract class ArPoseSource {
  /// What the platform reported during [start].
  ArCapabilities get capabilities;

  /// Whether poses are arriving and usable right now.
  TrackingState get tracking;

  /// The most recent pose, or `null` before the first sample or after tracking
  /// was lost.
  ArPose? get latest;

  /// Starts the pose stream. Returns the capabilities that were measured.
  Future<ArCapabilities> start();

  /// Stops the pose stream and releases the camera.
  ///
  /// This matters more than it looks: ARCore and the Camera2/CameraX stack
  /// cannot hold the camera at the same time, so the AR session has to be torn
  /// down before the still-capture camera is opened. The capture screen calls
  /// this as soon as the station's pose has been recorded.
  Future<void> stop();

  /// Pose samples, for a UI that wants to react rather than poll.
  Stream<ArPose> get poses;
}

/// Where the station anchor comes from.
///
/// Used for exactly one purpose, as the brief requires: measuring how far the
/// camera has drifted from the station so the flow can pause and guide the user
/// back. It never gates the shutter and it never stops the user moving.
abstract class ArStationAnchorSource {
  /// Whether the platform can hit-test and anchor at all.
  bool get ready;

  /// Starts plane detection for a station. Returns false when plane detection
  /// could not be enabled.
  Future<bool> beginStationScan();

  /// Hit-tests the screen centre against tracked planes.
  ///
  /// Returns `null` when the ray missed — which the UI must treat as "the
  /// button stays disabled", not as "place the anchor at a guessed point".
  PlaneHit? hitTestCentre();

  /// Re-runs the screen-centre hit-test and returns the fresh result.
  ///
  /// The platform call is asynchronous, while [hitTestCentre] is synchronous so
  /// that the interface stays usable from a `build`. The default implementation
  /// just forwards, which is correct for every synchronous source; the ARCore
  /// implementation overrides it to actually re-run the ray, because the phone
  /// moves between the preview and the tap.
  Future<PlaneHit?> refreshHitTest() async => hitTestCentre();

  /// Creates an anchor at a hit. Returns `null` when the platform refused.
  Future<ArAnchorHandle?> createAnchor(PlaneHit hit);

  /// Re-reads an anchor's world position, for the drift check.
  Future<ArAnchorHandle?> refreshAnchor(String id);

  /// The camera's current world position, for the drift check.
  Future<Vec3?> cameraPosition();

  /// Releases an anchor.
  Future<void> detachAnchor(String id);

  /// Ends the station scan and tears down the AR session.
  Future<void> endStationScan();
}
