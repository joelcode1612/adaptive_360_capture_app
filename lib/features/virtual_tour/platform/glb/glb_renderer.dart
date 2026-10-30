/// A pure-Dart software rasteriser for [GlbModel] geometry.
///
/// No `dart:ui`, no Flutter, no `vector_math`: the whole projection runs in a
/// bare Dart VM, which is what lets `test/glb_checks.dart` pin the numbers
/// without a device. [GlbTargetOverlayPainter] is the only thing that turns this
/// into pixels.
///
/// **Coordinate contract — the same one the rest of the project uses.**
/// Right-handed world with `+Y` up; a pose `R` maps `R·x̂`/`R·ŷ`/`R·ẑ` to the
/// camera's canonical right / up / **optical axis**, with the optical axis on
/// `+Z`. See `domain/math/quaternions.dart` for why the horizontal component is
/// negated on the way into the camera frame — it is the fix for the mirroring
/// bug the reference engine carried, and this file inherits it by calling
/// [Quat.toCameraFrame] rather than by re-deriving a basis.
///
/// The projection is the project's pinhole model, verbatim:
/// `fx = (W/2)/tan(hfov/2)`, `fy = (H/2)/tan(vfov/2)`,
/// `u = W/2 + fx·x/z`, `v = H/2 − fy·y/z`, with `(x, y, z)` the camera-frame
/// triple `(right, up, forward)` that [Quat.toCameraFrame] returns. That is
/// exactly `project()` in `domain/guidance/projection.dart`, so the 3D target
/// and the 2D fallback marker cannot disagree about where the target is —
/// `test/glb_checks.dart` asserts their agreement numerically.
///
/// Known limitations of this renderer, as opposed to a hardware one:
/// * no depth buffer — triangles are drawn in painter's order (far first), so
///   two coplanar overlapping meshes need an explicit offset (the bezel is
///   recessed by the overlay for that reason);
/// * no near-plane clipping — a triangle with any corner behind the near plane
///   is dropped rather than clipped, so a target pressed against the lens loses
///   its outer ring instead of drawing wrong;
/// * flat shading from the face normal only, since both capture assets are
///   authored without `NORMAL` attributes;
/// * no textures, no blending order between translucent parts, no shadowing.
library;

import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';

/// Where the camera is and how it sees, in the project's world convention.
class GlbCamera {
  /// The camera pose: `pose.rotate(unitZ)` is the optical axis.
  final Quat pose;

  /// The camera's centre in world space, in the same units as the model.
  final Vec3 position;

  /// The viewport in logical pixels.
  final double viewportW;
  final double viewportH;

  /// The real fields of view in degrees, from the reported intrinsics.
  final double hfovDeg;
  final double vfovDeg;

  /// Focal lengths in pixels, derived exactly as `project()` does.
  final double fx;
  final double fy;

  GlbCamera({
    required this.pose,
    required this.position,
    required this.viewportW,
    required this.viewportH,
    required this.hfovDeg,
    required this.vfovDeg,
  }) : fx = (viewportW / 2) / math.tan(hfovDeg * degToRad / 2),
       fy = (viewportH / 2) / math.tan(vfovDeg * degToRad / 2);

  /// A copy pointed along a different pose, at a different place.
  GlbCamera withPose(Quat newPose) => GlbCamera(
    pose: newPose,
    position: position,
    viewportW: viewportW,
    viewportH: viewportH,
    hfovDeg: hfovDeg,
    vfovDeg: vfovDeg,
  );

  /// A copy at a different distance, keeping the pose and the intrinsics.
  GlbCamera withPosition(Vec3 newPosition) => GlbCamera(
    pose: pose,
    position: newPosition,
    viewportW: viewportW,
    viewportH: viewportH,
    hfovDeg: hfovDeg,
    vfovDeg: vfovDeg,
  );

