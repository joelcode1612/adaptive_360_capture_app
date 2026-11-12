import 'dart:math' as math;

import 'package:adaptive_360_capture_app/core/math/vio_sphere_math.dart' as vio;

/// The result of comparing one camera pose with the frozen capture station.
class RotationInPlaceAssessment {
  const RotationInPlaceAssessment({
    required this.rawDriftM,
    required this.effectiveDriftM,
    required this.rotatingInPlace,
    required this.withinAllowance,
    this.driftReference,
    this.rotationRadiusM,
    this.modelResidualM,
  });

  /// TRUE 3-D distance from the camera to the frozen station origin.
  ///
  /// Never filtered or compensated: this is the physical measurement the
  /// diagnostics display and log.
  final double rawDriftM;

  /// The distance the capture gate applies. Equals [rawDriftM] unless a
  /// validated camera-rotation model supplies a [driftReference].
  final double effectiveDriftM;

  /// Whether the pose follows the validated camera path around a stable pivot.
  final bool rotatingInPlace;

  /// Whether raw movement is inside the explicit compensation safety cap.
  final bool withinAllowance;

  /// Predicted camera position for the current yaw, or `null` when the strict
  /// frozen-origin gate must apply.
  final vio.Vec3? driftReference;

  /// Estimated phone-to-pivot distance, when a rotation model was established.
  final double? rotationRadiusM;

  /// Position residual against the frozen pivot model, when available.
  final double? modelResidualM;

  bool get compensationActive => rotatingInPlace && driftReference != null;
}

class _Sample {
  const _Sample({
    required this.at,
    required this.timestampNanoseconds,
    required this.position,
    required this.unwrappedYawDeg,
  });

  final DateTime at;
  final int? timestampNanoseconds;
  final vio.Vec3 position;
  final double unwrappedYawDeg;
}

class _RotationModel {
  const _RotationModel({
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
    required this.offsetX,
    required this.offsetZ,
    required this.yawOriginDeg,
    required this.rotationSign,
    required this.maxFitResidualM,
  });

  final double pivotX;
  final double pivotY;
  final double pivotZ;
  final double offsetX;
  final double offsetZ;
  final double yawOriginDeg;
  final double rotationSign;
  final double maxFitResidualM;

  double get offsetRadiusM => math.sqrt(offsetX * offsetX + offsetZ * offsetZ);

  vio.Vec3 expectedPosition(double yawDeg) {
    final radians = (yawDeg - yawOriginDeg) * rotationSign * math.pi / 180;
    final c = math.cos(radians);
    final s = math.sin(radians);
    return vio.Vec3(
      pivotX + c * offsetX + s * offsetZ,
      pivotY,
      pivotZ - s * offsetX + c * offsetZ,
    );
  }
}

/// Separates a body turn from leaving the capture station using camera pose and
/// orientation together.
///
/// The station and its 26 targets stay frozen at calibration. A phone held
/// forward while a person turns does **not** travel on a constant-radius arc
/// around the original camera position: it travels around a pivot behind the
/// phone. This monitor first fits that physical model from a short, coherent
/// yaw sweep:
///
/// ```text
/// cameraPosition(yaw) = fixedPivot + rotateY(yaw - yawAtStart) * phoneOffset
/// ```
///
/// It then freezes the fit and compares subsequent ARCore poses against the
/// predicted path. It never refits a moving pivot. Model residual, a bounded
/// phone-to-pivot offset, a raw-excursion cap, monotonic yaw evidence, fresh
/// timestamps and sample-gap checks all have to pass; otherwise the strict
/// station-origin gate is restored. This is a conservative kinematic test, not
/// a body sensor: a walk that exactly reproduces the same position/orientation
/// path is indistinguishable from turning using these inputs alone.
class RotationInPlaceMonitor {
  RotationInPlaceMonitor({
    required this.stationOrigin,
    this.maxRotationRadiusM = 0.75,
    this.maxRawExcursionM = 1.05,
    this.minPivotOffsetM = 0.12,
    this.radialToleranceM = 0.10,
    this.minYawSweepDeg = 40,
    this.window = const Duration(milliseconds: 1400),
    this.minSamples = 8,
    this.maxSampleGap = const Duration(milliseconds: 150),
    this.minimumYawDirectionConsistency = 0.78,
    this.maximumYawStepDeg = 60,
    this.maximumPositionStepM = 0.35,
  });

