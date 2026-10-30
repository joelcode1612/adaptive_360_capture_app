/// A real glTF 2.0 **binary** (`.glb`) reader that returns renderable geometry.
///
/// Pure Dart on purpose: no `dart:ui`, no Flutter, no `vector_math`. That keeps
/// the parser runnable under a plain `dart` invocation, so the two shipped
/// capture models are verified against the dimensions recorded in
/// `ar_target_model.dart` on the host rather than on a device
/// (`test/glb_checks.dart`).
///
/// What it reads: the 12-byte header, the `JSON`/`BIN` chunk loop, `buffers` /
/// `bufferViews` / `accessors` (non-zero `byteOffset`, interleaved `byteStride`,
/// the `normalized` flag, every integer component type), `POSITION` / `NORMAL` /
/// `COLOR_0` / `TEXCOORD_0` attributes, `u8`/`u16`/`u32` indices, the default
/// scene's node graph with either a `matrix` or a translation/rotation/scale
/// transform per node, and each material's `baseColorFactor` / `doubleSided` /
/// `alphaMode`.
///
/// What it deliberately does not: images and texture samplers, glTF materials
/// beyond a base colour factor, morph targets, skins and animation, sparse
/// accessors, Draco/Meshopt compression, and `POINTS`/`LINES` primitive modes.
/// Anything skipped is recorded in [GlbModel.unsupported] rather than silently
/// dropped, and anything malformed raises [GlbParseException] — never a
/// `RangeError`, never garbage.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Thrown for every way a `.glb` can fail to parse.
///
/// The message is written to be shown to a user as-is: "handle loading failures"
/// means the reason reaches the UI, not that the app dies on a range error or
/// paints an empty box.
class GlbParseException implements Exception {
  final String message;

  /// Which asset the failure came from, when the path is known.
  final String? source;

  const GlbParseException(this.message, {this.source});

  GlbParseException inSource(String path) =>
      GlbParseException(message, source: source ?? path);

  @override
  String toString() =>
      'GlbParseException${source == null ? '' : ' ($source)'}: $message';
}

/// An RGBA colour with every channel in `0..1`, framework-free.
///
/// The overlay converts it to a `dart:ui` `Color` at paint time; keeping it out
/// of the parser and the renderer is what lets both run in a bare Dart VM.
class GlbColor {
  final double r;
  final double g;
  final double b;
  final double a;

  const GlbColor(this.r, this.g, this.b, [this.a = 1.0]);

  /// glTF's own default: opaque white.
  static const GlbColor white = GlbColor(1, 1, 1, 1);

  /// From glTF `baseColorFactor` components.
  factory GlbColor.fromFactor(List<double> f) => GlbColor(
    _unit(f[0]),
    _unit(f[1]),
    _unit(f[2]),
    f.length > 3 ? _unit(f[3]) : 1.0,
  );

  /// From an 8-bit RGB triple in 0..255, i.e. [ArTargetColors]' hex bytes.
  factory GlbColor.fromRgb24(List<int> rgb, [double alpha = 1.0]) => GlbColor(
    _unit(rgb[0] / 255.0),
    _unit(rgb[1] / 255.0),
    _unit(rgb[2] / 255.0),
    _unit(alpha),
  );

  GlbColor withAlpha(double newAlpha) => GlbColor(r, g, b, _unit(newAlpha));

  /// Multiplied by a flat-shade factor in `0..1`; alpha is untouched.
  GlbColor shaded(double factor) =>
      GlbColor(_unit(r * factor), _unit(g * factor), _unit(b * factor), a);

  /// `0xAARRGGBB`, the layout `dart:ui`'s `Color.fromValue` expects.
  int toArgb() {
    int channel(double v) => (v * 255.0 + 0.5).floor().clamp(0, 255);
    return (channel(a) << 24) |
        (channel(r) << 16) |
        (channel(g) << 8) |
        channel(b);
  }

  /// Value equality: the colour is a record of four numbers, and callers build
  /// fresh ones from `baseColorFactor` and from the state-tint getters, so two
  /// identical colours arriving by different routes must compare equal.
  @override
  bool operator ==(Object other) =>
      other is GlbColor &&
      other.r == r &&
      other.g == g &&
      other.b == b &&
      other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() =>
      'GlbColor(${r.toStringAsFixed(3)}, ${g.toStringAsFixed(3)}, '
      '${b.toStringAsFixed(3)}, ${a.toStringAsFixed(3)})';
}

