import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'adaptive360/arcore/test';
  const channel = MethodChannel(channelName);
  late ArCoreHost host;

  setUp(() {
    host = ArCoreHost(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void answerWith(Object? payload) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'takeStill');
          return payload;
        });
  }

  Map<String, Object?> stillPayload({
    Object? px = 0.25,
    Object? py = 1.4,
    Object? pz = -2.5,
    Object? qw = 1.0,
  }) => <String, Object?>{
    'jpeg': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
    'imageWidth': 4000,
    'imageHeight': 3000,
    'rotationAppliedDeg': 0,
    'timestampNs': 123456789,
    'tracking': 'TRACKING',
    'px': px,
    'py': py,
    'pz': pz,
    'qx': 0.0,
    'qy': 0.0,
    'qz': 0.0,
    'qw': qw,
  };

  group('takeStill carries the pose that opened the shutter', () {
    test('a complete payload yields a still with a capture pose', () async {
      answerWith(stillPayload());
      final still = await host.takeStill();

      expect(still.width, 4000);
      expect(still.height, 3000);
      expect(still.rotationAppliedDeg, 0);
      expect(still.capturePose, isNotNull);
      expect(still.capturePose!.position.x, 0.25);
      expect(still.capturePose!.position.y, 1.4);
      expect(still.capturePose!.position.z, -2.5);
      expect(still.capturePose!.tracking, TrackingState.tracking);
      expect(still.capturePose!.timestampNs, 123456789);
      expect(still.capturePose!.orientation.length, closeTo(1, 1e-12));
    });

    test(
      'the pose is raw ARCore, converted only through captureWorld',
      () async {
        answerWith(stillPayload());
        final still = await host.takeStill();
        final pose = still.capturePose!;

        // The raw quaternion is exactly what the host reported.
        expect(pose.orientation.z, 0.0);
        // The project convention is a separate, explicit conversion.
        expect(
          pose.captureWorld.w,
          closeTo(arCameraPoseToCaptureWorld(pose.orientation).w, 1e-12),
        );
      },
    );

    test(
      'an incomplete pose is null, so the caller refuses the photo',
      () async {
        for (final payload in <Map<String, Object?>>[
          stillPayload(px: null)..remove('px'),
          stillPayload(qw: double.nan),
          stillPayload()..remove('qy'),
        ]) {
          answerWith(payload);
          final still = await host.takeStill();
          expect(still.capturePose, isNull);
        }
      },
    );

    test('a payload without JPEG bytes is an ArCoreFailure', () async {
      answerWith(<String, Object?>{...stillPayload(), 'jpeg': null});
      await expectLater(host.takeStill(), throwsA(isA<ArCoreFailure>()));
    });

    test('a null native result is an ArCoreFailure', () async {
      answerWith(null);
      await expectLater(host.takeStill(), throwsA(isA<ArCoreFailure>()));
    });
  });
}
