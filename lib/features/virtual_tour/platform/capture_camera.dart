import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// What this device actually exposes.
///
/// Every capability is an explicit flag because the brief forbids claiming one
/// that was not established. "The camera plugin has a method for it" is not
/// evidence that the hardware honours it, so each is probed and reported as
/// measured.
///
/// The one that matters most is [exposureOffset]: without it the "poor lighting"
/// path has to rely on the user moving rather than on the app adjusting, and the
/// UI says so instead of pretending.
class CameraCapabilities {
  /// Whether `initialize()` succeeded at all.
  final bool ready;

  /// Preview, still capture and the analysis stream each have their own switch
  /// because they fail independently: a device can preview and shoot while
  /// refusing a second concurrent stream.
  final bool preview;
  final bool stillCapture;
  final bool imageStream;

  /// Exposure compensation, when the device reports a usable range.
  final bool exposureOffset;
  final double? minExposureOffset;
  final double? maxExposureOffset;

  /// Whether tap-to-focus / tap-to-meter are accepted.
  final bool focusPoint;
  final bool exposurePoint;

  /// Whether the platform reported a sensor orientation, which the UI uses to
  /// warn about a sideways hold before it starts giving turn instructions.
  final bool sensorOrientation;

  /// Resolution of the frames the analysis sees.
  final int frameWidth;
  final int frameHeight;

  /// Why something is missing, in words that can be shown to the user. `null`
  /// when nothing is missing.
  final String? limitation;

  const CameraCapabilities({
    required this.ready,
    required this.preview,
    required this.stillCapture,
    required this.imageStream,
    required this.exposureOffset,
    required this.focusPoint,
    required this.exposurePoint,
    required this.sensorOrientation,
    this.frameWidth = analysisWidth,
    this.frameHeight = analysisHeight,
    this.minExposureOffset,
    this.maxExposureOffset,
    this.limitation,
  });

  /// What a device with no usable camera stack reports.
  static const CameraCapabilities unavailable = CameraCapabilities(
    ready: false,
    preview: false,
    stillCapture: false,
    imageStream: false,
    exposureOffset: false,
    focusPoint: false,
    exposurePoint: false,
    sensorOrientation: false,
    limitation: 'No camera is available on this device.',
  );

  /// What a camera that *was* working reports once it has been closed.
  ///
  /// Separate from [unavailable] because the sentence is different and so is the
  /// cure: "no camera on this device" tells the user to put the phone down, while
  /// this one means the flow released the sensor and opening it again is the
  /// next step. A `dispose()` that left the old ready-true record behind made the
  /// capture screen reopen nothing and show a black viewfinder.
  static const CameraCapabilities closed = CameraCapabilities(
    ready: false,
    preview: false,
    stillCapture: false,
    imageStream: false,
    exposureOffset: false,
    focusPoint: false,
    exposurePoint: false,
    sensorOrientation: false,
    limitation: 'The camera is closed. It opens again when you continue.',
  );

  /// A one-line summary for the diagnostics panel.
  String summary() {
    if (!ready) return limitation ?? 'Camera unavailable.';
    final missing = <String>[
      if (!preview) 'preview',
      if (!stillCapture) 'still capture',
      if (!imageStream) 'analysis stream',
      if (!exposureOffset) 'exposure control',
      if (!focusPoint) 'tap to focus',
    ];
    return missing.isEmpty
        ? 'Camera ready: preview, stills, analysis stream and exposure control.'
        : 'Camera ready, without: ${missing.join(', ')}.';
  }

  /// A copy with the given fields replaced.
  ///
  /// Used when a probe or a failed call updates one capability; rebuilding the
  /// record field by field at every call site is how a flag silently resets.
  CameraCapabilities copyWith({
    bool? ready,
    bool? preview,
    bool? stillCapture,
    bool? imageStream,
    bool? exposureOffset,
    double? minExposureOffset,
    double? maxExposureOffset,
    bool? focusPoint,
    bool? exposurePoint,
    bool? sensorOrientation,
    int? frameWidth,
    int? frameHeight,
    String? limitation,
    bool clearLimitation = false,
  }) => CameraCapabilities(
    ready: ready ?? this.ready,
    preview: preview ?? this.preview,
    stillCapture: stillCapture ?? this.stillCapture,
    imageStream: imageStream ?? this.imageStream,
    exposureOffset: exposureOffset ?? this.exposureOffset,
    minExposureOffset: minExposureOffset ?? this.minExposureOffset,
    maxExposureOffset: maxExposureOffset ?? this.maxExposureOffset,
    focusPoint: focusPoint ?? this.focusPoint,
    exposurePoint: exposurePoint ?? this.exposurePoint,
    sensorOrientation: sensorOrientation ?? this.sensorOrientation,
    frameWidth: frameWidth ?? this.frameWidth,
    frameHeight: frameHeight ?? this.frameHeight,
    limitation: clearLimitation ? null : (limitation ?? this.limitation),
  );
}

/// The camera as the capture flow needs it.
///
/// Deliberately narrow: the state machine only ever wants "the current
/// downsampled frame", "a full-resolution still for the panorama" and "the
/// preview to put on screen". Anything wider would let camera details leak into
/// the flow logic, and the flow is the part that has to stay testable.
///
/// **This interface is pure Dart.** Rendering the preview is the only part that
/// needs Flutter, and it lives in `CameraPreviewSource` instead — which is what
/// lets the whole frame-source path, including `FakeCaptureCamera`, be exercised
/// by a plain `dart` run with no Flutter binding.
abstract class CaptureCamera {
  /// What the device reported during [initialize].
  ///
  /// **Invariant: [CameraCapabilities.ready] is false whenever the camera is not
  /// open.** The flow re-opens on `!ready` (see `beginCapture`), so an
  /// implementation that keeps a stale ready-true record after [dispose] gets
  /// never reopened — and since a closed camera renders no preview, the symptom
  /// is a black viewfinder with no message. Every implementation must reset to
  /// [CameraCapabilities.closed] on dispose.
  CameraCapabilities get capabilities;

  /// Opens the camera and probes what it supports.
  Future<CameraCapabilities> initialize();

  /// The most recent downsampled frame, or `null` before the first one arrives.
  LiveFrame? grabFrame();

  /// Whether a fresh frame has arrived since the last call.
  bool get hasFreshFrame;

  /// A full-resolution JPEG for the panorama, or `null` when capture failed.
  Future<Uint8List?> takeStill();

  /// Adjusts exposure compensation. A no-op when
  /// [CameraCapabilities.exposureOffset] is false.
  Future<void> setExposureOffset(double offset);

  /// Whether the camera is currently delivering frames.
  bool get isRunning;

  Future<void> dispose();
}
