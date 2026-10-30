import 'dart:async';
import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/camera_preview.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/capture_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Which of the feed's states this camera is in, decided once per build.
enum FeedState {
  /// An AR session holds the sensor and draws the feed itself, under the Flutter
  /// view. Nothing may be painted.
  arSurface,

  /// A preview exists and is being shown.
  preview,

  /// The camera is open and a preview is expected but has not arrived yet.
  waitingForPreview,

  /// The camera is open and will never produce a preview widget — a device whose
  /// camera supplies stills only, or a build with no preview implementation.
  noPreview,

  /// The camera is closed. Opening it is the next step, and it is offered.
  closed;

  /// Whether pixels are on screen. Everything else is an explanation.
  bool get hasImage => this == arSurface || this == preview;
}

/// The live image behind the capture and calibration guides.
///
/// Both camera screens used to inline the same four-line branch, and that branch
/// is what a real device reported as "the phone is a black screen": when the
/// camera had no preview to hand over it returned an empty widget over the
/// near-black chrome and said nothing. The user was left holding a black phone
/// with no reason and no way out, on a station they could not capture because
/// they could not see where they were pointing.
///
/// Every state is now visible and, where software can act on it, actionable. The
/// grey matters on its own: `#222` is the prototype's `.cam` and reads as a
/// viewfinder, while the `#0f1418` chrome reads as a dead screen. Confusing the
/// two is the bug this replaces.
///
/// [FeedState.arSurface] is the branch that would apply to a build with an
/// ARCore host — the platform draws the feed on a GL surface *under* a
/// transparent Flutter view, so there is no widget to embed. **This build has no
/// ARCore host** (`ar_bootstrap.dart`), so that arm never runs here; it is kept
/// because the host that replaces it needs it, not as a claim about this one.
class CameraFeed extends StatefulWidget {
  const CameraFeed({
    super.key,
    required this.camera,
    required this.arOwnsSensor,
    this.onReopen,
    this.reason,
    this.manualHint = false,
  });

  /// The camera the flow is currently using — `engine.activeCamera`, which is
  /// the only honest answer to "who owns the sensor right now".
  final CaptureCamera camera;

  /// True while an AR session holds the camera and draws its own feed.
  final bool arOwnsSensor;

  /// Re-opens the camera. Omitted where a retry cannot help.
  final Future<void> Function()? onReopen;

  /// A failure the flow already knows about (a denied permission, a camera that
  /// refused to open). Shown ahead of the generic wording, because it is the
  /// more specific sentence.
  final String? reason;

  /// Whether to point at the manual capture button. Only the capture screen has
  /// one, so only the capture screen may say this.
  final bool manualHint;

  @override
  State<CameraFeed> createState() => _CameraFeedState();
}

class _CameraFeedState extends State<CameraFeed> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _syncPolling();
  }

  @override
  void didUpdateWidget(CameraFeed old) {
    super.didUpdateWidget(old);
    // The engine swaps the camera when an AR session takes the sensor, so a
    // rebuild can arrive with a different one and a different readiness.
    if (!identical(old.camera, widget.camera)) _syncPolling();
  }

  /// Polls only while a preview is expected from a camera that is actually open.
  ///
  /// Two guards, both load-bearing. `CameraPreviewSource` because a camera that
  /// will never have a preview has nothing to wait for — and this class is used
  /// by test doubles that render no preview at all, so an unguarded periodic
  /// timer would leave a pending timer at the end of every widget test. Bounded
  /// because a preview that has not arrived in a few seconds is not going to
  /// arrive because the app kept polling, and a timer that outlives the station
  /// wakes the UI thread for nothing.
  void _syncPolling() {
    _poll?.cancel();
    _poll = null;
    _ticks = 0;
    if (_state != FeedState.waitingForPreview) return;
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {});
      if (_state != FeedState.waitingForPreview || ++_ticks >= _maxTicks) {
        _poll?.cancel();
        _poll = null;
      }
    });
  }

  int _ticks = 0;
  static const int _maxTicks = 25;

  FeedState get _state {
    if (widget.arOwnsSensor) return FeedState.arSurface;
    final cam = widget.camera;
    if (cam is! CameraPreviewSource) {
      return cam.isRunning ? FeedState.noPreview : FeedState.closed;
    }
    // `CaptureCamera` (a frame source) and `CameraPreviewSource` (a widget
    // supplier) are unrelated types, so the `is` above cannot promote — the cast
    // has to be spelled out.
    if ((cam as CameraPreviewSource).previewAspectRatio != null) {
      return FeedState.preview;
    }
    return cam.isRunning ? FeedState.waitingForPreview : FeedState.closed;
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == FeedState.arSurface) {
      // The Flutter view has to stay transparent for the platform's feed to show
      // through. Nothing may be painted here.
      return const ColoredBox(color: Colors.transparent);
    }
    if (state == FeedState.preview) {
      final cam = widget.camera as CameraPreviewSource;
      return ColoredBox(
        color: CaptureColors.viewfinder,
        child: cam.previewWidget(),
      );
    }
    return ColoredBox(
      color: CaptureColors.viewfinder,
      child: _Message(
        state: state,
        camera: widget.camera,
        reason: widget.reason,
        onReopen: widget.onReopen,
        manualHint: widget.manualHint,
      ),
    );
  }
}

/// What is drawn instead of the image, and why.
class _Message extends StatelessWidget {
  const _Message({
    required this.state,
    required this.camera,
    required this.reason,
    required this.onReopen,
    required this.manualHint,
  });

  final FeedState state;
  final CaptureCamera camera;
  final String? reason;
  final Future<void> Function()? onReopen;
  final bool manualHint;

  /// The sentence for this state, from the most specific evidence available.
  ///
  /// Ordered deliberately: the flow's own failure text (a denied permission, an
  /// exception from the plugin) beats what the camera reported, which beats the
  /// generic line. Two of those are device-supplied, and quoting the device is
  /// the point — a hard-coded message would be a guess about hardware this
  /// repository has never run on.
  String get _text {
    switch (state) {
      case FeedState.waitingForPreview:
        final limitation = camera.capabilities.limitation;
        return limitation == null
            ? 'Opening the camera…'
            : 'Opening the camera…\n$limitation';
      case FeedState.noPreview:
        return 'This camera gives no live preview.';
      case FeedState.closed:
        return reason ??
            camera.capabilities.limitation ??
            'The camera is closed.';
      case FeedState.arSurface:
      case FeedState.preview:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = state == FeedState.waitingForPreview;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (waiting)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: CaptureColors.ok,
                ),
              )
            else
              const Icon(
                Icons.no_photography_outlined,
                size: 34,
                color: CaptureColors.mutedOnDark,
              ),
            const SizedBox(height: 14),
            Text(
              _text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (manualHint) ...[
              const SizedBox(height: 6),
              const Text(
                'You can still capture: aim slowly, hold still, and use '
                '“Capture anyway” below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            if (state == FeedState.closed && onReopen != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: 200,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: CaptureColors.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        CaptureMetrics.smallRadius,
                      ),
                    ),
                  ),
                  onPressed: () => onReopen!(),
                  child: const Text('Re-open the camera'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
