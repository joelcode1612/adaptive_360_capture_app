import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/station_anchor.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/capture_json.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/capture_paths.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/frame_integrity.dart';

/// Where a station got to.
enum StationStatus {
  /// Capturing, or paused mid-sequence.
  inProgress,

  /// The user accepted the station's panorama.
  accepted,

  /// Captured, but VERIFY found gaps or an obstruction and the user has not
  /// yet accepted it. Kept distinct from [inProgress] so a resume knows the
  /// frames are all there and only the review is outstanding.
  needsReview,
}

/// One station: one viewpoint, one panorama group, one directory.
///
/// This is the unit the brief insists must never be merged with another. The
/// class holds no pixels — only the manifest and the per-frame evidence — so it
/// can be read back cheaply when a session resumes.
class StationGroup {
  final String sessionId;
  final int index;
  final String stationId;

  /// Approximate plan position in metres, from the floor-plan step.
  final ({double x, double z}) position;

  /// The ARCore anchor created for this station, when the device supports it.
  /// `null` means "no anchor": either ARCore is unavailable or the user set the
  /// station manually, in which case the drift check is disabled rather than
  /// guessed at.
  StationOrigin? origin;

  /// The plan this station was captured against. Stored per station because a
  /// later station may legitimately use a different FOV.
  final PlanParams planParams;

  /// Plan frame index → progress. A frame is only ever `ok` after it passed
  /// validation; see the state machine.
  final Map<int, TargetStatus> statuses;

  /// Accepted frames in acceptance order.
  final List<AcceptedFrame> frames;

  StationStatus status;

  /// Coverage measured by VERIFY before and after any repair, when known.
  double? coverageBefore;
  double? coverageAfter;

  /// Notes surfaced on the review screen: unresolved regions, warnings.
  final List<String> notes;

  final DateTime createdAt;
  DateTime updatedAt;

  StationGroup({
    required this.sessionId,
    required this.index,
    required this.stationId,
    required this.position,
    required this.planParams,
    required this.createdAt,
    required this.updatedAt,
    this.origin,
    Map<int, TargetStatus>? statuses,
    List<AcceptedFrame>? frames,
    List<String>? notes,
    this.status = StationStatus.inProgress,
    this.coverageBefore,
    this.coverageAfter,
  }) : statuses = statuses ?? <int, TargetStatus>{},
       frames = frames ?? <AcceptedFrame>[],
       notes = notes ?? <String>[];

  /// The on-disk directory name for this station.
  String dirName() => stationDirNameFor(index);

  int get acceptedCount => frames.length;

  /// True when every frame of the plan is either accepted or deliberately
  /// skipped — the precondition for VERIFY to be meaningful.
  bool get isFullyAddressed {
    final total = plannedFrameCount;
    if (total == 0) return false;
    for (var i = 0; i < total; i++) {
      if ((statuses[i] ?? TargetStatus.pending) == TargetStatus.pending) {
        return false;
      }
    }
    return true;
  }

  /// The plan's frame count. Persisted separately so a resume can tell whether
  /// the plan changed under it.
  int plannedFrameCount = 0;

