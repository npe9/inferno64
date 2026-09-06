# Putting the TempleOS ports on draw3d, and thereby on Metal

`doc/draw3d-templeos-audit.md` asked where `math/draw3d`'s vocabulary is
too thin for what the TempleOS apps need. This is the other half: what to
do about it, in what order, and what has to be *measured* at each step
before moving on.

Read `doc/temple-plan.md` first for the ports themselves.

## Scope: 25 ports, not 143

"Everything in the templeos tree" cannot mean all 143 ports. Most of them
are text, DolDoc, sound, or 2D Tk apps; routing those through a 3D
pipeline would be worse, not better. The defensible target is:

| group | count | ports |
| --- | --- | --- |
| real 3D through draw3d today | 9 | `3dpoly` `castlefrankenstein` `pick3d` `rotatetank` `shading` `shadow` `spriteplot3d` `wenceslas` `zoneout` |
| `sprite2d` only (2D helper, no 3D) | 8 | `bigguns` `bombergolf` `elephantwalk` `rocket` `rocketscience` `squirt` `tothefront` `xcaliber` |
| real 3D, hand-rolled, no draw3d | 8 | `box` `dungen` `keepaway` `lattice` `stadium` `talons` `titanium` `varoom` |

(`transform` includes the module for its `Vector` type and nothing else.)

Two further facts about that table set the agenda:

- **Exactly one port reaches the device.** `castlefrankenstein.b:142`
  loads `/dis/math/draw3ddev.dis`. The other eight 3D ports load the pure
  software provider, so none of them has ever touched the GPU.
- **The ports use a fraction of the interface.** Across all 18, there is
  not one call to `line3`, `plot3`, `sprite3`, `sprite3zb`, `sprite3yb`,
  `sprite3mat`, `fillpoly3g`, `begin`/`vertex`/`end`, `circle`, `ellipse`
  or `settransform`. They use the matrix stack, `fillpoly3`, and
  `sprite2d`. Everything else in the module is dead as far as
  `appl/temple/` is concerned — which is worth knowing before adding more.

## What is true today, measured

`draw3dbench(1)` (`appl/cmd/draw3dbench.b`, added with this plan) draws
one deterministic scene through both providers, into two destinations.
Three runs on this machine, spread ±3%:

| scene | destination | software | protocol |
| --- | --- | --- | --- |
| 64 large triangles | window layer | 5.57 ms/frame | **0.79 ms/frame** |
| 64 large triangles | offscreen buffer | 5.80 ms/frame | 7.75 ms/frame |
| 512 small triangles | window layer | 4.35 ms/frame | 8.50 ms/frame |
| 512 small triangles | offscreen buffer | 4.55 ms/frame | 3.38 ms/frame |

Five things follow, and each of them changes a phase below.

**1. Metal is real here, and it wins seven to one on the scene shape the
ports actually have.** With `INFERNO_METAL_STATS=1`, `g3_calls` is zero
through both software cases and in the thousands through the protocol
cases, with `soft_fallbacks=0` throughout — the geometry genuinely
reaches the GPU rather than falling back inside devdraw. A wall-sized
triangle is what `castlefrankenstein`, `dungen`, `stadium` and `varoom`
draw, and for those the app's own frame cost drops from 5.6 ms to
0.79 ms.

**2. An offscreen buffer gets no GPU at all.** `metal_queue_fillpoly3d()`
in `emu/MacOSX/win-cocoa.m` returns 0 unless the destination is `gscreen`,
`screenimage`, or a *fully clear* layer of the screen; anything else is
refused before a vertex is looked at. So a port that composes its frame
into a `newimage` buffer and blits at the end — 34 of the 144 do allocate
such a buffer — cannot be accelerated, and through the protocol provider
it is *slower* than the software one (7.75 vs 5.80 ms), because it pays
the wire cost and still rasterises on the CPU. Loading `draw3ddev.dis`
without also moving the destination is a pessimisation, not an
optimisation.

**3. The wire is already batched; the argument for a mesh call is not
syscalls.** `Display.writedraw` (`libinterp/draw.c:1227`) calls
`bufimage()`, which appends to the display's buffer and flushes later —
one message is a `memmove`, not a write. A batch entry point is still
worth having, but for Limbo-side per-call cost (measured at about 6.6 µs
per triangle on the protocol path with the GPU out of the picture) and
for the ring in point 5, not for system calls.

