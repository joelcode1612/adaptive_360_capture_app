import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// §8 calibration atomicity, ported from the source project.
///
/// The station record must never advertise itself before the calibration is
/// complete: a process death between the two metadata writes used to leave a
/// directory that resume discovery offered to the user as a resumable session.
/// The transaction stages both files behind a pending marker, keeps backups of
/// a replaced calibration, and only clears the marker after both commits land.
/// The source file's fifth test exercised the SiteWise tour wrapper, which §5
/// excludes from this standalone app; `FileCaptureRepository.saveCalibration`
/// delegates to the same transaction and is covered by
/// `capture_persistence_test.dart`.
void main() {
  late Directory tmp;
  late Directory stationDir;
  const stationId = 'station-1';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('capture_calibration_');
    stationDir = Directory(p.join(tmp.path, stationId));
    await stationDir.create(recursive: true);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  CaptureStation makeStation({int captured = 0}) => CaptureStation(
    stationId: stationId,
    referencePosition: const Vec3(0.02, 1.4, -0.1),
    referenceOrientation: const Quat(0, 0, 0, 1),
    createdAt: DateTime.utc(2026, 11, 12, 9),
    trackingStatus: TrackingState.tracking,
    capturedCount: captured,
  );

  List<CaptureTarget> makeTargets({int capturedCount = 0}) => [
    for (var i = 1; i <= 26; i++)
      CaptureTarget(
        targetId: i,
        stationId: stationId,
        yawDegrees: (i - 1) * 15.0,
        pitchDegrees: i <= 8
            ? 0
            : i <= 16
            ? 30
            : i <= 24
            ? -30
            : i == 25
            ? 90
            : -90,
        stationLocalDirection: const Vec3(0, 0, 1),
        status: i <= capturedCount
            ? CaptureTargetStatus.captured
            : CaptureTargetStatus.pending,
      ),
  ];

  group('persistCaptureCalibrationFiles', () {
    test('writes both files atomically and leaves no pending marker', () async {
      await persistCaptureCalibrationFiles(
        stationDirectory: stationDir.path,
        station: makeStation(),
        targets: makeTargets(),
      );

      expect(
        File(p.join(stationDir.path, 'station.json')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(stationDir.path, 'targets.json')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(stationDir.path, '.calibration.pending')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(stationDir.path, '.station.json.pending')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(stationDir.path, '.targets.json.pending')).existsSync(),
        isFalse,
      );

      final station = CaptureStation.fromJson(
        jsonDecode(
              await File(
                p.join(stationDir.path, 'station.json'),
              ).readAsString(),
            )
            as Map<String, dynamic>,
      );
      final targets =
          (jsonDecode(
                    await File(
                      p.join(stationDir.path, 'targets.json'),
                    ).readAsString(),
                  )
                  as List)
              .map(
                (dynamic row) =>
                    CaptureTarget.fromJson(row as Map<String, dynamic>),
              )
              .toList();
      expect(station.stationId, stationId);
      expect(targets.length, 26);
      expect(targets.every((t) => t.stationId == stationId), isTrue);
    });

    test(
      'an incomplete target set is rejected before any file is touched',
      () async {
        await expectLater(
          persistCaptureCalibrationFiles(
            stationDirectory: stationDir.path,
            station: makeStation(),
            targets: makeTargets().sublist(0, 10),
          ),
          throwsStateError,
        );
        expect(
          File(p.join(stationDir.path, 'station.json')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(stationDir.path, 'targets.json')).existsSync(),
          isFalse,
        );
      },
    );

    test('a replaced calibration keeps records and JPEGs intact', () async {
      // First calibration, then an accepted photo + its record.
      await persistCaptureCalibrationFiles(
        stationDirectory: stationDir.path,
        station: makeStation(),
        targets: makeTargets(),
      );
      final jpeg = File(p.join(stationDir.path, 'frames', 't01.jpg'));
      await jpeg.create(recursive: true);
      await jpeg.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9], flush: true);
      final records = File(p.join(stationDir.path, 'records.json'));
      await records.writeAsString(
        jsonEncode([
          CaptureRecord(
            stationId: stationId,
            targetId: 1,
            imagePath: jpeg.path,
            capturedAt: DateTime.utc(2026, 11, 12, 10),
            targetYawDegrees: 0,
            targetPitchDegrees: 0,
            cameraPosition: const Vec3(0, 0, 0),
            cameraOrientation: const Quat(0, 0, 0, 1),
            alignmentErrorDeg: 0.5,
            anchored: true,
            imageWidth: 640,
            imageHeight: 480,
          ).toJson(),
        ]),
        flush: true,
      );
      final jpegBytesBefore = await jpeg.readAsBytes();

      // A recalibration replaces the metadata only.
      await persistCaptureCalibrationFiles(
        stationDirectory: stationDir.path,
        station: makeStation(captured: 1),
        targets: makeTargets(capturedCount: 1),
      );

      expect(await jpeg.readAsBytes(), jpegBytesBefore);
      final keptRecords = jsonDecode(await records.readAsString()) as List;
      expect(keptRecords.length, 1);
    });

    test(
      'an interrupted transaction is excluded from resume, then recovered',
      () async {
        // First accepted calibration.
        await persistCaptureCalibrationFiles(
          stationDirectory: stationDir.path,
          station: makeStation(),
          targets: makeTargets(),
        );

        // Simulate a process death mid-transaction: current files renamed to
        // their backups, pending marker present, partial staged writes left.
        await File(
          p.join(stationDir.path, 'station.json'),
        ).rename(p.join(stationDir.path, '.station.json.calibration-backup'));
        await File(
          p.join(stationDir.path, 'targets.json'),
        ).rename(p.join(stationDir.path, '.targets.json.calibration-backup'));
        await File(
          p.join(stationDir.path, '.calibration.pending'),
        ).writeAsString(
          jsonEncode(<String, dynamic>{'hadStation': true, 'hadTargets': true}),
        );
        await File(
          p.join(stationDir.path, '.station.json.pending'),
        ).writeAsString('partial');

        // Resume discovery must not advertise the half-written directory.
        final repo = FileCaptureRepository(tmp.path);
        expect(await repo.stationIds(), isEmpty);

        // The next calibration attempt rolls the crash back and commits cleanly.
        final recovered = makeStation(captured: 3);
        await persistCaptureCalibrationFiles(
          stationDirectory: stationDir.path,
          station: recovered,
          targets: makeTargets(capturedCount: 3),
        );

        expect(
          File(p.join(stationDir.path, '.calibration.pending')).existsSync(),
          isFalse,
        );
        expect(
          File(
            p.join(stationDir.path, '.station.json.calibration-backup'),
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            p.join(stationDir.path, '.targets.json.calibration-backup'),
          ).existsSync(),
          isFalse,
        );
        final station = CaptureStation.fromJson(
          jsonDecode(
                await File(
                  p.join(stationDir.path, 'station.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>,
        );
        expect(station.capturedCount, 3);
        expect(await repo.stationIds(), [stationId]);
      },
    );
  });
}