  /// Frame indices still pending, in plan order.
  List<int> pendingIndices() => <int>[
    for (var i = 0; i < plannedFrameCount; i++)
      if ((statuses[i] ?? TargetStatus.pending) == TargetStatus.pending) i,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': captureSchemaVersion,
    'stationId': stationId,
    'index': index,
    'position': <String, Object?>{
      'x': jDouble(position.x),
      'z': jDouble(position.z),
    },
    'origin': origin == null ? null : jStationOrigin(origin!),
    'planParams': jPlanParams(planParams),
    'plannedFrameCount': plannedFrameCount,
    'status': status.name,
    'coverageBefore': jDouble(coverageBefore),
    'coverageAfter': jDouble(coverageAfter),
    'notes': notes,
    'statuses': <String, Object?>{
      for (final e in statuses.entries) e.key.toString(): e.value.name,
    },
    'frames': <Object?>[for (final f in frames) jAcceptedFrame(f)],
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static StationGroup fromJson(String sessionId, Map<String, Object?> m) {
    final pos = (m['position']! as Map).cast<String, Object?>();
    final rawStatuses =
        (m['statuses'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    final group = StationGroup(
      sessionId: sessionId,
      index: (m['index']! as num).toInt(),
      stationId: m['stationId']! as String,
      position: (
        x: (pos['x']! as num).toDouble(),
        z: (pos['z']! as num).toDouble(),
      ),
      planParams: planParamsFromJson(
        (m['planParams']! as Map).cast<String, Object?>(),
      ),
      createdAt: DateTime.parse(m['createdAt']! as String),
      updatedAt: DateTime.parse(m['updatedAt']! as String),
      origin: m['origin'] == null
          ? null
          : stationOriginFromJson(
              (m['origin']! as Map).cast<String, Object?>(),
            ),
      statuses: <int, TargetStatus>{
        for (final e in rawStatuses.entries)
          int.parse(e.key): TargetStatus.values.byName(e.value! as String),
      },
      frames: <AcceptedFrame>[
        for (final f in (m['frames']! as List))
          acceptedFrameFromJson(
            (f as Map).cast<String, Object?>(),
            viewpointIndex: (m['index']! as num).toInt(),
          ),
      ],
      notes: <String>[
        for (final n in (m['notes'] as List?) ?? const <Object?>[])
          n! as String,
      ],
      status: StationStatus.values.byName(m['status']! as String),
      coverageBefore: (m['coverageBefore'] as num?)?.toDouble(),
      coverageAfter: (m['coverageAfter'] as num?)?.toDouble(),
    );
    group.plannedFrameCount = (m['plannedFrameCount']! as num).toInt();
    return group;
  }
}

/// Writes frames and manifests to disk.
///
/// The contract the brief asks for is **every accepted frame reaches disk before
/// the state machine moves on**, so [appendFrame] is awaited on the ACCEPT
/// transition. A phone call arriving between the shutter and the write would
/// otherwise lose a frame that the UI already reported as done.
///
/// Writes go to a temporary file and are then renamed, so a crash mid-write
/// leaves the previous good manifest in place rather than a truncated one.
class FrameStore {
  final CapturePaths paths;

  /// Reads a written image back from disk before the frame is recorded.
  ///
  /// Injectable so a test can force a verdict; the default implementation only
  /// uses `dart:io`.
  final FrameIntegrityChecker integrity;

  FrameStore(this.paths, {FrameIntegrityChecker? integrity})
    : integrity = integrity ?? FrameIntegrityChecker();

  /// Writes the JPEG and its metadata, reads them back, and only then updates
  /// `group.json`.
  ///
  /// **Idempotent per frame index.** Re-accepting a frame replaces its previous
  /// entry instead of appending a second one, so a retake after a resume cannot
  /// double-count the frame in the summary or upload it twice. The image and the
  /// metadata file are overwritten in place for the same reason.
  ///
  /// The read-back is what makes "saved" mean something: a write that returns
  /// without error can still leave a file that stops halfway through the image
  /// (a full volume, or a kill during the rename). In that case nothing is
  /// recorded, `stored` is false, and the caller re-offers the target instead of
  /// advancing past a frame the panorama does not have. The bad file is left on
  /// disk: it is overwritten by the retake, and deleting a user's photograph
  /// because a check was uncertain is the wrong direction of failure.
  Future<FrameWrite> appendFrame({
    required StationGroup group,
    required int frameIndex,
    required Uint8List jpeg,
    required AcceptedFrame frame,
  }) async {
    final imagePath = paths.frameImage(
      group.sessionId,
      group.index,
      frameIndex,
    );
    final metaPath = paths.frameMeta(group.sessionId, group.index, frameIndex);

    frame.savedAt = DateTime.now();
    await _writeAtomic(imagePath, jpeg);
    await _writeAtomic(
      metaPath,
      utf8.encode(prettyJson(jAcceptedFrame(frame))),
    );

    final check = await integrity.inspect(imagePath);
    if (!check.isStored) {
      frame.savedAt = null;
      return FrameWrite(imagePath: imagePath, integrity: check);
    }

    group.frames.removeWhere((f) => f.index == frameIndex);
    group.frames.add(frame);
    group.statuses[frameIndex] = TargetStatus.ok;
    group.updatedAt = DateTime.now();
    await saveGroup(group);
    return FrameWrite(imagePath: imagePath, integrity: check);
  }

  /// Takes a frame back out of the station again.
  ///
  /// Used when something downstream of the write disagrees with the manifest —
  /// a read-back that now fails, or a resume that finds the file gone. The
  /// target returns to pending so the capture offers it again rather than
  /// reporting a station that is missing a frame.
  Future<void> unacceptFrame({
    required StationGroup group,
    required int frameIndex,
  }) async {
    group.frames.removeWhere((f) => f.index == frameIndex);
    group.statuses[frameIndex] = TargetStatus.pending;
    group.updatedAt = DateTime.now();
    await saveGroup(group);
  }

  /// Records a decision that is not a capture: a skip, or a pending retry.
  ///
  /// Skipping is deliberately *not* a capture. It marks the target `skipped`
  /// so VERIFY can report it as an unresolved region, and it never writes an
  /// image — there is nothing to write.
  Future<void> markStatus({
    required StationGroup group,
    required int frameIndex,
    required TargetStatus status,
  }) async {
    group.statuses[frameIndex] = status;
    group.updatedAt = DateTime.now();
    await saveGroup(group);
  }

  Future<void> saveGroup(StationGroup group) async {
    await paths.ensureStation(group.sessionId, group.index);
    await _writeAtomic(
      paths.groupFile(group.sessionId, group.index),
      utf8.encode(prettyJson(group.toJson())),
    );
  }

  /// Reads a station's manifest back. Returns `null` when it does not exist.
  Future<StationGroup?> loadGroup(String sessionId, int index) async {
    final f = File(paths.groupFile(sessionId, index));
    if (!await f.exists()) return null;
    final m = (jsonDecode(await f.readAsString()) as Map)
        .cast<String, Object?>();
    return StationGroup.fromJson(sessionId, m);
  }

  /// Every frame image on disk for a station, in plan order.
  ///
  /// This is what the upload path uses: it walks the directory rather than
  /// trusting the manifest, so a frame that was written but whose manifest
  /// update was interrupted is still found.
  Future<List<File>> listFrameImages(String sessionId, int index) async {
    final dir = Directory(paths.framesDir(sessionId, index));
    if (!await dir.exists()) return <File>[];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.jpg'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Reads every frame image of a station back from disk, keyed by plan index.
  ///
  /// This is the answer to "are the photographs really there, and are they
  /// whole?". It walks the directory rather than the manifest, so it also finds
  /// a file whose manifest update was interrupted, and it reports a manifest
  /// entry whose file has gone. Only the marker chain is read, not the pixels,
  /// so a whole station costs a few hundred kilobytes of I/O.
  Future<Map<int, FrameIntegrity>> inspectFrames(
    String sessionId,
    int index,
  ) async {
    final out = <int, FrameIntegrity>{};
    for (final file in await listFrameImages(sessionId, index)) {
      final frameIndex = paths.frameIndexOf(file.path);
      if (frameIndex == null) continue;
      out[frameIndex] = await integrity.inspect(file.path);
    }
    return out;
  }

  /// Reads one frame's own evidence file (`fNNN.json`) back from disk.
  ///
  /// Deliberately not `group.frames`: the preview page has to show what was
  /// written next to the photograph, not what the current process happens to
  /// hold in memory. Returns `null` when the file is missing or unreadable.
  Future<AcceptedFrame?> loadFrameMeta(
    String sessionId,
    int index,
    int frameIndex,
  ) async {
    final f = File(paths.frameMeta(sessionId, index, frameIndex));
    if (!await f.exists()) return null;
    try {
      final m = (jsonDecode(await f.readAsString()) as Map)
          .cast<String, Object?>();
      return acceptedFrameFromJson(m, viewpointIndex: index);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> _writeAtomic(String path, List<int> bytes) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}

/// What one [FrameStore.appendFrame] call ended up proving.
class FrameWrite {
  final String imagePath;
  final FrameIntegrity integrity;

  const FrameWrite({required this.imagePath, required this.integrity});

  /// False when the file did not survive the write; the frame is not recorded.
  bool get stored => integrity.isStored;

  @override
  String toString() =>
      'FrameWrite(health: ${integrity.health.name}, $imagePath)';
}

/// Everything the disk proves about one frame, read back on demand.
///
/// The review preview shows this rather than the in-memory session state: the
/// question a user asks at that point is "is this photograph really mine, and
/// was it taken where the app says it was?", and only the file and its evidence
/// can answer it.
class FrameEvidence {
  final String imagePath;
  final FrameIntegrity integrity;

  /// The frame's own `fNNN.json`, or `null` when it is missing or unreadable.
  final AcceptedFrame? meta;

  const FrameEvidence({
    required this.imagePath,
    required this.integrity,
    this.meta,
  });

  /// Whether the whole pair — photograph and evidence — came back.
  bool get complete => integrity.isStored && meta != null;

  /// How this frame ended up accepted, in one line, with no hidden optimism.
  ///
  /// A frame that failed the read-back is reported as such even if the manifest
  /// still calls it done: the file is the evidence, the status is a claim.
  String get verdict {
    if (!integrity.isStored) return integrity.label;
    final m = meta;
    if (m == null) return 'Image is stored, but its evidence file is missing.';
    if (m.warning != null) return 'Accepted with a warning: ${m.warning}';
    if (m.manual) return 'Manual shot accepted; the aim is not verified.';
    return 'Accepted: passed the quality checks';
  }
}
