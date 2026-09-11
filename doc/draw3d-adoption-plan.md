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

| scene | destination | software | protocol | `-c0` software | `-c0` protocol |
| --- | --- | --- | --- | --- | --- |
| 64 large triangles | window layer | 5.64 ms | **0.88 ms** | 68.6 ms | 7.30 ms |
| 64 large triangles | offscreen buffer | 5.85 ms | 7.80 ms | 72.1 ms | 14.8 ms |
| 512 small triangles | window layer | 4.52 ms | **1.52 ms** | 33.2 ms | 9.63 ms |
| 512 small triangles | offscreen buffer | 4.66 ms | 3.46 ms | 35.1 ms | 11.9 ms |

Five things follow, and each of them set a phase below.

**1. Metal now draws. It did not until 2026-09-06, and the first two
versions of this document claimed a GPU win on the strength of a
submission counter.** `g3_calls` counts submissions, not pixels; the
pixels were not arriving.

The cause: draw3d's own projection leaves clip *w* as the eye z, and its
camera looks down −Z, so **w is negative for everything in front of the
eye**. The software rasteriser does not care — it divides by w, and a
negative one just mirrors — but Metal clips to `0 <= z <= w` and
`-w <= x,y <= w`, which discards every vertex with w < 0. That was the
whole scene, silently. `vgmain` now negates the clip vector when w is
negative, which leaves x/w and y/w exactly as they were.

Three plausible guesses were wrong before that one, and each had to be
ruled out rather than argued away: the readback texture's `RGBA8Unorm`
against the pipelines' `BGRA8Unorm`; the missing `dstflush` on devdraw's
GPU-T&L branch (a real latent bug — a client that draws only 3D never
asks for a present — but not this); and the overlay pass, which discards
where the softscreen is unchanged and so never covered the geometry.
Replacing the vertex shader's transform with a hard-coded NDC triangle
was what showed the pipeline itself worked.

A second bug was hiding behind the first, and it is fixed too:
`src_rgba()` read bytes 0, 1 and 2 as red, green and blue for *every*
channel, which is right only for `XBGR32`. A Plan 9 channel descriptor
names its components from the most significant byte down, so `RGB24` —
what `Display.color` hands out — is B, G, R in memory, and every GPU
primitive drew a red source blue. Nobody had seen it because the
geometry path drew nothing at all.

I first read that swap as a *mirror*, from a screenshot histogram split
into thirds: the red triangle really was on the right in both, but the
GPU drew it blue, so the histogram said "blue on the right". The
in-process check below found the truth in one run. Screenshot analysis
was the wrong instrument once a readback was available.

**And the readback was never broken.** It reported the window border and
nothing else because there was nothing else; with the clip fixed,
`draw3dbench`'s readback line goes from 16166 to 225862. What remains
true is narrower: reading GPU output requires a `readpixels` *straight
off the image*, since that goes through devdraw's read message and calls
`gpudrawreadback()`. Copying the image into a scratch with `draw()`
first, which is what a port compositing its window into a buffer does,
still sees nothing.

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

### Phase 0 — make the Metal geometry path agree with the software one

**Done.** `draw3dbench`'s last section draws a red, a green and a blue
triangle at known world x through both providers and reports where each
lands and what colour it is; they agree to within a pixel, reproducibly.
That check is the thing to run before trusting any of the timings above,
because both of the bugs it caught were invisible to a timing.

One thing is still open. **A client that draws only 3D shows nothing,
even when it flushes.** Every other primitive here ends in a
`dstflush`, which is what records damage and eventually schedules a
present; the GPU-T&L branch falls straight through to `gdone` without
one. That looked like the answer and is not: adding
`dstflush(dst, dst->clipr)` there does not make such a client's window
show anything, so it was reverted rather than shipped on a guess.
Whatever the cause, it does not affect the ports, which all draw a
background or a HUD in 2D as well - the reproducer has to draw its
first frame and then nothing but `fillpoly3`.

The readback texture's `RGBA8Unorm` against the pipelines'
`BGRA8Unorm` is *not* a bug to fix, which took a measurement to
establish: the shader writes r,g,b,a, an `RGBA8Unorm` target puts them
in memory as R,G,B,A, and that is exactly the order `gscreen` (XBGR32)
wants. Changing the texture to match the pipeline would break the
readback.

A trap worth keeping: **do not flush before reading back.** A present
drains the GPU's geometry queue, and the readback then has nothing to
replay into the softscreen, so the read sees an empty window. That
looked like flakiness for a while.

The nine ports Phase 1 moved were therefore rendering *without their 3D
content* between that commit and the clip fix, which nobody would have
noticed from a screenshot because they all draw a background and a HUD
in 2D as well. Captured at the same four-second mark, `shading` puts
13304 saturated samples on the screen through the GPU against the
software provider's 12557 — agreement, for an animated demo. Before the
fix the same comparison was 11200 against 14448, a 22% shortfall.

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

### Phase 2 answered, for the destination question at least

Measured 2026-09-10 with `gorge(1)`, which draws about two hundred
Gouraud faces straight into the window image, and with `draw3dbench`
under `INFERNO_METAL_STATS=1`:

| how it is run | `g3_calls` | us a frame |
| --- | --- | --- |
| started directly, device provider | 40708 per 30 frames | 2408 |
| started directly, software provider | 0 | 73366 |
| under `wm(1)`, device provider | **0** | panics, see below |
| under `wm(1)`, software provider | 0 | 53250 |

So **the GPU is reached only when there is no window manager between the
program and the screen.** `metal_queue_fillpoly3d()` takes `gscreen` or
`screenimage`, or a layer whose `l->clear` is set — and a `wm(1)`
client's window is a layer that is not clear. Under `wm` every face
falls back to the CPU path in devdraw, and the device provider is then
*slower* than the software one because it pays the wire cost on top:
`draw3dbench`'s 64-large-triangle row goes 5941 us software against 7916
us protocol under `wm`, and 13025 against 1958 without it.

That is the answer to "draw where the GPU can see it": it is not enough
to avoid an offscreen buffer. The nine Phase 1 ports draw into their
`wmclient` window, so on this host they get no GPU either unless they
are started outside `wm`. Phase 1's numbers were taken without one.

**And driving the device provider under `wm` panics emu**, reproducibly,
with `panic: pushrun addrun` from `pushrun()` in `emu/port/dis.c` — a
`Prog` pushed onto the run queue while it already has a pending
`addrun`. `gorge -D` reproduces it three times out of three, headless or
under `wm`, with the JIT on or off and with audio disabled. It has not
been reduced below that program: a loop of 200 frames of 130 Gouraud
quads plus a `sprite3zb` into a memory image through the same provider
survives. `gorge` works round it by choosing its provider from whether a
`Draw->Context` was handed to it, which is exactly the condition, but
the panic is real and is somebody's bug.

### Phase 2b — the GPU path draws the wrong picture

Found 2026-09-10 by photographing the screen from outside `emu`, which
is the only way to see it: a `readpixels` of a GPU pass returns nothing
(Phase 3), so every check inside the process is blind to this.

`gorge(1)` through `draw3ddev` with no window manager: `g3_calls` 5915
and 6257 in two runs, `soft_fallbacks` 0, 2408 us a frame. And the frame
on the screen is **missing the ship, the pylons and the entire head-up
display**, with the canyon itself mis-composed. The same scene through
the software provider has all of it. Two captures out of two.

The visible mechanism is ordering: the geometry queue is drained at
present time, *after* everything the CPU drew into the same window, so
GPU output paints over the 2-D rather than under it. Anything a port
draws after its 3-D — text, a HUD, a reticle — is lost.

**This is the trap this document already warns about, walked into
anyway.** `g3_calls` being high and `soft_fallbacks` zero establishes
two real things: the geometry reached the hardware, and `devdraw` did
*not* draw it on the CPU (a successful `gpudrawfillpoly3d` does `goto
gdone`, `devdraw.c:3326`). Neither says the result is correct.
`draw3ddemo`'s own comment records the same shape of failure for
`frustum` — submissions counted, colours valid, nothing rasterized. A
submission counter and a frame timer both said the GPU was working.

