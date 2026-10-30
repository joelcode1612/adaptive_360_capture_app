import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';

/// The local stand-in for the two tables Section 4.5.2 names.
///
/// **Why JSON files and not SQL.** No database dependency or DDL exists in this
/// repository, and inventing a schema for a server-owned table would be a guess
/// presented as a contract. This store keeps the *same rows, ids and column
/// names* in two atomic JSON tables under the app's private documents
/// directory; when the real `VIRTUAL_TOUR` / `PROPERTY_PHOTO` tables arrive,
/// only this file changes. The repository above it never sees the storage
/// format.
///
/// Writes are serialised. Thirty captures are inserted in a loop, and a
/// last-write-wins read/modify/write race would silently drop rows — the bug
/// that matters most here, because the upload already has the JPEGs.
class VirtualTourLocalDataSource {
  VirtualTourLocalDataSource({required this.root});

  /// The app's private table directory, `…/virtual_tour_data`.
  final Directory root;

  static Future<VirtualTourLocalDataSource> createDefault() async {
    final docs = await getApplicationDocumentsDirectory();
    return VirtualTourLocalDataSource(
      root: Directory(p.join(docs.path, 'virtual_tour_data')),
    );
  }

  static const String tourTable = 'VIRTUAL_TOUR.json';
  static const String photoTable = 'PROPERTY_PHOTO.json';
  static const int schemaVersion = 1;

  Future<void> _tail = Future<void>.value();

  /// Runs [op] after every write that was queued before it.
  ///
  /// The chain keeps going when an operation fails, so one failed write does
  /// not wedge the table for the rest of the session.
  Future<T> _serialised<T>(Future<T> Function() op) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await op());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<VirtualTourRecord?> virtualTour(String id) async {
    final rows = await _readRows(tourTable);
    for (final row in rows) {
      if (row['id'] == id) return VirtualTourRecord.fromJson(row);
    }
    return null;
  }

  Future<void> upsertVirtualTour(VirtualTourRecord record) =>
      _serialised(() => _upsertRow(tourTable, record.id, record.toJson()));

  Future<void> upsertPropertyPhoto(PropertyPhotoRecord photo) =>
      _serialised(() => _upsertRow(photoTable, photo.id, photo.toJson()));

  Future<List<PropertyPhotoRecord>> propertyPhotos(String tourId) async {
    final rows = await _readRows(photoTable);
    return <PropertyPhotoRecord>[
      for (final row in rows)
        if (row['virtualTourId'] == tourId) PropertyPhotoRecord.fromJson(row),
    ];
  }

  Future<List<VirtualTourRecord>> listVirtualTours() async {
    final rows = await _readRows(tourTable);
    return <VirtualTourRecord>[
      for (final row in rows) VirtualTourRecord.fromJson(row),
    ];
  }

  Future<void> _upsertRow(
    String table,
    String id,
    Map<String, Object?> row,
  ) async {
    final rows = await _readRows(table);
    final index = rows.indexWhere((Map<String, Object?> r) => r['id'] == id);
    if (index >= 0) {
      rows[index] = row;
    } else {
      rows.add(row);
    }
    await _writeRows(table, rows);
  }

  Future<List<Map<String, Object?>>> _readRows(String table) async {
    final file = File(p.join(root.path, table));
    if (!await file.exists()) return <Map<String, Object?>>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('the table is not a JSON object');
      }
      final rows = decoded['rows'];
      if (rows is! List) {
        throw const FormatException('the table has no "rows" array');
      }
      return <Map<String, Object?>>[
        for (final row in rows) (row as Map).cast<String, Object?>(),
      ];
    } on FormatException catch (e) {
      throw VirtualTourFailure(
        'The local $table table is unreadable (${e.message}).',
        retryable: false,
      );
    } on TypeError {
      throw VirtualTourFailure(
        'The local $table table has an unexpected shape.',
        retryable: false,
      );
    }
  }

  Future<void> _writeRows(String table, List<Map<String, Object?>> rows) async {
    await root.create(recursive: true);
    final target = p.join(root.path, table);
    final tmp = File('$target.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': schemaVersion,
        'table': table,
        'rows': rows,
      }),
      flush: true,
    );
    // `rename` replaces an existing file on POSIX but not on Windows, where
    // retrying a tour would otherwise fail with "access denied" forever.
    final targetFile = File(target);
    if (await targetFile.exists()) await targetFile.delete();
    await tmp.rename(target);
  }
}
