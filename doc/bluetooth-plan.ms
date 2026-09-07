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
What is missing is everything above L2CAP on such a link.  There is no
GATT server \(em a database served from the name space rather than
discovered into it, which is the same tree read the other way \(em so
a peer that connects and asks for attributes gets no answer at all.
And there is no responder half of SMP, so a peer cannot pair with this
side; the Long Term Key Request event a peripheral gets when the peer
starts encryption is not handled either.  Until those two exist this
side can be found and connected to and is of no use once it has been.
.NH 2
Profiles, in the brief's order
.IP 1.
.B "HID over GATT."
The first genuinely useful device class and mostly parsing: the report
map, boot versus report protocol, and then keys onto
.CW /dev/keyboard
and motion onto
.CW /dev/pointer ,
exactly as
.CW appl/cmd/usb/usbd.b
already does for USB.  A BLE keyboard and mouse are the milestone
worth aiming at next.
.IP 2.
.B "Bluetooth Classic, at all."
Nothing of it exists.  Inquiry, remote name requests, BR/EDR
connections, link keys and secure simple pairing; and L2CAP's
connection-oriented channels, which LE never needed and which
everything Classic is built on.
.IP 3.
.B SDP .
Both halves.  Nothing Classic can be found without it.
.IP 4.
.B "RFCOMM and the serial port profile."
With SDP under it, this is what turns a Classic device into
.CW /net/bt/0/remote/ADDR/rfcomm/1/data
and lets a program open it like a serial line.
.IP 5.
.B "Classic HID."
HIDP over L2CAP, for the older keyboards and mice.
.IP 6.
.B "PAN and BNEP,"
and with them a binding into the IP stack so a Bluetooth link is
another
.CW /net/ether .
.IP 7.
.B "A2DP and AVRCP."
AVDTP signalling, media transport, codec negotiation, SBC at minimum,
buffering and timing, and
.I devaudio
underneath.  The brief says to leave audio out of a first stack and it
was right.
.IP 8.
.B "HFP and HSP,"
last, because they need synchronous transport: SCO and eSCO through
the controller, which over USB means isochronous endpoints.  There is
iso plumbing in
.CW devusb
and
.CW usbxhci
and none of it is verified.
.NH 2
The bench, and what it cannot cover
.PP
.CW scripts/bthci.py
models an LE controller and only that.  It has no Classic side, no
SCO, no Secure Connections, and it never rotates an address, so
everything in the two sections above that is not LE-and-legacy needs
the model extended before it can be tested at all.  And a model is not
a radio: nothing here has met real controller timing, a vendor's
firmware, or the air.  The first real device will find things this
cannot.
.PP
Two smaller pieces belong here.  Key storage should be its own
service, as the brief suggests, rather than a file
.CW btfs
happens to write; and H5, the three-wire UART transport, is what some
modules speak instead of H4.
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
