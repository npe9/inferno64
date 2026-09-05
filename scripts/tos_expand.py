#!/usr/bin/env python3
"""Extract a TempleOS distribution ISO's RedSea filesystem, expanding .Z files.

The TempleOS sources mirrored on GitHub were exported through a pipeline
that stripped every 0x05 byte, silently corrupting the binary DolDoc
sprite data embedded in .HC files (see tos_extract_sprites.py).  The
distribution ISO carries the original RedSea filesystem with each file
in TempleOS's own LZW-style compressed .Z format, so this walks the
RedSea directory tree and writes out every file, expanded, giving a
pristine source tree to extract sprites from.

RedSea (Kernel/BlkDev/DskRedSea.HC): 64-byte directory entries of
{U16 attr, U8 name[38], I64 block, I64 size, I64 datetime}; file data
is contiguous at block*512 from the start of the image.  Compression
(Kernel/Compress.HC): CArcCompress {I64 compressed_size, I64
expanded_size, U8 compression_type} then a bitstream of LZW codes,
9..12 bits for CT_8_BIT (8..12 for CT_7_BIT), with Terry's
entry-recycling variant once the table is full.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

RS_ATTR_DIR = 0x10
ARC_BITS_MAX = 12
CT_NONE, CT_7_BIT, CT_8_BIT = 1, 2, 3


def expand(src: bytes) -> bytes:
    comp_size, exp_size = struct.unpack_from("<qq", src, 0)
    ctype = src[16]
    body = src[17:comp_size]
    if ctype == CT_NONE:
        return body[:exp_size]
    if ctype not in (CT_7_BIT, CT_8_BIT):
        raise ValueError(f"unknown compression type {ctype}")
    min_bits = 7 if ctype == CT_7_BIT else 8
    min_table = 1 << min_bits
    nslots = 1 << ARC_BITS_MAX
    basecode = [0] * nslots
    ch = [0] * nslots
    children: list[set[int]] = [set() for _ in range(nslots)]

    padded = body + b"\0\0\0\0\0\0\0\0"
    bitpos = 0
    bitlen = 8 * len(body)

    out = bytearray()
    free_idx = min_table
    next_bits = min_bits + 1
    free_limit = 1 << next_bits
    cur_entry = -1
    next_entry = -1
    entry_used = True

    def entry_get():
        nonlocal free_idx, next_bits, free_limit, cur_entry, next_entry, entry_used
        if not entry_used:
            return
        entry_used = False
        i = free_idx
        cur_entry = next_entry
        if next_bits < ARC_BITS_MAX:
            next_entry = i
            i += 1
            if i == free_limit:
                next_bits += 1
                free_limit = 1 << next_bits
        else:
            while True:
                i += 1
                if i == free_limit:
                    i = min_table
                if not children[i]:
                    break
            next_entry = i
            children[basecode[i]].discard(i)
        free_idx = i

    entry_get()
    entry_used = True

    def extract() -> int:
        nonlocal bitpos
        byte = bitpos >> 3
        window = int.from_bytes(padded[byte:byte + 4], "little")
        v = (window >> (bitpos & 7)) & ((1 << next_bits) - 1)
        bitpos += next_bits
        return v

    if bitpos + next_bits > bitlen:
        return bytes(out)
    lastcode = extract()
    out.append(lastcode)
    entry_get()
    last_ch = lastcode

    stack = []
    while len(out) < exp_size and bitpos + next_bits <= bitlen:
        code_in = extract()
        if cur_entry == code_in:
            stack.append(last_ch)
            code = lastcode
        else:
            code = code_in
        while code >= min_table:
            stack.append(ch[code])
            code = basecode[code]
        stack.append(code)
        last_ch = code

        entry_used = True
        basecode[cur_entry] = lastcode
        ch[cur_entry] = last_ch
        children[lastcode].add(cur_entry)
        entry_get()
        while stack and len(out) < exp_size:
            out.append(stack.pop())
        lastcode = code_in
    return bytes(out)


def walk(data: bytes, block: int, size: int, dst: Path, verbose: bool,
         seen: set[int] | None = None):
    if seen is None:
        seen = set()
    if block in seen:
        return
    seen.add(block)
    off = block * 512
    for pos in range(off, off + size, 64):
        attr, = struct.unpack_from("<H", data, pos)
        rawname = data[pos + 2:pos + 40].split(b"\0")[0]
        if not rawname:
            continue
        name = rawname.decode("latin-1")
        blk, fsize = struct.unpack_from("<qq", data, pos + 40)
        if name in (".", "..") or blk <= 0 or fsize < 0:
            continue
        if attr & RS_ATTR_DIR:
            sub = dst / name
            sub.mkdir(parents=True, exist_ok=True)
            walk(data, blk, fsize, sub, verbose, seen)
        else:
            raw = data[blk * 512:blk * 512 + fsize]
            path = dst / name
            if name.upper().endswith(".Z"):
                try:
                    raw = expand(raw)
                    path = dst / name[:-2]
                except (ValueError, IndexError, struct.error) as exc:
                    print(f"{path}: expand failed ({exc}); keeping raw",
                          file=sys.stderr)
            path.write_bytes(raw)
            if verbose:
                print(f"{path} ({len(raw)} bytes)")


def find_root(data: bytes) -> tuple[int, int]:
    """The boot record points at the root; finding it by structure is
    simpler: every directory's "." entry addresses itself, but only the
    root's ".." does too."""
    for pos in range(0, len(data) - 128, 512):
        if data[pos + 2:pos + 5] != b".\0\0" or data[pos + 66:pos + 70] != b"..\0\0":
            continue
        blk, size = struct.unpack_from("<qq", data, pos + 40)
        parent, = struct.unpack_from("<q", data, pos + 104)
        if blk * 512 == pos and parent == blk and 0 < size < 1 << 20:
            return blk, size
    raise ValueError("no RedSea root directory found")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("iso", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    data = args.iso.read_bytes()
    block, size = find_root(data)
    args.outdir.mkdir(parents=True, exist_ok=True)
    walk(data, block, size, args.outdir, args.verbose)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
