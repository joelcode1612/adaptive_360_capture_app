import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/parallax.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/room_occlusion.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/environment/viewpoint.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/coverage.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_generator.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/decision_rules.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/image_analysis.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/testkit/simulated_room.dart';

/// The capture state machine.
///
/// Ported from `class Session` in `/*ENGINE*/`. The required sequence is
/// `INITIALISE → SURVEY → PLAN → ALIGN → SETTLE → CAPTURE → VALIDATE →
/// ACCEPT or RETRY → NEXT_TARGET → VERIFY → NEXT_VIEWPOINT or COMPLETE`, and
/// **a frame is never marked done unless it passed validation**.
///
/// The machine is pure: it takes a pose source and a frame source, and it never
/// touches Flutter, the camera or the AR session. Simulation mode supplies both
/// from the procedural room; live mode supplies them through
/// [LiveSensorSource], which the `ar/` and `camera/` layers implement.

/// Phases, with the wire names the reference uses (so logs and tests read the
/// same in both implementations).
enum CapturePhase {
  initialise('INITIALISE'),
  survey('SURVEY'),
  plan('PLAN'),
  align('ALIGN'),
  settle('SETTLE'),
  capture('CAPTURE'),
  validate('VALIDATE'),
  accept('ACCEPT'),
  retry('RETRY'),
  nextTarget('NEXT_TARGET'),
  verify('VERIFY'),
  nextViewpoint('NEXT_VIEWPOINT'),
  complete('COMPLETE');

  const CapturePhase(this.label);

  /// Upper-snake-case name, e.g. `NEXT_TARGET`.
  final String label;
}

/// Per-target progress. `ok` is only ever set after a frame passed validation.
enum TargetStatus { pending, ok, skipped }

/// One target of the active viewpoint.
class CaptureTarget {
  final PlanFrame frame;
  TargetStatus status = TargetStatus.pending;
  int tries = 0;

  CaptureTarget(this.frame);
}

/// One panorama group. Frames are never merged across viewpoints.
class Viewpoint {
  final ({double x, double z}) position;
  final CapturePlan plan;

  int extra = 0;
  double? coverageBefore;
  double? coverageAfter;
  CoverageStats? stats;
  double occlusion = 0;
  final List<String> unresolved = <String>[];
  final List<String> warnings = <String>[];
  List<int>? visibility;
  double hiddenPct = 0;
  int lowInformationCount = 0;
  int mirrorCount = 0;
  int nearCount = 0;
  int shiftedCount = 0;
  ParallaxEstimate? parallax;
  ViewpointSuggestion? recommendation;

  Viewpoint({required this.position, required this.plan});
}

/// A single log line emitted by the machine.
class SessionLogEntry {
  final double t;
  final String phase;
  final String level;
  final String message;

  const SessionLogEntry({
    required this.t,
    required this.phase,
    required this.level,
    required this.message,
  });

  @override
  String toString() =>
      '${t.toStringAsFixed(2)}s [${phase.padRight(12)}] $message';
}

/// The frame most recently captured, before validation.
class LastCapture {
  final Uint8List? rgba;
  final Float64List gray;
  final int w;
  final int h;

  /// The pose actually used for the shot (display yaw/pitch).
  final double poseYawDeg;
  final double posePitchDeg;
  final Quat pose;
  final double? errorDeg;
  final AimResult? aim;

  final double hfovDeg;
  final double vfovDeg;
  bool shifted = false;

  LastCapture({
    required this.rgba,
    required this.gray,
    required this.w,
    required this.h,
    required this.poseYawDeg,
    required this.posePitchDeg,
    required this.pose,
    required this.errorDeg,
    required this.aim,
    required this.hfovDeg,
    required this.vfovDeg,
  });
}

/// An accepted frame and its recorded evidence.
class AcceptedFrame {
  final int viewpointIndex;
  final int index;

  final double targetYawDeg;
  final double targetPitchDeg;
  final double hfovDeg;
  final double vfovDeg;

  final String? warning;
  final bool manual;
  final int attempts;
  final bool shifted;

  /// True when the file was found missing after capture (simulated fault).
  bool lost;

  final ImageStats stats;
  final Quat? pose;
  final Vec3 direction;
  final double? errorDeg;
  final Vec3? axis;
  final bool? axisDegenerate;

  final bool targetIsPole;
  final bool mirror;
  final bool near;

