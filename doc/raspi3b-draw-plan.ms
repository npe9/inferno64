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
justified by a speed measurement.  The ordering below follows from the
copy
.I existing ,
which needs no timer, and the benefit is read on a real board.
.PP
.B "A retracted claim, kept because it is instructive about probes."
An earlier draft of this section reported that under QEMU the first
direct-draw probe moved screen+flush from 5714us to
.B 12500us
\(em worse \(em and explained it as TCG tracking every store into the
emulated framebuffer region for display refresh, so that emulation
penalised the very thing this plan wants.
.PP
That explanation was wrong, and the number was the probe's own fault.
The probe pointed
.CW fb
at
.CW fbpa
but left
.CW flushmemscreen 's
.CW memmove
in place, so every flush still copied all 480 scanlines \(em to and from
the same address.  It was described at the time as "a self-copy
(no-op)", which a
.CW memmove
is not.  With the copy actually skipped when there is nothing to copy,
QEMU gives screen+flush
.B "1104us over 181 fills"
against 5714us over 35: about five times
.I better ,
in the direction silicon should go.
.PP
The lesson is not about TCG.  A probe that leaves the work it meant to
remove still in the code measures the probe, and an emulator is a
convenient thing to blame for a number one has produced oneself.
.NH 1
What it actually costs on the board
.PP
Read on real silicon, 2026-10-02, a Pi 3B booted over JTAG with the
kernel this branch builds, three boots:
.DS
.CW
            memdraw   screen+flush
boot 1       2090 us      24444 us
boot 2       2090 us      23333 us
boot 3       2090 us      23333 us
             (177 fills)  (9 fills)
.R
.DE
.LP
A fill is 307200 pixels, 1228800 bytes.  So the draw into ordinary cached
RAM runs at about 588 MB/s, and the same fill delivered to the screen at
50 to 53 MB/s.  The difference \(em the soft-to-fb copy and the cache
clean \(em is
.B "91.0 to 91.4%"
of the screen path, and
.B "about 10 times"
the cost of the drawing it exists to deliver (10.2 to 10.7).
.PP
.B "Three boots rather than one, and why the spread is what it is."
An earlier draft of this section quoted a single boot as 91.4% and
10.7x.  Those are the high end rather than the figure.  memdraw is
identical to the digit across all three boots, because it completes 177
fills inside the 200ms floor; screen+flush completes only
.B nine ,
so its quantisation is coarse \(em 24444 and 23333 are elapsed times of
220ms and 210ms divided by 9, which is one step of the millisecond clock.
The 4.8% spread is therefore mostly the instrument and not the board, and
.I more
boots cannot reduce it.  Only raising the floor for that arm would, by
taking more than nine samples; that is the honest improvement to make if
the figure ever needs to be tighter than "about ten times".
.PP
The ratio is what the plan rests on and it is not close to the line, so a
tenfold answer is enough to order the work.  The percentage is the stable
part: 91.0 against 91.4 across the three.
.PP
.B "The configuration, because it is the confound that has bitten here."
Every figure in this document was taken on a
.B JTAG
boot, and a JTAG boot parks cores 1 to 3 \(em so these are SINGLE-CORE
numbers, and nothing here can speak for what four active cores do to
memory bandwidth.  That is stated rather than buried because the
raspi3b-port session lost a uart measurement to exactly this: a 1.72x
that turned out to be a four-core card boot against a single-core JTAG
boot, two things changed and only one of them the patch.
.PP
What saves the step-1 figure below is that its two arms were taken the
SAME way \(em JTAG against JTAG, same board, same session, memdraw
identical to the digit across both as the control.  A ratio between two
runs of one configuration survives the configuration being unusual; an
absolute number does not.
.PP
That settles the ordering of this plan, and it settles it more strongly
than the plan assumed.  QEMU put the ratio of screen+flush to memdraw at
7.0; real hardware puts it at 11.2 to 11.7, so emulation
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
.PP
.B "And a defect in that kernel, found afterwards, which does not touch
.B "these figures."
The
.CW 7l
on this branch emits a conditional branch to ITSELF when the branch's
target label begins with an indirect branch \(em fixed on
.CW raspi3b-port
in
.CW c56c0c6c8 ,
.CW 1cc04ead7
and
.CW b97ac24d0 ,
not yet on this one.  This kernel has one, and it is in the worst place:
.DS
.CW
0x16a340  6b1f009f   CMP   w4, #0
0x16a344  54000000   B.EQ  +0        <- branches to itself
0x16a348  97fc57cb   BL
0x16a34c  17fffffb   B     -5        (a retry loop)
.R
.DE
.LP
.CW ksyms
puts
.CW 0x16a344
at
.CW panic+0xf0 ,
the same function where the amd64 half of the same bug emitted
.CW "74 fe" .
So an arm64 panic meeting that condition hangs at one instruction instead
of printing \(em on the one path whose failure cannot report itself.
.PP
It does not affect the measurement, and the distinction is worth keeping
straight: the kernel booted cleanly three times and
.CW drawrate()
never goes near
.CW panic() ,
so the figures above are from code that ran correctly.  It is a latent
hang, not a corrupted result.  The scan that found it is a filter over
the ELF program headers for words matching
.CW 0x54000000
with
.CW imm19
zero, keeping only offsets inside a
.CW PT_LOAD
marked executable \(em eight of the nine candidates in this file are
data, so the executable filter is what makes it a signal rather than
nine ghosts.
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
.B "DONE, AND MEASURED ON THE BOARD."
Build 1790990050, the same Pi, same 640x480, one JTAG boot:
.DS
.CW
            memdraw   screen+flush
before       2090 us   23333-24444 us   (9 fills)
after        2090 us        3448 us     (58 fills)
.R
.DE
.LP
memdraw is unchanged, which is the control: nothing about the drawing
moved, only the delivery.  screen+flush is
.B "6.8 to 7.1 times"
faster, 50 MB/s to about 356 MB/s, and what remains past the 2090us of
drawing is 1358us of cache clean rather than 21 to 22ms of copy.  So the
flush fell from 91% of the screen path to 39% of a much shorter one.
.PP
Correctness came back unchanged in the same boot:
.CW DRAW-OK ,
.CW TK-OK
with the same 564 bytes of glyph ink, and no faults or panics.  The fill
count rising from 9 to 58 is a side benefit \(em the arm that was too
coarse to quote precisely now takes six times the samples.
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
silicon-side question even though the mechanism is proven.
.PP
.B "Whether the firmware will do the waiting is UNKNOWN, and an earlier
.B "draft of this claimed otherwise."
It said the firmware offers no vsync tag and that the answer must be the
.CW SMI
or a DSI/HDMI field interrupt.  That was asserted, not checked.  The
property interface documents tag
.CW 0x0004800e
for exactly this, and whether this firmware honours it is a question for
the board.
.PP
.B "And it cannot be answered under QEMU, which is the trap here."
QEMU's
.CW bcm2835
property model sets the response bit for tags it does not implement.
Probing
.CW 0x0004800e
returns
.CW 0x80000000 ,
which looks like an answer \(em but so does
.CW 0x00049999 ,
which is not a tag at all, and five vsync calls take 2250 cycles rather
than blocking.  So a response code proves nothing there, and a probe that
reported "the firmware answers it" would have been reporting the
emulator's politeness.
.PP
This does not touch the two step-2 checks above, and the difference is
worth keeping straight: those were BEHAVIOURAL.  A doubled virtual height
returned twice the allocation, a size that changed rather than a bit that
was set, and the offset flip was confirmed by capturing the emulated
display.  A response code is the thing QEMU will lie about.
.NH 1
Step 2, answered: the firmware does the waiting
.PP
The vblank question above is settled, and not by this branch: the
raspi3b-port session measured tag
.CW 0x0004800e
on silicon
.CW ( c942709ef ).
The tag exists and it
.I blocks .
Eight successive waits gave gaps of 8612, 16664, 16665, 16667, 16665,
16666, 16667 and 16666us \(em 60.006Hz, stable to 2us, replicated on a
second build and boot.
.PP
.B "The control in that measurement is the part worth copying."
The first gap is SHORT and the remaining seven are equal, because the
probe entered mid-frame.  A fixed 16.667ms sleep would have produced
eight equal gaps.  So the short first gap is what distinguishes a real
vsync from a timer, and it is an internal control \(em no second build
needed to produce it.  The same measurement also checked the hazard that
.CW mboxread
bounds its wait with a SPIN COUNT rather than a timeout:
.CW Spins
is ten million, about a second, against a 16.7ms frame, so sixty frames
of headroom.
.NH 1
And the tear, which a readback probe cannot see
.PP
.B "This is the most important methodological result in this document."
With step 1 in place the same session measured the tear directly: 31 of
31 draw operations torn, 2339 rows written after the beam had passed
them, scanout period 319999 ticks = 16666.6us \(em which matches the
vsync figure independently, from a different mechanism.
.PP
In the
.I same
run,
.I drawink (1)
passed all five of its checks.
.PP
So a readback probe
.B cannot
detect tearing, and this is not a weakness of that particular test: the
framebuffer is never torn.  Tearing is a relationship between when a
pixel was written and where the beam was, and no amount of reading the
pixels back afterwards recovers it.  A probe of the form "sample a
scanline and look for two colours" would have reported success on a
wildly tearing display.  What to measure instead is phase, duration and
extent against 34.72us a row, which is arithmetic.
.PP
This matters beyond the Pi, because every instrument this branch and
.CW inferno-rio
use for draw correctness \(em
.I tkofftest (1),
.I lorigintest (1),
.CW readpixels
generally \(em is a readback probe.  They are sound for what they check,
which is what the pixels ARE.  They are blind by construction to anything
that is a property of WHEN the pixels got there.
.NH 1
What step 2 should actually do, and why not a vsync wait in the flush
.PP
Two findings from the same session change the shape of step 2.
.IP 1.
.B "A vsync wait in flushmemscreen is too late under Directfb."
By the time the flush runs, memdraw has already written the scanout
buffer.
.CW hwdraw()
is a genuine
.I pre-draw
hook, but it fires per draw OPERATION and a single Tk update is hundreds
of them, so there is no granularity at which per-operation
synchronisation is affordable.  That is a better argument for double
buffering than "it tears" is.
.IP 2.
.B "Tear-freedom costs the step-1 win back, scaled by damage."
The copy was 20452us of a 23900us full-screen path, but 818us for a
128x96 widget.  So paying it is affordable for ordinary Tk repaints and
not for a full-screen fill \(em and the expensive case is exactly the one
that needs no copy, because the next frame overwrites the whole back
buffer anyway.
.PP
Which gives the rule to try:
.B "flip when damage covers the screen, copy when it does not."
.PP
.B "And that rule needs this document's step 3 to work."
It has to know how much of the screen a frame will touch BEFORE drawing
it, which is precisely what a described frame can say and an immediate
draw cannot.  Step 3 was written here as a way to make the flush cheaper;
it turns out to be the thing that lets step 2 choose its strategy at all.
.CW tkscenebounds()
and
.CW "render bounds"
in
.CW inferno-rio 's
.CW libtk
were committed with the honest note that nothing consumed them.  This is
the consumer.
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
and nothing accumulating one.
.PP
.B "That last sentence is still true and is no longer the task."
.CW tkscenebounds()
in
.CW libtk/scene.c
already computes the union in one walk, conservatively: a clip node is
ignored rather than intersected, since a clip can only shrink what gets
painted; nodes inside a layer are skipped in favour of the layer's
.CW dstr ,
where the scratch actually lands; and an ellipse is computed from its
centre and radii rather than from
.CW r ,
which for that one node kind is not a box.  So the libtk side of step 3
exists.  What is left is a consumer.
.PP
.B "And the stored field is NOT that consumer."
Measured rather than assumed, on
.CW inferno-rio
.CW ( 5e8980f8d ):
.CW tkscenebounds()
has exactly one caller, the stats block in
.CW tkwalkflush() ,
which calls it once per tree and then
.CW tkscenefree() s
the tree two lines later.  A cached extent would be written once, read
once and freed.  A field accumulated during construction would have to be
maintained at every one of the dozen
.CW tkscene*()
constructors, and omitting one would silently UNDERSTATE the box, which
is the dangerous direction for a damage rectangle.  The walk costs one
pass per tree and the measurement puts the whole stats block below the
rig's drift.
.PP
So step 3 is: let
.CW flushmemscreen
clean the area
.CW tkscenebounds()
reports, instead of the union of whatever rectangles happened to get
drawn.  That is a change in
.CW os/inferno/raspi3b/screenbcm.c
and the seam that reaches it \(em kernel work, not
.CW libtk
work, and not this session's to write.
.PP
.B "Step 3 is not retired by the Directfb finding, and the inference that it is
.B "would be easy to make."
Elsewhere this plan records that the shipping path copies nothing per present
\(em
.CW Directfb
is 1 on
.CW raspi3b-port ,
so
.CW fb
IS
.CW vfb
and the
.CW memmove
is skipped. That retired the pixel-copy argument, and it is tempting to read it
as retiring damage-driven flushing altogether. It does not, because the guard
there covers only the copy:
.DS
.CW
	if(dp != sp)		/* Directfb: nothing to copy */
		memmove(dp, sp, nb);
	cacheflush(dp, nb);
.R
.DE
.CW cacheflush
runs unconditionally, per scanline, over the dirty span. The
area-proportional term on the shipping path is the
.I clean ,
which is exactly what this step targets.
.PP
.B "An attribution in that kernel's notes needs settling first, though."
It says the 43 MB/s repair and the 60 MB/s full-screen copy are slow because
they write uncached scanout memory, while
.CW screenbcm.c
also records \(em probed rather than argued \(em that
.CW mmu.c
maps every 2MB block below
.CW BCMPERIPH
as
.CW Pnormal ,
making
.CW fbpa
.CW 0x3c100000
ordinary
.I cacheable
memory. Both cannot hold. If the real cost is the
.CW cacheflush
write-back, this step attacks the dominant term; if the clean is a few percent,
the 43 MB/s needs a third explanation and the gate below should be re-derived
before any kernel code is written. One
.CW cycles()
bracket around
.CW cacheflush ,
separately from the
.CW memmove ,
decides it \(em on silicon, since QEMU models no data cache and a QEMU rig is
blind to this by construction. This plan has already paid once for optimising a
term nobody pays.
.PP
.B "Also note the two branches differ here."
.CW rio-pi-tk
has no
.CW Directfb
symbol at all:
.CW fb
is a kernel-RAM soft buffer,
.CW vfb
the VC-RAM one, and both the copy and the clean run. Correctness results from
this branch's kernel carry across; timings taken on it do not.
.PP
.B Gate:
a frame that touches one small widget must clean a correspondingly small
area.  Count bytes cleaned per frame, with a negative control: a frame
that legitimately dirties the whole screen must still report the whole
screen.  A metric that only ever goes down is measuring the wrong thing.
.PP
This step depended on the render-node
.CW libtk
being present on this branch, and it now is:
.CW 18207de0d
brought it over (35 files, 5106 insertions \(em every widget was
converted to emit nodes, so the whole of
.CW libtk
diverged along with
.CW include/tk.h 's
vocabulary), and
.CW 76163c65a
records it rendering on silicon, byte-identical to the direct path across
22 cases.  The integration question below is answered.
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
.PP
.B ANSWERED:
libtk onto this branch, the user's choice of the three.  Done as
.CW 18207de0d .
.PP
.B "And the technical risk this section cited does not exist."
It said this branch carries the
.CW memdrawcopy
hooks and
.CW inferno-rio 's
does not, so a path checkout would silently revert them.  Both branches
have 6
.CW memdrawcopy
and 3
.CW hwdraw
references, and
.CW "grep -cE \(dqmemdrawcopy|hwdraw\(dq"
over the branch diff of
.CW libmemdraw/draw.c
is 0 \(em the divergence there is entirely
.CW chardrawaa ,
the antialiased-glyph coverage path, which
.CW inferno-rio
HAS and this branch did not.  The gap ran the opposite way to the
assumption, and what made the checkout safe was that
.CW "git diff merge-base rio-pi-tk -- libtk"
is empty: this branch had made no
.CW libtk
changes since the split, so the conflict surface really was nil.
.CW libmemdraw/mkfile
was left alone deliberately, being the one file here whose content
.CW inferno-rio
lacks (the
.CW .j
JIT members).
.NH 1
Two draw-library faults that only a kernel could show
.PP
A panic in
.CW memset32
from
.CW memfillcolor ,
reached through
.CW bellipse ,
turned out to be two separate defects, neither of which a hosted run can
reproduce. Both are recorded here because the shape of the mistake
matters more than either fix.
.PP
.CW byteaddr
computed its row offset as
.CW "(s32)(sizeof(u32)*p.y*i->width)" ,
and
.CW 7c
drops a narrowing cast of a 64-bit value. The product compiled to
.CW UMULL ,
a 32\(mu32 to 64-bit
.I unsigned
multiply, so for a negative
.CW p.y
the low word
.CW 0xFFFFFFF8
times the width left a nonzero
.I high
word added to the pointer at full width. Only an image with a negative
.CW r.min.y
can reach it, and
.CW bellipse 's
brush disc
.CW Rect(\-t,\-t,t+1,t+1)
is the only one in the tree that has one \(em
.CW libdraw/bytesperline.c
already said such a rectangle is rare and that exactly one image here
has one. Fixed by keeping every operand 32 bits, so the truncation is
the arithmetic rather than a cast and there is nothing left to drop.
.PP
.CW allocmemimage
sized its allocation with
.CW "nw = l*Dy(r)"
in
.CW u32 ,
so a thickness whose true word count passed 2\u32\d wrapped to a small
one: at
.CW t=185352
the pool returned 83352 bytes for a rectangle holding 17.2 GB of pixels.
.CW draw (3)
rejects a negative semidiameter and thickness but bounds none of them
above. Fixed in
.CW uvlong
with a refusal past 2\u31\d bytes, plus a well-formedness check on the
rectangle in both allocators.
.PP
That fix was necessary and
.I not
sufficient, and what remained was
.CW byteaddr
again \(em the
.I x
offset this time, with no cast anywhere in the source. All three return
paths were
.CW "a + <32-bit int expression>" ,
and
.CW 7c
emitted
.CW SDIVW
or
.CW MULW
straight into a 64-bit
.CW ADD .
An AArch64 W-register write
.I zeroes
the upper half, so a negative offset widened
.I unsigned :
the \-1 that the sub-byte branch computes for
.CW p.x
of \-2 became
.CW 0x00000000FFFFFFFF
and the pointer landed 4GB past the image. C requires an int added to a
pointer to widen with its sign; the sign extension was simply absent.
.PP
.B "That makes the class wider than a dropped cast."
There is nothing here for a compiler to drop, which is why this one
outlived the row-offset fix: any instruction writing a W register can
feed a bad pointer, not just the
.CW UMULL
that the cast defect produced. Fixed the same way, by taking the offset
through an
.CW s32
local, so every path now sign-extends;
.I all
three were treated alike rather than argued about one at a time, since
the
.CW "depth >= 8"
path is the same shape and is reachable by any client that allocates an
image with a negative origin.
.PP
.B "A correction, because this plan said otherwise."
This section previously recorded the surviving fault as
.CW bdata
itself carrying bit 32 on a 1GB board, and called it a third defect in
the kernel pool. That was wrong, and it was inference from an address
rather than a measurement. The raspi3b session printed the fields at the
fault on silicon \(em
.CW "dst 0x1008c6c40 bdata 0x8c6c40 base 0x8c6c30 allocd 1 zero 17 width 2 r -2 -2 3 3"
\(em so
.CW bdata
was clean, high word zero, and the destination was exactly 2\u32\d above
a correctly allocated image. The pool was never implicated. Both faults
were in
.CW byteaddr ,
one in the row offset and one in the
.I x ,
and
.CW ellipsetest
now reports 9 of 9 in the kernel with zero traps.
.PP
.B "What this cost, and why."
Three instruments gave confident wrong answers before the mechanism came
out, and all three failed the same way \(em they measured something
adjacent to the question.
.IP \(bu
9.2 million ellipses at the board's own thickness ran clean under hosted
.CW emu ,
and that was quoted as evidence against the draw library. It is nothing
of the kind: the host is clang, which honours the cast, so the bug is
invisible there
.I "by construction" .
A host run can narrow the space; it cannot exonerate shared code that a
kernel compiles with a different compiler.
.IP \(bu
The test printed
.CW "9 ok, 0 fail"
on a kernel that then died on its way out. Draw operations batch into
the
.CW /dev/draw
buffer and run at flush, so the count recorded messages
.I queued
and the drawing happened during teardown. A count that cannot fail is
not a test.
.IP \(bu
With flushing added it still printed the pass line before the trap,
because console output is queued and a
.CW print
races a trap print. The last line on the wire does not name the faulting
case. Selecting one group per boot is what attributed it, since then the
answer is which invocation dies.
.PP
.B "And the build will lie to you."
.CW "mk iraspi3b"
after a change under
.CW lib*/
descends into the library, recompiles, re-archives, and then runs
.CW 7l
.I zero
times, exiting 0 with the old kernel in place. The kernel target has no
dependency on the library archives. Remove
.CW iraspi3b
and
.CW kernel8.img
and require exactly one
.CW "7l -o iraspi3b"
in the log; this is the opposite of the stale-object hazard elsewhere in
this tree, where removing an object does
.I not
force a rebuild and touching the
.CW .c
is what works, which is why the check is on the link count and not on a
habit.
