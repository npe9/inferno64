# TempleOS ports: where they stand and what is left

`appl/temple/` holds the Limbo ports of Terry Davis's TempleOS demos and
apps. This is the cold-start note for that work: what is done, what is
not, and — the part that has cost the most time — how to get the original
source and art out of TempleOS in the first place.

## Read the original before claiming anything

Every port's fidelity claim is checkable, because the HolyC is on this
machine. Do not write "GAP: no sprites" or "approximates the original"
without opening the `.HC` first. Reading it has repeatedly overturned
plausible-looking guesses:

- `dungen` had a random dungeon generator. `DunGen.HC` has none — the map
  *is* sprite `<1>`, sampled every `MAP_SCALE=4` pixels.
- `flattops` ran its simulation twenty times too fast: `ANIMATE_FREQ` is 50
  and `period = 0.1*game_speed/ANIMATE_FREQ`, and the port used the whole
  `0.1*game_speed` per tick.
- `wenceslas` ran sixteen times too slow: `AnimateTask` is a `Sleep(1)`
  loop, so its constants are per millisecond, and the port ran one step per
  16ms tick.
- `zoneout` drew its crosshair green. The original draws it `LTGREEN` and
  then overdraws it `BLACK` on the still-playing branch, so it is black in
  play and green only once the game is won.
- `lib/temple/vocab.txt` looked like it had Project Gutenberg junk leaking
  in. It is byte-identical to Terry's own `/Adam/God/Vocab.DD`, junk
  included, and `GodWord` really can say `tcosa10`.

## Graphics: the draw3d side

Two companion documents cover the 3D pipeline the ports draw through:
`doc/draw3d-templeos-audit.md` is where `math/draw3d`'s vocabulary falls
short of TempleOS's, and `doc/draw3d-adoption-plan.md` is the ordered,
measured plan for putting the ports onto it and thereby onto the GPU.
The headline number from the second: the protocol provider renders a
wall-sized-triangle scene in 0.79 ms/frame against the software
provider's 5.57, but only when the destination is the window layer — an
offscreen frame buffer gets no GPU at all and is *slower* through the
protocol. `draw3dbench(1)` is the harness.

## The sixteen colours are a register file, not a constant

`grpalette(2)` (`appl/lib/grpalette.b`, `grpalettetest(1)`) holds the
TempleOS palette. Before it, fifty-one ports each carried their own copy
of

```
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, ...
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
```

which is the *contents* of `gr.palette` written out as if it were a
constant. In TempleOS it is not one: `GrPaletteColorSet` rewrites the
registers underneath a drawing that has already been made, and the
`palette` port is the demo built entirely around that fact — it now
drives the real register file instead of a private copy of it, which is
what it was always describing.

Three palettes are loadable. `EGA` is the sixteen TempleOS boots with,
byte for byte, so "this port renders what the HolyC rendered" stays a
checkable claim: `$grpalette=ega` and the pixels are the ones that were
there before the module existed. `RICH` is the same sixteen *meanings*
spent on a display that is not an EGA DAC — same hue, same dim/bright
pairing at `i` and `i+8`, `BLACK` and `WHITE` byte-identical because
ports mix palette black with `Draw->Black` in one frame and a near-black
would show as a seam. `GREY` is the ramp `Palette.HC` writes. `RICH` is
the default; nothing about what an index *means* changed, so no port
draws anything different, it just draws it in better colours.

`shade`, `mix`, `dither` and `ramp` are the other half: colours that are
not in the sixteen at all. That is what the original could not do, and
what it faked.

**`keepaway` is the worked example.** Its `DCLighting` probability-dither
tossed a coin per pixel between a face's colour and its dark or bright
partner, because sixteen registers have nothing in between. The colour it
was aiming at is the *expected value* of that coin, and this display can
simply produce it: the sprite is now an `RGB24` image filled with
`grpal->mix(...)` at the illumination term, and the dither is gone. Same
lighting, no noise, and as many shades as the light has angles.

