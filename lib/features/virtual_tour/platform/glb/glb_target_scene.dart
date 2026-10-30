/// Turns the two parsed capture models into the triangles the guidance UI draws.
///
/// Pure Dart, and separate from `glb_target_overlay.dart` for the same reason
/// `camera_preview.dart` is split from `capture_camera.dart`: the behaviour the
/// brief pins — per-state bezel colour, check visibility, the out-of-view
/// opacity, screen placement, the sign conventions — has to be assertable in a
/// plain `dart` run, and only the pixels-on-screen part needs a Flutter binding.
///
/// This is the implementation of the [ArTargetRenderer] seam that
/// `ar_target_model.dart` declared: [setVisible], [placeTarget] and [apply]
/// mean exactly what they meant there, so the Flutter widget below it is a
/// loader plus a painter.
library;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_renderer.dart';

/// What a part of `ar_capture_target.glb` is, keyed by glTF mesh index as
/// recorded in [ArTargetModel]:
///
/// * 0 — the white base plate (≈0.54 m),
/// * 1 — the green centre square (≈0.20 m),
/// * 2 and 3 — the two check-mark boxes (visible only on `done`).
///
/// The asset is anonymous — its nodes carry no `name` — so the mesh index is the
/// only handle available. [GlbTargetTopology] therefore falls back to "every
/// part is just the target" when the part count is not four, rather than drawing
/// a check mark as a plate.
enum ArTargetPartRole { plate, center, checkMark, other }

/// Which part of the target model is which, plus the self-check that the asset
/// on disk is still the asset the spec was written against.
class GlbTargetTopology {
  /// One role per entry of [GlbModel.drawables], in order.
  final List<ArTargetPartRole> roles;

  /// True only for the four-part asset the spec describes.
  final bool isSpecLayout;

  GlbTargetTopology._(this.roles, this.isSpecLayout);

  factory GlbTargetTopology.from(GlbModel targetModel) {
    final isSpec = targetModel.drawables.length == 4;
    return GlbTargetTopology._(<ArTargetPartRole>[
      for (final d in targetModel.drawables)
        if (!isSpec)
          ArTargetPartRole.other
        else if (d.meshIndex == 0)
          ArTargetPartRole.plate
        else if (d.meshIndex == 1)
          ArTargetPartRole.center
        else
          ArTargetPartRole.checkMark,
    ], isSpec);
  }

  ArTargetPartRole roleOfDrawable(int drawableIndex) =>
      drawableIndex >= 0 && drawableIndex < roles.length
      ? roles[drawableIndex]
      : ArTargetPartRole.other;

  bool isCheckMarkDrawable(int drawableIndex) =>
      roleOfDrawable(drawableIndex) == ArTargetPartRole.checkMark;

  /// The same decision from the part itself, for the recolour hook.
  bool isCheckMarkPart(GlbDrawable drawable) =>
      isSpecLayout && (drawable.meshIndex == 2 || drawable.meshIndex == 3);

  /// Do the measured bounds still agree with [ArTargetModel] and
  /// [ArBezelModel]? When this is false the asset has changed under the spec and
  /// the UI says so instead of drawing something wrong.
  static bool targetMatchesSpec(GlbModel target, {double tolerance = 2e-3}) {
    if (target.drawables.length != 4) return false;
    final plate = target.drawables[0];
    final center = target.drawables[1];
    return _near(plate.widthX, ArTargetModel.baseHalfExtentM * 2, tolerance) &&
        _near(plate.heightY, ArTargetModel.baseHalfExtentM * 2, tolerance) &&
        _near(center.widthX, ArTargetModel.centerHalfExtentM * 2, tolerance) &&
        _near(center.heightY, ArTargetModel.centerHalfExtentM * 2, tolerance) &&
        target.drawables[2].max.z >= 0.018 - tolerance &&
        target.drawables[3].max.z >= 0.018 - tolerance &&
        target.drawables[2].min.z >= center.max.z - tolerance;
  }

  static bool bezelMatchesSpec(GlbModel bezel, {double tolerance = 2e-3}) =>
      _near(bezel.widthX, ArBezelModel.halfExtentM * 2, tolerance) &&
      _near(bezel.heightY, ArBezelModel.halfExtentM * 2, tolerance);

  static bool _near(double a, double b, double tol) => (a - b).abs() <= tol;
}

