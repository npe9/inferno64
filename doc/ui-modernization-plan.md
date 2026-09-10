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
| `/mnt/ft/go-mono.r.13.font` | 17 | 112 | **167** | 2 us |
| `/mnt/ft/go.r.16.font` | 21 | 118 | **185** | 2 us |
| `/mnt/ft/go.r.24.font` | 32 | 177 | **215** | 4 us |
| `/mnt/ft/go.r.32.font` | 43 | 230 | **242** | 7 us |

A bitmap font can only ever produce two, and does: exactly 2, not "about
2". The rest is antialiasing, at sizes chosen at open time rather than at
whatever size somebody once rasterised a `.font` to. Opening cost 0 ms at
16 px and 2 ms at 32 px, once. (Those draw times were 17 and 50 us when
this survey was written; section 2 is why they are not any more.)

`aadrawtest` prints that table, so it is re-measured rather than
remembered. Counting the levels needed one care: taken from the image the
timing loop leaves behind, the count is wrong — 2000 draws of the same
string over itself blend every partly-covered pixel toward the ink until
the face's own greys are gone, which reported **23** where a single clean
draw reports **185**. It counts a clean draw.

**Tk renders such a font, antialiased.** Measured through the harness in
section 0, a `label` drawn into an offscreen pane puts **185** distinct
values on the page through `/mnt/ft/go.r.16.font`, against **3** for
`/fonts/lucidasans/unicode.8.font` (the pane's background, the label's
white, and black). That 185 is `tkofftest` scanning a whole 900x700 pane
and `aadrawtest` scanning a tight box around one string, by different
code, arriving at the same number. The string's metrics are the face's
too. Both are checks, so they stay true or fail.

**Nothing in the tree used any of it, and that is what changed.** When
this survey was written there was no `fonts/ttf` directory, no startup
path ran `ttffs`, and no font path in `appl/wm/`, `appl/lib/tkclient.b` or
`appl/lib/titlebar.b` pointed at `/mnt/ft`; the numbers above were taken
with a host font copied in for the experiment and then deleted. The tree
now ships the faces and starts the server — see section 3 — so a clean
checkout reproduces this table by running `aadrawtest`.

The defaults are still 6-to-8 pixel bitmap faces where a program names one
explicitly: `/fonts/lucidasans/unicode.8.font` and its siblings, five
uses, plus `/fonts/pelm/*`. There is no `fontsrv` in this tree — `ttffs`
is the only mechanism, and it is already the whole pipeline.

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

So the toolkit is safe and the applications were the presumed risk: the
~60 programs in `appl/wm/` and `appl/lib/titlebar.b`, which pack by
computed pixel geometry and draw directly.

### That risk was measured, and for the Tk programs it is small

`tklayout(2)` reports widgets that did not get the room they asked for.
It runs from **`tkclient->onscreen`**, guarded by `$tklayout`, so the
check goes through the entry point every real program already passes
rather than through a reconstruction of it — the rule the previous
session's three blind checks earned.

**Every check reports how many widgets it looked at**, whether or not it
found anything. Without that, a program that never reaches `onscreen` —
because it failed, or waits for input before building its window — is
indistinguishable from one whose layout is fine, and a sweep cannot tell
"clean" from "never ran". That line is not decoration; see below.

Swept over 21 `appl/wm` programs that open a window and settle
(`about calendar clock colors date dir edit keyboard logwindow man memory
reversi sh smenu snake stopwatch sweeper task tetris toolbar view`) on a
900x700 screen:

| default font | reached | widgets | reports |
| --- | --- | --- | --- |
| the tree's bitmap `/fonts/pelm/unicode.8.font` | 19 of 21 | 433 | **0** |
| `/mnt/ft/go.r.20.font` | 19 of 21 | 433 | **0** |

The two that never reach the check are `clock` and `smenu`, which use
`wmclient` directly and draw their own contents rather than packing
widgets — outside what this can see, by construction rather than by
accident.

