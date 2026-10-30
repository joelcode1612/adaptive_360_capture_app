import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// A rigid transform: where something is, and which way it faces.
///
/// [orientation] is always a **proper rotation** in this project's convention
/// (see [StationFrame] for the full statement): `q·ẑ` is the forward/optical
/// axis, `q·ŷ` is up, and — because `(right, up, forward)` is left-handed for a
/// physical camera — `−q·x̂` is the physical screen-right.
class RigidPose {
  /// Position in AR world metres.
  final Vec3 position;

  /// Orientation in this project's convention.
  final Quat orientation;

  const RigidPose({required this.position, required this.orientation});

  static final RigidPose identity = RigidPose(
    position: Vec3.zero,
    orientation: Quat.identity,
  );

  /// The optical axis.
  Vec3 get forward => orientation.rotate(Vec3.unitZ);

  /// Physical screen-right. **Not** `q·x̂` — see the class comment.
  Vec3 get right => -orientation.rotate(Vec3.unitX);

  Vec3 get up => orientation.rotate(Vec3.unitY);

  /// The unit quaternion as `(x, y, z, w)`.
  List<double> toList() => <double>[
    ...orientation.toList(),
    ...position.toList(),
  ];
}

/// The coordinate adapter between ARCore, the station and the phone.
///
/// **This is the one place the three frames are reconciled.** Everything below
/// it — the target directions, the raycasts, the alignment maths, the guidance
/// wording — reads a world vector and never re-derives a frame.
///
/// ## The three frames
///
/// 1. **ARCore world.** Right-handed, `+Y` roughly up, metres, origin chosen by
///    ARCore when the session starts. A camera pose from ARCore maps the
///    camera's local frame (`+X` screen-right, `+Y` screen-up, `−Z` optical
///    axis) into it. **`+Y` is the gravity-aligned axis** — ARCore fuses the
///    accelerometer into its world estimate, so world `+Y` is "downwards"
///    regardless of how the phone is held. That is the axis the capture
///    reference is levelled against.
///
/// 2. **This project's orientation convention** (`Quat`, see
///    `domain/math/quaternions.dart`). `q·ẑ` is the optical axis, `q·ŷ` up. The
///    conversion from an ARCore quaternion is `arCameraPoseToCaptureWorld`, and
///    it is the only such conversion in the app.
///
/// 3. **Station-local**, the frame Section 1 §6 asks for: **`+X` right, `+Y`
///    up, `+Z` forward, positive yaw turns right, positive pitch looks up.** It
///    is anchored at the station's recorded position and oriented by the
///    direction the user was facing when they calibrated.
///
/// ## Why frame 3 is not simply "the pose quaternion"
///
/// A rotation's image `(q·x̂, q·ŷ, q·ẑ)` is right-handed, so `right × up ==
/// forward`. A physical camera is the opposite: `right × up == −forward`. No
/// rotation can satisfy both, which is why OpenGL, ARCore and ARKit all put the
/// optical axis on `−Z`. If station-local `+X` were `q·x̂`, then "yaw +90°" would
/// point to the user's **left** while the number said right — exactly the sign
/// bug that is invisible until someone follows an instruction and turns the
/// wrong way.
///
/// The station-local frame therefore takes its `+X` from the *physical* right,
/// `−q·x̂`. That makes the frame improper (a mirror), which is fine: it is a
/// basis for expressing directions, not a rotation to be composed. The mirror
/// lives in exactly two functions, [localToWorld] and [worldToLocal], and both
/// are the inverse of the other.
class StationFrame {
  /// Station origin, AR world metres.
  final Vec3 origin;

  /// The calibrated orientation, this project's quaternion convention.
  final Quat orientation;

  const StationFrame({required this.origin, required this.orientation});

  /// Builds the frame from an ARCore camera pose.
  ///
  /// [arOrientation] is the **raw** ARCore quaternion; the conversion happens
  /// here and nowhere else.
  factory StationFrame.fromArPose({
    required Vec3 position,
    required Quat arOrientation,
  }) => StationFrame(
    origin: position,
    orientation: arCameraPoseToCaptureWorld(arOrientation),
  );

