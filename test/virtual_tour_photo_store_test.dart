import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/virtual_tour/data/services/virtual_tour_photo_store.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';

/// A structurally valid baseline JPEG: SOI, APP0, SOF0 with [width]×[height],
/// SOS and EOI. The store only reads the markers and the frame header, so the
/// entropy-coded payload can be empty.
Uint8List jpegBytes({int width = 4000, int height = 3000, int padding = 0}) {
  final bytes = <int>[
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
    ...List<int>.filled(14, 0),
    0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, 8-bit precision
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x03, // three components
    0x01, 0x11, 0x00,
    0x02, 0x11, 0x01,
    0x03, 0x11, 0x01,
    0xFF, 0xDA, 0x00, 0x0C, // SOS, length 12
    ...List<int>.filled(10, 0),
    ...List<int>.filled(padding, 0x00),
    0xFF, 0xD9, // EOI
  ];
  return Uint8List.fromList(bytes);
}

Matcher throwsVirtualTourFailure([String? fragment]) {
  if (fragment == null) return throwsA(isA<VirtualTourFailure>());
  return throwsA(
    isA<VirtualTourFailure>().having(
      (failure) => failure.message,
      'message',
      contains(fragment),
    ),
  );
}

void main() {
  late Directory root;
  late VirtualTourPhotoStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('virtual_tour_photo_store');
    store = VirtualTourPhotoStore(root: root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('JPEG inspection', () {
    test('reads frame dimensions from the SOF segment', () {
      final info = VirtualTourPhotoStore.inspectJpeg(
        jpegBytes(width: 4032, height: 3024),
      );
      expect(info.width, 4032);
      expect(info.height, 3024);
    });

    test('reads dimensions from a progressive SOF2 frame', () {
      final bytes = jpegBytes(width: 1920, height: 1080);
      // SOF0 marker sits at offset 20 in the fixture.
      expect(bytes[20], 0xFF);
      expect(bytes[21], 0xC0);
      bytes[21] = 0xC2;
      final info = VirtualTourPhotoStore.inspectJpeg(bytes);
      expect(info.width, 1920);
      expect(info.height, 1080);
    });

    test('rejects data that is not a JPEG', () {
      expect(
        () => VirtualTourPhotoStore.inspectJpeg(
          Uint8List.fromList([1, 2, 3, 4, 5]),
        ),
        throwsVirtualTourFailure('not a JPEG'),
      );
    });

    test('rejects a truncated JPEG without an end marker', () {
      final full = jpegBytes();
      final truncated = Uint8List.sublistView(full, 0, full.length - 2);
      expect(
        () => VirtualTourPhotoStore.inspectJpeg(truncated),
        throwsVirtualTourFailure('truncated'),
      );
    });

    test('rejects a JPEG with no frame header', () {
      final bytes = Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xDA,
        0x00,
        0x02,
        0xFF,
        0xD9,
      ]);
      expect(
        () => VirtualTourPhotoStore.inspectJpeg(bytes),
        throwsVirtualTourFailure('without a frame header'),
      );
    });
  });

  group('saveJpeg', () {
    test('writes, reads back and reports the stored JPEG', () async {
      final bytes = jpegBytes(width: 4000, height: 3000, padding: 64);
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: bytes,
        expectedWidth: 4000,
        expectedHeight: 3000,
      );

      expect(saved.file.existsSync(), isTrue);
      expect(
        saved.file.path,
        store.pathFor(tourId: 'tour-1', index: 0, nodeId: 'h01'),
      );
      expect(p.basename(saved.file.path), '01_h01.jpg');
      expect(saved.byteCount, bytes.length);
      expect(saved.width, 4000);
      expect(saved.height, 3000);
      expect(await saved.file.readAsBytes(), bytes);
      expect(File('${saved.file.path}.part').existsSync(), isFalse);
    });

    test('names frames in capture order', () {
      expect(VirtualTourPhotoStore.fileNameFor(0, 'h01'), '01_h01.jpg');
      expect(VirtualTourPhotoStore.fileNameFor(9, 'u02'), '10_u02.jpg');
      expect(VirtualTourPhotoStore.fileNameFor(29, 'nadir'), '30_nadir.jpg');
    });

    test('replaces an existing frame on retry', () async {
      final first = jpegBytes(width: 100, height: 100, padding: 8);
      final second = jpegBytes(width: 200, height: 200, padding: 32);
      await store.saveJpeg(
        tourId: 'tour-1',
        index: 4,
        nodeId: 'h05',
        bytes: first,
      );
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 4,
        nodeId: 'h05',
        bytes: second,
      );

      expect(await saved.file.readAsBytes(), second);
      expect(saved.width, 200);
      expect(saved.height, 200);
    });

    test('accepts a frame whose SOF dimensions are swapped', () async {
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 2,
        nodeId: 'h03',
        bytes: jpegBytes(width: 3000, height: 4000),
        expectedWidth: 4000,
        expectedHeight: 3000,
      );
      expect(saved.width, 3000);
      expect(saved.height, 4000);
    });

    test('a rejected frame leaves the previous valid frame intact', () async {
      final valid = jpegBytes(width: 640, height: 480);
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 1,
        nodeId: 'h02',
        bytes: valid,
        generation: 1,
      );
      expect(saved.file.existsSync(), isTrue);

      await expectLater(
        store.saveJpeg(
          tourId: 'tour-1',
          index: 1,
          nodeId: 'h02',
          bytes: jpegBytes(width: 640, height: 480, padding: 4),
          expectedWidth: 4000,
          expectedHeight: 3000,
          generation: 2,
        ),
        throwsVirtualTourFailure('640×480'),
      );
      // The rejected write never replaced the target: the good frame is still
      // the one that will be uploaded, and no scratch file is left beside it.
      expect(await saved.file.readAsBytes(), valid);
      expect(store.tourDirectory('tour-1').listSync(), hasLength(1));
    });

    test('rejects an empty capture and leaves nothing on disk', () async {
      await expectLater(
        store.saveJpeg(
          tourId: 'tour-1',
          index: 0,
          nodeId: 'h01',
          bytes: Uint8List(0),
        ),
        throwsVirtualTourFailure('empty image'),
      );
      expect(store.tourDirectory('tour-1').existsSync(), isFalse);
    });

    test('rejects a target id that escapes the tour directory', () async {
      for (final nodeId in <String>['../h01', 'a/b', r'a\b', '..']) {
        await expectLater(
          store.saveJpeg(
            tourId: 'tour-1',
            index: 0,
            nodeId: nodeId,
            bytes: jpegBytes(),
          ),
          throwsVirtualTourFailure('cannot be used as a file name'),
        );
      }
      expect(store.tourDirectory('tour-1').existsSync(), isFalse);
    });
  });

  group('generations', () {
    test('an older save cannot overwrite a newer frame', () async {
      final newer = jpegBytes(width: 200, height: 200, padding: 32);
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: newer,
        generation: 2,
      );

      await expectLater(
        store.saveJpeg(
          tourId: 'tour-1',
          index: 0,
          nodeId: 'h01',
          bytes: jpegBytes(width: 100, height: 100, padding: 8),
          generation: 1,
        ),
        throwsVirtualTourFailure('superseded'),
      );

      expect(await saved.file.readAsBytes(), newer);
      expect(store.tourDirectory('tour-1').listSync(), hasLength(1));
    });

    test('a stale cleanup cannot delete a newer frame', () async {
      final newer = jpegBytes(width: 200, height: 200, padding: 32);
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: newer,
        generation: 2,
      );

      // This is the timeout callback from the attempt that generation 1 lost.
      await store.deletePhoto(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        generation: 1,
      );
      expect(saved.file.existsSync(), isTrue);
      expect(await saved.file.readAsBytes(), newer);

      await store.deletePhoto(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        generation: 2,
      );
      expect(saved.file.existsSync(), isFalse);
    });

    test('concurrent saves are serialized and the newest wins', () async {
      final first = jpegBytes(width: 100, height: 100, padding: 8);
      final second = jpegBytes(width: 200, height: 200, padding: 32);
      final firstFuture = store
          .saveJpeg(
            tourId: 'tour-1',
            index: 0,
            nodeId: 'h01',
            bytes: first,
            generation: 1,
          )
          .then<Object?>(
            (VirtualTourSavedPhoto photo) => photo,
            onError: (Object error) => error,
          );
      final secondFuture = store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: second,
        generation: 2,
      );

      // The older attempt either commits first or loses to the newer one; in
      // both orders generation 2 is the file left on disk.
      final firstOutcome = await firstFuture;
      final saved = await secondFuture;
      expect(
        firstOutcome,
        anyOf(isA<VirtualTourSavedPhoto>(), isA<VirtualTourFailure>()),
      );
      expect(await saved.file.readAsBytes(), second);
      expect(saved.width, 200);
      expect(store.tourDirectory('tour-1').listSync(), hasLength(1));
    });

    test('clearTour removes every frame and scratch file', () async {
      await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: jpegBytes(padding: 8),
      );
      await store.saveJpeg(
        tourId: 'tour-1',
        index: 1,
        nodeId: 'h02',
        bytes: jpegBytes(padding: 8),
      );
      final scratch = File(
        '${store.pathFor(tourId: 'tour-1', index: 0, nodeId: 'h01')}.99.part',
      );
      await scratch.writeAsBytes(jpegBytes(padding: 1));

      await store.clearTour('tour-1');

      expect(store.tourDirectory('tour-1').existsSync(), isFalse);
    });
  });

  group('deletePhoto', () {
    test('removes the frame and any partial file', () async {
      final saved = await store.saveJpeg(
        tourId: 'tour-1',
        index: 0,
        nodeId: 'h01',
        bytes: jpegBytes(padding: 16),
        generation: 3,
      );
      final oldPartial = File('${saved.file.path}.part');
      final generationPartial = File('${saved.file.path}.4.part');
      await oldPartial.writeAsBytes(jpegBytes(padding: 4));
      await generationPartial.writeAsBytes(jpegBytes(padding: 4));

      await store.deletePhoto(tourId: 'tour-1', index: 0, nodeId: 'h01');

      expect(saved.file.existsSync(), isFalse);
      expect(oldPartial.existsSync(), isFalse);
      expect(generationPartial.existsSync(), isFalse);
    });

    test('is quiet when the frame was never written', () async {
      await store.deletePhoto(tourId: 'tour-1', index: 0, nodeId: 'h01');
      expect(store.tourDirectory('tour-1').existsSync(), isFalse);
    });
  });
}
