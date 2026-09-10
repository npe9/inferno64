# What is left of the user interface, and in what order

`doc/ui-modernization-plan.md` is the survey and the record of what was
done. This is the forward half: the gaps that remain, sized, ordered, and
each with the evidence that says it is real and the test that would say it
is finished.

Everything here was checked against the tree rather than remembered.

## 0. First: how much of this reaches native Inferno

The work so far was done and measured under `emu` on macOS. Native
Inferno — the `os/` kernels — shares some of it and none of the rest, and
which is which is not obvious, so it is worth writing down before
planning anything on top.

A native kernel's libraries come from the `lib` section of its config.
`os/pc64/pc64` has:

```
lib
	aml fis #interp keyring memlayer memdraw draw tk sec mp math kern ip
```

so `memdraw` and `tk` are linked natively, and there is no `freetype`.
Eight configs list `tk`: `fads`, `ipaq1110`, `js`, `pc`, `pc4e`,
`pcdisk`, `pc64`, `rpcg`.

| what | native |
| --- | --- |
| `chardrawaa` — antialiased blit, `libmemdraw/draw.c` | **carries.** `memdraw` is linked |
| `winfo children`/`manager`/`master`, `libtk/ebind.c` | **carries.** `tk` is linked |
| chrome scaling, `appl/lib/titlebar.b` | **carries.** Dis |
| `tklayout(2)`, `tkofftest(1)`, the sweeps | **carries.** Dis |
| the Go fonts and `ttffs(4)` | **no.** No config links `freetype` |
| `emu -f` — the whole font lever | **no.** `emu/port/main.c` |
| widget announcements to `voice(3)` | links now; silent until a native voice device — see below |
| HiDPI | not applicable; a native framebuffer *is* the physical resolution |
| keyboard and IME | **no.** `emu/MacOSX/win-cocoa.m` is one backend of several |

So the half of this work that is portable C and Dis carries for free, and
the half that reaches the machine — fonts, the font flag, speech, input —
stops at `emu`. That is the shape of the remaining work, and it is not an
accident: the parts that carry are the parts that only ever touched
`libtk`, `libmemdraw` and Dis.

### The one thing to check before anything else

`libtk` references two symbols that only `emu` defines:

```
libtk/ebind.c:8    extern void voiceannounce(char*);      /* voice(3) */
libtk/textw.c:7    extern void voiceannouncetext(char*);  /* voice(3) */
```

`voiceannounce` and `voiceannouncetext` are defined in
`emu/port/devvoice.c` and nowhere else in the tree — there is no
`devvoice` outside `emu/`. `ebind.$O` is in `libtk/mkfile`'s object list,
and eight kernel configs link `tk`.

**Established, and it was broken.** Compiling the current `ebind.c` with
`kencc` for native amd64 and asking `inm -u` what it needs:

```
U voiceannounce
```

and `textw.c` the same for `voiceannouncetext`. It has been that way
since the announcements went in on 2026-08-24 — three days *after*
`Inferno/amd64/lib/libtk.a` was last built, which is why nothing had
noticed. The stale archive was also why a first look at it found no such
symbol and looked reassuring.

**Fixed** by `libtk/voicedefault.c`: the library carries the default for
its own dependency. It is a file of its own on purpose — a linker takes a
member out of an archive only to resolve a symbol that is still
undefined, so a configuration with a real voice device (emu lists
`voice`; a native kernel one day might) defines these first and never
pulls it, and a configuration without one links and is silent.

That makes it the portable default rather than a workaround: the same
mechanism that makes it work now steps out of the way when a native voice
device arrives.

Verified both directions. Natively, `voicedefault.o` compiled with kencc
defines both symbols (`T voiceannounce`) in the same archive that
references them. Hosted, `tkofftest(1)`'s eight announcement checks still
pass — which is the control that matters, because if the silent default
were being pulled instead of `devvoice.o` they would all report silence.

**Not claimed:** a native kernel has not been linked here. `os/` belongs
to someone else and building it is not this work's business. What is
shown is that the symbols are now supplied within `libtk` rather than
missing from it.

