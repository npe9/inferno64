#!/usr/bin/env python3
"""Extract TempleOS DolDoc sprite bins and .GR bitmaps to Inferno image files.

Writes uncompressed Inferno images (man 6 image):
  - name.bit  : r8g8b8a8 color+alpha (0xFF index → A=0)
  - name.mask : a8 mask (255 where opaque) for coffee-style draw

Usage:
  tos_extract_sprites.py FILE.HC [-o outdir] [--bin N] [--prefix name]
  tos_extract_sprites.py FILE.GR  [-o outdir] [--prefix name]
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# TempleOS gr_palette_std as RGB888 (high byte of each 16-bit channel in 0xRRRRGGGGBBBB)
PALETTE = [
    (0x00, 0x00, 0x00),  # 0 BLACK
    (0x00, 0x00, 0xAA),  # 1 BLUE
    (0x00, 0xAA, 0x00),  # 2 GREEN
    (0x00, 0xAA, 0xAA),  # 3 CYAN
    (0xAA, 0x00, 0x00),  # 4 RED
    (0xAA, 0x00, 0xAA),  # 5 PURPLE
    (0xAA, 0x55, 0x00),  # 6 BROWN
    (0xAA, 0xAA, 0xAA),  # 7 LTGRAY
    (0x55, 0x55, 0x55),  # 8 DKGRAY
    (0x55, 0x55, 0xFF),  # 9 LTBLUE
    (0x55, 0xFF, 0x55),  # 10 LTGREEN
    (0x55, 0xFF, 0xFF),  # 11 LTCYAN
    (0xFF, 0x55, 0x55),  # 12 LTRED
    (0xFF, 0x55, 0xFF),  # 13 LTPURPLE
    (0xFF, 0xFF, 0x55),  # 14 YELLOW
    (0xFF, 0xFF, 0xFF),  # 15 WHITE
]

SPT_END = 0
SPT_BITMAP = 23
TRANSPARENT = 0xFF

# Minimal element sizes for skipping non-bitmap elems (from SpriteNew.HC / Gr.HH).
# Values are total packed bytes including type byte. Unknown types fail loudly.
ELEM_FIXED = {
    0: 1,   # END
    1: 2,   # COLOR
    2: 2,   # DITHER_COLOR
    3: 5,   # THICK (type + I32)
    4: 9,   # PLANAR_SYMMETRY
    5: 5,   # TRANSFORM_ON
    6: 1,   # TRANSFORM_OFF
    7: 9,   # SHIFT
    # pts / many others vary — handled in skip_elem
}


def field11(s: str) -> bytes:
    return f"{s:>11} ".encode("ascii")


def write_inferno_rgba(path: Path, w: int, h: int, rgba: bytes) -> None:
    """Uncompressed r8g8b8a8 Inferno image."""
    hdr = b"".join([
        field11("r8g8b8a8"),
        field11("0"),
        field11("0"),
        field11(str(w)),
        field11(str(h)),
    ])
    path.write_bytes(hdr + rgba)


def write_inferno_mask(path: Path, w: int, h: int, alpha: bytes) -> None:
    """Uncompressed a8 mask image."""
    hdr = b"".join([
        field11("a8"),
        field11("0"),
        field11("0"),
        field11(str(w)),
        field11(str(h)),
    ])
    path.write_bytes(hdr + alpha)


def indices_to_rgba(indices: bytes) -> tuple[bytes, bytes]:
    rgba = bytearray(len(indices) * 4)
    mask = bytearray(len(indices))
    for i, pix in enumerate(indices):
        if pix == TRANSPARENT or pix > 15:
            rgba[i * 4 : i * 4 + 4] = b"\x00\x00\x00\x00"
            mask[i] = 0
        else:
            r, g, b = PALETTE[pix]
            rgba[i * 4 : i * 4 + 4] = bytes((r, g, b, 0xFF))
            mask[i] = 0xFF
    return bytes(rgba), bytes(mask)


def parse_docbins(data: bytes) -> dict[int, bytes]:
    try:
        t = data.index(0)
    except ValueError:
        return {}
    off = t + 1
    bins: dict[int, bytes] = {}
    while off + 16 <= len(data):
        num, _flags, size, _use = struct.unpack_from("<IIII", data, off)
        off += 16
        if size < 0 or off + size > len(data):
            break
        bins[num] = data[off : off + size]
        off += size
    return bins


def skip_elem(blob: bytes, p: int) -> int:
    """Return offset past the element at p, or -1 on failure."""
    if p >= len(blob):
        return -1
    typ = blob[p] & 0x7F
    if typ in ELEM_FIXED:
        return p + ELEM_FIXED[typ]
    # Point types: type + x + y (I32,I32) = 9
    if typ in (8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22):
        # many are Pt or PtPt; bitmap is 23. For safety only support known set.
        # Pt = 9, PtPt = 17, PtWH = 17, etc. Without full table, fail.
        pass
    if typ == SPT_BITMAP:
        if p + 17 > len(blob):
            return -1
        w, h = struct.unpack_from("<ii", blob, p + 9)
        stride = (w + 7) & ~7
        return p + 17 + stride * h
    # PtWHU8s variants already handled; mesh etc. unsupported
    return -1


def bitmaps_in_sprite(blob: bytes) -> list[tuple[int, int, int, int, bytes]]:
    """Return list of (x1,y1,w,h,indices_tight) for SPT_BITMAP elems."""
    out = []
    p = 0
    while p < len(blob):
        typ = blob[p] & 0x7F
        if typ == SPT_END:
            break
        if typ == SPT_BITMAP:
            if p + 17 > len(blob):
                break
            x1, y1, w, h = struct.unpack_from("<iiii", blob, p + 1)
            stride = (w + 7) & ~7
            raw = blob[p + 17 : p + 17 + stride * h]
            if len(raw) < stride * h or w <= 0 or h <= 0:
                break
            tight = bytearray(w * h)
            for y in range(h):
                tight[y * w : (y + 1) * w] = raw[y * stride : y * stride + w]
            out.append((x1, y1, w, h, bytes(tight)))
            p = p + 17 + stride * h
            continue
        nxt = skip_elem(blob, p)
        if nxt <= p:
            # unsupported element — stop after reporting
            raise ValueError(f"unsupported sprite element type {typ} at offset {p}")
        p = nxt
    return out


def extract_gr(data: bytes) -> tuple[int, int, bytes]:
    """Parse TempleOS .GR (uncompressed only for now)."""
    if len(data) < 32:
        raise ValueError("GR too small")
    # I64 cdt; I32 x0,y0,width,width_internal,height,flags
    _cdt, _x0, _y0, width, width_internal, height, flags = struct.unpack_from(
        "<qiiiiii", data, 0
    )
    off = 32
    DCF_COMPRESSED = 1
    DCF_PALETTE = 2
    if flags & DCF_PALETTE:
        off += 16 * 8  # CBGR48[16]
    if flags & DCF_COMPRESSED:
        raise ValueError("compressed GR not supported yet (need TempleOS LZW)")
    body = data[off : off + width_internal * height]
    tight = bytearray(width * height)
    for y in range(height):
        tight[y * width : (y + 1) * width] = body[
            y * width_internal : y * width_internal + width
        ]
    return width, height, bytes(tight)


def write_pair(outdir: Path, prefix: str, w: int, h: int, indices: bytes) -> None:
    rgba, mask = indices_to_rgba(indices)
    bit = outdir / f"{prefix}.bit"
    msk = outdir / f"{prefix}.mask"
    write_inferno_rgba(bit, w, h, rgba)
    write_inferno_mask(msk, w, h, mask)
    print(f"wrote {bit} and {msk} ({w}x{h})")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src", type=Path)
    ap.add_argument("-o", "--outdir", type=Path, default=None)
    ap.add_argument("--bin", type=int, default=None, help="only this BI number")
    ap.add_argument("--prefix", default=None)
    args = ap.parse_args()
    src: Path = args.src
    outdir = args.outdir or (src.parent / "extracted")
    outdir.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or src.stem.lower().replace(" ", "_")
    data = src.read_bytes()

    if src.suffix.lower() == ".gr":
        w, h, idx = extract_gr(data)
        write_pair(outdir, prefix, w, h, idx)
        return 0

    bins = parse_docbins(data)
    if not bins:
        print(f"{src}: no DolDoc bins", file=sys.stderr)
        return 1
    nums = [args.bin] if args.bin is not None else sorted(bins)
    nwritten = 0
    for num in nums:
        if num not in bins:
            print(f"{src}: missing bin {num}", file=sys.stderr)
            continue
        try:
            maps = bitmaps_in_sprite(bins[num])
        except ValueError as e:
            print(f"{src}: bin {num}: {e}", file=sys.stderr)
            continue
        if not maps:
            print(f"{src}: bin {num}: no SPT_BITMAP", file=sys.stderr)
            continue
        for i, (_x, _y, w, h, idx) in enumerate(maps):
            name = prefix if len(maps) == 1 and len(nums) == 1 else f"{prefix}_{num}"
            if len(maps) > 1:
                name = f"{name}_{i}"
            elif len(nums) > 1:
                name = f"{prefix}_{num}"
            write_pair(outdir, name, w, h, idx)
            nwritten += 1
    return 0 if nwritten else 1


if __name__ == "__main__":
    sys.exit(main())
