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

**And removing `tkclient`'s copy fixed something else.** The documented
startup — `emu /dis/wm/wm.dis wm/logon` — printed this on every run:

```
tkclient: tk error !bad window path .Wm_t.title on '.Wm_t.title cget -text'
```

It had been noted three times in passing as pre-existing and unrelated,
which it was. `wm/logon` asks for a `Plain` window, so there is no
titlebar and no `.Wm_t.title`, and `announce()` read that widget's text
on every focus without checking whether it existed. Establishing the
connection took a control rather than an inference: putting the call back
brings the message back, taking it away removes it.

A redundant announcement was also the only thing complaining on the path
a person follows to log in.

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
menu, pack, panel, scale, scrollbar and text. Still absent: treeview and
progressbar. Notebook is `tknotebook(2)` and **spinbox is now
`tkspinbox(2)`**, both Limbo compositions.

**Correction: combobox was on that list and should not have been.**
`choicebutton(9)` is one — it shows one of a `-values` list, opens a menu
of them when clicked, and writes the chosen index to a `-variable`. It
was missed because it is not called a combobox. That is the "look for an
existing mechanism before building one" rule catching a would-be
reimplementation, and it is worth noting *how* it was caught: not by
reading the widget list again, but by going to write the thing and
checking first.

**What was genuinely missing was on the accessibility side, and the
widget's own shape hid it.** A choicebutton has no label of its own —
what it displays *is* the chosen value — so arriving at one always said
the right thing, and every announcement test would have passed. Changing
it said *nothing*: `tkannouncestate()` had no case for it, and neither
commit path called `tkannouncechange()`. So a person choosing from a
combobox by ear got silence at the only moment that mattered. Both are
fixed and `tkofftest(1)` checks both, with the change check confirmed to
fail (`''`) when the announcement is taken back out.

There is no themed-widget layer.

**The split that matters:** the cheap half is compositions in Limbo over
the widgets that exist — a notebook is a frame, a row of buttons and
`pack forget`; a progressbar is a canvas rectangle. Only a treeview
really wants C. So this is not one task but a series, and it can start
whenever without blocking anything.

**`tkspinbox(2)` is the second**, and it took the notebook's lesson
literally: the value lives in an `entry`, so `libtk` announces it on
arrival for free — `tkannouncestate()` already has a case for `TKentry` —
where a number drawn on a canvas would have been silent. What an entry
does *not* do is say the value changed when a **button** moved it, since
nothing was typed into it, so `event()` writes the new number to
`/dev/voice/screen` itself. That is precisely the shape of the
`choicebutton` bug found the same afternoon — right on arrival, silent on
change — which is why the two are checked separately rather than
together.

**An application has to pump it**, because a Tk command is a string and
this Tk cannot add one to a number. The buttons report on a channel and
the application's own event loop hands what arrives to `event()`. A
process inside the module reading its own channel would put a second
writer on the same toplevel as the application, which is not a thing to
find out by trying.

**Progressbar is deliberately not next.** It has no state a person acts
on, so it announces nothing and inherits nothing; it is a canvas
rectangle and the least valuable line of code in this section. Treeview
still wants C.

**`tknotebook(2)` was the first**, and it makes the case: a frame of tabs,
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

~~What it does not do is *look* like a notebook: the tabs are radiobuttons
in a row.~~ They now carry `-indicatoron 0`, which drops the circle and
leaves a slab that the flat style fills in the accent when chosen — a
**segmented control**, which is what a current system draws for this job.
It is still a radiobutton underneath, so `voice(3)` announcement is
unchanged; the circle was never what made that work. A tab *shape* — a
page hanging off the selected one — still wants a canvas. Drawing them as tabs wants a canvas or a themed layer, which is
the expensive half.

**Done when:** each new widget has a `man/9/` page, like the ones there
now, and `tkofftest(1)` packs it at two fonts and finds it grows.

**Native:** carries if written in Limbo; needs the kernel rebuilt if
written in C, which is an argument for the Limbo half first.

## 5a. The widgets are gross

Separate from *which* widgets exist, which is section 5: the ones that do
exist look like 1997, and that is a decision nobody has revisited rather
than a constraint.

**What actually makes them look that way**, in the order it shows:

- ~~**Hard 3D bevels everywhere.**~~ **Done — `style(9)`.** `tkdrawrelief`
  in `libtk/utils.c` painted a one-pixel light edge and a one-pixel dark
  edge, and `raised` and `sunken` were the only shapes a widget had.
  There is now a per-toplevel `style classic|flat`; flat draws one
  restrained outline instead of the chisel, and classic stays the
  default, so the existing look is not taken away from anyone.

  **The pressed state needed no work at all, which was the surprise.**
  The plan above assumed a fill change would have to be *added*. It was
  already there: `buton.c` sets `bgnd = TkCactivebgnd` for a pressed
  button and `TkCselect` for a chosen indicator-less checkbutton, and the
  fill is drawn from `bgnd`. The relief was reinforcing a state that the
  fill already carried, so collapsing `raised` and `sunken` loses nothing
  — which is what makes the flat style one branch rather than a second
  set of shapes. `tkofftest(1)` checks that in **both** styles, because a
  flat look that quietly stopped saying which option is chosen is exactly
  the regression a border-pixel count would not notice.

  **Two instrument failures worth keeping, both of the same kind.** The
  border count was first taken over a *button*, where the glyphs dominate
  and both styles read 3 distinct values — a metric with no power to see
  the change. A text-free `frame` reads 2 against 3. Then the checkbutton
  state was measured with `ink()`, which counts pixels that are not the
  commonest value: a fill that merely *changes colour* leaves that count
  exactly where it was, and it read 366 either way in both styles.
  `dominant()` reads `#3D6A9A` chosen against `#F5F0D8` not. Neither
  metric was wrong about pixels; both were wrong about the question.

  **And the repaint had to be asked for properly.** `tkdirty()` only
  *propagates* dirtiness — to masters, and to views under a transparent
  widget — and returns at once unless the widget's own dirty rectangle is
  already set. Setting the style and calling `tkdirty()` on every widget
  therefore repainted almost nothing: 2 widgets took the flat branch and
  the check reported no difference. `tk->dirty = tkrect(tk, 1)` first, as
  `tkbuttonselect()` does, is the fix. The failing check said "3 against
  3" throughout, which is the same reading a broken flat style would
  give — so the negative control was run deliberately afterwards
  (`if(0 &&` on the branch): 3 against 3 with it disabled, 2 against 3
  with it back.
- ~~**No spacing discipline.**~~ **Done — `tkspaces[]` in `tk.h`.** The
  padding was per-widget and ad hoc, and worse than "ad hoc": `label.h`
  called 3 pixels `Textpadx` and `textw.c` called 2 pixels the *same
  name*, in the same toolkit, in different files. A label and a text
  widget packed side by side could not line up, and nothing said why.
  They are now one named register with a row per style, named apart
  (`labelpadx`, `textpadx`) so the discrepancy is visible rather than
  accidental, and the flat row makes them agree.

  **The classic row is the old numbers exactly**, and that is checked,
  not asserted: every size `tkofftest(1)` reports — `checkbutton 100x20
  -> 188x32`, `title ends 292, 4 buttons from 820, bar 898x20` — is
  unchanged to the pixel, and `temple/smoketest` still loads 297 of 297.

  **Spacings apply at configure time, not on restyle, and that is a
  decision.** Re-measuring existing widgets works and was implemented:
  the new size request travels up to the master and on to the toplevel,
  which re-fits itself to its contents — one `style` command resized the
  whole window and moved every widget in it (a packed frame went from
  x=408 to x=0). A window that jumps size because its borders were
  restyled is worse than a style whose spacings apply to what is built
  after it, so the re-measure was taken back out and `style(9)` says to
  set the style before building the interface.
- **Square corners** remain. ~~**and one-pixel lines at every size**~~ —
  **the scaled border is done**, as `tkborderwidth()` in `libtk/utils.c`,
  and it is the same fix one layer down as the plan predicted. Under the
  flat style a widget's default border is derived from the font: 1 pixel
  at a 15-pixel font, 2 at 30. Under classic it is the literal number it
  always was, because every existing layout has measured itself against
  that — and `tkofftest(1)` asserts *both*, the growth and the
  non-growth, so the check that protects old layouts is a check and not
  an intention.

  **It is the toplevel's font that decides it, not the widget's**, which
  is not a choice so much as an order of operations: the default border
  is set when the object is made, before `tkparse()` has looked at the
  widget's own `-font`. A `-font` on the button arrives too late to be
  measured, so the test uses two toplevels rather than two buttons. An
  explicit `-borderwidth` is never scaled.

  Corners are what is left, and they want a rounded-rectangle primitive
  that `libtk` does not have.
- **The colours are flat because they were literals.** That part is done
  — `wmtheme(2)` — but nothing yet *uses* it to do anything more than
  reproduce the old palette. A second table is now a small change, and
  the register is the place a lighter, quieter look would come from.
- ~~**No focus ring.**~~ **Done.** The two lines that draw it were
  commented out in `libtk/buton.c` and live, identical, in `label.c` —
  and `entry.c` does the same a line further down. So a label and a text
  field showed their focus and a *button* did not, which is the widget a
  person tabs between. Nothing was saved by leaving it out:
  `tk->highlightwidth` is already 1 for these widgets and `mainr` is
  already inset by it, so the pixel had been reserved and left blank all
  along. A focused button now reads 330 inked pixels against an
  unfocused one's 222.
- ~~**`tknotebook(2)`'s tabs are radiobuttons in a row**~~ — **done**,
  with `-indicatoron 0`: a segmented control, filled in the accent when
  chosen. Composition got there after all, because the style underneath
  changed rather than the widget. Making them look like tabs wants a canvas or
  the themed layer below.

**The order to do it in.** ~~The bevel and the focus ring~~ — both done;
the switch is `style(9)` rather than `wmtheme(2)`, because the choice has
to be made where the border is drawn, in C, and `wmtheme(2)` is Limbo and
holds colours. A Limbo caller says `tk->cmd(top, "style flat")` like any
other Tk command, so nothing had to be plumbed between the two.
~~**Spacing is next**~~ — done, and it *was* mostly a table.
~~Corners and scaled borders are last~~ — scaled borders done; corners
are all that remain of this section, and they need a primitive that is
not there.

