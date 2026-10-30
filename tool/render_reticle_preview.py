"""
Renders the bezel reticle in its four states, from the asset's own radii.

This is a preview of the Flutter widget's *appearance*, not a screenshot of it:
the annulus radii are read from `white_frame_bezel.glb` so the shape matches what
`BezelReticle` builds, and the colours are the same constants.

Usage:
    python tool/render_reticle_preview.py docs/previews/reticle_states.png
"""

import json
import math
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
BEZEL = ROOT / 'assets/models/white_frame_bezel.glb'

WHITE = (0xF4, 0xF4, 0xF4)
GREEN = (0x4C, 0xC2, 0x7F)
GREY = (0x9A, 0xA3, 0xAD)
BG = (24, 30, 36)
SEP = (70, 78, 86)


def radii():
    data = BEZEL.read_bytes()
    off, js = 12, None
    while off < len(data):
        clen, ctype = struct.unpack_from('<II', data, off)
        off += 8
        if ctype == 0x4E4F534A:
            js = json.loads(data[off:off + clen].decode('utf-8'))
        off += clen
    acc = js['accessors'][js['meshes'][0]['primitives'][0]['attributes']['POSITION']]
    bv = js['bufferViews'][acc['bufferView']]
    base = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = bv.get('byteStride') or 12
    binc = data[off - clen:off] if False else None
    # Re-read the BIN chunk properly.
    off2 = 12
    while off2 < len(data):
        clen2, ctype2 = struct.unpack_from('<II', data, off2)
        off2 += 8
        if ctype2 == 0x004E4942:
            binc = data[off2:off2 + clen2]
        off2 += clen2
    rs = []
    for i in range(acc['count']):
        x, y, z = struct.unpack_from('<fff', binc, base + i * stride)
        rs.append(math.hypot(x, y))
    return min(rs), max(rs)


def panel(size, progress, completed, within, inner, outer):
    # 4x supersampling for a smooth edge.
    s = 4
    w = size * s
    img = [[BG for _ in range(w)] for _ in range(w)]
    c = w / 2
    r_in = inner / outer * (w / 2)
    r_out = w / 2 - 2 * s

    for y in range(w):
        for x in range(w):
            dx, dy = x + 0.5 - c, y + 0.5 - c
            r = math.hypot(dx, dy)
            if not (r_in <= r <= r_out):
                continue
            if completed:
                img[y][x] = GREEN
                continue
            # Clockwise from twelve o'clock.
            ang = math.atan2(dy, dx) + math.pi / 2
            if ang < 0:
                ang += 2 * math.pi
            frac = ang / (2 * math.pi)
            if within and progress > 0 and frac <= progress:
                img[y][x] = GREEN
            else:
                img[y][x] = WHITE if within else GREY

    # Box downsample.
    out = []
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0, 0, 0]
            for dy in range(s):
                for dx in range(s):
                    px = img[y * s + dy][x * s + dx]
                    acc[0] += px[0]
                    acc[1] += px[1]
                    acc[2] += px[2]
            n = s * s
            row.append((acc[0] // n, acc[1] // n, acc[2] // n))
        out.append(row)
    return out


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for px in row:
            raw.extend(px)

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))

    pathlib.Path(path).write_bytes(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
        + chunk(b'IEND', b'')
    )


def main(out):
    inner, outer = radii()
    size = 180
    states = [
        (0.0, False, False),   # idle: not aimed
        (0.0, False, True),    # aimed, window not started
        (0.5, False, True),    # aimed, half the window elapsed
        (1.0, True, True),     # captured
    ]
    panels = [panel(size, p, done, within, inner, outer)
              for p, done, within in states]

    gap = 8
    rows = []
    for y in range(size):
        row = []
        for i, pnl in enumerate(panels):
            row.extend(pnl[y])
            if i != len(panels) - 1:
                row.extend([SEP] * gap)
        rows.append(row)

    write_png(out, rows)
    print('%s  %dx%d  inner=%.3f outer=%.3f' %
          (out, size * len(panels) + gap * (len(panels) - 1), size, inner, outer))
    print('states: idle | aimed | aimed + 50%% | captured')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'docs/previews/reticle_states.png')
