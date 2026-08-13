#!/usr/bin/env python3
"""Deterministic source/asset checks for the CastleFrankenstein port."""

from __future__ import annotations

import hashlib
import re
import sys
from collections import deque
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "appl/temple/castlefrankenstein.b"


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def constant(source: str, name: str) -> str:
    match = re.search(rf"^{name}:\s*con\s+([^;]+);", source, re.MULTILINE)
    require(match is not None, f"missing {name} constant")
    return match.group(1).strip()


def map_rows(source: str) -> list[str]:
    start = source.index("castlemap := array[] of {")
    end = source.index("\n};", start)
    return re.findall(r'"([.fpsb]+)"', source[start:end])


def mesh_header(number: int) -> tuple[int, int]:
    path = ROOT / f"icons/temple/castle_{number}.mesh"
    words = path.read_text(encoding="ascii").splitlines()[0].split()
    require(words[0] == "mesh" and len(words) == 3, f"bad mesh {number} header")
    return int(words[1]), int(words[2])


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    rows = map_rows(source)
    require(len(rows) == 30, "Castle map must have 30 authored rows")
    require(all(len(row) == 34 for row in rows), "Castle map rows must be 34 cells wide")
    digest = hashlib.sha256("\n".join(rows).encode()).hexdigest()
    require(digest == "0c89fb185f1937da89dba1fb2785b6f91890faf221c06e51fef857797ed588ac",
            "authored Castle map changed unexpectedly")

    require(constant(source, "MW") == "36", "map border width changed")
    require(constant(source, "MH") == "32", "map border height changed")
    require(constant(source, "SCRN_SCALE") == "512", "HolyC projection scale changed")
    require(constant(source, "FOCAL_OFFSET") == "1.0/3.0", "focal offset changed")
    require(constant(source, "EYE_H") == "125.0/512.0", "MAN_HEIGHT conversion changed")
    require("return Vector(sx / d3c.mx, sy / d3c.my, -rz);" in source,
            "focal denominator must not replace camera-forward depth")
    require("spawn mon_timer(mtick, 20)" in source, "monster animation is not 20 ms")
    require("for(; step >= 1.0/512.0; step /= 2.0)" in source,
            "movement no longer uses HolyC half-step fallback")
    require("position_ok(nx, ny)" in source and "tile_ok(cell(x), cell(y))" in source,
            "movement clearance must explicitly floor half-cell coordinates")
    require(constant(source, "BODY_RADIUS") == "0.08", "player wall clearance changed")

    # Build the bordered map and ensure the authored start belongs to the same
    # connected walkable component as every corridor cell.
    grid = [["." for _ in range(36)] for _ in range(32)]
    for y, row in enumerate(rows, 1):
        for x, value in enumerate(row, 1):
            grid[y][x] = value
    start = (1, 26)  # (1+MAN_START_X, MH-1-MAN_START_Y), truncated as HolyC indexing
    require(grid[start[1]][start[0]] in "fp", "authored player start is not walkable")
    seen = {start}
    queue = deque([start])
    while queue:
        x, y = queue.popleft()
        for point in ((x-1, y), (x+1, y), (x, y-1), (x, y+1)):
            px, py = point
            if point not in seen and grid[py][px] in "fp":
                seen.add(point)
                queue.append(point)
    walkable = {(x, y) for y in range(32) for x in range(36) if grid[y][x] in "fp"}
    require(seen == walkable, "Castle walkable map contains a disconnected component")

    require(mesh_header(3) == mesh_header(4), "monster interpolation meshes mismatch")
    for number in range(2, 7):
        vertices, faces = mesh_header(number)
        require(vertices > 0 and faces > 0, f"mesh {number} is empty")

    print("castlefrankenstein: map, projection, collision, timing, and meshes OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, ValueError) as error:
        print(f"castlefrankenstein: {error}", file=sys.stderr)
        raise SystemExit(1)
