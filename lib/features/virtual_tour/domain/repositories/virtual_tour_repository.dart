import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';

/// The two things the virtual-tour feature needs from the outside world.
///
/// The brief names exactly these operations, and the Bloc is written against
/// this interface rather than against HTTP or a database. That is what lets the
/// 30-photograph upload, its processing state and its failure path be tested
/// without a Python service, a device or a network.
///
/// Implemented by `VirtualTourRepositoryImpl`, which sends the files to the
/// stitching service and writes the resulting `VIRTUAL_TOUR` / `PROPERTY_PHOTO`
/// rows.
abstract class VirtualTourRepository {
  /// Sends every capture of one station to the Python/OpenCV stitcher and
  /// records the returned equirectangular panorama.
  ///
  /// Throws [VirtualTourFailure] with a message fit for the user. The Bloc
  /// turns that into its error state.
  Future<StitchedPanorama> uploadAndStitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  });

  /// Submits a stitched tour for human/automated verification.
  ///
  /// [panoramas] is the set returned by [uploadAndStitchPanorama], so a tour
  /// cannot be submitted on the strength of captured files alone.
  Future<VirtualTourSubmission> submitVirtualTourForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  });
}
