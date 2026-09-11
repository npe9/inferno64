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

## What to build, in order, and why

Each item names the Inferno axis it lands. An item that lands no axis the
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

The doors are the point. A room is a *mount*: entering one binds a server onto
the game's namespace and the room's rules come from whatever is mounted there,
so a shop is a file server with a `wares` file and a `ctl` file, and buying is a
write. Add a room by writing a server and mounting it; the game needs no change
and no recompile. That is the namespace argument made in a form somebody can
play, and nothing else in this tree makes it as plainly.

The horizontal wrap is free — the level surface is already wider than the screen
and `view` already takes an origin — so the mechanical work is the vertical
camera and the doorways, and the interesting work is all in the mount.

### 3. `tandem` — shape 4 — Styx across a machine boundary

Two players, one screen, one of them somewhere else. The game exports a pad as a
file and the second player's `emu` mounts it — the same mechanism whether that is
another window on this host or another machine. `orchard` proved a game can serve
a file interface; this proves the interface is enough to *play* through, at
frame rate, which is a considerably stronger claim and one that can be measured:
the number to report is the added latency per frame over the mount.

### 4. `bout` — shape 5 — behaviour as a little language

The content of this genre is the opponents, and an opponent is a state machine.
Written as a script in a small language, read at start-up, an opponent becomes a
file somebody can write without touching the game — the `tk(2)` argument applied
to behaviour rather than to layout. It pairs with `camber`: one demonstrates
authored *levels*, this one authored *conduct*.

### 5. `sprig` — shape 1 — one process per entity, if the measurement allows

The obvious Inferno reading of "many small independent things descending at
once" is one Dis process each, communicating over channels, multiplexed with
`alt`. That reading may be wrong: Dis execution in this emu is serialised, not
parallel, so thirty processes and their channel traffic may cost strictly more
than a loop over an array and buy nothing but shape.

**This must be measured before the game is written, not after.** The measurement
is a channel round-trip and an N-process step against the equivalent loop, and
whichever way it comes out it is worth writing down. If processes lose, the
finding — *one Dis process per entity costs X µs, so this is a teaching shape and
not a performance one* — is a better artefact than the game would have been, and
the game gets written as a loop.

### Not planned

Shape 6 (pointing device) is a real axis — `wmclient(2)` pointer input — but it
is a small one, and `spriteedit(1)` and the `wm` applications already drive the
pointer in anger. Shape 7's persistence is largely covered by `scorestore(2)` and
would be better demonstrated by `spire`'s mounted rooms than by a save file.
Shape 8 lands no axis that `strider` and `gorge` do not land harder.
