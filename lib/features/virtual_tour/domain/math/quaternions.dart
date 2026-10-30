import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Immutable unit-quaternion rotation, stored `(x, y, z, w)` with the Hamilton
/// product — the same convention as `/*ENGINE*/` in the reference.
///
/// **World convention, identical in every file of this project:**
/// right-handed, `+Y` up. `yaw 0°` → `+Z`, `yaw +90°` → `+X`,
/// `pitch +90°` → `+Y` (zenith), `pitch −90°` → `−Y` (nadir).
///
/// A pose maps the canonical axes to the world: `R·x̂` is the camera's
/// **right**, `R·ŷ` its **up**, `R·ẑ` its **optical axis** (its *forward*).
/// Those three images are orthonormal, so `Rᵀ·d = (d·right, d·up, d·forward)`
/// with no matrix inverse.
///
/// **Handedness — read this before touching [toCameraFrame].** `R` is a
/// *rotation* (determinant `+1`), so the triple
/// `(R·x̂, R·ŷ, R·ẑ) = (right, up, forward)` is necessarily right-handed:
/// `right × up == forward`. A physical camera is the opposite —
/// `right × up == −forward`, which is why OpenGL, ARCore and ARKit all put the
/// optical axis on `−Z` and call `+Z` *backward*. The two cannot be reconciled
/// by choosing a rotation: no pose can make `R·x̂` the physical screen-right
/// while `R·ẑ` is the physical optical axis. Something must be flipped, and
/// this project flips it in [toCameraFrame] — see the note there.
///
/// Euler angles are produced **only** to display a pose and consumed **only**
/// when a pose is built from numeric input. Nothing downstream of the pose
/// reads a yaw or a pitch, so the zenith and nadir need no special case, roll
/// is free, and there is no ±180° wrap to handle.
class Quat {
  final double x;
  final double y;
  final double z;
  final double w;

  const Quat(this.x, this.y, this.z, this.w);

  static const Quat identity = Quat(0, 0, 0, 1);

  /// Hamilton product. `this * o` applies `o` first, then `this`.
  Quat operator *(Quat o) => Quat(
    w * o.x + x * o.w + y * o.z - z * o.y,
    w * o.y - x * o.z + y * o.w + z * o.x,
    w * o.z + x * o.y - y * o.x + z * o.w,
    w * o.w - x * o.x - y * o.y - z * o.z,
  );

  /// Scalar multiply. Named rather than an `operator *` overload, because Dart
  /// does not allow two `*` overloads on one type.
  Quat scaled(double s) => Quat(x * s, y * s, z * s, w * s);

  Quat operator +(Quat o) => Quat(x + o.x, y + o.y, z + o.z, w + o.w);

  /// Inverse rotation for a unit quaternion.
  Quat get conjugate => Quat(-x, -y, -z, w);

  double dot(Quat o) => x * o.x + y * o.y + z * o.z + w * o.w;

  double get length => math.sqrt(x * x + y * y + z * z + w * w);

  /// Normalises; a zero quaternion becomes the identity rather than NaN,
  /// matching the reference's `|| 1` guard.
  Quat get normalized {
    final l = length;
    return l == 0 ? identity : Quat(x / l, y / l, z / l, w / l);
  }

  /// Rotation of [angleDeg] about [axis] (need not be normalised).
  static Quat axisAngle(double angleDeg, Vec3 axis) {
    final h = angleDeg * degToRad / 2;
    final s = math.sin(h);
    final l = axis.length;
    final k = l == 0 ? 1.0 : l;
    return Quat(axis.x / k * s, axis.y / k * s, axis.z / k * s, math.cos(h));
  }

  /// Rotates a world vector: `v + 2w(u×v) + 2u×(u×v)`.
  Vec3 rotate(Vec3 v) {
    final u = Vec3(x, y, z);
    final c = u.cross(v);
    final cc = u.cross(c);
    return Vec3(
      v.x + 2 * (w * c.x + cc.x),
      v.y + 2 * (w * c.y + cc.y),
      v.z + 2 * (w * c.z + cc.z),
    );
  }

  /// Pose from a yaw/pitch pair.
  ///
  /// `f = Ry(yaw)·Rx(−pitch)·ẑ` reproduces the reference's `basis()`
  /// convention exactly (asserted by the automated tests).
  factory Quat.fromYawPitch(double yawDeg, double pitchDeg) =>
      (Quat.axisAngle(yawDeg, Vec3.unitY) *
              Quat.axisAngle(-pitchDeg, Vec3.unitX))
          .normalized;

  /// Euler angles for **display only**. Never feed this back into control
  /// logic: it is degenerate at the poles.
  ({double yawDeg, double pitchDeg}) get yawPitch {
    final f = rotate(Vec3.unitZ);
    return (
      yawDeg: math.atan2(f.x, f.z) * radToDeg,
      pitchDeg: math.asin(clampDouble(f.y, -1, 1)) * radToDeg,
    );
  }

  /// Camera basis from the quaternion: `[right, up, forward]`.
  ({Vec3 right, Vec3 up, Vec3 forward}) get basis => (
    right: rotate(Vec3.unitX),
    up: rotate(Vec3.unitY),
    forward: rotate(Vec3.unitZ),
  );