**The better end state is still a native `voice` device.**
`emu/port/devvoice.c` is 400 lines whose hard part is the ring and the
announce policy, not the host: the formant synthesiser is `voice(3)`'s
own and portable, and only the PCM sink is host-specific. A native kernel
with a sound driver could serve the same `/dev/voice`, and
`speak /dev/voice/screen &` would be the screen reader on real hardware —
at which point every announcement already written lights up on the
machine instead of only under emulation.

## 1. Reviewing what was said — **done**

`/dev/voice/history`: everything that has been announced, newest first,
one to a line. Reading does not consume it and a focus change does not
clear it, which is what makes it the file for asking what was just said —
something a person may need to do more than once and cannot do with
`screen` at all, since reading that takes the announcement away and
`dropoutput()` throws the queued ones out when the focus moves.

The three decisions the plan left open, and the answers:

- **64 announcements.** `screen` holds sixteen because a backlog is worse
  than useless when it is being *spoken*. History is never spoken unless
  asked for, so it can afford to be longer; 64 is 16 KB.
- **Newest first**, because the question is almost always "what did that
  just say?" and the answer should not be at the bottom.
- **Everything that was announced**, at whatever level is in force. The
  buffer is capped, so a chatty shell pushes older entries out — the same
  bargain the ring already makes.

Written by the same `queue()` that fills `screen`, so it holds exactly
what was announced and inherits the same rule that an announcement
identical to the one before is dropped.

`tkofftest(1)` asserts the property that motivated it: after the eight
announcements above have all been consumed by reading `screen`, the
history still holds all eight, in newest-first order, and reading it
twice gives the same thing.

**The control caught a flaw in the check itself**, which is worth
recording. With the history writes disabled the test first *skipped* —
in Limbo an empty string is `nil`, so "the feature is broken" read
identically to "the file is not there". It now opens the file to decide
whether to skip and uses the contents only as the assertion, so a broken
history fails with `0 lines` instead of going quiet.

## 1a. The rest of the accessibility surface — **done**

Not in this plan when it was written, because the plan listed what was
left and this looked finished. It was not: `libtk` announced *where* the
keyboard was and almost nothing about *what* it had arrived at.

| | said before | says now |
| --- | --- | --- |
| checkbutton, radiobutton | `Wrap lines check button` | `... not checked`, and `checked` when it changes |
| scale | `scale` | `scale 40`, and `50` when a key moves it |
| listbox | `list` | `list Inbox`, and `Drafts` when a key walks it |
| entry | `entry` | `entry notes.txt`, unless masked with `-show` |
| menu item | *silence* | `Save as menu item` |
| text cursor | *silence* | the line, or the character when the line did not change |
| window entry | `window` | `Mail Reader window` |

Every one landed with a control demonstrating the previous silence, and
each has a check in `tkofftest(1)`, which went from 13 to 37.

Three things learned that outlast the changes:

- **Ask whether an existing widget's *state* means the right thing before
  reaching for one that merely looks right.** `tknotebook(2)`'s tabs are
  radiobuttons, so they announce themselves for free.
- **A test that reads what the system says out loud is a good test of
  what it displays.** The notebook's first version labelled every tab
  with its own source, because `'` quotes to end of line in this Tk. What
  said so was the speech check.
- **Reading a field aloud is not the same question as reading a password
  aloud.** Refusing every entry to protect three made every field in the
  system unreadable by ear. `-show` marks the three.

### Three layers each said which window it was

`wmclient.b` wrote the title itself, `tkclient.b` wrote the title itself,
and `libtk` was taught to. In `wmclient` the two came out in different
words and a window said its name twice, audibly. In `tkclient` the order
put them the other way round and the words happened to match, so
`voice(3)`'s dedup threw the second away and nothing looked wrong.

**The audible case was the lucky one.** Both are now `libtk`'s, which is
the only layer that knows a window has just been entered and the only one
that also covers a toplevel with no client library under it.

That bug could not have been caught by anything here: `tkofftest(1)`
builds toplevels with `tk->toplevel` and hands them an image of its own,
which is what lets it read pixels back, and that path never goes through
`wmclient`. `voicewmtest(1)` closes it — a real window under a real `wm`,
reading `/dev/voice/history` back. It catches two layers announcing in
*different* words; it cannot catch two announcing the *same* words,
because the dedup already makes that harmless.