**A correction: `keepaway`'s CMAP8 table was right.** This document said,
and commit `d463137a` said, that `keepaway`'s hand-typed "the same 16
colors as exact Plan 9 CMAP8 pixel values" was wrong — that
`cmap2rgb(36)` is green where the table has it standing for `BLUE`. That
claim was wrong, and it was wrong because it was checked against a
`cmap2rgb` written from memory rather than against the one in this tree.
`libdraw/rgb.c` computes `j = (c-v+r)&15`; the formula other Plan 9
lineages carry, and the one that was tested against, is `j = (c-v+r)/4`.
With the tree's own formula, 36 is `0000AA`, blue, and every entry of
that table is exactly what `scripts/tos_extract_sprites.py` independently
derives for the same sixteen colours. Nothing was broken and nothing
needed fixing.

The `keepaway` change itself stands on its own: dithering two palette
entries to fake a shade is a workaround for a palette, and RGB24 with the
real colour is better whether or not the CMAP8 table beside it was
correct. The measurement — 7 distinct colours in the lit sprite before,
30 after — is unaffected. Only the claim of a bug found in passing was
false, and the lesson is the one this file already states elsewhere:
check the tree, not your memory of the tree.

**Two more ports had the same shape, and are converted.** `shading` is
the demo *of* `DCLighting`, and its own GAP note already conceded the
divergence: TempleOS generates a random U16 per pixel and compares it
with `dither_probability_u16`, and the port stood in for that with a 4x4
ordered tile quantised to seventeen levels. Both are ways of assembling a
colour out of pixels of two other colours, because the palette has
nothing between them. It now fills a face with the shade, on a 65-step
ramp — nothing forces it to sixteenths any more. `grmodels`'s `trishade`
was the same 4x4 Bayer tile and is now `mix` at 32 steps between each
pair, cached the way the tiles were.

What is *not* converted, deliberately: `ROPF_DITHER` used as a fill
style. `titanium`'s tan desert, `bombergolf`'s background, `talons`'s
tiles and `sunmoon` are checkerboards that read as texture, and TempleOS
meant them to. A dither standing in for a shade is a workaround for a
palette and goes; a dither used as a pattern is the picture and stays.

**What the change is worth, measured.** Distinct colours in one rendered
frame, counted with `readpixels` off the running port at frame 40 — the
same code path in both cases, one build against the other:

| port | before | after |
| --- | --- | --- |
| `shading`, whole window | 40 | 139 |
| `keepaway`, the lit sprite raster | 7 | 30 |

Two things about how that was taken, both of which cost a run. The count
has to happen *before* `img.flush(Draw->Flushnow)`: these ports draw
through the protocol provider, and a present drains the GPU's queue and
leaves the readback nothing to replay — counting after the flush reported
2 colours for a frame that plainly had a shaded sphere in it. And
`temple/smoketest run` does not establish any of this: it spawns `init`
for 300ms, and every one of these changes lives in the *redraw* path, so
297/297 says the ports load and initialise and nothing more.

**The trap this work sat on.** A colour is a 32-bit RGBA word, but this
tree's `int` is 64 bits wide *at run time* (`1<<40` is a perfectly good
`int` here) while the compiler types a literal of `16r80000000` or more
as `big`. So a *literal* white is `int 16rFFFFFFFF` = −1, sign-extended
by the compiler, and a *computed* white is 4294967295, sign-extended by
nothing. They draw identically, because only the low 32 bits reach the
display, and they compare unequal while printing the same eight hex
digits under `%ux`. Every value `grpalette` returns goes through one
`rgba()` that sign-extends; any other code doing colour arithmetic has to
do the same. This is the same shape of defect as "Plan 9 `long` is 32
bits", inverted: here the arithmetic is *wider* than the type it is
notionally in.

## Sprite3 places by the ORIGIN, sprite2d places the middle

The single most repeated porting mistake in this tree, found 2026-09-06
after "the elephant is wrong" and then swept for.

