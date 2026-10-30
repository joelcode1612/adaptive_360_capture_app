import 'package:flutter/foundation.dart';

/// The startup sequence of the guided capture screen, as the user sees it.
///
/// **Why this exists.** The tour capture flow used to navigate straight into
/// `CaptureScreen.arCapture` and paint an unbounded spinner until
/// `engine.session` was non-null — but nothing on that navigation path ever
/// called `beginCapture()`, the only place a session is created. The spinner
/// was permanent. This model makes the startup sequence explicit, gives every
/// stage a name and a bounded wait, and — the part that matters — makes the
/// wait *expose* the stage it stopped at instead of pretending progress.
///
/// Pure Dart on purpose: the stages, the stall detection and the marker lines
/// are all testable without a device, a camera or an AR session. The widget
/// layer drives it and paints what it says.
enum CaptureStartStage {
  /// The screen is up; nothing has been asked of the engine yet.
  entering,

  /// `beginCapture()` has been called and has not returned.
  startingSession,

  /// The session exists. The machine is still warming up: no pose has been
  /// used to build the target plan yet.
  waitingForPose,

  /// A pose is live and the session has built its targets: the guidance state
  /// machine is running and the capture reference is real.
  tracking,

  /// A stage exceeded its bounded wait, or a call threw. [CaptureStartupState.
  /// error] names the stage and what happened; the UI offers Retry and Back.
  failed;

  /// One line for the panel. Never "Loading…": every stage says what is being
  /// waited for, and the failed stage says what failed and where.
  String get label => switch (this) {
    CaptureStartStage.entering => 'Preparing the capture view',
    CaptureStartStage.startingSession => 'Starting the capture session',
    CaptureStartStage.waitingForPose => 'Waiting for the camera direction',
    CaptureStartStage.tracking => 'Tracking',
    CaptureStartStage.failed => 'Capture did not start',
  };
}

/// How long each startup stage may take before the wait is abandoned.
///
/// Bounded waits exist to *expose* the stage that stalled — they are never
/// used to declare success. The values are deliberately generous: a cold
/// camera open and the machine's warm-up legitimately take seconds on a slow
/// phone, and a tight timeout would fail healthy devices.
class CaptureStartTimeouts {
  const CaptureStartTimeouts();

  /// `beginCapture()` opening the camera and building the session.
  static const Duration sessionStart = Duration(seconds: 8);

  /// From session created to the first pose driving the target plan: the
  /// warm-up ticks plus the sensors' own start-up.
  static const Duration firstPose = Duration(seconds: 20);
}

/// One startup attempt, tracked from the moment the screen is entered.
///
/// The screen owns one of these and feeds it evidence — a session, a pose, a
/// failure. Two rules are built in, because both were live bugs:
///
/// 1. **A session is not a tracking system.** [CaptureStartStage.tracking]
///    requires the session *and* its built targets. Reporting "ready" because
///    `beginCapture()` returned is how a black viewfinder got called success.
/// 2. **A missing pose stays missing.** [poseCount]/[consecutivePoseMisses]
///    count what actually arrived; nothing here substitutes a default
///    orientation and calls it valid.
class CaptureStartupState {
  CaptureStartupState({DateTime? now})
    : enteredAt = now ?? DateTime.now(),
      _stage = CaptureStartStage.entering;

  /// When the screen was entered. Every elapsed figure is measured from here.
  final DateTime enteredAt;

  CaptureStartStage _stage;

  /// The last completed pose time, or `null` while none has arrived.
  DateTime? _lastPoseAt;

  /// Poses observed since the last stage change.
  int _poseCount = 0;

  /// Consecutive observations with no pose. Expected briefly while sensors
  /// start; a stall is [CaptureStartTimeouts.firstPose] without one.
  int _consecutivePoseMisses = 0;

  /// Set on a thrown call, or by [fail] when a bounded wait expires.
  String? error;

  CaptureStartStage get stage => _stage;
  DateTime? get lastPoseAt => _lastPoseAt;
  int get poseCount => _poseCount;
  int get consecutivePoseMisses => _consecutivePoseMisses;

  bool get isTracking => _stage == CaptureStartStage.tracking;
  bool get isFailed => _stage == CaptureStartStage.failed;

  /// Moves to [stage].
  ///
  /// The counters are deliberately **not** reset here: `poseCount` and
  /// `consecutivePoseMisses` describe the whole attempt, and the diagnostics
  /// panel reads them as such — "2 poses seen" must not lose the pose that
  /// triggered the stage change. [retry] is the only place they reset.
  void _enter(CaptureStartStage next) {
    _stage = next;
  }

  /// `beginCapture()` was called. Idempotent: a second call while one is in
  /// flight keeps the stage instead of restarting the attempt.
  void markSessionRequested() => _enter(CaptureStartStage.startingSession);

