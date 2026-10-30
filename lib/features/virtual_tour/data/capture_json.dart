import 'dart:convert';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/station_anchor.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/image_analysis.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// JSON codec for the domain types that have to survive a process restart.
///
/// The codec lives here, not in `domain/`, on purpose: the domain layer stays
/// free of any wire or file format, so the persistence schema can change without
/// touching the engine that the tests pin.
///
/// Two rules this file follows everywhere:
///
/// * **Never invent a value.** A field that was not measured is written as
///   `null` and read back as `null`, so "unknown" never turns into `0.0`.
/// * **Doubles that JSON cannot represent are nulled.** `jsonEncode` throws on
///   `NaN` and `Infinity`; a malformed frame must not take the whole session
///   manifest down with it, so they are normalised to `null` first.
const int captureSchemaVersion = 1;

/// JSON-safe double: `null` for NaN/Infinity.
double? jDouble(double? v) => v == null || v.isNaN || v.isInfinite ? null : v;

List<double> jVec(Vec3 v) => <double>[
  jDouble(v.x)!,
  jDouble(v.y)!,
  jDouble(v.z)!,
];

Vec3 vecFromJson(Object? o) {
  final l = (o! as List).cast<num>();
  return Vec3(l[0].toDouble(), l[1].toDouble(), l[2].toDouble());
}

Vec3? vecOrNull(Object? o) => o == null ? null : vecFromJson(o);

List<double> jQuat(Quat q) => <double>[
  jDouble(q.x)!,
  jDouble(q.y)!,
  jDouble(q.z)!,
  jDouble(q.w)!,
];

Quat quatFromJson(Object? o) {
  final l = (o! as List).cast<num>();
  return Quat(
    l[0].toDouble(),
    l[1].toDouble(),
    l[2].toDouble(),
    l[3].toDouble(),
  );
}

Quat? quatOrNull(Object? o) => o == null ? null : quatFromJson(o);

Map<String, Object?> jPlanParams(PlanParams p) => <String, Object?>{
  'hfovDeg': jDouble(p.hfovDeg),
  'vfovDeg': jDouble(p.vfovDeg),
  'overlapH': jDouble(p.overlapH),
  'overlapV': jDouble(p.overlapV),
  'pattern': p.pattern,
  'yaw0Deg': jDouble(p.yaw0Deg),
  'repair': p.repair,
  'quality': p.quality,
  'budgetMinutes': jDouble(p.budgetMinutes),
  'turnSpeedDegPerSec': jDouble(p.turnSpeedDegPerSec),
  'settleMs': p.settleMs,
  'maxRetry': p.maxRetry,
  'clearanceM': jDouble(p.clearanceM),
};

PlanParams planParamsFromJson(Map<String, Object?> m) => PlanParams(
  hfovDeg: (m['hfovDeg']! as num).toDouble(),
  vfovDeg: (m['vfovDeg']! as num).toDouble(),
  overlapH: (m['overlapH']! as num).toDouble(),
  overlapV: (m['overlapV']! as num).toDouble(),
  pattern: m['pattern']! as String,
  yaw0Deg: (m['yaw0Deg']! as num).toDouble(),
  repair: m['repair']! as bool,
  quality: m['quality']! as String,
  budgetMinutes: (m['budgetMinutes']! as num).toDouble(),
  turnSpeedDegPerSec: (m['turnSpeedDegPerSec']! as num).toDouble(),
  settleMs: (m['settleMs']! as num).toInt(),
  maxRetry: (m['maxRetry']! as num).toInt(),
  clearanceM: (m['clearanceM']! as num).toDouble(),
);

Map<String, Object?> jStats(ImageStats s) => <String, Object?>{
  'mean': jDouble(s.mean),
  'darkShare': jDouble(s.darkShare),
  'saturatedShare': jDouble(s.saturatedShare),
  'laplacianVariance': jDouble(s.laplacianVariance),
  'gradientMean': jDouble(s.gradientMean),
  'strongEdgeShare': jDouble(s.strongEdgeShare),
  'entropy': jDouble(s.entropy),
};