/// How far the bezel is pushed behind the target plate, in model units (metres).
///
/// **Derived, not tuned.** The two assets are concentric and their radii meet:
///
/// ```
/// plate : disc   r 0 → 0.270,  z 0 → 0.006,  centre (0, 0)
/// bezel : torus  r 0.270 → 0.350, z 0 → 0.012,  centre (0, 0)
/// green : disc   r 0 → 0.100,  z 0 → 0.012
/// checks: 2 cuboids             z 0.012 → 0.018
/// ```
///
/// So the ring *surrounds* the plate and the two never overlap in x/y — they abut
/// on the circle `r = 0.270`. The only coincident surfaces are the bezel's inner
/// wall and the plate's rim, both cylinders at that radius, and they are edge-on
/// to the viewer.
///
/// The bezel's front face sits at `z = 0.012` and the plate's at `z = 0.006`, so
/// the setback that makes them **flush** is exactly the difference:
///
/// ```
/// 0.012 − 0.006 = 0.006
/// ```
///
/// That is what this value is. Flush means no gap and no step at the join, which
/// is what the reference shows. A smaller value makes the ring stand 6 mm proud;
/// a larger one recesses it.
///
/// **Why exactly this value, and not merely a small one.** Recessing the ring
/// pushes it away from the viewer, so it projects *smaller* than the plate in
/// front of it. That does not open daylight — it makes the nearer plate overlap
/// the ring's inner edge. The error crosses zero at one point:
///
/// ```
/// setback 0.020 → plate overlaps the ring by 3.8 mm
/// setback 0.014 → overlaps by 2.2 mm
/// setback 0.006 → exact: neither gap nor overlap
/// setback 0.002 → a 1.1 mm ring of daylight
/// setback 0.000 → a 1.7 mm ring of daylight
/// ```
///
/// 0.006 is that crossover, and it is the same number as `0.012 − 0.006` for the
/// obvious reason: at the crossover the two front faces are coplanar.
///
/// The previous value of 20 mm was justified by the claim that 120 bezel
/// triangles lie inside the plate's footprint. They do not — those triangles are
/// the inner wall, whose centroid radius is 0.2697 rather than 0.270, a rounding
/// artifact rather than overlap. Its real effect was 3.8 mm of the plate sitting
/// on top of the ring, which is the "incorrect overlap" this now removes.
const double arBezelSetbackM = 0.006;

/// The depth the marker sits at when the guidance UI pins it to a screen
/// position. One metre makes the assets' own metre scale read at roughly the
/// size the prototype's CSS placed it.
const double arTargetDistanceM = 1.0;

/// The §6 arrangement: the two GLB models over the camera preview, driven by
/// [ArTargetRenderState] and the projected aim point.
class GlbTargetScene implements ArTargetRenderer {
  final GlbModel targetModel;
  final GlbModel bezelModel;
  final GlbTargetTopology topology;

  bool _visible = true;
  ArTargetRenderState _state = const ArTargetRenderState(
    state: ArTargetVisualState.idle,
  );

  double _screenX = 0;
  double _screenY = 0;
  double _scale = 1;
  double _tiltXDeg = 0;
  double _tiltYDeg = 0;
  bool _placed = false;

  GlbTargetScene({
    required this.targetModel,
    required this.bezelModel,
    GlbTargetTopology? topology,
  }) : topology = topology ?? GlbTargetTopology.from(targetModel);

  ArTargetRenderState get state => _state;
  bool get isVisible => _visible;
  bool get isPlaced => _placed;

  /// Where [placeTarget] put the marker, in logical pixels.
  double get screenX => _screenX;
  double get screenY => _screenY;
  double get modelScale => _scale;
  double get tiltXDeg => _tiltXDeg;
  double get tiltYDeg => _tiltYDeg;

  /// The white the prototype paints the checks with on `done`. The asset ships
  /// them green, so this is an override, exactly as `glUpd()` did.
  static GlbColor get checkMarkColor => GlbColor.fromRgb24(ArTargetColors.idle);

  /// The bezel tint for the current state, from
  /// [ArTargetRenderState.bezelColor]: white / green-tint / amber.
  GlbColor get bezelColor => GlbColor.fromRgb24(_state.bezelColor);

  // ── ArTargetRenderer ────────────────────────────────────────────────────

  @override
  void setVisible(bool visible) => _visible = visible;

  @override
  void placeTarget({
    required double screenX,
    required double screenY,
    required double scale,
    required double rotXDeg,
    required double rotYDeg,
  }) {
    _screenX = screenX;
    _screenY = screenY;
    _scale = scale;
    _tiltXDeg = rotXDeg;
    _tiltYDeg = rotYDeg;
    _placed = true;
  }

  @override
  void apply(ArTargetRenderState state) => _state = state;

  // ── placement ───────────────────────────────────────────────────────────