TempleOS's `Sprite3(dc,x,y,z,elems)` puts the *bin rectangle's (0,0)* at
(x,y), and `Sprite3ZB(dc,x,y,z,elems,theta)` turns it about that same
point, with `theta` in **radians**. The rectangles are not centred: the
elephant's is (-124,-100)-(95,136), so its origin is at its shoulder;
`squirt`'s nozzle is (-1,-5)-(25,5), so it swings about the hose end
twenty-five pixels from its tip; the backdrops are (0,-117)-(641,2), so
they hang above the ground line.

`draw3d`'s `sprite2d` places the *middle of the bitmap*. The two are
different by however far the origin sits from the centre, which was 124
pixels for the elephant, 47 for a backdrop, 18 for `bigguns`' barrel and
12 for `squirt`'s nozzle. Ports that got this wrong compensated with
hand-measured constants that were close but never right.

Two idioms, and both are now in more than one port:

- Unrotated: `img.draw(spr.r.addpt(Point(x, y)), spr, msk, spr.r.min)`.
  Note the source point - `Point(0,0)` reads the wrong part of a sprite
  whose rectangle does not start at the origin.
- Rotated: carry the origin-to-middle offset through the mirror and the
  rotation and ask `sprite2d` for the middle where it lands. See
  `appl/temple/bigguns.b:sprorigin` or `bombergolf.b:drawrot`.

A symmetry plane (`DCF_SYMMETRY|DCF_JUST_MIRROR`) applied to a rotated
sprite is a flipped sprite turned the other way, since M.R(a) = R(-a).M.

Checked across every port that uses a sprite: `bombergolf` and
`rocketscience` already did it right, `elephant` did it right for its
scene; `elephantwalk`, `bigguns`, `squirt` and `rocket` did not and now
do. `rocket` and `rocketscience` still centre their *rotated* sprites,
whose origins are half a pixel off centre, which is not worth the code.

## The `.mask` files were laid out wrongly

Fixed 2026-09-06; here because the failure was invisible and the symptom
looked like something else entirely.

Plan 9 lays an image row out relative to a **byte boundary**, not to the
rectangle's left edge: `libdraw/bytesperline.c` gives a 1-bit image whose
`r.min.x` is not a multiple of 8 an extra byte per line, and its first
pixel starts part way into the first byte. Both sprite extractors wrote
`(width + 7) // 8` bytes with the first pixel at bit 0. The result:

- **85 of the 230 `.mask` files were short** and `Display.open` failed on
  them outright, returning nil.
- **146 of them were misaligned** by up to seven pixels, including many
  that opened fine.

A port whose mask came back nil then passed nil to `draw3d`'s `sprite2d`,
which built no coverage mask and drew its whole bounding box - so the
sprite appeared as a **solid black rectangle** with the art inside it.
That is what "the alpha on sprites is wrong" looks like from the outside,
and it is three bugs deep from the byte layout that caused it.

All 230 masks were repacked in place from the pixels they already held;
no re-extraction was needed. `sprite2d` now always builds its coverage
mask, so a missing mask degrades to an unmasked sprite rather than a
black box.

Still broken: `asciiorgan_1`. Its rectangle is `(-108,-56)-(-51,1)`, the
only asset lying entirely to the left of the origin, and both its `.bit`
and `.mask` fail `memload` with "bad writeimage call" even at the size
`bytesperline` asks for. `unitsperline` computes that size through an
unsigned wraparound for a negative `r.max.x`; that is where to start.

## Getting the source and the art

**The GitHub mirrors are corrupted.** `/Users/npe/src/TempleOS`,
`/Users/npe/src/templeos-cursor/templeos-source` and
`/Users/npe/src/templeOS-textbook` were all exported through a pipeline that
strips every `0x05` byte, which silently wrecks the binary DolDoc sprite
bins embedded in `.HC` files. The text reads fine, so this is easy to miss;
mesh extraction simply fails with an invalid vertex index, and bitmap
extraction can yield plausible-looking garbage. Four `wenceslas_*.bit`
files in this tree came from that route and were sizes no man could be.

