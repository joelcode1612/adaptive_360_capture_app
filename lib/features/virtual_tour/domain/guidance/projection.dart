import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Guidance: target direction → camera frame → screen.
///
/// Ported from `dCam`, `project`, `aim` and `wording` in `/*ENGINE*/`.

/// Dead zone (degrees) that stops the wording flickering when a component is
/// almost zero.
const double deadZoneDeg = 2;

/// Camera-frame direction of a world direction [d]: `Rᵀ·d`.
///
/// See [Quat.toCameraFrame] for why the horizontal component carries a sign
/// flip relative to the reference engine.
Vec3 toCameraFrame(Quat q, Vec3 d) => q.toCameraFrame(d);

/// Result of projecting a camera-frame direction onto a `W × H` viewport.
class ScreenProjection {
  /// False when the target is behind the camera and no true projection exists.
  final bool onScreen;
  final double u;
  final double v;

  /// Focal lengths in pixels, derived from the real field of view.
  final double fx;
  final double fy;

  const ScreenProjection({
    required this.onScreen,
    required this.u,
    required this.v,
    required this.fx,
    required this.fy,
  });

  @override
  String toString() =>
      'ScreenProjection(onScreen: $onScreen, u: ${u.toStringAsFixed(3)}, '
      'v: ${v.toStringAsFixed(3)})';
}

/// Pinhole projection of a camera-frame direction onto a `w × h` viewport with
/// horizontal field [hfovDeg] and vertical field [vfovDeg].
///
/// `fx = (W/2)/tan(hfov/2)`, `fy = (H/2)/tan(vfov/2)`,
/// `u = W/2 + fx·dc.x/dc.z`, `v = H/2 − fy·dc.y/dc.z`.
///
/// A direction is not a world position, so [dc.z] is not a distance in metres.
/// The native renderer owns the real 5 cm near-plane clipping. This helper must
/// nevertheless reject the horizon before dividing: a direction just in front
/// of it otherwise becomes a multi-million-pixel "on-screen" result.
///
/// When a direction is behind the camera or outside the visible rectangle, no
/// perspective pixel is returned. Instead, `onScreen` is false and the result
/// is a finite, inset edge point for the guidance arrow to point towards.
const double _forwardEpsilon = 1e-4;
const double _edgeInset = 12;

bool _finite(double value) => value.isFinite;

ScreenProjection _safeHiddenProjection(double w, double h) {
  final safeW = _finite(w) && w > 0 ? w : 1.0;
  final safeH = _finite(h) && h > 0 ? h : 1.0;
  return ScreenProjection(
    onScreen: false,
    u: safeW / 2,
    v: safeH / 2,
    fx: 0,
    fy: 0,
  );
}

ScreenProjection _edgeProjection({
  required Vec3 direction,
  required double w,
  required double h,
  required double fx,
  required double fy,
  double? projectedU,
  double? projectedV,
}) {
  // Prefer the actual projected bearing for a point in front but outside the
  // frustum. At/behind the horizon, use the camera-frame bearing instead.
  var dx = projectedU == null ? direction.x : projectedU - w / 2;
  var dy = projectedV == null ? -direction.y : projectedV - h / 2;
  if (!dx.isFinite || !dy.isFinite || (dx.abs() < 1e-9 && dy.abs() < 1e-9)) {
    dx = direction.x;
    dy = -direction.y;
  }
  final magnitude = math.sqrt(dx * dx + dy * dy);
  if (!magnitude.isFinite || magnitude < 1e-9) {
    return _safeHiddenProjection(w, h);
  }

  final ux = dx / magnitude;
  final uy = dy / magnitude;
  final halfW = math.max(0.0, w / 2 - _edgeInset);
  final halfH = math.max(0.0, h / 2 - _edgeInset);
  final scaleX = ux.abs() < 1e-9 ? double.infinity : halfW / ux.abs();
  final scaleY = uy.abs() < 1e-9 ? double.infinity : halfH / uy.abs();
  final scale = math.min(scaleX, scaleY);
  // A normal phone viewport is much wider than this, but keeping the clamp
  // bounds ordered also makes a transient 1×1 layout harmless.
  final minX = math.min(_edgeInset, w / 2);
  final maxX = math.max(w - _edgeInset, w / 2);
  final minY = math.min(_edgeInset, h / 2);
  final maxY = math.max(h - _edgeInset, h / 2);

  return ScreenProjection(
    onScreen: false,
    u: clampDouble(w / 2 + ux * scale, minX, maxX),
    v: clampDouble(h / 2 + uy * scale, minY, maxY),
    fx: fx,
    fy: fy,
  );
}