Phase 1's per-port evidence is `g3_calls` plus an unchanged lit-pixel
count. The lit-pixel count is the part that would have caught this, and
it cannot be taken through a GPU pass — so for the nine Phase 1 ports it
was taken on the software path. **Their pictures have not been checked
either.** That wants doing before any more ports move.

`gorge(1)` and `strider(1)` therefore default to the software provider
and offer `-D` for the other one, and say on screen which is in use.

**Now reproducible from inside the process, 2026-09-11.** With Phase 3
fixed, `gorge -g` reads its own window back and counts two things: the
pixels that are not sky, and the pixels that are white — which is the
head-up display, and which is exactly the part that goes missing.

```
games/gorge -g -S   non-sky 289920 of 290928, HUD pixels 1277
games/gorge -g -D   non-sky 290835 of 290928, HUD pixels 0
```

Two commands, two numbers, no camera. `-g` also writes the frame to
`gorge.gpu.raw`; rendered, the GPU frame has no text, no pylons, and a
canyon composed wrongly, matching what the photographs showed.

(`gorge -g` existed as `gpushot()` and **nothing called it** — there was
no `-g` flag. A diagnostic this document referred to by name could not
be run at all. It is wired up now.)

Phase 3's fix does *not* fix this: HUD pixels are 0 on the device
provider both with and without it, checked by rebuilding `emu` both
ways. The two faults are separate. Phase 3 was about a copy not seeing
the queue; this is about *when* the queue is drained relative to the
2-D drawing that belongs on top of it, and the drain still happens at
present time.

### Phase 1's nine ports' pictures, checked at last — 2026-09-11

`framegrab(1)` is the tool that was missing: it runs a module with a
draw context, waits, reads the display back and writes the frame out,
with a hash so two runs can be compared without rendering either. The
other provider is put in its place with a `bind` — the ports name the
provider by path, and a path is a name in a name space — so the two runs
differ in nothing else:

```
bind /dis/math/draw3d.dis /dis/math/draw3ddev.dis
framegrab -n 1800 -o soft.raw temple/rotatetank
```

**The result is that the device provider loses the whole 3-D content of
a frame most of the time.** `rotatetank`, pixels that are not the
background, five software runs and six device runs:

```
software  20461 20461 20465 20448 20459
device    14503 20031 14503 19960 14503 14503
```

14503 is the window chrome and the caption with nothing between them,
and all four of those runs hash *identically* — which for a demo that
animates means nothing was drawn, not that a frame was caught half
finished. The software provider never does it, in five runs out of five.

Rendered, the pattern is the same in every port that has both kinds of
primitive: **lines, points and 2-D survive; filled polygons do not.**
`3dpoly` draws its five coloured polygons and a mirror line on software
and, on the device, the mirror line alone. `pick3d` keeps every green
line, circle and cross and loses every blue and gold triangle.
`spriteplot3d` and `rotatetank` go blank. `shading` — whose entire
picture is one Gouraud sphere — comes out right when it comes out at
all.

So Phase 1's nine were declared done on `g3_calls` rising and
`soft_fallbacks` staying at zero, and this document said in as many
words that neither of those says the result is correct. It was right.

**The mechanism, found the same day.** `INFERNO_METAL_STATS=1` alongside
the pixel count, four runs of `rotatetank`:

```
lit 14503   readbacks=0   g3_calls=2460
lit 20417   readbacks=5   g3_calls=2460
lit 14503   readbacks=0   g3_calls=2460
lit 14503   readbacks=0   g3_calls=2460
```

`g3_calls` is **identical in every run**: the geometry reached the GPU
every time, blank frame or not. What differs is `readbacks`. A blank
frame is one where `metal_readback_geom()` found the queue already empty
and returned at its first line.

So: **a present consumes the geometry queue without writing it back into
`gscreen`.** The four `metal_present_*` functions each take the queued
vertices, draw them into the drawable, and zero the counters. Whether a
readback ever sees that geometry is therefore a race against
presentation — win it and `gscreen` gets the frame, lose it and there is
nothing left to render.

This is also the sharpest possible demonstration of the trap this
document keeps warning about. `g3_calls=2460` was Phase 1's evidence for
`rotatetank`, and it is the same 2460 in the runs where the picture is
there and the runs where it is not.

**The fix that follows**, not attempted here: `metal_present_tris3d()`
already copies the vertices into a retained `present_tri3d_verts` before
zeroing the counters, so the last presented geometry survives — its
`batches` array is freed, though. Retaining that, and the equivalents in
the other three present paths, would let `metal_readback_geom()` re-render
the last presented batch when the live queue is empty. The hazard is
staleness: a program that has cleared and not yet re-queued would get the
*previous* frame's geometry painted onto a fresh clear, so the retained
batch needs invalidating when the destination is cleared, and getting
that wrong is worse than the present fault. It wants doing deliberately
rather than as a two-line guess.

**What this does not establish.** `framegrab` reads the display's
software image. A present straight to a drawable that never writes that
image back would be invisible to it, so "a readback sees nothing" is
what every in-process check and every port that composites its window
would see — but it is not proof the screen was blank. Separating those
two still wants a camera. The `gorge -g` head-up-display count above is
a *different* fault and was photographed.


### Phase 2b, half of it: the readback composed the geometry over the 2-D — fixed 2026-09-11

The architecture for correct ordering was already here and one of the two
compositors did not use it.

`metal_flush_geom()` snapshots the softscreen as it stood *before* any 3-D
was queued — `mtl_under` — on the first 2-D draw after geometry.
`present_softscreen_body()` then draws `under`, then the geometry, then
`metal_overlay_soft()` puts back the pixels that changed afterwards. Under
goes beneath, the head-up display goes on top, and the order is right.

`metal_readback_geom()` used none of it. It uploaded the **current**
softscreen — which already contains everything drawn after the 3-D — and
then drew the geometry on top of all of it. Every HUD, reticle and score
was lost, and since `gorge -g` reads back to see its frame, that is
exactly the 0 white pixels it reported.

The readback now composes the same way present does: `under`, geometry,
`metal_overlay_soft`. The two paths agree by construction rather than by
coincidence.

*Evidence:* `gorge -g -D` head-up-display pixels **0 → 2047**, against
1277 on the software provider. (2047 rather than 1277 because the
provider line it prints differs in length.) `draw3dbench`'s readback line
is unchanged, and its twenty-five checks still pass.

### And the half that is still open: gorge's geometry

The HUD is back and the canyon is still wrong: no ceiling, no pylons, no
bolt, and two large planes where there should be a receding corridor.
The same scene through devdraw's C rasteriser is correct, so this is
Metal's geometry and not gorge's model or its ordering.

**What is *not* established.** Removing the `gpudrawfillpoly3g` hook makes
gorge correct — but gorge's geometry is *entirely* `fillpoly3g`, so that
moves all of it to the CPU and cannot tell a Gouraud fault from any other
Metal fault. It was recorded here as an isolation and it is not one.

The real gap was a missing measurement, and `g3probe(1)` is now it.
`draw3dbench` checks the GPU's **flat** `fillpoly3` for position, scale,
rotation, occlusion and equal depth; for Gouraud it checks only *that it
shades*, and nothing about where a face lands or what it occludes.

`g3probe` closes that, and the answer is that four of the five suspects
are innocent. Software against device, within about 1% throughout, which
is rasterisation:

- **placement**: one quad at six depths, `fillpoly3` against `fillpoly3g`
  — the two entry points agree, in both providers, at every depth.
- **the depth test**: a near quad and a far one drawn in both orders —
  the order does not matter in either provider.
- **`frustumoffset`**: the same occlusion test through gorge's own
  projection rather than `frustum` — no difference.
- **scale**: a corridor of 1 to 256 faces — 23366 lit against software's
  23588 at 256.

The fifth is guilty, and it is not about geometry at all:

```
provider       frames        lit
software            1      23376
device              1          0
device              1          0
device              1      23154
device              1      23154
device              1      23154
device              1          0
device              1      23154
device              1          0
software            8      23376
device              8      23154     (four runs, all)
```

**One frame drawn and read gives nothing at all about half the time.**
Eight frames is right every time; software is right every time. That is
the present-eats-the-queue race above, measured: over several frames a
readback eventually wins and the softscreen gets the geometry; over one
it may not.

So gorge's wrong picture is not a rasterisation fault to be found in a
shader. It is this, and the fix is the one named above — make
materialising into the softscreen deterministic instead of a race.

**An attempt at that fix is recorded here because it did not work.**
Calling `gpudrawreadback()` from `drawflush()`, so every flush
materialises, fixes the single-frame case outright (0 → 23388) and
*breaks gorge*: its head-up display goes back to 0. gorge draws its HUD
with `Image.text()`, which is not the draw message, so the hook that
materialises at the first 2-D after the 3-D never fires for it and the
flush-time materialise happens at a different point in the frame.
Repairing that with a full softscreen upload restores gorge and loses
the single-frame case again. The two pull against each other and the
pair was not committed: what is wanted is one materialise at a
well-defined point in the frame, not two hooks that each half-work.

Two smaller things this turned up, both my own instruments rather than
the code, and both worth knowing: a probe that does not flush before
reading measures the screen as it stood *before* the drawing — that
reported a first-call blow-up that did not exist; and a quad with any
vertex outside the frustum is dropped whole rather than clipped, in both
providers.

### Phase 2b closed: the GPU draws the right picture — 2026-09-11

`gorge` and `strider` both render correctly through Metal. Three faults,
all in `emu`, none in either game.

**1. A polygon straddling the eye plane was handed to the GPU.** A vertex
behind the eye gives `w <= 0`; interpolated across the triangle that
wraps, and the GPU paints an enormous wrong face instead of the sliver
that should be visible. `g3probe(1)`: a wall running through the eye
lights 40596 pixels through the software provider and **185898** through
Metal, where the same wall entirely in front of the eye agrees to within
1%. gorge flies a canyon *through* the eye every frame, so this was most
of its picture — the big flat shapes that swallowed the scene.
`devdraw.c`'s `'K'` case now projects every vertex first and declines the
GPU if any is behind the eye, so those polygons take the CPU path and
agree with software: **185898 → 40290**.

**Since replaced by real clipping.** `devdraw.c` already had a
`d3clipnear()` — Sutherland-Hodgman against the eye plane, in model
space, which works because the model transform is affine so eye z is
affine along a model-space edge. The **flat** path `'k'` has used it
since it was written; the Gouraud path `'K'` never did, and that
asymmetry was the whole fault. `d3clipnearlit()` is the same clip
carrying the per-vertex lit along by the same parameter, and `'K'` now
uses it, so the straddling faces go to the GPU clipped instead of to the
CPU whole: `g3_calls` 5713 → 6060, `g3_tris` 11339 → 12036, and the
picture is unchanged.

It is bounded at eight input vertices so the output can live on the
stack; anything larger is still declined to the CPU, which is correct if
unaccelerated, and every face either game draws is a triangle or a quad.

`'G'` (line3) and `'h'` (plot3) still do not clip, and `g3probe(1)` says
the two providers do not merely differ there, they fail in *opposite*
directions. Twenty-four lines running from behind the eye to well in
front:

```
provider     lines        lit
software     in front    19821
device       in front    19848
software     thru eye        0
device       thru eye    19686
```

In front they agree. Crossing the eye plane the **software provider
draws nothing at all** — it drops the whole line — and the device draws
something. Which of those is wrong depends on what `line3` is supposed
to mean for a line that is half behind you, and the answer is surely
"draw the half in front", which is neither.

Deliberately not changed here. Clipping only the device path would make
it *more* right while leaving software at zero, so the two would still
disagree; making them agree means changing what the Limbo provider does
with such a line, which is a semantic decision rather than a bug fix.
`appl/temple/box.b` is the only thing in the tree that draws with
`line3`, and neither game does, so nothing is visibly wrong today.

**2. Presentation was the only thing that consumed the geometry queue,**
and it does not write the softscreen back, so whether a frame's 3-D ever
reached the image everything else reads was a race. One frame drawn and
read gave nothing at all in four of eight runs. `metal_flush_geom()` now
*materialises* rather than only snapshotting: it is called on the first
message after queued geometry that is not itself a draw3d letter, which
is the one well-defined point in a frame where the 3-D is complete and
the 2-D that belongs on top of it has not been drawn. Eight runs of one
frame, all correct.

**3. `'K'` was missing from the list of draw3d letters** that must not
flush mid-batch — `'G'`, `'g'`, `'h'`, `'j'`, `'J'`, `'k'`, `'q'` and the
rest are all there. It is the one letter gorge uses for everything, so
every face triggered the flush hook. Added.

Measured after: `gorge -b -D` is **3433 µs a frame** against the software
provider's 58225 — seventeen times — and `gorge -g -D` gives 2047
head-up-display pixels where it gave 0. `strider -D` likewise draws its
terrain, its enemy, its weapons, its armour diagram and its radar.

**Both games now default to the device provider.** The last doubt was
the window manager, where this provider used to panic `emu` with
`pushrun addrun` — that panic was the unbalanced error stack in
`devdraw`'s own Gouraud fallback, fixed above. Run under `wm(1)`: three
runs of `gorge` and two of `strider`, no panic, 1675–2416 µs a frame.

```
gorge -b    (default)   2566 µs a frame, /dis/math/draw3ddev.dis
strider -b  (default)   3350 µs a frame, /dis/math/draw3ddev.dis
gorge -b -S (software) 58225 µs a frame
```

`-S` asks for software. `-t` and `-s` stay on software in both games:
they render into an offscreen image, which the GPU hook does not take,
and they are checks rather than play.

### There is a third path, and it is the fastest and the only correct one — 2026-09-11

Everything above compares two things: the Limbo software provider and
Metal. There is a third, and nothing could reach it.

`devdraw.c` guards every GPU hook as `if(gpudrawfillpoly3g != nil &&
gpudrawfillpoly3g(...))` and falls through to **its own C rasteriser**
when the hook is unset or declines. On this host the hook is always set,
so that C path only ran when Metal refused a destination — which is why
it showed up as "the device provider panics under `wm`" and not as
itself. `INFERNO_NOGPU` now leaves the geometry hooks unwired, so it can
be asked for and measured. The softscreen is still uploaded and
presented by Metal either way.

**It panicked, and the panic was a two-character bug.** In the `'K'`
(Gouraud) case, the `d3project` failure path did

```c
poperror();  free(pp2);  goto Kdone;
```

with **two** `waserror()` handlers pushed — `vx`'s was left on the error
stack, and `vx` itself leaked. An unbalanced error stack does not fail
where it happens; it fails later, as `panic: pushrun addrun`, when the
next unwind lands on a frame that has been reused. Only a client whose
geometry crosses the near plane ever reaches that exit, which is why
`gorge` panicked and `draw3dbench` and `temple/rotatetank` did not.
Fixed by popping both.

With that fixed, `gorge`, 202 faces a frame into the window:

| path | µs a frame | the picture |
| --- | --- | --- |
| Limbo `draw3d.dis` | 58225 | correct, Gouraud |
| **devdraw C, `INFERNO_NOGPU`** | **1383–1650** | **correct**, flat-shaded |
| Metal | 2433 | wrong: no HUD, mis-composed |

The C rasteriser is **35 to 42 times** the Limbo provider and *faster
than Metal*, and it is the only one of the three that draws the right
picture. Checked with `gorge -g`: head-up-display pixels are 1277 on
software, **2047** on the C path, 0 on Metal; rendered, the C frame has
the canyon, the ceiling, the pylons, the bolt and every line of the HUD.

**So the optimisation was not to make the GPU work.** The fast, correct
renderer was already in the tree, unreachable behind a missing switch
and a `poperror()`.

