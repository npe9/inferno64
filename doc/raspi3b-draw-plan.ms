.TL
Getting hardware-helped draw working on the Raspberry Pi 3B
.AU
.PP
An ordered plan, each step gated by a check that can fail, for removing
the Pi 3B's per-frame framebuffer copy and giving the board a draw path
worth building 3D on.  It is written after two measurements that changed
the picture, and it deliberately does not rest on any timing number,
because every timing number available today is a QEMU artifact.
.PP
The companion note
.CW doc/draw-hardware-seam.ms
describes the portable seam
.CW hwdraw(Memdrawparam*)
and why a softscreen board's cost does not sit behind it.  That argument
is the reason this plan is about
.CW flushmemscreen
and the mailbox, and not about filling in the board's
.CW hwdraw .
.NH 1
What is already established
.PP
Two facts were measured, not inferred, and both contradict comments
currently in the board's sources.
.IP 1.
.B "The framebuffer is mapped Normal write-back cacheable."
.CW mboxfballoc
returns
.CW 0x3c100000
(size 1228800, pitch 2560) on a 640x480 QEMU boot, and
.CW mmuinit
in
.CW os/inferno/raspi3b/mmu.c
maps every 2MB block below
.CW BCMPERIPH
.CW ( 0x3f000000 )
as
.CW Pnormal .
So the VideoCore framebuffer is ordinary cacheable memory to the CPU.
.IP 2.
.B "memdraw does not fault drawing into it."
.CW screenbcm.c
says "Drawing straight into the VC-RAM buffer faults deep in memdraw."
Pointing
.CW fb
at
.CW fbpa
and booting gives
.CW DRAW-OK ,
.CW TK-OK
and the same 564 bytes of glyph ink as the copying path.  No fault.
.PP
Both comments predate
.CW mmuinit() ,
and that is one cause rather than two coincidences.  With the MMU off,
all of RAM is Device-nGnRnE, where unaligned accesses fault
architecturally and memdraw makes them constantly \(em so the note was
true when written and stopped being true when the board gained an MMU.
The same staleness sits in
.CW os/inferno/raspi3b/fns.h:113 ,
where
.CW dmaflush(clean,addr,len)
is defined empty on the stated grounds that
.CW SCTLR.M=0
makes RAM device memory, while
.CW mmuenable
in
.CW l.s
sets
.CW $0x1005
(M, C and I) from
.CW mmuinit()
at
.CW main.c:249 .
.PP
A third fact was measured for step 2 below: asking the mailbox for a
virtual height of
.CW 2*h
returns an allocation of 2457600 bytes, exactly twice one screen, with
pitch unchanged.  QEMU honours
.CW SET_VIRTUAL_HEIGHT .
.PP
A fourth, taken afterwards, closes step 2's gate rather than leaving it
open: setting the virtual offset really does move the scanout.  Painting
the second half solid white, calling tag
.CW 0x00048009
with
.CW "y = 480" ,
and capturing the emulated display gives a frame that is
.CW ffffff
over 100% of its pixels; the same kernel with
.CW "y = 0"
gives
.CW 2850a0
over 100%, the Inferno desktop.  The control is the point \(em it shows
the capture follows the offset rather than always reporting white.  So
the whole page-flip substrate is confirmed under emulation: the buffer,
and the flip.
.NH 1
The rule this plan runs under
.PP
Every step names evidence that could come back negative, and no step is
justified by a speed measurement.  This matters here more than usual.
The board's
.CW DRAWRATE
line reports 819us a fill for memdraw and 5714us for screen+flush, and
the direct-draw probe moved the second number to 12500us \(em
.I worse .
That is not a result about the Pi.  Writing into the emulated framebuffer
region is expensive under TCG because every store is tracked for display
refresh, so QEMU penalises exactly the thing that is free on silicon.
The ordering below follows from the copy
.I existing ,
which needs no timer, and the benefit must be read on a real board.
.NH 1
What it actually costs on the board
.PP
Read on real silicon, 2026-10-02, a Pi 3B booted over JTAG with the
kernel this branch builds:
.DS
.CW
DRAWRATE-OK 640x480 (307200 pixels):
    memdraw      2090 us a fill over 177
    screen+flush 24444 us a fill over 9
.R
.DE
.LP
A fill is 307200 pixels, 1228800 bytes.  So the draw into ordinary cached
RAM runs at about 588 MB/s, and the same fill delivered to the screen
runs at about 50 MB/s.  The difference, 22354us, is the soft-to-fb copy
and the cache clean: it is
.B "91.4% of the screen path"
and
.B "10.7 times"
the cost of the drawing it exists to deliver.
.PP
That settles the ordering of this plan, and it settles it more strongly
than the plan assumed.  QEMU put the same ratio at 7.0 and real hardware
puts it at 11.7, so emulation
.I understated
how completely the copy dominates \(em which is the opposite of the
direction a reader would guess from the warning above, and the reason
that warning says only that QEMU decides nothing rather than that it
flatters the copy.
.PP
Note also that memdraw itself is
.I slower
on the board than under QEMU (2090us against 819us), which is what one
should expect and is a small check that the figure is real: TCG runs the
rasteriser on a fast host CPU, while the board is a 1.2GHz A53.  A
measurement where the emulator looked slower at everything would have
been suspicious.
.PP
.B "What the kernel this was taken on is:"
build 1790983290, with the pre-fix
.CW pl011_kick ,
whose interrupts-off window per console write is bounded at
.CW Maxpoll
= 64 bytes; what that costs on silicon is unmeasured.  It does not reach
these figures, because
.CW drawrate()
puts no print inside either timed region \(em it timestamps, loops, and
prints afterwards \(em but the kernel's state belongs with the number.
.PP
The boot was otherwise clean: no faults, no panics, 39 self-test markers,
and the console printed normally throughout.
.NH 1
Step 1: draw into the framebuffer, keep the cache clean
.PP
Stop allocating the shadow buffer and point
.CW scrdata.bdata
at the mailbox buffer.
.CW flushmemscreen
keeps its per-scanline
.CW cacheflush(dp,nb) ,
which is now the whole of its job, and loses the
.CW memmove .
The diff is small because the flush already walks the dirty rectangle
scanline by scanline for the cache clean.
.PP
.B Gate:
.CW DRAW-OK ,
.CW TK-OK
and the glyph-ink count unchanged at 564 under QEMU \(em already
observed.  On silicon, a screendump must show correct pixels, since a
missing or misplaced cache clean shows up there and nowhere else.
.PP
.B "Failure mode to watch:"
this introduces tearing.  Nothing separates drawing from scanout any
more, so a frame can be displayed half-updated.  That is why step 2 is
part of this plan and not optional polish, and why step 1 should land
behind a flag that can select the old copying path until step 2 works.
.NH 1
Step 2: double buffer and page flip through the mailbox
.PP
The mailbox code already speaks this protocol.  Tag
.CW 0x00048004
sets virtual width and height and currently pins them to the physical
size; tag
.CW 0x00048009
sets the virtual offset and is already in the tag list, set to
.CW "0, 0" .
The change is to ask for
.DS
.CW
set virt w,h   ->  w, 2*h
.R
.DE
.LP
allocate two screens' worth, draw into the half that is not being
scanned out, and then flip by setting the virtual offset to
.CW 0
or
.CW h .
This is what the vc4 KMS driver does on Linux, and it is the reason the
firmware exposes the tag at all.
.PP
.B "Gate, and it has been run:"
paint the two halves differently, flip, and capture the
.I emulated
display with the QEMU monitor's
.CW screendump
\(em not the kernel's own, which dumps
.CW gscreen ,
our memory, and cannot see what the GPU scans out.  Done: white at
.CW "y = 480" ,
desktop at
.CW "y = 0" ,
both 100% of the frame.  The check would have failed if the two captures
matched, and they do not.
.PP
.B "What this does not settle:"
a flip wants to land in vertical blank.  Nothing above tests that, and
without it the tear moves rather than vanishing \(em so tearing is a
silicon-side question even though the mechanism is proven.  The firmware
offers no vsync tag on this path; the usual answer is the
.CW SMI
or a DSI/HDMI field interrupt, and that is where the remaining work in
this step lies.
.NH 1
Step 3: drive the flush from described damage
.PP
With steps 1 and 2 done, the remaining per-frame work is the cache clean
over the dirty rectangle, and that cost is proportional to how much area
the system believes is dirty.  Today that comes from whatever rectangles
happened to get drawn.
.PP
The render-node tree in
.CW libtk
can do better, but not as it stands, and the note in
.CW doc/draw-hardware-seam.ms
was corrected on this exact point.  Every
.CW TkNode
carries its own
.CW "Rectangle r"
.CW ( include/tk.h:600 ),
so a union over a frame is one walk of the node list; but
.CW TkScene
.CW ( include/tk.h:612 )
is a block allocator, a head, a tail and a count, with no extent field
and nothing accumulating one.  Step 3 is to accumulate it and let the
flush use it.
.PP
.B Gate:
a frame that touches one small widget must clean a correspondingly small
area.  Count bytes cleaned per frame, with a negative control: a frame
that legitimately dirties the whole screen must still report the whole
screen.  A metric that only ever goes down is measuring the wrong thing.
.PP
This step depends on the render-node
.CW libtk
being present on this branch, which it is not \(em see the open
integration question below.
.NH 1
Step 4, contingent: DMA for the copy, only if steps 1 and 2 fail
.PP
If the framebuffer turns out to be unusable as a draw target on real
silicon \(em the one thing QEMU cannot rule out \(em then the copy stays
and the question becomes whether to hand it to the BCM DMA engine.  This
is listed last and as a contingency, because if steps 1 and 2 succeed
there is no copy left for DMA to accelerate.
.PP
It is also the most expensive step to do correctly.
.CW dmaxfer
is a peripheral transfer with a DREQ;
.CW dmacopy ,
the memory-to-memory control-block path, is
.CW static
in
.CW dmabcm.c ,
so a new entry point has to be exported from a driver this plan does not
own.  And
.CW dmaflush
is the empty macro described above, so the cache maintenance a
DMA-visible blit needs is exactly what the board currently declines to
emit.
.PP
.B "Why this cannot be signed off under QEMU:"
QEMU models no cache coherency, so a DMA path with missing or misplaced
cache maintenance passes under emulation and produces intermittently
stale pixels on silicon.  A test that can only return good news in the
dimension where the bug lives is worse than no test.  This step needs a
board on the bench and a byte-for-byte comparison against the software
path, with a runtime switch keeping that path reachable as an oracle.
.NH 1
Not in this plan
.PP
V3D, the programmable 3D core, is out of scope here.  It is the right
long-term answer for "generalized modernized 3D infrastructure" and it is
a much larger piece of work than everything above put together; nothing
in steps 1 to 3 forecloses it, and a board that can page-flip is a
strictly better starting point for it than one that cannot.
.PP
The board's
.CW hwdraw
stays a stub returning 0, and that is correct rather than unfinished, for
the reason
.CW doc/draw-hardware-seam.ms
gives: pc64's own guard declines hardware draw on a softscreen board, and
after step 1 the Pi is not even that \(em it draws directly into the
scanout buffer, where there is no second copy to accelerate.
.NH 1
Ownership, and what has to be handed over
.PP
Steps 1, 2 and 4 all modify
.CW os/inferno/raspi3b/screenbcm.c ,
.CW mailbox.c
and
.CW dmabcm.c ,
which belong to the native-kernel tree and not to this work.  The
measurements above were taken with temporary probes that were reverted;
the board's sources are unmodified.  What should go to that tree's owner
is three things:
.IP 1.
The
.CW screenbcm.c
comment about memdraw faulting on VC RAM is stale, and the probe that
shows it is two lines: point
.CW fb
at
.CW fbpa
and boot.
.IP 2.
.CW dmaflush
in
.CW fns.h:113
is an empty macro resting on
.CW SCTLR.M=0 ,
which
.CW mmuenable
has not left true since
.CW mmuinit()
landed.  Anyone writing DMA against it inherits a silent coherency bug.
.IP 3.
The mailbox already sets virtual size and virtual offset, so page
flipping is a change of arguments before it is a change of design.
.NH 1
The one open question this plan does not settle
.PP
Not, any more, whether page flipping works \(em that is measured above.
Step 3 needs the render-node
.CW libtk
from the
.CW inferno-rio
branch, which is not on this one.  That is a real three-way merge rather
than a copy: this branch's
.CW libmemdraw/draw.c
carries the
.CW memdrawcopy
hooks and
.CW inferno-rio 's
does not, so a path checkout would silently revert them and break the
Metal tile upload that
.CW emu/MacOSX/win-cocoa.m
depends on.  Which direction to integrate \(em libtk onto this branch,
this branch's board work onto
.CW inferno-rio ,
or both onto main \(em is a repository-structure decision, not a
technical one, and steps 1 and 2 do not depend on it.
