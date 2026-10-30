import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Station-origin drift check.
///
/// The ARCore anchor is used for exactly one thing: measuring how far the
/// camera has moved from the station where the panorama group started. This is
/// the *only* reason to have an anchor, and it is pure geometry, so it lives in
/// the domain and is unit-tested rather than being buried in the AR layer.
///
/// The threshold is **not** assumed. [StationAnchorPolicy.driftToleranceM]
/// must be supplied by the caller, because the right value depends on the
/// lens, the room and how much parallax the stitcher can absorb.

/// A world-space station origin.
class StationOrigin {
  final Vec3 worldPosition;

  /// Device yaw at lock time, for the floor-plan heading lock.
  final double lockYawDeg;

  /// Camera height at lock time, in metres.
  final double lockCameraHeightM;

  /// Whether the origin came from a plane hit-test or was estimated.
  final StationConfidence confidence;

  const StationOrigin({
    required this.worldPosition,
    required this.lockYawDeg,
    required this.lockCameraHeightM,
    required this.confidence,
  });

  @override
  String toString() =>
      'StationOrigin(${worldPosition.x.toStringAsFixed(2)}, '
      '${worldPosition.y.toStringAsFixed(2)}, '
      '${worldPosition.z.toStringAsFixed(2)}, '
      'yaw ${lockYawDeg.toStringAsFixed(1)}°, ${confidence.name})';
}

/// How the station origin was obtained.
enum StationConfidence {
  /// A hit-test landed on a tracked plane.
  plane,

  /// AR was available but no plane was found in time.
  estimated,

  /// No AR support; the origin came from a manual entry or is absent.
  manual,
}

/// Configurable drift policy.
class StationAnchorPolicy {
  /// Distance from the origin, in metres, beyond which capture pauses.
  ///
  /// **Deliberately has no default.** A sensible value depends on the lens and
  /// the stitcher, and guessing it would be worse than requiring it.
  final double driftToleranceM;

  /// Hysteresis: the user must return inside this fraction of the tolerance
  /// before capture resumes, so the pause does not chatter at the boundary.
  final double resumeFraction;

  const StationAnchorPolicy({
    required this.driftToleranceM,
    this.resumeFraction = 0.7,
  });
}

/// Result of evaluating the current camera position against the station origin.
class StationDrift {
  /// Horizontal distance from the origin, in metres.
  final double horizontalM;

  /// Full 3D distance, in metres.
  final double totalM;

  /// True when capture must pause.
  final bool exceedsTolerance;

  /// True when capture may resume (with hysteresis applied).
  final bool mayResume;

  /// Human-readable instruction, or null when the user is within tolerance.
  final String? guidance;

  const StationDrift({
    required this.horizontalM,
    required this.totalM,
    required this.exceedsTolerance,
    required this.mayResume,
    required this.guidance,
  });

  @override
  String toString() =>
      '${horizontalM.toStringAsFixed(3)} m '
      '${exceedsTolerance ? '(PAUSE)' : ''}';
}

/// Evaluates the camera's displacement from the station origin.
///
/// [wasPaused] feeds the hysteresis: once paused, the user must come back
/// inside `resumeFraction × tolerance` before capture restarts.
StationDrift evaluateStationDrift({
  required StationOrigin origin,
  required Vec3 cameraPosition,
  required StationAnchorPolicy policy,
  bool wasPaused = false,
}) {
  final dx = cameraPosition.x - origin.worldPosition.x;
  final dz = cameraPosition.z - origin.worldPosition.z;
  final dy = cameraPosition.y - origin.worldPosition.y;

  final horizontal = math.sqrt(dx * dx + dz * dz);
  final total = math.sqrt(dx * dx + dy * dy + dz * dz);

  final limit = policy.driftToleranceM;
  final resumeLimit = limit * policy.resumeFraction;

  // A station origin with no anchor (no AR support) cannot gate anything.
  if (origin.confidence == StationConfidence.manual) {
    return StationDrift(
      horizontalM: horizontal,
      totalM: total,
      exceedsTolerance: false,
      mayResume: true,
      guidance: null,
    );
  }

  final exceeds = wasPaused ? horizontal > resumeLimit : horizontal > limit;

  return StationDrift(
    horizontalM: horizontal,
    totalM: total,
    exceedsTolerance: exceeds,
    mayResume: !exceeds,
    guidance: exceeds
        ? 'You are ${horizontal.toStringAsFixed(2)} m from the station. '
              'Move back to the marked position (limit '
              '${limit.toStringAsFixed(2)} m).'
        : null,
  );
}
