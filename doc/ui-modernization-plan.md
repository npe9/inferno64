# Modernizing the user interface

This is a survey and a plan. Everything stated as fact here was checked in
this tree, running, and the check is given so it can be repeated or
falsified. Where a thing was *not* checked, that is said too.

The short version: **the single biggest visual modernization — antialiased,
scalable, arbitrary-size text — already works end to end and nothing uses
it.** The work is adoption, and adoption is the same job the 76 temple
ports just went through, one layer up.

## 0. First: UI work in this tree is currently unverifiable

`Image.readpixels` returns **`00 00 00`** for the on-screen framebuffer.
Checked both ways in one program: a window allocated on a `Screen` over
`display.image`, painted red and flushed, reads back `00 00 00`; so does
`display.image` itself at the same spot. An ordinary offscreen image in the
same program reads back real values — that is how every measurement below
was taken.

This matters more than anything else in this document. `AGENTS.md` requires
in-process evidence rather than screenshots, and the accessibility API
reports 0 windows for this backend whether or not it works. So today a UI
change can be *described* but not *shown*, and every number in a commit
message about the window system would be reasoning rather than measurement.
That is exactly the failure this tree spent a whole session correcting in
`temple/varoom` and `strut`.

The mechanism for a fix exists and is half-proven. A `Screen` can be
allocated over an **offscreen** image, a window made in it, and a Tk
toplevel bound to that window with `Tk->putimage(top, ".", win, nil)`.
Doing so, `top.image` is the offscreen window and Tk's own background paint
*does* reach the offscreen pixels — they come back `d8 f0 f5` rather than
the white the image was created with. But packed widget content did not
appear with that minimal sequence (`toplevel`, `putimage`, `label`, `pack`,
`update`), although the label reports `-actwidth 119 -actheight 15`, so it
was laid out. Something between layout and paint still wants what
`tkclient` does on a real window.

**Step one is therefore: finish that harness**, so that a Tk widget's
actual pixels can be read in-process. Then the psalmody method — record
every text box, test overlap and off-pane, drive through the production
entry point, confirm with a negative control — applies to the whole window
system rather than to one port at a time.

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
| `/mnt/ft/andale-mono.r.16.font` | 21 | 140 | **190** | 18 us |
| `/mnt/ft/andale-mono.r.32.font` | 41 | 266 | **244** | 62 us |

A bitmap font can only ever produce two. 190 and 244 are antialiasing, at
sizes chosen at open time rather than at whatever size somebody rasterised
a `.font` to. Opening cost 0 ms at 16 px and 2 ms at 32 px, once.

**Tk takes such a font too.** `label .l -font /mnt/ft/andale-mono.r.16.font`
is accepted and metricked: the same string measures `146x21` against
`119x15` in `/fonts/lucidasans/unicode.8.font`. What was *not* seen is Tk's
antialiased pixels, for the reason in section 0 — the label was on screen
and the screen does not read back.

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

## 2. What antialiasing costs, and why it is not what it must cost

18 us against 1 us per 14-character string is 18x relative and 1.3 us per
character absolute. For window chrome and labels that is nothing. For a
full redraw of a text window — 50 lines of 80 characters — it is about
5 ms against 0.3 ms, which is real.

But that is what *this implementation* costs, not what antialiasing costs.
`libmemdraw/draw.c`'s optimized text blit, `chardraw`, begins:

```
	if((par->state&(Replsrc|Simplesrc|Replmask)) != (Replsrc|Simplesrc)
	|| mask->depth != 1 || ...)
		return 0;
```

`mask->depth != 1` — the fast path handles **one-bit masks only**. An 8-bit
coverage mask falls through to the generic per-pixel `alphadraw`. So there
is a well-shaped optimization available: an 8-bit-mask case in `chardraw`,
the same loop reading a byte of coverage instead of a bit. The baseline to
beat is in the table above, and the negative control is trivial — disable
the new case and the 18 us comes back.

Per-pixel alpha itself is already right: a half-alpha red over white gives
`#FF8080`, and red through a 50% grey mask gives `#FF7F7F`.

## 3. Adopting a scalable font is the temple font pass, one layer up

This is the part to be careful about, because the tree has just done it and
knows what it costs. Moving 76 temple ports from the 8x8 TempleOS font to
Inferno's own broke, in ways that only measurement found:

- `strut`'s `txtat` returned `col + len s` — a character count — and
  chaining it across coloured runs put **three overlaps** in its help
  screen.
- `psalmody`'s whole layout constant stack had to be re-read: `13*FONTH`
  was never thirteen rows of text, it was where the picture changed.
- four more labels were centred on `n*FW/2` and sat 4 to 7 pixels off.

`libtk`'s widgets measure their font, so the toolkit itself is probably
safe — but that is an inference from the widget code, not a measurement,
and it is the first thing the harness from section 0 should check. What is
certainly not safe is the ~60 programs in `appl/wm/` and
`appl/lib/titlebar.b`, which pack by computed pixel geometry and draw
directly.

The method that worked, carried forward: **record every text box a screen
draws, test it for overlap and for leaving the pane, drive the check
through the entry point production uses, and confirm with a negative
control.** Three checks in that session reported "no problems" while
looking at a subset of what had changed.

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
`emu/MacOSX/win-cocoa.m`. Whether `libtk`'s widgets really measure their
font rather than assuming a cell, which is inference from reading them.
Whether `acme`'s and `sam`'s own drawing (they do not use Tk) share any of
these assumptions. And the on-screen appearance of anything at all, for the
reason in section 0.
