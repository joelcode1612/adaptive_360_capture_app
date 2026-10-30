import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Whether the phone has been steady long enough to take the photograph.
///
/// **Pure Dart and clock-injected**, because "stable for 450 ms" is a statement
/// about a sequence of samples, and the only honest way to test a sequence is to
/// supply the timestamps.
///
/// Four conditions have to hold, and each closes a different hole:
///
/// | Condition | What it stops |
/// | --- | --- |
/// | alignment error inside tolerance | a photograph of the wrong direction |
/// | orientation drift across the window ≤ [maxOrientationDriftDeg] | a phone passing *through* the target at speed |
/// | position drift ≤ [maxPositionDriftM] | the user walking away mid-window |
/// | angular rate ≤ [maxAngularVelocityDegPerSec] | the phone being carried rather than held |
/// | measurement age ≤ [maxMeasurementAge] | acting on a stale reading after tracking stalled |
///
/// The angular-rate gate is new and is the one that matters most in practice: a
/// phone moving at a constant 20 °/s through a target has *zero* drift relative
/// to a 450 ms-old sample only if the motion is uniform and the window short,
/// whereas the rate is unambiguous on every single sample.
///
/// The rate is taken from the platform's gyroscope when one reports it, and
/// otherwise estimated from **consecutive orientations** — never by subtracting
/// Euler angles, which wrap and mislead near ±180°.
class StabilityMonitor {
  StabilityMonitor({
    required this.window,
    this.maxOrientationDriftDeg = 1.5,
    this.maxPositionDriftM = 0.03,
    this.maxAngularVelocityDegPerSec = 5,
    this.maxMeasurementAge = const Duration(milliseconds: 250),
    this.rateBaseline = const Duration(milliseconds: 100),
    this.alignmentHysteresisDeg = 2,
  });

  /// How far past the alignment tolerance the error may drift before the
  /// window is discarded, in degrees.
  ///
  /// The strict tolerance still gates the shutter — `AlignmentResult.withinTolerance`
  /// is unchanged — but the *window* survives the last couple of degrees. On a
  /// real phone the raw 3-D error wanders around the tolerance while the user
  /// holds still; refusing on every excursion above it cleared the window on
  /// nearly every frame and left the app on "Hold still…" forever. This is
  /// the difference between "is this frame good enough" and "is the user
  /// holding it", and only the second question belongs here.
  final double alignmentHysteresisDeg;

  /// How long the conditions must hold. 450 ms, the starting value the brief
  /// names; a development parameter to be validated on hardware.
  final Duration window;

  /// How far the orientation may wander across the window, in degrees.
  final double maxOrientationDriftDeg;

  /// How far the position may wander across the window, in metres.
  final double maxPositionDriftM;

  /// The fastest rotation that still counts as "held still", in degrees/second.
  ///
  /// 5 °/s is deliberately tight: at that rate the phone moves a degree in
  /// 200 ms, which is a fifth of the alignment tolerance, so a shot taken at the
  /// limit is still framed correctly.
  final double maxAngularVelocityDegPerSec;

  /// The oldest reading that may still be acted on.
  final Duration maxMeasurementAge;

  /// The baseline the derived angular rate is measured over.
  ///
  /// **Not the frame interval.** Differencing two consecutive poses turns
  /// frame-to-frame jitter into apparent rotation: at 30 Hz, ±0.35° of noise is
  /// 0.7° in 33 ms — **21 °/s**, four times the gate's budget — so a perfectly
  /// still phone would be refused. Measured over 100 ms the same noise averages
  /// to a few °/s, while a genuine turn is still caught inside 100 ms.
  ///
  /// This was found by the comparison harness, not by inspection.
  final Duration rateBaseline;

  final List<_Sample> _samples = <_Sample>[];

  /// A short, refusal-proof history used only to measure the rate.
  ///
  /// Separate from [_samples] on purpose: [_refuse] clears the stability window,
  /// and clearing the rate history with it would blind the gate for the next few
  /// samples — exactly when the phone is most likely to still be moving.
  final List<_Sample> _rateHistory = <_Sample>[];

  bool _stable = false;
  Duration _held = Duration.zero;

  /// Diagnostics for the last [update], exposed rather than hidden so the UI and
  /// the comparison harness can show *why* a shot was refused.
  double? _lastAngularRate;
  Duration? _lastAge;
  String? _lastRejection;

  bool get isStable => _stable;
  Duration get heldFor => _held;
  double? get lastAngularVelocityDegPerSec => _lastAngularRate;
  Duration? get lastMeasurementAge => _lastAge;

  /// Why the last update refused, or `null` when it did not.
  ///
  /// One of `alignment`, `angular-rate`, `measurement-age`, `orientation-drift`,
  /// `position-drift`, `window`.
  String? get lastRejection => _lastRejection;

