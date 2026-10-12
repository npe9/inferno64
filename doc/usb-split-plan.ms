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
Phase 1.  A trace that can show a sequence \(em board, no behaviour change
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
