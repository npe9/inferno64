#!/usr/bin/env python3
"""Rasterize TempleOS DolDoc sprite bins as Inferno images and masks.

TempleOS sprites are element lists (CSprite in Adam/Gr/Gr.HH): color
changes, lines, rects, circles, ellipses, regular polygons, polylines,
B-splines, flood fills, bitmaps, text in the 8x8 system font, arrows,
planar symmetry and shifts.  GrSpritePlot.HC defines how each element
draws.  This walks every bin of a DolDoc file, rasterizes the 2D
elements at 1:1 scale on a transparent canvas, and writes an m8 .bit
plus k1 .mask per bin, named <prefix>_<binnum>, with the image rect
placed so that (0,0) is the sprite's origin.  --spr additionally dumps
each bin's element list as text for tools that want the vectors.

SPT_MESH / SPT_SHIFTABLE_MESH bins are 3D and are skipped here; use
tos_extract_meshes.py for those.
"""

from __future__ import annotations

import argparse
import math
import re
import struct
from pathlib import Path

TEMPLE_PALETTE = (
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
)
TRANSPARENT = 0xFF

(SPT_END, SPT_COLOR, SPT_DITHER_COLOR, SPT_THICK, SPT_PLANAR_SYMMETRY,
 SPT_TRANSFORM_ON, SPT_TRANSFORM_OFF, SPT_SHIFT, SPT_PT, SPT_POLYPT,
 SPT_LINE, SPT_POLYLINE, SPT_RECT, SPT_ROTATED_RECT, SPT_CIRCLE,
 SPT_ELLIPSE, SPT_POLYGON, SPT_BSPLINE2, SPT_BSPLINE2_CLOSED,
 SPT_BSPLINE3, SPT_BSPLINE3_CLOSED, SPT_FLOOD_FILL, SPT_FLOOD_FILL_NOT,
 SPT_BITMAP, SPT_MESH, SPT_SHIFTABLE_MESH, SPT_ARROW, SPT_TEXT,
 SPT_TEXT_BOX, SPT_TEXT_DIAMOND) = range(30)

NAMES = {
    SPT_COLOR: "color", SPT_DITHER_COLOR: "dither", SPT_THICK: "thick",
    SPT_PLANAR_SYMMETRY: "planarsym", SPT_TRANSFORM_ON: "transform_on",
    SPT_TRANSFORM_OFF: "transform_off", SPT_SHIFT: "shift", SPT_PT: "pt",
    SPT_POLYPT: "polypt", SPT_LINE: "line", SPT_POLYLINE: "polyline",
    SPT_RECT: "rect", SPT_ROTATED_RECT: "rotrect", SPT_CIRCLE: "circle",
    SPT_ELLIPSE: "ellipse", SPT_POLYGON: "polygon",
    SPT_BSPLINE2: "bspline2", SPT_BSPLINE2_CLOSED: "bspline2closed",
    SPT_BSPLINE3: "bspline3", SPT_BSPLINE3_CLOSED: "bspline3closed",
    SPT_FLOOD_FILL: "floodfill", SPT_FLOOD_FILL_NOT: "floodfillnot",
    SPT_BITMAP: "bitmap", SPT_MESH: "mesh", SPT_SHIFTABLE_MESH: "shiftmesh",
    SPT_ARROW: "arrow", SPT_TEXT: "text", SPT_TEXT_BOX: "textbox",
    SPT_TEXT_DIAMOND: "textdiamond",
}


def field(value: object) -> bytes:
    return f"{value!s:>11} ".encode("ascii")


def cmap_rgb(c: int) -> tuple[int, int, int]:
    r = c >> 6
    v = (c >> 4) & 3
    j = (c - v + r) & 15
    g, b = j >> 2, j & 3
    den = max(r, g, b)
    if den == 0:
        return (v * 17,) * 3
    num = 17 * (4 * den + v)
    return r * num // den, g * num // den, b * num // den


INFERNO_PALETTE = tuple(cmap_rgb(i) for i in range(256))


