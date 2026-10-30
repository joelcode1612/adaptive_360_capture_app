"""
Renders the two shipped GLB assets as one composite target, using the same
billboard transform, pinhole projection and flat shading as
`lib/features/virtual_tour/platform/glb/glb_renderer.dart`.

This exists so the composite can be *looked at* without a device. It reads the
real assets, expands the real index buffers, and rasterises the real triangles
with a z-buffer. Nothing here is a mockup: change an asset and the picture changes.

Usage:
    python tool/render_target_preview.py <out.png> [--setback 0.006] [--captured]
"""

import json
import math
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / 'assets/models/ar_capture_target.glb'
BEZEL = ROOT / 'assets/models/white_frame_bezel.glb'

# ── glTF ─────────────────────────────────────────────────────────────────


def load_glb(path):
    data = pathlib.Path(path).read_bytes()
    magic, version, _ = struct.unpack_from('<III', data, 0)
    if magic != 0x46546C67:
        raise SystemExit('%s is not a GLB' % path)
    off, js, binc = 12, None, None
    while off < len(data):
        clen, ctype = struct.unpack_from('<II', data, off)
        off += 8
        chunk = data[off:off + clen]
        off += clen
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode('utf-8'))
        elif ctype == 0x004E4942:
            binc = chunk
    return js, binc


_CT = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2),
       5124: ('i', 4), 5125: ('I', 4), 5126: ('f', 4)}
_NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def accessor(js, binc, index):
    a = js['accessors'][index]
    bv = js['bufferViews'][a['bufferView']]
    fmt, size = _CT[a['componentType']]
    ncomp = _NC[a['type']]
    base = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride') or size * ncomp
    return [struct.unpack_from('<' + fmt * ncomp, binc, base + i * stride)
            for i in range(a['count'])]


def triangles_of(path):
    """Expanded triangle list: [(v0, v1, v2, rgba)] in model space."""
    js, binc = load_glb(path)
    out = []
    for mesh in js['meshes']:
        prim = mesh['primitives'][0]
        pos = accessor(js, binc, prim['attributes']['POSITION'])
        idx = accessor(js, binc, prim['indices'])
        mat = js['materials'][prim['material']]
        base = mat.get('pbrMetallicRoughness', {}).get('baseColorFactor',
                                                       [1, 1, 1, 1])
        for i in range(0, len(idx), 3):
            out.append((pos[idx[i][0]], pos[idx[i + 1][0]], pos[idx[i + 2][0]],
                        tuple(base)))
    return out


# ── the scene's transform, mirroring glbBillboardTransform ───────────────
#
# Camera at the origin looking along +Z, up +Y, marker at (0, 0, 1). The model's
# +Z is mapped onto the direction from the marker back to the camera, so model
# +Z -> (0, 0, -1); `right = up x face` gives (-1, 0, 0), which is this project's
# physical screen-right for a camera looking down +Z.

TARGET_POINT = (0.0, 0.0, 1.0)
RIGHT = (-1.0, 0.0, 0.0)
UP = (0.0, 1.0, 0.0)
FACE = (0.0, 0.0, -1.0)

NEAR_M = 0.05
SHADE_FLOOR = 0.55
HFOV_DEG = 68.0


def to_world(p, setback):
    """Model point -> world, with the bezel's setback applied along its own -Z."""
    x, y, z = p[0], p[1], p[2] - setback
    return (TARGET_POINT[0] + x * RIGHT[0] + y * UP[0] + z * FACE[0],
            TARGET_POINT[1] + x * RIGHT[1] + y * UP[1] + z * FACE[1],
            TARGET_POINT[2] + x * RIGHT[2] + y * UP[2] + z * FACE[2])


def to_camera(w):
    """World -> (right, up, forward) of a camera at the origin looking down +Z."""
    return (-w[0], w[1], w[2])


def face_normal(a, b, c):
    u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
    n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2],
         u[0] * v[1] - u[1] * v[0])
    m = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2)
    return (0, 0, 0) if m == 0 else (n[0] / m, n[1] / m, n[2] / m)


