import 'dart:convert';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// One row of the motion record: what came in, what was displayed, and what the
/// gate decided.
///
/// The three are kept side by side on purpose. A row where `raw` and `filtered`
/// differ while `stable` is true is the evidence that smoothing is doing
/// something; a row where they differ and `stable` is true while the phone was
/// actually moving is the evidence that it is doing too much.
class MotionDiagnosticsEntry {
  final Duration at;
  final Quat raw;
  final Quat filtered;
  final double? angularRateDegPerSec;
  final int targetId;
  final double? errorDeg;
  final bool stable;
  final String phase;
  final String? result;

  const MotionDiagnosticsEntry({
    required this.at,
    required this.raw,
    required this.filtered,
    required this.targetId,
    required this.errorDeg,
    required this.stable,
    required this.phase,
    this.angularRateDegPerSec,
    this.result,
  });
}

/// A bounded, in-memory record of the motion pipeline.
///
/// Bounded because a capture session is minutes long at 30 Hz — unbounded, it
/// would be tens of thousands of rows held in RAM for no benefit. The oldest rows
/// are dropped, which is the right end to lose: a defect report needs the seconds
/// around the failure, not the start of the session.
///
/// **No personal data.** Only timestamps relative to the session, quaternions,
/// rates, target ids and outcomes. No device ids, no file paths, no location.
class MotionDiagnostics {
  MotionDiagnostics({this.capacity = 1800});

  /// Rows retained. 1800 ≈ one minute at 30 Hz.
  final int capacity;

  final List<MotionDiagnosticsEntry> _entries = <MotionDiagnosticsEntry>[];

  List<MotionDiagnosticsEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  void add(MotionDiagnosticsEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  void clear() => _entries.clear();

  static const String csvHeader =
      't_ms,raw_x,raw_y,raw_z,raw_w,filt_x,filt_y,filt_z,filt_w,'
      'rate_dps,target_id,error_deg,stable,phase,result';

  /// CSV, six decimals on the quaternion components.
  ///
  /// Six rather than full precision because a quaternion component beyond 1e-6
  /// is below any sensor's resolution, and the file stays readable.
  String toCsv() {
    final buffer = StringBuffer()..writeln(csvHeader);
    for (final e in _entries) {
      buffer
        ..write(e.at.inMilliseconds)
        ..write(',')
        ..write(e.raw.x.toStringAsFixed(6))
        ..write(',')
        ..write(e.raw.y.toStringAsFixed(6))
        ..write(',')
        ..write(e.raw.z.toStringAsFixed(6))
        ..write(',')
        ..write(e.raw.w.toStringAsFixed(6))
        ..write(',')
        ..write(e.filtered.x.toStringAsFixed(6))
        ..write(',')
        ..write(e.filtered.y.toStringAsFixed(6))
        ..write(',')
        ..write(e.filtered.z.toStringAsFixed(6))
        ..write(',')
        ..write(e.filtered.w.toStringAsFixed(6))
        ..write(',')
        ..write(e.angularRateDegPerSec?.toStringAsFixed(2) ?? '')
        ..write(',')
        ..write(e.targetId)
        ..write(',')
        ..write(e.errorDeg?.toStringAsFixed(2) ?? '')
        ..write(',')
        ..write(e.stable ? 1 : 0)
        ..write(',')
        ..write(e.phase)
        ..write(',')
        ..writeln(e.result ?? '');
    }
    return buffer.toString();
  }

  /// The same rows as JSON, for a tool that would rather not parse CSV.
  String toJson() =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'adaptive360.motion/1',
        'count': _entries.length,
        'rows': <Object?>[
          for (final e in _entries)
            <String, Object?>{
              't_ms': e.at.inMilliseconds,
              'raw': <double>[e.raw.x, e.raw.y, e.raw.z, e.raw.w],
              'filtered': <double>[
                e.filtered.x,
                e.filtered.y,
                e.filtered.z,
                e.filtered.w,
              ],
              'rate_dps': e.angularRateDegPerSec,
              'target_id': e.targetId,
              'error_deg': e.errorDeg,
              'stable': e.stable,
              'phase': e.phase,
              'result': e.result,
            },
        ],
      });
}