  /// When the bytes of this frame reached disk, stamped by the store.
  ///
  /// `null` until the frame has been written, and `null` for a manifest written
  /// before this field existed. It lives here rather than in the state machine
  /// because `domain/` deliberately never reads the wall clock — the machine is
  /// deterministic, and a timestamp would make it non-reproducible.
  DateTime? savedAt;

  AcceptedFrame({
    required this.viewpointIndex,
    required this.index,
    required this.targetYawDeg,
    required this.targetPitchDeg,
    required this.hfovDeg,
    required this.vfovDeg,
    required this.warning,
    required this.manual,
    required this.attempts,
    required this.shifted,
    required this.lost,
    required this.stats,
    required this.pose,
    required this.direction,
    required this.errorDeg,
    required this.axis,
    required this.axisDegenerate,
    required this.targetIsPole,
    required this.mirror,
    required this.near,
    this.savedAt,
  });
}

/// End-of-run summary.
class CaptureSummary {
  final int planned;
  final int accepted;
  final int rejected;
  final int retried;
  final int skipped;
  final int manual;
  final int lost;
  final double? coverageBefore;
  final double? coverageAfter;
  final int extraPhotos;
  final int extraViewpoints;
  final List<String> unresolved;
  final List<String> warnings;
  final ViewpointSuggestion? recommended;

  const CaptureSummary({
    required this.planned,
    required this.accepted,
    required this.rejected,
    required this.retried,
    required this.skipped,
    required this.manual,
    required this.lost,
    required this.coverageBefore,
    required this.coverageAfter,
    required this.extraPhotos,
    required this.extraViewpoints,
    required this.unresolved,
    required this.warnings,
    required this.recommended,
  });

  @override
  String toString() =>
      'planned $planned, accepted $accepted, '
      'rejected $rejected, retried $retried, skipped $skipped, '
      'manual $manual, lost $lost, extra photos $extraPhotos, '
      'extra viewpoints $extraViewpoints';
}

/// Simulated fault and environment knobs (the reference's `cond`).
class SessionConditions {
  final int? failIndex;
  final bool blank;
  final bool mirror;
  final double? light;
  final double? window;
  final double noise;
  final double blurBase;
  final bool blurFrames;
  final bool trackLoss;
  final bool shift;
  final bool fovChange;
  final int fovAfter;
  final double fovScale;
  final double drift;
  final double lossProbability;
  final double? nearDistance;
  final double radius;

  const SessionConditions({
    this.failIndex,
    this.blank = false,
    this.mirror = false,
    this.light,
    this.window,
    this.noise = 0,
    this.blurBase = 0,
    this.blurFrames = false,
    this.trackLoss = false,
    this.shift = false,
    this.fovChange = false,
    this.fovAfter = 10,
    this.fovScale = 0.7,
    this.drift = 0,
    this.lossProbability = 0,
    this.nearDistance,
    this.radius = 0.15,
  });
}

/// Live pose + frame source. Implemented by the `ar/` and `camera/` layers.
///
/// The domain never imports those layers; it only sees this interface, which
/// is why the whole machine stays unit-testable.
abstract class LiveSensorSource {
  /// Current camera orientation in this project's world convention, or null
  /// when tracking is unavailable.
  Quat? sensedOrientation();

  /// Angular rate magnitude in degrees per second, or null when unavailable.
  double? angularRateDegPerSec();

  /// A captured frame, or null when the camera produced nothing.
  LiveFrame? grabFrame();

  /// Runs the environment survey. Returns false to keep the machine in SURVEY.
  bool survey();

  /// What to tell the user when [sensedOrientation] returns `null`.
  ///
  /// Defaults to `null`, and the machine then falls back to its own generic
  /// wording. The live source overrides it so that losing AR tracking produces
  /// the brief's specific recovery instruction — point the phone back at the
  /// direction the station started in — instead of a generic "aim by eye".
  String? get trackingAdvice => null;
}

/// A frame handed over by the live pipeline.
class LiveFrame {
  final Uint8List rgba;
  final int w;
  final int h;

  const LiveFrame({required this.rgba, required this.w, required this.h});
}

/// Everything the machine needs to run.
class SessionConfig {
  final PlanParams plan;
  final QualityThresholds thresholds;
  final SessionConditions conditions;
  final bool live;
  final int seed;
  final ({double x, double z}) position;
  final RoomBox room;
  final List<ObstacleBox> obstacles;
  final bool autoViewpoint;
  final LiveSensorSource? sensorSource;