Per-program, the widget counts are what make the zero meaningful:
`sweeper` 122, `keyboard` 74, `calendar` 28, `stopwatch` 22, `reversi`
21, `edit` 19, and so on down to `toolbar` 4.

**That the two rows are identical is the point, and needed its own
proof** — two passes that quietly used the same font would also produce
identical rows. They did not: a plain `label` with no `-font` measures
`118x14` under the bitmap default and `151x27` under
`/mnt/ft/go.r.20.font`, and no run in the second pass printed
`tk: font not found`. So 19 programs and 433 widgets were laid out in a
face whose text is nearly twice as tall, and not one widget lost room.

### One program reports, and it turns out not to be broken

A second sweep took the programs the first deliberately left out — the
ones with hand-built geometry: `sam samtk brutus pinboard unibrowse vt
wish deb develop ftree filename mand polyhedra prof dmview rt c4 bounce
coffee pen`. **`wm/sam` is short of room at `go.r.20` on a 900x700
screen:**

```
.w.t got 884x218 but needs 960x216
.w   got 898x218 but needs 976x218
```

It is clean at the tree's bitmap font on the same screen, so this is the
font and not the screen: `sam`'s text pane is `text .w.t -width 80w`,
sized in characters, and at a face nearly twice as tall eighty columns no
longer fit across a 900-pixel display.

**But that is `sam` behaving correctly, not breaking.** `samtk.b` reads
`.w.t cget actwidth` and `actheight` *after* `tkclient->onscreen`, so it
computes from the size it was given rather than the size it asked for.
It shows about seventy-two columns instead of eighty, which is what a
text editor on a screen that narrow ought to do. Nothing was changed.

This is the limitation that `tklayout(2)`'s own BUGS section names — a
window clamped by the screen rather than by its own geometry reports the
same way as one whose layout is wrong — and it is worth having hit it
once, because the report is real, the reading of it was not. The checker
answers "did this widget get what it asked for", which is a strictly
weaker question than "is this laid out correctly", and the gap between
the two has to be closed by reading the program.

That finding took three attempts to state honestly. The first run of the
whole sweep was believed, then contradicted by a rerun showing zero — and
the difference was not the layout but a line further up the output:
`tk: font not found: /mnt/ft/go.r.20.font`. The run that reported nothing
had fallen back to a bitmap face and measured the wrong thing entirely.
**A layout result is only about the font that was actually in force, and
the only way to know which that was is to read the whole output, not the
`tklayout` lines.**

`wm/unibrowse` reported thirteen problems that were all false, and fixing
that is its own note below.

**So the answer to the question section 3 opened with:** layout was the
remaining objection to adopting a scalable font, and for the Tk programs
it does not materialise. Across 41 programs swept at two fonts, not one
has a layout that breaks; the single report is a text editor asking for
eighty columns on a screen too narrow for them at that size, and
adapting. `libtk` sizes each widget from its font and `pack` gives each
the room it asks for, which between them do the work.

What is untouched is the programs that draw their own text, which is a
different exercise, and the network-facing ones that will not come up
unattended.

### The font server could lose a race, and does not now

`wm`'s `startfonts()` waited for `/mnt/ft/index` to be *openable*. That
succeeds the moment the server is mounted, but the faces are only parsed
and indexed on the first *read*, so there was a window in which `-f`
named a font that could not yet be opened and `libtk` quietly fell back —
which is exactly the `tk: font not found` above. Seen once in about
thirty runs, under heavy load. It now waits for a readable index, which
is what the wait was always supposed to mean. Cold, that costs 3.1 s
before the first window appears, against the 5 s the wait allows; warm,
nothing.

