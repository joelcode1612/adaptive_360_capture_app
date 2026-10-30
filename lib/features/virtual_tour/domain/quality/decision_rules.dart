import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/image_analysis.dart';

/// Accept / reject rules for a captured frame.
///
/// Ported from `T0` and `decide` in `/*ENGINE*/`.
///
/// **These thresholds are provisional.** They were calibrated against the
/// reference's simulated frames, not against real photographs, and must be
/// re-calibrated on real devices before they are trusted. See the device
/// checklist in `docs/DEVICE_TEST_CHECKLIST.md`.
class QualityThresholds {
  /// Mean luminance below this is "too dark".
  final double darkMean;

  /// Mean luminance above this is "too bright".
  final double brightMean;

  /// Share of clipped highlights above this is "overexposed".
  final double saturatedShare;

  /// Laplacian variance below this is "blurry".
  final double sharpness;

  /// Strong-edge share below this is "low information".
  final double texture;

  /// Angular rate (deg/s) above this is "moving too fast".
  final double motion;

  /// Alignment tolerance in degrees, shared with the guidance layer.
  final double alignmentToleranceDeg;

  const QualityThresholds({
    this.darkMean = 55,
    this.brightMean = 215,
    this.saturatedShare = 0.12,
    this.sharpness = 60,
    this.texture = 0.05,
    this.motion = 8,
    this.alignmentToleranceDeg = 2.5,
  });

  /// The reference's provisional defaults.
  static const QualityThresholds provisional = QualityThresholds();

  QualityThresholds copyWith({
    double? darkMean,
    double? brightMean,
    double? saturatedShare,
    double? sharpness,
    double? texture,
    double? motion,
    double? alignmentToleranceDeg,
  }) => QualityThresholds(
    darkMean: darkMean ?? this.darkMean,
    brightMean: brightMean ?? this.brightMean,
    saturatedShare: saturatedShare ?? this.saturatedShare,
    sharpness: sharpness ?? this.sharpness,
    texture: texture ?? this.texture,
    motion: motion ?? this.motion,
    alignmentToleranceDeg: alignmentToleranceDeg ?? this.alignmentToleranceDeg,
  );
}

/// Warning codes attached to an accepted frame.
class QualityWarning {
  /// The frame is sharp but nearly featureless (a blank wall).
  static const String lowInformation = 'lowinfo';
}

/// Rejection codes.
class QualityRejection {
  static const String motion = 'motion';
  static const String dark = 'dark';
  static const String bright = 'bright';
  static const String blur = 'blur';
  static const String camera = 'camera';
}

/// Outcome of [decideQuality].
class QualityDecision {
  /// False when the frame must be retaken.
  final bool ok;

  /// One of [QualityRejection], or null when accepted.
  final String? code;

  /// [QualityWarning], or null when accepted cleanly.
  final String? warning;

  final String message;

  const QualityDecision({
    required this.ok,
    this.code,
    this.warning,
    required this.message,
  });

  /// True when the frame was accepted but carries a caveat.
  bool get hasWarning => warning != null;

  @override
  String toString() =>
      ok ? 'accept${warning != null ? '($warning)' : ''}' : 'reject($code)';
}

/// Applies the rules in priority order.
///
/// The order matters and is deliberate:
/// 1. **motion** — a moving phone invalidates everything else.
/// 2. **dark** — too dark to judge anything.
/// 3. **bright** — clipped highlights.
/// 4. **low information** — a *sharp blank wall is accepted with a warning*,
///    and is never retried as blur. This is the rule that stops the capture
///    loop from grinding forever against a featureless surface.
/// 5. **blur** — only reached once there is enough texture to judge sharpness.
QualityDecision decideQuality(
  ImageStats q,
  QualityThresholds t, [
  double? motionDegPerSec,
]) {
  if (motionDegPerSec != null && motionDegPerSec > t.motion) {
    return const QualityDecision(
      ok: false,
      code: QualityRejection.motion,
      message: 'Hold still. The phone is moving too fast.',
    );
  }
  if (q.mean < t.darkMean) {
    return const QualityDecision(
      ok: false,
      code: QualityRejection.dark,
      message: 'Image is too dark. Turn on a light or move away from shadow.',
    );
  }
  if (q.mean > t.brightMean || q.saturatedShare > t.saturatedShare) {
    return const QualityDecision(
      ok: false,
      code: QualityRejection.bright,
      message: 'Image is overexposed. Avoid pointing straight into the window.',
    );
  }
  if (q.strongEdgeShare < t.texture) {
    return const QualityDecision(
      ok: true,
      warning: QualityWarning.lowInformation,
      message:
          'Accepted with a warning: this wall has very little visual '
          'detail, so alignment may be difficult.',
    );
  }
  if (q.laplacianVariance < t.sharpness) {
    return const QualityDecision(
      ok: false,
      code: QualityRejection.blur,
      message: 'Image is blurry. Hold still and try again.',
    );
  }
  return const QualityDecision(ok: true, message: 'Frame accepted.');
}