  /// Whether [room] and [obstacles] describe the real space.
  ///
  /// The reference always has a room model because it always renders a
  /// procedural one. A live capture does not: ARCore reports planes, not a room
  /// box, and nothing in this project derives obstacles from plane data yet.
  ///
  /// Defaults to `true` so the simulated scenarios keep their occlusion and
  /// wall-visibility numbers unchanged. **The live path must pass `false`**,
  /// otherwise `_verify()` would report an occlusion percentage computed from a
  /// 5 m × 4 m box that nobody measured — a fabricated number shown to the user
  /// as a measurement, which is precisely what the brief forbids. With `false`
  /// those fields are reported as unavailable and the viewpoint recommendation
  /// is driven by coverage gaps and parallax alone.
  final bool roomIsMeasured;

  /// An explicit plan to use instead of deriving one from [plan].
  ///
  /// The live flow sets this to the fixed 26-point commercial plan so the
  /// session's targets match the prototype exactly; when `null` the session
  /// falls back to [planAll].
  final CapturePlan? fixedPlan;

  const SessionConfig({
    required this.plan,
    this.thresholds = QualityThresholds.provisional,
    this.conditions = const SessionConditions(),
    this.live = false,
    this.seed = 7,
    this.position = (x: 0, z: 0),
    this.room = const RoomBox(lengthM: 5, widthM: 4),
    this.obstacles = const <ObstacleBox>[],
    this.autoViewpoint = false,
    this.sensorSource,
    this.roomIsMeasured = true,
    this.fixedPlan,
  });
}

/// Analysis frames are deliberately small: the reference uses 120×160 and the
/// product downsamples before analysis too, so the isolate never sees a full
/// resolution frame.
const int analysisWidth = 120;
const int analysisHeight = 160;

/// The capture state machine.
class CaptureSession {
  final SessionConfig config;
  final PlanParams params;
  final QualityThresholds thresholds;
  final SessionConditions conditions;
  final bool live;
  final LiveSensorSource? sensorSource;

  final Mulberry32 _rand;
  final SphereSamples _samples;

  CapturePhase phase = CapturePhase.initialise;
  final List<String> history = <String>[CapturePhase.initialise.label];

  double t = 0;
  double wait = 0;

  final List<SessionLogEntry> log = <SessionLogEntry>[];
  final List<AcceptedFrame> acceptedFrames = <AcceptedFrame>[];
  final List<Viewpoint> viewpoints = <Viewpoint>[];

  int viewpointIndex = -1;
  List<CaptureTarget> targets = <CaptureTarget>[];
  int currentTargetIndex = 0;

  /// Pose is a unit quaternion. Euler angles are derived for display only.
  Quat pose = Quat.identity;
  ({double yawDeg, double pitchDeg}) displayPose = (yawDeg: 0, pitchDeg: 0);

  double drift = 0;
  double exposureCompensation = 1;
  String message = '';
  int attempt = 0;
  int rounds = 0;

  Vec3 rate = Vec3.zero;
  AimResult? aimResult;
  Vec3? cameraFrameDirection;

  int rejections = 0;
  int retries = 0;
  int skips = 0;
  int lostFrames = 0;
  int manualFrames = 0;
  int warnedFrames = 0;

  bool paused = false;
  bool manual = false;
  double settleTime = 0;
  bool positionShifted = false;
  bool manualCapture = false;
  bool hold = false;
  double manualTimer = 0;
  double motionCap = 0;

  LastCapture? last;
  QualityDecision? decision;
  ImageStats? stats;
  ViewpointSuggestion? recommendation;
  CaptureSummary? summary;
  double hiddenPct = 0;

  CaptureSession(this.config)
    : params = config.plan,
      thresholds = config.thresholds,
      conditions = config.conditions,
      live = config.live,
      sensorSource = config.sensorSource,
      _rand = Mulberry32(config.seed),
      _samples = fibonacciSamples(4000);

  CaptureTarget get current => targets[currentTargetIndex];
  Viewpoint get viewpoint => viewpoints[viewpointIndex];
  bool get isComplete => phase == CapturePhase.complete;

  void _go(CapturePhase p) {
    phase = p;
    history.add(p.label);
  }

  void _event(String msg, [String level = 'info']) {
    log.add(
      SessionLogEntry(
        t: _round2(t),
        phase: phase.label,
        level: level,
        message: msg,
      ),
    );
  }

  /// Opens a new panorama group and plans its targets.
  void startViewpoint(({double x, double z}) position) {
    final plan = config.fixedPlan ?? planAll(params, _samples);
    viewpoints.add(Viewpoint(position: position, plan: plan));
    viewpointIndex++;
    targets = plan.frames.map(CaptureTarget.new).toList();
    currentTargetIndex = 0;
    rounds = 0;
    attempt = 0;
    _event(
      'Viewpoint ${viewpointIndex + 1}: ${plan.frames.length} '
      'targets planned',
    );
  }