def build(width, setback, captured):
    """Returns (screen_triangles, width, height)."""
    height = width
    fx = (width / 2) / math.tan(math.radians(HFOV_DEG) / 2)

    bezel_tris = triangles_of(BEZEL)
    target_tris = triangles_of(TARGET)

    # Recolouring, exactly as ArTargetColors does: the bezel takes the state
    # colour, the check marks turn white, the plate and centre keep their own.
    bezel_rgba = (0.957, 0.957, 0.957, 1.0)
    check_rgba = (0.957, 0.957, 0.957, 1.0)
    # `triangles_of` flattens meshes in order, 256+256+12+12 for the target.
    plate_end = 256
    centre_end = 512
    check_end = len(target_tris)

    faces = []
    for i, (a, b, c, rgba) in enumerate(bezel_tris):
        faces.append(('bezel', i, a, b, c, bezel_rgba, setback))
    for i, (a, b, c, rgba) in enumerate(target_tris):
        if i < plate_end:
            col = rgba
        elif i < centre_end:
            col = rgba
        elif i < check_end:
            if not captured:
                continue          # check marks only appear on `done`
            col = check_rgba
        else:
            col = rgba
        faces.append(('target', i, a, b, c, col, 0.0))

    tris = []
    for group, seq, a, b, c, rgba, sb in faces:
        wa, wb, wc = to_world(a, sb), to_world(b, sb), to_world(c, sb)
        ca, cb, cc = to_camera(wa), to_camera(wb), to_camera(wc)
        if ca[2] <= NEAR_M or cb[2] <= NEAR_M or cc[2] <= NEAR_M:
            continue
        pts = []
        for cam in (ca, cb, cc):
            pts.append((width / 2 + fx * cam[0] / cam[2],
                        height / 2 - fx * cam[1] / cam[2]))
        area = ((pts[1][0] - pts[0][0]) * (pts[2][1] - pts[0][1])
                - (pts[1][1] - pts[0][1]) * (pts[2][0] - pts[0][0]))
        if abs(area) < 1e-9:
            continue
        if (max(p[0] for p in pts) < 0 or min(p[0] for p in pts) > width
                or max(p[1] for p in pts) < 0 or min(p[1] for p in pts) > height):
            continue

        normal = face_normal(wa, wb, wc)
        centre = ((wa[0] + wb[0] + wc[0]) / 3, (wa[1] + wb[1] + wc[1]) / 3,
                  (wa[2] + wb[2] + wc[2]) / 3)
        to_cam = (-centre[0], -centre[1], -centre[2])
        m = math.sqrt(sum(v * v for v in to_cam))
        facing = 0.0 if m == 0 else sum(normal[k] * to_cam[k] for k in range(3)) / m
        facing = abs(facing)                       # both assets are doubleSided
        shade = SHADE_FLOOR + (1 - SHADE_FLOOR) * max(0.0, min(1.0, facing))

        depth = (ca[2] + cb[2] + cc[2]) / 3
        tris.append((depth, pts, rgba, shade))
    return tris, width, height


# ── rasteriser ───────────────────────────────────────────────────────────


def rasterise(tris, width, height):
    # Background: the dark viewfinder, so the white marker reads against it.
    bg = (24, 30, 36)
    colour = [[bg for _ in range(width)] for _ in range(height)]
    zbuf = [[float('inf')] * width for _ in range(height)]

    for depth, pts, rgba, shade in tris:
        r = rgba[0] * shade
        g = rgba[1] * shade
        b = rgba[2] * shade
        rgb = (int(max(0, min(1, r)) * 255),
               int(max(0, min(1, g)) * 255),
               int(max(0, min(1, b)) * 255))
        (x0, y0), (x1, y1), (x2, y2) = pts
        minx = max(0, int(math.floor(min(x0, x1, x2))))
        maxx = min(width - 1, int(math.ceil(max(x0, x1, x2))))
        miny = max(0, int(math.floor(min(y0, y1, y2))))
        maxy = min(height - 1, int(math.ceil(max(y0, y1, y2))))
        denom = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if denom == 0:
            continue
        for py in range(miny, maxy + 1):
            for px in range(minx, maxx + 1):
                cx, cy = px + 0.5, py + 0.5
                w0 = ((y1 - y2) * (cx - x2) + (x2 - x1) * (cy - y2)) / denom
                w1 = ((y2 - y0) * (cx - x2) + (x0 - x2) * (cy - y2)) / denom
                w2 = 1 - w0 - w1
                if w0 < -1e-6 or w1 < -1e-6 or w2 < -1e-6:
                    continue
                if depth < zbuf[py][px]:
                    zbuf[py][px] = depth
                    colour[py][px] = rgb
    return colour


def downsample(colour, factor):
    h, w = len(colour), len(colour[0])
    oh, ow = h // factor, w // factor
    out = []
    for y in range(oh):
        row = []
        for x in range(ow):
            acc = [0, 0, 0]
            for dy in range(factor):
                for dx in range(factor):
                    px = colour[y * factor + dy][x * factor + dx]
                    acc[0] += px[0]
                    acc[1] += px[1]
                    acc[2] += px[2]
            n = factor * factor
            row.append((acc[0] // n, acc[1] // n, acc[2] // n))
        out.append(row)
    return out


def write_png(path, colour):
    h, w = len(colour), len(colour[0])
    raw = bytearray()
    for row in colour:
        raw.append(0)
        for px in row:
            raw.extend(px)

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    pathlib.Path(path).write_bytes(png)


def render(out, setback, captured, size=720):
    tris, w, h = build(size, setback, captured)
    img = rasterise(tris, w, h)
    img = downsample(img, 2)
    write_png(out, img)
    print('%s  setback=%.3f captured=%s  triangles=%d'
          % (out, setback, captured, len(tris)))


if __name__ == '__main__':
    out = sys.argv[1]
    setback = 0.006
    captured = '--captured' in sys.argv
    if '--setback' in sys.argv:
        setback = float(sys.argv[sys.argv.index('--setback') + 1])
    render(out, setback, captured)
