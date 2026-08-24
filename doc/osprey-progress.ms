.TL
Osprey: what is built, and what is next
.AU
Inferno RIO
.PP
Osprey is described in two places: the plan in
.I osprey-plan (6),
and the author's own presentation of the system, summarised in the first
section of that plan.  This document tracks what each of them asks for
against what the tree does, and names the order the rest is being built
in.  It is kept current as each piece lands.
.NH 1
Built
.PP
.B "The kernel."
An Osprey flavour that builds from its own tree alone, boots over UEFI
and over multiboot, brings up every processor through ACPI, and mounts a
root file system.  See
.I kernel-builds (6).
.PP
.B "Resource containers and the scheduler."
A run queue, a lock and a clock per core; earliest deadline first; a CPU
reservation with best-effort time beyond it, accounted apart, or a strict
reservation that stops the process holding it; bounded memory and network
accounting; a private name table; controlled migration between cores.
A container is billed for the process bound to it, wherever that process
runs.
.PP
.B "Asynchronous requests."
A physical segment a process attaches, carved into a slice per container:
two message rings, a data area, and semaphores.  A process submits and
collects without entering the kernel.  Requests are answered by a service
process the clock wakes, so nothing has to ask for them to be serviced,
and the dispatcher serves file operations against real channels.
.PP
.B "Select."
Waiting on several things at once: message rings and semaphores, arms in
the shared span, turned off in place.  An interrupt gives a semaphore and
wakes the task waiting on it.
.PP
.B "A driver served by a task."
A uart handed to a container: its interrupt gives a semaphore and masks
the device, and a kernel task of the container's does the register work
and lets the device interrupt again.  The task waits on the three things
the presentation gives a driver \- the control messages sent to it, the
semaphore its interrupt gives, and the output queue it takes work from
\- answers the control messages on the reply ring, and writes what it is
given straight out of the device, turning the output arm off in place
while what it last took is still going out.
.PP
.B "The packet path."
An ethernet interface handed to a container: its packets are charged
against the container's network caps and queued for it whole, each giving
a semaphore, without reaching the rest of the network stack.  The
interface takes its receive buffers from the container's own slice, so a
packet is written straight into memory the container has mapped and
reading one is being told where it is.
.PP
.B "The packet path, the other way."
A container that has been given an interface also fills transmit buffers
in its own slice, and
.CW send
names one and a length: the card reads the frame out of the slice and
nothing copies it.  Which buffers may be written is a word of bits in
the map that the kernel keeps, and a semaphore says when one comes back,
so a container with all of them in flight waits in the same
.CW select
as everything else.  The source address is the kernel's to write.
.PP
.B "A protocol stack outside the kernel."
.CW os/osprey/cmd/netsrv.c
answers ARP and ICMP echo for an address the kernel has never heard of,
over those buffers, and a second machine on the wire pings it.  It is
the talk's driver task with all three of its arms and nothing above
icmp: what it demonstrates is that the path is real, not that there is a
usable stack outside the kernel.
.PP
.B "A service outside the kernel."
A container may name another as its server.  Requests the kernel does not
implement are put on the server's ring with the container and sequence
they came from, an ordinary process takes them and answers them through
the same rings and the same select, and the answer is routed home.  The
server forks a process with a descriptor group of its own for each
container it answers for, so what it opens for one is not in another's.
.PP
.B "A container that says when it is waiting."
A container's own process blocking takes it off its core's run queue and
marks it
.CW blocked ,
and waking puts it back, so the scheduler chooses between containers
that can run and
.CW status
says which is which.  Its reservation refills while it waits.
.PP
.B "A name space a container carries."
What a container calls a thing is its own table in the policy layer, is
written into its checkpoint, and is what every
.CW open
is resolved through \- so a container that crosses to another machine
opens what its names name there.
.CW bind
is answered as mechanism, before anything is forwarded, and a
personality's part is only to say what a global name stands for here.
.PP
.B "\[*p]p."
The session protocol: sessions that outlive the connection carrying them,
transactions grouped so that opening a thing, reading it and closing it
is one round trip, reads that name an attribute rather than an offset
into bytes, versions that nobody else sees until the fid that made them
is closed and that are refused if what they were written against has
been committed over, and leases on fids and sessions.  What it names are
containers, whose settings and accounting are their attributes.
.PP
.B "A segment for each container, and pages handed over."
A container's slice is a segment of its own, and so is each page that may
be handed about, and the name of one is a capability: a container's
memory is for the process bound to it and the processes that one started,
and a page is for whichever container holds it.  A container takes a page, writes in it, and hands it to
another, which attaches the same page and finds what was written: the
page is mapped, not copied.
.PP
.B "Delegated authorisation."
A container is for whoever made it, and for whoever they hand it to by
name.  The kernel enforces that at a segment and at a \[*p]p open, and
knows nothing about the names beyond what it is told; the grants are
written into a checkpoint, so they cross to another machine with the
container.
.PP
.B "Migration."
A container carried to another machine over a wire: its checkpoint in an
ethernet frame of its own type, read back into a kernel that had never
heard of it, and destroyed where it came from so that it is in one place
afterwards.
.PP
.B "\[*p]p as its own transport, and isochronous data."
The protocol is spoken on a wire of its own \- ethernet type
.B 0x910A ,
a group in one frame and its replies in the frame back \- as well as
through
.BR #O/pip .
Nothing about the wire is a connection: each group says which session it
belongs to, which is what a session outliving its connection was for.  On
that wire a
.B Tstream
asks for an attribute to keep arriving at a rate rather than to be asked
for, and the frames come at that rate with nothing sent to make them
happen.
.PP
.B "Proving who is asking."
A machine holds a key and signs with it: a
.I ticket
saying a name may have a container until a time, and a checkpoint saying
who a container is for and who it has been handed to.  Two machines with
the same key take each other's word and nobody else's.  Over
.B #O/pip
the kernel already knows whose process is asking; over a wire it knows
nothing, so a session that has not presented a ticket may open only what
is nobody's, and one that has presented a good one asks as the name in
it for the container it names.  A checkpoint that arrives unsigned, or
signed by somebody else, is refused \- which is what makes the grants a
migrated container arrives with worth anything.
.PP
.B "A key agreed rather than typed in twice."
Two machines agree a key over the wire with the published 1024-bit group
\- each picks a number it keeps and sends what the group makes of it \-
so the key itself never crosses.  What that does not say is who was on
the other end, so both machines report the same fingerprint in
.B status
and a person compares them.  A grant taken back now stops a ticket made
under it, at every read, write, close and stream rather than only at the
next open.
.PP
.B "Checkpoint and restart."
Every container as text: what it is, what it is allowed, what it has
used, where it was running, and whatever its rings are holding \- a
message in flight is written out with the container, along with the data
area the buffers it names are in, and put back on the same ring when it
is read.  Reading it is a checkpoint and writing
one back is a restart, into this kernel or another one -- a container
that was running when it was written out is running again when it is read
back.
.PP
.B "What it costs."
The presentation measures a send, a receive and a context switch
together at 270 nanoseconds.  The same thing here \- a request put on a
ring, the container's service process woken and switched to, the answer
put back, and the asking process woken and switched again \- measures
about 59 microseconds, under QEMU with no hardware virtualisation, where
the cycle counter is emulated.  It is not a hardware figure and is not
meant to stand beside the talk's as one; it is what this kernel can be
compared with itself by.  Writing to
.CW #O/bench
is how it is asked.  Through the mapped ring, where no trap is taken at
all, four hundred round trips take about twenty milliseconds \- fifty
microseconds each \- and twenty single round trips against a server that
had gone to sleep each time cost no more than twenty runs that ask for
nothing, so the tick that wakes a sleeping server is not what a request
waits for.  Asking it the first time found that nothing woke a
container's service process when a request was submitted from inside the
kernel, so a round trip waited for the clock: 5.5 milliseconds, ninety
times what it costs now.
.NH 1
What proves it
.PP
.CW scripts/osprey-check.py
boots one kernel,
.CW scripts/osprey-check-wire.py
boots two on one wire, and
.CW scripts/osprey-check-net.py
boots two more and pings a container's own protocol stack from the
second; between them they ask for everything above and say
.B ok
or
.B FAIL
a line at a time.  Seventy-seven lines, all
.BR ok ,
against the kernel this file describes.
.NH 1
Next, in order
.PP
Most of what the plan and the presentation describe that a kernel of
this shape can do is done.  Both halves of the plan's user-level
services sentence are now built and checked: the file-system half in
.CW os/osprey/cmd/p9srv.c
and the protocol stack in
.CW os/osprey/cmd/netsrv.c ,
which is pinged from another machine over buffers nothing copies.  What
is left is a different kernel, and the things below, which neither
source spells out.
.PP
.B "1.  Knowing who agreed the key."
The exchange is with whoever answers.  A person comparing two
fingerprints is the only thing that says it was the machine that was
meant, and there is nothing a machine could compare instead without
something already shared to compare it against.
.NH 1
A personality outside the kernel
.PP
The talk's shape is a microkernel that keeps message passing, address
spaces, interrupts and scheduling, and library operating systems above
it.  Measured against that, almost all of this kernel is on the wrong
side of the line: of the Osprey kernel's sources, the mechanism is
.CW devosprey.c ,
.CW ospreyrt.c
and
.CW policy/ ,
together with proc, the locks, the mmu and segment and page code, the
trap and interrupt paths and the boot code.  Everything else \-
.CW chan.c ,
.CW dev.c ,
.CW pgrp.c ,
.CW sysfile.c ,
every
.CW dev*.c ,
the whole of
.CW ip/ ,
and every driver in
.CW pc/
\- is a personality, and it is about nine tenths of what is linked.
.PP
The first thing that had to change is who is asked first.
.CW dispatch()
answered a request out of the kernel and forwarded only what it refused;
it now answers the three requests the policy layer really owns \-
.CW yield ,
.CW poll
and
.CW alloc
\- and offers everything else to the container's server before
.CW ospreykernop() .
A container that has named a server never reaches the kernel's own
personality at all.  Along with that,
.CW forward()
stopped reporting a full server ring the same way it reports no server:
the first meant the request was answered
.CW retry ,
the second that the kernel answers it, and conflating them had the
personality a container had replaced answering for it whenever its
server was busy.
.PP
.CW os/osprey/cmd/p9srv.c
is the personality.  It is an ordinary user program: it maps its own
container's slice, waits on its request ring with a
.CW get
arm, performs
.CW open ,
.CW read ,
.CW write ,
.CW stat ,
.CW close
and
.CW bind
with the ordinary system calls in its own name space, and puts the
answer back with a
.CW put
arm.  It refuses everything else rather than falling back into the
kernel.  The check boots a kernel, gives one container a server running
in a name space of its own, and has that container open a name that
exists only there; the same name asked for by a container with no
server is answered
.CW error ,
which is what says the answer came from the program and not from the
kernel around it.
.PP
.CW bind
was the one the kernel had no answer for at all, and the first version
of this had the personality answer it by forking a name space.  That was
wrong, and the section
.I "A name space that can migrate"
below says why and what replaced it: naming is mechanism, the container
already had a table for it, and a personality's job is to say what a
name stands for here and not to keep the name.
.PP
Two things about this tree came out of building it, and both are the
same shape as the compiler that could not compile its own kernels.  The
harness booted an iso that had been built by hand without the root
device in its
.CW plan9.ini ,
so the kernel stopped at the bootargs prompt and every check failed at
once, which reads exactly like a broken kernel; the harness now builds
its own.  And
.CW os/osprey/cmd
holds its binaries in the repository, where nothing says whether they
were linked by the toolchain in the tree now: the committed
.CW ring
was half the size of the one this toolchain produces.  All four are
relinked.
.PP
Two things had to be got right for the server to be able to work at all.
A request names its arguments as offsets into the
.I asking
container's data area, so the server must map that container's slice: a
container that delegates to a server now thereby grants it that,
one step and not a chain.  And the server must not believe anything in a
client's map, since a container may write every byte of its own \- so
which slice belongs to which container is asked of
.CW status ,
and the offsets within a slice are taken from the server's own map and
applied to the client.
.PP
This is one personality for the file operations, and the kernel it runs
beside is unchanged.  Nothing has been taken out of the kernel; what is
real is that the path exists and something outside really uses it.
.NH 1
Packets, the other half of the lending
.PP
The plan's user-level services section asks for two things: protocol
stacks and packet processing in user space, and shared packet buffers
with zero-copy paths.
.CW os/osprey/cmd/p9srv.c
did the file half of the first.  This is the buffer half of the second,
on the transmit side; receive was already there.
.PP
A container that has been given an interface now has transmit buffers
of its own in its slice \-
.CW txbuf ,
.CW ntxbuf
and
.CW txbufsize ,
appended to the map so that a program with a shorter copy of it still
reads every field it knows \- and a
.CW send
request names one of them and a length.  Nothing is copied: the Block
that stands for that buffer is queued to the interface and the card
reads the frame out of the container's slice, which is the mirror of
.CW ospreylendbufs
lending it the receive side.  The Block returns to the container's pool
when the card is done, and until then a
.CW send
naming that buffer is answered
.CW retry .
.PP
What is demonstrated is that a container's
.CW send
from its own buffer is accepted \-
.CW "send done 64"
\- and that a second
.CW send
of the same buffer is refused with
.CW retry
while the card still has it.  That the frame arrives at the other end
was settled later, by the stack in user space below: the machine on the
far side of the wire pings the container and gets eight answers back.
.PP
Two things measured on the way, both of which correct what was written
before.  A container claiming an interface and being sent five frames
saw
.CW "direct 0 copied 5" :
the zero-copy receive path did not fire once.  That is consistent with
the code rather than against it \- igbe's receive ring is two hundred
and fifty-six deep and full of the driver's own buffers before the
interface is given away, so a container's buffer is not used until the
card's head comes round again \- but the man page read as though direct
delivery were the ordinary case, and it is not until a ring's worth of
traffic has gone by.  Four hundred pings later it is
.CW "direct 14 copied 396" ,
which is the first time that path has been seen to fire at all \- and
also fourteen frames in four hundred and ten, which is not the ordinary
case.  The reason was a number, not a bug: a container lent the
interface sixteen receive buffers against a ring two hundred and
fifty-six slots deep, and got one back per
.CW recv ,
so no more than sixteen of those slots could hold a container's buffer
at a time.  That number is
.CW *ospreypktbuf
now; set to the ring's own depth it is
.CW "direct 953 copied 257"
over twelve hundred pings, and the copying is the ring's first fill and
nothing after it.  And
.CW ospreymapsizes ,
which
.CW ospreylendbufs
uses, read the container's map without fixing it first; it worked only
because something else had fixed the map earlier.  Both it and the new
.CW ospreytxsizes
call
.CW mapfix
now, which is what every other reader of that map does and why
.CW mapfix
exists.
.NH 1
The stack in user space
.PP
The rest of the plan's sentence, and the piece it was named for.
.CW os/osprey/cmd/netsrv.c
is the talk's driver task with all three of its arms \- its own request
ring, the semaphore a received packet gives, and the semaphore a
transmit buffer gives when the card has finished with it \- and between
them it answers ARP for one address and ICMP echo.  A machine on the
other end of the wire configures an address, runs
.CW ip/ping ,
and is answered by a program the kernel knows nothing about, over
frames nothing copies in either direction.
.PP
Three things the kernel had to grow for it, each the smallest thing
that would do.
.CW Bpool
in
.CW os/osprey/port/portdat.h
gained a
.CW done
hook,
.CW freeb
in
.CW os/osprey/port/allocb.c
calls it after dropping the lock, and
.CW ospreytxdone
in
.CW os/osprey/port/devosprey.c
gives the container the semaphore named as the fifth field of the
.CW ether
control message.  The card's own address is reported as
.CW ea
on the
.CW packets
line of
.CW status ,
because a container that builds an ARP body needs to put its own address
in it and had no way to learn it; and
.CW send
now stamps the source address of every frame from the interface, the way
.CW etheroq
does, so a container may say what it likes about where a frame is going
and nothing about where it came from.  And
.CW txavail
in the map says which transmit buffers may be written, one bit each, set
while that buffer's block is on the free list: finding a buffer is a
load out of memory the container has already mapped.
.PP
That last one replaced a first attempt that counted rather than named.
.I netsrv
kept its own idea of which buffers were free and marked one free
whenever the transmit semaphore fired, which is right about how many
are free and wrong about which; the fifth frame it sent named a buffer
still in flight and was answered
.CW retry ,
and three pings out of eight came back.  The kernel is the one that
knows, so the kernel is the one that says.
.PP
.CW /scripts/osprey-check-net.py
is the check: two kernels on one wire, an interface given to a container
on the first, and
.CW ip/ping
on the second.  Eight requests, eight replies, and four hundred more to
use up the driver's receive ring.  What
.I netsrv
answers is ARP for one address and echo and nothing else \- no routing,
no fragmentation, no UDP, no TCP \- so what it demonstrates is that the
path is real and that the kernel needs to know nothing about it, not
that there is a usable stack outside the kernel.
.NH 1
The same slice at two addresses
.PP
The talk says segments may be shared at different addresses, and every
field in this span is an offset rather than a pointer so that they may.
Nothing had ever attached one twice to find out.
.CW "ring \fIsegment size\fP twice"
does: it attaches the slice a second time, refuses to go on if the
kernel gave it the same address, checks the two are the same memory by
writing a byte through one and reading it through the other, and then
works the ring through the second mapping alone \- the map read there,
the ring heads found from it there, the request put there.  The two come
out sixty thousand bytes apart and the request is answered
.CW "poll done" .
A pointer anywhere in the span would break that and nothing else in the
check would have noticed.
.NH 1
The span as a library
.PP
Three programs had a copy of the map, the ring head, the message, the
arm and the semaphore, and each copy had to be kept in step with the
kernel by hand: appending
.CW txavail
to the map meant appending it to
.CW ring.c
and to
.CW netsrv.c
as well, and a copy that had not been kept up would read the wrong bytes
and say nothing about it.
.CW os/osprey/libosprey9
is the one place now.  It includes the kernel's own declarations rather
than repeating them \-
.CW os/osprey/port/ospreyabi.h ,
which is the map and the arm split out of
.CW os/osprey/port/osprey.h
so that both sides can include it, and
.CW os/osprey/policy
for the message, the ring head and the semaphore \- and installs them
into
.CW Osprey/include/osprey
from those files.  Over that it puts attaching a slice, submitting and
collecting, building arms and waiting on them, the file operations, and
the output and number formatting all three had written for themselves,
since the C library's own print cannot be linked with these.
.CW p9srv.c
went from 687 lines to 497 and
.CW netsrv.c
from 639 to 396.
.PP
It is not a library operating system in the sense the plan means, and
the section below that says so still says so.  A Plan 9 kernel is still
underneath answering what the policy layer does not; this is that
kernel's request ABI made into a library.
.CW ring.c
is deliberately left as it was: it exists to show the ring unmediated,
and would show nothing if it used something else to work it.
.PP
Two defects in the library itself, neither of which any of the sixty
lines would have caught, because nothing called the part of it they were
in.  The names a request points at were put at the head of the data
area, where the arms already were: a program that opened a file and then
waited wrote the name over its own arms, and nothing said so.  The
offsets are worked out from one another now \- the arms, then the
message an arm took or put, then the names, then the buffer \- so that
changing the number of arms moves the rest rather than overlapping them.
And
.CW os/osprey/cmd/mkfile
rebuilt the library when a shared header changed but not the programs,
which would have gone on linking objects compiled against the old
layout: exactly the bug the library was written to remove, moved from
three copies to two stale objects.
.PP
.CW os/osprey/cmd/o9cat.c
is why the first of those is now known to be fixed rather than believed
to be.
.I p9srv
answers with ordinary system calls and
.I netsrv
only ever submits, so between them they never called
.CW o9open
or
.CW o9read ;
o9cat does nothing else, and says whether the arm it built before
opening is still there afterwards.  Put the old offsets back and the
check says
.CW FAIL ,
which is the only thing that makes a check worth having.
.PP
Converting them found one bug that was not there before and one shape
worth keeping.  The bug was mine: the old programs died when a select
was refused and the new ones asked again, so a server whose container
had been destroyed spun instead of stopping, and the round-trip
measurement went from 48 microseconds to 2.4 milliseconds \- the check
that measures it is what noticed.
.CW o9select
now tells a refusal apart from an empty wait, and a refusal is a reason
to stop.  The shape worth keeping is that a server checks a client's
request against
.I its own
map's bounds and never the client's, which is now said in the one place
the bounds are kept rather than in each program.
.NH 1
Portable, and now checked to be
.PP
.CW os/osprey/policy/README
says the layer is kept independent of Proc, Mach, device drivers and
architecture trap code, and the plan says the same in more words.
Nothing checked it.  Everything in the tree builds it with
.CW 6c
against the amd64 headers, where a dependence on a header that exists
only there, or on the width of a type, is invisible.
.CW scripts/osprey-check-portable.sh
builds every policy source with
.CW 8c
against the 386 headers \- thirty-two bit, which is where a layer
written on amd64 usually breaks \- and with
.CW kc
against the riscv64 headers, and the container-side library with
.CW 8c
beside them.  Any output at all is a failure, warnings included.  Both
pass as they stand, which is the answer that was wanted and not the one
that was expected.
.PP
It boots nothing and links nothing: the objects are thrown away, since
there is no Osprey build for either machine and the point is not to make
one.  The policy layer needs only
.CW u.h ,
.CW pool.h
and
.CW fcall.h ,
so the Inferno headers for those machines do.  The library is a smaller
claim than the policy layer and should be read as one: it needs a
.CW libc.h ,
and what it gets is a thirty-two bit
.CW u.h
out of
.CW 9front/386/include
together with the architecture-independent
.CW 9front/include/libc.h .
That catches an assumption about the width of a type, which is what was
wanted, and it is not an Osprey 386 userland, because there is not one.
Inferno has no
.CW libc.h
for any machine, having
.CW lib9.h
instead, which is why the riscv64 column has only the policy layer in
it.  And the whole thing catches what a compiler catches and no more: a
pointer cast to a
.CW ulong
compiles on both, so a check like this is a floor and not a proof.
.NH 1
A name space that can migrate
.PP
Osprey is a microkernel and its containers migrate, and both of those
say the same thing about a name space: it is state a container carries,
so it must live somewhere a checkpoint can reach.  A
.CW Pgrp
is not such a place.  It is a Plan 9 object, it is full of
.CW Chan s,
and nothing could write one into an ethernet frame and read it back on
another machine.  Giving each container a forked
.CW Pgrp
therefore gave it a name space that was real until the moment it
mattered: a container that migrated arrived having lost every name it
had bound, and nothing said so.
.PP
The right place was already there and doing nothing.  The policy layer
has
.CW Ns
in
.CW os/osprey/policy/ns.c
\- a table of local name against global name, one per container, with
.CW nsbind ,
.CW nsunbind
and
.CW nslookup
\- and
.CW snap.c
writes it into a checkpoint as
.CW "name \fIlocal global\fP"
lines and reads it back.  It was written, it was reported in
.CW status ,
it crossed the wire with a container, and
.CW nslookup
was called from nowhere at all.  A container's names migrated perfectly
and meant nothing anywhere.
.PP
So the name a container asks to open is now looked up in that table
first, on both paths: in
.CW ospreykernop
where the kernel's own personality answers, and in
.CW p9srv ,
which reads the container's names out of
.CW status
for the same reason it reads the slice from there rather than believing
a container's map.  A name the table does not hold is left as it stands
and resolved by whoever is answering, which is the buddy operating
system doing what a buddy is for.  And
.CW bind
is answered in
.CW dispatch()
beside
.CW yield ,
.CW poll
and
.CW alloc ,
before anything is forwarded: naming is mechanism.  A container has the
same answer to
.CW bind
whether it has named a server or not, which it did not when the name
space was a thing a personality forked.
.PP
Two things had to be measured rather than assumed.  Reading
.CW status
for every open cost more than the open: with two containers a read is
about a tenth of a millisecond and with twelve about eight tenths,
against a round trip of about fifty microseconds \- so between two and
sixteen times the thing it was for, growing with the number of
containers.  So a server reads a container's names once and keeps them,
and the kernel tells it when they change, on the same ring and by the
same mechanism as
.CW gone ,
because
.CW bind
is answered before anything is forwarded and a server cannot see one.
The check binds a name, reads through it, binds the same name to another
file and reads again; with that message ignored it reads the first file
both times, and two other lines fail as well.
.PP
And a name in this table is at most thirty-one bytes.  That was
decorative while nothing resolved through it and is not any more:
.CW nsbind
copied a name in and cut it short at the limit, so a container binding a
longer one would silently have opened something else.  It refuses now,
and the check binds a name too long and is told so.
.PP
The line that says it worked is on the wire: a container binds a name,
is checkpointed into an ethernet frame, is restarted on a machine that
had never heard of it, and opens what that name names there.  The
.CW RFNAMEG
version could not have had that line at all.
.PP
Two things fell out of it.  A container that has no server now gets
.CW bind
and gets it answered, where before it was refused \- the same mechanism
for everybody, which is what mechanism means.  And what a global name
stands for is genuinely the answering personality's: a container that
binds a local name to
.CW /n/only/proof
opens it through
.I p9srv
and is refused by the kernel's own personality, because
.CW /n/only
is a name
.I p9srv
made in its own process and the kernel never saw.  The check has both
of those, a line each.
.PP
Asking what else a checkpoint dropped found two more, both of them the
microkernel's own and neither a personality's.  The semaphores were not
carried at all: a container's counts, and what had been given and taken,
started again from nothing on the other machine, so a task that was owed
a wakeup lost it.  They are three numbers each and eight of them, and
they go now.  And the data area went only when a ring was not empty, on
the argument that the data was there for a message to name \- but the
area is the container's memory, and a container that had built its
select arms and was waiting on them lost them for no saving at all,
since
.CW snapdata
skips a chunk that is still zero.  Both are checked on one machine and
the semaphore again across the wire, where a container is given one four
times, carried to a kernel that had never heard of it, and found holding
.CW 4/4/0 .
.PP
Making the data area unconditional has a price and it was measured
rather than assumed.  An empty container's checkpoint is 238 bytes; one
that has opened a file and read fifty-five bytes through it is 455; one
whose whole four-kilobyte data area has been written is 9792.  A
checkpoint
.I mig
carries is one ethernet frame, so that last one does not fit \- which
is a second way to reach a limit the document already described, and
until now the only way there was a ring full of messages.  What it costs
is what the container has actually used, since
.CW snapdata
does not write a chunk that is still zero.
.PP
Asking the same question of the policy layer once more \- what is
written that nothing reads, and read that nothing writes \- found two
more.
.CW memrelease
was called from nowhere at all: a container's
.CW alloc
charged its memory and there was no operation of any kind that gave any
back, so
.CW memused
only ever grew and the memory cap could be reached by a container that
was using none of it.  There is a
.CW memfree
control message now, beside the
.CW netfree
that memory's half was missing.  And a frame a container sent was not
charged against its network caps though a packet it received was, which
was true from the moment the transmit path was written and was never the
intent: a send is charged while the card has the buffer and given back
when the card is finished, which is the same rule as the receive side's.
Twelve hundred pings each way is a quarter of a megabyte if nothing is
given back; what the container is left holding is a hundred and
fifty-six bytes, and the check says so.
.PP
Two things about the semaphore work itself, both of the class this
document already names.  The checkpoint's own reader and its writer
reached the semaphores through
.CW map->sem
rather than through
.CW semof ,
which is the accessor that calls
.CW mapfix
first \- a container may write every byte of its own map, and this file
had already had that bug twice; the status printer was doing it too.
All three go through
.CW semof
now.  And a checkpoint written where a container had more semaphores
than this kernel gives one is refused rather than read in part, which
matters because
.CW *ospreysem
is settable and two machines may now disagree.
.PP
A last pass with the same question, this time mechanical: every function
the policy layer defines, against every call site in
.CW os/osprey .
Three were called from nowhere at all.
.CW runtimeblock
and
.CW runtimewake
are the policy layer's own account of a container that is waiting \-
off its core's run queue, marked
.CW ProcessBlocked
\- and nothing called either, so a container asleep in a select stayed
on the run queue and called itself
.CW runnable
however long it waited: the scheduler chose between containers that
could run and containers that could not, the state in
.CW status
was never anything but
.CW runnable ,
and a checkpoint carried that.  A container's own process now blocks and
wakes at each of the four places it sleeps \- a select, a reply, room on
a ring, and the reply wait \- with the wake guarded by the container's
identity as well as its slot, since the sleep drops the lock and the slot
may hold somebody else by the time it returns.  Its period refills while
it waits, because a reservation is time it is owed whether it is running
or not.
.PP
The third,
.CW runtimeservice ,
was a loop over every container that the device had replaced with a
per-container call and its own guards.  It is gone, and so is
.CW ospreyservice ,
which was the adapter's copy of the same idea.  The rule this settled
on: a duplicate mechanism with fewer guards than the real one is a trap
for whoever calls it next and is removed, while a plain accessor nothing
happens to call is not, and stays.
.PP
The same pass over the adapter found the naming rule in two places.
.CW devosprey.c
formed
.CW osprey%d
and
.CW ospreypage%llud
itself when it published the segments, with a comment saying it used the
same rule as the adapter; and a name here is a capability, so two copies
of the rule that decides which container's memory a name reaches is not
a thing to keep by hand.  It is
.CW ospreyslicename
and
.CW ospreypagename
now, in the adapter, and the device and the create path both ask.
.PP
And a check that had been failing about one run in four turned out to be
the check.
.CW "the wire \[*p]p is spoken on given back when it is turned off"
counted kernel processes immediately after asking for them to start and
to stop; a kproc takes a moment to do either.  It waits for the number
now, bounded, so it still fails if the number never arrives \- which is
what it is actually about.  The two new lines beside it were written the
same way rather than with a sleep.
.PP
Asking which control messages no check exercises found eleven, and three
of them looked a container up without asking who was writing where every
other one that names a container asks:
.CW poke ,
which writes into a container's data area;
.CW detach ,
which takes it off its core; and the second argument of
.CW delegate ,
which is the container whose ring the requests will go on and which is
thereby given the right to reach the asking container's slice.  All
three ask now, and
.CW delegate
wants the server to be a container the caller may have.
.PP
And then the check written for them said
.CW ok
for the wrong reason, which is the more useful half of the story.  It ran
the three as
.CW none
and each was refused \- at
.CW open ,
not at the command:
.CW ctl
is mode 0664 and belongs to whoever booted the machine, so another user
cannot write a control message at all.  The holes were latent and not
live, what a grant buys another user is a segment and a
.I \[*p]p
session rather than the control file, and the three fixes are defence in
depth against a
.CW ctl
that is opened up later \- which is not as simple as changing the mode,
since the commands that name no container have nothing to check and
should not be anybody's.  The check lines are gone: they could not reach
the code they were written for, and a line that passes without reaching
it is worse than no line.  The fixes are in and unchecked, and both
documents say so.
.PP
The same run turned up a second way to pass without proving anything.
The harness reads everything between a check's markers, which includes
the commands as they were echoed, so an expected string that appears in
the command itself always matches.  One of the four was doing exactly
that.
.NH 1
The compiler, which was wrong
.PP
Adding one live pointer local to
.CW ospreywrite
made
.CW 6c
stop with a segmentation fault \- no diagnostic, just the signal \-
every time, and taking it away compiled.  The first answer was to say
the function was too big and split its two largest cases out, which
worked; the function is eight hundred and sixty-one lines now instead of
nine hundred and sixty-eight and is better for it.  But "too big for the
compiler" is not a diagnosis, and the compiler was wrong.
.PP
A
.CW Bits
is the compiler's set of variable numbers, and
.CW utils/cc/bits.c
works it in lanes of thirty-two:
.CW blsh
does
.CW b[n/32]
and
.CW 1L<<(n%32) ,
.CW bnum
does
.CW 32*i+bitno ,
and so does every
.CW reg.c .
The number of variables the optimiser will track was
.CW "NVAR = BITS*sizeof(ulong)*8" .
Those are the same number where a
.CW ulong
is thirty-two bits \- which is what it is on Plan 9, where these
compilers come from, whatever the machine \- and twice it where a
.CW ulong
is sixty-four, which is what
.CW lib9.h
makes it on this host.  So
.CW mkvar
would hand out variable numbers from a hundred and sixty to three
hundred and nineteen,
.CW blsh
would write
.CW b[5]
through
.CW b[9]
of a five-word
.CW Bits ,
and the
.CW Bits
is a local: what it wrote over was whatever the caller had on the stack.
The compiler then died later and somewhere else, with a pointer that had
become 1.
.PP
It is one line.
.CW NVAR
is
.CW BITS*BITSPERLANE
now, with
.CW BITSPERLANE
defined beside it and used in
.CW bits.c
so the two cannot drift again, and a function with more variables than
that gets the graceful path the code always had: the excess is not
tracked,
.CW mkvar
says so under
.CW -ww ,
and the function compiles.  Every compiler in the tree shares that
header \- there are nine \- and every one of them had it.
.PP
.CW scripts/cc-check.sh
is the check: a generated function with two hundred variables in it,
compiled by all nine.  Put the old
.CW NVAR
back and
.CW 6c
and
.CW 8c
exit 139.
.PP
The question that follows is whether it had been quietly spoiling
objects all along, and the answer is no, which is worth having asked.
Rebuilding the kernel with
.CW -ww
names every function whose variables the optimiser could not all track:
in the whole Osprey kernel there is one,
.CW ospreywrite ,
with twenty-three of them.  So that function had been compiled by a
compiler writing one word past a
.CW Bits
on its own stack, on every build, for as long as it has been this size.
Building
.CW devosprey.c
through the mkfile with each compiler in turn gives the same object
byte for byte.  That is not luck: a variable numbered past the end gets
a
.CW Bits
with no bit set in the part that is read, which is what the fixed
compiler hands back when it refuses one, so the set the optimiser works
from is the same either way.  What the bug did was corrupt the
compiler's own stack, and what that hit depended on the frame; here it
hit padding until one more local moved things and it hit a live pointer.
Nothing in the tree needs rebuilding on account of it.
.PP
Having the compiler under AddressSanitizer was worth more than the one
bug.  Every compile the Osprey kernel does \- a hundred and twenty-eight
of them, replayed with the real command lines \- is clean under it.  But
the class the bug belongs to is not: these compilers were written where
a
.CW ulong
is thirty-two bits and a name is short, and this tree builds them
somewhere neither is true.  Reading for more of the same found the
lexer.
.CW symb
is the fixed global a token is built in, fifteen hundred bytes of it,
and
.CW macbody
has always clamped its writes into it \-
.CW "if(cp <= symb+NSYMB-4)"
\- while
.CW lex.c
did not, in eleven places.  So an identifier or a constant longer than
that wrote past the end of a global with whatever the source said.  Four
thousand characters of it and
.CW 6c
exited zero and wrote an object; under the sanitizer it is a wild
pointer in
.CW dodecl .
Every write into
.CW symb
goes through
.CW SYMBPUT
now, and a token that reaches the end is truncated and said so, which is
what the macro processor always did.
.PP
.CW scripts/cc-check.sh
asks all nine compilers for all three: a function with two hundred
variables, a four thousand character name, and a four thousand digit
number.  Twenty-seven lines.  Finding it took AddressSanitizer, which is worth saying
because the crash was in
.CW regopt
reading a corrupt free list and the write was in
.CW blsh
two passes earlier; a watchpoint on the corrupted pointer showed only
the compiler's own honest writes to it.
.PP
Environments were the other half of the question and are a shorter
answer: nothing in
.CW os/osprey
opens
.CW #e
or touches an
.CW Egrp
\- not the device, not the adapter, not the policy layer, not either
personality, not the library.
.CW devenv.c
is linked because the kernel still carries a Plan 9 userland to be a
buddy to, and no container reaches it.
.CW pgrp.c
is linked for the same reason and for one more: the service process a
container names with
.CW serve
runs in the name space of whoever asked for it, and that is the name
space a global name is resolved in.  That
.CW Pgrp
is the buddy's, deliberately, and is no longer any container's.
.NH 1
The gaps, by why they are gaps
.PP
Five kinds, and they are not equally hard.  The first cannot be closed
without writing a different kernel; the rest can be closed from here,
and two of them have been since this was written.
.NH 2
Unreachable from a Plan 9 kernel
.PP
The microkernel itself, a library operating system linked into the task
that uses it, and processes that share an address space migrating as a
group.  The measure of it is the file count: the Osprey kernel is 95
portable sources, 121 machine sources and 25 in the ip stack, against
10 in
.CW policy
and one adapter.  Nine tenths of what is linked is a personality
sitting on the wrong side of the line the talk draws.  What can be done
from here \- and is \- is to let a container replace that personality
for itself.
.NH 2
Built and proven since
.PP
Both of these were open and both are closed.  A frame a container built
and handed to the card does arrive at the other end of the wire, because
the other end answers it: eight echo requests, eight replies.  And the
zero-copy receive path does fire, once the driver's two hundred and
fifty-six queued buffers have been used up \-
.CW "direct 14 copied 396"
after four hundred pings, where five frames had given
.CW "direct 0 copied 5" .
Both are checked by
.CW /scripts/osprey-check-net.py ,
which is where the numbers come from.  Fourteen of four hundred and ten
is the path firing and not the path being the ordinary one; what it
depended on was
.CW Npktbuf ,
which is now
.CW *ospreypktbuf
in
.CW plan9.ini ,
and the same check with it set to the ring's depth gives
.CW "direct 953 copied 257" .
.NH 2
Closed since, and once the wrong way
.PP
A container had no name space of its own:
.CW bind
was answered by
.I p9srv
in
.I its
name space, so two containers of one server shared its names, which is
not what a private name space means.  The first answer was to have the
personality fork one per container, with
.CW RFNAMEG
and
.CW RFFDG ,
on the argument that a name space is a personality's to give.  That was
wrong, and the section
.I "A name space that can migrate"
below says how.  What is right about it and stayed is the fork itself:
the server gives each container a descriptor group of its own, so what
it opens for one is not in another's, and the process holding the
request ring hands that process the message down a pipe and takes the
answer back, only the message going through the pipe since what it
points at is in the span both have mapped.
.PP
With that the server holds three things for a container \- a process, a
pipe and a mapping \- and until now it held all three for ever, since
nothing told it a container had gone.
.CW exit
now puts a message on the server's request ring before it takes anything
apart, with the container's identity on it and the operation
.CW gone ,
and there is no reply because what the message says is that there is
nobody left to reply to.
.I p9srv
answers it by closing the pipe, which ends the process and with it
everything open in its name space, and detaching the slice.  It is the
only message that travels the other way along the path a request takes,
and the only one in the list a container cannot ask for.  The check
counts the server's processes before and after and finds one fewer.
.NH 2
Enforced and now shown
.PP
The right a delegating container gives its server over its own memory
was enforced from the start and demonstrated by nothing: every container
in the check is glenda's, so a server reached a client's slice as its
owner would anyway, and the rule was never the reason.  A server of
another user is what the rule is for, and
.CW auth/none
gives one.  Two containers of glenda's, alike in everything except that
one has delegated to a container
.CW none
has been granted: asked for by a
.I ring
running as
.CW none ,
the one that delegated says
.CW "mapped osprey5"
and the one that did not says
.CW "segattach osprey7: permission denied" .
The name of a slice is a capability, and that is the line that says so.
One more thing was on core 0 that had no business being there: every
delegation in the check had both containers on it, so nothing routed a
message between cores, which is the first thing the talk says its
message passing does.  The pair that carries a request to somebody
else's ring and takes the answer back is now
.CW "attach 8 0"
and
.CW "attach 9 3" ,
and
.CW status
is read to show it really is
.CW "proc 8 core 0"
and
.CW "proc 9 core 3" .
.PP
The other half of the rule is shown against the very slice that refusal
names.  A container's memory is also for the process bound to it and the
processes that one started, which is how a container reaches its own
slice before anybody has been named;
.CW bindproc
binds a process of
.CW none 's
to the container that said
.CW "permission denied" ,
and a
.I ring
that process starts says
.CW "mapped osprey7" .
Same user, same container, same segment name: the only difference is
which process is asking, which is the whole of what the rule says.
.PP
Getting there needed one thing that is worth writing down.
.CW auth/none
builds a name space of its own, in which
.CW /tmp
is
.CW none 's
and not glenda's, so the first version failed with
.CW "/tmp/ring: file does not exist"
\- which reads exactly like the refusal being looked for and is not one.
The binary the server runs has to be somewhere both users see, and
.CW none
writes nowhere in glenda's home either, so the two share a directory
made for it.
.NH 2
Demonstration scale
.PP
One of these was measured rather than assumed, and turned out not to
matter.
.CW Npkt ,
the packets a container may hold, is thirty-two, and a flood arriving
faster than a container drains it would be dropped there; under twelve
hundred pings twenty milliseconds apart
.I netsrv
took twelve hundred frames and answered eleven hundred and ninety-eight,
so the queue was not what limited anything.  The rest below are written
down as what they are rather than changed.
.PP
Five of the limits are now read from
.CW plan9.ini
\-
.CW *ospreyqueue ,
.CW *ospreydata ,
.CW *ospreysem ,
.CW *ospreypktbuf
and
.CW *ospreytxbuf
\- because those five do nothing but lay out a slice: everything they
size is in the container's own slice and reached through the map, and
nothing in the adapter or the device indexes an array with them.  A
value below what the tree was built with is refused rather than obeyed,
and so is one that would make the whole arena more than sixty-four
megabytes.  That second ceiling is what makes the refusal worth
anything:
.CW xspanalloc
panics rather than returning nothing, so without it a number too big
would stop the kernel at
.CW devinit
and read as a broken kernel rather than as a line of
.CW plan9.ini
that should not have been written \- which is the third time in this
work that a configuration fault has worn that disguise.
That one of them mattered is measured, not argued: with
.CW *ospreypktbuf
left at sixteen, four hundred pings give
.CW "direct 14 copied 396" ;
set to two hundred and fifty-six, which is igbe's receive ring, twelve
hundred give
.CW "direct 953 copied 257" .
The copying is the ring's first fill and nothing after it.
.PP
The rest are still compile-time constants in
.CW os/osprey/adapter/ospreyrt.c
because each of them sizes an array that is compiled in: sixteen
containers, eight cores, thirty-two packets held, eight private names \-
and a name is at most thirty-one bytes, which used to be decorative and
is not any more, since every
.CW open
a container makes is resolved through that table \- four grants, eight
pages to a container, sixteen arms to a
.CW select .
Making those settable is not a configuration change but an allocation
change, and it is the honest reason they are not.  For a system whose
subject is predictable clouds these are not footnotes; the shape is
right and the numbers are a demonstration's.
.NH 2
Latency
.PP
The talk measures a send, a receive and a context switch together at
270 nanoseconds.  What this kernel measures, through the mapped ring
with no trap taken at all, is 46483, 49889, 46800 and 50551 nanoseconds
on four runs of
.CW #O/bench ,
and four hundred round trips in a hundredth to a fiftieth of a second.
Two orders of magnitude, and structural rather than tuning: a round
trip here wakes a Plan 9 kernel process to answer it.  The talk's
number is a microkernel's, and this is not one.
.NH 2
A class of bug worth naming
.PP
The container may write every byte of its own map, which is why
.CW mapfix
exists and rewrites the whole of it from the kernel's own constants
before it is used.  Of the ten places in
.CW os/osprey/adapter/ospreyrt.c
that read or write through
.CW p->map ,
five call
.CW mapfix
first and five do not.  Three of those five only write.  The two that
read \-
.CW ospreydataoffset
and
.CW ospreydatalen
\- are safe only because their callers happen to call
.CW ospreydata ,
which does fix the map, first.  That is the same accident that let
.CW ospreymapsizes
work for as long as it did and left
.CW ospreytxsizes
failing the moment it was written.
.NH 2
One instance where the plan asks for a choice
.PP
Of the plan's eight sections seven are built and checked.  The eighth is
.I "Architecture adapter" ,
which says the adapter "is selected by
.CW OBJTYPE
and the architecture mkfile", and exactly one exists:
.CW os/osprey/adapter/ospreyrt.c
with
.CW os/osprey/pc
and
.CW os/osprey/pc64
under it.  A thing selected by a variable that has only ever had one
value is not yet shown to be selected by anything.
.PP
The half of that which can be answered without a second machine is
answered above: the layer the adapter binds to the machine compiles for
two others, so what is portable is portable.  The other half wants a
second target, and there are two candidates of very different sizes.
.PP
The near one is 386, and it is nearer than it looks.
.CW os/osprey/pc
is not merely the drivers
.CW pc64
shares: it carries 9front's whole 386 machine layer \-
.CW l.s ,
.CW mem.h ,
.CW dat.h ,
.CW fns.h ,
.CW io.h
and a
.CW pc
configuration \- so nothing of the machine has to be written.  What is
missing is the tree's own cross-build plumbing for that object type: a
.CW mkfiles/mkfile-Osprey-386 ,
an
.CW Osprey/386
with headers and libraries in it, and
.CW os/osprey/pc/mkfile
converted from the native Plan 9 form it was inherited in, which begins
.CW </$objtype/mkfile
and cannot run here at all.
.PP
Every library such a kernel links now builds for 386, which is as far as
it goes without a userland.  Getting there was five repairs, and every
one of them was something that had never been compiled rather than
something that had gone wrong.
.CW Inferno/386/include/u.h
had
.CW uintptr
and neither
.CW intptr
nor
.CW usize ,
so
.CW include/kern.h
did not compile and nothing at all could be built for the object type;
.CW mkfiles/mkfile-Inferno-386
named the host
.CW ar
rather than the tree's
.CW iar ,
so every library stopped at the archive step;
.CW libkern/ainc-386.s
was a copy of the amd64 file, RARG and
.CW XADDL
and all, and
.CW 8a
has no word for
.CW XADDL
\- the 386 had no such instruction until the 486 \- so it is a
.CW CMPXCHGL
loop now;
.CW Osprey/386/include
held the Inferno hosted set, whose
.CW lib9.h
includes
.CW u.h
itself and redefines every floating-point macro; and
.CW os/osprey/kernlib/getcallerpc.s
was amd64 only and named unconditionally, so it is
.CW getcallerpc-amd64.s
with a 386 file beside it and the mkfile picks by
.CW OBJTYPE .
With those,
.CW libmp ,
.CW libsec ,
.CW libfis ,
.CW libkern ,
.CW libosprey ,
.CW libospreykern
and
.CW libaml
all build for 386.
.PP
What stops the kernel itself is not the kernel.  The boot filesystem a
configuration names embeds prebuilt
.CW paqfs
and
.CW factotum
binaries \-
.CW os/osprey/pc64/pc64
names them under
.CW Osprey/amd64/bin
\- and those exist for amd64 only.  A 386 kernel needs a 386 userland to
put in its boot filesystem before it needs anything else, and that is a
9front userland and a
.CW libc
for the object type, which this tree does not have.
.PP
The far one is a machine of another family.
.CW os/inferno
has riscv64 boards \-
.CW virt ,
.CW sifiveu ,
.CW spike
\- and they sit on the Inferno port layer, which is a different set of
sources with different contracts; they will not compose with this one.
Such a target needs what any new 9front machine needs written from
nothing:
.CW l.s ,
.CW mmu.c ,
.CW trap.c ,
.CW main.c ,
a clock and a console, against
.CW os/osprey/port 's
.CW portdat.h .
Both sizes are written down here rather than begun.
.NH 1
Not attempted
.PP
The presentation describes a microkernel with library operating systems
above it.  This is a Plan 9 kernel with an Osprey policy layer inside it,
and the parts of Osprey that are about where code runs rather than what
it does -- the microkernel itself, a library operating system linked
into the task that uses it, processes that share an address space
migrating as a group -- are not reachable from here without writing a
different kernel.  What is built follows the contracts rather than the
structure, and says so.
.PP
The plan's other name for what sits beside a library OS is a
.I buddy
operating system, and that much this does have: what a container asks
for and the policy layer cannot answer is answered by the Plan 9 kernel
around it, or by a user-level server the container has named.  It is a
buddy in the sense of answering for the parts a task has not brought
with it; it is not one in the sense the plan means, since the task did
not bring any of them.
