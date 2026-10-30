/// Projects the 30 world-locked capture markers and the fixed aiming bezel.
///
/// Pure Dart, separate from the Flutter overlay for the same reason
/// `glb_target_scene.dart` is: world-lock, culling, check-mark visibility and the
/// bezel's screen-centred placement are all assertable in a plain test, without
/// a widget tree or a device.
///
/// **The markers are world geometry, the bezel is screen geometry.** Each node
/// is drawn from its world position, facing the station's start point, so
/// turning the phone moves it across the preview exactly like the room does.
/// The `white_frame_bezel.glb` marker is re-planted one metre down the current
/// optical axis on every frame, so it stays centred on the screen and acts as
/// the reticle the 3.0° alignment gate refers to.
library;

import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour_capture_engine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_renderer.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_target_scene.dart';

/// The 30-node scene and its HUD.
class VirtualTourScene {
  VirtualTourScene({
    required this.targetModel,
    required this.bezelModel,
    required this.nodes,
    required this.startPosition,
    required this.startOrientation,
    GlbTargetTopology? topology,
    this.hudDistanceM = arTargetDistanceM,
    this.hudScale = 1.0,
    this.cullMarginDeg = 15,
    this.capturedOpacity = 0.55,
    this.unreliableOpacity = 0.3,
    this.hudOpacity = 0.9,
  }) : topology = topology ?? GlbTargetTopology.from(targetModel),
       _nodePoses = List<GlbTransform>.unmodifiable(<GlbTransform>[
         for (final node in nodes)
           _worldPose(node.worldPosition, startPosition, startOrientation),
       ]);

  final GlbModel targetModel;
  final GlbModel bezelModel;
  final GlbTargetTopology topology;
  final List<VirtualTourNode> nodes;
  final Vec3 startPosition;
  final Quat startOrientation;

  /// How far down the optical axis the HUD bezel is planted.
  final double hudDistanceM;

  /// 1.0 keeps the 0.70 m bezel at its authored size, matching the marker
  /// geometry that sits a metre away on the sphere.
  final double hudScale;

  /// A node whose centre is this far outside the viewport is not projected at
  /// all. The value is chosen so the cull happens where the marker's own
  /// half-width (≈15° at one metre) has already left the screen.
  final double cullMarginDeg;

  /// Captured markers stay visible but recede.
  final double capturedOpacity;

  /// When AR is not tracking, every marker is drawn faintly and grey. The world
  /// positions are untouched: the marker does not jump or follow the phone, it
  /// simply stops claiming to be a reliable world point.
  final double unreliableOpacity;

  static const GlbColor unreliableColor = GlbColor(0.55, 0.58, 0.62);

  final double hudOpacity;

  final List<GlbTransform> _nodePoses;

  static GlbColor get checkMarkColor => GlbTargetScene.checkMarkColor;

  /// The model→world pose of node [index]: on its world point, standing
  /// upright, facing the station's start point.
  GlbTransform nodeTransform(int index) => _nodePoses[index];

  /// The bezel's model→world pose for this camera: one metre straight ahead,
  /// billboarded so its ring faces the lens.
  GlbTransform hudTransform(GlbCamera camera) => glbBillboardTransform(
    target: camera.position + camera.pose.rotate(Vec3.unitZ) * hudDistanceM,
    camera: camera,
    scale: hudScale,
  );

  /// A coarse per-node test, run before the ~536 triangles of a marker are
  /// projected. It is deliberately rectangular: the viewport is rectangular,
  /// and the margin covers the marker's own extent.
  bool isNodeCandidate(GlbCamera camera, VirtualTourNode node) {
    final frame = camera.toCameraFrame(node.worldPosition);
    if (frame.z <= arTargetNearM) return false;
    final maxX = math.tan((camera.hfovDeg / 2 + cullMarginDeg) * degToRad);
    final maxY = math.tan((camera.vfovDeg / 2 + cullMarginDeg) * degToRad);
    return frame.x.abs() <= frame.z * maxX && frame.y.abs() <= frame.z * maxY;
  }

  /// One frame's triangles, in painter's order, with the HUD last.
  ///
  /// [capturedIds] decides the check marks: the asset ships them green, but an
  /// un-captured node must not show a tick. Captured nodes draw them white and
  /// at [capturedOpacity], so "already done" is visible without competing with
  /// the marker the user is aiming at.
  ///
  /// With [trackingAvailable] false the markers are still projected from their
  /// fixed world points — they must not move — but they are dimmed and greyed,
  /// because a marker drawn from a stale pose is no longer trustworthy.
  List<GlbScreenTriangle> triangles({
    required GlbCamera camera,
    required Set<String> capturedIds,
    required ArTargetVisualState hudState,
    bool trackingAvailable = true,
  }) {
    final all = <GlbScreenTriangle>[];
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (!isNodeCandidate(camera, node)) continue;
      final captured = capturedIds.contains(node.id);
      final opacity = trackingAvailable
          ? (captured ? capturedOpacity : 1.0)
          : unreliableOpacity;
      final projected = projectGlb(
        model: targetModel,
        modelToWorld: _nodePoses[i],
        camera: camera,
        nearM: arTargetNearM,
        opacity: opacity,
        recolor: trackingAvailable
            ? _recolorCheckMarks
            : (_) => unreliableColor,
        group: node.id,
        // Deterministic tie-break between different nodes at equal depth.
        groupOrder: 1 + node.index,
      );
      for (final triangle in projected) {
        if (!captured && topology.isCheckMarkDrawable(triangle.drawableIndex)) {
          continue;
        }
        all.add(triangle);
      }
    }
    all.sort(compareGlbDrawOrder);
    // The bezel is a HUD, not a world object: it is appended after the depth
    // sort so nothing on the sphere can ever draw over the reticle.
    all.addAll(
      projectGlb(
        model: bezelModel,
        modelToWorld: hudTransform(camera),
        camera: camera,
        nearM: arTargetNearM,
        opacity: hudOpacity,
        recolor: (_) => GlbColor.fromRgb24(ArTargetColors.forState(hudState)),
        group: 'hud',
        groupOrder: 0,
      ),
    );
    return all;
  }

  GlbColor? _recolorCheckMarks(GlbDrawable drawable) =>
      topology.isCheckMarkPart(drawable) ? checkMarkColor : null;

  static GlbTransform _worldPose(
    Vec3 position,
    Vec3 startPosition,
    Quat startOrientation,
  ) {
    // The marker faces the point the user started from, not the live camera.
    // Otherwise a marker would turn to follow the phone, which is exactly what
    // a world-locked object must not do.
    final startCamera = GlbCamera(
      pose: startOrientation,
      position: startPosition,
      viewportW: 1,
      viewportH: 1,
      hfovDeg: 60,
      vfovDeg: 60,
    );
    return glbBillboardTransform(target: position, camera: startCamera);
  }
}
