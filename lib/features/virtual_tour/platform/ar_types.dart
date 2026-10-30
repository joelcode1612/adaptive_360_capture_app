import 'dart:math' as math;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';

/// Platform-neutral AR types.
///
/// **Pure Dart.** Nothing here imports Flutter or a plugin, so the AR decision
/// logic can be unit-tested without a device and without a binding. The
/// platform bridge lives in `arcore_ar.dart`, which implements the interfaces
/// declared on top of these types.
///
/// ## Conventions, stated once
///
/// ARCore reports the camera pose as a rigid transform from the *camera's local
/// frame* to the AR world. The camera's local frame is the OpenGL/ARCore
/// convention:
///
/// ```
/// +X right, +Y up, +Z backward (the optical axis is -Z)
/// ```
///
/// This project's world convention is documented in `quaternions.dart`: the
/// optical axis is `+ẑ`, `+Y` is up, and yaw increases anticlockwise seen from
/// above. [ArPose.captureWorld] performs the conversion, and it is the *only*
/// place that conversion happens, because getting it wrong in one call site and
/// right in another is invisible until the marker points the wrong way.

/// What the AR system currently thinks about its own pose.
enum TrackingState {
  /// AR is present but no pose has arrived yet.
  initialising,

  /// A valid pose is being reported.
  tracking,

  /// AR lost confidence but has not given up. The pose may be stale.
  paused,

  /// AR stopped. The session has to be torn down and restarted.
  stopped,

  /// There is no AR system on this device.
  unavailable;

  /// Whether a pose from this state may be used to guide the user.
  bool get usable => this == TrackingState.tracking;

  /// What to tell the user, or `null` when there is nothing to say.
  String? get advice => switch (this) {
    TrackingState.initialising =>
      'Move the phone slowly so AR can find the room.',
    TrackingState.tracking => null,
    TrackingState.paused =>
      'AR cannot follow the room right now. Move to a brighter area with more '
          'visible detail.',
    TrackingState.stopped =>
      'AR tracking stopped. Point at the start direction and try again.',
    TrackingState.unavailable => 'This device cannot run AR tracking.',
  };
}

/// Camera intrinsics, as reported by the platform.
///
/// The brief forbids reading the field of view from a constant. This is where
/// the real numbers arrive. Note the two coordinate systems:
///
/// * [imageWidth]/[imageHeight] are the **sensor** image dimensions, which on a
///   phone are landscape.
/// * The app is portrait-locked, so the sensor's long side lands on screen-y.
///   [portraitDisplayFov] performs that swap; [sensorFov] does not.
class ArCameraIntrinsics {
  /// Focal length in pixels along the sensor's x axis.
  final double focalLengthXPx;

  /// Focal length in pixels along the sensor's y axis.
  final double focalLengthYPx;

  final double principalPointXPx;
  final double principalPointYPx;

  /// Sensor image size in pixels.
  final int imageWidth;
  final int imageHeight;

  /// Clockwise rotation, in degrees, that maps the sensor image to the display.
  /// One of 0, 90, 180, 270.
  final int rotationDeg;

  const ArCameraIntrinsics({
    required this.focalLengthXPx,
    required this.focalLengthYPx,
    required this.principalPointXPx,
    required this.principalPointYPx,
    required this.imageWidth,
    required this.imageHeight,
    this.rotationDeg = 90,
  });

  /// A 4:3 sensor with a 68° long side and square pixels, centred.
  ///
  /// **Provisional, and only a fallback.** Used when the platform refuses to
  /// report intrinsics, so that the flow can still run; every screen that shows
  /// a field of view also shows which source it came from.
  static const ArCameraIntrinsics fallback4x3 = ArCameraIntrinsics(
    focalLengthXPx: 0,
    focalLengthYPx: 0,
    principalPointXPx: 0,
    principalPointYPx: 0,
    imageWidth: 0,
    imageHeight: 0,
  );

  bool get isUsable =>
      imageWidth > 0 &&
      imageHeight > 0 &&
      focalLengthXPx > 0 &&
      focalLengthYPx > 0;

  /// Whether the pixels are square to within 2%.
  ///
  /// The plan generator's FOV model assumes square pixels (it derives one focal
  /// length per axis from the two fields of view and expects
  /// `(W/2)/tan(hfov/2) == (H/2)/tan(vfov/2)`). A sensor that reports
  /// noticeably different focal lengths would silently skew the coverage
  /// estimate, so it is reported rather than assumed.
  bool get squarePixels {
    if (!isUsable) return false;
    final ratio = focalLengthXPx / focalLengthYPx;
    return (ratio - 1).abs() <= 0.02;
  }

