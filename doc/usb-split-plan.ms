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
.CW ( "chan->xfer_count += bcnt; chan->xfer_buf += bcnt;"
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
anybody.
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
with the current driver, the model must show the periodic
complete\-split being
.B NAK'd ,
which is the state the board is in now.
.IP 3.
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
.NH 1
Phase 3.  Fix it
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
Phase 4.  Make it stay fixed
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
