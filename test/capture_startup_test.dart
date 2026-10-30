import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/capture_startup.dart';

/// The startup state model: the stages, the bounded waits, and the two rules
/// that keep them honest.
///
/// The bug these tests guard against is the one that shipped: the capture
/// screen waited forever for a session that nothing ever created, and would
/// have reported "ready" on a `null` pose if a shortcut had been taken instead.
void main() {
  final t0 = DateTime.utc(2026, 1, 1);

  group('stage progression', () {
    test('a session alone is not tracking', () {
      final s = CaptureStartupState(now: t0);
      expect(s.stage, CaptureStartStage.entering);

      s.markSessionRequested();
      expect(s.stage, CaptureStartStage.startingSession);

      s.markSessionCreated();
      expect(s.stage, CaptureStartStage.waitingForPose);
      expect(s.isTracking, isFalse);
    });

    test('tracking needs session, targets and a pose — all three', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.markSessionCreated();

      // Session and a pose, but the machine has not built the target plan
      // yet: the warm-up is still running, so this is still a wait.
      s.observe(hasSession: true, hasTargets: false, hasPose: true, now: t0);
      expect(s.stage, CaptureStartStage.waitingForPose);
      expect(s.lastPoseAt, t0);
      expect(s.poseCount, 1);

      // Now all three: the capture reference is real.
      s.observe(
        hasSession: true,
        hasTargets: true,
        hasPose: true,
        now: t0.add(const Duration(milliseconds: 250)),
      );
      expect(s.isTracking, isTrue);
      expect(s.poseCount, 2);
    });

    test('a missing pose stays missing — nothing substitutes a default', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.markSessionCreated();

      for (var i = 0; i < 3; i++) {
        s.observe(
          hasSession: true,
          hasTargets: true,
          hasPose: false,
          now: t0.add(Duration(milliseconds: 250 * i)),
        );
      }
      expect(s.isTracking, isFalse);
      expect(s.lastPoseAt, isNull, reason: 'a null pose is not recorded');
      expect(s.consecutivePoseMisses, 3);
      expect(s.poseCount, 0);

      // The moment a real pose arrives, tracking is reached and the miss
      // counter resets — the transient case is distinguished from the
      // persistent one by elapsed time, not by pretending.
      s.observe(
        hasSession: true,
        hasTargets: true,
        hasPose: true,
        now: t0.add(const Duration(seconds: 1)),
      );
      expect(s.isTracking, isTrue);
      expect(s.consecutivePoseMisses, 0);
      expect(s.lastPoseAt, t0.add(const Duration(seconds: 1)));
    });

    test('observations before a session exist are held, not counted', () {
      final s = CaptureStartupState(now: t0);
      s.observe(hasSession: false, hasTargets: false, hasPose: false, now: t0);
      expect(s.stage, CaptureStartStage.entering);
      expect(s.consecutivePoseMisses, 0);
    });

    test('a failed startup ignores further observations', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.fail('the camera is in use');
      s.observe(hasSession: true, hasTargets: true, hasPose: true, now: t0);
      expect(s.isFailed, isTrue);
      expect(s.isTracking, isFalse);
    });
  });

  group('bounded waits name the stage', () {
    test('the session-start budget exposes the startingSession stage', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      expect(s.stalledStage(t0.add(const Duration(seconds: 2))), isNull);
      expect(
        s.stalledStage(t0.add(CaptureStartTimeouts.sessionStart)),
        isNull,
        reason: 'the boundary itself is still inside the budget',
      );
      expect(
        s.stalledStage(
          t0.add(
            CaptureStartTimeouts.sessionStart + const Duration(seconds: 1),
          ),
        ),
        CaptureStartStage.startingSession,
      );
    });

    test('the first-pose budget exposes the waitingForPose stage', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.markSessionCreated();
      s.observe(hasSession: true, hasTargets: false, hasPose: false, now: t0);

      expect(s.stalledStage(t0.add(const Duration(seconds: 10))), isNull);
      expect(
        s.stalledStage(
          t0.add(CaptureStartTimeouts.firstPose + const Duration(seconds: 1)),
        ),
        CaptureStartStage.waitingForPose,
      );
    });

    test('once tracking is real, no stage can stall', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.markSessionCreated();
      s.observe(hasSession: true, hasTargets: true, hasPose: true, now: t0);
      expect(
        s.stalledStage(t0.add(const Duration(minutes: 5))),
        isNull,
        reason: 'a live capture is not a startup wait',
      );
    });

    test('a failed state is not reported as a stall', () {
      final s = CaptureStartupState(now: t0);
      s.fail('the camera is in use');
      expect(s.stalledStage(t0.add(const Duration(minutes: 5))), isNull);
    });
  });

  group('failure and retry', () {
    test('fail() names the stage and the cause', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.fail(
        'the camera may be held by another app',
        stalledIn: CaptureStartStage.startingSession,
      );
      expect(s.isFailed, isTrue);
      expect(s.error, contains('Starting the capture session'));
      expect(s.error, contains('the camera may be held by another app'));
    });

    test('an exception is reported verbatim', () {
      final s = CaptureStartupState(now: t0);
      s.fail('the capture session failed', thrown: StateError('boom'));
      expect(s.error, contains('boom'));
    });

    test('retry re-arms the failed stage without losing the clock', () {
      final s = CaptureStartupState(now: t0);
      s.markSessionRequested();
      s.observe(
        hasSession: true,
        hasTargets: true,
        hasPose: false,
        now: t0.add(const Duration(seconds: 1)),
      );
      s.fail('no camera direction arrived');
      s.retry();

      expect(s.stage, CaptureStartStage.startingSession);
      expect(s.isFailed, isFalse);
      expect(s.error, isNull);
      expect(s.lastPoseAt, isNull);
      expect(s.consecutivePoseMisses, 0);
      expect(
        s.enteredAt,
        t0,
        reason: 'the elapsed figure must stay measured from screen entry',
      );
    });

    test('describe reports the failure, then the wait, then the pose', () {
      final failed = CaptureStartupState(now: t0);
      failed.fail('the camera is in use');
      expect(failed.describe(t0), contains('camera is in use'));

      final waiting = CaptureStartupState(now: t0);
      waiting.markSessionCreated();
      final text = waiting.describe(t0.add(const Duration(seconds: 3)));
      expect(text, contains('Waiting for the camera direction'));
      expect(text, contains('3000 ms'));

      final live = CaptureStartupState(now: t0);
      live.markSessionCreated();
      live.observe(hasSession: true, hasTargets: true, hasPose: true, now: t0);
      final liveText = live.describe(t0.add(const Duration(seconds: 1)));
      expect(liveText, contains('Tracking'));
      expect(liveText, contains('pose 1000 ms ago'));
    });
  });

  group('markers', () {
    test('the codes are the documented ones', () {
      expect(CaptureStartMarkers.entered, 'AR3.1');
      expect(CaptureStartMarkers.sessionRequested, 'AR3.2');
      expect(CaptureStartMarkers.sessionCreated, 'AR3.3');
      expect(CaptureStartMarkers.trackingLive, 'AR3.4');
      expect(CaptureStartMarkers.failed, 'AR3.5');
    });

    test('logging a marker never throws', () {
      expect(
        () => CaptureStartMarkers.log(
          CaptureStartMarkers.entered,
          'capture screen entered',
          t0,
        ),
        returnsNormally,
      );
    });
  });

  group('stage labels', () {
    test('every stage has a human label that is not a spinner word', () {
      for (final stage in CaptureStartStage.values) {
        expect(stage.label, isNotEmpty);
        expect(stage.label.toLowerCase(), isNot(contains('loading')));
      }
      expect(CaptureStartStage.failed.label, 'Capture did not start');
    });
  });
}
