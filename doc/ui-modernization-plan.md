# Modernizing the user interface

This is a survey and a plan. Everything stated as fact here was checked in
this tree, running, and the check is given so it can be repeated or
falsified. Where a thing was *not* checked, that is said too.

The short version: **the single biggest visual modernization — antialiased,
scalable, arbitrary-size text — already works end to end and nothing uses
it.** The work is adoption, and adoption is the same job the 76 temple
ports just went through, one layer up.

Item zero was that none of this could be checked, because the screen does
not read back. That is fixed: `tkofftest(1)` renders Tk into memory and
measures it, and every Tk number below comes from it.

Since this was written, section 2 has been done: `chardraw` takes an 8-bit
coverage mask, and antialiased text went from 17 us a string to 2 — which
removes cost as an argument against adopting a scalable font and leaves
layout as the only real risk.

## 0. First: UI work in this tree could not be checked. Now it can

`Image.readpixels` returns **`00 00 00`** for the on-screen framebuffer.
Checked both ways in one program: a window allocated on a `Screen` over
`display.image`, painted red and flushed, reads back `00 00 00`; so does
`display.image` itself at the same spot. An ordinary offscreen image in the
same program reads back real values.

That mattered more than anything else in this document. `AGENTS.md` asks
for in-process evidence rather than screenshots, and the accessibility API
reports 0 windows for this backend whether or not it works. So a UI change
could be *described* but not *shown*, and every number in a commit message
about the window system would have been reasoning — the failure this tree
spent a session correcting in `temple/varoom` and `strut`.

**This is now fixed, and the fix is `tkofftest(1)`.** A Tk toplevel does
not have to be given the display's screen: allocate a `Screen` over an
ordinary image, make a window in it, and hand the toplevel that window
under the request id `tkclient` uses when there is no window manager —
`tk->putimage(top, ". -1", win, nil)`. Tk then draws into memory, where
`readpixels` works. Two details cost an hour each and are worth writing
down: the id is `-1` and `putimage` without it is silently half-ignored,
and **the image must be handed over after the widgets exist**, because Tk
paints what it has when the image arrives.

`tkofftest` checks four things, and its first check is the control the
others need — an untouched pane must read back as one value and no ink,
or "the widget drew" cannot be told from "the readback returns rubbish
that happens to vary". Current run: **4 ok, 0 fail** with a TrueType face
present, 3 with none.

What it does *not* do is in its BUGS: it checks that widgets are sized by
the font, not that they are placed correctly. The recording check that
would — every text box, tested for overlap and for leaving the pane —
exists only inside the temple ports and has not been made general. Making
it general, on top of this harness, is the next piece of work.

## 1. Antialiased scalable text already works

`libinterp/freetype.c` is a builtin module (`freetypemodinit()` is called
from `emu/MacOSX/emu-cocoa.c`), and `ttffs(4)` — `appl/cmd/ttffs.b`, built,
in `dis/` — serves TrueType files as Inferno `.font`/subfont files at
arbitrary pixel sizes over Styx. It emits `k8` subfonts, that is, **8-bit
coverage**, and `Image.text` blends them as a mask.

Measured, drawing `"Handgloves 123"` into an offscreen RGB24 image and
counting distinct values:

| font | height | width | grey levels | draw |
| --- | --- | --- | --- | --- |
| `/fonts/lucidasans/unicode.8.font` | 15 | 113 | **2** | 1 us |
| `/fonts/lucida/unicode.8.font` | 20 | 115 | **2** | 1 us |
| `/mnt/ft/andale-mono.r.16.font` | 21 | 140 | **190** | 2 us |
| `/mnt/ft/andale-mono.r.32.font` | 41 | 266 | **244** | 6 us |

A bitmap font can only ever produce two. 190 and 244 are antialiasing, at
sizes chosen at open time rather than at whatever size somebody rasterised
a `.font` to. Opening cost 0 ms at 16 px and 2 ms at 32 px, once. (Those
draw times were 17 and 50 us when this survey was written; section 2 is
why they are not any more.)

**Tk renders such a font, antialiased.** Measured through the harness in
section 0, a `label` drawn into an offscreen pane puts **190** distinct
values on the page through `/mnt/ft/andale-mono.r.16.font` and **213**
at 24 pixels, against **3** for `/fonts/lucidasans/unicode.8.font` (the
pane's background, the label's white, and black). The same string measures
`146x21` against `119x15`, so the metrics are the face's too. This is a
check in `tkofftest`, so it stays true or fails.

These numbers were taken with a host font copied into `fonts/ttf/` for the
experiment and then removed; nothing in a clean checkout reproduces them
without putting a `.ttf` there first. **DejaVu Sans Mono** is what would
ship — see section 3.

**And nothing in the tree uses any of it.** There is no `fonts/ttf`
directory in the repository, no startup script runs `ttffs`, and no font
path in `appl/wm/`, `appl/lib/tkclient.b` or `appl/lib/titlebar.b` points at
`/mnt/ft`. The defaults are 6-to-8 pixel bitmap faces:
`/fonts/lucidasans/unicode.8.font` and its siblings, five uses, plus
`/fonts/pelm/*`. There is no `fontsrv` in this tree — `ttffs` is the only
mechanism, and it is already the whole pipeline.

