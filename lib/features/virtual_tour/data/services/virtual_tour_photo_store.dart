import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';

/// A JPEG that has been written, read back and structurally checked.
class VirtualTourSavedPhoto {
  final File file;
  final int byteCount;
  final int width;
  final int height;

  const VirtualTourSavedPhoto({
    required this.file,
    required this.byteCount,
    required this.width,
    required this.height,
  });
}

/// Dimensions and structural markers read from a JPEG byte stream.
class VirtualTourJpegInfo {
  final int width;
  final int height;

  const VirtualTourJpegInfo({required this.width, required this.height});
}

/// Writes the 30 JPEGs of a tour station to the app's private documents area.
///
/// Separate from [VirtualTourLocalDataSource] because these are *files*, not the
/// `PROPERTY_PHOTO` rows that point at them. The repository writes those rows
/// only after the stitching service accepted the upload, so a row never exists
/// for a file that was never saved.
///
/// Each frame is written to `NN_<nodeId>.jpg` — the same order the multipart
/// request uses — through a generation-named `.<n>.part` file and a rename. A
/// crash or a full disk therefore leaves either no file or a complete one,
/// never a truncated JPEG that the stitcher would happily accept as an image.
/// Operations on one target are serialized, and a generation-aware cleanup can
/// never remove a frame written by a newer attempt.
///
/// **Verification is not `length()`.** The write is followed by a full read-back
/// and an exact byte comparison, then the JPEG markers are checked and the
/// frame dimensions read from the SOF segment. A file that fails any check is
/// deleted before the error is reported, so the engine never marks a node
/// captured against a path that cannot be uploaded.
class VirtualTourPhotoStore {
  VirtualTourPhotoStore({required this.root});

  /// The capture root, `…/virtual_tour_captures`.
  final Directory root;

  /// The newest generation that committed a file for each target path.
  final Map<String, int> _generationByPath = <String, int>{};

  /// One pending operation per target path, so two saves cannot interleave
  /// their write/rename steps and a delete cannot race a commit.
  final Map<String, Future<void>> _operations = <String, Future<void>>{};

  int _nextGeneration = 0;

  /// Allocates a monotonically increasing generation for a capture.
  ///
  /// The screen allocates one before a still is requested and passes it to
  /// every save and cleanup for that attempt. A late cleanup from an older
  /// attempt therefore cannot delete a file a newer attempt committed.
  int nextGeneration() => ++_nextGeneration;

  static Future<VirtualTourPhotoStore> createDefault() async {
    final docs = await getApplicationDocumentsDirectory();
    return VirtualTourPhotoStore(
      root: Directory(p.join(docs.path, 'virtual_tour_captures')),
    );
  }

  /// Directory that holds one station's frames.
  Directory tourDirectory(String tourId) =>
      Directory(p.join(root.path, tourId));

  /// The final path of a node's frame, whether or not it exists yet.
  String pathFor({
    required String tourId,
    required int index,
    required String nodeId,
  }) => p.join(tourDirectory(tourId).path, fileNameFor(index, nodeId));

  static String fileNameFor(int index, String nodeId) =>
      '${(index + 1).toString().padLeft(2, '0')}_$nodeId.jpg';

