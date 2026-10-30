import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';

/// Procedural simulated room.
///
/// Ported from `texel`, `blurRGBA` and `renderSim` in `/*ENGINE*/`.
///
/// **This is a test fixture, not part of the product.** The brief is explicit
/// that the procedural room must be used only inside tests. It exists so the
/// quality-analysis rules and the state machine can be exercised deterministically
/// without a device.
///
/// The rendered frames are clearly synthetic: a banded wall, a floor, a window
/// and a skirting board, with optional blur, noise and exposure scaling.

/// Conditions the simulated scene can express.
class SimScene {
  final bool blank;

  /// Reflective band at yaw −90°.
  final bool mirror;

  /// Global light multiplier; null means 1.
  final double? light;

  /// Window brightness multiplier.
  final double? window;

  /// Per-pixel noise amplitude; 0 disables the noise pass entirely (and with
  /// it one call to the PRNG, which matters for seeded reproducibility).
  final double noise;

  /// Exposure multiplier applied on top of [light].
  final double? exposure;

  /// Box-blur radius; values below 1 disable blurring.
  final double blur;

  const SimScene({
    this.blank = false,
    this.mirror = false,
    this.light,
    this.window,
    this.noise = 0,
    this.exposure,
    this.blur = 0,
  });

  SimScene copyWith({
    bool? blank,
    bool? mirror,
    double? light,
    double? window,
    double? noise,
    double? exposure,
    double? blur,
  }) => SimScene(
    blank: blank ?? this.blank,
    mirror: mirror ?? this.mirror,
    light: light ?? this.light,
    window: window ?? this.window,
    noise: noise ?? this.noise,
    exposure: exposure ?? this.exposure,
    blur: blur ?? this.blur,
  );
}

/// Scene colour for a (yaw, pitch) ray.
List<double> _texel(double yaw, double pitch, SimScene c) {
  // A mirror reflects the yaw across the −90° axis; the mirror flag stays set
  // so the frame edges are still drawn below.
  var y = wrapDeg(yaw);
  if (c.mirror && y > -135 && y < -45) y = -90 - y;

  var n = math.sin(y * 12.9898 + pitch * 78.233) * 43758.5453;
  n -= n.floorToDouble();

  late double r;
  late double g;
  late double b;

  if (pitch >= 38) {
    final s = ((y / 20).floor() + ((pitch - 38) / 10).floor()) & 1;
    final v = s != 0 ? 195.0 : 175.0;
    r = v;
    g = v;
    b = v;
    if (wrapDeg(y % 45 - 22.5).abs() < 7 && pitch > 52 && pitch < 66) {
      r = g = b = 236;
    }
    r += n * 8;
    g += n * 8;
    b += n * 8;
  } else if (pitch <= -28) {
    final s = ((y / 4).floor() + (pitch / 3).floor()) & 1;
    r = 150 + s * 30 + n * 10;
    g = 110 + s * 20 + n * 8;
    b = 70 + s * 10;
  } else {
    final secRaw = (((y + 45 + 360) % 360) / 90).floor();
    final sec = secRaw < 0 ? 0 : (secRaw > 3 ? 3 : secRaw);
    const base = <List<double>>[
      <double>[206, 196, 176],
      <double>[176, 190, 170],
      <double>[220, 220, 220],
      <double>[190, 170, 160],
    ];
    final bb = base[sec];
    final blank = c.blank && sec == 2;
    final row = ((pitch + 28) / 3).floor();
    final m = ((y + (row & 1) * 3) % 6 + 6) % 6;

    if (blank) {
      r = bb[0] + n * 2;
      g = bb[1] + n * 2;
      b = bb[2] + n * 2;
    } else {
      final k = (m < 0.5 || ((pitch + 28) % 3) < 0.35) ? 0.72 : 1.0;
      r = bb[0] * k + n * 14;
      g = bb[1] * k + n * 14;
      b = bb[2] * k + n * 14;
    }

    if (sec == 0 && y.abs() < 20 && pitch > 4 && pitch < 32) {
      final frame = y.abs() > 18 || pitch < 6 || pitch > 30 || y.abs() < 1;
      final v = frame ? 60.0 : 235.0 * (c.window ?? 1.0);
      r = g = b = v;
    }
    if (sec == 1 && y > 70 && y < 110 && pitch > 6 && pitch < 24) {
      final q = ((y / 3).floor() + (pitch / 3).floor()) & 1;
      r = q != 0 ? 200 : 70;
      g = q != 0 ? 60 : 90;
      b = q != 0 ? 50 : 140;
    }
    if (c.mirror && ((y + 135).abs() < 1.5 || (y + 45).abs() < 1.5)) {
      r = g = b = 70;
    }
  }

  final m2 = (c.light ?? 1) * (c.exposure ?? 1);
  return <double>[r * m2, g * m2, b * m2];
}