What it costs is shading: the `'K'` fallback degrades per-vertex Gouraud
to one flat fill at the average of the lits, which its own comment calls
"deliberately out of scope for this primitive's first cut". That is now
the highest-value piece of work in this document — a scanline Gouraud in
`devdraw.c` would give the quality of the Limbo path at roughly the speed
of the flat one. For comparison, the Limbo provider gets its Gouraud by
subdividing each triangle four ways to depth four: up to **256**
sub-triangles and 256 array allocations per triangle, which is where its
58 ms a frame goes — about 100,000 fills where 400 would do.

### Phase 2a — `litcolour` allocated a colour image per fill

Fixed 2026-09-10, and it is the reason a Gouraud scene could not be run
long enough to measure at first. `litcolour()` in both providers cached
exactly **one** `(pen, brightness)` pair. Flat shading asks for a
handful of brightnesses and that was enough; the software Gouraud path
subdivides every face four ways and asks for the average brightness of
each leaf, so essentially every fill missed the cache and allocated a
fresh `Display.rgb` image. Draw images are a limited resource in emu:
`gorge`'s canyon exhausted them in a few hundred frames, silently — the
program simply stopped, with no error and no clue.

It is a table now, indexed by brightness quantised to 1/64 of full scale
(under two levels out of 255, below what the eye resolves in a gradient)
and keyed by the pen as well. Keying it by brightness alone is not a
fix and looks like one: a frame cycles through eight or nine pens, so
each `setcolour()` threw the previous pen's table away.

**`Display.rgb` colours are never shaded at all**, separately from that.
`rgb()` returns a depth-24 `r8g8b8` image and `litcolour()` tints only a
depth-32 one, returning anything else unchanged — so a scene lit with
`rgb()` pens comes out completely flat, with no error. A replicated
one-pixel image in the display's own channels is depth 32 and does get
shaded; `gorge`'s `rgb32()` is that, and says so. Whether `litcolour`
should handle depth 24 is open.

### Phase 3 — make the GPU readback produce pixels — **done, 2026-09-11**

The hook was only ever called on the draw(3) *read* message. A `draw()`
that copies out of a GPU-backed image never drained the queue, so
anything the GPU had queued but not presented was invisible to a copy —
which is what every port that composites its window into a buffer does.

`emu/port/devdraw.c`'s `'d'` case now calls `gpudrawreadback()` before
`memdraw()`, exactly as the `'r'` case does. It is cheap when there is
nothing queued: `metal_readback_geom()` returns at once on an empty
queue, which is almost every draw.

*Evidence*, `draw3dbench`'s readback line, the `layer draw` column:

```
before  software layer draw=210183   protocol layer draw=0
after   software layer draw=210183   protocol layer draw=209696
```

209696 against 210183 is 0.2%, the same order of difference the
provider-agreement checks already show between GPU and software
rasterisation. *Negative control*: reverting the two lines returns the
protocol column to 0, confirmed by rebuilding `emu` both ways.

It costs nothing measurable. `gorge -b -D` is 2358 µs a frame against
the 2408 recorded above.

**What this unblocks.** Until now a `readpixels` of a GPU pass could not
be trusted, so every in-process check was blind to what the GPU actually
drew and the only way to see it was to photograph the screen. That is
no longer true, and Phase 2b below now has a reproducer that is two
commands and a number.

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

### Phase 6 — the display-list sprite type — **the gate passes, 2026-09-09**

`vsprite(2)` (`appl/math/vsprite.b`, `module/math/vsprite.m`) is the type,
hoisted out of `temple/spriteedit`'s interpreter rather than written
again, and `vspritetest(1)` is the gate this document set: render a
sprite from its element list and compare the pixels with the `.bit` the
extractor rasterised from the same list. Two independent rasterisers, one
in Python and one in Limbo, reading one source of truth.

**57 of 57 compared sprites pass, 52 of them pixel-exact.** The other
five are allowed sixteen pixels each and print their count. 166 of the
248 are not compared at all, for reasons that are in the man page and are
about the *extractor*, not the type.

Five things had to be got right, and each of them was found by the
comparison rather than by reading:

- **The `.mask` is not optional.** The extractor leaves a transparent
  pixel as byte 0 and CMAP8 0 is also `BLACK`, so the image alone cannot
  tell "nothing drew" from "drew in black". Comparing without it reported
  457 of 527 pixels differing on a sprite that was exact.
- **The box comes from the elements, not from the pixels.** The extractor
  computes it from the elements' nominal extents with the pen's
  half-width as a margin. Taking it from the pixels that came out made
  every sprite one row and one column smaller than its `.bit`.
- **Rounding is half-to-even, and it is not shift-invariant.** Python's
  `round()` is banker's rounding and Limbo's `int` rounds half away from
  zero, which is twelve pixels of a 527-pixel sprite. And the rounding
  has to happen on the *element* coordinate: `round(6.5)` is 6 and
  `round(6.5+3)` is 10, not 9, so rounding in canvas coordinates and
  rounding before offsetting are different pictures.
- **The canvas is the box.** Not a large scratch cropped afterwards: the
  extractor's raster is exactly the rectangle, so a flood fill that
  reaches an edge stops where the extractor's stops. A 2048x2048 scratch
  per sprite also exhausted the heap.
- **CMAP8 here is `(c-v+r)&15`.** `libdraw/rgb.c`'s `cmap2rgb` is not the
  `(c-v+r)/4` other Plan 9 lineages carry. Getting that wrong says 36 is
  green when it is blue, and it is what made half the pixels of every
  coloured sprite differ. It is also what made this session claim, wrongly,
  that `temple/keepaway`'s CMAP8 table was buggy; see `doc/temple-plan.md`.

And one real bug, in code that has been in the tree since the sprites
were extracted: `spriteedit`'s flood fill marks a pixel seen when it is
*popped*, so a pixel can be pushed once per neighbour and the stack needs
four times the canvas where it is allocated at exactly the canvas. It
never showed because the editor's canvas is a fixed 680x530 and its fills
are small; a canvas cropped to the sprite's own box reaches its edges
immediately, and the first sprite whose fill touched one overran the
stack. Fixed in both places by marking at push, which fills the same
region and bounds the stack by construction.

**The editor is now a caller, not a second copy.** Hoisting by extraction
left `spriteedit` running its own interpreter, and the two had already
stopped agreeing: every correction the `.bit` comparison forced — half-to-
even rounding, rounding on the element coordinate, the box rule — went
into the module only, so the editor placed a pixel by one rule and the
module, which is what matches the shipped `.bit` files, by another. That
is worse than the duplication it replaced. So
`spriteedit` was converted: the element type, the vocabulary, the text
grammar and the rasteriser all come from `vsprite(2)`, `Elem` gained a
`tag` field for the editor's selection flag, and `canvas()` was factored
out of `pixels()` so the editor can draw the same list onto its page.
The editor lost 735 lines.

*What that was worth, measured.* Rendering all 248 `.spr` through the
editor's own headless mode before and after: **21 of the 248 came out a
different number of inked pixels**, so the two rasterisers really did
disagree on a twelfth of the corpus, and the 227 unchanged say the
conversion did not disturb anything wholesale.

*The residual difference, measured too.* The editor's canvas is a fixed
680x530 page with the origin at its centre; the module's is the sprite's
box. `vspritetest(1)` now renders each sprite both ways and compares the
page render cropped back to the box: **57 of 57 identical**, none with
ink outside the box, three cut off by the page's edge — `elephant_1`,
`elephant_2` and `spritetext_1` run past the page and the editor simply
cannot show that part. A one-pixel change to the page origin makes all 57 fail,
which is the negative control that the check can see what it claims to.