The pristine source comes from the distribution ISO:

    python3 scripts/tos_expand.py /Users/npe/src/templeos-cursor/TempleOS.ISO -o /tmp/tos

`tos_expand.py` walks the RedSea filesystem and expands TempleOS's own
LZW-style `.Z` compression. Extract from `/tmp/tos/...`, never from a
mirror.

Three extractors, and it matters which:

| bin kind | tool | output |
| --- | --- | --- |
| `SPT_MESH` | `scripts/tos_extract_meshes.py` | `icons/temple/<name>_<n>.mesh` |
| bitmap and vector sprites | `scripts/tos_extract_sprites.py` | `icons/temple/<name>_<n>.bit` + `.mask` |
| vector element lists | `scripts/tos_extract_sprites.py` | `lib/temple/sprites/<name>_<n>.spr` |

`tos_extract_bitmaps.py` also reads `SPT_BITMAP` bins, but its extents are
exclusive where the sprite rasterizer's are inclusive, so it produces
images one row and one column smaller. **Every tracked `.bit` in this tree
is the sprite script's output**; use that one, or the new asset will not
match its neighbours.

Each extractor skips what is not its kind and says so, which is how to find
out what a bin actually is. A bin whose first element is a mesh is a mesh,
whatever a stale `.bit` of the same name suggests.

## Rendering the 3D sprite calls

TempleOS's `Sprite3*` family maps onto `draw3d(2)`, which already has a
matrix stack, a z-buffer (`DCDepthBufAlloc`) and a `settransform` hook that
is literally `dc->transform`. Prefer matrices to a per-vertex closure — the
closure runs interpreted Limbo once per vertex.

Two conventions to get right, both settled by measurement rather than
argument:

- TempleOS composes `Mat4x4RotY(r,..)` after `Mat4x4TranslationEqu(r,..)` as
  `v' = Ry * T * v` — the last call is outermost. draw3d's `translate`,
  `rotatex` and `rotatey` post-multiply, so the call order is the same.
- draw3d divides by `-z` and draws the larger eye z on top; TempleOS divides
  by `+z` and treats the smaller sprite z as nearer. A `scale(1,1,-1)` at
  the outside of the model matrix reconciles them. `zoneout` and
  `wenceslas` both do this, and `wenceslas`'s probe confirms it by drawing
  two overlapping triangles at sprite z -30 and +30 and checking that only
  the nearer survives.

## Verifying without looking at pixels

`emu-cocoa` will start a demo and it will survive, which proves very little.
Two cheaper and stronger checks, both used on `zoneout` and `wenceslas`:

- **Project known points** through the same matrices and assert on the
  numbers: a point dead ahead lands at screen centre, yawing left moves it
  right, a point behind the eye is rejected, a movement key advances the
  camera by exactly the original's constant.
- **Render offscreen and `readpixels`**, with a negative control that draws
  nothing. Count a colour that only the thing under test paints — the
  Wenceslas king's robe is `BLUE` and the peasant has none, so 142 blue
  pixels for one and zero for the other says which mesh was drawn. Compare
  the drawn bounding box against the mesh's own extents.

