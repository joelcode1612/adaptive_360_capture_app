import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// A landscape 4:3 sensor whose long-side field is exactly 90°.
const ArCameraIntrinsics sensor = ArCameraIntrinsics(
  focalLengthXPx: 2000,
  focalLengthYPx: 2000,
  principalPointXPx: 2000,
  principalPointYPx: 1500,
  imageWidth: 4000,
  imageHeight: 3000,
  rotationDeg: 0,
);

void main() {
  group('image-axis field of view', () {
    test('sensor axes are not swapped when image x runs across the screen', () {
      final fov = sensor.displayFovForImageAxis(axisX: 1, axisY: 0);
      expect(fov.hfovDeg, closeTo(90, 1e-6));
      expect(fov.vfovDeg, closeTo(73.739795, 1e-4));
    });

    test('portrait swaps the axes when image x runs down the screen', () {
      final fov = sensor.displayFovForImageAxis(axisX: 0, axisY: 1);
      expect(fov.hfovDeg, closeTo(73.739795, 1e-4));
      expect(fov.vfovDeg, closeTo(90, 1e-6));
    });

    test('the sign of the axis does not decide the swap', () {
      final left = sensor.displayFovForImageAxis(axisX: -1, axisY: 0);
      final up = sensor.displayFovForImageAxis(axisX: 0, axisY: -1);
      expect(left.hfovDeg, closeTo(90, 1e-6));
      expect(up.hfovDeg, closeTo(73.739795, 1e-4));
    });

    test('a diagonal axis keeps the sensor orientation', () {
      final fov = sensor.displayFovForImageAxis(axisX: 0.707, axisY: 0.707);
      expect(fov.hfovDeg, closeTo(90, 1e-6));
    });

    test('a surface rotation of 0 does not un-swap a portrait image', () {
      // This is the defect the measured axis fixes: the surface is at
      // ROTATION_0 because the app is portrait-locked, but the landscape
      // sensor still lands rotated 90° on screen.
      final portrait = sensor.displayFovForImageAxis(axisX: 0, axisY: 1);
      final legacy = sensor.portraitDisplayFov();
      expect(portrait.hfovDeg, lessThan(portrait.vfovDeg));
      expect(legacy.hfovDeg, greaterThan(legacy.vfovDeg));
    });

    test('the transform is square: tan(h/2)/tan(v/2) matches the aspect', () {
      final fov = sensor.displayFovForImageAxis(axisX: 0, axisY: 1);
      final ratio =
          math.tan(fov.hfovDeg * math.pi / 360) /
          math.tan(fov.vfovDeg * math.pi / 360);
      expect(ratio, closeTo(3000 / 4000, 1e-9));
    });
  });

  test('the fallback is already in portrait display terms', () {
    final fov = ArCameraIntrinsics.fallbackDisplayFov;
    expect(fov.hfovDeg, lessThan(fov.vfovDeg));
    expect(fov.vfovDeg, closeTo(68, 1e-9));
  });
}