ScreenProjection project(
  Vec3 dc,
  double w,
  double h,
  double hfovDeg,
  double vfovDeg,
) {
  // This is deliberately total: a malformed platform payload must result in
  // "not visible", never NaN/Infinity reaching Canvas geometry.
  if (!_finite(dc.x) ||
      !_finite(dc.y) ||
      !_finite(dc.z) ||
      !_finite(w) ||
      !_finite(h) ||
      w <= 0 ||
      h <= 0 ||
      !_finite(hfovDeg) ||
      !_finite(vfovDeg) ||
      hfovDeg <= 0 ||
      vfovDeg <= 0 ||
      hfovDeg >= 179 ||
      vfovDeg >= 179) {
    return _safeHiddenProjection(w, h);
  }

  final fx = (w / 2) / math.tan(hfovDeg * degToRad / 2);
  final fy = (h / 2) / math.tan(vfovDeg * degToRad / 2);
  if (!fx.isFinite || !fy.isFinite || fx <= 0 || fy <= 0) {
    return _safeHiddenProjection(w, h);
  }

  if (dc.z > _forwardEpsilon) {
    final u = w / 2 + fx * dc.x / dc.z;
    final v = h / 2 - fy * dc.y / dc.z;
    if (u.isFinite && v.isFinite && u >= 0 && u <= w && v >= 0 && v <= h) {
      return ScreenProjection(onScreen: true, u: u, v: v, fx: fx, fy: fy);
    }
    return _edgeProjection(
      direction: dc,
      w: w,
      h: h,
      fx: fx,
      fy: fy,
      projectedU: u,
      projectedV: v,
    );
  }

  return _edgeProjection(direction: dc, w: w, h: h, fx: fx, fy: fy);
}

/// Projects a display-oriented camera-frame direction with ARCore's exact
/// native camera projection matrix.
///
/// The app's direction convention is `(right, up, forward)`, while OpenGL's
/// view convention is `(right, up, -forward)`, hence the negated z component.
/// ARCore creates this matrix after [Session.setDisplayGeometry], so it includes
/// the real display rotation, crop, principal point and focal lengths used to
/// render the target mesh. A missing or malformed matrix falls back to the
/// intrinsics/FOV projection rather than disabling guidance.
ScreenProjection projectWithArCoreProjection(
  Vec3 dc,
  double w,
  double h,
  Float64List? matrix, {
  required double fallbackHfovDeg,
  required double fallbackVfovDeg,
}) {
  if (matrix == null || matrix.length != 16 ||
      !dc.x.isFinite || !dc.y.isFinite || !dc.z.isFinite ||
      !w.isFinite || !h.isFinite || w <= 0 || h <= 0 ||
      matrix.any((double value) => !value.isFinite)) {
    return project(dc, w, h, fallbackHfovDeg, fallbackVfovDeg);
  }

  final x = dc.x;
  final y = dc.y;
  final z = -dc.z;
  final clipX = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12];
  final clipY = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13];
  final clipW = matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15];
  final fx = matrix[0].abs() * w / 2;
  final fy = matrix[5].abs() * h / 2;
  if (!clipX.isFinite || !clipY.isFinite || !clipW.isFinite ||
      clipW <= _forwardEpsilon || !fx.isFinite || !fy.isFinite ||
      fx <= 0 || fy <= 0) {
    return _edgeProjection(direction: dc, w: w, h: h, fx: fx, fy: fy);
  }

  final u = w * (clipX / clipW + 1) / 2;
  final v = h * (1 - clipY / clipW) / 2;
  if (u.isFinite && v.isFinite && u >= 0 && u <= w && v >= 0 && v <= h) {
    return ScreenProjection(onScreen: true, u: u, v: v, fx: fx, fy: fy);
  }
  return _edgeProjection(
    direction: dc,
    w: w,
    h: h,
    fx: fx,
    fy: fy,
    projectedU: u,
    projectedV: v,
  );
}

/// Alignment error expressed as an axis-angle quantity.
class AimResult {
  /// Geodesic angle between the camera forward vector and the target, in
  /// degrees. Zero when perfectly aimed.
  final double angleDeg;

  /// Unit axis of the rotation that removes the error. Feed this to
  /// [Quat.axisAngle] to turn toward the target.
  final Vec3 axis;

  /// True when forward and target are parallel or opposite, so the axis is
  /// undefined and a deterministic perpendicular was substituted.
  final bool degenerate;

  const AimResult({
    required this.angleDeg,
    required this.axis,
    required this.degenerate,
  });
}

/// Alignment error between the camera's forward vector and target direction [d].
///
/// There is no yaw-difference interpolation anywhere in this project:
/// convergence is a great-circle rotation toward the target, so a pole target
/// is reached without a yaw special case and roll is never constrained.
AimResult aim(Quat q, Vec3 d) {
  final f = q.rotate(Vec3.unitZ);
  final ang = math.acos(clampDouble(f.dot(d), -1, 1)) * radToDeg;
  var ax = f.cross(d);
  final m = ax.length;
  var degenerate = false;
  if (m < 1e-9) {
    degenerate = true;
    ax = f.y.abs() < 0.9 ? f.cross(Vec3.unitY) : f.cross(Vec3.unitX);
  }
  return AimResult(angleDeg: ang, axis: ax.normalized, degenerate: degenerate);
}

