import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// One orientation reading, with everything the filter and the stability gate
/// need to judge it.
///
/// **Orientation only, deliberately.** The AR path's source is an ARCore camera
/// pose, which is already fused by ARCore; nothing here re-derives it. The legacy
/// sensor path supplies its own fused quaternion from `AttitudeFusion`. Either
/// way this type carries a *result*, not raw gyroscope counts — a distinction the
/// brief is explicit about.
class MotionSample {
  /// Orientation in this project's convention: `q·ẑ` is the optical axis, `q·ŷ`
  /// is up. Never an ARCore raw quaternion — see `arCameraPoseToCaptureWorld`.
  final Quat orientation;

  /// When the reading was produced, on a monotonic clock.
  final Duration at;

  /// Camera position, when the source has one. ARCore does; a gyro-only source
  /// does not, and must not pretend to.
  final Vec3? position;

  /// Angular rate in degrees per second, **only when a real gyroscope reported
  /// it**. `null` means "not measured" — never zero, which would read as "still".
  final double? angularRateDegPerSec;

  /// How old the underlying measurement was when it arrived. `null` when the
  /// source cannot say, in which case the gate treats it as fresh rather than
  /// inventing an age.
  final Duration? measurementAge;

  const MotionSample({
    required this.orientation,
    required this.at,
    this.position,
    this.angularRateDegPerSec,
    this.measurementAge,
  });

  /// Whether the quaternion is usable at all: finite and non-degenerate.
  ///
  /// A truncated platform payload or a NaN from a division produces a quaternion
  /// that normalises to garbage; smoothing it would smear the garbage forward for
  /// the length of the time constant, so it is rejected at the door.
  bool get isUsable =>
      orientation.x.isFinite &&
      orientation.y.isFinite &&
      orientation.z.isFinite &&
      orientation.w.isFinite &&
      orientation.length > 1e-6;

  MotionSample copyWith({Quat? orientation, Duration? at}) => MotionSample(
    orientation: orientation ?? this.orientation,
    at: at ?? this.at,
    position: position,
    angularRateDegPerSec: angularRateDegPerSec,
    measurementAge: measurementAge,
  );

  @override
  String toString() =>
      'MotionSample($orientation, at ${at.inMilliseconds} ms'
      '${position == null ? '' : ', pos $position'})';
}

/// Shortest rotation angle between two orientations, in degrees.
///
/// `2·atan2(|v|, |w|)` on the relative quaternion, which is numerically stable
/// for small angles where `2·acos(w)` loses most of its significant digits —
/// and small angles are exactly what a steadiness check spends its life
/// measuring.
///
/// The `|w|` handles quaternion sign ambiguity: `q` and `−q` are the same
/// rotation, and without the absolute value a sign flip would report 360° minus
/// the true angle instead of the true angle.
double angleBetweenDeg(Quat a, Quat b) {
  final rel = (b * a.conjugate).normalized;
  final v = math.sqrt(rel.x * rel.x + rel.y * rel.y + rel.z * rel.z);
  return 2 * math.atan2(v, rel.w.abs()) * radToDeg;
}

/// Angular speed implied by two orientations [dtSeconds] apart, in degrees per
/// second.
///
/// Returns `null` for a non-positive interval: dividing by zero would report an
/// infinite rate, and a duplicate timestamp is a scheduling artefact, not a
/// measurement.
double? angularRateFromQuaternions({
  required Quat from,
  required Quat to,
  required double dtSeconds,
}) {
  if (!(dtSeconds > 1e-6)) return null;
  return angleBetweenDeg(from, to) / dtSeconds;
}