double _unit(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

/// A glTF node transform, always resolved to a column-major 4×4 matrix.
///
/// glTF stores `matrix` column-major (`m[column * 4 + row]`) and a node with a
/// `matrix` ignores `translation`/`rotation`/`scale`, so both forms land in one
/// representation here and the renderer applies exactly one thing per part.
class GlbTransform {
  final Float64List m;

  GlbTransform._(this.m);

  static final Float64List _identityValues = Float64List.fromList(<double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1, //
  ]);

  static GlbTransform get identity =>
      GlbTransform._(Float64List.fromList(_identityValues));

  /// `T · R · S`, the glTF TRS form. Columns are the rotated, scaled canonical
  /// axes, which is exactly what [Quat.rotate] returns.
  factory GlbTransform.trs({
    Vec3 translation = Vec3.zero,
    Quat rotation = Quat.identity,
    Vec3 scale = const Vec3(1, 1, 1),
  }) {
    final x = rotation.rotate(Vec3.unitX) * scale.x;
    final y = rotation.rotate(Vec3.unitY) * scale.y;
    final z = rotation.rotate(Vec3.unitZ) * scale.z;
    return GlbTransform._(
      Float64List.fromList(<double>[
        x.x, x.y, x.z, 0, //
        y.x, y.y, y.z, 0, //
        z.x, z.y, z.z, 0, //
        translation.x, translation.y, translation.z, 1, //
      ]),
    );
  }

  /// From a glTF `matrix` (16 entries, column-major).
  factory GlbTransform.fromMatrix(List<double> raw) {
    final out = Float64List(16);
    for (var i = 0; i < 16; i++) {
      final v = raw[i];
      if (!v.isFinite) {
        throw const GlbParseException(
          'node matrix contains a non-finite value',
        );
      }
      out[i] = v;
    }
    return GlbTransform._(out);
  }

  /// `this · child` — apply [child] first, then `this`. Used to push a parent's
  /// scene-graph transform down into a child node.
  GlbTransform then(GlbTransform child) {
    final out = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += m[k * 4 + r] * child.m[c * 4 + k];
        }
        out[c * 4 + r] = sum;
      }
    }
    return GlbTransform._(out);
  }

  Vec3 apply(Vec3 p) {
    final i = m;
    return Vec3(
      i[0] * p.x + i[4] * p.y + i[8] * p.z + i[12],
      i[1] * p.x + i[5] * p.y + i[9] * p.z + i[13],
      i[2] * p.x + i[6] * p.y + i[10] * p.z + i[14],
    );
  }

  Vec3 get translation => Vec3(m[12], m[13], m[14]);

  Vec3 get scale => Vec3(
    math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]),
    math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]),
    math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]),
  );

  /// The rotational part. A zero-length column (scale 0) has no orientation, so
  /// that case yields the identity instead of NaN.
  Quat get rotation {
    final s = scale;
    if (s.x == 0 || s.y == 0 || s.z == 0) return Quat.identity;
    return Quat.fromMatrix3(<double>[
      m[0] / s.x, m[4] / s.y, m[8] / s.z, //
      m[1] / s.x, m[5] / s.y, m[9] / s.z, //
      m[2] / s.x, m[6] / s.y, m[10] / s.z, //
    ]);
  }

  bool get isIdentity {
    for (var i = 0; i < 16; i++) {
      if ((m[i] - _identityValues[i]).abs() > 1e-12) return false;
    }
    return true;
  }
}

/// One renderable part of a [GlbModel]: an expanded triangle soup plus the
/// scene-graph transform that puts it in the model's own space.
///
/// Vertices are non-indexed (every three entries form one triangle) because
/// that is what the rasteriser consumes; per-vertex attributes were
/// index-resolved at parse time so they line up with [positions].
class GlbDrawable {
  final List<Vec3> positions;

  /// Empty when the asset has no `NORMAL`; otherwise 3 per vertex.
  final List<Vec3> normals;

  /// Empty when there is no `TEXCOORD_0`; otherwise 2 floats per vertex.
  final Float32List uv0;

  /// Empty when there is no `COLOR_0`; otherwise one colour per vertex.
  final List<GlbColor> vertexColors;

  /// The primitive's material base colour (white when the asset has none).
  final GlbColor color;

  /// `material.doubleSided`; false when there is no material (glTF default).
  final bool doubleSided;

  /// `material.alphaMode`: `OPAQUE`, `MASK` or `BLEND`.
  final String alphaMode;

  /// This part's node transform, composed with its ancestors.
  final GlbTransform transform;

  final int meshIndex;
  final int primitiveIndex;

  /// The node's `name` when the asset has one. The shipped capture models are
  /// anonymous, so the overlay keys on [meshIndex] instead.
  final String? nodeName;

  /// Axis-aligned bounds **after** [transform], i.e. in the model's own space.
  final Vec3 min;
  final Vec3 max;

  const GlbDrawable({
    required this.positions,
    required this.normals,
    required this.uv0,
    required this.vertexColors,
    required this.color,
    required this.doubleSided,
    required this.alphaMode,
    required this.transform,
    required this.meshIndex,
    required this.primitiveIndex,
    required this.nodeName,
    required this.min,
    required this.max,
  });

  int get triangleCount => positions.length ~/ 3;
  int get vertexCount => positions.length;

  double get widthX => max.x - min.x;
  double get heightY => max.y - min.y;
  double get depthZ => max.z - min.z;
  Vec3 get center =>
      Vec3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2);

  @override
  String toString() =>
      'GlbDrawable(mesh $meshIndex/prim $primitiveIndex, $triangleCount tris, '
      'bounds ${widthX.toStringAsFixed(4)}x${heightY.toStringAsFixed(4)}x'
      '${depthZ.toStringAsFixed(4)})';
}

/// A parsed `.glb`: the parts to draw, their common bounds, and the diagnostics
/// for anything in the file that was not rendered.
class GlbModel {
  final List<GlbDrawable> drawables;

  /// Bounds over all drawables, in the model's own space — metres for the
  /// capture assets, which author 1 unit = 1 m.
  final Vec3 min;
  final Vec3 max;

  /// Counts read straight from the JSON chunk: the difference between "this
  /// decoded the file" and "this guessed one triangle out of the bytes".
  final int nodeCount;
  final int meshCount;
  final int materialCount;
  final int accessorCount;
  final int bufferViewCount;

  /// glTF features present in the file but not rendered. Non-empty is a warning
  /// rather than an error; the overlay surfaces it when it shows a failure.
  final List<String> unsupported;

  /// `asset.version`, verified to be `2.0` by the parser.
  final String gltfVersion;

  /// `asset.generator`, when present — useful when an asset misbehaves.
  final String? generator;

  const GlbModel({
    required this.drawables,
    required this.min,
    required this.max,
    required this.nodeCount,
    required this.meshCount,
    required this.materialCount,
    required this.accessorCount,
    required this.bufferViewCount,
    required this.unsupported,
    required this.gltfVersion,
    required this.generator,
  });

