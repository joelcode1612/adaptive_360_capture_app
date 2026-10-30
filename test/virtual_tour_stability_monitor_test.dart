import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/services/virtual_tour_stability_monitor.dart';

bool update(
  VirtualTourStabilityMonitor monitor,
  Duration now, {
  bool gateOpen = true,
  Duration? poseAge,
}) => monitor.update(
  now: now,
  orientation: Quat.identity,
  position: Vec3.zero,
  gateOpen: gateOpen,
  poseAge: poseAge,
);

void main() {
  group('reset', () {
    test('drops a completed hold and its issue', () {
      final monitor = VirtualTourStabilityMonitor();
      update(monitor, Duration.zero);
      expect(update(monitor, const Duration(milliseconds: 600)), isTrue);
      expect(monitor.heldFor, const Duration(milliseconds: 600));
      expect(monitor.progress, 1);

      monitor.reset();

      expect(monitor.isStable, isFalse);
      expect(monitor.heldFor, Duration.zero);
      expect(monitor.progress, 0);
      expect(monitor.lastIssue, isNull);
      expect(monitor.lastAngularRateDegPerSec, isNull);
      expect(monitor.lastPoseAge, isNull);
    });

    test('a window after reset is measured from the next sample', () {
      final monitor = VirtualTourStabilityMonitor();
      update(monitor, Duration.zero);
      update(monitor, const Duration(milliseconds: 300));
      monitor.reset();

      expect(
        update(monitor, const Duration(milliseconds: 900)),
        isFalse,
        reason: 'one sample cannot span a window',
      );
      expect(monitor.heldFor, Duration.zero);

      expect(update(monitor, const Duration(milliseconds: 1499)), isFalse);
      expect(update(monitor, const Duration(milliseconds: 1500)), isTrue);
    });
  });

  group('gate', () {
    test('closing the gate clears the partial window', () {
      final monitor = VirtualTourStabilityMonitor();
      update(monitor, Duration.zero);
      update(monitor, const Duration(milliseconds: 400));
      expect(monitor.heldFor, const Duration(milliseconds: 400));

      update(monitor, const Duration(milliseconds: 450), gateOpen: false);
      expect(monitor.heldFor, Duration.zero);
      expect(monitor.isStable, isFalse);

      update(monitor, const Duration(milliseconds: 500));
      expect(monitor.heldFor, Duration.zero);
      expect(update(monitor, const Duration(milliseconds: 1100)), isTrue);
    });

    test('a stale pose refuses and clears the window', () {
      final monitor = VirtualTourStabilityMonitor();
      update(monitor, Duration.zero);
      update(monitor, const Duration(milliseconds: 400));

      final stale = update(
        monitor,
        const Duration(milliseconds: 600),
        poseAge: const Duration(milliseconds: 151),
      );
      expect(stale, isFalse);
      expect(monitor.heldFor, Duration.zero);
      expect(monitor.lastIssue, VirtualTourStabilityIssue.poseAge);
    });
  });

  test('duplicate timestamps cannot accumulate a hold', () {
    final monitor = VirtualTourStabilityMonitor();
    update(monitor, Duration.zero);
    for (var i = 0; i < 20; i++) {
      expect(update(monitor, Duration.zero), isFalse);
    }
    expect(monitor.heldFor, Duration.zero);
    expect(monitor.progress, 0);
    expect(monitor.lastIssue, VirtualTourStabilityIssue.window);
  });
}
