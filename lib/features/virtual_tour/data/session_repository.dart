import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/room_occlusion.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/capture_json.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/capture_paths.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/frame_integrity.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/station_group.dart';

/// The session manifest: which stations exist and which one is active.
///
/// Deliberately holds **no** per-frame counts. Those live in each station's
/// `group.json`, which is the single source of truth, so a count can never
/// disagree with the frames actually on disk. Loading a handful of small JSON
/// files on resume is cheaper than reconciling two copies of the same state.
class SessionManifest {
  final String sessionId;
  final DateTime createdAt;
  DateTime updatedAt;

  /// The room the user described. Used for the viewpoint suggestion and the
  /// parallax estimate; it is a user estimate, not a measurement.
  final RoomBox room;

  /// The plan parameters chosen at the plan step.
  final PlanParams planParams;

  /// Station ids in creation order. A station's index is its position here.
  final List<String> stationIds;

  int activeStationIndex;

  SessionManifest({
    required this.sessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.room,
    required this.planParams,
    required this.stationIds,
    this.activeStationIndex = 0,
  });

  int get stationCount => stationIds.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': captureSchemaVersion,
    'sessionId': sessionId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'room': <String, Object?>{
      'lengthM': jDouble(room.lengthM),
      'widthM': jDouble(room.widthM),
    },
    'planParams': jPlanParams(planParams),
    'stationIds': stationIds,
    'activeStationIndex': activeStationIndex,
  };

  static SessionManifest fromJson(Map<String, Object?> m) {
    final room = (m['room']! as Map).cast<String, Object?>();
    return SessionManifest(
      sessionId: m['sessionId']! as String,
      createdAt: DateTime.parse(m['createdAt']! as String),
      updatedAt: DateTime.parse(m['updatedAt']! as String),
      room: RoomBox(
        lengthM: (room['lengthM']! as num).toDouble(),
        widthM: (room['widthM']! as num).toDouble(),
      ),
      planParams: planParamsFromJson(
        (m['planParams']! as Map).cast<String, Object?>(),
      ),
      stationIds: <String>[
        for (final s in (m['stationIds']! as List)) s! as String,
      ],
      activeStationIndex: (m['activeStationIndex']! as num).toInt(),
    );
  }
}

/// Where a resumed session should pick up.
///
/// This is the answer to "a phone call, an app switch or a back gesture must not
/// lose accepted frames, and the user must not have to repeat work". It is
/// derived from `group.json` **and** from what is actually in the `frames/`
/// directory, so it is correct even if the process was killed without ever
/// reaching a save, and even if the file a manifest entry points at never made
/// it to disk whole.
class ResumePoint {
  final int stationIndex;

  /// The first frame that is neither accepted nor deliberately skipped, or
  /// `null` when the station has no pending frames left.
  final int? nextFrameIndex;

  /// Frames already accepted, in plan order. The state machine is told these
  /// are done so it never re-shoots them.
  final List<int> alreadyAccepted;

  /// Frames the user explicitly skipped.
  final List<int> skipped;

  /// Frames the manifest calls accepted whose image did not survive the read-
  /// back: missing, truncated, or not a JPEG. They are counted as pending in
  /// [nextFrameIndex] and [alreadyAccepted] rather than trusted, and the review
  /// screen names the reason for each one so the user learns *why* the shot is
  /// being asked for again.
  final List<UnreadableFrame> unreadable;

  /// True when every frame is accepted or skipped.
  final bool stationComplete;

  /// True when there is no station to resume at all (a brand-new session).
  final bool isFresh;

  const ResumePoint({
    required this.stationIndex,
    required this.nextFrameIndex,
    required this.alreadyAccepted,
    required this.skipped,
    required this.unreadable,
    required this.stationComplete,
    required this.isFresh,
  });

  @override
  String toString() =>
      'ResumePoint(station $stationIndex, next $nextFrameIndex, '
      'accepted ${alreadyAccepted.length}, skipped ${skipped.length}, '
      'unreadable ${unreadable.length}, '
      'complete $stationComplete, fresh $isFresh)';
}

/// A frame the manifest says is done but the disk disagrees with.
class UnreadableFrame {
  final int frameIndex;
  final FrameHealth health;

  const UnreadableFrame(this.frameIndex, this.health);

  @override
  String toString() => 'UnreadableFrame(frame $frameIndex, ${health.name})';
}

/// Session lifecycle: create, persist, resume, enumerate.
class CaptureSessionRepository {
  final CapturePaths paths;
  final FrameStore frames;

  CaptureSessionRepository(this.paths) : frames = FrameStore(paths);

  /// Creates the session on disk and returns its manifest.
  ///
  /// [sessionId] is supplied by the caller (the app uses a UUID v4) so that the
  /// id can also be embedded in upload paths before the session exists.
  Future<SessionManifest> create({
    required String sessionId,
    required RoomBox room,
    required PlanParams planParams,
  }) async {
    final now = DateTime.now();
    final manifest = SessionManifest(
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
      room: room,
      planParams: planParams,
      stationIds: <String>[],
    );
    await paths.ensureSession(sessionId);
    await saveManifest(manifest);
    return manifest;
  }

