import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/quality/image_analysis.dart';

// Re-exported so the camera layer has one import for "the frame sizes the
// analysis works at", wherever they are defined.
export 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart'
    show analysisWidth, analysisHeight;

/// Downsampling and off-thread image analysis.
///
/// Everything here is pure Dart, so it runs — and is tested — without a device.
/// The only platform-facing piece is `plugin_camera.dart`, which feeds this.
///
/// The analysis resolution itself (`analysisWidth` / `analysisHeight`) is defined
/// next to the state machine, because the machine's validation buffer is sized
/// from it; this file re-exports the names for the camera layer's convenience.
///
/// Those dimensions are small on purpose:
///
/// * the metrics are *statistics over the whole frame*, and Laplacian variance is
///   scale-dependent — a fixed small size means the provisional thresholds mean
///   the same thing on every device, which a full-resolution frame would not;
/// * a 120×160 buffer is 19,200 pixels, so a frame costs microseconds to analyse;
/// * it keeps the per-frame allocation small enough that the camera stream can
///   run without GC pressure.

/// Box-averaged downsample of a luma plane to `outW × outH`.
///
/// [bytesPerRow] is the plane's row stride, which on Android is usually **larger**
/// than [width] because rows are padded for the hardware. Reading `width` bytes
/// per row and ignoring the stride is the classic way to get a sheared image, so
/// the stride is explicit here.
///
/// The result is a `Float64List` of `outW * outH` luminance values, 0…255, which
/// is exactly what [analyzeGray] consumes.
///
/// **Rotation is deliberately not applied.** A quarter turn does not change any
/// metric the analysis computes — the Laplacian variance, the histogram, the
/// entropy and the edge share are all invariant under a 90° rotation — and the
/// analysis frame is never used geometrically. Rotating it would cost a pass over
/// every pixel for no gain.
Float64List downsampleLuma(
  Uint8List plane,
  int width,
  int height,
  int bytesPerRow,
  int outW,
  int outH,
) {
  final out = Float64List(outW * outH);
  if (width <= 0 || height <= 0 || outW <= 0 || outH <= 0) return out;

  for (var oy = 0; oy < outH; oy++) {
    final y0 = (oy * height) ~/ outH;
    final y1 = math.max(y0 + 1, ((oy + 1) * height) ~/ outH);
    for (var ox = 0; ox < outW; ox++) {
      final x0 = (ox * width) ~/ outW;
      final x1 = math.max(x0 + 1, ((ox + 1) * width) ~/ outW);

      var sum = 0;
      var n = 0;
      for (var y = y0; y < y1 && y < height; y++) {
        final row = y * bytesPerRow;
        for (var x = x0; x < x1 && x < width; x++) {
          final i = row + x;
          if (i >= 0 && i < plane.length) {
            sum += plane[i];
            n++;
          }
        }
      }
      out[oy * outW + ox] = n == 0 ? 0 : sum / n;
    }
  }
  return out;
}

/// Expands a grayscale buffer to RGBA8888.
///
/// The domain's live frame carries RGBA because that is what its grayscale
/// conversion consumes. Going through RGBA costs one byte-tripling pass per
/// frame, which is cheap at this resolution, and it keeps a single frame format
/// across the simulated and live paths instead of two that can drift apart.
Uint8List grayToRgba(Float64List gray) {
  final out = Uint8List(gray.length * 4);
  for (var i = 0; i < gray.length; i++) {
    final v = gray[i].round().clamp(0, 255);
    final j = i * 4;
    out[j] = v;
    out[j + 1] = v;
    out[j + 2] = v;
    out[j + 3] = 255;
  }
  return out;
}

/// Expands an 8-bit luma plane to RGBA8888.
///
/// The AR path gets its analysis frame as one byte per pixel — the platform
/// downscales the camera image's luma plane and sends 19,200 bytes rather than
/// the 76,800 an RGBA frame would cost over the channel. This turns it back into
/// the format the domain's `LiveFrame` carries, without a `Float64List` in
/// between.
Uint8List lumaToRgba(Uint8List luma) {
  final out = Uint8List(luma.length * 4);
  for (var i = 0; i < luma.length; i++) {
    final v = luma[i];
    final j = i * 4;
    out[j] = v;
    out[j + 1] = v;
    out[j + 2] = v;
    out[j + 3] = 255;
  }
  return out;
}

/// Runs [analyzeGray] on a background isolate.
///
/// The brief asks for the analysis to stay off the UI thread. This uses
/// `Isolate.run`, i.e. **one short-lived isolate per analysis**, rather than a
/// long-lived worker with a port:
///
/// * analysis happens once per *capture attempt* — a few dozen times in a whole
///   session — not once per preview frame, so spawn cost (well under a
///   millisecond) is irrelevant;
/// * a worker isolate needs a lifecycle, an error path, a shutdown path and a
///   port protocol, all of which are places for a bug to hide. `Isolate.run`
///   cannot leak, because the isolate ends when the future completes.
///
/// The input is copied, not shared: 120×160 doubles is 150 KB, and the copy is
/// far cheaper than the coordination a shared buffer would need.
Future<ImageStats> analyzeOffThread(Float64List gray, int w, int h) =>
    Isolate.run(() => analyzeGray(gray, w, h));
