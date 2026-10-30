import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

// ── Local finite / usable guards ──────────────────────────────────────────
//
// The shared Vec3 and Quat classes do not define `isFinite` / `isUsable`.
// Rather than modifying those types (which are used across the codebase),
// these file-private helpers provide the exact same semantics the call sites
// below need: reject NaN / Infinity before it reaches acos / atan2, and
// reject degenerate zero-length vectors that would normalise to garbage.

bool _vec3Finite(Vec3 v) => v.x.isFinite && v.y.isFinite && v.z.isFinite;

bool _vec3Usable(Vec3 v) => _vec3Finite(v) && v.length > 1e-9;

bool _quatFinite(Quat q) =>
    q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite;

/// Phone-to-target alignment.
///
/// **Pure Dart.** No Flutter, no ARCore, no clock, so every sign in it is
/// asserted by the plain-`dart` suite rather than discovered on a device.
///
/// ## What it answers
///
/// Given where the phone is now, where it is pointing now, and where the target
/// actually is in the world, how should the user move the phone?
///
/// The target position is a **world point from an ARCore anchor**, not a
/// direction. That is the whole point: the user is allowed to walk away from the
/// station, and the answer has to change accordingly. Subtracting two yaw angles
/// would give a constant answer no matter where the user stands, which is wrong.
///
/// ## The calculation
///
/// ```
/// D_world = targetWorldPosition − cameraWorldPosition
/// d       = normalize(D_world)
/// D_cam   = (x, y, z) = the same direction in the camera's own frame,
///                       (right, up, forward)
/// yawCorrection   = atan2(x, z)                     positive → turn right
/// pitchCorrection = atan2(y, √(x² + z²))            positive → tilt up
/// angularError    = acos(clamp(forward · d, −1, 1))  the 3-D error
/// ```
///
/// `D_cam` is `Quat.toCameraFrame`, which already returns
/// `(right, up, forward)` — see `station_frame.dart` for the handedness
/// argument. `atan2` is wrapped by construction, so `+179°` and `−179°` produce
/// a 2° correction rather than 358°; [shortestAngleDeg] is provided for the
/// cases that compare two angles rather than deriving one.
class AlignmentCalculator {
  const AlignmentCalculator();

  /// Computes the correction from the phone's current pose to [targetPosition].
  ///
  /// [isPole] suppresses the horizontal wording for the zenith and nadir, where
  /// yaw is undefined and "turn right" would be noise. The 3-D error is still
  /// reported, and it is the only quantity the readiness gate uses there.
  AlignmentResult compute({
    required RigidPose camera,
    required Vec3 targetPosition,
    required double toleranceDeg,
    bool isPole = false,
    double deadZoneDeg = 2,
  }) {
    // Reject invalid / non-finite inputs before any arithmetic.
    if (!_vec3Finite(camera.position) ||
        !_quatFinite(camera.orientation) ||
        !_vec3Finite(targetPosition)) {
      return AlignmentResult.unusable(
        distanceM: 0,
        message: 'Invalid pose or target position.',
      );
    }
    final delta = targetPosition - camera.position;
    final length = delta.length;
    if (!length.isFinite || length <= 1e-9) {
      return AlignmentResult.unusable(
        distanceM: 0,
        message: 'The target is at the camera; there is no direction to it.',
      );
    }
    final d = delta.normalized;
    if (!_vec3Finite(d) || !_vec3Usable(d)) {
      return AlignmentResult.unusable(
        distanceM: length,
        message: 'Invalid target direction.',
      );
    }
    // Transform into camera-local coordinates via the inverse camera rotation.
    final cameraQuat = camera.orientation.normalized;
    if (!_quatFinite(cameraQuat)) {
      return AlignmentResult.unusable(
        distanceM: length,
        message: 'Invalid camera orientation.',
      );
    }
    final dcRaw = cameraQuat.conjugate.rotate(d);
    if (!_vec3Finite(dcRaw)) {
      return AlignmentResult.unusable(
        distanceM: length,
        message: 'Invalid camera-local direction.',
      );
    }
    // `q.conjugate.rotate(d)` gives the components along `(q·x̂, q·ŷ, q·ẑ)`,
    // which in this project's camera convention is `(−right, up, forward)` —
    // `−q·x̂` is the physical screen-right (see `RigidPose`). Negating x is
    // therefore the one step that turns the rotation's basis into the
    // `(right, up, forward)` triple the projection contract expects; without it
    // every horizontal correction is mirrored.
    final dc = Vec3(-dcRaw.x, dcRaw.y, dcRaw.z);
    if (!_vec3Finite(dc)) {
      return AlignmentResult.unusable(
        distanceM: length,
        message: 'Invalid camera-local direction.',
      );
    }
    final yawCorrectionDeg = math.atan2(dc.x, dc.z) * radToDeg;
    final pitchCorrectionDeg =
        math.atan2(dc.y, math.sqrt(dc.x * dc.x + dc.z * dc.z)) * radToDeg;

    final forward = camera.forward;
    if (!_vec3Finite(forward) || !_vec3Usable(forward)) {
      return AlignmentResult.unusable(
        distanceM: length,
        message: 'Invalid camera forward direction.',
      );
    }
    final angularErrorDeg =
        math.acos(clampDouble(forward.dot(d), -1, 1)) * radToDeg;

    return AlignmentResult(
      directionWorld: d,
      directionInCamera: dc,
      distanceM: length,
      yawCorrectionDeg: yawCorrectionDeg,
      pitchCorrectionDeg: pitchCorrectionDeg,
      angularErrorDeg: angularErrorDeg,
      toleranceDeg: toleranceDeg,
      isPole: isPole,
      deadZoneDeg: deadZoneDeg,
    );
  }