  Future<void> saveManifest(SessionManifest manifest) async {
    manifest.updatedAt = DateTime.now();
    await Directory(
      paths.sessionDir(manifest.sessionId),
    ).create(recursive: true);
    await _writeAtomic(
      paths.manifestFile(manifest.sessionId),
      utf8.encode(prettyJson(manifest.toJson())),
    );
  }

  Future<SessionManifest?> loadManifest(String sessionId) async {
    final f = File(paths.manifestFile(sessionId));
    if (!await f.exists()) return null;
    final m = (jsonDecode(await f.readAsString()) as Map)
        .cast<String, Object?>();
    return SessionManifest.fromJson(m);
  }

  /// Every session on disk, newest first.
  ///
  /// A session whose manifest is missing or unreadable is skipped rather than
  /// throwing, so one corrupt session cannot make the list screen unusable.
  Future<List<SessionManifest>> listSessions() async {
    final root = Directory(paths.root);
    if (!await root.exists()) return <SessionManifest>[];
    final out = <SessionManifest>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      try {
        final m = await loadManifest(p.basename(e.path));
        if (m != null) out.add(m);
      } on FormatException {
        continue;
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// Adds a station to the manifest and returns its index.
  Future<int> addStation(
    SessionManifest manifest, {
    required String stationId,
    required ({double x, double z}) position,
    required int plannedFrameCount,
  }) async {
    final index = manifest.stationIds.length;
    manifest.stationIds.add(stationId);
    manifest.activeStationIndex = index;
    final now = DateTime.now();
    final group = StationGroup(
      sessionId: manifest.sessionId,
      index: index,
      stationId: stationId,
      position: position,
      planParams: manifest.planParams,
      createdAt: now,
      updatedAt: now,
    )..plannedFrameCount = plannedFrameCount;
    await frames.saveGroup(group);
    await saveManifest(manifest);
    return index;
  }

  /// All stations of a session, in index order.
  ///
  /// A station whose manifest is missing is returned as `null` in its slot so
  /// the caller can see the hole instead of silently renumbering.
  Future<List<StationGroup?>> loadStations(SessionManifest manifest) async {
    final out = <StationGroup?>[];
    for (var i = 0; i < manifest.stationIds.length; i++) {
      out.add(await frames.loadGroup(manifest.sessionId, i));
    }
    return out;
  }

  /// Derives where to resume, from the active station's manifest **and** the
  /// images on disk.
  ///
  /// The rule is deliberately conservative: a frame counts as done only when
  /// its status is `ok` **and** its image is present and whole. A status without
  /// an image would mean the app was killed between the two writes; a status
  /// pointing at a file that stops halfway through the scan data means the write
  /// itself failed. Re-shooting is cheaper in every case than uploading a
  /// panorama with a hole in it, and the second case is invisible from the
  /// manifest alone, which is why the images are read back.
  Future<ResumePoint> resumePoint(SessionManifest manifest) async {
    if (manifest.stationIds.isEmpty) {
      return const ResumePoint(
        stationIndex: 0,
        nextFrameIndex: null,
        alreadyAccepted: <int>[],
        skipped: <int>[],
        unreadable: <UnreadableFrame>[],
        stationComplete: false,
        isFresh: true,
      );
    }

    final index = manifest.activeStationIndex.clamp(
      0,
      manifest.stationIds.length - 1,
    );
    final group = await frames.loadGroup(manifest.sessionId, index);
    if (group == null) {
      return ResumePoint(
        stationIndex: index,
        nextFrameIndex: null,
        alreadyAccepted: const <int>[],
        skipped: const <int>[],
        unreadable: const <UnreadableFrame>[],
        stationComplete: false,
        isFresh: true,
      );
    }

    final onDisk = await frames.inspectFrames(manifest.sessionId, index);

    final accepted = <int>[];
    final skipped = <int>[];
    final unreadable = <UnreadableFrame>[];
    int? next;

    for (var i = 0; i < group.plannedFrameCount; i++) {
      final status = group.statuses[i] ?? TargetStatus.pending;
      final check = onDisk[i];
      if (status == TargetStatus.ok && check != null && check.isStored) {
        accepted.add(i);
      } else if (status == TargetStatus.ok) {
        // Says done, but the photograph is not there or not whole. Reported
        // with the reason, then treated exactly like a pending frame.
        unreadable.add(
          UnreadableFrame(i, check?.health ?? FrameHealth.missing),
        );
        next ??= i;
      } else if (status == TargetStatus.skipped) {
        skipped.add(i);
      } else {
        next ??= i;
      }
    }

    return ResumePoint(
      stationIndex: index,
      nextFrameIndex: next,
      alreadyAccepted: accepted,
      skipped: skipped,
      unreadable: unreadable,
      stationComplete: next == null,
      isFresh: false,
    );
  }

  /// Deletes a session directory. Used by tests and by "discard" in the UI.
  ///
  /// Recursive, and therefore only ever called on a path this repository
  /// created under [CapturePaths.root] — never on a user-chosen directory.
  Future<void> deleteSession(String sessionId) async {
    final dir = Directory(paths.sessionDir(sessionId));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _writeAtomic(String path, List<int> bytes) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}
