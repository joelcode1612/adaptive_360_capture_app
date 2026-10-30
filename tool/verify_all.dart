// Runs every suite that can run without a device, with one plain `dart`
// invocation.
//
//   dart tool/verify_all.dart
//
// First seven:
//   * `capture engine` — reference parity and the state machine, ported from
//     the prototype's `runTests()`;
//   * `capture storage` — the "a frame reaches disk before the machine moves
//     on" contract, in a temp directory;
//   * `capture flow` — the AR tier ladder, the field-of-view resolution, the
//     platform-payload parsing, the drift gate, and one integration check per
//     screen group;
//   * `new modules` — the hold / misalignment check, the downsampler and the
//     off-thread analysis;
//   * `pre-stitch` — the local readiness gate that runs before an upload, ported
//     onto the new `StationGroup` model (its old test went with the entities it
//     used, so it had no coverage at all until this suite);
//   * `ui map` — the pure-Dart view geometry the `ui/` painters draw with: the
//     sphere-map orthographic projection and the status→colour-role mapping,
//     both extracted out of the painters so the suite can pin them;
//   * `capture guidance` — the `360° Capture Prototype (1).html` port: the fixed
//     26-point grid and its ring metadata, the 6-state capture-guidance machine,
//     the room recommendation, review outcome A/B, the 3D target-model spec and
//     the instruction copy.
//
// Three more, added with the port's own evidence:
//   * `glb parse + render` — the two shipped `.glb` files read from the paths
//     `pubspec.yaml` registers, part for part against the model spec, plus
//     synthetic containers a shipped asset cannot exercise;
//   * `attitude fusion` — the gyro-plus-gravity estimator that stands in for
//     ARCore, checked as physical consequences ("hold the phone like this, the
//     estimator must say this") because there is no reference to compare it to;
//   * `js golden parity` — the Dart engine against values produced by the
//     original reference JavaScript under Node, committed as
//     `test/js_golden.json`.
//
// Why a plain `dart` runner exists next to `flutter test`: the Flutter tool
// cannot spawn its helper processes in every environment (it shells out to
// `cmd.exe /c ver`, `where.exe flutter` and `git log`, and on a locked-down
// Windows box those spawns fail with OS error 231 — "all pipe instances are
// busy"). Everything here is pure Dart with no `dart:ui` dependency, so the same
// checks can be driven without the Flutter tool at all.
//
// Exit code is 0 when every check passes and 1 otherwise, so this is usable as a
// CI gate.
//
// ignore_for_file: avoid_print
import 'dart:io';
import '../test/engine_checks.dart';
import '../test/flow_checks.dart';
import '../test/fusion_checks.dart';
import '../test/glb_checks.dart';
import '../test/guidance_checks.dart';
import '../test/js_parity_checks.dart';
import '../test/rewrite_checks.dart';
import '../test/stitch_checks.dart';
import '../test/store_checks.dart';
import '../test/ui_checks.dart';

Future<void> main(List<String> args) async {
  final all = <String, List<EngineCheck>>{};

  all['capture engine'] = runEngineChecks();

  final temp = Directory.systemTemp.createTempSync('capture_store_');
  try {
    all['capture storage'] = await runStoreChecks(temp.path);
    // Reported as each check is decided: the flow suite drives whole stations
    // through the state machine, so if one stops making progress the last line
    // printed names the check that is stuck.
    all['capture flow'] = await runFlowChecks(
      temp.path,
      onCheck: (c) =>
          stdout.writeln('[flow] ${c.pass ? 'PASS' : 'FAIL'}  ${c.name}'),
    );
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }

  all['new modules'] = await runRewriteChecks();

  // Synchronous: the pre-stitch gate is a pure function of a station manifest,
  // with no I/O and nothing to await.
  all['pre-stitch'] = runStitchChecks();

  // Synchronous: the view geometry is a pure function of directions / statuses.
  all['ui map'] = runUiChecks();

  // Synchronous: the fixed 26-point grid, the 6-state guidance machine, the
  // recommendation and the target-model spec are all pure functions.
  all['capture guidance'] = runGuidanceChecks();

  // Synchronous: the parser reads the shipped asset bytes and the renderer is
  // pure arithmetic, so neither needs a device or `dart:ui`.
  all['glb parse + render'] = runGlbChecks();

  // Synchronous: the estimator is stepped with synthetic sensor samples.
  all['attitude fusion'] = runFusionChecks();

  // Synchronous, but reads `test/js_golden.json` from the working directory, so
  // it must be run from the package root like everything else here.
  all['js golden parity'] = runJsParityChecks();

  var total = 0;
  var failed = 0;
  final failures = <String>[];

  for (final entry in all.entries) {
    final checks = entry.value;
    print('');
    print('${entry.key.toUpperCase()}  (${checks.length} checks)');
    print('-' * 72);
    for (var i = 0; i < checks.length; i++) {
      final c = checks[i];
      total++;
      final mark = c.pass ? 'PASS' : 'FAIL';
      final detail = c.detail.isEmpty ? '' : '\n        ${c.detail}';
      print('[${(i + 1).toString().padLeft(2)}] $mark  ${c.name}$detail');
      if (!c.pass) {
        failed++;
        failures.add('${entry.key} #${i + 1}: ${c.name} — ${c.detail}');
      }
    }
  }

  print('');
  print('=' * 72);
  if (failed == 0) {
    print('$total/$total checks passed across ${all.length} suites.');
  } else {
    print('${total - failed}/$total checks passed, $failed failed:');
    for (final f in failures) {
      print('  - $f');
    }
  }

  // Flush before exiting. `exit()` terminates the VM immediately and does not
  // drain stdout, so with the output redirected to a file the summary could be
  // lost — a fully passing run then looked like it had hung. Setting `exitCode`
  // lets the stream close properly and still gives the right status.
  await stdout.flush();
  exitCode = failed == 0 ? 0 : 1;
}
