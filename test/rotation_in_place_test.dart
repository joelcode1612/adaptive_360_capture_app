import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/core/math/vio_sphere_math.dart' as vio;
import 'package:adaptive_360_capture_app/features/capture/domain/services/rotation_in_place.dart';

/// §8 body-rotation regression tests, ported from the source project.
///
/// The capture gate freezes a station origin, but the operator's body pivots
/// behind the phone: a 90° turn with the phone held 0.40 m forward moves the
/// camera ~0.57 m — far past the 0.20 m drift gate — without the operator
/// having walked anywhere. `RotationInPlaceMonitor` fits a fixed-pivot circle
/// to the yaw sweep and, only while the camera keeps travelling that arc,
/// measures drift from the predicted pivot point instead of the frozen origin.
/// Every test here keeps a way to cheat closed: spirals, sideways slides,
/// back-and-forth yaw and tracking breaks all drop straight back to the
/// strict gate.
void main() {
  const origin = vio.Vec3(0, 0, 0);
  final start = DateTime.utc(2026, 11, 12, 6);
  const stepMs = 66;

  /// Turns the whole body with the phone held [offsetM] in front of the
  /// operator. The camera therefore starts **at the station origin** and
  /// travels around a pivot behind it — the physical motion the 0.20 m gate
  /// must tolerate — instead of orbiting the calibration point.
  RotationInPlaceAssessment bodyTurn(
    RotationInPlaceMonitor monitor, {
    required double offsetM,
    required double sweepDeg,
    double degreesPerSecond = 45,
    double tremorM = 0,
    int? maxSamples,
  }) {
    var result = const RotationInPlaceAssessment(
      rawDriftM: 0,
      effectiveDriftM: 0,
      rotatingInPlace: false,
      withinAllowance: true,
    );
    final stepDeg = degreesPerSecond * stepMs / 1000;
    final totalSteps = maxSamples ?? (sweepDeg / stepDeg).ceil();
    for (var i = 0; i <= totalSteps; i++) {
      final theta = math.min(i * stepDeg, sweepDeg);
      final radians = theta * math.pi / 180;
      // Pivot sits directly behind the calibration camera position: the
      // camera starts at the station origin and travels around it.
      final jitter = tremorM * math.sin(i * 2.7);
      result = monitor.observe(
        position: vio.Vec3(
          offsetM * math.sin(radians) + jitter,
          0,
          offsetM * (math.cos(radians) - 1),
        ),
        yawDeg: theta,
        at: start.add(Duration(milliseconds: i * stepMs)),
        timestampNanoseconds: i * stepMs * 1000000,
      );
    }
    return result;
  }

  test('a body-spin with the phone held forward is not a walk-away', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    final result = bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);

    expect(result.rotatingInPlace, isTrue);
    expect(result.compensationActive, isTrue);
    expect(result.rotationRadiusM, closeTo(0.40, 0.02));
    expect(result.rawDriftM, greaterThan(0.20));
    // The gate sees the deviation from the predicted pivot path, not the
    // ~0.57 m translation the turn produced.
    expect(result.effectiveDriftM, lessThan(0.20));
    expect(result.driftReference, isNotNull);
  });

  test('90°, 180° and 360° body turns stay inside the compensated gate', () {
    for (final sweep in <double>[90, 180, 360]) {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      final result = bodyTurn(monitor, offsetM: 0.35, sweepDeg: sweep);
      expect(result.rotatingInPlace, isTrue, reason: 'sweep $sweep');
      expect(result.effectiveDriftM, lessThan(0.20), reason: 'sweep $sweep');
      expect(result.rawDriftM, lessThanOrEqualTo(1.05), reason: 'sweep $sweep');
    }
  });

  test('natural hand tremor during a body turn keeps compensation active', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    final result = bodyTurn(
      monitor,
      offsetM: 0.40,
      sweepDeg: 90,
      tremorM: 0.02,
    );
    expect(result.rotatingInPlace, isTrue);
    expect(result.effectiveDriftM, lessThan(0.10));
  });

  test('rotating the phone about its own centre needs no compensation', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    // Phone-only spin: camera stays within 3 cm of the calibrated point, so
    // the strict frozen-origin gate already accepts every frame.
    final result = bodyTurn(monitor, offsetM: 0.02, sweepDeg: 90);
    expect(result.rotatingInPlace, isFalse);
    expect(result.compensationActive, isFalse);
    expect(result.effectiveDriftM, result.rawDriftM);
    expect(result.rawDriftM, lessThan(0.20));
  });

  test('a slow walk-away never establishes a pivot model', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    var result = const RotationInPlaceAssessment(
      rawDriftM: 0,
      effectiveDriftM: 0,
      rotatingInPlace: false,
      withinAllowance: true,
    );
    // Walks away while turning: a spiral, not a fixed-pivot circle.
    for (var i = 0; i <= 30; i++) {
      final theta = i * 2.0;
      final radius = i * 0.02;
      final radians = theta * math.pi / 180;
      result = monitor.observe(
        position: vio.Vec3(
          radius * math.sin(radians),
          0,
          radius * math.cos(radians),
        ),
        yawDeg: theta,
        at: start.add(Duration(milliseconds: i * stepMs)),
        timestampNanoseconds: i * stepMs * 1000000,
      );
    }
    expect(result.rotatingInPlace, isFalse);
    expect(result.effectiveDriftM, result.rawDriftM);
    expect(result.rawDriftM, greaterThan(0.20));
  });

  test('sideways movement without a yaw sweep keeps the strict gate', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    var result = const RotationInPlaceAssessment(
      rawDriftM: 0,
      effectiveDriftM: 0,
      rotatingInPlace: false,
      withinAllowance: true,
    );
    for (var i = 0; i <= 20; i++) {
      result = monitor.observe(
        position: vio.Vec3(i * 0.025, 0, 0),
        yawDeg: 0,
        at: start.add(Duration(milliseconds: i * stepMs)),
        timestampNanoseconds: i * stepMs * 1000000,
      );
    }
    expect(result.rotatingInPlace, isFalse);
    expect(result.effectiveDriftM, result.rawDriftM);
    expect(result.rawDriftM, greaterThan(0.20));
  });

  test('back-and-forth yaw does not establish a pivot model', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    var result = const RotationInPlaceAssessment(
      rawDriftM: 0,
      effectiveDriftM: 0,
      rotatingInPlace: false,
      withinAllowance: true,
    );
    for (var i = 0; i <= 60; i++) {
      final theta = 25 * math.sin(i * 0.35);
      final radians = theta * math.pi / 180;
      result = monitor.observe(
        position: vio.Vec3(
          0.40 * math.sin(radians),
          0,
          0.40 * math.cos(radians),
        ),
        yawDeg: theta,
        at: start.add(Duration(milliseconds: i * stepMs)),
        timestampNanoseconds: i * stepMs * 1000000,
      );
    }
    expect(result.rotationRadiusM, isNull);
    expect(result.rotatingInPlace, isFalse);
  });

  test('beyond the raw excursion cap the compensation is refused', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    final result = bodyTurn(monitor, offsetM: 0.60, sweepDeg: 180);
    expect(result.withinAllowance, isFalse);
    expect(result.rotatingInPlace, isFalse);
    expect(result.effectiveDriftM, result.rawDriftM);
  });

  test(
    'leaving the predicted pivot path drops straight back to the raw gate',
    () {
      final monitor = RotationInPlaceMonitor(stationOrigin: origin);
      bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
      // After the turn the operator slides 0.4 m sideways off the arc.
      var moved = const RotationInPlaceAssessment(
        rawDriftM: 0,
        effectiveDriftM: 0,
        rotatingInPlace: false,
        withinAllowance: true,
      );
      for (var i = 0; i < 8; i++) {
        moved = monitor.observe(
          position: vio.Vec3(0.40 + i * 0.05, 0, -0.40),
          yawDeg: 90,
          at: start.add(Duration(milliseconds: 2100 + i * stepMs)),
          timestampNanoseconds: (2100 + i * stepMs) * 1000000,
        );
      }
      expect(moved.rotatingInPlace, isFalse);
      expect(moved.effectiveDriftM, moved.rawDriftM);
    },
  );

  test('a tracking break invalidates the pivot model', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
    monitor.invalidate();
    final after = monitor.observe(
      position: const vio.Vec3(0.40, 0, -0.40),
      yawDeg: 90,
      at: start.add(const Duration(milliseconds: 900)),
      timestampNanoseconds: 900 * 1000000,
    );
    expect(after.rotatingInPlace, isFalse);
    expect(after.rotationRadiusM, isNull);
  });

  test('a sample-gap or timestamp discontinuity invalidates the model', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    bodyTurn(monitor, offsetM: 0.40, sweepDeg: 90);
    final after = monitor.observe(
      position: const vio.Vec3(0.40, 0, -0.40),
      yawDeg: 90,
      at: start.add(const Duration(milliseconds: 2600)),
      timestampNanoseconds: 2600 * 1000000,
    );
    // ~550 ms after the last turn sample: outside the continuity window.
    expect(after.rotatingInPlace, isFalse);
    expect(after.rotationRadiusM, isNull);
  });

  test('stopping mid-turn keeps the hold compensated and ready', () {
    final monitor = RotationInPlaceMonitor(stationOrigin: origin);
    bodyTurn(monitor, offsetM: 0.40, sweepDeg: 120);
    // The operator stops and holds. Raw drift stays ~0.69 m, so only the
    // verified pivot reference can keep the capture gate open.
    var held = const RotationInPlaceAssessment(
      rawDriftM: 0,
      effectiveDriftM: 0,
      rotatingInPlace: false,
      withinAllowance: true,
    );
    for (var i = 0; i < 20; i++) {
      held = monitor.observe(
        position: vio.Vec3(
          0.40 * math.sin(120 * math.pi / 180),
          0,
          0.40 * (math.cos(120 * math.pi / 180) - 1),
        ),
        yawDeg: 120,
        at: start.add(Duration(milliseconds: 2800 + i * stepMs)),
        timestampNanoseconds: (2800 + i * stepMs) * 1000000,
      );
    }
    expect(held.rotatingInPlace, isTrue);
    expect(held.compensationActive, isTrue);
    expect(held.effectiveDriftM, lessThan(0.05));
  });

  test(
    'the engine gates on the pivot reference but still reports raw distance',
    () {
      final engine = vio.VioSphereEngine();
      engine.calibrateWithReference(stationOrigin: origin, stationYawRad: 0);
      const position = vio.Vec3(0.45, 0, 0);
      final pose = vio.VioPoseSample(
        position: position,
        rotation: const vio.Quat(0, 0, 0, 1),
        timestampNanoseconds: 0,
      );

      final strict = engine.evaluateFrame(
        pose: pose,
        trackingValid: true,
        activeTargetIndex: 0,
      );
      expect(strict.isWithinStation, isFalse);
      expect(strict.rawDriftM, closeTo(0.45, 1e-6));

      final compensated = engine.evaluateFrame(
        pose: pose,
        trackingValid: true,
        activeTargetIndex: 0,
        stationDriftReference: position,
      );
      expect(compensated.isWithinStation, isTrue);
      expect(compensated.stationDriftM, closeTo(0, 1e-6));
      expect(compensated.rawDriftM, closeTo(0.45, 1e-6));
    },
  );
}