  /// The station's pose in the world, for anything that wants a [RigidPose].
  RigidPose get worldPose =>
      RigidPose(position: origin, orientation: orientation);

  /// Station-local `+X`, i.e. the direction the user would call "right".
  Vec3 get rightAxis => -orientation.rotate(Vec3.unitX);

  /// Station-local `+Y`.
  Vec3 get upAxis => orientation.rotate(Vec3.unitY);

  /// Station-local `+Z`, the direction the user faced at calibration.
  Vec3 get forwardAxis => orientation.rotate(Vec3.unitZ);

  /// Station-local direction → world direction.
  ///
  /// `M = [right | up | forward]`, so `world = M · local`. Written as a rotation
  /// plus the mirror, which is the same thing and keeps `Quat` as the single
  /// rotation type in the app.
  Vec3 localToWorld(Vec3 local) =>
      orientation.rotate(Vec3(-local.x, local.y, local.z));

  /// World direction → station-local direction. The exact inverse of
  /// [localToWorld].
  Vec3 worldToLocal(Vec3 world) {
    final u = orientation.conjugate.rotate(world);
    return Vec3(-u.x, u.y, u.z);
  }

  /// Station-local point → world point.
  Vec3 localPointToWorld(Vec3 local) => origin + localToWorld(local);

  /// World point → station-local point.
  Vec3 worldPointToLocal(Vec3 world) => worldToLocal(world - origin);

  /// The world point `rayDistanceM` along a station-local direction.
  Vec3 pointAlongLocal(Vec3 localDirection, double rayDistanceM) =>
      origin + localToWorld(localDirection.normalized) * rayDistanceM;

  /// The camera's pose expressed in the station's frame.
  ///
  /// `T_station_camera = inverse(T_world_station) × T_world_camera`, with the
  /// rotation as `R_stationᵀ · R_camera` and the translation as the camera
  /// position in station-local coordinates.
  RigidPose cameraInStation(RigidPose cameraWorld) => RigidPose(
    position: worldPointToLocal(cameraWorld.position),
    orientation: orientation.conjugate * cameraWorld.orientation,
  );

  /// Where the phone is relative to the station, in the words the UI uses.
  ///
  /// Yaw and pitch are the intrinsic azimuth/elevation of the camera's optical
  /// axis *as seen from the station*, so a positive yaw is a heading to the
  /// user's right. Degenerate at the poles by construction — use the 3-D
  /// angular error there instead.
  ({double yawDeg, double pitchDeg}) headingOf(RigidPose cameraWorld) {
    final local = worldToLocal(cameraWorld.forward);
    return (
      yawDeg: math.atan2(local.x, local.z) * radToDeg,
      pitchDeg: math.asin(clampDouble(local.y, -1, 1)) * radToDeg,
    );
  }

  /// The yaw/pitch pair of an arbitrary station-local direction.
  static ({double yawDeg, double pitchDeg}) anglesOf(Vec3 localDirection) => (
    yawDeg: math.atan2(localDirection.x, localDirection.z) * radToDeg,
    pitchDeg: math.asin(clampDouble(localDirection.y, -1, 1)) * radToDeg,
  );

  /// How far the phone has moved from the station, in metres.
  double driftOf(RigidPose cameraWorld) =>
      (cameraWorld.position - origin).length;
}

// ── the gravity-aligned capture reference ────────────────────────────────

/// How close to straight up or down the camera may point and still calibrate,
/// in degrees.
///
/// The station's front direction is the camera's optical axis **projected onto
/// the horizontal plane**. Within this angle of vertical that projection is
/// shorter than `sin(maxVerticalityDeg)` of its original length, and its
/// direction is noise: the yaw of the whole 30-target arrangement would be
/// decided by a fraction of a degree of hand shake. Calibration is refused
/// instead, which is the "require a suitable calibration orientation" branch
/// of the requirement — the alternative would be an invented fallback heading
/// the user never asked for.
const double kMaxCalibrationVerticalityDeg = 10;

