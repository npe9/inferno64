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
.B "DONE, and the population above was two types short."
.CW panel
and
.CW choicebutton
never appeared in it at all, so the test had no opinion on two of the
seventeen; both are now cases, and the reading is
.CW "panel 1 0"
and
.CW "choicebutton 1 1" .
.CW separator
joined nothing because the gate in
.CW tkdrawframe()
named
.CW TKframe
alone \(em a separator
.I is
drawn by that function, so widening the condition was the first half of
the fix. The second half is the interesting one: a separator also draws
two one\-pixel rules with direct
.CW draw()
calls, and once the fill was a node those ran first and the flush
painted over them. 498 bytes differed in the posted menu, which is the
whole of a separator's ink. Emitting the rules as nodes too makes a
separator entirely a scene. It now reads
.CW "separator 2 2"
with the menu byte\-identical between the paths, 101 ok 0 fail under
both execution paths.
.PP
.B "Confirmed in the kernel,"
which is where this has to be true. Before the fix the same test under
QEMU on the Pi 3B kernel gave
.CW "separator 2 0"
and
.CW "canvas 4 0"
with every other type joining, 91 ok 0 fail 2 skipped. After it, with
the kernel relinked and the image rebuilt:
.IP
.EX
separator 2 2    canvas 4 0    panel 1 0    choicebutton 1 1
tkscenetest: 95 ok, 0 fail, 2 skipped
.EE
.LP
All seventeen types in the population on the board's own kernel, not
only hosted. The two skips are the kernel root having no
.CW /fonts/pelm/latin1.9.font
and no
.CW audio.bit ,
which is a root contents question and not a renderer one. The frame and
label counts differ from the hosted run (36 and 10 against 38 and 12)
only because those two cases skip here.
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
.B "Expose the tree. DONE."
A Limbo program can obtain a widget's node tree, so consumers \(em
recording, remote rendering, a 3D backend \(em can be written outside
libtk. This reads the goal as being about the API rather than about any
one consumer, and it was the only candidate that makes the existing
work infrastructure rather than an internal detail.
.PP
.CW "render record 1"
makes the walk serialise each tree it renders,
.CW "render tree"
hands back the last one, and
.CW tknode (2)
decodes it into an array of
.CW Node .
Off by default: it costs a serialisation on the path every repaint
takes and nothing in a running system reads it.
.PP
Text, one node per line, because the first consumers are recording and
inspection and both want to be readable, and because a string is what a
Limbo program can get out of a Tk command. A backend that wants the
nodes without the parse is a different interface and this does not
pretend to be it.
.PP
.B "Taken at FLUSH time, not kept as nodes."
The nodes the renderer walks are stack copies whose
.CW pts
points into a stack array \(em see
.CW scalenode() \(em
so a kept
.CW TkNode*
would outlive the scene that owns its strings and its points. A kept
string owns itself.
.PP
.B "Verified positionally, not by round trip."
Decoding a dump and encoding it again passes for a decoder that stored
the line verbatim, which is the same shape as the identity transform
that passed while
.CW TkNtransform
did nothing. So the checks assert field values at known places in a
known fixture \(em a raised frame, borderwidth 2:
.IP
.EX
4 nodes: roundfill colour roundfill border
the border's box  (58,0)\-(102,24), radius 5, width 2
its number        Tborder, 3
its rgba          2425392895
.EE
.LP
That last line was not decoration. On the Pi 3B kernel it read
.CW 2147483647
\(em a saturation, not a wrap \(em because
.CW "int s"
in Limbo went through
.CW strtol() ,
whose kencc
.CW long
is 32 bits, so every value above 2\u31\d\-1 was pinned to
.CW LONG_MAX
as
.CW libkern/strtol.c
defines it. Fixed with
.CW strtoll() ,
and
.CW cvttest (1)
now gives the conversion family a test of its own \(em 17 ok 0 fail on
both. A defect in the one instruction a Limbo program uses to read a
number was found by a graphics test, on a different machine, because
nothing in the conversion family had a test at all.
.LP
and three more fixtures for what that one cannot reach: a label for the
two quoted strings, with a space in its text; a selected checkbutton
for the only node in the flat style carrying points; and
.CW "render record 0"
for whether the answer after it is empty rather than stale.
.PP
.B "The name table has two guards and both were controlled."
Plan 9 C has no designated initialisers, so the names in
.CW scene.c
are positional against the enum and can drift. A nameless type dumps
.CW unknown\-N ;
a wrong\-length table emits one
.CW tablemismatch
line. Lengthening the table by one entry fires the second and, because
the diagnostic is the dump's first line, poisons the whole decode \(em
the right failure, since a drifted table should make a dump unusable
rather than subtly wrong. Dropping the
.CW radius
field makes the decoder answer
.CW "14 fields, want at least 15"
instead of reading the points out of the width.
.PP
.B "What is NOT shown, and it is the next thing here."
There is no encoder, so nothing proves a decoded tree is
.I sufficient
to reproduce the picture \(em only that every field survives the trip.
Reproducing it means a consumer that rasterises the primitive subset,
and that is reachable: every renderer case is
.CW draw() ,
.CW ellipse() ,
.CW fillpoly()
or
.CW bezspline() ,
and the three composite kinds
.CW ( TkNroundfill ,
.CW TkNcorners ,
.CW TkNborder )
are solid rectangles and a per\-row corner cut. None of it needs
anything a Limbo program cannot reach.
.IP \(bu
.B "Resolution independence. DONE."
Render a tree at a scale, which pixels cannot do \(em the one capability
a description genuinely has over a raster on this hardware, and
framebuffer compatible.
.CW tkscenerenderscaled()
takes the scale as
.CW num/den ,
integer with rounding and no floating point, because a renderer that
has to work in a kernel should not want an FPU. Driven by
.CW "render scaled" ,
and the figures are the same on the host and on the board:
.IP
.EX
scale 1:1              1 1 nodes 0 approx 0
a raised frame at 2:1  2 1 nodes 4 approx 0
a label at 2:1         2 1 nodes 4 approx 1
.EE
.LP
Geometry scales
.I exactly .
The two kinds that cannot are counted rather than hidden:
.CW TkNglyphs
names a font file whose size is in its name, and
.CW TkNtexture
goes through
.CW draw() ,
which replicates rather than resamples. So
.CW "approx 0"
is worth something because
.CW "approx 1"
is demonstrated beside it. Pi 3B kernel: 100 ok 0 fail 2 skipped, the
two skips being a font file and a bitmap absent from the kernel root.
.PP
.B "And the scale generalised to a node."
.CW TkNtransform
was declared in the vocabulary and emitted by nothing. It is bracketed
now, by a
.CW TkNtransformend
appended at the end of the enum rather than beside its opener, and
.CW "render xform"
wraps each tree in one. Translate and uniform scale only: a rotation
maps a rectangle to something that is not one, and this renderer draws
fills, borders and glyph runs as rectangles, so supporting it would
mean resampling \(em the thing a description exists to avoid.
.PP
The two paths are each other's control, which is the point of having
both:
.IP
.EX
a transform of 2 == a global scale of 2   0 bytes differ
a transform of 1 is the identity          0 differ
.EE
.LP
Byte\-identical on the host and on the Pi 3B kernel. That comparison
earned itself on its first run: the transform node was appended like
every other, so it arrived AFTER the span it was meant to bracket and
did nothing, and the picture came back identical to the untransformed
one. The identity case could not have found it \(em an identity that
never opens looks exactly like an identity that does \(em and only a
comparison against an independent implementation of the same
arithmetic could.
.PP
.B "And the third kind: opacity."
.CW tk.h
names clip, transform and opacity as the three that make animation cost
nothing to rasterise.
.CW TkNopacity
is the last of them and the only one that needs a surface:
.CW TkNclip
narrows a clipping rectangle and
.CW TkNtransform
changes arithmetic, but compositing a span at an alpha means having the
span somewhere before it lands. So the span renders into a surface that
starts as a
.B copy
of the destination and the close composites that whole surface back
through a constant\-alpha mask \(em which gives the right answer for the
span over what was beneath it without a per\-pixel path, and reuses the
1x1 replicated image
.CW tkcolor()
already caches.
.PP
.CW "render opacity A"
drives it.
.CW 255
emits no node at all, because an opacity that changes nothing should
not cost a surface, so the identity case here is weaker than the
transform's and the checks beside it are quantitative:
.IP
.EX
opacity 255   byte\-identical to no opacity at all
opacity 0     0 bytes inked
opacity 128   272256 of 525088, wanted 263573 +\-13178
.EE
.LP
The same three figures on the host and on the Pi 3B kernel \(em
.CW "272256 of 525088"
on both, not merely both within tolerance \(em which is what it should
be, since the two share
.CW libtk/scene.c
and
.I libmemdraw
and differ only in the compiler. 115 ok 0 fail hosted, 109 ok 0 fail 2
skipped on the kernel, the skips being a font file and a bitmap absent
from the kernel root.
.PP
The third line is
.B ink
\(em the summed distance of every channel from white, not inked
.B pixels ,
because a half\-transparent picture touches the same pixels. Forcing the
mask's alpha to 192 instead of the node's gave 394208 of 525088, which
is 0.751, which is 192/255 to three figures: the ink is
.B linear
in the alpha, so the figure above is the compositing arithmetic and not
a coincidence.
.PP
The alpha\-0 check is weaker than it reads, and the control said so:
with the composite deleted outright it still
.B passes ,
because a span drawn into a surface nobody blits back also leaves a
blank page. It is evidence the span was
.B diverted
and none at all that anything was composited. Written beside the check
rather than left to read stronger than it is.
.PP
What this does not do yet is nest. A clip, a layer and an opacity each
occupy one slot in a flat list and each refuses to open inside the
others that would put it in the wrong coordinates \(em the same
limitation the clip has had since it was added, and the same choice to
keep one renderer rather than grow a second.
.PP
What a size\-selection step would need, if text at a scale is wanted:
the node holds a face
.I name
and the families here ship discrete sizes
.CW ( ascii.10.font ,
.CW ascii.12.font ,
.CW ascii.16.font ),
so a scaled render would pick the nearest available size rather than
scale a bitmap. That is a substitution, not an interpolation, and it is
the next thing in this item rather than a thing in its way.
.IP \(bu
.B "Finish the breadth. DONE for separator; the other two are by design."
.CW separator
now emits. The two that still join nothing are not omissions:
.CW canvas
builds its own scene per draw and frees it, and
.CW panel
is the one widget whose content is the application's own live image via
.CW putimage ,
which
.CW TkNtexture
cannot name because it holds a
.I file
\(em the very property that lets a tree outlive the repaint that built
it. A panel cannot enter a serialisable tree without giving that up. A
GPU backend would want a texture
.I handle
here rather than a path, and that is the one place the node vocabulary
needs extending for the 3D story rather than for Tk.
.PP
Item 1 is now done on all three halves \(em breadth, resolution
independence, and exposing the tree \(em and each one's finding is
recorded above. The next
.I work
in this plan is item 2, and the next work in
.I this
one is a Limbo consumer that rasterises what it decodes, which is the
only thing that can show the exposed tree is sufficient rather than
merely complete.
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
.B "SUPERSEDED: the control DID fire, on cloud-port's armv7."
That checkout has a
.CW dis32
tree, so
.CW armv7
links there where it will not here. With the deferral off and the
distance forced,
.B five
illegal flushes \(em
.CW icmpiput6 ,
.CW conswrite ,
.CW progwrite
among them \(em zero at normal distance, zero with the fix, and output
byte-identical to the same link with the deferral switched off. A
complete pair on a live kernel, which is better evidence than 7l's (one
function on one board). So
.CW c64838f39
is
.I measured ,
not inspected, and the measurement is theirs.
.PP
.B "And conswrite appears on both linkers,"
which is worth keeping: a 29-slot sparse switch with enough literals
around it that the pool is reliably pending when the table is laid out.
It is the function to reach for if this class ever needs a reproducer
again.
.PP
.B "What follows is the record as it stood before that, kept because the
.B "reasoning is what made the fix shippable without it."
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
.B "THE BROKEN HEADERS ARE SOLVED, and they were not corruption at all."
The raspi3b session found it:
.CW poolfree()
coalesces a free block and the merge zeroes the swallowed header's
magic, so gc.c's incremental sweep cursor \(em
.CW "Bhdr* ptr" ,
a global at
.CW gc.c:45
precisely because a merge can swallow what it points at \(em is left
pointing at a dead header, and the next
.CW rungc()
fails
.CW okbhdr()
and abandons the sweep. Upstream fixes the cursor up in
.CW poolfree() ,
and
.I this
.I kernel's
.I copy
.I has
.I those
.I lines
.I commented
.I out .
With the fixup on, broken chains go 17 and 12 to
.B 0 .
So a "break" was a wasted re-sweep, not damage.
.PP
.B "Which means this guard found nothing because there was nothing to find,"
and that is the branch predicted when it was written: zero firings with
headers still appearing says the corruption does not reach markheap, and
here it says there was no corruption. The guard is still worth having
and that session kept it, because it is a different tier from theirs \(em
.CW gcbadptr
tests the WORD (aligned, above 0x1000) and this tests what the word
POINTS AT, which is the tier their plan had recorded as undetectable by
construction. With both at zero, "no corruption reaches markheap" is a
measurement rather than an absence of evidence.
.PP
.B "The same lines are commented out on THIS branch,"
verified rather than assumed:
.CW os/inferno/port/alloc.c:672
and
.CW 682
hold the two fixups and
.CW 646
the
.CW extern ,
all three commented, while
.CW "Bhdr* ptr"
is a live global at
.CW libinterp/gc.c:45
\(em so uncommenting the three lines is sufficient and would link.
.CW emu/port/alloc.c:707-718
.I has
the fixup, which is why the symptom is board-only.
.B "That file is in"
.CW os/
.B "and is not ours to change;"
it is recorded here so whoever owns it has the line numbers and knows
the symbol resolves.
.PP
.B "AND ELEVEN OF TWELVE WORKTREES HAVE THE DEFECT."
Surveyed comment-aware, because comment state is not line-local and the
live fix carries an extra condition
.CW ( "if(p == heapmem && c == ptr)" ):
.DS
.CW
	raspi3b-port                                   FIXED
	cloud-port genesize inferno-bt inferno-ports
	jit-research multicore nixos parallelgc
	pr-bluetooth rio-pi-tk xip                     DEFECT
.R
.DE
.LP
Two of those \(em
.CW jit-research
and
.CW parallelgc
\(em the raspi3b session's own survey had missed.
.CW parallelgc
is the one to note beside
.CW multicore :
a branch whose subject is the garbage collector, missing the fixup that
keeps the collector's own sweep cursor valid across a free. And
.CW multicore
runs
.CW parallelvm=1
by default, so a second context freeing concurrently WIDENS the window
in which a free can swallow the cursor between quanta.
.PP
.B "Two of the eleven are OUTSIDE git and cannot be fixed by a merge."
.CW jit-research
and
.CW parallelgc
are sibling directories holding the whole tree with no
.CW .git
at all \(em 38 registered worktrees against 40 directories \(em so
.CW "git worktree list"
cannot see them, which is why a survey of registered worktrees reported
ten and a survey of copies reports twelve. A correct test over the wrong
population.
.PP
.B "And"
.CW parallelgc
.B "is live work, not a stale snapshot:"
its newest source file is from
.I today ,
while
.CW multicore 's
is from four weeks ago. So the directory with the oldest source is the
registered worktree and the newest is the unmanaged copy. A cherry-pick
cannot reach it; whoever works there has to be told, or no fix landing
on any branch will ever arrive.
.PP
.B "The survey's control is what makes it worth quoting."
The first version of this check reported 0/2 for all twelve
.I including
.CW raspi3b-port ,
which is fixed \(em confidently and uniformly wrong, and a uniform clean
result is the dangerous kind. Before trusting a survey over N cases,
make it classify the one case whose answer is already known; if it
cannot, the other N\(mi1 are noise that looks like a result. And check
that the population is the one the question is about \(em four wrong
classifiers between two sessions were each uniform across all twelve,
so uniformity is the cheapest tell available and belongs first rather
than last.
.PP
.B "One more, from getting the staleness wrong twice in two commands:"
when a measurement filters and then aggregates, check the filter runs
AFTER the aggregation or not at all.
.CW head
before
.CW sort
is not a sample, it is whatever the filesystem walked first \(em the same
shape as a
.CW "grep -c"
before a comment strip, and it produces a confident uniform wrong answer
the same way.
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
The loader fixes have the same spread, and who was told
.PP
The same survey question applied to
.CW utils/ ,
which unlike
.CW os/
is ours: twelve copies of the tree carry a
.CW utils/7l ,
and only this one carries both its fixes.
.CW raspi3b-port
has the pool fix and not the
.CW -v
one, which matches what that session cherry-picked.
.CW 5l
is more widely present and fixed only here.
.PP
.B "Reported over the population that matters, not the total."
Seventy-three defect markers across twenty-odd copies is the wrong
number: most are dormant. Four of the defective copies have a live
session \(em
.CW multicore ,
.CW genesize ,
.CW xip
and
.CW cloud-port
\(em and each builds aarch64 boards, so the pool bug is live for all
four. They were told, with the 7l fix labelled demonstrated and the 5l
fix labelled structural-identity-only, because those deserve different
confidence.
.CW multicore
was told by both sessions, so its copy of the
.CW alloc.c
finding is one result relayed twice and not two confirmations.
.PP
.B "Nothing was committed to another branch."
.CW utils/
is ours by file ownership but a branch someone is working in is not, so
these are notifications rather than cherry-picks. The two unmanaged
copies \(em
.CW jit-research
and
.CW parallelgc
\(em have no
.CW .git
and no session, so they are reachable by neither a merge nor a message,
and
.CW parallelgc
was editing
.CW libinterp
the morning this was written.
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
