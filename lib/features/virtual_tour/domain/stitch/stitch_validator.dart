import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/data/station_group.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// Local pre-stitch sanity gate, run before anything is uploaded.
///
/// This does **not** stitch — the heavy lifting is the backend OpenCV pipeline
/// (see `backend/README.md`). What it does is catch the failures a stitcher
/// cannot recover from, so the user is told before they spend time on an upload:
///
/// * **Completeness.** A missing frame is a hole in the panorama. The plan's own
///   frame count is the reference, not a hard-coded number — the rewrite derives
///   it from the real field of view, so this file must not reintroduce a constant.
/// * **Neighbour overlap.** For each accepted frame, the angular distance to its
///   nearest accepted neighbour has to be small enough that the two share
///   features. Measured with [geodesicAngleDeg], a true great-circle angle, so it
///   stays correct across the poles where a yaw difference would not.
/// * **Station separation.** Frames from different stations are never combined;
///   each station is checked on its own and reported on its own.
///
/// It deliberately does **not** claim that passing this gate means the stitch will
/// succeed. The geometry and the image quality can both be fine and the stitch can
/// still fail on a textureless wall or a moving object. The result says "nothing
/// obviously wrong", not "will work".
class StitchReadiness {
  /// True when no problem was found. Not a promise that the stitch will succeed.
  final bool ready;

  /// One line per problem, already phrased for display.
  final List<String> problems;

  /// Per-station notes that are not blockers, e.g. an unresolved region.
  final List<String> warnings;

  const StitchReadiness({
    required this.ready,
    required this.problems,
    this.warnings = const <String>[],
  });

  @override
  String toString() => ready
      ? 'StitchReadiness(ready${warnings.isEmpty ? '' : ', '
                  '${warnings.length} warning(s)'})'
      : 'StitchReadiness(not ready: ${problems.join('; ')})';
}

class StitchValidator {
  /// Angular distance, in degrees, above which two neighbouring frames are judged
  /// too far apart to share features.
  ///
  /// Expressed as a fraction of the smaller field of view rather than as an
  /// absolute angle, so it follows the plan instead of assuming a 55°/70° camera.
  final double maxNeighbourFractionOfFov;

  const StitchValidator({this.maxNeighbourFractionOfFov = 0.9});

  /// Checks one station's panorama group.
  StitchReadiness checkStation(StationGroup group) {
    final problems = <String>[];
    final warnings = <String>[...group.notes];

    final planned = group.plannedFrameCount;
    final accepted = group.frames;

    // ── Completeness ────────────────────────────────────────────────────────
    final pending = group.pendingIndices();
    if (accepted.isEmpty) {
      problems.add('No frames were captured for this station.');
    } else if (pending.isNotEmpty) {
      final skipped = <int>[
        for (var i = 0; i < planned; i++)
          if (group.statuses[i] == TargetStatus.skipped) i,
      ];
      problems.add(
        'Missing ${pending.length} of $planned frame(s)'
        '${skipped.isEmpty ? '' : ' (${skipped.length} skipped)'} — the '
        'panorama will have holes.',
      );
    }

    // ── Neighbour overlap ───────────────────────────────────────────────────
    // Only meaningful with at least two frames: a single frame has no neighbour,
    // and calling it "infinitely far from its nearest neighbour" would be noise
    // on top of the completeness problem already reported.
    if (accepted.length >= 2) {
      for (final f in accepted) {
        var best = double.infinity;
        AcceptedFrame? nearest;
        for (final other in accepted) {
          if (identical(other, f)) continue;
          final d = geodesicAngleDeg(
            (yawDeg: f.targetYawDeg, pitchDeg: f.targetPitchDeg),
            (yawDeg: other.targetYawDeg, pitchDeg: other.targetPitchDeg),
          );
          if (d < best) {
            best = d;
            nearest = other;
          }
        }
        if (nearest == null || !best.isFinite) continue;

        // The limit is per *pair*, not per station: a frame covers a different
        // angle depending on which way you look from its centre.
        final limit =
            maxNeighbourFractionOfFov *
            (_halfExtentDeg(f, nearest) + _halfExtentDeg(nearest, f));
        if (best > limit) {
          problems.add(
            'Frame ${f.index} is ${best.toStringAsFixed(1)}° from its nearest '
            'captured neighbour (limit ${limit.toStringAsFixed(1)}°) — overlap '
            'may be insufficient.',
          );
        }
      }
    }

    // ── Warnings the user should see but that do not block ──────────────────
    final lowInfo = accepted.where((f) => f.warning != null).length;
    if (lowInfo > 0) {
      warnings.add(
        '$lowInfo frame(s) were accepted with a low-information warning. A '
        'featureless region can still defeat the stitcher even though the frame '
        'passed the quality check.',
      );
    }
    final manual = accepted.where((f) => f.manual).length;
    if (manual > 0) {
      warnings.add(
        '$manual frame(s) were captured manually because tracking was '
        'unavailable, so their aim is not verified.',
      );
    }

    return StitchReadiness(
      ready: problems.isEmpty,
      problems: problems,
      warnings: warnings,
    );
  }

