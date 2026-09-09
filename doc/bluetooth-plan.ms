.TL
Bluetooth: what is missing, and how to carry it to 9front
.AU
Inferno RIO
.PP
The stack that exists is described in
.I btfs (4)
and
.I bt (2),
and what it was verified against is recorded in
.I doc/inferno-ports.ms .
This document is the other half: what it still needs before it is
useful against real devices, in the order the parts block each other,
and a plan for the 9front implementation.
.PP
Everything below distinguishes what was checked in this tree from what
is known about 9front and could not be checked here, because
.CW os/9front
is a kernel and nothing else.
.NH 1
What the stack still needs
.PP
Four groups, roughly in the order they stop being optional: the things
that block any real device at all, the shape of what is already built,
the peripheral role, and then the profiles.
One item has come out of the first group since it was written:
resolvable private addresses are done.  What is left in it is a
controller and the pc64 uart fault under it, LE Secure Connections,
and somewhere to ask the user.
.NH 2
Blocking: nothing real can be talked to yet
.PP
.B "A controller."
The stack has never spoken to a radio.  Two ways to fix that and they
are not equal.
.IP \(bu
A USB dongle.
.CW appl/lib/bt/btusb.b
is written against the same
.CW devusb
the HID and mass-storage paths are verified against, and it needs a
dongle and an afternoon.  It also needs the last link of the chain the
brief describes \(em
.CW usbd
noticing a device of class
.CW e0/1/1
and starting the stack on it, the way it already starts a keyboard.
Nothing does that today; the device is enumerated and then left.
.IP \(bu
The Raspberry Pi 3B's onboard radio.  This is the harder one and the
brief says so.  H4 over the PL011 is the easy part and it is written.
The rest is not: loading the BCM43438 firmware blob through the vendor
HCI commands, changing the baud rate and following it on our side,
RTS/CTS on the GPIO lines, the reset sequence, and swapping the
console onto the mini-uart so the PL011 is free.  None of it is
started.
.PP
.B "The pc64 uart fault."
H4 over a uart does not survive on pc64 at all \(em see the capture in
.I doc/inferno-ports.ms .
It is a fault in the kernel's interrupt return, not in this stack, but
it stands between the H4 transport and any board where the controller
is on a serial line, which is to say between here and the Pi.
.PP
.B "Resolvable private addresses \(em done."
This was the gap most likely to make the stack look broken against a
device someone actually owns, and it is closed.  Modern peripherals
\(em phones, watches, a good many sensors \(em advertise from an
address that rotates every few minutes, and the whole point of the IRK
a bond distributes is to recognise the device behind it; the stack
stored the IRK and did nothing with it, so a bonded device was a
stranger again a quarter of an hour later.
.CW ah
is in
.CW appl/lib/bt/smp.b
beside the other AES-built functions,
.CW btfs
tries every stored bond's key against every resolvable address it
hears, and the device directory is named by the identity address
rather than by whatever the device is advertising from this minute,
with
.CW addr
following it and an
.CW identity
file saying what is behind it.  What is
.I not
done is the controller-side resolving list, which is the same idea
done by the radio and would be the faster path; nothing needs it yet.
.PP
A bond survives a restart with it: a key file read at startup
recognises the device behind an address it chose afterwards, with
nothing pairing in that session, which is the thing a bond is for and
the thing this stack could not do.
.PP
The one place the shape shows is a device first heard from a private
address and paired only afterwards: its directory keeps the name it
was given before there was a key to resolve it with.
.I btfs (4)
says so.
.PP
.B "LE Secure Connections."
Pairing here is LE legacy, and a device that requires Secure
Connections is told plainly that this cannot do it \(em which is
honest and is also a refusal.  Secure Connections needs P-256
elliptic-curve Diffie-Hellman and AES-CMAC, and
.CW libsec
in this tree has neither: there is no elliptic curve code in it at
all.  So this is not a Bluetooth job, it is a cryptography job first,
and it is the largest single item in this list.
.PP
.B "A way to ask the user."
Just Works is what the stack does because it is what needs no
interface.  Passkey entry and numeric comparison need somewhere to put
the question and read the answer \(em a file, in keeping with the rest
\(em and without them the stack cannot pair with anything that insists
on protection against a man in the middle.
.NH 2
The shape of what is built
.PP
None of these stop a device working; all of them are places the
current shape runs out.
.IP \(bu
Several controllers.  Each device named on
.CW btfs 's
command line becomes one numbered directory, and a radio's devices,
links, scanning and bonds are its own; the node table, the mount point
and the key file are shared.  A bond records the controller it was
made on, because a long term key is agreed between one peripheral and
one radio and the peripheral stores this side's identity address with
it.
.IP \(bu
.CW Hci.leconnect
takes a lock now, as the command path always has, so two callers
cannot take each other's answer off the one channel the completion
arrives on.  A controller will only have one LE Create Connection
outstanding anyway.  A completion that outlives the attempt that
asked for it is handled too: the channel it arrives on is buffered, so
one cannot be lost in the window between asking and waiting; a
cancelled attempt waits for the completion the specification promises
will follow, and returns the connection if it turns out to be a real
one that was merely late; and an attempt drains the channel before it
starts, so a controller that owes an event and sends it long
afterwards cannot poison the next connection.
.IP \(bu
SCO packets are still dropped \(em nothing needs them until audio
does, and audio needs a good deal more than a reader case \(em but
they are no longer dropped in silence: the first says so and the rest
are counted into
.CW /net/bt/0/state .
.IP \(bu
ATT does prepare/execute write now, so a value longer than the MTU can
be written as well as read: the pieces are queued with Prepare Write
and committed with Execute Write, the server's echo of each piece is
checked, and anything that does not match cancels the queue rather
than committing whatever the server understood.  Still no Read
Multiple and no signed writes.
.IP \(bu
GATT subscribes to Service Changed now, and walks the database again
when the device says it has moved, so a device that rearranges itself
is no longer believed on the stale copy.  Included services are followed, so a secondary service \(em which
primary discovery cannot see \(em is reachable through the service
that includes it.  It still does no caching, and the rediscovery is
wholesale rather than confined to the range the device names, which is
deliberate: a device that has just said it rearranged itself has least
claim to have got that range right.
.IP \(bu
A device that stops answering is forgotten, after
.CW -a
seconds and five minutes by default, so a scan in a busy room no
longer fills
.CW /net/bt/0/remote
for ever.  A connected device, a device with an identity from a bond,
and everything while scanning is off are kept regardless.  The node
table behind it still only grows, since qids are not reused; what a
forgotten device frees is its entries in it, not the array.
.IP \(bu
Connection parameters are checked when the peer asks, carried out when
they are accepted, and can be asked for from this side with
.CW params
on a device's
.CW ctl .
Accepting used to be unconditional and was followed by nothing at all,
which is the one answer worse than refusing: a peripheral that is told
yes adjusts its behaviour to a link that never changed.
.IP \(bu
LE credit-based channels are there.  A channel is asked for by PSM on
a device's
.CW ctl
and appears as a file under
.CW l2cap/ ;
one write is one SDU and one read is the next one whole.  Both
directions are flow controlled: an SDU going out is cut at the peer's
MPS and pays a credit per segment, waiting rather than dropping when
the peer has granted none, and credits coming in are granted for as
many segments as there is room for and given back when a reader takes
the SDU they carried.  A peer that sends a segment it has not paid for
or announces an SDU longer than the MTU loses the channel, since
credits are the only thing bounding this side's memory.  What is not
there is the enhanced form (0x17\-0x1a), which opens several channels
at once and can reconfigure them.
.NH 2
The peripheral role
.PP
The stack can advertise and can be connected to.
.CW "advertise on"
on a controller's
.CW ctl
starts connectable undirected advertising carrying the flags and the
name
.CW advname
was given, and a link a peer opens arrives under
.CW remote
like any other, with
.CW state
saying which side opened it.
.PP
There is a GATT server too.
.CW service
and
.CW characteristic
on a controller's
.CW ctl
build a database and it appears under
.CW /net/bt/N/gatt ,
which is
.CW remote/ADDR/gatt
read the other way: reading a file reads what a peer would read,
writing one sets what a peer will read next.  A peer that connects can
discover the services and characteristics and read them, including
values longer than the link's MTU.
A peer can write, too, and a characteristic that says it notifies
carries the descriptor a peer writes to ask for it: setting the value
through the file is then what tells every peer that asked.  An
indication is waited for, because only one may be outstanding.
Every database carries a Generic Attribute service with Service
Changed in it, so the database may grow while a peer is connected: the
handles the peer already holds stay right, and what it has not seen it
is told about.
A peer can pair with this side too: SMP has its responder half, the
Long Term Key Request a peripheral gets when the central starts
encryption is answered, and a long term key is distributed so the peer
can come back.  It is Just Works, like the initiator, with all that
implies.
A peer that has paired before comes back on that bond: it starts
encryption naming the key it was given, and the key is found from its
diversifier and handed to the controller, so nothing pairs twice.
.PP
What is missing on that side is everything Secure Connections needs,
and a passkey or numeric comparison; the peripheral role here is Just
Works and no more, in both directions.
.NH 2
Profiles, in the brief's order
.IP 1.
.B "HID over GATT."
Done for the boot protocol.
.CW bthid
takes the first connected device with a 1812 service, asks for the
boot protocol, and reads the boot keyboard and boot mouse reports off
their
.CW .notify
files; keys go to
.CW /dev/keyboard
and motion to
.CW /dev/pointer .
The translation is
.CW appl/lib/hidboot.b ,
shared with
.CW usbd ,
because above the transport the reports are identical.  What is left
is the report protocol, which means parsing the report map: a device
that will not do boot protocol is found and then left alone, exactly
as
.CW usbd
leaves one.
.PP
The report protocol is done too.  A device with no boot report has its
layout read off it \(em and it is the boot reports that are looked for
first, not Protocol Mode: writing 0 to the Protocol Mode of a device
that has no boot report would put it in a mode it cannot report in.
So:
.CW 2a4b
is a HID report descriptor and
.CW appl/lib/hidreport.b
walks it into a list of reports, each a list of fields with a usage, a
bit offset, a width and a count; each
.CW 2a4d
Report characteristic has a
.CW 2908
Report Reference descriptor beside it saying which report id it
carries.  Putting the two together is the only thing that says which
report is the keyboard and which the pointer \(em every Report
characteristic has the same UUID \(em and where in each report the
modifiers, the key codes, the buttons and the axes are.  The library
is shared with
.CW usbd
for the same reason
.CW hidboot
is, though
.CW usbd
does not use it yet: it still finds a boot interface or leaves the
device alone.
.PP
Two things in
.CW btfs
had to change for it.  A service may now hold the same UUID twice, so
when one does, every characteristic with that UUID is named
.CW uuid.hhhh
after its value handle rather than two files sharing one name and one
of them being unreachable; and a characteristic's descriptors, other
than the client configuration, are now files beside it, because a
Report Reference is a value a client has to read.
.PP
The bench runs the whole HID phase again in the report protocol, with
the same assertions: the same keystrokes, the same movement.  The
model's device gives the mouse the lower report id and puts it first,
so a host that guessed by order would have the two backwards.  The
control is
.CW --hidswap ,
which tells the two Report Reference descriptors the wrong way round
while sending exactly the same bytes: the phase must fail, and it
does, with the keyboard's reports arriving as pointer motion.  Run by
hand,
.CW --hidnomap
serves an empty report map and
.CW bthid
finds nothing to read, which is the other half of the same question.
.IP 2.
.B "Bluetooth Classic."
Finding devices is done.
.CW "inquiry on"
runs an inquiry \(em which is not a scan: the controller is told how
long to inquire for and says when it is over, so it ends by itself and
.CW state
says
.CW "inquiry off"
again.  What answers appears under
.CW remote
beside the LE devices, with
.CW type
reading
.CW classic
and the class of device it answered with; its address is a BD_ADDR and
never rotates, so there is no identity to resolve behind it.  A device
that sent an extended inquiry response has its name in it already; one
that did not is asked, with a Remote Name Request \(em a page that does
not become a connection \(em in a process of its own, because a page
takes as long as it takes and no lock may be held across it.
.PP
Inquiry Result and Inquiry Result with RSSI are read separately rather
than as one event with a field added: the plain one has two reserved
bytes after the page scan repetition mode and the other has one, so
the class, the clock offset and everything after them sit a byte
apart.  Getting that wrong reads a class of device out of the middle
of an address and is invisible until something depends on it.
.PP
A BR/EDR link is done as well.
.CW connect
on a Classic device's own
.CW ctl
pages it and
.CW disconnect
takes the link down; a peer that pages this side is accepted.  The
Connection Complete event does not say which side opened the link \(em
the LE one does \(em so the only thing that distinguishes an answer to
this side's page from a link a peer opened is whether the address is
the one being paged, and that is what the code checks.  Nothing runs
over the link: L2CAP's signalling channel is a different CID on
Classic and none of Classic L2CAP is written.
.PP
L2CAP runs over such a link, in basic mode: a connection request
answered with a CID, a configuration request each way, and only then a
channel.  There are no credits and no segmentation \(em one frame is
one SDU, up to the MTU the other side asked for \(em so what a
credit-based channel does with credits, this does by fitting.  It is
the same
.CW Chan ,
read and written with the same
.CW csend
and
.CW crecv ,
and it appears in the name space as the same file: one pair of files,
two protocols underneath.
.PP
Link keys and secure simple pairing are done as well, and they are
not SMP with different bytes: the controller runs the pairing and asks
this side questions on the way, so
.CW btfs
answers them out of the bonds rather than computing anything.  What
comes of it is a sixteen byte link key in the same
.CW Bond
an LE pairing fills in \(em a device may have both, one bond and two
radios' worth of keys \(em kept in the same store and served by the
same
.CW btkeyfs .
A link is encrypted after it is authenticated, because a link where
the key was agreed and never used is not a secure link.  It is Just
Works, like the LE side and for the same reason: there is nothing here
that can show a number or read one.  The old kind of Classic pairing,
with a PIN, is refused and said out loud.
.PP
So what is left of Classic is what those channels are for: HIDP, PAN,
and the audio profiles; and an SDP server, so that a device can find
what this side offers rather than being told.
.IP 3.
.B SDP .
The client half is done.
.CW btfs
asks as soon as a BR/EDR link comes up, over an L2CAP channel to PSM
1, and what the device answers becomes
.CW /net/bt/N/remote/ADDR/sdp ,
one file per service record.  A record holds its service classes, its
name, the protocol stack it is reached over \(em where an RFCOMM
channel number lives, and the reason to read a record at all \(em and
every other attribute the device gave, whether or not anything here
knows what it means.
.PP
Two things about SDP are not like anything else in this stack.  It is
big endian throughout, where HCI, L2CAP, ATT and SMP are all little
endian, and its UUIDs are big endian too, so
.CW bt->uuid ,
which reverses, is the wrong function to read one with.  And an answer
that does not fit comes back in pieces joined by a continuation state,
which may cut a record in the middle of a data element \(em so the
bytes are joined before anything is parsed, and the bench hands the
same answer back seventeen bytes at a time to prove it.
.PP
The server half is done too.
.CW "serial N"
on a controller's
.CW ctl
offers a serial port over RFCOMM on that channel and publishes the
service record that says where it is; a peer that pages this side can
then open an L2CAP channel to PSM 1, search, read the channel number
out of the record, open a channel to PSM 3, and open the port.  The
records are built out of the same
.CW Elem
a client reads, and one function turns them into bytes \(em there is
no second encoding here to disagree with the decoding.
.PP
The two verbs are one verb on purpose: a port nobody can find is no
use, and a record for a port that does not answer is worse than
none.
.IP 4.
.B "RFCOMM."
Done, and it is what the sentence above asked for:
.CW "rfcomm 1"
on a Classic device's own
.CW ctl
opens
.CW /net/bt/0/remote/ADDR/rfcomm/1/data
and a program reads and writes it like a serial line.  The channel
number comes out of an SDP record, which is what SDP is for.
.PP
It is TS 07.10 with a Bluetooth adaptation layer: a multiplexer inside
a multiplexer, one L2CAP channel to PSM 3 carrying a session and the
session carrying up to thirty data link connections.  Opening one is
three handshakes \(em parameter negotiation on the control channel,
SABM on the connection itself, and modem status both ways, which is
not a courtesy since a device may hold its end shut until it sees one
\(em and then the data is UIH frames with credits, negotiated in the
first of those rather than granted as LE L2CAP grants them.
.PP
The frame check sequence is the part that can be checked against
something outside this tree, and it is: SABM on DLCI 0 is
.CW "03 3F 01 1C"
and UA is
.CW "03 73 01 D7"
in every description of RFCOMM there is, and the bench asserts both
before it does anything else.  A stack that computes those two right
has the polynomial, the starting value and the complement right, and
the rest of the framing rests on that.  The multiplexer control
messages are from one reading of the specification and are pinned to
nothing; that is said here rather than left to be assumed.
.PP
The serial port profile's own record is done with it:
.CW "serial N"
publishes one, so a device finds the port rather than being told its
number.
.IP 5.
.B "Classic HID."
Done.  A Classic keyboard is found by an inquiry, its report
descriptor comes out of its
.CW 1124
service record rather than out of a characteristic, and its reports
arrive on an L2CAP channel to the interrupt PSM with a byte of HIDP
header in front of them.
.CW bthid
opens the control channel as well, because HIDP is two channels and a
device is entitled to expect both.
.PP
What makes it worth having is how little of it is new.  The report
descriptor is the same descriptor an LE device serves as its
.CW 2a4b
characteristic, so
.CW hidreport
parses it unchanged; the reports are the same reports, so
.CW hidboot 's
key table turns them into the same characters; and the bench phase
asserts the same keystrokes and the same movement as the LE one.
Everything underneath is different \(em inquiry rather than scanning,
a service record rather than a characteristic, an L2CAP channel rather
than a notification \(em and nothing above the transport is.
.PP
One thing had to be fixed in SDP for it.  A report descriptor travels
in a text data element and is full of bytes that are not characters,
so the string this stack made of it was mangled; an element now keeps
its bytes as well as its string, and
.CW btfs
writes the descriptor out as a
.CW hiddesc
line in hexadecimal rather than leaving it to be read out of the
attribute.
.IP 6.
.B "PAN and BNEP."
Done, and the sentence it was written as is what it does:
.CW btpan
turns a Bluetooth link into another
.CW /net/ether .
.PP
BNEP carries whole ethernet frames over an L2CAP channel, with the
addresses left out where they can be worked out \(em a link has two
ends, so a frame that arrived on it is from the far end and to this
one.  The addresses themselves are the two BD_ADDRs, which is the neat
part of the profile: a Bluetooth link already has two six byte
addresses on it, so PAN invents no MAC.
.CW btpan
serves the clone, addr and numbered conversation interface devip's
ether medium binds to \(em the same one
.CW appl/cmd/usb/etherusb.b
proved binds from Limbo \(em with that link underneath, so the IP
stack above gets ARP, neighbour discovery and multicast mapping
without knowing the wire is a radio.
.PP
It is an ordinary file client, like
.CW bthid :
it opens the L2CAP channel file
.CW btfs
made and does BNEP over that, so there is no Bluetooth in it beyond
the name of the directory.  What is not tested here is the binding
itself; the interface is the one that binds, and the phase drives it
the way the IP stack would \(em a conversation, an ethertype, a frame
out and a frame in \(em but nothing in this bench runs an IP stack
over it.
.IP 7.
.B "A2DP,"
as far as it goes without a codec.
.CW appl/lib/bt/avdtp.b
is the signalling: discover a sink's stream endpoints, ask what one
can do, choose an SBC configuration out of what it says it will take,
configure it, open, start, close.
.CW bta2dp
does that and then sends a file down the media channel, which is a
second L2CAP channel to the same PSM.
.PP
What is not here is SBC, and that is the difference between this and
A2DP.  Nothing turns sound into SBC frames or back, so the file has to
hold them already and
.CW bta2dp
says so rather than leaving it to be found out by listening.  The
brief said to leave audio out of a first stack; the signalling is not
audio, and it is what a codec would have been plugged into.
.PP
The choosing is worth its own line.  An SBC capability is three fields
of bits and a configuration is one bit out of each, so this is not
meeting in the middle: it is picking one of the things the sink
already said it would do.  In every field the best value is the lowest
bit \(em the frequencies run downward from the top bit, and joint
stereo and loudness are the bottom bit of theirs \(em and picking the
highest set bit instead gives 16000 mono four blocks, the worst of
everything on offer, with a stream that opens and starts and plays.
So the bench asserts what was chosen and not only that something was.
AVRCP is not implemented, and neither is
.I devaudio
underneath any of it.
.IP 8.
.B "HFP,"
as far as it goes without a synchronous connection.
.CW appl/lib/bt/hfp.b
is the service level connection and the AT commands above it, and
.CW bthfp
serves a telephone as three files:
.CW status
for the indicators,
.CW event
for the next thing that changed, and
.CW ctl
taking
.CW dial ,
.CW answer ,
.CW hangup
or a raw AT command.  So a program places a call by writing to a file
and learns it was answered by reading another.
.PP
What is missing is the sound, and it is the same thing that was
missing when this was written down as last: a call's audio goes over
SCO or eSCO, which the controller has to carry and which over USB
means isochronous endpoints, and there is iso plumbing in
.CW devusb
and
.CW usbxhci
that is still not verified.  So a call can be seen, placed, answered
and ended here, and cannot be heard, and
.CW bthfp
says so when it starts rather than leaving it to be discovered by
holding a silent telephone.  HSP is not implemented separately; a
headset offering only the older profile is found by the same search,
because its service class is looked for too.
.NH 2
The bench, and what it cannot cover
.PP
.CW scripts/bthci.py
models a controller and the devices on the other side of it: LE and
BR/EDR both, inquiry, connections, secure simple pairing, service
discovery, RFCOMM, HID, BNEP, AVDTP and a hands free gateway.  What it
does not model is what nothing here implements either: SCO and eSCO,
so no call audio and no SCO-carried anything; Secure Connections; and
an address that rotates on the Classic side.
.PP
And a model is not a radio.  Nothing here has met real controller
timing, a vendor's firmware, or the air, and every phase in the bench
is this stack talking to a program that was written from the same
specifications by the same reader.  Where that could be narrowed it
was \(em the AES vectors, the ah test vector, the RFCOMM frame check
sequence against frames every description of the protocol quotes \(em
and where it could not, the record says so.  The first real device
will find things this cannot.
.NH 2
Reading the wire with something this reader did not write
.PP
The largest of those gaps has now been narrowed rather than merely
written down.
.CW "bthci.py --snoop"
writes every HCI packet, both directions, to a
.CW btsnoop
capture, which is the format every Bluetooth capture tool reads, and
the bench runs
.CW tshark
over each phase's capture and fails the phase on any expert warning or
error.  Wireshark's dissectors \(em HCI, L2CAP, SDP, RFCOMM, BNEP,
AVDTP, ATT, SMP \(em were written by other people from the same
specifications, so they are the one check in this bench that does not
share this reader's understanding of them.  Notes are not failures:
.CW "Reached ATT_MTU"
is what a dissector says about a value longer than one packet, which
the bench sends on purpose.
.PP
It found four faults, and every one of them had been passing the
bench.  The first three came on the first run and the fourth once
those were fixed and the run reached further.
.IP \(bu
The model answered
.CW HCI_Inquiry
with a Command Complete.  Inquiry is defined to answer with a Command
Status, and so is every command that takes time; the model's fallback
for an opcode it did not recognise completed it.  The guest took
either, which is the right thing for a guest to do and is why nothing
here noticed.
.IP \(bu
The PAN phase sent a frame whose ethertype said ARP and whose body was
a counted up byte pattern, and the model handed it back with the
addresses swapped.  Both ends were content;
.CW tshark
called the packet malformed.  It is now a real ARP request, broadcast,
and the model builds a real ARP reply out of its fields \(em which is
a stronger assertion than the echo was, because a reply has to be
constructed by the far end and a loopback anywhere along the path
cannot produce one.
.IP \(bu
The audio phase sent six hundred counted up bytes down a channel that
had just agreed to SBC.  A stream whose configuration says SBC and
whose payload is not SBC is a lie on the wire, and the comment saying
that nothing here pretended the bytes were audio did not make the
bytes any less wrong.
.CW avdtp->sbcsilence
now builds a real SBC frame for whatever configuration was agreed:
the header, the length from the spec's own formula \(em which differs
for joint stereo, because of the join bit per subband \(em and the
CRC, with every scale factor and sample bit zero.  That is not an
encoder and there still is not one; it is the frame an encoder would
emit for a block of nothing.
.IP \(bu
The HID phase wrote Protocol Mode with a Write Request.  That
characteristic is write without response and not write \(em the model
had always declared it so, in the very same table \(em and a real
device answers a Write Request to it with Write Not Permitted.  The
properties were being read to decide whether to offer a writable file
and then ignored when the write was made.
.CW gatt->writecmd
is the other opcode, and
.CW btfs
now picks by what the characteristic declared.  The model refuses the
wrong one now, so the fix is held in place by something rather than by
having been made: with
.CW btfs
put back the way it was, the peer answers Write Not Permitted, the
dissector flags it, and the phase's own assertion \(em that the host
selected the boot protocol exactly once \(em fails.
.PP
The SBC frames were then checked against a second independent
implementation.
.CW ffmpeg
has an SBC decoder, and it decodes the frames taken back out of the
capture without a CRC error, deriving 48 kHz stereo and 16 kHz mono
from the bitstream alone \(em matching the two configurations the
model negotiates.  That it finds every frame boundary is what confirms
the length formula: get the length wrong and the next syncword is not
where the decoder looks for it.  The controls bite \(em flipping one
CRC byte makes
.CW ffmpeg
reject the frame, and a wrong syncword makes it reject the stream \(em
so the clean decode means something.  The audio is silence to within
the synthesis filterbank's own rounding, about \-67 dB.
.PP
And once, the disagreement was the other way round.  The Classic HID
phase draws two malformed packets from
.CW tshark ,
and they are not this side's fault.  That device declares Report ID 1
for the mouse and 2 for the keyboard, which is the reverse of the boot
protocol's convention and is deliberate: a host that assumed the boot
layout would have them exactly the wrong way round, and this phase is
what would catch it.
.CW tshark
assumes it.  It does not take the report descriptor out of SDP
attribute 0x0206 to drive its HID dissector, so it falls back to the
boot layout, reads report ID 1 as a keyboard report, finds four bytes
where a boot keyboard report has eight, and says malformed.  Swapping
the two identifiers on the wire makes every complaint go away, which
is what settled it: the bytes are well formed report protocol data and
the disagreement is about what the identifiers mean.  So the check
brought in to catch this side assuming things caught the other side
assuming them, and the guest, which reads the descriptor because that
is what
.CW hidreport (2)
is for, has it right.
.PP
That allowance, like
.CW params 's,
names the dissector chain and not just the message, so it covers the
HID dissector saying malformed and not malformed anywhere: a truncated
packet in that same capture still fails the phase.
.PP
The check has controls of its own, because a check that reads nothing
and reports nothing is worse than no check.  A capture with one ACL
packet truncated is failed; a capture holding only its header is
failed, which is the shape the mistake would take if
.CW --snoop
stopped reaching the model; and the phases that inject faults a
controller may not commit declare, by its text, the one complaint they
are allowed to draw, so any other still fails them.
.CW params
is the one that has such a declaration: it sends a connection
parameter request with a slave latency of 400 and a supervision
timeout of a tenth of a second, which the guest refuses and which
Wireshark is right to call a parameter mismatch.  Truncating a packet
in that same capture still fails it.
.PP
What this still is not is a radio.  A dissector checks that the bytes
are well formed and self consistent; it does not check timing, it does
not know what a vendor's firmware does, and it cannot tell that a
sequence which parses is a sequence a real controller would accept.
.PP
And it does not see everything even in the bytes.  The media packet's
timestamp counts samples, and how many samples a frame carries depends
on the configuration \(em sixteen blocks of eight subbands is a
hundred and twenty eight, four of four is sixteen.  It was written as
a constant, correct for the configuration it was written against and
eight times wrong for the other one the bench negotiates, and neither
new check could have said so:
.CW ffmpeg
decodes the SBC with the RTP header stripped off, and Wireshark does
not cross-check a timestamp against the codec parameters.  It is
.CW avdtp->sbcsamples
now, asked for rather than assumed.  A second implementation narrows
the gap; it does not close it, and what it does not cover is not
smaller for being harder to see.
.NH 2
Meeting a real controller, and the suites that exist
.PP
The obvious route does not exist.  QEMU had Bluetooth device
emulation \(em the
.CW -bt
options and a
.CW bt-hci
device \(em and it was removed in 6.0 as unmaintained and never
finished.  There is nothing to emulate a controller with, so a real
controller has to be a real controller, and there are three ways for
one to reach this stack.
.IP 1.
.B "USB passthrough."
.CW -device
.CW usb-host
hands a real dongle to the guest, and
.CW os/inferno/pc64/qemu-boot.sh
already passes its arguments through.  The
.CW pc64bt
configuration already builds
.CW usb
with
.CW usbxhcipci
and
.CW usbxhci ,
so the dongle would appear under
.CW /dev/usb .
This is the route that would give
.CW appl/lib/bt/btusb.b
its first real packet: it is written and it has never moved one.  It
needs interrupt and bulk endpoints, which is the part of
.CW devusb
that is exercised elsewhere; the isochronous endpoints SCO would need
are the part that is not, which is the same wall the audio work
stopped at.
.IP 2.
.B "A UART module."
A controller on a serial port is H4, or H5 over a line that drops
bytes, and both are implemented and both are in the bench.
.CW -serial
onto a USB serial adapter with a module behind it needs no USB stack
in the guest at all, which makes it the shortest path to a real radio
and the one that tests the least new code.
.IP 3.
.B "A relay onto the transport that is already proved."
.CW btfs
takes a
.CW tcp!host!port
dial string, which is how every phase of this bench reaches the model.
A small relay on a machine that can open a real controller \(em on
Linux, an
.CW AF_BLUETOOTH
.CW HCI
socket bound to a device that has been taken down \(em turns a real
radio into that same dial string, and nothing in the guest changes.
It is the least faithful of the three, because the host's kernel is in
the path and the timing is not the controller's, and it is the only
one of the three that can be set up from this machine at all: macOS
does not expose HCI, so the controller has to be on the other end of
something regardless.
.PP
On suites, three things exist and they are not equivalent.
.IP \(bu
The SIG's
.B "Profile Tuning Suite"
is the conformance suite, and it is what qualification actually means.
It runs on Windows against a dedicated PTS dongle and drives the
implementation under test through each profile's test cases;
.B AutoPTS
scripts it.  This is the real answer to the question, and it is also
the heaviest: it wants a controller, a host to drive, and an
implementation complete enough that the test cases have something to
talk to.
.IP \(bu
BlueZ's
.B btvirt
and
.B btproxy ,
built on its
.CW emulator/btdev.c ,
are an independently written controller emulator \(em the thing this
bench's model is, written by other people.  Running against it would
close the same gap the dissector closes, but for behaviour rather than
for framing: it would answer commands the way its authors read the
specification, and disagreements would be findings.  BlueZ's
.CW l2test ,
.CW rctest
and its unit tests come with it.  It is Linux only.
.IP \(bu
Wireshark's dissectors, which are the one of the three available on
this machine, and which are now wired into every phase of the bench.
.PP
The order that costs least for what it finds is: the dissector, then
.BR btvirt ,
then a UART module, then PTS, which is where a claim of conformance
would have to come from and which nothing here is ready for.  The
first two are done.
.NH 2
BlueZ, in a container
.PP
.CW scripts/btvirt
builds an image with BlueZ 5.79 in it and
.CW scripts/btvirt/run.sh
runs a bench phase against it instead of against the model.
.PP
.CW "btvirt -s"
is what makes this cheap.  It listens on a Unix socket and speaks
plain H4 \(em a packet type byte and then the packet \(em which is
exactly what
.CW btfs 's
.CW tcp!
transport already speaks, so nothing in the guest changes.  It needs
no kernel module, no
.CW /dev/vhci
and no privilege, which matters because Docker Desktop's LinuxKit
kernel has no
.CW hci_vhci
in it at all: the route through the kernel's own Bluetooth stack,
which would have been better still, is not available there.
.PP
The peer is
.CW scripts/btvirt/btpeer.c ,
and it is BlueZ from top to bottom.  Every controller btvirt makes
goes in one list, so a second connection to that same socket is a
second controller the first can hear; on it sits
.CW emulator/bthost.c ,
which is the host stack BlueZ drives its own implementation with in
its tests, and on that sits
.CW src/shared/gatt-server.c
over
.CW src/shared/gatt-db.c ,
which is BlueZ's real GATT server.  The only glue is a socketpair,
because
.CW bt_gatt_server
wants a file descriptor \(em on Linux an ATT channel is a socket \(em
and here the channel is a CID inside bthost.  It is
.CW SOCK_SEQPACKET
and not
.CW SOCK_STREAM ,
because ATT is a datagram protocol and a PDU that arrived in two
reads would be two malformed PDUs.
.PP
So what the Inferno side meets is a controller, a link layer, a host,
an SMP and a GATT server that were all written by other people.  The
.CW btvirt
phase passes against it:
.IP \(bu
the scan finds the peer, and the advertising data \(em flags and a
complete local name \(em is parsed into a name;
.IP \(bu
the connection comes up and the MTU exchange settles on 247;
.IP \(bu
discovery finds all four services with their characteristics and
client characteristic configuration descriptors;
.IP \(bu
the device name and the battery level read back;
.IP \(bu
subscribing writes the descriptor and three notifications arrive;
.IP \(bu
a two hundred byte write goes out as Prepare Write and Execute Write
and reads back whole, which is the path a bug was found in before;
.IP \(bu
legacy pairing completes and the link encrypts;
.IP \(bu
an inquiry finds the same peer on BR/EDR and pages it;
.IP \(bu
an L2CAP channel in basic mode carries a frame and the answer comes
back in upper case;
.IP \(bu
a serial port over RFCOMM does the same;
.IP \(bu
and an LE credit-based channel carries an SDU segmented to the peer's
MPS, one PDU per credit.
.PP
The bond it records has an all zero long term key, and that is not a
fault on either side:
.CW distribute_keys
in
.CW emulator/smp.c
sends zeros for every key it distributes, and the capture shows the
Encryption Information PDU carrying sixteen zero bytes.  This side
stored what it was given.  It is worth writing down because a bond
full of zeroes looks like a bug and is not one.
.PP
The traffic goes through
.CW scripts/btvirt/relay.py
rather than straight at the published port, because that is what
captures it, in the same btsnoop the model writes.  So the tshark
check runs over a conversation with BlueZ as well: 129 packets, no
expert warnings or errors, with Wireshark reading the whole SMP
exchange and the ATT traffic.  Three implementations that do not share
a reader now agree about those bytes.
.PP
The Classic half runs against it too.  Every controller btvirt makes
goes in one list and an inquiry walks that list, so the same peer
answers an inquiry; the phase finds it that way rather than by naming
an address, because the address is btvirt's to choose.  It then pages
it, opens an L2CAP channel in basic mode on a test PSM, and opens a
serial port over RFCOMM on channel 1 \(em bthost has servers for
both.  Each answers with the same bytes in upper case rather than
echoing them, because an echo is a weak assertion: a loopback
anywhere along the path passes it, and upper case has to be applied by
whoever received it.  Both come back.
.PP
RFCOMM is the one most worth having.  It is TS 07.10 with a Bluetooth
adaptation layer, written here out of the specification, and the
multiplexer start-up, the parameter negotiation, the DLC state machine
and the modem status exchange all now run against someone else's
reading of the same document.  They agree.
.PP
The frame after them did not, and the disagreement is BlueZ's.
.CW bthost_send_rfcomm_data
writes
.CW "sizeof(struct rfcomm_hdr) + len"
into the length indicator, which TS 07.10 section 5.2.1.4 defines as
the length of the information field alone.  Three too many: the
address, the control and the length octet are the header, not
information.  A 22 byte reply went out declaring 25, this stack
refused it, and
.CW tshark
called the frame malformed.
.PP
What settles it is that BlueZ's own receiver refuses it as well.
.CW rfcomm_uih_recv
reads the field as the information length and drops the frame unless
.CW "len >= hdr_len + data_len" ;
for a frame bthost sent, that is 26 against 3 plus 25, so bthost
cannot read back what bthost writes.  The sender and the receiver in
one file disagree, which is why nothing here is a matter of
interpretation: three readings \(em this stack's, Wireshark's, and
BlueZ's own parser \(em all say the same thing about BlueZ's
generator.  The image carries a two line patch for it,
.CW scripts/btvirt/bthost-rfcomm-length.patch ,
declared rather than folded into the build, and nothing else in
BlueZ's RFCOMM is touched, because the rest of it is the point.  This
is
.CW emulator/bthost.c ,
the host stack BlueZ tests with, and not the RFCOMM in the Linux
kernel.
.NH 3
Credits, against a peer that gives them one at a time
.PP
The LE credit-based channel goes on the link before it is dropped.
The peer serves it with an MTU of 512, an MPS of 48 and one initial
credit, and grants one credit at a time thereafter, which is the
stingiest a peer may legally be and the case a sender is most likely
to get wrong.
.PP
A 150 byte SDU goes out as 152 bytes with the two byte SDU length on
the first PDU, and the capture shows it cut to 48, 48, 48 and 8 \(em
exactly the MPS the peer asked for \(em with one of BlueZ's credit
grants between each.  The peer reassembles it and answers in upper
case.  So the segmentation, the SDU header going on the first PDU and
not on the rest, and waiting for a credit before sending are all now
checked against another implementation.
.PP
150 and not 200, and the reason is the peer's.
.CW bthost_send_cid
prepends the SDU header and hands the whole thing to
.CW send_acl
as one L2CAP PDU: it does not segment to the MPS the other side asked
for, and it keeps no account of the credits it has been given.  This
side offered an MPS of 188 in the connection request and BlueZ's
response acknowledged it \(em both are in the capture \(em and BlueZ
then sent 202 bytes in one PDU, which this side refused.  Refusing it
is right.
.PP
That one is not patched.  The RFCOMM length was two lines and could
not be anything but wrong; segmenting properly means tracking credits
on the send side as well, which is a change worth more care than a
test fixture deserves, and getting it half right would put a defect
into the thing being used as the independent reading.  So the SDU is
sized to what the peer can answer, the direction worth testing is
still tested, and the limitation is written here instead.
.PP
One thing found in the writing was this side's and not BlueZ's: the
.CW status
argument to an RFCOMM connect callback is true when the channel came
up, not when it failed, which is the opposite of what the name
suggests.  Reading it the other way round made a channel that opened
perfectly well look refused, and the data hook was never installed, so
the far end wrote into silence.  BlueZ's own
.CW tools/rfcomm-tester.c
ignores the argument entirely.
.PP
The control is the
.CW full
phase, which fails against this peer, and should: it ends by watching
a device rotate a resolvable private address, and btvirt's peer
advertises from a public address and does not rotate.
.PP
What this is still not is a radio, and one thing it is not either: the
contents of the peer's GATT database were chosen here, even though the
server answering out of it is BlueZ's.  What has been checked is the
protocol, not the profile.
.PP
Key storage is now its own service, as the brief suggests, rather
than a file
.CW btfs
happens to write.
.CW btkeyfs
serves
.CW bonds
and
.CW ctl ,
holds the store in a file of its own, and owns both files 0600 so that
a readable radio is not a readable key.
.CW "btfs -K"
names it and then keeps no key file: the bonds are read from the
service at startup and each new one is sent to it as a message.  The
text is the same in all three places \(em the served file, the store on
disk, and what
.CW btfs
shows in
.CW /net/bt/N/bonds \(em
because one piece of code writes it.  The bench runs the whole pair
and rejoin pair of phases over the service as well as over a key file,
with the same assertions, and a third phase exercises the store alone:
a bond per peer per controller, writing one twice replacing rather
than doubling it, a keyless line refused, and forgetting a peer on one
controller leaving it bonded on the other.  The controls are an empty
store, which must leave the rejoin with no bond, and \(em run by hand
\(em a store that appends and a store that takes a keyless line, both
of which the phase catches.
.PP
H5, the three-wire UART transport, is done.
.CW btfs -5
selects it: SLIP framing, a four byte header with sequence and
acknowledgement numbers, retransmission, and the sync and configure
handshake before anything may pass.  The window is one packet, which
is what makes the sender a loop rather than a queue with a timer per
entry; and no CRC is asked for or sent, which the configuration
negotiates.  Nothing above the transport changes, and the bench runs
its whole first phase over it.
.NH 1
The 9front implementation
.PP
The stack was written to be carried to 9front, and the shape it was
written in is what makes that cheap.  What cannot be carried is the
source: a native Inferno has no C user space and 9front has no Dis
interpreter, so this is a transliteration, not a port.  The point of
the discipline in the Limbo \(em byte arrays in and out over an
explicit session record, channels only at the seams between layers and
never inside protocol logic \(em is that the transliteration is
mechanical.
.NH 2
Step 0: there is nowhere to put it
.PP
This must be said before anything else.
.CW os/9front
in this tree is a kernel:
.CW port ,
.CW pc ,
.CW pc64 ,
.CW ip ,
.CW boot ,
.CW lib ,
and nothing more.  There is no libc, no libthread, no lib9p, no
.CW cmd ,
and so no way to build a 9front user program here and no way to run
one.  Two honest ways forward:
.IP \(bu
Write it on a real 9front, in
.CW /sys/src/cmd ,
where libthread, lib9p, libsec and nusb already are, and carry the
sources back into this tree afterwards as a userland subtree this tree
does not itself build.
.IP \(bu
Vendor a 9front userland into this tree first \(em libc, libthread,
lib9p, libsec and their headers, built for the target by the
.CW utils
compilers that are already here \(em and then write it in place.
.PP
The first is much the smaller job and is what this plan assumes.  The
second is a real piece of work with its own questions about where a
userland sits beside a kernel that is meant to be self-contained, and
it should not be started by accident on the way to Bluetooth.
.NH 2
Step 1: the mapping is nearly one to one
.PP
9front's libthread has the primitives Limbo has, which is why this is
transliteration and not redesign:
.EX
	spawn f(x)           proccreate(f, arg, stack)
	chan of T            chancreate(sizeof(T), 0)
	chan[n] of T         chancreate(sizeof(T), n)
	c <-= v              send(c, &v)
	v := <-c             recv(c, &v)
	alt { ... }          alt(Alt[])
	alt with a default   nbsend / nbrecv
	chan[1] of int lock  QLock
	array of byte        uchar*, and a length beside it
	a module's globals   static state in one file
.EE
The transport interface, which in Limbo is a module loaded by path,
becomes a struct of function pointers that
.CW h4.c
and the USB transport fill in.  Nothing above it changes.
.PP
The one place to be careful is that C has neither bounds checking nor
a garbage collector, so the bugs will move.  They will move to the H4
length arithmetic and to the ATT and GATT response parsers \(em which
are precisely the two places this Limbo got it wrong once each, so the
review effort is already scoped.
.NH 2
Step 2: file for file
.TF appl/cmd/bt/btbench.b
.PD
.TP
.CW appl/lib/bt/bt.b
.CW bt.c :
the accessors.  An afternoon, and the least interesting file.
.TP
.CW appl/lib/bt/h4.b
.CW h4.c
over
.CW /dev/eia* .
The framing is identical and so is the rule that made it correct:
read exactly the length the header gives and never read ahead.
.TP
.CW appl/lib/bt/btusb.b
a program under
.CW nusb ,
following that directory's own idiom rather than this one.  The
.CW /dev/usb
interface is the same interface: this tree's
.CW devusb
.I is
9front's, taken across earlier, so the endpoint files, the
.CW new
control message and the descriptor walk are the same on both sides.
.TP
.CW appl/lib/bt/hci.b
.CW hci.c :
a proc reading the transport and dispatching, a QLock around the
command, and a counting semaphore for the ACL credits.
.TP
.CW appl/lib/bt/l2cap.b
.CW l2cap.c :
a proc per link, a Channel per CID.
.TP
.CW appl/lib/bt/att.b
.CW att.c :
a router proc, a QLock, a reply Channel.
.TP
.CW appl/lib/bt/gatt.b
.CW gatt.c :
the same three discovery loops.  Pure logic, no concurrency, the
easiest file to be confident about.
.TP
.CW appl/lib/bt/smp.b
.CW smp.c
over libsec's AES for
.CW e() ;
.CW c1
and
.CW s1
transliterate unchanged, and the byte-order reversal that is the easy
thing to get wrong stays in one function, as it does here.
.TP
.CW appl/cmd/bt/btfs.b
.CW btfs.c
over lib9p.  This file gets
.I smaller .
lib9p's
.CW File
tree with
.CW createfile
and
.CW removefile
is exactly what
.CW nametree
was standing in for, and it is reference-counted and safe against
several writers, so the lock this stack needed around tree operations
has nothing to guard and goes away.
.TP
.CW appl/cmd/bt/btbench.b
not a program.  Every step of it is an
.CW echo
or a
.CW cat ,
so on 9front it should be a shell script, which is a fair measure of
whether the name space came across intact.
.PD
.NH 2
Step 3: the order, with a test at every step
.PP
The leverage here is that
.CW scripts/bthci.py
does not care what the guest runs.  It is a host-side program on the
end of a serial line or a network connection, so every step below has
a test from its first day, and the Inferno stack is a reference
implementation that already passes the same test.
.IP 1.
.CW h4.c
and
.CW hci.c ,
and a
.CW main
that resets the controller, reads its address, scans and prints
advertisements.  Against the model.  This is where the framing and the
command path are proved.
.IP 2.
.CW l2cap.c ,
.CW att.c ,
.CW gatt.c :
connect, discover, read a characteristic.  Against the model.
.IP 3.
.CW btfs.c
over lib9p, serving the same names, driven by the same shell commands
the Inferno bench uses.
.IP 4.
.CW smp.c :
pairing.  Against the model, which checks the commitment independently
and refuses a wrong one.
.IP 5.
The USB transport, against a real dongle.  This is the step where
9front gets ahead of Inferno rather than catching up, because nusb is
a mature place to put it and the hardware is there.
.PP
Port a file, run the model, and only then start the next.  The three
bugs this stack had were each found in one step of exactly that loop,
and each would have been much harder to find two steps later.
.NH 2
Step 4: what 9front makes easier, and what it does not
.PP
Easier: lib9p instead of styxservers and nametree and a hand-written
Navigator; libsec directly, which is also a better place to put P-256
if Secure Connections is ever wanted, since it would then serve
everything else on the system too; nusb, which already does hotplug,
so the
.CW usbd
link this stack is missing comes free; and real hardware, on a system
that is used on real hardware.
.PP
Not easier, and worth being clear about: nothing structural.  The
protocol is the protocol.  What is lost is Limbo's bounds checking and
its garbage collector, and what is gained is that the result runs
where 9front runs.
.NH 2
Step 5: keeping the two readable against each other
.PP
Keep the name space identical, keep the layer boundaries identical,
and keep the wire-format functions comparable line for line, so a fix
found on one side can be read across to the other.  Where the two must
differ \(em lib9p against styxservers, libthread against Limbo
processes \(em keep the difference at the seam and out of the protocol
code.  The moment a bug has to be fixed twice from scratch, the
discipline has already been lost.
.NH 2
And Osprey
.PP
Osprey gets nothing from either side.  It is a microkernel with
library operating systems above it: the unit of execution is a task,
the central call is
.CW select ,
and a driver is a task selecting on its own message queue, on a
semaphore an interrupt raises, and on its output queue.  It runs no
Dis, so none of the Limbo can land there, and the file server that
holds this design together has nothing to serve into.  Bluetooth on
Osprey is a third transliteration against that model \(em the
transport as a driver task, the layers above it as a library operating
system, and whatever Osprey offers in place of a name space \(em and
it is not attempted here.