  /// True while the simulated "sensor loss" window is active.
  bool get _orientationLostNow {
    if (!conditions.trackLoss) return false;
    final start = (targets.length * 0.4).floor();
    return currentTargetIndex >= start &&
        currentTargetIndex < start + 3 &&
        rounds == 0 &&
        !live;
  }

  /// Advances the machine by [dt] seconds.
  void tick(double dt) {
    if (paused || phase == CapturePhase.complete) return;
    t += dt;
    if (!live) drift += conditions.drift * dt / 60;

    switch (phase) {
      case CapturePhase.initialise:
        _event(
          live
              ? 'Capabilities read from the device'
              : 'Capabilities are simulated',
        );
        _go(CapturePhase.survey);
      case CapturePhase.survey:
        if (live && sensorSource != null && !sensorSource!.survey()) break;
        _go(CapturePhase.plan);
      case CapturePhase.plan:
        startViewpoint(config.position);
        _go(CapturePhase.align);
      case CapturePhase.align:
        _align(dt);
      case CapturePhase.settle:
        _settle(dt);
      case CapturePhase.capture:
        _capture();
      case CapturePhase.validate:
        _validate();
      case CapturePhase.accept:
        _accept();
      case CapturePhase.retry:
        _retry();
      case CapturePhase.nextTarget:
        _nextTarget();
      case CapturePhase.verify:
        _verify();
      case CapturePhase.nextViewpoint:
        _nextViewpoint();
      case CapturePhase.complete:
        break;
    }
  }

  double _gauss() => (_rand.next() + _rand.next() + _rand.next() - 1.5) * 1.4;

  /// Rotates the pose about the axis that removes the alignment error.
  ///
  /// There is no yaw-difference interpolation anywhere: convergence is a
  /// great-circle rotation toward the target, so a pole target is reached
  /// without a yaw special case and roll is never constrained.
  void _align(double dt) {
    final f = current.frame;
    final d = f.direction;

    if (live) {
      final s = sensorSource?.sensedOrientation();
      if (s == null || manual) {
        message = manual
            ? 'Manual alignment: press Capture when aimed.'
            : (sensorSource?.trackingAdvice ??
                  'Orientation unavailable. Aim by eye and use manual capture.');
        aimResult = null;
        cameraFrameDirection = null;
        if (manual && hold) {
          hold = false;
          _go(CapturePhase.settle);
          settleTime = 0;
        }
        return;
      }
      aimResult = aim(s, d);
      cameraFrameDirection = toCameraFrame(s, d);
      displayPose = s.yawPitch;
      message = wording(
        cameraFrameDirection!,
        aimResult!.angleDeg,
        thresholds.alignmentToleranceDeg,
      );
      if (aimResult!.angleDeg < thresholds.alignmentToleranceDeg) {
        settleTime = 0;
        _go(CapturePhase.settle);
      }
      return;
    }

    if (_orientationLostNow) {
      message = 'Orientation lost. Switched to manual alignment.';
      manualTimer += dt;
      wait += dt;
      if (manualTimer > 1.5) {
        manualTimer = 0;
        manualCapture = true;
        manualFrames++;
        _event('Manual capture because orientation was unavailable', 'warn');
        final yp = pose.yawPitch;
        pose = Quat.fromYawPitch(
          yp.yawDeg + (_rand.next() - 0.5) * 6,
          clampDouble(f.pitchDeg + (_rand.next() - 0.5) * 6, -90, 90),
        );
        displayPose = pose.yawPitch;
        settleTime = 0;
        _go(CapturePhase.settle);
      }
      return;
    }

    // The sensed pose carries drift, so the stored pose is aimed at the
    // inverse-drift goal: sensed = drift · stored = target.
    final targetQuat = Quat.fromYawPitch(
      f.isPole ? pose.yawPitch.yawDeg : f.yawDeg,
      f.pitchDeg,
    );
    final goal = (Quat.axisAngle(-drift, Vec3.unitY) * targetQuat).normalized;

    final turnSpeed = params.turnSpeedDegPerSec == 0
        ? 40.0
        : params.turnSpeedDegPerSec;
    final step = turnSpeed * dt;
    final goalAim = aim(pose, goal.rotate(Vec3.unitZ));

    pose = goalAim.angleDeg <= step
        ? goal
        : (Quat.axisAngle(step, goalAim.axis) * pose).normalized;

    // Drift is a rotation about the vertical axis; sensor noise is a small
    // rotation about a random axis. Neither is ever added to a yaw number.
    final noiseAngle = _gauss() * 0.15;
    final noiseAxis = Vec3(_gauss(), _gauss(), _gauss());
    var sensed = (Quat.axisAngle(drift, Vec3.unitY) * pose).normalized;
    sensed = (Quat.axisAngle(noiseAngle, noiseAxis) * sensed).normalized;

    displayPose = pose.yawPitch;
    aimResult = aim(sensed, d);
    cameraFrameDirection = toCameraFrame(sensed, d);
    message = wording(
      cameraFrameDirection!,
      aimResult!.angleDeg,
      thresholds.alignmentToleranceDeg,
    );

    if (aimResult!.angleDeg < thresholds.alignmentToleranceDeg) {
      settleTime = 0;
      _go(CapturePhase.settle);
    }
  }

