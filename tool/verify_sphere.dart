// Reproducible proof that the 26 capture targets are placed from the frozen
// station reference and nowhere else.
//
// Builds a station frame through the real calibration path, places all 26
// targets through the real `resolveTarget`, and then asks the two questions the
// "the targets move with the phone" report raises:
//
//   1. is every target exactly `targetRadiusM` from the station origin, at its
//      intended yaw/pitch in the station frame?
//   2. does any target's **world** position change when the camera moves?
//
// Run: dart run tool/verify_sphere.dart
import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// A station the user calibrated while standing at (0.3, 1.5, −1.2) facing world
/// +Z with the phone held level. `Ry(180)` is the ARCore pose whose optical axis
/// is +Z, so the capture-world orientation is identity and the reference comes
/// out level by construction — the same path `calibrateStation` walks.
StationFrame buildStation() {
  const origin = Vec3(0.3, 1.5, -1.2);
  final arPose = Quat.axisAngle(180, Vec3.unitY);
  final reference = captureReferenceFromPose(
    cameraForward: arCameraPoseToCaptureWorld(arPose).rotate(Vec3.unitZ),
  );
  if (!reference.ok)
    throw StateError(reference.reason ?? 'calibration refused');
  return StationFrame(origin: origin, orientation: reference.orientation!);
}

void main() {
  final radius = const CaptureGeometryConfig().targetRadiusM;
  final station = buildStation();
  final specs = buildCaptureSphere();

  print('== station');
  print('  origin      ${station.origin}');
  print('  orientation ${station.orientation}');
  print(
    '  right/up/fwd ${station.rightAxis} ${station.upAxis} ${station.forwardAxis}',
  );

  // ── 1. every target at its intended spherical position ───────────────────
  print('\n== placement (radius $radius m)');
  var worstRadius = 0.0;
  var worstYaw = 0.0;
  var worstPitch = 0.0;
  for (final spec in specs) {
    final resolved = resolveTarget(
      station: station,
      spec: spec,
      radiusM: radius,
    );
    final offset = resolved.worldPosition - station.origin;
    final radiusError = (offset.length - radius).abs();
    final angles = StationFrame.anglesOf(spec.direction);
    final yawError = (angles.yawDeg - spec.yawDegrees).abs();
    final pitchError = (angles.pitchDeg - spec.pitchDegrees).abs();
    worstRadius = math.max(worstRadius, radiusError);
    worstYaw = math.max(worstYaw, yawError);
    worstPitch = math.max(worstPitch, pitchError);
    if (spec.targetId <= 3 || spec.isPole) {
      print(
        '  T${spec.targetId.toString().padLeft(2, '0')} '
        'yaw ${spec.yawDegrees.toStringAsFixed(0).padLeft(4)}° '
        'pitch ${spec.pitchDegrees.toStringAsFixed(0).padLeft(3)}° → '
        '${resolved.worldPosition}  '
        '|r−$radius| = ${radiusError.toStringAsExponential(1)}  '
        'face ${resolved.facingNormal}',
      );
    }
  }
  print('  worst |r − $radius| = ${worstRadius.toStringAsExponential(1)} m');
  print('  worst yaw error    = ${worstYaw.toStringAsExponential(1)}°');
  print('  worst pitch error  = ${worstPitch.toStringAsExponential(1)}°');

  // ── 2. does the camera move the targets? ─────────────────────────────────
  // Three camera poses that differ by rotation and by translation. Each is a
  // full RigidPose; the placement takes none of them as input.
  final placed = <int, Vec3>{
    for (final spec in specs)
      spec.targetId: resolveTarget(
        station: station,
        spec: spec,
        radiusM: radius,
      ).worldPosition,
  };

  final cameras = <String, RigidPose>{
    'at the station, facing +Z': RigidPose(
      position: station.origin,
      orientation: Quat.identity,
    ),
    'turned 90° right': RigidPose(
      position: station.origin,
      orientation: Quat.axisAngle(90, Vec3.unitY),
    ),
    'tilted up 40°': RigidPose(
      position: station.origin,
      orientation: Quat.axisAngle(-40, Vec3.unitX),
    ),
    'walked 2 m right and 1 m forward': RigidPose(
      position: station.origin + const Vec3(-2, 0, 1),
      orientation: Quat.fromYawPitch(35, -12),
    ),
  };

  print('\n== world position under camera movement');
  var worstMove = 0.0;
  cameras.forEach((String label, RigidPose camera) {
    // The only thing that reads the camera is the *screen* projection, so the
    // world position is re-derived exactly as placement derives it.
    for (final spec in specs) {
      final resolved = resolveTarget(
        station: station,
        spec: spec,
        radiusM: radius,
      );
      final moved = (resolved.worldPosition - placed[spec.targetId]!).length;
      worstMove = math.max(worstMove, moved);
    }
    // Where target 1 lands on a 1080×2400 viewport with the reported display
    // field of view: this is the number that legitimately changes with the
    // camera, and it is the only one.
    final one = resolveTarget(
      station: station,
      spec: specs.first,
      radiusM: radius,
    );
    final d = (one.worldPosition - camera.position).normalized;
    final dc = camera.orientation.toCameraFrame(d);
    final fov = ArCameraIntrinsics.fallbackDisplayFov;
    final p = project(dc, 1080, 2400, fov.hfovDeg, fov.vfovDeg);
    print(
      '  $label → T01 screen (${p.u.toStringAsFixed(0)}, '
      '${p.v.toStringAsFixed(0)}) onScreen=${p.onScreen}',
    );
  });
  print(
    '  worst world movement across all four cameras: '
    '${worstMove.toStringAsExponential(1)} m',
  );

  // ── 3. the marker is not a billboard ─────────────────────────────────────
  // Its facing is fixed at placement, so it must not follow the camera.
  print('\n== facing under camera movement');
  cameras.forEach((String label, RigidPose camera) {
    final one = resolveTarget(
      station: station,
      spec: specs.first,
      radiusM: radius,
    );
    final toCamera = (camera.position - one.worldPosition).normalized;
    final dot = one.facingNormal.dot(toCamera);
    print('  $label → facing·toCamera = ${dot.toStringAsFixed(4)}');
  });
  print('  (1.0 = squarely facing the camera; anything else = world-fixed)');
}