Both of those found real defects in `lighttable`, which is worth
recording because it was written from the same reading of the original
that then turned out to be too loose. A probe that fires one photon at a
straight mirror at twelve angles of incidence and compares the reflected
direction against `2*theta_n + pi - theta_in` showed errors of up to 159
degrees past 46 degrees of incidence, three mirror events where there
should be one, and the zero-normal fallback firing. The cause was the
arc search in `FindNormal`: the original sweeps two arcs outward from
`theta+pi±pi/4` which together cover the whole circle, and the port swept
`theta±pi/4` to `theta±pi`, missing the wedge either side of the way the
photon is going — which is exactly where the crossings are on a grazing
hit. Restoring the original's sweep brought every angle from 7 to 79
degrees within 0.9 degrees, and the old sweep put back as a negative
control brought the failure back. A second probe against Snell's law
agrees to within 0.15 degrees from 5 to 69 degrees. Three other
deviations came out of the same reading: the photon moved `v` per baby
step rather than `v/BABY_STEPS` per step, photons were destroyed at the
edge instead of bouncing off the border, `p_normal_inhibit` was missing
altogether, and the flood fill filled the *fine* bitmap as well as the
coarse map — against the original's own first line, "the coarse gets
flood-filled but the fine grained is only outlines", which is what stops
the inside of a lens being a surface.

A soak run on the same harness closes what those two probes did not
reach: exit from a lens (the `n1=1.5` direction, where the arcsine clamp
lives), the border bounce, and `p_normal_inhibit` under load. Under the
critical angle the exits agree with Snell to within 0.7 degrees; past it
the clamp sends the ray out along the surface, as its GAP line says. Two
hundred and fifty-six photons over three hundred frames stay at 256 —
none escapes, all bounce — with the counters proportionate (80 mirrors,
104 refractions, 48 inhibited) and no zero-normal fallbacks, and the
whole run takes 18ms, 0.06ms a frame against a 20ms timer. Worth doing
because `findnormal` is two arc searches of a few hundred `bpeek` calls
each and a photon sliding along a boundary could in principle re-fire it
every few steps; it does not.

**A demo that starts under `emu-cocoa` and survives proves startup and
nothing else.** With no input delivered, `lighttable` has no photons and
`ropcollision` has never seen the pointer, so in both cases the code
under test never runs. Use it to catch a module that raises on load, and
the probes for everything else.

`appl/temple/smoketest.b` loads every module (`emu-g -r. temple/smoketest`,
291 of 291 at the time of writing). Redirect it to a *file* — through a
pipe, buffering makes it look hung. Its `run` mode needs a draw context and
fails under `emu-g`.

## Auditing a port against its original

Done 2026-09-06 over all 61 ports that have an original. Four automated
passes; three of them turned out to be mostly noise, which is worth knowing
before anyone runs them again.

**Comparing function names is useless.** The ports rename everything —
`DrawIt` becomes `redraw`, `AnimateTask` becomes `animate`, `CleanUp`
vanishes into the garbage collector. By that measure `psalmody` was missing
31 of 45 functions; it has the clipboard, the octave, the tempo control and
the meters, under Limbo names. Same for `budget`'s "missing" file
persistence, which is there as TSV.

**`RegWrite`/`RegDft` is a false positive**: all fourteen ports that would
need it use `scorestore` instead.

**`Play()` melodies are all present**, verbatim, in every one of the twelve
ports whose original has a `SongTask`. Sound is not where the gaps are.

**Two passes are worth running.** Compare every numeric `#define` of the
original against the port's own `NAME: con VALUE`, matching names
underscore- and case-insensitively and allowing a `.0` suffix on the value —
without those three tolerances it is all false positives. And compare the
string literals the original *prints*: ports rename functions but they
quote the original's text, so a printed string that appears nowhere is a
feature that was not ported. That pass is what found the four demos below
that draw no text at all.

## Every port ran slow, and none of them ran at 60fps

Seventy of the 138 ports drove their animation from a copy of the same
five lines:

```
timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
```

Fifty-seven of the copies were byte-identical and the rest differed only
in whether the period was an argument. It is wrong twice over.

**Sleeping for a length of time is not keeping to a rate.** The time a
frame's work takes is added to the sleep rather than taken out of it, so
the period is always longer than asked and grows with the work.

**And this host's sleep overshoots on its own account.** Measured, with
`nanosleep` directly in C and again through `sys->sleep` in Limbo: 16ms
takes 18.70ms, and it is about a fifth over at every length from 1ms to
33ms. A port that does nothing at all therefore gets 53 frames a second
when it asks for 60. That is not `emu`'s doing — `emu`'s clock agrees
with the host's wall clock to within the startup time — it is macOS's
scheduling quantum.

