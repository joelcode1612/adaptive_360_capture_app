import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// What the guidance display needs from an orientation filter.
///
/// One method in, one quaternion out, plus a reset. Kept this narrow so a test
/// can substitute a pass-through filter and prove that a behaviour belongs to the
/// smoother rather than to the controller.
abstract class OrientationFilter {
  /// Filters one sample and returns the orientation to *display*.
  ///
  /// Must be pure with respect to its input: no clock reads, no platform calls.
  /// The timestamp travels on [MotionSample] so a test can drive any cadence.
  Quat filter(MotionSample sample);

  /// Forgets all state. Called on session start, on tracking loss and whenever a
  /// reference change makes the previous estimate meaningless.
  void reset();

  /// The current smoothed orientation, or `null` before the first sample.
  Quat? get state;
}

/// A filter that does nothing, for measuring the baseline and for tiers where
/// smoothing is not wanted.
///
/// Having it as a real class rather than a `null` check keeps the controller free
/// of `if (smoother != null)` branches and lets the comparison harness swap
/// implementations without special cases.
class PassthroughOrientationFilter implements OrientationFilter {
  Quat? _state;

  @override
  Quat filter(MotionSample sample) {
    if (!sample.isUsable) return _state ?? Quat.identity;
    _state = sample.orientation.normalized;
    return _state!;
  }

  @override
  void reset() => _state = null;

  @override
  Quat? get state => _state;
}