  /// The frozen camera position at calibration. Immutable: target geometry
  /// must never move with the estimated turn pivot.
  final vio.Vec3 stationOrigin;

  /// Maximum fitted camera-to-turn-pivot distance. This is not the raw station
  /// movement limit; [maxRawExcursionM] separately bounds how far the camera
  /// may travel from the calibrated viewpoint.
  final double maxRotationRadiusM;

  /// Maximum compensated raw camera displacement from the calibrated point.
  /// 1.05 m permits a 0.50 m forward hold through a 180° turn (about 1.0 m
  /// excursion) while remaining a finite, explicit safety boundary.
  final double maxRawExcursionM;

  /// Offsets smaller than this are too poorly conditioned to distinguish from
  /// phone-only rotation; those poses stay on the strict station gate.
  final double minPivotOffsetM;

  /// Maximum position residual from the frozen yaw/pivot trajectory.
  final double radialToleranceM;

  /// Net, one-direction yaw sweep required before a pivot can be fitted.
  final double minYawSweepDeg;

  /// Evidence window for the initial fit.
  final Duration window;

  /// Minimum number of independent ARCore pose samples in the evidence window.
  final int minSamples;

  /// Largest allowed interval between consecutive pose timestamps.
  final Duration maxSampleGap;

  /// Minimum ratio of net yaw sweep to accumulated absolute yaw movement.
  /// Back-and-forth yaw cannot be counted as a full turn.
  final double minimumYawDirectionConsistency;

  /// Reject a single-frame orientation jump as a discontinuity.
  final double maximumYawStepDeg;

  /// Reject a single-frame translation jump as a discontinuity.
  final double maximumPositionStepM;

  final List<_Sample> _samples = <_Sample>[];
  _RotationModel? _model;

  double? get rotationRadiusM => _model?.offsetRadiusM;

  /// Clears the evidence and any established physical path model.
  void reset() => invalidate();

  /// Drops compensation after tracking loss, relocalisation or a bad path sample.
  void invalidate() {
    _samples.clear();
    _model = null;
  }

