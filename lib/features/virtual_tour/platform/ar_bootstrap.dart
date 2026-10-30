import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_null_sources.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_sources.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/sensor_pose_source.dart';

/// The one place that decides what pose source this build runs on.
///
/// **This build has no ARCore bridge.** The reference project's Kotlin ARCore
/// host needs `com.google.ar:core` on the classpath, and nothing in this app's
/// Gradle configuration provides it — so shipping that path would be shipping a
/// build that cannot compile, let alone run. The brief anticipates exactly this:
/// where real AR is not possible, ship a clearly labelled sensor-guided
/// prototype. That is what this file chooses.
///
/// Everything above it is written against the [ArPoseSource] and
/// [ArStationAnchorSource] interfaces, so no UI or flow code knows which branch
/// was taken, and adding an ARCore host later means changing this file and
/// nothing else.
///
/// Consequences the rest of the app has to live with, all of them honest:
///
/// * direction comes from the accelerometer and gyroscope, and its heading
///   reference drifts by the gyro's bias — see `sensor_pose_source.dart`;
/// * there is no plane, so no floor hit-test, so the station cannot be anchored;
/// * there is therefore no drift measurement, and `ArTier.poseOnly` says so in
///   the UI rather than silently skipping the check;
/// * the still camera keeps the sensor, because nothing else wants it —
///   `createArFrameGrabber()` returns null and the capture path uses the plugin
///   camera at full preview resolution instead of an ARCore camera image.
ArPoseSource createArPoseSource() => SensorPoseSource();

ArStationAnchorSource createArStationAnchorSource() =>
    NoArStationAnchorSource();

/// No AR session, so no AR camera: the ordinary still camera owns the sensor.
ArFrameGrabber? createArFrameGrabber() => null;

/// Whether this build can ever provide AR. It cannot.
bool get arPlatformAvailable => false;

/// What to tell the user about AR on this platform.
String get arPlatformDescription =>
    'This build has no ARCore host. Guidance runs on the motion sensors: '
    'direction only, no anchor and no drift measurement.';
