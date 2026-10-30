/// Typed failures surfaced to the UI instead of raw exceptions.
sealed class CaptureFailure {
  final String message;
  const CaptureFailure(this.message);
}

class PermissionFailure extends CaptureFailure {
  final bool permanentlyDenied;
  const PermissionFailure(super.message, {this.permanentlyDenied = false});
}

class SensorFailure extends CaptureFailure {
  const SensorFailure(super.message);
}

class CameraFailure extends CaptureFailure {
  const CameraFailure(super.message);
}

class QualityFailure extends CaptureFailure {
  final bool isWarningOnly;
  const QualityFailure(super.message, {this.isWarningOnly = true});
}

class StorageFailure extends CaptureFailure {
  const StorageFailure(super.message);
}

class BackendFailure extends CaptureFailure {
  final bool retryable;
  const BackendFailure(super.message, {this.retryable = true});
}
