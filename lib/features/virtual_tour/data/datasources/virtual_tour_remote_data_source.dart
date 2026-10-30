import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';

/// Where the Python/OpenCV stitching service lives.
///
/// Injected rather than hard-coded because this repository has no API contract
/// for it: no endpoint, no response schema, no DDL. A real deployment supplies
/// `--dart-define=VIRTUAL_TOUR_API_BASE_URL=https://…`; without it the app uses
/// [LocalVirtualTourRemoteDataSource] and says so in the success panel instead
/// of pretending a panorama was stitched.
class VirtualTourApiConfig {
  final Uri baseUri;

  /// Path of the multipart stitch endpoint, resolved against [baseUri].
  final String stitchPath;

  /// Path of the JSON submit endpoint. `{tourId}` is replaced on each request.
  final String submitPath;
  final Duration timeout;
  final Map<String, String> headers;

  const VirtualTourApiConfig({
    required this.baseUri,
    this.stitchPath = '/api/v1/panoramas/stitch',
    this.submitPath = '/api/v1/virtual-tours/{tourId}/submit',
    this.timeout = const Duration(seconds: 90),
    this.headers = const <String, String>{},
  });

  static const String _environmentBase = String.fromEnvironment(
    'VIRTUAL_TOUR_API_BASE_URL',
  );

  /// The configured endpoint, or `null` when this build has none.
  static VirtualTourApiConfig? fromEnvironment() {
    if (_environmentBase.trim().isEmpty) return null;
    final uri = Uri.tryParse(_environmentBase.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const VirtualTourFailure(
        'VIRTUAL_TOUR_API_BASE_URL is not a valid absolute URL.',
        retryable: false,
      );
    }
    return VirtualTourApiConfig(baseUri: uri);
  }

  Uri get stitchUri => baseUri.resolve(stitchPath);

  Uri submitUri(String tourId) => baseUri.resolve(
    submitPath.replaceAll('{tourId}', Uri.encodeComponent(tourId)),
  );
}

/// The network seam. The repository is written against this, so the Bloc and
/// its tests never open a socket.
abstract class VirtualTourRemoteDataSource {
  Future<StitchedPanorama> stitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  });

  Future<VirtualTourSubmission> submitForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  });

  Future<void> dispose() async {}
}

/// Uploads the station's JPEGs as one multipart request and reads the stitched
/// panorama URL from the JSON response.
///
/// The wire shape is documented here because it is the only contract this app
/// assumes:
///
/// * `POST {stitchPath}` with `multipart/form-data`;
/// * fields `tour_id`, `property_id`, `station_id`, and a `manifest` JSON array
///   describing each image (`nodeId`, `yawDeg`, `pitchDeg`, `capturedAt`);
/// * one `images` file part per capture, `image/jpeg`, named
///   `01_h01.jpg`, `02_h02.jpg`, … so the service can preserve order;
/// * a 2xx JSON response with `url` (or `panorama_url`), and optionally
///   `width`, `height`, `format`, `stitched_at`.
///
/// Submit is `POST {submitPath}` with JSON `{tour_id, panoramas, submitted_at}`
/// and expects `{status, verification_id?, submitted_at?}`.
class HttpVirtualTourRemoteDataSource implements VirtualTourRemoteDataSource {
  HttpVirtualTourRemoteDataSource({required this.config, http.Client? client})
    : _client = client ?? http.Client();

  final VirtualTourApiConfig config;
  final http.Client _client;

