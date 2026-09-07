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
Under `emu-cocoa` at 640x480, `-n 120`, JIT (the default); the software
column is interpreted Limbo, so `-c0` moves it a great deal further and
the protocol column much less, which makes these the *conservative*
ratios:

(Read the protocol column as "what the app's frame loop costs", not as
"what it costs to render this" - see point 1.)

| scene | destination | software | protocol | `-c0` software | `-c0` protocol |
| --- | --- | --- | --- | --- | --- |
| 64 large triangles | window layer | 5.64 ms | **0.88 ms** | 68.6 ms | 7.30 ms |
| 64 large triangles | offscreen buffer | 5.85 ms | 7.80 ms | 72.1 ms | 14.8 ms |
| 512 small triangles | window layer | 4.52 ms | **1.52 ms** | 33.2 ms | 9.63 ms |
| 512 small triangles | offscreen buffer | 4.66 ms | 3.46 ms | 35.1 ms | 11.9 ms |

Five things follow, and each of them set a phase below.

**1. The GPU path submits geometry that Metal does not draw. The timings
below are real; what they time is not a render.** Corrected 2026-09-06,
having been stated the other way round first, which is the most
important thing in this document.

`g3_calls` counts *submissions*, not pixels, and it was the only evidence
behind the original claim. Three later measurements say the pixels never
arrive:

- One large red triangle, one frame, held on screen. Captured from
  outside emu, against the same desktop, the software provider puts 8762
  strongly-red samples on the screen and the protocol provider puts 87 -
  which is the background.
- The readback pass runs on that geometry, with 192 vertices in one
  batch and an encoder created, and `getBytes` leaves gscreen's nonzero
  byte count *exactly* unchanged at 48182, the window border.
- The nine ports Phase 1 moved still render, because they draw a great
  deal in 2D as well; their 3D content has not been isolated.

Two hypotheses tested and rejected. The readback texture is
`RGBA8Unorm` where every geometry pipeline declares `BGRA8Unorm`, which
looked like the answer; making them agree changed nothing. And the
GPU-T&L branch in `emu/port/devdraw.c` jumps to `gdone` without a
`dstflush`, so nothing asks for a present after 3D geometry is queued -
a real latent bug, since a client that draws *only* 3D never presents at
all - but adding the flush did not make the triangle appear either.

So the cause is still open, and it is now the first thing to fix: until
it is, `D3CapGPU` is a fast way of drawing nothing. The timings that
follow are what the app's own frame loop costs, which is a real number
and the reason the protocol provider is worth having even on the CPU
path - `draw3ddev.dis` falls back to devdraw's C rasteriser, which is
much faster than Limbo - but they are not evidence of GPU rendering.

**2. An offscreen buffer gets no GPU at all.** `metal_queue_fillpoly3d()`
in `emu/MacOSX/win-cocoa.m` returns 0 unless the destination is `gscreen`,
`screenimage`, or a *fully clear* layer of the screen; anything else is
refused before a vertex is looked at. A program that composes its frame
into a `newimage` buffer and blits at the end cannot be accelerated, and
through the protocol provider that costs it 7.80 ms against the software
provider's 5.85 on the large-triangle scene — the wire cost on top of a
CPU rasterisation. Loading `draw3ddev.dis` without also checking where
the frame is drawn can be a pessimisation rather than an optimisation.

**3. The wire is already batched; the argument for a mesh call is not
syscalls.** `Display.writedraw` (`libinterp/draw.c:1227`) calls
`bufimage()`, which appends to the display's buffer and flushes later —
one message is a `memmove`, not a write. A batch entry point is still
worth having, for Limbo-side per-call cost (the protocol path costs about
6.8 us per triangle with the GPU out of the picture, against roughly 3 us
with it), but not for system calls.

**4. A readback after a GPU pass returns none of the geometry.**
`draw3dbench` looks twice, because the two ways of looking exercise
different code. A `draw()` into a scratch image copies bytes and never
gives the device a chance to bring GPU output back; a `readpixels()`
straight off the target goes through devdraw's read message, which calls
`gpudrawreadback()` first. Both agree, and the software provider is the
control:

| provider | layer, via draw | layer, direct read | screen, via draw | screen, direct read |
| --- | --- | --- | --- | --- |
| software | 210183 | 210183 | 226349 | 258365 |
| protocol | **0** | **0** | **16166** | **48182** |

(The draw columns count pixels and the read columns count nonzero bytes,
so read across a row, not down a column.) The window's border is
226349 - 210183 = 16166 pixels and 258365 - 210183 = 48182 bytes — which
is exactly, in both metrics, what the protocol provider's screen read
returns. It gets back the border and not one pixel of geometry, and
through the window layer it gets back nothing at all. Layer reads are
therefore not the problem, the software control proves them working on
the same scene through the same code, and this is not a partial readback.
The machinery does run — `readbacks` counts up — it just produces
nothing. This matters because several ports query pixels: `xcaliber`'s
laser walk, `ropcollision`'s collision count, flood fills.

