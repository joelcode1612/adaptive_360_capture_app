import 'dart:math' as math;

/// Immutable 3-vector.
///
/// Pure Dart. Ported from the reference's `dot3`, `cross3`, `norm3` and the
/// array arithmetic used throughout `/*ENGINE*/`.
class Vec3 {
  final double x;
  final double y;
  final double z;

  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);
  static const Vec3 unitX = Vec3(1, 0, 0);
  static const Vec3 unitY = Vec3(0, 1, 0);
  static const Vec3 unitZ = Vec3(0, 0, 1);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  Vec3 operator -() => Vec3(-x, -y, -z);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  /// Unit vector. A zero vector normalises to zero rather than NaN, which is
  /// what `norm3`'s `|| 1` guard does in the reference.
  Vec3 get normalized {
    final l = length;
    return l == 0 ? Vec3.zero : Vec3(x / l, y / l, z / l);
  }

  List<double> toList() => <double>[x, y, z];

  factory Vec3.fromList(List<double> v) => Vec3(v[0], v[1], v[2]);

  /// Largest absolute component-wise difference.
  double maxAbsDiff(Vec3 o) =>
      math.max(math.max((x - o.x).abs(), (y - o.y).abs()), (z - o.z).abs());

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(6)}, ${y.toStringAsFixed(6)}, '
      '${z.toStringAsFixed(6)})';
}