  @override
  Future<StitchedPanorama> stitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  }) async {
    if (images.isEmpty) {
      throw const VirtualTourFailure(
        'There are no photographs to stitch.',
        retryable: false,
      );
    }

    final request = http.MultipartRequest('POST', config.stitchUri)
      ..headers.addAll(config.headers);
    request.fields.addAll(<String, String>{
      'tour_id': tourId,
      'property_id': propertyId,
      'station_id': stationId,
      'manifest': jsonEncode(<String, Object?>{
        'tourId': tourId,
        'propertyId': propertyId,
        'stationId': stationId,
        'images': <Map<String, Object?>>[
          for (final image in images)
            <String, Object?>{
              'nodeId': image.nodeId,
              'yawDeg': image.yawDeg,
              'pitchDeg': image.pitchDeg,
              'capturedAt': image.capturedAt.toIso8601String(),
            },
        ],
      }),
    });

    for (var i = 0; i < images.length; i++) {
      final image = images[i];
      final file = File(image.filePath);
      if (!await file.exists()) {
        throw VirtualTourFailure(
          'The photograph for node ${image.nodeId} is missing from '
          '${image.filePath}.',
          retryable: false,
        );
      }
      final length = await file.length();
      if (length == 0) {
        throw VirtualTourFailure(
          'The photograph for node ${image.nodeId} is empty.',
          retryable: false,
        );
      }
      final name = '${(i + 1).toString().padLeft(2, '0')}_${image.nodeId}.jpg';
      request.files.add(
        await http.MultipartFile.fromPath(
          'images',
          file.path,
          filename: name,
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }

    final response = await _send(request, what: 'The stitching service');
    final json = _decodeJson(response, what: 'The stitching service');
    final rawUrl =
        (json['url'] ?? json['panorama_url'] ?? json['panoramaUrl']) as String?;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      throw const VirtualTourFailure(
        'The stitching service returned no panorama URL.',
      );
    }
    final stitchedAt = _dateOrNow(json['stitched_at'] ?? json['stitchedAt']);
    return StitchedPanorama(
      url: _absoluteUrl(rawUrl),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      format: json['format'] as String? ?? 'jpeg',
      stitchedAt: stitchedAt,
      simulated: json['simulated'] == true,
    );
  }

  @override
  Future<VirtualTourSubmission> submitForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  }) async {
    if (panoramas.isEmpty) {
      throw const VirtualTourFailure(
        'There is no stitched panorama to submit.',
        retryable: false,
      );
    }
    final submittedAt = DateTime.now().toUtc();
    final response = await _send(
      http.Request('POST', config.submitUri(tourId))
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          ...config.headers,
        })
        ..body = jsonEncode(<String, Object?>{
          'tour_id': tourId,
          'submitted_at': submittedAt.toIso8601String(),
          'panoramas': <Map<String, Object?>>[
            for (final panorama in panoramas) panorama.toJson(),
          ],
        }),
      what: 'The verification service',
    );
    final json = _decodeJson(response, what: 'The verification service');
    return VirtualTourSubmission(
      tourId: tourId,
      status: json['status'] as String? ?? 'pending_verification',
      verificationId:
          (json['verification_id'] ?? json['verificationId']) as String?,
      submittedAt: _dateOrNow(json['submitted_at'] ?? json['submittedAt']),
      simulated: json['simulated'] == true,
    );
  }

  @override
  Future<void> dispose() async => _client.close();

  Future<http.Response> _send(
    http.BaseRequest request, {
    required String what,
  }) async {
    try {
      final streamed = await _client.send(request).timeout(config.timeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = response.body.trim();
        final detail = body.isEmpty
            ? ''
            : ': ${body.length > 300 ? '${body.substring(0, 300)}…' : body}';
        throw VirtualTourFailure(
          '$what answered HTTP ${response.statusCode}$detail',
          retryable:
              response.statusCode >= 500 ||
              response.statusCode == 408 ||
              response.statusCode == 429,
        );
      }
      return response;
    } on TimeoutException {
      throw VirtualTourFailure(
        '$what did not answer within ${config.timeout.inSeconds}s.',
      );
    } on IOException catch (e) {
      throw VirtualTourFailure('$what could not be reached: $e');
    } on http.ClientException catch (e) {
      throw VirtualTourFailure('$what could not be reached: ${e.message}');
    }
  }

  Map<String, Object?> _decodeJson(
    http.Response response, {
    required String what,
  }) {
    final body = response.body.trim();
    if (body.isEmpty) {
      throw VirtualTourFailure('$what returned an empty response.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw VirtualTourFailure('$what returned invalid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw VirtualTourFailure('$what returned JSON that is not an object.');
    }
    return decoded.cast<String, Object?>();
  }

  String _absoluteUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) {
      throw const VirtualTourFailure(
        'The stitching service returned a URL that cannot be parsed.',
      );
    }
    if (uri.hasScheme) {
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw VirtualTourFailure(
          'The stitching service returned an unsupported URL scheme '
          '"${uri.scheme}".',
        );
      }
      return uri.toString();
    }
    return config.baseUri.resolveUri(uri).toString();
  }

  DateTime _dateOrNow(Object? raw) {
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.now().toUtc();
  }
}

/// The no-backend stand-in the app runs with when no endpoint is configured.
///
/// It is deliberately **not** a fake stitcher: it returns the first capture as
/// the "panorama" and marks the result `simulated`, so the screen can label it
/// rather than claim a 360° image was produced. Real stitching requires the
/// Python/OpenCV service.
class LocalVirtualTourRemoteDataSource implements VirtualTourRemoteDataSource {
  const LocalVirtualTourRemoteDataSource();

  @override
  Future<StitchedPanorama> stitchPanorama({
    required String tourId,
    required String propertyId,
    required String stationId,
    required List<PanoramaImage> images,
  }) async {
    if (images.isEmpty) {
      throw const VirtualTourFailure(
        'There are no photographs to stitch.',
        retryable: false,
      );
    }
    final first = File(images.first.filePath);
    if (!await first.exists()) {
      throw VirtualTourFailure(
        'The first photograph is missing from ${first.path}.',
        retryable: false,
      );
    }
    return StitchedPanorama(
      url: first.uri.toString(),
      stitchedAt: DateTime.now().toUtc(),
      simulated: true,
    );
  }

  @override
  Future<VirtualTourSubmission> submitForVerification({
    required String tourId,
    required List<StitchedPanorama> panoramas,
  }) async {
    if (panoramas.isEmpty) {
      throw const VirtualTourFailure(
        'There is no stitched panorama to submit.',
        retryable: false,
      );
    }
    return VirtualTourSubmission(
      tourId: tourId,
      status: 'pending_verification',
      verificationId: 'local-${DateTime.now().toUtc().millisecondsSinceEpoch}',
      submittedAt: DateTime.now().toUtc(),
      simulated: true,
    );
  }

  @override
  Future<void> dispose() async {}
}
