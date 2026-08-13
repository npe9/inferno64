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
