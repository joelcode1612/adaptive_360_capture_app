import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/widgets/target_verdict.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The per-target verdict is what the new list shows, so it is tested as a pure
/// function rather than through a widget.
///
/// The distinction that matters most: a target with no anchor is **not** a
/// failure. Telling the user it failed would send them looking for a bug when
/// the answer is "point the phone at a wall".
void main() {
  CaptureTarget target({
    int id = 9,
    CaptureTargetStatus status = CaptureTargetStatus.pending,
    String? anchorId,
    Vec3? anchorPos,
    String? surface,
    String? imagePath,
    String? message,
  }) => CaptureTarget(
    targetId: id,
    stationId: 's1',
    yawDegrees: 0,
    pitchDegrees: 0,
    stationLocalDirection: Vec3.unitZ,
    status: status,
    anchorIdentifier: anchorId,
    anchorWorldPosition: anchorPos,
    anchorSurfaceType: surface,
    imagePath: imagePath,
    message: message,
  );

  final anchored = target(
    anchorId: 'a1',
    anchorPos: const Vec3(0, 0, 3),
    surface: 'PLANE_VERTICAL',
  );

  group('saved', () {
    test('a captured target with a file names the file', () {
      final r = targetVerdict(
        target(
          status: CaptureTargetStatus.captured,
          imagePath: '/data/user/0/app/ar_capture/s1/frames/t09.jpg',
        ),
      );
      expect(r.verdict, TargetVerdict.saved);
      expect(r.detail, 'photo t09.jpg');
    });

    test('a captured target without a file has no detail line', () {
      final r = targetVerdict(target(status: CaptureTargetStatus.captured));
      expect(r.verdict, TargetVerdict.saved);
      expect(r.detail, isNull);
    });
  });

  group('failed', () {
    test('carries the recorded reason', () {
      final r = targetVerdict(
        target(status: CaptureTargetStatus.failed, message: 'Disk full.'),
      );
      expect(r.verdict, TargetVerdict.failed);
      expect(r.detail, 'Disk full.');
    });

    test('says so when no reason was recorded', () {
      final r = targetVerdict(target(status: CaptureTargetStatus.failed));
      expect(r.verdict, TargetVerdict.failed);
      expect(r.detail, 'No reason recorded.');
    });
  });

  group('probed states', () {
    test('never probed is "not scanned", not "no surface"', () {
      final r = targetVerdict(target());
      expect(r.verdict, TargetVerdict.unscanned);
      expect(r.verdict, isNot(TargetVerdict.noSurface));
      expect(r.verdict, isNot(TargetVerdict.failed));
      expect(r.detail, contains('Not scanned'));
    });

    test('probed and nothing there is "no surface"', () {
      final r = targetVerdict(target(), probe: const SurfaceProbe.miss());
      expect(r.verdict, TargetVerdict.noSurface);
      expect(r.detail, contains('No surface along this direction'));
    });

    test('probed with a surface is actionable even before anchoring', () {
      final r = targetVerdict(
        target(),
        probe: const SurfaceProbe.found(
          distanceM: 2.4,
          surfaceType: 'PLANE_VERTICAL',
        ),
      );
      expect(r.verdict, TargetVerdict.ready);
      expect(r.verdict.isActionable, isTrue);
      expect(r.detail, 'surface found · wall · 2.4 m');
    });

    test('the probe describes a floor and a ceiling differently', () {
      String describe(String type) =>
          SurfaceProbe.found(distanceM: 1.0, surfaceType: type).describe;
      expect(describe('PLANE_VERTICAL'), 'wall · 1.0 m');
      expect(describe('PLANE_HORIZONTAL_UPWARD_FACING'), 'floor · 1.0 m');
      expect(describe('PLANE_HORIZONTAL_DOWNWARD_FACING'), 'ceiling · 1.0 m');
      expect(describe('SOMETHING_ELSE'), 'surface · 1.0 m');
      expect(const SurfaceProbe.miss().describe, 'no surface');
    });

    test('an anchor id without a position does not count as anchored', () {
      // `isAnchored` requires both, so a half-populated target is still
      // un-capturable rather than silently treated as ready.
      final r = targetVerdict(target(anchorId: 'a1'));
      expect(r.verdict, TargetVerdict.unscanned);
    });

    test('a recorded message wins over the default advice', () {
      final r = targetVerdict(
        target(message: 'No surface along this direction yet.'),
        probe: const SurfaceProbe.miss(),
      );
      expect(r.detail, 'No surface along this direction yet.');
    });
  });

  group('ready and active', () {
    test('an anchored idle target is ready, and names the surface', () {
      final r = targetVerdict(anchored);
      expect(r.verdict, TargetVerdict.ready);
      expect(r.detail, 'anchored · PLANE_VERTICAL');
      expect(r.verdict.isActionable, isTrue);
    });

    test('the target being guided towards is active', () {
      final r = targetVerdict(
        target(
          status: CaptureTargetStatus.active,
          anchorId: 'a1',
          anchorPos: const Vec3(0, 0, 3),
        ),
      );
      expect(r.verdict, TargetVerdict.active);
      expect(r.detail, 'anchored');
      expect(r.verdict.isActionable, isTrue);
    });
  });

  group('actionability', () {
    test('only ready and active can be captured without changing anything', () {
      expect(TargetVerdict.saved.isActionable, isFalse);
      expect(TargetVerdict.failed.isActionable, isFalse);
      expect(TargetVerdict.noSurface.isActionable, isFalse);
      expect(TargetVerdict.unscanned.isActionable, isFalse);
      expect(TargetVerdict.ready.isActionable, isTrue);
      expect(TargetVerdict.active.isActionable, isTrue);
    });

    test('every verdict is reachable from a target', () {
      final reached = <TargetVerdict>{
        targetVerdict(target(status: CaptureTargetStatus.captured)).verdict,
        targetVerdict(target(status: CaptureTargetStatus.failed)).verdict,
        targetVerdict(target()).verdict,
        targetVerdict(target(), probe: const SurfaceProbe.miss()).verdict,
        targetVerdict(anchored).verdict,
        targetVerdict(
          target(
            status: CaptureTargetStatus.active,
            anchorId: 'a1',
            anchorPos: const Vec3(0, 0, 3),
          ),
        ).verdict,
      };
      expect(reached.length, TargetVerdict.values.length);
    });
  });
}
