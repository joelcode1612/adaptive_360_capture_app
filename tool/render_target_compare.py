"""
One image showing the composite at three states, rendered from the real assets.

Panels, left to right:
    1. setback 0.020 m  — the previous value: the ring is recessed 14 mm, so it
                          projects smaller and a band of background shows at the
                          join.
    2. setback 0.006 m  — the derived value: bezel front (z 0.012) minus plate
                          front (z 0.006), i.e. flush. No gap.
    3. setback 0.006 m, captured — the two check-mark cuboids turned white.

Usage:
    python tool/render_target_compare.py docs/previews/target_composite.png
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import render_target_preview as rp  # noqa: E402

PANEL = 300
SEPARATOR = 8
SEPARATOR_RGB = (70, 78, 86)


def panel(setback, captured):
    tris, w, h = rp.build(PANEL * 2, setback, captured)
    return rp.downsample(rp.rasterise(tris, w, h), 2)


def main(out):
    panels = [
        panel(0.020, False),
        panel(0.006, False),
        panel(0.006, True),
    ]
    height = len(panels[0])
    width = len(panels[0][0]) * len(panels) + SEPARATOR * (len(panels) - 1)

    rows = []
    for y in range(height):
        row = []
        for i, p in enumerate(panels):
            row.extend(p[y])
            if i != len(panels) - 1:
                row.extend([SEPARATOR_RGB] * SEPARATOR)
        rows.append(row)

    rp.write_png(out, rows)
    print('%s  %dx%d  (0.020 | 0.006 | 0.006 captured)' % (out, width, height))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1
         else 'docs/previews/target_composite.png')