  /// Field of view in the **sensor's** frame, in degrees.
  ({double hfovDeg, double vfovDeg}) sensorFov() {
    if (!isUsable) return (hfovDeg: 68, vfovDeg: 53.669);
    return (
      hfovDeg: 2 * math.atan((imageWidth / 2) / focalLengthXPx) * radToDeg,
      vfovDeg: 2 * math.atan((imageHeight / 2) / focalLengthYPx) * radToDeg,
    );
  }

  /// Field of view in the **portrait display's** frame, in degrees.
  ///
  /// `hfovDeg` is the screen-x field and `vfovDeg` is the screen-y field. For a
  /// 90°/270° rotation the two swap, which is the case that matters: a phone
  /// sensor is landscape and the app is portrait.
  ///
  /// Prefer [displayFovForImageAxis] when the host has measured the image axis:
  /// [rotationDeg] is the Android surface rotation, which is 0 for a
  /// portrait-locked app even though the landscape sensor is still rotated 90°
  /// relative to the display.
  ({double hfovDeg, double vfovDeg}) portraitDisplayFov() {
    final s = sensorFov();
    final swaps = rotationDeg == 90 || rotationDeg == 270;
    return swaps
        ? (hfovDeg: s.vfovDeg, vfovDeg: s.hfovDeg)
        : (hfovDeg: s.hfovDeg, vfovDeg: s.vfovDeg);
  }

  /// Field of view in the display's frame, from the measured image axis.
  ///
  /// [axisX]/[axisY] are the sensor image's +x direction expressed in view
  /// coordinates (the same axis the native encoder uses to rotate a still).
  /// When that direction is more vertical than horizontal, the sensor's long
  /// side lands on screen-y and the two fields of view swap. This is the
  /// measured form of the rotation [portraitDisplayFov] infers; it does not
  /// depend on the surface rotation at all.
  ({double hfovDeg, double vfovDeg}) displayFovForImageAxis({
    required double axisX,
    required double axisY,
  }) {
    final s = sensorFov();
    final swaps = axisY.abs() > axisX.abs();
    return swaps
        ? (hfovDeg: s.vfovDeg, vfovDeg: s.hfovDeg)
        : (hfovDeg: s.hfovDeg, vfovDeg: s.vfovDeg);
  }

  /// [portraitDisplayFov] for the provisional default, i.e. what a session that
  /// never reported intrinsics projects with.
  ///
  /// Exists so the fallback number lives in exactly one place: anything that
  /// has to put a world point on the screen before the first intrinsics event
  /// lands reads this rather than restating 68°.
  static ({double hfovDeg, double vfovDeg}) get fallbackDisplayFov =>
      fallback4x3.portraitDisplayFov();

  @override
  String toString() => isUsable
      ? 'intrinsics ${imageWidth}x$imageHeight f='
            '${focalLengthXPx.toStringAsFixed(1)}/'
            '${focalLengthYPx.toStringAsFixed(1)}px rot $rotationDeg°'
      : 'intrinsics unavailable';
}

/// What camera the AR session is actually running, as reported by the host.
///
/// The app does not choose ARCore's camera config; it takes the automatic
/// choice. That choice decides two things the user cares about and could
/// otherwise only guess from a blurry result:
///
/// * [stillWidth]/[stillHeight] — the resolution every saved photograph is
///   written from, because `Frame.acquireCameraImage()` hands over the CPU
///   image at this size. 640×480 and 1920×1080 both produce sharp photos at
///   their native size; only the second survives being viewed full-screen.
/// * [focusMode] — whether the lens is allowed to autofocus. ARCore's default
///   is **fixed** focus, which is sharp at one distance and soft everywhere
///   else, and it softens the saved photographs as well as the preview because
///   both come through the same lens.
///
/// Both are reported once per session, on the first pose event that carries
/// them, and shown in the capture screen's status detail. That turns "the
/// photos look blurry" into a number and a mode — which are different
/// problems with different fixes.
class ArCameraQuality {
  /// CPU image size of the session's camera config, in pixels.
  final int stillWidth;

  final int stillHeight;

  /// GPU texture size of the session's camera config, in pixels.
  final int previewWidth;

  final int previewHeight;

  /// `auto` or `fixed`, as granted when the session was configured.
  final String focusMode;

  const ArCameraQuality({
    required this.stillWidth,
    required this.stillHeight,
    required this.previewWidth,
    required this.previewHeight,
    required this.focusMode,
  });

  /// Whether the lens may autofocus.
  bool get autofocus => focusMode == 'auto';

  /// Whether the still stream can fill a 1080p-class display at 1:1.
  ///
  /// A photograph at this size is sharp on its own terms; the number is the
  /// limit of what the hardware offered, not a defect in the capture path.
  bool get fullHdStill => stillWidth >= 1920 || stillHeight >= 1920;

