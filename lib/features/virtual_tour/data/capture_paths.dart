import 'dart:io';
import 'package:path/path.dart' as p;

/// Directory name for station [index] (0-based).
///
/// Zero-padded so a plain lexicographic directory listing is also the station
/// order. Defined here as a free function because [StationGroup] needs the name
/// before a [CapturePaths] instance exists.
String stationDirNameFor(int index) =>
    'station-${(index + 1).toString().padLeft(2, '0')}';

/// Filesystem layout for a capture session.
///
/// ```
/// <root>/<sessionId>/
///   session.json                 session manifest, incl. resume state
///   station-01/
///     group.json                 this station's own panorama group
///     frames/
///       f000.jpg                 the frame, written the moment it is accepted
///       f000.json                its evidence: pose, target, quality, error
///       f001.jpg
///       ...
///   station-02/
///     ...
/// ```
///
/// **One directory per station.** A station is a panorama group, and groups are
/// never merged: the frames of `station-01` are the only inputs to the
/// `station-01` panorama. Sharing a `frames/` directory between stations is the
/// single easiest way to corrupt a tour, so the layout makes it impossible.
///
/// Frames live under `frames/` rather than beside `group.json` so that the
/// directory listing the uploader walks contains only images.
///
/// This file is deliberately **pure Dart**: no `path_provider`, no Flutter. That
/// keeps [FrameStore] and [CaptureSessionRepository] — and therefore the whole
/// "a frame reaches disk before the machine moves on" contract — testable under
/// a plain `dart` run. The platform default root lives in
/// `app_capture_paths.dart`.
class CapturePaths {
  /// Absolute path of the session root, e.g. `<appDocs>/capture_sessions`.
  final String root;

  const CapturePaths(this.root);

  String sessionDir(String sessionId) => p.join(root, sessionId);

  String manifestFile(String sessionId) =>
      p.join(sessionDir(sessionId), 'session.json');

  /// Directory name for station [index] (0-based). See [stationDirNameFor].
  String stationDirName(int index) => stationDirNameFor(index);

  String stationDir(String sessionId, int index) =>
      p.join(sessionDir(sessionId), stationDirName(index));

  String groupFile(String sessionId, int index) =>
      p.join(stationDir(sessionId, index), 'group.json');

  String framesDir(String sessionId, int index) =>
      p.join(stationDir(sessionId, index), 'frames');

  /// File name for frame [frameIndex]. The target index is zero-padded so that
  /// the frames sort in capture-plan order rather than `f10` before `f2`.
  String frameBaseName(int frameIndex) =>
      'f${frameIndex.toString().padLeft(3, '0')}';

  String frameImage(String sessionId, int index, int frameIndex) =>
      p.join(framesDir(sessionId, index), '${frameBaseName(frameIndex)}.jpg');

  String frameMeta(String sessionId, int index, int frameIndex) =>
      p.join(framesDir(sessionId, index), '${frameBaseName(frameIndex)}.json');

  /// The frame index a stored image name refers to, or `null` when the name is
  /// not one this class wrote.
  ///
  /// The rule lives beside [frameBaseName] rather than at each call site: every
  /// place that turns a directory listing back into a plan index has to use the
  /// same naming, and a re-implementation that disagrees would silently drop a
  /// frame that is really on disk.
  int? frameIndexOf(String path) {
    final name = p.basenameWithoutExtension(path);
    if (name.length != 4 || !name.startsWith('f')) return null;
    final index = int.tryParse(name.substring(1));
    return index == null || index < 0 ? null : index;
  }

  /// Creates every directory a session needs. Idempotent.
  Future<void> ensureSession(String sessionId) async {
    await Directory(framesDir(sessionId, 0)).create(recursive: true);
  }

  Future<void> ensureStation(String sessionId, int index) async {
    await Directory(framesDir(sessionId, index)).create(recursive: true);
  }
}