**The session-wide setting is done: `$tkstyle=flat`.** `tkclient(2)`
reads it in `toplevel()`, before the titlebar's own widgets exist — which
it has to, since spacings and border widths are read when a widget is
configured. So the whole look can be tried, or put back, across a session
without editing one program. Unset means classic.

**Flat is now the default.** The taste question was put to the user and
came back as "you do it, the goal here is to modernize inferno", which
settles it: a modernization whose modern half is opt-in has not modernized
anything. `TkSflat` is the constant that is zero and a `TkTop` is
allocated zeroed, so the default is decided in one enum and at no
creation site — there is no path that makes a toplevel and forgets.
`$tkstyle=classic` puts a whole session back.

**What flipping it cost, and it is worth knowing.** Five checks in
`tkofftest(1)` failed immediately, every one of them a check that had
silently relied on the default rather than stating a style: the two-tone
bevel's shades, the "a classic border does not scale" control, the
`$tkstyle` test, and the titlebar artwork measurement. That last is the
interesting one — it asserts that scaling the chrome preserves the
proportion of pixels inked, which is true of the *artwork* but stops being
measurable under flat, because a widget's border now scales with the font
too and by a different factor from the bitmap. 44% against 61%. Each of
those now names the style it means, which they should have done all along.

**That consequence is now fixed.** A flat control is about 1.5× the width
of a classic one, so the `wm` toolbar reached its edge sooner. It had no
overflow handling at all: `condenselabel()` wrapped a long title onto four
lines of fifteen characters, which makes a button *taller* and never
narrower, so the bar's width was whatever the titles happened to add up
to and the tasks past the end fell off.

It now shares the bar out — each task gets an equal slice of what is left
after the start menu, clamped to a floor and a ceiling, and its label is
elided to fit. **Equal shares rather than proportional to title length**,
because the point of a taskbar is that a task stays where you last saw
it; giving one window more room for having a long title moves every other
button whenever a title changes.

`elide()` and `measure()` went into `tklayout(2)` rather than staying
private to the toolbar, for a reason that paid off immediately: in the
toolbar they were untestable, and in `tklayout(2)` `tkofftest(1)` swept
budgets from 240px down to 20px and found the contract broken at the
bottom — the ellipsis has a minimum width, so a 20px budget came back
60px wide. `elide()` now never returns anything wider than it was given,
returning the ellipsis alone or nothing at all, because a caller cannot
tell that a result was too wide and one over-wide label costs a taskbar
every task after it.

**Still open in this section:** square corners, which want a
rounded-rectangle primitive `libtk` does not have; and a second colour
row. Note the colour item is not the same shape as the others: widget
colours are established in `tksetenvcolours()` when a `TkEnv` is made,
and unlike sizes they could safely be re-applied at runtime, since colour
does not feed back into layout. But choosing the second palette *is* the
taste decision, so it is left.

**How to know it worked.** `tkofftest(1)` renders offscreen and reads
pixels, so a look can be pinned the way the chrome's artwork is: the
count of distinct values in a button, whether the focused control differs
from an unfocused one at all, whether two widgets in a row share an edge.
None of that says a thing about taste, but it does catch a change that
was meant to be cosmetic and was not.

**Contrast is not taste, and the distinction earned its keep.** An
indicator-less checkbutton drawn in the accent kept the near-black
foreground: **2.80:1**, where WCAG AA asks 4.5:1 for body text. Light text
gives 5.63:1. The same defect reached the notebook's chosen tab, because a
tab is an indicator-less radiobutton — one fault in two places that look
nothing alike. `tkofftest(1)` now computes the ratio from the rendered
pixels and fails below 4.5.

Two things about measuring it. The **raw-byte approximation said 2.38:1
where the real figure is 2.80:1** — WCAG linearises each channel first,
and had the defect been marginal the wrong formula would have decided it
the wrong way. And the check first *reported* "6.-37:1", because Limbo's
`int` on a `real` rounds rather than truncates; the comparison was never
affected, but a check that reports a number nobody can read is a check
nobody will trust.

Classic is left with the defect, deliberately: it is the same two colours,
but classic exists to preserve the look this toolkit has always had and is
asserted unchanged.

**Menus, and a hover nobody could see.** A menu's highlighted row is the
accent under flat, with light text on it — a menu is a list you are
choosing from, and the choice should be obvious. A button's hover keeps a
quiet tint, because a button is not a list and an accent slab on every
rollover is noise.

The control for that change is what found the bigger problem. Reverting
the menu highlight to the old `TkCactivebgnd` reported **1.14:1** against
the menu body — and that number is not about menus. `#E2E2DE` on a
`#F0F0ED` page is the *hover tint for every widget*, and 1.14:1 is no
feedback at all. It had gone unnoticed because nothing tested hover.
`#CECEC6` is 1.39:1 against the page and 1.58:1 against a control's own
white, with ink at 9.98:1 on it.

`tkofftest(1)` now delivers a pointer with `tk->pointer()` — the same
entry the window system uses — and requires the widget under it to
change perceptibly. And it posts a menu and checks the highlighted row,
which needed one trick worth recording: **a posted menu is a separate
window** and asks the window system for a backing image, so offscreen it
has a rectangle and draws nothing. Handing it one with `putimage` under
the no-window-manager id makes popups testable at all; without it the
check read "0 pixels not the background" and looked like a menu that
draws nothing.

**A caution worth writing down.** This is the one item in this document
where "better" is a matter of taste rather than measurement, and where
the person whose taste matters is not the one writing the code. The
existing look is coherent — someone chose "Soft Plan9 Paper" — so the
work is to make it *adjustable* first and prettier second, which is why
the theme register came before this and not after.

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
   dependencies. Making the existing ones less ugly (§ 5a) is the part a
   person notices first, and the theme register is already the place to
   put it.

The first four are each a few days at most. The fifth is the one that
would change what the system looks like to someone who has never used it.

## 8. A GTK4-shaped renderer — begun

Asked how modern systems do GPU-accelerated widgets, the answer is that
almost none of them mean "the GPU draws the button". They mean a
**retained node tree**, rasterisation that is often still CPU, and
composition that is always GPU — with `transform`, `opacity`, `clip`,
corner radius and shadow as *compositor properties*, so animating them
never re-rasterises anything. Core Animation does this with a layer per
view; GTK4/GSK does it with render nodes fed to a Vulkan or OpenGL
renderer; Skia records display lists and rasterises in tiles.

**Where this tree already sat.** CPU rasterisation into a softscreen,
tile-damage upload into one Metal texture, GPU present. That *is* the
Core Animation model — at one-layer-per-screen granularity rather than
one-per-view. So the missing pieces are exactly: a retained display list,
per-widget layers, a glyph atlas, and batching.

**What is done: the node vocabulary and a software renderer**
(`libtk/scene.c`, `render(9)`). Nodes carry *values* — a rectangle, a
radius, an rgba — and never a `draw(2)` Image, because an Image is a
server-side resource belonging to one display and a number is what
another backend can consume. `tkdrawrelief`'s flat border can go either
way, and `tkofftest(1)` requires the two to agree **byte for byte**.

**The software renderer is the oracle, not a stepping stone.** Same
arrangement as `draw3d(2)`, where a software and a device provider are
compared rather than each trusted alone. It earned that immediately: the
first version drew 200 pixels of border in the wrong colour, because
`tkdrawrelief` picks its shade *two different ways* depending on whether
the colour is one of the three backgrounds (a precomputed slot in the
table) or anything else (a computed shade), and the node path used only
the first. For an entry that landed on the background colour, so the
border simply vanished. A visual comparison would have passed it, and
every later backend would have inherited it.

**A near-miss the test also caught about itself.** It first reported 0 of
1,890,000 bytes differing while the `render` command *did not exist* —
`cmdmain` in `libtk/utils.c` is binary-searched and must be sorted, and
`render` had been inserted after `send`. Both snapshots were the same
path, so of course they matched. The check now proves each path was
actually selected before comparing, because a comparison of a thing with
itself is the easiest way for a test like this to be worthless.

**What this does NOT yet buy, stated plainly.** Nothing. The tree is
built and thrown away every repaint, so no diffing, no reuse, and no
animation is cheaper than before. `tkbench(1)` says a thirty-widget
window is 400µs of drawing and 250µs of present — 4% of a frame — so
there was never speed on the table here anyway.

**The order the rest goes in, and why.**

1. **Widget backgrounds become `TkNroundfill`.** This removes
   `TkNborder`'s `out` argument, which only exists because a widget fills
   its whole rectangle before its border is drawn so the corner arrives
   already wrong. Until this is done a scene is not a correct description
   of a frame, just a correct reproduction of one.
2. **Text as `TkNglyphs`, with a glyph atlas.** The single biggest GPU
   text technique, and this tree has the pieces — `chardraw` already
   blends coverage masks — but the Metal sprite cache is explicit that it
   is *"not a packed atlas — one Metal texture per distinct pair"*.
