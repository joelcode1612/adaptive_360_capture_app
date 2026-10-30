/// The virtual-tour upload contract: the photographs the AR screen produced,
/// the panorama the stitching service returned, and the rows the two database
/// tables hold.
///
/// Pure Dart. Nothing here imports Flutter, `dart:io` or a plugin, so the data
/// layer, the Bloc and the tests all describe the same records without a device
/// or a binding.
library;

/// Where a failed request failed, so the UI can say more than "something went
/// wrong" and a retry can explain what it will retry.
enum VirtualTourStage {
  /// The 30 JPEGs are being sent to the stitching service.
  uploading,

  /// The service accepted the upload and is running OpenCV.
  stitching,

  /// The stitched panorama is being submitted for verification.
  submitting,

  /// The request never left the app: bad input, a missing file, no panorama.
  validation,
}

extension VirtualTourStageLabel on VirtualTourStage {
  String get label => switch (this) {
    VirtualTourStage.uploading => 'Uploading photographs',
    VirtualTourStage.stitching => 'Stitching panorama',
    VirtualTourStage.submitting => 'Submitting for verification',
    VirtualTourStage.validation => 'Cannot continue',
  };
}

/// A failure that is safe to show to the user as-is.
///
/// [retryable] is not cosmetic: a missing photograph must not offer a retry that
/// will fail identically, while a timeout must. The Bloc copies both fields into
/// its error state and the screen enables its Retry button from it.
class VirtualTourFailure implements Exception {
  final String message;
  final bool retryable;

  const VirtualTourFailure(this.message, {this.retryable = true});

  @override
  String toString() => 'VirtualTourFailure($message)';
}

/// One photograph captured at one world-locked node.
class PanoramaImage {
  final String nodeId;
  final String filePath;
  final double yawDeg;
  final double pitchDeg;
  final DateTime capturedAt;

  const PanoramaImage({
    required this.nodeId,
    required this.filePath,
    required this.yawDeg,
    required this.pitchDeg,
    required this.capturedAt,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'nodeId': nodeId,
    'filePath': filePath,
    'yawDeg': yawDeg,
    'pitchDeg': pitchDeg,
    'capturedAt': capturedAt.toIso8601String(),
  };

  static PanoramaImage fromJson(Map<String, Object?> m) => PanoramaImage(
    nodeId: m['nodeId']! as String,
    filePath: m['filePath']! as String,
    yawDeg: (m['yawDeg']! as num).toDouble(),
    pitchDeg: (m['pitchDeg']! as num).toDouble(),
    capturedAt: DateTime.parse(m['capturedAt']! as String),
  );

  @override
  String toString() => 'PanoramaImage($nodeId, $filePath)';
}

/// What the stitching service returned for one station.
class StitchedPanorama {
  /// Reachable URL of the equirectangular image.
  final String url;

  /// Pixel dimensions of the returned image; `0` when the service did not say.
  final int width;
  final int height;
  final String format;
  final DateTime stitchedAt;

  /// True only for the local stand-in, whose "panorama" is not stitched at all.
  /// The success screen labels it instead of presenting it as a real result.
  final bool simulated;

  const StitchedPanorama({
    required this.url,
    this.width = 0,
    this.height = 0,
    this.format = 'jpeg',
    required this.stitchedAt,
    this.simulated = false,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'width': width,
    'height': height,
    'format': format,
    'stitchedAt': stitchedAt.toIso8601String(),
    'simulated': simulated,
  };

  static StitchedPanorama fromJson(Map<String, Object?> m) => StitchedPanorama(
    url: m['url']! as String,
    width: (m['width'] as num?)?.toInt() ?? 0,
    height: (m['height'] as num?)?.toInt() ?? 0,
    format: m['format'] as String? ?? 'jpeg',
    stitchedAt: DateTime.parse(m['stitchedAt']! as String),
    simulated: m['simulated'] == true,
  );

  @override
  String toString() => 'StitchedPanorama($url, ${width}x$height)';
}

/// The service's acknowledgement that a tour entered verification.
class VirtualTourSubmission {
  final String tourId;
  final String status;
  final String? verificationId;
  final DateTime submittedAt;
  final bool simulated;

  const VirtualTourSubmission({
    required this.tourId,
    required this.status,
    this.verificationId,
    required this.submittedAt,
    this.simulated = false,
  });

  @override
  String toString() =>
      'VirtualTourSubmission($tourId, $status, ${verificationId ?? '—'})';
}

/// One row of the `VIRTUAL_TOUR` table.
///
/// The real schema is external to this repository; this is the local stand-in
/// written by [VirtualTourLocalDataSource]. The field names are chosen to match
/// the columns Section 4.5.2 names, so switching the store to SQL does not
/// rename anything above the data layer.
class VirtualTourRecord {
  final String id;
  final String propertyId;
  final String stationId;

