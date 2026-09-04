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
.B "Two stacks in two containers, one wire the kernel only routes."
The real Plan 9 IP stack \- devip, ip.c, tcp.c \- runs in each of two
containers, and an osprey interface in each has the ring between them
as its wire: the client end sends a frame as a request and takes the
far end's frames off the replies, the server end queues its frames until
asked.  The two stacks' tcp.c handshake across it and a line crosses
each way.  The frames are the stacks' own; the kernel carries the
messages and knows nothing of what is in them.
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
a line at a time.  Eighty-one lines, all
.BR ok ,
against the kernel this file describes.
.NH 1
Next, in order
.PP
Surveyed again on 2 September 2026 against both sources \- the talk
slide by slide, and the plan section by section \- and against the
tree, not the earlier record of it.  What the sources describe that is
built and checked is in the sections below.  What follows is everything
either source describes, or the built parts imply, that is not built,
in the order it should be done, each with the reason it is a gap.
.PP
.B "1.  Starting a program in a container: exec."
Built, above: the
.B exec
request starts a named program from the caller's server's file system
in a container of its own, and
.B wait
is answered with its status, for an ELF and for a Plan 9 a.out alike.
What remains of the item: the real
.CW p9srv
is not hosted on the microkernel, because it needs more of a Plan 9 ABI
than the buddy answers (item 2 is where that grows); and the talk's
.I "remote invocation"
is this request carried to another machine, which is item 6's wire
work.
.PP
.B "2.  The rest of a legacy ABI."
Built, above, for the Linux binary: file mappings, stdin and stdout
through the buddy's own descriptor table, SIGSEGV to a handler or a
kill.  The Plan 9 side has grown from open/read/close to a real file
lifecycle: the buddy now answers
.CW create ,
.CW fstat
and
.CW remove
as well, and \- the fix that made writing to a file work at all \-
.CW pwrite
to a file descriptor is forwarded to the buddy instead of the kernel's
console writer, which had been swallowing every legacy file write
regardless of its descriptor.  The p9pair check has the legacy a.out
create a file on the log store, write it, read the bytes back through the
buddy, and stat it \- by descriptor and by name both; remove is forwarded and the immutable log store
refuses it, which is the store's semantics, not a gap.  And errstr
crosses now, genuinely: the buddy stashes the real reason a call failed,
per container, and answers the process's
.CW errstr
from it \- so the refused remove leaves the program not a lie but the
store's own
.CW Eperm ,
read back over the buddy like any other result.  And
.CW pipe
is answered: the buddy makes a pipe on its own
.CW #|
and hands back two descriptors, and the program writes one end and reads
its message from the other, both ends held by the buddy.  And a declined
fault now reaches the program as a note instead of stopping the machine:
the per-config
.CW donotify ,
which was a stub that panicked, kills a legacy container cleanly when it
faults \- it registered no handler, so the note is its death, its
container exiting with the fault's own message
.CW ( "sys: trap: fault read addr=0x0" )
\- while a personality process's fault still panics, so a real corruption
stays visible.  The legacy binary reads a bad address on purpose and the
microkernel carries on.  And the name-space calls are answered now:
.CW rfork
with
.CW RFNAMEG
gives a legacy container its own name space \- the buddy keeps a
.CW Pgrp
per container, forked from its own (so it inherits
.CW /n
and the rest), and runs that container's forwarded calls in it, restoring
its own on the way out \- so a
.CW bind
is the container's own and does not change what any other program sees.
The legacy binary rforks a private name space, binds
.CW /n
into
.CW / ,
and reads
.CW /hello
\- which the bind resolves to
.CW /n/hello .
This is the item-6 piece the plan said the name-space calls wait on, done
for the legacy ABI.  And the fuller form of the note is answered too:
.CW notify (2)
registers a handler, and a declined fault is now delivered to it \- the
microkernel's own
.CW notify()
frame builder points the faulting program at its handler with the note
message, so the program catches its own fault instead of being killed.
The legacy binary registers a handler, reads a bad address, and its
handler prints the note
.CW ( "sys: trap: fault read addr=0x0" )
and exits.  And
.CW mount
is answered, the last of the name-space calls: the program opens the
personality's own exportfs
.CW ( #X ,
a 9P connection), mounts it onto
.CW /mnt
in its private name space, and reads
.CW /mnt/n/hello
through the loopback \-
.CW p9mount
attaches the served descriptor with
.CW mntattach
and mounts it with
.CW cmount ,
the same primitives the personality's own boot uses.  The file traps, the
name-space calls and the fault are all answered now; what is left of the
legacy ABI is the
.CW noted (2)
continuation that would let a handler resume the interrupted instruction
rather than exit (a fault cannot exercise it \- the address is still bad -
so it is not built).  The per-container name space is the buddy's; the other half of item 6, a
real user-level
.CW rfork
that forks the process itself, is the kernel's to make, not a program's,
and is now built \- both forms.
A legacy binary that calls
.CW "rfork(RFPROC)"
is forked into a process with a private address space, and
.CW "rfork(RFPROC|RFMEM)"
into a second thread of control over a shared one.
.CW ospreyforkkern
in
.CW devosprey.c
intercepts the call before it reaches the buddy (a container is the
kernel's to make), gives the child a container of its own for identity and
billing delegated to the same server, dups the parent's segments with
.CW dupseg
(text shared, data and bss copied copy-on-write for the plain fork or
shared for
.CW RFMEM ,
the stack always the child's own), and crafts a return frame with
.CW forkchild
so the child pops out of the scheduler in user mode at the parent's fork
point with the return register zero.
The child sees 0 and runs its own line and exits; the parent sees the
child's container id; the child is recorded beside exec's children so
.CW wait
answers it the same way.
The whole text and data image is faulted in on the parent first (through
.CW ospreybuddyfault ,
the buddy pager), because the child's new container is one the buddy laid
no image for and could not page; a data segment the buddy pages has no
.CW Image ,
so for the copy it is dupped as anonymous memory
.CW ( SG_BSS ),
its pages all resident from the prefault.
The child inherits the parent's open files: the kernel asks the buddy, at
the fork, to clone the parent container's descriptor table into the
child's
.CW ( Bforkfds
in
.CW devosprey.c ,
.CW FORKFDS
in
.CW p9buddy.c ),
dup'ing each real descriptor with
.CW p9dup
so each side holds its own and closes its own on exit, and copying the
console sentinels as they are.
The same request shares the parent's name space: a fork without RFNAMEG
inherits it, so if the parent rforked a private one the child holds the
same
.CW Pgrp
(incref'd, each container closing its own reference), and otherwise both
use the buddy's shared name space.
The test proves both: the parent opens a file and, in the private name
space it rforked and bound, forks; the child reads the file back through
the inherited descriptor and opens
.CW /hello ,
a name that exists only through the parent's bind.
And the parent reaps it: the fork's other end is
.CW await (2),
which the kernel answers - it made the child and knows when it exits - so
the parent's
.CW wait
blocks in a bounded kernel sleep until a child of its container is done,
then reads back the child's pid and exit status
.CW ( ospreylegacyawait
in
.CW devosprey.c ,
intercepting
.CW AWAIT
the way the fork intercepts
.CW rfork ).
So item 6 is whole \- both fork forms, the child a full copy of the
parent (its address space, its control flow, its open files and its name
space), and the parent waiting on it to exit.
(The boot-time
.CW "unimplemented syscall 14"
that printed twice from the server personality during the IP bring-up
is pinned and gone: the host libc's
.CW fastticks
calls
.CW nsec ,
which opens
.CW /dev/bintime
\- an
.CW open
trap the microkernel does not answer \- and
.CW il.c 's
.CW inittimescale
called it once per stack attached.  The symbol cannot be overridden,
the libc member being pulled in for
.CW nsec ,
so it is renamed the way
.CW sleep
was: the kernel-side sources are compiled
.CW -Dfastticks=kfastticks
and the personality's
.CW kfastticks
.CW ( os/osprey/cmd/p9/p9sched.c )
is the cooperative clock's tick count at 100 Hz.  That print was what
had been failing the last criterion of the p9buddy and p9linux checks;
both pass whole now.)
(A separate, pre-existing intermittent flake: the group-reservation and
.CW dumptask
status-line criteria fail on some boots \- their signature is a status
line printed a beat late, the fork and note criteria pass on the same
boots \- so they are timing, not a regression, and a re-run passes 34/34.)
.PP
.B "3.  Storage: a block device served by a task, then a file system."
The plan's user-level services section says file-system policy means two
device classes \- eMMC and SD as a block device, and raw NOR or NAND
flash \- and its storage section says which to build first: the block
path, then a log-structured service for raw flash whose reclamation is
an ordinary scheduled task with a reservation the service sets at start
through the request ABI.  All of that is built, above: the block device
driven from user space, the log-structured store on it, and its
reclamation as a task on the clock tick under a reservation the task
set by request, the log bounded rather than unbounded.  Create and remove
over 9P are answered now too: the exportfs
.CW ( p9srv.c )
creates a file the client names on the ring and removes it, and because
the store is mounted at
.CW /n
it creates by the fid's own path through
.CW namec ,
which follows the mount the way the server's own create does \- a
fid-relative create would land on the read-only device beneath the mount.
The client makes
.CW /n/clientmade
on the server over 9P, writes it, reads the bytes back, and its remove is
refused by the immutable store, the
.CW Eperm
crossing the ring.  What is left is the raw-flash tier itself, the same
store on a device whose erase and bad blocks are the store's problem \- a
board this tree has no Osprey target for yet (item 9).
.PP
.B "4.  \[*p]p for files, and \[*p]p devices."
Built, above, both halves: \[*p]p about the server personality's files
\- immutable versions committed on close, leases, a grouped
open-read-write-close in one round trip, over the ring \- and the uart a
container holds as a \[*p]p thing with the talk's attributes, its data
attribute answered by the driver task.  What remains is the
personality's \[*p]p on a wire of its own, and the attributes a uart
here does not have.  For the record, the talk's uart (slide 20) is
reached as a \[*p]p file with string attributes \-
.CW *
listing them,
.CW b
the baud rate,
.CW d
the data \- answered by the driver task; here the driver task takes
open, close and an output queue.  Serving the personality's files and
the uart task over \[*p]p is the piece; "\[*p]p devices in the kernel"
was the talk's own status line.
.PP
.B "5.  The second cut: console and clock as tasks."
The talk's kernel keeps interrupt handling and nothing of the device.
The uart is done, above: a uart task in a container of its own on the
microkernel, given work by another container over its output queue, its
bytes leaving on the wire.  The console is done too: every kernel
.CW print
goes through the console task now \-
.CW putstrn0
offers the line to
.CW consoletask
first and writes the port itself only when the task cannot, a panic or a
full queue \- so a container holds the console and the kernel's own output
is that container's to carry.  And the clock: the CMOS real-time clock is
read in user space now, the exokernel way, the personality's own
.CW outb / inb
on ports 0x70 and 0x71 under a port grant, reading the date and time with
no kernel rtc device in the data path (it reads the six registers twice
and takes them when the seconds match, the update-in-progress guard
without the long spin that would be a CPL3 window for the standing pc64
interrupt fault).  What is left is that the kernel still reads the clock
once itself at boot, before any task exists, to set the time of day \- the
bootstrap a task cannot do \- and retiring pc64 as the testbed, the
measure the plan sets.
.PP
.B "6.  Address-space groups, and a checkpoint that carries everything."
Slide 15: processes that share an address space migrate as a group.
The blocker here is two things, not one, and it is worth stating them
apart.  For the group as a scheduling unit, the scheduler is already
ready: it bills whichever process runs to that process's container
through the
.CW osprey
back-pointer every process carries, and enqueues each task under the
container's one reservation, so several processes sharing a container's
address space already run under one budget the moment there are several.
Making a second one is now built two ways: the kernel makes a group (a
second
.CW kproc
bound to a container and handed its slice), and \- since
.CW ospreyforkkern
gave the microkernel a user-level
.CW rfork
even though
.CW sysproc.c
is cut \- a program forks one itself, with
.CW "rfork(RFPROC|RFMEM)"
sharing the address space (a thread) or
.CW "rfork(RFPROC)"
copying it, the child a full copy down to its open files (item 2's fork
paragraph has the detail).  What is still true is that a container has one
select rendezvous and one arm area, so at most one of a group may select;
the double sleep that the uart task hit is what two selecting members
would be.
.PP
For migration, the blocker is different again: migration here is
checkpoint-and-restart, not resume \- the container comes back having to
open what it had open again, no register or stack state crosses \- so
there is no running group to carry across a wire, only the container's
state, which already crosses.  Resuming a running process, not just its
container's state, is the piece that would make slide 15's
.I migration
real, and it is not begun.
.PP
The group-scheduling half is built.  A container
.CW ( Groupid ,
made in the p9pair boot) holds not one process but two, both kernel
processes bound to it, both sharing its arena slice, both running under
its one reservation
.CW ( ospreygroupdemo
in
.CW os/osprey/port/devosprey.c ).
The scheduler needed nothing new for it: it bills whichever of them runs
to the container through the
.CW osprey
back-pointer, so the two accrue against one budget, which the status
line shows \- one container, its
.CW used
climbing, and both processes' pids on it, the second after
.CW group .
They are a group because they share the address space: the first writes
a byte into the slice and the second reads it, which the boot prints.
Only one process of a container may work its ring or select \- there is
one arm area, and two selecting members are the double sleep the uart
task hit \- so the group's members share the address space and the
budget and leave the ring to the one that has it.  A member pid list was
added to the container's status line
.CW ( ospreygroupjoin
in the adapter); it is not put in the checkpoint, so nothing there is
signed differently.  What stays open, as above, is resume: the group
is scheduled as one, but a checkpoint carries the container's state, not
the group's running registers, so there is not yet a running group to
carry to another machine.
.PP
.B "6a.  Resume, and a checkpoint that carries everything."
The group above is scheduled as one; what is not built is carrying a
.I running
group across a wire.  Migration here is checkpoint-and-restart, and a
checkpoint carries the container's rings, data area, semaphores, names
and grants, not a process's registers or stack, nor its packets, its
pages or its kernel channels, nor a checkpoint larger than one ethernet
frame.  Resuming a process rather than restarting it is the piece, and
it is the deepest one left.
.PP
.B "7.  The stack in user space, beyond a demonstration."
netsrv answers ARP for one address and echo, and now, when it is given a
rule, drops echo from a blocked source and counts it \- the talk's
packet filter, run in user space over the frames the card put in the
container's own slice
.CW ( blocked
in
.CW os/osprey/cmd/netsrv.c ).
The net check shows it: netsrv told to block the peer's address drops
the peer's pings, which get nothing back, while the runs with no rule
answer all eight; checked by
.CW /scripts/osprey-check-net.py .
The talk names routing, gateways and firewalls as what the system is
for, and a drop-by-rule filter is the firewall's own primitive.  The
reach of the stack has grown one transport past ICMP: a UDP datagram to
the stack's echo port is answered with its payload, from it back to the
sender, built and sent on the same zero-copy path
.CW ( answerudp
in
.CW os/osprey/cmd/netsrv.c ).
The net check dials it from the peer with
.CW con
over
.CW udp!10.9.0.1!7
and the stack echoes the datagram, which it prints; checked by
.CW /scripts/osprey-check-net.py .
TCP is answered too, which is a state machine rather than a datagram:
one connection at a time to the echo port, the three-way handshake
answered, data acknowledged and sent back, the close answered, with
real sequence and acknowledgement numbers and a checksum over the
pseudo-header, so 9front's own TCP on the other end talks to it
.CW ( answertcp
in
.CW os/osprey/cmd/netsrv.c ).
The net check dials it with
.CW con
over
.CW tcp!10.9.0.1!7 ,
and the line the peer sends comes back to the peer over the connection.
There is no retransmit and the window is a fixed one, so it is a
minimal TCP, not a whole one; what is left of item 7 is that reach and
the routing and gateways a firewall does beyond dropping.
.PP
.B "7a.  The real Plan 9 stack in user space, not a hand-written responder."
netsrv answers ARP, ICMP, UDP and a minimal TCP by parsing and building
frames itself; it talks to 9front's real TCP on the other end, but its
own side is a demonstration, not a stack, and the plan says so of it.
The architecture wants the actual Plan 9 IP stack \- \f(CWdevip\fP and
the \f(CW/net\fP tree with \f(CWtcp.c\fP's state machine \- run as a
user-space service over the exposed interface, the way the p9
personality already runs the kernel's upper half as a library.  That is
the honest form of item 7 and is filed apart here because it is a port,
not a responder.
.PP
It is feasible, and measured to be: compiled against the p9 personality's
shim, twenty-three of the twenty-five files in
.CW os/osprey/ip
\- including
.CW tcp.c ,
.CW udp.c ,
.CW ip.c ,
.CW ipifc.c ,
.CW arp.c ,
.CW icmp.c
and the media \- compile with only a small shim added: a complete
.CW Mach
carrying a
.CW ticks
field with
.CW MACHP
and
.CW HZ
(the stack's
.CW NOW
is
.CW TK2MS(MACHP(0)->ticks) ),
.CW MIN ,
.CW NUMSIZE
and
.CW READSTR ,
and externs for
.CW cpuserver
and a
.CW conf
with
.CW npage
(devip's
.CW scalednconv
alone wants them).
.CW netif.c
additionally wants
.CW coherence .
The two that do not compile are
.CW esp.c ,
which is IPsec and wants libsec crypto constants and can be dropped, and
.CW devip.c ,
which is only the two
.CW conf
symbols above.  The staged plan from here: (1) put those shim additions
in the personality and a kproc that advances
.CW ticks
as a coarse millisecond clock; (2) link the stack into the personality's
.CW p9lib
and resolve the runtime symbols the link names (the Fs allocation,
.CW ipmux ,
netif); (3) write an osprey medium modelled on
.CW netdevmedium.c
or
.CW pktmedium.c
whose reader kproc takes a frame from the exposed interface with
.CW ReqRecv
and injects it, and whose output copies a frame into a transmit buffer
and sends it with
.CW ReqSend ,
bridging the two header worlds the way
.CW p9srv_serve
does; (4) bring the stack up (ipinit, add the medium, bind an ipifc,
configure an address) and export
.CW /net ;
(5) a wire check where 9front's own TCP connects to
.CW /net/tcp
on the stack and its state machine, not a hand-written echo, answers.
.PP
The link gap for stage (2) is now enumerated, measured by adding the
stack to
.CW os/osprey/cmd/p9/build.sh
and reading what
.CW 6l
could not resolve.  The compile needs, beyond the shim above,
.CW npage
added to the shim
.CW dat.h 's
.CW Conf
(devip's
.CW scalednconv )
and a
.CW coherence
prototype; then the link wants a set of kernel-infrastructure functions
the shim does not yet carry \-
.CW xalloc
(add
.CW os/osprey/port/xalloc.c ),
.CW parsecmd ,
.CW cmderror ,
.CW lookupcmd
(add
.CW os/osprey/port/parse.c ),
.CW readnum ,
.CW emptystr ,
.CW return0 ,
.CW commonuser ,
.CW commonerror ,
.CW ptclbsum ,
.CW IPv4allsys
\- and a few ip helpers
.CW ( v4parseip ,
.CW isv4 ,
.CW v4tov6 ,
.CW v6tov4 ,
.CW defmask ,
.CW maskip ,
.CW parseip ,
.CW parseipmask )
that live in ip files or the plan9 ipaux the personality has not linked.
Most are one file or one small stub each; the shape is an
infrastructure-assembly pass, not a rewrite, and it is what stage (2)
is.  A single-machine first milestone that needs no exposed-interface
medium: bring the stack up on
.CW loopbackmedium.c
and have 9front-free, in-personality TCP over
.CW 127.0.0.1
be handled by the real
.CW tcp.c ,
which proves the stack runs before the osprey medium of stage (3) is
written.
.PP
Stage (2) is done: the real stack compiles and links into the personality.
.CW os/osprey/ip
\- ip.c, tcp.c, udp.c, ipifc.c, arp.c, icmp.c, devip.c, the media \- and
.CW os/osprey/port/netif.c
are built by
.CW os/osprey/cmd/p9/build.sh
against the shim, with the ip address helpers from
.CW os/osprey/kernlib
.CW ( parseip.c ,
.CW ptclbsum.c ,
.CW ipaux.c ,
.CW classmask.c ,
.CW eipfmt.c ,
compiled with the portable
.CW ip.h ,
not the kernel one) and
.CW os/osprey/ip/inferno.c 's
glue.  The shim gained a complete
.CW Mach
with
.CW ticks ,
.CW HZ ,
.CW MIN ,
.CW NUMSIZE / READSTR ,
.CW npage
on
.CW Conf ,
and host-backed
.CW xalloc ,
.CW readnum ,
.CW emptystr ,
.CW return0 ;
.CW os/osprey/cmd/p9/p9ip.c
carries
.CW ipprotoinit
(tcp, udp, il, ipifc, icmp, gre, ...).  The stack links dead \- not in
the personality's
.CW devtab ,
not called \- so every personality configuration builds and checks
unchanged (p9pair 24, p964 17, p9buddy 5, p9linux 12).
.PP
Stage (4), bring-up, now runs.
.CW ipdevtab
is in the personality
.CW devtab
and
.CW p9ipup
is called after
.CW p9setup .
It registers the loopback medium, mounts
.CW #I
at
.CW /net ,
binds loopback and gives it 127.0.0.1, and reads the real interface
status back \- the boot log prints
.CW "device loopback0 maxtu 65536 ... ttl 255 ... delay 40" ,
which is
.CW ipifc.c
formatting its own state.  The earlier
.CW donotify
panic was a stale
.CW p9prog.i :
the personality library is generated by
.CW build.sh ,
and the
.CW p9prog.i
mkfile rule did not list
.CW p9ip.c ,
so editing the bring-up left the old library embedded; adding
.CW p9ip.c
to the rule fixed it.  A divide-by-zero in
.CW il.c 's
.CW inittimescale
(the shim's
.CW fastticks
returns hz 0) is guarded.
.PP
On top of the live stack
.CW p9ipup
now drives
.CW tcp.c
directly: it announces
.CW tcp!*!7777 ,
opens a second conversation, and writes
.CW "connect 127.0.0.1!7777" .
The real
.CW tcp.c
state machine runs and emits a SYN \- the connection reads back
.CW "Syn_sent ... cwin 1460 ..." ,
tcp.c's own status line.  This is the decisive point: the user-space
process is running the actual Plan 9
.CW devip / tcp.c / udp.c ,
not a hand-written responder.  And the handshake now completes: the
connection reads back
.CW "Established ... swin 1048560>>4 ... qscale 4" \-
the real tcp.c three-way handshake, window scaling and all, done over
loopback in a user-space process.  Then a data round-trip: the accepted
side reads back the 42 bytes the connecting side wrote,
.CW "hello from osprey over the real plan 9 tcp" \-
the real tcp.c segmenting, delivering and reassembling a payload through
qio, not just exchanging control segments.
.PP
Completing it needed the looped SYN delivered back into the stack, and
that needed the one thing the shim never had: a scheduler.  The stock
.CW loopbackmedium.c
queues each packet and injects it from a separate
.CW loopbackread
kproc, so with
.CW kproc
a no-op that reader never ran.  The personality now has the classic
Plan 9 cooperative scheduler,
.CW os/osprey/cmd/p9/p9sched.c
with the
.CW setlabel / gotolabel
switch in
.CW xcall.s :
each kproc is a
.CW Proc
with its own stack and a saved
.CW Label ,
.CW sched
puts a running caller back on the run queue and resumes the next,
.CW sleep
blocks on a
.CW Rendez
until
.CW wakeup
readies it, and both re-check the condition.  No preemption is needed \-
the personality yields only where the real kernel does, at
.CW sleep .
.PP
The one sharp obstacle was the link.  The personality links the host
.CW libc.a ,
whose
.CW sleep(int)
owns the symbol
.CW sleep ,
so the kernel
.CW "sleep(Rendez*, int(*)(void*), void*)"
that
.CW qio.c 's
blocking reader calls could not be defined without a collision \- the
same wall that stopped overriding
.CW fastticks .
The fix is a per-file rename: the kernel-side sources are compiled
.CW -Dsleep=ksleep
(the ring transport, on the host headers, is not), so the stack calls
.CW ksleep
while the transport keeps libc's
.CW sleep .
.PP
With that in place the stock kproc-driven
.CW loopbackmedium.c
runs unchanged: the connecting side blocks in
.CW sleep
on
.CW c->cr ,
.CW sched
switches to
.CW loopbackread ,
which
.CW qbread s
the looped SYN and injects it, the handshake runs to
.CW Established
and
.CW wakeup
resumes the connector - the same
.CW "Established ... qscale 4"
and the same 42-byte data round-trip as before, now over the real
asynchronous medium, and stable across repeated boots.  The interim
synchronous loopback is removed;
.CW ip.c ,
.CW tcp.c ,
.CW ipifc.c
and
.CW loopbackmedium.c
are all the stock sources, untouched.  Every other configuration builds
unchanged.
.PP
UDP works too, over the same real loopback and scheduler.  An announced
udp conversation in the default (no-headers) mode does not receive on
itself: when a datagram arrives,
.CW udpiput
spawns a new conversation per peer with
.CW Fsnewcall
and queues it on the announcing conversation's listen file, exactly as
tcp does.  So the receiver announces, accepts through
.CW listen ,
and reads the datagram from the accepted conversation - and it comes back
whole,
.CW "a udp datagram through the real plan 9 udp.c" ,
44 bytes carried by the real
.CW udp.c
over loopback, the blocking listen and read both served by the
cooperative scheduler.  (An earlier reading of this as a scheduler
deadlock was a mistake in the test, which read the announce conversation's
own data directly and so waited for a datagram that had gone to a spawned
conversation; the scheduler was never at fault.)  Both transports run
5-of-5 across repeated boots.
.PP
Two things loopback hid, that the next medium needs, are now in.  First,
.CW tsleep
had no clock: the protocol timer kprocs
.CW ( arp 's
.CW rxmitproc ,
.CW tcp 's
.CW tcpack )
parked for good, harmless only because loopback delivery is instant and
lossless - a wire needs them for retransmission and address resolution.
The osprey clock tick, which the server loop already takes off the
device's semaphore every 10ms, now drives
.CW sched_tick ,
which readies any proc whose
.CW tsleep
deadline has passed;
.CW tsleep
is timed against it.  A proof kproc that sleeps 100ms and prints wakes
five times on schedule, and the timer kprocs cycle instead of pinning at
.CW state=3 .
Second, the server loop calls
.CW runkprocs
on each tick, which runs every ready kproc and hands the processor back;
because the loop's proc is requeued while it yields, an all-asleep moment
is no longer the deadlock panic it was on loopback but an ordinary idle -
the loop returns to its
.CW oselect
and waits there for the next tick, request, or packet.
.PP
The osprey-interface medium is now in, in its first form.
.CW os/osprey/ip/ospreymedium.c
is a medium whose inbound is not a kproc blocking in the kernel - a kproc
can only block in the cooperative scheduler - but
.CW ospreymediumpump ,
which the server loop calls each tick and which injects, in the loop's own
context, whatever frames have arrived.  A second interface is bound on it
at 10.0.0.1, and a kproc
.CW ( ostcp ,
which lives through the server loop where the pump runs) announces a port
and connects to 10.0.0.1: the route sends the SYN out the osprey
interface through
.CW ospreybwrite ,
the loop's pump carries it back in, and the real
.CW tcp.c
handshake completes -
.CW "Established ... qscale 4" ,
with the osprey interface's own counters moved to
.CW "pktin 5 pktout 5" ,
so the segments really did leave and re-enter through the medium, not
through loopback.  Four of four boots carry loopback TCP, loopback UDP and
this osprey-medium handshake together.  Making a kproc able to do this
needed one fix: a kproc that runs
.CW namec
and the fd layer must have its own
.CW errstr / syserrstr
buffers, since
.CW error
writes there and the server proc's are a single static pair.
.PP
The first form looped a frame back to the same stack.  The two-endpoint
form is now in, and it needed no second machine and no change to the
osprey device: devip keeps an independent
.CW Fs
per attach spec
.CW ( ipfs[dev] ),
so a second whole stack lives in the same personality, reached as
.CW #I1 .
An osprey interface is bound on each - 10.0.0.1 on the first, 10.0.0.2 on
the second - and binding the second pairs the two into one wire, so a
frame
.CW bwrite
sends out one arrives on the other's inbound queue, drained into that
stack by the loop's pump.  A kproc then announces a port on the second
stack and connects to 10.0.0.2 from the first: the SYN leaves the first
stack's interface, the pump carries it to the second, and the two stacks'
.CW tcp.c
complete a handshake between them -
.CW "Established ... swin 65535>>4 rwin 1048560>>4" ,
the two windows different because these are two independent stacks, not
one loopback.  Stack B then accepts the flow through its listen file as a
new conversation, so both ends agree the connection is up.
.PP
That two-stack form (two
.CW Fs )
is what proved the two endpoints, and with the arena bug fixed it runs
end to end: two independent stacks handshake and accept over the osprey
wire, and a byte stream crosses between them - stack A writes a line on its
connection and stack B reads it back off the accepted conversation, the
94-byte data segment leaving A's interface and the pump injecting it into
B.  Two small fixes past the handshake got the data across: the listen fd
is the accepted connection's ctl, so it is kept open to hold the
conversation up (closing it left B in Finwait1, dropping the data while A
retransmitted), and the reader polls while the pump carries the segment.
This is the second-machine wire test, run between two stacks in one address
space, handshake and data both.  What follows was the reasoning from while
the arena bug still forced it back to a single stack.  Two whole stacks in one address space trip the shared-state
corruption below over time - in steady state, tens of ticks in, a proc
faults and the note path panics
.CW donotify \-
so the boot ran on a demonstration that carried a known crash.  Until that
corruption is pinned, the boot's osprey-medium demonstration is the stable
single-stack self-loop (connect to the interface's own address, one
.CW Fs ),
which reaches
.CW Established
with the interface counters moved and idles clean, five boots of five; the
two-stack handshake stays proved here in the record, run by hand, not at
every boot.
.PP
The corruption itself is now sharply narrowed, though not yet caught.  A
first help was making the trap handler's user-fault line synchronous
.CW ( iprint ,
not the async console that had been dropping it), so the fault reads the
same every boot:
.CW "pc=0xffffffff addr=0xffffffff" ,
a jump to a bad address - a call through a corrupted function pointer, or
a smashed return.  It is the two
.CW Fs
themselves, not the medium: a second stack bound with plain loopback
crashes the same way as one bound with the osprey medium, so the osprey
work is not the cause.  It is not the scheduler's own
.CW Proc
labels (a guard on
.CW sched.pc
before every
.CW gotolabel
never fires) nor a kproc overrunning its stack (a canary at each kproc
stack's low end is never touched), and it is not the multicast timer (the
one global function pointer in the interface layer,
.CW multicastreportfn ,
is guarded, and dropping igmp entirely does not change it).  What is left
is shared file-scope state in
.CW devip
or a protocol that a second
.CW Fs
overwrites in steady state - the Plan 9 stack was written for one
.CW Fs
per kernel.  The value itself is a clue.
.CW 0xffffffff
is
.CW 0x00000000ffffffff \-
exactly what a 32-bit write of
.CW -1
leaves when it clobbers the low half of a 64-bit return address whose
high half was already zero, which every code address here is.  On this
toolchain
.CW long
is 32 bits, so that is a
.CW long -sized
store overrunning a stack buffer onto a return address a few frames up -
which is why the low-end kproc canary does not catch it (the smash is mid
stack), and why it takes a second
.CW Fs
of churn to reach.  Dumping the faulting stack sharpens it further: in the sixty-four words
above the stack pointer there is not one address that lands in the
personality's text - the frame is zeroed.  So it is not a single stray
.CW -1
store but a zeroing overrun - a
.CW memset
or a block copy past its bound - that wiped the return frame and left the
return address as the low
.CW -1 .
Bisecting the protocol list narrows it a great deal further.  With a
second
.CW Fs
and only tcp and the interface layer, the boot is clean; the crash needs
.CW icmp
present, and with it
.CW udp
and one of
.CW il / rudp .
Any of those alone with
.CW icmp
is clean;
.CW icmp
with all of them crashes.  That pattern - a fixed culprit that only turns
fatal once enough other protocols share the heap - is the layout
sensitivity again, and it places the write in the one path those protocols
share through
.CW icmp :
an ICMP error is received, and
.CW icmpiput
calls the embedded protocol's
.CW advise
\- tcp's, udp's - which runs the address-translation code
.CW ( transbackward ,
.CW icmpproxyadvice )
that rewrites the quoted packet in place.  Each of those functions reads
bounded, so the overrun is small and its landing depends on the heap, but
the path is now a dozen functions, not the whole stack.
.PP
Resolved.  The write was never in those functions at all: the personality's
.CW malloc
is a bump arena that never reuses (fresh memory stays the zero the BSS
started as, which
.CW newpgrp
relies on), so with nothing freed the arena must hold every allocation the
whole run ever makes.  One stack fits in the old 1MB; two, with a Block per
packet they exchange and never free, do not.  The arena filled - "malloc
arena exhausted, 1048352 of 1048576 used" - malloc returned nil, and the
stack's use of that nil smashed the return address to
.CW 0xffffffff .
Every earlier clue fits: two Fs doubled the allocations, the icmp+udp+il/rudp
combination was just enough more to cross 1MB, the steady-state timing was
the arena filling as Blocks piled up, and the layout sensitivity was which
allocation crossed the line.  The fix has two parts.  A one-time "arena exhausted" print makes the
failure legible instead of a wild fault.  And the churn itself is
reclaimed: Blocks, one per packet, are the only unbounded allocation -
everything else the personality allocates is persistent and small - so
.CW freeb
now returns a Block to a free list and
.CW allocb
reuses one (re-zeroed, since it always handed back zeroed memory), keeping
the never-reuse-stays-zero property the other callers rely on because only
Blocks are recycled and only through
.CW allocb .
With the churn reclaimed the arena holds only the persistent structures and
stays flat under traffic, so it sits at a comfortable 4MB.  Two Fs no
longer corrupts.
.PP
This is the wire test the talk's second machine stands for, run between
two stacks in one address space over the osprey medium.  What a real
second machine would change is only the medium's two ends: instead of two
.CW Fs
in one personality sharing a pair of queues,
.CW bwrite
would put the frame on an osprey ring to the peer container and the pump
would drain the ring the peer wrote, learned from a new
.CW oselect
arm - the osprey device carrying the frames it already carries requests
on.  The data stream across the two stacks works now, and it was the same
fault as the corruption above, not a separate one: writing bytes on one
stack and reading them on the other drove the deeper tcp processing
(queueing the bytes, answering with an ack) that allocated the Blocks
that exhausted the arena, so the
.CW "pc=0xffffffff"
was an unchecked nil from the exhausted allocator, and the same arena fix
that stopped two Fs corrupting stopped the data stream faulting.  Stack A
announces on
.CW #I1 ,
stack B connects across the medium, the two
.CW tcp.c
handshake and accept, and a byte stream crosses each way \- fifty-four
bytes one way, forty the other, each read back verbatim, full duplex,
checked in the p9pair boot.
The device-carried two-container form is now begun, in the one direction
the request ring runs.  A frame's bytes put on the ring to the peer
container cross it and are handed to the stack at the far end:
.CW ring9p_frame
in
.CW ring9p.c
stages the frame in the client's data area and sends it as a
.CW Reqframe
request, the server loop answers that op by handing the frame to
.CW ospreymediumreceive
.CW ( ospreymedium.c ),
which hands it to its own osprey interface with
.CW ipiput4
exactly as the pump hands over a locally-queued frame - the same path a
frame from a paired interface takes, so a frame from the peer container is
a frame like any other and the kernel only routed it.  The frame is a real
IP packet: the p9pair boot sends an ICMP echo request from the client
container, addressed to the address the server injects into
.CW ( 10.0.0.2 ),
and the server's stack accepts it and answers with an echo reply, which
.CW ospreybwrite
sees the stack send - the proof the stack at the far end received a real
packet across the ring and acted on it, not merely that the bytes arrived.
The reply is addressed to
.CW 10.0.0.1 ,
which the server's other stack owns, so it terminates there and does not
loop.
The reverse direction rides the same request's reply: the server returns
a frame on the reply and the client sees it come back whole, so a frame
crosses the ring both ways between the two containers - the channel a
symmetric medium needs.  That was the record while the reply still
returned the sender's own frame; it now carries the far stack's.
.PP
Two whole stacks in two containers now run one
.CW tcp.c
conversation over the ring, and the wire is the stacks' own traffic, not
a frame built by hand.  The medium
.CW ( os/osprey/ip/ospreymedium.c )
has a third form beside the looped and the paired ones, chosen at bind:
.CW "bind osprey ring"
makes an interface whose wire is the ring to the peer container, and
.CW "bind osprey ring client"
the other end of it.  The request ring runs one way, so the two ends
differ.  At the client end
.CW bwrite
sends the frame as a
.CW Reqframe
request
.CW ( ring9p_frame
in
.CW os/osprey/cmd/p9/ring9p.c ,
now symmetric: a frame out, and whatever frame the far stack has sent
back on the reply) \- a synchronous send, the whole personality waiting
in the
.CW SLEEP
call that services the ring, which is safe because nothing else in a
cooperative personality can run meanwhile \- and a frame that rides back
is queued for the pump rather than injected inside whatever protocol
path was sending.  At the server end
.CW bwrite
cannot reach the client at all, so it queues the frame until the client
asks: the server loop, answering
.CW Reqframe ,
injects the frame that came (if one did; a request carrying none is a
poll) and returns one of its own stack's from that queue
.CW ( ospreymediumtake ).
The client polls on every clock tick, and so needed a clock of its own:
it takes the tick by the same request a server uses
.CW ( ring9p_taketick ,
an
.CW ospreyxcall )
and waits for it by select on one arm in its data area
.CW ( ring9p_waittick ),
and on each tick polls the ring, advances the cooperative scheduler's
clock and runs its ready kprocs \- the loop the server personality has,
in the client, for as long as its stack is in use
.CW ( p9clientnet
in
.CW os/osprey/cmd/p9/p9ip.c ).
The ring interface's MTU is 1500, so
.CW tcp.c 's
own MSS keeps every segment inside one ring frame; a frame is staged at
one offset of the data area and returned at another.
An empty poll is not counted as a served request by the server loop, so
a hundred polls a second do not spend the run's request count.
.PP
What the boot shows.  The server binds a third osprey interface on stack B,
10.0.1.2, whose wire is the ring, and a kproc announces
.CW tcp!*!9999
on it and blocks in listen.  The client container, after all its other
work, mounts
.CW #I
at
.CW /net
of its own name space \- the same devip, ip.c and tcp.c, now running in
the second container \- binds
.CW "osprey ring client"
at 10.0.1.1, and a kproc connects to 10.0.1.2!9999.  The first frame the
client's stack sends over the ring is the IGMP report it sends on
getting an address (28 bytes), then the SYN (48 bytes, with options); the
server's log shows each arrive and be handed to its stack, the server's
tcp.c answers, its SYN-ACK rides back on the reply to the client's next
request, and the client's connection reads
.CW "Established ... swin 1048560>>4 rwin 1048560>>4 qscale 4" ,
the server's listen returns the accepted conversation, a 57-byte line
the client wrote is read by the server's tcp.c off the accepted
conversation (a 97-byte segment across the ring), and the server's
61-byte answer is read back by the client's.  The client's loop reports
the count: 47 ticks, six frames of its stack's over the ring to the
server, four of the server's stack's back.  Checked by
.CW /scripts/osprey-check-p9pair.py ,
forty-three criteria, five of them this and the gateway below.  What is
honest to keep saying: the
ring wire is between two containers on one machine, not two machines;
the server end's frames wait for the client to ask, so its latency is a
tick unless the client is sending; and the wire has no flow control
beyond the queue the server end holds, which drops when full and counts
the drop.  Making it run to the end also removed the server loop's
four-hundred-request cap, a headless-run guard from before the client
had a stack: the rest of the run had spent the count by the time the
client's stack came up, and nobody answered its ring.  The server now
serves until the kernel ends the boot with the boot program's exit.
.PP
And the gateway, which is item 7's "routing and gateways" done by the
real stack rather than by netsrv.  Stack B in the server container has a
wire on each side \- 10.0.0.2 to stack A, 10.0.1.2 to the client
container \- so it is told
.CW "iprouting 1" ,
stack A is given a route to 10.0.1.0/24 through 10.0.0.2, and the client
a route to 10.0.0.0/24 through 10.0.1.2.  Stack A announces
.CW tcp!*!8890 ,
which the client container can reach only if stack B forwards: it has no
wire to stack A at all.  The client's tcp.c connects to 10.0.0.1!8890,
the SYN crosses the ring to stack B, is not for it, and
.CW ip.c 's
forwarding sends it out the paired wire to stack A with the ttl
decremented; the SYN-ACK comes back the same way by stack A's route; the
handshake reads
.CW "Established ... swin 65535>>4 rwin 1048560>>4"
(stack A's window, not B's), stack A's listen accepts a connection from
10.0.1.1, a 44-byte line crosses to it and a 39-byte answer back, and
stack B's own statistics say
.CW "ForwDatagrams: 4"
by the time the answer is written \- the count
.CW ip.c
keeps of what it forwarded.  A router that is a container, its
forwarding the stack's own code in user space; what the firewall would
add to it is the rule, which netsrv has and the real stack does not.
.PP
.B "7b.  A legacy port device driven from user space."
The osprey device gained two primitives that let a personality own a
legacy port device outright, the exokernel way the talk names for the
frame buffer extended to port I/O and interrupts.
.B ReqIoport
delegates a range of I/O ports to the calling process by clearing their
bits in that process's own x86 TSS I/O-permission bitmap, which
.CW mmuswitch
loads on the way in; a
.CW inb
or
.CW outb
to a granted port then runs at CPL3 with no trap and no system call in
the data path \- proven first by a personality reading the i8042 status
port and printing the byte, a status not a fault.
.B ReqKbdnotify
routes the keyboard's IRQ1 to the container as a bare notification: the
kernel's handler gives a semaphore and wakes the driver's
.CW select ,
and does
.I not
read the scancode.  On that, the p9 personality carries a real i8042
keyboard driver
.CW ( p9kbd.c )
in user space above the microkernel: it takes the grant, registers the
notification, and thereafter, woken through the container semaphore's own
.CW oselect
arm, reads each scancode off port 0x60 with its own
.CW inb .
No scancode passes through the kernel.  Injecting
.CW a ,
.CW b ,
.CW c
over QMP produces
.CW 0x1e ,
.CW 0x30 ,
.CW 0x2e
and their releases, each read in user space and printed by the driver.
.PP
The mouse is the same driver, not a second one.  The i8042 is one
stateful controller with one output buffer, and its status port's aux
bit says whether a byte came from the keyboard or the mouse, so one
driver owns the whole device:
.B ReqMousenotify
routes IRQ12 the same way IRQ1 is routed, the kernel enables the aux
device and its reporting, and the driver's drain loop routes each byte by
the aux bit \- a scancode, or a byte of a three-byte PS/2 packet it
assembles into motion and buttons.  Moving the QEMU mouse makes the
driver read
.CW "dx=15 dy=-7"
off port 0x60, in user space, for each event injected.  The one thing
this cost that the keyboard did not: the two interrupts must give
.I different
semaphores.  A first cut shared one semaphore between IRQ1 and IRQ12 and
the mouse woke exactly once to an empty buffer \- a shared semaphore
between two interrupt sources loses wakeups, because the count and the
buffer state then come from two IRQs and desync.  A semaphore and an
.CW oselect
arm each fixed it; both wake the one driver.  The whole thing \- keyboard
and mouse \- is checked by
.CW scripts/osprey-check-kbd.py ,
and the p9pair check still passes twenty-four for twenty-four across boots.
.PP
One seam is honest to name.  The one-time controller enable \- the i8042
command-byte handshake that turns the keyboard interrupt on and drains
the buffer \- is done in the kernel inside
.CW ReqKbdnotify ,
not in the driver's CPL3 kproc.  That handshake spins on the status
port, and a spin that long at CPL3 in a cooperative kproc is a window for
a clock or device interrupt to land while the kproc is the running
context, which this microkernel's interrupt path corrupts: it is the
standing pc64 heisenbug
.CW ( "pc=0xffffffff" ,
a corrupted return), and a user driver taking a legacy IRQ from CPL3
reproduces it reliably where before it was intermittent.  Run in kernel
context an interrupt landing during the handshake is handled normally,
so the setup is done there (the aux enable in
.CW ReqMousenotify
the same way) and the reads \- the data path \- stay in user space.  The
kernel also takes its own
.CW ospreykbdintr
and
.CW ospreymouseintr
off the lines first, so the notification handlers are the only ones there
and the byte stays in the buffer for the driver.  The reliable
reproduction of the heisenbug is itself worth having; chasing it is not
this item's work.
.PP
.B "8.  What the talk's goals name and nothing here does."
Authenticated, controlled access to
.I "dynamic replicated data"
(slide 11) and a
.I "caching filesystem"
(slide 23): nothing in the tree replicates or caches anything, and both
sit on item 3.  These are the talk's ends, not its mechanisms, and they
come after the file system exists.
.PP
.B "9.  A second machine."
The talk boots the same code as
.CW kpc64
and
.CW kpc32 ,
and claims the system for hard real-time embedded work.  Osprey builds
for amd64 only.  The 386 libraries build and its machine layer is in the
tree; what a 386 kernel lacks is a 386 userland for its boot file system
(section "One instance where the plan asks for a choice").  A non-x86
board is written from nothing.  The plan's "adapter selected by OBJTYPE"
has one adapter to select.
.PP
.B "10.  The number: 270 nanoseconds."
The talk measures a send, a receive and a context switch at 270 ns
between tasks of the shape slide 25 dumps \- an 8 KB task with
.CW msgsend
and
.CW msgrecv .
Here a round trip is 46\-59 \(mcs under QEMU, and the section "Latency"
says why: a message wakes a Plan 9 kernel process.  The microkernel's
tasks are still Procs.  A task of the talk's shape on the microkernel,
and the number measured on hardware, is the piece; it is structural, and
it is last because everything above it is correct without it.
.PP
.B "11.  Knowing who agreed the key."
The exchange is with whoever answers.  A person comparing two
fingerprints is the only thing that says it was the machine that was
meant, and there is nothing a machine could compare instead without
something already shared to compare it against.
.PP
.B "12.  What is a demonstration's size."
Sixteen containers, eight cores, thirty-two packets, eight names, four
grants, eight pages, sixteen arms, one producer and one consumer per
ring, one process per container; ownership on
.B poke ,
.B detach
and the server named by
.B delegate
unchecked behind a mode that keeps other users out.  The shape is right
and the numbers are compiled in.
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
asks all nine compilers for all four, and the fourth came from somewhere
else: another session working on this branch, testing the floating
point, noticed that the compilers round a decimal constant to the
nearest double only sometimes, wrote it down in
.CW fptest (1)
and left it there.  It is
.CW mpatof
in
.CW utils/cc ,
and what it did was round three times where once is wanted \- the digits
into an exact integer and that to a double, five to the power of the
digits after the point and that to a double, and then a division.
Measured against correct rounding, eighty-six of four hundred random
decimal literals came out a unit in the last place away from the nearest
double, and two of the six coefficients
.CW libkern/exp.c
carries: one high and one low.  It is
.CW strtod
now, which is
.CW lib9 's,
which every one of these compilers already links \- so the conversion is
the same on every host the tree builds on, which is the reason the
compiler had one of its own and is met either way.  Nought of four
hundred after.
.PP
Two things about doing that are worth keeping.  The check carries twelve
of the constants the old conversion got wrong with the bytes of the
right answer beside them, worked out where correct rounding was not in
question, and looks for those bytes in the object either way round,
since a machine that stores them the other way is as right.  And it said
.CW FAIL
for every compiler at first with the fix in place, which was neither the
check nor the compilers: the binaries being asked were the old ones.
Removing
.CW o.out
and building again fixed it, and the explanation written here first \-
that
.CW "mk install"
in a compiler's directory does not relink when only
.CW libcc.a
has changed underneath it \- is wrong.  Tested both ways: touching
.CW libcc.a
relinks, and editing
.CW mpatof.c ,
building
.CW utils/cc
and then building
.CW utils/6c
gives a compiler with the edit in it.  What left nine stale binaries was
not established, and the likeliest thing is one of my own rebuild loops
with its errors sent to
.CW /dev/null .
What survives is smaller and duller than a build-system bug and worth
more than one: check that the compiler you are measuring is the one you
think, rather than that the loop which was meant to build it ran.
Thirty-six lines.  Finding it took AddressSanitizer, which is worth saying
because the crash was in
.CW regopt
reading a corrupt free list and the write was in
.CW blsh
two passes earlier; a watchpoint on the corrupted pointer showed only
the compiler's own honest writes to it.
.PP
The transmit accounting added a machine-stopper and the check found it.
Under a flood of twelve hundred frames the second machine died at eight
hundred and sixteen with
.CW "panic: ilock ... key 0xdeaddead ... held by pc ... proc 407" ,
the holder and the waiter in the same function.  What the completion
path did was work out which buffers were free by walking the pool's free
list under the pool's lock, at interrupt level, over a list this code
does not own: an unbounded walk under a lock is not a fault that gets
reported, it is a machine that stops, and it stopped.
.PP
.CW freeb
says which block came back now, not only which pool, so the completion
clears one bit and gives one charge back with no lock and no walk, and
the word the container reads follows from the bits.  The one walk left
\- unlinking a block a container has asked to send \- is bounded by the
number of blocks there are.  Three runs of the flood since, and the
first failing run is the reason the check runs the flood at all rather
than eight pings.
.PP
That panic named a class, so the class got the same treatment as the
others: every interrupt lock in the device and the adapter, and what
runs while it is held.  The device's are all short and bounded now.  The
adapter's semaphore lock was not: an interrupt giving a semaphore takes
it and every packet that arrives gives one, and
.CW status
and the checkpoint writer held it across a
.CW seprint
per semaphore, while the checkpoint reader held it across taking a line
of text apart.  All three copy or parse outside the lock now and hold it
only to move the numbers.  It is also why
.CW *ospreysem
has a ceiling of sixty-four where the other four have only the arena's:
the copy has to go somewhere fixed.
.PP
Two limits were then asked what the changes had done to them, one of
which turned out to be fine.
.CW Statuslen
is thirty-two kilobytes and
.CW *ospreysem
is settable now, so a machine with sixteen containers holding sixty-four
semaphores each ought to have been near it: measured, that status is
eleven thousand two hundred bytes with the trailing
.CW "key none"
line still on it, so nothing is cut and the arithmetic that said
otherwise was wrong.  Worth having asked, and worth saying it was
refuted rather than fixed.
.PP
The other had moved a long way.  Making the data area unconditional put
about nine and a third kilobytes of checkpoint behind every container
that has written all of its own, where an idle one used to be two
hundred and forty; at
.CW "Snaplen = 64*1024"
the eighth such container was refused, and that cliff arrived with the
change and nothing said so.
.CW snap
is a checkpoint of the whole machine, so it is sized for the whole
machine now: a hundred and ninety-two kilobytes, and sixteen full
containers come to a hundred and forty-nine thousand three hundred and
ninety-nine bytes of it.  The check fills every container the machine
can hold and counts them in what comes back.
.PP
Another session is working on this branch at the same time, on the
Inferno boards, and found a fault in the compilers worth recording here
because it reaches this kernel.
.CW mkvar
gives the two halves of a union separate entries when their offsets
differ, and neither then looks address-taken, so a double whose high
word is written through the other arm of the union can be kept in a
register while the write goes to memory and be returned stale.
.CW libkern/frexp-386.c ,
which is what amd64 builds, is exactly that shape:
.CW ldexp
scales by writing
.CW x.ms .
They fixed
.CW jc
and
.CW tc ,
where a board boots and
.CW fptest (1)
can say so, and left the other seven alone for want of anything to say
whether it worked.
.PP
What can be said from here is where it lands.  Nothing in the Osprey
kernel's sources calls
.CW exp ,
.CW pow ,
.CW ldexp
or
.CW frexp ,
and nothing formats a float; but
.CW frexp
and
.CW ldexp
are in the linked kernel all the same, pulled in by something in the
print path, where
.CW exp
and
.CW pow
are not.  So the routines that fix repairs are carried by this kernel
and, as far as the sources say, never reached.  That was the reason to
leave
.CW 6c
to whoever could run a number through it \- and once the loaders were
right, this machine could.
.CW fpbits
carries the idiom itself, a double whose high word is added to through
a pointer, and printed
.CW "scale 3ff8000000000000"
where
.CW 4008000000000000
is right: 1.5 for 3.0, the fault exactly as they described it, and the
.CW -S
listing shows
.CW y
never leaving
.CW X0
while
.CW "ADDL AX, y+-4(SP)"
writes to memory.  Their
.CW mkvar
fix is in
.CW 6c
now, adapted to its signature; the listing stores the double before the
half-write and reloads it after, the check they wrote counts
.CW 6c
among the fixed, and the line on the machine reads
.CW "scale 4008000000000000" .
The other five compilers with the fault are left as they left them, for
the reason they gave: nothing here boots with them.
.PP
Trying to run a number from here turned up something else, and getting
it right took four goes, of which the first three were wrong in
different ways and are worth keeping for that.  A double did not work in
an Osprey command: a variable set to 1.5 read back as sixteen zero bits,
from a literal or from the program's own data alike, and
.CW "a > 1.0"
was false while
.CW "b == 3.0"
was true in the same run.  The first account said the programs cannot do
floating point at all; the second said it looked like the library, since
these programs cannot link the C library's startup; the third measured
more carefully and still blamed the library.  All three were guesses
dressed as findings.  What settled it was comparing the object with the
binary: the object held 1.5 and the linked program held eight zero
bytes, so the fault was in
.CW 6l
and nowhere else.
.PP
.CW Ieee
holds a double as two longs, and every loader laid the eight bytes out
by casting that struct to bytes, which on a host with a sixty-four bit
long copies the low word and the four zero bytes above it and never the
high word.  The other session had found and fixed exactly this in
.CW 5l
and
.CW tl ,
the two it could boot, and left the other seven; the same edit is in all
nine now, and
.CW scripts/cc-check.sh
links a program holding two doubles with each and looks for their bytes.
On the machine,
.CW fpbits
prints
.CW "1.5 3ff8000000000000" ,
.CW "3.0 4008000000000000"
and
.CW "compares yes" ,
and that is a line in the single-machine check.
.PP
That the whole math path works now follows without running it.
.CW exp
is the six coefficients above, correctly rounded since
.CW mpatof
was fixed, combined by
.CW ldexp ,
which is the scale-through-a-pointer idiom that
.CW fpbits
prints right; there is nothing left in
.CW exp
for the three faults to hide in.  It could not be run from a command
anyway, and the reason is worth pinning down because it is the concrete
shape of the missing userland.  The programs link
.CW Osprey/amd64/lib/libc.a ,
which is not built by this tree \- there is no recipe for it anywhere in
the mkfiles, it is an untracked artifact dated before this work, and its
members carry nonsense modes
.CW ( "rws-ws-w-" on abort.6 )
and a format this
.CW 6l
will not read
.CW ( "opcode out of range 678" on exp, pow and log ) .
The members
.I ring
and
.I p9srv
happen to use read; the math and the startup do not, which is why every
Osprey command supplies its own
.CW _main
and its own output.  This tree's own
.CW iar
is not the cause: a library it builds carries
.CW rw-r--r--
members this loader reads, as
.CW libosprey9.a
does.  The fix is a libc built from source with this toolchain, which is
the userland the plan's
.I "User-level services"
section is about and which no part of this tree yet holds.
.PP
One more thing came out of it, and it belongs to the fact that two
sessions are working in one tree.  Relinking any of these programs gave
a binary with no library in it \- 253 bytes of text where
.CW o9cat
has four thousand \- and the cause was an uncommitted one-line change
to
.CW utils/6l/pass.c
in the working tree, the other session's, which my rebuild of the loader
had compiled in.  A loader built from the committed
.CW pass.c
links 4053 bytes of text for the same program.  That file is not mine
to touch and is not touched; the loader installed here is built from
the committed source, and this is written down so that whoever next
finds every program shrinking knows where to look.
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
Cutting toward the paper's kernel
.PP
The direction changed here.  Until now the work built the Osprey policy
layer inside a Plan 9 kernel and let a container replace the file and
network personalities from user space.  The instruction now is to cut
the Plan 9 kernel functionality out \- process groups, the rfork that
copies a name space, the whole file and device personality \- until what
is left is the kernel the paper dictates: fast message passing, address
space maintenance, interrupt handling, and process scheduling, and
nothing else in the kernel.  A task, not a Plan 9 process, is the unit;
files are reached over \[*p]p from a library operating system, not from
a kernel file server.
.PP
The obstacle is the boot, and naming it is half the plan.  The first
process today,
.CW proc0
in
.CW os/osprey/port/userinit.c ,
builds a
.CW Pgrp ,
an
.CW Egrp ,
an
.CW Fgrp
and an
.CW Rgrp ,
resolves a name space through
.CW namec ,
loads Plan 9
.CW initcode
into a text segment, and drops to the Plan 9 shell.  That shell is what
every check in this document runs on.  Cutting the groups and the name
space out means that boot cannot come up, so a microkernel needs an
Osprey init task to boot into instead: a task that uses only message
passing, a segment for its address space, and the scheduler, with no
.CW Pgrp
and no
.CW namec .
.PP
So the cut is done constructively, not by deleting first and having
nothing to test for a long time.  A second configuration,
.CW upc64 ,
shares the machine layer \- the trap, interrupt, mmu, clock and console
code, which are the kernel's real job \- and carries a stripped device
list: only
.CW arch ,
.CW cons ,
.CW uart ,
.CW segment
and
.CW osprey ,
which are the four services and a console to watch them on.  Its
.CW userinit
starts an Osprey init task directly, with no groups and no
.CW initcode .
When that task can do from the microkernel what a container does now \-
message passing, select, semaphores, a segment it maps, a driver served
by a task \- the Plan 9 configuration
.CW pc64
and the personality devices it carries are deleted.  Until then
.CW pc64
is kept only as the testbed the fifty-eight-line check still runs on, and
its retirement is the measure of the work, not its persistence.
.PP
The first cut is built and boots.
.CW os/osprey/pc64/upc64
is the configuration; it sets
.CW ospreymicro ,
and
.CW proc0
branches on it to
.CW ospreymicroboot
in
.CW os/osprey/port/devosprey.c
rather than building the Plan 9 groups and name space and dropping to
the shell.  That task ensures the arena, creates a container, submits
four requests to its message ring, lets the dispatcher answer them, and
collects four replies \- status
.CW done
on every one \- then idles.  The console shows
.CW "osprey micro: a task, no plan 9 boot"
and
.CW "osprey micro: 4 of 4 requests answered" ,
and
.CW "proc0: groups"
never prints, so no
.CW Pgrp
is made on that path.
.CW scripts/osprey-check-micro.py
boots it and checks those three things.
.CW pc64
still boots the Plan 9 shell with
.CW ospreymicro
zero, so the fifty-eight-line check is unaffected.
.PP
What is proved is small and real: the four services stand and a task runs
on them with the Plan 9 boot cut away.  What upc64 still carries is
pc64's whole device list and the port sources behind it \- the file and
name-space personality is linked, merely not entered on this path.  The
next cut is done: the device list is stripped.  upc64 carries eleven
devices where pc64 carries twenty-four, having lost root, pnp, pipe,
proc, mnt, srv, shr, dup, cap, kprof, fs, and the sd and audio stacks \-
the file and name-space personality.  What is kept is
.CW cons ,
.CW arch ,
.CW uart ,
.CW segment
and
.CW osprey ,
the four services and a console, plus
.CW rtc ,
.CW swap ,
.CW env
and the ether and ip stack, which the always-linked port code and the
osprey device's own packet path still reference at link time and which
later cuts remove.  Removing
.CW mnt ,
.CW srv
and
.CW shr
left symbols the port core names that the microkernel boot never
reaches; the config's port section stubs each with a panic, and none
fires, which is the evidence they are personality and not mechanism.
Data fell from three hundred and thirty-seven kilobytes to two hundred
and sixty-three.  The task still boots and answers four of four requests
on its ring, and
.CW scripts/osprey-check-micro.py
still passes.
.PP
The network is cut too.  The osprey device named an interface by calling
.CW etherlookup
in the ether device directly; it goes through the
.CW ospreyetherlookup
pointer now, which the ether device fills at reset the way it already
took a received packet through
.CW ospreyetheriq .
A kernel with no ether device leaves the pointer nil and the osprey
device's ether control message fails rather than failing to link.  With
that, the whole ether and ip stack \- the drivers, the media, tcp, udp
and the rest \- leaves upc64, which is down to eight devices:
.CW arch ,
.CW cons ,
.CW env ,
.CW osprey ,
.CW rtc ,
.CW segment ,
.CW swap
and
.CW uart .
The stack was most of the kernel: upc64 is seventy-seven kilobytes of
text where pc64 is three and a half megabytes.  The microkernel still
boots its task and answers four of four requests, and pc64 still answers
a ping from another machine through the hook, so
.CW scripts/osprey-check-net.py
passes nine of nine.
.PP
Swap and env are cut too, each as its own step: swap because the
microkernel does not page, its five symbols defined as their real
no-swap no-ops; env because an environment is a name-space thing kept in
a library operating system.  The microkernel is six devices now \-
.CW arch ,
.CW cons ,
.CW osprey ,
.CW rtc ,
.CW segment
and
.CW uart
\- which is the four services, a console, and the clock.  The clock
stays because it is the scheduler's, and because the AP-start path
writes the warm-reset vector through it; taking it out would strand the
scheduler's tick and the other processors, so it is not an extra to
shed but the timekeeping the fourth service is built on.  Sixty-eight
kilobytes of text against pc64's three and a half megabytes.
.PP
What is left is not a device but the always-linked port sources behind
them:
.CW chan.c ,
.CW pgrp.c ,
.CW cache.c
and
.CW sysfile.c ,
which are the name space, the process groups the instruction named
first, and the file machinery.  These are woven into the kernel, not
bound to it through a device table: thirty-three uses of a process's
.CW pgrp
across the port layer, and the name resolution
.CW chan.c
does for every open.  The microkernel boot touches none of it \- a
kernel task has a nil
.CW pgrp
and opens nothing \- so the code is linked and dormant rather than
reached, which is why the boot stands with it present.  Removing it from
the binary is the deep cut, and it is where cutting becomes writing a
different
.CW proc.c
and
.CW chan.c :
the mkfile links one set of port sources into both configurations, so
the microkernel cannot drop
.CW pgrp.c
while pc64 keeps it without the port source list becoming
per-configuration, and the code that would go is entangled with the proc
and segment code that stays.  That is the boundary the paper draws when
it calls the microkernel unreachable from a Plan 9 kernel, reached now
from the other side: the device personality is gone, and what remains is
the name-space machinery itself.
.PP
The yardstick for how far this goes is seL4, which provides no devices
at all: its kernel is endpoints and notifications for message passing,
thread and address-space objects, and interrupt-handler capabilities, and
every driver \- disk, network, console, clock \- is a userspace task that
holds an interrupt capability and a mapping of the device's registers.
The only hardware the kernel touches is what it cannot delegate: the
interrupt controller, and a timer for the scheduling tick.  Measured
against that, six devices is not the floor.  osprey and segment are the
real kernel mechanisms, message passing and address spaces; the interrupt
and scheduling core is legitimate; but cons, uart and rtc are drivers
that seL4 would put in userspace, each a task that selects on the
semaphore its interrupt gives, which is the very shape the paper
describes for a driver and which pc64 already has one instance of in the
uart served by a task.  So the seL4-minimal end state is two kernel
devices, osprey and segment, with cons, uart and rtc moved out to driver
tasks \- the same driver-task work, not more device deletion \- and a
bare panic console kept in the kernel the way seL4 keeps a debug putchar,
because the kernel must be able to report a fault before any userspace
driver exists.
.NH 2
The two large cuts: a plan
.LP
Two cuts remain, and they are not more of the device-list deletion that
took the kernel from twenty-four devices to six.  Each is structural.
.PP
The first is the port-source cut, the name space and everything Plan 9
built on it.  It is staged.  Stage one, done, cuts the process groups,
the file system calls, the process system calls and the system-call
trace formatter: pgrp.c, sysfile.c, sysproc.c and syscallfmt.c are no
longer linked into the microkernel.  The subtlety that shaped it is that
pgrp.c was not all name space.  Five of its functions \- newpgrp,
newrgrp, closepgrp, closergrp and the resource wait \- are the lifecycle
of a process's and a rendezvous's group and of waiting on a scarce
resource, which the scheduler itself needs: proc.c's kproc makes a group
and the rendezvous path locks one.  Those five moved into proc.c, where
they belong, so both kernels still have them and only the microkernel
loses the name-space half.  What the remaining linked code still names
from the cut files \- the file-descriptor group, the mount operations,
the system-call entry points \- is stubbed in the microkernel's own
configuration as loud panics, because a kernel process holds no file
group, opens no descriptor, mounts nothing and takes no system call, so
none is reached; two utilities that are real, the byte swap the reboot
path uses and the do-nothing sleep predicate the whole kernel uses, are
kept as real code, not stubs.  Verified: the task still boots, its ring
still answers, it still reaches idle, and pc64 is untouched at all
fifty-eight of its checks.
.PP
Stage two, done, is chan.c and cache.c themselves, the name resolution
and the file cache.  It was deeper because chan.c was not only name
space: the device bring-up main() calls at boot, the reference counting
the whole kernel turns on, and two string helpers all lived inside it.
Those are kept, as real code in the microkernel's configuration - the
reference counting and the string helpers verbatim, the three device
bring-up functions rewritten only to iterate the device table by pointer
rather than by index, because a configuration line whose first token
begins with the letters of a section name is misread by the config
compiler as a new section and silently truncates the file; a real bug in
mkdevc that this cut was the first to provoke, worked around in the
configuration rather than in the shared tool.  Everything that is name
space - namec, the channel clone and close, the path and mount-head
operations - is a loud panic, because a kernel that resolves no name
reaches none of it.  Verified: the task boots, its ring answers, it
reaches idle, and pc64 is unchanged at all fifty-eight checks.  With
this the microkernel has no name space at all: no namec, no channel, no
mount, no file cache, no process group, no file or process system call.
What is left is the four services the paper keeps and the devices that
serve them.
.PP
Two more Plan 9 sources went with the same idiom: auth.c, the
authentication - fversion, fauth, the host owner and host domain - and
rdb.c, the remote kernel debugger.  Their callers were the file and
process system calls, already cut.  What still named them was the
console device: iseve, which asks whether the caller is the host owner,
and the writes to the owner and domain files.  A microkernel has one
trust domain, managed by the library operating system above it, so iseve
returns true and the rest are console file handlers this kernel has no
name space to reach, so they panic.  The one subtlety was the host
owner string itself: it must stay nil until userinit sets it, because
userinit sets it with kstrdup, which frees the old value, and a string
literal cannot be freed - a real double-free the boot caught at once and
inspection would not have.
.PP
The microkernel check grew a fourth line for this cut.  The first three
prove the boot reaches a task and its ring answers; none of them walks
the teardown the cut left stubbed, because the boot task idles rather
than exits.  So the boot now spawns a kernel task that returns, which
takes it through pexit and the group closes: closepgrp, moved to proc.c,
runs for real, and the file, rendezvous and environment closes and the
dot close are each guarded by a nil a kernel task has.  If any stub were
wrong this panics; the fourth check asserts the task exited and the
kernel did not, which is the teardown being clean.
.NH 2
Cut B begins: the last-resort console
.LP
The second large cut turns cons, uart and rtc into userspace driver
tasks.  Its first piece, and the one that must exist before any of the
others can be removed, is a console that owes nothing to a device: a
panic must be able to reach the screen before the first driver task runs
and after the console has moved out of the kernel.  seL4 keeps exactly
this and no more, a debug putchar.  kdebugputc, in the machine's own
main.c, is it: a direct polled write to the 8250 at COM1, waiting on the
line-status register and writing the byte itself rather than going
through consuart and the uart driver.  The microkernel proves it at boot
by writing one line straight through kdebugputc, which the fifth check
asserts appears; with cons still present, so the fast path and the
last-resort path can be compared, which is why this piece is built first.
.PP
Finding it cost an afternoon to a mistake worth recording: the amd64
machine has its own main.c and mmu.c under the pc64 directory that shadow
the 32-bit ones under pc, and an edit to the wrong one is not a
compile error but a kernel that boots the 32-bit code in a 64-bit
address space and faults early with a physical address used as a
virtual one.  An inconsistent incremental build made it look like a
name-space or PCI-BIOS problem in turn; a clean rebuild, the only honest
test, showed the tree was sound and the edit was in the wrong file.
.PP
The rest of Cut B, the driver tasks themselves, rests on mechanisms the
osprey device already carries, so it is a build on what exists rather
than on a userland that does not.  An interrupt already gives a
container a semaphore it selects on: ospreyticksem for the clock,
ospreyuartsem for the uart, ospreyethersem for a packet, and the uart's
output is already staged for a task to drive.  Device memory is already
lent to a container through a Physseg.  Reading the device to plan the driver tasks turned up that one of them
is already built and tested.  The osprey device carries a uart command,
documented in osprey(3) and exercised by the Plan 9 check, that binds a
uart to a container: the container's task selects on the semaphore the
uart's interrupt gives and drives the port through the kernel's thin
uart primitive - intrmask, the staged send - rather than by touching
registers itself.  That is the paper's driver-as-a-task, and it settles
the model this kernel uses: not seL4's map-the-registers-into-userspace,
but a thin register primitive kept in the kernel with the driver policy -
when to read, when to write, how to buffer - run as a container task
above it.  It is the more honest shape for a kernel whose tasks migrate,
because a mapped register is pinned to a machine and a served primitive
is not.
.PP
So the uart driver task exists.  What remains of Cut B is to use it: to
have the microkernel run a container as its console's driver rather than
the kernel's own devcons path, and to do the same for the clock, whose
interrupt already gives a container a semaphore through ospreyticksem.
The register primitives and the bare panic console stay in the kernel;
the policy moves out.  That is a build on a mechanism that is already
proven, and it is where Cut B goes next.
.PP
The first use of it is now in the microkernel boot, and it is the
paper's central primitive shown for the first time driven by a real
interrupt with no name space anywhere in reach.  The boot asks the clock
to give its container a semaphore on every tick - the way a device
interrupt hands work to the task that serves it - waits on that
semaphore with an OSdown arm, and a few ticks later the arm is ready.
That is a driver task's select over arms, woken by the clock's
interrupt, running as a container in the scheduler like any other task.
A sixth microkernel check asserts it.  With it the microkernel now shows
all four services and the primitive that ties them together: message
passing through the request ring, the address space its arena is,
process teardown through pexit, and a select over arms woken by an
interrupt - the shape every driver task will take.
.PP
The piece after this is the same select serving a real named device
rather than the clock: bind a uart to the container, feed a string
through ospreyoutput onto its output queue, and watch it leave the
machine on the second serial port, which the check harness already
supports.  Every mechanism it needs is in hand - ospreyctluart binds and
spawns ospreyuarttask, ospreyoutput queues the work, COM2 exists.  The
one thing to get right, found by reading the code rather than by running
it, is the lock: ospreyuarttask takes ospreylock around its own select,
so the boot cannot hold that lock while it waits for the task to run, as
it does through the poll loop and the clock demonstration.  The boot
must release ospreylock and let the task contend for it, the way the
control-file path releases it between one write and the next.  That is
the next step, and it is a careful one, not a large one.
.PP
It was attempted and is not yet landed, and the honest record is worth
keeping.  The lock hand-off worked: a second container was created, the
second serial port bound to it with ospreyctluart's logic, the driver
task spawned, a line queued through ospreyoutput, and the boot released
ospreylock and waited while the task ran.  The task reported the send
complete - it bound the right port, COM2 and not the console, and drove
its output length to zero - but the bytes did not arrive on the second
serial port the harness watches, though the boot loader's own writes to
that port did.  So the send succeeds at the register and the port is the
right one, yet nothing reaches the emulated line.  The difference from
the Plan 9 path, where the same uart command works, is that there the
port is opened through the device before it is driven, and the direct
bind skips whatever that opening does; calling the port's enable did not
close the gap.  Resolving it needs the emulator's serial state looked at
directly rather than more guessing, so it was reverted to keep the
microkernel at the six checks that pass, and it is where this picks up.
.NH 2
A file operation answered outside the kernel
.LP
The point of the cut is that a personality \- opening a name, reading
it, the shape of a file \- is a program above the kernel, not code
inside it, and the microkernel now shows one such operation answered
that way.  A second container is made the first one's server.  The
client submits an open.  Servicing the client does not reach the
kernel's own personality in ospreykernop, whose open calls namec, which
is a panic in this kernel: dispatch forwards the request to the server's
request ring instead, stamped with the client's identity.  The boot then
plays the server in the same loop \- not as a task, so no lock is
released and nothing contends for it, the mistake the uart round-trip
made \- reading the forwarded request off the server's ring with a get
arm, answering it done, routing the answer back to the client, and the
client collecting it.  A seventh check asserts the open completed with no
panic, and the completion is the whole proof: the kernel's cut
personality could not have answered, it would have faulted in namec, so
that the client got a done at all means the other container did.
.PP
This is not p9srv and it is not the 9front personality, and the
difference is the honest part.  p9srv is that personality: an ordinary
user program that answers a container's open and read with ordinary
system calls in its own name space, and it runs and is tested on the
Plan 9 kernel, where the whole of 9front is still present to provide
those system calls.  The microkernel cannot host it, and the reason is
exact: running a program is loading and exec, which are sysproc.c, which
the cut removed.  So what is proven here is the delegation path the
kernel keeps \- a request carried to another container and its answer
carried back, the kernel doing nothing but the carrying \- with the boot
standing in for the program a server would be.  Hosting the real p9srv
is the next thing, and it needs the one capability the cut took out: a
way to load and start a program in a container.
.NH 2
A library operating system on the microkernel, the right way
.LP
A first answer to this got the shape wrong and is worth recording as a
wrong turn.  It linked the 9front personality into the kernel binary and
had a kernel task call namec directly.  That is not a library operating
system; it is a smaller monolithic kernel.  A library operating system
is the personality implemented as a library that a program links and
runs on top of the microkernel, in its own space, reaching the kernel
only through the kernel's own interface.  The personality must be above
the kernel, not in it.  That config, lup64, was removed.
.PP
The right shape needs the microkernel to run a user program, which the
cut removed with sysproc.c and which the wrong turn dodged rather than
built.  xup64 builds it.  It is the same cut core as upc64, but instead
of running a kernel task it sets up a user program's text and stack and
enters user mode, with no name space: the exokernel gives the program an
address space and lets it run.  The program reaches the kernel through a
system-call interface of two calls and no more: write, which puts bytes
on the console, and exit.  There is no open, no bind, no name to resolve
in the kernel; those are the personality's, and the personality is a
library the program links.  Verified from the boot: xup64 reaches user
mode, and a program's first system call traps into the kernel \- at
first the panic stub the cut left, then, once the two calls were real,
the program's own output.
.PP
On that interface runs the library operating system.  userprog is a
program that opens and reads a file not through the kernel but through
persopen and persread, a personality it links and calls in its own
address space: a name space of a couple of files and the open and read
over it.  It prints that it is opening a file through its personality
library, then the file's contents, served by that library and not the
kernel, then that they came from user space, and exits.  The kernel
carried none of it but the write of the output and the exit.  Four checks
assert it, and the ospreyuser flag leaves upc64 and pc64 untouched.
.PP
This is a library operating system in the shape the paper means: the OS
personality implemented as a library, run on top of the microkernel, the
kernel providing only its four services and a minimal interface to them.
It is minimal \- a couple of files, not 9front's name resolution \- but
the architecture is right, which lup64's was not.
.PP
The program also maps its container's ring, which is how a library
operating system would reach what it does not hold.  It maps its
container's slice with segattach \- the address-space service, one of the
four, offered as a call \- after the kernel binds it to a container so it
is entitled to that slice.  Five checks assert the program running, its
personality library serving a file, and this mapping, and the flag that
turns it on leaves upc64 and pc64 untouched.
.PP
And a message-passing round trip over that ring: the program puts a poll
request in the ring in its own memory, traps once to have the kernel
service it, and reads the reply back from the ring - submit and collect
are memory, only the service is a trap, which is the shape the paper
gives.  Poll is a mechanism the kernel answers itself; a file request
would be forwarded the same way to a server.  A sixth check asserts it.
.PP
It did not work at first - about half the time no reply came back, per
boot, and retries did not help - and finding out why is worth recording,
because the cause was subtle and the method was not a guess.  Comparing
the kernel's and the program's view of the ring showed the kernel never
saw the request; narrowing further showed the service finding no
container bound to the process at all.  The binding was being cleared:
the boot bound the process to its container by setting the slot but not
the process's own back-pointer to the container, and the clock's reaper
clears any slot whose process claims no container, so a single tick
between the bind and the first service undid it.  Binding the way attach
does - the back-pointer too - fixed it, and the round trip now returns
every time.
.PP
So the loop is closed in the right shape: a program on top of the
microkernel, its OS personality a library it links, reaching the kernel
through a minimal interface - an address space, a mapped ring, message
passing over that ring, and exit.
.PP
And the file server it talks to over the ring now exists, so the
personality library reaches files it does not hold, by a real open and
read protocol.  The boot makes a second container, the server, delegates
the client to it, and spawns a task that holds a small name space of a
couple of files.  The library opens a file by name: it writes the name
into its own data area and submits an open; the server reads the name out
of the client's slice, which delegation entitles it to, resolves it, and
returns a handle.  Then the library reads: it submits a read with the
handle, and the server copies that file's bytes into the client's data
area - so the answer is the whole file, not what fits in a reply - and
returns the count, and the library reads the bytes out of its own memory.
Both operations cross the ring, both run in user space, and the kernel
carries the messages and nothing else.  Two bugs fell on the way, each a
general one: the service call must yield after servicing or the retry
loop starves the server task, and the flat-loaded program has no data
segment, so its ring state lives on the stack, not in statics that are
BSS the image does not load.
.PP
This is the paper's shape now in full, in miniature: a microkernel of
four services and a minimal interface to them; a program on top whose OS
personality is a library it links; and, reached by an open-and-read
protocol over the ring, a file server that is another task on the same
microkernel, answering in its own name space.  What is small is the
content, not the structure - two held files, not storage behind a real
tree.  The server, though, is no longer a kernel task: it is its own user
program now, described next.  Growing the content is the work from here;
the structure is the library operating system the paper describes.
.NH 1
The file server as its own user task
.PP
The file server started as a kernel task, which the plan recorded as the
one thing still on the wrong side of the line: a server answering the
client's opens and reads, but from inside the kernel.  It is now a second
user program, and two user tasks exchange the messages while the kernel
only routes them.
.PP
A kernel process reaches user mode the same way the first program did.
proc0 becomes a user task by loading its image into its own address
space and calling touser; a kernel process does no differently, because
the kernel-process flag is only about scheduling.  So the server is
spawned as a kernel process whose entry loads the same program image,
binds itself to its own container the way attach binds - the slot and the
process's back-pointer both, or the clock's reaper clears it - and enters
user mode with one argument that names its role and the two slices it is
to map.  The shared image branches on that argument: with it, the program
is the server; without it, the client.
.PP
In user space the server maps two slices with the address-space service.
Its own ring is where the microkernel routes the client's forwarded
requests, and it reads them straight out of that ring in its own memory,
no trap to collect a request.  The client's slice it maps too, which
delegation entitles it to - the name to open and the buffer to read into
are offsets in the client's slice, so a server that could not reach it
could answer nothing.  It resolves the name in its own small table,
copies the file's bytes into the client's slice, writes the reply into
its own reply ring, and sleeps - and the only thing the sleep is for is to
have the kernel route what it answered back to the client.  Submit and
collect are memory on both sides; the two traps in the whole exchange are
the two sleeps that move a request forward and a reply home.
.PP
One kernel change made this work, and it is small: the service call a
task makes now also routes, for a task that answers for others, whatever
that task has replied.  It was already what the kernel did for a server
at other moments; doing it on the server's own service call is what lets
a user-space server's replies reach its client with no kernel task
driving it.  It is a no-op for a task that serves no one, so the ordinary
caller is unaffected.
.PP
The server waits for its requests with select, the talk's central call,
now offered to a user task.  It names one arm in its own data area - a get
on its request ring - and the select returns when that arm is ready,
having taken the request into a buffer the arm named, exactly the shape
the talk draws for a task that selects on its message queue.  The syscall
reuses the DUP number the way service reuses SLEEP: the program's libc
already has the stub, and the minimal interface spends spare numbers
rather than inventing an ABI.  The block underneath is a real rendezvous
now: a task with no ready arm sleeps, and it is woken the instant an arm
becomes ready - an interrupt gives its semaphore and wakes the container's
select, a request forwarded to a server's ring wakes that server - rather
than waking on a timer to look again.  It keeps a short timeout as well,
so an idle driver still returns and can give up and the headless boot
ends, but a real event wakes it at once.  This is the paper's driver
sleeping on its select and being woken by the interrupt, not polling.  The
same select serves the reply home before
it waits again, so a server answers and waits on the one call.  Two user
tasks, each its own container and ring, exchange an open and a read, the
kernel carrying and routing the messages, answering none of them, and the
server expressing its wait as the talk's select over an arm.
.PP
A note on the console this surfaced.  With two user tasks writing to the
bare COM1, the boot marker lost a byte and a check that matched it exactly
failed - not the exchange, the console.  The fix was to wait for the
UART's transmit register between bytes, which the client's console path
already did and the boot marker did not.  A lock around whole strings was
tried and taken back out: it would have held a spinlock across an
unbounded hardware wait, which turns a panic on another core into a silent
hang - the one time the console matters most.  The per-byte wait is what
carried it; strings from two tasks may interleave, which reads fine.
.NH 1
User-level drivers over exposed hardware
.PP
The talk gives a driver a shape: a task on its message queue, its
interrupt's semaphore and its output queue, with the kernel doing only
the least an interrupt must.  seL4 says the same in its own words \- the
kernel exposes a device's memory as frames a program may map and each
interrupt as a notification a program waits on, and the driver is a user
program.  The microkernel does exactly that for three real devices now,
and the drivers that use them run in user space, above the kernel, in
xup64's program.
.PP
The first is the display.  UEFI hands the kernel a linear frame buffer
and names it in a boot argument \- on this machine 1280 by 800, 32 bits a
pixel, at a physical address.  The microkernel publishes it as a named
physical segment, the way it publishes a container's slice, so the
program maps it with segattach \- the address-space service, one of the
four \- and writes pixels.  It draws a grey desktop, two overlapping
windows each with a border, a title bar and a body, and a cursor.  The
kernel multiplexes nothing and knows nothing of what is drawn; it exposed
the memory and the driver did the rest.  This is the exokernel model for
graphics, and it is why the draw stack does not go back in the kernel: it
belongs here.
.PP
The second and third are the keyboard and the mouse, and they show the
interrupt half of the model.  Each is a short handler in the kernel that
does only what the talk allows an interrupt to do.  On the keyboard's
interrupt the handler reads the one scancode byte from the i8042 and
writes it into a ring in the container's own data area \- the area the
program has already mapped \- and raises a semaphore.  On the mouse's
interrupt, twelve, the handler reads one aux byte the same way into a
second ring and raises a second semaphore.  The kernel enables the two
interrupts at the controller itself, since it runs no keyboard
initialisation of its own, and links no keyboard or mouse device: the
hardware is exposed, the driver is above.
.PP
Above the kernel, in the same program, the drivers wait on those
interrupts the way the talk says a driver does: they select on the
interrupt semaphores.  The keyboard's interrupt gives semaphore one and
the mouse's gives semaphore two, both exposed to the container; the driver
selects over a down on each and wakes when either fires, then reads the
scancode or mouse byte out of the ring the short handler filled - the
semaphore is the wake, the ring is the data.  This is the same select the
file server waits on its ring with, on the other arm the talk names: a
down on a semaphore rather than a get on a ring.  The keyboard driver
draws a square per key press and echoes the scancode to the console.  The
mouse driver assembles the three-byte PS/2 packets,
sign-extends the movement, moves the cursor sprite over the desktop \-
saving and restoring the pixels under it, so it lifts cleanly \- and marks
a left button press.  Driven from the outside: sending
.CW "hello osprey"
makes the keyboard driver echo the exact scancodes and draw a square per
key, and moving and clicking the mouse moves the cursor to the place
aimed at and leaves a click mark there \- the console prints the click at
the cursor's moved position, which is the packet path, the cursor
arithmetic and the button bit all working from the exposed ring.  None of
it is in the kernel.
.PP
So both halves of the driver model are live above the microkernel:
exposed device memory drives a user-level graphics driver, and exposed
interrupts drive user-level keyboard and mouse drivers that select on
those interrupts' semaphores, each interrupt handed on as a semaphore the
driver waits on and a ring the driver reads.  This is the path the gap analysis
lays out toward rio: the display and the input are user-level drivers
now, and what remains between here and rio is a user-level draw service
that multiplexes the display among clients, and the 9front personality as
a library with a name space and exec, under which rio would run.  Those
are content and userland; the driver model beneath them is built and
shown.
.NH 1
Toward rio: the frame buffer reaches the full personality
.PP
A full 9front personality is already up.  Booting the disk on pc64
reaches a glenda rc prompt with the whole userland - rc, the commands,
and rio itself, all on the disk.  What stops the graphical login is not a
personality but three devices the profile binds and the kernel does not
carry: the draw device, the mouse and the usb host.  The draw stack
belongs above the kernel, over the exposed frame buffer, so the first
step toward rio is that frame buffer reaching an ordinary process of the
full personality the exposed-address-space way.
.PP
It does now.  The kernel publishes the firmware frame buffer as the
.CW framebuffer
physical segment at ospreyinit, on every configuration, not only the
microkernel path - the same publish the microkernel program already maps,
now offered to the full personality too.  A small program of that
personality,
.CW os/osprey/cmd/fb.c ,
cross-built on the host and carried in on the boot ISO the proven way
(9660srv over the CD's data track), maps the segment with segattach and
writes pixels straight into it.  Booted off the disk and run, it draws a
full-screen gradient, a block and two bars - and they are on the screen,
with no kernel graphics stack anywhere in the path.  The memory a driver
needs is handed to a user program by name; the program draws.
.PP
That is the foundation every version of the draw stack stands on.  What
comes next along this line is a user-level draw service - a program that
owns the mapped frame buffer and answers the draw protocol rio speaks,
multiplexing the display among windows, with the mouse and keyboard fed
from the exposed interrupts already built - and then rio itself, off the
disk, against that service.  Its draw code, devdraw.c, was an older protocol
version and is now reconciled to the current one: it compiles clean
against the headers again.  The divergence turned out to be small - the
Warp matrix became a struct, and one command, the affine transform, has a
newer memdraw entry (a mask image and more points) and a wire form to
match.  drawwarp is on the struct now, and the affine command, which rio
does not use, refuses until its new form is written; everything rio needs
is on the current protocol.  So a user-space draw server derived from this
code speaks the version the disk's rio speaks.
.PP
The compositing library works over the exposed frame buffer, and the way
to it is to build where the toolchain and the libraries already agree.
The host's linker cannot read the prebuilt 9front
.CW libmemdraw.a
or even libc's
.CW malloc
- those objects were built by a newer compiler than plan9port's linker
here reads, which is a red herring: it is a fact about cross-linking
foreign objects, not about the library being out of reach.  The disk is a
full 9front development machine - 6a, 6c, 6l, mk, the matching libc and
libmemdraw, and all of /sys/src, rio's source included - so a program of
the personality is built there, natively, against those very libraries.
.CW os/osprey/cmd/fbdraw.c ,
carried onto the boot ISO as source, is compiled and linked on the disk
with its own 6c and 6l against its own libmemdraw, and run: it allocates a
memory image with the library, fills a background and draws two rectangles
with memimagedraw, and blits the result to the exposed frame buffer - and
it is on the screen.  So the compositing core a draw server needs builds
and runs; nothing about it was a wall, only the host cross-link was.  The
draw server is written and built the same way, on the disk against the
disk's libraries, and a from-source stack in the tree - the userland built
with the utils toolchain, which is the same kencc - is the reproducible
version of the same thing.
.PP
The draw service itself is now built and running.
.CW os/osprey/cmd/draw
is the kernel's own
.CW devdraw.c
reused whole behind a small kernel-compat shim
.CW ( kshim.c ,
.CW kshim.h )
and a
.CW lib9p
front end
.CW ( main.c )
that turns each 9P request into the device's own Chan entry points and
its kernel-style error unwinding back into an Rerror.  The shim's
.CW attachscreen
hands the device the exposed
.CW framebuffer
segment as the screen's backing store, with
.CW softscreen
zero, so the compositing lands directly on the frame buffer and the
flush is a no-op.  Mounted at
.CW /dev ,
it makes
.CW /dev/draw ,
and a real
.CW libdraw
client -
.CW dtest.c ,
built on the disk against the disk's
.CW libdraw
\-
.CW initdraw s
through it and draws two rectangles that are on the screen.  The whole
draw stack is a user program above the microkernel; there is no kernel
graphics.  One porting gap had to be closed for it: the device never
calls
.CW memimageinit ,
which in the kernel is run from the port screen init, so the shared
images
.CW memopaque
and the rest stayed nil and
.CW memdraw
faulted on the first mask;
.CW main
now calls it before
.CW drawreset .
.PP
The mouse is a user-level driver of the same kind, and with it rio runs.
The kernel exposes the PS/2 aux byte stream the way it exposes the frame
buffer: a dedicated page holds a ring the IRQ12 handler fills, published
as the physical segment
.CW mousering
.CW ( ospreymouseexpose
in devosprey.c, run at init on the full personality; xup64 keeps its own
container path, so the two never both arm the interrupt).
.CW os/osprey/cmd/draw/mouse.c
segattaches that page, decodes the three-byte packets into an absolute
position and a button mask, and serves
.CW /dev/mouse
in the format
.CW libdraw
reads.  Nothing privileged is in the driver - it does no
.CW in
or
.CW out ,
only reads the exposed page - and nothing about the mouse is in the
kernel beyond filling the ring.  With
.CW /dev/draw
and
.CW /dev/mouse
both served from user space,
.CW rio
starts against them and paints its desktop on the exposed frame buffer,
and a right-click opens its menu: the Plan 9 window system running,
interactive, on a draw stack and an input driver that are ordinary
programs above the microkernel, no kernel graphics and no kernel mouse.
The whole event path is exercised end to end - a mouse move and a button
press become PS/2 bytes at the i8042, the kernel's aux interrupt writes
them into the exposed page, the driver decodes the packets and reports
the move and the button on
.CW /dev/mouse ,
and rio moves the cursor to where the move aimed and pops its
New/Resize/Move/Delete/Hide/Exit menu, whose text is drawn back through
the user-level draw server (so devdraw's font path runs too).  Carried
one step further, the same input path sweeps out a new window: select
New from the menu, press button 3 at one corner and release at the
other, and rio makes the window, spawns
.CW rc
in it, and draws the frame and the
.CW %
prompt - a usable terminal, swept and shelled entirely through the two
user-level drivers.  And it takes input: with rio run in the foreground
so it owns
.CW /dev/cons ,
a line typed on the console reaches the focused window, and
.CW echo
.CW hello
runs and prints its answer back into the window.  So the desktop is not
merely painted but worked: menu, window sweep, and an interactive shell
that executes what is typed, all above the microkernel with no kernel
graphics and no kernel mouse.  The three configs still check: pc64 58,
upc64 7, xup64 10.
.PP
The keyboard is a user-level driver of the same shape as the mouse.  The
kernel exposes the PS/2 scancode stream as a second physical segment,
.CW kbdring ,
programming the keyboard and aux interrupt-enable bits in one
command-byte write and arming IRQ1 and IRQ12 together;
.CW os/osprey/cmd/draw/kbd.c
maps it, tracks shift and control, translates set-1 scancodes through a
US keymap into runes, and serves
.CW /dev/kbd ,
which rio reads in preference to
.CW /dev/cons .
And the cursor, which the kernel would draw were there a mouse device,
is drawn by the one program that owns the screen: the draw server forks
a proc that reads the same
.CW mousering
and composites an arrow onto the frame buffer, a lock shared with the
draw path lifting it around every draw so the two never collide.  With
these the desktop is usable on its own - a live window (osprey-console's
.CW --display
.CW cocoa )
comes up with a tracking cursor, a terminal
.CW ( rio
.CW -i
.CW window )
and a keyboard that types into it.  So all three of display, pointer and
keyboard are user programs above the microkernel, and nothing of the
screen or the input hardware is in the kernel beyond exposing the frame
buffer and filling the two interrupt rings.
.PP
The second cut is the driver tasks, described above as the seL4 shape:
cons, uart and rtc leave the kernel and become tasks that hold an
interrupt and a mapping of their device's registers.  It is the larger
build because it needs the userland those tasks run in, and it is taken
up after the port-source cut is complete.
.NH 1
The gaps, by why they are gaps
.PP
Five kinds, and they are not equally hard.  The first cannot be closed
without writing a different kernel; the rest can be closed from here,
and two of them have been since this was written.
.NH 2
The microkernel, and a personality that is a library on it
.PP
This was written down as unreachable from a Plan 9 kernel: the
microkernel itself, a library operating system linked into the task that
uses it, and processes that share an address space migrating as a group.
Two of the three are now built.
.PP
The microkernel is
.CW upc64
and
.CW xup64 :
the Plan 9 kernel with its name space, process groups and file cluster
cut away, keeping the four services the talk keeps \- message passing,
the address space, interrupts and scheduling.  It boots into a user
task, not the Plan 9 shell, and the task reaches the kernel only through
a minimal syscall interface.  This is checked by
.CW /scripts/osprey-check-micro.py
and
.CW /scripts/osprey-check-user.py .
.PP
The library operating system is
.CW p964 ,
the same cut core carrying the Plan 9 file personality as a user
library.  The name-space machinery \-
.CW chan.c ,
.CW dev.c ,
.CW pgrp.c ,
.CW devroot.c ,
the same port sources the full kernel links \- is compiled as ordinary
user code behind a shim that supplies the locks, the error unwinding and
the allocation the kernel gave them, embedded in the task the
microkernel enters and linked with it.  On boot the task builds a name
space in user space, attaches the root device with
.CW namec ,
reads a directory through
.CW open
and
.CW read ,
then mounts a second device \- the environment,
.CW devenv.c
\- with
.CW cmount ,
writes a value into it, and opens
.CW /greeting ,
a name with no device prefix, which the union walk carries from the root
across the mount table into the environment device and reads the value
back.  Then it mounts a real 9P server: it attaches the mount device
.CW ( #M ,
.CW devmnt.c )
to a transport, which runs
.CW Tversion
and
.CW Tattach ,
mounts the server's root, and opens
.CW /hello ,
which
.CW devmnt
walks and reads over 9P \-
.CW Twalk ,
.CW Topen ,
.CW Tread
\- into the server; the resolved channel is served by the mount device,
not the transport, which is what proves 9P carried it.  The server is a
container of its own, delegated to over the microkernel ring: the
marshalling
.CW ( convS2M ,
.CW convM2S )
and the mount client are the kernel's own, the transport
.CW ( ring9p.c )
maps the container's ring with
.CW segattach
and carries each 9P message across it, and the server
.CW ( srv9p.c )
is a second user program in the file-server container that answers.  The
file's bytes are held only in that server binary, so reading them back
through
.CW /hello
is proof they crossed the ring.  Finally it reaches the name space the
way a program does: it opens
.CW /hello
and
.CW /greeting
by name and reads them by file descriptor, through the fd table
.CW ( Fgrp )
the file-descriptor layer keeps \- small integers, not held channels,
naming both the local file and the one the 9P server holds across the
ring, and lists the server's directory by descriptor - opening it,
reading it, and unpacking a 9P stat entry per file - the way ls does -
and it writes the server's one writable file and reads it back, a full
read-write round trip over the ring.  Finally it turns the relation
around: an exportfs
.CW ( p9srv.c )
answers 9P about this name space itself, walking and opening and reading
the channels its own fids stand for, and the personality mounts that
export and reads its own root directory back over 9P \- a loopback that
makes it a 9P server as well as a client.  The name space is built and
walked in the task's own address space, the kernel routing the 9P
messages and serving print and exit.  What moved to the right side of the
line is the name-space machinery, four sources \-
.CW chan.c ,
.CW dev.c ,
.CW pgrp.c ,
.CW devroot.c ,
.CW devenv.c ,
the pipe
.CW devpipe.c ,
the service registry
.CW devsrv.c ,
the mount client
.CW devmnt.c
and the queue
.CW qio.c
the file-descriptor layer
.CW ( p9file.c ,
the fd table and open/read/write/close/seek/stat/dup lifted from
.CW sysfile.c )
and an exportfs
.CW ( p9srv.c ,
the personality answering 9P about its own name space)
\- linked into the program rather than the kernel, with the ring
transport
.CW ( ring9p.c )
and the 9P server
.CW ( srv9p.c ,
in the file-server container) written beside them; the rest of the
syscall layer and the other devices are still on the other side.  This is checked by
.CW /scripts/osprey-check-p9.py .
.PP
What is real is a name space that mounts and names files a server holds
over real 9P: attach, walk, open, read, create, write, the union walk and
now
.CW cmount
with
.CW devmnt
and
.CW convS2M / convM2S
\- the file personality naming a server's files, over 9P that crosses
the microkernel ring to a container of its own.  This is the plan's
picture: a library operating system on the microkernel, naming the files
of a buddy that answers over message passing, the kernel only routing.
A program reaches all of it by file descriptor now, through the fd table,
the way a Plan 9 program does \- opening, reading, writing, seeking,
stat-ing, listing, creating, binding and duplicating a descriptor, over
local files and files a 9P server holds alike, and the name space carries a pipe as well as files,
two ends of a channel a program writes and reads.  A program can post a
channel to
.CW /srv
by name and another find and mount it there, the way Plan 9 servers
announce themselves - the personality posts its own exportfs and mounts
it back by name.  What is not yet real is breadth, not
structure: the served tree is a handful of files, one of them writable -
listed, read and written, but small; the union directory read is ported
in its plain form (the rock fixup, which rewrites an entry that is itself
a mount point, is stubbed), so ls of "/" composes the root device, the
environment and the 9P mount but would not reflect a mount made on one of
their entries; the ring's data area is about nine kilobytes and today's messages
are tens of bytes, so a larger tree would want the transport to page a
big read rather than assume one fits; the file syscalls exported back as a 9P server the personality offers to
others are built as an exportfs but shown only as a loopback \- the
personality mounting its own export \- not yet reached by a client in a
container of its own over the ring; and the third of the three unreachable
things \- processes that share an address space migrating as a group \-
is not begun.  What was unreachable from a Plan 9 kernel is reached by
not running on one: the kernel is cut to the microkernel, and the
personality is a library the task links.
.PP
And there are two of them now.  The
.CW p9pair
configuration runs the personality in two containers at once: one the
client, one the server, the client delegating to the server so its 9P
crosses the ring.  The server
.CW ( p9pairsrv.c )
brings up its own name space, then answers 9P about it \- the exportfs
over the ring rather than the loopback \- for the client, which mounts it
and reads its exported root.  One library operating system names another's
files by message passing, the kernel only routing them: the client's
server is a second library OS in a container of its own, not the Plan 9
kernel answering for it as on pc64, nor a loopback within one task.  This
is the paper's structure \- a microkernel with library operating systems
on top \- with two of them, one delegating file operations it does not
answer itself to the other, one-directional (the client mounts the
server, not the reverse).  It is not the paper's
.I buddyOS ,
which is a different mechanism and a different shape.  The paper's buddy
operating system is a
.I per-process
peer: one legacy binary is associated with one buddy process that
interposes on that binary's own system traps \- its system calls and its
page faults \- and emulates a legacy OS for it, giving it
.CW /dev
and
.CW /proc .
That is the recursive, user-level-virtual-machine interposition of vx32
and the Fluke nested process, not a single personality server that many
clients call; the paper grounds it in Wine, a per-application emulator of
an unmodified binary.  p9pair is the opposite shape \- a shared file
server two library OSes talk through \- and so is nothing like a buddyOS;
the per-process trap-interposing buddy is unbuilt.  What p9pair is, is the
library-OS mechanism the paper lists beside legacy emulation.  It is checked by
.CW /scripts/osprey-check-p9pair.py .
The one constraint it obeys is the reason it is two containers and not
one: a container has a single server it delegates to, and its request
ring cannot carry both its own outgoing requests and a client's incoming
ones, so the client is pure client and the server pure server.
.PP
And the buddy operating system the paper names \- the other kind, that
runs an unmodified legacy binary and answers its traps \- is built too,
for the Plan 9 system-call ABI.  The
.CW p9buddy
configuration runs an ordinary Plan 9 program
.CW ( legacyp9.c )
in one container: it opens and reads a file with the plain library,
trapping in the Plan 9 ABI, and knows nothing of the microkernel or a
peer.  Those calls are not implemented in the kernel; in
.CW dosyscall 's
otherwise-unimplemented path
.CW ( ospreybuddyforward )
the kernel, running as the legacy process, copies the call's pointer
arguments through the container's own data area, forwards the call over
the ring to a peer personality, waits for it to answer, and copies any
read bytes back.  The peer
.CW ( p9buddy.c
against the name space and the descriptor layer) emulates open, read,
close and the rest and holds the descriptor table that stands for the
legacy process's.  On boot the legacy program opens the root, reads it,
and closes it, every file trap answered by the peer and none by the
kernel.  This is the paper's per-process interposition \- vx32 and Fluke,
not a shared server \- with system calls interposed, and, since the
paragraph on exec below, page faults too: the Plan 9 binary is
.CW /boot/legacy
in the buddy's file system, laid out by it as an a.out and paged in
seven faults.  It is checked by
.CW /scripts/osprey-check-p9buddy.py .
.PP
The same buddy now serves the Linux ABI, which is the author's "plan9 to
start then linux".  The
.CW p9linux
configuration runs an unmodified, statically linked Linux x86-64 binary
.CW ( os/osprey/cmd/p9/linuxlegacy.c ,
built by clang for Linux with raw system calls and no libc, embedded
whole as an ELF).  The kernel's ELF loader
.CW ( ospreyloadelf
in
.CW os/osprey/port/userinit.c )
maps each program header at its own address and
.CW touserat
(l.s) enters at
.CW e_entry
with a System V stack.  The binary's calls arrive in the Linux
convention \- number in ax, arguments in di, si, dx, r10, r8, r9, cx
and r11 clobbered, every other register preserved \- and that last
clause was the piece that stood in the way: the Plan 9 SYSCALL entry
.CW ( syscallentry
in
.CW os/osprey/pc64/l.s )
clobbered ax to load m, saved only bp, r14 and r15, and returned
nothing else, so the number the kernel read was m's address and a
Linux binary's callee-saved registers came back as whatever the kernel
had left in them.  The entry now arrives with no register free and
switches stacks through memory instead: the user sp is parked in a
word of a per-processor block the GS base names
.CW ( Gsblock
in
.CW os/osprey/pc64/dat.h ,
m at offset 0 as the assembly has always read it, the parked sp at 8),
sp itself is the scratch register that loads m and then m->proc, and
once on the kernel stack every register is stored into the Ureg;
.CW forkret
restores every one.  The Plan 9 ABI needs none of it and loses
nothing, and every other configuration is checked unchanged below.
.CW syscall()
in
.CW os/osprey/pc64/trap.c
reads the Linux convention out of the Ureg for a process marked
.CW oslinux ;
.CW dosyscall
answers Linux write to the console and exit itself, and
.CW ospreybuddyforward
maps open, read, close and lseek to their Plan 9 numbers and forwards
them to the buddy exactly as for the Plan 9 binary.  On boot the Linux
program opens the root, reads 470 bytes of it, closes it, checks that
rbx survived every trap, and exits through Linux exit(2).  One bug was
the program's own, and a real Linux would have killed it the same way:
a C-language
.CW _start
assumes a function's frame (sp 8 mod 16, as a call leaves it) where the
kernel enters with sp 16-aligned, and clang's first aligned SSE store
faulted; the program has the assembly entry a nolibc program is meant
to have.
.PP
Its page faults are the buddy's too, which is the other half of what
the paper's buddy interposes on.  The kernel no longer carries the
Linux binary at all: it is a file in the buddy's own file system,
.CW /boot/linux ,
embedded in the personality the way a kernel embeds its boot files
.CW ( os/osprey/cmd/p9/p9linuxfile.c ).
At boot the kernel, running as the legacy process, asks the buddy to
exec it
.CW ( ospreybuddyexec
in
.CW os/osprey/port/devosprey.c ):
the buddy opens the file in its own name space, reads the ELF and
program headers, keeps the loadable ones, and answers with the entry
and each segment's address, size and flags, from which the kernel makes
segments with no page in them
.CW ( ospreyexeclinux
in
.CW os/osprey/port/userinit.c ).
The first touch of every page is then a fault, and
.CW faultamd64
in
.CW os/osprey/pc64/trap.c
takes a legacy process's fault to
.CW ospreybuddyfault
before the kernel's own demand loader sees it: the kernel allocates the
frame, asks the buddy for the page, and the buddy fills the data area
with the file's bytes where the image has them and zero where it has
none
.CW ( p9buddy.c 's
.CW PAGE );
the kernel copies it in, hangs it on the segment, and maps it.  That
holds whether the process touched the page or the kernel did on its
behalf, reading a system call's argument out of it, which is how the
first fault actually arrives: the program's first act is a write whose
string sits in a page nobody has supplied yet, and it is the kernel's
.CW validaddr
that faults.  A fault on the stack, or on a page already present, is
the kernel's as for any process; a fault on a page the buddy has not
got is the process's own bad address.  On boot the buddy lays the
binary out (entry
.CW 0x401000 ,
four loadable segments), supplies its text, its read-only data and its
bss one fault each, and then serves the file calls as before.  The data
area a container's requests carry their bytes in was smaller than a
page plus the offset the data starts at, so
.CW ospreyinit
sizes it to two pages for this configuration, through the same
.CW ospreysetsize
that
.CW plan9.ini
reaches.
.PP
The rest of what item 2 of the survey asked for is built on the same
machinery.  A file mapping \-
.CW mmap
with a descriptor \- is a data segment whose pages the buddy reads from
the file at the offset
.CW ( MAPPAGE ,
the image's page path with an offset; the kernel keeps the mapping in
the Proc and
.CW ospreybuddyfault
asks for the file's page instead of the image's), private, so a page
is the process's own copy; the program maps the first page of
.CW /boot/linux
and reads its own ELF magic out of it.  The process's descriptors are
its own numbers now, kept by the buddy apart from its own: 0, 1 and 2
are the console, which the personality has no file for, so a read
there is end of file and a write goes out the way the personality's own
prints do, and
.CW open
hands back the process's number, not the buddy's.  And a fault the
buddy declines is SIGSEGV.
.CW rt_sigaction
registers the handler and the restorer a libc always supplies (the
kernel puts no trampoline on the stack, so a registration without one
is refused);
.CW ospreylinuxsignal
in
.CW os/osprey/pc64/trap.c
saves the trap frame, puts a siginfo with the address at its Linux
offset and a ucontext (present, zero: a handler that reads registers
out of it sees zeros) on the stack below the red zone, pushes the
restorer as the handler's return address, and points the frame at the
handler with the System V arguments;
.CW rt_sigreturn
puts the saved frame back, so the faulting instruction is retried.
The program's handler maps the page the fault named
.CW ( MAP_FIXED
is honoured for it) and returns, and the store that faulted goes
through.  A process with no handler, or one that faults in its handler,
is killed with status 139, the 128 plus the signal Linux gives, and its
parent's wait sees that.  A Plan 9 program's declined fault is now the
same shape: its
.CW donotify ,
once a stub that panicked, delivers the note to the program's
.CW notify (2)
handler if it registered one \- the microkernel's own
.CW notify()
frame builder points the frame at the handler with the note message, the
same machinery a full Plan 9 kernel uses \- and otherwise kills the
container cleanly, its parent's wait seeing a non-zero status.  The
handler catches the fault and exits; the
.CW noted (2)
continuation that resumes the interrupted instruction is not built, since
a bad-address fault cannot exercise it.
.PP
Memory is the kernel's to give, and the Linux calls that ask for it are
answered there rather than forwarded: they are the microkernel's
address-space service, not a file the buddy holds.
.CW brk
moves the top of a heap segment exec placed a page above the image
(the kernel's own
.CW ibrk ,
demand-zero, so a fresh page reads as zero); anonymous private
.CW mmap
makes a demand-zero segment at the next free address from 1 TB up,
and
.CW munmap
detaches the segment mmap made at exactly that address
.CW ( ospreylinuxbrk ,
.CW ospreylinuxmmap ,
.CW ospreylinuxmunmap
in
.CW os/osprey/port/userinit.c ,
reached from
.CW dosyscall
in the
.CW p9linux
configuration).  A file mapping is refused, and errors are the negative
errno Linux uses.  The program grows its break by 64 KB, checks the
pages read as zero and hold what it writes, maps two pages, writes both
ends and unmaps them.  Two things on the way were not kernel bugs and
are worth writing down.  A 40-bit constant in an enum is an int in this
compiler and came out zero, so the mmap base is a define; and this
kernel's
.CW %p
prints the low thirty-two bits of a pointer, because the shared
.CW libkern/dofmt.c
takes the pointer as a
.CW ulong
- the idiom AGENTS.md describes - which made a mapping at 1 TB look
like one at zero until the prints were changed to
.CW %llux .
It is checked by
.CW /scripts/osprey-check-p9linux.py .
.PP
A program can now be started at run time, which is the first item of
the survey's list and the one the rest stood on.  A container puts a
name in its data area and submits
.B exec
(the request
.CW ReqExec
in
.CW os/osprey/policy/syscall.h ,
appended after
.CW gone ).
The adapter's dispatcher hands it to the kernel
.CW ( ospreyexeckern
in
.CW os/osprey/port/devosprey.c ),
which makes a container of its own for the program, delegates it to the
caller's server, and gives it a kernel process that binds to it, asks
that server to lay the named file out
.CW ( ospreyexecbuddy
in
.CW os/osprey/port/userinit.c ,
the Linux buddy's exec made general), and enters user mode at its entry;
the program's pages and system calls are the server's from then on,
exactly as p9linux's are.  The reply is the new container's identity.
.B wait ,
which the man page said nobody answered, is answered by the kernel:
now, with the status, if a child of the caller has exited, and when it
exits otherwise \- the dispatcher returns as if a server were answering
and the kernel puts the reply on the caller's ring itself
.CW ( ospreyreplylater
in
.CW os/osprey/adapter/ospreyrt.c )
from the child's exit.  A program exec started ends when it exits
.CW ( ospreyexits ):
its parent told, its container taken apart the way the exit control
message takes one apart, its server told
.B gone
so it lets go of the image it held.  The boot program's exit idles the
machine as before.  The Linux system-call path
.CW ( ospreylinuxsyscall )
moved out of the p9linux configuration into the port, since any
personality configuration can now be asked to run one, and brk's heap
and mmap's cursor moved from statics into the Proc, since there can be
more than one.  The server side had two consequences.  A server answers
for the container it was started with and for every container the
kernel exec'd and delegated to it, so
.CW p9pairsrv.c
maps the slice of whichever container a request names, finding it by
reading the identity in each slice it is allowed to map; and the buddy
keeps an image per container, not one.  The request numbers the
personalities used on the ring for 9P and forwarded system calls were
4 and 6, which are
.B wait
and
.B recv
in the list, and had passed only because nothing answered those; they
are 14 and 15 now, above every request the list names.
.PP
p9pair shows it: after the client personality has read the server's
exported root over the ring, it execs
.CW /boot/linux ,
the server's own copy of the Linux binary, and waits.  The kernel
reports container 100 starting it for container 1, served by container
3; the server lays it out and pages it in; the program's file calls,
brk and mmap are answered; it exits with status 0 and the client's wait
returns that status.  Three containers, the third started by a request
rather than by the boot.
.PP
The buddy lays out a Plan 9 a.out as well, so the kernel carries neither
legacy binary now: the eight big-endian words of the header say where
the text, data and bss go (the same places the kernel's own loader put
them: text with its header at UTZERO, data on the next page, bss after
it), and the buddy presents those as three loadable pieces of the same
shape an ELF's program headers take, so the kernel has one loader and
one pager for both kinds and only the entry differs \- an ELF is
entered at
.CW e_entry
the Linux way, an a.out at
.CW UTZERO+0x28
the Plan 9 way with argv0 on the stack.  p9buddy's own boot execs
.CW /boot/legacy
this way (seven pages, one fault each, then open, read, close and exit
through the buddy), and p9pair execs both binaries in turn and waits
for each.  Two things this found: the fault hook in
.CW faultamd64
was gated on the process being Linux, so an a.out's first instruction
fetch went to the kernel's own demand loader and died in
.CW pio
on a nil image (a process now carries
.CW buddyimage ,
set for either kind); and the server's cache of which slot held which
container went stale the moment a slot was reused, so the second exec
was answered with the server's "no such slice" code, which the kernel
read as a two-segment layout \- identities are read from the map every
time now, and that refusal is -1, a count no layout can have.  What
exec does not do yet: run a program whose ABI needs more of the buddy
than the file calls, brk and mmap \- the real
.CW p9srv
is such a program; and it is a request on one machine, not the talk's
remote invocation, which is this request carried over the wire.  Checked
by
.CW /scripts/osprey-check-p9pair.py .
.PP
The first of the storage pieces the survey's item 3 asks for is built
on p9pair too: a block device driven by a task above the kernel.  The
kernel's part is what a kernel must do and no more
.CW ( ospreyblkexpose
in
.CW os/osprey/port/devosprey.c ):
it finds a virtio 1.0 block device with the legacy interface off, so
every register is memory; publishes the BAR the registers live in as
the physical segment
.CW virtioblk ,
uncached; reads the four virtio-pci capabilities \- PCI configuration
space, which a container is not given \- and writes their offsets, the
notify multiplier, the physical address of the container's own slice
and the number of a semaphore into a descriptor at
.CW Ospreyblkoff
in the server personality's data area
.CW ( Ospreyblk
in
.CW os/osprey/port/ospreyabi.h );
and turns the device's interrupt into that semaphore, the handler
reading the interrupt status to drop the line and giving the semaphore,
the way the keyboard's does.  Everything else is a program
.CW ( os/osprey/cmd/p9/blkvirtio.c ,
compiled against the user headers, in the server personality): the
reset and feature dance, a queue of eight kept in the container's own
data area at
.CW Ospreyblkring
and handed to the device by physical address, a request as three
chained descriptors \- header, sector, status \- the notify, and a
select on the semaphore for each completion, which is exactly the wait
the talk's uart task does on its interrupt.  When the server comes up
with a device exposed it reads sector 0 and prints the text the host
put there, writes a stamp to sector 1 and reads it back, three
requests and three completions taken through the semaphore; and the
check reads sector 1 of the image on the host afterwards and finds the
stamp, so a write from a program above the microkernel reached the
disk.  The harness attaches the image with
.CW --blk
(a virtio-blk-pci device with
.CW disable-legacy=on ),
and that run is made without QEMU's snapshot, or the write would be
thrown away.  This is the eMMC/SD tier of the plan's storage section
as far as the block device: what the adapter exposes upward is block
read and write.
.PP
The file system on it is built, and it is the shape the plan's storage
section says storage on this system should have: a log
.CW ( os/osprey/cmd/p9/devlfs.c ,
the device
.CW #l
in the server personality's name space, reaching the driver through
three plain-typed calls).  A file's version is one record \- a header
sector naming the file, its version and its length, then its data in
the sectors after it \- appended at the head of the log and never
changed: a version is immutable once written, and it is written when
the file is closed, which is what slide 19 says of every file and what
the plan says \[*p]p wants of storage.  Mounting is a scan of the log
from sector 1 to the first sector that is not a record, taking each
file's latest version as it goes; nothing is written in place, so a
power loss leaves a log one record shorter, never a torn file.  The
server personality mounts it at
.CW /n
with
.CW MCREATE ,
and on a fresh disk creates
.CW hello
as version 1; the client personality walks to it through the mounted
root over 9P across the ring, reads it, writes it, and the clunk
commits version 2 to the disk over there; and a second boot on the same
image finds two records and the file at version 2 with the client's
text.  Two things had to move for it: the 9P exporter walked with
mounts turned off, so nothing a personality mounted was part of what it
exported, and now follows them, which is what an exportfs does; and the
block driver's own demonstration wrote sector 1, the log's first
record, so it writes the last sector instead.  What is not built: the
exporter answers no create or remove over 9P, so a client can rewrite a
file the server made but not make one; a version is at most 8 KB and
there are thirty-two files, and a removed file is not a tombstone yet.
.PP
Reclamation is built, and it is what the plan's storage section asks
of it: a scheduled task with a reservation of its own.  The log is a
ring now: the oldest record is copied to the head if it is the latest
version of its file and dropped if it is not, and the start moves past
it, so the space comes round to be written again; sector 0 holds a
checkpoint \- start, head, record number \- rewritten in place after
every commit and every step, the one sector written in place, and a
disk without one is scanned from sector 1 as before.  A step is taken
on the clock tick when the log is more than half full, and by a writer
that finds no room, so that normally the storage task's reservation
pays for it and only a full log costs the writer.  The task says what it
needs: two requests were added to the list
.CW ( ReqReserve ,
.CW ReqTick
in
.CW os/osprey/policy/syscall.h ),
the first setting the caller's budget and period in microseconds, which
the device converts to the counter the scheduler keeps time in, the
second giving the caller's semaphore on every clock tick, the
interrupt-to-task path.  The server personality asks for 2 ms of every
10 ms and the tick on its second semaphore, and its select waits on the
tick before the ring, since under a stream of requests the ring is
always ready and a tick that came second would never be taken.  This
found a structural fact about the rings that the earlier work had not
needed: a server's request ring carries its clients' requests and its
reply ring its answers to them, so a server has no ring of its own to
ask the kernel on, and the kernel's service path used to take the next
message on a server's request ring \- a client's 9P \- as the server's
own, which sent the client's request through the kernel's personality
and crashed the client.  The service path leaves a server's ring to the
server's program now
.CW ( ospreyisserver ),
and a task's own asks are a system call
.CW ( ospreyxcall ,
number 60, above the Plan 9 table: the first try reused PREAD, and an
unmodified Plan 9 binary's read is pread, so the buddy's legacy program
lost its read until the number moved),
put to the dispatcher directly and answered at once.  On a 64-sector
image the client writes forty-one versions, more than the 61-sector log
holds, and every reclaim step \- 28 in the first boot, 41 in the second
\- ran on the tick, none on a writer; the second boot reads the
checkpoint, finds the wrapped log with the file at version 42, and goes
on.  When the boot program exits the kernel prints every container's
line of status, which is the talk's dumptask: the storage task's
reservation, what it used of it, its best-effort time beyond it and
the periods it was seen in.  Seen is the word: a container is charged
when its process is the one running at a clock tick, so a task that
runs in short bursts between selects is charged in samples, and the
figures are what the samples caught.  Setting a reservation starts the
period's accounting afresh, since what was used of the old one is not
owed against the new.
.PP
And the file is reached over \[*p]p, which is the first half of the
survey's item 4.  The kernel speaks \[*p]p about containers; the server
personality now speaks it about its files
.CW ( os/osprey/cmd/p9/pipfsrv.c ,
the grammar of
.I pip (5)
served over the name space the way
.CW p9srv.c
serves 9P over it, carried on the ring as a second op beside 9P's).  A
fid names a file opened in that name space; its attributes are
.CW * ,
.CW data ,
.CW version ,
.CW length
and
.CW name ;
a write to
.CW data
makes the version the fid is making, which a read through that fid
sees and a read through any other does not, and the close commits it
as a whole by writing the file anew \- on the store, one new record \-
refusing a fid whose file has been committed over since it was opened.
Leases are counted in the server task's clock ticks.  The root fid's
.CW *
is the root directory's names.  The client sends one group \- a
session, an open of
.CW /n/hello ,
a read of
.CW * ,
a read of
.CW data ,
a write, a close \- and gets six replies in one round trip: the open at
version 2, the write making version 3 that is nobody else's until the
close, the close committing version 3 (the store's record of it right
after); then a second group resumes the session by its number and reads
version 3's data.  Streams and tickets are answered as what they are
here: no wire to stream on, no key to check a ticket against.  What is
not built: the personality's \[*p]p on a wire of its own (the kernel's
is).  Checked, with a second boot, by
.CW /scripts/osprey-check-p9pair.py .
.PP
The second half of item 4 is the talk's slide 20 itself: the uart as a
\[*p]p thing, its attributes read and written by name and answered by
the driver task.  On pc64 a uart a container has been given is a thing
the kernel's \[*p]p walks to by the uart's own name
.CW ( pipwalkuart
in
.CW os/osprey/port/devosprey.c ,
beside the numbered containers).  Its attributes are
.CW * ,
which lists them,
.CW b ,
the line speed,
.CW d ,
the data, and
.CW name .
A read of
.CW d
is what the uart has received, as much as is there, without waiting.
A write to
.CW d
is staged in the container's data area and put on the container's
output queue, exactly as the
.CW output
control message puts work there, so it goes out through the driver
task's third arm and the transmitter, and a write to
.CW b
is the control message the task answers by setting the speed.  A uart
is not a file: its version is 0 and its close commits nothing.  The
check on pc64 opens
.CW /eia1
over
.CW #O/pip ,
reads
.CW * ,
.CW b
and
.CW name ,
writes
.CW d ,
and the bytes leave the machine on the second serial line, where the
harness reads them.  Only what a uart here has is offered: the talk's
uart listed twenty attributes, of which this one has the speed and the
data.
.PP
Item 5 begins where Cut B's record says it picks up: the uart task on
the microkernel, which drove the second serial port to send-complete
and got no byte out of it.  Two causes, both found by building rather
than guessing.  The port had never been enabled the device's way: the
control message's hand-over called the uart's task-enable, which
programs the FIFO, the interrupt enable and the modem lines, but never
the line format or the speed, which the device layer's
.CW uartenable
sets when a port is first opened and which the direct bind skipped; on
pc64 the port had been through that, on the microkernel nothing had
opened it.  The hand-over
.CW ( ospreyuartbind
in
.CW os/osprey/port/devosprey.c ,
factored out of the control message so a boot can call it) enables the
uart the device's way first.  And a container has one select and one
arm area: the uart task and the server personality both selected
through the server's, which the kernel reported as a double sleep and
which took the client down with a corrupted return.  The uart now has
a container of its own, made at boot, whose task is the driver, and
that container is delegated to the server, so the server may map its
slice and put work on its output queue \- a place in that slice and how
much of it, no trap \- which is how a driver task is given work.  The
server personality does that with one line as it comes up, and the
line leaves the machine on the second serial port, where the pair
check's reader on the host finds it.  .PP
The console follows: on the microkernel every print, the kernel's own
and the tasks', now goes through a console task, which is the second
cut's harder half because a kernel with no way to say anything is a
kernel that cannot report a fault.  A container of its own
.CW ( Consid ,
made at boot) holds the console uart, its uart task the console driver;
.CW putstrn0
in
.CW os/osprey/port/devcons.c
hands each line to
.CW consoletask ,
which stages it in that container's data area and puts it on the
container's output queue, in order, one slot per piece with a slot more
than the queue holds so nothing in flight is overwritten.  The kernel
writes the port itself only where the task cannot serve: a panic (the
.CW panicking
flag routes around the task), before the task exists, or with the queue
full, and then through the bare polled
.CW kdebugputc
seL4 keeps for exactly this.  A boot shows every line of its own output
arriving through the task and none going straight to the port, and at
the end says how many bytes went each way.  The console uart is given
up by the kernel to make this
.CW ( ospreyuartbind
with its take-console argument clears
.CW serialoq
and the uart's console flag), which is the kernel handing out the one
device losing it would be fatal, on purpose, because the task and the
panic path are both proven first.  What remains of item 5 is the clock,
whose interrupt still does the container accounting itself before giving
the tick to whoever asked, and the register primitives the tasks call,
which stay in the kernel by design \- the driver policy is what moved
out, not the thin register access, which is the shape this kernel chose
over mapping registers into a task that then cannot migrate.
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
A class of bug worth naming, and closed
.PP
The container may write every byte of its own map, which is why
.CW mapfix
exists and rewrites the whole of it from the kernel's own constants
before it is used.  This document used to say that of the readers in
.CW os/osprey/adapter/ospreyrt.c ,
two \-
.CW ospreydataoffset
and
.CW ospreydatalen
\- were safe only because their callers happened to call
.CW ospreydata ,
which does fix the map, first: the same accident that let
.CW ospreymapsizes
work for as long as it did and left
.CW ospreytxsizes
failing the moment it was written.  They call it themselves now, and a
sweep of every function in the file that reads through
.CW p->map
says none is left without it.
.PP
It was not a hypothetical.
.CW status
prints what
.CW ospreydataoffset
returns, and a server reads
.CW status
for a container's slice precisely so as not to believe that container's
own map \- so without the fix a container could scribble a false data
offset into its map and have the kernel repeat it back as its own
account.  Written to and then asked, the machine said
.CW "data 7122474062569137221"
where the truth was 3648.
.PP
Proving that took two goes, and the second found something worse than
the bug.  The check compares what
.CW status
says before and after the scribble, and it passed with the fault put
back in.  It was not the check: the harness reads everything between a
check's markers, and the console echoes each command, so the word
.CW unmoved
in
.CW "if(~ $d1 $d2) echo unmoved"
matched the command rather than the answer.  That is the second line in
this file to have passed that way, so the harness takes the commands out
of what it reads now \- by what was typed, not by the prompt they follow,
because a background job's output arrives on the same console line as the
next prompt and dropping whole prompt lines dropped that too.  With the
commands gone and the fault in, the line fails, which is what a check is
for.
.PP
And the other two harnesses read their logs the same way, so they were
asked the same question mechanically: which of the strings a check looks
for also appears in a command it sent.  Three did \-
.CW Rread
and
.CW Rauth
on the wire, and
.CW 10.9.0.1
in the network check, whose arp section runs on to an
.CW ip/ping
naming that very address.  All three still pass with the commands taken
out, so none of them was hiding a failure; but a line that would pass
whatever the machine did is not a line worth having, and all three
harnesses take the commands out now.
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
above it.  The larger part of this tree is a Plan 9 kernel with an
Osprey policy layer inside it, which follows the contracts rather than
the structure and says so.  Beside it now stands the structure itself:
.CW upc64
and
.CW xup64
are the kernel cut to the microkernel, and
.CW p964
runs the Plan 9 file personality as a library linked into the task on
it, building its name space in user space.  Two of the three things once
written down here as reachable only by writing a different kernel -- the
microkernel, and a library operating system linked into the task that
uses it -- are built; the third, processes that share an address space
migrating as a group, is not begun, and the personality the library
carries is a name space and a directory read, not yet the breadth of the
file operations.
.PP
The plan's other name for what sits beside a library OS is a
.I buddy
operating system, and that is built in both the senses the plan uses.
On pc64, what a container asks for and the policy layer cannot answer
is answered by the Plan 9 kernel around it, or by a user-level server
the container has named: a buddy in the sense of answering for the
parts a task has not brought with it.  On the microkernel,
.CW p9buddy
and
.CW p9linux
are the per-process buddy the paper means: an unmodified legacy binary,
Plan 9 or Linux, whose own system traps a peer personality answers.
For the Linux binary the buddy is loader and pager as well: the binary
is a file in the buddy's file system and every page of it arrives by a
fault the buddy answers.  What that buddy does not yet do is take the
Plan 9 binary's page faults the same way, and what it maps is the
handful of file calls the demonstration makes.