  /// The signed smallest rotation from [fromDeg] to [toDeg], in `(-180, 180]`.
  ///
  /// `+179 → −179` is `+2`, not `−358`.
  static double shortestAngleDeg(double fromDeg, double toDeg) =>
      wrapDeg(toDeg - fromDeg);
}

/// The outcome of one alignment computation.
class AlignmentResult {
  /// Unit direction from the camera to the target, in world coordinates.
  final Vec3 directionWorld;

  /// The same direction in the camera's frame, `(right, up, forward)`.
  final Vec3 directionInCamera;

  /// The **display-only** camera-frame direction the arrow is drawn from.
  ///
  /// Identical to [directionInCamera] unless a caller ran it through
  /// [DisplayDirectionFilter]. It exists so the pointer can be de-jittered
  /// without touching [directionInCamera], [angularErrorDeg] or
  /// [yawCorrectionDeg] — the three numbers the capture gate and the wording
  /// read. A smoothed value must never be able to declare a shot ready, so the
  /// filter is applied *after* every gating quantity is computed and the result
  /// is carried in this separate field.
  ///
  /// `null` means "no display smoothing": consumers fall back to
  /// [directionInCamera], which is what a directly constructed result (tests,
  /// simulations) always wants.
  final Vec3? displayDirectionInCamera;

  /// Camera-to-target distance, in metres.
  final double distanceM;

  /// Positive → turn right. Wrapped into `(-180, 180]`.
  final double yawCorrectionDeg;

  /// Positive → tilt up.
  final double pitchCorrectionDeg;

  /// The 3-D angle between the optical axis and the target, in degrees.
  final double angularErrorDeg;

  final double toleranceDeg;
  final bool isPole;
  final double deadZoneDeg;

  /// Set when the geometry has no answer at all.
  final bool usable;
  final String? message;

  const AlignmentResult({
    required this.directionWorld,
    required this.directionInCamera,
    required this.distanceM,
    required this.yawCorrectionDeg,
    required this.pitchCorrectionDeg,
    required this.angularErrorDeg,
    required this.toleranceDeg,
    this.isPole = false,
    this.deadZoneDeg = 2,
    this.displayDirectionInCamera,
    this.usable = true,
    this.message,
  });

  /// The direction the pointer should be drawn along.
  ///
  /// Falls back to the unsmoothed [directionInCamera], so a result built
  /// without a display filter behaves exactly as it did before the filter
  /// existed.
  Vec3 get pointerDirection => displayDirectionInCamera ?? directionInCamera;

  /// Attaches a display-only direction without disturbing any gating quantity.
  AlignmentResult withDisplayDirection(Vec3? direction) => AlignmentResult(
    directionWorld: directionWorld,
    directionInCamera: directionInCamera,
    distanceM: distanceM,
    yawCorrectionDeg: yawCorrectionDeg,
    pitchCorrectionDeg: pitchCorrectionDeg,
    angularErrorDeg: angularErrorDeg,
    toleranceDeg: toleranceDeg,
    isPole: isPole,
    deadZoneDeg: deadZoneDeg,
    displayDirectionInCamera: direction,
    usable: usable,
    message: message,
  );

  factory AlignmentResult.unusable({
    required double distanceM,
    required String message,
  }) => AlignmentResult(
    directionWorld: Vec3.zero,
    directionInCamera: Vec3.zero,
    distanceM: distanceM,
    yawCorrectionDeg: 0,
    pitchCorrectionDeg: 0,
    angularErrorDeg: 180,
    toleranceDeg: 0,
    message: message,
    usable: false,
  );

