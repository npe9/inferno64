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
   caret and focus ring inside one `TkNlayer`, with the scratch-and-blit
   kept for the two cases that have no nodes yet: a visible selection
   (two more runs and a band behind them) and `-show`, which builds a
   throwaway Rune buffer. The glyph node carries a *string*, so the
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

   **What is left is the rest of the widgets and then the walk.** Each
   `tkitmp` user converts the same way, against the same byte check;
   `scale` and `scrollbar` are the remaining ones, and the indicator a
   `checkbutton` draws needs an ellipse node first. Only when
   a repaint produces one tree instead of one per widget is there
   anything for a backend to batch.
4. **A Metal backend.** Last, and only after 3: the measured hazard is
   94% command-buffer overhead for small work, so a backend that issues a
   draw call per node would be *slower* than the CPU, decisively. The
   whole reason the real systems work is that they batch a frame into one
   or two submissions.
5. **`clip`, `transform`, `opacity`** — the three that make animation
   free, and the actual prize.
