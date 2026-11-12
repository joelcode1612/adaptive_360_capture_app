import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

import 'capture_flow_test.dart' show calibratedHarness, Harness;

/// Completion is a photograph, not an alignment reading.
///
/// These pin the guidance contract: the arrow and ring belong to the one
/// incomplete active target, a successfully saved target leaves the active
/// guidance immediately, and the next target is chosen from the actual list of
/// incomplete targets. A ring at 100% without a saved photograph must not
/// advance anything, and a late or repeated completion must not skip a target.
void main() {
  /// Selects [id] and holds the aim until the real automatic shutter fires and
  /// its transaction — including the completion transition and the next
  /// selection — has settled, so assertions can run immediately afterwards.
  Future<void> aimAndCapture(Harness harness, int id) async {
    await harness.controller.selectTarget(id);
    await Harness.flush();
    // A deliberate move off the target first. This is what re-aiming means to
    // the controller: it breaks the stability window and clears a latched
    // failure, so a retry is a fresh alignment episode rather than a loop.
    await harness.emit(orientation: Quat.axisAngle(90, Vec3.unitY));
    await harness.holdForAutomaticShutter();
  }

  group('alignment is not completion', () {
    test('a full ring without a saved photograph does not advance', () async {
      final harness = await calibratedHarness(autoAdvance: true);
      await harness.controller.selectTarget(1);

      // Hold the photograph in flight. With only one shutter, the instant the
      // ring fills IS the instant it fires — so the window in which "aligned
      // and steady" is true while no photograph exists is the save itself.
      // This is the invariant that matters: the ring is not the completion.
      final gate = Completer<void>();
      harness.gateway.stillGate = gate.future;
      await harness.emitUntilShutterArms();

      final state = harness.controller.state;
      expect(state.alignment, isNotNull);
      expect(state.alignment!.withinTolerance, isTrue);
      expect(state.stable, isTrue);
      expect(harness.gateway.stillRequests, 1);

      // Aligned, steady, shot requested — and still the same target, with no
      // photograph and no advancement.
      expect(state.activeTargetId, 1);
      expect(state.guidanceTarget?.targetId, 1);
      expect(state.targets[0].status, isNot(CaptureTargetStatus.captured));
      expect(state.targets[0].imagePath, isNull);
      expect(state.capturedCount, 0);

      // Only the saved record completes it.
      gate.complete();
      await Harness.waitFor(() => harness.controller.state.capturedCount == 1);
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.captured,
      );
      expect(harness.controller.state.activeTargetId, 2);
    });

    test('a failed photograph keeps the target active and guided', () async {
      final harness = await calibratedHarness(
        stillError: const ArCoreFailure('Fake: no camera image.'),
        autoAdvance: true,
      );

      await aimAndCapture(harness, 1);

      final state = harness.controller.state;
      expect(harness.gateway.stillRequests, 1);
      expect(state.targets[0].status, CaptureTargetStatus.failed);
      expect(state.targets[0].imagePath, isNull);
      expect(state.capturedCount, 0);
      expect(state.activeTargetId, 1, reason: 'no advance on failure');
      expect(state.guidanceTarget?.targetId, 1);
      expect(state.instruction, isNot(contains('Select a target')));

      // The same target can be aimed at and shot again; success then advances.
      harness.gateway.stillError = null;
      await aimAndCapture(harness, 1);
      expect(harness.controller.state.capturedCount, 1);
      expect(harness.controller.state.activeTargetId, 2);
    });
  });

  group('a saved target leaves the guidance', () {
    test(
      'the completed target is replaced by the next incomplete one',
      () async {
        final harness = await calibratedHarness(autoAdvance: true);
        final firstNode =
            harness.controller.state.targets[0].anchorWorldPosition!;
        expect(firstNode, isNotNull);

        await aimAndCapture(harness, 1);

        final state = harness.controller.state;
        expect(state.targets[0].status, CaptureTargetStatus.captured);
        expect(state.targets[0].imagePath, isNotNull);
        expect(state.capturedCount, 1);
        expect(state.activeTargetId, 2);
        expect(state.guidanceTarget?.targetId, 2);

        // The finished target's node is gone from the renderer's scene, not
        // merely faded, and the new target is the one that is placed and
        // guided. Its shared station anchor stays — the other 25 nodes need it —
        // so the node is identified by its own world position.
        expect(
          harness.gateway.lastScene.any((draw) {
            final m = draw.modelMatrix;
            if (m == null || m.length < 15) return false;
            return (Vec3(m[12], m[13], m[14]) - firstNode).length < 1e-5;
          }),
          isFalse,
          reason: 'a captured target must not keep its active marker',
        );
        expect(state.activeAnchored, isTrue);
        expect(state.activeAnchorTracking, isTrue);

        // The new target starts clean: the previous target's 0° alignment and
        // full stability window are not carried over. The aim that just
        // completed target 1 is 45° off target 2, and that is exactly what the
        // fresh alignment says.
        expect(state.alignment!.angularErrorDeg, closeTo(45, 0.5));
        expect(state.stable, isFalse);
        expect(state.stabilityProgress, 0);
        expect(state.targets[1].status, CaptureTargetStatus.active);

        // The completion is persisted, and the target cannot be selected again
        // as active guidance.
        expect(
          harness.repository.targets['s1']![0].status,
          CaptureTargetStatus.captured,
        );
        await harness.controller.selectTarget(1);
        await Harness.flush();
        expect(harness.controller.state.activeTargetId, 2);
        expect(harness.controller.state.guidanceTarget?.targetId, 2);
      },
    );

    test('the arrow is aimed at the new target', () async {
      final harness = await calibratedHarness(autoAdvance: true);
      await aimAndCapture(harness, 1);
      expect(harness.controller.state.activeTargetId, 2);

      await harness.emit();
      final alignment = harness.controller.state.alignment;
      expect(alignment, isNotNull);
      expect(alignment!.usable, isTrue);

      final frame = StationFrame(origin: Vec3.zero, orientation: Quat.identity);
      final expected = frame
          .localToWorld(buildCaptureSphere()[1].direction)
          .normalized;
      expect(alignment.directionWorld.x, closeTo(expected.x, 1e-9));
      expect(alignment.directionWorld.y, closeTo(expected.y, 1e-9));
      expect(alignment.directionWorld.z, closeTo(expected.z, 1e-9));
      // And it is not the direction of the target just saved.
      final previous = frame
          .localToWorld(buildCaptureSphere()[0].direction)
          .normalized;
      expect(alignment.directionWorld.x, isNot(closeTo(previous.x, 1e-6)));
    });

    test('next selection skips completed targets in list order', () async {
      final harness = await calibratedHarness(autoAdvance: true);

      await aimAndCapture(harness, 2);
      expect(harness.controller.state.activeTargetId, 3);

      // The user goes back to the target that was skipped. Once it is saved,
      // the next target is the first incomplete one in list order — target 2
      // is done now and must not become active again.
      await aimAndCapture(harness, 1);
      final state = harness.controller.state;
      expect(state.capturedCount, 2);
      expect(state.targets[1].status, CaptureTargetStatus.captured);
      expect(state.activeTargetId, 3);
      expect(state.guidanceTarget?.targetId, 3);
    });

    test(
      'retake is the explicit reset that makes it selectable again',
      () async {
        final harness = await calibratedHarness(autoAdvance: true);
        await aimAndCapture(harness, 1);
        await aimAndCapture(harness, 2);
        expect(harness.controller.state.capturedCount, 2);

        await harness.controller.retake(1);
        await Harness.flush();

        final state = harness.controller.state;
        expect(state.targets[0].status, CaptureTargetStatus.active);
        expect(state.targets[0].imagePath, isNull);
        expect(state.activeTargetId, 1);
        expect(state.guidanceTarget?.targetId, 1);
        expect(state.capturedCount, 1);
        expect(harness.repository.stations['s1']!.capturedCount, 1);

        await aimAndCapture(harness, 1);
        expect(harness.controller.state.capturedCount, 2);
        expect(harness.controller.state.activeTargetId, 3);
      },
    );
  });

  group('duplicate and interrupted events', () {
    test(
      'eligible frames arriving inside the save do not skip a target',
      () async {
        final harness = await calibratedHarness(autoAdvance: true);
        await harness.controller.selectTarget(1);

        // Hold the write open, then keep the pose aimed and steady. Every one
        // of these frames re-evaluates the gate, so the in-flight latch is the
        // only thing standing between them and a second photograph. Three
        // frames — not twenty: the save refuses a photograph older than 250 ms
        // from its armed frame, and that freshness gate is real, so the frames
        // must stay inside it rather than blow past it.
        final gate = Completer<void>();
        harness.gateway.stillGate = gate.future;
        await harness.emitUntilShutterArms();
        await harness.emitStable(count: 3);
        expect(harness.gateway.stillRequests, 1);

        gate.complete();
        await Harness.waitFor(
          () => harness.controller.state.capturedCount == 1,
        );
        await Harness.flush();

        final state = harness.controller.state;
        expect(harness.gateway.stillRequests, 1);
        expect(state.capturedCount, 1);
        expect(state.targets[0].status, CaptureTargetStatus.captured);
        expect(state.activeTargetId, 2);
        expect(state.targets[1].status, CaptureTargetStatus.active);
      },
    );

    test('losing tracking neither completes nor advances', () async {
      final harness = await calibratedHarness(autoAdvance: true);
      await harness.controller.selectTarget(1);
      // Aligned, but short of the 600 ms hold: the shutter has not armed yet,
      // which is the only honest way to observe a tracking loss before a
      // photograph exists now that the gate fires by itself.
      await harness.emitStable(count: 5);
      expect(harness.controller.state.alignment!.withinTolerance, isTrue);
      expect(harness.gateway.stillRequests, 0);

      await harness.emit(tracking: TrackingState.paused);

      final state = harness.controller.state;
      expect(state.targets[0].status, CaptureTargetStatus.active);
      expect(state.activeTargetId, 1);
      expect(state.guidanceTarget?.targetId, 1);
      expect(state.capturedCount, 0);
      expect(state.alignment, isNull);
      expect(harness.gateway.stillRequests, 0);
      // Keep holding the paused pose: the gate is evaluated on every frame, so
      // this is the sustained version of the old manual press.
      await harness.emitStable(tracking: TrackingState.paused);
      await Harness.flush();
      expect(harness.gateway.stillRequests, 0);
      expect(harness.controller.state.activeTargetId, 1);
    });

    test('a selection made during the save survives the completion', () async {
      final harness = await calibratedHarness(autoAdvance: true);
      await harness.controller.selectTarget(1);

      // Hold the photograph in flight. This is the window in which the user
      // can still operate the target sheet.
      final gate = Completer<void>();
      harness.gateway.stillGate = gate.future;
      await harness.emitUntilShutterArms();

      await harness.controller.selectTarget(10);
      await Harness.flush();
      expect(harness.controller.state.activeTargetId, 10);

      gate.complete();
      await Harness.waitFor(() => harness.controller.state.capturedCount == 1);
      await Harness.flush();

      final state = harness.controller.state;
      // The photograph is recorded against the target that was shot…
      expect(state.targets[0].status, CaptureTargetStatus.captured);
      expect(state.capturedCount, 1);
      // …and the newer selection keeps the guidance; it is not replaced by
      // the completed target or by an automatic advance.
      expect(state.activeTargetId, 10);
      expect(state.guidanceTarget?.targetId, 10);
      expect(state.targets[9].status, CaptureTargetStatus.active);
      expect(state.alignment, isNull);
    });
  });
}
