import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/data/services/glb_mesh_source.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_target_scene.dart';

/// The real shipped assets, through the real parser and the real flattening step.
///
/// Everything here is measured against the bytes in `assets/models/`, not against
/// a fixture. The numbers were taken from the glTF JSON chunks themselves:
///
/// ```
/// ar_capture_target.glb   nodes 4, meshes 4, materials 4
///   mesh 0  130 verts, 256 tris, POSITION only, indexed, baseColor 0.95 grey
///   mesh 1  130 verts, 256 tris, POSITION only, indexed, baseColor 0.30 0.69 0.31
///   mesh 2    8 verts,  12 tris, POSITION only, indexed, baseColor 0.30 0.69 0.31
///   mesh 3    8 verts,  12 tris, POSITION only, indexed, baseColor 0.30 0.69 0.31
///   no textures, no images, no UVs, no normals, no COLOR_0, no node transforms
/// white_frame_bezel.glb   nodes 1, meshes 1
///   mesh 0  256 verts, 512 tris, POSITION only, indexed, baseColor 0.95 grey
/// ```
///
/// A non-zero triangle count is not proof of visibility, but these are the
/// numbers that must reach the native renderer, and they are the numbers a
/// regression would change.
Future<ByteData> _loadFromDisk(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

void main() {
  late GlbMeshSource meshes;

  setUpAll(() async {
    meshes = await GlbMeshSource.load(loader: _loadFromDisk);
  });

  test(
    'both asset paths are declared in pubspec.yaml exactly as the code uses',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(arTargetAssetPath, 'assets/models/ar_capture_target.glb');
      expect(arBezelAssetPath, 'assets/models/white_frame_bezel.glb');
      expect(pubspec, contains('- $arTargetAssetPath'));
      expect(pubspec, contains('- $arBezelAssetPath'));
      // And the files are really there, with that exact capitalisation.
      expect(File(arTargetAssetPath).existsSync(), isTrue);
      expect(File(arBezelAssetPath).existsSync(), isTrue);
    },
  );

  test(
    'the target parses into four parts with the expected triangle counts',
    () {
      final target = meshes.targetModel;
      expect(target.drawables.length, 4);
      expect(target.triangleCount, 256 + 256 + 12 + 12);
      expect(
        target.drawables.map((GlbDrawable d) => d.triangleCount).toList(),
        <int>[256, 256, 12, 12],
      );
      expect(target.gltfVersion, '2.0');
      expect(target.unsupported, isEmpty);
    },
  );

  test('the bezel parses into one 512-triangle part', () {
    final bezel = meshes.bezelModel;
    expect(bezel.drawables.length, 1);
    expect(bezel.triangleCount, 512);
  });

  test('indexed geometry is expanded, not dropped', () {
    // 256 triangles indexed from 130 vertices must arrive as 768 loose
    // vertices; if the parser forwarded the index buffer to a renderer that
    // never reads it, the triangle count would be wrong here.
    final plate = meshes.targetModel.drawables[0];
    expect(plate.triangleCount, 256);
    expect(plate.vertexCount, 768);
    expect(plate.positions.length, 768);
    // Every triangle is complete: a multiple of three.
    expect(plate.positions.length % 3, 0);
  });

  test(
    'the uploaded target mesh excludes exactly the two check-mark cuboids',
    () {
      final buffers = meshes.targetBuffers;
      // 256 + 256 triangles, i.e. meshes 0 and 1 only.
      expect(buffers.vertexCount, (256 + 256) * 3);
      expect(buffers.positions.length, buffers.vertexCount * 3);
      expect(buffers.colors.length, buffers.vertexCount * 4);
    },
  );

  test('the uploaded bezel keeps all of its geometry', () {
    final buffers = meshes.bezelBuffers;
    expect(buffers.vertexCount, 512 * 3);
  });

  test(
    'vertex colours come from the materials, because the asset has no others',
    () {
      // The asset carries POSITION only — no COLOR_0 — so the colour of every
      // vertex must be its material's baseColorFactor.
      final plate = meshes.targetModel.drawables[0];
      expect(plate.vertexColors, isEmpty);
      expect(plate.color.r, closeTo(0.95, 1e-6));
      expect(plate.color.g, closeTo(0.95, 1e-6));
      expect(plate.color.b, closeTo(0.95, 1e-6));

      final centre = meshes.targetModel.drawables[1];
      expect(centre.color.r, closeTo(0.30, 1e-6));
      expect(centre.color.g, closeTo(0.69, 1e-6));
      expect(centre.color.b, closeTo(0.31, 1e-6));

      final buffers = meshes.targetBuffers;
      // First vertex of the plate is the plate colour, in 0..1 floats.
      expect(buffers.colors[0], closeTo(0.95, 1e-6));
      expect(buffers.colors[1], closeTo(0.95, 1e-6));
      expect(buffers.colors[2], closeTo(0.95, 1e-6));
      expect(buffers.colors[3], closeTo(1.0, 1e-6)); // alpha
    },
  );

  test('the plate keeps its authored 0.54 m proportions', () {
    final plate = meshes.targetModel.drawables[0];
    expect(plate.widthX, closeTo(ArTargetModel.baseHalfExtentM * 2, 2e-3));
    expect(plate.heightY, closeTo(ArTargetModel.baseHalfExtentM * 2, 2e-3));
    expect(plate.depthZ, closeTo(0.006, 2e-3));
  });

  test('both assets still match the dimensions the spec records', () {
    expect(meshes.matchesSpec(), isTrue);
  });

  test('nothing in either asset needs a feature the renderer lacks', () {
    // Textures, UVs, normals and COLOR_0 are all absent, and every node
    // transform is identity, so a position-only mesh with a flat material is a
    // complete representation — not an approximation.
    for (final model in <GlbModel>[meshes.targetModel, meshes.bezelModel]) {
      for (final drawable in model.drawables) {
        expect(drawable.normals, isEmpty);
        expect(drawable.uv0, isEmpty);
        expect(drawable.vertexColors, isEmpty);
        expect(drawable.transform.isIdentity, isTrue);
        expect(drawable.doubleSided, isTrue);
      }
    }
  });

  test(
    'describe() reports the geometry that actually reached the renderer',
    () {
      expect(meshes.describe(), contains('target 4 parts / 536 tris'));
      expect(meshes.describe(), contains('bezel 512 tris'));
    },
  );

  // ── the composite target ──────────────────────────────────────────────
  //
  // The reference image is a white ring surrounding a white disc with a green
  // centre. That composite only holds if the two assets are concentric and their
  // radii meet, so those two facts are asserted rather than assumed.

  group('the composite target geometry', () {
    double maxRadiusOf(GlbDrawable d) => d.positions
        .map((p) => math.sqrt(p.x * p.x + p.y * p.y))
        .reduce(math.max);

    double minRadiusOf(GlbDrawable d) => d.positions
        .map((p) => math.sqrt(p.x * p.x + p.y * p.y))
        .reduce(math.min);

    test('the two models share one assembly centre', () {
      // If these ever differ the ring would sit eccentric around the plate, and
      // no setback value could fix it.
      expect(meshes.targetModel.center.x, closeTo(0, 1e-5));
      expect(meshes.targetModel.center.y, closeTo(0, 1e-5));
      expect(meshes.bezelModel.center.x, closeTo(0, 1e-5));
      expect(meshes.bezelModel.center.y, closeTo(0, 1e-5));
    });

    test('the ring surrounds the plate and abuts it exactly', () {
      final plate = meshes.targetModel.drawables[0];
      final bezel = meshes.bezelModel.drawables[0];
      expect(maxRadiusOf(plate), closeTo(0.270, 1e-4));
      // The ring's inner edge is the plate's outer edge: no gap, no overlap.
      expect(minRadiusOf(bezel), closeTo(maxRadiusOf(plate), 1e-4));
      expect(maxRadiusOf(bezel), closeTo(0.350, 1e-4));
    });

    test('the ring is hollow', () {
      // A solid disc would have geometry out to r = 0; the annulus starts at
      // 0.270, which is what leaves the plate visible through it.
      expect(minRadiusOf(meshes.bezelModel.drawables[0]), greaterThan(0.26));
    });

    test('the green centre stays inside the plate and is green', () {
      final centre = meshes.targetModel.drawables[1];
      expect(maxRadiusOf(centre), closeTo(0.100, 1e-4));
      expect(
        maxRadiusOf(centre),
        lessThan(maxRadiusOf(meshes.targetModel.drawables[0])),
      );
      expect(centre.color.g, greaterThan(centre.color.r));
      expect(centre.color.g, greaterThan(centre.color.b));
    });

    test(
      'the check marks sit above the plate, so they only show when enabled',
      () {
        for (final index in <int>[2, 3]) {
          final check = meshes.targetModel.drawables[index];
          expect(check.min.z, greaterThanOrEqualTo(0.012 - 1e-4));
          expect(check.max.z, closeTo(0.018, 1e-4));
        }
      },
    );

    test('the setback makes the two front faces flush', () {
      // The value is derived, not tuned: the bezel's front face is at
      // z = 0.012 and the plate's at z = 0.006, so a setback of their
      // difference leaves the composite flat — no gap, no step at the join.
      final plate = meshes.targetModel.drawables[0];
      final bezel = meshes.bezelModel.drawables[0];
      expect(bezel.max.z - arBezelSetbackM, closeTo(plate.max.z, 1e-9));
      expect(arBezelSetbackM, closeTo(bezel.max.z - plate.max.z, 1e-9));
    });

    test('the join opens no visible gap at the marker distance', () {
      // Recessing the ring would make it project smaller and leave daylight
      // between it and the plate: 20 mm left 4.2 px at 1080 wide / 68°.
      const plateRadius = 0.270;
      const viewfinderWidth = 1080.0;
      const hfovDeg = 68.0;
      final fx = (viewfinderWidth / 2) / math.tan(hfovDeg * math.pi / 180 / 2);
      final gapPx = plateRadius * fx * (1 - 1 / (1 + arBezelSetbackM));
      expect(gapPx, lessThan(1.5));
    });

    test('the setback is the gap/overlap crossover, not merely small', () {
      // Recessing the ring makes it project smaller, so the nearer plate
      // overlaps its inner edge; bringing it forward opens daylight. Exactly one
      // value gives neither, and it is the one in use.
      const distance = 1.0; // arTargetDistanceM
      const plateFront = 0.006;
      const bezelFront = 0.012;
      const sharedRadius = 0.270;

      double offsetAt(double setback) =>
          sharedRadius / (distance - plateFront) -
          sharedRadius / (distance + setback - bezelFront);

      // 0 at the value in use: the two front faces are coplanar.
      expect(offsetAt(arBezelSetbackM), closeTo(0, 1e-12));
      // Larger: the plate sits on top of the ring (the old 20 mm behaviour).
      expect(offsetAt(0.020), greaterThan(0.003));
      // Smaller: a ring of daylight appears between them.
      expect(offsetAt(0.002), lessThan(0));
    });

    test('both renderers use the same setback', () {
      // The AR module draws through OpenGL and the legacy overlay in pure Dart;
      // the composite must look the same in both.
      expect(arBezelSetbackM, const CaptureGeometryConfig().bezelSetbackM);
    });
  });
}
