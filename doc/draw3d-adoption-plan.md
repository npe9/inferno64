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