**What is left here:** a way to review the screen rather than the
announcements — reading a window's contents without moving the keyboard
— which is a different mechanism again. Nothing announces a scrollbar's
position either, though what it should say is not obvious: paging moves
the view and not the cursor, and inventing a behaviour there would be
guessing.

### And one gap that is not an announcement gap at all

Looking for the next thing to announce turned up something else. **The
`text` widget has no keyboard selection.** Its binding table has
`Left`, `Right`, `Up`, `Down`, `Home`, `End` and the emacs equivalents,
and nothing shifted; selecting is mouse-only, and `brutus` is the only
program that selects at all — from its own code, by adding the `sel` tag.

So a person who cannot use a mouse cannot select text, which is a
usability gap before it is an accessibility one: no copy, no cut, no
replace-a-region.

**It cannot be fixed in `libtk`.** A shifted arrow is not distinguishable
from an arrow by the time Tk sees it. `Shift` in `keyboard.m` is a
*shifter key* — `LShift`, `RShift` arrive as key presses of their own —
and `keyDown` in `win-cocoa.m` drops `modifierFlags` except to swallow
Cmd chords. There is no modifier bit riding on the arrow to bind against.

So this is platform work first: carry the modifier through the key path,
which is the same file and the same function as the `NSTextInputClient`
item in section 2, and a good argument for doing them together.

**And there is room to carry it.** The encoding already has one modifier
bit riding on a key — `APP = Spec|0x200`, which is how the Alt keys
arrive, and the text widget binds `{TkKey|APP|'\t'}` against it. The
payload is eleven bits (`Keyup | (key & 0x7ff)`), named keys stop at
`0x6f`, and **`0x400` is unused** in both `include/keyboard.h` and
`module/keyboard.m`. So a `Shifted` bit is an additive change to a shared
header rather than a redesign, and `{TkKey|Shifted|Left}` becomes a thing
that can be bound.

The widget half is the larger half, and its hard part is not the
binding. `tkttagchange(tk, TkTselid, &first, &last, 1)` already sets a
selection between two indices — that is what the mouse path does. What
keyboard selection needs and the mouse does not is an **anchor that
survives editing**: a `TkTindex` holds pointers to items and lines, and
an edit can free them, so remembering one in a field of `TkText` would
leave a stale pointer to crash on. It wants a mark, which this widget
already moves with the text, the way `insert` is moved. That is the piece
to design first.

## 2. Text input

**What is wrong.** `emu/MacOSX/win-cocoa.m` at two sites:

```
ch = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
```

The first character of the event, and the rest dropped. No input method,
no composition, and Cmd chords swallowed. macOS says so itself: every run
in this session logged `error messaging the mach port for
IMKCFRunLoopWakeUpReliable`.

**Why it matters more than it looks.** This is not a nicety for other
alphabets — it is the difference between the system being usable in a
language and not. Everything else in this plan is about how the interface
looks or reads; this is about whether text can be entered at all.

**Half of it is done.** `deliverchars()` now walks the whole string and
decodes surrogate pairs, so a character above the basic plane arrives as
one rune instead of a lone high surrogate, and an event carrying more
than one character no longer loses everything after the first. The first
character still goes through `convert_key()`, because that is what turns
a keyCode into Return or an arrow; the rest are text and are delivered as
themselves.

**And it is testable now, which it was not.** Nothing in the system can
produce a surrogate pair on demand — a person has to type one, and
writing to `/dev/keyboard` goes in *below* the platform and exercises
none of the decoding. `INFERNO_KEY_TEST` pushes a string through the same
path a key event takes, the same shape as `INFERNO_RESIZE_TEST`, and
`keychartest(1)` reads `/dev/keyboard` and compares rune for rune:
`héllo 😀 世界` is 11 UTF-16 units and 10 runes, and all ten arrive.
With the old one-unit behaviour restored it reports one.

That seam is worth more than the fix, because the rest of this item needs
it.

**What is left.** `NSTextInputClient` on the view, so that a composition
is *shown while it is being made* rather than arriving finished. That is
the half a person actually notices, and it cannot be checked by pushing a
string through a hook: it needs a real input method and a person looking
at a window. Also still there: `keyDown` returns early on any
`NSEventModifierFlagCommand`, so every Cmd chord is swallowed — changing
that risks the menu, and the menu is not testable here either.

