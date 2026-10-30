// Reproducible comparison of the orientation pipelines.
//
// Runs one synthetic sequence through the baseline (no smoothing, no rate gate)
// and through candidate A (adaptive smoothing + the full stability gate), and
// writes the metrics to docs/measurements/.
//
// **What this can and cannot show.** The sequence is generated, so the ground
// truth is exact and every angular error below is a real measurement of the
// filter against that truth — not an estimate. But it is a *synthetic* truth: it
// says nothing about how ARCore behaves on a real phone. Treat these numbers as
// "the filter does what it claims on a known input", not as device accuracy.
//
// Run with:
//   dart run tool/motion_comparison.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/capture/domain/motion/adaptive_quaternion_smoother.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/orientation_filter.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/stability_monitor.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

const double _dtSeconds = 1 / 30;
const Duration _dt = Duration(microseconds: 33333);

/// The scripted motion, in degrees of yaw, as a function of time.
///
/// 0–1.5 s still · 1.5–2.1 s turn to 90° at 150 °/s · 2.1–3.6 s still ·
/// 3.6–4.2 s turn back · 4.2–6 s still.
double truthYawDeg(double t) {
  if (t < 1.5) return 0;
  if (t < 2.1) return 90 * (t - 1.5) / 0.6;
  if (t < 3.6) return 90;
  if (t < 4.2) return 90 * (1 - (t - 3.6) / 0.6);
  return 0;
}

/// True angular rate of the script above, in degrees/second.
double truthRateDegPerSec(double t) {
  if (t >= 1.5 && t < 2.1) return 150;
  if (t >= 3.6 && t < 4.2) return -150;
  return 0;
}

bool isStationary(double t) => t < 1.5 || (t >= 2.1 && t < 3.6) || t >= 4.2;

/// True once the jitter measurement is meaningful: a short guard after each turn
/// so the filter's own settle transient is not counted as jitter.
bool isSteadyForMetrics(double t) =>
    (t >= 0.3 && t < 1.5) || (t >= 2.6 && t < 3.6) || (t >= 4.7 && t < 6.0);

