import 'dart:async';
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/motion_rate.dart';

/// The `sensors_plus` implementation of [MotionRateSource].
///
/// ## Why the gyroscope and not ARCore
///
/// ARCore does not report angular velocity, and even if it did, it would not be
/// available during the capture phase: the AR session is torn down before the
/// still camera opens, because the two cannot hold the camera at once. The
/// settle gate runs on *every* frame, so its rate has to come from a source that
/// outlives the AR session. `sensors_plus` is that source, and it is already a
/// dependency.
///
/// ## Why readings expire
///
/// A stale rate is worse than no rate. If the stream stops — the app was
/// backgrounded, the sensor was released — and the last value was small, the
/// machine would read "the phone is still" and fire the shutter on a frame the
/// user took while lifting the phone. A reading older than [staleAfter] is
/// therefore reported as `null`, and [isStale] lets the UI say so.
class GyroRateSource implements MotionRateSource {
  /// How long a reading stays valid without a new sample.
  final Duration staleAfter;

  StreamSubscription<GyroscopeEvent>? _sub;

  double? _rateDegPerSec;
  DateTime? _at;
  bool _failed = false;
  Object? _error;

  GyroRateSource({this.staleAfter = const Duration(milliseconds: 250)});

  @override
  double? get rateDegPerSec {
    if (_failed) return null;
    final at = _at;
    if (at == null) return null;
    if (DateTime.now().difference(at) > staleAfter) return null;
    return _rateDegPerSec;
  }

  @override
  bool get isStale {
    final at = _at;
    if (at == null) return false;
    return DateTime.now().difference(at) > staleAfter;
  }

  @override
  bool get hasFailed => _failed;

  @override
  Object? get error => _error;

  @override
  void start() {
    if (_sub != null) return;
    _failed = false;
    _error = null;
    _sub =
        gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 20),
        ).listen(
          (e) {
            final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
            // sensors_plus reports rad/s.
            _rateDegPerSec = mag * 180 / math.pi;
            _at = DateTime.now();
          },
          onError: (Object e) {
            _failed = true;
            _error = e;
            _rateDegPerSec = null;
            _at = null;
          },
          cancelOnError: false,
        );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    // Cleared, not kept: a background gap must not be mistaken for stillness.
    _rateDegPerSec = null;
    _at = null;
  }

  @override
  String status() {
    if (_failed) {
      return 'No gyroscope: the settle check runs on the pose alone. '
          '(${_error ?? 'unknown error'})';
    }
    final r = rateDegPerSec;
    if (r == null) return 'Waiting for the gyroscope…';
    return 'Gyroscope ${r.toStringAsFixed(1)}°/s${isStale ? ' (stale)' : ''}';
  }
}