  /// Whether the 3-D error is inside tolerance. The only readiness test the
  /// poles can use, and the one the spec requires everywhere.
  bool get withinTolerance => usable && angularErrorDeg <= toleranceDeg;

  /// Whether the target is in front of the camera at all.
  bool get inFront => directionInCamera.z > 0;

  /// "Turn right 20°" / "Turn left 8°" / "Tilt up 12°" / "Tilt down 5°" /
  /// "Target aligned — hold steady." — the wording Section 1 §10 asks for.
  ///
  /// Never shows an aligned state because a model loaded or a flag was set: it
  /// is derived from [angularErrorDeg] alone.
  String get instruction {
    if (!usable) return message ?? 'No target position';
    if (withinTolerance) return 'Target aligned — hold steady.';

    final yaw = yawCorrectionDeg;
    final pitch = pitchCorrectionDeg;
    final parts = <String>[];

    if (!isPole) {
      if (yaw.abs() > 90) {
        // Behind the camera: "turn around" is the useful instruction, not a
        // 170° turn to the left.
        parts.add(
          'Turn around ${yaw > 0 ? 'to the right' : 'to the left'} '
          '${(180 - yaw.abs()).abs().round()}°',
        );
      } else if (yaw > deadZoneDeg) {
        parts.add('Turn right ${yaw.abs().round()}°');
      } else if (yaw < -deadZoneDeg) {
        parts.add('Turn left ${yaw.abs().round()}°');
      }
    }

    if (pitch > deadZoneDeg) {
      parts.add('tilt up ${pitch.abs().round()}°');
    } else if (pitch < -deadZoneDeg) {
      parts.add('tilt down ${pitch.abs().round()}°');
    }

    if (parts.isEmpty) return 'Hold still';
    final sentence = parts.join(' and ');
    return '${sentence[0].toUpperCase()}${sentence.substring(1)}';
  }

  /// A single, display-only primary instruction for a settled [guidance] state.
  ///
  /// The raw [instruction] intentionally lists both yaw and pitch corrections.
  /// That is useful in diagnostics, but it lets a small change in which axis is
  /// numerically larger make the on-screen sentence jump between "turn" and
  /// "tilt" on consecutive ARCore frames. The controller has already chosen a
  /// hysteretic primary direction in [guidanceStateOf]; use that answer for the
  /// visible sentence while keeping all raw values available for the capture
  /// gate and the expanded diagnostic readout.
  String instructionForGuidance(GuidanceState guidance) {
    if (!usable) return message ?? 'No target position';
    final yawDegrees = math.max(1, yawCorrectionDeg.abs().round());
    final pitchDegrees = math.max(1, pitchCorrectionDeg.abs().round());
    return switch (guidance) {
      GuidanceState.aligned => 'Target aligned — hold steady.',
      GuidanceState.left => 'Turn left $yawDegrees°',
      GuidanceState.right => 'Turn right $yawDegrees°',
      GuidanceState.up => 'Tilt up $pitchDegrees°',
      GuidanceState.down => 'Tilt down $pitchDegrees°',
      // A target behind the optical axis needs the fuller, raw instruction so
      // the user is told to turn around rather than to make a tiny correction.
      GuidanceState.behind => instruction,
      GuidanceState.trackingPaused => 'Waiting for AR tracking.',
      GuidanceState.awaitingTarget => message ?? 'Waiting for a target position.',
    };
  }

  /// A compact readout for the diagnostics line.
  String get readout =>
      'yaw ${yawCorrectionDeg >= 0 ? '+' : ''}'
      '${yawCorrectionDeg.toStringAsFixed(1)}° · '
      'pitch ${pitchCorrectionDeg >= 0 ? '+' : ''}'
      '${pitchCorrectionDeg.toStringAsFixed(1)}° · '
      'error ${angularErrorDeg.toStringAsFixed(1)}°';
}

/// The named guidance states, so the sentence, the pointer and the log all
/// answer "which way?" with the same word.
///
/// The arrow itself stays geometric — it is drawn from the projected camera-frame
/// direction, which carries the diagonal cases the enum collapses to one axis.
/// The enum's job is the parts that must not disagree: which instruction line is
/// honest right now, and which transition is worth a log line.
enum GuidanceState {
  /// Inside the 3° tolerance. No arrow, and none should appear.
  aligned,

  /// The target is to the left, and left is the larger error.
  left,

  /// The target is to the right, and right is the larger error.
  right,

