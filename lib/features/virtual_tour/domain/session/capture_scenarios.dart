import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/room_occlusion.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';

/// The reference's baseline plan parameters and its ten scripted scenarios.
///
/// Ported from `BASE` and `SCEN` in `/*ENGINE*/`. These are **test fixtures**:
/// they exist so the state machine can be exercised end to end against known
/// outcomes without a device.

/// Baseline plan parameters, identical to the reference's `BASE`.
const PlanParams baselinePlanParams = PlanParams(
  hfovDeg: 55,
  vfovDeg: 70,
  overlapH: 0.25,
  overlapV: 0.25,
  pattern: 'adaptive',
  yaw0Deg: 0,
  repair: true,
  quality: 'standard',
  budgetMinutes: 0,
  turnSpeedDegPerSec: 40,
  settleMs: 400,
  maxRetry: 3,
  clearanceM: 0.5,
);

/// One scripted scenario.
class CaptureScenario {
  final String name;

  /// What the reference says should happen.
  final String expectation;

  final RoomBox room;
  final ({double x, double z}) position;
  final SessionConditions conditions;
  final List<ObstacleBox> obstacles;
  final bool autoViewpoint;

  const CaptureScenario({
    required this.name,
    required this.expectation,
    required this.room,
    required this.position,
    this.conditions = const SessionConditions(),
    this.obstacles = const <ObstacleBox>[],
    this.autoViewpoint = false,
  });
}

/// The ten scenarios, in the reference's order.
const List<CaptureScenario> captureScenarios = <CaptureScenario>[
  CaptureScenario(
    name: 'Normal rectangular room, good lighting',
    expectation:
        'Every target accepted, full coverage, no extra photos or '
        'viewpoints.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
  ),
  CaptureScenario(
    name: 'Large room, long viewing distance',
    expectation: 'Full coverage and low parallax. A longer capture time.',
    room: RoomBox(lengthM: 12, widthM: 9),
    position: (x: 6, z: 4.5),
    conditions: SessionConditions(nearDistance: 6, radius: 0.15),
  ),
  CaptureScenario(
    name: 'Small room with nearby furniture',
    expectation:
        'Coverage is complete but parallax risk is high and the '
        'furniture blocks part of the view, so another viewpoint is '
        'recommended.',
    room: RoomBox(lengthM: 3, widthM: 2.6),
    position: (x: 1.5, z: 1.3),
    conditions: SessionConditions(nearDistance: 0.7, radius: 0.2),
    obstacles: <ObstacleBox>[
      ObstacleBox(x: 2.2, z: 1.3, w: 0.8, d: 1.6, h: 1.1),
    ],
    autoViewpoint: true,
  ),
  CaptureScenario(
    name: 'Blank white walls',
    expectation:
        'Sharp but low-detail frames are accepted with a warning, '
        'with no endless retries.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(blank: true),
  ),
  CaptureScenario(
    name: 'Mirrors or reflective surfaces',
    expectation:
        'Frames are accepted, the reflective region is recorded, and '
        'no extra geometry is assumed.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(mirror: true),
  ),
  CaptureScenario(
    name: 'Poor lighting and bright windows',
    expectation:
        'Dark and overexposed frames are rejected, then recover after '
        'exposure adjustment or are skipped with a warning.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(light: 0.22, window: 2.2, noise: 6),
  ),
  CaptureScenario(
    name: 'One frame fails quality validation',
    expectation:
        'Exactly one frame is rejected as blurry, then the retry '
        'succeeds.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(failIndex: 7),
  ),
  CaptureScenario(
    name: 'Partially obstructed viewpoint',
    expectation:
        'The coverage test passes, but the obstruction is detected '
        'and a second viewpoint is recommended rather than reporting the room '
        'complete.',
    room: RoomBox(lengthM: 6, widthM: 4),
    position: (x: 2, z: 2),
    obstacles: <ObstacleBox>[ObstacleBox(x: 3, z: 2, w: 1, d: 2.4, h: 1.9)],
    autoViewpoint: true,
  ),
  CaptureScenario(
    name: 'Orientation sensor loss',
    expectation:
        'Automatic capture pauses, three frames are captured '
        'manually, and all are recorded as manual.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(trackLoss: true),
  ),
  CaptureScenario(
    name: 'Camera position shift during rotation',
    expectation:
        'Frames after the shift are excluded from the panorama group '
        'and retaken.',
    room: RoomBox(lengthM: 5, widthM: 4),
    position: (x: 2.5, z: 2),
    conditions: SessionConditions(shift: true),
  ),
];

/// Runs scenario [index] and returns the finished session.
CaptureSession runScenario(int index) {
  final s = captureScenarios[index];
  return runCaptureSession(
    SessionConfig(
      plan: baselinePlanParams,
      conditions: s.conditions,
      position: s.position,
      room: s.room,
      obstacles: s.obstacles,
      autoViewpoint: s.autoViewpoint,
      seed: 11 + index,
    ),
  );
}

/// Runs every scenario.
List<CaptureSession> runAllScenarios() =>
    List<CaptureSession>.generate(captureScenarios.length, runScenario);