  /// 0…1, for a progress ring.
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
    _lastAngularRate = null;
    _lastAge = null;
    _lastRejection = null;
  }

  /// Feeds one pose sample and returns whether the phone is stable now.
  ///
  /// [now] is injected rather than read from the clock so a test can walk the
  /// monitor through a window without waiting for one.
  ///
  /// [angularRateDegPerSec] must be supplied **only** when a real gyroscope
  /// reported it. When it is `null` the rate is estimated from the previous
  /// sample's orientation; when there is no previous sample the rate is unknown
  /// and the gate is skipped for that one reading, because two samples are
  /// needed before the window can be satisfied anyway.
  bool update({
    required DateTime now,
    required RigidPose pose,
    required AlignmentResult alignment,
    Duration? measurementAge,
    double? angularRateDegPerSec,
  }) {
    // Prune, but keep the newest sample at or before the cutoff.
    //
    // A plain `removeWhere(at.isBefore(cutoff))` deletes exactly the sample that
    // proves the window has elapsed: with 60 ms samples and a 450 ms window the
    // oldest survivor is always 420 ms old, so `heldFor` can never reach the
    // window and the shutter never fires. Keeping one sample from *before* the
    // cutoff is what makes "held for at least the window" true.
    final cutoff = now.subtract(window);
    while (_samples.length > 1 && !_samples[1].at.isAfter(cutoff)) {
      _samples.removeAt(0);
    }

    _lastAge = measurementAge;

    // Stale readings first: acting on an old pose is the one failure that makes
    // every other measurement meaningless.
    if (measurementAge != null && measurementAge > maxMeasurementAge) {
      return _refuse('measurement-age');
    }

    // An unusable alignment or a tracking gap breaks the run immediately: the
    // user has to be steady *and* aimed, and a gap means "steady" was never
    // established.
    if (!alignment.usable ||
        alignment.angularErrorDeg >
            alignment.toleranceDeg + alignmentHysteresisDeg) {
      return _refuse('alignment');
    }

    // Rate, measured from the poses themselves over [rateBaseline].
    //
    // The platform's gyro figure is **not** used for the gate even when it is
    // reported: a phone's gyro carries a bias of several degrees per second
    // that ARCore's visual-inertial pose has already corrected, so a perfectly
    // still phone can report 6–10 °/s while its pose does not move at all —
    // and the gate then refuses forever. The pose stream is the authority
    // because it is the same evidence the drift checks use. The platform
    // figure is kept as the fallback for the first sample, where there is no
    // baseline yet, and is still reported in diagnostics.
    double? rate;
    _Sample? anchor;
    for (final s in _rateHistory) {
      if (now.difference(s.at) >= rateBaseline) anchor = s;
    }
    anchor ??= _rateHistory.isEmpty ? null : _rateHistory.first;
    if (anchor != null) {
      final dt = now.difference(anchor.at).inMicroseconds / 1e6;
      if (dt >= 0.02) {
        rate = angularRateFromQuaternions(
          from: anchor.pose.orientation,
          to: pose.orientation,
          dtSeconds: dt,
        );
      }
    }
    // A platform figure may only *raise* the verdict, and only when the poses
    // agree that something moved: a gyro bias reports several °/s on a phone
    // that is not moving at all, while a genuine fast turn shows up in the
    // pose delta too. With no baseline yet (first sample) it is the only
    // evidence there is, so it is used directly.
    if (rate == null) {
      rate = angularRateDegPerSec;
    } else if (angularRateDegPerSec != null &&
        angularRateDegPerSec > maxAngularVelocityDegPerSec &&
        rate > maxAngularVelocityDegPerSec * 0.25) {
      rate = angularRateDegPerSec;
    }
    _lastAngularRate = rate;
    _rateHistory.add(_Sample(at: now, pose: pose));
    if (_rateHistory.length > 12) _rateHistory.removeAt(0);

    if (rate != null && rate > maxAngularVelocityDegPerSec) {
      return _refuse('angular-rate');
    }

    _samples.add(_Sample(at: now, pose: pose));

    if (_samples.length < 2) {
      _stable = false;
      _held = now.difference(_samples.first.at);
      _lastRejection = 'window';
      return false;
    }

    final oldest = _samples.first;
    // Quaternion angle, not a forward-vector angle: a roll change is real
    // movement and the vector form cannot see it.
    final driftDeg = angleBetweenDeg(oldest.pose.orientation, pose.orientation);
    final driftM = (pose.position - oldest.pose.position).length;

    if (driftDeg > maxOrientationDriftDeg) return _refuse('orientation-drift');
    if (driftM > maxPositionDriftM) return _refuse('position-drift');

    final spansWindow = now.difference(oldest.at) >= window;
    _held = now.difference(oldest.at);
    if (!spansWindow) {
      _stable = false;
      _lastRejection = 'window';
      return false;
    }

    _stable = true;
    _lastRejection = null;
    return true;
  }

  bool _refuse(String reason) {
    _samples.clear();
    _stable = false;
    _held = Duration.zero;
    _lastRejection = reason;
    return false;
  }
}

class _Sample {
  final DateTime at;
  final RigidPose pose;
  const _Sample({required this.at, required this.pose});
}

/// Angle between two unit-ish vectors, in degrees.
///
/// Kept for callers that only have directions; the window drift now uses the
/// quaternion form in [angleBetweenDeg].
double vectorAngleDeg(Vec3 a, Vec3 b) {
  final la = a.length;
  final lb = b.length;
  if (la == 0 || lb == 0) return 180;
  final dot = a.dot(b);
  final cross = a.cross(b).length;
  return math.atan2(cross, dot) * radToDeg;
}