  RotationInPlaceAssessment observe({
    required vio.Vec3 position,
    required double yawDeg,
    required DateTime at,
    int? timestampNanoseconds,
  }) {
    final displacement = position - stationOrigin;
    final rawDriftM = displacement.length;
    final previous = _samples.isEmpty ? null : _samples.last;
    var unwrappedYawDeg = yawDeg;
    var discontinuity = false;

    if (!_finite(position) || !yawDeg.isFinite || !rawDriftM.isFinite) {
      invalidate();
      return _strict(rawDriftM, withinAllowance: false);
    }

    if (previous != null) {
      final deltaYaw = _wrappedDelta(previous.unwrappedYawDeg, yawDeg);
      final elapsed = at.difference(previous.at);
      final timestampWentBack =
          timestampNanoseconds != null &&
          previous.timestampNanoseconds != null &&
          timestampNanoseconds <= previous.timestampNanoseconds!;
      final timestampGap =
          timestampNanoseconds != null &&
          previous.timestampNanoseconds != null &&
          timestampNanoseconds - previous.timestampNanoseconds! >
              maxSampleGap.inMicroseconds * 1000;
      final positionStep = (position - previous.position).length;
      discontinuity =
          elapsed <= Duration.zero ||
          elapsed > maxSampleGap ||
          timestampWentBack ||
          timestampGap ||
          deltaYaw.abs() > maximumYawStepDeg ||
          !positionStep.isFinite ||
          positionStep > maximumPositionStepM;
      if (discontinuity) {
        // Do not let evidence on either side of a pose discontinuity share a
        // fitted pivot. The current sample becomes only a new baseline.
        invalidate();
      } else {
        unwrappedYawDeg = previous.unwrappedYawDeg + deltaYaw;
      }
    }

    final sample = _Sample(
      at: at,
      timestampNanoseconds: timestampNanoseconds,
      position: position,
      unwrappedYawDeg: unwrappedYawDeg,
    );
    _samples.add(sample);
    while (_samples.length > 1 && at.difference(_samples.first.at) > window) {
      _samples.removeAt(0);
    }

    final rawWithinAllowance = rawDriftM <= maxRawExcursionM;
    if (!rawWithinAllowance) {
      invalidate();
      return _strict(rawDriftM, withinAllowance: false);
    }

    _model ??= _tryEstablish();
    final model = _model;
    if (model == null || discontinuity) {
      return _strict(rawDriftM, withinAllowance: rawWithinAllowance);
    }

    final expected = model.expectedPosition(unwrappedYawDeg);
    final residual = (position - expected).length;
    if (!residual.isFinite || residual > radialToleranceM) {
      // A translation that no longer follows the frozen pivot path is a walk,
      // slide, hand reposition or tracking correction; fail closed immediately.
      invalidate();
      return RotationInPlaceAssessment(
        rawDriftM: rawDriftM,
        effectiveDriftM: rawDriftM,
        rotatingInPlace: false,
        withinAllowance: rawWithinAllowance,
        modelResidualM: residual,
      );
    }

    return RotationInPlaceAssessment(
      rawDriftM: rawDriftM,
      effectiveDriftM: residual,
      rotatingInPlace: true,
      withinAllowance: true,
      driftReference: expected,
      rotationRadiusM: model.offsetRadiusM,
      modelResidualM: residual,
    );
  }

  RotationInPlaceAssessment _strict(
    double rawDriftM, {
    required bool withinAllowance,
  }) => RotationInPlaceAssessment(
    rawDriftM: rawDriftM,
    effectiveDriftM: rawDriftM,
    rotatingInPlace: false,
    withinAllowance: withinAllowance,
  );

  _RotationModel? _tryEstablish() {
    if (_samples.length < minSamples) return null;
    if (_samples.last.at.difference(_samples.first.at) <
        Duration(milliseconds: window.inMilliseconds ~/ 2)) {
      return null;
    }
    if (_samples.any(
      (_Sample sample) =>
          (sample.position - stationOrigin).length > maxRawExcursionM,
    )) {
      return null;
    }

    var signedSweep = 0.0;
    var absoluteSweep = 0.0;
    for (var i = 1; i < _samples.length; i++) {
      final delta =
          _samples[i].unwrappedYawDeg - _samples[i - 1].unwrappedYawDeg;
      signedSweep += delta;
      absoluteSweep += delta.abs();
    }
    if (signedSweep.abs() < minYawSweepDeg || absoluteSweep < 1e-6) {
      return null;
    }
    if (signedSweep.abs() / absoluteSweep < minimumYawDirectionConsistency) {
      return null;
    }

    final fits = <_RotationModel>[];
    final positiveFit = _fitForSign(1);
    final negativeFit = _fitForSign(-1);
    if (positiveFit != null) fits.add(positiveFit);
    if (negativeFit != null) fits.add(negativeFit);
    fits.sort(
      (_RotationModel a, _RotationModel b) =>
          a.maxFitResidualM.compareTo(b.maxFitResidualM),
    );
    if (fits.isEmpty) return null;
    final best = fits.first;
    if (best.maxFitResidualM > radialToleranceM) return null;
    if (best.offsetRadiusM < minPivotOffsetM ||
        best.offsetRadiusM > maxRotationRadiusM) {
      return null;
    }
    final pivotOffset = math.sqrt(
      math.pow(best.pivotX - stationOrigin.x, 2) +
          math.pow(best.pivotZ - stationOrigin.z, 2),
    );
    if (!pivotOffset.isFinite || pivotOffset > maxRotationRadiusM) {
      return null;
    }
    return best;
  }