/// How far [forward] points above the plane perpendicular to [up], in degrees:
/// `+90` when it is exactly [up], `−90` when it is exactly opposite, `0` when
/// it lies in the plane.
double elevationAboveHorizontalDeg(Vec3 forward, Vec3 up) {
  final u = up.normalized;
  if (u.length == 0) return 0;
  final f = forward.normalized;
  if (f.length == 0) return 0;
  return math.asin(clampDouble(f.dot(u), -1, 1)) * radToDeg;
}

/// [forward] with its component along [up] removed: the shadow it casts on the
/// horizontal plane. Length zero when [forward] is parallel to [up].
Vec3 projectOntoHorizontal(Vec3 forward, Vec3 up) {
  final u = up.normalized;
  if (u.length == 0) return forward;
  return forward - u * forward.dot(u);
}

/// Builds the capture reference orientation from the camera pose at the moment
/// "Calibrate station" was pressed.
///
/// **Why not the raw camera orientation.** The raw pose carries the phone's
/// pitch and roll at calibration time. Freezing that as the reference tilts
/// the entire target sphere by whatever angle the user happened to hold the
/// phone at: calibrate while looking 20° up and the middle ring sits at +20°,
/// the upper ring at +65°, and "level" stops meaning level. The rings are
/// defined against **gravity**, not against the phone.
///
/// So the reference is rebuilt from two vectors only:
///
/// * `up` — the world's gravity axis (`+Y`; ARCore fuses the accelerometer, so
///   this is gravity-aligned and phone-roll-free by construction);
/// * `forward` — the camera's optical axis projected onto the horizontal
///   plane, which keeps the user's **yaw** (where they were facing) and drops
///   their pitch and roll.
///
/// The third axis completes the rotation basis, `R·x̂ = up × forward`, which
/// makes `−R·x̂` the physical screen-right — the same convention
/// [StationFrame.rightAxis] and the rest of this project use. The result is a
/// proper unit quaternion (proper rotation, determinant +1) whose `ẑ` image is
/// the projected forward and whose `ŷ` image is gravity up.
///
/// Returns `ok: false` with a stated reason when the forward projection is too
/// short to define a heading (the camera points within
/// [kMaxCalibrationVerticalityDeg] of straight up or down). Nothing is
/// invented in that case: no fallback yaw, no identity — calibration simply
/// does not happen, and the caller says why.
({bool ok, String? reason, Quat? orientation}) captureReferenceFromPose({
  required Vec3 cameraForward,
  Vec3 gravityUp = const Vec3(0, 1, 0),
  double maxVerticalityDeg = kMaxCalibrationVerticalityDeg,
}) {
  final up = gravityUp.normalized;
  if (up.length == 0) {
    return (
      ok: false,
      reason:
          'The gravity direction is unavailable, so the capture reference '
          'cannot be levelled. Move the phone and try again.',
      orientation: null,
    );
  }
  final f0 = cameraForward.normalized;
  if (f0.length == 0) {
    return (
      ok: false,
      reason:
          'The camera has no usable forward direction yet. Wait for AR '
          'tracking.',
      orientation: null,
    );
  }
  if (elevationAboveHorizontalDeg(f0, up).abs() > 90 - maxVerticalityDeg) {
    return (
      ok: false,
      reason:
          'Hold the phone closer to horizontal before calibrating — the '
          'front direction cannot be measured while the camera points within '
          '${maxVerticalityDeg.toStringAsFixed(0)}° of straight up or down.',
      orientation: null,
    );
  }
  final forward = projectOntoHorizontal(f0, up).normalized;
  if (forward.length < 1e-9) {
    return (
      ok: false,
      reason:
          'The camera points too close to vertical to fix a front '
          'direction. Hold the phone closer to horizontal and calibrate '
          'again.',
      orientation: null,
    );
  }
  // Rotation basis: columns are R·x̂, R·ŷ, R·ẑ. `up × forward` completes the
  // right-handed triple, so −R·x̂ is the physical screen-right.
  final right = up.cross(forward);
  final orientation = Quat.fromMatrix3(<double>[
    right.x,
    up.x,
    forward.x,
    right.y,
    up.y,
    forward.y,
    right.z,
    up.z,
    forward.z,
  ]);
  return (ok: true, reason: null, orientation: orientation);
}
