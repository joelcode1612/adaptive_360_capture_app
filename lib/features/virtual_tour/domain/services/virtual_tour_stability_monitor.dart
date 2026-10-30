import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Why the 600 ms stability window was refused or restarted.
enum VirtualTourStabilityIssue {
  /// The pose is older than the 150 ms budget.
  poseAge,

  /// The phone is rotating faster than 3 °/s.
  angularRate,

  /// The orientation moved more than 1.0° across the window.
  orientationDrift,

  /// The camera moved more than 0.02 m across the window.
  positionDrift,

  /// The window has not filled yet.
  window,
}

/// Decides whether a phone has been held still long enough for a 30-node shot.
///
/// Pure Dart and clock-injected: [update] receives a monotonic [Duration], never
/// `DateTime.now()`, so a test can walk through a 600 ms window instantly and a
/// device cannot be fooled by a wall-clock adjustment.
///
/// The monitor is updated every frame so the angular rate and pose age stay
/// visible even when the user is not aimed at a target, but the window only
/// accumulates while [gateOpen] is true. Closing a gate — losing alignment,
/// drifting, a cooldown, or tracking loss — clears the window immediately, which
/// is what stops "steady while pointing somewhere else" from counting.
class VirtualTourStabilityMonitor {
  VirtualTourStabilityMonitor({
    this.window = const Duration(milliseconds: 600),
    this.maxAngularVelocityDegPerSec = 3.0,
    this.maxOrientationDriftDeg = 1.0,
    this.maxPositionDriftM = 0.02,
    this.maxPoseAge = const Duration(milliseconds: 150),
    this.rateBaseline = const Duration(milliseconds: 100),
  }) : assert(window > Duration.zero);

  final Duration window;
  final double maxAngularVelocityDegPerSec;
  final double maxOrientationDriftDeg;
  final double maxPositionDriftM;
  final Duration maxPoseAge;

  /// The span the derived rate is measured over.
  ///
  /// Differencing consecutive ARCore poses turns frame-to-frame jitter into an
  /// apparent rotation; measuring over 100 ms averages that noise while still
  /// catching a real turn inside the window.
  final Duration rateBaseline;

  final List<_StabilitySample> _samples = <_StabilitySample>[];
  final List<_StabilitySample> _rateHistory = <_StabilitySample>[];

  bool _stable = false;
  Duration _held = Duration.zero;
  double? _lastAngularRateDegPerSec;
  Duration? _lastPoseAge;
  double? _lastOrientationDriftDeg;
  double? _lastPositionDriftM;
  VirtualTourStabilityIssue? _lastIssue;

  bool get isStable => _stable;
  Duration get heldFor => _held;
  double? get lastAngularRateDegPerSec => _lastAngularRateDegPerSec;
  Duration? get lastPoseAge => _lastPoseAge;
  double? get lastOrientationDriftDeg => _lastOrientationDriftDeg;
  double? get lastPositionDriftM => _lastPositionDriftM;
  VirtualTourStabilityIssue? get lastIssue => _lastIssue;

  double get progress {
    final total = window.inMicroseconds;
    if (total <= 0) return 1;
    return (_held.inMicroseconds / total).clamp(0.0, 1.0);
  }

  void reset() {
    _samples.clear();
    _rateHistory.clear();
    _stable = false;
    _held = Duration.zero;
    _lastAngularRateDegPerSec = null;
    _lastPoseAge = null;
    _lastOrientationDriftDeg = null;
    _lastPositionDriftM = null;
    _lastIssue = null;
  }

