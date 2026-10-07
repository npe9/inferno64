.TL
What is left: the render node, two loaders, and the collector
.AU
.PP
This plan exists because a day of work on the draw path fixed real bugs
and advanced the stated goal by nothing. The goal is a generalised,
modernised 3D infrastructure for Plan 9 and Inferno, with libtk in the
Pi 3B kernel as the vehicle. The kernel part is done and verified. The
part that would make it worth having is not started, and it is item 1.
.PP
Items are in the order they should be done, which is not the order of
their cost. Item 1 is the goal and is open-ended; items 2 to 4 are
bounded and known; item 5 is a decision rather than work.
.NH 1
What is already true, so nobody re-does it
.PP
libtk's render-node tree is in the Pi 3B kernel and renders there:
.CW tkscenetest
reports 46 ok 0 fail 1 skipped on silicon and 91 ok 0 fail 2 skipped
under QEMU, byte-identical to the direct path across every case. Steps 1
and 2 of
.CW doc/raspi3b-draw-plan.ms
are done and measured. Step 3 was measured and
.I retired:
the clean is 0.3 to 6.1% of wall for widget-shaped damage, which is
inside the 2.9% build-to-build spread, so it could not be validated end
to end even if it worked.
.PP
Also done and not to be revisited: both
.CW byteaddr
faults, the
.CW allocmemimage
sizing guard,
.CW u32addr ,
7l's literal pool splitting a jump table, 7l's
.CW -v
crash, and
.CW $Math
registration. Instruments that exist and have controls:
.CW ellipsetest ,
.CW tests/kencc-wideptr ,
.CW FRAMEPERLINE ,
and the raspi3b session's
.CW switchtab
and
.CW umulladd .
.NH 1
Item 1: the render node has no consumer, and that is the whole payoff
.PP
.CW libtk/scene.c
builds a
.CW TkScene
per run of node-capable widgets and
.CW tkwalkflush()
renders it and then calls
.CW tkscenefree()
two lines later. So the tree is a transient intermediate representation
that reproduces exactly what immediate mode already did \(em which is
why it is byte-identical, and why it currently earns nothing. A scene
graph pays for itself by being
.I retained:
diffed between frames, cached per subtree, or handed to a GPU. None of
those is possible while the tree's lifetime is one flush.
.PP
.B "The constraint that makes this a design change and not a tweak."
The walk's first invariant is that a
.CW TkScene*
is valid only until the next thing that paints into the window, because
.CW tkwalkflush()
frees it. That invariant exists because
.I direct
painters interleave with node-capable ones: a
.CW menu
separator is drawn by
.CW frame.c
and a
.CW text
widget's embedded window paints directly. Retention moves ownership of
the tree from the walk to the widget, which is precisely what the
invariant forbids today.
.PP
.B "Step 1.1 \(em find out whether retention is possible at all."
Separate rendering from freeing in
.CW tkwalkflush()
and see what breaks. This is a read and a small experiment, not a
feature: the question is how many widgets are purely node-capable, and
whether a retained tree can be bounded to a subtree that no direct
painter enters. If the answer is "almost none", item 1 stops here and
says so, and the GPU route below becomes the next candidate instead.
.PP
.B "1.1 IS ANSWERED, and it moves 1.2's target."
.CW "render types"
.CW ( libtk/scene.c ,
.CW inferno-rio
.CW 343e1635b )
counts, per widget type, how many times its draw ran and how many of
those joined a tree. Over
.CW tkscenetest 's
32 cases, 15 of the 17 types:
.DS
.CW
	frame 36 36    label 12 12     checkbutton 1 1  button 3 3
	menubutton 1 1 menu 2 2        separator 2 0    cascade 2 2
	listbox 4 4    scrollbar 2 2   text 2 2         canvas 4 0
	entry 4 4      radiobutton 1 1 scale 2 2
.R
.DE
.LP
Thirteen join.
.CW separator
does not, which is what the walk's invariants already said \(em
.CW frame.c
draws it. So the shared walk is very nearly all node-capable, and the
direct painter that breaks it is one widget.
.PP
.B "Confirmed in the kernel,"
which is where this has to be true: the same test under QEMU on the Pi
3B kernel gives
.CW "separator 2 0"
and
.CW "canvas 4 0"
with every other type joining, 91 ok 0 fail 2 skipped. The frame and
label counts differ (34 and 10 against 36 and 12) only because two
cases skip there.
.PP
.B "But canvas is the finding, and it is not a direct painter."
.CW tkdrawcanv()
calls
.CW tkwalkflush()
on entry, builds a
.I private
.CW TkScene
with
.CW tkscenenew() ,
renders it, and frees it at the end of the draw;
.CW tkcvsdirect()
renders, frees and recreates it mid-draw when an item needs the raw
image. So the canvas is its own island: it does not join the shared
walk, it owns a tree.
.PP
.B "That is the widget-owned tree 1.2 was going to invent,"
already working and already shipping byte-identical pixels. It also
shows how invariant 1 is satisfied rather than fought: flush the
enclosing walk on entry, and own what you build. Retention is then a
much smaller change than it looked \(em keep
.CW cd.sc
across draws instead of freeing it at the end, and rebuild it only when
the item list changed \(em and it is confined to one widget whose
correctness is already covered by twelve canvas cases.
.PP

.B "STEP 1.2 IS RETIRED, measured and not argued."
.CW "render items"
.CW ( inferno-rio
.CW d4b4695f2 )
counts canvas items whose draw method ran:
.DS
.CW
	unchanged repaint               0 items walked
	20 spread items, change one     1 at the edge, 1 in the middle
.R
.DE
.LP
.CW tkdrawcanv()
already keeps its pixels in
.CW c->image ,
guards the item loop with the dirty region, and culls per item with
.CW rectXrect(i->p.bb,
.CW r) .
So a clean canvas walks no items and a dirty one walks only those whose
box meets the damage. A retained scene's caching is strictly coarser
than what is already there, so there is nothing for it to save. Same
shape as step 3's retirement: the term it would reduce is already near
zero.
.PP
An intermediate reading of "one item changed, two walked" looked like
over-collection and was two items close enough that both boxes met one
damage rectangle. Twenty spread items separated arrangement from
scaling; one number could not have.
.PP
.B "AND THE GPU ROUTE DOES NOT EXIST ON THE TARGET."
Checked before planning any of it:
.CW os/inferno/port/devdraw.c
has
.I zero
.CW gpuimagealloc
or
.CW gpudrawdamage
hooks \(em those are emu-only \(em and the board's one acceleration
seam,
.CW hwdraw()
in
.CW screenbcm.c:498 ,
is a stub that
.CW "USED(par); return 0;" ,
with
.CW ishwimage()
returning 0 beside it. There is no hardware draw path on the Pi 3B to
hand a tree to.
.PP
So both of item 1's routes are closed for the stated target: the
CPU-side caching route by measurement, and the GPU route by there being
nothing there. The emu Metal path is real but host-only, and the goal
says drawing to the framebuffer is fine, so speed on this board was
never the point.
.PP
.B "What that leaves, and it is a choice rather than a next step."
The tree IS the modernised infrastructure, it is in the kernel, and 13
of 15 widget types already emit it \(em so "generalised" is nearly
satisfied already. What is missing is a consumer, and the candidates
that are framebuffer-compatible and on-goal are:
.IP \(bu
.B "Expose the tree."
Let a Limbo program obtain a widget's node tree, so consumers \(em
recording, remote rendering, a 3D backend \(em can be written outside
libtk. This reads the goal as being about the API rather than about any
one consumer, and is the only candidate that makes the existing work
infrastructure rather than an internal detail.
.IP \(bu
.B "Resolution independence."
Render a tree at a scale, which pixels cannot do. Framebuffer
compatible, and the one capability a description genuinely has over a
raster on this hardware.
.IP \(bu
.B "Finish the breadth."
.CW separator
is the one type that does not emit, and
.CW canvas
is an island with its own tree. Closing those two makes emission total.
Cheap, and worth nothing on its own until a consumer exists.
.PP
Nothing here is started. Item 1 is at a decision, and the next
.I work
in this plan is item 2.
.PP
.B "Superseded: the GPU route as this plan first named it."
which this plan already named as the alternative and told itself not to
start in parallel. The CPU-side caching route is closed on measurement:
retention is possible (canvas proves it) and buys nothing (canvas also
proves it). What a retained tree could still earn is what the pixels
cannot do \(em feed a backend that wants geometry rather than a raster,
which is
.CW gpu (2)
and
.CW draw3d .
.PP
.B "Superseded: step 1.2 as written."
For a widget whose subtree is purely node-capable, keep its tree across
frames and replay it when nothing in that widget changed, instead of
re-running the widget's draw code. That is the smallest capability
immediate mode structurally cannot have.
.PP
.B "Gate, with its negative control, because the obvious gate measures
.B "nothing."
A replayed tree must be byte-identical to a freshly built one \(em
.CW tkscenetest
already has that harness and already compares two paths pixel for pixel.
.B "And a widget that HAS changed must NOT replay:"
without that arm the gate passes trivially for a replay cache that is
never invalidated, which is the same shape as a count that cannot fail.
Report both arms or neither.
.PP
.B Unknown,
and it decides whether 1.2 is worth writing: how much of a real Tk
window is node-capable. Nobody has counted. Count it in 1.1 before
building anything.
.PP
.B "The alternative if retention is impossible:"
hand the tree to the GPU rather than caching it. This tree already has
real Metal compute and a vertex path
.CW ( gpu (2),
.CW draw3d ),
so a node tree is the natural input to it, and that is the form the
"generalised 3D infrastructure" takes if the CPU-side caching does not
survive 1.1. Do not start both.
.NH 1
Item 2: 5l splits jump tables the same way 7l did
.PP
Confirmed structurally rather than assumed.
.CW utils/5l/span.c:61
is
.DS
.CW
	c += m;
	if(blitrl)
		checkpool(p);
.R
.DE
.LP
with the same
.CW flushpool
that splices a branch and the pool in after whatever
.CW p
happens to be, and the same
.CW "BUG: should refer back to values until out-of-range"
comment at line 184. 5l has
.CW ABCASE
and no guard on it, so a jump table long enough to straddle a pool flush
is cut exactly as conswrite's was.
.PP
.CW mkfiles/mkfile-Inferno-arm
sets
.CW "LD= 5l" ,
and
.CW os/inferno/armv7
is the one live board on
.CW OBJTYPE=arm .
So this is one board, not none, and the bug is latent rather than
observed \(em no armv7 panic has been attributed to it.
.PP
.B Steps:
port 7l's deferral (skip the forced flush while inside a CASE run, with
the lookahead that still allows a flush after the last entry) and port
the
.CW diag
for an illegal flush point.
.B "Positive control first,"
by the route that worked and not the one that did not: force the
.I distance
check, not the pool
.I size
threshold. Shrinking the size threshold makes pools flush early, empties
the pending pool before any table, and makes the bug
.I less
likely \(em it looked like a control and was the opposite.
.PP
.B "DONE as"
.CW c64838f39 ,
.B "and the gate did NOT run \(em saying which, as this section asked."
The deferral and the diag are in, 5l builds with no new warnings, and
the output of every link that could be produced here is
.B byte-identical
with and without the fix. That is a no-regression result and it is also
why the control cannot fire: the fix is inert wherever no flush falls in
a table.
.PP
.B "The positive control did not fire."
Tried: a generated function with pool constants pinned early and a
filler sweep of 340 to 480 statements, to walk the table across the
flush point; 23 real
.CW libmemdraw
files compiled for arm32 and linked individually; and the whole set
together. Zero firings. And the armv7 kernel cannot be linked in this
checkout \(em it wants a
.CW dis32
tree that does not exist here \(em so the one real arm32 link is
untested. So this ships on structural identity plus the diag, and not on
a demonstrated reproduction.
.PP
.B "The identity is the evidence, and it is specific."
.CW span.c:61
is the same forced flush,
.CW flushpool()
the same splice with the same
.CW "BUG: should refer back to values"
comment,
.CW optab.c:212
sizes
.CW ABCASE
at 4 so pcs advance through the table, and
.CW asm.c:1226
is
.CW "MOVW R<<2(PC),PC"
\(em the dispatch LOADS its target out of the table, and case 63 stores
an
.I absolute
pc, so a spliced pool word is jumped to directly rather than added as an
offset. Worse than 7l's, where it was at least an offset.
.PP
.B "And one control attempt was wrong in the familiar direction:"
shrinking the distance window to 0x40 found nothing, because more
frequent flushes EMPTY the pool before any table and make the bug less
likely. Same error as 7l's pool-size attempt. The condition needs a pool
entry to SURVIVE until the table, which is why a bigger program, not a
tighter window, is the way to look for it.
.NH 1
Item 3: every loader's -v flag has the same varargs crash
.PP
.CW listinit()
installs a handful of verbs and never
.CW 'f' ,
so
.CW "%5.2f"
prints literally
.I and
the double is never consumed from the varargs. Where a
.CW "%s"
follows, it reads part of a double as a
.CW char* :
.CW <nil>
when the misread word is zero, a segfault when it is not. Fixed in 7l by
formatting the time into a string once and passing it with
.CW %s .
.PP
The same
.CW "%5.2f"
followed by
.CW "%s"
exists in 5l, 6l, 8l, 0l and jl, four or five sites each. It is
mechanical: the same
.CW cputimestr()
helper per loader, every site converted, because the cosmetic
.CW "%f%"
and the fatal read are one defect and leaving the harmless ones invites
a re-find.
.PP
.B "DONE as"
.CW 5f28ab08a ,
.B "and unlike item 2 the gate RAN \(em for all five."
A self-contained probe compiled with each loader's own compiler and
linked with
.CW -v :
.DS
.CW
	            link   %f%   the ldobj line
	fixed         0      0   "0.00 ldobj: t.6"
	unfixed 6l    0     16   "%f% ldobj: <nil>"
.R
.DE
.LP
The
.CW <nil>
is the misalignment showing through \(em
.CW %s
consumed the double's bits instead of the filename pointer. Exit 0 on so
small a link because the misread word happened to be zero every time,
which is why 7l segfaulted on a kernel link and this does not: more
library lines, more chances the word is a non-zero garbage pointer.
.PP
.B "And the site was checked, not just the exit status."
Each
.CW -v
output contains its own
.CW "ldobj:"
line, so the format that crashes is the one being printed. Exit 0 from a
run that never reached the site would have proved nothing.
.PP
No warnings added, measured by stashing the change and rebuilding: 5,
14, 14, 6, 7 per loader before and after. And the self-recursion 7l's
mechanical pass caused was avoided by ORDERING \(em replace the call
sites first, insert the helper second, so the helper's own call is never
rewritten.
.PP
.B "And watch the mechanical pass."
Rewriting
.CW cputime()
to
.CW cputimestr()
across a loader will also rewrite it inside the helper being added, so
the helper calls itself; the build accepts infinite recursion in
silence. That happened in 7l and was caught by reading the file, not by
compiling it.
.NH 1
Item 4: markheap writes through unvalidated pointers
.PP
.CW libinterp/gc.c 's
.CW markheap()
walks a type's pointer map and, for every declared-pointer word that is
not
.CW H ,
writes
.CW h->color
through it with no check that the word is a heap pointer. A single
garbage word therefore writes into an unrelated live object, with
.I no
.I fault
.I at
.I the
.I write ,
so the damage appears later as a structure wrong in a way its own code
cannot account for. The only guard,
.CW checkmarkptr() ,
is gated behind
.CW distrack ,
which is 0 on raspi3b.
.PP
It is not a theory: that board reports 38 to 56 broken GC block headers
per boot, and 38 still appeared on a kernel carrying the
.CW "IC IALLUIS"
fix, which killed the prediction that they were a consequence of the
stale-instruction bug.
.PP
.B "DONE as"
.CW 4613599c7 ,
.B "and it CONTAINS rather than fixes."
A bounds check against the heap's arena is not available \(em the heap
is pool-allocated across several arenas, not one range. But
.CW color
is cheaper and better: its whole domain is 0..3, since
.CW mutator ,
.CW marker
and
.CW sweeper
are
.CW gccolor%3
and
.CW propagator
is 3, and all three allocation paths in
.CW heap.c
set it immediately after
.CW poolalloc ,
before the object can escape. So one unsigned compare rejects a garbage
word and can NEVER reject a real heap object \(em which is the direction
that matters, because a false negative would leave a live object
unmarked and free it underneath its owner.
.PP
.B "And the existing guard was not one."
.CW checkmarkptr()
on the raspi3b branch is board bring-up instrumentation that ends in
.CW abort() ,
disabled behind
.CW distrack
because it fires on a hosted emu within a second of a shell starting.
It is a probe with false positives, not a validation, so there was
nothing to enable.
.PP
.B "Why containment is the honest word."
.CW initmem()
sets every declared-pointer slot to
.CW H ,
so a garbage word in one is always the consequence of an earlier
corruption. Skipping it does not repair that; it stops one bad word
scribbling an unrelated live object, and counts it where it is
detectable instead of where it surfaces.
.PP
.B "Controls, both run:"
.CW tkscenetest ,
.CW ellipsetest
and
.CW "gfxstress all"
fire it zero times, so it has no false positives on healthy work; and
with the threshold inverted to reject everything the print fires, the
skip path runs, and
.CW ellipsetest
stops completing \(em which is what marking nothing should do. The count
is a variable so a board can be read over JTAG, with the print bounded
to one line a boot.
.PP
.B Caveat,
unchanged: the 38 to 56 broken GC block headers a boot are on the
raspi3b session's hardware and are not reproduced here, and the Pi
kernel with this in boots with zero firings. So what is claimed is a
container and a detector, not a diagnosis of those headers.
.NH 1
Item 5: where this work should live, which is a decision and not a task
.PP
Nothing is merged to main.
.CW rio-pi-tk
is 1716 commits ahead of it,
.CW inferno-rio
1005,
.CW raspi3b-port
1985, and all three are 113 behind. The aarch64 loader fixes are
committed on
.CW rio-pi-tk ;
.CW raspi3b-port
has taken the pool fix and not yet the
.CW -v
one, which is theirs to cherry-pick and has been offered.
.PP
This is a repository-structure question, as
.CW doc/raspi3b-draw-plan.ms
already said of the libtk integration, and the answer is the user's. The
facts above are what the decision needs; the plan does not presume it.
Items 1 to 4 do not depend on it.
.NH 1
What this plan deliberately leaves out
.PP
Step 3 of the draw plan, which is measured and retired, not deferred.
The peer's cherry-pick, which is theirs. The kernel-versus-emu builtin
registration mechanism, which is understood for emu and
.I unverified
for the kernel and should stay labelled so rather than become a
plausible fix. And whatever makes
.CW wm/colors ,
.CW wm/calendar
and
.CW wm/about
draw once and idle without reaching a per-frame instrument, which is why
the bimodality in
.CW FRAMEPERLINE
rests on two clients and is flagged as such.