/// In-place separable box blur of the RGB channels, radius [k].
void _blurRgba(Uint8List d, int w, int h, int k) {
  final t = Float64List(w * h * 3);

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      var a = 0.0;
      var b = 0.0;
      var c = 0.0;
      var count = 0;
      for (var s = -k; s <= k; s++) {
        final xi = (i + s).clamp(0, w - 1);
        final o = (j * w + xi) * 4;
        a += d[o];
        b += d[o + 1];
        c += d[o + 2];
        count++;
      }
      final q = (j * w + i) * 3;
      t[q] = a / count;
      t[q + 1] = b / count;
      t[q + 2] = c / count;
    }
  }

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      var a = 0.0;
      var b = 0.0;
      var c = 0.0;
      var count = 0;
      for (var s = -k; s <= k; s++) {
        final yj = (j + s).clamp(0, h - 1);
        final q = (yj * w + i) * 3;
        a += t[q];
        b += t[q + 1];
        c += t[q + 2];
        count++;
      }
      final o = (j * w + i) * 4;
      d[o] = _toUint8Clamp(a / count);
      d[o + 1] = _toUint8Clamp(b / count);
      d[o + 2] = _toUint8Clamp(c / count);
    }
  }
}

/// Renders one simulated frame at [yawDeg] / [pitchDeg] with the given field of
/// view, into a packed RGBA buffer of `w × h`.
Uint8List renderSim(
  int w,
  int h,
  double yawDeg,
  double pitchDeg,
  double hfovDeg,
  double vfovDeg,
  SimScene c,
  Mulberry32 rand,
) {
  final d = Uint8List(w * h * 4);
  final b = orthonormalBasis(yawDeg, pitchDeg);
  final th = math.tan(hfovDeg * degToRad / 2);
  final tv = math.tan(vfovDeg * degToRad / 2);

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      final dx = th * (2 * (i + 0.5) / w - 1);
      final dy = tv * (1 - 2 * (j + 0.5) / h);

      final wx = dx * b.right.x + dy * b.up.x + b.forward.x;
      final wy = dx * b.right.y + dy * b.up.y + b.forward.y;
      final wz = dx * b.right.z + dy * b.up.z + b.forward.z;

      final l = math.sqrt(wx * wx + wy * wy + wz * wz);
      final t = _texel(
        math.atan2(wx, wz) * radToDeg,
        math.asin(clampDouble(wy / l, -1, 1)) * radToDeg,
        c,
      );

      final o = (j * w + i) * 4;
      final nz = c.noise != 0 ? (rand.next() - 0.5) * c.noise : 0.0;
      d[o] = _toUint8Clamp(t[0] + nz);
      d[o + 1] = _toUint8Clamp(t[1] + nz);
      d[o + 2] = _toUint8Clamp(t[2] + nz);
      d[o + 3] = 255;
    }
  }

  if (c.blur >= 1) _blurRgba(d, w, h, c.blur.round());
  return d;
}

/// Matches JavaScript's `Uint8ClampedArray` assignment: clamp to 0…255, and
/// round halves to even.
int _toUint8Clamp(double v) {
  if (v.isNaN) return 0;
  if (v <= 0) return 0;
  if (v >= 255) return 255;
  final f = v.floorToDouble();
  final diff = v - f;
  if (diff < 0.5) return f.toInt();
  if (diff > 0.5) return f.toInt() + 1;
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}