  int get triangleCount =>
      drawables.fold<int>(0, (int s, GlbDrawable d) => s + d.triangleCount);
  int get vertexCount =>
      drawables.fold<int>(0, (int s, GlbDrawable d) => s + d.vertexCount);

  double get widthX => max.x - min.x;
  double get heightY => max.y - min.y;
  double get depthZ => max.z - min.z;
  Vec3 get center =>
      Vec3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2);

  @override
  String toString() =>
      'GlbModel(${drawables.length} parts, $triangleCount tris, '
      '${widthX.toStringAsFixed(4)}x${heightY.toStringAsFixed(4)}x'
      '${depthZ.toStringAsFixed(4)})';
}

const int _glbMagic = 0x46546C67; // 'glTF' read little-endian
const int _glbVersion = 2;
const int _jsonChunkType = 0x4E4F534A; // 'JSON'
const int _binChunkType = 0x004E4942; // 'BIN\0'

const int _modePoints = 0;
const int _modeLines = 1;
const int _modeLineLoop = 2;
const int _modeLineStrip = 3;
const int _modeTriangles = 4;

const int _ctByte = 5120;
const int _ctUbyte = 5121;
const int _ctShort = 5122;
const int _ctUshort = 5123;
const int _ctInt = 5124;
const int _ctUint = 5125;
const int _ctFloat = 5126;

/// Parses a complete `.glb` file.
///
/// [source] only labels errors, e.g. the asset path the bytes came from.
/// Throws [GlbParseException] for a malformed or unsupported container.
GlbModel parseGlb(Uint8List bytes, {String? source}) =>
    _GlbReader(bytes, source).read();

/// One accessor's slice of one buffer, ready to step through.
class _Window {
  final ByteData data;
  final int start;
  final int stride;
  final int count;
  final int components;
  final int componentType;
  final int componentSize;
  final bool normalized;

  const _Window({
    required this.data,
    required this.start,
    required this.stride,
    required this.count,
    required this.components,
    required this.componentType,
    required this.componentSize,
    required this.normalized,
  });

  double readAt(int element, int component) {
    final offset = start + element * stride + component * componentSize;
    final raw = switch (componentType) {
      _ctFloat => data.getFloat32(offset, Endian.little),
      _ctByte => data.getInt8(offset).toDouble(),
      _ctUbyte => data.getUint8(offset).toDouble(),
      _ctShort => data.getInt16(offset, Endian.little).toDouble(),
      _ctUshort => data.getUint16(offset, Endian.little).toDouble(),
      _ctInt => data.getInt32(offset, Endian.little).toDouble(),
      _ => data.getUint32(offset, Endian.little).toDouble(),
    };
    if (!normalized || componentType == _ctFloat) return raw;
    final max = switch (componentType) {
      _ctByte || _ctShort => 32767.0,
      _ctUbyte => 255.0,
      _ctUshort => 65535.0,
      _ => 2147483647.0,
    };
    return raw / max;
  }
}

class _GlbReader {
  final Uint8List _bytes;
  final String? _source;
  final ByteData _view;

  Map<String, dynamic> _json = const <String, dynamic>{};
  Uint8List? _binChunk;
  final List<ByteData> _buffers = <ByteData>[];
  final List<String> _unsupported = <String>[];

  _GlbReader(this._bytes, this._source) : _view = ByteData.sublistView(_bytes);

  GlbParseException _fail(String message) =>
      GlbParseException(message, source: _source);

  GlbModel read() {
    if (_bytes.lengthInBytes < 12) {
      throw _fail(
        'file is ${_bytes.lengthInBytes} bytes, too short to hold a 12-byte '
        'GLB header',
      );
    }
    final magic = _view.getUint32(0, Endian.little);
    if (magic != _glbMagic) {
      throw _fail(
        'magic header is 0x${magic.toRadixString(16)}, not 0x46546c67 ("glTF") '
        '— this is not a GLB file',
      );
    }
    final version = _view.getUint32(4, Endian.little);
    if (version != _glbVersion) {
      throw _fail('container version $version is not glTF 2');
    }
    final declared = _view.getUint32(8, Endian.little);
    if (declared > _bytes.lengthInBytes) {
      throw _fail(
        'header declares $declared bytes but only ${_bytes.lengthInBytes} are '
        'present — the asset is truncated',
      );
    }
    if (declared < _bytes.lengthInBytes) {
      throw _fail(
        'header declares $declared bytes but the file is '
        '${_bytes.lengthInBytes} — trailing bytes after the last chunk',
      );
    }

    _readChunks();
    final asset = _requireMap(_json['asset'], 'asset');
    final assetVersion = _requireString(asset['version'], 'asset.version');
    if (assetVersion != '2.0') {
      throw _fail('asset.version "$assetVersion" is not "2.0"');
    }

    _resolveBuffers();
    final drawables = _buildDrawables();
    if (drawables.isEmpty) {
      throw _fail('the default scene holds no renderable TRIANGLES primitive');
    }

    var lo = Vec3(double.infinity, double.infinity, double.infinity);
    var hi = Vec3(-double.infinity, -double.infinity, -double.infinity);
    for (final d in drawables) {
      lo = _vecMin(lo, d.min);
      hi = _vecMax(hi, d.max);
    }

    return GlbModel(
      drawables: drawables,
      min: lo,
      max: hi,
      nodeCount: _list('nodes').length,
      meshCount: _list('meshes').length,
      materialCount: _list('materials').length,
      accessorCount: _list('accessors').length,
      bufferViewCount: _list('bufferViews').length,
      unsupported: List<String>.unmodifiable(_unsupported),
      gltfVersion: assetVersion,
      generator: asset['generator'] is String
          ? asset['generator'] as String
          : null,
    );
  }