  /// World→camera frame for a point: `(right, up, forward)`, forward positive
  /// in front of the camera.
  Vec3 toCameraFrame(Vec3 worldPoint) =>
      pose.toCameraFrame(worldPoint - position);

  /// The image of a camera-frame point. Undefined for `z <= 0`; callers must
  /// test [isInFront] first.
  ({double u, double v}) projectCameraFrame(Vec3 cameraFrame) => (
    u: viewportW / 2 + fx * cameraFrame.x / cameraFrame.z,
    v: viewportH / 2 - fy * cameraFrame.y / cameraFrame.z,
  );

  static bool isInFront(Vec3 cameraFrame, double nearM) =>
      cameraFrame.z > nearM;

  /// The camera-frame triple of pixel `(u, v)`: the inverse of
  /// [projectCameraFrame], with `forward` normalised to 1.
  Vec3 cameraFrameOfPixel(double u, double v) =>
      Vec3((u - viewportW / 2) / fx, (viewportH / 2 - v) / fy, 1.0);

  /// The world direction through pixel `(u, v)` — the exact inverse of
  /// [toCameraFrame] followed by [projectCameraFrame], which `test/glb_checks.dart`
  /// round-trips.
  Vec3 pixelDirection(double u, double v) {
    final c = cameraFrameOfPixel(u, v);
    // Undo `Quat.toCameraFrame`'s negated x: a camera-frame triple `(x, y, z)`
    // is the world vector `-x·right + y·up + z·forward`, and the pose's columns
    // are exactly those three images.
    return pose.rotate(Vec3(-c.x, c.y, c.z));
  }
}

/// One triangle after world→camera→screen projection, in viewport pixels.
class GlbScreenTriangle {
  final double ax;
  final double ay;
  final double bx;
  final double by;
  final double cx;
  final double cy;

  /// Mean camera-frame forward distance; the painter's-order key.
  final double depth;

  /// The shaded colour, including any `opacity` the caller asked for.
  final GlbColor color;

  /// Which [GlbModel.drawables] entry this came from — the overlay keys
  /// visibility (the check marks) and the failure report on it.
  final int drawableIndex;

  /// A label for the model this triangle came from (`''` when the caller did
  /// not name one). Two GLB files are drawn as one marker, and
  /// [drawableIndex] alone cannot tell the bezel's part 0 from the target's
  /// part 0.
  final String group;

  /// Group rank, used only to break depth ties: with equal depths the earlier
  /// group is drawn first.
  final int groupOrder;

  /// Traversal order, kept so the painter's sort is deterministic for equal
  /// depths instead of leaving it to Dart's unstable `List.sort`.
  final int sequence;

  const GlbScreenTriangle({
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.cx,
    required this.cy,
    required this.depth,
    required this.color,
    required this.drawableIndex,
    required this.sequence,
    this.group = '',
    this.groupOrder = 0,
  });

