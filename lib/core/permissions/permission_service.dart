import 'package:permission_handler/permission_handler.dart';
import 'package:adaptive_360_capture_app/core/error/failures.dart';

/// Camera permission gate with permanently-denied handling.
class PermissionService {
  Future<void> ensureCapturePermissions() async {
    final camera = await Permission.camera.request();
    if (!camera.isGranted) {
      throw PermissionFailure(
        camera.isPermanentlyDenied
            ? 'Camera permission permanently denied. Open app settings to enable it.'
            : 'Camera permission is required for 360 capture.',
        permanentlyDenied: camera.isPermanentlyDenied,
      );
    }
    // The accelerometer and the gyroscope are normal permissions on Android:
    // the manifest's `<uses-feature>` entries declare them and the OS grants
    // them without asking. There is nothing to request, and asking for
    // `Permission.sensors` (which maps to BODY_SENSORS, a health-sensor
    // permission this app does not declare) only produced a
    // "No permissions found in manifest" error in the device log.
  }

  Future<bool> get cameraGranted async =>
      (await Permission.camera.status).isGranted;

  Future<void> openSettings() => openAppSettings();
}