**5. A reproducible one-off stall, cause unidentified.** At exactly
`-n 60` — the old default — the 512-triangle protocol case takes 8.4 ms
per frame instead of 1.5, and the per-frame maximum shows why: a single
414 ms stall in one frame. It is absent at `-n 10`, `20`, `40`, `50`,
`55` and `120` (worst frame 2-3 ms), reproducible at `-n 60` across
runs, and decays through `-n 65`, `80` and `100`. The obvious suspect is
the geometry ring — 49152 vertices (`MaxGPUTriVerts`), drained only by
`present_softscreen()` on the main thread, with `Flushnow` *not* draining
it (`metal_flush_geom()` only snapshots the softscreen) and
`metal_tri3d_reserve()` spinning in `osyield()` until the presenter
catches up. But saturation would predict a stall at a fixed frame count
and worse behaviour at more frames, and `-n 120` is clean, so the ring is
not what this measurement shows. The ring and the missing back-pressure
signal are real properties of the code and are dealt with in Phase 5;
this particular stall is an open question with a one-command reproducer.
There is also a ceiling of `MaxG3Batches = 64` distinct model/projection
transforms per frame.

## The ports still on software rendering: do they need it?

Asked after Phase 1, and answered by measurement rather than by
assumption. Two groups are left, and they need different things.

**The eight `sprite2d` ports gain nothing from the provider.** `sprite2d`
is the *same Limbo pixel loop in both providers* — neither sends a
message — so `draw3ddemo`'s load idiom would do nothing for `bigguns`,
`bombergolf`, `elephantwalk`, `rocket`, `rocketscience`, `squirt`,
`tothefront` or `xcaliber`. `draw3dbench` has a sprite case that makes
this a measurement: the provider column comes out flat, 1705 µs against
1695 µs for a 220x220 sprite.

The cost was in the loop itself, and it is now gone for the case that
mattered. With no rotation the inverse transform is separable, so the
real arithmetic hoists into two tables, and when those come out as the
identity the whole operation is a masked blit: 220x220 unrotated fell
from 1705 µs to 35 µs against a 30 µs floor for the equivalent `draw()`.
That is `elephantwalk`'s frame cost, 1.6 ms of it. The rotated path still
costs about 2.6 ms at that size, but no port rotates a sprite anywhere
near it — the largest is `bombergolf`'s 84x34 at about 260 µs — so it
does not need work. (Fixing the resample also turned up that every sprite
in the tree was drawn a column and a row out of place; see
`sprite2dtest(1)`.)

**The eight hand-rolled ports are not slow enough to matter.** `box`,
`dungen`, `keepaway`, `lattice`, `stadium`, `talons`, `titanium` and
`varoom` draw with `Image.fillpoly`, `Image.line` and `Image.draw`. Those
run in C in libmemdraw and have *no* GPU hook: devdraw's `case 'p'`/`'P'`
and `case 'L'` call `mempoly`/`memfillpoly`/`memline` directly, and the
`gpudraw*` hooks are wired only into the draw3d messages. So they are not
on the GPU — but they are already in C, which is where most of the win
would have come from.

CPU used over a five-second window, one core = 100%:

| port | CPU | port | CPU |
| --- | --- | --- | --- |
| `keepaway` | 22% | `titanium` | 4% |
| `varoom` | 17% | `box` | 2% |
| `stadium` | 9% | `lattice` | 1% |
| `talons` | 8% | | |
| `dungen` | 7% | (`tictactoe`, idle baseline) | 3% |

For comparison the nine ports Phase 1 moved to the GPU run at 0–10%
(`castlefrankenstein` 10%, `shading` and `shadow` 8%, `zoneout` 7%,
`3dpoly` 6%, `elephantwalk` 3%, `pick3d` and `spriteplot3d` 1%,
`rotatetank` 0%). Nothing in the tree is close to saturating a core.

So Phase 9 stays where it is, and it is about vocabulary rather than
speed: these ports grew their own projection and depth handling because
draw3d did not offer what they needed, and the reason to move them is
that it will. **Caveat**: these figures are from each port's idle or
attract state, because no input is delivered — the same limit
`doc/temple-plan.md` warns about. A port whose gameplay draws far more
than its attract screen would not show it here.

## Order of work

Each phase names the evidence that closes it. A phase is not done because
the code compiles; it is done when the stated number moved and a negative
control put it back.

### Phase 0 — make the Metal geometry path draw at all

Point 1. Nothing else in this plan means anything until a triangle
submitted to `gpudrawfillpoly3d` appears on the screen. The reproducer
is a dozen lines: one `fillpoly3` of a large triangle into a `wmclient`
window through `/dis/math/draw3ddev.dis`, held on screen, captured from
outside.