The fix is not a better sleep. It is to sleep to an **absolute
deadline**: ask for the time between now and when the next frame is due,
so the overshoot comes off the following ask instead of adding to the
period. With the very same `nanosleep` that gives 18.70ms when asked for
16, deadline pacing gives **16.699ms**. That is `frameclock(2)`
(`appl/lib/frameclock.b`), and all seventy copies are gone.

**Measured, per port, not by arithmetic.** `psalmody` asked for 33ms:

| | before | after |
| --- | --- | --- |
| `psalmody`, measured in the port | 26.94 fps | 59.99 fps |

The "before" is the port exactly as it was with nothing added but a frame
counter inside its own timer loop. Six of the heaviest ports measured
after the change: `titanium` 59.98, `stadium` 60.01, `talons` 59.97,
`rawhide` 59.99, `keepaway` 58.89, `varoom` 58.38 — the last two are the
two whose redraw sometimes costs more than a frame, which is the clock
reporting the port rather than itself.

**Speed had to be preserved, and that is the risky half.** A port that
steps a fixed amount per tick would run 19% fast once the clock stopped
overshooting, and one that ticked at 10ms would run 40% slow if it were
simply moved to 60Hz. So a fixed-step port keeps its own step as a
*substep*: the clock reports the milliseconds that actually passed, and
the port runs as many of its own steps as that time calls for, then draws
once. `blot` runs exactly 64 steps of 10ms and stops, so it can be timed:
**797ms before, 652ms after, against the 640ms its code asks for.** The
port was running 19% slow and now runs at the rate it was written for.

Twenty ports needed nothing but the clock, because their state was
already a function of `sys->millisec()` rather than of tick count. Eleven
more were written for a 16ms step, which is what 60fps is. The rest
substep.

What is *not* on the clock: `temple/god`, whose ticker sends without
blocking and stops when a popup closes, neither of which the shared clock
does; and the handful of ports whose `sleep` paces a game rather than a
frame — `life`'s generations, `maze`'s search, `hanoi`'s moves.

## State

**`Demo/Games` is complete.** All 30 are ported, and as of this note all of
them have been checked against the original rather than merely written.

**`Apps` is complete** apart from `Apps/X-Caliber`, which is ported as
`xcaliber`.

**`Demo/Graphics` and `Demo/Snd` are complete.** All 40 that were
unported have been written, wired into `appl/temple/mkfile` and
`smoketest.b`, given a `man/1` page and a `man/1/INDEX` entry.  The
smoketest loads 291 of 291 clean, each new demo starts under `emu-cocoa`
without raising, and `man/1/temple` lists them all under a `Graphics`
heading.

Three naming notes for anyone reading the list:

- `Grid.HC` is ported as **`griddemo`**, because `grid` in section 1
  already belongs to `grid-session(1)`.  `GridDemo()` is the original's
  own entry point.
- `3DPoly.HC` is `3dpoly.b` with `implement Poly3d`, since a Limbo module
  name cannot start with a digit.
- `Demo/Graphics/Collision.HC` is **`ropcollision`**, because `collision`
  belongs to the `Demo/Games` program of the same name, which is a
  different demo (64 elastic balls) and is faithfully ported.

Seven of them cannot reproduce the mechanism the original exists to show,
and say so in the file and the man page rather than pretending:
`balloon` (VGA plane-mask pokes into a framebuffer), `charanimation`
(repointing `text.font` so every space on the display ripples), `pantext`
(`gr.pan_text_x/y`, which moves everything already drawn), `palette`
(hardware palette registers), `winzbuf` (the window manager's own
per-cell ownership array), `wallpaperctrl` and `wallpaperfish` (controls
and a paint routine installed on the desktop task).  In each the content
is ported and the mechanism is named as absent.

### What is left inside the ports that exist

