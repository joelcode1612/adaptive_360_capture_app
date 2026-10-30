import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/data/services/glb_mesh_source.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/widgets/bezel_reticle.dart';

/// The reticle is drawn from the shipped bezel, so these tests check the asset
/// rather than a hand-written circle.
Future<ByteData> _loadFromDisk(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

void main() {
  late GlbMeshSource meshes;

  setUpAll(() async {
    meshes = await GlbMeshSource.load(loader: _loadFromDisk);
  });

  group('bezelAnnulus', () {
    test('reads the ring radii from the asset, not from a constant', () {
      final a = bezelAnnulus(meshes.bezelModel);
      expect(a.inner, closeTo(0.270, 1e-4));
      expect(a.outer, closeTo(0.350, 1e-4));
      // The band is 80 mm wide, which is what makes it read as a frame.
      expect(a.outer - a.inner, closeTo(0.080, 1e-4));
    });
  });

  group('buildBezelRingPath', () {
    test('fills the box and is centred on it', () {
      const size = 200.0;
      final path = buildBezelRingPath(meshes.bezelModel, size: size);
      expect(path.getBounds().isEmpty, isFalse);

      final b = path.getBounds();
      // Outer radius maps to half the box, so the bounds are the box.
      expect(b.left, closeTo(0, 1.0));
      expect(b.top, closeTo(0, 1.0));
      expect(b.width, closeTo(size, 1.0));
      expect(b.height, closeTo(size, 1.0));
    });

    test('is hollow: the centre is not filled', () {
      const size = 200.0;
      final path = buildBezelRingPath(meshes.bezelModel, size: size);
      expect(
        path.contains(const Offset(100, 100)),
        isFalse,
        reason: 'a ring must not fill its own hole',
      );
    });

    test('the band itself is filled', () {
      const size = 200.0;
      final path = buildBezelRingPath(meshes.bezelModel, size: size);
      // Mid-band: r = (0.270 + 0.350) / 2 = 0.310 m, scaled by 0.310 / 0.350.
      final x = 100 + (0.310 / 0.350) * 100;
      expect(path.contains(Offset(x, 100)), isTrue);
    });

    test('is cached per model and size', () {
      final a = buildBezelRingPath(meshes.bezelModel, size: 120);
      final b = buildBezelRingPath(meshes.bezelModel, size: 120);
      final c = buildBezelRingPath(meshes.bezelModel, size: 160);
      expect(identical(a, b), isTrue, reason: 'same size must reuse the path');
      expect(identical(a, c), isFalse, reason: 'a new size must rebuild');
    });
  });

  group('BezelReticle', () {
    testWidgets('draws the ring without throwing', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: BezelReticle(
                size: 78,
                progress: 0.5,
                withinTolerance: true,
                completed: false,
                bezel: meshes.bezelModel,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to a circle before the asset loads', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: BezelReticle(
                size: 78,
                progress: 0,
                withinTolerance: false,
                completed: false,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the completed state', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: BezelReticle(
                size: 78,
                progress: 1,
                withinTolerance: true,
                completed: true,
                bezel: meshes.bezelModel,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