  /// Gyroscope-rate gate. The rate is an axis-angle quantity; the "hold still"
  /// test uses its magnitude.
  void _settle(double dt) {
    if (live) {
      final m = sensorSource?.angularRateDegPerSec();
      motionCap = m ?? 0;
      rate = Vec3.zero;
    } else {
      final mag = _gauss().abs() * 1.2 + (_rand.next() < 0.03 ? 12.0 : 0.0);
      rate = Vec3(_gauss(), _gauss(), _gauss()).normalized * mag;
      motionCap = mag;
    }

    if (motionCap > thresholds.motion) {
      settleTime = 0;
      wait += dt;
      message = 'Hold still. The phone is moving.';
      return;
    }
    settleTime += dt;
    message = 'Hold still.';
    final window = (params.settleMs == 0 ? 400 : params.settleMs) / 1000;
    if (settleTime >= window) _go(CapturePhase.capture);
  }

  void _capture() {
    final f = current.frame;
    final c = conditions;
    message = 'Capturing';

    if (live) {
      final frame = sensorSource?.grabFrame();
      if (frame == null) {
        _event('Camera frame unavailable', 'fail');
        _go(CapturePhase.retry);
        decision = const QualityDecision(
          ok: false,
          code: QualityRejection.camera,
          message: 'Camera frame unavailable.',
        );
        return;
      }
      final s = sensorSource?.sensedOrientation();
      final yp = s?.yawPitch;
      last = LastCapture(
        rgba: frame.rgba,
        gray: toGrayscale(frame.rgba, frame.w, frame.h),
        w: frame.w,
        h: frame.h,
        poseYawDeg: yp?.yawDeg ?? f.yawDeg,
        posePitchDeg: yp?.pitchDeg ?? f.pitchDeg,
        pose: s ?? pose,
        errorDeg: aimResult?.angleDeg,
        aim: aimResult,
        hfovDeg: params.hfovDeg,
        vfovDeg: params.vfovDeg,
      );
      motionCap = sensorSource?.angularRateDegPerSec() ?? 0;
    } else {
      final forced =
          c.failIndex != null &&
          currentTargetIndex == c.failIndex &&
          attempt == 0;
      final burst =
          forced ||
          (c.blurFrames && currentTargetIndex % 5 == 2 && attempt == 0);
      final motion = burst ? 20.0 : _gauss().abs() * 1.2;
      final scale = c.fovChange && acceptedFrames.length >= c.fovAfter
          ? c.fovScale
          : 1.0;
      final hf = params.hfovDeg * scale;
      final vf = params.vfovDeg * scale;

      final rgba = renderSim(
        analysisWidth,
        analysisHeight,
        displayPose.yawDeg,
        displayPose.pitchDeg,
        hf,
        vf,
        SimScene(
          blank: c.blank,
          light: c.light,
          window: c.window,
          exposure: exposureCompensation,
          noise: c.noise,
          blur: (burst ? 3 : 0) + c.blurBase,
          mirror: c.mirror,
        ),
        _rand,
      );

      last = LastCapture(
        rgba: rgba,
        gray: toGrayscale(rgba, analysisWidth, analysisHeight),
        w: analysisWidth,
        h: analysisHeight,
        poseYawDeg: displayPose.yawDeg,
        posePitchDeg: displayPose.pitchDeg,
        pose: pose,
        errorDeg: aimResult?.angleDeg,
        aim: aimResult,
        hfovDeg: hf,
        vfovDeg: vf,
      );
      motionCap = motion;

      if (c.shift &&
          !positionShifted &&
          rounds == 0 &&
          currentTargetIndex >= (targets.length * 0.4).floor() &&
          viewpointIndex == 0) {
        positionShifted = true;
        _event('Camera position shifted during rotation (simulated)', 'warn');
      }
      last!.shifted = positionShifted;
    }

    _go(CapturePhase.validate);
  }

