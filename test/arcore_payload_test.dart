import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_payload.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

/// The payload parser's contract against non-finite numbers.
///
/// The regression these pin: a platform channel can deliver `double.nan` (a
/// sensor value that never converged, a native division by zero), the parser
/// used to accept it because `v is num` is true for NaN, and **every
/// comparison against NaN is false** — so a NaN position produced a NaN
/// `driftM`, and `NaN > 0.6` is `false`, which means the station-drift gate
/// would have waved a phone standing metres away straight through. The fix is
/// at the door: a non-finite component makes the payload "incomplete", which
/// the callers already treat as "no pose" — never a default value.
void main() {
  Map<Object?, Object?> poseMap({
    Object? px = 0.0,
    Object? py = 0.0,
    Object? pz = 0.0,
    Object? qx = 0.0,
    Object? qy = 0.0,
    Object? qz = 0.0,
    Object? qw = 1.0,
    Object? tracking = 'TRACKING',
  }) => <Object?, Object?>{
    'px': px,
    'py': py,
    'pz': pz,
    'qx': qx,
    'qy': qy,
    'qz': qz,
    'qw': qw,
    'tracking': tracking,
  };

  group('a finite payload still parses', () {
    test('the complete map becomes a pose', () {
      final pose = parsePose(poseMap(px: 1.5, py: -0.25, pz: 3));
      expect(pose, isNotNull);
      expect(pose!.position.x, 1.5);
      expect(pose.position.y, -0.25);
      expect(pose.position.z, 3);
      expect(pose.tracking, TrackingState.tracking);
    });

    test('the orientation is normalised, not taken on trust', () {
      final pose = parsePose(poseMap(qw: 2, qz: 0, qx: 0, qy: 0));
      expect(pose!.orientation.length, closeTo(1, 1e-12));
    });
  });

  group('a non-finite component is an incomplete payload', () {
    test('NaN in the position → no pose', () {
      for (final bad in <Object?>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(parsePose(poseMap(px: bad)), isNull);
        expect(parsePose(poseMap(py: bad)), isNull);
        expect(parsePose(poseMap(pz: bad)), isNull);
        expect(
          parseVec3(<Object?, Object?>{'px': bad, 'py': 0, 'pz': 0}),
          isNull,
        );
      }
    });

    test('NaN in the quaternion → no pose', () {
      expect(parsePose(poseMap(qx: double.nan)), isNull);
      expect(parsePose(poseMap(qy: double.nan)), isNull);
      expect(parsePose(poseMap(qz: double.infinity)), isNull);
      expect(parsePose(poseMap(qw: double.nan)), isNull);
    });

    test('NaN in the derived fields → no value, not a default', () {
      expect(
        parseDisplayFov(<Object?, Object?>{
          'displayHfovDeg': double.nan,
          'displayVfovDeg': 60,
        }),
        isNull,
      );
      expect(
        parseIntrinsics(<Object?, Object?>{
          'fx': double.nan,
          'fy': 500,
          'cx': 100,
          'cy': 100,
          'imageWidth': 100,
          'imageHeight': 100,
        }),
        isNull,
      );
    });

    test('a missing key and a NaN are the same answer: null', () {
      // The contract this file documents: null means "the platform did not
      // say", and the callers never invent a value from it. A NaN is a value
      // the platform cannot stand behind, so it is the same answer.
      expect(parsePose(poseMap(px: null)), isNull);
      expect(parsePose(poseMap(px: double.nan)), isNull);
    });
  });

  group('a degenerate orientation is refused, not normalised', () {
    test('an all-zero quaternion is an incomplete payload', () {
      // ARCore never reports a numerically zero rotation, so zero here can
      // only mean "the payload did not say": refused — never substituted, and
      // never normalised into an arbitrary direction.
      expect(parsePose(poseMap(qx: 0, qy: 0, qz: 0, qw: 0)), isNull);
    });

    test('a near-zero quaternion is refused below the shared cut', () {
      // 1e-10 in every slot squares to 4e-20 — under the engine's 1e-18
      // `degenerateLengthSquared` cut. A division by that length would scale
      // rounding noise into a full unit rotation, so the parser refuses here,
      // before any normalisation.
      expect(
        parsePose(poseMap(qx: 1e-10, qy: 1e-10, qz: 1e-10, qw: 1e-10)),
        isNull,
      );
    });

    test('just above the cut parses and normalises honestly', () {
      // 2e-9 in every slot squares to 1.6e-17 — above the cut, so the payload
      // stands behind itself. Four equal components fill one direction, so the
      // unit normalisation must land on 0.5 everywhere, not on the identity
      // substitute the domain math keeps for exactly-zero lengths.
      final pose = parsePose(poseMap(qx: 2e-9, qy: 2e-9, qz: 2e-9, qw: 2e-9))!;
      expect(pose.orientation.x, closeTo(0.5, 1e-12));
      expect(pose.orientation.y, closeTo(0.5, 1e-12));
      expect(pose.orientation.z, closeTo(0.5, 1e-12));
      expect(pose.orientation.w, closeTo(0.5, 1e-12));
      expect(pose.orientation.length, closeTo(1, 1e-12));
    });

    test('a quaternion that overflows when squared is refused', () {
      // 1e200 is a legal finite double; its square is `Infinity`. An unguarded
      // length-squared threshold answers `Infinity > cut` with true — so a
      // bare threshold would pass a rotation no double can represent. The
      // parser checks the sum finitely so the overflow the payload already
      // carries is refused at the door.
      expect(
        parsePose(poseMap(qx: 1e200, qy: 1e200, qz: 1e200, qw: 1e200)),
        isNull,
      );
    });

    test('the component order survives the normalisation', () {
      // (1, 2, 3, 4) is a legitimate rotation up to length, and the parse must
      // keep which value belongs to which slot while dividing by √30 — the
      // platform channel is `(x, y, z, w)` and the parser may not reshuffle it.
      final pose = parsePose(poseMap(qx: 1, qy: 2, qz: 3, qw: 4))!;
      final s = math.sqrt(30);
      expect(pose.orientation.x, closeTo(1 / s, 1e-9));
      expect(pose.orientation.y, closeTo(2 / s, 1e-9));
      expect(pose.orientation.z, closeTo(3 / s, 1e-9));
      expect(pose.orientation.w, closeTo(4 / s, 1e-9));
    });
  });

  group('why the gate depends on this', () {
    test('every comparison against NaN is false', () {
      // The language semantics behind the defect: a NaN drift would sail
      // through `driftM > limit` and through `driftM > 0` alike. The parser
      // guard is what keeps a NaN from ever reaching the gate.
      const limit = 0.6;
      expect(double.nan > limit, isFalse);
      expect(double.nan > 0, isFalse);
      expect(double.nan.isFinite, isFalse);
      expect(1.5 > limit, isTrue);
    });

    test('a NaN-free pose cannot produce a NaN drift', () {
      final pose = parsePose(poseMap(px: 5.0));
      final drift = (pose!.position - const Vec3(0, 0, 0)).length;
      expect(drift.isFinite, isTrue);
      expect(drift, greaterThan(0.6));
    });
  });
}