3. **Whole-frame emission**, so a repaint produces one tree rather than
   one per `tkdrawrelief` call. Prerequisite for batching, and bigger than
   it looks — **measured, not guessed**: a `tkgallery(1)` frame draws 43
   widgets and takes **27 scratch surfaces**, so a frame is 28 surfaces
   and a flat node list cannot describe one. `tkdrawslaves1()` walks the
   tree against a single `dst`, but seven of the widget files get a
   scratch from `tkitmp()`, draw into it, and blit out.

   **The good news is that it is sequential.** `tkitmp()` hands out *one
   cached scratch per context* — `ti->i` opaque, `ti->ia` alpha — reused
   whenever it is big enough, so those 27 are 27 reuses of the same image
   and not 27 allocations. There is never more than one scratch live. So
   `TkNlayer` is a *scope* — render these children into a scratch, then
   composite the result at a point — rather than a live offscreen target,
   which is much the easier thing to render and is why this is tractable
   at all. The node is declared in `tk.h` so the numbering does not move.

   **Done as far as one widget.** `TkNlayer` exists and is proved on a
   `frame` — which does *not* need one, and that is why: the result must
   be identical to rendering in place, so an extent or offset error shows
   as a difference rather than as a widget that looks fine. A `button` is
   then the first widget that genuinely needs a layer, and its whole
   interior is nodes in the simple case: fill, text, focus ring (a square
   stroke is `TkNborder` with radius 0), relief, composite.

   `tkreliefnodes()` was split out of `tkdrawrelief()` for that — a widget
   building its own scene needs its border in the *same* tree, not a
   second tree rendered into an image halfway through its own drawing.

   **`entry` is the second, and it went the same way.** Fill, glyph run,
   caret and focus ring inside one `TkNlayer`. The two cases first left
   out — a visible selection and `-show` — are in now, and neither
   needed a new node type: the selection band is the five filled
   rectangles `tktextsdraw()` always drew, and `-show` changes which
   runes the glyph node names, not what kind of node it is. What the
   conversion actually bought was the *sharing*: the band's geometry is
   `tkselrects()` in `utils.c` and the selection's clipping is
   `entrysel()` in `entry.c`, each written once and called by both
   paths, because four boundary cases (a selection starting before the
   first visible rune, ending after the last, or both) written out twice
   is two chances to disagree. The glyph node carries a *string*, so the
   visible slice of the entry's Runes is converted to UTF-8 and the node
   takes its own copy — a `Rune*` into a widget's buffer is not a value
   and the node outlives the call.

   **Each of the three new paths was proved reached before it was
   believed.** The identity check passing says nothing on its own: shift
   the node text one pixel and it must fail (768 bytes), widen the node
   ring by one and it must fail (1032), widen the node caret by three and
   it must fail (126). All three did. That last one also established that
   the caret is *lit* during the comparison — which is why the check now
   drops focus and takes it back before each snapshot: the caret blinks on
   a 500ms repeater that runs with or without a window manager, and a
   toggle landing between the two snapshots would report the clock's
   difference as the renderer's.

   **`listbox` is the third, and the first with no exception.** Everything
   it draws is a filled rectangle, a run of text or a stroked box, so the
   guard is just `tkviascene && tkstyleflat(tk)`.

   That made the *test* the hard part, and the identity check was wrong in
   two ways that a passing run could not show. It focused the entry, so
   `tkhaskeyfocus(.l)` was false and both of the listbox's focus-guarded
   nodes — the active item's box and the widget's ring — were never
   emitted: the control for the active box came back **clean**, which by
   the merged rule means the check never reached the code. It now takes
   **two** snapshot pairs, one with the entry focused and one with the
   listbox, because only one widget can hold the keyboard and both have
   nodes that depend on having it. And the listbox was three short
   unscrolled items, where every way the two paths could diverge — all of
   them clipping questions — is absent; it is now scrolled in both
   directions with an item wider than the widget, so a line starts at a
   negative x and the active box runs past both edges.

   **The fourth is a `radiobutton`, and it needed the vocabulary to
   grow.** Its indicator is a ring with a dot in it — the one shape in
   the flat style that is not a rectangle — so `TkNellipse` and
   `TkNellipsefill` came first. They take a centre and two radii rather
   than a bounding rectangle, because a rectangle cannot say whether a
   circle of radius *r* is *2r* or *2r+1* across, and they are numbered
   after the six declared-and-unimplemented types rather than beside
   `TkNroundfill`, because a node type's number must not move once a
   backend has seen it. The same node is what the flat scale's knob will
   need.

   Both radiobutton states are in the check, and both controls fail as
   they must — the ring by 912 bytes, the dot by 96. That second one is
   also what proves the widget is *chosen*: the dot is emitted only when
   it is, so a clean control there would have meant the variable never
   took rather than that the node matched.

   **The fifth is a `scale`, in both orientations.** A flat scale is
   filled rectangles, two runs of text and the two circles of its knob, so
   it went the way the radiobutton did. Its label, value and tick marks
   are drawn only when asked for, so the check asks for all three; the
   band behind the slider is drawn only while the slider is under the
   pointer, which the widget learns from its own `tkScaleMotion`
   command, so the check sends it one for each scale and fails if
   `identify` does not then say `slider`. Both scales take their own
   focused snapshot pair, since the ring is emitted by the same code for
   either orientation and only a focused widget draws it.

   Nine controls, each a perturbation of the scene path alone, fail on
   the committed code: label 2664 bytes of 7560000, value 1296, tick
   marks 432, knob rim 696, knob centre 528, track 2832, fill 1968,
   active band 1296, focus ring 2382. The first round of those controls
   came back clean for five of them, and the fault was the controls: they
   shifted an *argument*, and so moved the direct drawing as well as the
   nodes. A perturbation has to be on the side being tested. The tick
   interval was 0.25 on a range of 100 as well, which is 400 marks in 160
   pixels drawn onto the same few columns; it is now 25.

   **The sixth is a `scrollbar`, and it needed one more node.** Its flat
   arrows are solid triangles, the last shape in the flat style that is
   neither a rectangle nor an ellipse, so `TkNpolyfill` came first: a
   filled polygon whose points are copied into the scene as a glyph
   node's string is, always filled by the nonzero rule because every
   caller uses it. The check adds a horizontal scrollbar with its first
   arrow under the pointer and a vertical one with its slider under it,
   so that between them both arrow colours, both capsule colours and
   both active bands are drawn. One of them is sunken, because a
   scrollbar's relief is flat by default and a flat relief draws no
   border at all: with both left alone, perturbing the border node
   changed nothing, which says the control never reached the code.

   Six scene-only controls then fail: arrow band 84 bytes of 7560000
   (small because the arrow glyph is painted over the same triangle, so
   only a sliver of the shifted band shows), arrow glyph 840, slider
   band 420, capsule body 3948, capsule ends 540, border 5184. A
   *pressed* part is the same shape in the accent colour and is not
   compared, because pressing starts autorepeat and runs the
   scrollbar's command.

   **What is left is the exceptions.** Seven widgets have a node path
   for their ordinary flat case, the seventh being the `label` — the
   widget there are most of, and the one that brings `menubutton` and
   `choicebutton` with it, since one draw method serves all three. It
   had only its *text* as a node before, rendered into a scratch, which
   under the walk meant every label ended a run: asking `tkitmp` for the
   scratch is exactly what says a widget is about to paint into the
   window. Converting it removed a flush per label and took the pane from
   6 trees to 5.

   Four controls on its node path, all failing: text 5910 bytes of
   9450000, focus ring 480, relief 1740, fill 23535. The fill is the
   interesting one. Shifting it *passes*, because that node paints the
   same colour the layer is already filled with — it mirrors a
   redundant draw the direct path has always done — so the control that
   says it is reached has to change its colour instead of its position.
   Reaching those three at all needed the pane's menubutton to be
   `-justify left`, because a menubutton defaults to centre and the node
   path is only taken by the run that reduces to one `string()`, and
   `-state active`, because the fill is drawn only for a widget the
   pointer is on and there is no pointer here.

   **The eighth is a `checkbutton`, and it needed the last node.** Its
   tick is a stroked B-spline, so `TkNspline` came first — points owned
   by the scene as `TkNpolyfill`'s are, `width` the thickness, `radius`
   the end style, the same at both ends because that is what every
   caller asks. Its box is a filled rectangle when on and a stroke when
   off, so both states are in the pane. Three controls, all failing:
   filled box 240 bytes, empty box 420, tick 195. (The denominator those
   were measured against is not the one a run prints today: the pane has
   grown twice since, and it is `len who * W * H * 3`. Only the numerator
   means anything — a control that fails.)

   **A lesson that cost real coverage.** Adding those widgets pushed
   both scrollbars off the bottom of the 900×700 pane — and a widget
   that does not fit is not drawn by *either* path, so it leaves the
   comparison without failing it. The identity check went on passing
   while the scrollbar node path was compared by nothing. The pane is
   900×1000 now, the test asserts that every widget in it has a positive
   size and lies inside it, and a scrollbar control was re-run to show
   the coverage is back (1050 bytes). The assertion itself needed a
   second try: a widget that does not fit is not pushed *outside*, the
   packer hands it a negative size, so comparing only x plus width
   against the pane passed while the scrollbars were 886 by −14.

   Still drawn through a scratch image: a widget whose image came from
   a file *descriptor*, which has no path for a texture node to name.
   A `menu`, a `text` and a `canvas` no longer paint directly — see
   below — and a `panel` never will.

   **A `panel` is out on principle, not pending.** Its image is a live
   `Image` a Limbo program writes through `putimage`, so there is no
   file for a node to name, and a node that held the `Image` itself
   would break the one rule the vocabulary keeps — which is also the
   rule that would let a tree outlive its repaint, since the program
   may have redrawn that image in the meantime. The `tkwalkflush()` at
   the top of `tkdrawpanel()` is load-bearing and stays. A `canvas`
   has the same problem per item rather than per widget: a stipple and
   a pen are live images too, so it is the *last* of these to look at
   and may end up partly excluded for the same reason. That guess was
   right, and it is recorded below: a canvas is converted, and a
   stipple draws. `text` is the
   honest middle — glyph runs, and `TkNglyphs` already exists.

   **A `menu` is nodes, and the walk runs through it.** This was much
   smaller than "a direct painter" suggested, because a menu's items
   are `TkLabel`s and a label has been nodes since `f32a759e`. The only
   things a menu painted itself were the slab behind each item and its
   own border, and both had a node already — `tkscenecolour()` and
   `tkreliefnodes()`. A menu sits in its own posted window, so it joins
   the walk on that window's image and the run structure did not
   change at all: the pane went from 40 widgets to 41 in the same 8
   trees.

   The slab needed a second look. Perturbing its *position* changed no
   pixel, because an item's slab is the background colour unless the
   pointer is on it — it was drawn to get full-width highlighting, and
   with nothing highlighted it is invisible by construction. The pane
   now activates an item, and the accent it gets is what the control
   bites on: dropping it from the node path alone fails by 81018
   bytes, and the border control by 1944.

   **A `text` is nodes, and it needed `TkNclip` first.** A text widget
   narrows the window's clip around its own inside and draws its lines
   through it, so it could not be converted until a clip was something
   a tree could carry. It is eight things, each with a control that
   fails: the glyph run (25020 bytes), a tag's background (59670), a
   tag's relief, which is the classic two-tone bevel and now has a node
   form beside `tkbevel` (20088), the widget's own border (4392), the
   clip itself (50148), the underline (13770), the overstrike (10854)
   and the caret (9). The caret had to be a node rather than be left
   alone: it is drawn last so that no item overwrites it, and a caret
   going straight to the window while a tree was pending would be
   covered by that tree.

   **A held `TkScene*` is a pointer to freed memory, and that was a
   real bug in the committed menu.** `tkwalkflush()` renders the
   pending tree and calls `tkscenefree()` on it, so the pointer
   `tkwalkjoin()` returned is only good until the next thing that
   paints into the window. `drawmenu()` took one before its item loop
   and used it after; a `separator` is an item that paints directly,
   through `frame.c`, so a menu with one in it faulted —
   `sys: bad address addr=0x430000010f`. The pane has a separator now,
   and neither `drawmenu()` nor the text widget holds a tree any more:
   they ask the walk again at each emission, which is two comparisons.

   That left the clip, which cannot be re-asked for, because a span is
   not a point. So the **walk** owns it: `tkwalkclip()` and
   `tkwalkclipend()` record what is open, and a tree begun after a
   flush has the clip re-emitted into it. Clips nest by intersection,
   innermost last, so what reaches the renderer is always one
   rectangle — which is all it supports, and is enough, since a clip
   inside a clip is just a smaller clip.

   **The grid does not use it, and the earlier claim that it did is
   withdrawn.** `e0ad7abb` said a clip node let the walk run through a
   grid, taking the pane from 8 trees to 6, and that was measured on a
   pane where no gridded child ever painted into the window. Gridding a
   `canvas` — which does — makes it fail by 16212 bytes, and the reason
   is a rule that was not stated anywhere: **a tree must not span a
   change to the destination's own clip.** The grid narrows the
   window's clip around its children for the sake of the ones that draw
   directly; the frame's own border lies *outside* that rectangle and
   was already in the tree, so when the child's flush rendered it, it
   was cut away.

   Two ways out were tried and both are recorded because the second
   looked better than it was. Flushing on each side of the narrowing is
   correct and is what the grid already did, so the grid is simply back
   to that. Having the walk remember the clip each tree *began* under
   and restoring it to render seemed to remove the rule entirely — it
   is worse, 124572 bytes, because a widget legitimately drawn under a
   narrower clip later in the same run then renders under the wider
   one. The clip node keeps the customer it was built for, the text
   widget, whose tree genuinely outlives its narrowing and whose
   control fails by 50148 bytes; for the grid it earns nothing, and a
   control proves that too — removing it changes not one pixel.

   **There is no exclusion, and the two reasons given for one were both
   wrong.** A `text` can hold a widget in the middle of a line, drawn by
   descending into it from inside `tktdrawline`, which paints into the
   window there and then. That was gated off twice. The first reason
   was a crash — `sys: bad address addr=0x6574666150`, ASCII bytes
   followed as a pointer — which turned out to be the held-pointer bug
   above and nothing to do with embedding. The second was 83898 bytes
   of difference once the crash was fixed, called "ordering across a
   descent"; it is the clip-span rule, the same defect as the grid's.
   The descent's flush renders the pending tree *while the image is
   narrowed to this widget's inside*, so every earlier widget's nodes
   are cut to that rectangle.

   `tkdrawtext` flushes once before `tktsetclip()` now, so the tree is
   empty at the narrowing; what a mid-line flush renders is this
   widget's own nodes, which belong inside the clip anyway, and the
   walk hands the clip to the tree that comes after. 83898 goes to 0,
   the gate goes, and `tkthaswindow()` — which walked every line and
   every item of the whole buffer on every repaint, with no early exit
   — goes with it.

   That also gives the walk-owned clip its only test. Nothing else in
   the pane flushes inside a clip span, so without an embedded window
   the re-emit branch was committed code that never ran; with one, the
   control fails by 147 bytes. What is still unexercised is the
   *nesting*: a widget closes its clip before returning and a descent
   into another window gets a `Walk` of its own, so nothing nests
   today. The stack is kept rather than reduced to one rectangle so a
   caller that does nest is right rather than silently wrong, and the
   comment says it is unexercised.

   **It is the first widget whose node path costs more, and the reason
   is structural.** `tkbench(1)` puts a flat `text` at 5.97µs a widget
   drawn directly and 6.72µs through nodes — about 13% — where every
   other row is within a couple of per cent either way (label 8.60 against
   8.78, entry 19.06 against 17.88, listbox 31.62 against 31.08). A
   text widget emits a node per *item per line*; every widget converted
   before it emits a fixed handful whatever it contains. So this is the
   first evidence that the node path's cost tracks content rather than
   widget count, which is the thing a retained tree would eventually be
   for. It is 0.75µs, so it buys nothing to act on now, but it is the
   number to watch when `canvas` is looked at, since a canvas is
   nothing but items.

   **A real defect fell out of it, and it was not in the text widget.**
   Adding a tagged `text` to the pane made the comparison differ by one
   pixel, at the widget's top right. The cause was that `tkdrawrelief`
   already goes through nodes when `render scene` is on, and the border
   node is a pure stroke, while `tkroundbox` — what it does otherwise —
   paints the parent's colour back where the curve cuts the corner.
   Turning the switch on therefore changed what a border *meant* for
   any widget that draws in place. Nothing had shown it because nothing
   in the pane had ever painted into a corner; a tag background that
   reaches the widget's edge does. `tksceneborderon` existed for
   exactly this case and was being used by nobody; `tkreliefnodeson`
   now calls it, from both `tkdrawrelief` and the text widget.

   The first guess was wrong and is worth recording: the border is
   skipped unless the whole widget refreshes, which is two repaints in
   thirty-three, so a skipped corner mend looked like the answer.
   Making the border unconditional did not fix the pixel, and once the
   real cause was found the change was taken back out rather than left
   in as a plausible-looking extra.

   **`-indicatoron 0` was a stale exclusion.** Such a button draws no
   indicator at all — it picks a relief from its state and is otherwise
   a push button — so every part of it already had a node. Its control
   was clean twice before it discriminated, and the reason is worth
   keeping: a check or radio button is created with `borderwidth 0`, so
   the relief it picks draws *nothing*, and perturbing it changes no
   pixels. What proved the widget was reached at all was moving its
   text, 8856 bytes; what makes the relief control bite is giving the
   button a border, 16128. A state shown only by a bevel that is never
   drawn would have been worth knowing about either way.

   **`TkNtexture` is done, and it names a FILE.** The rule the node
   vocabulary keeps is that a node holds no display-side resource —
   that is why `TkNglyphs` gave up its `Font*` for a face name the
   renderer resolves through `scenefont()` — and a texture node keeps
   it the same way.

   What settled the shape was asking what the renderer can reach. A
   `TkCtxt` has a `Display`, which is all `display_open()` wants, and
   no `TkTop`, so a Tk image *name* would be unresolvable there even
   though a `TkImg` has one. A path is resolvable, and a path is what
   both sources of an image actually have: a `-bitmap` is
   `/icons/tk/NAME` or an `@path`, and `image create bitmap -file` goes
   through the same option parser. So `pbmap()` now remembers the path
   of what it opens, in a small list beside the images (`tkimgpath()`
   in `parse.c`) rather than in the widget, because the option parser
   writes an `Image*` into a struct field by offset and has no idea
   what widget it is filling in. An image that came from a file
   *descriptor* has no path and keeps the scratch — the only exclusion
   left.

   The renderer opens the file and caches it, exactly as `scenefont()`
   caches a face. That is the part worth having a check on, and the
   identity check is the right one: it says the re-opened file draws
   the same pixels as the image the widget is holding.

   **The colour image earned its place immediately.** Every icon under
   `/icons/tk` is an 8-bit mask, painted through in the foreground
   colour, and with only those in the pane the node path looked
   perfect. `icons/penguin.bit` is `r5g6b5`, drawn as a source, and it
   failed by 604800 bytes: the renderer was passing `img->r.min` as the
   source point where the widget passes `ZP`, and every mask had hidden
   that by starting at the origin. Three controls now: the texture
   shifted a pixel, 6468 bytes; the colour one shifted, 4380; mask and
   source swapped, 23274.

   **The `cascade` came in on `TkNpolyfill`**, which the scrollbar's
   arrows had already put there — `tktriangle()` is one `fillpoly()` of
   three points, and the node renderer calls the same `fillpoly()` with
   the same winding rule and the same source point, so all that was
   needed was for both to be handed the same three points. What had
   kept the cascade out was not the drawing but the *test*: its arrow
   is only ever seen in a posted menu, and a posted menu is a separate
   window with nobody offscreen to give it a backing image. `checkmenu`
   had already solved that — make the window over the pane's own Screen
   and hand it over the way a toplevel gets one — so the identity pane
   now posts a menu with a cascade in it, and what the menu draws lands
   in the pane's image. Control: the triangle's points moved two pixels
   on the node side, 468 bytes, at (724,63), inside the menu. No
   widget needs an exception for anything it does with *text* any more:
   `buton.c` took the same three cases as `label.c` the moment
   `tkscenestring()` existed, and its own controls — the underline
   dropped from the node side, 288 bytes; the justification forced back
   to left, 4068 — say the pane reaches them.

   **A label's remaining three cases went the same way as the entry's,
   and for the same reason.** Several lines, an underline and a
   justification are not new node types — a line is a `TkNglyphs` and
   the underline rule is a filled rectangle — so all that was needed
   was for both paths to lay them out identically, which they now do
   because `tkdrawstring()` and `tkscenestring()` are one function with
   two tails. Four controls, each on the node side only: every line
   shifted a pixel, 46902 bytes; the underline rule shifted a pixel,
   144; the justification ignored, 8172; all but the first line
   dropped, 14526.

   That last one was clean the first time it was run, and the reason is
   worth keeping. The layout walks the caller's string by writing a
   `\0` over each newline and putting it back afterwards; a
   perturbation that broke out of the loop early skipped the putting
   back, so the label's text stayed truncated and the *draw()* path
   drew one line too. Both paths agreed, and the check passed. A
   perturbation has to be on the side under test — and a perturbation
   that corrupts shared state is not on either side.

   **Sharing the geometry turned up a defect neither path could see.**
   `entrysel()`, which is the old selection arithmetic moved somewhere
   both paths can reach it, ends a selection that runs off the right at
   `s.max.x` — an absolute x — where every other value it computes is an
   offset that `rectaddpt()` then shifts by `s.min`. Working it through:
   `s.max.x` is `r.max.x - xp` and `rectaddpt` adds `s.min.x = xp` back,
   so the band's right edge lands on `r.max.x`, the widget's *outer*
   edge. `xp` is `borderwidth + entrypadx + highlightwidth`, and
   `entrypadx` is 8 in the flat style, so the border painted afterwards
   covers only `borderwidth` of that: the rest is selection colour lying
   in the inset gutter, on screen, today, in both paths. An identity
   check cannot see it — both paths call the same function and so make
   the same mistake — which is exactly why it is worth writing down
   that an identity check is not a correctness check.

   So `tkofftest(1)` gained one check that looks at the pixels instead:
   an entry with a selection running off the right, beside one with
   nothing selected, and the gutter between the text and the border
   must read the same in both. Against the old arithmetic it failed by
   264 of 672 bytes; with `xs1` made an offset like everything else
   around it, 0. The first version of that check sampled a single
   pixel two in from the border and passed — it had landed on a glyph,
   and the selected foreground and the ordinary one are the same shade
   in this theme. A band, not a pixel.

   **A `canvas` is nine draw methods, and seven of them describe
   themselves.** A canvas is the only widget whose drawing is not its
   own, so converting the widget meant converting the items. Doing them
   one at a time needed both ways to work in the same pass, which is
   what `TkCdraw` is for: it carries the destination image, the
   context, and the tree or `nil`, and an item that draws calls
   `tkcvsdirect()` — which renders whatever is pending and hands back
   the image. The order is therefore preserved by construction rather
   than by a flag on the item.

   `rectangle`, `oval`, `polygon`, `bitmap`, `line`, `text` and `image`
   describe themselves. `arc` and `window` draw, and each says in its
   own source why: there is no node for a partial ellipse — `TkNellipse`
   is a whole one — and an arc's pieslice arm needs a temporary image to
   cut its two radii against, which no node describes either; a window
   item has nothing to describe at all, because the picture is whatever
   the embedded widget paints.

   Several are converted only in part, and the part is named rather
   than the item excluded. `TkNpolyfill` fills by the nonzero winding
   rule and by nothing else, so a polygon asked for another one draws;
   there is no node for a filled spline, so a smooth polygon's fill
   draws while its outline is a `TkNspline`; a stroked polyline has no
   node, so only a *smooth* line reaches one; and a stipple draws
   everywhere, which is the guess made when `panel` was excluded,
   confirmed.

   **A fourth real defect, and this one was in the vocabulary.**
   `TkNspline` kept its two end styles packed in a `short`. A canvas
   arrow is `Endarrow(25,20,10)`, which is 25329922 — it came back as
   −32510. The ends moved into the node's spare `Point`, which is two
   full ints, and nothing else in the vocabulary packs a value it does
   not own. Only an `-arrow` on a *smooth* line reaches it, so the pane
   needed one added before the bug could be seen at all.

   **The buffered route had no control, and that is worse than having a
   weak one.** A canvas draws its items by one of two routes:
   unbuffered, straight into the window under a narrowed clip;
   buffered, which is the *default*, into an image the canvas keeps
   that is blitted afterwards. Both render the tree. Adding a buffered
   canvas holding the same items was not enough, because a buffered
   canvas re-runs its item draw methods only while something in it has
   changed — a repaint that finds it clean blits what is already there.
   So both halves of a snapshot pair compared one cached image with
   itself, built once at creation in whichever mode was current, and
   deleting that render outright moved *no pixel* of the test. The pair
   dirties every canvas it can find before each snapshot now (`move all
   0 0`: every item's bounding box into the update rectangle, every
   item translated by zero), and deleting the render fails by 38409
   bytes.

   Two smaller things fell out of measuring that. The dirtying walks
   `winfo children` rather than a list of the canvases in the pane
   today, because a hardcoded list is the same shape as the hole it was
   written to close. And the render at the end of the item loop covers
   only what the *last drawing item* left after it — every item that
   draws flushes — so the control's size depends on the order of the
   item list: with a drawing item last it failed by 13209 bytes, with a
   node item last by 38409.

   **What the node path costs, measured three times, twice wrongly.**
   This entry was rewritten twice before it was right, and both wrong
   versions are described here rather than deleted, because the way
   each was wrong is the useful part.

   When `text` came out dearer through nodes the reason given was that
   it emits a node per item *per line* where every widget before it
   emitted a fixed handful, and the note said that was "the number to
   watch when `canvas` is looked at, since a canvas is nothing but
   items". So `tkbench(1)` grew a canvas row — five items of four
   kinds that all describe themselves, and a spec that may be several
   commands separated by semicolons, because an empty canvas repaints a
   background and measures nothing about the item table.

   **First wrong version: the row was timing a blit.** It reported
   22.94µs drawn against 23.60µs through nodes, about 3%, and the
   conclusion drawn — that the prediction was wrong and the node path's
   cost tracks the cheapness of what it describes rather than the count
   — was worthless. The canvas was created with no `-buffer` option,
   which is the default, which is buffered; `tkdrawcanv()` clears
   `c->update` at the end of every repaint and runs the item loop only
   when the clip of the update rectangle is non-empty, so the items
   were drawn once at creation and every timed repaint after was a
   blit. Which is exactly the fact this session had just spent its time
   discovering in `tkofftest(1)` and fixing with `cvdirty`,
   reintroduced one commit later in the benchmark. Stability across
   runs was not evidence: two runs of a worthless measurement agree. A
   counter in `tkcvsrectdraw()` settled it — **fewer than 50 calls
   across a buffered run, 117200 across an unbuffered one.**

   **Second wrong version: the fixed cost was inside the slope.** With
   `-buffer none` the figures became 10.2µs drawn against 11.3–11.7µs
   through nodes, and `text` 5.8 against 6.75, so the entry said the
   prediction had held — content-heavy widgets cost 12–16% more through
   nodes. That was measured on a build where **a frame filled the
   window twice** (below), and since a row's widgets are packed into
   frames that grow with the widget count, part of every node slope was
   that redundant fill growing. It was not a property of the widgets at
   all.

   **What is true, after the frame was fixed**, over repeated runs:

   | | drawn | nodes |
   |---|---|---|
   | empty toplevel | 56.6–56.8µs | 56.7–57.2µs |
   | `text` | 5.54–5.59µs | 5.73–5.78µs |
   | `canvas -buffer none` | 9.90µs | 10.25–10.32µs |
   | `listbox` | 31.40–31.50µs | 29.74–30.07µs |

   The fixed cost is **gone, not reduced**, and the per-widget figures
   are at parity or better — `listbox`, `button`, `entry` and `frame`
   are all *cheaper* through nodes. `text` and `canvas` are 3–4%
   dearer, which is the honest residue of "a node per item", an order
   of magnitude smaller than either earlier reading.

   **A frame filled the window twice, and that was the whole fixed-cost
   gap.** The guess recorded above and never tested — "most likely a
   tree allocated and freed per run, and per widget in `tkdrawrelief`"
   — was wrong: an empty toplevel's frames have `borderwidth` 0, so
   `tkdrawrelief` returns before allocating anything. Counting instead
   of guessing, an empty toplevel is one tree of exactly **two** nodes,
   `TkNcolour` then `TkNroundfill`, **both 900×700**. The first is the
   corner mend; the rounded fill leaves the corner pixels alone, so
   what is behind them must be painted first — but at a radius of zero
   it leaves nothing alone and covers every pixel the mend painted. A
   frame with no border is the commonest widget in a window and is
   usually the size of the window, so this was a second full-window
   fill on every repaint, and 2.5MB of redundant fill is 56µs.
   Emitting the mend only when there is a corner to mend leaves the
   empty toplevel at one node. Controls: dropping the mend for *every*
   frame fails by 840 bytes, at the bordered frame over `.c`'s red
   canvas rectangle, which is the arrangement the comment there
   describes; perturbing the surviving fill fails by 6258 bytes.

   **The buffered row, and a mechanism stated wrongly once.** Two rows
   rather than one, because a buffered canvas's steady-state repaint
   genuinely is a blit — that is what buffering is *for* — and for a
   default canvas the direct-versus-nodes question barely applies,
   because in steady state neither path runs. The blit is 22.9µs where
   drawing all five items unbuffered is 10.0µs, and the first attempt
   to explain that said a buffered repaint does "two full-area draws,
   the background and then the blit". **It does not.** A counter says
   the background draw is taken **0 times in 60000** — it is guarded on
   the canvas image not covering the dirty rectangle, which in steady
   state it does. The blit is the whole of it, and a blit reads as well
   as writes where the unbuffered background only writes.

   The conclusion survives the correction because it never depended on
   the count of draws, only on which cost is fixed: the buffered cost
   is fixed in the canvas's **size** and the unbuffered cost grows with
   its **contents**. Measured at three item counts: buffered 23.6 /
   23.1 / 22.9µs at 5, 20 and 40 items — flat, as that predicts —
   against unbuffered 10.2 / 20.8 / 23.8µs. The lines cross between 20
   and 40, which was predicted from the 5- and 20-item slope (≈24
   items) *before* the 40-item run was made. So buffering a canvas pays
   above a content threshold; at five items it looks like a loss only
   because five items is nearly empty.

   A canvas does not *join* the walk even when its items are nodes: its
   items usually go into its own buffer, and a tree belongs to one
   target, so it flushes and builds a tree of its own — the same thing
   `tkdrawrelief()` does with a one-off tree. With four canvases in it
   the pane is **44 widgets and 250 nodes in 12 trees**, and the tree
   count did not move when the fourth was added, because it is packed
   next to the third with no node widget between them and the second
   `tkwalkflush()` finds an empty walk.

   **The walk is done, and it is one tree per *run*, not per repaint.**
   `tkdrawslaves` opens a walk around its descent, `tkwalkjoin` hands a
   widget the open tree, and `tkscenefinish` renders a tree only when it
   is not the walk's. It cannot be one tree for the whole repaint while
   any widget still paints directly: that widget's pixels would be
   covered by nodes rendered after it. So everything that paints into
   the window itself flushes what is pending first — every caller of
   `tkitmp`, which is exactly the widgets that draw through a scratch,
   plus the canvas, panel, text and menu painters, which draw straight
   in — and so does the grid clipping in `tkdrawslaves1`, whose narrowed
   clip is gone by the time deferred nodes would render. Painter order
   is therefore unchanged, which is what the identity check measures.

   Descents nest: a canvas's window item and a text widget's embedded
   windows each descend from inside a draw method, so the walk is a
   small stack rather than one state. An inner descent draws into
   another window and must not join the outer tree, and with one state
   its close left the outer descent with no walk at all — every widget
   after a canvas built its own tree again. The pane holds a canvas with
   a scale inside a window item for exactly that reason.

   The test pane is **19 widgets and 123 nodes in 5 trees** as this is
   written — about two dozen nodes a tree, which is the number item 4
   has to answer to, and which the test prints on every run because it
   moves each time a widget is converted. Against the measured 94%
   command-buffer overhead for small work, a backend that submitted once
   per tree would be paying a submission for two dozen rectangles. So the unit of submission cannot be the tree; it has to
   be the repaint, which means the flush points have to become
   *boundaries within* one submission rather than separate renders — and
   that is a harder change than the walk was, because a direct painter
   in the middle of a repaint writes pixels a GPU submission would have
   to be ordered against. Batching is invisible in the
   pixels, which is the point of it, so `render count` answers the two
   numbers and the check asks that the trees be fewer than the widgets.
   Four controls: batching off, and the check fails; the `tkitmp` flush
   removed, and the *pixels* differ by 4524 bytes, which is what says
   the flush points carry the painter order; the grid flush removed, and
   8004 bytes differ; the stack collapsed back to one state, and the
   pixels are identical while 11 widgets batch instead of 15 — which is
   the honest shape of that change, a batching improvement and not a
   correctness fix. That last one was clean at first, because no
   widget in the pane was gridded — and then clean again with one
   gridded, because the frame grew to fit it and the clip cut nothing.
   It fails only with `grid propagate .g 0` and a 207-pixel scale in a
   60-pixel frame, which is the arrangement where a clip is real.
