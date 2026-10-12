.de P1
.DS L
..
.de P2
.DE
..
.TL
Finishing USB split transactions on the Pi 3B: a plan with oracles
.AU
.PP
Written 11 October 2026, after seven hypothesis-led attempts at the
periodic split path and seven reverts. The attempts are listed in
.CW doc/open-issues-plan.ms ;
this document is about why that approach cannot finish the job and what
to put in place instead.
.NH 1
Where things stand
.LP
.B WORKING ,
on silicon, four cores, installed on the card as build 1791738405:
.IP \(bu
full\-speed and low\-speed devices
.B enumerate
behind the LAN9514 hub's transaction translator. Control transfers over
splits work. This had never worked on this board before.
.IP \(bu
a low\-speed boot mouse attaches:
.CW "usbd: ep5.0: boot mouse on ep5.1" .
.B NOT WORKING:
.IP \(bu
the mouse's interrupt endpoint delivers nothing. The device answers
.CW Nak
to every periodic complete\-split, including while it is being moved, so
no report ever reaches
.CW /dev/pointer
and the pointer does not move.
.NH 1
Why seven attempts failed, and it is not the hypotheses
.LP
Each attempt was a defensible reading of USB 2.0 or a measured register
disagreement. Three came from the specification, two from a register
that genuinely disagreed with another register, two from a protocol
violation that is genuinely present. None moved the symptom and the last
one lost the device.
.PP
The common cause is not bad reasoning. It is that
.B "three things were missing and all seven attempts needed them:"
.IP 1.
.B "No oracle."
Nothing says what the controller and the translator are
.I supposed
to do at each step, in a form that can be checked. The specification
describes the wire; it does not describe what this core expects software
to write, and in what order.
.IP 2.
.B "No way to see a sequence."
Every judgement rested on a rate\-limited
.CW print
into a 16K ring that wraps. A print shows the first few events of
thousands and perturbs the timing of a 125 us microframe while doing it.
Two diagnostics confounded themselves this way \(em one read a register
the code had already cleared, another overwrote the field it was
comparing against.
.IP 3.
.B "No reproducible environment."
.CW hw/usb/hcd-dwc2.c
in the patched qemu mentions
.CW HCSPLT
once, in a table of register names: the model stores the split registers
and never acts on them. So
.CW raspi3b-usb
runs the driver's whole split path and cannot detect a split defect \(em
it was 52 markers green while the stale\-accumulator bug stopped every
split transfer on real hardware.
.PP
.B "An eighth hypothesis would fail the same way."
The phases below build the three missing things, in increasing cost, and
each one has an acceptance test that does not depend on the mouse
working.
.NH 1
PHASE 0 IS DONE, and it changes the shape of the work
.LP
The oracle is on this disk after all:
.CW /Users/npe/src/linux-cursor/linux/drivers/usb/dwc2/ .
Three things read out of it, each contradicting or reframing an earlier
attempt.
.NH 2
What dwc2 does, and where
.LP
.CW dwc2_hc_start_transfer() ,
.CW drivers/usb/dwc2/hcd.c :
.P1
if (chan->do_split) {
        num_packets = 1;
        if (chan->complete_split && !chan->ep_is_in)
                chan->xfer_len = 0;           /* CSPLIT OUT */
        else if (chan->ep_is_in || chan->xfer_len > chan->max_packet)
                chan->xfer_len = chan->max_packet;
        else if (!chan->ep_is_in && chan->xfer_len > 188)
                chan->xfer_len = 188;

        /* For split set ec_mc for immediate retries */
        if (chan->ep_type == INT || chan->ep_type == ISOC)
                ec_mc = 3;
        else
                ec_mc = 1;
}
.P2
.CW dwc2_hc_nak_intr() ,
.CW drivers/usb/dwc2/hcd_intr.c ,
whose comment reads
.I "Re-start the SSPLIT transfer" :
.P1
if (chan->do_split) {
        if (chan->complete_split)
                qtd->error_count = 0;
        qtd->complete_split = 0;              /* back to the START-split */
        qtd->num_naks++;
        qtd->qh->want_wait = qtd->num_naks >= DWC2_NAKS_BEFORE_DELAY && ...;
        dwc2_halt_channel(hsotg, chan, qtd, DWC2_HC_XFER_NAK);
}
.P2
.NH 2
Three findings
.IP 1.
.B "THIS DRIVER'S NAK HANDLING IS ALREADY RIGHT, and the plan was wrong."
A NAK on a complete\-split means restart the start\-split, which is
exactly what the main loop does by clearing
.CW Compsplt .
The earlier prescription here \(em retry the complete\-split on NAK \(em
is contradicted by the oracle, and that is why attempt 7 regressed. That
prescription is withdrawn.
.IP 2.
.B "MULTICNT is the split retry count and this driver always writes 1."
.CW chansetup()
sets
.CW 1<<OMulticnt
unconditionally; dwc2 asks for
.B 3
on a periodic split, which is how many immediate retries the core makes
for itself. Measured here:
.CW hcchar
.CW 215e8805 ,
MC 1. None of the seven attempts looked at this field.
.IP 3.
.B "num_packets = 1 applies to EVERY split, not just periodic ones,"
and an IN split asks for
.CW max_packet
exactly rather than a rounded total.
.NH 2
AND THE RULES DO NOT GRAFT ON, which is the real finding
.LP
Both were applied \(em MC 3 for periodic splits, one packet and
.CW maxpkt
for every split \(em and the result was no reports and
.CW "mouse gone" ,
the same regression attempt 7 produced. Reverted.
.PP
.B "The reason is structural."
dwc2 can program one packet per split because it does its own
bookkeeping:
.CW chan->xfer_count
and
.CW chan->xfer_buf ,
advanced by hand
.CW "(chan->xfer_count += bcnt; chan->xfer_buf += bcnt;"
in
.CW hcd_intr.c )
plus a separate
.CW ssplit_out_xfer_count ,
and the channel re\-programmed for each packet.
.PP
.CW chanio()
is a different shape. It programs
.CW hctsiz
once for the whole transfer, lets the hardware advance
.CW hcdma
and
.CW Pktcnt
across packets, and measures progress as
.CW "n = hc->hcdma - hcdma" .
Telling it that a transfer is one packet while it still accounts for
.CW len
bytes leaves the two disagreeing, and the transfer errors.
.PP
.B "So this is not a register to find."
It is
.CW chanio 's
transfer loop restructured to program one packet per split and keep its
own offset \(em dwc2's shape \(em with the split rules then following
naturally. That is the work, and it explains why eight one\-line changes
failed: every one of them was a fragment of a different design.
.NH 2
What Phase 0 leaves for the rest
.IP \(bu
Phase 1's trace is still worth building, and more so: a restructured
loop needs a before\-and\-after of the transition sequence, which a
rate\-limited print cannot give.
.IP \(bu
Phase 2's model is unchanged in value but no longer the only oracle. Its
acceptance tests stand.
.IP \(bu
Phase 3 now has a definite shape: port
.CW chanio 's
split path to per\-packet programming with explicit bookkeeping, then
apply MC 3 and the one\-packet rules, which are known\-good only in that
design.
.NH 1
Phase 0 as originally written \(em an oracle to read \(em no board, no code
.LP
.B "Goal:"
a written state\-machine table in this document \(em phase (start or
complete) by handshake (ACK, NAK, NYET, ERR, data) by transfer type
(control/bulk, interrupt/iso) to action \(em with each row citing a
source.
.PP
.B "Sources, in order of value:"
.IP \(bu
Linux
.CW drivers/usb/dwc2/
\(em
.CW hcd.c ,
.CW hcd_intr.c ,
.CW hcd_queue.c .
This is the authoritative software side of the same core and it handles
splits properly. The functions that matter are the channel\-halted
interrupt handler and the per\-handshake handlers.
.IP \(bu
9front's
.CW sys/src/9/bcm/usbdwc.c ,
which is the
.I donor
of this driver. A diff says what this tree changed or lost, which is a
different question from what the core wants.
.IP \(bu
the DWC OTG databook's periodic split section, if it can be had.
.PP
.B "NEITHER IS ON THIS DISK."
There is no Linux source here and the qemu model is not an
implementation of splits. So Phase 0 needs one of: network access to
fetch them, or a copy dropped into the tree.
.B "This is the cheapest phase and it blocks the rest;"
do it first.
.PP
.B "Done when:"
the table is written and every row cites a file and function. A row that
cannot be sourced is marked unknown rather than guessed \(em the
guessing is what produced seven reverts.
.NH 1
PHASE 1 IS DONE, and the first thing it measured was my own reading
.LP
Committed: the trace in
.CW os/inferno/raspi3b/usbdwc.c ,
the reader
.CW tools/jtag/splittrace ,
and
.CW tests/splittrace.sh
in
.CW tests/toolchain .
Three arrays of 32\-byte records in BSS, written under their own lock,
no formatting in the measured path. Read off the board as build
1791764046 with all five devices enumerating, so the trace is a no\-op
\(em verified, not assumed.
.PP
.B "THE SHAPE BELOW WAS BUILT AS WRITTEN, with one addition that turned
.B "out to matter more than the ring."
The plan asked for one array. It got three, because a trace of the
failure alone cannot say what success looks like and the ring cannot
outlive the thing it is meant to catch.
.IP \(bu
.CW splitev ,
a ring of 512. Every split transition on every channel.
.IP \(bu
.CW splitev0 ,
256, filling once, taking only
.B "low\-speed control"
splits \(em the mouse's
.I own
control endpoint. Same device, same hub port, same translator, same
low\-speed link, and it
.I works .
The control for the experiment.
.IP \(bu
.CW splitev1 ,
64, filling once, taking only periodic events that are neither
.CW Chhltd|Nak
nor
.CW Chhltd|Ack ,
plus
.CW periodicpoll
and
.CW periodicnak
as the denominator. See
.B "WHAT THE RING CANNOT ANSWER
below; this is the array the question actually needs.
.NH 2
The two sequences, side by side
.LP
The same low\-speed mouse behind the same transaction translator, two
endpoints. This is the first time anyone has seen either.
.PP
.CW ep5.0 ,
control, which
.B works :
.P1
SS-ARM   frm 907.1  ss  -
SS-EV    frm 907.1  ss  Chhltd|Ack
PROMOTE  frm 907.1  CS  Chhltd|Ack
CS-EV    frm 907.1  CS  Chhltd|Nyet
CS-RETRY frm 907.1  CS  Chhltd|Nyet
CS-EV    frm 907.1  CS  Chhltd|Nyet
CS-RETRY frm 907.1  CS  Chhltd|Nyet
CS-EV    frm 907.1  CS  Chhltd|Nyet
TERM     frm 907.1  CS  Chhltd|Nyet
SS-ARM   frm 907.2  ss  -
SS-EV    frm 907.2  ss  Chhltd|Ack
PROMOTE  frm 907.2  CS  Chhltd|Ack
CS-EV    frm 907.2  CS  Xfercomp|Chhltd|Ack
TERM     frm 907.2  CS  Xfercomp|Chhltd|Ack
.P2
.CW ep5.1 ,
interrupt IN, which does not:
.P1
SS-ARM   frm 177.5  ss  -
SS-EV    frm 178.0  ss  Chhltd|Ack
PROMOTE  frm 178.0  CS  Chhltd|Ack
CS-EV    frm 178.1  CS  Chhltd|Nak
TERM     frm 178.1  CS  Chhltd|Nak
.P2
.NH 2
What that settles
.LP
.B "The complete\-split IS issued on the periodic endpoint."
The phase in each record is captured at the event, before this driver
touches
.CW hcsplt ,
so
.CW CS
here is evidence where the printed diagnostic's
.CW hcsplt
was not: that print read the register two statements after the clear and
reported every stall and every NAK as a start\-split. The comment in
.CW splitcontinue()
that rested on it is rewritten to say what the code does and that the
change it described was tried and reverted.
.PP
.B "The control path succeeds by RE\-STARTING, not by retrying."
Every low\-speed control stage in the trace spends all three NYET
retries, is taken as terminal, and then succeeds on the
.I next
start\-split from
.CW chanio 's
outer loop. So
.CW Splitretries
has never been what makes control work.
.PP
And the reason is in the microframe column, which is the one thing no
previous attempt could see: all three retries land in
.B "the same microframe as the start\-split"
\(em all three at
.CW 907.1 .
The translator runs the low\-speed transaction in the
.I next
microframe, so a complete\-split in the same one can only answer NYET.
The budget is not too small \(em it is spent before the translator has
begun. The re\-start at
.CW 907.2
then gets
.CW Xfercomp
on its first complete\-split, which is the translator handing back the
.I first
transaction's result.
.PP
.B "One oddity recorded and deliberately not chased:"
.CW hcdma
is
.CW ...108
through the nine records of the first attempt and
.CW ...110
on the re\-start. If the re\-start really re\-sent a SETUP from the
advanced pointer the device would have seen eight bytes of something
else \(em and enumeration says it did not. Worth understanding; not a
blocker.
.NH 2
WHAT THE RING CANNOT ANSWER, which is the real finding
.LP
The first read off the board was
.B "20983 records, 100%"
.CW Chhltd|Nak
.B "on ep5.1, with nobody touching the mouse."
.PP
.B "That is what a working host polling an idle interrupt endpoint looks
.B "like."
A boot mouse that is not moving NAKs every poll. NAK is the device's
final answer \(em "nothing" \(em where NYET is "not yet". Linux's dwc2
restarts the start\-split on exactly that: its
.CW dwc2_hc_nak_intr
carries the comment
.I "Re\-start the SSPLIT transfer" ,
which is what this driver does. So the
sequence above is
.I not
a defect, and
.PP
.B "the prescription this document started with \(em retry the periodic
.B "complete\-split on NAK \(em is withdrawn for the second time."
It came back in new clothes while this section was being drafted,
dressed as "USB 2.0 11.18.4 wants complete\-splits in consecutive
microframes, and one is not a schedule." The spec's consecutive
complete\-splits are for the NYET case, which this driver already
retries. Writing it down twice is cheaper than implementing it twice.
.PP
.B "And the microframe gap on ep5.1 is not a slip either."
.CW SS-ARM
at
.CW 177.5
and
.CW SS-EV
at
.CW 178.0
looks like three microframes lost, and it is consistent:
.P1
188.1 -> 188.4
198.5 -> 199.0
209.1 -> 209.4
219.5 -> 220.0
230.1 -> 230.4
.P2
But
.CW chanio
sets
.CW Oddfrm
to the
.I current
frame parity and
.CW splitcontinue
sets it to the
.I next
\(em deliberately opposite, at
.CW usbdwc.c:1272
and
.CW usbdwc.c:987
\(em so the start\-split executes a frame later by construction and the
complete\-split lands at X+1 or X+2, which is in spec for the first one.
The rest is handler latency. Do not build on it.
.NH 2
AND THE READER WAS DEAD. The experiment could not have run
.LP
.B "periodicpoll stops at exactly 4000, and"
.CW Maxiters
.B "is 4000."
.PP
An idle interrupt endpoint NAKs for ever \(em correctly; it is how a
device says "nothing to report" \(em and a blocking read on one is
supposed to wait. Only bulk IN was exempt from
.CW Maxiters ,
so at
.CW pollival
10 ms every
.CW read(ep5.1/data)
ended in
.CW Eio
forty seconds in and
.CW usbd 's
mouse reader stopped. The board then polled nothing for the rest of its
uptime.
.PP
.B "The tell was a number that would not move, and it had been read
.B "four times."
.CW periodicpoll
came back 4000 on four separate JTAG reads of the same boot, minutes
apart, with
.CW periodicnak
pinned at 3997 beside it. Worse, the read before those four went
.CW 3362 \(->
.CW 4000
across forty-five seconds and was taken as "polling is live" \(em but
forty-five seconds at a hundred polls a second is four and a half
thousand polls, not six hundred. That was the approach to a cap being
read as a rate.
.PP
.B "A counter that has stopped looks exactly like a counter that is
.B "high."
That is the whole lesson, and the ring had the proof all along:
.P1
usbdwc: ep5.1 type 4 dir in: 4001 attempts, last intr 00000012
hcchar 215e8805 hctsiz 00100008 hcsplt 8000c104
.P2
Nobody had grepped for it because nobody was looking for a bound. The
NAK bound two lines below in the same function already exempted
.CW Tintr
IN for precisely this reason; the two bounds now agree.
.PP
.B "What this does to everything written above, and to the plan's whole
.B "history."
The eight capped NAK prints that "the device NAKs while being moved"
rests on came from the first eighty milliseconds of a reader that then
died. The mouse was moved long afterwards, into nothing. That claim has
never been tested \(em and until this fix it
.I could
not be, because
.CW splitev1
could never fill: there was nothing polling the endpoint to fill it.
.PP
.B "Verified on silicon,"
build 1791794616 from the card:
.CW periodicpoll
2415
.CW \(->
10881
.CW \(->
11859 across three reads, past the old cap and still climbing, all five
devices enumerating, boot mouse attached on ep5.1.
.CW DATA
is still 0 \(em which is now a statement about an endpoint that is
actually being polled, and was not before.
.NH 2
So the discriminating fact is missing, and now there is an instrument for it
.LP
.B "Was anybody moving the mouse during those 20983 records?"
On that boot, no. The claim that the device NAKs
.I "while being moved"
comes from eight capped prints in the first eighty milliseconds of an
.I earlier
boot \(em not from a capture taken during motion. It is the single fact
that decides between two completely different pieces of work, and it has
never been measured.
.PP
The ring cannot measure it: 512 entries at five records a poll and a
10 ms interval is one second of history, and a JTAG read takes longer
than that, so a read after motion shows the mouse idle again. Hence
.CW splitev1 ,
which fills once and waits indefinitely. It needs no coordination with
anybody \(em
.B "and, until the"
.CW Maxiters
.B "fix in the section above, it could not have worked either,"
because nothing was polling the endpoint for it to catch. Both halves
of the instrument had to be right before the question could be put, and
only one of them was.
.PP
.B "THE EXPERIMENT HAS A PHYSICAL DEPENDENCY, stated plainly:"
the mouse has to be moved at some point after the board boots. Until it
is, an empty
.CW splitev1
means "nothing interesting has happened yet", not "the device is
silent", and
.CW splittrace
says so in those words rather than leaving the reader to supply them \(em
with
.CW periodicpoll
and
.CW periodicnak
printed as the denominator. Both branches of that verdict are in
.CW tests/splittrace.sh ,
because those are the only lines in the tool that draw a conclusion
rather than print a field.
.NH 2
The measurement, in two parts, and what each part can say alone
.LP
.B "The controller half"
is
.CW periodicdata
in
.CW usbdwc.c ,
read by
.CW tools/jtag/splittrace :
complete\-splits that carried
.CW Xfercomp .
It counts at the controller, so it does not depend on any Dis process
being alive to read the result \(em which matters, because on this
board none is.
.PP
.B "The other half"
is
.CW ptrwatch (1),
new, which reads
.CW /dev/pointer
for a bounded time and says how many events arrived.
.B "It exists because nothing on this board reads that queue:"
.CW mousecheck()
in the board's init gives up after twenty\-five seconds and reports
.CW USB-MOUSE-NONE ,
so a mouse moved by hand later produces events nobody sees. It is
bounded because
.CW tools/jtag/boardrun
runs one command and waits for it, so a
.CW cat
of
.CW /dev/pointer
wedges the poller \(em a self\-inflicted wedge this tree has paid for
once already.
.PP
.B "Together they locate the loss."
Neither can alone:
.P1
PTRWATCH-OK                       the whole path works
PTRWATCH-NONE, periodicdata > 0   lost between the controller
                                  and /dev/pointer
PTRWATCH-NONE, periodicdata == 0  the device never answered
.P2
.B "The procedure is now one command:"
.P1
sh tools/jtag/mousecapture
.P2
It reads the counters, says
.B "MOVE THE MOUSE NOW
for twenty seconds, watches
.CW /dev/pointer
through
.CW ptrwatch
for exactly that window, reads the counters again, and gives a verdict
on the
.I difference .
.PP
.B "On the difference and not the value,"
because an absolute reading cannot tell a report delivered during the
window from one delivered an hour ago \(em and this document already
records one conclusion published from an absolute counter that had
stopped moving.
.PP
.B "And it checks the instrument before it reads the result."
If the poll count did not move, the endpoint was not being polled and it
says
.CW "CANNOT SAY" ,
which is a statement about the instrument rather than about the device.
Verified live with nobody at the mouse: 984 polls and 984 NAKs in an
eight\-second window, which is 123 a second against the hundred a second
of a 10 ms interval, so the reader is alive and running at the right
rate.
.PP
The two awkward verdicts are the reason it is a tool and not a pair of
commands. Data counted at the controller with no events at
.CW /dev/pointer
locates the loss
.I downstream ;
events at
.CW /dev/pointer
with no data counted is reported as
.B CONTRADICTORY
with the counter named as the suspect, rather than as a success.
.NH 2
The periodic NYET deferral: four attempts, four reverts, and why
.LP
Phase 1 found a real protocol error and it was fixed four ways, none of
which held. The attempts are written out because the reason is
structural and the next reader will otherwise repeat them in the same
order.
.PP
.B "The error."
On a NYET,
.CW splitcontinue
re-enables the channel at once, for every transfer type. Linux's dwc2
is explicit that this is right only for control and bulk \(em the
comment at the head of
.CW dwc2_hc_nyet_intr
reads
.I "NYET on CSPLIT / re-do the CSPLIT immediately on non-periodic"
\(em and routes interrupt and isochronous endpoints to
.CW dwc2_halt_channel
with
.CW DWC2_HC_XFER_NYET ,
which re-queues the channel at the endpoint's
.I next
scheduled microframe, or calls it a transaction error if the scheduled
window has already passed. One complete\-split per microframe, under a
schedule, with an end.
.PP
The trace confirms the error rather than suggesting it: a periodic NYET
and its retry carry identical
.CW hfnum
values.
.PP
.B "The four attempts."
.CW splitcontinue
runs in the interrupt handler and cannot sleep, so the deferral has to
come from the SOF interrupt: put the channel in a mask, unmask
.CW Sofintr ,
and let the
.CW Sofintr
arm of
.CW dwcinterrupt()
re-enable it.
.B "Each attempt was judged by sampling"
.CW hfnum
.B "at the NYET and again at the re-arm,"
eight pairs at a time, so the claim could be checked instead of
believed:
.P1
unmask Sofintr                        6 of 8 SAME uframe
unmask, clearing gintsts first        8 of 8 SAME uframe
hand the mask over at handler end     7 of 8 SAME uframe
hand over AND clear at the hand-over  8 of 8 SAME uframe
.P2
.B "The reason."
.CW dwcinterrupt()
reads
.CW gintsts
once into a local and then services
.CW Hcintr
and
.CW Sofintr
from that one value, so a deferral raised in the
.CW Hcintr
arm is serviced by the
.CW Sofintr
arm of the same call \(em in the microframe it was deferred from.
Handing the mask over at the end of the handler does not help, because
the BCM interrupt controller has no EOI and
.CW gintsts.Sofintr
is still latched from the SOF that began the current microframe, so
unmasking re-enters at once. Clearing that latch does not help either:
the next SOF is 125 microseconds away and the whole NYET-to-re-arm path
is shorter than that. The two samples that
.I did
move were both in microframe 6, where the existing
.CW "(hfnum&7) != 6"
guard makes the handler wait \(em which is what identified the
mechanism.
.PP
.B "And the last attempt made it measurably worse."
The NYET rate went from 173 in 4000 polls to 680 in 1004 \(em
sixteenfold \(em with
.CW DATA
still 0. Reverting restored 80 in 4000, so that is a real regression and
not a change that merely failed to help.
.PP
.B "Why it is not pursued further, and this is the part that is a
.B "decision rather than a measurement."
96% of this endpoint's complete\-splits are answered Nak on the
.I first
one with no NYET anywhere near them. A correct deferral would alter 4%
of the traffic and is not the reason the mouse does not move. Doing it
properly needs a microframe schedule the channel is re-queued against
\(em dwc2's
.CW next_active_frame
and
.CW num_hs_transfers
\(em which is Phase 3's restructure and belongs
.I in
it rather than in front of it. The finding is recorded in
.CW splitcontinue()
beside the code it describes.
.PP
.B "What was kept:"
nothing in the driver's behaviour, and two things otherwise \(em this
section, and the note in
.CW splitcontinue() .
.B "What the instrument cost in defects of its own:"
two. A
.CW words()
helper was called without being defined, so two register dumps came
back empty and a loop over
.CW min(n,\ len(d),\ len(r))
ran zero times and printed
.I "all 8 moved to a later microframe"
from no samples at all \(em the only hint being a
.CW "command not found"
two lines above the verdict. And the comparison was
.CW d[i]\ ==\ r[i]
on the raw register, where
.CW hfnum
carries
.CW FRREM
\(em the time left in the microframe \(em in its top half, so two reads
in the same microframe differ almost always: it printed
.CW ok
beside eight pairs of which six showed
.I identical
frame.uframe one column to the left. Both are fixed in the reader; a
verdict is now refused outright when the samples read back are fewer
than the count claimed.
.NH 2
The two branches, and what each one makes the next piece of work
.IP \(bu
.B "Non\-NAK events appear with motion."
The split path moves bytes and the defect is downstream: the data, the
.CW /dev/pointer
reader, or the check that reports
.CW USB-MOUSE-NONE .
Then
.CW "pkt 2 xfer 8"
becomes live \(em ep5.1 is programmed two packets for an 8\-byte read
with
.CW maxpkt
5, because
.CW HOWMANY(8,5)
is 2 \(em and the records
.I after
the first data will show what the core does with
.CW Pktcnt
1 still outstanding on a split channel. That is where dwc2's
.CW "num_packets = 1"
would matter, and the one\-packet clamp can be re\-judged on the sequence
instead of on whether the pointer moved.
.IP \(bu
.B "Still 100% NAK with motion."
The device never has data on ep5.1 and the split path is exonerated. The
next discriminator is a
.CW "GET_REPORT(Input)"
over ep5.0, which every HID device must answer: a report over the
control pipe while ep5.1 NAKs puts the fault on the interrupt pipe;
nothing over either puts it on the HID set\-up payloads.
.PP
.B "Phase 3 waits for that answer."
Restructuring
.CW chanio 's
split path to per\-packet programming is a large change justified by
Phase 0's reading of dwc2, and it is the wrong thing to start if the
bytes are not being lost there. The capture costs one hand movement.
.NH 1
Phase 1 as originally written \(em the shape, kept for the record
.LP
.B "Goal:"
see one failing transaction end to end, without prints.
.PP
.B "Shape:"
a fixed array in BSS, one entry per split state transition:
.P1
struct Splitev {
        uint    hfnum;          /* frame and microframe */
        uint    hcchar;
        uint    hcsplt;
        uint    hcint;
        uint    hctsiz;
        uint    hcdma;
        ushort  chan;
        ushort  tag;            /* which transition */
};
.P2
written at: start\-split armed, start\-split completed, promotion to
complete\-split, complete\-split armed, complete\-split completed, and
every terminal event. 512 entries is 16 KB and covers several poll
intervals.
.PP
.B "Why an array and not prints:"
no formatting cost in the path being measured, no 16K ring to overflow,
no rate limit to hide the interesting event, and the whole sequence is
present rather than the first eight of it. Read it over JTAG with a new
.CW tools/jtag/splittrace
that decodes each entry, the way
.CW tools/jtag/vmheld
reads the collector's counters.
.PP
.B "Done when:"
.CW splittrace
prints the full transition sequence of a single interrupt transfer with
microframe numbers, and the sequence is stable across two boots. That is
the first time anyone will have seen what this driver actually does on
the wire, rather than its first eight events.
.PP
.B "This phase alone may answer it."
A sequence showing, say, the complete\-split landing two microframes
late, or the core re\-arming the channel between transitions, is the kind
of thing none of the seven attempts could have seen.
.NH 1
Phase 2.  Split support in the qemu model \(em the reproducible oracle
.LP
.B "Goal:"
a model that implements SSPLIT and CSPLIT with a translator that buffers
one transaction per periodic endpoint per microframe, so the path can be
driven, inspected and regression\-tested off the board.
.PP
.B "THE ACCEPTANCE TEST IS THE WHOLE POINT, and it is not `the mouse works'."
A model written from the specification can easily encode the same
misunderstanding that produced seven reverts, after which model and
driver agree and silicon still fails. So the model must first
.B "REPRODUCE KNOWN SILICON BEHAVIOUR:"
.IP 1.
with the stale\-accumulator bug reverted in the driver, the model must
show
.B "no full-speed enumeration"
behind a hub \(em the state the board was in this morning.
.IP 2.
with the current driver and an
.B idle
low\-speed interrupt endpoint behind the hub, the model must show the
periodic complete\-split answered
.B NAK ,
and the driver must
.B "keep polling indefinitely."
.B "THIS ROW WAS WRITTEN WRONG THE FIRST TIME"
and the correction is the main thing Phase 1 taught: it said "the model
must show the periodic complete\-split being NAK'd, which is the state
the board is in now", as though the NAK were the defect. It is not. An
idle interrupt endpoint NAKs every poll, correctly, and dwc2 restarts
the start\-split on exactly that. A model that treated a NAK as a
failure would encode the misunderstanding this phase exists to avoid.
.IP 3.
with
.CW Maxiters
.B "restored to its old form"
\(em no exemption for interrupt IN \(em the model must reproduce
.P1
usbdwc: ep5.1 type 4 dir in: 4001 attempts, ...
.P2
after about forty seconds of an idle endpoint, and must
.I not
produce it with the exemption in. That is a known silicon failure with
a known fix and a forty\-second repro, which makes it the cheapest row
on this list to check and the one most likely to catch a model that
does not really poll.
.IP 4.
with a high\-speed device, the model must be unchanged from today.
.PP
Only when a model reproduces two known failures and one known success is
it worth debugging against.
.B "If it cannot reproduce them, the model is wrong and says nothing"
\(em and that is a result worth having early rather than after a fix
built on it.
.PP
.B "Cost:"
this is the expensive phase, days rather than hours, and it touches
.CW tools/qemu-patches
(a twenty\-first patch) and
.CW docker/Qemu.Dockerfile 's
build.
.B "It is also the only route to a regression test for any of this,"
and the coverage hole it closes is the one that let a total split
failure pass 52 green markers.
.NH 2
Phase 2 surveyed: it is two device models, not one, and the first is the blocker
.LP
.CW hw/usb/hcd-dwc2.c
and
.CW hw/usb/dev-hub.c
read in
.CW /Users/npe/src/qemu-v10.1.3 ,
with
.CW include/hw/usb/dwc2-regs.h .
What follows is cited rather than recalled.
.NH 3
The blocker: nothing in qemu can make a guest emit a split at all
.LP
A driver only sets
.CW Spltena
for a full\- or low\-speed device behind a
.B high\-speed
hub. There is no such hub in the tree:
.IP \(bu
.CW dev-hub.c:124
has
.CW ".bcdUSB = 0x0110" ,
and its
.CW desc_hub
carries only a
.CW .full
descriptor with no
.CW .high ,
so
.CW usb_desc_init()
gives it
.CW USB_SPEED_MASK_FULL ,
.CW usb_pick_speed()
picks FULL, and
.CW dwc2_attach()
writes
.CW HPRT0.PRTSPD
= FULL. The driver then never sets
.CW Spltena .
Downstream ports register LOW|FULL only
.CW "(dev-hub.c:617)."
.IP \(bu
There is no transaction translator anywhere:
.CW "grep -rni 'transaction translator' hw/usb/"
finds nothing, and EHCI says so in comments \(em
.CW hcd-ehci.c:1308
.I "TODO check 4.12 for splits"
and
.CW ":1747"
.I "TODO: split transfers are not implemented" .
.IP \(bu
.B "And our own"
.CW usb-lan9514
.B "is not a hub."
.CW hw/usb/dev-lan9514.c:4
says so in its own second comment line: "the ethernet function only:
the hub in front of it on a Raspberry Pi" is not modelled. It
.I is
high\-speed
.CW "(.bcdUSB"
.CW 0x0200 ,
a
.CW .high
descriptor at
.CW ":296" )
but it has no downstream ports \(em no
.CW usb_register_port
call in the file at all.
.PP
So Phase 2's first half is a
.B "high-speed, TT-advertising hub,"
which is a second device model: a
.CW .high
descriptor,
.CW bDeviceProtocol
1 or 2, the hub descriptor's TT fields, and downstream ports advertising
.CW USB_SPEED_MASK_HIGH .
Either that or downstream ports added to
.CW usb-lan9514 ,
which is closer to the board's real topology and is probably the better
buy.
.NH 3
The controller half, with the functions named
.LP
.B "hcsplt is never read, confirmed by grep and not by belief."
.CW "grep -n 'index + 1' hw/usb/hcd-dwc2.c"
finds nothing;
.CW hcsplt
appears only as a trace\-table name
.CW "(hcd-dwc2.c:964)"
and an accessor macro
.CW "(hcd-dwc2.h:137)"
\(em and
.B "none of those accessor macros is used anywhere either,"
the
.CW .c
hand\-indexes
.CW s->hreg1[] .
.CW HCSPLT_*
in
.CW dwc2-regs.h:772-784
are defined and referenced from no
.CW .c
file.
.CW HCCHAR_LSPDDEV
.CW "(:765),"
.CW HCCHAR_ODDFRM
and
.CW HCCHAR_MULTICNT
are likewise never referenced:
.B "the model is speed-blind below the root port."
.PP
.B "And the two interrupt bits the split protocol needs do not exist in
.B "the model."
.CW HCINTMSK_NYET
and
.CW HCINTMSK_ACK
are never set anywhere \(em nor are
.CW DATATGLERR ,
.CW FRMOVRUN ,
.CW BNA
or
.CW AHBERR .
A start\-split completion is ACK+CHHLTD and a not\-ready complete\-split
is NYET+CHHLTD, so both have to be added.
.PP
.B "The first transaction runs synchronously inside the CHEN store:"
.CW dwc2_hsotg_write
.CW ":1156"
\(->
.CW dwc2_hreg1_write
.CW ":1051"
\(->
.CW dwc2_enable_chan
.CW ":658"
\(->
.CW dwc2_handle_packet
.CW ":287"
.CW usb_handle_packet()
\(-> the HCINT/HAINT/IRQ raise at
.CW ":384-387" ,
all before the guest's store retires. Two async paths exist
.CW "(USB_RET_ASYNC"
at
.CW ":305" ,
and
.CW needs_service
with
.CW dwc2_work_bh
at
.CW ":567" )
but neither defers the
.I first
attempt. Making a start\-split not complete synchronously means
.CW qemu_bh_schedule ,
as
.CW ":659"
already does.
.PP
.B "Device lookup is already hub-transparent,"
which is one piece of luck:
.CW dwc2_find_device
.CW "(:183)"
calls
.CW usb_find_device() ,
which recurses through
.CW usb_hub_find_device()
.CW "(dev-hub.c:289),"
and hub completions already forward upstream. A plain
.CW HCCHAR.DEVADDR
lookup is enough; resolving by
.CW "HCSPLT.HUBADDR / PRTADDR"
is optional.
.NH 3
A modelling defect found on the way, which matters to any TT schedule
.LP
.CW dwc2_frame_boundary()
.CW "(:149-166)"
computes
.P1
frcnt = (uint16_t)((now - s->sof_time) / s->fi);
s->frame_number = (s->frame_number + frcnt) & 0xffff;
.P2
and
.CW s->fi
is
.CW "USB_FRMINTVL - 1"
= 11999, a
.B bit\-time
count being used to divide
.B nanoseconds .
At expiry
.CW "now - sof_time"
is about
.CW usb_frame_time ,
so FRNUM jumps by roughly 83 per 1 ms tick and 10 per 125\ \(mcs tick \(em
never by one.
.B "So a TT must not schedule against HFNUM+1;"
it has to use the
.CW eof_timer
tick itself or its own counter. And it means the microframe numbers this
driver reads under qemu are not microframe numbers, which is worth
knowing before any of Phase 1's microframe reasoning is checked against
the model.
.PP
Note also that
.CW usb_frame_time
is 125\ \(mcs only when the
.I root\-port
device is high\-speed
.CW "(:441-455),"
1 ms otherwise, and that HFIR writes are accepted and ignored
.CW "(:893)"
\(em the interval is not guest\-programmable.
.NH 2
Phase 2's first half is DONE, and a mutation test says it is not enough
.LP
.B "Committed:"
.CW tools/qemu-patches/0028 ,
a USB 2.0 hub for
.CW usb-hub
behind
.CW usbver=2 ,
and
.CW raspi3b-split
in
.CW tools/boardsuite \(em
.B "the first configuration in this tree that runs the dwc2 split path
.B "at all."
.PP
The board's real topology, in qemu, for the first time: a high\-speed hub
with a high\-speed ethernet child and full\-speed HID children behind its
translator. The guest says so itself:
.P1
usbd: ep1.0: port 1: high ep2.0 vid 0409 did 55aa class 9
usbd: ep2.0: port 1 status 0x10501 (high-speed (no split))
usbd: ep2.0: port 2 status 0x10101 (full-speed (needs split))
usbd: ep2.0: port 2: full ep4.0 vid 0627 did 0001 class 0
usbd: ep4.0: boot mouse on ep4.1
.P2
Baseline 49 markers, mouse, keyboard and tablet all \-OK, and the one
known \-FAIL the other Pi arms already carry. It is also the first time
the LAN9514 model has run at high speed \(em behind the auto\-created
full\-speed hub it never could, so
.B "every ethernet number this suite has produced for the Pi boards is a
.B "full-speed number."
.NH 3
Two things in the command line were wrong first, and both looked fine
.IP \(bu
.B "The hub has to come FIRST."
qemu's dwc2 has one port, so
.CW usb_claim_port()
creates a hub of its own as soon as a non\-hub device finds the last port
free \(em with
.I default
properties, which is full speed. Written after the other devices,
.CW usbver=2
ended up on an
.B empty
hub hanging off port 4 while the auto\-created full\-speed hub took the
root port and everything landed behind it. The boot looked entirely
normal and the guest reported "full\-speed (needs split)" about the
children of a full\-speed hub.
.B "An option accepted and doing nothing."
.IP \(bu
.B "The tablet has to be there."
Left out, and it cost a marker: the pointer check reports
.CW USB-TABLET
and
.CW USB-MOUSE
out of one window and the harness sends tablet positions whatever is
attached, so the mouse's own events arrived instead and the check said
.CW USB-TABLET-FAIL
\(em a \-FAIL and not a \-NONE, because events
.I did
arrive. A configuration carrying a permanent known \-FAIL teaches people
to ignore a red line.
.NH 3
AND THE MUTATION TEST FAILS, which is the result worth having
.LP
The per\-transfer accumulator clear was removed from
.CW chanio() \(em
the defect that kept every full\- and low\-speed device off the real
board's hub until 11 October, and the one this plan's acceptance row 1
names \(em and both configurations were run against the mutant:
.P1
raspi3b-split: ok 49 markers and 1 known -FAIL
raspi3b-usb:   ok 52 markers and 1 known -FAIL
.P2
.B "Neither noticed."
So the hub makes the split path
.I run ;
it does not make it
.I observable .
.PP
That is exactly the outcome this phase's acceptance list was written to
force \(em "if it cannot reproduce them, the model is wrong and says
nothing, and that is a result worth having early rather than after a fix
built on it" \(em and it arrived before any fix was built on it. The
remaining work is the translator in
.CW hcd-dwc2.c ,
which never reads
.CW HCSPLT
and never raises
.CW ACK
or
.CW NYET ,
so every split currently succeeds by accident: the model simply performs
the transfer the start\-split asked for and reports it done.
.PP
.B "One difference from silicon, already visible and worth keeping:"
on the board a periodic start\-split is answered
.CW Ack
and the complete\-split is answered
.CW Nak ;
under this configuration the
.I start\-split
is answered
.CW Nak
\(em because the model never raises
.CW ACK ,
so
.CW splitcontinue()
never promotes. The failure is in the same place and has a different
shape, which is precisely the discrepancy a translator has to close.
.NH 2
PHASE 2 IS DONE. The acceptance list, answered row by row
.LP
.B "Committed:"
.CW tools/qemu-patches/0029 ,
a transaction translator in
.CW hcd-dwc2.c .
One buffered result per channel: a start\-split performs the transaction
against the downstream device and reports the hub's
.CW ACK|CHHLTD
with no data; the matching complete\-split delivers the buffered answer
through the existing
.CW "send == false"
tail, so the DMA write\-back and the
.CW "HCTSIZ / HCDMA"
bookkeeping happen exactly once; nothing buffered is answered
.CW NYET .
.NH 3
Row by row
.IP 1.
.B "The stale accumulator: STRUCTURALLY UNREACHABLE, and that is the
.B "answer rather than a failure to try."
It is a
.B race
\(em the handler ORs sticky bits into
.CW ctlr->hcintr
and a later stage consumes an earlier stage's event \(em and a model
that runs the whole transfer
.I synchronously
inside the
.CW CHEN
store has no race to hit. Mutated out and measured: both arms green.
This row can never be met by this model and asking for it again would
be work with no possible result.
.IP 2.
.B "The periodic complete-split NAK: MET, exactly."
With the translator the guest prints
.P1
usbd: ep2.0: port 2: full ep4.0 vid 0627 did 0001 class 0
usbd: ep4.0: boot mouse on ep4.1
usbdwc: ep4.1 INTR-IN NAK 1: hcint 00000012 COMPLETE-split
.P2
which is what a real Pi 3B prints. Before the translator the
.I start\-split
was the thing NAK'd, because the model never raised
.CW ACK
and
.CW splitcontinue()
never promoted. The word
.CW COMPLETE
is now an evidence line in
.CW tools/boardsuite/run ,
and it was checked that it rejects the pre\-translator text.
.IP 3.
.B "The 4001 attempts: RUN, AND NOT REPRODUCIBLE HERE \(em a finding
.B "about the acceptance list."
With
.CW Maxiters
restored to its old form the configuration stayed green and no
.CW "4001 attempts"
appeared, because the harness drives the mouse, the keyboard
.I and
the tablet, so every periodic endpoint has data within a few polls: the
highest
.CW iters
in the whole log is 5, against the 4000 the bound needs. The row needs
an interrupt endpoint nobody touches, and this configuration has none.
.IP 4.
.B "A high-speed device unchanged: MET."
.CW raspi3b-usb
reported 52 markers and one known \-FAIL before and after every change
here, including under all three mutations.
.NH 3
The mutation table, which is what the phase is actually worth
.P1
mutant                              split cfg   plain cfg
----------------------------------  ---------   ---------
none                                ok 49       ok 52
stale interrupt accumulator (RACE)  ok 49       ok 52
exact-equality split phase test     FAIL        ok 52
old Maxiters (no Tintr IN exempt)   ok 49       ok 52
.P2
.B "The third row is the whole return on this phase."
The exact\-equality phase test is the real defect that kept every full\-
and low\-speed device off the board's hub until 11 October, and
.B "only the split configuration notices it."
That is the coverage hole closed: a change to the split path can fail in
CI for the first time.
.PP
.B "The second and fourth rows are the bound, and recording them is as
.B "valuable as the third."
This catches protocol defects and not timing ones, and it cannot see a
defect in an endpoint the harness is busy driving.
.NH 3
Three things in the translator had to be got right, each after being got wrong
.IP \(bu
.B NYET ,
not
.CW NAK ,
when nothing is buffered. For a periodic endpoint they are different
answers: NYET is "the translator has not finished" and NAK is the
.I device's
"nothing to report", which is terminal and sends the guest back to a
fresh start\-split.
.IP \(bu
.B "A complete-split is answered BEFORE the device lookup,"
because on the wire it is addressed to the hub.
.B "SET_ADDRESS is the proof."
qemu applies the address at the SETUP stage, so the device moves during
that stage's start\-split and the matching complete\-split, still
correctly addressed to 0, finds nothing. With the lookup first \(em and a
failure returning silently, with no interrupt \(em every full\-speed
device wedged at its new address:
.P1
usb_set_addr dev 4
usb_dwc2_enable_chan ch 0 dev 0x0 ep 0
no device at addr 0 ep 0 hcsplt 8001c102
usbdwc: ep4.0 completion timeout channel 0
.P2
.IP \(bu
.B "The ctrl/bulk NAK auto-retry is skipped on a split channel."
It leaves the channel enabled and sets
.CW needs_service ,
so
.CW dwc2_work_bh
re\-issues every 250\ \(mcs \(em right when the model is the only one
retrying, wrong when the guest's split state machine is.
.NH 3
What the model still cannot be used to judge
.LP
.B "The NYET path in the model is dead code today."
A start\-split buffers its answer synchronously, so the matching
complete\-split always finds one and the
.CW NYET
branch never runs. That means
.CW Splitretries
cannot be judged here, and
.B "neither can the microframe deferral"
\(em the four attempts recorded above were all on silicon and would show
nothing under qemu, which has no usable microframe clock anyway. Both
remain board\-only questions.
.NH 3
The change list
.IP 1.
.CW dwc2_enable_chan()
.CW "(:611)"
\(em read
.CW "s->hreg1[index + 1]" ,
branch on
.CW "Spltena / Compsplt,"
decode
.CW "HUBADDR / PRTADDR / XACTPOS."
.IP 2.
.CW dwc2_handle_packet()
.CW "(:223)"
\(em read hcsplt beside
.CW ":227-229" ,
emit
.CW ACK
and
.CW NYET
in the
.CW ":357-389"
region, and force per\-maxpacket sizing for splits, bypassing the
.CW p->small
heuristic at
.CW ":652-656" .
.IP 3.
.CW dwc2_hreg1_write()
.CW "(:986)"
\(em a
.CW HCSPLT
case if write masking is wanted; today it raw\-stores.
.IP 4.
.CW DWC2Packet
.CW "(hcd-dwc2.h:45-58)"
\(em split phase, hub address, port, position, and the buffered result
so a complete\-split can replay it.
.B "This must be mirrored in"
.CW vmstate_dwc2_state_packet
.CW "(hcd-dwc2.c:1418)"
.B "or migration breaks silently."
.IP 5.
a deferral hook \(em
.CW dwc2_frame_boundary()
for a real per\-frame translator pump, or
.CW dwc2_work_bh()
plus
.CW needs_service
for a cheaper 250\ \(mcs retry.
.IP 6.
.CW dwc2_reset_enter()
.CW "(:1246" ,"
loop at
.CW ":1331" )
\(em clear the new per\-channel split state beside
.CW needs_service .
.IP 7.
.CW hw/usb/trace-events
.CW "(:187-235)"
\(em trace points for the split phase.
.PP
.B "And there is no generic qemu helper for `one transaction per
.B "frame'."
The in\-tree template is the model's own
.CW needs_service
+
.CW dwc2_work_bh
+
.CW frame_timer
triple, which EHCI copies. USB core's
.CW usb_ep_combine_input_packets()
and friends are pipelining aids, not schedulers.
.NH 1
PHASE 3: the first piece has landed, and the rest still waits on one hand
.LP
.B "Landed:"
one packet per periodic split, with
.CW USB-SPLITPKT-OK
as a marker that can fail.
.PP
A translator buffers one transaction per periodic endpoint per
microframe, and dwc2 programs
.CW "num_packets = 1"
for every split. ep5.1 is
.CW maxpkt
5 and usbd reads into an 8\-byte buffer, so
.CW HOWMANY(8,5)
is 2: this driver had been asking for two packets out of one split on
every mouse poll since the path was written.
.B "Periodic only,"
because control splits are asynchronous and have a measured working
baseline on this board \(em 45 completions, 401 bytes, zero moving
nothing \(em and changing them would trade a known\-good path for
conformance with nothing observable to gain, which is how the previous
eight attempts were chosen.
.PP
.B "This is the first change on this path with a gate that was shown to
.B "fail."
It was also the first with a gate that was shown
.I not
to:
.NH 2
The gate was wrong first, and the mutation test is what found it
.LP
An evidence line
.CW "INTR split: asked 4 got 4"
was tried. The suite asserts that a pattern is
.B PRESENT ,
and
.CW "got 4"
is present even with the clamp removed, because a device that happens to
return one packet's worth still moves exactly
.CW maxpkt .
With the clamp out, one run printed
.CW "got 8"
and
.CW "got 4"
in the same boot and stayed
.B GREEN ;
a second printed only
.CW "got 8"
and went red.
.PP
.B "A presence check cannot assert an absence, and a gate that fires on
.B "one run in two is not a gate."
So the driver says which programming it used, once per boot \(em
.CW USB-SPLITPKT-OK
or
.CW -FAIL ,
two different markers, so the diff catches the flip. Re\-run with the
clamp removed it now fails three ways: the marker diff, the known\-FAIL
set, and the evidence line. Baseline 50 markers.
.PP
And two counters for the board, where no marker diff exists:
.CW pkt1
and
.CW pktn ,
read by
.CW splittrace .
.B "They count PROGRAMMINGS, one per transfer and not one per attempt,"
so 37 and 9 against 4659 periodic start\-splits armed is not an
inconsistency \(em one blocking
.CW read()
of the mouse is a single programming that has looped thousands of times.
.PP
On silicon, build 1791803556:
.CW "USB-SPLITPKT-OK periodic split programmed 1 packet of 5" .
.NH 2
What is left of Phase 3, and why it is not started
.LP
dwc2's full shape is the restructure Phase 0 described: keep
.CW chan->xfer_count
and
.CW chan->xfer_buf
and advance them per packet, re\-programming the channel each time,
instead of programming
.CW hctsiz
once and measuring
.CW "n = hc->hcdma - hcdma" .
The one\-packet clamp above is the part of it that could be judged
without the device cooperating; the rest cannot.
.PP
.B "And three measurements now argue it may not be needed at all:"
.IP \(bu
the control half of the split path demonstrably works \(em 45
completions, 401 bytes,
.CW "MOVING NOTHING 0" ;
.IP \(bu
every start\-split promotes:
.CW "taken as terminal 0"
over thousands of polls, so the handshake is not the problem;
.IP \(bu
and the periodic failure is the
.I device
answering NAK, which is the correct answer from an endpoint with nothing
to report.
.PP
So the evidence that would justify the restructure is narrow and
specific: a moved mouse delivering data at the controller with the bytes
short or lost, or delivering nothing at all while
.CW GET_REPORT
over its control pipe succeeds. One command now produces that evidence
\(em
.CW "sh tools/jtag/mousecapture" \(em
and until it is run, building the restructure would be the ninth change
on this path chosen by reading rather than by measurement.
.NH 1
Phase 3 as originally written \(em kept for the record
.LP
With Phase 0's table and Phase 1's trace, and ideally Phase 2's model:
change the driver until the trace matches the table.
.PP
.B "The rule that the seven attempts broke, written as a gate:"
a change ships only when it moves a
.I measured
quantity toward the table, and the trace shows the transition sequence
before and after. Not when it is a correct reading of the
specification \(em all seven were.
.PP
.B "If the model passes and silicon still fails,"
the model is wrong about the hub rather than the driver being wrong, and
Phase 2's acceptance list grows a row. Say that rather than patching the
driver to suit the model.
.NH 1
PHASE 4 IS DONE, all three items
.IP 1.
.B "A configuration that can fail when splits break:"
.CW raspi3b-split ,
with
.CW USB-MOUSE-OK
as the delivered\-report marker and five evidence lines for the
enumeration \(em including
.CW "INTR-IN NAK 1: hcint 00000012 COMPLETE-split" ,
the one line only a two\-phase handshake can print, checked to reject
the pre\-translator text. The mutation table above is what it is worth.
.IP 2.
.B "The six split counters, readable."
They were fields of
.CW Ctlr
and the only way to see them was a print, capped at a handful per boot.
They now live in a
.CW Splitstat
whose address
.CW reset()
publishes in
.CW dwcsplitstat ,
and
.CW tools/jtag/splittrace
follows the pointer.
.B "A struct and a pointer, not six globals:"
six globals would attribute one controller's counts to whichever
controller bumped them, and a Pi 3B has exactly one dwc2, so nothing
could tell the difference \(em which is why it is worth not writing it
that way.
.IP 3.
.B "The annotation."
.CW USB-MOUSE-OK
and
.CW USB-KBD-OK
in
.CW doc/inferno-ports.ms
now say what they were measured on, and the correction went further than
the plan asked: the devices are not on the root port at all but behind a
hub qemu creates by itself, at
.B full
speed \(em which is also why every ethernet number this suite has
produced for the Pi boards is a full\-speed number.
.NH 2
What the counters say on silicon, which is the point of having them
.P1
splits completed 45, of them moving bytes 28 (401 bytes),
  MOVING NOTHING 0
start-splits promoted to complete-split 5561, taken as terminal 0
.P2
.B "Both zeroes are the interesting numbers."
.CW "MOVING NOTHING 0"
is the stale\-accumulator fix confirmed by a counter rather than by a
marker \(em that counter is exactly the signature of a split reported
complete without its data stage having run, which is what the bug did to
every IN transfer.
.CW "taken as terminal 0"
says the Ack requirement in
.CW splitcontinue()
has never once rejected a start\-split on this board, which retires the
last of the doubt about the periodic no\-Ack promotion that was tried and
reverted.
.PP
And 5561 promotions against 45 completions is the idle mouse, stated as
a ratio: every start\-split promotes, and the complete\-split that
follows is answered NAK.
.NH 1
Phase 4 as originally written \(em the three items, kept for the record
.IP \(bu
a boardsuite configuration that exercises a full\- and a low\-speed
device behind a hub, with markers for enumeration
.I and
for a delivered interrupt report. Today no configuration can fail when
splits break.
.IP \(bu
the split counters already in
.CW Ctlr
.CW splitok ,
.CW splitokdata ,
.CW splitbytes ,
.CW splitempty ,
.CW splitpromote ,
.CW splitterm )
exposed through
.CW vmheld
so a regression is a number rather than an absence.
.IP \(bu
.CW USB-MOUSE-OK
in
.CW doc/inferno-ports.ms
annotated with what it was measured on. The existing
.CW USB-MOUSE-OK
and
.CW USB-KBD-OK
records there are
.B "QEMU, root-port, non-split"
and have never meant anything about this path.
.NH 1
Order, cost, and what blocks what
.P1
Phase 0  oracle to read      hours    BLOCKED: needs the source fetched
Phase 1  binary trace        hours    independent; may answer it alone
Phase 2  qemu splits         days     wants Phase 0's table first
Phase 3  the fix             ?        wants 0 and 1; better with 2
Phase 4  keep it fixed       hours    wants 2 for the CI half
.P2
.PP
.B "Start with Phase 1 if the sources cannot be had today."
It needs nothing but the board, it is the instrument whose absence
confounded two diagnostics already, and it is the one phase that might
make the rest unnecessary.
.NH 1
What not to do, from seven attempts
.IP \(bu
.B "Do not test a hypothesis by changing the driver and looking at the mouse."
The mouse is a single bit of output at the end of a long chain; it
cannot distinguish a fix from a no\-op, and it took an A/B with a
verified probe to show that one change had done nothing at all.
.IP \(bu
.B "Do not trust a diagnostic that reads a register the code also writes."
Two did. Capture the value where the state is true and print the
capture.
.IP \(bu
.B "Do not read a green"
.CW raspi3b-usb
.B "as evidence about splits."
It cannot fail when they break.
.IP \(bu
.B "Do not leave an unattributed change in the driver."
Seven are reverted; a reader would take any of them for a deliberate
design.