def rgb2cmap(rgb: int) -> int:
    r, g, b = rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF
    return min(range(256), key=lambda i: sum(
        (a - z) ** 2 for a, z in zip((r, g, b), INFERNO_PALETTE[i])
    ))


CMAP = tuple(rgb2cmap(rgb) for rgb in TEMPLE_PALETTE)

FONT_SRC = Path("/Users/npe/src/TempleOS/Kernel/FontStd.HC")


def load_font() -> list[int] | None:
    for cand in (FONT_SRC,
                 Path(__file__).resolve().parent.parent / "fonts/temple/FontStd.HC"):
        if cand.exists():
            vals = re.findall(rb"0x([0-9A-Fa-f]{16})", cand.read_bytes())
            if len(vals) >= 256:
                return [int(v, 16) for v in vals[:256]]
    return None


FONT = load_font()


def plausible(data: bytes, pos: int) -> bool:
    if pos + 16 > len(data):
        return False
    num, flags, size, uses = struct.unpack_from("<IIII", data, pos)
    return (num < 0x10000 and flags == 0 and 0 < size
            and pos + 16 + size <= len(data) and uses < 0x10000)


def docbins(data: bytes):
    pos = data.index(0) + 1
    while pos + 16 <= len(data):
        # Saved docs sometimes disagree by a byte or two between a bin's
        # size field and its element data; resync on a sane-looking
        # header rather than trusting the arithmetic blindly.
        if not plausible(data, pos):
            for skew in range(-4, 65):
                if skew and plausible(data, pos + skew):
                    pos += skew
                    break
            else:
                return
        num, _flags, size, _uses = struct.unpack_from("<IIII", data, pos)
        pos += 16
        yield num, data[pos:pos + size]
        pos += size


def elements(blob: bytes):
    """Yield (kind, fields...) tuples; raises on malformed data."""
    p = 0
    while p < len(blob):
        k = blob[p] & 0x7F
        if k == SPT_END:
            return
        if k == SPT_COLOR:
            yield (k, blob[p + 1]); p += 2
        elif k == SPT_DITHER_COLOR:
            yield (k, blob[p + 1], blob[p + 2]); p += 3
        elif k == SPT_THICK:
            yield (k, *struct.unpack_from("<i", blob, p + 1)); p += 5
        elif k in (SPT_PLANAR_SYMMETRY, SPT_LINE, SPT_RECT, SPT_ARROW):
            yield (k, *struct.unpack_from("<4i", blob, p + 1)); p += 17
        elif k in (SPT_TRANSFORM_ON, SPT_TRANSFORM_OFF):
            yield (k,); p += 1
        elif k in (SPT_SHIFT, SPT_PT, SPT_FLOOD_FILL, SPT_FLOOD_FILL_NOT):
            yield (k, *struct.unpack_from("<2i", blob, p + 1)); p += 9
        elif k == SPT_POLYPT:
            num, x, y = struct.unpack_from("<3i", blob, p + 1)
            nbytes = (num * 3 + 7) >> 3
            yield (k, num, x, y, blob[p + 13:p + 13 + nbytes])
            p += 13 + nbytes
        elif k == SPT_POLYLINE:
            num, = struct.unpack_from("<i", blob, p + 1)
            pts = struct.unpack_from("<%di" % (2 * num), blob, p + 5)
            yield (k, num, pts); p += 5 + 8 * num
        elif k == SPT_ROTATED_RECT:
            x1, y1, x2, y2 = struct.unpack_from("<4i", blob, p + 1)
            ang, = struct.unpack_from("<d", blob, p + 17)
            yield (k, x1, y1, x2, y2, ang); p += 25
        elif k == SPT_CIRCLE:
            yield (k, *struct.unpack_from("<3i", blob, p + 1)); p += 13
        elif k == SPT_ELLIPSE:
            x, y, w, h = struct.unpack_from("<4i", blob, p + 1)
            ang, = struct.unpack_from("<d", blob, p + 17)
            yield (k, x, y, w, h, ang); p += 25
        elif k == SPT_POLYGON:
            x, y, w, h = struct.unpack_from("<4i", blob, p + 1)
            ang, = struct.unpack_from("<d", blob, p + 17)
            sides, = struct.unpack_from("<i", blob, p + 25)
            yield (k, x, y, w, h, ang, sides); p += 29
        elif k in (SPT_BSPLINE2, SPT_BSPLINE2_CLOSED,
                   SPT_BSPLINE3, SPT_BSPLINE3_CLOSED):
            num, = struct.unpack_from("<i", blob, p + 1)
            pts = struct.unpack_from("<%di" % (3 * num), blob, p + 5)
            yield (k, num, pts); p += 5 + 12 * num
        elif k == SPT_BITMAP:
            x, y, w, h = struct.unpack_from("<4i", blob, p + 1)
            stride = (w + 7) & ~7
            yield (k, x, y, w, h, blob[p + 17:p + 17 + stride * h])
            p += 17 + stride * h
        elif k in (SPT_MESH, SPT_SHIFTABLE_MESH):
            off = 13 if k == SPT_SHIFTABLE_MESH else 1
            nv, nt = struct.unpack_from("<2i", blob, p + off)
            yield (k, nv, nt); p += off + 8 + 12 * nv + 16 * nt
        elif k in (SPT_TEXT, SPT_TEXT_BOX, SPT_TEXT_DIAMOND):
            x, y = struct.unpack_from("<2i", blob, p + 1)
            q = blob.index(0, p + 9)
            yield (k, x, y, blob[p + 9:q].decode("latin-1")); p = q + 1
        else:
            raise ValueError(f"unknown sprite element type {k} at {p}")


