import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

import 'capture_targets_test.dart' show orientationFor;

const AlignmentCalculator calc = AlignmentCalculator();

/// A station at the origin facing world +Z, i.e. the simplest possible frame.
final StationFrame station = StationFrame(
  origin: Vec3.zero,
  orientation: Quat.identity,
);

/// A camera standing at the station, looking at station-local (yaw, pitch).
RigidPose cameraFacing(double yawDeg, double pitchDeg, [Vec3? at]) => RigidPose(
  position: at ?? Vec3.zero,
  orientation: orientationFor(
    station.localToWorld(direction(yawDeg, pitchDeg)),
  ),
);

/// Station-local (yaw, pitch) → world point at [distance] metres.
Vec3 targetAt(double yawDeg, double pitchDeg, [double distance = 3]) =>
    station.localPointToWorld(direction(yawDeg, pitchDeg) * distance);

Vec3 direction(double yawDeg, double pitchDeg) {
  final y = yawDeg * math.pi / 180;
  final p = pitchDeg * math.pi / 180;
  final cp = math.cos(p);
  return Vec3(cp * math.sin(y), math.sin(p), cp * math.cos(y));
}

void main() {
  // ── required case 3 ───────────────────────────────────────────────────
  test(
    'a phone 20° left of a straight-ahead target is told to turn right 20°',
    () {
      // Target: yaw 0, pitch 0, straight ahead of the station.
      final target = targetAt(0, 0);
      // Phone: turned 20° to the *left*, i.e. station-local yaw -20°.
      final camera = cameraFacing(-20, 0);

      final result = calc.compute(
        camera: camera,
        targetPosition: target,
        toleranceDeg: 3,
      );

      expect(result.yawCorrectionDeg, closeTo(20, 1e-6));
      expect(result.pitchCorrectionDeg, closeTo(0, 1e-6));
      expect(result.angularErrorDeg, closeTo(20, 1e-6));
      expect(result.instruction, 'Turn right 20°');
      expect(result.withinTolerance, isFalse);
    },
  );

  // ── required case 4 ───────────────────────────────────────────────────
  test('a target to the right produces a right-turn instruction', () {
    final target = targetAt(90, 0);
    final camera = cameraFacing(0, 0);

    final result = calc.compute(
      camera: camera,
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(result.yawCorrectionDeg, greaterThan(89));
    expect(result.instruction, 'Turn right 90°');
  });

  test('a target to the left produces a left-turn instruction', () {
    final target = targetAt(-90, 0);
    final camera = cameraFacing(0, 0);

    final result = calc.compute(
      camera: camera,
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(result.yawCorrectionDeg, lessThan(-89));
    expect(result.instruction, 'Turn left 90°');
  });

  // ── required case 5 ───────────────────────────────────────────────────
  test('a target above the camera produces an upward correction', () {
    final target = targetAt(0, 30);
    final camera = cameraFacing(0, 0);

    final result = calc.compute(
      camera: camera,
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(result.pitchCorrectionDeg, closeTo(30, 1e-6));
    expect(result.instruction, 'Tilt up 30°');
  });

  test('a target below the camera produces a downward correction', () {
    final target = targetAt(0, -30);
    final camera = cameraFacing(0, 0);

    final result = calc.compute(
      camera: camera,
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(result.pitchCorrectionDeg, closeTo(-30, 1e-6));
    expect(result.instruction, 'Tilt down 30°');
  });

  test('a perfectly aimed phone is told to hold still', () {
    final target = targetAt(45, 0);
    final camera = cameraFacing(45, 0);

    final result = calc.compute(
      camera: camera,
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(result.angularErrorDeg, closeTo(0, 1e-6));
    expect(result.withinTolerance, isTrue);
    expect(result.instruction, 'Ready to capture. Hold still.');
  });

  // ── required case 6 ───────────────────────────────────────────────────
  group('angle wrapping', () {
    test('+179° to -179° is 2°, not 358°', () {
      expect(AlignmentCalculator.shortestAngleDeg(179, -179), closeTo(2, 1e-9));
      expect(
        AlignmentCalculator.shortestAngleDeg(-179, 179),
        closeTo(-2, 1e-9),
      );
    });

    test('a correction computed across the wrap is 2°', () {
      // Two phones, 2° apart, straddling ±180°. The difference between their
      // yaw corrections must be 2°, not 358°.
      final target = targetAt(180, 0);
      final a = calc.compute(
        camera: cameraFacing(179, 0),
        targetPosition: target,
        toleranceDeg: 3,
      );
      final b = calc.compute(
        camera: cameraFacing(-179, 0),
        targetPosition: target,
        toleranceDeg: 3,
      );
      final delta = AlignmentCalculator.shortestAngleDeg(
        a.yawCorrectionDeg,
        b.yawCorrectionDeg,
      );
      expect(delta.abs(), closeTo(2, 1e-6));
    });

    test('every correction is inside (-180, 180]', () {
      for (var yaw = -180.0; yaw <= 180; yaw += 7) {
        final result = calc.compute(
          camera: cameraFacing(yaw, 0),
          targetPosition: targetAt(0, 0),
          toleranceDeg: 3,
        );
        expect(result.yawCorrectionDeg, greaterThan(-180.001));
        expect(result.yawCorrectionDeg, lessThanOrEqualTo(180.001));
      }
    });
  });

  // ── required case 7 ───────────────────────────────────────────────────
  test('moving the phone changes the direction to an anchored target', () {
    // A wall 3 m straight ahead of the station. The phone then steps 1 m to the
    // station's right, so the target is no longer dead ahead.
    final target = targetAt(0, 0, 3);
    final atStation = calc.compute(
      camera: cameraFacing(0, 0),
      targetPosition: target,
      toleranceDeg: 3,
    );
    final steppedRight = calc.compute(
      camera: cameraFacing(0, 0, const Vec3(-1, 0, 0)),
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(atStation.yawCorrectionDeg, closeTo(0, 1e-6));
    // The target is now 1 m to the left of where the phone stands, so the phone
    // must turn left — and by atan(1/3), not by 0.
    expect(
      steppedRight.yawCorrectionDeg,
      closeTo(-math.atan(1 / 3) * 180 / math.pi, 1e-6),
    );
    expect(steppedRight.yawCorrectionDeg, isNot(closeTo(0, 1e-3)));
  });

  test(
    'the direction is recomputed from the new position, not the old one',
    () {
      final target = targetAt(0, 0, 3);
      final moved = calc.compute(
        camera: cameraFacing(0, 0, const Vec3(0, 0, 2)),
        targetPosition: target,
        toleranceDeg: 3,
      );
      // Standing 2 m in front of the station, the wall is only 1 m away.
      expect(moved.distanceM, closeTo(1, 1e-9));
      expect(moved.angularErrorDeg, closeTo(0, 1e-6));
    },
  );

  // ── required case 8 ───────────────────────────────────────────────────
  test('rotating the phone changes the alignment but not the station', () {
    final reference = station.orientation;
    final target = targetAt(0, 0);

    final before = calc.compute(
      camera: cameraFacing(0, 0),
      targetPosition: target,
      toleranceDeg: 3,
    );
    final after = calc.compute(
      camera: cameraFacing(15, 0),
      targetPosition: target,
      toleranceDeg: 3,
    );

    expect(before.angularErrorDeg, closeTo(0, 1e-6));
    expect(after.angularErrorDeg, closeTo(15, 1e-6));
    // The station's recorded pose is untouched by the phone moving.
    expect(station.orientation, reference);
    expect(station.orientation.maxComponentDiff(reference), 0);
  });

  // ── poles ─────────────────────────────────────────────────────────────
  group('the poles', () {
    test('use the 3-D error and suppress the yaw wording', () {
      final zenith = station.localPointToWorld(Vec3.unitY * 2.5);
      final camera = cameraFacing(0, 0);
      final result = calc.compute(
        camera: camera,
        targetPosition: zenith,
        toleranceDeg: 3,
        isPole: true,
      );
      expect(result.angularErrorDeg, closeTo(90, 1e-6));
      expect(result.instruction, 'Tilt up 90°');
      expect(result.instruction.contains('Turn'), isFalse);
    });

    test('are aligned when the phone points straight up', () {
      final zenith = station.localPointToWorld(Vec3.unitY * 2.5);
      final result = calc.compute(
        camera: cameraFacing(0, 90),
        targetPosition: zenith,
        toleranceDeg: 3,
        isPole: true,
      );
      expect(result.angularErrorDeg, closeTo(0, 1e-6));
      expect(result.withinTolerance, isTrue);
    });
  });

  // ── degenerate geometry ───────────────────────────────────────────────
  test('a target at the camera is reported unusable, not as NaN', () {
    final result = calc.compute(
      camera: cameraFacing(0, 0),
      targetPosition: Vec3.zero,
      toleranceDeg: 3,
    );
    expect(result.usable, isFalse);
    expect(result.yawCorrectionDeg, 0);
    expect(result.withinTolerance, isFalse);
  });

  test('a target behind the camera is told to turn around', () {
    final behind = station.localPointToWorld(direction(180, 0) * 3);
    final result = calc.compute(
      camera: cameraFacing(0, 0),
      targetPosition: behind,
      toleranceDeg: 3,
    );
    expect(result.instruction.contains('Turn around'), isTrue);
    expect(result.inFront, isFalse);
  });

  test(
    'the 3-D error agrees with the aim() helper the rest of the app uses',
    () {
      for (final spec in buildCaptureSphere()) {
        final target = station.localPointToWorld(spec.direction * 3);
        for (final yaw in <double>[0, 37, -90, 150]) {
          final result = calc.compute(
            camera: cameraFacing(yaw, 0),
            targetPosition: target,
            toleranceDeg: 3,
          );
          final forward = cameraFacing(yaw, 0).forward;
          final d = (target - Vec3.zero).normalized;
          final expected =
              math.acos((forward.dot(d)).clamp(-1.0, 1.0)) * 180 / math.pi;
          expect(result.angularErrorDeg, closeTo(expected, 1e-9));
        }
      }
    },
  );

  // ── the gate is a real tolerance, not a formality ──────────────────────
  group('every target and the tolerance', () {
    test('all 26 targets align when the phone is aimed exactly at them', () {
      for (final spec in buildCaptureSphere()) {
        final target = station.localPointToWorld(spec.direction * 3);
        final camera = RigidPose(
          position: Vec3.zero,
          orientation: orientationFor(station.localToWorld(spec.direction)),
        );
        final r = calc.compute(
          camera: camera,
          targetPosition: target,
          toleranceDeg: 3,
          isPole: spec.isPole,
        );
        expect(
          r.angularErrorDeg,
          closeTo(0, 1e-6),
          reason:
              'target ${spec.targetId} '
              '(yaw ${spec.yawDegrees}, pitch ${spec.pitchDegrees})',
        );
        expect(r.withinTolerance, isTrue, reason: 'target ${spec.targetId}');
      }
    });

    test('a 5° error fails a 3° tolerance — the gate is not 360°', () {
      // The brief warns that some configurations use a 360° yaw tolerance,
      // which would let any heading pass. This pins the opposite.
      final r = calc.compute(
        camera: cameraFacing(5, 0),
        targetPosition: targetAt(0, 0),
        toleranceDeg: 3,
      );
      expect(r.angularErrorDeg, closeTo(5, 1e-6));
      expect(r.withinTolerance, isFalse);
      expect(r.toleranceDeg, 3);
      expect(r.toleranceDeg, lessThan(360));
    });

    test('the tolerance boundary is tight in both directions', () {
      final inside = calc.compute(
        camera: cameraFacing(2.9, 0),
        targetPosition: targetAt(0, 0),
        toleranceDeg: 3,
      );
      final outside = calc.compute(
        camera: cameraFacing(3.2, 0),
        targetPosition: targetAt(0, 0),
        toleranceDeg: 3,
      );
      expect(inside.withinTolerance, isTrue);
      expect(outside.withinTolerance, isFalse);
    });

    test('the poles are vertical directions, and yaw does not rescue them', () {
      final zenith = station.localPointToWorld(Vec3.unitY * 2.5);
      // Aimed at the horizon, 90° away from the zenith: must fail.
      final wrong = calc.compute(
        camera: cameraFacing(0, 0),
        targetPosition: zenith,
        toleranceDeg: 3,
        isPole: true,
      );
      expect(wrong.withinTolerance, isFalse);

      // Aimed straight up: must pass, and must not depend on yaw.
      for (final yaw in <double>[0, 45, -135]) {
        final r = calc.compute(
          camera: RigidPose(
            position: Vec3.zero,
            orientation: (Quat.fromYawPitch(yaw, 89.99)).normalized,
          ),
          targetPosition: zenith,
          toleranceDeg: 3,
          isPole: true,
        );
        expect(r.withinTolerance, isTrue, reason: 'yaw $yaw');
      }
    });
  });
}
