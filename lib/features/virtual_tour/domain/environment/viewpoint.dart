import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/room_occlusion.dart';

/// Suggests a second capture position when one station cannot see everything.
///
/// Ported from `suggestVP` in `/*ENGINE*/`.
///
/// A 7×7 grid of candidate positions is scored by how much of the wall surface
/// each one can see — with the wall points that were hidden from *every*
/// already-captured viewpoint weighted more heavily, so the suggestion moves
/// toward the area that is still missing rather than toward the already-good
/// area.
class ViewpointSuggestion {
  final double x;
  final double z;
  final double score;

  const ViewpointSuggestion({
    required this.x,
    required this.z,
    required this.score,
  });

  @override
  String toString() =>
      '(${x.toStringAsFixed(2)}, ${z.toStringAsFixed(2)}) '
      'score ${score.toStringAsFixed(3)}';
}

/// Returns the best alternative station position, or null when none qualifies.
///
/// [clearanceM] is the minimum wall clearance. [hiddenPoints] is the mask of
/// wall points not visible from any viewpoint captured so far; when it is null
/// every point counts equally.
ViewpointSuggestion? suggestViewpoint({
  required RoomBox room,
  required ({double x, double z}) from,
  required List<ObstacleBox> obstacles,
  double clearanceM = 0.5,
  List<int>? hiddenPoints,
}) {
  final pts = wallPoints(room);
  ViewpointSuggestion? best;

  for (var a = 0; a < 7; a++) {
    for (var b = 0; b < 7; b++) {
      final x = clearanceM + a * (room.lengthM - 2 * clearanceM) / 6;
      final z = clearanceM + b * (room.widthM - 2 * clearanceM) / 6;

      // Skip positions inside (or too close to) an obstacle.
      var inside = false;
      for (final o in obstacles) {
        if (o.footprintContains(x, z, 0.4)) {
          inside = true;
          break;
        }
      }
      if (inside) continue;

      // Skip positions too close to where we already stand to be a new
      // viewpoint.
      final minSep = math.min(room.lengthM, room.widthM) * 0.25;
      if (math.sqrt((x - from.x) * (x - from.x) + (z - from.z) * (z - from.z)) <
          minSep) {
        continue;
      }

      final vis = wallVisibility(room, (x: x, z: z), obstacles, pts);
      var all = 0;
      var hiddenCount = 0;
      var hiddenVisible = 0;
      for (var i = 0; i < vis.length; i++) {
        all += vis[i];
        if (hiddenPoints != null && hiddenPoints[i] != 0) {
          hiddenCount++;
          hiddenVisible += vis[i];
        }
      }

      final score = hiddenCount > 0
          ? 0.8 * hiddenVisible / hiddenCount + 0.2 * all / vis.length
          : all / vis.length;

      if (best == null || score > best.score + 1e-6) {
        best = ViewpointSuggestion(
          x: (x * 100).roundToDouble() / 100,
          z: (z * 100).roundToDouble() / 100,
          score: score,
        );
      }
    }
  }

  return best;
}

/// Points of the room's walls not visible from **any** captured viewpoint.
List<int> hiddenFromAll(
  List<List<int>> visibilityPerViewpoint,
  int pointCount,
) {
  final hidden = List<int>.filled(pointCount, 0);
  for (var i = 0; i < pointCount; i++) {
    var seenAnywhere = false;
    for (final v in visibilityPerViewpoint) {
      if (v.length > i && v[i] != 0) {
        seenAnywhere = true;
        break;
      }
    }
    hidden[i] = seenAnywhere ? 0 : 1;
  }
  return hidden;
}
