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

`appl/temple/smoketest.b` loads every module (`emu-g -r. temple/smoketest`,
253 of 253 at the time of writing). Redirect it to a *file* — through a
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

**`Demo/Graphics` is the frontier: 35 unported.** Sizes are the readable
text lines of the `.HC`, which is a fair proxy for the work:

Four are now done — `mousedemo`, `griddemo` (the name `grid` in section 1
belongs to `grid-session`, so the port takes the original's `GridDemo()`
entry point), `bspline` and `speedline` — leaving 35.

- Small, no sprite bins (under ~50 lines): `scrncapture` (13), `winzbuf`
  (21), `palette` (23), `charanimation` (25), `spriteputext` (21),
  `spriteraw` (32), `pantext` (33), `blot` (35), `sunmoon` (36),
  `balloon` (28).
- Middling: `spriteplot3d` (32), `spritetext` (28), `rotatetank` (38),
  `extents` (41), `spriteplot` (45), `predatorprey` (69),
  `lowpassfilter` (74), `shadow` (78), `wallpaperfish` (84),
  `scrollbars` (95), `mathaudiodemo` (96), `pick` (96), `wallpaperctrl`
  (96), `slider` (98), `3dpoly` (107), `commonancestor` (111).
- Large: `shading` (154), `polezeros` (158), `lattice` (252),
  `elephant` (256), `pick3d` (284), `transform` (233), `edsprite` (54 but
  12 sprite bins), `lighttable` (592), `spriteput` (18 lines, 25KB of
  sprite data).

`Demo/Snd` has two left: `morsecode` (161) and `waterfowl` (82, one sprite
bin, 300KB of sound data).

### What is left inside the ports that exist

**Undeclared deviations** — the port differs and does not say so:

- `bigguns` halves the world silently. `MAP_WIDTH` is 2048 in BigGuns.HC and
  1024 in the port; `DUST_NUM` is 512 and the port uses 256. `MAP_WIDTH`
  drives `elevs[]`, the horizontal scroll range and the dust wrap, so this is
  not cosmetic. It also never shows the opening `PopUpOk` — which is Terry's
  "I refuse to rip-off the original ... Write games, don't play them.", the
  same text `zoneout` now carries — nor "The map scrolls.", and it does not
  use `ROP_COLLISION`. Its one GAP line covers the scroll widgets, not any
  of this.
- **Four ports open no font and draw no text at all**: `bigguns`,
  `massspring`, `maze`, `hanoi`. Absent with it are MassSpring's
  "Left-Click to place mass / Right-Click and drag to place spring / Springs
  are 100 pixs long.", Maze's "Solve maze starting at right click.", and
  Hanoi's `Disk: %d from %d to %d` move readout.
- **Four ports are silent where the original beeps**, and none of them
  references `tone(2)`: `digits` (`Beep;Beep;` on a wrong answer), `maze`
  (leaving the maze), `tictactoe` (`Beep` for player one and `Beep(74)` for
  player two on an illegal click — two different pitches), `hanoi` (on
  completion).
- `digits` reworded the instructions instead of using the original's, and
  `logic` shows only the three-input worked example, not the four-input one
  ("enter A=0xFF00, B=0xF0F0, C=0xCCCC and D=0xAAAA").
- `spriteedit` covers element kinds 0-24 but `SPT_ROTATED_RECT` and
  `SPT_SHIFTABLE_MESH` are not obviously among them; worth one check.

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

- `Demo/Graphics/Collision.HC` is a different program from
  `Demo/Games/Collision.HC`. The port `collision` is the games one — 64
  elastic balls in fixed point — and is faithful. The tracked
  `icons/temple/collision_1.bit` and `_2.bit` belong to the *graphics*
  one, an unported `ROP_COLLISION` mouse demo, and the name is taken.
- Several of these lean on machinery TempleOS has and this tree does not,
  and the honest port is of the *content* rather than the mechanism:
  `winzbuf` reads `gr.win_z_buf`, `pantext` slides `gr.pan_text_x`,
  `charanimation` patches `text.font` in place, `palette` writes the VGA
  palette registers. Say so in the file rather than pretending.
- `Balloon.HC` writes VGA planes directly through `OutU8`. What is worth
  porting is its content: the 60-byte Commodore 64 balloon sprite, moved
  down the screen. There is a stale `dis/temple/balloon.dis` from an
  older layout and an unrelated `appl/danby/balloon.b`.