  /// Saves [bytes] and proves they are readable on disk before returning.
  ///
  /// [expectedWidth] and [expectedHeight] are the oriented dimensions reported
  /// by the camera. The check accepts the swapped pair as well, because a JPEG
  /// may carry its rotation in EXIF rather than in its SOF dimensions.
  Future<VirtualTourSavedPhoto> saveJpeg({
    required String tourId,
    required int index,
    required String nodeId,
    required Uint8List bytes,
    int? expectedWidth,
    int? expectedHeight,
    int? generation,
  }) async {
    if (bytes.isEmpty) {
      throw const VirtualTourFailure(
        'The camera returned an empty image, so nothing was saved.',
      );
    }
    if (nodeId.isEmpty ||
        nodeId.contains('/') ||
        nodeId.contains('\\') ||
        nodeId.contains('..')) {
      throw VirtualTourFailure(
        'The target id "$nodeId" cannot be used as a file name.',
      );
    }

    final useGeneration = generation ?? nextGeneration();
    final directory = tourDirectory(tourId);
    await directory.create(recursive: true);
    final name = fileNameFor(index, nodeId);
    final target = File(p.join(directory.path, name));
    if (p.basename(target.path) != name ||
        !p.basenameWithoutExtension(target.path).endsWith('_$nodeId')) {
      throw VirtualTourFailure(
        'The photograph path for node $nodeId does not match its target id.',
      );
    }
    // The generation is part of the partial's name, so two attempts can never
    // share a scratch file even if a caller bypasses the serialization below.
    final partial = File('${target.path}.$useGeneration.part');

    try {
      await partial.writeAsBytes(bytes, flush: true);

      // Validate the partial *before* it can replace anything. The previous
      // build renamed first and, on any later failure, deleted the target
      // unconditionally — so a corrupt retry destroyed the good frame that was
      // already on disk.
      final written = await partial.readAsBytes();
      if (written.length != bytes.length) {
        throw VirtualTourFailure(
          'The photograph for node $nodeId was truncated: ${bytes.length} bytes '
          'were captured but ${written.length} reached the disk.',
        );
      }
      if (!_bytesEqual(written, bytes)) {
        throw VirtualTourFailure(
          'The photograph for node $nodeId changed while being written to disk.',
        );
      }

      final info = inspectJpeg(written);
      if (expectedWidth != null &&
          expectedHeight != null &&
          !_dimensionsMatch(
            actualWidth: info.width,
            actualHeight: info.height,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
          )) {
        throw VirtualTourFailure(
          'The photograph for node $nodeId is '
          '${info.width}×${info.height}, but the camera reported '
          '$expectedWidth×$expectedHeight.',
        );
      }

      return await _serialized(target.path, () async {
        final current = _generationByPath[target.path] ?? -1;
        if (useGeneration < current) {
          throw VirtualTourFailure(
            'The photograph for node $nodeId was superseded by a newer '
            'capture and was not written.',
          );
        }
        if (await target.exists()) await target.delete();
        await partial.rename(target.path);
        _generationByPath[target.path] = useGeneration;
        return VirtualTourSavedPhoto(
          file: target,
          byteCount: written.length,
          width: info.width,
          height: info.height,
        );
      });
    } catch (e) {
      // Only the partial is ours to remove. The target may belong to an older
      // generation and must survive a failed newer attempt.
      await _deleteQuietly(partial);
      if (e is VirtualTourFailure) rethrow;
      throw VirtualTourFailure(
        'The photograph for node $nodeId could not be written: $e',
      );
    }
  }

  /// Removes one node's frame and its in-flight partial files.
  ///
  /// When [generation] is given the removal is conditional: a newer capture
  /// that has already committed keeps its file, and only that generation's
  /// partial is deleted. A late timeout callback therefore cannot erase a
  /// photograph the user has just taken successfully.
  Future<void> deletePhoto({
    required String tourId,
    required int index,
    required String nodeId,
    int? generation,
  }) async {
    final path = pathFor(tourId: tourId, index: index, nodeId: nodeId);
    await _serialized(path, () async {
      if (generation != null) {
        await _deleteQuietly(File('$path.$generation.part'));
        final current = _generationByPath[path];
        if (current == null || current > generation) return;
        _generationByPath.remove(path);
        await _deleteQuietly(File(path));
        return;
      }
      _generationByPath.remove(path);
      await _deleteQuietly(File(path));
      await _deleteParts(path);
    });
  }