  void _validate() {
    final l = last!;
    final q = analyzeGray(l.gray, l.w, l.h);
    final r = decideQuality(q, thresholds, motionCap);
    stats = q;
    decision = r;
    _event(
      '${r.ok ? 'Accepted: ' : 'Rejected: '}${r.message}',
      r.ok ? (r.hasWarning ? 'warn' : 'info') : 'fail',
    );
    if (!r.ok) rejections++;
    message = r.message;
    _go(r.ok ? CapturePhase.accept : CapturePhase.retry);
  }

  void _accept() {
    final f = current.frame;
    final l = last!;
    final r = decision!;
    final c = conditions;

    final e = AcceptedFrame(
      viewpointIndex: viewpointIndex,
      index: f.index,
      targetYawDeg: l.poseYawDeg,
      targetPitchDeg: l.posePitchDeg,
      hfovDeg: l.hfovDeg,
      vfovDeg: l.vfovDeg,
      warning: r.warning,
      manual: manualCapture || manual,
      attempts: attempt + 1,
      shifted: l.shifted,
      lost: false,
      stats: stats!,
      pose: l.pose,
      direction: f.direction,
      errorDeg: l.errorDeg == null ? null : _round3(l.errorDeg!),
      axis: l.aim?.axis,
      axisDegenerate: l.aim?.degenerate,
      targetIsPole: f.isPole,
      mirror:
          c.mirror &&
          !f.isPole &&
          f.pitchDeg < 38 &&
          f.pitchDeg > -28 &&
          f.yawDeg > -135 &&
          f.yawDeg < -45,
      near:
          c.nearDistance != null &&
          !f.isPole &&
          f.yawDeg > 45 &&
          f.yawDeg < 135,
    );

    if (c.lossProbability > 0 && _rand.next() < c.lossProbability) {
      e.lost = true;
      lostFrames++;
      _event('Frame file missing after capture', 'fail');
    }
    if (r.hasWarning) warnedFrames++;

    acceptedFrames.add(e);
    current.status = TargetStatus.ok;
    manualCapture = false;
    manual = false;
    attempt = 0;
    exposureCompensation = 1;
    hold = false;
    _go(CapturePhase.nextTarget);
  }

  void _retry() {
    retries++;
    current.tries++;
    attempt++;
    final r = decision;
    if (r?.code == QualityRejection.dark) exposureCompensation *= 1.8;
    if (r?.code == QualityRejection.bright) exposureCompensation *= 0.6;

    final maxRetry = params.maxRetry == 0 ? 3 : params.maxRetry;
    if (attempt >= maxRetry) {
      current.status = TargetStatus.skipped;
      skips++;
      _event('Skipped after $attempt attempts: ${r?.message}', 'warn');
      attempt = 0;
      exposureCompensation = 1;
      _go(CapturePhase.nextTarget);
    } else {
      _go(CapturePhase.align);
    }
  }

  void _nextTarget() {
    var k = -1;
    for (var i = currentTargetIndex + 1; i < targets.length; i++) {
      if (targets[i].status == TargetStatus.pending) {
        k = i;
        break;
      }
    }
    if (k < 0) {
      _go(CapturePhase.verify);
      return;
    }
    currentTargetIndex = k;
    _go(CapturePhase.align);
  }

