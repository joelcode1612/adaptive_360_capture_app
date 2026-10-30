// On-device verification of the capture-screen startup.
//
// **Why this is an integration test and not a unit test.** The bug it pins
// — the guided flow navigating into the capture screen and parking on an
// eternal spinner — only exists in the assembled app: the navigation, the
// engine, the camera and the real sensor stream. A widget test with a fake
// engine would test the fake.
//
// It drives the real wizard on the connected phone through the VM service,
// which needs no input injection and so runs where `adb shell input` is
// blocked by device policy.
//
// What it proves, in order:
//   1. entering the capture screen shows a **named stage** (the panel that
//      replaced the message-less spinner) — not a bare spinner;
//   2. the session the panel waits for actually starts, and the live capture
//      view (the "Station 1" header and viewfinder) appears;
//   3. the whole thing happens within a bounded time, so a regression to the
//      old hang fails this test instead of the user.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:adaptive_360_capture_app/main.dart' as app;

/// Pumps until [finder] matches or [timeout] expires.
///
/// `pumpAndSettle` is unusable on these screens: the startup panel and the
/// capture view both carry perpetual animations (a spinner, the guidance
/// ring), so a settle would never come. The pumps are also the only way real
/// timers — the engine's ticker and the startup watchdog — get to run.
Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

Future<void> tapThrough(
  WidgetTester tester,
  String label, {
  Duration settle = const Duration(seconds: 4),
}) async {
  final found = await waitFor(tester, find.text(label), timeout: settle);
  expect(found, isTrue, reason: 'never saw the "$label" button');
  await tester.tap(find.text(label));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('guided flow starts the capture session', (tester) async {
    app.main();
    await waitFor(tester, find.text('Guided flow'), timeout: const Duration(seconds: 10));

    // ── the wizard: launcher → room → plan → station setup ──────────────
    await tapThrough(tester, 'Guided flow');
    await tapThrough(tester, 'Set Up Capture');
    await tapThrough(tester, 'Recommend Capture Plan');
    await tapThrough(tester, 'Start Capture');

    // This build runs the sensor path, so the button says so by name.
    await tapThrough(tester, 'Begin Sensor Guidance');

    // The sensor path needs a direction before the station can be locked.
    final locked = await waitFor(tester, find.text('Set Station Here'));
    expect(
      locked,
      isTrue,
      reason: 'the sensors never produced a direction, so the station could '
          'not be locked — that is a sensor failure, not the startup bug',
    );
    await tester.tap(find.text('Set Station Here'));

    // ── the startup: a named stage, not a bare spinner ──────────────────
    // The fix's first assertion: the screen must say what it is waiting
    // for. Before the fix it showed only a CircularProgressIndicator with
    // no text, forever, because nothing called beginCapture().
    final stageShown = await waitFor(
      tester,
      find.textContaining('STEP 3'),
      timeout: const Duration(seconds: 15),
    );
    expect(
      stageShown,
      isTrue,
      reason: 'the capture screen showed no startup stage — the eternal '
          'spinner has regressed',
    );
    await binding.takeScreenshot('1-startup-panel');

    // ── the session starts: the live capture view appears ───────────────
    // "Station 1" is the capture screen's header, shown as soon as the
    // engine has a session — the exact thing that was missing.
    final live = await waitFor(
      tester,
      find.text('Station 1'),
      timeout: const Duration(seconds: 30),
    );
    expect(
      live,
      isTrue,
      reason: 'the capture session never started — beginCapture() was not '
          'called on entering the screen',
    );
    await binding.takeScreenshot('2-capture-live');

    // ── the capture machine is running: a target is being guided ────────
    // The instruction panel always has a sentence while a session is live
    // ("Hold still…", "Turn left…", the target count). Seeing any of them
    // proves the ticker is advancing the machine, not just its header.
    final guiding = await waitFor(
      tester,
      find.textContaining(RegExp(r'Capture \d+ of 26')),
      timeout: const Duration(seconds: 15),
    );
    expect(
      guiding,
      isTrue,
      reason: 'the session started but the 26-target machine never engaged',
    );
    await binding.takeScreenshot('3-target-guiding');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