4. **A backend — but not on faith.** See the section below: the
   measurement that was supposed to justify one says the opposite, so
   this is now gated rather than scheduled.
5. **`clip`, `transform`, `opacity`** — the three that make animation
   free, and the actual prize.

## The next bit, and why it is not the GPU

Written after the walk landed, against the numbers rather than the
intention. Items 1 and 2 above are still open, item 3 is done.

### What the measurement says

`tkbench(1)` puts a thirty-widget window at **400µs of drawing and 250µs
of present** — 4% of a frame. `gpu(3)` and `doc/hpc-plan.md:366` put
command-buffer commit-and-wait at **94% of a small GPU call**, and say it
barely moves with the size of the problem. Those two numbers together say
a Metal backend for `libtk` cannot win a repaint it is given: there is
0.4ms of work to take, the submission alone costs a comparable amount,
and the CPU path is already at 4% of a frame.

So **the reason to finish this is not speed, and pretending otherwise
would be the third time this tree talked itself into a GPU path that
measurement did not support** — `math(2)`'s BLAS builtins invalidated the
`matvec` offload case outright, and the draw3d readback case cost a
session before the numbers were believed. The reasons that survive
contact with the numbers are:

- **A tree that is a description, not a reproduction.** Today it
  reproduces what `draw()` did, corner-repainting and all. That is what
  items 1 and 2 are about, and neither needs a GPU.
