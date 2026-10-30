import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

// How the phone is being held, checked BEFORE any direction guidance.
//
// The reference goes straight from the pose to "Turn right and look up". On a
// real phone that is the wrong first question: if the user is holding the phone
// sideways, or has tipped it flat, then a turn instruction is either
// unachievable or actively misleading, and the marker is off-screen for a reason
// that has nothing to do with where they are pointing. So the hold is assessed
// first, and when it is wrong the guidance says how to hold the phone instead of
// which way to turn.
//
// Vector-only, like the rest of the engine. The brief forbids converting to
// Euler angles to reason about the pose, and this file does not. The three
// inputs are all dot products of the world up axis with the pose's own basis
// vectors:
//
//     gx = Y · (R·x̂)     gy = Y · (R·ŷ)     gz = Y · (R·ẑ)
//
// `(gx, gy, gz)` is simply the world up direction expressed in the camera's
// frame — `Rᵀ·Y`, the same quantity `d_cam` computes for a target, with the world
// up as the target. Every conclusion below is a comparison between those three
// numbers and nothing else.
//
//   * `gy ≈ 1` — the screen's top points up: portrait, upright.
//   * `|gx| ≈ 1` — the screen's top points sideways: the phone is on its side.
//   * `gx ≈ gy ≈ 0` — the world up is along the optical axis, so the screen is
//     facing up or down and there is no "screen up" to speak of: flat.
//
// Roll is measured against the world, not against a nominal pose.
// [HoldAssessment.rollDeg] is `atan2(gx, gy)`: the angle by which the world's up
// direction appears rotated within the screen plane. It is zero when the horizon
// would be level on screen, regardless of which way the phone is pointing, which
// is what makes it usable at the zenith and nadir where a yaw/pitch-based roll
// would be undefined.

/// What is wrong with the hold, if anything.
///
/// Every case here is something the user can act on immediately. There is
/// deliberately no "screen facing the ceiling" verdict: a phone lying flat on a
/// table and a phone tilted right back to photograph the ceiling are the same
/// geometry, and they cannot be told apart without knowing whether a hand is
/// holding it. Both are covered by [aimedTooSteeply], whose advice — lower or
/// raise the phone towards the horizon — is correct for either.
enum HoldIssue {
  /// Nothing to correct.
  none,

  /// Rolled noticeably off level, but not on its side. Common and harmless enough
  /// to correct in passing.
  tiltedSideways,

  /// On its side — landscape in a portrait-designed flow.
  heldSideways,

  /// Upside down.
  upsideDown,

  /// The optical axis is steeply up or down while the current target is not a
  /// pole, so the target is far outside the viewfinder. Covers "tilted up",
  /// "tilted down" and "lying flat".
  aimedTooSteeply,
}

/// The assessment, with the numbers it was derived from.
class HoldAssessment {
  final HoldIssue issue;

  /// The world up in the camera frame: `(gx, gy, gz)`. Kept because it is the
  /// whole evidence for the verdict, and it is what a bug report needs.
  final Vec3 upInCamera;

  /// Angle of the world up within the screen plane, degrees, in
  /// `(−180, 180]`. Zero means the horizon is level on screen; `±90` means the
  /// phone is on its side; `±180` means upside down.
  final double rollDeg;

  /// Angle between the optical axis and the horizontal plane, degrees: `0` when
  /// aimed at the horizon, `±90` when aimed straight up or down.
  final double axisElevationDeg;

  /// True when the screen is close to horizontal, so roll has no meaning.
  final bool flat;

  /// A short instruction for the user, or `null` when the hold is fine.
  ///
  /// Deliberately phrased as a hold correction, never as a turn. The brief asks
  /// for no popup for routine corrections, so the caller shows this in the
  /// existing guidance banner rather than as a dialog.
  final String? advice;

  const HoldAssessment({
    required this.issue,
    required this.upInCamera,
    required this.rollDeg,
    required this.axisElevationDeg,
    required this.flat,
    required this.advice,
  });

  /// True when guidance should be suppressed in favour of the hold advice.
  bool get blocksGuidance => issue != HoldIssue.none;

  @override
  String toString() =>
      'HoldAssessment(${issue.name}, roll ${rollDeg.toStringAsFixed(1)}°, '
      'axis ${axisElevationDeg.toStringAsFixed(1)}°, flat $flat)';
}

/// Thresholds for [assessHold], all configurable and all provisional.
///
/// Marked provisional for the same reason as the quality thresholds: they are
/// chosen to be sensible, not measured. They need a device to calibrate, and
/// `DEVICE_TEST_CHECKLIST.md` lists that as an open item.
class HoldThresholds {
  /// Below this, the hold is treated as upright.
  final double levelToleranceDeg;

  /// At or above this, the phone counts as on its side.
  final double sidewaysDeg;

  /// At or above this, the phone counts as upside down.
  final double upsideDownDeg;

  /// Above this, roll is ignored because the screen is too flat for it to mean
  /// anything.
  final double flatAxisDeg;

  /// Below this, the world up's projection onto the screen plane is too short to
  /// read a roll angle from, so the roll verdicts are skipped.
  ///
  /// `0.05` is about 3° of axis elevation from vertical. Kept tiny on purpose:
  /// the failure mode being avoided is dividing a degenerate `atan2`, not
  /// smoothing a noisy angle, and a larger threshold would start suppressing real
  /// leans on a phone that happens to be pointed steeply.
  final double rollDegenerateThreshold;

