import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';

/// Spherical coverage engine.
///
/// Ported from `cover`, `covStats`, `fill` and `lonWidth` in `/*ENGINE*/`.
///
/// A frame is a **rectilinear frustum**, tested exactly as
/// `|x/z| ≤ tan(hfov/2)`, `|y/z| ≤ tan(vfov/2)`, `z > 0` — no `atan2`, no
/// `hypot`, no angular approximation. Because the sample grid is equal-area,
/// the fraction of samples covered estimates the solid-angle fraction.

/// Per-sample coverage counts and best margin from one frustum set.
class CoverageField {
  /// Number of frames whose frustum contains each sample.
  final Uint16List counts;

  /// Best (largest) edge margin in degrees per sample, or a large negative
  /// sentinel for samples that no frame covers.
  final Float64List margins;

  const CoverageField(this.counts, this.margins);
}

/// Computes how many frames cover each sample, and the best margin.
CoverageField cover(List<PlanFrame> frames, SphereSamples s) {
  final n = s.n;
  final counts = Uint16List(n);
  final margins = Float64List(n)..fillRange(0, n, -99);

  for (final f in frames) {
    final th = math.tan(f.hfovDeg * degToRad / 2);
    final tv = math.tan(f.vfovDeg * degToRad / 2);

    // The frame's own basis. A pole frame looks straight up or down and its
    // basis is still well defined (`right × up == forward`), so no special
    // case is needed — this is exactly what `basis()` does in the reference.
    final b = orthonormalBasis(f.yawDeg, f.pitchDeg);
    final fwd = b.forward;
    final r = b.right;
    final u = b.up;

    for (var i = 0; i < n; i++) {
      final x = s.x[i];
      final y = s.y[i];
      final z = s.z[i];

      final zc = x * fwd.x + y * fwd.y + z * fwd.z;
      if (zc <= 0.01) continue;

      final xc = x * r.x + y * r.y + z * r.z;
      final yc = x * u.x + y * u.y + z * u.z;

      if (xc.abs() <= th * zc && yc.abs() <= tv * zc) {
        counts[i]++;
        final m = math.min(
          f.hfovDeg / 2 - math.atan(xc / zc).abs() * radToDeg,
          f.vfovDeg / 2 - math.atan(yc / zc).abs() * radToDeg,
        );
        if (m > margins[i]) margins[i] = m;
      }
    }
  }

  return CoverageField(counts, margins);
}

/// One uncovered patch of the sphere, clustered into a 15° × 15° bin.
class UncoveredRegion {
  final double yawDeg;
  final double pitchDeg;

  /// Share of the whole sphere, in percent.
  final double sharePct;

  const UncoveredRegion({
    required this.yawDeg,
    required this.pitchDeg,
    required this.sharePct,
  });

  @override
  String toString() =>
      'yaw ${yawDeg.toStringAsFixed(0)}°, '
      'pitch ${pitchDeg.toStringAsFixed(0)}° '
      '(${sharePct.toStringAsFixed(1)}%)';
}

/// Summary statistics over a frame set.
class CoverageStats {
  /// Percent of the sphere covered by at least one frame.
  final double coveragePct;

  /// Percent of the sphere covered by at least two frames.
  final double overlapPct;

  /// Percent covered by exactly one frame — the risky band for stitching.
  final double singlePct;

  /// Percent covered by no frame at all.
  final double uncoveredPct;

  /// Smallest edge margin over covered samples, in degrees; null when nothing
  /// is covered. A small margin means the seam sits right at a frustum edge.
  final double? minMargin;

  final List<UncoveredRegion> uncovered;

  final int frames;

  // ── enriched by the plan generator ──────────────────────────────────────
  int rows = 0;
  int repairs = 0;
  int baseFrames = 0;
  int poleFrames = 0;
  double minOverlap = 0;
  double timeSeconds = 0;

  CoverageStats({
    required this.coveragePct,
    required this.overlapPct,
    required this.singlePct,
    required this.uncoveredPct,
    required this.minMargin,
    required this.uncovered,
    required this.frames,
  });

  @override
  String toString() =>
      'coverage ${coveragePct.toStringAsFixed(2)}%, '
      'uncovered ${uncoveredPct.toStringAsFixed(3)}%, '
      '$frames frames';
}

