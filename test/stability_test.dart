import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/stability_monitor.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1);

  AlignmentResult aligned(Vec3 cameraPosition) {
    return const AlignmentCalculator().compute(
      camera: RigidPose(
        position: Vec3.zero,
        orientation: Quat.identity,
      ).copyAt(cameraPosition),
      targetPosition: const Vec3(0, 0, 3),
      toleranceDeg: 3,
    );
  }

  test('a still, aimed phone becomes stable after the window', () {
    final monitor = StabilityMonitor(window: const Duration(milliseconds: 500));
    var now = start;
    var stable = false;
    for (var i = 0; i < 12; i++) {
      stable = monitor.update(
        now: now,
        pose: RigidPose(position: Vec3.zero, orientation: Quat.identity),
        alignment: aligned(Vec3.zero),
      );
      now = now.add(const Duration(milliseconds: 50));
    }
    expect(stable, isTrue);
    expect(
      monitor.heldFor,
      greaterThanOrEqualTo(const Duration(milliseconds: 500)),
    );
    expect(monitor.progress, 1);
  });

  test('is not stable before the window has elapsed', () {
    final monitor = StabilityMonitor(window: const Duration(milliseconds: 500));
    expect(
      monitor.update(
        now: start,
        pose: RigidPose(position: Vec3.zero, orientation: Quat.identity),
        alignment: aligned(Vec3.zero),
      ),
      isFalse,
    );
    expect(
      monitor.update(
        now: start.add(const Duration(milliseconds: 100)),
        pose: RigidPose(position: Vec3.zero, orientation: Quat.identity),
        alignment: aligned(Vec3.zero),
      ),
      isFalse,
    );
    expect(monitor.progress, lessThan(1));
  });

  test('a phone swinging through alignment never becomes stable', () {
    final monitor = StabilityMonitor(
      window: const Duration(milliseconds: 500),
      maxOrientationDriftDeg: 1.5,
    );
    var now = start;
    var stable = false;
    for (var i = 0; i < 14; i++) {
      // A slow, steady pan: every sample is inside the alignment tolerance, so
      // an "is it aimed?" test would happily fire — but the pose moves ~5°
      // across the window, which is more than the drift budget allows.
      final angle = i * 0.5;
      stable = monitor.update(
        now: now,
        pose: RigidPose(
          position: Vec3.zero,
          orientation: Quat.fromYawPitch(angle, 0),
        ),
        alignment: const AlignmentCalculator().compute(
          camera: RigidPose(
            position: Vec3.zero,
            orientation: Quat.fromYawPitch(angle, 0),
          ),
          targetPosition: const Vec3(0, 0, 3),
          toleranceDeg: 40,
        ),
      );
      now = now.add(const Duration(milliseconds: 50));
    }
    expect(stable, isFalse);
  });

  test('losing alignment resets the run', () {
    final monitor = StabilityMonitor(window: const Duration(milliseconds: 500));
    var now = start;
    for (var i = 0; i < 10; i++) {
      monitor.update(
        now: now,
        pose: RigidPose(position: Vec3.zero, orientation: Quat.identity),
        alignment: aligned(Vec3.zero),
      );
      now = now.add(const Duration(milliseconds: 50));
    }
    final lost = const AlignmentCalculator().compute(
      camera: RigidPose(
        position: Vec3.zero,
        orientation: Quat.fromYawPitch(40, 0),
      ),
      targetPosition: const Vec3(0, 0, 3),
      toleranceDeg: 3,
    );
    expect(
      monitor.update(
        now: now,
        pose: RigidPose(
          position: Vec3.zero,
          orientation: Quat.fromYawPitch(40, 0),
        ),
        alignment: lost,
      ),
      isFalse,
    );
    expect(monitor.heldFor, Duration.zero);
    expect(monitor.isStable, isFalse);
  });

  test('a phone that walks away is not stable', () {
    final monitor = StabilityMonitor(
      window: const Duration(milliseconds: 500),
      maxPositionDriftM: 0.03,
    );
    var now = start;
    var stable = false;
    for (var i = 0; i < 12; i++) {
      final position = Vec3(0, 0, i * 0.05);
      stable = monitor.update(
        now: now,
        pose: RigidPose(position: position, orientation: Quat.identity),
        alignment: const AlignmentCalculator().compute(
          camera: RigidPose(position: position, orientation: Quat.identity),
          targetPosition: const Vec3(0, 0, 3),
          toleranceDeg: 40,
        ),
      );
      now = now.add(const Duration(milliseconds: 50));
    }
    expect(stable, isFalse);
  });
}

/// Small helper so the test can vary the camera position without rebuilding the
/// whole pose by hand.
extension on RigidPose {
  RigidPose copyAt(Vec3 position) =>
      RigidPose(position: position, orientation: orientation);
}
