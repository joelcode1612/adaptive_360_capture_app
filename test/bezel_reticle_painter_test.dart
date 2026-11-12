import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/presentation/widgets/bezel_reticle.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// A synchronous canvas recorder: records every path paint and its colour,
/// without touching the rasterizer. `CustomPainter.paint` only calls methods
/// on the canvas it is given, so a noSuchMethod proxy is sufficient and the
/// test stays deterministic on every host.
class _RecordingCanvas implements dart_ui.Canvas {
  final List<dart_ui.Paint> paints = <dart_ui.Paint>[];
  int clipCount = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #drawPath:
      case #drawCircle:
        paints.add(invocation.positionalArguments.last as dart_ui.Paint);
        return null;
      case #clipPath:
        clipCount++;
        return null;
      case #save:
      case #restore:
        return null;
    }
    return super.noSuchMethod(invocation);
  }

  /// Whether any path was painted in the completion green.
  bool get drewGreen => paints.any(
    (dart_ui.Paint paint) => _sameColor(paint.color, CaptureColors.ok),
  );

  bool get drewAmber => paints.any(
    (dart_ui.Paint paint) => _sameColor(paint.color, CaptureColors.warn),
  );

  bool get drewWhiteBase => paints.any(
    (dart_ui.Paint paint) =>
        paint.color.a >= 0.9 &&
        (paint.color.r - 0.9569).abs() < 0.003 &&
        (paint.color.g - 0.9569).abs() < 0.003 &&
        (paint.color.b - 0.9569).abs() < 0.003,
  );
}

/// Component-wise colour comparison with a small tolerance.
///
/// This Flutter version stores colours as floats (`a`/`r`/`g`/`b`, 0…1); two
/// colors derived from the same 8-bit constant can round differently through
/// the paint pipeline, so exact `==` is unreliable while the visual result is
/// identical.
bool _sameColor(dart_ui.Color a, dart_ui.Color b) =>
    (a.a - b.a).abs() < 0.003 &&
    (a.r - b.r).abs() < 0.003 &&
    (a.g - b.g).abs() < 0.003 &&
    (a.b - b.b).abs() < 0.003;

/// Builds a synthetic annulus in the same shape class as the shipped
/// `white_frame_bezel.glb`: a rectangular-section torus face in the XY plane
/// with inner 0.270, outer 0.350, front face at +Z.
GlbModel _bezel() {
  const segments = 64;
  const inner = 0.270;
  const outer = 0.350;
  const zFront = 0.012;
  final positions = <Vec3>[];
  for (var i = 0; i < segments; i++) {
    final a0 = i * 2 * math.pi / segments;
    final a1 = (i + 1) * 2 * math.pi / segments;
    Vec3 p(double radius, double angle) =>
        Vec3(radius * math.cos(angle), radius * math.sin(angle), zFront);
    final i0 = p(inner, a0);
    final i1 = p(inner, a1);
    final o0 = p(outer, a0);
    final o1 = p(outer, a1);
    positions
      ..addAll([i0, o0, o1])
      ..addAll([i0, o1, i1]);
  }
  final drawable = GlbDrawable(
    positions: positions,
    normals: const <Vec3>[],
    uv0: Float32List(0),
    vertexColors: const <GlbColor>[],
    color: GlbColor.white,
    doubleSided: false,
    alphaMode: 'OPAQUE',
    transform: GlbTransform.identity,
    meshIndex: 0,
    primitiveIndex: 0,
    nodeName: null,
    min: const Vec3(-outer, -outer, zFront),
    max: const Vec3(outer, outer, zFront),
  );
  return GlbModel(
    drawables: [drawable],
    min: const Vec3(-outer, -outer, zFront),
    max: const Vec3(outer, outer, zFront),
    nodeCount: 1,
    meshCount: 1,
    materialCount: 1,
    accessorCount: 0,
    bufferViewCount: 0,
    unsupported: const <String>[],
    gltfVersion: '2.0',
    generator: null,
  );
}

/// Pumps [build] and returns the reticle painter it installed.
Future<CustomPainter> _pump(WidgetTester tester, WidgetBuilder build) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(builder: build),
    ),
  );
  final renderObject = tester.renderObject<RenderCustomPaint>(
    find.byType(CustomPaint).first,
  );
  return renderObject.painter!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fallback reticle (no GLB asset)', () {
    testWidgets('aligned half-hold paints a clipped green clockwise sweep', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.5,
          withinTolerance: true,
          completed: false,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.clipCount, 1, reason: 'the sweep is clipped to a wedge');
      expect(canvas.drewGreen, isTrue);
    });

    testWidgets('zero progress paints the base ring only', (tester) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0,
          withinTolerance: true,
          completed: false,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewGreen, isFalse);
      expect(canvas.clipCount, 0);
      expect(canvas.drewWhiteBase, isTrue);
    });

    testWidgets('not-aligned ring never shows progress colour', (tester) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.9,
          withinTolerance: false,
          completed: false,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewGreen, isFalse);
      expect(canvas.clipCount, 0);
    });

    testWidgets('a capture blocker paints amber, never progress', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.5,
          withinTolerance: true,
          completed: false,
          captureBlocked: true,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewAmber, isTrue);
      expect(canvas.drewGreen, isFalse);
    });

    testWidgets('completed hold paints the full green ring unclipped', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0,
          withinTolerance: false,
          completed: true,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewGreen, isTrue);
      expect(canvas.clipCount, 0);
    });

    testWidgets('hold-complete confirmation keeps the ring green', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 1,
          withinTolerance: true,
          completed: false,
          holdComplete: true,
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewGreen, isTrue);
      expect(canvas.clipCount, 0);
    });
  });

  group('GLB bezel path', () {
    testWidgets('the same half-hold paints the green sweep on the asset ring', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => BezelReticle(
          size: 80,
          progress: 0.5,
          withinTolerance: true,
          completed: false,
          bezel: _bezel(),
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.clipCount, 1);
      expect(canvas.drewGreen, isTrue);
    });

    testWidgets('the asset ring path traces the shipped annulus', (
      tester,
    ) async {
      final bezel = _bezel();
      expect(bezelAnnulus(bezel).inner, closeTo(0.270, 1e-6));
      expect(bezelAnnulus(bezel).outer, closeTo(0.350, 1e-6));
      final ring = buildBezelRingPath(bezel, size: 80);
      expect(ring.getBounds().width, closeTo(80, 1e-6));
      expect(ring.getBounds().height, closeTo(80, 1e-6));
    });

    testWidgets('hold-complete confirmation also covers the asset ring', (
      tester,
    ) async {
      final painter = await _pump(
        tester,
        (BuildContext context) => BezelReticle(
          size: 80,
          progress: 1,
          withinTolerance: true,
          completed: false,
          holdComplete: true,
          bezel: _bezel(),
        ),
      );
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));
      expect(canvas.drewGreen, isTrue);
      expect(canvas.clipCount, 0);
    });
  });

  group('repaint contract', () {
    testWidgets('identical state does not repaint; progress changes do', (
      tester,
    ) async {
      final first = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.25,
          withinTolerance: true,
          completed: false,
        ),
      );
      final same = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.25,
          withinTolerance: true,
          completed: false,
        ),
      );
      expect(same.shouldRepaint(first), isFalse);

      final progressed = await _pump(
        tester,
        (BuildContext context) => const BezelReticle(
          size: 80,
          progress: 0.5,
          withinTolerance: true,
          completed: false,
        ),
      );
      expect(progressed.shouldRepaint(first), isTrue);
    });
  });
}