  /// How far off-axis [from] can see, looking towards [to].
  ///
  /// A rectilinear frustum is a rectangle in tangent space: half-width
  /// `tan(hfov/2)`, half-height `tan(vfov/2)`. A ray leaving the centre at
  /// bearing θ meets whichever edge it reaches first, so the bound is
  /// `min(halfW/|cos θ|, halfH/|sin θ|)`.
  ///
  /// **Why this exists.** An earlier version used `0.9 × min(hfov, vfov)` as one
  /// limit for the whole station. That is right for neighbours separated in yaw,
  /// because then the bearing is horizontal and the bound is `hfov/2` — and in a
  /// portrait app `hfov` *is* the smaller of the two. But the zenith and nadir
  /// frames are separated from the nearest ring **vertically**, where the same
  /// frame covers `vfov/2`, the larger one. With the flow's default
  /// 53.7°×68.0° portrait frustum that turned a real 13.9° of overlap into a
  /// false "will not stitch" on every single station.
  static double _halfExtentDeg(AcceptedFrame from, AcceptedFrame to) {
    final halfW = math.tan(from.hfovDeg * degToRad / 2);
    final halfH = math.tan(from.vfovDeg * degToRad / 2);
    final c = math.cos(_bearingRad(from, to)).abs();
    final s = math.sin(_bearingRad(from, to)).abs();
    final r = math.min(
      c < 1e-12 ? double.infinity : halfW / c,
      s < 1e-12 ? double.infinity : halfH / s,
    );
    return math.atan(r) * radToDeg;
  }

  /// The bearing of [to] within [from]'s own image plane, in radians: 0 is
  /// screen-right, π/2 is screen-up.
  ///
  /// A frustum is symmetric about both of its axes, so only the absolute
  /// direction matters and the handedness correction the guidance layer applies
  /// to `d_cam.x` is deliberately not involved here.
  static double _bearingRad(AcceptedFrame from, AcceptedFrame to) {
    final basis = orthonormalBasis(from.targetYawDeg, from.targetPitchDeg);
    final d = directionFromYawPitch(to.targetYawDeg, to.targetPitchDeg);
    return math.atan2(d.dot(basis.up), d.dot(basis.right));
  }

  /// Checks every station of a session, keyed by station index.
  Map<int, StitchReadiness> checkSession(List<StationGroup> stations) =>
      <int, StitchReadiness>{
        for (final s in stations) s.index: checkStation(s),
      };

  /// A one-line summary for the review screen.
  static String summarise(Map<int, StitchReadiness> perStation) {
    final blocked = perStation.entries.where((e) => !e.value.ready).toList();
    if (blocked.isEmpty) {
      return '${perStation.length} station(s) passed the pre-stitch check.';
    }
    return '${blocked.length} of ${perStation.length} station(s) need review: '
        '${blocked.map((e) => 'station ${e.key + 1}').join(', ')}.';
  }
}
