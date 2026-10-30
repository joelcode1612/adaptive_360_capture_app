import 'dart:io';
import 'dart:typed_data';

/// What a read-back of a stored photograph actually proved.
///
/// The brief requires that a frame is never reported as saved unless the file
/// exists and can be opened, and that a frame whose image is broken is offered
/// again instead of being trusted. Reading `group.json` alone cannot tell those
/// apart, so the store asks the filesystem.
///
/// The checks are deliberately ordered from the certain to the merely useful,
/// because a false negative here would block a real capture forever:
///
/// * the file exists and can be opened;
/// * it is not empty;
/// * it starts with the JPEG image-record marker `FF D8`;
/// * it ends with the end-of-image marker `FF D9` — a file that stops in the
///   middle of the scan data was not written completely;
/// * a start-of-frame segment is found, which is where the pixel dimensions are.
///
/// The first four decide whether the frame counts as stored. The last one is
/// reported but does not invalidate a file: a JPEG that carries its markers but
/// whose size header was not found within the read window is still an image, and
/// refusing it would be a guess about the encoder rather than a fact about the
/// file.
enum FrameHealth {
  /// Present, readable, `FF D8` at the front, `FF D9` at the back, and the
  /// pixel dimensions were recovered from a start-of-frame segment.
  verified,

  /// Present, readable and terminated, but no start-of-frame segment was found
  /// in the window that was read. Counted as stored; the size is unknown.
  storedUnsized,

  /// Present and readable, but the JPEG markers are not there — the bytes are
  /// not a JPEG at all, or the file was overwritten with something else.
  notAnImage,

  /// The file ends inside the image: the trailing `FF D9` is missing, which is
  /// what a killed write or a full volume looks like.
  truncated,

  /// Status says the frame was accepted, but there is no file.
  missing,

  /// The file exists but could not be opened — permissions, or it disappeared
  /// between the listing and the read.
  unreadable,
}

/// The read-back result for one frame image.
class FrameIntegrity {
  final String path;
  final FrameHealth health;

  /// Bytes reported by the filesystem, when the file could be opened.
  final int? byteLength;

  /// Pixel dimensions read from the start-of-frame segment, when found.
  final int? width;
  final int? height;

  /// Why an [FrameHealth.unreadable] check failed, for the review screen.
  final String? error;

  const FrameIntegrity({
    required this.path,
    required this.health,
    this.byteLength,
    this.width,
    this.height,
    this.error,
  });

  /// True when the image is safe to treat as an accepted frame.
  ///
  /// `storedUnsized` is included for the reason described on [FrameHealth]: the
  /// markers say the whole image was written, and only the size is unproven.
  bool get isStored =>
      health == FrameHealth.verified || health == FrameHealth.storedUnsized;

  bool get dimensionsKnown => width != null && height != null;

  String get dimensionsLabel => dimensionsKnown
      ? '$width×$height px'
      : health == FrameHealth.verified
      ? 'unknown'
      : 'not read';

  /// One line for the UI, phrased so it can be read next to a photograph.
  String get label => switch (health) {
    FrameHealth.verified =>
      'Read back: $dimensionsLabel, '
          '${_kilobytes(byteLength)}',
    FrameHealth.storedUnsized =>
      'Stored (${_kilobytes(byteLength)}), but no '
          'image size header was found',
    FrameHealth.truncated =>
      'Truncated: the file ends inside the image '
          '(${_kilobytes(byteLength)})',
    FrameHealth.notAnImage =>
      'Not a JPEG: the image markers are missing '
          '(${_kilobytes(byteLength)})',
    FrameHealth.missing => 'No file on disk',
    FrameHealth.unreadable =>
      'Could not be opened${error == null ? '' : ': $error'}',
  };

  static String _kilobytes(int? bytes) => bytes == null
      ? 'unknown size'
      : '${(bytes / 1024).toStringAsFixed(1)} kB';

