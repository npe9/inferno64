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

.B "Step 1.2 \(em retain and replay one subtree."
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
.B Gate:
the diag fires on an armv7 link with the deferral removed and the
distance forced, and does not fire with the deferral in. Then an armv7
kernel links and boots.
.B Unknown:
whether armv7 builds in this checkout at all. Establish that before
anything else, because it decides whether the gate is runnable or the
fix ships on inspection alone \(em and say which.
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
.B "Gate, and its limit."
Each loader, run with
.CW -v
on a real link, must exit 0 with no
.CW "%f%"
in the output. That is runnable for 5l and jl if their boards build
here; 6l and 8l need amd64 and 386 kernels, which may not. Where a
loader cannot be exercised, say the fix is by inspection and leave it
labelled that way rather than implying a gate that did not run.
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
.B "Fix to try:"
a bounds check against the heap's own arena before the write \(em two
compares, on a hot path, so measure the cost rather than assume it is
free.
.B "Positive control:"
inject a garbage declared-pointer word and confirm the check catches it,
because a validation that has never rejected anything has not been shown
to validate.
.B Caveat:
the broken-header evidence is on someone else's board. The libinterp
work and the control can be done under host emu with
.CW distrack
enabled; the confirmation that it reduces the header count cannot.
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
