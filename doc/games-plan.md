# Games as demonstrations: what is built, and what is still worth building

The games in `appl/cmd/games` and `lib/tiles` are not here to be games. Each one
exists to make some part of this system visible by using it for real, under a
frame deadline, in a program a person can sit down in front of. A demonstration
that nobody can run is a claim; a demonstration you can play is evidence.

This document is a survey. It says what the existing eight demonstrate, sorts the
early arcade and console catalogue into the handful of *mechanical shapes* it
actually contains, and says which of those shapes would land an Inferno axis that
nothing here has landed yet. It is a list of work, in order, with a reason
attached to each item that is about this system and not about the game.

## On copying

What is taken from these old games is the mechanics: a jump whose height depends
on how long the button is held, four pursuers with four different ideas about
where you are, a gauge that punishes holding the fast button. Mechanics are the
part that is not anybody's property, and they are also the only part that is
interesting here, because the mechanics are what put load on the system. The
expression is not taken: no character, name, sprite, level layout, tune or line
of text in this tree comes from anywhere but this tree. The names are one-word
English nouns; the art is written out as `.123` strings in the source or in
`lib/tiles/*.chr`, by hand, here. That is the whole of the policy.

## What is here already

Verified by running them, and by each one's own `-t` mode.

| | shape | what it puts load on |
|---|---|---|
| `rivet(1)` | fixed screen, climb a structure | `tiles(2)`'s tile map, one screen; one-way platform collision |
| `sprocket(1)` | side-scrolling run and jump | the scroll: a level four screens wide, drawn once, blitted as a window; a mutable background |
| `starling(1)` | fixed shooter, a formation of attackers | metasprite throughput. 40 metasprites plus 48 stars in **210 µs a frame** compiled, 283 µs interpreted |
| `orchard(1)` | maze chase, four pursuers with four rules | **a file interface**: the game serves its own state and control through `file2chan(2)`, so a shell script can read the board and drive it |
| `gorge(1)` | fly a canyon | `draw3d(2)`: ~200 Gouraud quads a frame. Device provider **2408 µs/frame**, software **73366 µs** |
| `strider(1)` | walking-machine combat | a simulation with instruments: heat, sectional armour, a torso that turns independently of the legs, and a HUD that has to be read at speed |
| `warren(1)` | maze chase | **the shell as the language**: rules in ~20 lines of `sh(1)` over `sh-tiles(1)`, a frame in 220 µs |
| `leap(1)` | side-scrolling platformer | the same, with gravity, a camera and an entity list. Measured cost **~1 ms per entity**, so ~40 entities is the shell's ceiling at 25 Hz |
| `camber(1)` | side-view racer, with a design mode | **content as data**: every tile and every feature of a course is read from a file at run time, through `tiles(2)`'s command language, and `camber -e` writes those files |
| `spire(1)` | vertical climber with rooms off it | **the namespace**: a room is a *mount*. A door runs a program that serves four files over Styx, mounts it on `/n/room`, and reads and writes those files; leaving is an unmount, and the room's process ends with the connection |
| `tandem(1)` | two players on one screen | **Styx across a machine boundary**: the game is a file server with no window, and every player — the local one included — is a client of it. A frame over the mount costs **1278 µs**, 8% of the 60 Hz budget |
| `bout(1)` | a duel against a scripted opponent | **behaviour as a little language**: an opponent is a file of states and timed instructions, read at start-up. The game reads `/lib/bouts` and fights what it finds; `bout -c` checks a file and reports `file:line` like a compiler |
| `sprig(1)` | fixed screen, defence upward, a meter that runs out | **one Dis process per entity**: every pest owns its state, takes the frame off a shared channel and moves itself. Cleared first by `procbench(1)`; a 16-pest wave costs **2 µs a frame** |

Two things follow from that table. `orchard` is the only one that exposes itself
as a filesystem. And until `camber`, nothing in it loaded its content from
anywhere: every one of the four earlier Limbo tile games compiles its art and its
levels in as arrays of strings, even though `tiles(2)` grew a command language —
`sheet`, `map`, `at`, `set` — precisely so that they would not have to. The shell
games read their levels from `lib/tiles/*.map`; the older Limbo ones do not.
Converting them is not on the list below, because `camber` has now made the
argument and repeating it four times would demonstrate nothing further.

## The shapes the catalogue actually contains

Sorted by mechanics rather than by title, because the mechanics are what decide
what a port would exercise. Titles are named only as the shape a reader will
recognise.

