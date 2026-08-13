#!/usr/bin/env python3
"""Extract TempleOS SPT_MESH DolDoc bins as portable text meshes."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def docbins(data: bytes):
    end = data.index(0) + 1
    while end + 16 <= len(data):
        num, _flags, size, _uses = struct.unpack_from("<IIII", data, end)
        end += 16
        if end + size > len(data):
            raise ValueError("truncated DolDoc bin")
        yield num, data[end : end + size]
        end += size


def mesh(blob: bytes):
    if not blob or blob[0] & 0x7F != 24:
        return None
    p = 0
    verts = []
    tris = []
    while p < len(blob) and blob[p] != 0:
        if blob[p] & 0x7F != 24:
            raise ValueError(f"unsupported element {blob[p] & 0x7F} at {p}")
        nvert, ntri = struct.unpack_from("<II", blob, p + 1)
        p += 9
        base = len(verts)
        verts.extend(struct.unpack_from("<iii", blob, p + 12 * i)
                     for i in range(nvert))
        p += 12 * nvert
        part = [struct.unpack_from("<IIII", blob, p + 16 * i)
                for i in range(ntri)]
        if any(max(a, b, c) >= nvert for _col, a, b, c in part):
            raise ValueError("mesh triangle has an invalid vertex index")
        tris.extend((colour, a + base, b + base, c + base)
                    for colour, a, b, c in part)
        p += 16 * ntri
    if p != len(blob) - 1:
        raise ValueError(f"invalid SPT_MESH tail at {p}")
    return verts, tris


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("-o", "--outdir", type=Path, required=True)
    ap.add_argument("--prefix", default=None)
    args = ap.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or args.source.stem.lower()
    for num, blob in docbins(args.source.read_bytes()):
        decoded = mesh(blob)
        if decoded is None:
            continue
        verts, tris = decoded
        dst = args.outdir / f"{prefix}_{num}.mesh"
        with dst.open("w", encoding="ascii") as out:
            out.write(f"mesh {len(verts)} {len(tris)}\n")
            for x, y, z in verts:
                out.write(f"v {x} {y} {z}\n")
            for colour, a, b, c in tris:
                out.write(f"f {colour} {a} {b} {c}\n")
        print(f"wrote {dst} ({len(verts)} vertices, {len(tris)} triangles)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