  /// How far the optical axis may leave the horizon before it counts as aimed
  /// too steeply, when the target is not a pole.
  final double steepAxisDeg;

  const HoldThresholds({
    this.levelToleranceDeg = 18,
    this.sidewaysDeg = 65,
    this.upsideDownDeg = 115,
    this.flatAxisDeg = 60,
    this.rollDegenerateThreshold = 0.05,
    this.steepAxisDeg = 55,
  });

  /// Provisional defaults. Not calibrated on hardware.
  static const HoldThresholds provisional = HoldThresholds();

  HoldThresholds copyWith({
    double? levelToleranceDeg,
    double? sidewaysDeg,
    double? upsideDownDeg,
    double? flatAxisDeg,
    double? rollDegenerateThreshold,
    double? steepAxisDeg,
  }) => HoldThresholds(
    levelToleranceDeg: levelToleranceDeg ?? this.levelToleranceDeg,
    sidewaysDeg: sidewaysDeg ?? this.sidewaysDeg,
    upsideDownDeg: upsideDownDeg ?? this.upsideDownDeg,
    flatAxisDeg: flatAxisDeg ?? this.flatAxisDeg,
    rollDegenerateThreshold:
        rollDegenerateThreshold ?? this.rollDegenerateThreshold,
    steepAxisDeg: steepAxisDeg ?? this.steepAxisDeg,
  );
}

/// Assesses how the phone is held.
///
/// [targetIsPole] suppresses the "aimed too steeply" verdict, because pointing
/// the camera at the ceiling or the floor is exactly right when the current
/// target *is* the zenith or the nadir. Without that, the zenith target would
/// tell the user to stop aiming at the zenith.
HoldAssessment assessHold(
  Quat pose, {
  HoldThresholds thresholds = HoldThresholds.provisional,
  bool targetIsPole = false,
}) {
  // The world up in the camera frame: Rᵀ·Y.
  final r = pose.rotate(Vec3.unitX);
  final u = pose.rotate(Vec3.unitY);
  final f = pose.rotate(Vec3.unitZ);
  final upInCamera = Vec3(
    Vec3.unitY.dot(r),
    Vec3.unitY.dot(u),
    Vec3.unitY.dot(f),
  );
  final gx = upInCamera.x;
  final gy = upInCamera.y;
  final gz = upInCamera.z;

  final horizontal = math.sqrt(gx * gx + gy * gy);
  final rollDeg = math.atan2(gx, gy) * radToDeg;

  // Elevation of the optical axis: |gz| is the sine of the angle between the
  // optical axis and the vertical, so the elevation from the horizon is the
  // complement.
  final axisElevationDeg = math.asin(clampDouble(gz, -1, 1)) * radToDeg;

  final flat = horizontal < math.cos(thresholds.flatAxisDeg * degToRad);

  if (targetIsPole) {
    // The target is the zenith or the nadir, so the camera is *meant* to be
    // pointing at the ceiling or the floor. That makes the phone flat by
    // definition, which means roll is undefined and elevation is intentional:
    // there is nothing to correct and nothing worth saying. Returning early here
    // is what stops the zenith target from telling the user to stop aiming at the
    // zenith.
    return HoldAssessment(
      issue: HoldIssue.none,
      upInCamera: upInCamera,
      rollDeg: rollDeg,
      axisElevationDeg: axisElevationDeg,
      flat: flat,
      advice: null,
    );
  }

  // Roll is only readable while there is a meaningful "screen up" to measure it
  // against. `horizontal` is the length of the world up's projection onto the
  // screen plane; when the optical axis is within a couple of degrees of
  // vertical that projection collapses and `atan2(gx, gy)` becomes noise, so the
  // roll verdicts are skipped rather than computed from a degenerate ratio. The
  // elevation check below then fires, which is the right advice for a phone that
  // is pointing straight up or down.
  final rollReadable = horizontal > thresholds.rollDegenerateThreshold;
  final absRoll = rollDeg.abs();

  HoldIssue issue = HoldIssue.none;
  String? advice;

  if (rollReadable && absRoll >= thresholds.upsideDownDeg) {
    issue = HoldIssue.upsideDown;
    advice = 'Turn the phone the right way up.';
  } else if (rollReadable && absRoll >= thresholds.sidewaysDeg) {
    issue = HoldIssue.heldSideways;
    advice = 'Hold the phone upright, not on its side.';
  } else if (rollReadable && absRoll >= thresholds.levelToleranceDeg) {
    issue = HoldIssue.tiltedSideways;
    advice = rollDeg > 0
        ? 'Straighten the phone: it is leaning to your left.'
        : 'Straighten the phone: it is leaning to your right.';
  } else if (axisElevationDeg.abs() >= thresholds.steepAxisDeg) {
    issue = HoldIssue.aimedTooSteeply;
    advice = axisElevationDeg > 0
        ? 'Lower the phone towards the horizon.'
        : 'Raise the phone towards the horizon.';
  }

  return HoldAssessment(
    issue: issue,
    upInCamera: upInCamera,
    rollDeg: rollDeg,
    axisElevationDeg: axisElevationDeg,
    flat: flat,
    advice: advice,
  );
}