  /// Deletes every frame for a tour and waits for queued writes to finish.
  ///
  /// Used when a station is recalibrated: the old frames belong to a world
  /// frame that no longer exists and must not be uploaded with the new one.
  Future<void> clearTour(String tourId) async {
    final directory = tourDirectory(tourId);
    // Wait for the operations already queued for this directory. New captures
    // are prevented by the caller's recalibration state, not by this loop.
    while (true) {
      final pending = _operations.entries
          .where(
            (MapEntry<String, Future<void>> entry) =>
                p.isWithin(directory.path, entry.key),
          )
          .map((MapEntry<String, Future<void>> entry) => entry.value)
          .toList(growable: false);
      if (pending.isEmpty) break;
      await Future.wait<void>(
        pending.map(
          (Future<void> future) =>
              future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
    }
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // A frame that cannot be removed is reported by the next save; clearing
      // the tour must still let the session restart.
    }
    _generationByPath.removeWhere(
      (String key, int _) => p.isWithin(directory.path, key),
    );
  }

  /// Runs [action] after every operation already queued for [key].
  Future<T> _serialized<T>(String key, Future<T> Function() action) async {
    final previous = _operations[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _operations[key] = gate.future;
    try {
      await previous;
      return await action();
    } finally {
      gate.complete();
      if (identical(_operations[key], gate.future)) {
        _operations.remove(key);
      }
    }
  }

  /// Removes `.part` files left for [path] by an explicit delete.
  Future<void> _deleteParts(String path) async {
    final target = File(path);
    final prefix = '${p.basename(path)}.';
    try {
      if (!await target.parent.exists()) return;
      await for (final entity in target.parent.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) && name.endsWith('.part')) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // Cleanup is best-effort; the delete that matters has already happened.
    }
  }

  /// Reads the dimensions from a structurally valid baseline/progressive JPEG.
  ///
  /// Throws [VirtualTourFailure] when the SOI or EOI marker is missing or no
  /// frame header appears before the scan data. This is not a full decode — the
  /// UI additionally asks Flutter's codec to decode the frame — but it catches
  /// truncation and arbitrary non-JPEG bytes, which is what a failed camera
  /// capture returns.
  static VirtualTourJpegInfo inspectJpeg(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      throw const VirtualTourFailure(
        'The camera returned data that is not a JPEG image.',
      );
    }
    if (bytes[bytes.length - 2] != 0xFF || bytes[bytes.length - 1] != 0xD9) {
      throw const VirtualTourFailure(
        'The camera returned a truncated JPEG without an end marker.',
      );
    }

    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      var marker = bytes[offset + 1];
      while (marker == 0xFF) {
        offset++;
        if (offset + 1 >= bytes.length) break;
        marker = bytes[offset + 1];
      }
      if (marker == 0xD9 || marker == 0xDA) break;
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if (offset + 4 > bytes.length) break;
      final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2 || offset + 2 + length > bytes.length) {
        throw const VirtualTourFailure(
          'The camera returned a JPEG with a corrupt segment.',
        );
      }
      if (_isStartOfFrame(marker)) {
        if (length < 7) {
          throw const VirtualTourFailure(
            'The camera returned a JPEG without frame dimensions.',
          );
        }
        final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
        final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
        if (width <= 0 || height <= 0) {
          throw const VirtualTourFailure(
            'The camera returned a JPEG with zero-sized frame dimensions.',
          );
        }
        return VirtualTourJpegInfo(width: width, height: height);
      }
      offset += 2 + length;
    }
    throw const VirtualTourFailure(
      'The camera returned a JPEG without a frame header.',
    );
  }

  static bool _isStartOfFrame(int marker) =>
      (marker >= 0xC0 && marker <= 0xC3) ||
      (marker >= 0xC5 && marker <= 0xC7) ||
      (marker >= 0xC9 && marker <= 0xCB) ||
      (marker >= 0xCD && marker <= 0xCF);

  static bool _dimensionsMatch({
    required int actualWidth,
    required int actualHeight,
    required int expectedWidth,
    required int expectedHeight,
  }) =>
      (actualWidth == expectedWidth && actualHeight == expectedHeight) ||
      (actualWidth == expectedHeight && actualHeight == expectedWidth);

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The failure that matters is the one being reported, not cleanup.
    }
  }
}