  /// One line for the status detail.
  String describe() => autofocus
      ? 'Photos $stillWidth×$stillHeight · autofocus on'
      : 'Photos $stillWidth×$stillHeight · focus locked at the default '
            'distance';

  @override
  String toString() => describe();
}

/// What the device's AR stack actually supports.
///
/// Every field is a *measured* flag. `depth` in particular exists so that the
/// code can say "not available" out loud instead of quietly behaving as if the
/// depth API were being used.
class ArCapabilities {
  /// ARCore is present *and* this device is on its supported list.
  final bool supported;

  /// Whether the ARCore service APK is installed. Distinguishes "this phone can
  /// never do it" from "install the update".
  final bool serviceInstalled;

  /// Horizontal plane detection is available (the API, not the result).
  final bool planes;

  /// Whether a tracked plane has actually been seen since the session started.
  ///
  /// Kept separate from [planes] on purpose. "Plane detection is enabled" is a
  /// capability; "the floor has been found" is a measurement, and only the
  /// second one may enable the Set Station Here button. Collapsing them would
  /// let the UI tell the user to tap a button that cannot work yet.
  final bool planesTracked;

  /// Anchors could be created and tracked.
  final bool anchors;

  /// The session can hand over its own camera image.
  ///
  /// This is where stills come from while a session is live, because ARCore
  /// holds the camera device exclusively — `camera2`/CameraX cannot open it at
  /// the same time. When this is false the flow has no way to take a photo
  /// without closing the session, and it says so rather than failing silently.
  final bool cameraImage;

  /// The depth API is available. **Never assumed**, because nothing in this
  /// project uses depth.
  final bool depth;

  /// ARCore's own version string, when it reported one.
  final String? arcoreVersion;

  /// Why AR is not usable, in words that can be shown to the user.
  final String? reason;

  /// The camera intrinsics, when the platform reported them.
  final ArCameraIntrinsics? intrinsics;

  /// The field of view in **display** terms, when the platform reported it
  /// directly.
  ///
  /// Preferred over [ArCameraIntrinsics.portraitDisplayFov] because it is what
  /// the platform actually projects with — it already accounts for the display
  /// rotation and the viewport aspect. The derived value is the fallback, and
  /// the two are compared in the diagnostics rather than assumed equal.
  final ({double hfovDeg, double vfovDeg})? displayFov;

  const ArCapabilities({
    required this.supported,
    this.serviceInstalled = false,
    this.planes = false,
    this.planesTracked = false,
    this.anchors = false,
    this.cameraImage = false,
    this.depth = false,
    this.arcoreVersion,
    this.reason,
    this.intrinsics,
    this.displayFov,
  });

  /// What a device with no AR stack at all reports.
  static const ArCapabilities none = ArCapabilities(
    supported: false,
    reason: 'No AR support was reported by the platform.',
  );

  /// Whether an anchor can be created and used to gate capture.
  bool get canAnchor => supported && planes && anchors;

  /// Whether a still can be taken without closing the AR session.
  bool get canShootWhileRunning => supported && cameraImage;

  /// Whether a pose can be read at all.
  bool get canPose => supported;

  /// The display field of view, from the platform when it said, otherwise
  /// derived from the intrinsics, otherwise `null` (and the caller then uses
  /// its own provisional default and says so).
  ({double hfovDeg, double vfovDeg})? get effectiveDisplayFov =>
      displayFov ?? intrinsics?.portraitDisplayFov();

  /// A copy with the given fields replaced.
  ArCapabilities copyWith({
    bool? supported,
    bool? serviceInstalled,
    bool? planes,
    bool? planesTracked,
    bool? anchors,
    bool? cameraImage,
    bool? depth,
    String? arcoreVersion,
    String? reason,
    ArCameraIntrinsics? intrinsics,
    ({double hfovDeg, double vfovDeg})? displayFov,
    bool clearReason = false,
  }) => ArCapabilities(
    supported: supported ?? this.supported,
    serviceInstalled: serviceInstalled ?? this.serviceInstalled,
    planes: planes ?? this.planes,
    planesTracked: planesTracked ?? this.planesTracked,
    anchors: anchors ?? this.anchors,
    cameraImage: cameraImage ?? this.cameraImage,
    depth: depth ?? this.depth,
    arcoreVersion: arcoreVersion ?? this.arcoreVersion,
    reason: clearReason ? null : (reason ?? this.reason),
    intrinsics: intrinsics ?? this.intrinsics,
    displayFov: displayFov ?? this.displayFov,
  );

