import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The real persistence layer's schema contract.
///
/// There is no SQL table in this project: the station store is
/// `<appDocs>/ar_capture/<stationId>/`, where the station id is the directory
/// name **and** the primary key, and `targets.json` / `records.json` carry it
/// as the foreign key while `targetId` is the frame index. These tests pin
/// that contract against the real [FileCaptureRepository] - including the two
/// properties a resume depends on: a retake replaces its record instead of
/// appending a duplicate, and one station's frames never appear under
/// another's.
void main() {
  late Directory root;
  late FileCaptureRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ar_capture_persistence');
    repository = FileCaptureRepository(root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  CaptureStation station(String id, {int capturedCount = 0}) => CaptureStation(
    stationId: id,
    referencePosition: const Vec3(1, 1.6, -2),
    referenceOrientation: Quat.identity,
    createdAt: DateTime.utc(2026, 10, 20),
    trackingStatus: TrackingState.tracking,
    capturedCount: capturedCount,
    total: kCaptureTargetCount,
  );

  CaptureRecord record(String stationId, int targetId) => CaptureRecord(
    stationId: stationId,
    targetId: targetId,
    imagePath: '/tmp/$stationId-t$targetId.jpg',
    capturedAt: DateTime.utc(2026, 10, 20, 12, targetId),
    targetYawDegrees: 0,
    targetPitchDegrees: 45,
    cameraPosition: Vec3.zero,
    cameraOrientation: Quat.identity,
    alignmentErrorDeg: 0.4,
    anchored: true,
    anchorIdentifier: 'anchor-1',
    anchorSurfaceType: 'WORLD',
    imageWidth: 1920,
    imageHeight: 1080,
  );

  test('a station is its own record, keyed by its own id', () async {
    const id = 'station-1760000000000';
    await repository.saveStation(station(id));

    final file = File(p.join(root.path, id, 'station.json'));
    expect(await file.exists(), isTrue);

    final loaded = await repository.loadStation(id);
    expect(loaded, isNotNull);
    expect(loaded!.stationId, id);
    expect(loaded.referencePosition.x, closeTo(1, 1e-9));
    expect(loaded.referencePosition.y, closeTo(1.6, 1e-9));
    expect(loaded.referenceOrientation.length, closeTo(1, 1e-9));
    expect(loaded.trackingStatus, TrackingState.tracking);
    expect(loaded.total, kCaptureTargetCount);
    expect(await repository.loadStation('station-does-not-exist'), isNull);
  });

  test('all 26 targets are filed under the station that owns them', () async {
    const id = 'station-a';
    await repository.saveStation(station(id));
    await repository.saveTargets(<CaptureTarget>[
      for (final spec in buildCaptureSphere())
        CaptureTarget(
          targetId: spec.targetId,
          stationId: id,
          yawDegrees: spec.yawDegrees,
          pitchDegrees: spec.pitchDegrees,
          stationLocalDirection: spec.direction,
        ),
    ]);

    final loaded = await repository.loadTargets(id);
    expect(loaded.length, kCaptureTargetCount);
    expect(
      loaded.every((CaptureTarget t) => t.stationId == id),
      isTrue,
      reason: 'the station id is the foreign key on every target',
    );
    expect(
      loaded.map((CaptureTarget t) => t.targetId).toSet().length,
      kCaptureTargetCount,
      reason: '26 distinct frame indices',
    );
    expect(await repository.loadTargets('station-b'), isEmpty);
  });

  test(
    'a retake replaces its record instead of appending a duplicate',
    () async {
      const id = 'station-a';
      await repository.saveStation(station(id));
      await repository.saveRecord(record(id, 3));
      await repository.saveRecord(record(id, 7));
      // The same frame taken again: same station, same frame index.
      await repository.saveRecord(record(id, 3));

      final records = await repository.loadRecords(id);
      expect(records.length, 2, reason: 'one record per frame index');
      expect(records.map((CaptureRecord r) => r.targetId).toList(), <int>[
        3,
        7,
      ]);
    },
  );

  test('a station with a different id never sees other frames', () async {
    await repository.saveStation(station('station-a'));
    await repository.saveStation(station('station-b'));
    await repository.saveRecord(record('station-a', 1));
    await repository.saveRecord(record('station-b', 2));

    expect((await repository.loadRecords('station-a')).length, 1);
    expect((await repository.loadRecords('station-b')).single.targetId, 2);
    expect(
      await repository.stationIds(),
      containsAll(<String>['station-a', 'station-b']),
    );
  });

  test('frame paths are per station and indexed by frame', () async {
    final path = await repository.framePath('station-a', 7);
    expect(path, contains('station-a'));
    expect(path, contains('frames'));
    expect(path.endsWith('t07.jpg'), isTrue);
  });
}
