import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour_capture_engine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_renderer.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/overlays/virtual_tour_scene.dart';

const double viewportW = 1000;
const double viewportH = 2000;

GlbCamera cameraFacing(double yawDeg, {double pitchDeg = 0}) => GlbCamera(
  pose: Quat.fromYawPitch(yawDeg, pitchDeg),
  position: Vec3.zero,
  viewportW: viewportW,
  viewportH: viewportH,
  hfovDeg: 60,
  vfovDeg: 90,
);

({double u, double v}) centroid(Iterable<GlbScreenTriangle> triangles) {
  var su = 0.0;
  var sv = 0.0;
  var n = 0;
  for (final t in triangles) {
    su += t.ax + t.bx + t.cx;
    sv += t.ay + t.by + t.cy;
    n += 3;
  }
  expect(n, greaterThan(0));
  return (u: su / n, v: sv / n);
}

({double r, double g, double b}) meanColor(
  Iterable<GlbScreenTriangle> triangles,
) {
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  var n = 0;
  for (final t in triangles) {
    r += t.color.r;
    g += t.color.g;
    b += t.color.b;
    n++;
  }
  expect(n, greaterThan(0));
  return (r: r / n, g: g / n, b: b / n);
}

void main() {
  late GlbModel target;
  late GlbModel bezel;
  late List<VirtualTourNode> nodes;

  setUpAll(() {
    target = parseGlb(
      File(arTargetAssetPath).readAsBytesSync(),
      source: arTargetAssetPath,
    );
    bezel = parseGlb(
      File(arBezelAssetPath).readAsBytesSync(),
      source: arBezelAssetPath,
    );
    nodes = VirtualTourCaptureEngine.atStart(
      position: Vec3.zero,
      orientation: Quat.identity,
    ).nodes;
  });

  VirtualTourScene scene() => VirtualTourScene(
    targetModel: target,
    bezelModel: bezel,
    nodes: nodes,
    startPosition: Vec3.zero,
    startOrientation: Quat.identity,
  );

  List<GlbScreenTriangle> group(List<GlbScreenTriangle> all, String id) =>
      <GlbScreenTriangle>[
        for (final t in all)
          if (t.group == id) t,
      ];

  test('the HUD bezel is centred and painted after every world marker', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(0);
    final all = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );

    final hud = group(all, 'hud');
    expect(hud, isNotEmpty);
    final c = centroid(hud);
    expect(c.u, closeTo(viewportW / 2, 2));
    expect(c.v, closeTo(viewportH / 2, 2));
    expect(all.last.group, 'hud');

    final firstHud = all.indexWhere((t) => t.group == 'hud');
    expect(all.sublist(firstHud).every((t) => t.group == 'hud'), isTrue);

    // The bezel is planted one metre down the optical axis.
    final planted = sceneUnderTest.hudTransform(camera).apply(Vec3.zero);
    expect((planted - camera.position).length, closeTo(1.0, 1e-9));
    expect(planted.z, closeTo(1.0, 1e-9));
  });

  test('turning the phone moves a world marker but not the HUD', () {
    final sceneUnderTest = scene();
    final before = sceneUnderTest.nodeTransform(0);
    final straight = sceneUnderTest.triangles(
      camera: cameraFacing(0),
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );
    final turned = sceneUnderTest.triangles(
      camera: cameraFacing(20),
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );

    // The marker's model→world pose is fixed at the start pose, so it cannot
    // follow the live camera.
    expect(identical(sceneUnderTest.nodeTransform(0), before), isTrue);
    expect(sceneUnderTest.nodeTransform(0).m, before.m);

    final h01Straight = group(straight, 'h01');
    final h01Turned = group(turned, 'h01');
    expect(h01Straight, isNotEmpty);
    expect(h01Turned, isNotEmpty);
    final straightCentre = centroid(h01Straight);
    final turnedCentre = centroid(h01Turned);
    expect(straightCentre.u, closeTo(viewportW / 2, 2));
    expect(straightCentre.v, closeTo(viewportH / 2, 2));
    expect((turnedCentre.u - straightCentre.u).abs(), greaterThan(80));

    final hudTurned = centroid(group(turned, 'hud'));
    expect(hudTurned.u, closeTo(viewportW / 2, 2));
    expect(hudTurned.v, closeTo(viewportH / 2, 2));
  });

  test('markers behind the camera are not projected', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(180);
    final all = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );

    expect(sceneUnderTest.isNodeCandidate(camera, nodes.first), isFalse);
    expect(group(all, 'h01'), isEmpty);
    expect(group(all, 'hud'), isNotEmpty);
  });

  test('the rectangular cull keeps only markers near the viewport', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(0);
    expect(sceneUnderTest.isNodeCandidate(camera, nodes[0]), isTrue); // 0°
    expect(sceneUnderTest.isNodeCandidate(camera, nodes[1]), isTrue); // 30°
    expect(sceneUnderTest.isNodeCandidate(camera, nodes[2]), isFalse); // 60°
  });

  test('captured markers dim and reveal white check marks', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(0);

    final pending = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );
    final pendingH01 = group(pending, 'h01');
    expect(pendingH01, isNotEmpty);
    final pendingChecks = pendingH01.where(
      (t) => sceneUnderTest.topology.isCheckMarkDrawable(t.drawableIndex),
    );
    expect(pendingChecks, isEmpty);
    final pendingPlate = pendingH01.firstWhere(
      (t) => !sceneUnderTest.topology.isCheckMarkDrawable(t.drawableIndex),
    );
    expect(pendingPlate.color.a, closeTo(1.0, 1e-9));

    final captured = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{'h01'},
      hudState: ArTargetVisualState.idle,
    );
    final capturedH01 = group(captured, 'h01');
    expect(capturedH01, isNotEmpty);
    final checks = capturedH01
        .where(
          (t) => sceneUnderTest.topology.isCheckMarkDrawable(t.drawableIndex),
        )
        .toList();
    expect(checks, isNotEmpty);
    for (final check in checks) {
      // White after recolouring: the three channels stay equal under shading.
      expect(check.color.r, closeTo(check.color.g, 1e-9));
      expect(check.color.g, closeTo(check.color.b, 1e-9));
    }
    final plate = capturedH01.firstWhere(
      (t) => !sceneUnderTest.topology.isCheckMarkDrawable(t.drawableIndex),
    );
    expect(plate.color.a, closeTo(0.55, 1e-9));
  });

  test('tracking loss dims and greys markers without moving them', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(0);

    final reliable = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
    );
    final unreliable = sceneUnderTest.triangles(
      camera: camera,
      capturedIds: const <String>{},
      hudState: ArTargetVisualState.idle,
      trackingAvailable: false,
    );

    final reliableH01 = group(reliable, 'h01');
    final unreliableH01 = group(unreliable, 'h01');
    expect(unreliableH01.length, reliableH01.length);
    final reliableCentre = centroid(reliableH01);
    final unreliableCentre = centroid(unreliableH01);
    expect(unreliableCentre.u, closeTo(reliableCentre.u, 1e-6));
    expect(unreliableCentre.v, closeTo(reliableCentre.v, 1e-6));

    // Recolouring is to one fixed grey, so every triangle keeps the same
    // channel ratios; lighting may only scale all three together.
    final grey = VirtualTourScene.unreliableColor;
    for (final triangle in unreliableH01) {
      expect(triangle.color.a, closeTo(0.3, 1e-9));
      expect(
        triangle.color.g / triangle.color.r,
        closeTo(grey.g / grey.r, 1e-6),
      );
      expect(
        triangle.color.b / triangle.color.g,
        closeTo(grey.b / grey.g, 1e-6),
      );
    }

    // The HUD is screen geometry, not world geometry: it stays crisp and
    // keeps the guidance colour even while the world markers are unreliable.
    final hud = group(unreliable, 'hud');
    expect(hud, isNotEmpty);
    for (final triangle in hud) {
      expect(triangle.color.a, closeTo(0.9, 1e-9));
    }
  });

  test('the HUD takes the colour of the guidance state', () {
    final sceneUnderTest = scene();
    final camera = cameraFacing(0);

    ({double r, double g, double b}) hudFor(ArTargetVisualState state) {
      final all = sceneUnderTest.triangles(
        camera: camera,
        capturedIds: const <String>{},
        hudState: state,
      );
      return meanColor(group(all, 'hud'));
    }

    final idle = hudFor(ArTargetVisualState.idle);
    expect(idle.r, closeTo(idle.g, 1e-9));
    expect(idle.g, closeTo(idle.b, 1e-9));

    final aligned = hudFor(ArTargetVisualState.aligned);
    expect(aligned.g, greaterThan(aligned.r));
    expect(aligned.g, greaterThan(aligned.b));

    final failed = hudFor(ArTargetVisualState.failed);
    expect(failed.r, greaterThan(failed.g));
    expect(failed.g, greaterThan(failed.b));

    expect(math.max(idle.r, math.max(idle.g, idle.b)), greaterThan(0));
  });
}
