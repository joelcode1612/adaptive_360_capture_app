import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/adaptive_quaternion_smoother.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/motion_sample.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/orientation_filter.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The filter's contract, tested on synthetic sequences.
///
/// Nothing here needs a phone: every case is a list of (orientation, timestamp)
/// pairs, which is the whole reason [MotionSample] carries its own clock.
MotionSample sample(Quat q, int ms) => MotionSample(
  orientation: q,
  at: Duration(milliseconds: ms),
);

void main() {
  group('AdaptiveQuaternionSmoother', () {
    test('the first sample passes through untouched', () {
      final f = AdaptiveQuaternionSmoother();
      final q = Quat.fromYawPitch(30, 10);
      expect(
        f.filter(sample(q, 0)).maxComponentDiff(q.normalized),
        lessThan(1e-12),
      );
      expect(f.snapCount, 1);
      expect(f.smoothingFraction, 0);
    });

    test('a small rotation is smoothed, not adopted immediately', () {
      final f = AdaptiveQuaternionSmoother(tauSeconds: 0.12);
      final a = Quat.identity;
      final b = Quat.fromYawPitch(6, 0);

      f.filter(sample(a, 0));
      final out = f.filter(sample(b, 33)); // 33 ms later, 6° step

      final toA = angleBetweenDeg(out, a);
      final toB = angleBetweenDeg(out, b);
      // Between the two, and much closer to where it came from.
      expect(toA, greaterThan(0.05));
      expect(toB, greaterThan(0.05));
      expect(toA + toB, closeTo(6, 1e-6));
      expect(toA, lessThan(toB));
      expect(f.smoothingFraction, closeTo(0.5, 1e-9)); // 1 of 2 snapped
    });

    test('the coefficient is frame-rate independent', () {
      // Two runs covering the same elapsed time in different numbers of steps
      // must end at the same orientation. A fixed per-sample alpha would not.
      Quat run(int steps) {
        final f = AdaptiveQuaternionSmoother(tauSeconds: 0.12);
        f.filter(sample(Quat.identity, 0));
        for (var i = 1; i <= steps; i++) {
          f.filter(sample(Quat.fromYawPitch(10, 0), (300 * i) ~/ steps));
        }
        return f.state!;
      }

      final coarse = run(2);
      final fine = run(20);
      expect(angleBetweenDeg(coarse, fine), lessThan(0.2));
    });

    test('a large rotation snaps instead of lagging', () {
      final f = AdaptiveQuaternionSmoother(snapAngleDeg: 25);
      f.filter(sample(Quat.identity, 0));
      final turned = Quat.fromYawPitch(90, 0);
      final out = f.filter(sample(turned, 33));
      expect(angleBetweenDeg(out, turned), lessThan(1e-9));
      expect(f.snapCount, 2);
    });

    test('crossing ±180° does not sweep the long way round', () {
      final f = AdaptiveQuaternionSmoother(tauSeconds: 0.12, snapAngleDeg: 25);
      final a = Quat.fromYawPitch(179, 0);
      final b = Quat.fromYawPitch(-179, 0); // 2° away, not 358°
      f.filter(sample(a, 0));
      final out = f.filter(sample(b, 33));

      // If the filter had taken the long arc the output would be near the
      // opposite heading; it must instead be within 2° of the pair.
      expect(angleBetweenDeg(out, a), lessThan(2.0001));
      expect(angleBetweenDeg(out, b), lessThan(2.0001));
    });

    test('q and −q are the same rotation to the filter', () {
      final target = Quat.fromYawPitch(40, 5);
      final negated = Quat(-target.x, -target.y, -target.z, -target.w);

      Quat runWith(Quat t) {
        final f = AdaptiveQuaternionSmoother();
        f.filter(sample(Quat.identity, 0));
        return f.filter(sample(t, 33));
      }

      expect(
        angleBetweenDeg(runWith(target), runWith(negated)),
        lessThan(1e-9),
      );
    });

    test('the output is always normalised', () {
      final f = AdaptiveQuaternionSmoother();
      f.filter(sample(Quat(0, 0, 0, 4), 0)); // deliberately unnormalised
      final out = f.filter(sample(Quat(0, 0.5, 0, 0.5), 33));
      expect(out.length, closeTo(1, 1e-12));
    });

    test('invalid input is rejected and the state is held', () {
      final f = AdaptiveQuaternionSmoother();
      final good = Quat.fromYawPitch(12, 0);
      f.filter(sample(good, 0));

      final nan = Quat(double.nan, 0, 0, 1);
      final out = f.filter(sample(nan, 33));
      expect(out.maxComponentDiff(good.normalized), lessThan(1e-12));
      expect(out.length, closeTo(1, 1e-12));

      // A zero quaternion has no orientation at all.
      final zero = f.filter(sample(const Quat(0, 0, 0, 0), 66));
      expect(zero.maxComponentDiff(good.normalized), lessThan(1e-12));
    });

    test('a non-positive interval snaps rather than dividing by zero', () {
      final f = AdaptiveQuaternionSmoother();
      f.filter(sample(Quat.identity, 100));
      final out = f.filter(sample(Quat.fromYawPitch(5, 0), 100)); // same ms
      expect(angleBetweenDeg(out, Quat.fromYawPitch(5, 0)), lessThan(1e-9));
      expect(out.length, closeTo(1, 1e-12));
    });

    test('a gap longer than maxGap snaps', () {
      final f = AdaptiveQuaternionSmoother(maxGapSeconds: 0.5);
      f.filter(sample(Quat.identity, 0));
      final target = Quat.fromYawPitch(8, 0);
      final out = f.filter(sample(target, 900)); // 900 ms > 500 ms
      expect(angleBetweenDeg(out, target), lessThan(1e-9));
    });

    test('reset forgets the estimate', () {
      final f = AdaptiveQuaternionSmoother();
      f.filter(sample(Quat.fromYawPitch(70, 0), 0));
      f.filter(sample(Quat.fromYawPitch(70, 0), 33));
      expect(f.state, isNotNull);

      f.reset();
      expect(f.state, isNull);
      expect(f.sampleCount, 0);

      final fresh = f.filter(sample(Quat.identity, 1000));
      expect(fresh.maxComponentDiff(Quat.identity), lessThan(1e-12));
    });

    test('smoothing reduces jitter on a still phone', () {
      // ±0.4° of frame-to-frame noise, the order ARCore produces at 30 Hz.
      final jitter = <Quat>[
        for (var i = 0; i < 40; i++)
          Quat.fromYawPitch(i.isEven ? 0.4 : -0.4, i % 3 == 0 ? 0.3 : -0.3),
      ];

      final smoother = AdaptiveQuaternionSmoother(tauSeconds: 0.12);
      final raw = <double>[];
      final filtered = <double>[];

      // Jitter is variation of the *direction*, so the measured quantity is a
      // component of the forward vector — not the angle from identity, which is
      // almost constant here and would hide the very thing under test.
      for (var i = 0; i < jitter.length; i++) {
        final out = smoother.filter(sample(jitter[i], i * 33));
        raw.add(jitter[i].rotate(Vec3.unitZ).x);
        filtered.add(out.rotate(Vec3.unitZ).x);
      }

      double sd(List<double> v) {
        final m = v.reduce((a, b) => a + b) / v.length;
        final varr =
            v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length;
        return math.sqrt(varr);
      }

      // Skip the first sample, which snaps by definition.
      final rawSd = sd(raw.sublist(1));
      final filtSd = sd(filtered.sublist(1));
      expect(rawSd, greaterThan(0.001), reason: 'the input really is jittery');
      expect(filtSd, lessThan(rawSd * 0.8));
    });
  });

  group('PassthroughOrientationFilter', () {
    test('reports the input unchanged, which is what a baseline needs', () {
      final f = PassthroughOrientationFilter();
      final q = Quat.fromYawPitch(33, -7);
      expect(
        f.filter(sample(q, 0)).maxComponentDiff(q.normalized),
        lessThan(1e-12),
      );
      expect(
        f.filter(sample(q, 33)).maxComponentDiff(q.normalized),
        lessThan(1e-12),
      );
    });

    test('holds the last value through invalid input', () {
      final f = PassthroughOrientationFilter();
      final q = Quat.fromYawPitch(10, 0);
      f.filter(sample(q, 0));
      expect(
        f
            .filter(sample(Quat(double.infinity, 0, 0, 1), 33))
            .maxComponentDiff(q.normalized),
        lessThan(1e-12),
      );
    });
  });

  group('angleBetweenDeg', () {
    test('is zero for identical orientations and for q vs −q', () {
      final q = Quat.fromYawPitch(25, 15);
      expect(angleBetweenDeg(q, q), closeTo(0, 1e-9));
      expect(
        angleBetweenDeg(q, Quat(-q.x, -q.y, -q.z, -q.w)),
        closeTo(0, 1e-9),
      );
    });

    test('matches the known angle for a pure yaw', () {
      expect(
        angleBetweenDeg(Quat.identity, Quat.fromYawPitch(37, 0)),
        closeTo(37, 1e-9),
      );
      expect(
        angleBetweenDeg(Quat.identity, Quat.fromYawPitch(0, 62)),
        closeTo(62, 1e-9),
      );
    });

    test('is symmetric', () {
      final a = Quat.fromYawPitch(10, 20);
      final b = Quat.fromYawPitch(-70, 5);
      expect(angleBetweenDeg(a, b), closeTo(angleBetweenDeg(b, a), 1e-9));
    });

    test('is stable at very small angles', () {
      // 2·acos(w) would return 0 for anything under ~1e-4° here.
      final a = Quat.identity;
      final b = Quat.fromYawPitch(0.001, 0);
      expect(angleBetweenDeg(a, b), closeTo(0.001, 1e-9));
    });
  });

  group('angularRateFromQuaternions', () {
    test('is the angle divided by the interval', () {
      final rate = angularRateFromQuaternions(
        from: Quat.identity,
        to: Quat.fromYawPitch(5, 0),
        dtSeconds: 0.05,
      );
      expect(rate, closeTo(100, 1e-6));
    });

    test('is null for a non-positive interval', () {
      expect(
        angularRateFromQuaternions(
          from: Quat.identity,
          to: Quat.fromYawPitch(5, 0),
          dtSeconds: 0,
        ),
        isNull,
      );
      expect(
        angularRateFromQuaternions(
          from: Quat.identity,
          to: Quat.fromYawPitch(5, 0),
          dtSeconds: -1,
        ),
        isNull,
      );
    });

    test('uses the shortest arc across ±180°', () {
      final rate = angularRateFromQuaternions(
        from: Quat.fromYawPitch(179, 0),
        to: Quat.fromYawPitch(-179, 0),
        dtSeconds: 0.1,
      );
      expect(rate, closeTo(20, 1e-6)); // 2° in 0.1 s, not 3580
    });
  });
}