Two things to fix on the way, both real whatever the main cause turns
out to be: the readback texture's pixel format disagrees with every
geometry pipeline's, and the GPU-T&L branch never requests a present.

*Evidence:* the capture shows the triangle, and `draw3dbench`'s readback
line stops reading back the border alone. Negative control: revert, and
both go back.

### Phase 1 — reach the device at all

Change the nine 3D ports from `load Draw3d Draw3d->PATH` to
`/dis/math/draw3ddev.dis`. This is safe without the two-line fallback
idiom that `draw3ddemo.b:56` established, because `draw3ddev.b` already
degrades internally: `haveproto` is set from `probe()`, and every
primitive has a software branch behind it. The idiom only guards against
the `.dis` file being absent, which is worth keeping for exactly that
reason, but it is not what makes the fallback work.

Checked before proposing it: all nine draw straight into `win.image`.
The three that call `newimage` (`3dpoly`, `shading`, `wenceslas`) use it
for small textures and masks, not for a frame buffer, so none of the nine
is blocked by point 2 and all nine can move together.

*Evidence:* `INFERNO_METAL_STATS=1` showing `g3_calls` rise from zero
with `soft_fallbacks` still zero. Negative control: put the load line
back and watch `g3_calls` return to zero.

**Done.** Eight ports changed (`castlefrankenstein` already did it), and
each was run for eight seconds under `emu-cocoa` with the counters on.
Highest `g3_calls` seen in a 30-frame window, `soft_fallbacks` zero in
every case:

| port | `g3_calls` | port | `g3_calls` |
| --- | --- | --- | --- |
| `shading` | 30720 | `rotatetank` | 2460 |
| `castlefrankenstein` | 20550 | `pick3d` | 1560 |
| `zoneout` | 17220 | `shadow` | 1320 |
| `wenceslas` | 55440 | `3dpoly` | 300 |
| | | `spriteplot3d` | 240 |

`wenceslas` reports zero when simply started, because its 3D is behind
`if(page >= 3)` and the two popup pages need a keypress to dismiss — the
`doc/temple-plan.md` rule about a demo that starts and survives, exactly.
Forcing `page := 3` gives the 55440 above. That port also carried the
negative control: with `page` still forced and only the load line put
back to `Draw3d->PATH`, `g3_calls` returns to 0.

### Phase 2 — draw where the GPU can see it

Phase 1's nine are clear, but 34 of the 144 ports do allocate an
offscreen frame buffer, and the eight `sprite2d` ports and the eight
hand-rolled ones have not been checked. Audit those sixteen and split
them:

- **Double buffering only.** Draw straight into the window layer; it is
  already backed, and `wmclient` handles the flush. These move now.
- **Pixel queries.** `xcaliber` reads the beam bounding box back;
  `ropcollision` walks a mask against the buffer; flood fills read.
  These are blocked on Phase 3 and stay on the software path until it
  lands, with a comment saying so.

*Evidence:* the port's own lit-pixel count is unchanged (the frame must
look the same), and `g3_calls` becomes nonzero.

### Phase 3 — make the GPU readback produce pixels

Point 4 is a bug with a two-line reproducer in `draw3dbench(1)`, and it
already has its own control: the software provider reads back correctly
on the same scene through the same code, so the fault is in what the
readback writes and not in reading a layer. Until it is fixed, any port
that mixes GPU 3D with `readpixels` silently reads black, which is worse
than being slow.

Start by checking whether `metal_readback_geom()` is writing into
`gscreen` while the reader is looking at `screenimage` or at the layer's
backing store; the two are distinguished in `metal_queue_fillpoly3d()`
and may not be the same image here.

*Evidence:* `draw3dbench`'s last two lines agree between providers.
Negative control: revert the fix, confirm the protocol row returns to
0 / 16166.

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
should fail cleanly or drain, not spin in `osyield()`, and
`MaxG3Batches = 64` needs either raising or a documented limit. The
stall in point 5 is the thing to chase here, since this is the code it
would live in.

*Evidence:* `draw3dbench` grows a mesh case; the protocol figure for 512
small triangles must fall. Measure with the GPU out of the picture too
(offscreen destination), so the Limbo-side saving is separable from the
Metal one, and re-run the `-n` sweep to see whether the stall is gone.

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
- **Sweep the frame count before quoting a per-frame figure.** A single
  frame count can sit on an artifact: `-n 60` reports 8.4 ms/frame where
  `-n 55` and `-n 120` report 1.5, and only the per-frame maximum shows
  that the difference is one 414 ms stall rather than a slower renderer.
  `draw3dbench` prints `worst=` for exactly this reason.
- **A demo that starts and survives proves startup.** Same rule as
  `doc/temple-plan.md`: no input is delivered, so the interesting code
  never runs. Assert on numbers.
- **`big` is a reserved word in Limbo** and the error it gives is a
  syntax error four lines away from the declaration.