To reproduce all of the above: put a `.ttf` in `fonts/ttf/`, run `ttffs`
from something that has a draw context (it needs `ctxt.display`, so not a
bare `sh`), make `/mnt/ft` exist first, and open
`/mnt/ft/<name>.r.<size>.font`.

## 2. What antialiasing cost, and what it costs now — **done**

It was 17 us against 1 us per 14-character string, 17x. That was never
what antialiasing costs; it was what *this implementation* cost.
`libmemdraw/draw.c`'s optimized text blit, `chardraw`, stored the source
colour wherever a mask **bit** was set and began:

```
	|| mask->depth != 1 || ...
		return 0;
```

so an 8-bit coverage mask — every glyph of a scalable font — fell through
to the general per-pixel `alphadraw`, with its per-scanline conversion
buffers and per-pixel indirect calls.

`chardraw` takes a coverage mask now, blending rather than storing.
Measured, with each blit flushed inside the timed region because draw
operations queue to `/dev/draw`:

| | before | after |
| --- | --- | --- |
| 512x512 masked blit, RGB24 | 1675 us | **475 us** |
| 512x512 masked blit, XRGB32 | 1200 us | **525 us** |
| 14-character string, TrueType 16px | 17 us | **2 us** |
| 14-character string, TrueType 32px | 50 us | **6 us** |
| 14-character string, bitmap font | 1 us | 1 us |

**Antialiased text now costs 2 us against the bitmap font's 1.** Not 17x;
2x, on a string, in a frame with 16,700 us in it.

The new path blends the destination's bytes against the same bytes of the
source colour, which `memimagedraw` has already converted to the
destination's format — so it needs to know nothing about which channel is
which. What it does need is which bytes are channels at all: it decodes
the descriptor, leaves a byte the format ignores exactly as it was
(because that is what the general path does), and refuses a palette index,
a channel narrower than a byte, and a destination with alpha, all of which
still go the old way. The arithmetic is `alphacalcS`'s, `MUL(a, src) +
MUL(255-a, dst)`, so the result is the same to the byte.

How that is known, and what would catch it breaking: `aadrawtest(1)`,
seven checks. It paints through a mask whose coverage runs 0 to 255 and
compares every byte against the blend computed independently in Limbo, for
`RGB24`, `XRGB32` and `GREY8`. That passes identically with the fast path
in and disabled — which is the point, the two paths agree — so a second
check asserts that `RGB24` beats `RGBA32`, which by design does not take
the fast path: with three bytes a pixel against four, `RGB24` is the
*slower* of the two through the general path, so beating it at all says the
fast path is being taken. With the dispatch disabled that check fails and
every timing returns to the "before" column.

Arithmetic is one thing and addressing another, so it also draws **real
text** into both formats and compares: 0 of 19,845 pixels differ at 32
pixels, 2,725 of them inked. Shifting the coverage path's mask origin by
one byte makes that fail — and exposed something worth knowing about the
check itself: with a *bitmap* font it passes vacuously, because a one-bit
mask never reaches the new path. `vspritetest` (57/57 against the
`.bit` files) and the temple smoketest (297 ok) cover the one-bit path,
which is untouched.

Per-pixel alpha itself was already right: a half-alpha red over white
gives `#FF8080`, and red through a 50% grey mask gives `#FF7F7F`.

## 3. Adopting a scalable font is the temple font pass, one layer up

**There were two arguments against adoption and section 2 removed one of
them.** Cost is no longer an objection: 2 us a string against 1. What is
left is layout, and that is the part to be careful about, because the tree
has just done it and knows what it costs. Moving 76 temple ports from the 8x8 TempleOS font to
Inferno's own broke, in ways that only measurement found:

- `strut`'s `txtat` returned `col + len s` — a character count — and
  chaining it across coloured runs put **three overlaps** in its help
  screen.
- `psalmody`'s whole layout constant stack had to be re-read: `13*FONTH`
  was never thirteen rows of text, it was where the picture changed.
- four more labels were centred on `n*FW/2` and sat 4 to 7 pixels off.

**`libtk`'s widgets do measure their font** — that was an inference and is
now a measurement, from `tkofftest`. Packed at 15 pixels and at 30, every
font-sized widget grows in both axes:

| widget | at 15px | at 30px |
| --- | --- | --- |
| label | 119x15 | 230x30 |
| button | 55x17 | 104x32 |
| checkbutton | 100x20 | 188x32 |
| radiobutton | 103x20 | 204x32 |
| menubutton | 30x15 | 70x30 |
| scale | 85x41 | 85x56 |

(The control: run it with the same font twice and the check reports 0 of
6.) Widgets configured in character units — an `entry`'s `-width`, a
`text`'s `-width` and `-height` — deliberately do not grow, which is Tk's
own semantics.

So the toolkit is safe and the applications are the risk: the ~60 programs
in `appl/wm/` and `appl/lib/titlebar.b`, which pack by computed pixel
geometry and draw directly.

