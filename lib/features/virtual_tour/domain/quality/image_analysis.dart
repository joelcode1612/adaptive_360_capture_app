import 'dart:math' as math;
import 'dart:typed_data';

/// Pixel statistics used to judge a captured frame.
///
/// Ported from `gray` and `analyze` in `/*ENGINE*/`. Every value is derived
/// from pixels; none of them is a proxy for "this will stitch".

/// Grayscale conversion weights (Rec. 601), matching the reference.
const double _kr = 0.299;
const double _kg = 0.587;
const double _kb = 0.114;

/// Converts packed RGBA bytes to a single-channel grey plane.
Float64List toGrayscale(Uint8List rgba, int w, int h) {
  final n = w * h;
  final g = Float64List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    g[i] = _kr * rgba[o] + _kg * rgba[o + 1] + _kb * rgba[o + 2];
  }
  return g;
}

/// Result of [analyzeGray].
class ImageStats {
  /// Mean luminance, 0…255.
  final double mean;

  /// Share of pixels below 25 — crushed shadows.
  final double darkShare;

  /// Share of pixels above 245 — clipped highlights.
  final double saturatedShare;

  /// Variance of the 4-neighbour Laplacian. The sharpness metric.
  final double laplacianVariance;

  /// Mean gradient magnitude, a coarse texture measure.
  final double gradientMean;

  /// Share of pixels whose gradient magnitude exceeds 10 — "edge pixels".
  final double strongEdgeShare;

  /// Shannon entropy of the 32-bin luminance histogram, in bits.
  final double entropy;

  const ImageStats({
    required this.mean,
    required this.darkShare,
    required this.saturatedShare,
    required this.laplacianVariance,
    required this.gradientMean,
    required this.strongEdgeShare,
    required this.entropy,
  });

  @override
  String toString() =>
      'mean ${mean.toStringAsFixed(1)}, '
      'dark ${(darkShare * 100).toStringAsFixed(1)}%, '
      'sat ${(saturatedShare * 100).toStringAsFixed(1)}%, '
      'lapVar ${laplacianVariance.toStringAsFixed(1)}, '
      'strong ${(strongEdgeShare * 100).toStringAsFixed(1)}%, '
      'entropy ${entropy.toStringAsFixed(2)}';
}

/// Computes every pixel statistic in one pass over the interior.
///
/// The Laplacian uses the 4-neighbour stencil `4c − l − r − u − d`, so the
/// 1-pixel border is excluded from the sharpness and gradient sums.
ImageStats analyzeGray(Float64List g, int w, int h) {
  final n = w * h;
  var sum = 0.0;
  var dark = 0;
  var saturated = 0;
  final hist = List<int>.filled(32, 0);

  for (var i = 0; i < n; i++) {
    final v = g[i];
    sum += v;
    if (v < 25) dark++;
    if (v > 245) saturated++;
    final bin = (v ~/ 8).clamp(0, 31);
    hist[bin]++;
  }

  final mean = sum / n;

  var lapSum = 0.0;
  var lapSqSum = 0.0;
  var count = 0;
  var gradSum = 0.0;
  var strong = 0;

  for (var j = 1; j < h - 1; j++) {
    for (var i = 1; i < w - 1; i++) {
      final k = j * w + i;
      final c = g[k];
      final lap = 4 * c - g[k - 1] - g[k + 1] - g[k - w] - g[k + w];
      final gx = g[k + 1] - g[k - 1];
      final gy = g[k + w] - g[k - w];
      final gm = math.sqrt(gx * gx + gy * gy) / 2;
      lapSum += lap;
      lapSqSum += lap * lap;
      count++;
      gradSum += gm;
      if (gm > 10) strong++;
    }
  }

  final safeCount = count == 0 ? 1 : count;
  final lapVar =
      lapSqSum / safeCount - (lapSum / safeCount) * (lapSum / safeCount);

  var entropy = 0.0;
  for (final c in hist) {
    if (c != 0) {
      final p = c / n;
      entropy -= p * (math.log(p) / math.ln2);
    }
  }

  return ImageStats(
    mean: mean,
    darkShare: dark / n,
    saturatedShare: saturated / n,
    laplacianVariance: lapVar,
    gradientMean: gradSum / safeCount,
    strongEdgeShare: strong / safeCount,
    entropy: entropy,
  );
}
