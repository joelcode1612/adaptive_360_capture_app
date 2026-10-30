// Runs the ported capture-engine suite with a plain `dart` invocation.
//
//   dart run tool/verify_capture_engine.dart
//
// Why this exists next to `test/capture_engine_test.dart`: the Flutter tool
// cannot spawn its helper processes in every environment (it shells out to
// `cmd.exe /c ver`, `where.exe flutter` and `git log`, and on a locked-down
// Windows box those spawns fail with OS error 231 — "all pipe instances are
// busy"). The engine is deliberately pure Dart with no `dart:ui` dependency, so
// the same checks can be driven from here without the Flutter tool at all.
//
// Exit code is 0 when every check passes and 1 otherwise, so this is usable as
// a CI gate.
//
// ignore_for_file: avoid_print
import 'dart:io';
import '../test/engine_checks.dart';

void main() async {
  final checks = runEngineChecks();
  final failed = <EngineCheck>[];

  for (var i = 0; i < checks.length; i++) {
    final c = checks[i];
    final label = (i + 1).toString().padLeft(2);
    final mark = c.pass ? 'PASS' : 'FAIL';
    final detail = c.detail.isEmpty ? '' : '\n          ${c.detail}';
    print('[$label] $mark  ${c.name}$detail');
    if (!c.pass) failed.add(c);
  }

  print('');
  print('-' * 72);
  if (failed.isEmpty) {
    print('${checks.length}/${checks.length} checks passed.');
  } else {
    print(
      '${checks.length - failed.length}/${checks.length} checks passed, '
      '${failed.length} failed:',
    );
    for (final f in failed) {
      print('  - ${f.name}');
      if (f.detail.isNotEmpty) print('      ${f.detail}');
    }
  }

  // Flush before exiting: `exit()` terminates the VM immediately without
  // draining stdout, so a redirected run could lose the summary line and look
  // like a hang. See the same note in `verify_capture_flow.dart`.
  await stdout.flush();
  exitCode = failed.isEmpty ? 0 : 1;
}