  /// Twice the signed screen-space area. Zero for a degenerate triangle, and
  /// negative for a clockwise one on a y-down canvas.
  double get signedArea2 => (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

  @override
  String toString() =>
      'GlbScreenTriangle(depth ${depth.toStringAsFixed(4)}, '
      'drawable $drawableIndex, seq $sequence, $color)';
}

/// Colour override hook: return a colour to replace a drawable's material, or
/// `null` to keep it. Used by the overlay for the per-state bezel tint and the
/// white check marks.
typedef GlbRecolor = GlbColor? Function(GlbDrawable drawable);

/// Draw-order comparator, shared by `projectGlb` and `GlbTargetScene`.
///
/// Sort key: far first, then by group rank, then by traversal order. Dart's
/// `List.sort` is an unstable introsort, so the two extra keys are what make a
/// frame reproducible — and make `test/glb_checks.dart` able to assert the
/// order rather than merely that depths are non-increasing.
int compareGlbDrawOrder(GlbScreenTriangle a, GlbScreenTriangle b) {
  final byDepth = b.depth.compareTo(a.depth);
  if (byDepth != 0) return byDepth;
  final byGroup = a.groupOrder.compareTo(b.groupOrder);
  return byGroup != 0 ? byGroup : a.sequence.compareTo(b.sequence);
}

/// Projects every drawable of [model] and returns the visible triangles in
/// **draw order (far first)**.
///
/// * [modelToWorld] places the model: the overlay passes the billboard pose
///   composed with the bezel's recess offset.
/// * [nearM] is the near plane in world units; a triangle with any corner at or
///   behind it is dropped, so a model that is entirely **behind the camera
///   produces no triangles at all** rather than an inverted splat. Dropping
///   rather than clipping is a documented limitation of this renderer, not an
///   oversight: see the library comment.
/// * [cullBackFaces] culls only parts whose material is not `doubleSided`; both
///   capture assets are `doubleSided: true`, so their far walls still draw.
/// * [opacity] multiplies every material alpha (the 0.75 out-of-view case).
/// * [recolor] replaces the material colour per part; [group] labels the
///   resulting triangles so two models can be drawn as one marker.
List<GlbScreenTriangle> projectGlb({
  required GlbModel model,
  required GlbTransform modelToWorld,
  required GlbCamera camera,
  required double nearM,
  double opacity = 1.0,
  bool cullBackFaces = true,
  double shadeFloor = 0.55,
  GlbRecolor? recolor,
  String group = '',
  int groupOrder = 0,
}) {
  final out = <GlbScreenTriangle>[];
  var sequence = 0;

  for (var d = 0; d < model.drawables.length; d++) {
    final drawable = model.drawables[d];
    // `modelToWorld · nodeTransform`: node-local space first, then the model's
    // placement in the world.
    final toWorld = modelToWorld.then(drawable.transform);
    final baseColor = recolor?.call(drawable) ?? drawable.color;
    final positions = drawable.positions;

    for (var i = 0; i + 2 < positions.length; i += 3) {
      final w0 = toWorld.apply(positions[i]);
      final w1 = toWorld.apply(positions[i + 1]);
      final w2 = toWorld.apply(positions[i + 2]);

      final c0 = camera.toCameraFrame(w0);
      final c1 = camera.toCameraFrame(w1);
      final c2 = camera.toCameraFrame(w2);
      if (!(GlbCamera.isInFront(c0, nearM) &&
          GlbCamera.isInFront(c1, nearM) &&
          GlbCamera.isInFront(c2, nearM))) {
        continue; // at or behind the near plane: dropped, never reflected
      }

      // The face normal and centre drive both the cull and the flat shade.
      final normal = _faceNormal(w0, w1, w2);
      final centre = Vec3(
        (w0.x + w1.x + w2.x) / 3,
        (w0.y + w1.y + w2.y) / 3,
        (w0.z + w1.z + w2.z) / 3,
      );

      // Back-face culling in world space, from the face normal rather than the
      // screen winding: the assets' winding is authored CCW when seen from their
      // own +Z, which is not something a y-down canvas can test directly.
      if (cullBackFaces && !drawable.doubleSided) {
        if (normal.dot(centre - camera.position) >= 0) continue;
      }

      final p0 = camera.projectCameraFrame(c0);
      final p1 = camera.projectCameraFrame(c1);
      final p2 = camera.projectCameraFrame(c2);

      if (_outsideViewport(p0.u, p1.u, p2.u, camera.viewportW) ||
          _outsideViewport(p0.v, p1.v, p2.v, camera.viewportH)) {
        continue;
      }

      final signedArea2 =
          (p1.u - p0.u) * (p2.v - p0.v) - (p1.v - p0.v) * (p2.u - p0.u);
      if (signedArea2.abs() < 1e-9) continue; // degenerate on screen

      // Flat shading: how squarely the face meets the optical axis. Doubly
      // sided parts take the absolute value so their back reads lit too, which
      // is what makes the plate visible from either side of the phone.
      var facing = normal.dot((camera.position - centre).normalized);
      if (drawable.doubleSided) facing = facing.abs();
      final shade =
          shadeFloor + (1 - shadeFloor) * clampDouble(facing, 0.0, 1.0);

      var color = baseColor;
      if (drawable.vertexColors.isNotEmpty) {
        // glTF: COLOR_0 multiplies baseColorFactor.
        final v = drawable.vertexColors[i];
        color = GlbColor(
          clampDouble(color.r * v.r, 0.0, 1.0),
          clampDouble(color.g * v.g, 0.0, 1.0),
          clampDouble(color.b * v.b, 0.0, 1.0),
          color.a * v.a,
        );
      }

      out.add(
        GlbScreenTriangle(
          ax: p0.u,
          ay: p0.v,
          bx: p1.u,
          by: p1.v,
          cx: p2.u,
          cy: p2.v,
          depth: (c0.z + c1.z + c2.z) / 3,
          color: color.shaded(shade).withAlpha(color.a * opacity),
          drawableIndex: d,
          sequence: sequence++,
          group: group,
          groupOrder: groupOrder,
        ),
      );
    }
  }

  out.sort(compareGlbDrawOrder);
  return out;
}

Vec3 _faceNormal(Vec3 a, Vec3 b, Vec3 c) => (b - a).cross(c - a).normalized;

/// True when all three screen coordinates are off the same edge.
bool _outsideViewport(double a, double b, double c, double extent) =>
    (a < 0 && b < 0 && c < 0) || (a > extent && b > extent && c > extent);

/// The billboard pose that stands a model whose own `+Z` is its face normal so
/// that it faces [camera] at [target], with `+Y` as near to the camera's up as
/// the geometry allows.
///
/// The capture models are authored in the XY plane facing `+Z` (their accessor
/// bounds run 0 → 0.018 in Z), which is exactly the shape a billboard needs: the
/// returned pose maps the model's `+Z` onto the direction from the target back
/// to the camera. [tiltXDeg]/[tiltYDeg] are the prototype's head-tilt angles and
/// are applied in the model's own frame, after the billboard, so a positive
/// `tiltYDeg` always turns the plate's own right edge away from the viewer.
GlbTransform glbBillboardTransform({
  required Vec3 target,
  required GlbCamera camera,
  double tiltXDeg = 0,
  double tiltYDeg = 0,
  double scale = 1.0,
}) {
  final toCamera = camera.position - target;
  final face = toCamera.length == 0
      ? camera.pose.rotate(Vec3.unitZ)
      : toCamera.normalized;
  var up = camera.pose.rotate(Vec3.unitY);
  // When the camera looks straight down its own up is (nearly) the face normal,
  // so take a fixed world axis instead — a plate facing the nadir still needs a
  // deterministic roll.
  if (up.dot(face).abs() > 0.999) up = Vec3.unitZ;
  // `(right, up, face)` has to be a right-handed triple to be a rotation, which
  // fixes the cross-product order: right = up × face, then re-derive up.
  var right = up.cross(face);
  if (right.length < 1e-9) right = Vec3.unitX.cross(face);
  right = right.normalized;
  final orthoUp = face.cross(right).normalized;
  // Columns of the rotation: where the model's x̂, ŷ, ẑ land in the world.
  final billboard = Quat.fromMatrix3(<double>[
    right.x, orthoUp.x, face.x, //
    right.y, orthoUp.y, face.y, //
    right.z, orthoUp.z, face.z, //
  ]);
  final tilt =
      (Quat.axisAngle(tiltXDeg, Vec3.unitX) *
              Quat.axisAngle(tiltYDeg, Vec3.unitY))
          .normalized;
  return GlbTransform.trs(
    translation: target,
    rotation: (billboard * tilt).normalized,
    scale: Vec3(scale, scale, scale),
  );
}
