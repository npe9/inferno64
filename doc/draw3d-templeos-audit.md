# Where draw3d(2) is not expressive enough for the TempleOS ports

An audit, done 2026-09-06, of `math/draw3d.m` against the graphics
vocabulary the TempleOS originals in `appl/temple/` actually use. Every
claim below was checked against `/tmp/tos` (expand the ISO — see
`doc/temple-plan.md`) and against `appl/math/draw3d.b`,
`appl/math/draw3ddev.b` and `module/draw.m`, not recalled.

The short answer: **draw3d is a competent immediate-mode 3D library and
TempleOS's is a retained-mode one.** The single biggest gap is not a
missing function, it is a missing *type* — and most of the rest follows
from it.

## 1. The type gap: a sprite is a display list, not a bitmap

TempleOS's

    Sprite3(dc, x, y, z, elems)

takes `elems`, a **display list**: a packed array of typed elements
(`Adam/Gr/Gr.HH`, `SPT_END` … `SPT_TEXT_DIAMOND`, thirty kinds) that
`Sprite3` walks, executing each through the DC's *current* colour,
dither, thickness, transform, symmetry, lighting and depth-buffer state.
`Sprite3B`, `Sprite3XB`, `Sprite3YB`, `Sprite3ZB` and `Sprite3Mat4x4B`
are four-line wrappers that set `dc->x/y/z` or `dc->r` and call it.
Crucially, `SPT_MESH` and `SPT_SHIFTABLE_MESH` are *elements*: a sprite
can contain 3D geometry, and drawing it is one call.

Inferno's

    draw3d->sprite3(c, p, img, mask, scale)

takes a raster image and a mask. It projects the point and blits. The
two things share a name and nothing else.

Everything downstream is a consequence, and it is measurable in the tree:

| | count | what it means |
| --- | ---: | --- |
| `lib/temple/sprites/*.spr` element lists | 248 | extracted, with nowhere to hand them |
| `icons/temple/*.mesh` | 64 | ditto |
| `icons/temple/*.bit` + `.mask` | 230 each | pre-rasterised *because* of this |
| ports interpreting an element list in Limbo | 8 | `battlelines`, `rawhide`, `spriteplot`, `spriteedit`, `spritetext`, `stadium`, `varoom`, `zing` |
| ports looping a mesh's triangles in Limbo | 10 | `castlefrankenstein`, `keepaway`, `pick3d`, `spriteplot3d`, `rotatetank`, `shadow`, `talons`, `titanium`, `wenceslas`, `zoneout` |
| ports loading a pre-rasterised `.bit` | 35 | |

`spriteedit`'s own GAP line records the sharpest edge of it: it
implements all thirty element kinds *except* that "mesh/shiftmesh
ELEMENTS inside a sprite are inert placeholders" — because there is no
draw3d call that takes a mesh.

**What would close it:** a sprite/display-list type draw3d can execute,
and a mesh type it can take whole. Not a rewrite of the matrix code,
which is fine.

## 2. No batch entry point

    Gr3Mesh(dc, vertex_cnt, p, tri_cnt, tri)

takes whole vertex and triangle arrays and does the transform, the
symmetry reflection, the lighting callback and the fill inside one call.
draw3d has no batch entry point at all: `fillpoly3` takes one polygon,
`project` takes one vertex. Every triangle of every mesh crosses the
Limbo/library boundary individually.

This is where expressiveness and speed are the same finding:

- `polyfill->fillpoly` (the z-buffered fill `fillpoly3` drives) is
  interpreted Limbo where `Image.fillpoly` is a native draw call. On a
  synthetic frame of 200 quads and 300 triangles it costs **7.18ms a
  frame against 0.07ms**, plus 0.68ms to clear a 640x480 depth buffer.
  That measurement is why `varoom` and `talons` keep painter sorts; see
  `doc/temple-plan.md`.
- `talons`'s header already blamed "`project()` pays a 4x4 matmul per
  vertex in Limbo — far too slow for the thousands of terrain vertices
  per frame" and hand-rolled its renderer. It was right about the symptom
  and never found the cause: see §6.

## 3. Device-context state with no home

TempleOS puts these on the `CDC` and every primitive obeys them. draw3d's
`Context` has `dst`, `zstate`, `zenable`, `clipbehind`, `colour`,
`transform` and a viewport, and nothing else.

- **Symmetry.** `DCF_SYMMETRY` + `DCSymmetrySet`/`DCSymmetry3Set` install
  a mirror plane; every primitive is then drawn twice, or only mirrored
  with `DCF_JUST_MIRROR`. Ten originals use it: `battlelines`, `bigguns`,
  `blackdiamond`, `bombergolf`, `dungen`, `elephantwalk`, `griddemo`,
  `rawhide`, `strut`, `symmetry`, `talons`, `varoom`, `wallpaperfish`,
  `3dpoly`. The ports either draw everything twice or, in `3dpoly`,
  build an `I - 2nn^T` reflection matrix by hand.
