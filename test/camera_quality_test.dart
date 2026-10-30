import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/application/capture_state.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_payload.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The camera-quality report: what arrives from the host, and how the state
/// carries it.
///
/// The point of the report is diagnosis. A blurry capture has two very
/// different causes — the lens locked at fixed focus, or a small CPU stream —
/// and both look identical on screen. These tests pin that the numbers arrive
/// intact, that an absent report stays absent (never a invented 0×0 camera),
/// and that a session restart clears them.
void main() {
  group('ArCameraQuality', () {
    test('describe states the resolution and the focus mode', () {
      const auto = ArCameraQuality(
        stillWidth: 1440,
        stillHeight: 1080,
        previewWidth: 1920,
        previewHeight: 1080,
        focusMode: 'auto',
      );
      expect(auto.autofocus, isTrue);
      expect(auto.describe(), 'Photos 1440×1080 · autofocus on');
    });

    test('a fixed-focus session says so, and says what it costs', () {
      const fixed = ArCameraQuality(
        stillWidth: 640,
        stillHeight: 480,
        previewWidth: 640,
        previewHeight: 480,
        focusMode: 'fixed',
      );
      expect(fixed.autofocus, isFalse);
      expect(
        fixed.describe(),
        contains('focus locked at the default distance'),
      );
    });

    test('fullHdStill is true for 1920 on either axis', () {
      const landscape = ArCameraQuality(
        stillWidth: 1920,
        stillHeight: 1080,
        previewWidth: 1920,
        previewHeight: 1080,
        focusMode: 'auto',
      );
      const portrait = ArCameraQuality(
        stillWidth: 1080,
        stillHeight: 1920,
        previewWidth: 1080,
        previewHeight: 1920,
        focusMode: 'auto',
      );
      expect(landscape.fullHdStill, isTrue);
      expect(portrait.fullHdStill, isTrue);
      const low = ArCameraQuality(
        stillWidth: 1280,
        stillHeight: 720,
        previewWidth: 1280,
        previewHeight: 720,
        focusMode: 'auto',
      );
      expect(low.fullHdStill, isFalse);
    });
  });

  group('parseCameraQuality', () {
    Map<Object?, Object?> payload({
      Object? stillWidth = 1440,
      Object? stillHeight = 1080,
      Object? previewWidth = 1920,
      Object? previewHeight = 1080,
      Object? focusMode = 'auto',
    }) => <Object?, Object?>{
      'stillWidth': stillWidth,
      'stillHeight': stillHeight,
      'previewWidth': previewWidth,
      'previewHeight': previewHeight,
      'focusMode': focusMode,
    };

    test('reads every field from a complete payload', () {
      final quality = parseCameraQuality(payload());
      expect(quality, isNotNull);
      expect(quality!.stillWidth, 1440);
      expect(quality.stillHeight, 1080);
      expect(quality.previewWidth, 1920);
      expect(quality.previewHeight, 1080);
      expect(quality.focusMode, 'auto');
    });

    test('null when the host reported nothing', () {
      expect(parseCameraQuality(const <Object?, Object?>{}), isNull);
    });

    test('null when any field is missing', () {
      expect(
        parseCameraQuality(payload(stillWidth: null)),
        isNull,
        reason: 'a half-reported camera is not a camera',
      );
      expect(parseCameraQuality(payload(focusMode: null)), isNull);
    });

    test('null for a zero-sized stream rather than 0x0', () {
      expect(parseCameraQuality(payload(stillWidth: 0)), isNull);
      expect(parseCameraQuality(payload(stillHeight: 0)), isNull);
    });
  });

  group('pose events carry the report', () {
    Map<Object?, Object?> poseEvent({
      Map<Object?, Object?> quality = const {},
    }) => <Object?, Object?>{
      'type': 'pose',
      'px': 0.0,
      'py': 0.0,
      'pz': 0.0,
      'qx': 0.0,
      'qy': 0.0,
      'qz': 0.0,
      'qw': 1.0,
      'tracking': 'TRACKING',
      'timestampNs': 1,
      ...quality,
    };

    test('the event the host marks with the config carries it', () {
      final event = ArCoreEvent.fromMap(
        poseEvent(
          quality: <Object?, Object?>{
            'stillWidth': 640,
            'stillHeight': 480,
            'previewWidth': 640,
            'previewHeight': 480,
            'focusMode': 'fixed',
          },
        ),
      );
      expect(event.pose, isNotNull);
      expect(event.pose!.cameraQuality, isNotNull);
      expect(event.pose!.cameraQuality!.stillWidth, 640);
      expect(event.pose!.cameraQuality!.autofocus, isFalse);
    });

    test('every other pose event carries nothing', () {
      final event = ArCoreEvent.fromMap(poseEvent());
      expect(event.pose, isNotNull);
      expect(
        event.pose!.cameraQuality,
        isNull,
        reason: 'the config is reported once, not per frame',
      );
    });
  });

  group('CaptureState carries the report', () {
    const quality = ArCameraQuality(
      stillWidth: 1920,
      stillHeight: 1080,
      previewWidth: 1920,
      previewHeight: 1080,
      focusMode: 'auto',
    );

    CaptureState state() => CaptureState(
      phase: CapturePhase.idle,
      geometry: const CaptureGeometryConfig(),
    );

    test('copyWith keeps it when a frame omits it', () {
      final next = state()
          .copyWith(cameraQuality: quality)
          .copyWith(
            phase: CapturePhase.scanning,
            tracking: TrackingState.tracking,
          );
      expect(next.cameraQuality, same(quality));
    });

    test('a session restart clears it', () {
      final restarted = state()
          .copyWith(cameraQuality: quality)
          .copyWith(clearCameraQuality: true);
      expect(restarted.cameraQuality, isNull);
      // And clearing is not the same as the value the flag guards being null:
      // the next session's report still lands.
      final next = restarted.copyWith(cameraQuality: quality);
      expect(next.cameraQuality, same(quality));
    });
  });
}