/// Human-readable correction derived from the signs of `d_cam`.
///
/// Never mentions yaw, pitch or roll, and covers the four quadrants, the pure
/// horizontal and vertical cases, and the whole behind-the-camera half-space.
String wording(Vec3 dc, double errDeg, double tolDeg) {
  if (errDeg < tolDeg) return 'Target aligned. Hold still.';

  final b = math.atan2(dc.x, dc.z) * radToDeg;
  final e = math.atan2(dc.y, math.sqrt(dc.x * dc.x + dc.z * dc.z)) * radToDeg;

  final horizontal = b > deadZoneDeg
      ? 'right'
      : b < -deadZoneDeg
      ? 'left'
      : null;
  final vertical = e > deadZoneDeg
      ? 'up'
      : e < -deadZoneDeg
      ? 'down'
      : null;

  if (b.abs() > 90) {
    return 'Turn around'
        '${horizontal != null ? ' to the $horizontal' : ''}'
        '${vertical != null ? ' and look $vertical' : ''}';
  }
  if (horizontal != null && vertical != null) {
    return 'Turn $horizontal and look $vertical';
  }
  if (horizontal != null) return 'Turn $horizontal';
  if (vertical != null) return 'Look $vertical';
  return 'Target aligned. Hold still.';
}

/// Geodesic angle between two yaw/pitch pairs, in degrees.
///
/// Vector-based: it is the angle between the two unit directions, not a
/// difference of angles, so it is correct across the poles and across ±180°.
double geodesicAngleDeg(
  ({double yawDeg, double pitchDeg}) a,
  ({double yawDeg, double pitchDeg}) b,
) {
  final u = directionFromYawPitch(a.yawDeg, a.pitchDeg);
  final v = directionFromYawPitch(b.yawDeg, b.pitchDeg);
  return math.acos(clampDouble(u.dot(v), -1, 1)) * radToDeg;
}

/// Converts an ARCore / ARKit camera-pose quaternion into this project's world
/// convention.
///
/// ARCore reports `R_ar`, the rotation from the AR camera's local frame to the
/// AR world. That local frame is the standard camera frame: `+X` screen-right,
/// `+Y` screen-up, `+Z` *backward* — the optical axis is `−Z`.
///
/// This project's pose convention instead puts the **optical axis on `+ẑ`**,
/// because [Quat.fromYawPitch] and [directionFromYawPitch] are built that way
/// (`yaw 0° → +Z`) and the plan, the coverage test and the alignment angle all
/// depend on it. Matching the two therefore means:
///
/// * `q·ẑ` must be the optical axis: `R_ar·(0,0,−1)`
/// * `q·ŷ` must be the physical up: `R_ar·(0,1,0)`
/// * `q·x̂` is then forced, and comes out as the physical *left*
///   (`−R_ar·(0,1,0) × ...`); [Quat.toCameraFrame] compensates for that.
///
/// The columns of `q` are `R_ar` with the first and third negated, which is
/// exactly `R_ar · Ry(180°)`. **The multiply is on the right:** `Ry(180°)` acts
/// in the camera's local frame, so it must be applied *before* `R_ar`, not
/// after. Left-multiplying happens to give the same answer for a pure-yaw AR
/// pose (rotations about the same axis commute) and is therefore easy to get
/// away with by accident — the unit test uses a *pitched* pose so that the two
/// orders differ and only the correct one passes.
///
/// This is pure and unit-tested precisely because it is the one place where a
/// sign error would silently mirror the entire guidance UI.
Quat arCameraPoseToCaptureWorld(Quat arPose) =>
    (arPose * Quat.axisAngle(180, Vec3.unitY)).normalized;

/// The exact inverse of [arCameraPoseToCaptureWorld].
///
/// `Ry(180°)` is its own inverse, so the round trip is `q → q·Ry(180) →
/// q·Ry(180)·Ry(180) = q`. It exists so that a test (or the simulator) can state
/// a pose in the engine's own yaw/pitch terms and still push it through the real
/// AR conversion, rather than bypassing it and quietly testing nothing.
Quat captureWorldToArPose(Quat captureWorld) =>
    (captureWorld * Quat.axisAngle(-180, Vec3.unitY)).normalized;

/// Browser `DeviceOrientationEvent` → quaternion.
///
/// `alpha` about Z, `beta` about X, `gamma` about Y (intrinsic ZXY); screen
/// rotation is applied afterwards as a further rotation about Z. Retained
/// because the reference's browser/simulation path uses it and because it is a
/// useful test fixture. **This is not a calibrated AR pose:** no anchor, no
/// drift correction, and it degrades near the poles.
Quat fromDeviceOrientation(
  double alpha,
  double beta,
  double gamma,
  double screenDeg,
) =>
    (Quat.axisAngle(screenDeg, Vec3.unitZ) *
            (Quat.axisAngle(alpha, Vec3.unitZ) *
                Quat.axisAngle(beta, Vec3.unitX) *
                Quat.axisAngle(gamma, Vec3.unitY)))
        .normalized;