  /// One line for the diagnostics panel.
  String summary() {
    if (!supported) {
      return reason ?? 'AR is not available on this device.';
    }
    final missing = <String>[
      if (!planes) 'plane detection',
      if (!anchors) 'anchors',
      // Not cosmetic: without the session's camera image there is no way to
      // take a still while the session holds the sensor, so the flow has to
      // close AR and lose the pose. The user needs to know that up front.
      if (!cameraImage) 'still capture through the AR session',
    ];
    final fov = switch ((displayFov, intrinsics)) {
      (final ({double hfovDeg, double vfovDeg}) f, _) =>
        'FOV ${f.hfovDeg.toStringAsFixed(1)}°×'
            '${f.vfovDeg.toStringAsFixed(1)}° from the platform.',
      (null, final ArCameraIntrinsics k) when k.isUsable =>
        'FOV derived from the camera intrinsics '
            '(rot ${k.rotationDeg}°).',
      _ => 'FOV from a provisional default: the camera reported no intrinsics.',
    };
    return missing.isEmpty
        ? 'AR ready: pose, planes and anchors. $fov'
        : 'AR ready, without: ${missing.join(', ')}. $fov';
  }

  @override
  String toString() =>
      'ArCapabilities(supported: $supported, planes: $planes, '
      'planesTracked: $planesTracked, anchors: $anchors, depth: $depth)';
}

/// A camera pose sample.
///
/// [position] and [orientation] are **raw ARCore values**: AR world metres and
/// a rotation from the camera's OpenGL-style local frame to the AR world. Do
/// not feed [orientation] to the guidance maths directly — use
/// [captureWorld], which is the converted form this project's engine expects.
class ArPose {
  final Vec3 position;
  final Quat orientation;
  final TrackingState tracking;

  /// Gyroscope magnitude in degrees per second, when the platform reported one.
  ///
  /// Used by the SETTLE phase, which wants the *rate* rather than a difference
  /// between poses: a pose difference cannot tell a slow drift from a fast
  /// wobble, and it is silent while the phone is stationary but shaking.
  final double? angularRateDegPerSec;

  /// Monotonic timestamp in nanoseconds, when the platform reported one.
  final int? timestampNs;

  const ArPose({
    required this.position,
    required this.orientation,
    required this.tracking,
    this.angularRateDegPerSec,
    this.timestampNs,
  });

  /// The orientation in this project's world convention.
  ///
  /// Delegates to [arCameraPoseToCaptureWorld], so the handedness conversion
  /// has exactly one implementation.
  Quat get captureWorld => arCameraPoseToCaptureWorld(orientation);

  @override
  String toString() =>
      'ArPose(${position.toString()}, ${tracking.name}'
      '${angularRateDegPerSec == null ? '' : ', ${angularRateDegPerSec!.toStringAsFixed(1)}°/s'})';
}

/// The result of a screen-centre hit-test against a tracked plane.
class PlaneHit {
  /// The intersection point, in AR world metres.
  final Vec3 worldPosition;

  /// The plane's normal, in AR world space.
  final Vec3 planeNormal;

  /// Ray distance from the camera to the hit, in metres.
  final double distanceM;

  /// The platform's plane type, e.g. `HORIZONTAL_UPWARD_FACING`.
  final String planeType;

  /// Horizontal extent of the plane, in metres, when reported.
  final ({double x, double z})? extent;

  const PlaneHit({
    required this.worldPosition,
    required this.planeNormal,
    required this.distanceM,
    required this.planeType,
    this.extent,
  });

  /// Whether the plane faces up, i.e. it is a floor or a table top.
  ///
  /// The station anchor is deliberately placed on a *horizontal* plane: the
  /// user aims slightly down at the floor, which is the surface that is both
  /// easy to find and physically where their feet are.
  bool get isHorizontal => planeNormal.y.abs() > 0.7;

  /// How steeply the camera was looking down at the plane, in degrees.
  double get incidenceDeg =>
      math.acos(clampDouble(planeNormal.y.abs(), -1, 1)) * radToDeg;

  @override
  String toString() =>
      'PlaneHit(${worldPosition.toString()}, '
      '${distanceM.toStringAsFixed(2)} m, $planeType)';
}

/// A handle to an anchor held by the platform.
///
/// Deliberately opaque: the Dart side never computes an anchor's transform, it
/// asks the platform. That keeps the anchor's drift model in one place (ARCore's)
/// instead of being duplicated and diverging.
class ArAnchorHandle {
  final String id;
  final Vec3 worldPosition;

  /// ARCore's own tracking state for this anchor.
  final TrackingState tracking;

  const ArAnchorHandle({
    required this.id,
    required this.worldPosition,
    required this.tracking,
  });

  @override
  String toString() =>
      'Anchor($id, ${worldPosition.toString()}, '
      '${tracking.name})';
}
