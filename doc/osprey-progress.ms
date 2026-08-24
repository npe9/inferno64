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
server forks a process with a name space of its own for each container
it answers for, so what one container binds is not what another sees and
not what the server sees.
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
a line at a time.  Sixty-one lines, all
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
is the one the kernel has no answer for at all: a container has no name
space of its own there, only the name table the policy layer keeps, so
.CW ReqBind
is refused and always was.  The personality has one for each container
it answers for, because it is a program and can fork one; a container
that names it can build a name space and then open a name that no name
space on the machine held before it asked, and what it builds there
belongs to it alone.
The check does exactly that, has the container ask the personality for
the shape of the file it opened through that bind and finds the file's
own name in what comes back, and has the same
.CW bind
refused to a container the kernel still answers for.
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
Closed since, in the personality
.PP
A container had no name space of its own:
.CW bind
was answered by
.I p9srv
in
.I its
name space, so two containers of one server shared its names, which is
not what a private name space means.  It has one now, and it is the
personality's to give, not the kernel's \- which is the whole argument
for putting the personality outside in the first place.  The first
request from a container has the server attach that container's slice
and fork a process for it with
.CW RFNAMEG
and
.CW RFFDG ;
the process holding the request ring hands that process the message down
a pipe and takes the answer back, and only the message goes through the
pipe, since what it points at is in the span both have mapped.  The
check has two containers of one server bind different directories over
the same name and read different files through it, and the server's own
name space hold neither.
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
containers, eight cores, thirty-two packets held, eight private names,
four grants, eight pages to a container, sixteen arms to a
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