  /// `beginCapture()` returned with a session. Idempotent.
  void markSessionCreated() => _enter(CaptureStartStage.waitingForPose);

  /// Records one observation of the live session.
  ///
  /// [hasSession] is `engine.session != null`; [hasTargets] is the session
  /// having built its target plan (the machine's warm-up complete);
  /// [hasPose] is a non-null pose from the pose source. Tracking requires all
  /// three — a session with no pose is still [CaptureStartStage.
  /// waitingForPose], and the UI keeps saying so.
  void observe({
    required bool hasSession,
    required bool hasTargets,
    required bool hasPose,
    DateTime? now,
  }) {
    if (_stage == CaptureStartStage.failed) return;
    if (!hasSession) return;
    if (_stage == CaptureStartStage.startingSession ||
        _stage == CaptureStartStage.entering) {
      _enter(CaptureStartStage.waitingForPose);
    }
    if (hasPose) {
      _lastPoseAt = now ?? DateTime.now();
      _poseCount++;
      _consecutivePoseMisses = 0;
    } else {
      _consecutivePoseMisses++;
    }
    if (hasTargets && hasPose) _enter(CaptureStartStage.tracking);
  }

  /// The stage a bounded wait expired in, or `null` while everything is inside
  /// its budget.
  ///
  /// Each answer names [CaptureStartStage], because "it timed out" without a
  /// stage is exactly the generic spinner this replaces.
  CaptureStartStage? stalledStage(DateTime now) {
    if (_stage == CaptureStartStage.failed ||
        _stage == CaptureStartStage.tracking) {
      return null;
    }
    final inStage = now.difference(enteredAt);
    switch (_stage) {
      case CaptureStartStage.entering:
      case CaptureStartStage.startingSession:
        return inStage > CaptureStartTimeouts.sessionStart ? _stage : null;
      case CaptureStartStage.waitingForPose:
        return inStage > CaptureStartTimeouts.firstPose ? _stage : null;
      case CaptureStartStage.tracking:
      case CaptureStartStage.failed:
        return null;
    }
  }

  /// Marks the startup failed, naming the stage and why.
  ///
  /// [thrown] is reported verbatim for an exception; [stalledIn] carries the
  /// stage when the cause is a bounded wait.
  void fail(String reason, {CaptureStartStage? stalledIn, Object? thrown}) {
    _stage = CaptureStartStage.failed;
    final where = stalledIn == null ? '' : ' at ${stalledIn.label}';
    final cause = thrown == null ? reason : '$reason: $thrown';
    error = 'Capture did not start$where. $cause';
  }

  /// Arms a retry: back to [CaptureStartStage.startingSession] with the
  /// counters cleared, keeping [enteredAt] so the elapsed figure stays honest.
  void retry() {
    error = null;
    _lastPoseAt = null;
    _poseCount = 0;
    _consecutivePoseMisses = 0;
    _enter(CaptureStartStage.startingSession);
  }

  /// One line for the panel: stage, and while waiting, how long.
  String describe(DateTime now) {
    if (isFailed) return error ?? CaptureStartStage.failed.label;
    final waited = now.difference(enteredAt).inMilliseconds;
    if (isTracking) {
      final pose = _lastPoseAt == null
          ? 'no pose yet'
          : 'pose ${now.difference(_lastPoseAt!).inMilliseconds} ms ago';
      return '${_stage.label} ($pose)';
    }
    return '${_stage.label} — $waited ms';
  }
}

/// The startup markers, and where each one may be logged from.
///
/// A marker is printed **only after its operation actually happened** — never
/// before, and never as a hopeful default. The elapsed figure is measured from
/// [CaptureStartupState.enteredAt], so the log reads as a timeline.
class CaptureStartMarkers {
  const CaptureStartMarkers._();

  /// AR3.1 — the capture screen was entered with no session.
  static const String entered = 'AR3.1';

  /// AR3.2 — `beginCapture()` was called.
  static const String sessionRequested = 'AR3.2';

  /// AR3.3 — `beginCapture()` returned and a session exists.
  static const String sessionCreated = 'AR3.3';

  /// AR3.4 — the first pose drove the target plan: tracking is real.
  static const String trackingLive = 'AR3.4';

  /// AR3.5 — a startup stage failed, named. Always paired with the reason.
  static const String failed = 'AR3.5';

  /// Logs one marker with its elapsed time. No-op outside debug builds, so the
  /// release console stays clean and no personal data is emitted.
  static void log(String marker, String event, DateTime since) {
    if (!kDebugMode) return;
    final ms = DateTime.now().difference(since).inMilliseconds;
    debugPrint('[$marker] $event ($ms ms since screen entry)');
  }
}