  /// The target is above the optical axis.
  up,

  /// The target is below the optical axis.
  down,

  /// The target is behind the camera: no screen position exists to point at.
  behind,

  /// ARCore has no valid pose, so no directional claim may be made at all.
  trackingPaused,

  /// The pose is valid but this target has no position yet — placement is
  /// pending. Listed so a directional claim is never inferred from its absence.
  awaitingTarget;

  /// Whether this state is a directional instruction the user can turn by.
  bool get isDirectional =>
      this == GuidanceState.left ||
      this == GuidanceState.right ||
      this == GuidanceState.up ||
      this == GuidanceState.down;
}

/// The one mapping from tracking + alignment to a [GuidanceState].
///
/// Pure and cheap, so the UI and the diagnostics read it rather than each
/// re-deriving it from the numbers — which is how a pointer, a sentence and a
/// log line come to name three different directions for one frame.
///
/// ## The hysteresis, and why it is a latch rather than a wider band
///
/// The visual `aligned` indicator used to flip on the gate's own 3.0° boundary,
/// so an error oscillating 2.90° / 3.10° / 3.12° produced `aligned` ↔ `left`
/// several times a second.
///
/// The obvious fix — enter at 3.0°, leave at 3.5° — is wrong here: it would
/// display `aligned` while [AlignmentResult.withinTolerance] was false, i.e. an
/// indicator claiming a shot the shutter then refuses. Widening the band
/// *inward* has the mirror problem: inside the band the indicator says "turn"
/// while the gate is already satisfied, and the automatic shutter fires under a
/// turn instruction.
///
/// So both thresholds default to the tolerance itself — the indicator and the
/// gate agree at every angle — and the flapping is removed in **time** instead:
/// [alignedHeldMs] is how long the error has been continuously inside
/// tolerance, and `aligned` is only entered once that reaches
/// [alignedLatchMs]. Leaving is immediate, so the indicator can never lag a
/// genuinely lost aim. The result is:
///
/// * `aligned` ⟹ `withinTolerance` at that instant, always;
/// * a tremor that keeps crossing 3.0° never latches, and the display stays on
///   the honest directional state instead of flickering;
/// * the 600 ms stability window is longer than the 200 ms latch, so the latch
///   never delays a legitimate capture.
///
/// Directional labels use an independent 2° axis/sign deadband. It only keeps
/// the *wording* from bouncing between near-equal yaw and pitch corrections;
/// it does not smooth [AlignmentResult] or widen either capture threshold.
GuidanceState guidanceStateOf({
  required bool trackingValid,
  required AlignmentResult? alignment,
  GuidanceState? previous,
  double alignedEntryThresholdDeg = 3.0,
  double alignedExitThresholdDeg = 3.0,
  double alignedLatchMs = 200,
  double alignedHeldMs = 0,
  double directionSwitchDeadbandDeg = 2.0,
}) {
  if (!trackingValid) return GuidanceState.trackingPaused;
  final a = alignment;
  if (a == null || !a.usable) return GuidanceState.awaitingTarget;

  // Neither threshold may reach outside the capture gate: `toleranceDeg` is the
  // gate's own number (3.0°), and this clamp is what keeps the indicator from
  // ever claiming an aim the shutter would refuse.
  final tolerance = a.toleranceDeg;
  final exit = math.min(alignedExitThresholdDeg, tolerance);
  final entry = math.min(alignedEntryThresholdDeg, exit);

  final errorDeg = a.angularErrorDeg;
  if (previous == GuidanceState.aligned && errorDeg <= exit) {
    return GuidanceState.aligned;
  }
  if (errorDeg <= entry && alignedHeldMs >= alignedLatchMs) {
    return GuidanceState.aligned;
  }
  // `directionInCamera.z` is the component along the optical axis: non-positive
  // means the target is behind, where `project` has no screen point to return.
  if (!a.inFront) return GuidanceState.behind;

  final yaw = a.yawCorrectionDeg;
  final pitch = a.pitchCorrectionDeg;
  // Direction labels are display-only. Retain the previous primary axis through
  // a narrow 2° band so a nearly diagonal target does not alternate between
  // "turn" and "tilt" as ARCore's pose estimate jitters. The raw alignment,
  // the 3° gate and the automatic shutter remain untouched.
  final switchDeadband = math.max(0.0, directionSwitchDeadbandDeg);
  final previousWasHorizontal =
      previous == GuidanceState.left || previous == GuidanceState.right;
  final previousWasVertical =
      previous == GuidanceState.up || previous == GuidanceState.down;
  if (!a.isPole &&
      previousWasHorizontal &&
      yaw.abs() + switchDeadband >= pitch.abs()) {
    return _horizontalGuidance(
      yaw: yaw,
      previous: previous,
      signDeadbandDeg: switchDeadband,
    );
  }
  if (previousWasVertical &&
      (a.isPole || pitch.abs() + switchDeadband >= yaw.abs())) {
    return _verticalGuidance(
      pitch: pitch,
      previous: previous,
      signDeadbandDeg: switchDeadband,
    );
  }
  // At a pole, yaw is undefined — the whole sphere's horizontal wording is noise
  // there, so only the vertical axis may be named. [AlignmentResult.instruction]
  // applies the same rule to its wording.
  final horizontal = !a.isPole && yaw.abs() >= pitch.abs();
  if (horizontal) {
    return _horizontalGuidance(
      yaw: yaw,
      previous: previous,
      signDeadbandDeg: switchDeadband,
    );
  }
  return _verticalGuidance(
    pitch: pitch,
    previous: previous,
    signDeadbandDeg: switchDeadband,
  );
}