/// Aggregates a [CoverageField] into [CoverageStats].
CoverageStats coverageStats(List<PlanFrame> frames, SphereSamples s) {
  final field = cover(frames, s);
  final cnt = field.counts;
  final mar = field.margins;
  final n = s.n;

  var c1 = 0;
  var c2 = 0;
  var mm = double.infinity;
  final bins = <String, List<double>>{}; // key -> [count, sumYaw, sumPitch]

  for (var i = 0; i < n; i++) {
    if (cnt[i] >= 1) {
      c1++;
      if (mar[i] < mm) mm = mar[i];
    }
    if (cnt[i] >= 2) c2++;
    if (cnt[i] == 0) {
      final y = math.atan2(s.x[i], s.z[i]) * radToDeg;
      final p = math.asin(clampDouble(s.y[i], -1, 1)) * radToDeg;
      final key = '${(y / 15).round()},${(p / 15).round()}';
      final b = bins.putIfAbsent(key, () => <double>[0, 0, 0]);
      b[0] += 1;
      b[1] += y;
      b[2] += p;
    }
  }

  final unc =
      bins.values
          .map(
            (b) => UncoveredRegion(
              yawDeg: (b[1] / b[0]).roundToDouble(),
              pitchDeg: (b[2] / b[0]).roundToDouble(),
              sharePct: b[0] / n * 100,
            ),
          )
          .toList()
        ..sort((a, b) => b.sharePct.compareTo(a.sharePct));

  return CoverageStats(
    coveragePct: c1 / n * 100,
    overlapPct: c2 / n * 100,
    singlePct: (c1 - c2) / n * 100,
    uncoveredPct: (n - c1) / n * 100,
    minMargin: c1 > 0 ? mm : null,
    uncovered: unc,
    frames: frames.length,
  );
}

/// Greedy gap filler: adds frames centred on uncovered samples until the sphere
/// is covered, or [maxAdd] frames have been added.
///
/// Ported from `fill`.
List<PlanFrame> fillGaps(
  List<PlanFrame> frames,
  SphereSamples s,
  double hfovDeg,
  double vfovDeg, {
  int maxAdd = 80,
}) {
  final add = <PlanFrame>[];
  final field = cover(frames, s);
  final cnt = Uint32List.fromList(field.counts);

  for (var k = 0; k < maxAdd; k++) {
    final idx = cnt.indexOf(0);
    if (idx < 0) break;

    var y = math.atan2(s.x[idx], s.z[idx]) * radToDeg;
    var p = math.asin(clampDouble(s.y[idx], -1, 1)) * radToDeg;
    final pole = p.abs() > 85;
    if (pole) {
      p = p > 0 ? 90 : -90;
      y = 0;
    }

    final f = PlanFrame(
      yawDeg: _round2(y),
      pitchDeg: _round2(p),
      hfovDeg: hfovDeg,
      vfovDeg: vfovDeg,
      isPole: pole,
      isZenith: pole && p > 0,
      isNadir: pole && p < 0,
      isRepair: true,
    );

    final c2 = cover(<PlanFrame>[f], s);
    for (var i = 0; i < s.n; i++) {
      if (c2.counts[i] > 0) cnt[i]++;
    }
    add.add(f);
  }

  return add;
}

/// Half-step slack that lets a longitude sweep sample sitting exactly on the
/// frustum edge count as inside, which is how the reference reads it.
/// See [longitudeWidth].
const double _edgeTie = 1e-12;

/// Longitude width (degrees) of the frustum centred at [pitchDeg].
///
/// Walks outward in longitude in 0.25° steps until the frustum test fails, so
/// it measures the real width rather than approximating it. Returns at least
/// 0.5° so a caller can never divide by zero.
///
/// A sweep sample that lands exactly on the frustum edge counts as inside.
/// With `H = 90` the horizon row's 45° sample is such a tie: `|xc|` and
/// `tan(H/2)·zc` are the same number to the last bit. The reference reads that
/// sample as inside because V8's `Math.sin(45°)` comes out 1 ulp *below* the
/// correctly-rounded value Dart returns — `0.70710678118654746172` against
/// `0.70710678118654757274` — so a bare `>` here would make the row 0.5°
/// narrower than the golden's and change its overlap (see
/// `docs/JS_PARITY_DISCREPANCIES.md`). The epsilon cannot do anything else: the
/// nearest sweep sample outside the frustum misses by 6.2e-3, ten orders of
/// magnitude wider.
double longitudeWidth(double pitchDeg, double hfovDeg, double vfovDeg) {
  final th = math.tan(hfovDeg * degToRad / 2);
  final tv = math.tan(vfovDeg * degToRad / 2);
  final b = orthonormalBasis(0, pitchDeg);
  var w = 0.0;

  for (var l = 0.0; l <= 180; l += 0.25) {
    final d = directionFromYawPitch(l, pitchDeg);
    final zc = d.dot(b.forward);
    if (zc <= 0.01) break;
    final xc = d.x * b.right.x + d.y * b.right.y + d.z * b.right.z;
    final yc = d.x * b.up.x + d.y * b.up.y + d.z * b.up.z;
    if (xc.abs() > th * zc + _edgeTie || yc.abs() > tv * zc + _edgeTie) break;
    w = l;
  }

  return math.max(2 * w, 0.5);
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