- **Animation.** `clip`, `transform` and `opacity` make a moving thing
  cost nothing to *re-describe*. That pays on the CPU renderer too: the
  tree is rebuilt from scratch every repaint today, so nothing that
  moves is cheap, whoever rasterises it.
- **Not having to answer the question again.** A node vocabulary that
  can express a frame is worth having even if nothing but `memdraw`
  consumes it, because every later decision — damage tracking, a
  backend, a remote display — needs a description of the frame and there
  is currently none.

### The order, and the evidence each step owes

**A. ~~Widget fills become `TkNroundfill`~~ — DONE, as a shaped
composite, and the plan was wrong about it twice.**

   It said the *fills* should become rounded so that `TkNcorners` — four
   cutaways painted in the parent's colour after the widget is drawn —
   would stop being needed. The first correction: the fill it named does
   not exist. Every converted widget takes its fill from `TkNlayer`,
   which fills the scratch flat before anything is drawn into it.

   The second correction cost a failing run to find, which is the point
   of having one. A rounded fill under a square composite still shows a
   `listbox`'s selection band in the corner, because the band is drawn
   *after* the fill and runs the full width of the widget. Twelve
   pixels. So the corner node was not mending the fill; it was mending
   everything drawn over it, and a fill of any shape cannot do that.

   The shape therefore belongs on the **composite**:
   `tkscenelayerround()` takes a radius, and the layer's blit copies the
   middle band plus each corner row span by span with the same `inset()`
   the rounded fill and the border already use, so the three agree by
   construction. The corners are not copied, what shows through is what
   was already there — the parent's background, the same colour the mend
   used to paint — and a widget no longer needs to know what is behind
   it in order to draw itself.

   It also needed the focus ring drawn *before* the border in `entry`
   and `scale`, which is the order `button`, `label` and `listbox`
   already used: a ring drawn after the border puts its square corner
   where the border has just cut the widget away. A focused entry had a
   blue notch outside its own rounded corner, in the ordinary drawing
   path and not only in the nodes.

   Identity holds at 0 bytes; the pane's node count fell by the five
   corner nodes. Controls: the composite squared again differs by 2400
   bytes, its radius widened by two by 2712, and a print in the
   `TkNcorners` renderer is reached by no run at all.

   **Then the direct path had to be clipped too, and that is the part
   the whole-pane check could not have found on its own.** The composite
   leaves the destination's corner pixels alone; the mend painted the
   parent's flat background over them. Those agree only while what is
   behind a widget *is* that flat colour, which is true of every widget
   in a pane of widgets on frames. Put a bordered `entry` in a `canvas`
   over a red item and they disagree: page-grey against red, six pixels
   a row. So both paths now end in one shaped blit, `tkshapedblit()`,
   with `tkinset()` and `tkclamprad()` shared so the fill, the border
   and the blit cannot hold different opinions about where the curve is.
   The control is one widget's blit put back to square, which brings the
   red back on one side only.

   Two real defects fell out of insisting the paths agree. A widget
   narrower than twice its own corner had its border stroke drawn
   *outside* the outline the same routine had just cut away — an
   8-pixel entry, a thin scrollbar — and the stroke is clamped now, in
   both paths. And a focused `entry` or `scale` drew its ring after its
   border, putting a square blue corner outside a rounded one.