**Undeclared deviations** — the port differs and does not say so. As of
2026-09-06 the list below is closed; it is kept because the *kinds* of
gap it names are the ones to look for next time.

- `bigguns` halved the world silently: `MAP_WIDTH` is 2048 in BigGuns.HC
  and was 1024 in the port, `DUST_NUM` is 512 and the port used 256.
  `MAP_WIDTH` drives `elevs[]`, the scroll range and the dust wrap, so it
  was not cosmetic. It also never showed either `PopUpOk` — Terry's "I
  refuse to rip-off the original ... Write games, don't play them." and
  "The map scrolls." — and did not use `ROP_COLLISION`, testing a shot's
  centre against `elevs[]` instead of its circle. *Fixed*: both constants,
  both panels, and the circle test. Since the map holds nothing but the
  terrain, `ROP_COLLISION` against `bkcolor=LTCYAN` reduces exactly to
  asking whether any point of a radius-2 circle is at or below `elevs[]`;
  a real map bitmap would buy nothing.
- **Four ports opened no font and drew no text at all**: `bigguns`,
  `massspring`, `maze`, `hanoi`. *Fixed*: MassSpring's `PopUpOk`
  ("Left-Click to place mas", typo included), Maze's two `TextPrint`
  lines, and Hanoi's `Disk:%d from %d to %d` move readout are all
  present; `bigguns`' only text was its two panels.
- **Four ports were silent where the original beeps**: `digits`, `maze`,
  `tictactoe`, `hanoi`. *Fixed* through `tone(2)`. `Beep` is
  `Kernel/KMisc.HC`'s `Beep(I8 ona=62)` — `Snd(ona)` for 500ms then
  silence for 200ms — so the port computes the frequency from the ona the
  same way `asciiorgan` does, and `tictactoe` keeps the original's two
  pitches, 62 for player one and 74 for player two. The fanfares are
  spawned rather than run inline, because three of them inline would
  freeze the window for two seconds; the original does freeze.
- `digits` had reworded instructions and its own colour names. *Fixed*:
  the original's text, and `ST_RAINBOW_10`'s names and palette values —
  BLACK, BROWN, RED, LTRED, YELLOW, GREEN, BLUE, PURPLE, LTGRAY, WHITE,
  which are TempleOS's names and not the resistor code's, even though the
  text says electrical engineering colour codes. Same for `hanoi`, whose
  disks are `gr_rainbow_10`.
- `logic` showed only the three-input worked example. *Fixed*: `Init`
  prints one example or the other according to the table size, and the
  port now does the same.
- `spriteedit`'s `SPT_ROTATED_RECT` and `SPT_SHIFTABLE_MESH`: *checked,
  nothing wrong*. The port's kind constants are `iota` over the same
  order as `Adam/Gr/Gr.HH`, all thirty of them, and both kinds are drawn,
  created, dragged and serialised.

**Declared deviations** — in the file headers already, honest, still not 1:1.

Closable, and closed:

- `timeclock`'s "end of file does not end a description". **Done, and not
  in the port.** `readdesc()` stopped when the read returned <= 0, which
  was right; emu never returned 0. Host stdin reaching EOF killed the
  keyboard slave without telling the console queue, so any reader of
  `/dev/cons` blocked for ever — `temple/timeclock`, every `p9/cmd` tool's
  bare-stdin fallback, a piped `emu` shell. Fixed in
  `emu/port/devcons.c` (`kbdhangup`), `b6d495fd`, with a negative control.
  The other half of that entry — binary compressed `CDate` records — stays.
- `xcaliber`'s laser. **Done.** The old note said the hit test was geometric
  rather than the original's `GrPeek` probe, and that was wrong about the
  original: `X-Caliber.HC` picks what the beam *damages* geometrically too,
  in the derivative, by nearest mass within its own radius of the ray. What
  is per-pixel is the beam that gets *drawn* — `Line()` is handed
  `&LaserPlot`, which reads each pixel and ends the line at the first that is
  neither BLACK nor WHITE. So the beam stops on a shot in flight, an
  explosion ring or an enemy's drawn body, none of which is a mass, and
  passes through white text. Both are now present, and the frame is composed
  offscreen so the walk can read it back.
