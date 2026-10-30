import 'dart:math' as math;

/// The live capture guidance state machine.
///
/// Ported from the prototype's `tick()` in `360° Capture Prototype (1).html`.
/// This is the state the user *sees*: the orb colour, the instruction line and
/// the capture progress ring all read from [CaptureGuidanceState]. It is pure
/// Dart and owns no camera, so the plain-`dart` suite pins its exact thresholds.
///
/// The prototype drives it once per animation frame with the phone's current
/// orientation and the target's orientation; here the flow feeds it the same
/// two directions every tick. The transitions are copied verbatim:
///
/// * `init` → after [initHoldSec] → `search`;
/// * `search` → when the direction error `d < [searchAlignDeg]` → `align`;
/// * `align` → if `d > [alignExitDeg]` back to `search`; else after
///   [alignHoldSec] → `cap`;
/// * `cap` → if `d > [capExitDeg]` back to `search`; else after [capHoldSec]
///   the frame is captured (`done`) or, if [forceFail] was set, `fail`;
/// * `done` → after [doneHoldSec] the caller advances to the next target;
/// * `fail` → stays until the caller retries or resets.
enum CaptureGuidanceState { init, search, align, cap, done, fail }

/// The shortest signed angle from [from] to [to], in (−180, 180].
double angleDiff360(double from, double to) => ((to - from + 540) % 360) - 180;

/// The yaw correction the user has to make, in degrees, **positive = turn
/// right**.
///
/// This is `angleDiff360` negated, and the negation is the handedness fix of
/// CHANGELOG entry 1 applied to the yaw numbers rather than to the camera-frame
/// vector: `Quat.yawPitch` reports `atan2(f.x, f.z)` and `+x̂` is the physical
/// *left*, so a *larger* target yaw than the heading's is a target to the *left*.
/// The prototype's `tick()` compares the raw yaws and therefore says "Turn right"
/// for a target on the left — mirrored guidance that its own tests could not see,
/// for the same reason entry 1 could not. `wording()`, which works from
/// [toCameraFrame], is the authority; this agrees with it, and a check pins the
/// two against each other.
double _yawErrorRightwardDeg(double headYawDeg, double targetYawDeg) =>
    -angleDiff360(headYawDeg, targetYawDeg);

/// The signed correction pair the guidance copy is written from.
///
/// Positive `yawRightDeg` = turn right, positive `pitchUpDeg` = look up. The
/// yaw term is dropped for a pole target, as the prototype does
/// (`pole ? 0 : ad(...)`), because every azimuth is the same place when the aim
/// is straight up.
///
/// Both the state machine and the capture screen need the same pair, and the
/// screen used to recompute it inline — which is how a sign convention ends up
/// applied in one place and not the other.
({double yawRightDeg, double pitchUpDeg}) guidanceErrorDeg({
  required double headYawDeg,
  required double headPitchDeg,
  required double targetYawDeg,
  required double targetPitchDeg,
}) {
  final pole = targetPitchDeg.abs() >= 90;
  return (
    yawRightDeg: pole ? 0 : _yawErrorRightwardDeg(headYawDeg, targetYawDeg),
    pitchUpDeg: targetPitchDeg - headPitchDeg,
  );
}

/// The guidance state machine.
class CaptureGuidance {
  CaptureGuidanceState state = CaptureGuidanceState.init;

  /// Time accumulated in the current hold, seconds.
  double t = 0;

  /// Capture progress, 0…1, valid while [state] is [CaptureGuidanceState.cap].
  double capProgress = 0;

  /// Whether the target is outside the view frustum (computed by the view and
  /// reported to the engine). Affects only the line style and the "target
  /// outside view" hint; it does not change the state transitions.
  bool outOfView = false;

  bool _forceFail = false;

  /// True after a capture was aborted because the phone moved too much
  /// (`d > [capExitDeg]` while in `cap`), mirroring the prototype's
  /// `S.msg='moving'` banner. Cleared once the target re-aligns or the frame is
  /// captured, so the "Phone moving too much — hold steady" line only shows
  /// while it is genuinely true.
  bool _moving = false;

