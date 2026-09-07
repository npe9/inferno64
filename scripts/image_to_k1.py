#!/usr/bin/env python3
"""Convert a common image into an uncompressed Inferno k1 mask."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def field(value: object) -> bytes:
    return f"{value!s:>11} ".encode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--threshold", type=int, default=128)
    args = parser.parse_args()

    image = Image.open(args.source).convert("L")
    width, height = image.size
    # Correct only because this writes a rectangle at the origin.  Plan 9
    # lays a row out relative to a byte boundary, not to the rectangle's
    # left edge, so a 1-bit image whose r.min.x is not a multiple of 8
    # needs an extra byte per line and starts its first pixel part way
    # into the first byte.  See k1_bytesperline() in tos_extract_sprites.py,
    # which is a transcription of libdraw/bytesperline.c; assuming this
    # formula there left 85 of the tree's 230 .mask files unreadable.
    stride = (width + 7) // 8
    data = bytearray(stride * height)
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            if pixels[x, y] >= args.threshold:
                data[y * stride + x // 8] |= 0x80 >> (x & 7)

    header = b"".join(
        (field("k1"), field(0), field(0), field(width), field(height))
    )
    args.destination.write_bytes(header + data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