**B. `TkNglyphs` carries a font NAME, not a `Font*` — half done.**

   The node no longer holds a display-side resource: it carries the
   face's name and the renderer resolves it with `font_open()`, the same
   call `libtk` already uses for every face including `*default*`, with
   a small never-emptied cache. Identity holds at 0 bytes with two faces
   in the pane — the second one had to be *added*, because with every
   widget in the default face a node naming the wrong font would still
   have drawn. Controls: a name nothing can open loses 45891 bytes of
   text, and the wrong name — `*default*` for every node — differs by
   64158.

   What is left of B is the layout: the node still carries a string, so
   the renderer calls `string()`. A backend cannot, so positioned glyphs
   and an atlas are still owed — but that changes what the pixels are
   made of and is a step of its own. The original phrasing of this item
   follows, and the atlas half of it stands:

   ~~**`TkNglyphs` carries an atlas reference, not a `Font*`**~~ (plan
   item 2). This is the one node that still holds a resource, and `scene.c` says
so in place. It blocks two separate things: a retained tree cannot
outlive the caller while it points at a `Font`, and no backend can draw
text from a node that hands it a display-side font object. The pieces
are here — `chardrawaa()` in `libmemdraw/draw.c:2535` already blends
coverage masks — and the Metal sprite cache is explicitly *not* an atlas
(`emu/MacOSX/win-cocoa.m:4058`, "one Metal texture per distinct
(img,mask) pair"). *Done when* a glyph node holds an atlas id and a list
of positioned glyphs, the software renderer draws from the atlas, and
the identity check still reads 0 bytes at three font sizes including a
TrueType face. *Control:* shift one glyph's position in the atlas path;
and separately, free the `Font` after building the tree and before
rendering it — which must still draw correctly, since that is the whole
property being bought.

**B′. What the node path costs, measured — and one layer that cost
   everything.** `tkbench(1)` grew a `-n` flag that selects the node
   path before the timed repaints, and the first run was alarming: an
   empty toplevel — two frames — repainted in **1.41ms** against
   **59µs** on the direct path, twenty-four times the fixed cost, with
   every widget 1.4× dearer.

   It was one decision, and the code had said so all along. A `frame`
   was given a `TkNlayer` *because it does not need one*: it draws
   straight into its parent's image, so it was the one widget that could
   prove a layer was rendered identically to drawing in place. A layer
   is a scratch the size of the widget, allocated, filled and blitted
   every repaint, and a frame is usually the size of the window. With
   the layer taken off the frame the empty toplevel is **114µs**, and
   each widget's node cost lands within the noise of its direct cost —
   label 8.90µs against 8.73, button 13.18 against 13.35, listbox 33.19
   against 34.56, entry 16.15 against 19.79. The proof stands; six
   widgets that genuinely need a layer keep the node exercised.

   The remaining gap is fixed cost, not per-widget: 111µs against 59µs
   for an empty toplevel, and it is *not* the rounded fill — making a
   borderless frame's fill square, which is what it should have been
   anyway, moved 114µs to 111µs and no more. What is left is most
   likely a tree allocated and freed per run, and per widget in
   `tkdrawrelief`, which builds a scene of its own for any widget whose
   relief is drawn in the flat style. Worth knowing; not worth chasing
   at 4% of a frame until something asks for it.

   The lesson is the one this plan keeps relearning: the thing that
   makes a renderer slow is not the vocabulary, it is one allocation in
   the wrong place, and nothing but a measurement finds it.

**C. A retained tree, and damage.** Only after B, because a tree that
holds a `Font*` cannot be kept. Today `tkdrawslaves1()` decides what to
repaint from `tk->dirty` rectangles and every surviving widget rebuilds
its nodes from scratch. The question worth answering is whether keeping
last frame's tree and re-emitting only the dirty subtrees is measurably
cheaper on the CPU path — `tkbench(1)` already measures the thing that
would move. *Done when* a repaint that changes one widget rebuilds one
widget's nodes and `tkbench` shows the difference. *Control:* the
obvious one is a tree that is never invalidated, which must produce a
stale window; if it does not, the damage is not being used.

**D. `clip`, `transform`, `opacity`.** The prize, and the first thing
that makes a *moving* interface cheaper rather than merely described.
Testable exactly as everything else here has been: a transform node
against the same widget drawn at the transformed position, byte for
byte.

**E. A backend, if and only if a measurement asks for one.** The gate,
written down now so it is not argued later: a GPU path is worth building
when a repaint's drawing cost exceeds roughly **2ms** — five times the
present cost, well past the submission overhead — for a window somebody
actually uses. The way to find out is to run `tkbench(1)` at the sizes
that might get there: a full-screen window at HiDPI, a 200-widget form,
a text widget scrolling. If none of them gets there, the honest
conclusion is that `libtk` should stay on `memdraw`, and the node tree's
value is B, C and D rather than a rasteriser.

The infrastructure is not the obstacle if the gate is passed:
`emu/MacOSX/win-cocoa.m` already has a `CAMetalLayer`, a command queue,
pipelines for the softscreen blit, geometry, GPU-side T&L and textured
quads with blending, and — the part that is usually the hard one — a
readback path (`metal_blit_tex`, `metal_overlay_soft`) that makes GPU
output observable by `readpixels`, because `draw(3)` reads must be
ordered after writes. A node backend would register the way
`gpudrawfillpoly3d` does (`emu/port/devdraw.c:198`): a nullable hook,
software when it is nil, and the software renderer as the oracle.

### The unfinished widget conversions, sized

Not on the critical path, but this is where they stand, so nobody has to
re-derive it:

Three entries stood here and are **withdrawn** — they were written
before the work that closed them and were still being read as open:

- **`cascade`** — done. Its arrow is `tktriangle()`, one `fillpoly()` of
  three points, and `TkNpolyfill` renders it with the same winding rule
  and source point. The obstacle was never the drawing but the *test* —
  a cascade is only seen in a posted menu, and a posted menu is a
  separate window — and that was solved by making the window over the
  pane's own Screen, so the pane posts a menu with a cascade in it now.
- **`entry` with a selection or `-show`** — done. The band is
  `tkscenetextsel()`, five `TkNcolour`s, and the runs are `TkNglyphs`;
  `entrysel()` is the shared arithmetic both paths reach, and sharing it
  turned up a real defect neither path could see on its own.
- **Images and bitmaps** — done. `TkNtexture` is implemented and names
  a *file*, which is why an image that came from a file descriptor is
  the one case still excluded: it has no name to give.
- **`panel`** — paints into the window directly, is a flush point in
  the walk, and stays that way on principle: its image is a live
  `Image` a Limbo program writes through `putimage`, so there is no
  file for a node to name. `text`, `canvas` and `menu` were on this
  line and are done.

## 9. A node that cannot say where it lands — **done**

Written after the walk and the widget conversions, and it is a defect
report rather than a plan item: three node kinds did not describe the box
they mark, which is the one property the whole vocabulary exists to
provide.

- `tkscenetext()` set `r.max = r.min`, so a glyph run was an **empty
  rectangle at the text origin**.
- `tkscenepolyfill()` and `tkscenespline()` never set `r` at all,
  leaving it zeroed.

A backend reading such a node can neither place it nor cull it, and the
tree's own premise is that it "outlives the repaint that built it and can
be handed to something else to draw". Fixed at build time, where the
information is already in hand: the text setter has the `Font`, so it
records `stringwidth` by height; the polygon takes the box of its points;
the spline unions `memlinebbox()` over consecutive control points, which
is `libmemdraw`'s own answer to arrows and end styles rather than that
arithmetic rewritten in `libtk`. A B-spline stays inside its control
hull, so that bounds the curve.

### The test nearly tested nothing, and the reason is structural

The obvious check — does the scene union cover every pixel the repaint
touched — **passes with all three bugs present**, and that was confirmed
by removing a fix and watching it still pass. A zeroed rect is *empty*,
so a union walk skips it; and every detail node sits inside its own
widget's background, so no scene-level rectangle moves when a glyph run
or a polygon fails to describe itself. **A scene-level union cannot see
per-node extent at all.**

So the nodes are asked directly. `render nodes` reports how many nodes
marked pixels and how many described no box; the second must be zero.
Proved by removing each fix in turn: without polyfill 92 ok 1 fail,
without glyphs 92 ok 1 fail, without spline 92 ok 1 fail, all three
present 93 ok 0 fail. The spline arm needed a checked `checkbutton` and a
canvas line with an arrow added to the pane — nothing else there emits a
spline node, and until they were added that arm passed with the fix
removed.

### `render bounds`, and the consumer it does not have

`tkscenebounds()` unions what a tree marks, reached as `render bounds`.
It is conservative by construction, and that direction is the one that
matters: damage too large only costs work, damage too small drops pixels.
A clip node is therefore ignored rather than intersected, since leaving
it out can never make the answer too small.

**Nothing consumed it when it was committed, and no speculative caller
was wired to justify it.** `emu/MacOSX/win-cocoa.m` already marks 32x32
tiles from per-`memimagedraw` damage, which is *finer* than a whole-frame
union, so a union would tell it nothing it does not have.

### The consumer turned up, and it is not the one this was aimed at

It was aimed at making the Raspberry Pi 3B's `flushmemscreen` cheaper.
That is not what wants it. The Pi work went: draw straight into the
scanout buffer and the copy disappears — 91% of the screen path, measured
at **6.8 to 7.1 times faster** on silicon. But drawing into scanout
tears, and the usual answer is double buffering, whose cost *scales with
damage*: the copy to the back buffer is 20452µs of a 23900µs path
full-screen but 818µs for a 128×96 widget.

Not "the fix", which is what this said and which conflates two things.
Double buffering removes the **half-drawn** frame; it does not promise a
**clean** one. Without a wait for vertical blank the flip itself becomes
the tear line, so the tear *moves* rather than vanishing. The Pi's
`mboxvsync()` exists and the period is measured, but a vsync wait holds
the mailbox lock for a whole frame and whether that is affordable is its
own measurement.

So the rule is **copy `damage(N-1) \ damage(N)`** per frame.

### WITHDRAWN: that this needs anything from `libtk`

This section claimed the rule had to know a frame's extent *before
drawing it*, that an immediate-mode draw could not say, and that
`tkscenebounds()` was the answer. **That is wrong, and the error was
mine as much as the Pi session's: it conflates "before the frame is
SHOWN" with "before it is DRAWN".** The copy only has to precede the
**flip**.

Work the order with two buffers. After the flip for frame N-1, front is
frame N-1 and back is frame N-2, so back is stale exactly in
`S = damage(N-1)`. Then:

1. draw `damage(N)` into back;
2. at `'v'`, **both** rectangles are in hand — `S` from the previous
   present and `damage(N)` from the one just finished;
3. copy `S \ damage(N)` front→back;
4. flip.

| region | back buffer holds | correct? |
|---|---|---|
| in `damage(N)` | drawn this frame | yes |
| in `S`, not in `damage(N)` | frame N-1, copied from front — and frame N == frame N-1 here | yes |
| outside `S` | frame N-2, which equals frame N-1 outside `S`, and N is undamaged here | yes |

The cost is `|damage(N-1) \ damage(N)|`, the deferred cost exactly, and
the work is a rectangle subtraction of at most four pieces. Nothing needs
to know anything before the drawing, so **there is no pre-draw hint and
no path from `libtk` to build**.

`tkscenebounds()` therefore still has no consumer, and the commit that
said so plainly remains true — not because the consumer is unwritten but
because it should not exist. It may still earn its place as the only
thing in the tree that knows a frame's extent *before* the frame, which
is genuinely unavailable elsewhere; just not for this.

### The hazard that replaces it: drawing into a stale buffer

Step 1 draws into a buffer stale in `S`. An operation that **fully
overwrites** its damage rect does not care. One that does not leaves
frame N-2 pixels inside `damage(N)`, which step 3 deliberately excludes
from repair. The exposure is `damage(N) ∩ S`, and it is wider than
"read-modify-write" suggests:

- **`string` is the default case, not a rare one**: a glyph is a *mask*,
  so non-ink pixels inside the glyph rect keep what the destination held.
- `line`, `poly`, `ellipse` write only their spans while `dstflush()`
  charges the whole bounding box, so the holes lie inside `damage(N)`.
- any `'d'` with a non-opaque mask, an alpha source, or `op != SoverD`.

Only a fill or an opaque blit is a true overwrite. So the question is
whether Tk draws partial-overwrite operations straight onto a window or
onto a per-widget offscreen image that is then blitted opaquely — and
Inferno's Tk being flicker-free hints at the second, which is a guess and
labelled as one.

It ships either way: on the first partial-overwrite operation in frame N
that meets `S`, repair all of `S` eagerly. The worst case degrades to the
eager cost — 1770µs, the number this was trying to beat — and never to a
wrong image. Which makes what remains a **performance** question rather
than a correctness one.

### Measured: there are no partial-overwrite operations at all

`INFERNO_FRAME_DAMAGE` also tallies the command byte behind every damage
rectangle, and classifies each `'d'`. On `runtests -g` at 640×480:

| | count |
|---|---|
| ops producing damage | `d`=2644… 8628 total `'d'` calls, plus `G`, `L`, `b`, `f`, `t` |
| `s` `x` `l` `p` `P` `e` `E` reaching the damage path | **0** |
| `'d'` operations that do not overwrite their rect | **0 of 8628** |

So Tk sends no string, line, polygon or ellipse directly to the screen or
to a window layer — it renders them into per-widget images and blits
those — and every blit it does send is `SoverD` with an opaque mask and
source. **The stale-buffer hazard does not arise on this workload, and no
per-operation machinery is needed.** That was the Pi session's guess from
Tk being flicker-free, and it holds.

**Both zeroes were checked against a control, because a zero from a
predicate is worth nothing until the predicate is shown able to fire.**
The op tally proves the instrument sees operations at all (2644 `'d'`
rectangles, not silence). Inverting the opacity test to `op == SoverD`
gives **8628 of 8628**, so the counter can be non-zero and every
operation really is `SoverD`.

**The limit**: with the op term legitimately zero, the mask-alpha and
source-alpha terms were never exercised by this workload, so they are
untested rather than confirmed. A workload that blits an alpha image to a
window would test them.

### And what that zero does to the acceptance test

The zero is good news about the drawn region and therefore *bad* news
about what an instrument can see. If every operation fully overwrites its
rectangle, the pixels a frame draws are always right — so a defect in the
machinery that repairs the region a frame did **not** draw produces a
screen that looks entirely correct, with wrong pixels only where nothing
is watching.

That is not hypothetical. The Pi session's first repair had an inverted
source and copied the back buffer onto itself: a no-op whose only symptom
would have been subtly stale pixels in exactly the region the repair
exists to fix.

So the acceptance test for a flip is **not** "does the screen look
right". It is a readback of the **un-redrawn** region specifically,
asserting it still holds the previous frame's content there.

`lorigintest(1)` is already that shape, which is why it caught the
afterimage: `alone()` and `over()` check the region a move *vacated* —
the part nothing redrew — rather than the window's new position. The
general rule is the sharpest version of the blind-instrument problem in
this document: **an instrument that watches what the code writes cannot
see a bug in what the code does not write.** Point it at the complement
of the action.

### Measured first: Tk's damage is widget-sized

The rule above is only worth the plumbing if Tk's damage is small, and
that is a question about `libtk`'s repaint logic rather than about any
board — which means it can be answered here. `INFERNO_DAMAGE_HIST=n`
puts the same five buckets the Pi's `flushmemscreen` uses into emu's,
printing every n flushes:

Run at **640×480**, which is the Pi's geometry to the byte (a full screen
is 1228800 bytes either place), so the buckets *are* coverage:

| workload | flushes | mean bytes | mean coverage | ≤5.3% | ≤21% | >85% |
|---|---|---|---|---|---|---|
| `runtests -g` | 197 | 106356 | 8.7% | 74.6% | 19.8% | 4.1% |
| `wmtest -n 40` | 122 | 66979 | 5.5% | 98.4% | 0.0% | 1.6% |

So the common case is a widget at a few percent of the screen, the mean
copy is 1115 to 1770µs — **6.7 to 10.6% of a 16665µs frame** — and the
flip case, damage past 85% of the screen, is **1.6 to 4.1% of flushes**.
Both halves of the rule are affordable, which is what it needed.

### Neither bytes nor coverage transfers, and that is why this was re-run

The first version of this measured at 1024×768 and argued the buckets
transferred because they are byte-denominated: a 128×96 widget is 49152
bytes on any screen. The raspi3b-port session pointed out the other half
— the rule's *decision* is about coverage, and the same rectangle is
2.6× more of a 640×480 screen than of a 1024×768 one, so the flip case
should fire more often on the Pi.

Both arguments are half right, and the data says why. Shrinking the
screen by 2.56× in area moved the mean damage by only 2.08× and 1.47×:

| workload | 1024×768 | 640×480 | ratio | coverage then → now |
|---|---|---|---|---|
| `runtests -g` | 221236 B | 106356 B | 2.08× | 7.0% → 8.7% |
| `wmtest -n 40` | 98404 B | 66979 B | 1.47× | 3.1% → 5.5% |

