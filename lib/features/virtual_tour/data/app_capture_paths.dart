import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/capture_paths.dart';

/// The platform default location for capture sessions.
///
/// Split out from `capture_paths.dart` so that file — and everything built on
/// it — stays pure Dart and can be exercised without a Flutter binding. This is
/// the only part of the storage layer that needs the platform.
///
/// On Android this is the app's private documents directory
/// (`/data/user/0/<pkg>/app_flutter`), which is what we want: frames are the
/// user's own photos of their own premises, and they must not land in shared
/// storage where any other app can read them. Nothing is uploaded anywhere until
/// the user presses upload, and the upload path is separate (`infrastructure/`).
Future<CapturePaths> defaultCapturePaths() async {
  final docs = await getApplicationDocumentsDirectory();
  return CapturePaths(p.join(docs.path, 'capture_sessions'));
}