ImageStats statsFromJson(Map<String, Object?> m) => ImageStats(
  mean: (m['mean']! as num).toDouble(),
  darkShare: (m['darkShare']! as num).toDouble(),
  saturatedShare: (m['saturatedShare']! as num).toDouble(),
  laplacianVariance: (m['laplacianVariance']! as num).toDouble(),
  gradientMean: (m['gradientMean']! as num).toDouble(),
  strongEdgeShare: (m['strongEdgeShare']! as num).toDouble(),
  entropy: (m['entropy']! as num).toDouble(),
);

Map<String, Object?> jStationOrigin(StationOrigin o) => <String, Object?>{
  'worldPosition': jVec(o.worldPosition),
  'lockYawDeg': jDouble(o.lockYawDeg),
  'lockCameraHeightM': jDouble(o.lockCameraHeightM),
  'confidence': o.confidence.name,
};

StationOrigin stationOriginFromJson(Map<String, Object?> m) => StationOrigin(
  worldPosition: vecFromJson(m['worldPosition']),
  lockYawDeg: (m['lockYawDeg']! as num).toDouble(),
  lockCameraHeightM: (m['lockCameraHeightM']! as num).toDouble(),
  confidence: StationConfidence.values.byName(m['confidence']! as String),
);

/// The evidence for one accepted frame.
///
/// [manual] and [attempts] are recorded because the summary and the review
/// screen both need them after a restart, and re-deriving them would be a lie.
Map<String, Object?> jAcceptedFrame(AcceptedFrame f) => <String, Object?>{
  'index': f.index,
  'targetYawDeg': jDouble(f.targetYawDeg),
  'targetPitchDeg': jDouble(f.targetPitchDeg),
  'hfovDeg': jDouble(f.hfovDeg),
  'vfovDeg': jDouble(f.vfovDeg),
  'warning': f.warning,
  'manual': f.manual,
  'attempts': f.attempts,
  'shifted': f.shifted,
  'lost': f.lost,
  'stats': jStats(f.stats),
  'pose': f.pose == null ? null : jQuat(f.pose!),
  'direction': jVec(f.direction),
  'errorDeg': jDouble(f.errorDeg),
  'axis': f.axis == null ? null : jVec(f.axis!),
  'axisDegenerate': f.axisDegenerate,
  'targetIsPole': f.targetIsPole,
  'mirror': f.mirror,
  'near': f.near,
  'savedAt': f.savedAt?.toIso8601String(),
};

AcceptedFrame acceptedFrameFromJson(
  Map<String, Object?> m, {
  required int viewpointIndex,
}) => AcceptedFrame(
  viewpointIndex: viewpointIndex,
  index: (m['index']! as num).toInt(),
  targetYawDeg: (m['targetYawDeg']! as num).toDouble(),
  targetPitchDeg: (m['targetPitchDeg']! as num).toDouble(),
  hfovDeg: (m['hfovDeg']! as num).toDouble(),
  vfovDeg: (m['vfovDeg']! as num).toDouble(),
  warning: m['warning'] as String?,
  manual: m['manual']! as bool,
  attempts: (m['attempts']! as num).toInt(),
  shifted: m['shifted']! as bool,
  lost: m['lost']! as bool,
  stats: statsFromJson((m['stats']! as Map).cast<String, Object?>()),
  pose: quatOrNull(m['pose']),
  direction: vecFromJson(m['direction']),
  errorDeg: (m['errorDeg'] as num?)?.toDouble(),
  axis: vecOrNull(m['axis']),
  axisDegenerate: m['axisDegenerate'] as bool?,
  targetIsPole: m['targetIsPole']! as bool,
  mirror: m['mirror']! as bool,
  near: m['near']! as bool,
  savedAt: switch (m['savedAt']) {
    final String iso => DateTime.tryParse(iso),
    _ => null,
  },
);

/// Pretty-printed JSON, with a trailing newline so the file is diff-friendly.
String prettyJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