  /// Feeds one pose and returns whether the window is complete.
  ///
  /// [poseAge] is the time since the pose was produced on the same monotonic
  /// clock as [now]. A `null` age means the source cannot say; it is treated as
  /// fresh rather than inventing a failure.
  ///
  /// [angularRateDegPerSec] must come from a real gyroscope. It may only raise
  /// the verdict: a biased gyro reports several °/s on a motionless phone, while
  /// a genuine turn also shows up in the pose delta. The pose stream is the
  /// authority; the gyro is used alone only on the first sample, before a
  /// baseline exists.
  bool update({
    required Duration now,
    required Quat orientation,
    required Vec3 position,
    Duration? poseAge,
    double? angularRateDegPerSec,
    bool gateOpen = true,
  }) {
    _lastPoseAge = poseAge;

    _rateHistory.add(
      _StabilitySample(at: now, orientation: orientation, position: position),
    );
    if (_rateHistory.length > 12) _rateHistory.removeAt(0);

    final rate = _rateFor(now, orientation, angularRateDegPerSec);
    _lastAngularRateDegPerSec = rate;
    _lastOrientationDriftDeg = null;
    _lastPositionDriftM = null;

    if (poseAge != null && poseAge > maxPoseAge) {
      return _refuse(VirtualTourStabilityIssue.poseAge);
    }
    if (!gateOpen) {
      _samples.clear();
      _stable = false;
      _held = Duration.zero;
      if (_lastIssue == VirtualTourStabilityIssue.poseAge) {
        _lastIssue = null;
      }
      return false;
    }
    if (rate != null && rate > maxAngularVelocityDegPerSec) {
      return _refuse(VirtualTourStabilityIssue.angularRate);
    }

    final cutoff = now - window;
    while (_samples.length > 1 && _samples[1].at <= cutoff) {
      _samples.removeAt(0);
    }
    _samples.add(
      _StabilitySample(at: now, orientation: orientation, position: position),
    );
    _held = now - _samples.first.at;

    // Keep the window bounded even at a high pose rate; 600 ms of 60 Hz poses
    // is 36 samples, and older ones can never become relevant again.
    final maxSamples = (window.inMilliseconds / 16).ceil() + 4;
    if (_samples.length > maxSamples) _samples.removeAt(0);

    if (_samples.length < 2) {
      _stable = false;
      _lastIssue = VirtualTourStabilityIssue.window;
      return false;
    }

    final oldest = _samples.first;
    final driftDeg = _quaternionAngleDeg(oldest.orientation, orientation);
    final driftM = (position - oldest.position).length;
    _lastOrientationDriftDeg = driftDeg;
    _lastPositionDriftM = driftM;

    if (driftDeg > maxOrientationDriftDeg) {
      return _refuse(VirtualTourStabilityIssue.orientationDrift);
    }
    if (driftM > maxPositionDriftM) {
      return _refuse(VirtualTourStabilityIssue.positionDrift);
    }

    final spansWindow = now - oldest.at >= window;
    if (!spansWindow) {
      _stable = false;
      _lastIssue = VirtualTourStabilityIssue.window;
      return false;
    }

    _stable = true;
    _lastIssue = null;
    return true;
  }

  double? _rateFor(Duration now, Quat orientation, double? gyroRate) {
    _StabilitySample? anchor;
    for (final sample in _rateHistory) {
      if (now - sample.at >= rateBaseline) anchor = sample;
    }
    anchor ??= _rateHistory.isEmpty ? null : _rateHistory.first;

    double? rate;
    if (anchor != null) {
      final dt = (now - anchor.at).inMicroseconds / 1e6;
      if (dt >= 0.02) {
        rate = _quaternionAngleDeg(anchor.orientation, orientation) / dt;
      }
    }
    if (rate == null) {
      rate = gyroRate;
    } else if (gyroRate != null &&
        gyroRate > maxAngularVelocityDegPerSec &&
        rate > maxAngularVelocityDegPerSec * 0.25) {
      rate = gyroRate;
    }
    return rate;
  }

  bool _refuse(VirtualTourStabilityIssue issue) {
    _samples.clear();
    _stable = false;
    _held = Duration.zero;
    _lastIssue = issue;
    return false;
  }
}

class _StabilitySample {
  final Duration at;
  final Quat orientation;
  final Vec3 position;

  const _StabilitySample({
    required this.at,
    required this.orientation,
    required this.position,
  });
}

/// Shortest rotation angle between two orientations, in degrees.
///
/// `2·atan2(|v|, |w|)` rather than `2·acos(w)`: the former keeps precision for
/// the small angles this gate measures all day, and `|w|` folds the quaternion
/// sign ambiguity so `q` and `−q` do not read as a full turn.
double _quaternionAngleDeg(Quat a, Quat b) {
  final rel = (b * a.conjugate).normalized;
  final v = math.sqrt(rel.x * rel.x + rel.y * rel.y + rel.z * rel.z);
  return 2 * math.atan2(v, rel.w.abs()) * radToDeg;
}