**Already covered here:** climb a fixed structure (*Donkey Kong*, *Donkey Kong
Jr.*); run and jump across a scrolling level (*Super Mario Bros.*); shoot a
descending formation from a fixed position (*Galaxian*, *Space Invaders*); be
chased around a maze (*Pac-Man*); forward motion through a receding world
(*Rad Racer*, *3-D WorldRunner*); drive or pilot a machine with instruments.

**Not covered:**

1. **Fixed screen, defence upward, consumable meter.** You are underneath; a
   threat works its way down toward you; you spray upward at it; the spray is a
   resource that runs out and recovers, so the game is about when *not* to fire.
   Many small fast independent things descend at once. (*Donkey Kong 3*.)

2. **Vertical scroll with horizontal wrap, and rooms off to the side.** The view
   climbs; the world wraps left to right so there is no edge; and doors lead out
   of the platforming into rooms with entirely different rules — a shop, a
   treasury, a trial. Two kinds of game in one program, joined by doorways.
   (*Kid Icarus*.)

3. **Side-view racer with a heat gauge and a design mode.** Lanes you move
   between, ramps that launch you, an attitude in the air that decides whether
   the landing is clean, and a temperature gauge that punishes holding the fast
   button. And a mode in which you lay out the course, save it, and then race the
   thing you saved. (*Excitebike*, *Mach Rider*, *Wrecking Crew* — the design
   mode is a whole family, not one title.)

4. **Two players on one screen.** Cooperative or quietly contested: both players
   in the same space, able to help or to ruin each other. (*Ice Climber*, the
   arcade *Mario Bros.*)

5. **A duel against a scripted opponent.** You cannot out-run it; you learn its
   tells. Each opponent is a state machine with a personality, and the game's
   content *is* those state machines. (*Punch-Out!!*)

