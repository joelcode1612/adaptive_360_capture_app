import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The gravity-aligned capture reference.
///
/// The property that matters is not any single number but this: **however the
/// phone was held when the user pressed Calibrate — tilted up, tilted down,
/// rolled onto its side — the three rings come out level with gravity.** The
/// rings are defined against gravity, not against the phone, so calibrating
/// while looking 20° up must not put the middle ring at +20°.
///
/// The camera pose for a test is built from a yaw/pitch pair plus a roll
/// about the optical axis: `fromYawPitch(yaw, pitch) * axisAngle(roll, ẑ)`
/// keeps the forward vector as `fromYawPitch` defines it and rotates the
/// camera's up around it.
void main() {
  const gravityUp = Vec3(0, 1, 0);

  /// A camera orientation in this project's convention.
  Quat cameraPose({
    required double yawDeg,
    required double pitchDeg,
    double rollDeg = 0,
  }) =>
      Quat.fromYawPitch(yawDeg, pitchDeg) * Quat.axisAngle(rollDeg, Vec3.unitZ);

  Vec3 forwardOf(Quat q) => q.rotate(Vec3.unitZ);

  group('the horizontal projection', () {
    test("removes the gravity component and keeps what's left", () {
      final forward = Vec3(0.6, 0.8, 0).normalized;
      final projected = projectOntoHorizontal(forward, gravityUp);
      expect(projected.dot(gravityUp), closeTo(0, 1e-12));
      expect(projected.x, greaterThan(0));
      expect(projected.length, closeTo(0.6, 1e-12));
    });

    test('measures elevation against the plane, not the axis', () {
      expect(
        elevationAboveHorizontalDeg(Vec3.unitZ, gravityUp),
        closeTo(0, 1e-9),
      );
      expect(
        elevationAboveHorizontalDeg(Vec3.unitY, gravityUp),
        closeTo(90, 1e-9),
      );
      expect(
        elevationAboveHorizontalDeg(-Vec3.unitY, gravityUp),
        closeTo(-90, 1e-9),
      );
      final diag = Vec3(0, 1, 1).normalized;
      expect(elevationAboveHorizontalDeg(diag, gravityUp), closeTo(45, 1e-9));
    });
  });

  group('the reference built at calibration', () {
    test('keeps the yaw and drops the pitch of a level phone', () {
      final pose = cameraPose(yawDeg: 30, pitchDeg: 0);
      final result = captureReferenceFromPose(cameraForward: forwardOf(pose));
      expect(result.ok, isTrue);
      final q = result.orientation!;
      expect(q.length, closeTo(1, 1e-12));
      // Up is gravity, not wherever the phone's top happened to point.
      expect(q.rotate(Vec3.unitY).x, closeTo(0, 1e-12));
      expect(q.rotate(Vec3.unitY).y, closeTo(1, 1e-12));
      expect(q.rotate(Vec3.unitY).z, closeTo(0, 1e-12));
      // Forward is the camera's own: yaw preserved exactly, pitch gone.
      final f = q.rotate(Vec3.unitZ);
      expect(f.x, closeTo(forwardOf(pose).x, 1e-12));
      expect(f.y, closeTo(0, 1e-12));
      expect(f.z, closeTo(forwardOf(pose).z, 1e-12));
    });

    test('a tilted calibration leaves the rings level with gravity', () {
      // The user calibrates while looking 20° up, yawed 30° right. Freezing
      // the raw pose would have tilted the whole target sphere by 20°; these
      // rings are the regression.
      final pose = cameraPose(yawDeg: 30, pitchDeg: 20);
      final result = captureReferenceFromPose(cameraForward: forwardOf(pose));
      expect(result.ok, isTrue);
      final station = StationFrame(
        origin: const Vec3(1, 1.5, -2),
        orientation: result.orientation!,
      );

      for (final spec in buildCaptureSphere()) {
        final world = station.localToWorld(spec.direction).normalized;
        expect(
          elevationAboveHorizontalDeg(world, gravityUp),
          closeTo(spec.pitchDegrees, 1e-9),
          reason:
              'target ${spec.targetId} (${spec.ringName}) sits at '
              '${spec.pitchDegrees} degrees of elevation, however the '
              'phone was held',
        );
      }
      // The front target is exactly the camera's horizontal heading, and the
      // back target is its opposite.
      final specs = buildCaptureSphere();
      final frontSpec = specs.firstWhere(
        (CaptureTargetSpec s) => s.yawDegrees == 0 && s.pitchDegrees == 0,
      );
      final backSpec = specs.firstWhere(
        (CaptureTargetSpec s) => s.yawDegrees == 180 && s.pitchDegrees == 0,
      );
      final front = station.localToWorld(frontSpec.direction).normalized;
      final back = station.localToWorld(backSpec.direction).normalized;
      final expectedForward = projectOntoHorizontal(
        forwardOf(pose),
        gravityUp,
      ).normalized;
      expect(front.x, closeTo(expectedForward.x, 1e-9));
      expect(front.y, closeTo(0, 1e-9));
      expect(front.z, closeTo(expectedForward.z, 1e-9));
      expect(front.dot(back), closeTo(-1, 1e-9));
    });

    test('a rolled calibration keeps up as gravity, not the camera up', () {
      // Phone rolled 180 degrees: its own up points at the floor. The
      // reference's up must still be the world's.
      final pose = cameraPose(yawDeg: 0, pitchDeg: 0, rollDeg: 180);
      expect(
        pose.rotate(Vec3.unitY).y,
        lessThan(0),
        reason: 'the camera really is upside down',
      );
      final result = captureReferenceFromPose(cameraForward: forwardOf(pose));
      expect(result.ok, isTrue);
      expect(result.orientation!.rotate(Vec3.unitY).y, closeTo(1, 1e-12));
    });
  });

  group('a camera that cannot define a heading', () {
    test('straight up is refused with a stated reason', () {
      final result = captureReferenceFromPose(cameraForward: Vec3.unitY);
      expect(result.ok, isFalse);
      expect(result.orientation, isNull);
      expect(result.reason, contains('horizontal'));
    });

    test('straight down is refused too', () {
      final result = captureReferenceFromPose(cameraForward: -Vec3.unitY);
      expect(result.ok, isFalse);
      expect(result.reason, contains('horizontal'));
    });

    test('the boundary is the documented 10 degrees from vertical', () {
      // 80 degrees of elevation: the projection keeps sin(80) of its length
      // and the heading is still well defined — accepted.
      final at80 = Vec3(0.17365, 0.98481, 0);
      expect(captureReferenceFromPose(cameraForward: at80).ok, isTrue);
      // 85 degrees: within 10 of vertical, the heading would be noise.
      final at85 = Vec3(0.08716, 0.99619, 0);
      expect(captureReferenceFromPose(cameraForward: at85).ok, isFalse);
    });
  });
}
