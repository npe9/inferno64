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


def code_only(source: str) -> str:
    """Source with Limbo comment lines removed.

    Structural checks below match on text, and this file's own prose quotes
    the very calls they look for -- line 461 says "the shifted-w perspective
    is draw3d->frustumoffset()" and line 460 says "by (z + FOCAL_OFFSET)".
    Two assertions were therefore satisfied by COMMENTS and passed while the
    code was mutated out from under them: replacing frustumoffset with
    frustum, and replacing FOCAL_OFFSET with 0.0, were both accepted.  Found
    by mutating the source and watching the test not care.
    """
    return "\n".join(l for l in source.splitlines()
                      if not l.lstrip().startswith("#"))


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
    # The projection moved from a per-vertex Limbo closure into real
    # matrices in 6d573b870 ("the shifted-w perspective is
    # draw3d->frustumoffset()"), so that devdraw -- and eventually the GPU --
    # does the transform instead of interpreted bytecode.  That commit deleted
    # the line this test used to require,
    #
    #   return Vector(sx / d3c.mx, sy / d3c.my, -rz);
    #
    # and did not update the test, so this file has failed since.  Bisected:
    # the assertion and the matching source were both present in 6d573b870~1.
    #
    # Asserting the new form rather than deleting the check, because the
    # invariants it was protecting still exist and are still worth pinning --
    # they are now arguments to one call instead of a formula.
    code = code_only(source)
    require("draw3d->frustumoffset(" in code,
            "the projection must be set up as a matrix, not a per-vertex closure")
    require("draw3d->settransform(" not in code,
            "the per-vertex settransform closure must stay gone; it is the "
            "thing the matrix path replaced")
    # The shifted-w perspective: dividing by (z + FOCAL_OFFSET) and not by a
    # bare z is the whole reason frustumoffset exists rather than frustum.
    require("FOCAL_OFFSET)" in code,
            "the perspective divide must still be shifted by FOCAL_OFFSET")
    # Y inversion.  Draw screen Y grows downward and world Y grows upward, and
    # the original code carried a comment saying the previous sign "put the
    # floor above the camera" -- so the minus on the sy argument is a bug that
    # has already happened once.
    require("-(real SCRN_SCALE/2.0) / d3c.my" in code,
            "perspective Y must stay inverted, or the floor renders above the camera")
    # Scale divided by the live viewport half-extent rather than baked in, so
    # that a resize does not change the field of view.
    require("(real SCRN_SCALE/2.0) / d3c.mx" in code,
            "the X scale must divide by the viewport half-extent, as the "
            "per-vertex code did, so resize is exact")
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
