/// The gyroscope rate, as an interface.
///
/// **Pure Dart.** The SETTLE phase and the motion rejection both gate on an
/// angular rate, and the flow layer needs to be testable without a Flutter
/// binding, so the interface lives here and the `sensors_plus` implementation
/// lives in `gyro_rate.dart`.
///
/// A rate is allowed to be absent, and absent is *not* the same as zero. A
/// missing reading means "the sensor has not reported recently", and the flow
/// must not read that as "the phone is still" — that is precisely the bug the
/// previous implementation had, where a `stop()` that did not clear its last
/// magnitude made the whole background gap look like a stable hold.
abstract class MotionRateSource {
  /// The angular rate magnitude in degrees per second, or `null` when there is
  /// no fresh reading.
  double? get rateDegPerSec;

  /// Whether a reading exists but has expired.
  bool get isStale;

  /// Whether the sensor failed outright, so the UI can say the settle check is
  /// running on the pose alone.
  bool get hasFailed;

  /// The failure, when [hasFailed] is true.
  Object? get error;

  /// Starts sampling. Idempotent.
  void start();

  /// Stops sampling and **clears the reading**.
  Future<void> stop();

  /// A one-line status for the diagnostics panel.
  String status();
}

/// A rate source that never reports anything.
///
/// Used on a device with no gyroscope, and by tests that do not care about the
/// motion gate. It reports `hasFailed = false` and `rateDegPerSec = null`, which
/// the machine reads as "no motion information" rather than "no motion".
class NoMotionRate implements MotionRateSource {
  @override
  double? get rateDegPerSec => null;

  @override
  bool get isStale => false;

  @override
  bool get hasFailed => false;

  @override
  Object? get error => null;

  @override
  void start() {}

  @override
  Future<void> stop() async {}

  @override
  String status() => 'No motion sensor is in use.';
}

/// A scripted rate, for tests.
class ScriptedMotionRate implements MotionRateSource {
  double? rate;
  bool failed = false;
  Object? failure;

  ScriptedMotionRate({this.rate});

  @override
  double? get rateDegPerSec => failed ? null : rate;

  @override
  bool get isStale => false;

  @override
  bool get hasFailed => failed;

  @override
  Object? get error => failure;

  @override
  void start() {}

  @override
  Future<void> stop() async {
    rate = null;
  }

  @override
  String status() => failed
      ? 'No gyroscope: the settle check runs on the pose alone.'
      : 'Gyroscope ${rate?.toStringAsFixed(1) ?? 'n/a'}°/s';
}
