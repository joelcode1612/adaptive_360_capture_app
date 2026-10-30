import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Direction of a (yaw, pitch) pair on the unit sphere.
///
/// `vec(y, p) = (cos p · sin y, sin p, cos p · cos y)`.
///
/// **Note on the yaw convention:** this yaw is *clockwise seen from above*
/// (forward → `+X`). A textbook right-handed rotation about `+Y` by θ maps
/// `(0,0,−1) → (−sinθ, 0, −cosθ)` — the **negative** of this. It is a
/// navigation/azimuth yaw, which is the right choice for a human-facing UI
/// ("turn right"), but **do not feed it into a library expecting a standard
/// right-handed rotation** (e.g. ARKit's `simd_quatf(axis: y, angle:)`)
/// without negating θ.
Vec3 directionFromYawPitch(double yawDeg, double pitchDeg) {
  final y = yawDeg * degToRad;
  final p = pitchDeg * degToRad;
  final cp = math.cos(p);
  return Vec3(cp * math.sin(y), math.sin(p), cp * math.cos(y));
}

/// Orthonormal camera basis for a (yaw, pitch) pose.
///
/// Returns `forward` (the optical axis), `right` and `up`, right-handed, so
/// `right × up == forward`.
({Vec3 forward, Vec3 right, Vec3 up}) orthonormalBasis(
  double yawDeg,
  double pitchDeg,
) {
  final y = yawDeg * degToRad;
  final p = pitchDeg * degToRad;
  final sy = math.sin(y);
  final cy = math.cos(y);
  final sp = math.sin(p);
  final cp = math.cos(p);
  return (
    forward: Vec3(cp * sy, sp, cp * cy),
    right: Vec3(cy, 0, -sy),
    up: Vec3(-sp * sy, cp, -sp * cy),
  );
}

/// An equal-area sample grid on the unit sphere (Fibonacci / golden-angle).
///
/// Because the samples are equal-area, the *fraction* of samples inside a set
/// of frusta is an unbiased estimate of the *solid-angle* fraction. That is
/// what makes [CoverageStats.coverage] meaningful.
///
/// The coordinates are stored `asFloat32`-rounded, because the reference keeps
/// them in `Float32Array`s and every coverage number it reports is computed
/// from that quantisation. The lists themselves stay `Float64List` so callers
/// can accumulate in full precision exactly as JavaScript accumulates in doubles
/// after reading a `Float32Array`.
class SphereSamples {
  final int n;
  final Float64List x;
  final Float64List y;
  final Float64List z;

  const SphereSamples._(this.n, this.x, this.y, this.z);

  Vec3 at(int i) => Vec3(x[i], y[i], z[i]);
}

final Map<int, SphereSamples> _sampleCache = <int, SphereSamples>{};

/// Returns the cached equal-area grid of [n] points.
///
/// The golden angle is `π(3 − √5)`; point `i` is placed at
/// `y = 1 − 2(i + 0.5)/n` with radius `√(1 − y²)` and azimuth `i · g`.
SphereSamples fibonacciSamples(int n) {
  final cached = _sampleCache[n];
  if (cached != null) return cached;

  final xs = Float64List(n);
  final ys = Float64List(n);
  final zs = Float64List(n);
  final g = math.pi * (3 - math.sqrt(5));

  for (var i = 0; i < n; i++) {
    final yy = 1 - 2 * (i + 0.5) / n;
    final r = math.sqrt(math.max(0, 1 - yy * yy));
    final ph = i * g;
    xs[i] = asFloat32(r * math.cos(ph));
    ys[i] = asFloat32(yy);
    zs[i] = asFloat32(r * math.sin(ph));
  }

  final s = SphereSamples._(n, xs, ys, zs);
  _sampleCache[n] = s;
  return s;
}