**4. GPU pixels cannot be read back through a window layer.** After a
protocol frame into `win.image`, `readpixels` on that layer returns
nothing lit; the same read of the display's screen image sees the
geometry. The readback machinery does run — `readbacks` counts up, and
devdraw's read message calls `gpudrawreadback()` — so this is a hole in
the layer read path, not a missing readback. It matters because several
ports query pixels: `xcaliber`'s laser walk, `ropcollision`'s collision
count, flood fills.

**5. There is no back-pressure signal, only a spin.** Geometry the GPU has
not yet presented lives in a fixed 49152-vertex ring
(`MaxGPUTriVerts`), drained only by `present_softscreen()` on the main
thread. `Flushnow` does *not* drain it — `metal_flush_geom()` only
snapshots the softscreen. When a program submits faster than the
presenter runs, `metal_tri3d_reserve()` spins in `osyield()` until it
catches up. That, not per-triangle cost, is what the 8.50 ms figure in
the 512-triangle row measures. There is also a ceiling of
`MaxG3Batches = 64` distinct model/projection transforms per frame.

## Order of work

Each phase names the evidence that closes it. A phase is not done because
the code compiles; it is done when the stated number moved and a negative
control put it back.

### Phase 1 — reach the device at all

Change the nine 3D ports from `load Draw3d Draw3d->PATH` to
`/dis/math/draw3ddev.dis`. This is safe without the two-line fallback
idiom that `draw3ddemo.b:56` established, because `draw3ddev.b` already
degrades internally: `haveproto` is set from `probe()`, and every
primitive has a software branch behind it. The idiom only guards against
the `.dis` file being absent, which is worth keeping for exactly that
reason, but it is not what makes the fallback work.

Do **not** do this for a port whose frame goes into an offscreen buffer
until Phase 2 has moved it; per point 2 that would make it slower.

*Evidence:* per-port ms/frame before and after, and
`INFERNO_METAL_STATS=1` showing `g3_calls` rise from zero with
`soft_fallbacks` still zero. Negative control: put the load line back and
watch `g3_calls` return to zero.

### Phase 2 — draw where the GPU can see it

Audit the in-scope ports for a `newimage` frame buffer and split them:

- **Double buffering only.** Draw straight into the window layer; it is
  already backed, and `wmclient` handles the flush. These move now.
- **Pixel queries.** `xcaliber` reads the beam bounding box back;
  `ropcollision` walks a mask against the buffer; flood fills read.
  These are blocked on Phase 3 and stay on the software path until it
  lands, with a comment saying so.

*Evidence:* the port's own lit-pixel count is unchanged (the frame must
look the same), and `g3_calls` becomes nonzero.

### Phase 3 — fix layer readback

Point 4 above is a bug with a one-line reproducer in `draw3dbench(1)`.
Until it is fixed, any port that mixes GPU 3D with `readpixels` silently
reads black, which is worse than being slow.

*Evidence:* `draw3dbench`'s last line reports a nonzero count for the
window layer. Negative control: revert the fix, confirm it returns to
zero.

### Phase 4 — close the z gap in the Limbo fallback

The device depth-tests sprites, ellipses, lines and plots
(`d3spritez`, `d3ellipsez`, `d3zpixel` in `emu/port/devdraw.c`). Neither
Limbo provider does: `sprite3*`, `line3` and `plot3` project and blit and
never touch `c.zstate`. That asymmetry is tolerable today only because no
temple port calls those entry points — but it stops being tolerable the
moment one does, because the fallback is what every non-Metal host and
every `emu-g` run takes. A port that renders correctly on Metal and
wrongly headless is worse than one that is slow both ways.

*Evidence:* a scene with a sprite behind a wall renders identically
through `draw3d.dis`, through `draw3ddev.dis` with the protocol, and
through `draw3ddev.dis` with the probe forced to fail. Negative control:
disable the z test and confirm the sprite punches through.

### Phase 5 — a batch entry point