**Native:** does not carry. Native keyboards come through the kernel's
own driver, and composition there is a different piece of work with the
same shape. Worth doing hosted first anyway, because the hosted side is
where the OS already has the machinery.

**Done when:** a composition is visible while it is being typed, and a
Cmd chord reaches the application instead of vanishing. Neither can be
shown from a script; both want a person at a keyboard.

## 3. A theme register — **done**

**What is wrong,** counted rather than estimated: `appl/lib/titlebar.b`
has four colours (`#8A9098` inactive, `#3D6A9A` focused, `#D4D0C4`
button, `#2A2A22` glyph) written out fourteen times; `appl/lib/wmclient.b`
has three more as Limbo constants; `appl/wm/sweeper.b` and `appl/wm/vt.b`
have their own. The desktop background `16rC4C0B4FF` is written twice,
`wmclient.b:34` and `wm.b:33` — the duplication a register exists to
remove, already happening.

**`grpalette(2)` is not the mechanism.** It is TempleOS's *sixteen-colour
indexed* file, where a colour is an index into a table a program rewrites
underneath a finished drawing. These are specific RGBA values. Right
shape, wrong table.

**`wmtheme(2)`** holds them: `inactive`, `focused`, `chrome`, `glyph`,
`label`, `desktop`, offering each as a packed RGBA for `draw(2)` and as
`#rrggbb` for `tk(2)`. `titlebar.b`, `wmclient.b` and `wm.b` read it, and
the defaults are exactly the values that were written down before, so
adopting it changed no pixel. The desktop background is now written once
instead of twice.

One thing had to move to make it possible: `title_cfg` was an array
initialiser, and Limbo evaluates those at load time — before `init()` has
run — so the colours could not have come from anywhere but a literal. It
is a function now.

`tkofftest(1)` holds it to both ends: that the register still holds what
was written down before, and that the titlebar *on the page* is the
colour the register says.

**Both checks earned themselves immediately.** Writing the register I
typed `#D4C0C4` for `#D4D0C4` — one digit — and the first check is what
that kind of mistake is for. And the second only proved itself after a
false negative: the control that was meant to break it used `/* */`,
which is not a Limbo comment, so `titlebar.dis` never rebuilt and the
check "passed" against unchanged code. **Filtering the build output is
what hid it** — `mk` had printed the syntax error all along. With a `#`
comment the control fails as it should, naming both colours.

**Native:** carries. Pure Dis.

## 4. HiDPI

**What is wrong.** `emu/MacOSX/win-cocoa.m:4894`:

```
mtl_layer.contentsScale = 1.0;	/* 1 Inferno pixel = 1 point */
```

and `present_softscreen` sizes the drawable in points. On a Retina
display every window is a 1x image the OS scales up.

**Why it is not one line.** Inferno has no notion of display scale. Set
the scale and the framebuffer is backing-resolution, so every UI element
renders at half physical size — the text would be sharp and everything
would be tiny.

**What changed since the survey.** The survey argued this should ride
along with the font pass, because both touch the same ~60 programs and
doing them separately means touching everything twice. That argument is
weaker now: the font pass is done, and it left `tklayout(2)`,
`$tklayout` and the sweep harness behind. A HiDPI pass can *reuse* that
rather than be bundled with it — sweep at scale 2 the way the font work
swept at `go.r.20`.

**Done when:** the sweep reports nothing at scale 2 the way it reports
nothing at `go.r.20` today, and a glyph read back from an offscreen image
has twice the pixels.

**Native:** not applicable, and this is worth being clear about rather
than filing as "portable later". A native framebuffer is already at the
physical resolution; there is no scaling layer to correct. What native
wants instead is for the UI to follow a *measured* size — which is what
the font work did — not a scale factor.

## 5. The widget set — begun

`libtk` has button, canvas, entry, frame, grid, image, label, listbox,
menu, pack, panel, scale, scrollbar and text. Verified absent: notebook,
treeview, combobox, progressbar, spinbox. There is no themed-widget
layer.

**The split that matters:** the cheap half is compositions in Limbo over
the widgets that exist — a notebook is a frame, a row of buttons and
`pack forget`; a progressbar is a canvas rectangle. Only a treeview
really wants C. So this is not one task but a series, and it can start
whenever without blocking anything.

