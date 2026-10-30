import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// Pure-Dart view geometry for the sphere coverage map and the per-view frame
/// grid.
///
/// No Flutter import. Everything here is numbers, records and enums so the
/// plain-`dart` suite can verify the conventions the painters draw with — the
/// two painters used to recompute these inline, which meant a flipped axis or a
/// swapped colour role would only surface on a device.
///
/// Ported from the map drawing in `adaptive_360_realistic_test.html`.
class SphereProjection {
  /// Orthographic projection of a unit direction onto the coverage map, looking
  /// straight down the world −Z axis.
  ///
  /// The map is a disc: a direction `(x, y, z)` lands at the XY point `(x, y)`
  /// — the z component is the depth into / out of the screen and is dropped, as an
  /// orthographic projection must. The returned coordinates are in a unit disc
  /// with **+X right and +Y up**, so [Vec3.unitY] (straight up) is at the top of
  /// the map and [Vec3.unitZ] (the forward optical axis) is at the centre.
  ///
  /// The painter applies the canvas translate / scale; this function is only the
  /// projection convention, which is exactly the part that must not silently
  /// flip. It is the same handedness the plan, the coverage test and the
  /// alignment angle all use (yaw 0° → +Z, +Y up).
  ///
  /// Returns unit-disc coords with +X right and +Y up. The z component (depth)
  /// is dropped. [Vec3.unitY] → `(0, 1)` (top), [Vec3.unitZ] → `(0, 0)` (centre).
  static (double x, double y) project(Vec3 v) => (v.x, v.y);

  /// Maps a unit-disc point to canvas pixels (y grows downward) for a disc of
  /// [radius] centred at ([centerX], [centerY]).
  ///
  /// The painter calls this immediately after [project], so all of the geometry
  /// lives here and the painter is left as a sequence of `drawCircle` calls.
  static (double cx, double cy) toCanvas(
    (double, double) p,
    double centerX,
    double centerY,
    double radius,
  ) => (centerX + p.$1 * radius, centerY - p.$2 * radius);
}

/// The colour role a planned frame's status maps to on the sphere map and the
/// frame grid.
///
/// `neutral` is *not* a colour — it is the role the painters fill with whatever
/// muted tone suits their surface (the map uses the outline colour, the grid
/// uses [CaptureColors.frameCellEmpty]). Keeping the role here, away from
/// Flutter, means the status → role decision is one tested switch instead of two
/// inline switches that can drift apart.
enum SphereDotRole { ok, warn, neutral }

/// The role each [TargetStatus] draws as on the coverage map and the grid.
///
/// Exhaustive over [TargetStatus]: if a status is added, the compiler forces
/// this to be updated, which is the guard against a silently-uncovered frame.
SphereDotRole sphereDotRole(TargetStatus status) => switch (status) {
  TargetStatus.ok => SphereDotRole.ok,
  TargetStatus.skipped => SphereDotRole.warn,
  TargetStatus.pending => SphereDotRole.neutral,
};