  /// `stitched` after the panorama is stored, then `pending_verification`.
  final String status;
  final String? panoramaUrl;
  final int panoramaWidth;
  final int panoramaHeight;
  final int photoCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? submittedAt;
  final String? verificationId;
  final bool simulated;

  const VirtualTourRecord({
    required this.id,
    required this.propertyId,
    required this.stationId,
    required this.status,
    required this.photoCount,
    required this.createdAt,
    required this.updatedAt,
    this.panoramaUrl,
    this.panoramaWidth = 0,
    this.panoramaHeight = 0,
    this.submittedAt,
    this.verificationId,
    this.simulated = false,
  });

  VirtualTourRecord copyWith({
    String? status,
    String? panoramaUrl,
    int? panoramaWidth,
    int? panoramaHeight,
    int? photoCount,
    DateTime? updatedAt,
    DateTime? submittedAt,
    String? verificationId,
    bool? simulated,
  }) => VirtualTourRecord(
    id: id,
    propertyId: propertyId,
    stationId: stationId,
    status: status ?? this.status,
    photoCount: photoCount ?? this.photoCount,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    panoramaUrl: panoramaUrl ?? this.panoramaUrl,
    panoramaWidth: panoramaWidth ?? this.panoramaWidth,
    panoramaHeight: panoramaHeight ?? this.panoramaHeight,
    submittedAt: submittedAt ?? this.submittedAt,
    verificationId: verificationId ?? this.verificationId,
    simulated: simulated ?? this.simulated,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'propertyId': propertyId,
    'stationId': stationId,
    'status': status,
    'panoramaUrl': panoramaUrl,
    'panoramaWidth': panoramaWidth,
    'panoramaHeight': panoramaHeight,
    'photoCount': photoCount,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'submittedAt': submittedAt?.toIso8601String(),
    'verificationId': verificationId,
    'simulated': simulated,
  };

  static VirtualTourRecord fromJson(Map<String, Object?> m) =>
      VirtualTourRecord(
        id: m['id']! as String,
        propertyId: m['propertyId']! as String,
        stationId: m['stationId']! as String,
        status: m['status']! as String,
        panoramaUrl: m['panoramaUrl'] as String?,
        panoramaWidth: (m['panoramaWidth'] as num?)?.toInt() ?? 0,
        panoramaHeight: (m['panoramaHeight'] as num?)?.toInt() ?? 0,
        photoCount: (m['photoCount'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(m['createdAt']! as String),
        updatedAt: DateTime.parse(m['updatedAt']! as String),
        submittedAt: m['submittedAt'] == null
            ? null
            : DateTime.parse(m['submittedAt']! as String),
        verificationId: m['verificationId'] as String?,
        simulated: m['simulated'] == true,
      );
}

/// One row of the `PROPERTY_PHOTO` table.
///
/// Written once per captured node **and** once for the stitched panorama, so the
/// table records both the evidence and the derived image. [kind] separates the
/// two; [nodeId] is the world-locked node for a capture and `panorama` for the
/// derived image.
class PropertyPhotoRecord {
  final String id;
  final String virtualTourId;
  final String propertyId;
  final String nodeId;
  final String kind;
  final String location;
  final double yawDeg;
  final double pitchDeg;
  final int width;
  final int height;
  final int sourceCount;
  final DateTime capturedAt;
  final DateTime createdAt;

  const PropertyPhotoRecord({
    required this.id,
    required this.virtualTourId,
    required this.propertyId,
    required this.nodeId,
    required this.kind,
    required this.location,
    required this.capturedAt,
    required this.createdAt,
    this.yawDeg = 0,
    this.pitchDeg = 0,
    this.width = 0,
    this.height = 0,
    this.sourceCount = 0,
  });

  static const String kindCapture = 'capture';
  static const String kindPanorama = 'panorama';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'virtualTourId': virtualTourId,
    'propertyId': propertyId,
    'nodeId': nodeId,
    'kind': kind,
    'location': location,
    'yawDeg': yawDeg,
    'pitchDeg': pitchDeg,
    'width': width,
    'height': height,
    'sourceCount': sourceCount,
    'capturedAt': capturedAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };

  static PropertyPhotoRecord fromJson(Map<String, Object?> m) =>
      PropertyPhotoRecord(
        id: m['id']! as String,
        virtualTourId: m['virtualTourId']! as String,
        propertyId: m['propertyId']! as String,
        nodeId: m['nodeId']! as String,
        kind: m['kind']! as String,
        location: m['location']! as String,
        yawDeg: (m['yawDeg'] as num?)?.toDouble() ?? 0,
        pitchDeg: (m['pitchDeg'] as num?)?.toDouble() ?? 0,
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        sourceCount: (m['sourceCount'] as num?)?.toInt() ?? 0,
        capturedAt: DateTime.parse(m['capturedAt']! as String),
        createdAt: DateTime.parse(m['createdAt']! as String),
      );
}
