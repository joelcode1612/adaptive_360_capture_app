import 'package:adaptive_360_capture_app/features/virtual_tour/application/flow_state.dart';

/// Where one station's stitched panorama lives.
///
/// Deliberately **not** a field on [StationRecord]. The capture flow never
/// produces a panorama — that is the backend's OpenCV pipeline, reached through
/// `infrastructure/backend/processing_client.dart` — so `flow/` must not model an
/// upload result it does not create. The app fills this in when the processing
/// service returns, and until then it stays empty and the viewer stays shut.
class PanoramaRef {
  /// A network URL, for a panorama the service stored remotely.
  final String? url;

  /// A local file, for an offline or preview panorama.
  final String? path;

  const PanoramaRef({this.url, this.path});

  const PanoramaRef.empty() : url = null, path = null;

  bool get isEmpty =>
      (url == null || url!.isEmpty) && (path == null || path!.isEmpty);
}

/// One stop in the 360° viewer.
///
/// Pure Dart, and moved out of `presentation/screens/tour_screen.dart` for
/// exactly that reason: that widget imports Flutter, so importing it from
/// `flow/` would drag a binding into the layer the whole test suite depends on
/// being pure. Nothing here needs a widget, a context or a binding.
class TourViewpoint {
  final String id;
  final String? imageUrl;
  final String? imagePath;

  /// Hotspot label → the id of the viewpoint it navigates to.
  final Map<String, String> links;

  const TourViewpoint({
    required this.id,
    this.imageUrl,
    this.imagePath,
    this.links = const <String, String>{},
  });
}

/// Builds the viewer's stops from the accepted stations.
///
/// **Only stations that actually have a panorama become stops.** `TourScreen`
/// renders an equirectangular sphere and dereferences `imageUrl ?? imagePath`, so
/// a station with neither would be a crash rather than an empty state. A station
/// still waiting on the stitch is simply absent — which is why the caller must
/// check for empty before navigating rather than assuming the list matches the
/// accepted stations one-for-one.
///
/// The stops are linked in a ring so the viewer can walk the tour in order and
/// come back to the start. With one stop there is nothing to link to.
List<TourViewpoint> buildTourViewpoints(
  List<StationRecord> stations, {
  required PanoramaRef Function(StationRecord) panoramaFor,
}) {
  final kept = <StationRecord>[
    for (final s in stations)
      if (!panoramaFor(s).isEmpty) s,
  ];

  TourViewpoint stop(StationRecord s, Map<String, String> links) =>
      TourViewpoint(
        id: s.displayName,
        imageUrl: panoramaFor(s).url,
        imagePath: panoramaFor(s).path,
        links: links,
      );

  if (kept.length < 2) {
    return <TourViewpoint>[
      for (final s in kept) stop(s, const <String, String>{}),
    ];
  }
  return <TourViewpoint>[
    for (var i = 0; i < kept.length; i++)
      stop(kept[i], <String, String>{
        kept[(i + 1) % kept.length].displayName:
            kept[(i + 1) % kept.length].displayName,
      }),
  ];
}
