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

**Declared deviations** — in the file headers already, honest, still not 1:1:
`talons` (map halved to 512x512 with the bird count scaled to keep density;
painter sort rather than the depth buffer), `varoom` (painter's algorithm
instead of GrFillPoly3's per-pixel depth buffer), `xcaliber` (geometric laser
hit test rather than the per-pixel GrPeek beam guard), `tothefront` (no
user-written HolyC AI files from ~/ToTheFront), `psalmody` (fixed GodSongStr
settings, no Help.DD viewer, no compressed .HC.Z songs), `budget` (TSV rather
than Bgt.DATA.Z/Strs.DD.Z), `god` (GodDoodle out of scope), `timeclock`
(text records rather than compressed CDate, and end of file does not end a
description).

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