*What it costs, and what fixing that turned up.* The rasteriser held its
canvas as RGBA and converted every one of the page's 360,400 pixels back
to a palette index through a sixteen-way nearest-colour search, where the
editor's old path wrote `pal[c&15]` straight into the canvas and touched
only the pixels it drew: 4ms to 10ms a frame, on every frame of a
rubber-band drag. Nothing draws anything but one of the sixteen, so the
canvas now holds indices — one byte a pixel, no search, and a quarter of
the memory. Timed as whole `-t` runs, ten each, `emu`'s own 7.2ms
start-up included: `battlelines_1` (527 pixels) 12.2ms before the port
and 15.5ms now, `elephant_1` (44,091) 15.2ms and 15.6ms, `spritetext_1`
(991,935) 14.0ms and 17.7ms. What is left is the page-sized array the
editor's canvas needs whatever the sprite's size.

That change found a real bug it was not looking for. A flood fill asks
"is this pixel already the colour I am about to paint?", and it was
asking it of two different representations: the pixel came back from the
canvas as a positive packed RGBA, and the ink came from `pal[]`, whose
entries are sign-extended, so for any colour with red ≥ 128 the two could
never be equal. Only the inverted fill uses that test, and there is
exactly one `floodfillnot` in the 248 sprites — `psalmodydraw_11`, whose
fill therefore never stopped and inked the entire 680x530 page instead of
the 37 pixels inside its circle. Both sides now go through one function,
so they cannot be in different forms. *Attributed with a control*: put
the pixel back into the positive form while leaving the ink
sign-extended, and the whole-page fill returns; restore it and it goes.
The first control tried — restoring the old `inkv` expression — changed
nothing, because it was the other side of the comparison that had moved.

Two things a different canvas changes. A flood fill that escapes the
sprite runs to the canvas edge — which happens for none of the 248. And a
dither's checkerboard is in canvas coordinates, which is *not*
hypothetical: `spriteplot_1` differs by 684 pixels between the editor's
page and its own box, and moving the page origin one pixel in x makes it
identical, so the difference is entirely checkerboard phase. It is not
among the 57 because it has text in it. So a dithered sprite in the
editor has its two dither colours swapped relative to what a port draws
and what the `.bit` holds. Nothing moves; it is still not the same
picture. Fixing it would mean either shifting the editor's page by a
pixel, which moves everything else, or making the phase
element-relative, which would stop matching the shipped assets. Both are
in the man pages' BUGS instead.

**It scales and turns now, and the oracle was already in the tree.** The
point of a display list is that it can be drawn at any size, and there is
no `.bit` of a scaled sprite to check one against — but `spriteedit`'s
Transform Selected has done exactly this since the sprites were
extracted, exact for every 2D element including TempleOS's
rect-to-rotated-rect promotion. So `transform`, `transformelem`,
`Sprite.transformed`, `polyptabs` and `walkappend` are that code moved
into `vsprite(2)` (verbatim, diffed) and the editor calls them; a
transform now means one thing in the tree rather than two.

*The gate, since there is no asset to compare against.* Three properties
that hold whatever the right answer is, checked as **pixels**, not as
arithmetic: turning by nothing and scaling by one changes nothing; four
quarter turns come back; scaling by four and then by a quarter is the
original, which is exact because every coordinate is an integer. **46 of
46 pass.** Eleven sprites are skipped and the reason is TempleOS's: a
transform promotes a `rect` to a rotated `rect`, and a `rect` is filled
where a rotated one is an outline, so a transformed rect is deliberately
a different picture — `scripts/tos_extract_sprites.py` draws the two the
same way, so that is the reference, not a defect here.

Three properties that are all satisfied by doing nothing, so there is a
fourth: scaling by four must produce at least twice the ink. **The
measure is ink and not the box**, because the box carries the pen's
half-width as a margin and the pen does not scale unless the sprite sets
a thickness — `psalmodydraw_12`, two vertical lines 4 apart, is 7 wide
and comes out 19 wide rather than 28, which is right and looks wrong. It
cost a run to see that the first version of this check was measuring the
margin.

*Negative control:* make `transformelem` return its input unchanged and
the transform score goes from 46/46 to 1/46. The one that still passes
has too little ink for the growth check to bite.

**The first port is converted, and it is a visual change.** `stadium`'s
wandering fans are one vector sprite drawn at each fan's angle. The port
had its own three-line parser (`color`, `thick`, `line` and nothing else)
and drew each line through `draw(2)` — a third rasteriser for a format
that already has one. It now reads the sprite with `vsprite(2)` and draws
`transformed(ang).raster()`; because a wandering fan's angle only ever
moves by 1/25 radian and is put back to zero outside ±0.75, there are 39
of them and each raster is made once and kept, which is less work per
frame than the walk it replaces.

*The cache nearly cost a bug, and the shape of it is worth keeping.* A
fan the ball knocks over is frozen at −π/2 and never passes that clamp
again, so it is outside the wander's range. Sized to the wander and
indexed by a **clamped** key, the cache drew it at −0.76 radians: a fan
flattened by the ball standing almost upright, **202 pixels different
where every other angle differs by about 14**. Nothing in the tree could
have caught it — `vspritetest` never asks for that angle and the smoke
test never throws the ball. The fix is not a wider clamp but no clamp:
the cache reaches far enough to hold −π/2, and an angle outside even that
is drawn *without* the cache. Clamping a cache key silently returns the
wrong answer; missing costs a raster.

A first version of the fix also compared the exact angle against the one
the slot was rasterised at, and would have thrown the cache away: 1/25 is
not exact in binary, so two fans nominally at the same wander angle
differ in the last bits and every frame would have re-rasterised. The
comparison bought nothing — the wander lands on multiples of 1/25 inside
±0.75 and −π/2 quantises to −39, so no two angles this port can produce
share a slot — and the key is the quantised angle alone.

*Measured, because it is not a no-op.* A throwaway program rendered the
sprite both ways — the old walk and `transformed().raster()` — into two
offscreen `RGB24` images at every one of the 39 wander angles, counting
pixels that are not white and pixels where the two differ: **about 14 of
108 inked pixels differ, mean over the 39 angles, worst 23**.
At angle zero the old walk inked 115 pixels and the new render 105, 22 of
them different — and `vspritetest` says `stadium_1` is **pixel-exact**
against its `.bit`, so at that angle the new render is the reference and
the old walk was the one that was wrong. That is what "prove it now
matches the reference" looks like, as against "prove nothing changed".

**The rest are converted, and each in the shape its port actually wanted.**

- **`spritetext`** read the element list with a tokeniser of its own that
  knew fifteen of the thirty kinds — a `polypt` "summarised" itself as
  five hundred bytes of hex. It reads through the type and prints
  `elemline()`, which makes the listing what `Sprite2Code` emits. Checked
  first that this is safe: all 248 shipped `.spr` round-trip through
  `parseline`/`elemline` with no change of meaning, one re-quoted. `-t`
  prints what the window shows; of 39 lines the code listing is identical
  and exactly two summaries differ, both kinds the old walk had no case
  for.
- **`zing`** rotates its arrow, so it is `transformed(deg, 1.0).raster()`
  with a raster kept per whole degree. A whole degree is enough, measured:
  at 180 angles against the same angle rounded to a degree, **0 of 180
  move a pixel**; at two degrees 150 of 180 do. Counting pixels that
  *differ* cannot tell those apart, which is why the measure is
  displacement. Against the port's own walk: 11 of 79 inked pixels differ,
  none moves, and `vspritetest` says `zing_1` is pixel-exact, so the new
  render is the reference. The cost was re-checked after `varoom` (below)
  showed a raster cache losing to an element walk: at a deliberately heavy
  **40 arrows a frame**, `redraw()` takes **291us** through the raster
  cache, **246us** walking the turned element list instead, and **216us**
  through the private rotate the conversion removed. The same ordering,
  three ways — but 45us a frame at forty arrows, where `varoom` was
  5,000us a frame at the 290 bushes its driven run averaged. `zing` is left as it is: the
  difference is below the frame clock's own resolution and the raster is
  the render `vspritetest` checks.
- **`rawhide`** rasterised the `.spr` into its walkability shadow map with
  a three-kind loader, so a `circle` would have been visible in the `.bit`
  and invisible to `GrPeek`. `Sprite.pixels()` is exactly that map's shape.
  289 of 1,000,000 cells change, 19 more are walkable, and the control is
  in the commit — the first version of the measurement dumped from inside
  `rivermake()`, which runs *before* the fence posts are stamped, and so
  reported the maps identical no matter what.
