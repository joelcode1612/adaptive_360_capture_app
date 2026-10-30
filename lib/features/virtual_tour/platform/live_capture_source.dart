import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_sources.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The live pose + frame source the capture state machine runs on.
///
/// `LiveSensorSource` is the domain's one seam to the outside world; this is
/// the implementation that fills it from ARCore and the camera. It is **pure
/// Dart** — it only touches the two interfaces — which is why a test can drive
/// the whole live path with `ScriptedArPoseSource` and `FakeCaptureCamera`
/// without a device, a plugin or a Flutter binding.
///
/// Note what it does *not* do: it never converts a quaternion to yaw and pitch
/// to hand those to the engine. The engine gets the unit quaternion and derives
/// display angles itself. Converting here and again there is how two sources of
/// truth appear.
class LiveCaptureSource implements LiveSensorSource {
  final ArPoseSource pose;
  final CaptureCamera camera;

  /// Where the station started, for the "face the start direction" recovery
  /// hint. `null` before a station is locked.
  final double? Function()? stationLockYawDeg;

  /// The gyroscope rate, in degrees per second.
  ///
  /// Preferred over [ArPose.angularRateDegPerSec] because ARCore does not report
  /// angular velocity at all, and because this source keeps working during the
  /// capture phase, when the AR session has already been closed to free the
  /// camera for stills.
  final double? Function()? angularRateProvider;

  LiveCaptureSource({
    required this.pose,
    required this.camera,
    this.stationLockYawDeg,
    this.angularRateProvider,
  });

  /// The camera's orientation in this project's world convention, or `null`
  /// when there is no usable pose.
  ///
  /// Returning `null` rather than the last known good pose is deliberate. A
  /// stale pose would let the machine decide the target is aligned and fire the
  /// shutter while the phone is actually pointing somewhere else, which
  /// produces a frame the stitcher cannot place and the user cannot see coming.
  @override
  Quat? sensedOrientation() {
    final p = pose.latest;
    if (p == null || !p.tracking.usable) return null;
    return p.captureWorld;
  }

  @override
  double? angularRateDegPerSec() =>
      angularRateProvider?.call() ?? pose.latest?.angularRateDegPerSec;

  @override
  LiveFrame? grabFrame() => camera.grabFrame();

  /// The SURVEY phase, in live mode.
  ///
  /// The reference walks a procedural room here. With a real camera there is no
  /// room model to walk — the environment *is* the room — so the survey has
  /// nothing to do and completes immediately. The phase is kept in the sequence
  /// because the order is part of the ported contract and the log reads the
  /// same in both modes.
  @override
  bool survey() => true;

  /// What to tell the user when there is no usable pose.
  ///
  /// The brief asks for a specific recovery: guide the user to face the
  /// direction they started from. That is actionable without knowing the
  /// current heading, which is exactly the situation — if we knew the heading we
  /// would not be showing this.
  @override
  String? get trackingAdvice {
    final t = pose.tracking;
    final base = t.advice;
    if (t == TrackingState.tracking) return null;
    final locked = stationLockYawDeg?.call() != null;
    if (!locked) return base;
    return '${base ?? 'AR cannot follow the room right now.'} '
        'Point the phone back towards where you started this station, then '
        'hold still until tracking returns. Frames you have already captured '
        'are safe.';
  }

  /// Whether the pose is healthy enough to guide the user.
  bool get isGuiding => pose.tracking.usable && pose.latest != null;

  @override
  String toString() =>
      'LiveCaptureSource(${pose.tracking.name}, '
      'camera ${camera.capabilities.ready ? 'ready' : 'not ready'})';
}
