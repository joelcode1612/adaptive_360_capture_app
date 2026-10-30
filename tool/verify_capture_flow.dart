// Plain-`dart` runner for the flow-layer checks.
//
//   dart tool/verify_capture_flow.dart
//
// Exit code 0 when every check passes, 1 otherwise.
//
// ignore_for_file: avoid_print
import 'dart:io';
import '../test/engine_checks.dart';
import '../test/flow_checks.dart';

Future<void> main(List<String> args) async {
  final temp = Directory.systemTemp.createTempSync('capture_flow_');
  final checks = <EngineCheck>[];
  var failed = 0;

  // Print as each check is decided rather than at the end: the suite drives
  // whole stations through the state machine, so if one of them stops making
  // progress the last line printed is the check that is stuck.
  void report(EngineCheck c) {
    checks.add(c);
    if (!c.pass) failed++;
    stdout.writeln(
      '[${checks.length.toString().padLeft(2)}] ${c.pass ? 'PASS' : 'FAIL'}  '
      '${c.name}${c.detail.isEmpty ? '' : '\n        ${c.detail}'}',
    );
  }

  try {
    await runFlowChecks(temp.path, onCheck: report);
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }

  stdout.writeln('');
  stdout.writeln(
    '${checks.length - failed}/${checks.length} flow checks passed.',
  );

  // Flush, then set the exit code — do **not** call `exit()`.
  //
  // `exit()` terminates the VM immediately and does not flush stdout. With the
  // output redirected to a file that silently truncated the summary line, which
  // made a fully passing run look like it had hung: every check was present and
  // the total was missing. Setting `exitCode` lets the VM drain and close the
  // stream, and the process still exits with the right status.
  await stdout.flush();
  exitCode = failed == 0 ? 0 : 1;
}
