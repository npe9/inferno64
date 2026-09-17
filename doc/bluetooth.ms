.\"
.\" EX and EE are man(7) macros and mean nothing to ms.
.\"
.de EX
.br
.in +4n
.nf
..
.de EE
.fi
.in -4n
.br
..
.TL
A Bluetooth Stack as a File Server,
and Four Ways to Find Out Whether It Works
.AU
Inferno RIO
.AI
.DA
.AB
Bluetooth is a dozen protocols stacked on one another, and an
implementation of it is usually a kernel subsystem with a socket
interface on the side.  This one is not: it is an ordinary user
program that serves a name space, and a program uses Bluetooth here by
opening, reading and writing files.  The kernel carries HCI packets
and does nothing else.
.PP
That is the easy half to describe.  The hard half is knowing whether
any of it is right, because a protocol stack tested against a model
written by the same person who wrote the stack will agree with itself
about its own misreadings.  This paper describes the architecture, and
then describes four checks arranged so that each one is answerable by
something that did not share the author's reading of the
specification: a model with negative controls, a dissector nobody here
wrote, a second implementation to pair with, and an arithmetic library
to check the parts the second implementation cannot.  Between them
they found nine faults: six in this stack and the bench that was
supposed to be testing it, and three in the implementation brought in
to check it.
.AE
.NH 1
What this is
.PP
.CW btfs
is a Bluetooth stack for Inferno: Low Energy and Classic, about ten
thousand lines of Limbo in fifteen libraries, with another ten
thousand in the programs that use them and the bench that tests them.
It speaks to a controller over H4 or H5 on a serial port, over USB, or
over a TCP connection, and it serves everything above that as files.
.PP
The layers are one library each, and the sizes are worth reading as a
map of where the difficulty is:
.EX
hci.b     1644   commands, events, links, credits
l2cap.b   1425   channels: fixed, basic, credit-based
smp.b     1372   pairing, legacy and Secure Connections
rfcomm.b   878   TS 07.10 and its adaptation layer
gattsrv.b  778   the attribute database, served outward
sdp.b      761   service discovery, both halves
avdtp.b    599   the signalling under an audio stream
h5.b       475   SLIP framing, sequencing, retransmission
gatt.b     437   discovery, read, write, subscribe
hfp.b      362   a telephone, as AT commands
btusb.b    358   the transport over /dev/usb
bnep.b     257   ethernet frames over a link
bt.b       229   addresses, hex, byte order
att.b      224   requests, responses, notifications
h4.b       197   the transport over /dev/eia
.EE
.PP
.CW hci.b
and
.CW l2cap.b
are the largest because they are where the concurrency is.  Everything
above them is a protocol written down; those two are a protocol
written down plus the business of not deadlocking.
.NH 1
The shape: a name space
.PP
Bluetooth's own structure is a hierarchy \(em a controller, the
devices it can hear, the services each device has, the
characteristics inside a service \(em so it is served as one:
.EX
/net/bt/0/addr
/net/bt/0/ctl
/net/bt/0/state
/net/bt/0/bonds
/net/bt/0/remote/345678ABCDEF/name
/net/bt/0/remote/345678ABCDEF/state
/net/bt/0/remote/345678ABCDEF/confirm
/net/bt/0/remote/345678ABCDEF/gatt/180f/2a19
/net/bt/0/remote/345678ABCDEF/gatt/180f/2a19.notify
/net/bt/0/remote/345678ABCDEF/l2cap/0080
/net/bt/0/remote/345678ABCDEF/rfcomm/1/data
.EE
.PP
Reading a battery level is
.CW cat ;
subscribing to it is
.CW cat
of a different file that blocks until the next notification.  A serial
port over RFCOMM is a file you write to and read from.  An L2CAP
channel is a file where one write is one SDU and one read is that SDU
whole, on either kind of link \(em one pair of files, two very
different protocols underneath.
.PP
The consequences of this are larger than they look.
.IP \(bu
The programs above the stack contain no Bluetooth.
.CW bthid
turns a keyboard into keystrokes by reading notification files;
.CW btpan
serves an ethernet interface by opening one L2CAP channel file and
speaking BNEP over it;
.CW bthfp
dials a telephone by writing to a file.  None of them links against
the stack.
.IP \(bu
The stack can be tested from a shell script, and is.
.IP \(bu
It can be somewhere else.  A name space is mountable, so the radio can
be on another machine, and nothing above notices.
.IP \(bu
Two radios are two directories in one program rather than two
programs, so the node table and the key store are shared while the
links and the bonds are not.
.PP
The keys are their own service.
.CW btkeyfs
serves
.CW bonds
and
.CW ctl
at
.CW /net/btkeys ,
owns both 0600, and keeps the store in a file of its own, so that a
readable radio is not a readable key.
.CW "btfs -K"
names it and then keeps no key file at all.
.NH 1
Concurrency
.PP
Each layer is processes and channels, and the rule throughout is that
the demultiplexer never does work that can block.
.PP
.CW hci.b
has a process reading the transport and dispatching, a lock around the
command in flight, and a counting semaphore for the controller's ACL
credits.  A command waits on a reply channel; an event that nobody is
waiting for is dropped rather than queued, because a stale reply
delivered to the next waiter is worse than a lost one.
.PP
.CW l2cap.b
has a process per link and a channel per CID.  Every answer to
signalling is sent from a spawned process rather than from the
demultiplexer, and that was not a stylistic choice: a configuration
response sent inline deadlocked against the ACL credits, because the
process that would have freed a credit was the one waiting to send.
.PP
The lesson recurs.  A layer that answers its own inbound traffic
synchronously will eventually wait on something the inbound path is
responsible for delivering.
.NH 1
Cryptography
.PP
.CW libsec
in this tree has no elliptic curve code, so LE Secure Connections
needed the arithmetic before it could need the protocol.
.PP
.CW cmac.b
is AES-CMAC over the AES the interpreter already exposes: one block of
CBC with a zero initialisation vector is ECB for that block.
.CW p256.b
is the NIST P-256 curve over
.CW IPint ,
the multi-precision integers Limbo already has.  Points are affine and
every addition inverts, which is the slow way and the way that can be
read against the formulas line by line; a scalar multiplication takes
about 150 ms and a pairing needs two.
.PP
Two decisions in
.CW p256.b
are worth naming because they are about being checkable rather than
about being fast.  The point at infinity is a nil coordinate, so the
identity is a case the arithmetic must name rather than one it can
fall into.  And
.CW a
is computed as
.CW p\-3
rather than written out, because writing it out is one more place for
a typing mistake that the curve equation would then agree with.
.NH 1
The problem with testing this
.PP
.CW scripts/bthci.py
models a controller and the devices behind it: LE and BR/EDR, inquiry,
connections, secure simple pairing, service discovery, RFCOMM, HID,
BNEP, AVDTP and a hands-free gateway.  A bench runs sixty-seven phases
against it, each asserting something specific, and it is a good model.
It is also written from the same specifications by the same reader as
the stack it tests.
.PP
That is not a small caveat.  It means a misreading agrees with itself.
If the author believed the RFCOMM length field counted the header,
both ends would believe it, every frame would round-trip, and every
phase would pass.  The bench would be measuring self-consistency and
reporting it as correctness.
.PP
So the tests are arranged as a ladder, each rung answerable by
something that did not share that reading.
.NH 2
Rung one: negative controls
.PP
Every assertion has a control that makes it fail.  This is the
cheapest rung and it catches the largest class of mistake, which is a
test that would pass whatever the code did.
.PP
Four phases are inverted: the bench requires them to fail, and then
requires them to have failed for the stated reason.
.CW keynone
rejoins from an empty key store and must find no bond \(em without it,
a passing rejoin would only show that the stack had kept the key
somewhere of its own.
.CW brnoconf
opens a channel the peer never configures.
.CW rfnocredit
withholds RFCOMM credits.
.CW hidswap
swaps two report references and requires the meaning to change.
.PP
Controls are also applied to the checking machinery itself, which is
where they are most often forgotten.  The capture check is given a
truncated capture and a capture holding only its header, and must fail
both.  A phase declared as having no controller is held to having
none, rather than merely skipped \(em and that assertion caught its
own author, when the cryptography phase was declared no-wire on the
assumption that arithmetic needs no radio.  It does not, but the bench
brings the controller up before it dispatches, so there are thirty-four
packets of HCI start-up whatever the phase then does.
.NH 2
Rung two: a dissector nobody here wrote
.PP
.CW "bthci.py --snoop"
writes every HCI packet, both directions, as a
.CW btsnoop
capture, and the bench runs
.CW tshark
over each phase and fails it on any expert warning or error it has not
declared.  Wireshark's dissectors were written by other people from
the same documents, which is the entire point of them.  A full run
puts about ten thousand packets through them.
.PP
It found three faults on its first run, all of which had been passing
the bench, and all three the same shape: a frame that declared one
thing and carried another, with both ends agreeing about it.
.IP \(bu
.CW HCI_Inquiry
was answered with a Command Complete.  Inquiry answers with a Command
Status, and so does every command that takes time.  The guest accepted
either, which is the right thing for a guest to do and is exactly why
nothing noticed.
.IP \(bu
A frame whose ethertype said ARP carried a counted-up byte pattern.
It is a real broadcast ARP request now, and the model builds a real
ARP reply out of its fields \(em a stronger assertion than the echo it
replaced, because a reply must be constructed by the far end and a
loopback anywhere along the path could pass the old check.
.IP \(bu
The audio phase sent six hundred counted-up bytes down a channel that
had just agreed to SBC, under a comment saying that nothing pretended
they were audio.  That was true about the intent and did not make the
bytes any less wrong.
.CW sbcsilence
now builds a real SBC frame for whatever configuration was agreed \(em
the header, the length from the spec's own formula, and the CRC \(em
with every sample bit zero.  It is not an encoder; it is the frame an
encoder would emit for a block of nothing.
.PP
Once the disagreement went the other way.  The Classic HID phase draws
malformed packets from
.CW tshark ,
and the bytes are right: that device declares Report ID 1 for the
mouse and 2 for the keyboard, the reverse of the boot protocol's
convention, deliberately, because a host that assumed the boot layout
would have them the wrong way round and this phase is what catches it.
.CW tshark
assumes it \(em it does not take the report descriptor out of the SDP
record to drive its HID dissector.  Swapping the identifiers on the
wire makes every complaint go away, which is what settled it.  So the
check brought in to catch this side assuming things caught the other
side assuming them, and it is declared by dissector chain rather than
by message, so a truncated packet in that same capture still fails.
.NH 2
Rung three: a second implementation to pair with
.PP
A dissector checks that bytes are well formed.  It does not answer
them.  For that the stack needs to talk to an implementation that
disagrees when it is wrong.
.PP
QEMU cannot help: its Bluetooth device emulation was removed in 6.0.
BlueZ can.
.CW scripts/btvirt
builds an image with BlueZ in it;
.CW "btvirt -s"
listens on a Unix socket and speaks plain H4, which is exactly what
.CW btfs 's
.CW tcp!
transport already speaks, so no guest code changes.  It needs no
kernel module and no privilege \(em which matters, because Docker
Desktop's kernel has no
.CW hci_vhci
in it at all.
.PP
The peer is BlueZ throughout.  Every controller btvirt makes goes in
one list, so a second connection is a second controller the first can
hear; on it sits
.CW emulator/bthost.c ,
the host stack BlueZ drives its own implementation with, and on that
.CW src/shared/gatt-server.c .
The only glue is a socketpair, because
.CW bt_gatt_server
wants a file descriptor and here the ATT channel is a CID inside
bthost \(em
.CW SOCK_SEQPACKET ,
since a PDU that arrived in two reads would be two malformed PDUs.
.PP
Against that, and in both roles, the stack now completes: scanning,
connecting, an MTU exchange, discovery, a read, notifications, a long
write through Prepare and Execute, LE pairing legacy and Secure
Connections, numeric comparison, passkey entry, a credit-based channel
segmented to the peer's MPS one PDU per credit, and then on BR/EDR an
inquiry, a page, basic-mode L2CAP, RFCOMM and secure simple pairing.
.PP
It found faults on both sides.  In this stack:
.IP \(bu
.CW respond()
refused any peer that asked for Secure Connections.  Since everything
modern asks for it, a peripheral behaving that way can be paired with
by almost nothing.
.IP \(bu
.CW l2cap.b
made a fixed channel when somebody opened it, and dropped frames for
one nobody had opened yet.  BlueZ sends its Pairing Request the moment
the link is up, so the request was on the wire, the capture showed it,
and this side never answered \(em nothing timed out and nothing was
logged, because from the responder's point of view no request had
arrived.
.PP
And in BlueZ:
.IP \(bu
.CW bthost_send_rfcomm_data
writes the header length into the length indicator, which TS 07.10
defines as the information field's length alone.  What settles it is
that BlueZ's own receiver refuses the frame too:
.CW rfcomm_uih_recv
requires
.CW "len >= hdr_len + data_len" ,
which for a bthost-sent frame is 26 against 3 plus 25.  A sender and a
receiver in one file disagreeing is not a matter of interpretation.
.IP \(bu
.CW bthost_send_cid
does not segment to the peer's MPS and keeps no account of credits: it
acknowledged an MPS of 188 and then sent 202 bytes in one PDU.
.IP \(bu
.CW sc_dhkey_check
builds the check it sends with a bare
.CW "memset(r, 0, sizeof(r))"
and no test of the method, while its verifying half has the
conditional that puts the passkey in
.CW r .
So bthost sends a DHKey check computed with the wrong
.CW r
for every passkey pairing.
.PP
The first of those was patched, because it was two lines and could not
be anything but wrong.  The second was not: segmenting properly means
tracking credits on the send side too, and getting it half right would
put a defect into the thing being used as the independent reading.
The SDU is sized to what the peer can answer instead, and the
limitation is written down.
.NH 2
Rung four: arithmetic, for what the peer cannot check
.PP
Some things are never transmitted, and for those a second
implementation is no help at all.
.PP
Numeric comparison is the sharp case.  Its wire is identical to Just
Works: both sides compute
.CW g2
over the two public keys and the two nonces, and a person compares six
digits that never travel.  A wrong
.CW g2
therefore fails silently \(em two devices showing different numbers,
and nothing in the protocol to notice.  bthost cannot check it, having
no
.CW g2
and nobody to ask.
.PP
So it is checked against
.CW openssl :
the public keys and nonces taken out of a capture, the message
rebuilt, the CMAC computed by openssl, its low four bytes taken modulo
a million.  For a run that showed
.CW "numeric 504437" ,
openssl gives 1191504437, and that modulo a million is 504437.  The
responder's
.CW g2
takes its arguments the other way round, so it is a different
calculation and is checked separately, and agrees too.
.PP
P-256 is checked the same way and also by properties that need no
memorised vector: the base point is on the curve, n times it is the
point at infinity, (n\-1) times it is its own negation, and a
Diffie-Hellman agrees from both sides.  A memorised vector copied
wrongly agrees with itself; a curve constant with a digit changed
fails the first of those, which was tried.  Agreement with openssl is
five freshly generated keypairs, public key and shared secret each.
.PP
AES-CMAC has RFC 4493's four vectors, and they are not four of the
same thing: two of the messages divide into whole blocks and two must
be padded, so both subkeys are exercised.
.NH 1
What the ladder is for
.PP
Set out as a table, the rungs answer different questions:
.EX
control      would this test fail if the code were wrong?
dissector    are these bytes well formed?
peer         does someone else's implementation accept them?
arithmetic   is the number right that nobody sends?
.EE
.PP
No rung subsumes another.  The dissector passed the RFCOMM length
frames as far as HCI and L2CAP went and only complained at the RFCOMM
layer; the peer accepted well-formed frames whose meaning was wrong;
and the arithmetic check exists precisely for the case where there is
nothing on the wire to look at.
.NH 1
What is not tested
.PP
None of this is a radio.  Nothing here has met real controller timing,
a vendor's firmware, or the air.  A dissector checks that bytes are
self-consistent; it does not know what a chip does.  The routes to a
real controller are USB passthrough into the
.CW pc64bt
kernel \(em which would give
.CW btusb.b
its first real packet, since it is written and has never moved one \(em
a UART module on a serial port, or a relay onto the
.CW tcp!
transport.  Conformance in the sense that matters commercially is the
SIG's Profile Tuning Suite, and nothing here is ready for it.
.PP
Audio is absent.  A call's audio goes over SCO or eSCO, which over USB
means isochronous endpoints, and that plumbing is unverified; music
needs an SBC encoder, which is deliberately not written.  So a call
can be seen, placed, answered and ended here, and cannot be heard, and
.CW bthfp
says so when it starts rather than leaving it to be found out by
holding a silent telephone.
.PP
The contents of the peer's GATT database were chosen here, even though
the server answering out of them is BlueZ's.  What has been checked is
the protocol, not the profile.
.PP
And the bench is intermittent.  Under a whole run
.CW emu
sometimes exits without a message, or stalls for more than thirty
seconds \(em long enough that ATT's transaction timeout, which is the
specification's own value, expires while a reply that had already
arrived sits waiting.  The phases that fail pass on their own, five
times out of five.  A phase that never reached the end is retried
once, loudly, and a phase that failed an assertion never is: those are
answers, and running answers again until they change is how a bench
stops meaning anything.
.NH 1
Discussion
.NH 2
What the name space bought, and what it cost
.PP
The usual objection to serving a protocol stack as files is
performance, and it is a real one.  Every operation is a Styx
transaction: opening a characteristic, reading it, writing a control
line.  There is no zero-copy path and no way to express an atomic
operation except by making the control file's grammar carry it.
Errors are strings, so a caller that wants to distinguish two failures
matches text.  For a stack whose busiest link carries a few hundred
kilobits a second this is irrelevant, and on something with a real
data path it would not be.
.PP
What it bought was not mainly elegance.  It was that the interface has
no privileged side.  A test is a program that opens files, so the
bench is a shell script and a Limbo program that between them use
nothing the stack does not already offer to any other caller \(em
which means the thing being tested is the thing that ships, not a
test harness bolted to its internals.  The same property makes the
radio mountable from another machine, and makes
.CW bthid ,
.CW btpan
and
.CW bthfp
contain no Bluetooth: they are file clients, and they would work
unchanged against a radio in another room.
.PP
That is worth stating as a design claim rather than a happy accident.
The shape of the interface determined the shape of the testing, and
the testing is where most of the work went.
.NH 2
Does the ladder generalise
.PP
Nothing about the four rungs is specific to Bluetooth.  Any
implementation of a specified protocol faces the same-reader problem
the moment its tests are written by whoever wrote it, and the four
questions are general:
.IP \(bu
Would this test fail if the code were wrong?
.IP \(bu
Are these bytes well formed by someone else's reading?
.IP \(bu
Does an independent implementation accept them?
.IP \(bu
Is the value right that nobody sends?
.PP
The first is old advice and still the most often skipped, because a
test that has never failed is indistinguishable from a test that
cannot.  The second and third have become cheap in a way they were not
twenty years ago: a container with another implementation in it costs
minutes, and dissectors for most wire formats already exist.
.PP
The fourth is the one worth arguing for, because it has no wire to
look at and so no cheap substitute.  It applies wherever a protocol
computes something both ends must agree on without transmitting it,
which is most of what cryptography is: derived keys, confirmation
values, comparison numbers.  Those are exactly the values whose
wrongness is invisible \(em a wrong
.CW g2
does not corrupt a packet, it just quietly stops the six digits from
meaning anything \(em and they are also exactly where the security
lives.  A test suite that checks only the wire has its widest blind
spot precisely where it can least afford one.
.NH 2
When the oracle is wrong
.PP
Three of the nine faults were in the implementation brought in to
check this one.  That is the obvious hazard of using a reference
implementation as an oracle, and it is worth being clear about why it
did not defeat the method.
.PP
A single oracle cannot tell you who is wrong.  When this stack and
BlueZ disagreed, the tie was broken by the other rungs rather than by
preference.  The RFCOMM length is the cleanest case: BlueZ's sender
and BlueZ's own receiver disagree with each other \(em
.CW rfcomm_uih_recv
would reject the frame
.CW bthost_send_rfcomm_data
built \(em so the question was settled inside BlueZ without appeal to
anything here, and Wireshark and the specification agreed.  The
credit-based segmentation case was settled by the capture: the peer
acknowledged an MPS of 188 in a message that is in the file, and then
sent 202 bytes.
.PP
The corollary is that the rungs must stay independent to be worth
anything.  That independence is partial and should be said plainly:
while diagnosing passkey entry, bthost's round logic was read, so for
that one function this is no longer a wholly independent reading of
the specification.  It is recorded in the plan and it is a real
weakening.
.PP
A milder version of the same hazard is that bthost is BlueZ's test
host stack, not the Linux kernel's Bluetooth implementation.  Its
faults are in code exercised less hard than the kernel's, which makes
finding three of them less surprising and less damning than it would
otherwise be.  It is still the right oracle for this purpose, because
it is the half of BlueZ that can be driven from a socket without a
radio.
.NH 2
Two lessons
.PP
The first is about instrumentation.
.CW progexit
in the interpreter printed a reason for a program that broke, but a
program that was killed, or raised a
.CW fail:
string, or simply returned, reached the bottom of that function with
nothing said \(em and if it was the last one,
.CW cleanexit(0)
left by
.CW _exit
without a word.  A killed last program and a finished one were
indistinguishable from outside.  Separately, a real memory fault in
.CW emu
is loud but still exits 0, because
.CW trapmemref
turns it into a Dis exception: so "no crash report, therefore not a
crash" was worthless reasoning, and the exit status settles nothing on
its own.  Both were fixed by making the program say which of the
possible things happened.
.PP
The second is about fixtures, and it cost the most.
.PP
Passkey entry failed against BlueZ at round 1 of 20.  Everything
measurable said both sides computed the same function over the same
input: bthost's own round 1 confirm, recomputed from the capture with
openssl, matched 0x81; this side's matched 0x81; and 0x81 is what bit
1 of the passkey calls for.  On that evidence the code was withdrawn,
on the principle that an unverified pairing method should not ship.
.PP
The principle was right and the diagnosis was wrong.  A context patch
meant to give bthost a passkey with bits in it had applied one of its
two hunks and silently dropped the other, so bthost sent its confirms
with the real passkey and checked this side's against zero.  Every
round whose bit is 0 then agrees by accident, and round 1 is the first
whose bit is 1 \(em exactly the observed shape.  All the evidence was
correct.  The one thing not measured was whether the fixture was what
it claimed to be.
.PP
What settled it was making bthost print what it was comparing, and the
prints never appeared, which is what showed the patch had half
applied.  That should have been the first move rather than the last.
The edits live in a script now, as substitutions with every one
counted afterwards, because a substitution that finds nothing can be
caught and a context patch that half applies cannot.
.PP
With that fixed the twenty rounds run, and the property passkey entry
exists for is visible:
.EX
passkey 703711 (bit 0 wrong):    1 round, then refused
passkey 703708 (bit 1 wrong):    2 rounds, then refused
passkey 703710 (right):         20 rounds, and a bond
.EE
.PP
A test apparatus is code, and it is the code least likely to be
tested.  Every rung of the ladder above was built to check the stack
against something that did not share its author's assumptions; the one
thing left checking itself was the apparatus, and that is where the
day went.
.NH 1
Conclusion
.PP
A Bluetooth stack can be an ordinary program that serves a name space,
and this one is: fifteen libraries and about ten thousand lines of
Limbo, with the kernel carrying HCI packets and nothing more.  The
programs above it \(em a keyboard, an ethernet, a telephone \(em
contain no Bluetooth at all, because there is nothing to contain: they
open files.
.PP
Writing the protocols was not the hard part.  The hard part was
establishing that any of it was right, given that the obvious way to
test a protocol stack is against a model that shares its author's
misreadings.  Four kinds of check, arranged so that each is answerable
by something that did not share that reading, found nine faults: six
here, every one of them something the stack's own bench had been
passing, and three in the implementation brought in to check it, which
were diagnosable as its faults and not this one's only because there
was more than one rung to triangulate from.
.PP
What is here is a stack that agrees with someone else's about every
byte it sends, and about the numbers it computes and does not send.
What is not here is a radio.  The next thing that would find faults
none of this can is a real controller, and the record says so in the
places where it would otherwise be tempting to imply more.
