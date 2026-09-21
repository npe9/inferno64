.TL
A radio as files: the layer it belongs in, and the sizes that cross it
.AU
.PP
.CW doc/radio-plan.ms
chose a shape for
.CW #W
and
.CW doc/radio-evidence.ms
made it run.  This is the part neither argued: whether the shape is
right.  It is written after building it, which is the only order in
which that can be answered honestly, and the answer is that two things
are in the wrong layer.
.NH 1
The error, which is one error made twice
.PP
.CW os/inferno/radio/sx127x.c
puts a four-byte RadioHead header on every packet it sends, drops every
packet whose first byte is not this station's address or the broadcast
one, and implements acknowledgement and retry.  Its
.CW ctl
takes
.CW node ,
.CW dest ,
.CW ack ,
.CW retries
and
.CW acktimeout
beside
.CW freq ,
.CW power ,
.CW sf ,
.CW bw
and
.CW cr .
.PP
So a device whose job is "put this packet on the air" also decides who
packets are for and when to send them again.  That is addressing and
reliability in the physical layer.
.PP
The right comparison is not a UDP socket, which is the one that comes to
mind first and flatters the mistake: UDP already carries addresses, ports
and a checksum, so thinking of a radio as UDP smuggles all three into the
part.  The right comparison is an Ethernet frame interface.  One write is
one frame, one read is one frame, the device knows about the medium and
nothing about who is talking to whom.  Plan 9 has exactly that separation
already and it is the one to copy:
.DS
.CW "  #l /net/ether0    frames, and the medium"
.CW "  #I /net/...       addresses, ports, reliability"
.DE
so:
.DS
.CW "  /dev/radio0       SX127x packet radio"
.CW "    ctl             the modem: freq, power, sf, bw, cr"
.CW "    data            one write one packet, one read one"
.CW "    pkt             a packet and what was known about it"
.CW "    stats           counters"
.CW ""
.CW "  /net/lora         the protocol over it"
.CW "    clone"
.CW "    0/ctl           dest, ack, retries, timeout"
.CW "    0/data          this conversation's packets"
.CW "    0/local 0/remote 0/status"
.DE
.PP
The separation earns its keep immediately rather than eventually.  The
same SX127x does LoRa or FSK; LoRa is not LoRaWAN; a beacon process and a
command process want the same radio at the same time and as built cannot
have it, because
.CW dest
is stored in the radio and two writers of one
.CW ctl
overwrite each other.  And later the same boundary carries an SX126x
underneath, or LoRaWAN above, without either knowing about the other.
.PP
So the rule for
.CW radio (3),
stated as a prohibition because that is the useful form:
.B "atomic packets, radio configuration and receive metadata, and no
.B "addressing, ports, acknowledgement, routing, fragmentation or
.B "reliability."
Everything in that second list belongs above.
.NH 1
The verbs
.PP
There are five \(em
.CW open ,
.CW read ,
.CW write ,
.CW close ,
and the namespace operations \(em so the question is what reading and
writing each file means.
.IP "send" 12
.CW write
to
.CW data :
exactly one packet of exactly the length written.  Not a stream.  The
boundary is what everything above depends on.
.IP "receive"
.CW read
from
.CW data ,
blocking: exactly one packet.  A buffer too small is an error, not a
truncation, and the packet stays for a reader that fits.
.IP "configure"
text to
.CW ctl ,
one command per write.
.IP "observe"
.CW read
.CW stats .
.IP "wait"
is not a verb.  A blocking read is how Inferno waits.  Worth saying,
because a radio interface in any other system has a callback, a poll or
a select in it, and here the absence is the design.
.NH 2
Receive metadata, which is the awkward one
.PP
LoRa hands the receiver things the payload does not contain: RSSI, SNR,
whether the CRC checked, frequency error, when it arrived.  A
.CW data
file that returns payload alone throws all of it away, and a higher
layer that wants to choose a spreading factor, or a ground station
pointing an antenna, needs it.
.PP
As built it is in
.CW stat ,
and that is a race: by the time a reader gets there another packet may
have replaced it.  It reports the last packet the
.I radio
saw, not the last packet
.I you
read.
.PP
The established answer is not a second file.  It is
.CW recvmsg ()
rather than
.CW recv ()
\(em a packet delivered together with ancillary data, in one operation,
without any of it going over the air.  In files that is a second
.I name
for the same queue, not a second queue:
.DS
.CW "  read(data, ...)   payload"
.CW "  read(pkt, ...)    a fixed header -- length, rssi, snr,"
.CW "                    flags, tick -- then the payload"
.DE
One read of
.CW pkt
is one packet and its ancillary data, atomically, because they came out
of the same queue entry.  A program that does not care reads
.CW data
and never sees the header; a program that does reads
.CW pkt .
Nothing is racing because nothing is looked up after the fact.
.NH 2
A budget in time, which files have no word for
.PP
.CW iounit
says how much one operation carries and nothing about how often.  A LoRa
packet at SF12 and 125kHz is 1319ms of air \(em
.B measured ,
and the datasheet formula agrees to the millisecond \(em and the 868MHz
band in Europe permits one per cent duty cycle: two minutes of silence
for every packet.  A
.CW data
file that accepts writes as fast as a program makes them is telling that
program something untrue, and nothing below detects it.  The packets go
out and the licence is what breaks.
.PP
A file interface says this the only way it says anything: the write
waits.  A radio that has spent its allowance blocks until it has more.
So
.CW stats
reports air time used and left, and
.CW ctl
takes a
.CW duty
window, because the window is a property of where the radio is standing
rather than of the radio.
.PP
Built.
.CW ctl
takes
.CW "duty n" ,
zero to a hundred and zero by default, and a transmit of
.I A
milliseconds is followed by
.I "A (100 - D) / D"
of silence \(em the rule every LoRaWAN stack implements, which holds
the ratio over every window rather than over an hour.
.CW stats
reports the duty cycle, all the air the radio has used, how long until
it may transmit again, and how many writes have waited.
.PP
.B Measured .
Four nine-byte writes in a row at SF7 took 240ms with the duty cycle
off and 14190ms at one per cent, against 14147 predicted from the
driver's own
.CW airtime-total-ms
of 47 milliseconds a packet.  The first packet after a silence does not
wait, so a short burst is slightly over the ratio and a long run
converges on it; that is the rule's behaviour and not an approximation
of it, since a scheme that made the first packet wait would be refusing
to transmit into an hour it had not used.
.PP
.CW Duty
is off by default because it is a number somebody has to know: the
band, the sub-band and the region decide it, and in the United States
it is a dwell time rather than a ratio, which this cannot express.  A
kernel that never sets it transmits as fast as it is asked, which is
the same as before this existed.
.NH 1
The sizes, which are a chain
.PP
There is no single
.CW iounit
on a radio.  There is a chain, and each layer must subtract its own
overhead and republish or the number stops.
.B Measured ,
.CW mps2-an386 :
.DS
.CW "  SX1276 FIFO, LoRa explicit header   255"
.CW "  /dev/radio0/data                    255"
.CW "  less the RadioHead header             4"
.CW "  /net/lora/n/data                    251"
.CW "  less ssl(3) header, digest, padding  30"
.CW "  #D/n/data                           221"
.CW "  Styx msize, adopted from it         221"
.CW "  less IOHDRSZ                         24"
.CW "  one Tread                           197"
.DE
.PP
All four of the message sizes in that chain were printed by
.CW radiostyx
on a second station: 255 straight at the packet device, 251 through
.CW #L ,
225 through
.I ssl (3)
alone and 221 through both.  Nothing in it is told there is a radio at
the bottom.
.PP
The first subtraction used to happen inside
.CW sx127x.c ,
which is why
.CW /dev/radio0/data
used to be 251.  The four bytes are not saved by moving them, they are
charged where they are spent; what changed is that a program that does
not want addressing no longer pays for it.
.PP
Two of the subtractions were not being done at all until this week.
.IP \(bu
.CW os/inferno/port/exportfs.c:806
adopts a transport's
.CW iounit
as the Styx message size.  That was right already, and it is the
mechanism the whole chain rests on.
.IP \(bu
.CW devssl.c
published no
.CW iounit
at all, so the chain stopped there: a Styx server above it negotiated
8192, and the only reason the first test passed was that the reply
happened to be 210 bytes against a 251-byte budget.  It publishes one
now \(em conservatively, the worst case it can impose, because the
algorithm may be chosen after the file is opened and an
.CW iounit
is a promise and not an estimate.
.IP \(bu
.CW appl/lib/ssl.b 's
.CW connect ()
opened
.CW data
before pushing the file descriptor, so the device had nothing to compute
a budget from even once it could.  The two lines are the other way round
now, and the negotiated size went from 8192 to 221.
.PP
The general rule is worth more than the radio.
.B "A filter that delimits messages must publish an iounit, and it must
.B "be the one underneath less its own overhead."
Otherwise the budget stops at the filter and the program on top is told
it may write as much as it likes, by something that has no idea.
.NH 1
What to do
.IP 1. 4
.B Done .
Take the link layer out of the part.  The RadioHead header, the address
filter, and acknowledgement and retry come out of
.CW os/inferno/radio/sx127x.c ,
and
.CW node ,
.CW dest ,
.CW ack ,
.CW retries
and
.CW acktimeout
come out of its
.CW ctl .
What is left is a packet radio.
.IP 2. 4
.B Done .
Put them back above it, as a
.CW /net/lora
device with
.CW clone
and a directory per conversation, which is
.CW devether 's
shape.  A Limbo library over
.CW /dev/radio0
would be cheaper, and the protocol is the same either way, but it
cannot be that: what sits on top of this link is
.I ssl (3)
and
.CW sys->export (),
and both of those are filters over a file descriptor.  A library has
no file descriptor to give them.
.CW os/inferno/radio/devlora.c
is
.CW #L ,
served on
.CW /net/lora ,
and it attaches to a packet device the way
.CW devssl
attaches to anything \(em a file descriptor written to its
.CW ctl
\(em so it is not welded to
.CW #W
and includes none of the chip driver's headers.
.PP
That is as far as the decoupling goes, and the boundary is worth
saying exactly.  What is underneath has to delimit messages and has to
publish an
.CW iounit .
A pipe does neither:
.CW os/inferno/port/devpipe.c:73
opens its queues as byte streams.  So the obvious negative control
\(em run the link layer over a pipe with no radio in the room \(em was
not available when this was written.
.PP
It is now, and by supplying the missing thing rather than by relaxing
the requirement.
.CW os/inferno/radio/devkiss.c
is
.CW #k ,
which puts KISS's boundary on a byte stream and publishes an
.CW iounit ,
so a pipe with it on one end is a packet device.
.I Ax25 (3)
and
.I aprs (1)
run over it in one kernel with nothing else fitted, and what comes out
of the far end of the pipe is what a TNC would be handed.  That is
also how this tree reaches a real amateur station: a KISS frame
carries exactly the bytes
.CW #a
builds, and the TNC does the HDLC.  The decoupling that can be shown is
structural: it compiles, links and runs without
.CW sx127x.h ,
and every number it uses comes out of the
.CW Chan .
.PP
Measured, two
.CW mps2-an386
over a socket pair: a conversation's
.CW iounit
is 251, four less than the 255 underneath it; a packet addressed to 9
arrives at station 2 and is counted under
.CW notours
rather than delivered; an acknowledged write reports one send, no
retries and one acknowledgement received, and the other end reports one
acknowledgement sent.
.PP
Under
.CW "-global sx1276.drop-pct=50" ,
eight acknowledged writes became 24 transmissions with 16 retries, two
got through and six gave up \(em and the receiver delivered
.CW loss-1
and
.CW loss-2
twice each.  That is the duplicate the old
.CW radio (3)
listed as a bug and nobody had watched.  The fix is RadioHead's: the
last identifier from each address, and a retransmission of something
already delivered is acknowledged again rather than delivered again.
On the same seeded channel the same six arrivals now deliver four
payloads, once each, with
.CW "duplicate 2"
in
.CW stats .
.IP 3. 4
.B Done .
.CW pkt ,
with ancillary data, and
.CW stats
renamed from
.CW stat
to match what it holds.
.IP 4. 4
.B Done .
Duty cycle.
.PP
Everything else stays, and the reason to trust it is that it has been
load-bearing: one write one packet, one read one packet, a short read
refused and an oversize write refused were guesses when
.CW doc/radio-plan.ms
made them, and they are what let
.I ssl (3)
and Styx sit on top without either knowing there was a radio underneath.
