.TL
Why the Pi 3B does not answer EXECUTE_QPU, and what to try
.AU
.PP
.B "The state, in one paragraph."
The draw3d protocol letters are implemented in this board's
.CW devdraw
and rasterise in software, byte\-identical to the hosted ones; the
.CW gpudraw*
hooks are declared and nil, so a backend is a file that assigns them.
On silicon the firmware answers
.CW GET_CLOCK_RATE
(V3D at 250 MHz) and
.CW SET_ENABLE_QPU ,
and refuses a nonsense tag, so the property channel works and the
answers mean something.
.CW EXECUTE_QPU
is
.I "never answered:"
.CW buf[1]
and
.CW buf[4]
come back as the driver left them and the value buffer holds the
request verbatim.
.PP
.B "What is NOT the question."
The argument layout. Fitting parameters to a request nobody replies to
cannot converge, and the sweep that appeared to rule words out was
measuring a spin loop in
.CW mboxread
rather than the firmware. That loop is now bounded by time, which is
what makes the hypotheses below separable at all.
.NH 1
One EXECUTE_QPU attempt kills the property channel until a reboot
.PP
.B "This invalidates every multi-question run of the battery,"
including the ordering this document argued for, and it is not fixable
by reordering. Measured on silicon, one fresh JTAG boot, the same tag
before and after, by the session that owns the board:
.DS
.CW
control GET_CLOCK_RATE   PROCESSED, 8 bytes,      25 us
EXECUTE_QPU              UNTOUCHED, no reply,  200004 us
THE SAME control again   UNTOUCHED, no reply, 1000004 us
.DE
.PP
Not slower.
.B "Not at all,"
at any bound, and it stays dead across separate board runs within the
same boot. Only a reboot brings it back.
.PP
.B "So the exec has to be the last thing a boot does."
The battery was one run, ordered so that an early failure would make
the later lines meaningful \(em which is right for independent
questions and wrong for these, because
.CW H1
is the exec and everything after it was reading a dead mailbox rather
than its own hypothesis.
.PP
It nearly produced a false finding. A
.CW H3
run after an exec came back
.CW "OUT OF TIME"
and would have read as "the V3D power domain is unreadable". The good
.CW H3
result \(em domain 0xa, state 1, answered in 23 us \(em is good only
because it ran before any exec.
.PP
.CW tools/jtag/qpubattery.sh
is one question per invocation now, one boot each, and
.B "every question prints the control before AND after it,"
so a verdict carries its own evidence that the channel was alive when
the question was asked and whether the question killed it. A verdict
from an unbracketed run cannot tell its own failure from a channel that
was already gone.
.PP
.B "And it explains the wedge better than the lock did."
A dead property channel blocks every driver that comes back to it at
runtime \(em
.CW btbcm
and
.CW thermbcm
here, and
.CW sdhostbcm ,
.CW sdhcibcm ,
.CW pwmbcm
and
.CW screenbcm
on branches that have them. A thirty-second spinlock hold made that
worse by occupying the lock as well, but the channel was already
unrecoverable, and a shorter bound only loses the board more slowly.
Capping and yielding the mailbox wait is right for the kernel's own
sake \(em a user program must not be able to make the kernel spin \(em
and it does
.B not
make an exec safe to run.
.PP
.B "And it is EXECUTE_QPU specifically, measured."
A fresh boot doing the control, then
.CW reset
and
.CW enable
with no exec, then the control again:
.DS
.CW
A-CONTROL-FRESH   PROCESSED, 8 bytes, 25 us, 0xee6b280
B-ENABLE-NO-EXEC  reset, enable accepted
C-CONTROL-AFTER   PROCESSED, 8 bytes, 24 us, 0xee6b280
.DE
.PP
25 us before and 24 us after, the same value both times. So it is not
the reset path, not the enable path, and not
.CW #Q
touching the channel at all.
.PP
That also disposes of the other reading the two timeouts allowed:
.CW qputry
writes its
.B own
.CW exec
.CW "(appl/cmd/qputry.b:163),"
so the earlier run's first timeout was its submission and the second
was the explicit one \(em two execs, not an exec preceded by something
else. Which means the battery's
.CW arith
question is an exec too, and it was listed as shareable: running it
between
.CW enable
and
.CW h2
would have spent a boot producing a dead
.CW h2
and read as a finding about firmware memory.
.NH 1
What the five measurements eliminate, and the one question left
.PP
Each taken before any exec in its own boot:
.DS
.CW
the parser runs and walks the list   absent tag answered, 0x80000001, 22us
GET_CLOCK_RATE implemented+answered  25us, 250 MHz
SET_ENABLE_QPU implemented+answered  accepted, channel alive after
the V3D power domain is ON           domain 0xa reads back state 1
EXECUTE_QPU                          reached, never answers, CHANNEL DEAD
.DE
.PP
So the handler is
.B entered
\(em it is not absent, or it would look like
.CW 0x000f0f0f
\(em and it does not return, and it takes the property channel with it.
.B "Not absent, not unimplemented, not powered off, not slow, and not"
.B "provoked by anything else #Q does,"
each by a measurement rather than by argument.
.PP
.B "H5 IS ANSWERED: SET_ENABLE_QPU ungates the V3D register block, and
.B "the 0xdeadbeef was the debugger's filler for a gated one."
Measured on silicon in ONE firmware session with
.CW 0x3f10001c
reading
.CW 00000102
throughout as a control, and no hole probe anywhere near it:
.DS
.CW
before enable   0x3fc00000: deadbeef
echo qpuenable  answered, reply 0x0 (accepted)
after enable    0x3fc00000: 02443356
.R
.DE
.PP
and the KERNEL'S OWN read, through
.CW "ident force 1"
rather than the debugger, gave
.CW 0x02443356
in the same session. Two independent readers agreeing is what settled
it, after the control that would have settled it was disqualified for
damaging a core.
.PP
.B "So the block is THERE and gated, and h2 is worth its boot:"
.CW EXECUTE_QPU
not answering is no longer explicable as a dead block, provided the
exec is issued after
.CW enable .
.PP
.B "Persistence, which matters for choosing a starting state."
The ungated state survives a JTAG boot and does NOT survive
.IR hardreset .
So a JTAG boot inherits whatever the firmware session already had and is
.I not
a clean slate for this question;
.I hardreset
is.
.PP
.B "And the read does not stall. The first report that it did was
.B "retracted."
Both versions are recorded here because the retraction is the more
useful result and because this plan carried the wrong one for a commit.
.PP
What the one run that reached V3D shows (JTAG,
.IR "rasberry pi inferno" ):
.DS
.CW
0x3f10001c   00000102   PM_RSTC, so the read path works
0x3f100020   00000000   PM_RSTS
0x3fc00000   deadbeef deadbeef deadbeef
.R
.DE
.PP
openocd exit 0, no abort, no timeout, and
.CW alive
answered right afterwards with an advanced counter. The access
completed and the board kept running.
.PP
.B "The wedge came from the CONTROL."
A read of a genuine peripheral hole at
.CW 0x3f900000
aborted, ended the openocd script
.I before
its
.CW resume ,
and left
.CW cpu0
unable to execute debug opcodes \(em while
.CW cpu1-3
stayed merely halted and answered normally. An explicit
.CW resume
did not recover it. The misattribution was exposed when a later run
reproduced the wedge
.I without
touching V3D and never printed even its first control: the run that
"timed out on V3D" had died during attach, before any read.
.PP
.B "So a destructive control in the same script as the measurement cost
.B "the attribution."
Which is the same mistake, one level up, as reading IDENT0..2 in one
command: when the thing dies you cannot say which line killed it. Both
are now separated \(em
.CW "ident force"
reads ONE word by default, and the re-run drops the hole entirely.
.PP
.B "And the discriminator is gone with it."
The hole was the only characterisation of what a FAILED read looks like
here, so it was what would have decided whether that
.CW 0xdeadbeef
is three real reads of an undriven block or the debugger's filler for
an access that silently did nothing. It is disqualified, because it
does not fail the way a failed read fails \(em it damages a core. That
question is open and is not being dressed up.
.PP
.B "What this plan and devv3d still had wrong independently of that:"
both offered two outcomes, a version word or zero, where
.CW 0xdeadbeef
is neither. The status string now has an
.CW unknown
branch for it, a
.CW STALLED
state for a read begun and not finished \(em never observed \(em and a
.CW tried
marker set before each read so a halted target says which word died,
since on a board that stalls nothing runs again to print anything.
.PP
.B "What it leaves is a conflict worth stating plainly."
The domain query answers
.CW 0xa
state 1 \(em on \(em while the register block does not answer the bus.
Something is answering about power that is not the thing being read. If
.CW SET_ENABLE_QPU
ungates the block, then
.CW IDENT0
should read after it and the next measurement says so; if it still
stalls, the block is never on and
.CW EXECUTE_QPU
entering a handler and never returning is the firmware's own first V3D
access stalling exactly as the debugger's did. That reading is asked
for: IDENT0 after
.CW enable ,
in one boot, with the same three controls.
.PP
.B "And a clock the driver never sets."
.CW devv3d
asks for the domain and sends
.CW SET_ENABLE_QPU
but never sets the V3D clock. If
.CW IDENT0
reads only after a
.CW SET_CLOCK_RATE
(0x38002, clock id 5), every V3D access this driver has ever made was to
an unclocked block, and that is a driver defect rather than a firmware
mystery.
.PP
.B "H2 was attempted and is VOID, on a seam neither tree could see alone."
The raspi3b session JTAG-booted this kernel while the board served
.I its
.CW /dis
over styx, so
.CW qputry
\(em which the question needed to load code \(em was not there:
.CW "sh: qputry: file does not exist" ,
no exec was ever sent, and the unchanged status afterwards read exactly
like the question being answered rather than never asked. Fixed by not
needing a userland command at all:
.CW /dev/v3dcode
takes raw bytes, so a
.CW "code W0 [W1 ...]"
ctl command now takes them as text and the battery depends only on this
driver.
.PP
.B "And the allocation comes back in the WRONG WINDOW, which is a bug in
.B "this driver."
Measured on silicon:
.DS
.CW
gpumem firmware handle 0x4 bus 0xbeaccf60 size 4096
gpualloc tried alloc answered lock answered
.R
.DE
.PP
.CW 0xbeaccf60
is in the
.CW 0x80000000
window \(em L2-cached, non-allocating \(em and not the uncached
.CW 0xc0000000
one.
.CW Memflags
is
.CW 0xc
with the comment "COHERENT|DIRECT, as a QPU program wants", but
.CW MEM_FLAG_DIRECT
is
.CW 1<<2
and
.CW MEM_FLAG_COHERENT
is
.CW 2<<2 ,
so
.CW 0xc
is
.CW MEM_FLAG_L1_NONALLOCATING
and asks for exactly the cached window it got. The firmware answered
correctly; the comment is wrong. The allocation is REAL and in the wrong
place, not failed.
.PP
.B "The stop condition given for that run was also wrong,"
and is recorded because it would have mattered had the run got that far:
it said to stop if the bus address came back "without the
.CW 0xc0000000
bits", while
.CW v3dgpualloc 's
actual test is
.CW "(membus & 0xc0000000) == 0" ,
which
.CW 0x80000000
passes. The driver would have gone on and used that memory.
.PP
.B "Two levers, and the battery has only ever pulled one."
Flags
.CW 0x4
instead of
.CW 0xc
should give the uncached alias, which is a one-constant change and is
being measured by two bare
.CW tag
commands that touch no GPU. Separately,
.CW EXECUTE_QPU 's
third word is
.CW noflush
and both
.CW qputry
and the battery pass
.CW 1 ,
so the firmware is told not to flush the VideoCore L2 while the code
sits in an L2-cached alias.
.CW devv3d
does
.CW cacheflush()
its own writes, which settles the ARM side and says nothing about VC L2.
So h2 with
.CW noflush=0
is a different question and will be asked as one rather than by quietly
editing h2.
.PP
.B "A clock rate is not a liveness signal."
GET_CLOCK_RATE answered 250 MHz on clock 5 with
.CW "enabled 0"
and
.CW "enable untried"
in the same boot, and IDENT0 proves the block is gated until
SET_ENABLE_QPU. So the clock answers the same either side of the gate.
.PP
.B "What is left is h2."
If
.CW EXECUTE_QPU
answers from a firmware allocation when it never answers from the
kernel's own alias, the alias was the whole fault.
.CW devv3d 's
.CW gpumem
provenance line and its separate
.CW alloc
and
.CW lock
fields exist so that a second silence is attributable to the exec
rather than to an allocation that quietly did not happen \(em the
allocating path has never succeeded anywhere, since QEMU refuses it for
want of alias bits, which is the shape of code that is wrong in a way
no run has shown.

.NH 1
The hypotheses, each with the test that kills it
.LP
.B "H1 \(em the firmware replies, later than we waited."
A firmware that starts a QPU job and waits for it would reply after its
own timeout, not at once. Our bound was ~1.05s and the requested
timeout word was 1000ms, which are the same order \(em so a reply could
have been cut off by a hair.
.IP
.B Test:
raise the mailbox wait to 30s and repeat. A reply at any time kills the
silence reading. Needs the wait to be a parameter, which is item 1
below.
.LP
.B "H2 \(em the code and control list are not where the QPU can fetch them."
This is the leading hypothesis. The buffers are static kernel memory
passed as
.CW "pa | 0xc0000000" ,
the uncached alias the
.I VPU
reads property messages through. The QPUs fetch through the V3D, which
is not the VPU, and the documented way to get memory a QPU can run from
is to ask the firmware for it:
.CW ALLOCATE_MEMORY
(0x3000c) then
.CW LOCK_MEMORY
(0x3000d), which returns a bus address.
.IP
.B Test:
allocate and lock, put the code and control list there, and execute
from that address. If the reply appears, the alias was the fault.
.LP
.B "H3 \(em the V3D is clocked but not powered."
.CW SET_ENABLE_QPU
was accepted, but accepted is not the same as effective, and a power
domain is a separate thing from a clock on this SoC.
.IP
.B Test:
.CW SET_DOMAIN_STATE
for the V3D domain, then read it back, then execute. A domain that
reads back off after being set on is an answer by itself.
.LP
.B "H4 \(em this firmware does not implement the tag."
Possible, and the least interesting. But an unimplemented tag normally
gets a reply with the tag's processed bit clear, and we get no reply at
all, so H4 does not explain the observation on its own.
.IP
.B Test:
probe a tag that is certainly absent but harmless and compare the
shape of the failure with
.CW EXECUTE_QPU 's.
Identical shapes make H4 likelier; different shapes rule it out.
.NH 1
What to build, and why in this order
.IP 1.
.B "The mailbox wait as a parameter."
Without it H1 cannot be tested and every other test inherits a bound
nobody chose. Cheapest item and it gates the rest.
.IP 2.
.B "A generic tag command."
.CW "echo tag 0x00030030 4 10 >/dev/v3dctl"
and read the response. This is the highest\-leverage item by a wide
margin: it makes H3 and H4 testable, and every future firmware question
after them, without a kernel rebuild. The alternative is a C function
per tag.
.IP 3.
.B "Firmware\-allocated memory."
.CW ALLOCATE_MEMORY ,
.CW LOCK_MEMORY ,
and the code and control list written through the returned bus address.
Tests H2, the leading hypothesis, and is the one item that is real work
rather than an interface.
.IP 4.
.B "One board run."
Items 1 to 3 make the whole battery a handful of lines, which matters
because the board is shared and each window is short.
.NH 1
What success and failure both look like
.LP
If
.CW EXECUTE_QPU
starts answering, the encoding bootstrap becomes possible and the
method is the one already written down: garbage that does not end
against a candidate end\-of\-program sequence, discriminated by elapsed
time now that the bound is real.
.PP
If it does not answer under any of these, that is a firmware limit and
the right outcome is to write it down and stop \(em with the
.CW gpudraw*
hooks still in place, because they cost nothing and a later firmware or
a V3D register driver would use the same seam. The software
rasteriser is not a placeholder: it is what makes 3D work on this board
today, and it is byte\-identical to the hosted path.
.PP
.B "What would make this a bad plan to continue."
If item 3 shows the QPU can fetch and the tag still goes unanswered,
there is nothing further to try through the mailbox and the next step
would be the V3D registers directly \(em a driver project, not a step,
and one to decide on rather than drift into.
.NH 1
Silicon, 10 October 2026: the unified kernel, and one measurement per boot
.PP
.B "The two tracks are one tree now."
.CW rio-pi-tk
was merged into
.CW raspi3b-port
and the result built, booted in QEMU, written to the card and booted on
the real Pi 3B. That matters to this plan for a specific reason: item
h2 was recorded VOID on a cross\-tree seam, because the experiment needed
a kernel from one tree and a
.CW qputry
from the other. There is no seam now.
.PP
.B "V3D answers on silicon through this kernel."
.CW "bind -a '#Q' /dev"
then
.CW "echo enable"
and
.CW "ident force 3" :
.IP
.EX
clock hz 250000000
enabled 1          enable accepted
ident V3D tried 3 read 3 0x2443356 0xc1102431 0x121
.EE
.PP
.CW IDENT0
is the "V3D" magic, and
.B "that part is a replication and not a result"
\(em H5 above already had
.CW 0x02443356
from two independent readers. What it adds is that it reproduces
through the merged kernel booted
.I "from the card,"
where H5 read it under JTAG, so the unification did not cost the one
thing that was working.
.PP
.B "IDENT1 and IDENT2 are new, and they say how big the block is."
Decoding
.CW IDENT1
= 0xc1102431: NSLC 3, QUPS 4 \(em three slices of four, so
.B "twelve QPUs,"
which is the VideoCore IV a BCM2837 should have. So the thing that will
not answer
.CW EXECUTE_QPU
is not a stub or a cut\-down part; it reports a full VideoCore IV.
The clock is
.B "250 MHz and not the 700 MHz QEMU reported,"
so the V3D\-BLIND guard earned its place on the first real run.
.PP
.B "The two-tag alias experiment, both arms in one boot."
This was the free experiment this plan asked for, and it settles which
window a flag value buys:
.IP
.EX
flags 0x4   handle 0x4   bus 0xfeaccf60   top 0xC...  uncached
flags 0xc   handle 0x5   bus 0xbeacbf20   top 0x8...  L2-cached
.EE
.PP
So
.CW "Memflags = 0xc"
in
.CW devv3d.c
asks for the L2\-cached non\-allocating window, not an uncached one, and
its comment ("as a QPU program wants") is at best unverified. The code
is not therefore wrong \(em it calls
.CW cacheflush()
on the code, uniform and control buffers before executing, which is the
compensation that window requires. But the comment asserts a property
nobody measured, and now it is measured.
.PP
.B "AND THE ALLOCATION IS IN THE WRONG PLACE, not merely the wrong window."
.CW gpualloc
succeeds \(em alloc answered, lock answered, handle 0x4, bus 0xbeaccf60,
4096 bytes \(em and then
.CW exec
refuses it:
.IP
.EX
qputry: exec: gpu memory is not in RAM this kernel can reach
.EE
.PP
Strip the L2 alias from 0xbeaccf60 and the physical address is
0x3eaccf60, about 1002 MB. The boot log says
.CW "arm-mem base 0x0 size 0x3c000000"
\(em 960 MB. The firmware allocated above the ARM/VideoCore split, so
the ARM cannot write the code it is being asked to run, and the driver
is right to refuse. Changing the window would not fix that; changing
.CW gpu_mem
in
.CW config.txt
is the knob, and it is a card edit and a reboot, not a code change.
.NH 2
PROCESSED where this document recorded UNTOUCHED, on a card boot
.PP
.B "FIRST, A CORRECTION TO WHAT I ALMOST CLAIMED HERE."
I wrote this section up as the discovery that one exec poisons the
property channel and that only the first reading of a boot counts. That
is already the FIRST NUMBERED SECTION of this document \(em "One
.CW EXECUTE_QPU
attempt kills the property channel until a reboot" \(em measured on
silicon by the session that owns the board, with the same control before
and after, and
.CW tools/jtag/qpubattery.sh
was already rewritten to one question per invocation because of it. I
appended to this file having read only its tail and its section
headings, rediscovered a documented result, and presented it as new.
.PP
.B "The habit that failed is worth naming:"
I treated the plan as a place to write conclusions rather than a thing
to read first, so the one document guaranteed to contain the prior art
was the one I did not consult. Nothing below is offered as new unless it
disagrees with what is already above.
.PP
.B "WHAT IS ACTUALLY NEW IS A DISAGREEMENT, and it is small and specific."
This document records the first exec of a boot as
.CW "tag 0x0 UNTOUCHED wrote 0 bytes"
from a
.B JTAG
boot. On a
.B card
boot of the unified kernel the first exec of a boot reads:
.IP
.EX
exec refused code 0x0 tag 0x80000004 PROCESSED wrote 4 bytes 1008631 us
wait OUT OF TIME (no reply) after 1000000 us (asked 1000000)
.EE
.PP
.B "PROCESSED, four bytes written"
\(em the firmware
.I does
touch the response buffer. Reproduced on two separate fresh card boots,
one exec each. That is the only reading here that contradicts the
sections above, and the candidate explanation is in those sections'
own terms: they record that the ungated state
.B "survives a JTAG boot and does not survive"
.IR hardreset ,
so a JTAG boot inherits whatever the previous firmware session left and
is not a clean slate. A card boot is a firmware restart. If that is the
difference, then
.B "the tag response is written only when the firmware session is fresh,"
which is testable with one
.I hardreset
and one exec and would be worth the boot.
.PP
.B "AND MY REPLICATION OF IT WAS WORTHLESS, by this document's own rule."
I read PROCESSED, doubted it, ran it three more times in the SAME boot,
got UNTOUCHED three times and wrote the first down as refuted. Then a
reboot and a single reading reproduced PROCESSED exactly. The three
"replications" ran on the channel the first exec had already killed \(em
which is precisely what the first section of this plan says happens,
and precisely why
.CW qpubattery.sh
takes one question per boot. Repetition is evidence only when the state
between repetitions is the same, and here the first trial destroys it;
I had the rule in front of me and repeated into a dead channel anyway.
.PP
.B "Program content makes no difference, which answers item 3 as planned."
This plan proposed discriminating by elapsed time between garbage that
does not end and a candidate end\-of\-program sequence. Both were run,
one clean boot each:
.IP
.EX
0xdeadbeef 0xcafebabe                      PROCESSED 4 bytes 1008631 us
thrend + two nops (6 words, canonical VC4)  PROCESSED 4 bytes 1004254 us
.EE
.PP
Four milliseconds apart, on a one\-second bound, with the same response
in both. A terminating program is not treated differently from
nonsense, so the firmware is not getting as far as running the code and
the "stuck in a program that never ends" reading is refuted. Combined
with the refusal above, the likeliest remaining account is that
.CW EXECUTE_QPU
will not complete for code the ARM placed in its own RAM rather than in
firmware memory the QPU can fetch \(em and the only way to give it the
latter is to move the
.CW gpu_mem
split so that firmware memory is also ARM\-addressable.
.PP
.B "What this does NOT show."
Nothing here says the QPU ran anything. No pixel, no uniform written
back, no counter moved. The headline remains that the block identifies
itself, is clocked and is ungated, and that the mailbox's execute path
does not complete; the software rasteriser is still what draws 3D on
this board.
.NH 2
What the unification cost, and the one number that justifies it
.PP
.B "The merge broke the display and the fix is committed."
rio\-pi\-tk's
.CW mboxfballoc
has five parameters where this branch's has six \(em the sixth is the
VIRTUAL height, which is what makes a page flip a
.CW SET_VIRTUAL_OFFSET
instead of a copy. Rebuilding
.CW mailbox.c
from their copy dropped it, and
.CW screenbcm.c
went on passing six arguments to five parameters, so the framebuffer
allocation failed and the kernel booted with no framebuffer at all. The
only symptom was
.CW "no frame buffer"
from two unrelated Dis tests.
.PP
.B "7c and 7l could not have caught it."
.CW screenbcm.c
declares its own
.CW extern
rather than taking one from
.CW fns.h ,
so the prototype and the definition are in different translation units;
the compiler checks a prototype only against uses in the same unit and
the loader does not compare signatures. It compiled, linked and booted
silently. There is a test for the class now,
.CW tests/extern-arity.py ,
whose positive control is this exact bug.
.PP
.B "AND THE DRAW3D LETTERS RASTERISE IDENTICALLY ON THE BOARD."
This is the number that makes the merge worth having.
.CW os/inferno/port/devdraw.c
gained 1581 lines and ten protocol letters that previously existed only
in emu, and the board's config asked the right question about them:
does the kernel rasterise them, and the same way.
.CW draw3dkerntest
on the real Pi 3B against the same test under hosted emu:
.IP
.EX
poly   device 4356  software 4128  228 differ  sums 0x1124da01 0x16bcf9c5
line   device  675  software  657   18 differ  sums -0x208b1d40 0x4273e1e4
plot   device    3  software    3    0 differ  sums equal
.EE
.PP
.B "Every figure is identical between the two,"
to the byte and to the checksum. The native kernel's draw3d
implementation and emu's agree exactly, so the hosted path is a valid
oracle for the board one from here on \(em which is worth more than any
single measurement, because it means this work no longer needs the board
to check a rasteriser change.
.PP
The rest of the gate on silicon, same boot:
.CW drawink
all checks passed (21 lines, not the empty pass that
.CW drawink
can silently become),
.CW polytest
13 ok 0 fail, and
.CW bndstest
11 ok 0 fail \(em so bounds checks are still armed with the JIT on.
