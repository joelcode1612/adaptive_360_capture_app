import 'package:adaptive_360_capture_app/features/virtual_tour/data/datasources/virtual_tour_local_data_source.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/datasources/virtual_tour_remote_data_source.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/repositories/virtual_tour_repository.dart';

/// The repository from the brief: upload + stitch, then persist.
///
/// Order is deliberate:
///
/// 1. send the photographs and get a panorama URL from the service;
/// 2. only then write `PROPERTY_PHOTO` rows for each source frame and for the
///    derived panorama;
/// 3. only then write the `VIRTUAL_TOUR` row.
///
/// A failure at step 1 writes nothing, so a retry starts clean. A failure at
/// step 2 or 3 raises a failure that says the panorama exists but the records do
/// not — which is true, and is better than returning success for a tour the
/// app cannot find again. Every write is an upsert keyed by a deterministic id,
/// so retrying the same tour replaces rows instead of duplicating them.
class VirtualTourRepositoryImpl implements VirtualTourRepository {
  VirtualTourRepositoryImpl({
    required VirtualTourRemoteDataSource remote,
    required VirtualTourLocalDataSource local,
  }) : _remote = remote, // ignore: prefer_initializing_formals
       _local = local; // ignore: prefer_initializing_formals

  final VirtualTourRemoteDataSource _remote;
  final VirtualTourLocalDataSource _local;

  @override
  Future<StitchedPanorama> uploadAndStitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  }) async {
    if (images.isEmpty) {
      throw const VirtualTourFailure(
        'A panorama needs at least one photograph.',
        retryable: false,
      );
    }

    final stitched = await _remote.stitchPanorama(
      tourId: tourId,
      propertyId: propertyId,
      stationId: stationId,
      images: images,
    );

    final now = DateTime.now().toUtc();
    try {
      // Source frames first: if the derived row is written but a source row is
      // missing, the table claims a panorama that no capture supports.
      for (final image in images) {
        await _local.upsertPropertyPhoto(
          PropertyPhotoRecord(
            id: '${tourId}_${image.nodeId}',
            virtualTourId: tourId,
            propertyId: propertyId,
            nodeId: image.nodeId,
            kind: PropertyPhotoRecord.kindCapture,
            location: image.filePath,
            yawDeg: image.yawDeg,
            pitchDeg: image.pitchDeg,
            capturedAt: image.capturedAt.toUtc(),
            createdAt: now,
          ),
        );
      }
      await _local.upsertPropertyPhoto(
        PropertyPhotoRecord(
          id: '${tourId}_panorama',
          virtualTourId: tourId,
          propertyId: propertyId,
          nodeId: 'panorama',
          kind: PropertyPhotoRecord.kindPanorama,
          location: stitched.url,
          width: stitched.width,
          height: stitched.height,
          sourceCount: images.length,
          capturedAt: stitched.stitchedAt.toUtc(),
          createdAt: now,
        ),
      );

      final existing = await _local.virtualTour(tourId);
      final status = _preserveLaterStatus(existing?.status);
      await _local.upsertVirtualTour(
        VirtualTourRecord(
          id: tourId,
          propertyId: propertyId,
          stationId: stationId,
          status: status,
          panoramaUrl: stitched.url,
          panoramaWidth: stitched.width,
          panoramaHeight: stitched.height,
          photoCount: images.length,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
          submittedAt: existing?.submittedAt,
          verificationId: existing?.verificationId,
          simulated: stitched.simulated,
        ),
      );
    } catch (e) {
      if (e is VirtualTourFailure) rethrow;
      throw VirtualTourFailure(
        'The panorama was stitched, but the tour records could not be saved: '
        '$e',
      );
    }

    return stitched;
  }

  @override
  Future<VirtualTourSubmission> submitVirtualTourForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  }) async {
    if (panoramas.isEmpty) {
      throw const VirtualTourFailure(
        'There is no stitched panorama to submit.',
        retryable: false,
      );
    }

    final existing = await _local.virtualTour(tourId);
    if (existing == null || existing.panoramaUrl == null) {
      throw const VirtualTourFailure(
        'This tour has no recorded panorama, so it cannot be submitted. '
        'Stitch it first.',
        retryable: false,
      );
    }

    final submission = await _remote.submitForVerification(
      tourId: tourId,
      panoramas: panoramas,
    );

    try {
      await _local.upsertVirtualTour(
        existing.copyWith(
          status: submission.status,
          submittedAt: submission.submittedAt.toUtc(),
          verificationId: submission.verificationId,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } catch (e) {
      if (e is VirtualTourFailure) rethrow;
      throw VirtualTourFailure(
        'The tour was submitted, but its new status could not be saved: $e',
      );
    }

    return submission;
  }

  /// Re-stitching a tour must not silently undo a verification that already
  /// started. A row that has not been submitted is simply `stitched`.
  static String _preserveLaterStatus(String? existing) {
    if (existing == null) return 'stitched';
    return switch (existing) {
      'pending_verification' || 'verified' || 'rejected' => existing,
      _ => 'stitched',
    };
  }
}
