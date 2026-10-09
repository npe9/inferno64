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