GuidanceState _horizontalGuidance({
  required double yaw,
  required GuidanceState? previous,
  required double signDeadbandDeg,
}) {
  if ((previous == GuidanceState.left || previous == GuidanceState.right) &&
      yaw.abs() < signDeadbandDeg) {
    return previous!;
  }
  return yaw >= 0 ? GuidanceState.right : GuidanceState.left;
}

GuidanceState _verticalGuidance({
  required double pitch,
  required GuidanceState? previous,
  required double signDeadbandDeg,
}) {
  if ((previous == GuidanceState.up || previous == GuidanceState.down) &&
      pitch.abs() < signDeadbandDeg) {
    return previous!;
  }
  return pitch >= 0 ? GuidanceState.up : GuidanceState.down;
}

/// A short, **bounded** low-pass on the pointer's direction.
///
/// ## What it is allowed to touch
///
/// Only the arrow's geometry. [AlignmentResult.angularErrorDeg],
/// [AlignmentResult.yawCorrectionDeg], `withinTolerance` and every number the
/// capture gate reads are computed from the raw pose and are never filtered —
/// a smoothed value must not be able to arm a shutter. The filter's output
/// travels in [AlignmentResult.displayDirectionInCamera], a separate field, so
/// the two cannot be confused at a call site.
///
/// ## Why the bound matters
///
/// An exponential filter trades jitter for lag, and lag in a pointer is a lie
/// about which way to turn. The deviation from the raw direction is therefore
/// clamped: whenever the smoothed vector is more than [maxDeviationDeg] away
/// from the true one — a fast turn, a target change, a resumed stream — the
/// filter snaps to the raw direction instead of easing towards it. Jitter is
/// reduced during a steady aim (where it is visible) and never during a turn
/// (where lag would be misleading).
///
/// [reset] must be called when the active target changes, when tracking is
/// lost, and when the station is recalibrated: carrying an estimate across any
/// of those would blend two different targets' directions into one.
class DisplayDirectionFilter {
  DisplayDirectionFilter({
    this.alpha = 0.35,
    this.maxDeviationDeg = 4.0,
  });

  /// Weight of the newest sample, 0…1. Higher follows the raw pose more closely.
  final double alpha;

  /// The largest angle the smoothed direction may sit away from the raw one.
  final double maxDeviationDeg;

  Vec3? _state;

  /// Whether the filter currently holds an estimate.
  bool get hasState => _state != null;

  /// Filters [raw], or returns `null` when there is no usable direction.
  ///
  /// A non-finite or zero-length input clears the state and returns `null`:
  /// there is no honest direction to draw, and the caller draws nothing.
  Vec3? filter(Vec3? raw) {
    if (raw == null || !_vec3Finite(raw) || !_vec3Usable(raw)) {
      _state = null;
      return null;
    }
    final target = raw.normalized;
    final previous = _state;
    if (previous == null) {
      _state = target;
      return target;
    }
    final blended = previous * (1 - alpha) + target * alpha;
    var next = _vec3Usable(blended) ? blended.normalized : target;
    if (_angleDeg(next, target) > maxDeviationDeg) {
      // Too far from the truth to be worth smoothing: snap.
      next = target;
    }
    _state = next;
    return next;
  }

  /// Forgets the estimate, so the next sample seeds the filter afresh.
  void reset() => _state = null;

  static double _angleDeg(Vec3 a, Vec3 b) {
    final dot = clampDouble(a.dot(b), -1, 1);
    return math.acos(dot) * radToDeg;
  }
}