  /// Row-major 3×3 rotation matrix. Round-trips through [fromMatrix3] to 1e-9.
  List<double> toMatrix3() => <double>[
    1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), //
    2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), //
    2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), //
  ];

  /// Inverse of [toMatrix3] (Shepperd's method, as in the reference).
  factory Quat.fromMatrix3(List<double> m) {
    final t = m[0] + m[4] + m[8];
    List<double> q;
    if (t > 0) {
      final s = math.sqrt(t + 1) * 2;
      q = <double>[
        (m[7] - m[5]) / s,
        (m[2] - m[6]) / s,
        (m[3] - m[1]) / s,
        0.25 * s,
      ];
    } else if (m[0] > m[4] && m[0] > m[8]) {
      final s = math.sqrt(1 + m[0] - m[4] - m[8]) * 2;
      q = <double>[
        0.25 * s,
        (m[1] + m[3]) / s,
        (m[2] + m[6]) / s,
        (m[7] - m[5]) / s,
      ];
    } else if (m[4] > m[8]) {
      final s = math.sqrt(1 + m[4] - m[0] - m[8]) * 2;
      q = <double>[
        (m[1] + m[3]) / s,
        0.25 * s,
        (m[5] + m[7]) / s,
        (m[2] - m[6]) / s,
      ];
    } else {
      final s = math.sqrt(1 + m[8] - m[0] - m[4]) * 2;
      q = <double>[
        (m[2] + m[6]) / s,
        (m[5] + m[7]) / s,
        0.25 * s,
        (m[3] - m[1]) / s,
      ];
    }
    return Quat(q[0], q[1], q[2], q[3]).normalized;
  }

  /// Shortest-arc interpolation. Flips to the nearer hemisphere first, so the
  /// path never takes the long way round.
  static Quat slerp(Quat a, Quat b, double t) {
    var d = a.dot(b);
    var bb = b;
    if (d < 0) {
      bb = Quat(-b.x, -b.y, -b.z, -b.w);
      d = -d;
    }
    if (d > 0.9995) {
      return Quat(
        a.x + (bb.x - a.x) * t,
        a.y + (bb.y - a.y) * t,
        a.z + (bb.z - a.z) * t,
        a.w + (bb.w - a.w) * t,
      ).normalized;
    }
    final th = math.acos(clampDouble(d, -1, 1));
    final s = math.sin(th) == 0 ? 1e-9 : math.sin(th);
    final c1 = math.sin((1 - t) * th) / s;
    final c2 = math.sin(t * th) / s;
    return Quat(
      a.x * c1 + bb.x * c2,
      a.y * c1 + bb.y * c2,
      a.z * c1 + bb.z * c2,
      a.w * c1 + bb.w * c2,
    ).normalized;
  }

  List<double> toList() => <double>[x, y, z, w];

  /// The largest absolute component difference against [o].
  ///
  /// Used by the AR-conversion round-trip checks. Comparing two quaternions by
  /// their yaw and pitch alone would hide a sign flip on a component that the
  /// yaw/pitch projection collapses, which is exactly the kind of error the
  /// conversion between the AR frame and this project's frame can have.
  double maxComponentDiff(Quat o) => math.max(
    math.max((x - o.x).abs(), (y - o.y).abs()),
    math.max((z - o.z).abs(), (w - o.w).abs()),
  );

  factory Quat.fromList(List<double> v) => Quat(v[0], v[1], v[2], v[3]);

  /// Direction of a world vector [d] in the camera's view space, as the triple
  /// `(right, up, forward)`.
  ///
  /// `forward` is positive in front of the camera, `right` positive to the
  /// **physical** screen-right and `up` positive towards the physical top of
  /// the screen, so this feeds straight into the pinhole model:
  /// `u = W/2 + fx·x/z`, `v = H/2 − fy·y/z`.
  ///
  /// **Why `right` is `−R·x̂`.** No rotation can make `R·x̂` the physical
  /// screen-right while `R·ẑ` is the optical axis: a physical camera's
  /// `(right, up, forward)` is left-handed while a rotation's image is
  /// right-handed. The reference engine used `+R·x̂`, which silently
  /// mirrors the horizontal axis — the marker is drawn on the wrong side of the
  /// screen and "turn right" means turn left. That is invisible in the
  /// reference's own tests, because they only ever check that the projection and
  /// the wording agree with *each other*, never with a physical camera.
  ///
  /// Negating the `x` component (equivalently, calling `−R·x̂` the camera's
  /// right) is the smallest correction that makes the whole triple physically
  /// correct. It leaves `forward` and `up` — and therefore the plan, the
  /// coverage test, the alignment angle, the quality rules and the state
  /// machine — exactly as ported. Section 1 of
  /// `docs/JS_PARITY_DISCREPANCIES.md` records the divergence.
  Vec3 toCameraFrame(Vec3 d) {
    final b = basis;
    return Vec3(-d.dot(b.right), d.dot(b.up), d.dot(b.forward));
  }

  @override
  String toString() =>
      'Quat(${x.toStringAsFixed(6)}, ${y.toStringAsFixed(6)}, '
      '${z.toStringAsFixed(6)}, ${w.toStringAsFixed(6)})';
}