  static Vec3 _vecMin(Vec3 a, Vec3 b) =>
      Vec3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z));
  static Vec3 _vecMax(Vec3 a, Vec3 b) =>
      Vec3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z));

  // ── container ───────────────────────────────────────────────────────────

  void _readChunks() {
    var offset = 12;
    Map<String, dynamic>? json;
    Uint8List? bin;
    while (offset + 8 <= _bytes.lengthInBytes) {
      final length = _view.getUint32(offset, Endian.little);
      final type = _view.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      if (start + length > _bytes.lengthInBytes) {
        throw _fail(
          'chunk at $offset declares $length bytes but only '
          '${_bytes.lengthInBytes - start} remain — the asset is truncated',
        );
      }
      if (length % 4 != 0) {
        throw _fail(
          'chunk at $offset has length $length, not a multiple of 4 as the GLB '
          'container requires',
        );
      }
      if (offset == 12 && type != _jsonChunkType) {
        throw _fail('the first chunk must be the JSON chunk');
      }
      if (type == _jsonChunkType) {
        if (json != null) throw _fail('more than one JSON chunk');
        json = _decodeJson(start, length);
      } else if (type == _binChunkType) {
        if (bin != null) throw _fail('more than one BIN chunk');
        bin = Uint8List.sublistView(_bytes, start, start + length);
      } else {
        _unsupported.add('skipped chunk "${_chunkName(type)}"');
      }
      offset = start + length;
    }
    if (json == null) throw _fail('no JSON chunk');
    _json = json;
    _binChunk = bin;
  }

  Map<String, dynamic> _decodeJson(int start, int length) {
    final String text;
    try {
      text = utf8.decode(
        _bytes.sublist(start, start + length),
        allowMalformed: false,
      );
    } on FormatException catch (e) {
      throw _fail('JSON chunk is not valid UTF-8: ${e.message}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw _fail('JSON chunk is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw _fail('JSON chunk is not a glTF object');
    }
    return decoded;
  }

  static String _chunkName(int type) {
    final codes = <int>[
      (type >> 24) & 0xFF,
      (type >> 16) & 0xFF,
      (type >> 8) & 0xFF,
      type & 0xFF,
    ];
    return codes.every((int b) => b >= 0x20 && b < 0x7F)
        ? String.fromCharCodes(codes)
        : '0x${type.toRadixString(16)}';
  }

  void _resolveBuffers() {
    final buffers = _list('buffers');
    if (buffers.isEmpty) {
      throw _fail('no buffers declared — there is no geometry');
    }
    for (var i = 0; i < buffers.length; i++) {
      final b = _requireMap(buffers[i], 'buffers[$i]');
      final byteLength = _requireInt(b['byteLength'], 'buffers[$i].byteLength');
      final uri = b['uri'];
      if (uri == null) {
        if (i != 0) {
          throw _fail(
            'buffers[$i] has no uri; only buffer 0 may read the BIN chunk',
          );
        }
        final bin = _binChunk;
        if (bin == null) {
          throw _fail(
            'buffer 0 reads the BIN chunk but the container has none',
          );
        }
        if (bin.lengthInBytes < byteLength) {
          throw _fail(
            'BIN chunk holds ${bin.lengthInBytes} bytes but buffer 0 declares '
            '$byteLength',
          );
        }
        _buffers.add(ByteData.sublistView(bin, 0, byteLength));
        continue;
      }
      if (uri is! String) throw _fail('buffers[$i].uri is not a string');
      if (!uri.startsWith('data:')) {
        throw _fail(
          'buffers[$i].uri "$uri" points at an external file, which a GLB '
          'inside an asset bundle cannot resolve',
        );
      }
      _buffers.add(ByteData.sublistView(_decodeDataUri(uri, i, byteLength)));
    }
  }

  Uint8List _decodeDataUri(String uri, int index, int expected) {
    final comma = uri.indexOf(',');
    if (comma < 0) {
      throw _fail('buffers[$index].uri is a data: URI with no payload');
    }
    if (!uri.substring(0, comma).contains('base64')) {
      throw _fail(
        'buffers[$index].uri uses a percent-encoded data: URI; only base64 is '
        'supported',
      );
    }
    final Uint8List data;
    try {
      data = base64Decode(uri.substring(comma + 1));
    } on FormatException catch (e) {
      throw _fail('buffers[$index].uri is not valid base64: ${e.message}');
    }
    if (data.lengthInBytes < expected) {
      throw _fail(
        'buffers[$index].uri holds ${data.lengthInBytes} bytes but $expected '
        'were declared',
      );
    }
    return data;
  }

  // ── JSON plumbing ───────────────────────────────────────────────────────

  List<dynamic> _list(String key) {
    final v = _json[key];
    if (v == null) return const <dynamic>[];
    if (v is! List<dynamic>) throw _fail('"$key" is not an array');
    return v;
  }

  Map<String, dynamic> _requireMap(Object? v, String what) {
    if (v is! Map<String, dynamic>) {
      throw _fail('$what is missing or is not an object');
    }
    return v;
  }

  int _requireInt(Object? v, String what) {
    if (v is! num) throw _fail('$what is not a number');
    if (v is double && v != v.roundToDouble()) {
      throw _fail('$what is $v, not an integer');
    }
    return v.toInt();
  }

  int? _optionalInt(Object? v, String what) =>
      v == null ? null : _requireInt(v, what);

  String _requireString(Object? v, String what) {
    if (v is! String) throw _fail('$what is not a string');
    return v;
  }

  List<double> _numberList(Object? v, String what, int? exactLength) {
    if (v is! List<dynamic>) throw _fail('$what is not an array');
    if (exactLength != null && v.length != exactLength) {
      throw _fail('$what has ${v.length} components, expected $exactLength');
    }
    final out = <double>[];
    for (final e in v) {
      if (e is! num) throw _fail('$what contains a non-number');
      out.add(e.toDouble());
    }
    return out;
  }

  // ── scene graph and geometry ────────────────────────────────────────────

  List<GlbDrawable> _buildDrawables() {
    final materials = _readMaterials();
    final nodes = _list('nodes');
    final meshes = _list('meshes');
    if (nodes.isEmpty) {
      throw _fail('the asset declares no nodes, so nothing can be placed');
    }
    final out = <GlbDrawable>[];

    for (final placed in _sceneNodes(nodes)) {
      final node = _requireMap(nodes[placed.key], 'nodes[${placed.key}]');
      final meshIndex = _optionalInt(node['mesh'], 'nodes[${placed.key}].mesh');
      if (meshIndex == null) continue; // a group or camera node
      if (node['skin'] != null) {
        _unsupported.add(
          'nodes[${placed.key}] is skinned — the bind pose is drawn, without '
          'animation',
        );
      }
      if (meshIndex < 0 || meshIndex >= meshes.length) {
        throw _fail(
          'nodes[${placed.key}] references mesh $meshIndex, outside '
          '0..${meshes.length - 1}',
        );
      }
      final mesh = _requireMap(meshes[meshIndex], 'meshes[$meshIndex]');
      if (mesh['weights'] != null) {
        _unsupported.add(
          'meshes[$meshIndex] has morph targets — only the base mesh is drawn',
        );
      }
      final prims = mesh['primitives'];
      if (prims is! List<dynamic> || prims.isEmpty) {
        throw _fail('meshes[$meshIndex] has no primitives');
      }
      final nodeName = node['name'] is String ? node['name'] as String : null;
      for (var p = 0; p < prims.length; p++) {
        final prim = _requireMap(prims[p], 'meshes[$meshIndex].primitives[$p]');
        final drawable = _readPrimitive(
          prim: prim,
          meshIndex: meshIndex,
          primitiveIndex: p,
          transform: placed.value,
          nodeName: nodeName,
          materials: materials,
        );
        if (drawable != null) out.add(drawable);
      }
    }
    return out;
  }

  /// The default scene's nodes, each paired with its scene→node transform.
  ///
  /// glTF lets one node be shared by several parents, which is legal and is
  /// emitted once per path; a node appearing twice on the *same* path is a
  /// cycle and is rejected.
  List<MapEntry<int, GlbTransform>> _sceneNodes(List<dynamic> nodes) {
    final result = <MapEntry<int, GlbTransform>>[];
    final parented = List<bool>.filled(nodes.length, false);

    void walk(int index, GlbTransform fromParent, Set<int> path) {
      if (!path.add(index)) {
        throw _fail(
          'node $index appears twice on one path — the node graph is cyclic',
        );
      }
      final node = _requireMap(nodes[index], 'nodes[$index]');
      // The node's own transform applies to it as well as to its children: a
      // root mesh node carrying a `matrix` is placed by that matrix, and
      // dropping it here would draw the mesh at the origin.
      final accumulated = fromParent.then(_nodeTransform(node, index));
      result.add(MapEntry<int, GlbTransform>(index, accumulated));
      final children = node['children'];
      if (children != null) {
        if (children is! List<dynamic>) {
          throw _fail('nodes[$index].children is not an array');
        }
        for (final c in children) {
          final childIndex = _requireInt(c, 'nodes[$index].children entry');
          if (childIndex < 0 || childIndex >= nodes.length) {
            throw _fail(
              'nodes[$index] references child $childIndex, outside '
              '0..${nodes.length - 1}',
            );
          }
          parented[childIndex] = true;
          walk(childIndex, accumulated, <int>{...path});
        }
      }
    }

    final scenes = _list('scenes');
    if (scenes.isNotEmpty) {
      final sceneIndex = _json['scene'] == null
          ? 0
          : _requireInt(_json['scene'], 'scene');
      if (sceneIndex < 0 || sceneIndex >= scenes.length) {
        throw _fail('scene $sceneIndex is outside 0..${scenes.length - 1}');
      }
      final scene = _requireMap(scenes[sceneIndex], 'scenes[$sceneIndex]');
      final roots = scene['nodes'];
      if (roots is! List<dynamic>) {
        throw _fail('scenes[$sceneIndex].nodes is missing or not an array');
      }
      for (final r in roots) {
        final i = _requireInt(r, 'scenes[$sceneIndex].nodes entry');
        if (i < 0 || i >= nodes.length) {
          throw _fail(
            'scene $sceneIndex references node $i, outside '
            '0..${nodes.length - 1}',
          );
        }
        walk(i, GlbTransform.identity, <int>{});
      }
      return result;
    }

    // No scene table: every node nobody parents is a root.
    for (var i = 0; i < nodes.length; i++) {
      final node = _requireMap(nodes[i], 'nodes[$i]');
      final children = node['children'];
      if (children is List<dynamic>) {
        for (final c in children) {
          final ci = _requireInt(c, 'nodes[$i].children entry');
          if (ci >= 0 && ci < nodes.length) parented[ci] = true;
        }
      }
    }
    for (var i = 0; i < nodes.length; i++) {
      if (!parented[i]) walk(i, GlbTransform.identity, <int>{});
    }
    return result;
  }

  GlbTransform _nodeTransform(Map<String, dynamic> node, int index) {
    final matrix = node['matrix'];
    if (matrix != null) {
      return GlbTransform.fromMatrix(
        _numberList(matrix, 'nodes[$index].matrix', 16),
      );
    }
    final translation = node['translation'] == null
        ? Vec3.zero
        : Vec3.fromList(
            _numberList(node['translation'], 'nodes[$index].translation', 3),
          );
    final scale = node['scale'] == null
        ? const Vec3(1, 1, 1)
        : Vec3.fromList(_numberList(node['scale'], 'nodes[$index].scale', 3));
    var rotation = Quat.identity;
    if (node['rotation'] != null) {
      final r = _numberList(node['rotation'], 'nodes[$index].rotation', 4);
      rotation = Quat(r[0], r[1], r[2], r[3]).normalized;
    }
    return GlbTransform.trs(
      translation: translation,
      rotation: rotation,
      scale: scale,
    );
  }

  List<GlbColor> _readMaterials() {
    final materials = _list('materials');
    final out = <GlbColor>[];
    for (var i = 0; i < materials.length; i++) {
      final m = _requireMap(materials[i], 'materials[$i]');
      final pbr = m['pbrMetallicRoughness'];
      if (pbr is Map<String, dynamic> && pbr['baseColorTexture'] != null) {
        _unsupported.add(
          'materials[$i] has a baseColorTexture — the flat base colour is used '
          'instead',
        );
      }
      if (m['emissiveTexture'] != null) {
        _unsupported.add('materials[$i] has an emissiveTexture — ignored');
      }
      final factor = pbr is Map<String, dynamic>
          ? pbr['baseColorFactor']
          : null;
      if (factor == null) {
        out.add(GlbColor.white);
        continue;
      }
      final f = _numberList(factor, 'materials[$i].baseColorFactor', null);
      if (f.length < 3) {
        throw _fail(
          'materials[$i].baseColorFactor has ${f.length} components, expected '
          '3 or 4',
        );
      }
      out.add(GlbColor.fromFactor(f));
    }
    return out;
  }

  GlbDrawable? _readPrimitive({
    required Map<String, dynamic> prim,
    required int meshIndex,
    required int primitiveIndex,
    required GlbTransform transform,
    required String? nodeName,
    required List<GlbColor> materials,
  }) {
    final where = 'meshes[$meshIndex].primitives[$primitiveIndex]';
    final mode = _optionalInt(prim['mode'], '$where.mode') ?? _modeTriangles;
    if (mode != _modeTriangles) {
      _unsupported.add(
        '$where uses mode ${_modeName(mode)} — only TRIANGLES can be rasterised',
      );
      return null;
    }
    final attributes = _requireMap(prim['attributes'], '$where.attributes');
    final positionIndex = _optionalInt(
      attributes['POSITION'],
      '$where.attributes.POSITION',
    );
    if (positionIndex == null) {
      throw _fail('$where has no POSITION attribute and cannot be drawn');
    }
    for (final key in attributes.keys) {
      if (key != 'POSITION' &&
          key != 'NORMAL' &&
          key != 'COLOR_0' &&
          key != 'TEXCOORD_0') {
        _unsupported.add(
          '$where has attribute "$key" — the renderer ignores it',
        );
      }
    }

    final positions = _readVec3(positionIndex, 'POSITION of $where');
    final normalIndex = _optionalInt(
      attributes['NORMAL'],
      '$where.attributes.NORMAL',
    );
    final normals = normalIndex == null
        ? const <Vec3>[]
        : _readVec3(normalIndex, 'NORMAL of $where');
    final uvIndex = _optionalInt(
      attributes['TEXCOORD_0'],
      '$where.attributes.TEXCOORD_0',
    );
    final uv0 = uvIndex == null
        ? Float32List(0)
        : _readVec2(uvIndex, 'TEXCOORD_0 of $where');
    final colorIndex = _optionalInt(
      attributes['COLOR_0'],
      '$where.attributes.COLOR_0',
    );
    final vertexColors = colorIndex == null
        ? const <GlbColor>[]
        : _readColors(colorIndex, 'COLOR_0 of $where');

    final indexList = prim['indices'] == null
        ? null
        : _readIndices(
            _requireInt(prim['indices'], '$where.indices'),
            positions.length,
            where,
          );

    // glTF requires every attribute of a primitive to describe the same number
    // of vertices; an asset that does not is corrupt, not merely odd.
    if (normals.isNotEmpty && normals.length != positions.length) {
      throw _fail(
        '$where has ${normals.length} normals for ${positions.length} positions',
      );
    }
    if (uv0.isNotEmpty && uv0.length ~/ 2 != positions.length) {
      throw _fail(
        '$where has ${uv0.length ~/ 2} texture coordinates for '
        '${positions.length} positions',
      );
    }
    if (vertexColors.isNotEmpty && vertexColors.length != positions.length) {
      throw _fail(
        '$where has ${vertexColors.length} vertex colours for '
        '${positions.length} positions',
      );
    }

    final expanded = _expandVec3(positions, indexList, where);
    if (expanded.isEmpty) throw _fail('$where yields no triangles');

    var color = GlbColor.white;
    var doubleSided = false;
    var alphaMode = 'OPAQUE';
    final materialIndex = _optionalInt(prim['material'], '$where.material');
    if (materialIndex != null) {
      if (materialIndex < 0 || materialIndex >= materials.length) {
        throw _fail(
          '$where references material $materialIndex, outside '
          '0..${materials.length - 1}',
        );
      }
      color = materials[materialIndex];
      final m = _requireMap(
        _list('materials')[materialIndex],
        'materials[$materialIndex]',
      );
      doubleSided = m['doubleSided'] == true;
      if (m['alphaMode'] != null) {
        alphaMode = _requireString(
          m['alphaMode'],
          'materials[$materialIndex].alphaMode',
        );
      }
    }

    var lo = Vec3(double.infinity, double.infinity, double.infinity);
    var hi = Vec3(-double.infinity, -double.infinity, -double.infinity);
    for (final p in expanded) {
      final w = transform.apply(p);
      lo = _vecMin(lo, w);
      hi = _vecMax(hi, w);
    }

    return GlbDrawable(
      positions: List<Vec3>.unmodifiable(expanded),
      normals: normals.isEmpty
          ? const <Vec3>[]
          : List<Vec3>.unmodifiable(_expandVec3(normals, indexList, where)),
      uv0: uv0.isEmpty ? Float32List(0) : _expandVec2(uv0, indexList, where),
      vertexColors: vertexColors.isEmpty
          ? const <GlbColor>[]
          : List<GlbColor>.unmodifiable(
              _expandColors(vertexColors, indexList, where),
            ),
      color: color,
      doubleSided: doubleSided,
      alphaMode: alphaMode,
      transform: transform,
      meshIndex: meshIndex,
      primitiveIndex: primitiveIndex,
      nodeName: nodeName,
      min: lo,
      max: hi,
    );
  }

  static String _modeName(int mode) => switch (mode) {
    _modePoints => 'POINTS',
    _modeLines => 'LINES',
    _modeLineLoop => 'LINE_LOOP',
    _modeLineStrip => 'LINE_STRIP',
    _modeTriangles => 'TRIANGLES',
    _ => '$mode',
  };

  // ── accessor reading ────────────────────────────────────────────────────

  _Window _window(
    int accessorIndex,
    String where, {
    String? expectType,
    bool requireFloat = false,
  }) {
    final accessors = _list('accessors');
    if (accessorIndex < 0 || accessorIndex >= accessors.length) {
      throw _fail(
        '$where references accessor $accessorIndex, outside '
        '0..${accessors.length - 1}',
      );
    }
    final acc = _requireMap(
      accessors[accessorIndex],
      'accessors[$accessorIndex]',
    );
    final type = _requireString(acc['type'], 'accessors[$accessorIndex].type');
    if (expectType != null && type != expectType) {
      throw _fail('$where is accessor type "$type", expected "$expectType"');
    }
    final componentType = _requireInt(
      acc['componentType'],
      'accessors[$accessorIndex].componentType',
    );
    final components = switch (type) {
      'SCALAR' => 1,
      'VEC2' => 2,
      'VEC3' => 3,
      'VEC4' => 4,
      'MAT3' => 9,
      'MAT4' => 16,
      _ => throw _fail(
        'accessors[$accessorIndex] has unsupported type "$type"',
      ),
    };
    final componentSize = switch (componentType) {
      _ctByte || _ctUbyte => 1,
      _ctShort || _ctUshort => 2,
      _ctInt || _ctUint || _ctFloat => 4,
      _ => throw _fail(
        'accessors[$accessorIndex].componentType $componentType is not a glTF '
        'component type',
      ),
    };
    if (requireFloat && componentType != _ctFloat) {
      throw _fail(
        '$where has componentType $componentType; float32 (5126) is required',
      );
    }
    final count = _requireInt(acc['count'], 'accessors[$accessorIndex].count');
    if (count <= 0) {
      throw _fail('accessors[$accessorIndex] declares count $count');
    }

    final bufferViewIndex = _optionalInt(
      acc['bufferView'],
      'accessors[$accessorIndex].bufferView',
    );
    if (bufferViewIndex == null) {
      throw _fail(
        'accessors[$accessorIndex] has no bufferView — sparse and constant '
        'accessors are not supported',
      );
    }
    final bufferViews = _list('bufferViews');
    if (bufferViewIndex < 0 || bufferViewIndex >= bufferViews.length) {
      throw _fail(
        'accessors[$accessorIndex] references bufferView $bufferViewIndex, '
        'outside 0..${bufferViews.length - 1}',
      );
    }
    final bv = _requireMap(
      bufferViews[bufferViewIndex],
      'bufferViews[$bufferViewIndex]',
    );
    final bufferIndex =
        _optionalInt(bv['buffer'], 'bufferViews[$bufferViewIndex].buffer') ?? 0;
    if (bufferIndex < 0 || bufferIndex >= _buffers.length) {
      throw _fail(
        'bufferViews[$bufferViewIndex] references buffer $bufferIndex, outside '
        '0..${_buffers.length - 1}',
      );
    }
    final buffer = _buffers[bufferIndex];
    final bvOffset =
        _optionalInt(
          bv['byteOffset'],
          'bufferViews[$bufferViewIndex].byteOffset',
        ) ??
        0;
    final bvLength = _requireInt(
      bv['byteLength'],
      'bufferViews[$bufferViewIndex].byteLength',
    );
    final accOffset =
        _optionalInt(
          acc['byteOffset'],
          'accessors[$accessorIndex].byteOffset',
        ) ??
        0;
    final elementSize = components * componentSize;
    // `byteStride` is only declared for interleaved vertex attributes. A dense
    // view — every index buffer, and most POSITION views — has none, so its
    // stride is the element size: 1 byte for uint8 indices, 2 for uint16. Those
    // are valid glTF, so the alignment rules below are applied to the *accessor
    // window*, not to an implicit stride.
    final declaredStride = _optionalInt(
      bv['byteStride'],
      'bufferViews[$bufferViewIndex].byteStride',
    );
    final stride = declaredStride ?? elementSize;
    if (stride < elementSize) {
      throw _fail(
        'bufferViews[$bufferViewIndex].byteStride $stride is smaller than one '
        '$elementSize-byte element',
      );
    }
    if (declaredStride != null && stride % componentSize != 0) {
      throw _fail(
        'bufferViews[$bufferViewIndex].byteStride $stride is not a multiple of '
        'the $componentSize-byte component type',
      );
    }
    // glTF requires the combined offset to land on a component boundary; the
    // buffer view and the accessor each contribute, so neither is checked alone.
    if ((bvOffset + accOffset) % componentSize != 0) {
      throw _fail(
        'accessors[$accessorIndex] starts at byte ${bvOffset + accOffset} of '
        'buffer $bufferIndex, which is not aligned to a $componentSize-byte '
        'component',
      );
    }
    if (bvOffset + bvLength > buffer.lengthInBytes) {
      throw _fail(
        'bufferViews[$bufferViewIndex] spans ${bvOffset + bvLength} bytes but '
        'buffer $bufferIndex only has ${buffer.lengthInBytes}',
      );
    }
    // `byteLength` is a whole number of elements only for non-interleaved
    // views, so it is not checked; the accessor window below bounds each read.
    final start = bvOffset + accOffset;
    final lastEnd = start + (count - 1) * stride + elementSize;
    if (lastEnd > bvOffset + bvLength) {
      throw _fail(
        'accessors[$accessorIndex] reads to byte $lastEnd, past the end of '
        'bufferView $bufferViewIndex (${bvOffset + bvLength}) — truncated '
        'geometry',
      );
    }
    return _Window(
      data: buffer,
      start: start,
      stride: stride,
      count: count,
      components: components,
      componentType: componentType,
      componentSize: componentSize,
      normalized: acc['normalized'] == true,
    );
  }

  Float64List _readElements(
    int accessorIndex,
    String where, {
    required String expectType,
  }) {
    final w = _window(
      accessorIndex,
      where,
      expectType: expectType,
      requireFloat: true,
    );
    final out = Float64List(w.count * w.components);
    var k = 0;
    for (var i = 0; i < w.count; i++) {
      for (var c = 0; c < w.components; c++) {
        out[k++] = w.readAt(i, c);
      }
    }
    return out;
  }

  List<Vec3> _readVec3(int accessorIndex, String where) {
    final raw = _readElements(accessorIndex, where, expectType: 'VEC3');
    return <Vec3>[
      for (var i = 0; i < raw.length; i += 3)
        Vec3(raw[i], raw[i + 1], raw[i + 2]),
    ];
  }

  Float32List _readVec2(int accessorIndex, String where) {
    final raw = _readElements(accessorIndex, where, expectType: 'VEC2');
    return Float32List.fromList(raw);
  }

  List<GlbColor> _readColors(int accessorIndex, String where) {
    final w = _window(accessorIndex, where);
    if (w.components != 3 && w.components != 4) {
      throw _fail(
        '$where must be VEC3 or VEC4, got ${w.components} components',
      );
    }
    return <GlbColor>[
      for (var i = 0; i < w.count; i++)
        GlbColor(
          w.readAt(i, 0),
          w.readAt(i, 1),
          w.readAt(i, 2),
          w.components == 4 ? w.readAt(i, 3) : 1.0,
        ),
    ];
  }

  List<int> _readIndices(int accessorIndex, int vertexCount, String where) {
    final w = _window(accessorIndex, '$where.indices');
    if (w.components != 1) {
      throw _fail(
        '$where.indices must be SCALAR, got ${w.components} components',
      );
    }
    if (w.componentType != _ctUbyte &&
        w.componentType != _ctUshort &&
        w.componentType != _ctUint) {
      throw _fail(
        '$where.indices uses componentType ${w.componentType}; only uint8, '
        'uint16 and uint32 index buffers are readable',
      );
    }
    final out = <int>[];
    if (w.count % 3 != 0) {
      throw _fail(
        '$where.indices holds ${w.count} entries, not a multiple of 3 — the '
        'index buffer ends mid-triangle',
      );
    }
    for (var i = 0; i < w.count; i++) {
      final v = w.readAt(i, 0).toInt();
      if (v < 0 || v >= vertexCount) {
        throw _fail(
          '$where.indices entry $i is $v but the POSITION accessor holds only '
          '$vertexCount vertices',
        );
      }
      out.add(v);
    }
    return out;
  }

  /// Index buffer → triangle soup. A degenerate index (two identical corners)
  /// is dropped here, so the per-vertex attribute expansions below stay in
  /// step with the positions.
  List<Vec3> _expandVec3(List<Vec3> source, List<int>? indices, String where) {
    if (indices == null) {
      if (source.length % 3 != 0) {
        throw _fail(
          '$where is non-indexed but holds ${source.length} positions, not a '
          'multiple of 3',
        );
      }
      return source;
    }
    final out = <Vec3>[];
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      if (a == b || b == c || a == c) continue;
      out
        ..add(source[a])
        ..add(source[b])
        ..add(source[c]);
    }
    return out;
  }

  Float32List _expandVec2(
    Float32List source,
    List<int>? indices,
    String where,
  ) {
    if (indices == null) return source;
    final out = <double>[];
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      if (a == b || b == c || a == c) continue;
      for (final v in <int>[a, b, c]) {
        out
          ..add(source[v * 2])
          ..add(source[v * 2 + 1]);
      }
    }
    return Float32List.fromList(out);
  }

  List<GlbColor> _expandColors(
    List<GlbColor> source,
    List<int>? indices,
    String where,
  ) {
    if (indices == null) return source;
    final out = <GlbColor>[];
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t], b = indices[t + 1], c = indices[t + 2];
      if (a == b || b == c || a == c) continue;
      out
        ..add(source[a])
        ..add(source[b])
        ..add(source[c]);
    }
    return out;
  }
}