  _RotationModel? _fitForSign(double sign) {
    final first = _samples.first;
    final normal = List<List<double>>.generate(
      4,
      (_) => List<double>.filled(4, 0),
    );
    final rhs = List<double>.filled(4, 0);
    var meanY = 0.0;

    void addEquation(List<double> row, double value) {
      for (var r = 0; r < 4; r++) {
        rhs[r] += row[r] * value;
        for (var c = 0; c < 4; c++) {
          normal[r][c] += row[r] * row[c];
        }
      }
    }

    for (final sample in _samples) {
      final radians =
          (sample.unwrappedYawDeg - first.unwrappedYawDeg) *
          sign *
          math.pi /
          180;
      final c = math.cos(radians);
      final s = math.sin(radians);
      // [pivotX, pivotZ, offsetX, offsetZ] in the station's horizontal plane.
      addEquation(<double>[1, 0, c, s], sample.position.x);
      addEquation(<double>[0, 1, -s, c], sample.position.z);
      meanY += sample.position.y;
    }

    final solution = _solveLinear(normal, rhs);
    if (solution == null) return null;
    meanY /= _samples.length;
    var maxResidual = 0.0;
    final candidate = _RotationModel(
      pivotX: solution[0],
      pivotY: meanY,
      pivotZ: solution[1],
      offsetX: solution[2],
      offsetZ: solution[3],
      yawOriginDeg: first.unwrappedYawDeg,
      rotationSign: sign,
      maxFitResidualM: 0,
    );
    for (final sample in _samples) {
      final residual =
          (sample.position - candidate.expectedPosition(sample.unwrappedYawDeg))
              .length;
      if (!residual.isFinite) return null;
      maxResidual = math.max(maxResidual, residual);
    }
    return _RotationModel(
      pivotX: solution[0],
      pivotY: meanY,
      pivotZ: solution[1],
      offsetX: solution[2],
      offsetZ: solution[3],
      yawOriginDeg: first.unwrappedYawDeg,
      rotationSign: sign,
      maxFitResidualM: maxResidual,
    );
  }

  static List<double>? _solveLinear(
    List<List<double>> matrix,
    List<double> rhs,
  ) {
    final n = rhs.length;
    final a = List<List<double>>.generate(
      n,
      (int row) => <double>[...matrix[row], rhs[row]],
    );
    for (var column = 0; column < n; column++) {
      var pivot = column;
      for (var row = column + 1; row < n; row++) {
        if (a[row][column].abs() > a[pivot][column].abs()) pivot = row;
      }
      if (a[pivot][column].abs() < 1e-9) return null;
      if (pivot != column) {
        final swap = a[column];
        a[column] = a[pivot];
        a[pivot] = swap;
      }
      final divisor = a[column][column];
      for (var j = column; j <= n; j++) {
        a[column][j] /= divisor;
      }
      for (var row = 0; row < n; row++) {
        if (row == column) continue;
        final factor = a[row][column];
        for (var j = column; j <= n; j++) {
          a[row][j] -= factor * a[column][j];
        }
      }
    }
    final result = <double>[for (var row = 0; row < n; row++) a[row][n]];
    return result.every((double value) => value.isFinite) ? result : null;
  }

  static double _wrappedDelta(double fromDeg, double toDeg) {
    var delta = toDeg - fromDeg;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }
    return delta;
  }

  static bool _finite(vio.Vec3 v) =>
      v.x.isFinite && v.y.isFinite && v.z.isFinite;
}
