import 'dart:io';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';

void main() {
  for (final path in <String>[
    'assets/models/ar_capture_target.glb',
    'assets/models/white_frame_bezel.glb',
  ]) {
    final bytes = File(path).readAsBytesSync();
    final model = GlbModel.parse(bytes);
    print('== $path');
    print('  min=${model.min}');
    print('  max=${model.max}');
    print('  widthX=${model.widthX} heightY=${model.heightY} depthZ=${model.depthZ}');
    print('  nodes=${model.nodeCount} meshes=${model.meshCount} tris=${model.triangleCount}');
    print('  drawables=${model.drawables.length}');
  }
}