The method that worked, carried forward: **record every text box a screen
draws, test it for overlap and for leaving the pane, drive the check
through the entry point production uses, and confirm with a negative
control.** Three checks in that session reported "no problems" while
looking at a subset of what had changed.

**The switch already exists, and it works.** `emu -f <path>` sets the
default font for every Tk widget in every program — one global,
`tkfont` in `libtk/utils.c`, which every widget's environment inherits.
Pointed at a `ttffs` face, a plain `label` with no `-font` option comes out
antialiased: `tkofftest`'s "a widget's own pixels read back" check goes
from 3 grey levels to **190** under `emu -f /mnt/ft/andale-mono.r.16.font`,
and every widget sizes itself to the face. So adopting a scalable font
tree-wide is a *runtime* choice, not an edit to ~60 programs — which also
means it can be tried, measured and reverted without touching source.

Two things had to change to make that usable, and both are done:

- **`ttffs` demanded a draw context.** It wanted one only to rasterise
  glyphs into images, never to put anything on a screen, but insisting on
  it meant `ttffs` could only be started from a program that already had a
  window — the wrong way round, since the fonts have to be served *before*
  the first window opens. It allocates its own display when there is no
  context now, so it starts from a plain shell, and the whole chain works:
  serve fonts, then run a Tk program whose default font is a TrueType face.
- **`man/1/emu` named the wrong default.** It said
  `/fonts/lucm/unicode.9.font`; `libtk` falls back to
  `/fonts/pelm/unicode.8.font`. That font does exist, it is just not the
  one used.

**The first real bug the sweep found is in the chrome every window has.**
`titlebar->minsize` — the smallest a window may be resized to — combined
only the *button* rects. The buttons are fixed-size bitmaps; the title is
text. So the minimum was short by however much the title is taller than a
button: one pixel at the tree's own 8-pixel font, and **twelve** at a
32-pixel one, which is a window that can be dragged shorter than its own
titlebar. That is a pre-existing bug a bigger font merely makes visible,
and `wmclient.b` already carries a guard clamping a negative content
height, which is the symptom being patched. `minsize` takes the bar's own
height now, and `tkofftest` asserts it at two fonts — the check fails at
both without the fix.

That is one bug in the first piece of shared UI examined, which is the
shape of the risk section 3 is about. The rest of `appl/wm` has not been
swept.

Shipping a face is a fork worth naming rather than deciding quietly: the
tree would vendor one permissively-licensed TrueType file, the way
`lib/tls/` vendors a frozen Mozilla CA bundle. **DejaVu Sans Mono and
DejaVu Sans** are the obvious pick — the licence is permissive, they carry
the Unicode coverage the existing `unicode.*` faces imply, and `ttffs`'s
own man page uses DejaVu in its example.

## 4. HiDPI is the same sweep, so do it in the same pass

`emu/MacOSX/win-cocoa.m` sets

```
	mtl_layer.contentsScale = 1.0;	/* 1 Inferno pixel = 1 point */
```

and `present_softscreen` sets `drawableSize` to the framebuffer's size in
*points*. That is a decision, not an oversight, and it is why text on a
Retina display is a 1x image the OS scales up.

Changing it is not one line, because Inferno has no notion of display
scale: a backing-resolution framebuffer renders every UI element at half
physical size. Making the UI follow a measured font and making it follow a
scale factor touch the same ~60 files. Doing them as two passes means
touching them twice.

## 5. Everything else, in the order it matters

- **A theme register.** Colours are literals: `appl/lib/titlebar.b` carries
  a hand-picked "Soft Plan9 Paper" palette inline, `appl/wm/sweeper.b` and
  `appl/wm/vt.b` have their own. The temple ports solved exactly this with
  `grpalette(2)`, one register file replacing a literal duplicated in 51
  places. The window system wants the same and does not have it.
- **The widget set is Tk 8.0.** `libtk` has button, canvas, entry, frame,
  grid, image, label, listbox, menu, pack, panel, scale, scrollbar and
  text. There is no notebook, treeview, combobox, progressbar or spinbox,
  and no themed-widget layer. The cheap half of that gap is compositions in
  Limbo over the existing widgets; only the expensive half needs C.
- **Text input is one character at a time.** `keyDown` takes
  `[chars characterAtIndex:0]` and drops everything else, and swallows every
  Cmd chord. No input method, no multi-character composition. (macOS
  already complains: `error messaging the mach port for
  IMKCFRunLoopWakeUpReliable`.)
- **What already works, and should not be re-invented:** the scroll wheel
  reaches Tk (`TkButton4P`/`TkButton5P`, bound to `yview scroll` in
  `libtk/textw.c`), and the clipboard is wired both ways in the backend
  (`clipread`/`clipwrite`).

## What this survey did not check

The Linux and Plan 9 backends — every backend claim here is about
`emu/MacOSX/win-cocoa.m`. Whether `acme`'s and `sam`'s own drawing (they do
not use Tk) share any of these assumptions. Whether any of the ~60
`appl/wm/` programs survive a font change, which is the actual adoption
risk and wants the general recording check from section 0 first. And the
on-screen appearance of anything at all: the harness proves what Tk
*drew*, not what the display *shows*.
