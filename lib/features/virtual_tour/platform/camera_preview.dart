import 'package:flutter/widgets.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';

/// The Flutter half of a camera: the preview widget.
///
/// Split from [CaptureCamera] on purpose. `CaptureCamera` is the frame source —
/// what the capture flow and its tests actually drive — and keeping it free of
/// Flutter means the whole path from "camera produced a frame" through
/// validation to "frame written to disk" runs under a plain `dart` invocation.
/// Only the pixels-on-screen part needs a binding, and only this file needs it.
///
/// A camera that cannot render a preview (a test double, or a device where the
/// preview failed while stills still work) simply does not implement this.
abstract class CameraPreviewSource {
  /// The live preview, or an empty widget when preview is unavailable.
  Widget previewWidget();

  /// The preview's aspect ratio, or `null` before it is known.
  double? get previewAspectRatio;
}