  void _verify() {
    final vp = viewpoint;

    final good = acceptedFrames
        .where(
          (a) => a.viewpointIndex == viewpointIndex && !a.lost && !a.shifted,
        )
        .toList();

    final frames = good
        .map(
          (a) => PlanFrame(
            yawDeg: a.targetYawDeg,
            pitchDeg: a.targetPitchDeg,
            hfovDeg: a.hfovDeg,
            vfovDeg: a.vfovDeg,
          ),
        )
        .toList();

    final st = coverageStats(frames, _samples);

    if (vp.coverageBefore == null) {
      vp.coverageBefore = st.coveragePct;
      vp.shiftedCount = acceptedFrames
          .where((a) => a.viewpointIndex == viewpointIndex && a.shifted)
          .length;
    }

    if (positionShifted && rounds == 0) positionShifted = false;

    if (st.uncoveredPct > 0.001 && rounds < 2) {
      final add = fillGaps(frames, _samples, params.hfovDeg, params.vfovDeg);
      for (final f in add) {
        f.index = targets.length;
        targets.add(CaptureTarget(f));
      }
      vp.extra += add.length;
      rounds++;
      _event(
        'Coverage gap detected. Retake ${add.length} direction(s).',
        'warn',
      );
      _go(CapturePhase.nextTarget);
      return;
    }

    vp.coverageAfter = st.coveragePct;
    vp.stats = st;
    vp.unresolved.clear();
    if (st.uncoveredPct > 0.001) {
      vp.unresolved.add(
        'Coverage gap remains: ${st.uncoveredPct.toStringAsFixed(2)}% of the sphere',
      );
    }

    if (config.roomIsMeasured) {
      vp.occlusion = occlusionShare(vp.position, config.obstacles, _samples);
      vp.visibility = wallVisibility(
        config.room,
        vp.position,
        config.obstacles,
      );
      final visible = vp.visibility!.fold<int>(0, (a, b) => a + b);
      vp.hiddenPct = (1 - visible / vp.visibility!.length) * 100;
    } else {
      // No room model. Reported as unavailable rather than as zero: "0%
      // occluded" is a measurement, and there is none to make.
      vp.occlusion = 0;
      vp.visibility = null;
      vp.hiddenPct = 0;
    }

    final forVp = acceptedFrames.where(
      (a) => a.viewpointIndex == viewpointIndex,
    );
    vp.lowInformationCount = forVp
        .where((a) => a.warning == QualityWarning.lowInformation)
        .length;
    vp.mirrorCount = forVp.where((a) => a.mirror).length;
    vp.nearCount = forVp.where((a) => a.near).length;

    if (vp.occlusion > 0.03) {
      vp.warnings.add(
        'An obstacle blocks ${(vp.occlusion * 100).toStringAsFixed(1)}% of '
        'viewing directions. ${vp.hiddenPct.toStringAsFixed(0)}% of the wall '
        'surface is hidden from this position.',
      );
    }
    if (vp.lowInformationCount > 0) {
      vp.warnings.add(
        '${vp.lowInformationCount} low-information frames. '
        'Image alignment may be difficult.',
      );
    }
    if (vp.mirrorCount > 0) {
      vp.warnings.add(
        '${vp.mirrorCount} frames show a reflective surface. '
        'Reflected objects are not room geometry.',
      );
    }

    if (conditions.nearDistance != null) {
      final maxCols = vp.plan.rows.fold<int>(1, (m, r) => math.max(m, r.count));
      final pr = estimateParallax(
        maxRowColumns: maxCols,
        nearDistanceM: conditions.nearDistance!,
        hfovDeg: params.hfovDeg,
        radiusM: conditions.radius,
      );
      vp.parallax = pr;
      if (pr.risk != 'low') {
        vp.warnings.add(
          'Parallax risk ${pr.risk} '
          '(about ${pr.pixelShift.toStringAsFixed(1)} px, heuristic). '
          'Nearby objects may not stitch.',
        );
      }
    }

    if (manualFrames > 0) {
      vp.warnings.add(
        '$manualFrames frames captured manually without '
        'orientation data.',
      );
    }

    final hidden = _hiddenFromAllViewpoints();
    final hp = hidden.isEmpty
        ? 0.0
        : hidden.where((x) => x != 0).length / hidden.length * 100;
    vp.recommendation = null;

    if (hp > 3 ||
        (vp.parallax != null && vp.parallax!.isHigh) ||
        vp.unresolved.isNotEmpty) {
      // A position is only a recommendation if it was worked out against the
      // room the user is actually standing in. With no room model the search
      // would run over the default fixture box and return a coordinate that
      // looks exactly like advice while being noise, so the limit is stated
      // instead — the gap itself stays reported, and naming the missing area is
      // something the sphere measurement *can* do without a room.
      if (!config.roomIsMeasured) {
        vp.unresolved.add(
          'No room model is available on this device, so a further capture '
          'position cannot be worked out. Add a station where the area above '
          'is missing.',
        );
      } else {
        vp.recommendation = suggestViewpoint(
          room: config.room,
          from: vp.position,
          obstacles: config.obstacles,
          clearanceM: params.clearanceM,
          hiddenPoints: hidden,
        );
        recommendation = vp.recommendation;
        if (vp.recommendation != null) {
          _event(
            'Additional viewpoint recommended at '
                '(${vp.recommendation!.x}, ${vp.recommendation!.z})',
            'warn',
          );
        }
      }
    }

    if (config.autoViewpoint &&
        vp.recommendation != null &&
        viewpointIndex < 2) {
      _go(CapturePhase.nextViewpoint);
    } else {
      _finish();
    }
  }