  /// The world point the marker is pinned to: pixel `(screenX, screenY)` on the
  /// camera's pinhole sphere, at [distanceM]. The inverse pinhole lives in
  /// [GlbCamera.pixelDirection], so this agrees with `project()` by
  /// construction — the 3D marker and the guidance wording cannot disagree
  /// about where the target is.
  Vec3 markerCentre(GlbCamera camera, {double? distanceM}) =>
      camera.position +
      camera.pixelDirection(_screenX, _screenY) * (distanceM ?? _distanceM);

  double _distanceM = arTargetDistanceM;

  /// The plate's model→world pose: centred on the aim pixel, facing the camera,
  /// with the prototype's head-tilt angles applied in the plate's own frame.
  GlbTransform plateToWorld(
    GlbCamera camera, {
    double? distanceM,
    double? scale,
  }) => glbBillboardTransform(
    target: markerCentre(camera, distanceM: distanceM),
    camera: camera,
    tiltXDeg: _tiltXDeg,
    tiltYDeg: _tiltYDeg,
    scale: scale ?? _scale,
  );

  /// The bezel's pose: the plate's, recessed along the plate's own normal.
  GlbTransform bezelToWorld(
    GlbCamera camera, {
    double? distanceM,
    double? scale,
  }) => plateToWorld(
    camera,
    distanceM: distanceM,
    scale: scale,
  ).then(GlbTransform.trs(translation: Vec3(0, 0, -arBezelSetbackM)));

  /// Target recolour: the asset's own plate and centre colours are preserved,
  /// only the check marks are turned white.
  GlbColor? recolorTarget(GlbDrawable drawable) =>
      topology.isCheckMarkPart(drawable) ? checkMarkColor : null;

  /// The bezel is a single part and always takes the state colour.
  GlbColor? recolorBezel(GlbDrawable drawable) => bezelColor;

  /// True when the marker the UI just pinned to `[screenX, screenY]` is not in
  /// front of the camera at all.
  ///
  /// `placeTarget` is fed by `project()`, which clamps a target behind you to
  /// the screen edge, so without this guard the 3D marker would be placed on a
  /// ray that no longer points at the real target. The overlay answers by
  /// drawing nothing and handing the edge marker to the 2D fallback, which is
  /// what the brief's "not only on a separate screen / handle failure" pair
  /// asks for.
  bool isMarkerBehindCamera(GlbCamera camera, {double? distanceM}) {
    final centre = markerCentre(camera, distanceM: distanceM);
    return camera.toCameraFrame(centre).z <= arTargetNearM;
  }

  /// Projected triangles for the current state, in draw order (far first).
  ///
  /// Returns nothing when hidden, when unplaced, or when the marker is behind
  /// the camera — the case the brief calls out: the geometry has to vanish, not
  /// splat inside-out.
  List<GlbScreenTriangle> triangles({
    required GlbCamera camera,
    double? distanceM,
  }) {
    _distanceM = distanceM ?? arTargetDistanceM;
    if (!_visible || !_placed) return const <GlbScreenTriangle>[];
    if (isMarkerBehindCamera(camera, distanceM: _distanceM)) {
      return const <GlbScreenTriangle>[];
    }

    final plate = plateToWorld(camera, distanceM: _distanceM);
    final target = projectGlb(
      model: targetModel,
      modelToWorld: plate,
      camera: camera,
      opacity: _state.targetOpacity,
      nearM: arTargetNearM,
      recolor: recolorTarget,
      group: 'target',
      groupOrder: 1,
    ).where((GlbScreenTriangle t) => _drawnNow(t.drawableIndex));

    final bezel = projectGlb(
      model: bezelModel,
      modelToWorld: bezelToWorld(camera, distanceM: _distanceM),
      camera: camera,
      nearM: arTargetNearM,
      recolor: recolorBezel,
      group: 'bezel',
      groupOrder: 0,
    );

    final all = <GlbScreenTriangle>[...bezel, ...target];
    all.sort(compareGlbDrawOrder);
    return all;
  }

  /// Check marks appear only on `done`; the rest of the target group always
  /// draws.
  bool _drawnNow(int drawableIndex) =>
      _state.showChecks || !topology.isCheckMarkDrawable(drawableIndex);
}

/// The nearest geometry this renderer will draw, in metres.
///
/// Matched to `project()`'s `dc.z > 0.0001` test in
/// `domain/guidance/projection.dart`: a target closer than this to the lens is
/// either out of focus or between the lens and the wall, and drawing it would
/// flood the screen.
const double arTargetNearM = 0.05;
