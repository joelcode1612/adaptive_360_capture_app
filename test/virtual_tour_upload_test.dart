import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/virtual_tour/data/datasources/virtual_tour_local_data_source.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/datasources/virtual_tour_remote_data_source.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/repositories/virtual_tour_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/services/virtual_tour_photo_store.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/repositories/virtual_tour_repository.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/bloc/virtual_tour_bloc.dart';

final DateTime capturedAt = DateTime.utc(2026, 10, 25, 9, 30);

List<PanoramaImage> imagesFor(String tourId, {int count = 30}) =>
    <PanoramaImage>[
      for (var i = 0; i < count; i++)
        PanoramaImage(
          nodeId: 'n${(i + 1).toString().padLeft(2, '0')}',
          filePath: '/tmp/$tourId/${i + 1}.jpg',
          yawDeg: i * 12,
          pitchDeg: i.isEven ? 0 : 35,
          capturedAt: capturedAt.add(Duration(seconds: i)),
        ),
    ];

final StitchedPanorama stitched = StitchedPanorama(
  url: 'https://cdn.example.test/tours/tour-1/panorama.jpg',
  width: 8192,
  height: 4096,
  format: 'jpeg',
  stitchedAt: DateTime.utc(2026, 10, 25, 9, 40),
);

StitchedPanorama panoramaResult() => StitchedPanorama(
  url: stitched.url,
  width: stitched.width,
  height: stitched.height,
  stitchedAt: DateTime.utc(2026, 10, 25, 9, 40),
);

class FakeRemote implements VirtualTourRemoteDataSource {
  FakeRemote({this.panorama});

  int stitchCalls = 0;
  int submitCalls = 0;
  final List<List<PanoramaImage>> receivedImages = <List<PanoramaImage>>[];
  final List<String> receivedTourIds = <String>[];

  int stitchFailuresRemaining = 0;
  int submitFailuresRemaining = 0;
  VirtualTourFailure stitchFailure = const VirtualTourFailure(
    'The stitching service is unavailable.',
  );
  VirtualTourFailure submitFailure = const VirtualTourFailure(
    'The verification service is unavailable.',
  );

  Completer<StitchedPanorama>? stitchGate;

  StitchedPanorama? panorama;

  VirtualTourSubmission submission = VirtualTourSubmission(
    tourId: 'tour-1',
    status: 'pending_verification',
    verificationId: 'verification-42',
    submittedAt: DateTime.utc(2026, 10, 25, 9, 41),
  );

  @override
  Future<StitchedPanorama> stitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  }) async {
    stitchCalls++;
    receivedTourIds.add(tourId);
    receivedImages.add(images);
    if (stitchFailuresRemaining > 0) {
      stitchFailuresRemaining--;
      throw stitchFailure;
    }
    final gate = stitchGate;
    if (gate != null) return gate.future;
    return panorama ?? panoramaResult();
  }

  @override
  Future<VirtualTourSubmission> submitForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  }) async {
    submitCalls++;
    if (submitFailuresRemaining > 0) {
      submitFailuresRemaining--;
      throw submitFailure;
    }
    return submission;
  }

  @override
  Future<void> dispose() async {}
}

class FakeRepository implements VirtualTourRepository {
  int stitchCalls = 0;
  int submitCalls = 0;
  final List<List<PanoramaImage>> receivedImages = <List<PanoramaImage>>[];

  int stitchFailuresRemaining = 0;
  int submitFailuresRemaining = 0;
  VirtualTourFailure stitchFailure = const VirtualTourFailure(
    'The stitching service is unavailable.',
  );
  VirtualTourFailure submitFailure = const VirtualTourFailure(
    'The verification service is unavailable.',
  );

  Completer<StitchedPanorama>? stitchGate;
  StitchedPanorama? panorama;

  VirtualTourSubmission submission = VirtualTourSubmission(
    tourId: 'tour-1',
    status: 'pending_verification',
    verificationId: 'verification-42',
    submittedAt: DateTime.utc(2026, 10, 25, 9, 41),
  );

  @override
  Future<StitchedPanorama> uploadAndStitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  }) {
    stitchCalls++;
    receivedImages.add(images);
    if (stitchFailuresRemaining > 0) {
      stitchFailuresRemaining--;
      return Future<StitchedPanorama>.error(stitchFailure);
    }
    final gate = stitchGate;
    if (gate != null) return gate.future;
    return Future<StitchedPanorama>.value(panorama ?? panoramaResult());
  }

  @override
  Future<VirtualTourSubmission> submitVirtualTourForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  }) {
    submitCalls++;
    if (submitFailuresRemaining > 0) {
      submitFailuresRemaining--;
      return Future<VirtualTourSubmission>.error(submitFailure);
    }
    return Future<VirtualTourSubmission>.value(submission);
  }
}