  @override
  String toString() => 'FrameIntegrity(${health.name}, $path)';
}

/// Reads a frame image back from disk and reports what it proves.
///
/// Pure `dart:io` — no Flutter, no plugins — so the same check runs on the
/// phone and under a plain `dart` test, which is what keeps the "a frame is only
/// done when its bytes are provably there" rule covered by the automated suite
/// rather than only by a device run.
class FrameIntegrityChecker {
  const FrameIntegrityChecker();

  /// How much of the head of the file is scanned for JPEG markers.
  ///
  /// Android camera JPEGs put their start-of-frame segment within the first few
  /// kilobytes, after the JFIF/EXIF/XMP application segments; a megabyte leaves
  /// room for a large embedded thumbnail without reading a whole photograph.
  static const int headWindowBytes = 1 << 20;

  Future<FrameIntegrity> inspect(String path) async {
    final file = File(path);
    RandomAccessFile? raf;
    try {
      if (!await file.exists()) {
        return FrameIntegrity(path: path, health: FrameHealth.missing);
      }
      final length = await file.length();
      if (length < 4) {
        return FrameIntegrity(
          path: path,
          health: FrameHealth.notAnImage,
          byteLength: length,
        );
      }
      raf = await file.open();
      final head = await raf.read(
        length < headWindowBytes ? length : headWindowBytes,
      );
      await raf.setPosition(length - 2);
      final tail = await raf.read(2);
      return _parse(path, length, head, tail);
    } on FileSystemException catch (e) {
      return FrameIntegrity(
        path: path,
        health: FrameHealth.unreadable,
        error: e.osError?.message ?? e.message,
      );
    } finally {
      await raf?.close();
    }
  }

  /// Walks the JPEG marker chain of [head] and checks that [tail] is `FF D9`.
  ///
  /// Segments are followed by their declared length rather than searched for
  /// `FF C0` byte patterns: scan data is arbitrary bytes and can contain a
  /// look-alike marker, which would make a naive search report dimensions for a
  /// corrupt file.
  static FrameIntegrity _parse(
    String path,
    int byteLength,
    Uint8List head,
    List<int> tail,
  ) {
    if (head.length < 2 || head[0] != 0xFF || head[1] != 0xD8) {
      return FrameIntegrity(
        path: path,
        health: FrameHealth.notAnImage,
        byteLength: byteLength,
      );
    }

    final terminated = tail.length == 2 && tail[0] == 0xFF && tail[1] == 0xD9;
    var pos = 2;
    int? width;
    int? height;

    while (pos + 1 < head.length) {
      if (head[pos] != 0xFF) break; // broken framing: stop, do not guess
      final marker = head[pos + 1];
      if (marker == 0xFF) {
        pos++; // fill byte
        continue;
      }
      if (marker == 0xD9) break; // end of image
      if (marker == 0xDA) break; // start of scan: only entropy data follows
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2; // standalone markers carry no length
        continue;
      }
      if (pos + 3 >= head.length) break;
      final segmentLength = (head[pos + 2] << 8) | head[pos + 3];
      if (segmentLength < 2) break;

      // SOF0–SOF15 except DNL (0xC4), and the JPEG-LS/extended family that
      // shares the range. The layout after the length is precision (1),
      // rows (2), columns (2).
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        if (pos + 9 <= head.length) {
          height = (head[pos + 5] << 8) | head[pos + 6];
          width = (head[pos + 7] << 8) | head[pos + 8];
          if (width > 0 && height > 0) {
            return FrameIntegrity(
              path: path,
              health: terminated ? FrameHealth.verified : FrameHealth.truncated,
              byteLength: byteLength,
              width: width,
              height: height,
            );
          }
        }
        break;
      }
      pos += 2 + segmentLength;
    }

    return FrameIntegrity(
      path: path,
      health: terminated ? FrameHealth.storedUnsized : FrameHealth.truncated,
      byteLength: byteLength,
    );
  }
}