6. **Aim a pointing device at targets.** The input device is the game.
   (*Duck Hunt*, *Hogan's Alley*, *Wild Gunman*.)

7. **A connected map that remembers.** Rooms joined into one world, an inventory
   that persists, and state that survives the program exiting. (*Metroid*,
   *The Legend of Zelda*.)

8. **Momentum on a grid**, and **physics toys** — turning about posts with
   conserved speed (*Clu Clu Land*), a table with flippers (*Pinball*), a swing
   meter and ballistics (*Golf*). Real shapes, but the axis they exercise here is
   arithmetic, which `strider` and `gorge` already exercise harder.

## The process each of these is built through

The request these games answer is to demonstrate the *development process*, not
only the system's features, so it is worth writing down what that process is
here. It is the same for every item below.

An interface goes in `module/`, as a `.m` file whose comments are the
documentation of record. The implementation goes in `appl/lib` and is compiled by
`mk`, never by calling `limbo` by hand, so the tree's own flags apply. Content —
art, levels, behaviour — goes in a little language, in files under `lib/`, so it
can be written and read by something other than the program. A `man/` page
describes it and is checked with `groff -man -Tutf8 -k -ww`. A test goes in
`appl/cmd/*test.b`, or in the program's own `-t`, and is not believed until it
has been seen to fail: the check is disabled, the failure is confirmed to return,
and the check is restored. What the test does *not* cover goes in BUGS. The
section `INDEX` is hand-curated. The commit stages explicit pathspecs, because
this tree holds other people's work in progress.

`camber` is the worked example, defects and all. Writing it turned up three real
bugs (below); two of its picture checks passed at first and were only made into
checks by the control that failed them — one of those was reading the wrong
sprites entirely, and the other was still passing with three of the four edges of
a cursor drawn.

## What to build, in order, and why

**All five are now built.** Each item names the Inferno axis it lands. An item that lands no axis the
existing eight already land is not on this list, however good a game it would be.

### 1. `camber` — shape 3 — content as data, authored by a tool

**Built.** See `camber(1)`, `lib/tiles/ridge.trk`, `lib/tiles/camber.chr`.

The axis is the development process itself. A track is a text file in a little
language; the game reads it at run time; the editor writes it; a shell script can
generate one; and the art is `lib/tiles/camber.chr`, loaded through `tiles(2)`'s
`sheet` command, not compiled in. Nothing about the course is in the Limbo. This
is the first game here of which that is true, and it is the reason it is first:
it turns `tiles(2)`'s command language from a facility into a thing that is used.

The genre carries its own justification for the editor — the design mode is the
feature the originals are remembered for — so the demonstration is not bolted on.

Writing it turned up three real defects, which is the argument for building these
things rather than describing them. Mud subtracted speed with no floor, so the
four-lane mud band stopped the machine dead and the course could not be finished
at all. A collision set the same eighty-frame timer on the player and on the
rival, so both recovered on the same frame in the same place and collided again
for ever. And `tiles(2)`'s `fontof` looked for a binding literally named `font`:
a font declared under any other name was silently not found, every surface took
the first tile sheet as its font instead, and `text` drew nothing at all with no
error anywhere. That last one is a library bug that had been sitting there since
the command language was written, and it took a second caller to find it.

### 2. `spire` — shape 2 — rooms as a namespace

**Built.** See `spire(1)`, `roomsrv(2)`, `lib/tiles/spire.doors`.

The doors are the point. A room is a *mount*: entering one binds a server onto
the game's namespace and the room's rules come from whatever is mounted there,
so a shop is a file server with a `wares` file and a `ctl` file, and buying is a
write. Add a room by writing a server and mounting it; the game needs no change
and no recompile. That is the namespace argument made in a form somebody can
play, and nothing else in this tree makes it as plainly.

It was built that way and the claim holds up: `spire -t` asserts the three
states that make it a claim rather than a decoration — `/n/room/wares` unreadable
before the door, readable *with the server's own name and stock* during, and
unreadable again after. The control is a door pointed at a program that does not
exist; it must refuse to open, and it does. There is deliberately no fallback
anywhere: a door that could show a shop without having mounted one would make the
mount decoration, and a test would pass on the decoration. Stubbing the mount out
and faking a shop fails eight assertions.

Two rooms ship, `spireshop` and `spirespring`, and nothing in the game
distinguishes them: both are named only in `lib/tiles/spire.doors`. Each is under
a hundred lines because `roomsrv(2)` does the serving and the contents are in a
file. Either can be mounted by hand from a shell — `mount {games/spireshop} /n/room`
— which is the same interface `styxlisten(1)` would present it over a network.

Building it turned up one bug worth the whole exercise. A server started down a
pipe must be given a file-descriptor group containing **only** its end of that
pipe. `FORKFD` copies the whole table, which still holds the *client* end, so the
server holds its own connection open, its read never reaches end of file, and its
process outlives every unmount — `mntgen` and both rooms were still in `ps` after
the game had exited, and `emu` would not exit either. The same goes for the name
space: a server sharing the one the mount lands in holds a reference to the mount
of itself. `NEWFD` plus a name space copied *before* the mount fixes both, and the
self test went from 90 seconds (killed by a timeout) to 0.23 seconds.

That trap is not specific to games, and the shell has it too: `mount {cmd} dir`
from `sh(1)` leaves the server running after the unmount for exactly this reason.

### 3. `tandem` — shape 4 — Styx across a machine boundary

**Built.** See `tandem(1)` and `tests/tandemnet.sh`.

Two players, one screen, one of them somewhere else. The design that makes the
point is that there is no host program and no client program: **the game is a file
server with no window and no keyboard, and every player is a client of it**,
including the local one. `tandem` with no arguments starts `tandem -serve` down a
pipe and mounts it; `tandem -j tcp!host!port` mounts a game on another machine.
From the mount onwards it is the same code, because mounting a pipe and mounting
a TCP connection are the same thing. `orchard` proved a game could serve a file
interface; this proves the interface is enough to *play* through.

The number to report was the cost of a frame over the mount, and it is **1278 µs**
— about 8% of the 60 Hz budget — with the two files a client touches every frame
held open. Opening them each frame instead costs **3083 µs**, 19%, because an
open-write-clunk is four Styx round trips where one would do. That is the single
most useful thing the measurement produced and it changed the client.

`tests/tandemnet.sh` runs the whole self test through `styxlisten(1)` on a TCP
port, so the claim is checked over a real connection and not only over a pipe.
The negative control is built into the test it runs: it ends by unmounting the
game and asserting the client can then read nothing. A client with a local copy
of anything would pass everything else and fail that.

Three real bugs came out of it, all of them in the *plumbing* rather than the
game:

- **`break` in an `alt` arm leaves the alt, not the loop** — again. The server's
  message loop never ended on a read error, so it outlived every client.
- A spawned ticker process outlives the server that spawned it and keeps `emu`
  alive after everything has exited. The clock is now not a process at all: the
  game catches up to the wall clock when somebody reads `state`, which also means
  a game nobody is reading burns nothing.
- The server ran its own clock *and* honoured `step`, so every assertion about
  exactly how far the game had moved was a race against it — intermittently, about
  one run in six. A client now writes `drive` to take the clock, and the test
  asserts the game then does *not* move on its own, which is what makes the rest
  of the frame assertions mean anything.

### 4. `bout` — shape 5 — behaviour as a little language

**Built.** See `bout(1)` and `lib/bouts/*.bout`.

The content of this genre is the opponents, and an opponent is a state machine.
Written as a script, read at start-up, an opponent becomes a file somebody can
write without touching the game — the `tk(2)` argument applied to conduct rather
than to layout. It pairs with `camber`: one demonstrates authored *levels*, this
one authored *conduct*, which is the part of a game usually hardest to get out of
the source.

The directory **is** the list. There is no table of opponents anywhere in
`bout.b`, and nothing in it knows the name, the rhythm or the tricks of any of
them: it reads `/lib/bouts` and fights whatever is there. The three that ship are
genuinely different from each other in a way that is entirely in the files —
`Ironhand` is slow and tells for a long time, `Willow` tells for barely long
enough and throws two high before a low, and `Crane` tells low and strikes high
once, early, and then never again.

The half that makes it a language rather than a config file is `bout -c FILE`,
which checks a file and reports `file:line` the way a compiler would. Every `goto`
and `hurt` is resolved against the states that exist, because a typo there is a
fighter that stops moving mid-bout, and that reads as the game being broken rather
than the file being wrong. `-t` asserts that thirteen kinds of wrong file are
refused *and* that a right one is accepted — the second half being the control
that stops a parser which rejects everything from passing.

The test also asserts each of the three can be beaten by reading the tells, and
none of them by standing still. Two of its own assertions were wrong first time
and both were instructive: a ratio of damage taken guarding right against guarding
wrong failed on `Crane`, because `Crane` lies about its tell on purpose — a test
should not be tuned around a feature — and "standing still loses" was false
because a bout begins out of reach, so standing still meant nothing landing at all.

### 5. `sprig` — shape 1 — one process per entity

**Built.** See `sprig(1)`. The measurement that cleared it is `procbench(1)`.

The obvious Inferno reading of "many small independent things descending at once"
is one Dis process each, communicating over channels. That reading might have been
wrong, since Dis execution in this emu is serialised rather than parallel, so the
plan said to measure before writing a game on the strength of it. Measured,
compiled, on an Apple M-series host:

| | channel round trip | spawn |
|---|---|---|
| compiled (`emu -c1`) | 0.03 µs | 13.56 µs |
| interpreted (`emu -c0`) | 0.07 µs | 7.29 µs |

Microseconds per entity per frame, compiled:

| entities | loop | procs | pool | procs/loop |
|---|---|---|---|---|
| 1 | 0.01 | 0.05 | 0.05 | 3.7× |
| 16 | 0.01 | 0.08 | 0.11 | 6.0× |
| 256 | 0.01 | 0.20 | 0.34 | 15.2× |

`pool` — every entity taking from one channel — is what a game actually has,
because `alt` cannot be written over an array of channels.

**The answer was that the shape is affordable.** Four to sixteen times a loop per
entity, charged on a number too small to matter: 256 entities as processes come to
about 54 µs a frame against 3 µs, out of the 16600 µs a sixtieth of a second
allows. So `sprig` was written that way, and the honest claim for it is that it
reads well, not that it runs fast. The one constraint the measurement imposed —
never spawn per entity per frame, at 7 to 14 µs a go — is why pests are spawned
once a wave. `sprig -b` reports the in-game cost, and a sixteen-pest wave is 2 µs
a frame.

(Spawning is *cheaper* interpreted than compiled, which is the opposite of
everything else measured. Not chased.)

The claim is tested rather than asserted: each pest's process increments its own
counter, and `-t` checks every counter equals the frame count and that the pests
moved. Doing the stepping in the driver instead — which would leave every other
assertion in the game passing — fails it.

### Not planned

Shape 6 (pointing device) is a real axis — `wmclient(2)` pointer input — but it
is a small one, and `spriteedit(1)` and the `wm` applications already drive the
pointer in anger. Shape 7's persistence is largely covered by `scorestore(2)` and
would be better demonstrated by `spire`'s mounted rooms than by a save file.
Shape 8 lands no axis that `strider` and `gorge` do not land harder.