- **Lighting.** `dc->ls` is a light-source vector and `dc->lighting` is a
  *replaceable function pointer* that shades a triangle; `Gr3Mesh` calls
  it per triangle. draw3d's `fillpoly3` takes a `lit` scalar the caller
  computed, and `fillpoly3g` an array of them — so the lighting model
  lives in each port, in Limbo, per vertex.
- **Dither.** `ROPF_DITHER` makes a colour a *pair* of colours;
  `ROPF_PROBABILITY_DITHER` plus `dither_probability_u16` makes the mix a
  per-pixel random draw (`0x8000` = 50/50). `Context.colour` is one
  `ref Image`. `shading`'s GAP records the workaround: an ordered 4x4
  Bayer tile, "without the noise, because draw3d(2) fills a polygon with
  one colour".
- **Brush.** `dc->brush` is a whole DC used as a pen. `Blot.HC` is built
  on it. No analogue.
- **Thickness that scales with depth.** `dc->thick` with `DCThickScale`
  and `dc->r_norm` scales stroke width by the transform. `line3`'s
  `thick` is a raw int in screen pixels.

## 4. Draw-as-query: the idea with no counterpart anywhere

The most distinctive thing in the TempleOS vocabulary is that *asking a
question is a drawing operation*. Three of them:

- `ROP_COLLISION` with `dc->bkcolor` and `dc->collision_cnt`: a raster op
  that paints nothing and counts the pixels it would have set that are
  not the background colour. Draw the shape, read the count.
- `DCF_LOCATE_NEAREST` with `dc->nearest_dist`: every primitive drawn
  through the DC updates the squared distance from the cursor to the
  nearest pixel actually painted. Drawing the scene *is* the pick.
- `DCF_RECORD_EXTENTS` with `min_x/max_x/min_y/max_y`: the bounding box
  of what was drawn, in screen coordinates.

Nothing in `draw(2)`, `draw3d(2)` or `polyfill(2)` offers any of it, and
the cost is visible in the ports: `ropcollision` and `bigguns` rebuild
`ROP_COLLISION` by compositing the frame into an offscreen RGB24 image
and walking the sprite's mask against `readpixels`; `pick` rebuilds
`DCF_LOCATE_NEAREST` as a mask-pixel scan with a bounding-box early-out;
`extents` computes its own.

This is the gap most worth closing at the `draw(2)` level rather than in
draw3d, because it is not 3D at all.

## 5. Missing primitives

Present in TempleOS, absent from draw3d:

- **Text in 3D.** `GrPrint3`, `GrPutChar3`, `GrVPrint3`, `GrTextBox3`,
  `GrTextDiamond3`. draw3d has no text call of any kind; every port draws
  its labels in screen space with `Image.text`.
- **Flood fill.** `GrFloodFill`, `GrFloodFill3`, `GrFloodFillRay`. Not in
  `draw(2)` either; `lighttable`, `varoom` and `blot` hand-roll it.
- **`GrArrow3`** (`commonancestor`, `flattops`), **`GrRegPoly3`**,
  **`GrRect3`**, **`GrBlot3`**.
- **The spline family.** `Gr2BSpline`/`Gr3BSpline`/`Gr2Bezier`/
  `Gr3Bezier` and their `*3` 3D variants. `draw(2)` has 2D `bezspline`,
  `fillbezspline`, `bezier` and `fillbezier` — which `bspline` could have
  used and did not — but draw3d has no spline at all.
- **Raster ops.** `ROP_XOR`, `ROP_EQU`, `ROP_MONO`. `draw(2)` has
  `*op` variants (`gendrawop`, `polyop`, `fillpolyop`, `ellipseop`,
  `arcop`, `bezierop`) taking Plan 9 compositing ops, and `SxorD` looks
  like the answer to `ROP_XOR`. **It is not, and this was measured:** on
  both an RGB24 and a CMAP8 surface, with an opaque source over an opaque
  destination, `SxorD`/`DxorS` through `gendrawop` clear the destination
  to index 0, and through `fillpolyop` change nothing at all; drawing
  twice never restores what was underneath. Plan 9's ops composite
  *coverage*, not pixel values. `symmetry` and `circletrace`'s GAP notes
  are right. draw3d exposes no `op` argument in any case.

## 6. Defects found while auditing

These are bugs, not design gaps, and are worth separating out.