- **`varoom`** scales its bushes with perspective and mirrors half of
  them. It now reads its four `.spr` through `vsprite(2)` and walks the
  element list the type hands back, drawing each line and circle with
  `Image.line` and `Image.ellipse` as the port always did. Rasterising
  each bush at its scale and blitting the raster was tried first and is
  **three times slower**, and the way that was missed is worth keeping:
  the cache census that justified it — 42,000 draws on 61 distinct
  (sprite, mirror, scale) keys — was taken with the car **stationary**,
  because `varoom` only accelerates on a keypress and nothing was
  pressing one. The bushes never moved, so every scale was a repeat. With
  the throttle held the same census gives over 4,096 distinct keys, and
  the cache still hits 97% of the time — the cache was never the problem.
  The blit was: a bush is sixteen thin lines that ink a few hundred
  pixels, and compositing a masked raster over the whole box it sits in
  costs more than drawing them. Measured in situ, timing the real
  `redraw()` over 840 frames of a driven car, twice each: **7501 and 7473
  us a frame** through the blit against **2445 and 2478 us** through the
  walk. The walk is pixel-identical to the parser it replaces — 4
  sprites x 2 mirrors x 40 scales from 0.1 to 4.0, 249,797 inked pixels,
  **0 differ**, and adding one to the pen in the new path makes 456,979
  differ, so the comparison can see a change.

  The pen stays the port's, and that is two divergences from the art, not
  one. `varoom` draws a **one pixel** line where the sprite says `thick
  2`, at every distance — which is why `vsprite`'s render of the same
  file inks about **2.9x** as much, measured. And it does not scale the
  pen with the perspective, which TempleOS's transform does —
  `transformelem` multiplies `thick` by the scale, so a bush drawn at
  twice the size would carry twice the pen. Both are changes to how the
  game looks rather than rasteriser details, so neither is made here — and neither is certified
  by `vspritetest`, which checks `varoom_*` against their `.bit` at scale
  1 and says nothing about how this port draws them.
- **`battlelines`** is the one that is not a raster and was never going to
  be: five element lists tweened between, mirrored, and drawn in one
  colour. `vsprite(2)` does the reading, because a second copy of the
  grammar is a second thing to drift; the drawing stays in the port,
  because no raster can be tweened.
- **`spriteplot` was never a walker** and is not converted. It opens the
  pre-rasterised `.bit` and touches `lib/temple/sprites/` only to `stat`
  the element list for `$IS`. Replacing a correct blit with a runtime
  raster that is 20 pixels different would be a regression dressed as
  consistency. The "seven ports, each still walks the element list with a
  loader of its own" above is wrong about this one.

**A retraction, caught by an instrument that was lying.** The first
version of this paragraph said `spriteplot`'s banner would change font if
it were rendered from the vectors, and put the cost at 387 of 19,125
pixels against its own `.bit`. That number was measured with no font at
all: `vspritetest` took its display from the draw context, a bare command
gets none under `emu-cocoa`, and `vsprite(2)` with no display draws no
text — so the 387 pixels were the text *missing*, not a different font.
The test now asks the display for itself when it has no context, and the
real figure is **20 of 19,125**, which is not the font at all: the dump
shows a dithered run starting one column earlier for about ten rows, the
same shape-from-cos-and-sin disagreement the five allowed sprites have.
So this tree's `temple.8x8` and the extractor's `FontStd.HC` agree, and
`spriteplot` is convertible after all — it is still 4 pixels over the
allowance, so it is not in the compared set, and that is a number to
bring down rather than a slack to widen.

The lesson is the file's own: an instrument that silently does less than
you think reads as a difference in the thing measured.

**A correction to the count.** This section said "twelve ports" in three
places. Counted rather than remembered — `grep -l lib/temple/sprites/
appl/temple/*.b` — it is **seven**: `battlelines`, `rawhide`,
`spriteplot`, `spritetext`, `stadium`, `varoom` and `zing`, plus
`spriteedit` itself. Each still walks the element list with a loader of
its own; converting them is what the type was built for and none of it
is done.


This is the audit's headline gap and the place a plan can burn the most
work, so it is gated on one port.

TempleOS's `Sprite3` executes a display list of up to 30 element kinds;
this tree has 248 `.spr` files holding exactly such lists, and
`spriteedit.b` already interprets every kind in Limbo. That interpreter is
the reference implementation to hoist into `draw3d` as a first-class
type, so a `.spr` can be handed over whole instead of being walked
element by element by each of the seven ports that read one.

*Evidence:* pick a single one of those seven that currently
pre-rasterises its sprite, render it from the `.spr` through the new
type, and compare pixels against the port's `.bit`. Do not schedule the
other six until that comparison passes.

### The Sprite3 family was broken, and is not any more — **done, 2026-09-08**

The audit's line that "there is not one call to `sprite3`, `sprite3zb`,
`sprite3yb`, `sprite3mat`" across all eighteen ports was recorded as a
fact about the ports. The only caller in the tree is
`appl/wm/draw3ddemo.b`, which draws two sprites beside its cube and looks
plausible doing it — so nothing had ever *checked* the family, which is a
different thing from nothing calling it. `draw3dbench(1)` now checks it,
and two of the four checks failed on the software provider the first time
they ran.

What the one caller was actually getting is worth stating, because it is
what "looks plausible" hides. It asks for `scale` 1.0 at an eye distance
of about 6, so `sc` is about 1/6 — and the software path answered that by
*cropping* the sprite to a sixth of its width and height rather than
resampling it. The demo has been showing the top-left corner of its
sprite, at full size, for as long as it has existed. It also runs with
`setz(1)`, so its sprites have been ignoring a depth buffer that was
switched on; nothing in the scene passes in front of them, so nothing
showed.

The four checks, and why each is shaped the way it is:

| check | metric |
| --- | --- |
| place | sprite centre against `project()` of its own world point |
| scale | on-screen width at z = −4, −2 and −8: 16, 32, 8 |
| rotate | bounding box of a 48x12 sprite at 0° and at 90° |
| occlude | sprite pixels behind a nearer face, **and in front of one** |

Two of those were rewritten after they passed for the wrong reason, which
is the part worth keeping:

- **Shrinking cannot test a resample.** The first scale check compared
  z = −8 against z = −4 and passed on both providers. It shouldn't have:
  `draw()` does not resample, it clips, and a 16-wide sprite *cropped* to
  8 is 8 wide exactly as a resampled one is. Only enlargement
  discriminates — no crop makes 16 pixels cover 32 — and with that added,
  the software provider reported 16 where 32 was wanted.
- **Zero occluded pixels is also what "never drew" looks like.** The
  first occlusion check counted sprite pixels behind a nearer triangle
  and called zero a pass. A provider that silently dropped every sprite
  would have passed it. The positive control — the same sprite in *front*
  of the triangle, which must appear — is what makes the zero mean
  something.

What they found, both in the software provider:

- **The perspective scale did nothing but crop.** `spriteat` shortcut a
  near-zero rotation to a bare `dst.draw()` into an `sw` by `sh`
  rectangle. `draw` replicates or clips a source; it does not resample
  one. So a sprite could get smaller by losing its right and bottom edges
  and could not get larger at all — which is to say the one thing that
  makes it a *3D* sprite was absent. `transformsprite` already had the
  resample, and already reduced to the same native blit when the resample
  turned out to be the identity, so the shortcut was buying nothing it
  did not already have.
