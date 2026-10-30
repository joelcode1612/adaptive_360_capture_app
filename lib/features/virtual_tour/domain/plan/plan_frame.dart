import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// One planned capture direction.
///
/// Ported from the frame objects built by `planAll` and `fill` in the
/// reference. Every frame carries its own field of view, because the plan is
/// generated from the camera's *real* intrinsics rather than a constant.
class PlanFrame {
  final double yawDeg;
  final double pitchDeg;

  /// Horizontal field of view of the camera that will shoot this frame.
  final double hfovDeg;

  /// Vertical field of view of the camera that will shoot this frame.
  final double vfovDeg;

  /// Index into `CapturePlan.rows`; null for the pole frames and repairs.
  final int? row;

  final bool isPole;
  final bool isZenith;
  final bool isNadir;

  /// True for frames added by the coverage repair pass.
  final bool isRepair;

  /// Ring metadata for the fixed commercial plan (the prototype's `TG`).
  ///
  /// `null` for a frame the adaptive planner produced; set for every frame of
  /// the fixed 26-point grid so the progress map and the capture counter can
  /// read the ring name and the "k of c" ordinal exactly as the prototype shows.
  final int? ringIndex;
  final String? ringName;
  final int? indexInRing;
  final int? countInRing;

  /// Assigned by `planAll` once the final ordering is known.
  int index = -1;

  PlanFrame({
    required this.yawDeg,
    required this.pitchDeg,
    required this.hfovDeg,
    required this.vfovDeg,
    this.row,
    this.isPole = false,
    this.isZenith = false,
    this.isNadir = false,
    this.isRepair = false,
    this.ringIndex,
    this.ringName,
    this.indexInRing,
    this.countInRing,
  });

  /// The unit direction vector this frame aims at.
  ///
  /// Every target exposes one, so no downstream code ever converts back to a
  /// yaw/pitch pair — which is what removes the pole special cases.
  Vec3 get direction => isPole
      ? (isZenith ? Vec3.unitY : -Vec3.unitY)
      : directionFromYawPitch(yawDeg, pitchDeg);

  @override
  String toString() =>
      'PlanFrame(yaw: $yawDeg, pitch: $pitchDeg'
      '${isZenith ? ', zenith' : ''}${isNadir ? ', nadir' : ''}'
      '${isRepair ? ', repair' : ''})';
}