- **`project()` computes a full MVP per vertex and throws it away.** Both
  `appl/math/draw3d.b` and `appl/math/draw3ddev.b` open `project()` with
  `matmul()`, which multiplies the 4x4 projection by the 4x4 model matrix
  into `ms.mull` — 64 multiplies and 48 adds. `ms.mull` is written there
  and **read nowhere in either file**; `toeye()` uses `hd ms.modl` and
  `toclip()` uses `hd ms.prjl` directly. Nothing outside draw3d calls
  `matmul()` (`appl/wm/collide.b` has its own `m_matmul`). Measured over
  20000 projections, five runs each way: **6ms → 2ms with the JIT and
  52ms → 14ms at `-c0`**, so two thirds of `project()`'s cost and three
  quarters of it respectively. This is what `talons` felt and routed
  around. **Fixed**; 960 projections over 24 combinations of viewport,
  projection and model matrix are byte-identical before and after, in
  both providers.
- **`fillpoly3`'s `normal` parameter is dead.** It is in the public
  signature and `appl/math/draw3d.b`'s own comment says so: the code
  "always derives its own screen-space normal from the projected vertices
  for the z-plane fit".
- **`sprite3`, `sprite3zb`, `sprite3yb` and `sprite3mat` do not use the
  z-buffer**, in either provider: they project and blit, and never touch
  `c.zstate`. `module/math/draw3d.m` says `zenable` means "use z-buffer
  for fillpoly3 / **sprites**", which is wrong. TempleOS's `Sprite3B`
  family writes the depth buffer, and `varoom`, `titanium`, `keepaway`
  and `talons` all depend on that.
- **`line3` and `plot3` do not use the z-buffer either.** TempleOS's
  `GrPlot3B` sets `dc->db_z` and plots through the depth buffer.
- **`polyfill->fillpoly` wrote depth one column past each row.** Found by
  running the nine draw3d demos while auditing: `temple/shadow` raised
  `array bounds error` a few frames in, and did so on unmodified draw3d
  too. `xscan` clamps a span's right end to the clip rectangle's
  `max.x`, which is *exclusive*, but `filllinez` fills `[left,right]`
  *inclusive* — so a span reaching the right-hand edge indexed one past
  its row of the depth buffer. On any row but the last that quietly wrote
  a depth value into column 0 of the row below (measured: a triangle
  running off the right edge clobbered twelve consecutive rows); on the
  last row it left the array and raised. **Fixed**: the depth loop stops
  at the row end, the fill still runs to `right` because the draw device
  clips the extra column itself. A 400-polygon z-buffered scene kept
  strictly inside the buffer renders bit-identically, pixels and depth,
  before and after; the same scene allowed to cross the edge renders
  identical *pixels* and a different depth buffer, which is the stray
  writes going away.

## What this cost, ranked

By how many shipped ports had to work around it:

1. **No display-list/mesh sprite type** — 8 ports interpret element lists,
   10 loop mesh triangles, 35 use pre-rasterised bitmaps, 248 `.spr` and
   64 `.mesh` files sit unused by the library.
2. **No symmetry state** — 14 originals; every port draws twice or builds
   a reflection matrix.
3. **No z on sprites, lines or points** — 8 ports whose originals use
   `DCDepthBufAlloc` or `Mat4x4` do not use draw3d at all: `box`,
   `dungen`, `keepaway`, `lattice`, `stadium`, `talons`, `titanium`,
   `varoom`. (Forty-nine originals touch *some* 3D entry point, but most
   use `GrLine3`/`Sprite3` at z=0, where not needing draw3d is correct.)
4. **No batch entry point** — the reason the z-buffered path is a hundred
   times slower than the flat one, and so the reason two renderers keep
   painter sorts.
5. **No draw-as-query** — 3 ports rebuild it from `readpixels`.
6. **No dither pair or probability** — `shading`, `sunmoon`, `psalmody`,
   `bombergolf`, `titanium`, `talons`, `3dpoly`.
7. **No 3D text, flood fill, arrow, spline** — one or two ports each.

## What is *not* a gap

Worth recording so it is not re-audited:

- The matrix stack, `push`/`pop`, `frustum`/`ortho`/`frustumoffset`,
  `viewport` and `settransform` cover `DCF_TRANSFORMATION`,
  `DCMat4x4Set`, `Mat4x4Rot*` and `dc->transform` completely.
  `frustumoffset` exists precisely because `zoneout`'s camera needed a
  shifted w-row, and it worked.
- The composition-order and z-sense conventions are settled and written
  down in `doc/temple-plan.md`; they are not a vocabulary problem.
- `fillpoly3g` covers Gouraud shading, which TempleOS does not have.
- `sprite2d` is a genuine addition for ports rendering into Tk buffers.