- `talons`' halved map and painter sort, `varoom`'s painter sort. **Both
  measured, both staying as they are** — see below.

**The z-buffer is not affordable in these two, and that is a measurement.**
`math/polyfill` has a real per-pixel z-buffer and `math/draw3d`'s
`fillpoly3` drives it; `3dpoly`, `zoneout` and `wenceslas` all use it. But
`polyfill->fillpoly` is interpreted Limbo where `Image.fillpoly` is a
native draw call. On a synthetic frame of 200 quads and 300 triangles —
lighter than `varoom`'s real load — it costs **7.18ms a frame against
0.07ms**, a hundred times over, plus **0.68ms a frame** to clear a 640x480
depth buffer. That is the whole reason the two big painter sorts exist,
and it should be re-measured, not re-argued, if anyone tries again.

What the sort actually loses in `varoom` is narrow, and worth knowing
before spending on it. The original gives every *sprite* a single depth —
`Sprite3B(dc,x,y,z+GR_Z_ALL,img)`, and `GR_Z_ALL` is only `I32_MAX/2`, a
bias to keep z positive, not a "no depth" flag — so for whole objects a
back-to-front sort by that same depth agrees with a depth buffer exactly.
It differs in two places: where a track polygon's *interpolated* depth
crosses a sprite's single depth (a bush on the road, whose base should be
cut by nearer tarmac and whose top should not), and between the triangles
of one car mesh, sorted by centroid here and resolved per pixel there.

**`talons`' map is a heap limit, and now a numbered one.** At the
original's 1024x1024 the world generates in 341ms into 207851 panels and
6272 objects and plays fine — but only with `emu -pheap=40000000` or more,
where emu's default heap is 32MB; at 32MB it dies in `dopanels` with
`out of memory: heap`. The demo has to work started from the wm menu with
no flags, so it stays at 512x512. To try the full size: `MAPW`/`MAPH` to
1024, `BIRDN` to 256 (`B_NUM`), the `obx`.. arrays to 16384 (4096 silently
drops objects past 6272), and pass the flag. The bump, fish, boat and tree
densities are per-panel probabilities and scale by themselves.

Not closable, and not worth attempting:

- `tothefront` (no user-written HolyC AI files from ~/ToTheFront) would need
  a HolyC interpreter.
- `psalmody` (no compressed `.HC.Z` songs), `budget` (TSV rather than
  `Bgt.DATA.Z`/`Strs.DD.Z`) and half of `timeclock` (text records rather than
  compressed `CDate`) would need a Limbo *compressor* for TempleOS's LZW;
  `scripts/tos_expand.py` only decompresses, and it is Python, not in-tree.
- `god`'s GodDoodle is a separate program.
- `psalmody`'s fixed GodSongStr settings and missing Help.DD viewer.

**Platform-level and recurring**, declared in about twenty headers and
unlikely to change: the `MenuPush` pull-down bars, `WinMax` fullscreen
borderless operation, the `PopUp*` dialog family, and `ROP_XOR`.

Notes for whoever starts on these:

- Several of these lean on machinery TempleOS has and this tree does not,
  and the honest port is of the *content* rather than the mechanism:
  `winzbuf` reads `gr.win_z_buf`, `pantext` slides `gr.pan_text_x`,
  `charanimation` patches `text.font` in place, `palette` writes the VGA
  palette registers. Say so in the file rather than pretending.
- `Balloon.HC` writes VGA planes directly through `OutU8`. What is worth
  porting is its content: the 60-byte Commodore 64 balloon sprite, moved
  down the screen. There is a stale `dis/temple/balloon.dis` from an
  older layout and an unrelated `appl/danby/balloon.b`.
