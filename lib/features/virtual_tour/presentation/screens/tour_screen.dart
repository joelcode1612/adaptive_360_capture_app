import 'dart:io';
import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/tour_viewpoint.dart';

/// Interactive 360° viewer for an equirectangular panorama.
///
/// Accepts either a network URL (stitched result from the backend) or a
/// local file (preview / offline). Renders on a 3D sphere — never as a flat
/// image. Hotspots navigate between multiple viewpoints when provided.
class TourScreen extends StatefulWidget {
  final String? panoramaUrl;
  final String? panoramaFilePath;
  final List<TourViewpoint>? viewpoints;
  final int initialViewpoint;

  const TourScreen({
    super.key,
    this.panoramaUrl,
    this.panoramaFilePath,
    this.viewpoints,
    this.initialViewpoint = 0,
  }) : assert(
         panoramaUrl != null || panoramaFilePath != null || viewpoints != null,
       );

  @override
  State<TourScreen> createState() => _TourScreenState();
}

// `TourViewpoint` now lives in `flow/tour_viewpoint.dart`, so the flow can build
// the stops and this screen can render them without either one importing the
// other's dependencies. See that file for why it is pure Dart.

class _TourScreenState extends State<TourScreen> {
  late int _current;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _current = widget.initialViewpoint;
  }

  TourViewpoint get _view {
    if (widget.viewpoints != null && widget.viewpoints!.isNotEmpty) {
      return widget.viewpoints![_current.clamp(
        0,
        widget.viewpoints!.length - 1,
      )];
    }
    return TourViewpoint(
      id: 'single',
      imageUrl: widget.panoramaUrl,
      imagePath: widget.panoramaFilePath,
    );
  }

  ImageProvider _image() {
    final v = _view;
    if (v.imagePath != null) return FileImage(File(v.imagePath!));
    return NetworkImage(v.imageUrl!);
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    final hasMulti = (widget.viewpoints?.length ?? 1) > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          hasMulti
              ? 'Tour — ${_view.id} (${_current + 1}/${widget.viewpoints!.length})'
              : 'Virtual tour',
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          PanoramaViewer(
            animSpeed: 0.5,
            sensorControl: SensorControl.orientation,
            onImageLoad: () => setState(() => _loading = false),
            hotspots: [
              for (final entry in v.links.entries)
                Hotspot(
                  latitude: 0,
                  longitude: 90,
                  width: 90,
                  height: 90,
                  widget: TextButton(
                    onPressed: () {
                      final idx = widget.viewpoints!.indexWhere(
                        (e) => e.id == entry.value,
                      );
                      if (idx >= 0) {
                        setState(() {
                          _current = idx;
                          _loading = true;
                        });
                      }
                    },
                    child: Text(
                      '→ ${entry.key}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
            ],
            child: Image(image: _image()),
          ),
          if (_loading)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 8),
                  Text(
                    'Loading panorama…',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Center(
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          if (hasMulti)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _current > 0
                        ? () => setState(() {
                            _current--;
                            _loading = true;
                          })
                        : null,
                  ),
                  Text(
                    '${_current + 1} / ${widget.viewpoints!.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward, color: Colors.white),
                    onPressed: _current < widget.viewpoints!.length - 1
                        ? () => setState(() {
                            _current++;
                            _loading = true;
                          })
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