Add a mesh call to the module — vertices, triangle indices, one lit per
face or per vertex — with a protocol message and a Metal path that
reserves the whole run once. Ten ports already load `.mesh` assets
(`castlefrankenstein`, `keepaway`, `pick3d`, `rotatetank`, `shadow`,
`spriteplot3d`, `talons`, `titanium`, `wenceslas`, `zoneout`) and every
one of them walks the triangle list in Limbo. TempleOS has exactly this
call, `Gr3Mesh(dc, vertex_cnt, p, tri_cnt, tri)`; the audit's §2 is about
its absence.

While in there, deal with the ring: a mesh larger than what is free
should fail cleanly or drain, not spin, and `MaxG3Batches = 64` needs
either raising or a documented limit.

*Evidence:* `draw3dbench` grows a mesh case; the protocol figure for 512
small triangles must fall, and the spin in point 5 must stop showing up
as a stall. Measure with the GPU out of the picture too (offscreen
destination), so the Limbo-side saving is separable from the Metal one.

### Phase 6 — the display-list sprite type

This is the audit's headline gap and the place a plan can burn the most
work, so it is gated on one port.

TempleOS's `Sprite3` executes a display list of up to 30 element kinds;
this tree has 248 `.spr` files holding exactly such lists, and
`spriteedit.b` already interprets every kind in Limbo. That interpreter is
the reference implementation to hoist into `draw3d` as a first-class
type, so a `.spr` can be handed over whole instead of being walked
element by element by each of the twelve ports that read one.

*Evidence:* pick a single one of those twelve that currently
pre-rasterises its sprite, render it from the `.spr` through the new
type, and compare pixels against the port's `.bit`. Do not schedule the
other eleven until that comparison passes.

### Phase 7 — DC state

The audit's §3: a symmetry plane (`DCF_SYMMETRY`), a light source and a
replaceable lighting hook (`dc->ls`, `dc->lighting`), the dither pair and
`ROPF_PROBABILITY_DITHER`, `dc->brush`, and depth-scaled `dc->thick`.
Each of these is state the ports currently re-implement per port or drop.

*Evidence:* one port per feature, against the original's output.

### Phase 8 — draw as query

`ROP_COLLISION` with `collision_cnt`, `DCF_LOCATE_NEAREST` with
`nearest_dist`, `DCF_RECORD_EXTENTS` with the min/max box. These are the
audit's §4. They belong at the `draw(2)`/devdraw level rather than inside
draw3d, because the device is already walking the pixels — it is the only
place where the answer is free. `ropcollision` and `xcaliber` are the
callers that exist today.

### Phase 9 — the eight hand-rolled ports

`box`, `dungen`, `keepaway`, `lattice`, `stadium`, `talons`, `titanium`,
`varoom` each grew their own projection and their own depth handling
because draw3d did not offer what they needed. Move them last, when it
does. `varoom` and `talons` keep painter-order sorts specifically because
z-buffered filling in Limbo was too slow; with the GPU doing the fill,
re-measure whether the sort can go.

*Evidence:* per port, frame time and a pixel comparison against the
pre-migration render.

## What this plan is not doing

- **The 125 ports with no 3D.** They stay as they are.
- **Making `polyfill` faster.** It is interpreted Limbo, and the answer to
  its cost is to stop calling it, which is what every phase above is
  about. Optimising it would be work against the grain of the fix.
- **A second GPU backend.** The Metal hooks are the only ones wired
  (`emu/MacOSX/win-cocoa.m:557`); the protocol is backend-neutral and
  another host can fill them in, but nothing here depends on that.

## Traps

- **`emu-g` has no Metal and no `Draw`.** The GPU path cannot be covered
  headlessly, so every phase needs its software-fallback equivalent
  checked as well, and `draw3dbench` has to be run under `emu-cocoa`.
- **Presentation is coalesced.** `present_on_main()` runs on the main
  thread and `Flushnow` does not force it, so a tight render loop
  measures submission, not display. Use `draw3dbench -p` when you want
  the per-30-frame `INFERNO_METAL_STATS` line to appear at all.
- **A demo that starts and survives proves startup.** Same rule as
  `doc/temple-plan.md`: no input is delivered, so the interesting code
  never runs. Assert on numbers.
- **`big` is a reserved word in Limbo** and the error it gives is a
  syntax error four lines away from the declaration.
