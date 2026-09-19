.TL
AX.25 over LoRa: what is duplicated, what is missing, and what it looks like as files
.AU
.PP
.CW doc/radio-interface.ms
took the link layer out of the packet device and put it in
.CW #L ,
where it carries the RadioHead header a PyCubed speaks.  That header is
four bytes and its protocol is one byte of address, an identifier, an
acknowledge flag and a retry flag.
.PP
AX.25 is the other link layer this radio could carry, and the one an
amateur ground station already has.  This is what it would take, written
before building it, because most of the question is whether the two
overlap enough that one of them should not exist.
.NH 1
The two, side by side
.PP
What
.CW #L
does today, against the AX.25 procedure that does the same job:
.DS
.CW "function            #L today            AX.25"
.CW ""
.CW "address             1 byte each way     7 bytes: call+SSID"
.CW "broadcast           address 255         dest QST or CQ"
.CW "datagram            a bare frame        UI, PID 0xf0"
.CW "acknowledgement     ACK flag + id       I and RR, with N(R)"
.CW "retransmission      RETRY flag, same id T1 expiry, up to N2"
.CW "duplicate           last id per peer    N(S) against V(R)"
.CW "ordering            none                N(S) and N(R)"
.CW "outstanding frames  one                 k, up to 7"
.CW "flow control        none                RNR"
.CW "connection          none                SABM, UA, DISC, DM"
.CW "segmentation        refused, named      the 2.2 segmenter"
.CW "multi-hop           none                digipeater path"
.CW "negotiation         none                XID"
.CW "loopback            none                TEST"
.DE
.PP
So the duplication is real but narrow.
.CW #L 's
identifier, acknowledge flag, retry flag and seen-table are a
stop-and-wait link with one frame outstanding; AX.25's I, RR, N(S),
N(R), T1 and N2 are the same thing done properly.  Everything above the
line \(em address, broadcast, datagram \(em differs only in encoding.
Everything below it,
.CW #L
does not have at all.
.PP
What is
.I not
duplicated is more interesting.  Two of the rows in that table are the
reason to do this at all:
.IP \(bu
.B "Seven bytes of address."
A RadioHead address is a byte a station picks.  An AX.25 address is a
callsign, and on an amateur band an unidentified transmission is not
permitted.  A satellite that transmits on 70cm has to say who it is in
a form a regulator and a receiving station both already read; that is
not a feature of the protocol, it is the licence.
.IP \(bu
.B "A ground station that already exists."
.I Direwolf ,
a TNC, a handheld with a KISS port: all of them decode AX.25 today and
none of them has heard of RadioHead.  The argument for RadioHead is that
a PyCubed speaks it; the argument for AX.25 is that everything else
does.
.PP
They are not alternatives so much as two different other ends.
.NH 1
What AX.25 has that has to be built
.PP
Taking the rows below the line in order, with what each is for.
.IP "\fBa connection\fP" 
SABM, UA, DISC, DM and the state machine between them.  Without it there
is no moment at which both ends agree they are talking, so a sender
cannot tell a peer that is absent from a peer that is silent.
.CW #L
finds that out only by exhausting its retries.
.IP "\fBsequence numbers\fP"
N(S) and N(R), modulo 8, against V(S), V(R) and V(A).  This is what
makes delivery ordered rather than merely un-duplicated.  A RadioHead
identifier says "you have seen this before"; a sequence number says
"and here is where it goes".
.IP "\fBa window\fP"
Up to
.CW k
frames outstanding.  On an ordinary link this is most of the throughput.
On this one it is worth much less than it looks, and the reason is in
.I radio (3):
at one per cent duty cycle a 47ms packet is followed by 4653ms of
enforced silence, so the acknowledgement rides in the gap whatever the
window is.
.B "A duty-cycled link is stop-and-wait whether or not the protocol is."
Where the window earns its keep is at 10 per cent on 433, or with no
duty limit at all, which is the case in the United States.
.IP "\fBflow control\fP"
RNR, and RR to release it.  A receiver whose queue is full has no way to
say so in
.CW #L ;
it drops, and the sender learns from a missing acknowledgement, which
costs a retransmission to discover something the other end already knew.
.IP "\fBsegmentation\fP"
.CW #L
refuses an oversize write and names the budget, on the argument that
splitting silently hides the message-size question.  AX.25 2.2 has a
segmenter, so under AX.25 the question has an answer and the refusal
becomes a choice rather than a principle.
.IP "\fBdigipeaters\fP"
Up to two addresses in 2.2, eight in 2.0, each with a has-been-repeated
bit.  For a satellite this is the difference between a footprint and a
network: a station that cannot hear the bird directly reaches it through
one that can.
.IP "\fBXID and TEST\fP"
Parameter negotiation and loopback.  Both optional in 2.2, and both
cheap.  TEST in particular is the only thing in the protocol that
answers "is the other end alive" without changing any state.
.NH 1
Minimal, and still AX.25
.PP
"Feature complete" is the wrong target; the right one is the smallest
thing a TNC on the other end will talk to without knowing it is talking
to a satellite.  That is AX.25 2.0 connected mode with UI, which is what
every TNC implements and what 2.2 is careful to stay compatible with:
.IP 1. 4
The address field: destination, source, and up to two digipeaters.  Six
bytes of callsign shifted left one bit, space-padded, then an SSID byte
of C/H, two reserved bits, four bits of SSID and the
end-of-address bit.
.IP 2. 4
UI frames, control
.CW 0x03 ,
with a PID.  This alone is APRS and is the whole of what most amateur
satellite traffic is.
.IP 3. 4
SABM, UA, DISC, DM: connection up and down.
.IP 4. 4
I frames with N(S), N(R) and the poll/final bit; RR, RNR and REJ.
Modulo 8.
.IP 5. 4
T1, T3, N2, k and N1, with values that can be set.
.PP
What is deliberately left out, and why each is safe to leave out:
.IP \(bu
.B SREJ ,
selective reject.  Optional in 2.2, negotiated by XID, and a station
that never offers it is never sent one.
.IP \(bu
.B SABME ,
modulo-128.  Same: optional, negotiated, and a window of 63 is
meaningless on a link that is stop-and-wait for regulatory reasons.
.IP \(bu
.B FRMR .
2.2 deprecates it in favour of replying DM, which this would do.
.IP \(bu
.B XID .
Without SREJ or modulo-128 there is nothing to negotiate, and a station
that does not answer XID is treated as a 2.0 station, which is correct.
.IP \(bu
.B "The segmenter."
It is optional in 2.2, and refusing an oversize write with the budget
named is what
.CW #L
already does and what
.I radio (3)
argues for.
.PP
That list is five things in and five things out, and the five that are
out are exactly the five that 2.2 made optional.
.NH 1
The sizes, which decide N1
.PP
An AX.25 frame over LoRa does not carry the HDLC flags, the bit
stuffing or the FCS: the LoRa PHY already delimits the packet and
checks it, and putting a second CRC inside the first is paying twice.
What is left is the address field, the control byte and the PID.
.B Measured
against the 255 the part's FIFO holds:
.DS
.CW "  SX1276 FIFO, LoRa explicit header   255"
.CW "  /dev/radio0/data                    255"
.CW "  less address, no digipeaters         14"
.CW "  less control and PID                  2"
.CW "  /net/ax25/n/data                    239"
.CW "  with two digipeaters                225"
.DE
So
.CW N1 ,
whose specified default is 256, has to be 239 here and less with a
path.  A station that assumes the default and sends 256 bytes of
information produces a frame this radio cannot transmit, so
.CW N1
is not a tuning parameter on this link, it is a property of it, and it
is the number the
.CW iounit
must publish.
.PP
For comparison,
.CW #L
publishes 251, and the chain
.CW doc/radio-interface.ms
measured runs 255, 251, 225, 221 through
.I ssl (3)
and Styx.  Under AX.25 that becomes 255, 239, 209, 205.
.NH 1
What it is as files
.PP
The answer is not a new shape.  AX.25 connected mode is the problem
.CW #I/tcp
solves, over one hop instead of many, so it is
.CW devip 's
interface with the state machine's own names in
.CW status :
.DS
.CW "  /net/ax25/ctl        fd n, addr CALL-n"
.CW "  /net/ax25/addr"
.CW "  /net/ax25/stats"
.CW "  /net/ax25/clone"
.CW "  /net/ax25/n/ctl      connect, announce, disconnect, ..."
.CW "  /net/ax25/n/data     ordered information"
.CW "  /net/ax25/n/local    our callsign"
.CW "  /net/ax25/n/remote   theirs"
.CW "  /net/ax25/n/status   state, V(S), V(R), V(A), retries"
.CW "  /net/ax25/n/listen   opens when somebody connects"
.DE
with
.CW ctl
taking, per conversation:
.DS
.CW "  connect CALL-n [via CALL-n[,CALL-n]]"
.CW "  announce"
.CW "  disconnect"
.CW "  ui on|off"
.CW "  pid 0xf0"
.CW "  window k        t1 ms    t3 ms    n2 n"
.DE
Three of those deserve an argument rather than an assertion.
.IP \(bu
.B Listen .
.CW #L
has
.CW announce
and no
.CW listen ,
and
.I lora (3)
carries that as a bug: an announced conversation latches onto whoever
spoke last, so two stations talking to one server interleave.  Under
AX.25 that is not a wart, it is impossible \(em a connection is per
peer, SABM arrives from a particular callsign, and the answer has to be
a new conversation.  So
.CW listen
is not an extra, it is what makes the protocol expressible.
.IP \(bu
.B "ui on."
A UI frame is connectionless, so a conversation in
.CW ui
mode never leaves the disconnected state and every write is one frame
to the configured destination.  This is APRS, and it is the mode a
beacon uses.  It is a mode of a conversation rather than a separate
file because the addressing, the digipeater path and the PID are the
same in both.
.IP \(bu
.B "t1, and where it comes from."
.I Lora (3)
found that an acknowledgement cannot be sent while the answering
station owes its duty cycle, so a timeout shorter than that debt
expires before the reply can go out.  The same applies to T1 exactly,
and the same answer applies: this layer cannot compute it, because
computing it means knowing the modem's parameters, which is the
coupling the layering exists to avoid.  So T1 is set, and
.CW status
reports what it is.
.NH 1
Where it goes
.PP
A device of its own,
.CW #X
served on
.CW /net/ax25 ,
attached to a packet device by a file descriptor written to its
.CW ctl ,
exactly as
.CW #L
is.  Not a framing mode of
.CW #L ,
for three reasons: the address is a different type, the reliability is a
different mechanism, and one of them needs a
.CW listen
file that would be meaningless in the other.  A device with two
personalities selected by a
.CW ctl
command is two devices sharing a
.CW switch .
.PP
What
.I should
be shared is the part neither protocol owns: attaching to a packet
device by descriptor, holding its receive path, running one reader,
republishing an
.CW iounit
less a header, and keeping a table of conversations with
.CW clone .
That is the same in both and is worth factoring once the second one
exists, which is the only point at which it can be factored honestly.
.NH 1
Order
.IP 1. 4
.B Done .
The address field, and UI frames.  Testable against a peer that builds
the bytes from the specification, the way
.I loraraw (1)
does for RadioHead, and useful on its own: a beacon is a UI frame.
.RS
.PP
.CW os/inferno/radio/devax25.c
is
.CW #a ,
served on
.CW /net/ax25 .
Measured, two
.CW mps2-an386
over a socket pair, against
.I ax25raw (1),
which builds the bytes from the specification on the far side of a
device boundary:
.CW "N0CALL-7>KA9Q-1"
built by hand is delivered as its information field;
.CW "N0CALL-7>QST"
is too;
.CW "N0CALL-7>W1AW-2"
is counted under
.CW notours
and dropped; and a frame with an unrepeated
.CW WIDE1-1
in its path is counted under
.CW todigi
rather than delivered, because a hop still to go is addressed to the
digipeater.  In the other direction the hand-built peer decodes
.CW "KA9Q-1>W1AW-2 via WIDE1-1,WIDE2-1 UI pid 0xf0" ,
which is the path and the control and PID bytes the specification
asks for.
.PP
The sizes came out as this document predicted: 239 with no path and
225 with two digipeaters, from
.CW sys->iounit
and not from a constant in the test.  The path is refused while
.CW data
is open, so the number is exact rather than a worst case.
.RE
.IP 2. 4
SABM, UA, DISC, DM, and the state machine with no data in it.
.IP 3. 4
I, RR, REJ, and the sequence numbers.
.IP 4. 4
RNR, and the window.
.IP 5. 4
Digipeaters.
.PP
Each of those is a thing a TNC on the other end can be pointed at, which
is the reason for that order rather than any other.