- **Sprites ignored the z-buffer.** `Context.zenable` is documented as
  "use z-buffer for fillpoly3 / sprites" and no sprite path consulted it,
  in either provider's software code. A sprite has one depth — TempleOS's
  `Sprite3B` gives the whole thing the z of its anchor — so the test is
  `polyfill`'s `filllinez` with the epsilon at zero: nearer wins, and
  winning claims the pixel. It goes in the general per-pixel loop, and a
  z-tested sprite therefore forgoes the separable and native-blit
  shortcuts, which write whole runs and cannot consult a depth per pixel.
  Only a caller that asks for the test pays for it.

  Equal depth wins, which is *not* `filllinez`'s rule. Every sprite has
  one depth apiece and `GR_Z_ALL` puts whole groups of them at the same
  one, so a strict test gives every overlapping pixel to whichever sprite
  drew first and makes the second invisible — the ordinary case in a
  scene, not a corner of it. Made strict again, the check reports 0 of
  256 pixels of the second sprite surviving.

The protocol provider passed all four from the start: the GPU sprite path
was already right, and the positive control proves its zeros are real
occlusion rather than dropped sprites.

Attribution was checked one fix at a time. With only the depth
*comparison* disabled — `zwin` made to always win — `occlude` reports 16
pixels through a nearer face again while `scale` still reads 16,32,8.

**What this unblocks.** Phase 9's ordering rested on draw3d not offering
what the hand-rolled ports needed. `varoom`'s own comment names the
defect its painter sort leaves: "a bush standing on the road, whose base
should be cut by nearer tarmac and whose top should not". That is exactly
a single-depth sprite against an interpolated surface, and it is now
expressible. What has *not* been re-measured is the thing that made the
sort necessary — a z-buffered fill cost 7.18 ms a frame in interpreted
Limbo against 0.07 ms for a plain one — so before any port moves, measure
the GPU fill **in that port's own destination**, because an offscreen
frame buffer gets no GPU at all and is slower through the protocol
provider than through the software one.

And the sprites themselves have to go the same way. With `zenable` on,
the *software* sprite path is now the general per-pixel Limbo loop for
every sprite, rotated or not, because the run-based shortcuts cannot
consult a depth. That is the same cost class as the z-buffered fill the
sort was avoiding. A z-tested sprite is affordable on the protocol
provider drawing into a window layer; it is not affordable in interpreted
Limbo at `varoom`'s 512 bushes a frame. What is unblocked is that the
behaviour now exists to migrate *to* — not that migrating is free.

### Phase 9's real gate, measured — **the answer was not the fill**

Phase 9 was ordered last on the belief that the hand-rolled ports were
waiting for a fast z-buffered *fill*. `draw3dbench(1)` now measures the
thing they actually spend their frame on, and the fill was never the
problem.

All four candidates — `varoom`, `talons`, `rawhide`, `stadium` — already
draw straight into `win.image`, the window layer, so the destination gate
of Phase 2 is passed for every one of them.

Marginal cost per primitive, 640x480, window layer, depth on, measured as
the slope between an empty frame and a loaded one so the fixed cost of
clear-and-present is out of it:

| primitive | software | protocol |
| --- | --- | --- |
| triangle | 2 µs | 2 µs |
| 16x16 sprite, z off | 5 µs | 0 µs |
| 16x16 sprite, z on | 10 µs | 0 µs |
| 220x220 sprite | 1562 µs | 0 µs |

A triangle costs the same either way. A *sprite* did not, and finding out
why took two wrong measurements first, both worth recording because both
looked plausible:

- **2048 sprites a frame measured the present rate.** `MaxGPUSprites` was
  512, and past it `metal_queue_sprite` spins on `osyield()` until a
  present drains the queue. The first run reported 64 µs for a GPU sprite
  against 1 µs for a GPU triangle and the difference was entirely stall.
  The load has to sit under the ceiling, or the ceiling has to move.
- **A cheap sprite loop measured presentation, not sprites.** Timing 512
  sprites and dividing gave 22 ms a frame for the protocol provider and 4
  for the software one — the protocol column floored by the present rate.
  Only the slope between two loads separates them.

With the load under the ceiling the real cause showed:
`metal_present_sprites` opened **one Metal render command encoder per
sprite**. An encoder is a whole render pass, with the attachments loaded
and stored around it, so a field of five hundred identical bushes was
five hundred passes over the drawable. Batching each run of sprites that
share a texture and sampler into one pass — order preserved, since
fragments rasterise in draw order within a pass — and raising the ceiling
to 8192:

| sprites in a frame | before | ceiling raised only | batched |
| --- | --- | --- | --- |
| 256 | 3 ms | 2 ms | 2 ms |
| 512 | 14 ms | 14 ms | **2 ms** |
| 1024 | 28 ms | 14 ms | **2 ms** |

Each change is attributable on its own: raising the ceiling alone takes
1024 sprites from 28 ms to 14 by removing the stall and leaves the
per-pass cost; batching alone is what takes 512 and 1024 to 2 ms. All
twelve `sprite3` checks and both mask-edge checks still pass in both
providers afterwards, so the batching did not disturb ordering, depth or
compositing.

**What this changes for Phase 9.** `varoom` projects 512 bushes and seven
cars a frame — it was sitting exactly on the old ceiling, and would have
stalled the moment it moved to GPU sprites. It no longer would: a
thousand depth-tested GPU sprites now cost 2 ms a frame. The remaining
constraint is coherence, not speed: depth lives on the GPU for the
protocol provider and in `c.zstate` for the software one, so a frame must
draw all its geometry and all its sprites through the *same* provider.
Choose it by the sprite sizes — under about 45x45 the software blit is as
cheap, above it the GPU is twenty times cheaper and flat.

### Phase 9 begins: `box`, and `line3` had the same hole as the sprites

`box` is the smallest of the eight hand-rolled ports — 148 lines, an
orthographic +/-100 wireframe cube tumbling on three Euler angles — and
it was migrated first for that reason, following this document's own
rule: prove the path on one, then schedule the rest.

**`line3` was checked first, and failed the same way `sprite3` did.**
Placement and thickness were right in both providers (a thick-3 pen
lights 7.0x the pixels of a thick-0 one, which is what Plan 9's 2r+1
widths predict, and a lit-pixel count alone could not have told a pen
that ignored its thickness argument from one that did). But the software
provider's `line3` went straight to `Image.line` and never consulted the
depth buffer: 427 pixels of a line behind a nearer face, where the
protocol provider drew 0 with 1267 in front. Fixed by transcribing
`emu/port/devdraw.c`'s `d3linez` into Limbo — walk the bounding box,
project each pixel onto the segment, reject outside the pen radius,
interpolate eye z along the segment and take the pixel only if it is
nearer — so the two providers now agree by construction rather than by
argument. The result goes out as one masked draw rather than a draw per
pixel; twelve edges of a thousand pixels each, through the interpreter,
would otherwise cost more than the test is worth.

Lines take nearer-**or-equal**, as sprites do, and that correction is
worth its own paragraph because the reasoning that first made them strict
was wrong. The rule was taken from `d3linez`, "the device's rule" — but
`d3linez` is the device's *CPU fallback*. The device's actual depth state
is `MTLCompareFunctionLessEqual` and always has been, so a GPU line,
triangle and sprite have equal-wins semantics, and only the CPU
fallbacks were strict. They disagreed with the GPU they stand in for.

It matters to a real port rather than to a corner case: `temple/lattice`
draws a stroke as a ribbon of overlapping micro-steps all on one layer,
so a strict test keeps the first of every overlap and discards the rest.
`draw3dbench` grew the check — two lines crossing at one depth, where all
of the second must survive — and it reads 1301 of 1301 pixels; made
strict again it reads 1236. `emu/port/devdraw.c`'s `d3linez` was changed
to match, so the GPU, the device's fallback and both Limbo providers now
state the same rule.

`polyfill`'s `filllinez`, which is what a z-buffered *fill* goes through,
is still strict. It is left alone deliberately: it is used well beyond
draw3d (`wm/polyhedra` among others) and its span-edge tolerance clause
makes it not quite a plain comparison, so changing it is its own piece of
work with its own evidence.

**The migration itself.** The correspondence is exact and is the one
every remaining hand-rolled port will need:

| the original | draw3d |
| --- | --- |
| `Mat4x4RotZ` / `RotX` / `Scale` | `rotatez` / `rotatex` / `scale` on MODEL |
| orthographic, drop z | `ortho(200.0, ...)` on PROJ |
| `dc->x,y = (200,200)` | `viewport()` over the 400x400 box centred there |
| `GrLine3(..., thick)` | `line3(c, a, b, thick)` |