Tk's damage scales with the screen **sub-linearly** — some of it is
widget-sized and fixed, some of it is window-sized and follows the
layout. So byte figures do not transfer (they fell), and coverage
figures do not transfer either (they rose, in the direction predicted).
The conclusion is duller and more useful than either position: **measure
at the target geometry**, which is what the table above does.

**One limit remains.** Both workloads are automated suites rather than a
person using the machine. What makes that less worrying is that the
churn-heavy one — `wmtest -n 40`, forty toplevels — is the *more*
widget-sized of the two, so if these are biased it is toward
overestimating damage.

### WITHDRAWN: the budget argument, and why it was wrong

An earlier version of this section argued that the rare `>85%` bucket was
what justified the rule, on two grounds: that 4.1% of flushes carried 47%
of the damage bytes, and that every flush in that bucket exceeds a 60Hz
frame budget on the copy alone (20452µs against 16665µs, 1.23×). Both
numbers are correct. **The conclusion does not follow and the argument is
withdrawn.**

Working the sequence rather than the distribution: with two buffers,
drawing frame N into the back buffer requires `damage(N-1) \ damage(N)`
copied into it first, because the back buffer holds frame N-2. So

| scheme | cost of frame N |
|---|---|
| eager — copy after each flip | `|damage(N)|` |
| deferred — copy before each draw | `|damage(N-1) \ damage(N)|` |

and since `|A \ B| = |A| − |A ∩ B|`, summing gives

> **eager − deferred = Σ |damage(N-1) ∩ damage(N)|**

The saving is the **overlap between consecutive frames' damage**, and
screen coverage does not appear in it anywhere.

So an *isolated* full-screen frame drops a frame under **both** schemes.
Deferred makes the full frame itself free, then charges the frame after it
`|full \ widget|`, which is nearly the whole screen. The 20452µs does not
disappear; it moves one frame later. "Dropped frames deterministically"
was a true statement about *eager* presented as an argument for
*deferred*. Deferred wins on drops only when full-screen frames are
**consecutive**: k in a row is k drops eager and one deferred.

The 47% goes the same way. It is a true statement about where eager's
cost sits, not a saving — for isolated fulls the deferred total is the
same to within a couple of widgets, because the big copy is still paid.
**The number described the cost and it was read as the prize.**

### The rule that survives is better than the one it replaces

The saving is **repeated damage of the same region, at any size**,
because that is where consecutive damage overlaps. A widget animating in
place costs eager that rectangle every frame and costs deferred *zero,
for ever*. "Flip when damage covers the screen" is one sufficient
condition for `damage(N-1) \ damage(N)` being empty, which is why it
looked right — and it misses every small repeated rectangle. The rule is
just **copy `damage(N-1) \ damage(N)`**, with no coverage test in it.

### Measured, with the right quantity this time

`INFERNO_DAMAGE_HIST` now also keeps the previous rectangle and
accumulates the overlap — one `rectclip` and an add:

| workload | flushes | eager | deferred | saving |
|---|---|---|---|---|
| `runtests -g` @640×480 | 197 | 20952256 B | 3084216 B | 84.9% |
| `wmtest -n 40` @640×480 | 122 | 8171520 B | 1182672 B | 84.9% |

That is 1770µs eager against 261µs, and 1115µs against 161µs. The saving
is overlap, which is what the model says, and not coverage, which is what
the withdrawn argument said.

**But this number is not yet the one the model wants, and the reason is
the same mistake one level down.** The model's `damage(N)` is what *frame*
N draws. `flushmemscreen` is called per **flush**, and nothing here has
established that a flush is a frame. The per-transition data says it
probably is not: `damage(N-1)` is entirely *inside* `damage(N)` in 132 of
196 transitions, and 120 of 121 for `wmtest`, with **no** transition
having zero overlap. Nested, growing rectangles are what several flushes
refining one logical update look like — so 84.9% may be measuring
redundancy *within* a frame rather than overlap *between* frames.

If a flush is not a frame then the figure is an upper bound, because a
flip coalesces nested flushes into one damage region and it is the
overlap between coalesced regions that matters.

### Settled: a frame boundary already exists, and a flush is a frame here

It needed no platform-specific instrument. `'v'` in `devdraw` **is** the
client's present by its own declaration — `libdraw`'s
`flushimage(d, visible)` emits it only when `visible` is non-zero — so
the union of damage between `'v'` commands is exactly the quantity the
model wants, in portable code above both a flip and an upload. What makes
the raw flush stream ambiguous is only that `dunlock()` calls
`drawflush()` on every `/dev/draw` write that took the drawlock, mixing
incidental flushes in with real presents.

`INFERNO_FRAME_DAMAGE=n` accumulates damage between `'v'`s. On
`runtests -g` at 640×480:

| workload | boundary | count | eager | deferred | saving | per frame |
|---|---|---|---|---|---|---|
| `runtests -g` | per flush | 197 | 20952256 B | 3084216 B | 84.9% | 1770→261µs |
| `runtests -g` | per `'v'` | 197 | 20952256 B | 3084216 B | 84.9% | 1770→261µs |
| `wmtest -n 40` | per flush | 122 | 8171520 B | 1182672 B | 84.9% | 1115→161µs |
| `wmtest -n 40` | per `'v'` | 122 | 8171520 B | 1182672 B | 84.9% | 1115→161µs |

The two boundaries agree **exactly** — same counts, same bytes. So on
these workloads Tk emits one `'v'` per update: a flush *is* a frame,
there is no intra-frame fragmentation to coalesce, and the upper bound
turns out to be the value. Measured at the right boundary rather than
assumed to be the same.

(An earlier version of this table reported 196 frames against 197
flushes and explained the 71632-byte gap as one damage region. That was a
line sampled while the run was still going, before the last frame
closed. The final counts are equal, which is a cleaner result than the
one it replaces — and a reminder that a cumulative counter read mid-run
is not the total.)

Two cross-checks had already pointed that way. Strict growth —
`damage(N-1)` *properly* inside `damage(N)`, the refinement a present
would absorb — is **0.9%** of overlap bytes on this workload and 0.7% on
`wmtest`; the overlap is almost all equal rectangles, which given
containment means the same rectangle redrawn. The equal case alone could
not distinguish a widget repainted next frame from one flushed twice in
the same frame, which is why the `'v'` measurement was still worth
taking.

And the sequence question the model raised, which the distribution had
thrown away: the `>1MB` flushes in that run are at indices **1, 2, 3, 4,
5, 6, 7 and 68** — seven consecutive, then one isolated. So the
consecutive case that favours deferred does occur, but all of it is
start-up paint; the single mid-run full frame drops a frame either way.

### The methodological failure, which is the part worth keeping

Every number in the withdrawn argument was correct. The histogram, the
47%, and the per-byte rate — which was even checked for linearity at both
ends. The conclusion was wrong anyway, because **a distribution over
flushes cannot answer a question about order**, and neither of us asked
which kind of question we had.

Checking a rate does not check that the quantity measured is the quantity
the argument needs. That is a different and harder check, and it is the
one that was missing.

### And a warning about every instrument in this section

The Pi work measured its tear directly: 31 of 31 draw operations torn,
2339 rows written after the beam had passed them — and in the *same run*,
a readback check of the pixels passed all five of its tests. **The
framebuffer is never torn.** Tearing is a relationship between when a
pixel was written and where the beam was, and reading the pixels back
afterwards cannot recover it.

`tkofftest(1)`, `lorigintest(1)` and `render bounds` are all readback
probes. They are sound for what they check, which is what the pixels
**are**. They are blind by construction to anything that is a property
of **when** the pixels got there, and no amount of care inside them fixes
that.

The accumulator costs nothing measurable: two extra walks of the node
list per tree moved the per-widget slope by a few tenths of a percent,
and the *direct* path — which none of it can touch — moved by the same
amount over the same runs, so the shift is the rig drifting.

### What `TkScene` still does not know

Its damage bounds, as a stored property. Every `TkNode` carries a
`Rectangle r`, so the union is one walk away, but `TkScene` is a block
allocator, a head, a tail and a count, with no extent field and nothing
accumulating one. An earlier draft of `doc/draw-hardware-seam.ms` claimed
otherwise and was corrected: it is an opportunity the description makes
cheap, not a property it already has.
