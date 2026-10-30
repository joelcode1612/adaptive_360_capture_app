import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/orientation_filter.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// Time-constant quaternion smoothing for the guidance display, with three
/// deliberate escape hatches.
///
/// ## What it is for
///
/// ARCore reports a fused pose at ~30 Hz. Consecutive frames disagree by a
/// fraction of a degree even when the phone is still, and that disagreement moves
/// the guidance arrow and flickers the instruction. Smoothing removes the flicker
/// from the *display* while the gate keeps reading the unsmoothed pose.
///
/// **It does not make the orientation more accurate.** It cannot: the input is
/// already ARCore's best estimate, and averaging two noisy estimates of the same
/// quantity does not add information. This filter is a presentation filter, and
/// every claim about it in this project is about jitter and latency, never about
/// accuracy.
///
/// ## The coefficient
///
/// ```
/// alpha = 1 − exp(−dt / tau)
/// ```
///
/// Frame-rate independent by construction: a 16 ms step and a 33 ms step produce
/// the same *time* response, so a phone that throttles to 20 Hz does not become
/// four times smoother (and four times laggier) than one running at 60 Hz. A
/// fixed `alpha` per sample would do exactly that, which is the usual bug.
///
/// ## The three escape hatches
///
/// Smoothing is wrong in three situations, and each is handled explicitly rather
/// than by tuning `tau` down until they stop mattering:
///
/// 1. **No previous state** — first sample, or after [reset]. Snap.
/// 2. **A gap** — `dt` longer than [maxGapSeconds], or non-positive. The user
///    paused, the app was backgrounded, or the clock repeated. Interpolating
///    across it would smear a stale orientation into the present. Snap.
/// 3. **A large jump** — the target is more than [snapAngleDeg] from the current
///    estimate. Either the user deliberately turned towards another target, or
///    tracking was re-acquired somewhere else. Both need the display to arrive
///    immediately; a smoother that lags a 90° turn by 300 ms makes the guidance
///    actively wrong. Snap.
///
/// Escape hatch 3 is what makes this *adaptive*: within [snapAngleDeg] the filter
/// behaves as a first-order low-pass; beyond it, it is transparent.
class AdaptiveQuaternionSmoother implements OrientationFilter {
  /// Smoothing time constant in seconds. Larger is smoother and laggier.
  ///
  /// 120 ms is a starting value, not a validated one: at 30 Hz it settles a
  /// small correction in roughly three frames, which is fast enough that the
  /// arrow does not trail the hand, and slow enough to remove frame jitter.
  final double tauSeconds;

  /// A gap longer than this is a discontinuity, not a sample interval.
  final double maxGapSeconds;

  /// A jump larger than this is a turn or a re-acquisition, not jitter.
  final double snapAngleDeg;

  Quat? _state;
  Duration? _lastAt;

  int _samples = 0;
  int _snaps = 0;

  AdaptiveQuaternionSmoother({
    this.tauSeconds = 0.12,
    this.maxGapSeconds = 0.5,
    this.snapAngleDeg = 25,
  }) : assert(tauSeconds > 0, 'tau must be positive'),
       assert(maxGapSeconds > 0, 'maxGap must be positive'),
       assert(snapAngleDeg > 0, 'snapAngle must be positive');

  @override
  Quat? get state => _state;

  /// How many samples have been filtered.
  int get sampleCount => _samples;

  /// How many of them bypassed smoothing. A high ratio on a still phone means
  /// the input is jumping, which is worth knowing rather than hiding.
  int get snapCount => _snaps;

  /// Fraction of samples that were smoothed rather than snapped, 0…1.
  double get smoothingFraction => _samples == 0 ? 0 : 1 - _snaps / _samples;

  @override
  Quat filter(MotionSample sample) {
    // Invalid input is dropped, not smoothed: a NaN would otherwise poison the
    // state for the length of the time constant.
    if (!sample.isUsable) return _state ?? Quat.identity;

    final target = sample.orientation.normalized;
    final last = _lastAt;
    final previous = _state;
    _samples++;

    if (previous == null || last == null) return _snap(target, sample.at);

    final dt = (sample.at - last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > maxGapSeconds) return _snap(target, sample.at);

    if (angleBetweenDeg(previous, target) > snapAngleDeg) {
      return _snap(target, sample.at);
    }

    final alpha = (1 - math.exp(-dt / tauSeconds)).clamp(0.0, 1.0);
    // `Quat.slerp` normalises and takes the shorter arc (it flips the second
    // operand when the dot product is negative), so the sign ambiguity of the
    // double cover is handled there rather than here.
    _state = Quat.slerp(previous, target, alpha).normalized;
    _lastAt = sample.at;
    return _state!;
  }

  Quat _snap(Quat target, Duration at) {
    _snaps++;
    _state = target;
    _lastAt = at;
    return target;
  }

  @override
  void reset() {
    _state = null;
    _lastAt = null;
    _samples = 0;
    _snaps = 0;
  }

  @override
  String toString() =>
      'AdaptiveQuaternionSmoother(tau $tauSeconds s, snap $snapAngleDeg°, '
      'smoothed ${(smoothingFraction * 100).toStringAsFixed(0)}%)';
}