void main() {
  final rng = Mulberry32(0xA5F00D);
  final steps = (6.0 / _dtSeconds).floor();

  // ── scenario A: jitter, settle and error against the scripted truth ────
  final rawSamples = <Quat>[];
  final times = <double>[];
  for (var i = 0; i < steps; i++) {
    final t = i * _dtSeconds;
    final jitterYaw = (rng.next() - 0.5) * 0.7; // ±0.35°
    final jitterPitch = (rng.next() - 0.5) * 0.5; // ±0.25°
    times.add(t);
    rawSamples.add(
      (Quat.fromYawPitch(truthYawDeg(t) + jitterYaw, jitterPitch)).normalized,
    );
  }

  final passthrough = PassthroughOrientationFilter();
  final smoother = AdaptiveQuaternionSmoother(tauSeconds: 0.12);

  final rawOut = <Quat>[];
  final smoothOut = <Quat>[];
  for (var i = 0; i < steps; i++) {
    final sample = MotionSample(
      orientation: rawSamples[i],
      at: Duration(microseconds: (times[i] * 1e6).round()),
    );
    rawOut.add(passthrough.filter(sample));
    smoothOut.add(smoother.filter(sample));
  }

  double meanAbsError(List<Quat> qs) {
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i < steps; i++) {
      if (!isSteadyForMetrics(times[i])) continue;
      final truth = Quat.fromYawPitch(truthYawDeg(times[i]), 0);
      sum += angleBetweenDeg(qs[i], truth);
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  double maxAbsError(List<Quat> qs) {
    var worst = 0.0;
    for (var i = 0; i < steps; i++) {
      if (!isSteadyForMetrics(times[i])) continue;
      final truth = Quat.fromYawPitch(truthYawDeg(times[i]), 0);
      worst = math.max(worst, angleBetweenDeg(qs[i], truth));
    }
    return worst;
  }

  /// Standard deviation of the forward direction **within each stationary
  /// window**, averaged.
  ///
  /// Pooling the windows would measure the difference between the two headings
  /// (0° and 90°) rather than the jitter inside either of them, which is what
  /// made the first version of this harness report a meaningless σ of 0.45.
  double forwardSd(List<Quat> qs) {
    final windows = <List<double>>[[], [], []];
    for (var i = 0; i < steps; i++) {
      final t = times[i];
      final x = qs[i].rotate(Vec3.unitZ).x;
      if (t >= 0.3 && t < 1.5) windows[0].add(x);
      if (t >= 2.6 && t < 3.6) windows[1].add(x);
      if (t >= 4.7 && t < 6.0) windows[2].add(x);
    }
    var total = 0.0;
    var counted = 0;
    for (final xs in windows) {
      if (xs.length < 2) continue;
      final m = xs.reduce((a, b) => a + b) / xs.length;
      final varr =
          xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / xs.length;
      total += math.sqrt(varr);
      counted++;
    }
    return counted == 0 ? 0 : total / counted;
  }

  /// Time from the end of the first turn until the orientation is within
  /// [toleranceDeg] of the truth, in milliseconds. `null` if never.
  int? settleMs(List<Quat> qs, {double toleranceDeg = 1}) {
    for (var i = 0; i < steps; i++) {
      if (times[i] < 2.1) continue;
      final truth = Quat.fromYawPitch(truthYawDeg(times[i]), 0);
      if (angleBetweenDeg(qs[i], truth) <= toleranceDeg) {
        return ((times[i] - 2.1) * 1000).round();
      }
    }
    return null;
  }

  // ── the gate, driven by scenario A ────────────────────────────────────
  const station = StationFrame(origin: Vec3.zero, orientation: Quat.identity);
  const calc = AlignmentCalculator();
  const targetWorld = Vec3(0, 0, 3);

  ({int firstStableMs, int stableSamples, int samples}) runGate(
    StabilityMonitor monitor,
    List<Quat> source,
  ) {
    var firstStable = -1;
    var stableCount = 0;
    var counted = 0;
    final t0 = DateTime.utc(2026, 1, 1);
    for (var i = 0; i < steps; i++) {
      final now = t0.add(Duration(microseconds: (times[i] * 1e6).round()));
      final pose = RigidPose(position: Vec3.zero, orientation: source[i]);
      final alignment = calc.compute(
        camera: pose,
        targetPosition: targetWorld,
        toleranceDeg: 3,
      );
      final stable = monitor.update(
        now: now,
        pose: pose,
        alignment: alignment,
        measurementAge: _dt,
      );
      // Measured only after the camera has come back to the target at t = 4.2.
      // Between 2.1 s and 4.2 s it is 90° away, so the alignment gate blocks it
      // for the right reason and counting that would measure the script.
      if (times[i] >= 4.2) {
        counted++;
        if (stable) stableCount++;
        if (stable && firstStable < 0) {
          firstStable = ((times[i] - 4.2) * 1000).round();
        }
      }
    }
    return (
      firstStableMs: firstStable,
      stableSamples: stableCount,
      samples: counted,
    );
  }

  final gateRaw = runGate(
    StabilityMonitor(window: const Duration(milliseconds: 450)),
    rawOut,
  );
  final gateSmooth = runGate(
    StabilityMonitor(window: const Duration(milliseconds: 450)),
    smoothOut,
  );

  // ── scenario B: aimed but rotating — the rate gate's reason to exist ───
  //
  // The camera is placed on a circle around the target, always looking at it, so
  // the alignment error stays ~0 and only the rate gate can refuse. This is the
  // "phone being carried while aimed" case.
  ({int baselineFalseReady, int candidateFalseReady, int movingSamples})
  runCarried() {
    final t0 = DateTime.utc(2026, 1, 1);
    final noRateGate = StabilityMonitor(
      window: const Duration(milliseconds: 450),
      maxAngularVelocityDegPerSec: 1e9, // the pre-change behaviour
    );
    final withRateGate = StabilityMonitor(
      window: const Duration(milliseconds: 450),
      maxAngularVelocityDegPerSec: 5,
    );
    var baseFalse = 0;
    var candFalse = 0;
    var moving = 0;
    var yaw = 0.0;

    for (var i = 0; i < steps; i++) {
      final t = i * _dtSeconds;
      // 20 °/s for 2 s, starting at 0.5 s — faster than the 5 °/s budget.
      if (t >= 0.5 && t < 2.5) yaw += 20 * _dtSeconds;
      final now = t0.add(Duration(microseconds: (t * 1e6).round()));
      final q = Quat.fromYawPitch(yaw, 0);
      final pose = RigidPose(position: Vec3.zero, orientation: q);
      final alignment = calc.compute(
        camera: pose,
        // Target on the camera's own forward: alignment is ~0 throughout.
        targetPosition: q.rotate(Vec3.unitZ) * 3,
        toleranceDeg: 3,
      );
      // This scenario's own motion, not the other script's. Using
      // `truthRateDegPerSec` here counted the *scripted* turns — during which
      // this camera is stationary — as movement, which is what produced the
      // bogus "18 false readies" in the first run.
      final movingNow = t >= 0.5 && t < 2.5;
      if (movingNow) moving++;
      if (noRateGate.update(
            now: now,
            pose: pose,
            alignment: alignment,
            measurementAge: _dt,
          ) &&
          movingNow) {
        baseFalse++;
      }
      if (withRateGate.update(
            now: now,
            pose: pose,
            alignment: alignment,
            measurementAge: _dt,
          ) &&
          movingNow) {
        candFalse++;
      }
    }
    return (
      baselineFalseReady: baseFalse,
      candidateFalseReady: candFalse,
      movingSamples: moving,
    );
  }

  final carried = runCarried();

  // ── scenario C: the same gate on realistic pose jitter ─────────────────
  //
  // ±0.35° was chosen for scenario A to make the smoother's effect visible. It is
  // also 7–17× larger than ARCore's frame-to-frame noise once tracking settles,
  // and the rate gate is sensitive to exactly that. This run repeats the gate on
  // ±0.05° so the sensitivity is quantified rather than hidden.
  ({double stillStableFraction, int? firstStableMs, double meanRateDps})
  runRealisticJitter() {
    final r2 = Mulberry32(0x5EED);
    final t0 = DateTime.utc(2026, 1, 1);
    final monitor = StabilityMonitor(window: const Duration(milliseconds: 450));
    var stableCount = 0;
    var counted = 0;
    var firstStable = -1;
    var rateSum = 0.0;
    var rateN = 0;

    for (var i = 0; i < steps; i++) {
      final t = i * _dtSeconds;
      final q = (Quat.fromYawPitch(
        truthYawDeg(t) + (r2.next() - 0.5) * 0.1,
        (r2.next() - 0.5) * 0.1,
      )).normalized;
      final now = t0.add(Duration(microseconds: (t * 1e6).round()));
      final pose = RigidPose(position: Vec3.zero, orientation: q);
      final alignment = calc.compute(
        camera: pose,
        targetPosition: targetWorld,
        toleranceDeg: 3,
      );
      final stable = monitor.update(
        now: now,
        pose: pose,
        alignment: alignment,
        measurementAge: _dt,
      );
      final r = monitor.lastAngularVelocityDegPerSec;
      if (r != null) {
        rateSum += r;
        rateN++;
      }
      if (t >= 4.2) {
        counted++;
        if (stable) stableCount++;
        if (stable && firstStable < 0) {
          firstStable = ((t - 4.2) * 1000).round();
        }
      }
    }
    return (
      stillStableFraction: counted == 0 ? 0 : stableCount / counted,
      firstStableMs: firstStable < 0 ? null : firstStable,
      meanRateDps: rateN == 0 ? 0 : rateSum / rateN,
    );
  }

  final realistic = runRealisticJitter();

  // ── report ────────────────────────────────────────────────────────────
  final metrics = <String, Object?>{
    'schema': 'adaptive360.motion-comparison/1',
    'note':
        'Synthetic scripted input at 30 Hz with ±0.35° yaw / ±0.25° pitch jitter. '
        'Ground truth is the script, so angular errors are exact measurements '
        'against that truth — but they say nothing about ARCore accuracy on a '
        'device.',
    'sequence': <String, Object?>{
      'rate_hz': 30,
      'duration_s': 6.0,
      'samples': steps,
      'script':
          'still 1.5s · turn 90° at 150°/s · still 1.5s · turn back · still',
    },
    'scenario_a_jitter_and_error': <String, Object?>{
      'static_jitter_sd_forward_x': <String, Object?>{
        'baseline': forwardSd(rawOut),
        'candidate_a': forwardSd(smoothOut),
      },
      'mean_abs_error_deg': <String, Object?>{
        'baseline': meanAbsError(rawOut),
        'candidate_a': meanAbsError(smoothOut),
      },
      'max_abs_error_deg': <String, Object?>{
        'baseline': maxAbsError(rawOut),
        'candidate_a': maxAbsError(smoothOut),
      },
      'settle_to_1deg_after_turn_ms': <String, Object?>{
        'baseline': settleMs(rawOut),
        'candidate_a': settleMs(smoothOut),
      },
    },
    'scenario_a_gate': <String, Object?>{
      'first_stable_after_turn_ms': <String, Object?>{
        'on_raw': gateRaw.firstStableMs,
        'on_smoothed': gateSmooth.firstStableMs,
      },
      'stable_sample_fraction_after_turn': <String, Object?>{
        'on_raw': gateRaw.samples == 0
            ? null
            : gateRaw.stableSamples / gateRaw.samples,
        'on_smoothed': gateSmooth.samples == 0
            ? null
            : gateSmooth.stableSamples / gateSmooth.samples,
      },
    },
    'scenario_c_realistic_jitter': <String, Object?>{
      'note':
          'Same gate, ±0.05° jitter — the order ARCore produces once tracking '
          'settles. Measured while still, after the camera returned to the target.',
      'mean_derived_rate_dps': realistic.meanRateDps,
      'still_stable_fraction': realistic.stillStableFraction,
      'first_stable_after_return_ms': realistic.firstStableMs,
    },
    'scenario_b_carried_while_aimed': <String, Object?>{
      'rate_dps': 20,
      'moving_samples': carried.movingSamples,
      'false_ready_samples_baseline_no_rate_gate': carried.baselineFalseReady,
      'false_ready_samples_candidate_a': carried.candidateFalseReady,
    },
  };

  final outDir = Directory('docs/measurements');
  outDir.createSync(recursive: true);
  File(
    '${outDir.path}/motion_comparison.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(metrics));

  final csv = StringBuffer()
    ..writeln('t_s,truth_yaw,raw_error_deg,filtered_error_deg,truth_rate_dps');
  for (var i = 0; i < steps; i++) {
    final truth = Quat.fromYawPitch(truthYawDeg(times[i]), 0);
    csv
      ..write(times[i].toStringAsFixed(3))
      ..write(',')
      ..write(truthYawDeg(times[i]).toStringAsFixed(2))
      ..write(',')
      ..write(angleBetweenDeg(rawOut[i], truth).toStringAsFixed(3))
      ..write(',')
      ..write(angleBetweenDeg(smoothOut[i], truth).toStringAsFixed(3))
      ..write(',')
      ..writeln(truthRateDegPerSec(times[i]).toStringAsFixed(0));
  }
  File('${outDir.path}/motion_trace.csv').writeAsStringSync(csv.toString());

  stdout
    ..writeln('samples: $steps')
    ..writeln('--- scenario A: jitter and error vs scripted truth ---')
    ..writeln(
      'static jitter (sd of forward.x): '
      'baseline ${forwardSd(rawOut).toStringAsFixed(6)}  '
      'candidate ${forwardSd(smoothOut).toStringAsFixed(6)}',
    )
    ..writeln(
      'mean |error|: baseline ${meanAbsError(rawOut).toStringAsFixed(3)}°  '
      'candidate ${meanAbsError(smoothOut).toStringAsFixed(3)}°',
    )
    ..writeln(
      'max |error|:  baseline ${maxAbsError(rawOut).toStringAsFixed(3)}°  '
      'candidate ${maxAbsError(smoothOut).toStringAsFixed(3)}°',
    )
    ..writeln(
      'settle to 1°:  baseline ${settleMs(rawOut)} ms  '
      'candidate ${settleMs(smoothOut)} ms',
    )
    ..writeln('--- scenario A: the gate ---')
    ..writeln(
      'first stable after turn: raw ${gateRaw.firstStableMs} ms  '
      'smoothed ${gateSmooth.firstStableMs} ms',
    )
    ..writeln('--- scenario C: realistic ±0.05° jitter, gate while still ---')
    ..writeln(
      'mean derived rate ${realistic.meanRateDps.toStringAsFixed(2)} °/s · '
      'still-stable fraction ${realistic.stillStableFraction.toStringAsFixed(2)} · '
      'first stable ${realistic.firstStableMs} ms',
    )
    ..writeln('--- scenario B: carried while aimed (20 °/s) ---')
    ..writeln(
      'false-ready samples: baseline ${carried.baselineFalseReady}  '
      'candidate ${carried.candidateFalseReady}  '
      'of ${carried.movingSamples} moving',
    )
    ..writeln('written to ${outDir.path}/motion_comparison.json');
}