  /// Whether the last capture attempt was aborted by motion (read by the UI for
  /// the transient banner).
  bool get moving => _moving;

  /// Prototype timings, in seconds.
  static const double initHoldSec = 1.4;
  static const double searchAlignDeg = 5;
  static const double alignExitDeg = 8;
  static const double alignHoldSec = 0.9;
  static const double capExitDeg = 10;
  static const double capHoldSec = 1.3;
  static const double doneHoldSec = 0.9;

  /// Resets to the initial state, ready for a new target.
  void reset() {
    state = CaptureGuidanceState.init;
    t = 0;
    capProgress = 0;
    _forceFail = false;
    _moving = false;
  }

  /// Requests the next captured frame to fail (the prototype's `ctl('fail')`).
  ///
  /// Consumed once: after a `fail` the flag clears so only the one frame is
  /// marked bad, exactly as the prototype's `S.fail` does.
  void requestFail() => _forceFail = true;

  /// Advances the machine by [dt] seconds.
  ///
  /// [headYawDeg]/[headPitchDeg] is the phone's current orientation;
  /// [targetYawDeg]/[targetPitchDeg] is the aim. For a pole target the yaw
  /// contribution to the error is dropped, as the prototype does
  /// (`pole ? 0 : ad(...)`).
  void update(
    double dt, {
    required double headYawDeg,
    required double headPitchDeg,
    required double targetYawDeg,
    required double targetPitchDeg,
    bool outOfView = false,
    bool forceFail = false,
  }) {
    this.outOfView = outOfView;
    if (forceFail) _forceFail = true;
    t += dt;

    final e = guidanceErrorDeg(
      headYawDeg: headYawDeg,
      headPitchDeg: headPitchDeg,
      targetYawDeg: targetYawDeg,
      targetPitchDeg: targetPitchDeg,
    );
    final dy = e.yawRightDeg;
    final dp = e.pitchUpDeg;
    final d = math.sqrt(dy * dy + dp * dp);

    switch (state) {
      case CaptureGuidanceState.init:
        if (t > initHoldSec) {
          state = CaptureGuidanceState.search;
          t = 0;
        }
      case CaptureGuidanceState.search:
        if (d < searchAlignDeg) {
          state = CaptureGuidanceState.align;
          t = 0;
          _moving = false;
        }
      case CaptureGuidanceState.align:
        if (d > alignExitDeg) {
          state = CaptureGuidanceState.search;
          t = 0;
        } else if (t > alignHoldSec) {
          state = CaptureGuidanceState.cap;
          t = 0;
          capProgress = 0;
        }
      case CaptureGuidanceState.cap:
        if (d > capExitDeg) {
          state = CaptureGuidanceState.search;
          t = 0;
          capProgress = 0;
          _moving = true;
        } else {
          capProgress = (t / capHoldSec).clamp(0, 1);
          if (t > capHoldSec) {
            state = _forceFail
                ? CaptureGuidanceState.fail
                : CaptureGuidanceState.done;
            _forceFail = false;
            _moving = false;
            t = 0;
          }
        }
      case CaptureGuidanceState.done:
        // Terminal: the flow reads [state] for the orb and the instruction, and
        // calls [reset] itself when the captured frame advances the session to
        // the next target. Nothing here moves on its own.
        break;
      case CaptureGuidanceState.fail:
        // Stays until [reset] or [retry].
        break;
    }
  }

  /// True the moment a frame has been held long enough to capture.
  bool get isDone => state == CaptureGuidanceState.done;

  /// True when the last capture was forced to fail.
  bool get isFail => state == CaptureGuidanceState.fail;

  /// Clears a `fail` so the next attempt can succeed (the prototype's retry).
  void retry() {
    if (state == CaptureGuidanceState.fail) reset();
  }
}
