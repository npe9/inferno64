#!/usr/bin/env python3
"""Extract TempleOS SPT_BITMAP DolDoc bins as Inferno images and masks."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


SPT_END = 0
SPT_BITMAP = 23
TRANSPARENT = 0xFF
TEMPLE_PALETTE = (
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
)


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


def plausible(data: bytes, pos: int) -> bool:
    if pos + 16 > len(data):
        return False
    num, flags, size, uses = struct.unpack_from("<IIII", data, pos)
    return (num < 0x10000 and flags == 0 and 0 < size
            and pos + 16 + size <= len(data) and uses < 0x10000)


def docbins(data: bytes):
    try:
        pos = data.index(0) + 1
    except ValueError as exc:
        raise ValueError("DolDoc source has no text terminator") from exc
    while pos + 16 <= len(data):
        # Some saved docs disagree by a byte or two between a bin's size
        # field and its actual element data (seen in BlackDiamond.HC and
        # others), which throws the chain off; resync on a header that
        # makes sense rather than trusting the arithmetic blindly.
        if not plausible(data, pos):
            for skew in range(-4, 65):
                if skew and plausible(data, pos + skew):
                    pos += skew
                    break
            else:
                return
        num, flags, size, uses = struct.unpack_from("<IIII", data, pos)
        pos += 16
        yield num, flags, uses, data[pos:pos + size]
        pos += size


def bitmap(blob: bytes) -> tuple[int, int, int, int, bytes] | None:
    if not blob or blob[0] == SPT_END:
        return None
    kind = blob[0] & 0x7F
    if kind != SPT_BITMAP:
        return None
    if len(blob) < 18:
        raise ValueError("truncated SPT_BITMAP header")
    x, y, width, height = struct.unpack_from("<iiii", blob, 1)
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid SPT_BITMAP dimensions {width}x{height}")
    stride = (width + 7) & ~7
    end = 17 + stride * height
    # Allow a byte or two of slack around the terminator; on-disk sizes
    # are not always exact (see the resync note in docbins).
    if end > len(blob) or abs(len(blob) - (end + 1)) > 2:
        raise ValueError("SPT_BITMAP size or terminator does not match its header")
    return x, y, width, height, blob[17:end]


# Plan 9 lays a row out relative to a byte boundary, not to the
# rectangle's left edge, so a 1-bit image whose r.min.x is not a
# multiple of 8 needs an extra byte per line and starts its first pixel
# part way into the first byte.  Writing (width + 7) // 8 bytes with the
# first pixel at bit 0 - which this script used to do - produced a file
# short of what libdraw's readimage expects, and 84 of the 230 .mask
# files in icons/temple could not be opened at all.  Their sprites then
# drew with no mask, which in draw3d's sprite2d meant the whole rotated
# bounding box came out as a solid black rectangle.
def _cdiv(a: int, b: int) -> int:
    """Integer division truncating towards zero, as C does; Python floors."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def k1_bytesperline(minx: int, maxx: int) -> int:
    """libdraw's bytesperline() for a 1-bit image, transcribed."""
    if minx >= 0:
        return _cdiv(maxx + 7, 8) - _cdiv(minx, 8)
    return _cdiv(-minx + 7, 8) + _cdiv(maxx + 7, 8)


def k1_firstbit(minx: int) -> int:
    """x coordinate that the first byte of a row starts at."""
    if minx >= 0:
        return _cdiv(minx, 8) * 8
    return -(_cdiv(-minx + 7, 8) * 8)

def write_images(
    dst: Path, x0: int, y0: int, width: int, height: int, pixels: bytes
) -> None:
    stride = (width + 7) & ~7
    mask_stride = k1_bytesperline(x0, x0 + width)
    bit0 = k1_firstbit(x0)
    image = bytearray(width * height)
    mask = bytearray(mask_stride * height)
    for y in range(height):
        for x in range(width):
            colour = pixels[y * stride + x]
            if colour == TRANSPARENT:
                continue
            if colour >= len(CMAP):
                raise ValueError(f"unsupported TempleOS palette index {colour}")
            image[y * width + x] = CMAP[colour]
            b = x0 + x - bit0
            mask[y * mask_stride + b // 8] |= 0x80 >> (b & 7)
    rect = (field(x0), field(y0), field(x0 + width), field(y0 + height))
    dst.with_suffix(".bit").write_bytes(b"".join((field("m8"), *rect)) + image)
    dst.with_suffix(".mask").write_bytes(b"".join((field("k1"), *rect)) + mask)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("--prefix")
    args = parser.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or args.source.stem.lower()
    count = 0
    for num, _flags, _uses, blob in docbins(args.source.read_bytes()):
        decoded = bitmap(blob)
        if decoded is None:
            continue
        x, y, width, height, pixels = decoded
        dst = args.outdir / f"{prefix}_{num}"
        write_images(dst, x, y, width, height, pixels)
        print(f"wrote {dst}.bit and {dst}.mask ({width}x{height}, origin {x},{y})")
        count += 1
    if count == 0:
        raise ValueError("no SPT_BITMAP DolDoc bins found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
