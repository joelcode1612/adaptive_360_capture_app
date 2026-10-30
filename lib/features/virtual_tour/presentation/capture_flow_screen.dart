import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/flow_state.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_flow_controller.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/ar_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/plan_screens.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/review_screens.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/station_setup_screen.dart';

/// The capture flow, screens 1–9 of `360° Capture Prototype.html`.
///
/// One host with a switch over [CaptureScreen] rather than nine routes. The
/// flow is a wizard: the screens share a controller, a session and a state
/// machine, and pushing each one onto the navigator would mean either threading
/// the controller through every `MaterialPageRoute` or reaching for a global.
/// The prototype's `go(n)` is a screen index, and this keeps that shape.
///
/// Screens 1–5 are the real screens. Screens 6 and 9 — the progress map and the
/// tour preview — are promoted from the prototype's sheets to full screens so
/// each screen group is reachable and testable on its own; the progress map is
/// still also available as a sheet over the camera, which is where the prototype
/// puts it.
class CaptureFlowScreen extends StatefulWidget {
  const CaptureFlowScreen({super.key, this.controller, this.autoStart = true});

  /// Injected by a test. When `null` the screen builds the real one, which
  /// needs the platform's camera, AR and storage.
  final CaptureFlowController? controller;

  /// Whether to build the controller on the first frame. A test that injects
  /// one sets this false.
  final bool autoStart;

  @override
  State<CaptureFlowScreen> createState() => _CaptureFlowScreenState();
}

class _CaptureFlowScreenState extends State<CaptureFlowScreen>
    with WidgetsBindingObserver {
  CaptureFlowController? _controller;
  String? _bootError;
  bool _booting = false;

  CaptureFlowController? get _c => _controller ?? widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      _controller = widget.controller;
      // The listener is what makes the host follow the flow. Built here rather
      // than left to `_boot`, which returns immediately for an injected
      // controller: without it the screen keeps painting screen 1 no matter
      // where the flow goes, and a test that injects one — the documented way
      // of reaching these widgets — would be checking a layout that never
      // changes.
      _controller!.addListener(_onFlowChanged);
    } else if (widget.autoStart) {
      _boot();
    }
  }

  Future<void> _boot() async {
    if (_booting || _controller != null) return;
    _booting = true;
    try {
      final created = await CaptureFlowController.create();
      if (!mounted) {
        created.dispose();
        return;
      }
      setState(() => _controller = created);
      created.addListener(_onFlowChanged);
      created.syncTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootError = '$e');
    } finally {
      _booting = false;
    }
  }

  void _onFlowChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        c.onAppPaused();
      case AppLifecycleState.resumed:
        c.onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onFlowChanged);
    // Only dispose what this widget created. An injected controller belongs to
    // its owner.
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_bootError != null) {
      return _BootFailure(message: _bootError!);
    }
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Every screen is dark: in the prototype the whole app lives inside one dark
    // phone shell, so there is no light variant to fall back to. The capture
    // screen gets the other theme for exactly one reason — its scaffold has to
    // be transparent so an AR session's camera surface shows through behind the
    // Flutter view.
    final cameraScreen = c.screen == CaptureScreen.arCapture;
    final flow = PopScope(
      canPop: !cameraScreen,
      onPopInvokedWithResult: (didPop, _) {
        // The capture screen has no back: leaving mid-station without saving
        // would discard frames the machine has already validated. The sheet on
        // that screen offers Resume and Save and exit instead.
        if (!didPop) c.onAppPaused();
      },
      child: _screenFor(c),
    );
    return cameraScreen ? Theme(data: captureCameraTheme(), child: flow) : flow;
  }

  Widget _screenFor(CaptureFlowController c) => switch (c.screen) {
    CaptureScreen.intro => IntroScreen(controller: c),
    CaptureScreen.roomDetails => RoomDetailsScreen(controller: c),
    CaptureScreen.plan => PlanScreen(controller: c),
    CaptureScreen.stationSetup => StationSetupScreen(controller: c),
    CaptureScreen.arCapture => ArCaptureScreen(controller: c),
    CaptureScreen.progressMap => ProgressMapScreen(controller: c),
    CaptureScreen.stationReview => StationReviewScreen(controller: c),
    CaptureScreen.addStation => AddStationScreen(controller: c),
    CaptureScreen.tourPreview => TourPreviewScreen(controller: c),
  };
}

/// Shown when the flow could not even be built.
///
/// Not a crash screen: the most likely cause is a device with no usable camera,
/// which is a supported configuration and gets an explanation, not a stack
/// trace.
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Capture could not start',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