**`tknotebook(2)` is the first**, and it makes the case: a frame of tabs,
a frame per page, `pack forget` for the ones not showing. `tkofftest(1)`
checks what makes it a notebook rather than three frames — that exactly
one page has a geometry manager, that selecting swaps which, and that its
tabs follow the font like everything else.

**Its tabs are radiobuttons, and that is not about appearance.** A
radiobutton is a control with a state, so `libtk` already announces it to
`voice(3)` on arrival and on change — "General radio button selected" —
and a person choosing a tab by ear is told what they chose, without the
module knowing speech exists. Buttons would have been silent. Every new
widget in this series should be asked the same question: is there an
existing widget whose *state* means the right thing, before reaching for
one that merely looks right?

**The announcement caught a bug the eye would have found slower.** The
first version passed `-text 'General`, and in this Tk a `'` quotes to the
*end of the line* — so every tab was labelled with its own source. What
said so was the speech check printing
`'General -variable nbv_nb -value 0 -command {send nbc_nb 0} radio button
selected'`. `tk->quote` is the fix.

What it does not do is *look* like a notebook: the tabs are radiobuttons
in a row. Drawing them as tabs wants a canvas or a themed layer, which is
the expensive half.

**Done when:** each new widget has a `man/9/` page, like the ones there
now, and `tkofftest(1)` packs it at two fonts and finds it grows.

**Native:** carries if written in Limbo; needs the kernel rebuilt if
written in C, which is an argument for the Limbo half first.

## 6. Text quality beyond antialiasing

`man/4/ttffs` BUGS, still true: *"No kerning or subpixel rendering is
supported. Only 8-bit greyscale anti-aliased fonts are served."*

So: no kerning, no shaping (Arabic, Indic), no bidi, and no colour fonts
— no emoji.

**Correcting this document:** it said the cheapest step was kerning,
because "FreeType already has the pairs and `ttffs` simply does not ask."
That is wrong, and wrong in a way worth keeping visible. `ttffs` serves
*subfonts*, and a subfont's advance model is one byte per glyph —
`include/draw.h`:

```
struct Fontchar {
	...
	uchar	width;		/* width of baseline */
};
	p.x += i->width;
```

Kerning is a property of a *pair*. There is nowhere in the font file to
put it and nothing in the drawing path that would read it, so this is not
"ask FreeType for one more number": it is a change to the font format and
to every consumer of it, or a kerning table carried beside the font and
consulted at draw time. Either is a real piece of work, not a cheap one.
The same is true of shaping, which needs to reorder and substitute
glyphs, and of colour fonts, which need more than the 8-bit coverage
`ttffs` emits.

**Native:** blocked on the same thing as the fonts — no config links
`freetype`.

## 7. Coverage this work did not reach

- **24 of the 65 `appl/wm` programs** are unswept: the network-facing
  ones that will not come up unattended (`mail`, `readmail`, `telnet`,
  `remotelogon`, `sendmail`, `fedi`) and the ones that draw their own
  text rather than packing widgets, which `tklayout(2)` cannot see by
  construction.
- **Programs that draw their own text** — the games, the `temple` ports,
  `acme` and `sam` — share none of the toolkit's guarantees. The method
  for checking those exists only inside the temple ports and was never
  made general.
- **Every backend claim here is about `emu/MacOSX/win-cocoa.m`.** Linux
  and Plan 9 are unexamined.
- **On-screen appearance.** The harness proves what Tk *drew*, never what
  the display *shows*: `readpixels` returns `00 00 00` for anything on
  the screen. Everything in both documents rests on that distinction.

## The order, and why

1. ~~Check the `voiceannounce` link~~ — **done.** It was broken; `libtk`
   carries its own default now.
2. ~~Review buffer~~ — **done.** `/dev/voice/history`, and with it the
   rest of the announcement surface: control state, menus, the text
   cursor, and one window announcement instead of three.
3. **Text input** — half done (characters arrive whole, and there is a
   hook that proves it). The rest is `NSTextInputClient`, which needs a
   person at a keyboard to verify.
4. ~~Theme register~~ — **done.** `wmtheme(2)`.
5. **HiDPI** — the most visible, the largest, now able to reuse the
   sweep.
6. **Widgets and text quality** — open-ended, start whenever, no
   dependencies.

The first four are each a few days at most. The fifth is the one that
would change what the system looks like to someone who has never used it.