def bspline(pts, order: int, closed: bool):
    """Sample a uniform B-spline over 2D control points (z dropped)."""
    ctrl = [(pts[3 * i], pts[3 * i + 1]) for i in range(len(pts) // 3)]
    if closed:
        ctrl = ctrl + ctrl[:order]
    n = len(ctrl)
    if n < order + 1:
        return ctrl
    out = []
    steps = 16
    for seg in range(n - order):
        window = ctrl[seg:seg + order + 1]
        for s in range(steps + 1):
            t = s / steps
            if order == 2:
                b = ((1 - t) ** 2 / 2, (-2 * t * t + 2 * t + 1) / 2, t * t / 2)
            else:
                b = ((1 - t) ** 3 / 6, (3 * t ** 3 - 6 * t * t + 4) / 6,
                     (-3 * t ** 3 + 3 * t * t + 3 * t + 1) / 6, t ** 3 / 6)
            x = sum(w * p[0] for w, p in zip(b, window))
            y = sum(w * p[1] for w, p in zip(b, window))
            out.append((x, y))
    return out


class Raster:
    def __init__(self, x0: int, y0: int, x1: int, y1: int):
        self.x0, self.y0 = x0, y0
        self.w, self.h = x1 - x0, y1 - y0
        self.pix = bytearray([TRANSPARENT]) * (self.w * self.h)
        self.color = 0
        self.dither = None
        self.thick = 1
        self.sym = None

    def put(self, x: float, y: float):
        xi, yi = int(round(x)) - self.x0, int(round(y)) - self.y0
        if 0 <= xi < self.w and 0 <= yi < self.h:
            c = self.color
            if self.dither is not None:
                c = self.dither[(xi + yi) & 1]
            self.pix[yi * self.w + xi] = c
        if self.sym is not None:
            sx, sy = self.reflect(x, y)
            xi, yi = int(round(sx)) - self.x0, int(round(sy)) - self.y0
            if 0 <= xi < self.w and 0 <= yi < self.h:
                c = self.color
                if self.dither is not None:
                    c = self.dither[(xi + yi) & 1]
                self.pix[yi * self.w + xi] = c

    def reflect(self, x: float, y: float):
        (ax, ay), (bx, by) = self.sym
        dx, dy = bx - ax, by - ay
        d2 = dx * dx + dy * dy
        if d2 == 0:
            return 2 * ax - x, 2 * ay - y
        t = ((x - ax) * dx + (y - ay) * dy) / d2
        px, py = ax + t * dx, ay + t * dy
        return 2 * px - x, 2 * py - y

    def dot(self, x: float, y: float):
        r = self.thick / 2.0
        if r <= 0.5:
            self.put(x, y)
            return
        ir = int(math.ceil(r))
        for dy in range(-ir, ir + 1):
            for dx in range(-ir, ir + 1):
                if dx * dx + dy * dy <= r * r:
                    self.put(x + dx, y + dy)

    def line(self, x1, y1, x2, y2):
        steps = int(max(abs(x2 - x1), abs(y2 - y1))) + 1
        for i in range(steps + 1):
            t = i / steps
            self.dot(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)

    def path(self, pts, close=False):
        for a, b in zip(pts, pts[1:] + (pts[:1] if close else [])):
            self.line(a[0], a[1], b[0], b[1])

    def fill_rect(self, x1, y1, x2, y2):
        if x2 < x1:
            x1, x2 = x2, x1
        if y2 < y1:
            y1, y2 = y2, y1
        for y in range(int(y1), int(y2)):
            for x in range(int(x1), int(x2)):
                self.put(x, y)

    def flood(self, x, y, invert=False):
        xi, yi = int(x) - self.x0, int(y) - self.y0
        if not (0 <= xi < self.w and 0 <= yi < self.h):
            return
        target = self.pix[yi * self.w + xi]
        c = self.color
        if self.dither is not None:
            c = self.dither[0]
        if target == c:
            return
        stack = [(xi, yi)]
        while stack:
            px, py = stack.pop()
            if not (0 <= px < self.w and 0 <= py < self.h):
                continue
            if self.pix[py * self.w + px] != target:
                continue
            cc = c
            if self.dither is not None:
                cc = self.dither[(px + py) & 1]
            self.pix[py * self.w + px] = cc
            stack.extend(((px + 1, py), (px - 1, py), (px, py + 1), (px, py - 1)))

    def text(self, x, y, s):
        if FONT is None:
            return
        for i, ch in enumerate(s):
            g = FONT[ord(ch) & 0xFF]
            for row in range(8):
                bits = (g >> (8 * row)) & 0xFF
                for col in range(8):
                    if bits & (1 << col):
                        self.put(x + 8 * i + col, y + row)

    def blot(self, x, y, w, h, pixels):
        stride = (w + 7) & ~7
        for yy in range(h):
            for xx in range(w):
                c = pixels[yy * stride + xx]
                if c == TRANSPARENT:
                    continue
                xi, yi = x + xx - self.x0, y + yy - self.y0
                if 0 <= xi < self.w and 0 <= yi < self.h:
                    self.pix[yi * self.w + xi] = c & 0x0F


def draw(rast: Raster, elems, shift_only_bounds=False):
    sx = sy = 0
    for e in elems:
        k = e[0]
        if k == SPT_COLOR:
            rast.color = e[1] & 0x0F
            rast.dither = None
        elif k == SPT_DITHER_COLOR:
            rast.dither = (e[1] & 0x0F, e[2] & 0x0F)
        elif k == SPT_THICK:
            rast.thick = e[1]
        elif k == SPT_SHIFT:
            sx += e[1]; sy += e[2]
        elif k == SPT_PLANAR_SYMMETRY:
            rast.sym = ((e[1] + sx, e[2] + sy), (e[3] + sx, e[4] + sy))
        elif k == SPT_PT:
            rast.dot(e[1] + sx, e[2] + sy)
        elif k == SPT_LINE:
            rast.line(e[1] + sx, e[2] + sy, e[3] + sx, e[4] + sy)
        elif k == SPT_ARROW:
            x1, y1, x2, y2 = e[1] + sx, e[2] + sy, e[3] + sx, e[4] + sy
            rast.line(x1, y1, x2, y2)
            ang = math.atan2(y2 - y1, x2 - x1)
            for da in (2.6, -2.6):
                rast.line(x2, y2, x2 + 6 * math.cos(ang + da),
                          y2 + 6 * math.sin(ang + da))
        elif k == SPT_RECT:
            rast.fill_rect(e[1] + sx, e[2] + sy, e[3] + sx, e[4] + sy)
        elif k == SPT_ROTATED_RECT:
            x1, y1, x2, y2, ang = e[1] + sx, e[2] + sy, e[3] + sx, e[4] + sy, e[5]
            cx, cy = x1, y1
            c, s = math.cos(ang), math.sin(ang)
            pts = []
            for px, py in ((x1, y1), (x2, y1), (x2, y2), (x1, y2)):
                dx, dy = px - cx, py - cy
                pts.append((cx + dx * c - dy * s, cy + dx * s + dy * c))
            rast.path(pts, close=True)
        elif k == SPT_CIRCLE:
            x, y, r = e[1] + sx, e[2] + sy, e[3]
            n = max(12, int(2 * math.pi * abs(r)))
            rast.path([(x + r * math.cos(2 * math.pi * i / n),
                        y + r * math.sin(2 * math.pi * i / n))
                       for i in range(n)], close=True)
        elif k == SPT_ELLIPSE:
            x, y, w, h, ang = e[1] + sx, e[2] + sy, e[3], e[4], e[5]
            c, s = math.cos(ang), math.sin(ang)
            n = max(12, 2 * (abs(w) + abs(h)))
            pts = []
            for i in range(n):
                t = 2 * math.pi * i / n
                ex, ey = w * math.cos(t), h * math.sin(t)
                pts.append((x + ex * c - ey * s, y + ex * s + ey * c))
            rast.path(pts, close=True)
        elif k == SPT_POLYGON:
            x, y, w, h, ang, sides = (e[1] + sx, e[2] + sy, e[3], e[4],
                                      e[5], e[6])
            pts = []
            for i in range(max(sides, 2)):
                t = ang + 2 * math.pi * i / sides
                pts.append((x + w * math.cos(t), y + h * math.sin(t)))
            rast.path(pts, close=True)
        elif k == SPT_POLYLINE:
            pts = [(e[2][2 * i] + sx, e[2][2 * i + 1] + sy)
                   for i in range(e[1])]
            rast.path(pts)
        elif k == SPT_POLYPT:
            # 3-bit direction codes from a start point (GrSpritePlot's
            # polypt_map): 0=stay,1..7 = compass steps.
            x, y = e[2] + sx, e[3] + sy
            rast.dot(x, y)
            dirs = ((0, 0), (1, 0), (1, 1), (0, 1), (-1, 1),
                    (-1, 0), (-1, -1), (0, -1), (1, -1))
            data = e[4]
            for i in range(e[1] * 3 // 3):
                bit = i * 3
                v = 0
                for b in range(3):
                    byte = data[(bit + b) >> 3] if (bit + b) >> 3 < len(data) else 0
                    v |= ((byte >> ((bit + b) & 7)) & 1) << b
                dx, dy = dirs[v + 1] if v + 1 < len(dirs) else (0, 0)
                x += dx; y += dy
                rast.dot(x, y)
        elif k in (SPT_BSPLINE2, SPT_BSPLINE2_CLOSED):
            rast.path(bspline(e[2], 2, k == SPT_BSPLINE2_CLOSED))
        elif k in (SPT_BSPLINE3, SPT_BSPLINE3_CLOSED):
            rast.path(bspline(e[2], 3, k == SPT_BSPLINE3_CLOSED))
        elif k == SPT_FLOOD_FILL:
            rast.flood(e[1] + sx, e[2] + sy)
        elif k == SPT_FLOOD_FILL_NOT:
            rast.flood(e[1] + sx, e[2] + sy, invert=True)
        elif k == SPT_BITMAP:
            rast.blot(e[1] + sx, e[2] + sy, e[3], e[4], e[5])
        elif k == SPT_TEXT:
            rast.text(e[1] + sx, e[2] + sy, e[3])
        elif k in (SPT_TEXT_BOX, SPT_TEXT_DIAMOND):
            rast.text(e[1] + sx, e[2] + sy, e[3])


def bounds(elems):
    x0 = y0 = 10 ** 9
    x1 = y1 = -(10 ** 9)
    sx = sy = 0
    thick = 1
    have = False
    sym = None

    def pt(x, y, margin=0):
        nonlocal x0, y0, x1, y1, have
        for xx, yy in ((x, y),) + ((reflectpt(x, y),) if sym else ()):
            x0 = min(x0, xx - margin)
            y0 = min(y0, yy - margin)
            x1 = max(x1, xx + margin + 1)
            y1 = max(y1, yy + margin + 1)
        have = True

    def reflectpt(x, y):
        (ax, ay), (bx, by) = sym
        dx, dy = bx - ax, by - ay
        d2 = dx * dx + dy * dy
        if d2 == 0:
            return 2 * ax - x, 2 * ay - y
        t = ((x - ax) * dx + (y - ay) * dy) / d2
        return 2 * (ax + t * dx) - x, 2 * (ay + t * dy) - y

    for e in elems:
        k = e[0]
        m = thick // 2 + 1
        if k == SPT_THICK:
            thick = e[1]
        elif k == SPT_SHIFT:
            sx += e[1]; sy += e[2]
        elif k == SPT_PLANAR_SYMMETRY:
            sym = ((e[1] + sx, e[2] + sy), (e[3] + sx, e[4] + sy))
        elif k in (SPT_PT, SPT_FLOOD_FILL, SPT_FLOOD_FILL_NOT):
            pt(e[1] + sx, e[2] + sy, m)
        elif k in (SPT_LINE, SPT_RECT, SPT_ARROW):
            pt(e[1] + sx, e[2] + sy, m)
            pt(e[3] + sx, e[4] + sy, m)
        elif k == SPT_ROTATED_RECT:
            r = int(math.hypot(e[3] - e[1], e[4] - e[2])) + 1
            pt(e[1] + sx, e[2] + sy, r + m)
        elif k == SPT_CIRCLE:
            pt(e[1] + sx, e[2] + sy, abs(e[3]) + m)
        elif k in (SPT_ELLIPSE, SPT_POLYGON):
            r = max(abs(e[3]), abs(e[4]))
            pt(e[1] + sx, e[2] + sy, r + m)
        elif k == SPT_POLYLINE:
            for i in range(e[1]):
                pt(e[2][2 * i] + sx, e[2][2 * i + 1] + sy, m)
        elif k == SPT_POLYPT:
            pt(e[2] + sx, e[3] + sy, e[1] + m)
        elif k in (SPT_BSPLINE2, SPT_BSPLINE2_CLOSED,
                   SPT_BSPLINE3, SPT_BSPLINE3_CLOSED):
            for i in range(e[1]):
                pt(e[2][3 * i] + sx, e[2][3 * i + 1] + sy, m)
        elif k == SPT_BITMAP:
            pt(e[1] + sx, e[2] + sy)
            pt(e[1] + e[3] + sx, e[2] + e[4] + sy)
        elif k in (SPT_TEXT, SPT_TEXT_BOX, SPT_TEXT_DIAMOND):
            pt(e[1] + sx, e[2] + sy)
            pt(e[1] + 8 * len(e[3]) + sx, e[2] + 8 + sy)
    if not have:
        return None
    return int(x0), int(y0), int(x1), int(y1)


# Plan 9 lays a row out relative to a byte boundary, not to the
# rectangle's left edge, so a 1-bit image whose r.min.x is not a
# multiple of 8 needs an extra byte per line and starts its first pixel
# part way into the first byte.  Writing (width + 7) // 8 bytes with the
# first pixel at bit 0 - which this script used to do - produced a file
# short of what libdraw's readimage expects, and 84 of the 230 .mask
# files in icons/temple could not be opened at all.  Their sprites then
# drew with no mask, which in draw3d's sprite2d meant the whole rotated
# bounding box came out as a solid black rectangle.
def _ceildiv(a: int, b: int) -> int:
    """ceil(a/b) for a positive b, matching libdraw's ceildiv()."""
    return (a + b - 1) // b if a >= 0 else -((-a) // b)


def k1_bytesperline(minx: int, maxx: int) -> int:
    """libdraw's bytesperline() for a 1-bit image, transcribed."""
    if minx >= 0:
        return _ceildiv(maxx, 8) - minx // 8
    return _ceildiv(-minx, 8) + _ceildiv(maxx, 8)


def k1_firstbit(minx: int) -> int:
    """x coordinate that the first byte of a row starts at."""
    if minx >= 0:
        return minx // 8 * 8
    return -(_ceildiv(-minx, 8) * 8)

def write_images(dst: Path, x0, y0, width, height, pix):
    mask_stride = k1_bytesperline(x0, x0 + width)
    bit0 = k1_firstbit(x0)
    image = bytearray(width * height)
    mask = bytearray(mask_stride * height)
    for y in range(height):
        for x in range(width):
            c = pix[y * width + x]
            if c == TRANSPARENT:
                continue
            image[y * width + x] = CMAP[c & 0x0F]
            b = x0 + x - bit0
            mask[y * mask_stride + b // 8] |= 0x80 >> (b & 7)
    rect = (field(x0), field(y0), field(x0 + width), field(y0 + height))
    dst.with_suffix(".bit").write_bytes(b"".join((field("m8"), *rect)) + image)
    dst.with_suffix(".mask").write_bytes(b"".join((field("k1"), *rect)) + mask)


def spr_dump(elems) -> str:
    out = []
    for e in elems:
        k = e[0]
        name = NAMES.get(k, str(k))
        if k == SPT_POLYLINE:
            out.append(f"{name} {e[1]} " + " ".join(map(str, e[2])))
        elif k in (SPT_BSPLINE2, SPT_BSPLINE2_CLOSED,
                   SPT_BSPLINE3, SPT_BSPLINE3_CLOSED):
            out.append(f"{name} {e[1]} " + " ".join(map(str, e[2])))
        elif k == SPT_BITMAP:
            out.append(f"{name} {e[1]} {e[2]} {e[3]} {e[4]} {e[5].hex()}")
        elif k == SPT_POLYPT:
            out.append(f"{name} {e[1]} {e[2]} {e[3]} {e[4].hex()}")
        elif k in (SPT_TEXT, SPT_TEXT_BOX, SPT_TEXT_DIAMOND):
            out.append(f"{name} {e[1]} {e[2]} {e[3]!r}")
        else:
            out.append(" ".join(map(str, (name,) + e[1:])))
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("--prefix")
    parser.add_argument("--spr", type=Path,
                        help="also dump element lists as text into this dir")
    args = parser.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    if args.spr:
        args.spr.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or args.source.stem.lower()
    count = 0
    for num, blob in docbins(args.source.read_bytes()):
        try:
            elems = list(elements(blob))
        except (ValueError, IndexError, struct.error) as exc:
            print(f"bin {num}: skipped ({exc})")
            continue
        if args.spr and elems:
            (args.spr / f"{prefix}_{num}.spr").write_text(spr_dump(elems))
        if any(e[0] in (SPT_MESH, SPT_SHIFTABLE_MESH) for e in elems):
            print(f"bin {num}: mesh, skipped (use tos_extract_meshes.py)")
            continue
        box = bounds(elems)
        if box is None:
            continue
        x0, y0, x1, y1 = box
        if x1 - x0 > 2048 or y1 - y0 > 2048:
            print(f"bin {num}: skipped ({x1-x0}x{y1-y0} exceeds sanity bound)")
            continue
        rast = Raster(x0, y0, x1, y1)
        draw(rast, elems)
        dst = args.outdir / f"{prefix}_{num}"
        write_images(dst, x0, y0, rast.w, rast.h, rast.pix)
        print(f"wrote {dst}.bit and {dst}.mask ({rast.w}x{rast.h}, origin {x0},{y0})")
        count += 1
    if count == 0:
        print("no drawable sprite bins found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
