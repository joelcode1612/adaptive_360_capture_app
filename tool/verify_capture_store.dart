// Runs the storage-layer suite with a plain `dart` invocation.
//
//   dart tool/verify_capture_store.dart
//
// Same reason as `verify_capture_engine.dart`: the Flutter tool cannot spawn its
// helper processes in every environment. The storage layer is pure Dart apart
// from `app_capture_paths.dart`, so it can be driven from here against a temp
// directory — no device, no Flutter binding.
//
// Exit code is 0 when every check passes and 1 otherwise.
//
// ignore_for_file: avoid_print
import 'dart:io';
import '../test/engine_checks.dart';
import '../test/store_checks.dart';

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('capture_store_');
  late final List<EngineCheck> checks;
  try {
    checks = await runStoreChecks(temp.path);
  } finally {
    // Left behind on the previous version of this runner: every run leaked a
    // temp directory with a session's worth of frames in it.
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }

  final failed = <EngineCheck>[];
  for (var i = 0; i < checks.length; i++) {
    final c = checks[i];
    final mark = c.pass ? 'PASS' : 'FAIL';
    final detail = c.detail.isEmpty ? '' : '\n          ${c.detail}';
    print('[${(i + 1).toString().padLeft(2)}] $mark  ${c.name}$detail');
    if (!c.pass) failed.add(c);
  }

  print('');
  print('-' * 72);
  if (failed.isEmpty) {
    print('${checks.length}/${checks.length} storage checks passed.');
  } else {
    print(
      '${checks.length - failed.length}/${checks.length} passed, '
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
