import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/stability_monitor.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The gates the brief asks for, each isolated so a failure names its cause.
///
/// Every test drives `StabilityMonitor` with explicit timestamps: "stable for
/// 450 ms" is a statement about a sequence, and a sequence is the only honest
/// thing to supply.
void main() {
  final start = DateTime.utc(2026, 10, 18, 9);

  /// A camera aimed at a target 3 m along +Z, with an 8° tolerance so that the
  /// *rate* gate — not the alignment gate — is what the rotation tests exercise.
  AlignmentResult aimed({double yawDeg = 0, double toleranceDeg = 8}) =>
      const AlignmentCalculator().compute(
        camera: RigidPose(
          position: Vec3.zero,
          orientation: Quat.fromYawPitch(yawDeg, 0),
        ),
        targetPosition: const Vec3(0, 0, 3),
        toleranceDeg: toleranceDeg,
      );

  /// A camera at [yawDeg] looking at a target placed **along its own forward**.
  ///
  /// Needed to isolate the rate gate: rotating the camera away from a fixed
  /// target trips the alignment gate first, and then the test would be measuring
  /// the wrong refusal.
  AlignmentResult aimedAlong(double yawDeg, {double toleranceDeg = 8}) {
    final q = Quat.fromYawPitch(yawDeg, 0);
    return const AlignmentCalculator().compute(
      camera: RigidPose(position: Vec3.zero, orientation: q),
      targetPosition: q.rotate(Vec3.unitZ) * 3,
      toleranceDeg: toleranceDeg,
    );
  }

  RigidPose poseAt(double yawDeg, {double rollDeg = 0}) => RigidPose(
    position: Vec3.zero,
    orientation:
        (Quat.fromYawPitch(yawDeg, 0) * Quat.axisAngle(rollDeg, Vec3.unitZ))
            .normalized,
  );

  StabilityMonitor monitor({
    Duration window = const Duration(milliseconds: 450),
  }) => StabilityMonitor(window: window);

  group('noise is not movement', () {
    /// A still phone, as a real one reports it: sub-degree orientation jitter,
    /// millimetre position jitter, and — on some devices — a gyroscope whose
    /// bias reads several °/s while the pose does not move at all.
    test('hand tremor still qualifies as stable', () {
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 20; i++) {
        final jitterYaw = (i.isEven ? 0.35 : -0.30) * (i % 3 == 0 ? 1.6 : 1);
        final jitterM = (i.isEven ? 0.004 : -0.003);
        stable = m.update(
          now: now,
          pose: RigidPose(
            position: Vec3(jitterM, 0, 0),
            orientation: Quat.fromYawPitch(jitterYaw, 0.2),
          ),
          alignment: aimed(yawDeg: jitterYaw),
        );
        now = now.add(const Duration(milliseconds: 33));
      }
      expect(stable, isTrue, reason: 'tremor is not movement');
      expect(m.lastRejection, isNull);
    });

    test('a biased gyroscope on a still phone is not movement', () {
      // The pose is constant; only the platform rate claims 9 °/s. Trusting it
      // blindly is what kept a still phone on "Hold still…" forever.
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 20; i++) {
        stable = m.update(
          now: now,
          pose: poseAt(0),
          alignment: aimed(),
          angularRateDegPerSec: 9,
        );
        now = now.add(const Duration(milliseconds: 33));
      }
      expect(stable, isTrue);
      expect(m.lastRejection, isNull);
    });

    test('a genuine walk is still refused', () {
      final m = monitor();
      var now = start;
      for (var i = 0; i < 12; i++) {
        m.update(
          now: now,
          pose: RigidPose(
            position: Vec3(0, 0, i * 0.05),
            orientation: Quat.identity,
          ),
          alignment: aimed(),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(m.isStable, isFalse);
      expect(m.lastRejection, 'position-drift');
    });

    test('a stale measurement is refused before anything else', () {
      final m = monitor();
      final stable = m.update(
        now: start,
        pose: poseAt(0),
        alignment: aimed(),
        measurementAge: const Duration(milliseconds: 900),
      );
      expect(stable, isFalse);
      expect(m.lastRejection, 'measurement-age');
    });
  });

  group('alignment hysteresis', () {
    /// An alignment result at a chosen 3-D error, with the real 3° tolerance.
    AlignmentResult errorOf(double deg) => AlignmentResult(
      directionWorld: Vec3.unitZ,
      directionInCamera: Vec3.unitZ,
      distanceM: 3,
      yawCorrectionDeg: deg,
      pitchCorrectionDeg: 0,
      angularErrorDeg: deg,
      toleranceDeg: 3,
    );

    test('a tremor-sized excursion keeps the window', () {
      // 4.5° is outside the 3° shutter tolerance but inside tolerance +
      // hysteresis (5°) — the user is holding it, just not perfectly.
      final m = StabilityMonitor(window: const Duration(milliseconds: 450));
      var now = start;
      var stable = false;
      for (var i = 0; i < 14; i++) {
        stable = m.update(
          now: now,
          pose: poseAt(0),
          alignment: errorOf(i % 4 == 0 ? 4.5 : 0.4),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
      expect(m.lastRejection, isNull);
    });

    test('a genuine misalignment still throws the window away', () {
      final m = StabilityMonitor(window: const Duration(milliseconds: 450));
      var now = start;
      for (var i = 0; i < 4; i++) {
        m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      m.update(now: now, pose: poseAt(0), alignment: errorOf(6.5));
      expect(m.isStable, isFalse);
      expect(m.heldFor, Duration.zero);
      expect(m.lastRejection, 'alignment');
    });
  });

  group('angular velocity', () {
    test('a still phone becomes stable after the window', () {
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 12; i++) {
        stable = m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
      expect(m.lastRejection, isNull);
      expect(m.lastAngularVelocityDegPerSec, closeTo(0, 1e-6));
    });

    test('a phone rotating faster than 5°/s never becomes stable', () {
      final m = monitor();
      var now = start;
      var stable = false;
      // 20°/s: 1.2° per 60 ms sample. Alignment stays well inside 8°.
      for (var i = 0; i < 14; i++) {
        stable = m.update(
          now: now,
          pose: poseAt(i * 1.2),
          alignment: aimedAlong(i * 1.2),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isFalse);
      expect(m.lastRejection, 'angular-rate');
      expect(m.lastAngularVelocityDegPerSec, closeTo(20, 1.0));
    });

    test('a supplied gyro rate is used verbatim', () {
      final m = monitor();
      // Orientation is perfectly still; only the reported rate says otherwise.
      final stable = m.update(
        now: start,
        pose: poseAt(0),
        alignment: aimed(),
        angularRateDegPerSec: 30,
      );
      expect(stable, isFalse);
      expect(m.lastRejection, 'angular-rate');
    });

    test('a rate just under the threshold is accepted', () {
      final m = monitor();
      var now = start;
      var stable = false;
      // 3°/s — inside the 5°/s budget.
      for (var i = 0; i < 12; i++) {
        stable = m.update(
          now: now,
          pose: poseAt(i * 0.18),
          alignment: aimedAlong(i * 0.18),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
    });
  });

  group('measurement age', () {
    test('a stale reading is refused', () {
      final m = monitor();
      final stable = m.update(
        now: start,
        pose: poseAt(0),
        alignment: aimed(),
        measurementAge: const Duration(milliseconds: 400),
      );
      expect(stable, isFalse);
      expect(m.lastRejection, 'measurement-age');
      expect(m.lastMeasurementAge, const Duration(milliseconds: 400));
    });

    test('a fresh reading is accepted', () {
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 12; i++) {
        stable = m.update(
          now: now,
          pose: poseAt(0),
          alignment: aimed(),
          measurementAge: const Duration(milliseconds: 33),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
    });

    test('an unknown age is treated as fresh, not as stale', () {
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 12; i++) {
        stable = m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
    });
  });

  group('drift across the window', () {
    test(
      'a roll change is caught even though the forward vector is unchanged',
      () {
        final m = monitor();
        var now = start;
        final refusals = <String>[];
        var everStable = false;

        for (var i = 0; i < 20; i++) {
          // 4.5°/s of roll: inside the 5°/s rate budget, but 0.27° per sample
          // accumulates ~1.9° across the 450 ms window, past the 1.5° drift
          // budget. Forward never moves; only the orientation does, so a
          // forward-vector drift check would miss this entirely.
          final stable = m.update(
            now: now,
            pose: poseAt(0, rollDeg: i * 0.27),
            alignment: aimed(),
          );
          everStable = everStable || stable;
          final r = m.lastRejection;
          if (r != null && !refusals.contains(r)) refusals.add(r);
          now = now.add(const Duration(milliseconds: 60));
        }

        // A refusal clears the run, so the *sequence* of reasons alternates; the
        // honest assertions are that the drift gate fires at all and that the
        // phone never qualifies.
        expect(refusals, contains('orientation-drift'));
        expect(everStable, isFalse);
      },
    );

    test('walking away is caught by position drift', () {
      final m = monitor();
      var now = start;
      var stable = false;
      for (var i = 0; i < 12; i++) {
        stable = m.update(
          now: now,
          pose: RigidPose(
            position: Vec3(0, 0, i * 0.05),
            orientation: Quat.identity,
          ),
          alignment: aimed(),
        );
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isFalse);
      expect(m.lastRejection, 'position-drift');
    });
  });

  group('recovery', () {
    test('a refusal resets the run, and settling afterwards re-qualifies', () {
      final m = monitor();
      var now = start;
      // A genuine turn: 25 °/s is 1.5° every 60 ms, and the poses carry it.
      var yaw = 0.0;
      for (var i = 0; i < 6; i++) {
        m.update(
          now: now,
          pose: poseAt(yaw),
          alignment: aimed(),
          angularRateDegPerSec: 25,
        );
        yaw += 1.5;
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(m.isStable, isFalse);
      expect(m.heldFor, Duration.zero);
      expect(m.lastRejection, 'angular-rate');

      var stable = false;
      for (var i = 0; i < 12; i++) {
        stable = m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(stable, isTrue);
      expect(m.lastRejection, isNull);
    });

    test('reset clears everything', () {
      final m = monitor();
      var now = start;
      for (var i = 0; i < 12; i++) {
        m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(m.isStable, isTrue);
      m.reset();
      expect(m.isStable, isFalse);
      expect(m.heldFor, Duration.zero);
      expect(m.lastAngularVelocityDegPerSec, isNull);
      expect(m.lastRejection, isNull);
    });

    test('a tracking interruption resets readiness', () {
      final m = monitor();
      var now = start;
      for (var i = 0; i < 12; i++) {
        m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(m.isStable, isTrue);

      final lost = const AlignmentCalculator().compute(
        camera: RigidPose(
          position: Vec3.zero,
          orientation: Quat.fromYawPitch(40, 0),
        ),
        targetPosition: const Vec3(0, 0, 3),
        toleranceDeg: 3,
      );
      expect(m.update(now: now, pose: poseAt(40), alignment: lost), isFalse);
      expect(m.heldFor, Duration.zero);
      expect(m.lastRejection, 'alignment');
    });
  });

  group('the window itself', () {
    test('is not satisfied before it has elapsed', () {
      final m = monitor();
      expect(
        m.update(now: start, pose: poseAt(0), alignment: aimed()),
        isFalse,
      );
      expect(
        m.update(
          now: start.add(const Duration(milliseconds: 100)),
          pose: poseAt(0),
          alignment: aimed(),
        ),
        isFalse,
      );
      expect(m.lastRejection, 'window');
      expect(m.progress, lessThan(1));
    });

    test('progress reaches 1 exactly when stable', () {
      final m = monitor();
      var now = start;
      for (var i = 0; i < 12; i++) {
        m.update(now: now, pose: poseAt(0), alignment: aimed());
        now = now.add(const Duration(milliseconds: 60));
      }
      expect(m.isStable, isTrue);
      expect(m.progress, 1);
    });
  });

  group('MotionSample', () {
    test('rejects non-finite and degenerate quaternions', () {
      MotionSample of(Quat q) =>
          MotionSample(orientation: q, at: Duration.zero);
      expect(of(Quat.identity).isUsable, isTrue);
      expect(of(Quat(double.nan, 0, 0, 1)).isUsable, isFalse);
      expect(of(Quat(0, 0, 0, double.infinity)).isUsable, isFalse);
      expect(of(const Quat(0, 0, 0, 0)).isUsable, isFalse);
    });
  });
}
