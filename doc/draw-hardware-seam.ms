.TL
The hardware seam in Inferno's draw path
.AU
.PP
Inferno's rasteriser has two places where something other than portable C
can take over a draw.  They look alike and are not alike, and the
difference decides where a board's acceleration has to go.  This note
records what they are, who supplies them today, and why the Raspberry
Pi 3B's cost does not sit in either of them.  It is written because the
seam already exists and is shared by
.I emu
and every native kernel: a board that wants hardware draw does not need a
new interface, it needs to fill in this one.
.NH 1
Two seams, one of which is not an acceleration hook
.PP
.CW hwdraw(Memdrawparam*)
is the real one.  It is declared in
.CW include/memdraw.h ,
defaulted in
.CW libmemdraw/hwdraw.c
to
.CW "return 0; /* could not satisfy request */" ,
and called from
.CW libmemdraw/draw.c:187 ,
.I before
any of the software paths, under a comment that says exactly what it is
for: "Each video driver provides this function, which checks to see if
there is anything it can help with."  Returning non-zero means the draw
is done and
.CW memimagedraw
returns immediately.  The parameter block carries
.CW dst ,
.CW r ,
.CW src ,
.CW sr ,
.CW mask
and
.CW mr ,
plus a
.CW state
word of
.CW Simplesrc ,
.CW Simplemask
and
.CW Fullmask
flags and a resolved source pixel
.CW sdval .
.PP
.CW memdrawcopybegin
and
.CW memdrawcopy ,
defined as nullable function pointers in
.CW libmemdraw/drawcopy.c ,
are not an acceleration hook, and the resemblance is a trap this note
exists partly to defuse.  They are called at
.CW libmemdraw/draw.c:2104-2121 ,
.I after
the
.CW memmove
that does the work.  Nothing they do can change the pixels or skip the
copy.  They are damage notification: a backend learns which rectangle
just changed.  The one registration in the tree is
.CW emu/MacOSX/win-cocoa.m ,
which uses it to mark tiles for upload to the Metal texture.
.PP
The comment in
.CW drawcopy.c
explains why these two pointers live in their own file rather than beside
.CW hwdraw :
so that "a kernel with its own hwdraw does not drag the default one in
behind them."  That sentence anticipates a board supplying
.CW hwdraw ,
and is the clearest statement in the tree that the seam is meant to be
filled.
.NH 1
Who supplies them now
.PP
Every native board already links its own
.CW hwdraw ,
which replaces
.CW libmemdraw/hwdraw.c
at link time rather than overriding it at run time \(em there is no
registration call and no way to have both.  So the seam is not empty; it
is occupied, mostly by stubs.
.IP \(bu
.CW os/inferno/raspi3b/screenbcm.c:498
returns 0 with a comment explaining that the overlay cursor means there
is nothing to avoid.  Likewise
.CW raspi4 ,
.CW virt ,
.CW virts ,
.CW virt32 ,
.CW virt32s ,
.CW virtarm64
and
.CW shakti .
.IP \(bu
.CW os/inferno/pc64/screen.c:496
is the only native
.CW hwdraw
in the tree that accelerates anything, and it is the worked example
anyone filling this seam should read first.
.LP
Only
.CW emu/MacOSX/win-cocoa.m
registers
.CW memdrawcopy .
No native kernel does.
.NH 1
What pc64 does, and the clause that matters
.PP
pc64's
.CW hwdraw
does two separate jobs.  Unconditionally, if the soft cursor is in use, it
calls
.CW swcursoravoid
on whichever of
.CW r ,
.CW sr
and
.CW mr
touch the screen data \(em that is correctness, not speed, and it happens
before any acceleration decision.  Then:
.DS
.CW
if(!hwaccel || scr->softscreen || scr->tilt)
	return 0;
.R
.DE
.LP
and past that guard, two cases.  A solid fill, recognised as
.CW Simplesrc|Simplemask|Fullmask
with an opaque source pixel and op
.CW S ,
goes to
.CW scr->fill .
A straight copy \(em opaque mask, no source alpha, source and destination
in the same buffer \(em goes to
.CW scr->scroll .
Both are exactly the two cases a DMA engine or a 2D blitter can do.
.PP
The
.CW scr->softscreen
term in that guard is the architecturally important part.  A board that
composes into ordinary RAM and then pushes the result to the scanout
buffer declines hardware draw entirely, and it is right to: the
destination of every
.CW memimagedraw
is plain cached RAM, so there is no device memory involved and nothing for
a blitter to be faster at.  Accelerating a RAM-to-RAM draw through a
device would be slower than the CPU doing it.
.NH 1
Why this means the Pi's cost is not behind hwdraw
.PP
The Pi 3B is a softscreen board.
.CW screenbcm.c
memdraws into
.CW fb ,
ordinary kernel RAM, and
.CW flushmemscreen
pushes the dirty rectangle to
.CW vfb ,
the uncached VideoCore buffer the GPU scans out, one scanline at a time:
.DS
.CW
memmove(dp, sp, nb);
cacheflush(dp, nb);
.R
.DE
.LP
That copy is the board's real per-frame cost, and it passes through
.I neither
seam.  It is not a
.CW memimagedraw ,
so
.CW hwdraw
never sees it; and
.CW memdrawcopy
fires only from within
.CW memimagedraw ,
after the fact.  A board wanting to accelerate the Pi's display has to
change
.CW flushmemscreen
itself.  Filling in the Pi's
.CW hwdraw
would accelerate the wrong half, and by pc64's own rule a softscreen board
should decline it anyway.
.PP
In cost order, then, the Pi's candidates are: the soft-to-fb copy in
.CW flushmemscreen
first, by a wide margin, since it runs over every dirty pixel every frame;
then DMA or HVS for fills; then V3D for anything programmable.  The
render-node tree in
.CW libtk
could help the first of these, and not by making any single copy faster.
Every
.CW TkNode
carries its own
.CW "Rectangle r" ,
so the union of a frame's damage is one walk of the node list away, and a
flush driven from that union would push the frame's real bounds instead of
whatever rectangles happened to get drawn.  Nothing computes it today:
.CW TkScene
is a block allocator, a head, a tail and a count, with no extent field.
That is an opportunity the description makes cheap, not a property it
already has.
.NH 1
Why no implementation accompanies this note
.PP
The obvious move \(em give the Pi a DMA-backed
.CW hwdraw
or
.CW flushmemscreen
\(em was scoped and deliberately not built, for a reason worth recording so
it is not rediscovered.
.PP
.CW os/inferno/raspi3b/fns.h:113
defines
.CW dmaflush(clean,addr,len)
as empty, justified by a comment saying "SCTLR.M=0 makes RAM device
memory."  That was true once and is not true now:
.CW mmuinit()
is called from
.CW main.c:249 ,
and
.CW mmuenable
in
.CW l.s
sets
.CW $0x1005
into
.CW SCTLR_EL1 ,
which is M, C and I \(em MMU on, data cache on, instruction cache on.  A
DMA-visible blit on an A53 with caches enabled therefore does need the
maintenance that macro declines to emit.
.CW flushmemscreen
already knows this and calls
.CW cacheflush
per scanline for precisely that reason, so the driver is cache-aware in
the screen path and stale only in that one macro's comment.
.PP
The decisive problem is testing.  QEMU does not model cache coherency, so
a DMA draw that omitted or misplaced a cache maintenance operation would
pass under emulation and produce intermittently stale pixels on silicon.
A test that can only return good news in the dimension where the bug
lives is worse than no test.  This work wants a real board on the bench,
and the correctness gate should be a byte-for-byte comparison against the
software path, with a runtime switch keeping that path available as an
oracle.
.NH 1
Summary for whoever fills the seam
.IP 1.
Put acceleration in
.CW hwdraw ,
not in
.CW memdrawcopy .
The latter runs after the copy and cannot help.
.IP 2.
Read
.CW os/inferno/pc64/screen.c:496
first.  It is the only native example, and its
.CW Simplesrc|Simplemask|Fullmask
tests are the vocabulary for recognising the fill and blit cases.
.IP 3.
If the board is a softscreen board, the cost is in
.CW flushmemscreen ,
not in
.CW hwdraw .
Check which before writing anything.
.IP 4.
Verify against the software path byte for byte, with the software path
kept reachable at run time.  Do not accept QEMU as evidence for anything
involving caches or device timing.
