import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Axis-aligned room geometry used by the occlusion and viewpoint heuristics.
///
/// Ported from `rayBox`, `occlusion`, `wallPts`, `wallVis` and `suggestVP` in
/// `/*ENGINE*/`.
///
/// **These are heuristics over boxes the user enters, not a reconstruction of
/// the room.** They can only say "an obstacle the user described blocks this
/// fraction of viewing directions".

/// An axis-aligned box standing on the floor.
///
/// `(x, z)` is the centre in plan view, `w`/`d` are its width and depth, and
/// `h` is its height above the floor.
class ObstacleBox {
  final double x;
  final double z;
  final double w;
  final double d;
  final double h;

  const ObstacleBox({
    required this.x,
    required this.z,
    required this.w,
    required this.d,
    required this.h,
  });

  /// `[loX, loY, loZ]` and `[hiX, hiY, hiZ]`.
  ({Vec3 lo, Vec3 hi}) get bounds =>
      (lo: Vec3(x - w / 2, 0, z - d / 2), hi: Vec3(x + w / 2, h, z + d / 2));

  /// True when `(px, pz)` is within [margin] metres of the box footprint.
  bool footprintContains(double px, double pz, double margin) =>
      (px - x).abs() < w / 2 + margin && (pz - z).abs() < d / 2 + margin;
}

/// Rectangular room footprint in metres.
class RoomBox {
  final double lengthM;
  final double widthM;

  const RoomBox({required this.lengthM, required this.widthM});
}

/// Height of the camera above the floor used by every occlusion test.
const double cameraHeightM = 1.5;

/// Slab test for a ray against an axis-aligned box.
///
/// [origin] is the ray start, [dir] the (unnormalised) direction, [tMax] the
/// parametric limit. Returns true when the ray enters the box within
/// `[0, tMax]`.
bool rayIntersectsBox(ObstacleBox box, Vec3 origin, Vec3 dir, [double? tMax]) {
  var t0 = 0.0;
  var t1 = tMax ?? 1e9;
  final b = box.bounds;
  final lo = b.lo;
  final hi = b.hi;
  final o = <double>[origin.x, origin.y, origin.z];
  final dd = <double>[dir.x, dir.y, dir.z];
  final l = <double>[lo.x, lo.y, lo.z];
  final hgh = <double>[hi.x, hi.y, hi.z];

  for (var k = 0; k < 3; k++) {
    if (dd[k].abs() < 1e-9) {
      if (o[k] < l[k] || o[k] > hgh[k]) return false;
    } else {
      var a = (l[k] - o[k]) / dd[k];
      var bb = (hgh[k] - o[k]) / dd[k];
      if (a > bb) {
        final tmp = a;
        a = bb;
        bb = tmp;
      }
      t0 = math.max(t0, a);
      t1 = math.min(t1, bb);
      if (t0 > t1) return false;
    }
  }
  return t1 > 0;
}

/// Share of viewing directions (0…1) blocked by any obstacle from [pos].
double occlusionShare(
  ({double x, double z}) pos,
  List<ObstacleBox> obstacles, [
  SphereSamples? samplesOverride,
]) {
  if (obstacles.isEmpty) return 0;
  final s = samplesOverride ?? fibonacciSamples(4000);
  final p = Vec3(pos.x, cameraHeightM, pos.z);
  var blocked = 0;
  for (var i = 0; i < s.n; i++) {
    final d = Vec3(s.x[i], s.y[i], s.z[i]);
    for (final o in obstacles) {
      if (rayIntersectsBox(o, p, d)) {
        blocked++;
        break;
      }
    }
  }
  return blocked / s.n;
}

/// Sample points along the room's four walls, at four heights each.
List<Vec3> wallPoints(RoomBox room) {
  final pts = <Vec3>[];
  for (var k = 0; k < 80; k++) {
    final u = k / 80 * 4;
    final e = u.floor();
    final f = u - e;
    final xf = <double>[f, 1, 1 - f, 0][e];
    final zf = <double>[0, f, 1, 1 - f][e];
    final x = xf * room.lengthM;
    final z = zf * room.widthM;
    for (final hgt in const <double>[0.3, 0.9, 1.5, 2.2]) {
      pts.add(Vec3(x, hgt, z));
    }
  }
  return pts;
}

/// 1 for each wall point visible from [pos], 0 for each blocked one.
List<int> wallVisibility(
  RoomBox room,
  ({double x, double z}) pos,
  List<ObstacleBox> obstacles, [
  List<Vec3>? points,
]) {
  final pts = points ?? wallPoints(room);
  final p = Vec3(pos.x, cameraHeightM, pos.z);
  return pts
      .map(
        (w) =>
            obstacles.any(
              (o) => rayIntersectsBox(
                o,
                p,
                Vec3(w.x - p.x, w.y - p.y, w.z - p.z),
                1,
              ),
            )
            ? 0
            : 1,
      )
      .toList();
}
