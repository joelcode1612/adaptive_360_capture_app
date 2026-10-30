import 'dart:math' as math;
import 'dart:typed_data';

/// Scalar helpers shared by the whole capture domain.
///
/// Pure Dart: no Flutter, no platform channels. Ported from the `/*ENGINE*/`
/// block of `adaptive_360_realistic_test.html` (constants `D2R`, `R2D`,
/// `clamp`, `wrap`, `mulberry`).

/// Degrees → radians.
const double degToRad = math.pi / 180;

/// Radians → degrees.
const double radToDeg = 180 / math.pi;

/// Clamps [v] into `[a, b]`, matching `Math.min(b, Math.max(a, v))`.
double clampDouble(double v, double a, double b) => math.min(b, math.max(a, v));

/// Wraps an angle in degrees into `(-180, 180]`.
///
/// Kept in the reference's `((a % 360) + 540) % 360 - 180` form so negative
/// inputs behave identically.
double wrapDeg(double a) => ((a % 360) + 540) % 360 - 180;

/// Rounds [v] to the nearest float32 and returns it as a `double`.
///
/// The reference stores its sphere samples in `Float32Array`s, so every number
/// its coverage pass reads is already float32-quantised. Dart has no float32
/// scalar, so the engine holds `double`s and rounds on store instead — see
/// `fibonacciSamples`. Without this, downstream sums and margins agree with
/// JavaScript only to ~1e-7 rather than bit for bit.
double asFloat32(double v) => (Float32List(1)..[0] = v)[0];

/// 32-bit signed multiply, the equivalent of JavaScript's `Math.imul`.
///
/// The low 32 bits of the product are the same whether the operands are read
/// as signed or unsigned, so masking to 32 bits is enough.
int _imul(int x, int y) => (x * y) & 0xFFFFFFFF;

/// Deterministic 32-bit PRNG (Mulberry32), bit-for-bit identical to the
/// reference so that seeded scenarios reproduce the same numbers.
///
/// Every value is kept as an unsigned 32-bit pattern in a Dart `int`; `>>>`
/// then matches JavaScript's `>>>` and `^` matches its `^`. The only place
/// JavaScript's `| 0` matters is the addition, where it truncates to 32 bits —
/// reproduced with `& 0xFFFFFFFF`.
class Mulberry32 {
  int _a;

  Mulberry32(int seed) : _a = seed & 0xFFFFFFFF;

  /// Uniform in `[0, 1)`.
  double next() {
    _a = (_a + 0x6D2B79F5) & 0xFFFFFFFF;

    // JS: let t = Math.imul(a ^ a >>> 15, 1 | a);
    var t = _imul(_a ^ (_a >>> 15), 1 | _a);

    // JS: t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    // `+` binds tighter than `^`, so the sum is formed first, then XORed.
    t = ((t + _imul(t ^ (t >>> 7), 61 | t)) ^ t) & 0xFFFFFFFF;

    // JS: return ((t ^ t >>> 14) >>> 0) / 4294967296;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }
}