Future<void> settle() async {
  for (var i = 0; i < 16; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

VirtualTourStitchRequested stitchEvent({List<PanoramaImage>? images}) =>
    VirtualTourStitchRequested(
      tourId: 'tour-1',
      propertyId: 'property-1',
      stationId: 'station-1',
      images: images ?? imagesFor('tour-1'),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('virtual_tour_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('repository', () {
    late FakeRemote remote;
    late VirtualTourLocalDataSource local;
    late VirtualTourRepositoryImpl repository;

    setUp(() {
      remote = FakeRemote();
      local = VirtualTourLocalDataSource(root: tempDir);
      repository = VirtualTourRepositoryImpl(remote: remote, local: local);
    });

    test(
      'stitches first, then writes 30 captures, one panorama and the tour',
      () async {
        final images = imagesFor('tour-1');
        final result = await repository.uploadAndStitchPanorama(
          tourId: 'tour-1',
          propertyId: 'property-1',
          stationId: 'station-1',
          images: images,
        );

        expect(result.url, stitched.url);
        expect(remote.stitchCalls, 1);
        expect(remote.receivedTourIds, <String>['tour-1']);
        expect(remote.receivedImages.single.length, 30);

        final photos = await local.propertyPhotos('tour-1');
        expect(photos.length, 31);
        final captures = photos.where(
          (r) => r.kind == PropertyPhotoRecord.kindCapture,
        );
        expect(captures.length, 30);
        expect(captures.map((r) => r.nodeId).toSet().length, 30);
        expect(captures.first.id, 'tour-1_n01');
        expect(captures.first.location, '/tmp/tour-1/1.jpg');
        expect(captures.first.yawDeg, 0);
        expect(captures.first.pitchDeg, 0);

        final panoramas = photos.where(
          (r) => r.kind == PropertyPhotoRecord.kindPanorama,
        );
        expect(panoramas.length, 1);
        expect(panoramas.single.id, 'tour-1_panorama');
        expect(panoramas.single.location, stitched.url);
        expect(panoramas.single.width, 8192);
        expect(panoramas.single.height, 4096);
        expect(panoramas.single.sourceCount, 30);

        final tour = await local.virtualTour('tour-1');
        expect(tour, isNotNull);
        expect(tour!.status, 'stitched');
        expect(tour.panoramaUrl, stitched.url);
        expect(tour.photoCount, 30);
        expect(tour.submittedAt, isNull);
        expect(tour.verificationId, isNull);
      },
    );

    test('a retry upserts instead of duplicating rows', () async {
      final images = imagesFor('tour-1');
      await repository.uploadAndStitchPanorama(
        tourId: 'tour-1',
        propertyId: 'property-1',
        stationId: 'station-1',
        images: images,
      );
      final first = await local.virtualTour('tour-1');

      await repository.uploadAndStitchPanorama(
        tourId: 'tour-1',
        propertyId: 'property-1',
        stationId: 'station-1',
        images: images,
      );

      expect((await local.propertyPhotos('tour-1')).length, 31);
      expect((await local.listVirtualTours()).length, 1);
      final second = await local.virtualTour('tour-1');
      expect(second!.createdAt, first!.createdAt);
      expect(second.status, 'stitched');
    });

    test('submitting requires a stored panorama', () async {
      await expectLater(
        repository.submitVirtualTourForVerification(
          tourId: 'tour-1',
          panoramas: <StitchedPanorama>[panoramaResult()],
        ),
        throwsA(
          isA<VirtualTourFailure>()
              .having((f) => f.retryable, 'retryable', isFalse)
              .having((f) => f.message, 'message', contains('Stitch it first')),
        ),
      );
      expect(remote.submitCalls, 0);
    });

    test('submit records status, time and verification id', () async {
      await repository.uploadAndStitchPanorama(
        tourId: 'tour-1',
        propertyId: 'property-1',
        stationId: 'station-1',
        images: imagesFor('tour-1'),
      );

      final submission = await repository.submitVirtualTourForVerification(
        tourId: 'tour-1',
        panoramas: <StitchedPanorama>[panoramaResult()],
      );
      expect(submission.status, 'pending_verification');
      expect(submission.verificationId, 'verification-42');
      expect(remote.submitCalls, 1);

      final tour = await local.virtualTour('tour-1');
      expect(tour!.status, 'pending_verification');
      expect(tour.verificationId, 'verification-42');
      expect(tour.submittedAt, submission.submittedAt);
    });

    test('re-stitching does not undo a started verification', () async {
      await repository.uploadAndStitchPanorama(
        tourId: 'tour-1',
        propertyId: 'property-1',
        stationId: 'station-1',
        images: imagesFor('tour-1'),
      );
      await repository.submitVirtualTourForVerification(
        tourId: 'tour-1',
        panoramas: <StitchedPanorama>[panoramaResult()],
      );

      await repository.uploadAndStitchPanorama(
        tourId: 'tour-1',
        propertyId: 'property-1',
        stationId: 'station-1',
        images: imagesFor('tour-1'),
      );

      final tour = await local.virtualTour('tour-1');
      expect(tour!.status, 'pending_verification');
      expect(tour.verificationId, 'verification-42');
      expect(tour.submittedAt, isNotNull);
    });

    test('empty input fails without touching the service', () async {
      await expectLater(
        repository.uploadAndStitchPanorama(
          tourId: 'tour-1',
          propertyId: 'property-1',
          stationId: 'station-1',
          images: const <PanoramaImage>[],
        ),
        throwsA(
          isA<VirtualTourFailure>().having(
            (f) => f.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
      await expectLater(
        repository.submitVirtualTourForVerification(
          tourId: 'tour-1',
          panoramas: const <StitchedPanorama>[],
        ),
        throwsA(isA<VirtualTourFailure>()),
      );
      expect(remote.stitchCalls, 0);
      expect(remote.submitCalls, 0);
    });
  });

  group('HTTP remote', () {
    late File first;
    late File second;

    setUp(() async {
      first = File(p.join(tempDir.path, 'first.jpg'))
        ..writeAsBytesSync(Uint8List.fromList(<int>[0xff, 0xd8, 1, 2, 3]));
      second = File(p.join(tempDir.path, 'second.jpg'))
        ..writeAsBytesSync(Uint8List.fromList(<int>[0xff, 0xd8, 4, 5, 6]));
    });

    List<PanoramaImage> twoImages() => <PanoramaImage>[
      PanoramaImage(
        nodeId: 'h01',
        filePath: first.path,
        yawDeg: 0,
        pitchDeg: 0,
        capturedAt: capturedAt,
      ),
      PanoramaImage(
        nodeId: 'h02',
        filePath: second.path,
        yawDeg: 30,
        pitchDeg: 0,
        capturedAt: capturedAt,
      ),
    ];

    test(
      'sends one multipart request with a manifest and every JPEG',
      () async {
        late http.Request seen;
        final client = MockClient((http.Request request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'panorama_url': '/tours/tour-9/panorama.jpg',
              'width': 4096,
              'height': 2048,
              'stitched_at': '2026-10-25T09:45:00Z',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final remote = HttpVirtualTourRemoteDataSource(
          config: VirtualTourApiConfig(
            baseUri: Uri.parse('https://api.example.test'),
          ),
          client: client,
        );

        final result = await remote.stitchPanorama(
          tourId: 'tour-9',
          propertyId: 'property-1',
          stationId: 'station-1',
          images: twoImages(),
        );

        expect(seen.method, 'POST');
        expect(
          seen.url.toString(),
          'https://api.example.test/api/v1/panoramas/stitch',
        );
        expect(seen.headers['content-type'], contains('multipart/form-data'));
        final body = latin1.decode(seen.bodyBytes);
        expect(body, contains('name="tour_id"'));
        expect(body, contains('tour-9'));
        expect(body, contains('name="manifest"'));
        expect(body, contains('"nodeId":"h01"'));
        expect(body, contains('filename="01_h01.jpg"'));
        expect(body, contains('filename="02_h02.jpg"'));
        expect(body, contains('name="images"; filename="01_h01.jpg"'));

        expect(
          result.url,
          'https://api.example.test/tours/tour-9/panorama.jpg',
        );
        expect(result.width, 4096);
        expect(result.height, 2048);
        expect(result.simulated, isFalse);
        await remote.dispose();
      },
    );

    test('a 5xx is retryable and a missing file is not', () async {
      final client = MockClient(
        (http.Request request) async => http.Response('service down', 503),
      );
      final remote = HttpVirtualTourRemoteDataSource(
        config: VirtualTourApiConfig(
          baseUri: Uri.parse('https://api.example.test'),
        ),
        client: client,
      );

      await expectLater(
        remote.stitchPanorama(
          tourId: 'tour-9',
          propertyId: 'property-1',
          stationId: 'station-1',
          images: twoImages(),
        ),
        throwsA(
          isA<VirtualTourFailure>()
              .having((f) => f.retryable, 'retryable', isTrue)
              .having((f) => f.message, 'message', contains('503')),
        ),
      );

      await expectLater(
        remote.stitchPanorama(
          tourId: 'tour-9',
          propertyId: 'property-1',
          stationId: 'station-1',
          images: <PanoramaImage>[
            PanoramaImage(
              nodeId: 'h01',
              filePath: p.join(tempDir.path, 'missing.jpg'),
              yawDeg: 0,
              pitchDeg: 0,
              capturedAt: capturedAt,
            ),
          ],
        ),
        throwsA(
          isA<VirtualTourFailure>().having(
            (f) => f.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
      await remote.dispose();
    });

    test('submits JSON and reads the verification acknowledgement', () async {
      late http.Request seen;
      final client = MockClient((http.Request request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'status': 'pending_verification',
            'verification_id': 'verification-7',
            'submitted_at': '2026-10-25T10:00:00Z',
          }),
          202,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final remote = HttpVirtualTourRemoteDataSource(
        config: VirtualTourApiConfig(
          baseUri: Uri.parse('https://api.example.test'),
        ),
        client: client,
      );

      final submission = await remote.submitForVerification(
        tourId: 'tour-9',
        panoramas: <StitchedPanorama>[panoramaResult()],
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'https://api.example.test/api/v1/virtual-tours/tour-9/submit',
      );
      expect(seen.headers['content-type'], contains('application/json'));
      final decoded = jsonDecode(seen.body) as Map<String, Object?>;
      expect(decoded['tour_id'], 'tour-9');
      expect((decoded['panoramas']! as List<Object?>).length, 1);

      expect(submission.status, 'pending_verification');
      expect(submission.verificationId, 'verification-7');
      expect(submission.submittedAt, DateTime.utc(2026, 10, 25, 10));
      await remote.dispose();
    });
  });

  group('photo store', () {
    Uint8List jpegFixture({int padding = 0}) => Uint8List.fromList(<int>[
      0xFF, 0xD8, // SOI
      0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17
      0x00, 0x01, 0x00, 0x01, // 1×1
      0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
      0xFF, 0xDA, // SOS
      ...List<int>.filled(padding, 0),
      0xFF, 0xD9, // EOI
    ]);

    test('writes NN_nodeId.jpg atomically and verifies the bytes', () async {
      final store = VirtualTourPhotoStore(root: tempDir);
      final bytes = jpegFixture(padding: 32);
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: bytes,
      );

      expect(p.basename(saved.file.path), '01_h01.jpg');
      expect(p.join(tempDir.path, 'tour-1', '01_h01.jpg'), saved.file.path);
      expect(saved.file.existsSync(), isTrue);
      expect(saved.byteCount, bytes.length);
      expect(await saved.file.length(), bytes.length);
      expect(await saved.file.readAsBytes(), bytes);
      expect(File('${saved.file.path}.part').existsSync(), isFalse);

      final smaller = jpegFixture();
      await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: smaller,
      );
      expect(await saved.file.length(), smaller.length);
    });

    test('rejects an empty frame instead of writing a 0-byte JPEG', () async {
      final store = VirtualTourPhotoStore(root: tempDir);
      await expectLater(
        store.saveJpeg(
          tourId: 'tour-1',
          index: 4,
          nodeId: 'h05',
          bytes: Uint8List(0),
        ),
        throwsA(isA<VirtualTourFailure>()),
      );
      expect(
        File(p.join(tempDir.path, 'tour-1', '05_h05.jpg')).existsSync(),
        isFalse,
      );
    });
  });

  group('bloc', () {
    late FakeRepository remote;
    late VirtualTourBloc bloc;

    setUp(() {
      remote = FakeRepository();
      bloc = VirtualTourBloc(repository: remote, stageDelay: Duration.zero);
    });

    tearDown(() async {
      await bloc.close();
    });

    test('runs uploading → stitching → success (REQ-807)', () async {
      final states = <VirtualTourState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      bloc.add(stitchEvent());
      await settle();

      expect(states.length, 3);
      expect(states[0], isA<VirtualTourProcessing>());
      expect(
        (states[0] as VirtualTourProcessing).stage,
        VirtualTourStage.uploading,
      );
      expect(
        (states[1] as VirtualTourProcessing).stage,
        VirtualTourStage.stitching,
      );
      final success = states[2] as VirtualTourSuccess;
      expect(success.panorama.url, stitched.url);
      expect(success.submitted, isFalse);
    });

    test('a second request while one is running is ignored', () async {
      remote.stitchGate = Completer<StitchedPanorama>();
      bloc.add(stitchEvent());
      await settle();
      expect(remote.stitchCalls, 1);

      bloc.add(stitchEvent());
      await settle();
      expect(remote.stitchCalls, 1);

      remote.stitchGate!.complete(panoramaResult());
      await settle();
      expect(bloc.state, isA<VirtualTourSuccess>());

      // A stitch after success is a duplicate too.
      bloc.add(stitchEvent());
      await settle();
      expect(remote.stitchCalls, 1);
    });

    test(
      'a retryable failure emits an error and retries the same payload',
      () async {
        remote.stitchFailuresRemaining = 1;
        final states = <VirtualTourState>[];
        final sub = bloc.stream.listen(states.add);
        addTearDown(sub.cancel);

        bloc.add(stitchEvent());
        await settle();

        final error = states.whereType<VirtualTourError>().single;
        expect(error.retryable, isTrue);
        expect(error.stage, VirtualTourStage.stitching);

        bloc.add(const VirtualTourRetryRequested());
        await settle();

        expect(remote.stitchCalls, 2);
        expect(remote.receivedImages[0], remote.receivedImages[1]);
        expect(bloc.state, isA<VirtualTourSuccess>());

        // There is nothing left to retry.
        bloc.add(const VirtualTourRetryRequested());
        await settle();
        expect(remote.stitchCalls, 2);
      },
    );

    test('an empty request is a non-retryable validation error', () async {
      bloc.add(stitchEvent(images: const <PanoramaImage>[]));
      await settle();

      final error = bloc.state as VirtualTourError;
      expect(error.stage, VirtualTourStage.validation);
      expect(error.retryable, isFalse);
      expect(remote.stitchCalls, 0);
    });

    test(
      'reset makes a late response stale instead of emitting success',
      () async {
        remote.stitchGate = Completer<StitchedPanorama>();
        final states = <VirtualTourState>[];
        final sub = bloc.stream.listen(states.add);
        addTearDown(sub.cancel);

        bloc.add(stitchEvent());
        await settle();
        expect(bloc.state, isA<VirtualTourProcessing>());

        bloc.add(const VirtualTourResetRequested());
        await settle();
        expect(bloc.state, isA<VirtualTourInitial>());

        remote.stitchGate!.complete(panoramaResult());
        await settle();

        expect(states.last, isA<VirtualTourInitial>());
        expect(states.whereType<VirtualTourSuccess>(), isEmpty);
      },
    );

    test('submits the panorama once and keeps the submission', () async {
      bloc.add(stitchEvent());
      await settle();
      final panorama = (bloc.state as VirtualTourSuccess).panorama;

      bloc.add(
        VirtualTourVerificationRequested(
          tourId: 'tour-1',
          panoramas: <StitchedPanorama>[panorama],
        ),
      );
      await settle();

      final success = bloc.state as VirtualTourSuccess;
      expect(success.submitted, isTrue);
      expect(success.submission!.status, 'pending_verification');
      expect(success.submission!.verificationId, 'verification-42');
      expect(remote.submitCalls, 1);

      bloc.add(
        VirtualTourVerificationRequested(
          tourId: 'tour-1',
          panoramas: <StitchedPanorama>[panorama],
        ),
      );
      await settle();
      expect(remote.submitCalls, 1);
    });

    test('a submit failure keeps the panorama and can be retried', () async {
      remote.submitFailuresRemaining = 1;
      bloc.add(stitchEvent());
      await settle();
      final panorama = (bloc.state as VirtualTourSuccess).panorama;

      bloc.add(
        VirtualTourVerificationRequested(
          tourId: 'tour-1',
          panoramas: <StitchedPanorama>[panorama],
        ),
      );
      await settle();

      final error = bloc.state as VirtualTourError;
      expect(error.stage, VirtualTourStage.submitting);
      expect(error.retryable, isTrue);
      expect(error.panorama!.url, panorama.url);

      bloc.add(const VirtualTourRetryRequested());
      await settle();

      final success = bloc.state as VirtualTourSuccess;
      expect(success.submitted, isTrue);
      expect(success.panorama.url, panorama.url);
      expect(remote.submitCalls, 2);
    });
  });
}