  /// How much of the wall surface is hidden from *every* viewpoint.
  ///
  /// Returns an empty list when there is no room model, i.e. in a live capture
  /// before AR plane data is wired in. Callers treat an empty list as "not
  /// measured", not as "nothing is hidden" — see [CaptureSummary.unresolved].
  List<int> _hiddenFromAllViewpoints() {
    final first = viewpoints.isEmpty ? null : viewpoints.first.visibility;
    if (first == null || first.isEmpty) return const <int>[];
    final n = first.length;
    return hiddenFromAll(
      viewpoints.map((v) => v.visibility ?? const <int>[]).toList(),
      n,
    );
  }

  void _nextViewpoint() {
    final r = viewpoint.recommendation ?? recommendation;
    if (r == null) {
      _finish();
      return;
    }
    startViewpoint((x: r.x, z: r.z));
    _go(CapturePhase.align);
  }

  void _finish() {
    final hidden = _hiddenFromAllViewpoints();
    final hp = hidden.isEmpty
        ? 0.0
        : hidden.where((x) => x != 0).length / hidden.length * 100;
    if (hp > 3) {
      viewpoints.last.unresolved.add(
        '${hp.toStringAsFixed(1)}% of the wall surface is not visible from any '
        'captured viewpoint.',
      );
    }
    hiddenPct = hp;

    summary = CaptureSummary(
      planned: viewpoints.fold<int>(0, (s, v) => s + v.plan.frames.length),
      accepted: acceptedFrames.where((a) => !a.lost).length,
      rejected: rejections,
      retried: retries,
      skipped: skips,
      manual: manualFrames,
      lost: lostFrames,
      coverageBefore: viewpoints.first.coverageBefore,
      coverageAfter: viewpoints.first.coverageAfter,
      extraPhotos: viewpoints.fold<int>(0, (s, v) => s + v.extra),
      extraViewpoints: viewpoints.length - 1,
      unresolved: <String>[
        for (var i = 0; i < viewpoints.length; i++)
          ...viewpoints[i].unresolved.map((u) => 'VP${i + 1}: $u'),
      ],
      warnings: <String>[
        for (var i = 0; i < viewpoints.length; i++)
          ...viewpoints[i].warnings.map((u) => 'VP${i + 1}: $u'),
      ],
      recommended: recommendation,
    );
    _go(CapturePhase.complete);
  }

  // ── user-driven actions ────────────────────────────────────────────────

  /// Retries the current target from ALIGN or SETTLE.
  void forceRetry() {
    if (phase == CapturePhase.align || phase == CapturePhase.settle) {
      attempt++;
      _event('Manual retry');
      _go(CapturePhase.align);
    }
  }

  /// Skips the current target, recording a warning. The frame is *not* marked
  /// done.
  void skip() {
    if (targets.isEmpty || phase == CapturePhase.complete) return;
    current.status = TargetStatus.skipped;
    skips++;
    _event('Skipped by user (recorded warning)', 'warn');
    attempt = 0;
    _go(CapturePhase.nextTarget);
  }

  /// Discards this viewpoint's accepted frames and starts it again.
  void restartViewpoint() {
    acceptedFrames.removeWhere((a) => a.viewpointIndex == viewpointIndex);
    for (final t in targets) {
      t.status = TargetStatus.pending;
    }
    currentTargetIndex = 0;
    rounds = 0;
    attempt = 0;
    _event('Viewpoint restarted');
    _go(CapturePhase.align);
  }

  /// Pauses the machine, e.g. for an incoming call.
  void pause() {
    if (paused) return;
    paused = true;
    _event('Paused');
  }

  /// Resumes after a pause.
  void resume() {
    if (!paused) return;
    paused = false;
    _event('Resumed');
  }

  /// Accepts the recommended extra viewpoint after a completed run.
  void acceptRecommendedViewpoint() {
    if (phase == CapturePhase.complete &&
        (viewpoint.recommendation != null || recommendation != null)) {
      summary = null;
      _go(CapturePhase.nextViewpoint);
    }
  }
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
double _round3(double v) => (v * 1000).roundToDouble() / 1000;

/// Runs a session to completion, capped at [maxTicks] iterations.
CaptureSession runCaptureSession(SessionConfig config, {int maxTicks = 40000}) {
  final s = CaptureSession(config);
  var k = 0;
  while (!s.isComplete && k++ < maxTicks) {
    s.tick(0.05);
  }
  return s;
}