The matrix stack post-multiplies as OpenGL's does, so the calls read left
to right in the order the original applies them — scale outermost, Rz(θ1)
innermost. The depth buffer stays *off*: the original draws all twelve
edges with no hidden-line removal, and switching depth on would hide the
back of the cube, which is a different picture and not a better one.

*Evidence.* Lit red pixels, centroid and horizontal span, read with
`readpixels` at the fortieth tick, which is the same attitude and scale
in every build because the angle steps are fixed:

| build | pixels | centroid | span |
| --- | --- | --- | --- |
| hand-rolled, `Image.line` | 1478 | 200,223 | 159..243 |
| draw3d, software provider | **1478** | **200,223** | **159..243** |
| draw3d, protocol provider | 1438 | 200,222 | 158..242 |

The software row is identical to the original in every figure, so the
transform migration is exact: the matrix stack, `ortho`, `viewport` and
`line3` reproduce the hand-rolled Euler arithmetic pixel for pixel. The
2.7% and the one pixel in the protocol row are therefore attributable to
the GPU line rasteriser alone, not to the port — which is what running
both providers through the same measurement was for.

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

### Phase 10 — `sprite2d` on the GPU — **done, 2026-09-07**

The biggest single lever left, and the one nothing above reaches. Rotated
2D sprites are what the temple ports actually spend their time on, and
they are entirely interpreted Limbo in **both** providers:

| sprite | software | protocol | native `Image.draw` |
| --- | --- | --- | --- |
| 16x16, 0° | 5 µs | 5 µs | 0 µs |
| 220x220, 0° | 35 µs | 40 µs | 35 µs |
| 220x220, 30° | **2670 µs** | **2690 µs** | 30 µs |

A rotation costs seventy-six times what the same blit costs upright, and
the protocol column is flat because `sprite2d` in `draw3ddev.b` does not
send a message at all — it calls the same `transformsprite` the software
provider does. Meanwhile `metal_queue_sprite` already exists, already
does exactly this job as a textured quad, and is already reachable — by
`sprite3*`, which `appl/wm/draw3ddemo.b` calls and no temple port does.

So the GPU can do this today and nothing asks it to. Two figures say why
that is a phase and not an afternoon:

- **All eight `sprite2d` callers are on the software provider.** They are
  `bigguns`, `bombergolf`, `elephantwalk`, `rocket`, `rocketscience`,
  `squirt`, `tothefront`, `xcaliber`. None of the nine ports Phase 1
  moved to `draw3ddev` calls `sprite2d` at all, so the two sets do not
  overlap and moving the message would benefit nobody until those eight
  move too.
- **Two of the eight draw into an offscreen `buffer`** (`elephantwalk`,
  `rocket`), which `metal_queue_sprite` rejects outright — same
  destination gate as Phase 2, and the same answer needed.

The work is therefore four parts, in this order: a screen-space sprite
message (`'j'` carries a *world* vertex and a scale and lets the device
project, which is wrong for a 2D placement — this wants centre, width,
height, angle and a mirror flag); the device handler, with the existing
`d3spritez` as its in-C fallback; the offscreen destination from Phase 2;
and only then the eight ports.

`sprite2dtest(1)` is the gate, and it was built for this: its three
families — 1:1, quarter turns, doublings — are the ones whose answer does
not depend on the resampler, so a GPU path has to pass them exactly as
the Limbo one does.

**What was actually done.** A `'J'` message (screen space: centre, size,
angle, mirror — no projection, no depth, since a 2D sprite has none of
those and `'j'`'s world point would have put the current matrices in the
way), a `gpudrawsprite2d` hook, `metal_queue_sprite2d`, and `d3spritez`
as the in-C fallback for destinations the GPU will not take. The eight
ports moved. End to end into the window, 640x480:

| sprite | software | protocol |
| --- | --- | --- |
| 220x220 at 30° | 2725 µs | **65 µs** |
| 64x64 scaled to 220 | 6690 µs | **50 µs** |
| upright, any size | unchanged | unchanged |

The offscreen-destination blocker turned out not to be one: `d3spritez`
in C is the fallback there and is itself about a hundred times faster
than the Limbo loop, so the ports that compose into a buffer gain too
without `metal_queue_sprite` ever seeing them.

**Three of the eight are on that C path and not the GPU one** —
`elephantwalk` and `rocket` draw into a Tk `buffer`, and `xcaliber`
composes into `buf` (`cimg = buf`). Measuring any of them with
`INFERNO_METAL_STATS` shows `spr_calls=0`, which is correct and not a
sign the feature is broken; that reading cost time once already. The
five that do reach the GPU are `bigguns`, `bombergolf`, `rocketscience`,
`squirt` and `tothefront` — observed live at 30 sprites per 30 presents
for `rocketscience` and 350 for `bombergolf`.

`sprite2d` sends the message only when there is resampling to do. An
upright sprite at its own size is a plain masked `draw`, and handing
*that* to the GPU measured 60 µs against 5 µs for a 64x64: the sprite
queue is drained by presentation, so a tight loop of cheap sprites
throttles to the present rate. The wins are all in the cases a blit
cannot do.

The sprite sampler is **point**, not bilinear, for `sprite2d`. The art is
8x8-grid pixel art and bilinear magnification blurs it; and the same call
reaches the GPU or the Limbo resampler depending only on the
destination, so anything but point sampling would change a sprite's
appearance when it moved from a window into a buffer. `sprite3` keeps the
smooth filter, having no exact oracle to match.

**Four real bugs fell out of making the two paths agree**, none of which
a reading would have found:

- `d3spritez` centred its box on the requested point, where
  `transformsprite` centres a `bw` box at `c - bw/2` (integer) and then
  samples about `bw/2.0` — half a pixel apart whenever a dimension is
  odd. 21 of `sprite2dtest`'s 24 identity cases differed on that alone.
- `d3maskset` read bit 7 of the mask byte for every pixel instead of
  bit `x&7`, so seven pixels in eight took their neighbour's coverage.
  `metal_upload_sprite_tex` had the same bug independently.
- `metal_upload_sprite_tex` took depth 8 to mean grey, so every CMAP8
  sprite — which is every `.bit` file in `icons/temple` — drew on the
  GPU in greyscale. It converts through `memdraw` now, which knows every
  channel this tree has.
- `d3spritez` never range-checked the source index the Limbo path
  guards.

**One hazard left, not currently reachable.** A `'J'` sprite is queued at
depth 0, which is nearer than anything `eye_to_depth` produces, so it
always passes the depth test — that is the painter-order 2D behaviour it
replaces. But the sprite pass shares one depth state, so when depth
writes are on it also *writes* 0 over the sprite's rectangle, and a
`fillpoly3` drawn afterwards in the same frame would be hidden. Nothing
does that today: the eight `sprite2d` ports draw no 3D and the nine 3D
ports call no `sprite2d`. If the two ever meet, the fix is to split the
sprite pass into a depth-writing encoder and a non-writing one rather
than to change the depth value.

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
- **The GPU is deliberately no longer colour-identical to the software
  renderer, as of 2026-09-07.** `fgmain` shades `fillpoly3` faces per
  pixel — a geometric normal from `dfdx`/`dfdy` of the eye position, an
  eye-space key light, a Blinn-Phong lobe and a Fresnel rim — because a
  fragment shader gets that for nothing and an interpreted Limbo inner
  loop cannot. So the nine ports on `draw3ddev` look different under
  `emu-cocoa` than under `emu-g`, **on purpose**. A face-on red triangle
  reads 255,0,0 through the software provider and 253,17,17 through the
  GPU. `INFERNO_METAL_FLAT` turns the shading off and restores exact
  agreement; run that before treating a colour difference between the
  two backends as a regression. `draw3dbench`'s agreement check compares
  geometry — centroid and lit-pixel count — and the dominant colour
  component, not the exact colour, for the same reason.
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
