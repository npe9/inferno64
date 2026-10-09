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
.CW ( appl/cmd/qputry.b :163),
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