**The positive control is the important half.** Zero reports is also what
a checker that has gone blind produces. The same sweep on a 260x200
screen at 28 pixels — where things *must* be clipped — gives 16 reports
naming widgets and numbers, down to `wm/task`'s `.b.kill got 2x41 but
needs 50x39`, a button squeezed until its label is gone.

**An earlier version of this section reported a sweep that had not
happened.** It claimed 21 programs at three fonts, all zero. In `zsh`,
`for p in $PROGS` over a scalar does not word-split, so every run
launched `wm/wm wm/about calendar clock ...` — one program, twenty
arguments — and only `about` was ever tested. Nothing in the output said
so, because a program that is never started reports nothing, exactly like
a program with a clean layout. The widget counts above exist so that
cannot happen twice; they are what exposed it.

Three ways to detect a broken layout were tried and two of them cannot
work here, which is worth writing down so nobody builds on them:

- **Siblings overlapping** almost cannot happen: this Tk has only `pack`
  and `grid`, no `place`, and both hand out disjoint space. Kept, never
  seen to fire.
- **A widget outside the pane** cannot happen at all. Tk *clips* to the
  room available, so a label needing 502 pixels in a 200-pixel window
  reports itself as 200 wide. A checker built on this would have passed
  everything, always — and my first one was.
- **Asked-for against given** works, because `Tk->Required` is *not*
  clipped. The difference between the two is exactly the text that was
  cut off, per widget, by name.

Two false positives had to be removed first, and both are informative:
a widget created and never packed still reports its border as a rectangle
(`wm/toolbar` makes a `button .b -text {XXX}` solely to ask how tall a
button would be), and `pack .b .l1 -in .f` — which `wm/about` does —
leaves widgets named under the root while laying them out inside `.f`, so
grouping by name reports a frame as overlapping its own contents. Three
`winfo` queries were added to `libtk` to tell the difference: `children`,
`manager` and `master`. See `winfo(9)`.

**What this does not cover** is a program that draws its own text into an
image rather than packing widgets — the games and the temple ports — which
is where the previous session's overlaps actually were. The method for
those (record every text box a screen draws, test it for overlap and for
leaving the pane) still exists only inside the temple ports.

**The switch already exists, and it works.** `emu -f <path>` sets the
default font for every Tk widget in every program — one global,
`tkfont` in `libtk/utils.c`, which every widget's environment inherits.
Pointed at a `ttffs` face, a plain `label` with no `-font` option comes out
antialiased: `tkofftest`'s "a widget's own pixels read back" check goes
from 3 grey levels to **168** under `emu -f /mnt/ft/go-mono.r.13.font`,
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
titlebar. That is a pre-existing bug a bigger font merely makes
visible. `minsize` takes the bar's own height now, and `tkofftest` asserts
it at two fonts — the check fails at both without the fix.

**Correcting an earlier note in this document:** it said `wmclient.b`'s
guards clamping a negative content height were "the symptom being patched"
by the same bug. They are not. Those guards take the titlebar height from
`tk->rect(w.titlebar, ".", Border|Required)` — Tk's own required size —
not from `minsize`, and they fire for any caller that reshapes a window to
a rect smaller than border plus titlebar, which is reachable however
`minsize` behaves. They guard programmatic reshapes; `minsize` bounds user
drags. Fixing one did not make the other dead code.

That is one bug in the first piece of shared UI examined, which is the
shape of the risk section 3 is about. The rest of `appl/wm` has not been
swept.

**The default reaches real windows, not just this test's own — checked.**
`tkofftest` builds its toplevels with `tk->toplevel`; every actual program
builds one with `tkclient->toplevel`, which connects to a window manager
and puts a titlebar on before it gets to a widget. If anything along that
path named a font of its own, `-f` would set the default for a bare
toplevel and miss every real window. Nothing does — there is no `-font` in
`tkclient.b`, `wmlib.b`, `titlebar.b` or `wm.b` — and `tkofftest` now
asserts it dynamically: a label built through `tkclient->toplevel` reports
the same `cget -font` as one built bare, and when that default is a served
face the window reads back **199 grey levels** where the bitmap default
gives 3. `wm/wm wm/logon` itself comes up under `-f` with nothing on
stderr; the control is a deliberately wrong `-f`, which prints
`tk: font not found:` from `libtk/utils.c`.

### The face this tree ships: the Go fonts

The tree now vendors a face, the way `lib/tls/` vendors a frozen Mozilla CA
bundle. **The Go fonts** — `fonts/ttf/go*.ttf`, two families (`go`
proportional and `go-mono`) in all four styles.

The reason to prefer them here over DejaVu, which this document previously
proposed, is not licensing alone. They were drawn by **Bigelow & Holmes**,
who drew the Lucida faces Inferno has shipped in `fonts/lucida`,
`fonts/lucidasans` and `fonts/lucm` since the beginning — so adopting them
is a continuation of the tree's own typography rather than a substitution
of someone else's. Unlike those, they are under a three-clause BSD licence
instead of the restrictions in `fonts/LICENCE`, which forbids adaptation
and constrains redistribution. A default font has to be one nobody
downstream has to think about.

### Getting them served, without asking anyone to remember anything

The chain is: `ttffs` must be serving before the first Tk toplevel exists,
because `-f` names a path under its mount. Nothing arranges that by
itself, so:

- **`wm/wm` starts it**, in `startfonts()`, immediately before it builds
  its own first toplevel — guarded on there being faces to serve, `ttffs`
  being built, and nobody already serving `/mnt/ft`, and quiet about each.
  The window system is the right owner: every graphical session goes
  through it, its lifetime is the session's, and it gets there before any
  widget exists.
- `lib/sh/fonts` does the same by hand, for a session with no window
  system.

Which reduces the whole adoption to one flag:

```
emu -f /mnt/ft/go-mono.r.13.font
; wm/wm wm/logon
```

**The obvious place was `/lib/sh/profile`, and it was wrong.** `emuinit`
runs `sh -l`, so the profile is on the path of every ordinary session and
a shell makes no windows — the ordering looks right by construction. But a
Styx server's loop never returns and emu does not exit while a process is
running, so putting the server there stopped emu from ever exiting: a
batch `emu -l script` that used to finish in **0.079 s** ran until it was
killed. That is every scripted and CI invocation in the tree. The same
trap bit `tkofftest` and `aadrawtest`, which start a server themselves
when they find faces to serve; both unmount what they started. Shipping
actual `.ttf` files is what exposed all three — with an empty `fonts/ttf`
none of that code ever ran.

Verified end to end, with no `-l` at all so that only `wm/wm` could have
mounted anything: `emu -f /mnt/ft/go-mono.r.13.font /dis/sh.dis` running
`wm/wm wm/sh` comes up with nothing on stderr, where a deliberately wrong
`-f` prints `tk: font not found:`. And `tkofftest`'s real-window check
reports `/mnt/ft/go-mono.r.13.font` as the inherited default with **199**
grey levels on the page.

Two smaller things fell out of shipping actual `.ttf` files, both fixed:

- `ttffs` warned once per face on every cold start, because a missing
  glyph-range cache went through the same `xwarn` path as a corrupt one.
  A cold cache is the normal first run. It is silent now; a stale or
  malformed cache still warns. The caches themselves are gitignored —
  they are derived, and `readranges` rejects one no newer than its `.ttf`,
  which a checkout's mtimes cannot be relied on to satisfy. Generating
  all eight costs **2.8 s**, once per checkout, on the first read of
  `/mnt/ft/index` — not at mount, which is why `startfonts()`'s wait for
  the mount returns long before it and the cost lands on the first font
  open instead, where it blocks rather than fails.
- `tkofftest` started `ttffs` when it found faces to serve and then never
  exited, because a Styx server's loop does not return and emu waits for
  it. It unmounts what it started.

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
