import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_target_scene.dart';

/// Reads an asset path into bytes.
///
/// Injectable so a `flutter test` run can read the same two files off disk
/// without a Flutter asset bundle.
typedef AssetLoader = Future<ByteData> Function(String path);

/// Turns the two shipped `.glb` assets into the raw triangle buffers the native
/// AR renderer draws.
///
/// **The assets are not converted, replaced or re-authored.** They are read
/// byte-for-byte from `assets/models/` and parsed by the project's existing
/// glTF reader; this class only flattens the result into the vertex buffers a
/// GLES 2.0 mesh needs. That is deliberate: the same parser is what the existing
/// pure-Dart target overlay uses, so the geometry in the real AR scene and the
/// geometry the unit tests assert on cannot drift apart.
///
/// The native renderer has no model loader of its own, on purpose — shipping a
/// second glTF implementation in Kotlin would be a second thing to keep correct.
class GlbMeshSource {
  /// Public so a test can build one from stand-in models: the mesh geometry is
  /// irrelevant to the alignment and anchoring maths, and forcing a test to read
  /// the real asset would couple those suites to the asset bundle.
  GlbMeshSource(this._target, this._bezel);

  static GlbMeshSource? _instance;

  /// Loads both models once and caches them for the process.
  ///
  /// Throws [GlbParseException] when an asset is missing or malformed. The
  /// caller shows that rather than drawing a stand-in: a broken asset is a build
  /// problem, not a runtime state to degrade from.
  static Future<GlbMeshSource> load({AssetLoader? loader}) async {
    final cached = _instance;
    if (cached != null) return cached;
    final read = loader ?? rootBundle.load;
    final targetBytes = await read(arTargetAssetPath);
    final bezelBytes = await read(arBezelAssetPath);
    final created = GlbMeshSource(
      parseGlb(
        targetBytes.buffer.asUint8List(
          targetBytes.offsetInBytes,
          targetBytes.lengthInBytes,
        ),
        source: arTargetAssetPath,
      ),
      parseGlb(
        bezelBytes.buffer.asUint8List(
          bezelBytes.offsetInBytes,
          bezelBytes.lengthInBytes,
        ),
        source: arBezelAssetPath,
      ),
    );
    _instance = created;
    return created;
  }

  final GlbModel _target;
  final GlbModel _bezel;

  /// The parsed target model, for the self-check the UI reports.
  GlbModel get targetModel => _target;
  GlbModel get bezelModel => _bezel;

  /// Triangle count of the target mesh, for the diagnostics line.
  int get targetTriangles => _target.triangleCount;
  int get bezelTriangles => _bezel.triangleCount;

  /// The plate's authored width along its own `X`, in metres.
  ///
  /// The measured bounding box, not a guess: the marker's draw scale is
  /// `targetDiameterM / targetWidthM`, so the plate ends up exactly the
  /// configured physical size whatever units the asset was authored in.
  double get targetWidthM => _target.widthX;

  /// The bezel's authored width along its own `X`, in metres.
  double get bezelWidthM => _bezel.widthX;

  /// Flattens one model into position and colour buffers.
  ///
  /// The target is uploaded without its check-mark meshes (they only appear on
  /// `captured`); the bezel is uploaded whole.
  ///
  /// **Selection is by topology, not by a raw index.** `GlbTargetTopology`
  /// decides which drawable is a check mark, and it only does so when the asset
  /// still has the four-part layout it was written against. A hard-coded
  /// `meshIndex >= 2` would silently drop the two green cuboids — or, on a
  /// changed asset, drop the wrong geometry — with nothing to notice it.
  MeshBuffers buffersFor(GlbModel model, {required bool skipCheckMarks}) {
    final positions = <double>[];
    final colors = <double>[];
    final topology = GlbTargetTopology.from(model);
    for (final drawable in model.drawables) {
      if (skipCheckMarks && topology.isCheckMarkPart(drawable)) continue;
      final base = drawable.color;
      for (var i = 0; i < drawable.positions.length; i++) {
        final p = drawable.transform.apply(drawable.positions[i]);
        positions.add(p.x);
        positions.add(p.y);
        positions.add(p.z);
        final c = i < drawable.vertexColors.length
            ? drawable.vertexColors[i]
            : base;
        colors.add(c.r);
        colors.add(c.g);
        colors.add(c.b);
        colors.add(c.a);
      }
    }
    return MeshBuffers(
      positions: Float32List.fromList(positions),
      colors: Float32List.fromList(colors),
      vertexCount: positions.length ~/ 3,
    );
  }

  MeshBuffers get targetBuffers => buffersFor(_target, skipCheckMarks: true);
  MeshBuffers get bezelBuffers => buffersFor(_bezel, skipCheckMarks: false);

  /// One line describing what was actually parsed, for the diagnostics panel.
  ///
  /// Answers "did both models load, and how much geometry is in the scene"
  /// without a device: the numbers are the parsed triangle counts, not a claim.
  String describe() {
    final target = targetBuffers;
    final bezel = bezelBuffers;
    return 'target ${_target.drawables.length} parts / '
        '${_target.triangleCount} tris → ${target.vertexCount} verts · '
        'bezel ${_bezel.triangleCount} tris → ${bezel.vertexCount} verts';
  }

  /// Whether the shipped assets still match the dimensions the spec records.
  bool matchesSpec() =>
      GlbTargetTopology.targetMatchesSpec(_target) &&
      GlbTargetTopology.bezelMatchesSpec(_bezel);

  /// The centre of the target plate in its own model space, so the renderer can
  /// be told to place the *plate* on the anchor rather than the model's bounds
  /// centre (the two differ: the bezel sticks out beyond the plate).
  Vec3 get targetCentre => _target.center;

  /// How far the bezel must be pushed back so the two coplanar meshes neither
  /// z-fight nor gap.
  ///
  /// **0.006, derived from the assets — not the 0.020 this constant used to
  /// claim.** The two models are concentric and their front faces land
  /// coplanar at exactly this value: the plate's front face is at
  /// `0.012 − 0.006` of its own depth and the ring's at `0`, so `0.006` is
  /// both the difference of the front faces and the crossover where neither
  /// gap nor overlap occurs (0.020 made the nearer plate overlap the ring by
  /// 3.8 mm; 0.002 left a 1.1 mm ring of daylight). The scene push reads the
  /// same number from [CaptureGeometryConfig.bezelSetbackM]; this constant
  /// exists so both renderers agree, so it must never drift from it again —
  /// `test/glb_pipeline_test.dart` pins the two together.
  static const double bezelSetbackM = 0.006;
}

/// One uploaded mesh: xyz per vertex and rgba per vertex.
class MeshBuffers {
  final Float32List positions;
  final Float32List colors;
  final int vertexCount;

  const MeshBuffers({
    required this.positions,
    required this.colors,
    required this.vertexCount,
  });

  bool get isEmpty => vertexCount == 0;
}
