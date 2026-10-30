import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';

/// Parallax risk heuristic.
///
/// Ported from `parallax` in `/*ENGINE*/`.
///
/// This estimates the pixel shift between neighbouring frames caused by the
/// user's hand-held translation, not by the virtual sphere's radius. It is a
/// **heuristic**: the reference computes it from the neighbouring-frame chord
/// at the nominal hand-sway radius and a 540 px reference focal length.
class ParallaxEstimate {
  /// Estimated double-image shift in pixels.
  final double pixelShift;

  /// `low` | `moderate` | `high`.
  final String risk;

  const ParallaxEstimate({required this.pixelShift, required this.risk});

  bool get isHigh => risk == 'high';

  @override
  String toString() => '${pixelShift.toStringAsFixed(1)} px ($risk)';
}

/// Reference focal length in pixels used by the heuristic (a 1080-wide image).
const double _referenceFocalPx = 540;

/// Estimated parallax between adjacent frames.
///
/// [maxRowColumns] is the widest ring's column count — the smallest yaw step in
/// the plan. [nearDistanceM] is the closest object the user reported;
/// [radiusM] is the nominal hand-sway radius (default 0.15 m).
ParallaxEstimate estimateParallax({
  required int maxRowColumns,
  required double nearDistanceM,
  required double hfovDeg,
  double radiusM = 0.15,
}) {
  final n = math.max(maxRowColumns, 3);
  final dy = 360 / n;
  final chord = 2 * radiusM * math.sin(dy * degToRad / 2);
  final f = _referenceFocalPx / math.tan(hfovDeg * degToRad / 2);
  final px = f * chord * (1 / nearDistanceM - 1 / 6);
  return ParallaxEstimate(
    pixelShift: px,
    risk: px < 2 ? 'low' : (px < 6 ? 'moderate' : 'high'),
  );
}
