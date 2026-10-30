import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';

/// The fixed 26-point commercial capture plan.
///
/// Ported from the prototype's target grid `TG`:
/// * Middle ring — pitch 0°, eight frames at 45° yaw (0…315);
/// * Upper ring — pitch +40°, eight frames at 45° yaw;
/// * Lower ring — pitch −40°, eight frames at 45° yaw;
/// * Zenith — pitch +90°, yaw 0;
/// * Nadir — pitch −90°, yaw 0.
///
/// That is exactly 26 views: "8 upper, 8 middle, 8 lower, one zenith and one
/// nadir" — the copy the intro screen shows. There is deliberately no
/// Fibonacci spread and no coverage-repair pass: the prototype's plan is a
/// fixed grid, not a derived one, and the coverage map is drawn from these same
/// 26 directions.
///
/// The grid is independent of the camera field of view — the prototype does not
/// vary the number of views by lens — so [hfovDeg]/[vfovDeg] only annotate each
/// [PlanFrame] (they feed the per-view coverage test, not the count).

/// Ring names in the prototype's order: Middle (0°), Upper (+40°), Lower (−40°).
const List<String> commercialRingNames = <String>[
  'Middle ring',
  'Upper ring',
  'Lower ring',
];

/// Ring pitches, in [commercialRingNames] order, degrees.
const List<double> commercialRingPitchDeg = <double>[0, 40, -40];

/// Frames per ring.
const int commercialRingCount = 8;

/// Builds the fixed 26-point commercial plan.
///
/// [hfovDeg]/[vfovDeg] are the lens the frames are annotated with; they do not
/// change the grid. Returns a [CapturePlan] compatible with the adaptive one, so
/// the rest of the flow (station records, the progress map, the review grid)
/// can consume it unchanged.
CapturePlan plan26({double hfovDeg = 53.669, double vfovDeg = 68}) {
  final frames = <PlanFrame>[];
  for (var r = 0; r < commercialRingPitchDeg.length; r++) {
    final pitch = commercialRingPitchDeg[r];
    for (var k = 0; k < commercialRingCount; k++) {
      frames.add(
        PlanFrame(
          yawDeg: (k * 45).toDouble(),
          pitchDeg: pitch,
          hfovDeg: hfovDeg,
          vfovDeg: vfovDeg,
          ringIndex: r,
          ringName: commercialRingNames[r],
          indexInRing: k,
          countInRing: commercialRingCount,
        ),
      );
    }
  }
  frames.add(
    PlanFrame(
      yawDeg: 0,
      pitchDeg: 90,
      hfovDeg: hfovDeg,
      vfovDeg: vfovDeg,
      isPole: true,
      isZenith: true,
      ringName: 'Zenith · ceiling',
    ),
  );
  frames.add(
    PlanFrame(
      yawDeg: 0,
      pitchDeg: -90,
      hfovDeg: hfovDeg,
      vfovDeg: vfovDeg,
      isPole: true,
      isNadir: true,
      ringName: 'Nadir · floor',
    ),
  );
  for (var i = 0; i < frames.length; i++) {
    frames[i].index = i;
  }

  // Three iso-latitude rings, each covered by 8 columns at 45° spacing.
  final rows = commercialRingPitchDeg
      .map((p) => PlanRow(pitchDeg: p, longitudeWidthDeg: 360))
      .toList();
  for (final row in rows) {
    row.need = commercialRingCount;
    row.count = commercialRingCount;
    row.spacingDeg = 360 / commercialRingCount;
    row.overlap = 0;
  }

  return CapturePlan(
    params: PlanParams(hfovDeg: hfovDeg, vfovDeg: vfovDeg),
    frames: frames,
    rows: rows,
    stats: null,
    checks: const <PlanCheck>[
      PlanCheck('ok', 'Fixed 26-point commercial plan (prototype grid).'),
    ],
    timeSeconds: 0,
    errors: const <String>[],
  );
}
