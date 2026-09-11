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
happen.  The personality's \[*p]p about its files is on a wire of its
own as well: a TCP connection between two containers' stacks across the
ring, on which a session outlives its connection and a stream's frames
come at their rate.
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
.B "Resume, and migration."
A running process is carried into a container of its own with its
registers, stack, data, open files and name space, and the container it
came from is destroyed: it goes on from the call, in the new container,
rather than starting again, and the processes that share its address
space are stopped and carried along with it as a group.  And over a
wire: its segments, register frame and every resident page are pulled
out of the kernel by its server, carried in a TCP connection between two
personalities' stacks on two machines, and pushed into a process the far
kernel makes, which resumes from the same instruction with the same
stack; the container it left is destroyed; and the processes sharing
its address space are stopped and carried after it, sharing the arrived
memory there.  Open files do not cross.
.PP
.B "The real wire, driven from user space."
The kernel exposes a virtio network device to the server container the
way it exposes the block device \- the register BAR as a segment, the
interrupt as a semaphore, nothing more \- and a driver in the
personality brings it up and runs its queues in the container's own
slice; the real Plan 9 stack binds an ethernet medium on that driver.
Two such machines on one cable talk: ARP, a TCP handshake and a line
each way, two tcp.c's in two user-space personalities on two machines,
the kernels carrying interrupts and nothing else.
.PP
.B "Dynamic replicated data."
A replica of a file in another container follows a stream of the file's
committed version over the \[*p]p wire, answers reads from its copy while
the version stands, and refetches within a period when another path
writes the file.  And the caching file system: a device in the client
personality, bound over
.CW /n ,
answers an open of a name from a copy of the server's file, fetched
over the wire on the first open and kept current by the same stream.
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
.CW scripts/osprey-check-all.sh
builds every configuration and runs every check, one after another,
because a list kept in someone's head is not a list.  Fourteen of them:
.CW osprey-check.py
boots one kernel;
.CW osprey-check-wire.py
boots two on one wire;
.CW osprey-check-net.py
boots two more and pings a container's own protocol stack from the
second;
.CW osprey-check-p9wire.py
boots two microkernels on one cable with the real stack in user space on
each and carries a process from each to the other; and the rest ask for
the personalities, the window system, the keyboard and the rest of what
is below.  Each says
.B ok
or
.B FAIL
a line at a time, and the sweep prints a tally per check.
.PP
364 lines against the kernel this file describes, and eight more from
the two that build rather than boot \- the 9front userland this tree
builds itself, and the policy layer for 386 and riscv64.  All
.BR ok ,
on the sweep of 11 September 2026.
.PP
The count is given as of a run rather than as a property, and the
reason is worth one paragraph.  An earlier sweep the same day lost a
line to the console rather than to what it checks: the personality's
fault line and a program's output reach the same serial port by two
paths and one cut the other in half, leaving
.CW "osprey: fault at uscat: started wer pc 0x2000f7, inside ..." ,
which the criterion that reads that line could not find.  About one
boot in three has a cut line somewhere.  The section on the console as
a task says what is left of that and why a lock does not close it.  A
tally is a measurement of a run, and a run of three hundred and
sixty-four things on an emulated machine is not a proof that will
repeat exactly; what it is proof of is that every one of them passed
when it was asked.
.NH 1
Next, in order
.PP
Surveyed again on 2 September 2026 against both sources \- the talk
slide by slide, and the plan section by section \- and against the
tree, not the earlier record of it, and worked through on 4 September
2026: each item below carries what was built against it that day and
checked on a booted kernel.  What the sources describe that is built
and checked is in the sections below.  What follows is everything
either source describes, or the built parts imply, in the order it
was done, each item ending with what of it, if anything, remains.
Read on 4 September, and worked through again on 5 September as the
demonstration items below were made real, what remains across all of
them is of two kinds.  Board-bound, wanting a board this tree has no
Osprey target for: the raw-flash tier of item 3, a non-amd64 second
machine for item 9 (the second machine itself is real now \- two amd64
kernels on a socket cable, each driving a user-space virtio-net device,
running tcp.c to tcp.c and migrating a process between them, twenty
criteria of
.CW osprey-check-p9wire ),
and the hardware figure of the talk's number, item 10.  Structural: the
talk's 270-nanosecond round trip, item 10, needs a task that is not a
Plan 9 process, which this kernel's is (the microkernel number is
measured, 56 \(mcs a request between two personalities under QEMU after
the demonstrations' item 2, but that is a Proc waking a Proc, not a
task).  The other half of that sentence is closed: rio runs on the
microkernel itself now, on the
.CW p964
library personality, which has exec, the name space, processes, a
window and input (phase 3.2), and which serves the system calls of an
ordinary Plan 9 binary that was not built for it (phase 3.3) \- so the
personality runs executables and not only programs linked against it.
What a library operating system still cannot do for a program is split
the program's own flow of control:
.CW rfork(RFPROC)
is refused by name, which is why rio on
.CW p964
is rio relinked against the library rather than rio unmodified.  Slide 15 \- processes sharing an address space
migrating as a group \- is whole, on one machine and across a wire, and
the migrated process carries its descriptor table and its private name
space with it.
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
buddy, and stat it \- by descriptor and by name both; remove is
forwarded, and the store takes it now (the section on storage says what
a remove is there: a tombstone at the head of the log).  And errstr
crosses, genuinely: the buddy stashes the real reason a call failed,
per container, and answers the process's
.CW errstr
from it \- so a remove of a name that is not there leaves the program
not a lie but
.CW "file does not exist" ,
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
name-space calls and the fault are all answered now, and so is the
.CW noted (2)
continuation, the last of the ABI: the configs carry
.CW xnoted
(the cut
.CW sysproc.c 's
.CW sysnoted ,
which restores the register frame
.CW notify()
saved on the program's stack and, for
.CW NCONT ,
resumes the interrupted instruction), and since a fault cannot exercise
it \- the address is still bad \- the kernel posts a note by request
.CW ( ReqNote ,
an
.CW ospreyxcall ),
delivered to the handler on the way back from the call.  The legacy
binary's handler continues with
.CW NCONT
for a note that is not a fault and exits for one that is, and the
program prints from the instruction after the call.  Two things were
found on the way: the config generator drops preprocessor lines from a
config's C, so the frame check that needs
.CW sizeof(Ureg)
is an arch helper
.CW ( uregok
in
.CW os/osprey/pc64/trap.c );
and the stock
.CW fpunoted
reads the saved FPU state of a process that never used the FPU and has
none, which the cut caller assumed \- a kernel fault at 0x340 \- so it
is guarded.  The per-container name space is the buddy's; the other half of item 6, a
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
attribute answered by the driver task.  The personality's \[*p]p is on a wire of
its own now, too.  With a real stack in each of two containers over the
ring (item 7a), the server personality's \[*p]p
.CW ( pipfsrv.c )
is spoken on a TCP connection between them \- port 9001 of stack B,
answered by a kproc,
.CW pipwire
in
.CW os/osprey/cmd/p9/p9ip.c ,
each group and each reply a record on the stream (a 4-byte count, then
the messages), served by
.CW pipfs_servewire ,
the same server that answers the ring.  The client container sends a
group of four over its own tcp.c \- session, open
.CW /n/hello ,
read data, read version \- and reads the four replies back; then it
closes the connection, opens another, and a group naming the session by
number resumes it and reads through the fid the first connection
opened, still open: the session outlived the connection, which is what
the talk's sessions were for.  And on a wire a
.B Tstream
can be answered, which over the ring it cannot (a reply is the answer to
a request, and nothing can arrive unasked): the server keeps a stream
per fid and a second kproc,
.CW pipstreamer ,
puts what the streams owe on the connection every tick
.CW ( pipfs_stream ),
an
.B Rread
with the
.B Tstream 's
tag and no request to match.  The client asks for the version every
100 ms three times, and three frames arrive, each 100 ms after the
last by the client's own clock, with nothing sent to make them happen.
Three criteria in
.CW /scripts/osprey-check-p9pair.py ;
.I pip (5)
says which of its messages each transport answers.  As for the uart's
attributes: read against the tree rather than the earlier record, the
uart a container holds already answers all three the talk's slide
names \-
.CW *
listing them,
.CW b
the line speed (readable, and writable as a request to the driver task),
.CW d
the bytes received \- and
.CW name
besides
.CW ( devosprey.c ,
the uart case of the \[*p]p read and write).  Nothing of the item
remains.  For the record, the talk's uart (slide 20) is
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
is that container's to carry.  One thing about it found on 4 September:
when the queue to the task was momentarily full, the rest of a print
went straight to the port, ahead of what was queued, and cut a line in
two \- the console interleave that had flaked a criterion on every busy
boot, and that the faster ring yield of item 10 made constant.  The
kernel now waits up to twenty milliseconds for the task to drain, the
lock dropped, when it is in process context with interrupts on (the
task runs on the other processor meanwhile), and falls through to the
port only then; a boot's direct bytes fell from about a thousand to a
hundred, the rest being the fault prints that are meant to be
synchronous.
.PP
Those hundred bytes are the whole of what is left of it, and on 11
September they were measured rather than assumed: one boot in three has
a line cut in two, and the sweep of that day lost a criterion to one \-
.CW "osprey: fault at uscat: started wer pc 0x2000f7, inside ..." ,
which is the personality's fault line with fourteen characters of a
program's line driven through it.  The obvious fix was tried the same
day and taken out again:
.CW iprint
was made to offer its line to the console task, the way
.CW putstrn0
does, and p9legacy's lines came out in order for it \- the fault line
moved from log line 496, before the faulting program had even been
loaded, to 521, where it happened.  Then
.CW xup64
said why that is wrong.  Its console task is a user program that stops,
and the three lines it had not taken when it stopped were the last
three of the boot, with three criteria on them.  An
.CW iprint
is a line that must be seen, and a queue is a promise that somebody
will drain it; a kernel cannot make that promise for a user program.
.PP
So what remains is not a gap that a lock would close, and that is worth
being precise about, because a lock looks like the answer.  With a
console task the port has two writers: this kernel, through
.CW putc
on the chip, and the task's own uart driver, which is a user program
with a port grant.  No lock in this kernel reaches the second of them.
Ordering them means the kernel not writing the port at all \- which is
the arrangement, and which is exactly what cannot be relied on for the
print that says a fault happened.  And the clock: the CMOS real-time clock is
read in user space now, the exokernel way, the personality's own
.CW outb / inb
on ports 0x70 and 0x71 under a port grant, reading the date and time with
no kernel rtc device in the data path (it reads the six registers twice
and takes them when the seconds match, the update-in-progress guard
without the long spin that would be a CPL3 window for the standing pc64
interrupt fault).  And the time of day is the task's to set, not the
kernel's to read: read against the tree, the microkernel never read the
clock at boot at all \- its rtc driver is linked only because the AP
start path writes the warm-reset vector through it \- so its time of
day started at zero, and tickets, which expire against
.CW seconds() ,
were measured from 1970.  Now the personality, having read the CMOS
clock in user space, hands the kernel the time by a request of its own
.CW ( ReqSettime ,
an
.CW ospreyxcall ,
answered by
.CW todset ),
and the kernel says what it was given: the p9pair check compares those
seconds with the host's own clock and they agree within the boot's
length.  Who may set it is unchecked, which is the demonstration scale
of item 12.  What is left of the item is retiring pc64 as the testbed,
the measure the plan sets.
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
signed differently.  What stayed open when this was written was resume
\- a checkpoint carries the container's state, not the group's running
registers \- and it is item 6a below, where it is closed: the group is
carried as a group, across a wire, its members' pages shared again at
the far end.
.PP
.B "6a.  Resume, and a checkpoint that carries everything."
The group above is scheduled as one; what this item was written for is
carrying a
.I running
group across a wire.  Migration was checkpoint-and-restart, and a
checkpoint carries the container's rings, data area, semaphores, names
and grants, not a process's registers or stack, nor its packets, its
pages or its kernel channels, nor a checkpoint larger than one ethernet
frame.  Resuming a process rather than restarting it was the piece, and
the deepest one left; it is built, on one machine and then across a
wire, and the rest of this item is how.
.PP
Resume is built, on one machine.  A process asks to be moved
.CW ( ReqMove ,
an
.CW ospreyxcall ;
.CW ospreymovekern
in
.CW os/osprey/port/devosprey.c )
and the kernel carries it, as it is, into a container of its own: the
fork's own mechanism \- a new container delegated to the same server, a
new
.CW Proc
whose return frame is the caller's
.CW ( forkchild ),
the caller's segments dupped copy-on-write, its descriptor table cloned
by the buddy, its name space shared \- with the return register set to
the new container's identity rather than 0
.CW ( forkchildret ,
in
.CW os/osprey/pc64/trap.c ),
and then, instead of two processes, one: the container it came from is
taken apart the way an exit takes one apart, its entry in the child
table, and any wait pending on it, carried to the new container so that
the parent reaps the moved process and not a phantom of the old.  The
legacy Plan 9 binary opens a file, sets a local variable, and asks to be
moved; the call returns to it in the new container, and it prints the
new identity, the variable (42) still on its stack, and the file read
through the descriptor it opened before \- the state crossed, the
program did not start again \- and then exits from the new container,
which is what the client's wait is answered with.  Two criteria in
.CW /scripts/osprey-check-p9pair.py .
And the pages cross a wire now, which is what a checkpoint could not
do: a process is carried to another machine and resumed there.  The
kernel keeps nothing of the wire \- the server personality has it, the
real stack on the exposed network device (the section on the real wire,
under 7a) \- so the kernel hands the process's state to its server by
request and the server carries it in a TCP connection of its own.  A
process asks
.CW ( ReqMove
to the wire), its whole image is made resident as for a fork, and it is
parked in the kernel while the kernel tells its server
.CW ( OpMigrate
on the server's ring) and the server's
.CW migsend
pulls the state out: the segments and the register frame in one
request
.CW ( ReqMigsnap ),
then every resident page by halves
.CW ( ReqMigpage ,
a half being what the server's data area has room for; the kernel
answers a hole with the next resident address, so an empty megabyte of
stack costs one request), each a record on the connection to the other
machine's
.CW migrecv ,
which has its kernel make a container and a process with those
segments
.CW ( ReqMigmake ),
fill each page
.CW ( ReqMigput )
and start it from the frame
.CW ( ReqMigstart ,
sanitised by
.CW uregsanitize
in
.CW os/osprey/pc64/trap.c ,
the return register set to the new container's identity); the answer
comes back and the first server tells its kernel
.CW ( ReqMigdone ),
whereupon the parked process's container is taken apart and its
parent's wait answered as an exit.  All of it is in
.CW ospreymigcall
in
.CW devosprey.c
and
.CW migsend / migrecv
in
.CW os/osprey/cmd/p9/p9ip.c .
Both machines run both halves, and in the check each machine's legacy
process asks at about the same moment, so the two swap: four segments,
nine pages, 36864 bytes each way, and on each machine's console the
other's process prints that it is container 107 there and that its
stack still holds 42 \- the same program, going on from its request's
return, on another kernel.  Then it registers its note handler, takes
a note by request, faults on purpose and exits there, all answered by
the machine it arrived on.  Two criteria in
.CW /scripts/osprey-check-p9wire.py .
.PP
What the first crossing found, each on a booted pair.  The staging area
is one: the pages come through the same bytes the header was read
into, so the sender copies the header out first and the receiving
kernel keeps the register frame from the header when it makes the
process, or the frame is the last page's bytes.  A process made from
nothing keeps what
.CW newproc
does not reset \- the Linux ABI switch, the buddy's image, the note
handler \- from the Proc's last occupant, which a fork copies from its
parent and this has to set: the first arrival ran with the Linux
program's signal handler and died 139.  And
.CW fault()
refuses an instruction fetch from a segment exec has not marked
executable
.CW ( flushme ),
so the arrived text faulted on its first instruction until the
segment was marked as exec marks it.  Also the user-space driver's
transmit ring dropped a frame when all eight were in flight, which a
burst from tcp.c is, and every drop cost a retransmission timeout; it
waits briefly for a slot now.  And the group crosses with it, which is slide 15 whole: asked to go
with its group
.CW ( ReqMove
with both flags), the kernel stops the members as the one-machine
group move does, and the server carries each after the first \- its
header marking the segments it shares with the first
.CW ( Migshared ),
which are carried once and shared again at the far end
.CW ( ReqMigmake
with the first's identity), its own stack carried, its frame kept \-
and the far kernel makes each a child of the arrived first, so the
arrived parent reaps it; the members' containers go with the mover's
when the answer comes.  The check has each machine's legacy process
fork a thread counting in shared memory and cross with it: on the far
console the parent prints that it is container 108 there with 42 on its
stack and the thread's count at 20 before the crossing and 41 after,
the thread arrives as container 109 sharing 108's memory, two pages of
its own, and the parent stops and reaps it there.  Eleven pages,
45056 bytes, each way.  One more criterion in
.CW /scripts/osprey-check-p9wire.py .
What is honest to keep saying: open files do not cross \- the far buddy
knows nothing of them \- and the process that arrives is a Plan 9
process of no buddy image, all its pages carried.  Nothing of slide 15
remains.
.PP
The group moves too, which is slide 15's own sentence.  Asked to move
with its group
.CW ( ReqMove
with a flag), the kernel finds the other containers' processes that
share a data or bss segment with the caller \- what
.CW "rfork(RFPROC|RFMEM)"
made \- and stops each before its registers can be taken: the member
is marked
.CW Proc_stopme
and parks
.CW Stopped
on its next way back to user mode (the configs'
.CW donotify
runs
.CW procctl
first, which is where the kernel's stop has always happened), the mover
waiting up to two seconds for it and refusing the move rather than
leaving it half done if a member never comes back.  Then each member
gets a container of its own and a process built from its own register
frame and its own stack, sharing the mover's new segments where it
shared the old
.CW ( ospreymoveproc ),
its old container is taken apart, and its old process, still parked, is
readied with
.CW Proc_exitme
and ends in the same place it stopped.  Children of the old container
become children of the new, so the moved parent still reaps what it
made.  The legacy binary forks a thread that counts in shared memory,
moves with it, and reads the count still climbing afterwards \- 20
before, 42 after, in the run recorded \- then stops it by a shared flag
and reaps it from the new container.  One criterion in
.CW /scripts/osprey-check-p9pair.py .
Two things found on the way.  A child-table slot reused by a fork or an
exec kept the wait state of its last occupant, so a stale
.CW waiting
answered the wrong request and freed the entry before the parent
asked \- the thread's exit reaped by nobody \- now cleared at creation.
And two test-bench matters, honestly test-bench: the EFI loader read the
kernel straight into its link address with nothing said to the
firmware, and with the kernel past a megabyte it stalled after printing
its configuration one boot in several; it now claims the load region
from the firmware first
.CW ( claimpages
in
.CW os/osprey/boot/efi/efi.c ),
which is what a loader owes the firmware on hardware too, and the
console driver restarts a boot whose loader has gone quiet, since the
stall is not the kernel's to answer for.  What stays true of the group
move: a member blocked for good in the kernel would not stop and the
move is refused; and the shared segments are shared, not copied, with
the destroyed containers' processes until those end.
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
fifty-seven criteria, six of them this, the gateway and the firewall below, three
the \[*p]p wire of item 4, one the time of day of item 5, three the
resume and the group move of item 6a, four the replica and the caching
file system of item 8, one the note continuation of item 2.  What is
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
forwarding the stack's own code in user space.
.PP
And the firewall's rule, with the real stack's own rule engine rather
than netsrv's: once an
.CW ipmux
conversation exists, every packet for the stack passes its rules before
its protocol sees it (devip's
.CW Fsrcvpcolx ),
and one that matches is diverted to that conversation.  Stack B
announces a port, and when the client asks (a datagram to 9003) puts up
.CW "src=10.0.1.1;proto=06;data[2:3]=232c"
\- source, protocol and destination port, the fields a firewall's rule
has \- so the client's SYNs to port 9004 arrive on the ipmux
conversation, are read and counted there, 64 bytes each, and tcp.c never
sees them; after two the conversation is closed, which lifts the rule,
the next retransmitted SYN reaches tcp.c, and the connection is accepted
and answered
.CW ( fwsrv
and
.CW fwtest
in
.CW os/osprey/cmd/p9/p9ip.c ).
What the client sees is a connect held 1.6 seconds while the rule stood
and completed once it was lifted, and its line answered.  One criterion
in
.CW /scripts/osprey-check-p9pair.py .
So item 7 is whole in the form the sources give it: the real stack in a
container, routing between two wires, and a rule that drops before the
stack \- with the demonstration's own limits, one rule and one machine.
.PP
.PP
And the stack on a real wire, which is what the plan's stage (3) first
asked for \- a medium over the exposed interface \- done the exokernel
way rather than over the kernel's ether driver.  The kernel's virtio
exposure is one routine now
.CW ( ospreyvioexpose
in
.CW devosprey.c ,
the block and the network device the same shape to it), and the
network device goes to the server container as the segment
.CW virtionet
with its descriptor at
.CW Ospreynetoff
and its interrupt on the fifth semaphore.  Above it,
.CW os/osprey/cmd/p9/netvirtio.c
is the driver as a task: reset, VERSION_1 and MAC, a receive and a
transmit queue of eight in the slice's packet buffers, the frames in
the slice's packet and transmit buffers (contiguous with the slice, so
a physical address is the slice's plus an offset), no offloads; and
.CW os/osprey/ip/ospreyvnetmedium.c
is
.CW ethermedium.c
with its three kernel-device channels replaced by calls into that
driver \- IPv4 and ARP \- and its reading in a pump the server loop
runs when the device's semaphore is given and on every tick.  Two
machines booted from one image on one cable tell themselves apart by
the MAC the bench gives them and take 10.1.0.1 and 10.1.0.2 from it;
machine 1 announces a port, machine 2 connects across the cable, and
a line crosses each way, ARP and all: seven frames in and six out on
one side, five and six on the other, none dropped.  Two things were
found by the first real wire.  The personality's stack clock,
.CW NOW ,
had never advanced \- nothing wrote the Mach tick count it reads \-
so
.CW arp.c ,
which sends a request only when the entry is older than its
retransmit time, never sent one; loopback and the ring medium need no
ARP and never showed it; the cooperative tick now advances it.  And
QEMU's virtio-net is a transitional device unless told
.CW disable-legacy=on ,
which the check now says, as the block device's line already did.
Checked by
.CW /scripts/osprey-check-p9wire.py ,
six criteria on two machines, and three more for the process, and its
group, that cross it (item 6a).
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
The seam that was honest to name is closed.  The one-time controller
enable \- the i8042 command-byte handshake that turns the keyboard and
aux interrupts on and drains the buffer \- used to be done in the
kernel inside
.CW ReqKbdnotify
and
.CW ReqMousenotify ,
not in the driver's CPL3 kproc, because the handshake spins on the
status port and a spin that long at CPL3 was thought to reopen the
standing pc64 interrupt-path bug
.CW ( "pc=0xffffffff" ,
a corrupted return) whenever a clock or device interrupt landed while
the kproc was the running context.  Item 15 of the demonstrations built
the tooling to test exactly that: a trap-return checksum, and a
reproduction that spins two hundred million times at CPL3 while
interrupts land.  Run fifty-two boots, it corrupted no return.  So the
handshake is the driver's now
.CW ( i8042enable
in
.CW p9kbd.c ,
with the driver's own
.CW ospreyinb
and
.CW ospreyoutb ) :
the whole i8042, its one-time enable and its scancode and mouse reads
both, is owned in user space, and the kernel only takes its own
.CW ospreykbdintr
and
.CW ospreymouseintr
off the lines
.CW ( intrdisable )
and arms the notification handlers
.CW ( intrenable ).
The interrupt is not enabled in the controller until the driver's
handshake sets the command bit, so between the kernel's arming and that
a keypress cannot fire, and a spurious one only wakes the driver, which
drains.  The kbd check passes six of six with the enable moved: the
driver reads make and break codes for four keys and a decoded PS/2
mouse packet, all by
.CW inb
at CPL3, the controller it programmed itself.
.PP
.B "8.  What the talk's goals name."
Authenticated, controlled access to
.I "dynamic replicated data"
(slide 11) and a
.I "caching filesystem"
(slide 23).  These are the talk's ends, not its mechanisms, and they
come after the file system exists, which it now does.  The replicated
data is built, in the form the wire above makes natural: the client
container keeps a replica of the server's
.CW /n/hello
and follows a stream of the file's committed version over the \[*p]p
wire
.CW ( replica
in
.CW os/osprey/cmd/p9/p9ip.c ).
A fid's version is fixed at its open \- a fid's data is a snapshot \-
so the server gained an attribute,
.CW latest ,
the file's committed version now
.CW ( fileversion
in
.CW pipfsrv.c ),
and that is what the stream carries, every 100 ms, unasked.  While each
frame says the version the replica holds, a read is answered from the
copy with nothing asked of the server; when a frame says another
version, the replica opens a new fid on the file, reads it, closes the
old, and moves the stream to the new fid, and is current again within a
period.  The change is made by another path while it watches: 9P over
the ring, the client's own mount of the server, writing the file.  The
boot shows the replica holding version 43, three reads answered from it,
the 9P write, the next frame saying 44, the refetch reading the new
text, and the summary \- six frames, five reads from the copy, one
refetch.  Two criteria in
.CW /scripts/osprey-check-p9pair.py .
What that is not: the access is not authenticated \- the personality's
\[*p]p has no key, only the kernel's has.
.PP
The caching file system is that replica generalised and put behind a
name space:
.CW os/osprey/cmd/p9/devcache.c ,
a device
.CW ( #K )
in the client personality, bound over its own
.CW /n .
An entry per name: the first open of
.CW /n/hello
fetches the server's file over the \[*p]p wire \- one group: session,
open, data, latest \- and sets a stream of its committed version on the
fid, which a reader kproc takes off the wire and notes against the
entry; the next open finds the entry current and answers from the copy
with nothing asked of the server; an open after the stream has said
another version refetches (a new fid, the old closed, the stream moved),
and reads are of the copy.  The directory lists what is cached.  The
boot reads
.CW /n/hello
through the client's name space twice \- a miss, then a hit \- lists
.CW /n ,
has 9P over the ring write a new version, waits two periods of the
stream, and reads again: the open refetches and the read is the new
text; one miss, one hit, one refetch.  Two criteria in
.CW /scripts/osprey-check-p9pair.py .
Its limits are the replica's: copies in one program's memory, reads
only \- a write goes by another path and the stream is how the cache
learns of it \- and no key.  So the two ends slide 11 and slide 23 name
are both reached, in the form the built mechanisms give them, and what
they lack is the authentication the kernel's \[*p]p has and the
personality's does not.
.PP
.B "9.  A second machine."
The talk boots the same code as
.CW kpc64
and
.CW kpc32 ,
and claims the system for hard real-time embedded work.  Osprey builds
for amd64 only.  The 386 libraries build and its machine layer is in the
tree; what a 386 kernel lacks is a 386 userland for its boot file system
(section "One instance where the plan asks for a choice") \- and, found
by trying it rather than by reading,
.I "an assembler that will take its machine layer" :
.CW 8a
here does not know
.CW FXSAVE ,
.CW FXRSTOR
or
.CW LDMXCSR ,
which
.CW os/osprey/pc/l.s
uses, nor the
.CW "JMPF syscall(SB)"
in the same file, so it has never been through an assembler in this
tree.  Nothing builds it, which is why nobody had noticed.  A non-x86
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
says where it goes: half in the scheduler, a third in two blunt wake
sweeps, four microseconds in the work.  The microkernel's tasks are
still Procs.  A task of the talk's shape on the microkernel, and the
number measured on hardware, is the piece; it is structural, and it is
last because everything above it is correct without it.  What a task
that is not a Proc costs is measured now, in 10a below.
.PP
The microkernel's own number, between two personalities, is measured
now \- 56 \(mcs a request after item 2 of the section on making the
demonstrations real, 108 before it \- and one thing was found by
measuring it.  The p9pair client times
a thousand requests by the cycle counter \- each put on its ring, carried
by the kernel to the server container, taken by the server's select,
answered, and routed home \- and the check turns the cycles into time
by the rate the kernel prints: 108 \(mcs a request, under QEMU.  Before
that could be measured the number was two milliseconds, and not
because of the path: a program's yield after a request
.CW ( xsleep ,
the SLEEP call that services the ring) slept a fixed two milliseconds
however fast the reply came, so every request from a personality \-
every 9P message, every \[*p]p group, every frame poll \- cost at least
that.  The yield now sleeps on the container's reply rendezvous, which
the server's select wakes when it routes a reply home
.CW ( ospreyawaitreply
in
.CW devosprey.c ),
with the two milliseconds as the bound.  The whole p9pair run is
quicker for it, and the store's reclamation had to change to keep up:
one step a tick was enough while every write waited two milliseconds,
and a client answered in a hundred microseconds outran it and made
writers pay, so the tick now takes up to eight steps until the log is
half free, still under the storage task's reservation.  What remains
of the item is what it was: a task that is not a Proc, and hardware.
.PP
.B "10a.  What a task that is not a Proc costs."
The claim the item rests on is that the shape is the cost \- that a
message is expensive here because the two ends are Procs and a message
between them goes through the scheduler.  The section "Latency"
measures one side of that: half of a 59-microsecond round trip is the
scheduler's two legs, and four microseconds of it is the work.  The
other side is what the same exchange costs when there is no scheduler
in it, and that is now measured rather than assumed.
.PP
.CW taskswitch
.CW ( os/osprey/pc64/l.s ;
amd64 only, since the 386 machine layer in this tree does not assemble
at all \- 8a rejects the
.CW FXSAVE ,
.CW FXRSTOR
and
.CW LDMXCSR
in its
.CW l.s \-
and a line nobody can assemble is a line nobody can prove) leaves one
task and enters another in one instruction stream, and
.CW devosprey.c
has two tasks with an eight-kilobyte stack each \- the size the talk
dumps \- that pass a message by switching straight from one to the
other.
.CW "task 20000"
written to
.CW #O/bench
measures them: 65 to 100 nanoseconds a round trip, which is two
switches, so 32 to 50 nanoseconds a switch, against 33 to 39
nanoseconds to read the cycle counter once.  A switch here costs about
what reading the clock costs.
.PP
Three orders below the whole round trip, but that comparison flatters
it, since the round trip carries four microseconds of real work the
tasks are not doing.  The same-quantity comparison is the one the
section is really making: 65 nanoseconds of handoff against the
thirty microseconds the scheduler's two legs cost, which is a factor of
four hundred and sixty.  Both numbers come off the same emulator in the
same boot from the same counter, which is what makes the ratio worth
anything when none of the absolute figures is a hardware one.
.PP
A label in this kernel is a stack pointer and a program counter and
nothing else, and that is the whole of a context in this ABI: the
tree's own
.CW setjmp
for amd64 saves those two and no registers at all, because the Plan 9
compilers keep nothing in a register across a call.  So the switch is
eight instructions.  The reason to write it rather than to call
.CW setlabel
and
.CW gotolabel
in turn is that the code between the two would run on a stack that is
about to be left.
.PP
What this is not is the talk's 270 nanoseconds reproduced, and the
difference is not in the tasks' favour.  These tasks are not
preemptible; they run in the kernel context of whatever Proc entered
them and share its address space; nothing schedules them but each
other; the measured loop runs with interrupts off.  A microkernel's
task is preemptible and may be picked up by any processor, and the
talk's number includes all of that.  This is a lower bound on what a
message costs with no scheduler in it, and nothing else in the kernel
uses it: the containers' service path still wakes a kproc.  Converting
that path \- the request ring waking a task, the task answering, the
caller resumed without the scheduler \- is what would close item 10 on
this side, and the hardware figure is the other side, still
board-bound.
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
section is about.  No part of this tree held one when this was written;
it does now, and the section "2.3c: the userland this tree builds
itself" is where it was built.
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
big read rather than assume one fits.  Two things this paragraph used
to call open are closed, and both are checked: the exportfs is reached
by a client in a container of its own over the ring (the client
personality mounts the server personality and reads, writes, creates
and removes in its name space, ninety-odd criteria of
.CW osprey-check-p9pair ),
and the third of the three unreachable things \- processes that share
an address space migrating as a group \- is whole, on one machine and
across a wire
.CW ( osprey-check-p9wire ).  What was unreachable from a Plan 9 kernel is reached by
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
handler catches the fault and exits.  The
.CW noted (2)
continuation that resumes the interrupted instruction is built too, and
a bad-address fault is not what exercises it: the legacy program asks
for an
.CW alarm (2)
note and for a note posted by request, its handler takes each and calls
.CW noted(NCONT) ,
and it comes back to the instruction after the call both times.
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
record, so it writes the last sector instead.  The exporter answers create and remove
as well now, by the fid's own path so that the mount is followed: the
client makes a file in the server's name space over the ring, writes it,
reads it back and removes it.  What is not built: a version is at most
8 KB and there are thirty-two files.
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
\- ran on the tick, none on a writer (a figure of that day's speed;
what holds is the rule of the plan's item 3 below); the second boot reads the
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
version 3's data.  Streams and tickets were answered here as what they were when this was
written: no wire to stream on, no key to check a ticket against.  The
wire is built since, and it is item 8 of the section on making the
demonstrations real: the personality speaks \[*p]p across the cable to
the other machine's personality, a
.CW Tauth
carrying a ticket its own kernel signed and the far kernel checking it
.CW ( ReqTicket ,
.CW ReqCheckticket ),
so a session on the wire has a name and an open is judged by the file's
owner against it.  The stream came with the wire:
.CW Tstream
is answered for a group that came over the cable, the wire's own task
emitting the attribute at the period asked for, and it is still refused
for a group that came over the ring \- where a reply is the answer to a
request and there is no wire for an unasked frame to leave on.  Checked, with a second boot, by
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
Two orders of magnitude.
.PP
This document used to explain the difference in one sentence \- a round
trip here wakes a Plan 9 kernel process to answer it \- and that
sentence was an assertion.  A round trip is five things: putting the
request on the ring, waking the machine's waiters, waking the
container's servers, waiting for one of them to answer, and taking the
reply off; only the fourth is the other process's, and the total on its
own says nothing about which of them is the cost.  So
.CW #O/bench
reads the cycle counter at each stage now and prints the parts beside
the whole.  Two thousand round trips, on four processors, on the
eleventh of September 2026:
.CW "66145 ns each; submit 1457, wake 12606, wakeservers 2496" ,
.CW "wait 48588, collect 840" ,
and every one of the two thousand slept.
.PP
Three quarters of it is the waiting, but the waiting is not one thing
either, and a wait measured only from outside is still an assertion
about what the other process does with it.  So the service process
reads the counter around its own pass too, and the same bench prints
that: of a 45 microsecond wait, the server spends
.B 4
microseconds answering the request and routing the reply, and
.B 11
more in its own sweep of the rendezvouses, which leaves about
.B 30
in the scheduler's two legs \- getting to the server after the caller
wakes it, and getting back to the caller after it replies.
.PP
That is the division the section exists to give.  Half of a round trip
is the scheduler, a third of it is two blunt wake sweeps, and four
microseconds of it is the work the whole thing is for.
.PP
The half that is the scheduler is the process shape, and that much of
the old sentence holds: this process goes to sleep, the scheduler runs
the container's service kproc, it answers, and this process is woken
and scheduled again.  A microkernel's send-receive does not do that,
and no tuning of this code removes it.  What it costs instead, when the
two ends are not Procs, is measured in item 10a above: 65 to 100
nanoseconds for the same exchange, three orders down.
.PP
The third that is the sweeps is not the process shape at all, and the
breakdown is what shows it.
.CW ospreywakeup
wakes three rendezvous for each of sixteen container slots \- forty
eight
.CW wakeup
calls, all but one of them on a rendezvous nobody is sleeping on \- and
it is called on every submit, which is the caller's 10 to 12
microseconds; the service process calls it too on every pass, which is
the 11 inside the wait.  That is this kernel's bluntness, not Plan 9's
process, and it would cost the same in a kernel whose tasks were
anything at all.  It is a third of the round trip sitting in two loops
that a targeted wake would remove; it is written down here and not
done, because a wake that misses is an intermittent hang across every
check in the tree, and the win would take 60 microseconds to 39, which
is still two orders off the talk.
.PP
One control, because there was an explanation that would have made all
of this the emulator's: on four processors an idle core has to be
brought out of a halt with an interprocessor interrupt, and under QEMU
that is a vm exit.  If that were the cost, one processor would collapse
the wait.  Booted with
.CW "-p 1" ,
the same bench says
.CW "62833 and 68087 ns each" ,
with the wait 46530 and 50619, which is the four-processor number.  So
the interrupt is not where the wait goes.  The control bounds that
share rather than removing it: on one processor the caller must be
descheduled for the server to run at all, so what it shows is that
nothing is added by having three more processors to wake, which is the
explanation that was on offer.
.PP
What these numbers are not is hardware.  This is QEMU's software
emulation on a loaded host, so a microsecond here is not a microsecond
on a machine; what the breakdown supports is the division of the round
trip into its parts and the ratios between them, which is what the
argument needs.  The talk's number is a microkernel's, and this is not
one.
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
Making the demonstrations real
.PP
Everything above is checked on a booted kernel, and much of it is
checked in a form that is a demonstration: the mechanism is real, the
shape around it was the quickest that would let the mechanism be seen.
Read on 4 September against the tree, these are the places where a
quick shape stands in for the real one, in the order they should be
made real, each with what the real form is and what will prove it.
The reasons for the order: the first two are under everything and
cheap; the storage and the wire come next because the migration and
the cache are built on them; authority comes before anything is called
finished; the two kernel bugs are last only because they are the least
predictable.
.PP
.B "1.  The console never bypasses its task."
Done.  When the queue to the console task was full a print waited
twenty milliseconds and then wrote the port, ahead of what was queued.
The form first planned \- a print sleeping until the task makes room \-
would deadlock: a printer may hold the lock the task needs to take a
message.  The real form is a FIFO the kernel keeps between printers and
the task
.CW ( ospreyconsput ,
.CW ospreyconsflush ,
.CW ospreyconsdrained
in
.CW devosprey.c ):
every print appends to it in order and never blocks, and the FIFO is
fed to the task's output queue a slot at a time whenever there is room,
by the printer and by the task itself when its take frees a slot.  Only
the FIFO overflowing \- the task sixteen kilobytes behind \- or a panic
goes to the port.  The user-fault line of
.CW trap.c
is an ordinary print again, and the eight-hundred-sleep drain in
.CW legacyp9.c
is gone.  Proof: the kernel's line at exit reads
.CW "0 straight to the port"
and the p9pair check is 57 of 57.  A second, later finding under the
same item: a kernel line was still cut in two, now and then, by a Linux
program's output, and three probes in turn cleared the FIFO (its slots
are checksummed at fill and at the end of their push, and a fill landing
on the slot in flight is counted: all zero), cleared the counted
fallbacks, and then noticed the intruding lines ended in carriage
return and newline where the task's do not \- the mark of the bare
port's own conversion.  The writer was the kernel's answer to a Linux
program's write to its standard output
.CW ( ospreylinuxsyscall
in
.CW userinit.c ),
which pushed each byte to the port itself; it goes through the console
like every other write now, and the kernel's exit lines count every
path to the port: through
.CW uartputs
only before the task exists, through
.CW kdebugputs
never.
.PP
.B "2.  A reply wakes whom it is for."
Done.  The route reports which containers received replies
.CW ( ospreyroutewoke
in
.CW ospreyrt.c )
and only their reply rendezvous are woken
.CW ( ospreyroutewake
in
.CW devosprey.c );
the broadcast is gone.  The round trip between two personalities went
from 108 to 56 \(mcs \- the broadcast had been waking the server's own
select loop some hundred times a second \- and the kernel's line at
exit counts the containers woken, each for a reply of its own.
.PP
.B "3.  Reclamation paid for by the reservation, not by a number."
Done.  The tick asks the kernel what the task's reservation is and what
it has used of it this period
.CW ( ReqAccount ,
an xcall answered from the container's own accounting by
.CW ospreyaccount
in
.CW ospreyrt.c ),
and which period this is, measures what each reclaim step costs by the
cycle counter, and steps while what reclamation itself has spent this
period is under three quarters of the budget, until the log is half
free.  It is reclamation's own spending that is measured, not the
container's: the server personality serves its client out of the same
reservation and is at its budget most periods, and measured that way
(the first form of this item) reclamation never got a step once the
client stopped polling, and writers paid again.  So a writer pays only
when the log has filled between two ticks, and then one step, for its
own record.  What the check asks is that rule and not more: an early
run of it, with the client slowed by a two-millisecond wait, saw
eighteen steps on the tick and none for a writer, and the check was
written to demand that; with the ring medium of item 5 the client
writes a version a millisecond, a reclaim step's disk round trip through
the user-space driver costs more than the share of one period under a
host load of thirty, and a burst of twelve versions lands between two
ticks.  The tick's line says what it spent of the reservation: under
that load a step cost from a quarter of a million cycles to three and a
half million, against a share of two million in each period of ten
million, so a tick gets one step or three, and the writers' steps \-
eleven in the first boot, twenty-five in the second, which starts with
the log full \- are the rule, not a failure of it.
.PP
.B "4.  The network driver waits, it does not spin."
Done.  The rings are sixteen, from the slice's own buffers (the boot
sets the
.CW pktbuf
tunable to thirty-two and
.CW txbuf
to sixteen), which was what the first attempt at item 1 found wanting:
under a host load of thirty the eight-entry receive ring overflowed
between two ticks, SYNs were lost and backed off for seconds, and two
machines that boot four seconds apart missed each other.  And the
driver neither drops nor waits:
.CW vnet_send
says when every slot is in flight, the medium keeps the frame on a
transmit queue of its own, and the pump \- run by the device's
interrupt and on every tick \- sends what waited, in order, as slots
free
.CW ( vnetdrain
in
.CW ospreyvnetmedium.c ).
Proof: machine 2 sends a megabyte across the cable in 8 KB writes and
machine 1 reads it back whole \- 20 milliseconds, 52 megabytes a
second, under QEMU \- with nothing dropped and, as it happens, nothing
refused either, tcp.c's own pacing keeping a burst inside sixteen
frames; the queue is there for when it does not.  Ten criteria in the
two-machine check.
.PP
Two bandaids found and removed on the way, both in the two-machine
check.  A wait is a wait:
.CW ring_wait
gave up after ten seconds, which a child migrating over a slow wire
outlasted, and the client went on with the child still here; it waits
until answered now.  And the sender connects to the other machine up to
twenty times a second apart, since the other may not be listening yet.
The check itself waits, on each machine, for a line the kernel prints
at the later of the machine's own departure and the exit of the process
that arrived, since the two come in either order.
.PP
.B "5.  The ring medium carries frames both ways without polling."
Done.  A container's output queue is its own memory, and its server
maps the slice: so the server end's frames go into the client's own
packet buffers (sixteen through thirty-one) and a message naming each
onto the client's output queue, written there in memory
.CW ( ringsrv_output
in
.CW p9pairsrv.c ),
and one request
.CW ( ReqKick )
has the kernel wake the client's select, which takes the message on an
arm of its own beside the tick
.CW ( ring9p_wait ,
.CW ring9p_taken )
and injects the frame from the buffer
.CW ( ospreymediumtaken ).
The client's frames go the other way the same way, staged in its packet
buffers naught through fifteen and named by the request, so neither
direction copies through the small data area and the MTU is a packet
buffer's, 2048.  A full queue holds the server's frame on the medium
until the tick.  Proof: the client's line at the end says every one of
the server's frames came on its output queue, taken by select as many
times, and no polls; the kernel carries a wakeup per frame and nothing
else.  Making this run on two machines found a bug older than any of
it, in the personality's cooperative scheduler: its sleep loops armed
the wait once, before the loop, so after a wakeup with the condition
still false the sleeper yielded marked Running, was queued as
runnable, and ran round with the serve loop for good \- the loop never
regaining its select, the machine's stack going quiet while its
kernel and client went on.  A bulk transfer's queue wakeups made it
happen one run in two; the kernel's new once-a-second watch for a
process sitting at one user pc placed it in
.CW sched
and
.CW setlabel ,
and the sleeps now arm the wait before every switch.
.PP
.B "6.  Migration that carries what a process has."
Done.  The descriptor table is the buddy's, so it is the buddy's to
carry: the sender's personality asks its buddy for the departing
container's record
.CW ( p9buddy_migout
in
.CW p9buddy.c :
the image's file name and kind, and each open descriptor's number,
mode, offset and name, which the buddy records at open and create; a
pipe's end has no name and is left behind, said so), sends it after
the kernel's header, and the taker's buddy lays the same image out for
the arrived container and reopens each descriptor at its offset in its
own file system
.CW ( p9buddy_migin ).
The kernel's header says whether the process's text and data are a
buddy image's
.CW ( Migimage ),
and before such a process is parked its text pages and every data page
equal to the buddy's copy are let go
.CW ( mfreeseg ,
a page at a time), as is every page of zeros in bss or stack; the far
kernel makes the data segment data, not bss, marks the process the
buddy's, and what was let go pages in from the image there, or from
this machine's again if the crossing is refused.  A segment shared
with a process that stays \- a forked sibling shares the text \- is
carried whole: only a segment whose every sharer is leaving (the
process, its group, a process parked in another departure) may lose
pages.  Pages cross whole, staged across two adjacent packet buffer
slots of the server's slice (a slot is 2112 bytes; slots 18 to 23 for
arrivals, 24 to 31 for departures), the header alone through the data
area.  Departures are a table of four
.CW ( migouts ),
each with slots of its own, and the taker's listener hands each
connection to a kproc of its own, so two cross at once; the parked
process sleeps on its entry's rendezvous, woken by every page the
server pulls and by the answer, and is refused only when nothing has
moved for ten seconds, not after a minute's count.  The legacy
program's proof: it opens
.CW /n/hello ,
writes forty pages of its bss, forks a sibling that asks to cross at
the same moment alone, and crosses with its thread; on the far machine
it reads the file through the descriptor, counts its forty pages
intact, reads
.CW /hello
\- the bind of
.CW /n
onto
.CW /
it made in a private name space before crossing, which names
.CW /n/hello
there because the buddy rebuilt the name space and replayed the bind
.CW ( p9buddy_migout
records each bind,
.CW p9buddy_migin
rforks the ns and replays them) \- and the sibling does the same.  So
the process's name space crosses now, not only its descriptors: what
the survey once kept saying, that a migrated process's kernel channels
do not cross, is no longer whole \- its private name space, the binds
that made it, crosses with it.  The figures, the same on both
machines: the parent lets go of six pages \- its five of text and one
of zeros \- and carries forty-three, the forty it dirtied, its stack
and two data pages that differ, where the whole image had crossed
before; the sibling, asking a moment earlier while the parent still
runs and shares its text, carries that text whole, five pages, and
lets go of one, which is the rule and not a failure of it.
.PP
Two bugs older than the item came out of it.  Letting go of shared
text under a live sharer made the sharer fault, and the process that
reached the note code with no container was a ghost: the old process
of a group member that a local move had copied was told to exit
.CW ( Proc_exitme )
and then, as its old container was taken apart, the container's
release \- meant to undo a stop this device had imposed \- cleared
that order and readied it, and it went back to user mode with no
container, sharing the old address space, after every group move and
every wire departure, until some page it needed was gone.  The release
now undoes a stop and not an exit.  And a forked or moved child's
buddy image was an empty table: the buddy cloned the descriptors at a
fork but not the image's file and layout, which the whole-image
residency of a fork hid until a page was let go; the clone carries
them now.
.PP
Three more came out of running it.  A process may hold ten segments
.CW ( NSEG ,
an enum in
.CW portdat.h ),
and the personality's text, data, bss and stack, its two device BARs
and the slices of the containers it serves fill them by the seventh
container, whose every request was then \*(lqunmapped\*(rq and whose
buddy was lost to it \- which is why a moved process's descriptor read
empty and a departing container had no record: the count is thirty
now.  Every exit of a legacy process, and the move's and the
migration's, called
.CW pexit
with its second argument 0, which to Plan 9 means keep the memory and
become a Broken process, held for a debugger until four more break; so
every exited, moved or carried process lingered with all its pages and
its segment references until the fourth exit after it, and a departing
process's text always looked shared with a process that stays.  They
free their memory now, and a departure lets go of what it may \- which
found the last one: the buddy's page fault
.CW ( ospreybuddyfault )
put the page it had fetched into the segment without looking again,
and two sharers of a segment on two cores, faulting the same page once
pages were let go that had always been resident, hit the assertion in
.CW segpage ;
a form of it that inserts only into an empty slot
.CW ( segpageif )
does it under the segment's own lock, and the page present is used.
And an arrival exited against a departed container's child-table entry, whose
container record had been reused: a lookup skips entries already done.
The client's select loop of item 5 took the kernel's \*(lqnothing in
200 ms\*(rq for a failure, which a tick paused by a loaded host can
produce; it asks again.
.PP
.B "7.  A group member that is blocked still crosses."
Done, Plan 9's own way.  With the stop
.CW ( Proc_stopme )
the move posts each member a note
.CW ( postnote ),
which cancels the sleep it is in; the interrupted call returns
.CW Eintr
on its way out, and there, at the return to user mode, the stop takes
hold and the member is carried with the call's return in its
registers.  The note itself is never delivered: a moved process starts
with no notes, and a move refused takes it back
.CW ( ospreydropnotes )
before the member goes on, since a note delivered to a process without
a handler would kill it.  What the program does with an interrupted
call is the program's, as on Plan 9: the legacy program's thread
sleeps a minute, sees the sleep return \-1 on the other machine, and
goes on counting there \- the two-machine check reads the count at 1
before the crossing and above it after.  Which found that no legacy
process had ever slept: the configuration gives SLEEP's number to the
boot program's yield-and-service call, a two-millisecond wait, and a
legacy process trapping the same number got that too, whatever it
asked \- a minute's sleep was two milliseconds, and the thread counted
on as if nothing had blocked it.  A process whose text is a buddy's
image gets Plan 9's sleep(2) now.  And the arrived member saw its
sleep return 0, not \-1: an arrival's frame is built by
.CW forkchild ,
which zeroes the return register as fork's child's, and the leader's
identity was then written over it for every arrival; a member gets its
own saved return back
.CW ( uregax ),
on a local move as on the wire.  Proof, the two-machine check's
fifteenth criterion: the thread had counted to 1 before the crossing
and to 17 after it, and said its minute's sleep was interrupted.
.PP
That post-exit fault \- the server personality returning into address
\-1 on a kproc stack of zeros
.CW ( "user fault: read addr=0xffffffff pc=0xffffffff" ,
pid 6) \- was run down under item 9, whose caching file system made it
happen every run: it was the one shared reply buffer of the
cooperative scheduler, reset by a stream tick under a group that had
slept mid-build.  The fault dump that prints the frames below the
stack pointer and the registers, direct to the port, is what placed
it; item 9 has the fix.
.PP
.B "8.  The personality's \[*p]p wire checks who is asking."
Done.  The kernel has the key and checks tickets already, so the
personality asks it: a
.CW Tauth
on the wire puts the ticket in the server's data area and the kernel
says whom it names
.CW ( ReqCheckticket ,
xcall 34: signed with this key and not expired, or no), and that name
is the session's from then on; a session without one is nobody, which
on a wire is all a frame can prove.  The personality has a name now
.CW ( eve
is
.CW osprey ,
in
.CW p9shim.c ),
so its files are somebody's, and an open on the wire is judged by the
file's owner and mode against the session's name: a file that is
somebody's is refused to a session that is nobody's, and a named
session reads as owner or as other.  The asking end gets its ticket
from its own kernel
.CW ( ReqTicket ,
xcall 35: for the caller's container and a name the container is for
\- a container nobody has claimed is anyone's, and the ticket says just
that).  What the ticket does not do is name a container on the far
machine: the number in it is the signer's, kept for the record.
.PP
The two kernels must hold the same key, and in this configuration the
kernel has no wire of its own to agree one over (item 11's exchange is
the kernel's, on a kernel ether); the check types the same key into
both machines' plan9.ini
.CW ( ospreykey= ,
read at
.CW ospreyinit ,
the fingerprint printed), which is the alternative the design names.
Proof, two criteria of the two-machine check: machine 2's session that
is nobody's asks machine 1's personality for
.CW /n/hello
and is refused \- \*(lqnot yours: a session that is nobody's may open
only nobody's files\*(rq \- and with a ticket its kernel signed, which
machine 1's personality had its kernel check, the session is
.CW osprey
and reads the file.  The rule fell on the ring too: the client
container's \[*p]p over the device-carried wire \- the pair check's
own groups, the replica, the caching file system \- opened sessions
that were nobody's and was refused the personality's files, as it
should be; every client asks its kernel for a ticket once
.CW ( pip_ticket )
and says who it is in the first group of each session it opens.  Two
more things came of that: the caching file system's group buffer was
sixty-four bytes, a session alone, and a ticket in it smashed the
client personality's stack, which died by a note; and the boot
program's idle loop, entered killed by that note with the note still
pending, had its sleep raise
.CW Eintr
into no handler at all and panicked the idle machine \- it clears what
is pending and sleeps under an error label now.  And the personality's
\[*p]p listener answered on stack B alone, the ring's; a second
listens on stack A, where the cable is.
.PP
.B "9.  The cache is a file system."
Done.  A write through
.CW #K
is taken into a draft of the entry and the close commits it: a \[*p]p
open, write and close on a fid of its own over the wire
.CW ( cachecommit ),
the server's close committing a version on the log, and the copy
becomes the draft at the version the server said, which the entry's
stream then says too.  The directory is the server's root listing,
asked for at the start of each read
\- an entry per file it has a copy of, its version and length as the
cache knows them.  A cache is a window on the store, and its directory
is that window, not the whole of the store.  A ninth name in a cache of
eight evicts the entry least recently used that has no chan open on
it and nothing being written through: its fid is closed on the wire,
which stops its stream on the server, and its copy is freed
.CW ( cachedrop ).
A name the server has not got leaves no entry behind.  And the lease:
a stream is the fid's use, and the session's, so each frame renews
their leases on the server \- before this a streamed fid lapsed three
seconds after its last read, its stream stopped with it, and the
cache served its copy stale for good, within the check's window
unseen \- and an entry whose stream has been silent past the lease is
dropped and fetched afresh at its next open.  The server's session
holds sixteen fids and sixteen streams now, one per entry and one for
the group of the moment.  Proof, four criteria of the pair check: the
write through
.CW /n/hello
read back on the server by 9P; the directory listing what the cache
holds; nine files through the cache of eight with the ninth evicting
the least recently used; and an entry still held and read from the
copy three and a half seconds later.
.PP
And a fifth, which could not be asked until the store took a remove at
all.  A cache holds a copy, and a copy of a file that has been removed
is a file that does not exist; a cache that went on answering from it
would be the worst kind of wrong, since the reader has no way to tell.
The server already said so and nobody was listening: the stream watches
a name \-
.CW latest
is the file's committed version now, which
.CW fileversion
finds by walking to it \- so a removed name makes that walk fail, and
what goes out on the stream's tag is an
.CW Rerror
rather than a version.  The cache's reader threw away every frame that
was not an
.CW Rread .
It reads the error now, lets the copy go, and takes the entry out of
the table altogether when nobody is holding it \- so the name leaves
the cache's directory, and the next open of it asks the server, which
refuses.  The reason a reader gets is the server's own and not this
cache's guess at it.
.PP
Two things had to be got right, and both are about where the code runs.
Nothing is said on the wire from the reader: that kproc is the one that
takes replies off the wire, so a close sent from there would be waiting
for itself \- the fid is left, and its lease lapses on the server in
three seconds, which stops the stream there.  And an entry with a chan
open on it is read straight out of the copy, which is why eviction
waits for its use count to fall to zero; freeing it in the reader would
be freeing it under a reader.  Such an entry keeps what it has and is
made to read as stale, so the next open refetches \- and the refetch is
the call that fails.
.PP
The criterion is the whole path in one boot:
.CW /n/cachef7
is held by the cache with its stream running, removed on the server by
the other path (9P over the ring, which is where the tombstone is
written), and four stream periods later the cache says
.CW "the stream says \(lqfile does not exist: '/n/cachef7'\(rq: the copy
.CW "is let go" ,
and the open after that is refused.  The check also carries the control
it needs: a line that would print if the cache still answered from the
copy, which is not in the log.
.PP
This is where the cooperative scheduler's one shared reply buffer
showed at last.  The server builds a group's replies and a stream
tick's frames through the same globals
.CW ( rbuf ,
.CW rn );
a group's
.CW readattr
reads a file, which sleeps, and the scheduler then ran the stream
task, which reset those globals under the sleeping group, ruining both
buffers and jumping wild in the end.  A flag holds the builder now, and
the stream task defers a tick while a group is mid-build.  And the
test leaves no streams firing behind it: it lets go of every entry
when it is done
.CW ( cachestopall ),
each entry's fid closed on the wire, its stream stopped on the server,
so eight streams did not run on through the firewall and migration
work that follows and, before that, a run that went on long enough
faulted the personality after the boot program had exited.
.PP
.B "10.  Authority on the kernel's requests."
Done.  A container carries a capability word
.CW ( caps ,
set at boot by
.CW ospreyaddcaps ),
a bit per authority, and the requests of a task's own check it.  The
server holds the console \- its tasks read the CMOS clock in user
space and its rtc task sets the kernel's time of day \- so it is
granted
.CW Capsettime
when it is created, and
.CW ReqSettime
refuses a container without it.  The network device, when it is
exposed to a server
.CW ( ospreynetexpose ),
grants that server
.CW Capwire ,
and
.CW ReqMove
to the wire refuses a container whose server holds no device, since it
is that server's real stack the process would cross on.  Proof, three
criteria across the two checks: the server sets the time and says it
holds the console; a legacy container asks and is refused, in the
kernel's words and its own; and on two machines each server is granted
the wire when its device is exposed, and the crossings that follow are
the authority in use.
.PP
.B "11.  Configuration read, not derived."
Done.  Each machine reads
.CW /n/net
from its store at boot
.CW ( netconf_read )
\- its own address, its peer's, its role and the wire, pi-p and
migration ports \- and the wire is brought up, the cable connected, the
pi-p and migration reached, from those values.  A fresh disk has no
such file, so it is written once from the MAC (the bootstrap: address
.CW 10.1.0.n
for a MAC ending in n, the peer its complement, role by the last bit),
and read from then on, here and on the next boot; the same image on two
disks holds two files and the machines differ only in them.  Proof, a
criterion of the two-machine check: machine 1 writes
.CW /n/net
saying it is
.CW 10.1.0.1 ,
role server, machine 2 that it is
.CW 10.1.0.2 ,
role client, and each binds its wire to the address the file gives.
.PP
.B "12.  The firewall's rule set by policy."
Done.  The rule is a container attribute, not a datagram anyone could
send: the client, holding the container by a ticket its kernel signed,
opens a \[*p]p session over the ring and writes the
.CW firewall
attribute
.CW ( pip_twrite ),
and the server takes it only from an authenticated session
.CW ( pipfs_firewall
holds the value; a session that is nobody's is refused).  The firewall
task waits for it, puts the rule up in the real stack's own
.CW ipmux
\- source, protocol, destination port \- and takes it down when the
holder writes
.CW down .
Proof, a criterion of the pair check: the client writes the attribute
up, stack B diverts the client's SYNs and counts them before
.CW tcp.c
sees them, the client writes it down, and the connect held until then
is accepted and answered.
.PP
Making the firewall a \[*p]p write, where the cache already held a
\[*p]p wire, found that the server served one connection at a time: a
cache holding its connection open for streams starved every other.  So
the server serves each connection on a kproc of its own
.CW ( pipconn ),
each delivering its own sessions' stream frames to its own fd; a
stream stops when its connection closes, though the session lives on;
and a session with no open fid is reaped when its connection closes,
so a table of them does not fill.  The one shared reply buffer is held
across a group's build by the flag of item 9, so two connections do
not cross.
.PP
.B "13.  The loader refuses, and the stall is understood."
Done, both halves.  When the firmware will not give up the kernel's
load region
.CW ( claimpages
fails), the loader no longer reads into it anyway: it prints the
firmware's memory map, region by region
.CW ( printmemmap
in
.CW efi.c ),
says the region it links at is not free, and halts \- reading into
memory that is not the loader's is what the stall was, so it refuses
rather than corrupt.  And the stall itself: with
.CW claimpages
claiming the load region first, twenty boots in a row stalled none
(the count run automatically, each boot to
.CW "osprey: hello world" ),
so the test harness's restart \- which used to start a stalled boot
over up to twice \- is gone; a stall now times the run out, as a real
fault should.  The band-aid is removed because the thing it hid is
fixed, and measured to be fixed.
.PP
.B "14.  One layout for the data area."
Done.  The offsets are one enum in
.CW ospreydata.h
\- the select arms and the message a select takes off the output
queue, the 9P a client and its server exchange, the buddy's argument
and data blocks, the migration header and staging, the pi-p tickets,
and the block and network descriptors \- which
.CW ospreyabi.h
includes and every user reads, in both the kernel's header world and
the user program's.  The header carries its own check: one enum value
is a sum of
.CW 1/(region\ ends\ before\ the\ next\ begins)
terms, so a layout where two regions that share a data area overlap
divides by zero and will not compile.  Proof: the enum is read in six
files that held the constants before, and moving one offset to overlap
another fails the build with a divide check, as it should.
.PP
.B "15.  The pc64 interrupt-path bug."
Two things were once one.  The idle server faulting after a two-machine
run
.CW ( "pc=0xffffffff" )
was run down under item 9: it was the personality's one shared reply
buffer, reset by a stream tick under a group that had slept mid-build,
not a kernel interrupt-path bug at all \- and it is fixed there.  What
remained was the kernel half, said to be reproduced by a user driver
taking a legacy interrupt at CPL3.  The tooling the plan named is
built: the trap handler snapshots the return frame on the way in for an
interrupt from user mode and, on the way out, when no note was
delivered and no fixup moved the pc, checks it is unchanged
.CW ( ospreytraptrace ,
armed by the config).  And the reproduction: the i8042 driver spins two
hundred million times at CPL3 while the clock and device interrupts
land, the window the bug was said to corrupt.
.PP
The tooling found the bug in the hunt, not in the kernel.  A first cut
kept the snapshot per processor, and it reported the return corrupted
four boots in fifteen \- but every one was a valid pc changing to
another valid pc, because a trap that sleeps and reschedules lets
another process's trap overwrite the shared snapshot; the frame was
never touched, the instrument was.  This is the shape of the thing that
made forty-six earlier traces inconclusive: an interrupt from user
mode that reschedules is normal, and an instrument that does not hold
its snapshot on its own stack cannot tell that from a fault.  With the
snapshot a local, so a reschedule cannot reach it, fifty-two boots of
the reproduction \- two hundred million CPL3 iterations each, thousands
of interrupts taken from user mode \- corrupted no return and panicked
none.  The
.CW pc64
trap entry passes its argument in a slot of its own
.CW ( "PUSHQ SP" ),
not aliased to a saved register the way the arm64 entry's was before
that port's fix, so the shape the plan guessed at is not present here;
whatever the standing corruption was, the reproduction no longer
reproduces it, and the two-machine runs, whose idle fault was item 9's,
are clean nineteen criteria in a row.  The honest reading is that the
kernel half is gone \- fixed by earlier work on this branch, or a
figure of an instrument that could not hold still \- and the tooling to
tell, and to catch it should it return, is in the tree.
.PP
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
migrating as a group, is built on one machine (the group is stopped and
carried into containers of its own sharing the moved memory) and one
process at a time across a wire (its pages carried to another kernel
and resumed there); and the personality the library carries has grown
from a name space and a directory read to the file operations, the real
IP stack, a driver for the disk and one for the network, both above the
kernel, and \[*p]p about its files on the ring and on a wire.
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
For either binary the buddy is loader and pager as well: the binary is
a file in the buddy's file system and every page of it arrives by a
fault the buddy answers.  The Plan 9 a.out is paged the same way as the
Linux ELF now \- the buddy lays it out as three pieces and supplies
each page from its file
.CW ( p9buddy_page ,
by
.CW img->kind ),
which the p9buddy check shows: the legacy a.out laid out by the buddy
and its pages supplied by fault, exactly as the Linux binary's are.
What is left is breadth, not kind: the buddy maps the file calls the
demonstration makes \- open, read, write, close, create, remove, stat,
seek, pipe, bind, mount, errstr \- and rc or rio would need far more of
the Plan 9 ABI than that.
.NH 1
Running real programs on the two personalities: a plan
.PP
A program runs on the microkernel two ways, and rio should run both.
On the server personality (the p9pair, p9buddy and p9linux configs) a
program runs in its own container and a peer container \- the buddy \-
answers its system calls over the ring; this is arrangement two, a
process boundary between the program and the OS.  On the library-OS
personality (p964, xup64) the personality is compiled as a library
linked into the task, and the program calls
.CW namec
and
.CW open
as ordinary functions in its own address space, only the four
microkernel services trapping to the kernel; this is arrangement three,
the exokernel shape.  Today a hand-written demonstration binary runs on
two, and the library-OS task runs as itself on three; neither starts an
arbitrary program, and rio runs only on the full
.CW pc64
kernel.  The plan brings a real program, and then rio, to both.
.NH 2
Track two: the server personality runs an arbitrary program, then rio
.PP
.B "Phase 2.1: exec carries arguments, and an arbitrary in-tree binary runs. Done."
The exec request passed only the program's name
.CW ( ring_exec ,
.CW ReqExec ),
and the a.out is entered with
.CW argv0
the name and nothing more.  A real program wants
.CW argc
and
.CW argv .
The request carries an argument vector, the kernel lays it on the new
program's stack the Plan 9 way \- the strings, the pointer array,
.CW argc ,
and the
.CW _tos \-
and an ordinary in-tree libc program, not the hand-written demo, runs
under the buddy: the tree already builds several
.CW ( Osprey/amd64/bin :
.CW o9cat ,
.CW netsrv ,
.CW fb ) .
Done: the request carries the vector packed in the data area
.CW ( ring_execv ),
the kernel copies it into the child and lays it on the new program's
stack, strings and pointer array and a nil, entered with the stack
pointer at the array
.CW ( ospreyenteruservec ),
and the entry trampoline
.CW ( init9.c 's
.CW _main )
takes the array and calls
.CW startboot .
A real
.CW cat
.CW ( os/osprey/cmd/p9/catp9.c ,
an ordinary Plan 9 binary that knows nothing of Osprey) is embedded as
.CW /boot/cat ,
exec'd as
.CW "/boot/cat /n/hello" ,
receives its two-element argv, opens the file through the buddy and
writes its bytes \- "version 42 of forty..." \- back to the console, and
exits.  One criterion of the pair check.
.PP
.B "Phase 2.2: a shell."
A shell forks, execs, waits and pipes \- the buddy answers all four
already.  What it wants beyond the demonstration's file calls is the
handful a real program's libc reaches for: heap growth
.CW ( brk ),
.CW dup ,
.CW fd2path ,
.CW sleep ,
the note calls in full.  Each missing one is added and proven by a
program that makes it.  A small shell, built in-tree against the same
libc, runs under the buddy and executes a script that runs a command and
pipes its output to another.
.PP
.B "2.2a: dup."
Done.
.CW DUP 's
Plan 9 number (5) is reused by the personality for select-over-arms,
which the ring clients call, so for a legacy program the number had to
mean two things at once.  The config's
.CW xselect
branches on
.CW up->buddyimage :
a program whose text and data are a buddy image dups through the buddy's
descriptor table
.CW ( Bdupfd ),
everything else runs the real select.  The distinguisher had to be that
and not merely having a server \- a ring client has a server too, and
clobbering its select with a dup regressed seventeen pair criteria until
the branch was narrowed.
.CW /boot/cat
dups the descriptor it opened and reads the file through the duplicate.
.PP
.B "2.2b: brk and fd2path."
Done, and they divide the way the paper's two halves do.  Heap growth is
memory, which is the microkernel's own service and not a file the buddy
holds, so
.CW brk_
is answered in the kernel
.CW ( ospreybuddybrk ,
called from the config's
.CW xbrk
for a buddy image and from
.CW ibrk
on
.CW BSEG
for anything else): it moves the top of the same heap segment
.CW ospreyexecbuddy
made a page above the image.  An ask below that segment's base is not a
refusal but the truth about the layout \- the span from the linker's
.CW end
to the page boundary the heap begins at is inside the image's own bss,
which the buddy already supplies as zeros \- so libc's first
.CW sbrk ,
which asks for
.CW end
plus a few bytes, succeeds having moved nothing.
.CW fd2path
is the other half: the buddy holds the descriptor table, so it answers
from the
.CW Chan 's
own path in the name space the container's buddy resolved it in
.CW ( p9fd2path ,
by
.CW chanpath ).
.PP
Two things in it are worth writing down.
.CW fd2path (2)
yields 0, not a byte count, and the kernel's copy-back is driven by the
count, so the buddy answers with the length it wrote \- which says how
much to copy \- and the kernel turns that into the call's 0; without the
translation the program would read an uninitialised buffer and a test
that printed it could still look plausible.  And a small
.CW malloc
would prove nothing about growth, since it lands inside the image's own
bss:
.CW /boot/cat
asks for half a megabyte, far past the one page exec left above the
image, writes a pattern the length of it and reads every byte back \-
which the check asserts by the break really moving that far, not merely
by the call returning.
.PP
The heap crosses a wire now too.  The migration header carried the
segment array after two words; a process that arrived on another machine
got
.CW linuxheap
set to \-1, so its first
.CW brk
there would be refused for want of a heap even though the segment had
crossed by index like all the others.  The header carries two more words
\- the heap segment's index and the break in it \- and the taker restores
them.  The header's shape was written down twice, in the kernel and in
the personality that walks it
.CW ( p9ip.c 's
.CW "hdr + 2" ),
and growing it in one place broke every migration criterion of the wire
check until the constant moved to
.CW ospreydata.h
.CW ( Odmighdrwords )
where both sides read it: the same duplicated-layout hazard item 14
removed for the data area, in the one header it had not reached.
.PP
.CW sleep
and the note calls are already in and already proven: a legacy process
gets Plan 9's
.CW sleep (2)
with the milliseconds it asked for
.CW ( xsleep 's
.CW buddyimage
branch, item 9's minute-long sleep), and
.CW notify (2)
and
.CW noted (2)
are answered by the config
.CW ( xnotify ,
.CW xnoted )
with two pair criteria over them \- a note that is not a fault,
delivered to the program's handler and resumed from with
.CW noted(NCONT) ,
and a declined fault the program catches itself.
.PP
.B "2.2c: exec(2) in place."
Done.  A shell forks and then execs, and the exec it makes is not the
one the personality had: the exec request
.CW ( ring_execv )
starts a program in a container of its own, while this one replaces the
caller's own program in the caller's own container, keeping its
descriptors.  It is in two parts and the order between them is the whole
of it.  Everything that can fail happens first, while the process is
still whole: the name and the argument vector are copied out of the
address space that is about to go \- they live in it, and the entry path
reads them after the mapping has changed \- and the buddy is asked to lay
the new binary out.  Either can refuse, and a refusal is
.CW \-1
to a process that goes on running.  Only then does the second part run,
which cannot fail into anything the caller could survive: the old
segments go, the new ones are made, and the process enters the new
program without returning through the system call
.CW ( ospreyexecself ,
the config's
.CW xexec ).
.PP
The buddy had to change with it.  Its
.CW EXEC
closed the running image's file before it knew whether the new binary
would parse, so an exec of a name that is not there left a process that
could no longer fault a page \- a shell's mistyped command would have
killed the shell rather than printed an error.  It now reads the new
binary into locals and commits the image record only when it has parsed,
which is what makes the refusal a refusal.  And leaving the kernel by
the entry path rather than by the system call's return leaves the call's
error label standing unless it is dropped: not an error the first time
or the tenth, an overflow after enough execs, which is why
.CW /boot/exec
execs twenty times over and reads through the descriptor it opened
before the first every time.
.PP
Two bugs fell out of it, and the second is worth the space.  The first:
Plan 9's
.CW seek (2)
yields its answer through a pointer libc passes as the first argument
.CW ( "seek(vlong *ret, fd, n, type)" ,
as
.CW sysseek
has it), and the buddy's marshalling read the descriptor out of that
pointer's slot, so a legacy program's every seek had been of a descriptor
made from an address.  The second is underneath it: a Plan 9 system
call's arguments arrive one to an eight-byte slot, but an
.CW int
fills four of its slot and the other four are whatever the stack held \-
.CW 0xfefefefe ,
the fill a fresh stack carries \- so the descriptor, mode and flag
arguments were reaching the buddy with rubbish in their top halves, and
had been working by whatever happened to lie there.  The seek was
failing or not by the same luck, which is what made it visible at all.
.PP
The cut to four bytes has to be a mask.  This tree's
.CW 6c
does not emit a narrowing cast to an unsigned type from a 64-bit value:
.CW (uint)x
and
.CW (ulong)x
of a
.CW uvlong
compile to the whole eight bytes with no truncation at all, while
.CW (int)x
compiles to
.CW MOVLQSX
and is right.  So the first cut of the fix changed nothing, and the
instrumentation that showed
.CW 0xfefefefe00000003
arriving at the buddy showed it arriving there after the fix too.
.CW "& 0xffffffffULL"
is what the code uses, and the reason is written beside it.
.PP
.B "2.2d: the shell."
Done.
.CW /boot/sh
is an ordinary Plan 9 program - one command a line, words at blanks,
stages at
.CW | ,
.CW #
a comment; no quoting, no variables, no redirection to a file, a shell
for the demonstration and not one to live in.  It is the smallest
program that needs all four of the things a shell needs: it forks a
process for each stage, execs it in place, makes a pipe and dups one end
onto each stage's standard descriptor, and waits for each and reads its
exit status.  It reads its script from a file the client wrote to the
disk over 9P, so the script is a file in the buddy's name space like any
other, and every one of its calls is answered by a peer container over
the ring.  Proof: the script's first line runs a command, its second is
a pipeline, and the four hundred and eighty-five bytes of
.CW /n/hello
cross the pipe from one legacy process to another and are counted at the
far end.
.PP
Two things had to change under it, and both are about the shape of the
personality rather than about the shell.
.PP
The first: a forwarded system call is served on a kproc now, not in the
service loop's own call stack.  Serving inline is fine while every call
answers at once, and a pipe is the first that does not - the pipeline's
second stage reads a pipe its first stage has not written yet, the read
blocks in the buddy, and blocking there blocks the loop that would have
carried the first stage's write.  The whole personality stopped and its
cooperative scheduler said exactly what had happened
.CW ( "no runnable proc" ).
This is the same shape item 12 found on the pi-p server, and it has the
same answer.  A pool of four workers, not a kproc for each container: a
kproc costs a 32K stack and a slot in the scheduler's table, and a
container that never blocks would spend both for the whole boot; with
all four busy the call is served inline as before, which is no worse
than it was.  Every write to the reply queue stays in the service loop,
so two workers finishing at once cannot cross there - item 9's lesson,
applied before it could be relearned.  A call that does not block still
finishes in the pass that dispatched it, since
.CW runkprocs
runs the worker at once rather than at the next tick; the kernel's wait
for a forwarded call is thirty seconds now rather than the eight hundred
milliseconds its own asks of the buddy get, because a read of a pipe
waits on another process and not on the buddy.
.PP
The second is where a write goes.  A legacy program's writes to 0, 1 and
2 went straight to the console, by the number, which is right until a
shell dups a pipe onto 1: the first stage's output then went to the
console and the second stage read an empty pipe.  Routing every write to
the buddy instead fixes that - the buddy holds the descriptor table and
prints the console ones itself - and it was tried, and it broke the two
note criteria: it turns every legacy
.CW print
into a ring round trip, and so into a call a note can interrupt, and an
interrupted call and the one the note handler makes share the
container's one data area, so a line was lost and another printed twice.
What is in the tree instead keeps the console path and marks the
exception: the kernel sees every
.CW dup
and
.CW close
a legacy program makes, so it knows which of 0, 1 and 2 have had
something else put on them
.CW ( up->buddyredir ,
carried across fork and across an exec in place, cleared for a program
the exec request starts), and only a redirected descriptor leaves the
console path.  The interrupted-call hazard is still there for a
forwarded call a note interrupts; it is now reached only by a program
that redirects, and it is written down here rather than papered over.
.PP
One more bug was under the pipeline, and it is worth saying how it was
caught rather than only what it was.  When a container went, the buddy
closed its descriptors from three upward, which is right only while
nothing has redirected: a shell puts the pipe's write end on descriptor
one, so the write end outlived the process that held it and the reader
at the other end never saw end of file.  What made this hard to see is
that the pipeline worked anyway - every byte crossed, the count at the
far end was the whole of the first stage's output, and the second stage
finished - because the forwarded call's own thirty-second bound
eventually gave up and the program read
.CW \-1
where it expected 0.  The two are the same byte count.  So the program
says which it got, and the criterion asserts the 0: without that line
the test passed while the pipe was broken, for thirty-five seconds a
run, and would have gone on passing.
.PP
Phase 2.2 is done, and all of it is the
.CW p9pair
configuration, whose check runs the legacy program with a full buddy
beside it; the
.CW p9buddy
and
.CW p9linux
configurations carry neither the dup branch nor
.CW xbrk
nor
.CW xexec ,
and their legacy demonstrations do not reach for any of them.  What the
buddy answers is now open, read, write, close, create, remove, stat,
fstat, seek, fd2path, dup, pipe, bind, mount, errstr, rfork, await and
exec, with brk in the kernel beside them - enough for a shell, and named
here so that what rio will want beyond it can be measured against it.
.NH 2
Three things the checks turned up, and what they were
.PP
Five phases in one run of work left three checks failing once each and
passing on retry \- the note criterion, a pair criterion, two wire
criteria \- and a "transient" recorded three times is a finding, not
noise.  All three were the same thing, and the evidence is a line in a
wire log:
.CW "\&...it opened /n/hello thuser fault: read addr=0x0..." .
The sentence the criterion matched was cut in half by a kernel print.
.PP
Both writers already go through the console task's FIFO
.CW ( putstrn0
routes the kernel's print there when a task is running, and the
personality's write reaches the same
.CW ospreyconsput
under the same lock), so the order is one queue \- until the queue
fills.  A full FIFO makes the caller write the port itself, which is
right for a panic and wrong for everything else: the task is pushing
queued bytes at that moment and the two writers cross.  The FIFO was
sixteen kilobytes and a run put a kilobyte and a half round it.  It is a
hundred and twenty-eight now, and three wire runs in a row are clean
where single runs had been failing; the count of what still went direct
is printed at the end of a run and is the number to watch.
.PP
Two real faults were under those runs as well.  The personality's arena
\- a bump allocator that never frees \- ended a two-machine run at
4183184 of 4194304 bytes used and panicked in
.CW kproc
for want of a stack.  What ate it is kprocs: every one costs a 32K stack
out of the arena and none is given back, a kproc per pi-p connection and
four more for the workers of 2.2d.  Twelve megabytes now, which costs no
memory until touched \- the arena is bss, and the kernel fills a bss
page only when it is first written.  And the pi-p wire's connect had one
try: the two machines boot independently and neither waits, so a connect
that arrived before the far end was listening failed both ticket
criteria together for a reason that had nothing to do with tickets.  It
retries now, the same wait the migration path already makes for the same
reason.
.PP
.B "Phase 2.3: rio."
rio is 9front source this tree does not carry, so its binary is built on
the disk against the disk's libc and carried in, the way the draw
server's compositing core already is.  The buddy answers the rest of the
ABI rio's libc uses, and rio's name space \- given by the buddy \- holds
.CW /dev/draw ,
.CW /dev/mouse
and
.CW /dev/kbd ,
served by the user-level drivers already built.  Proof: rio draws its
menu and sweeps a window on the server personality, as it does on
.CW pc64 ,
but with its system calls answered by a peer container over the ring.
.PP
.B "What 2.3 costs, measured before building it."
One clause of the paragraph above is wrong and the rest is right for a
reason already written down higher up: the section on the draw server
records that this host's linker cannot read the prebuilt 9front
libraries, and that building on the disk is what that costs.  What
follows is the same fact counted, and the ABI measured against it.
.PP
The wrong clause is that rio is source the tree cannot have.  It is twelve files \-
.CW rio.c ,
.CW data.c ,
.CW fsys.c ,
.CW scrl.c ,
.CW time.c ,
.CW util.c ,
.CW wctl.c ,
.CW wind.c ,
.CW xfid.c ,
.CW dat.h ,
.CW fns.h ,
.CW mkfile
\- 6407 lines at 9front revision
.CW a0a079f4054f88eabcb2c2e6d20f3ee4a1908b78 ,
and its mkfile names five libraries:
.CW libdraw ,
.CW libframe ,
.CW libthread ,
.CW libplumb ,
.CW libc .
The tree already carries all five, built, in
.CW 9front/amd64/lib ,
with their headers in
.CW 9front/include ,
and the tree's own
.CW 6c
compiles all nine of rio's C files against those headers with no
warnings, and compiles the four libraries' own sources too \- 63 of
.CW libdraw ,
9 of
.CW libframe ,
25 of
.CW libthread ,
3 of
.CW libplumb .
The compiler is not the problem.
.PP
The linker is, and the count is the part that is new.  Nothing in this
tree has ever linked
.CW 9front/amd64/lib ,
and the reason is that it cannot:
.CW 6l
here reads 228 of the 262 members of
.CW libc.a
and rejects the other 34 with
.CW "opcode out of range 665" ,
and rejects one member of
.CW libdraw.a
the same way.  Those archives were built by 9front's own
.CW 6c ,
which emits instructions past the end of this linker's table.  The
tree has a workaround for this already, without naming it as one:
.CW buildsh.sh
compiles four modules out of
.CW lib9/
and links them ahead of the archive, and all four \-
.CW utfnlen ,
.CW vsnprint ,
.CW dofmt ,
.CW vfprint
\- are in the 34.  It works for a program that formats a little.  It
does not scale to rio, which reaches the allocator
.CW ( pool ,
.CW malloc ),
the rune formatter and the Dir conversions, and the archive's own
decomposition is not 9front's source decomposition \- 57 of its members
have no same-named source file at that revision, which are the
generated system-call stubs and the Unicode tables.  Building a libc
here from source would mean generating those stubs, and
.CW sys/src/libc/9syscall
carries only a
.CW mkfile
and
.CW sys.h ;
the numbers would have to come from this kernel's table, not 9front's.
So rio's binary is built where the toolchain matches the archives \-
which is the disk, as the paragraph above said, but for the linker's
reason and not for want of source.
.PP
That last step is wrong.  It was committed, it stood for two phases,
and 2.3c below is what replaced it, so it is worth saying exactly where
the reasoning went off.  The stubs never needed generating, because the
stubs were never the part this linker cannot read.  Counted this time
rather than carried forward: 31 of the 34 unreadable members have a
same-named source file at that revision, 58 members have no same-named
source in the import, and 55 of those 58 read fine.  Two of that 58 are
there by choice rather than by absence:
.CW main9
and
.CW main9p
do exist at that revision and were deliberately not taken, because this
tree enters a program through its own glue.  Counted against 9front
rather than against the import, then: 33 of the 34 unreadable members
have source at that revision, and the one that does not is
.CW runenorm ,
a generated table nothing here reaches.  The claim the composition
rests on is narrower and it holds: not one of the 34 is a system-call
stub, so the stubs \- the members with no source at all \- are every one
of them readable.  So the two halves compose:
build from source what the linker rejects, keep the archive for what it
is the only source of, and put the source-built archive first on the
link line.  I did not try it because I had concluded it was impossible;
the conclusion was one unchecked step long.
.PP
The other cost is the one to size before starting.  What rio and its
four libraries ask of the kernel, counted over their sources at that
revision:
.CW alarm ,
.CW bind ,
.CW chdir ,
.CW close ,
.CW create ,
.CW dup ,
.CW errstr ,
.CW exec ,
.CW mount ,
.CW noted ,
.CW notify ,
.CW open ,
.CW pipe ,
.CW pread ,
.CW read ,
.CW write ,
.CW remove ,
.CW rendezvous ,
.CW rfork ,
.CW seek ,
.CW sleep ,
.CW stat ,
.CW fstat ,
.CW unmount ,
.CW nsec ,
and
.CW postnote ,
which is not a system call but a write to
.CW /proc/n/note ,
with the process id in it.
The buddy answers open, read, write, close, create, remove, stat,
fstat, seek, fd2path, dup, pipe, bind, mount, errstr, rfork, await and
exec.  The gap is
.CW alarm ,
.CW chdir ,
.CW notify ,
.CW noted ,
.CW postnote ,
.CW rendezvous ,
.CW sleep ,
.CW nsec
and
.CW unmount
\- nine.  Seven of them are not file operations, which is the shape one
would want: the buddy is a file personality and those seven are time,
notes, and a place to block.  The other two are files, which is the
opposite of what this counting assumed and is the first thing the
section after this one records.  All nine are answered now, three of
them before this measurement was taken; 2.3a and 2.3b below are where
the other six were built, and what is left of 2.3 is the binary.
.PP
One of the nine looked like it would end the phase and does not.
rio calls
.CW proccreate
six times, which is
.CW rfork(RFPROC|RFMEM)
\- a second kernel process in the same address space \- and two
containers sharing an address space is not what a process boundary
between a program and its operating system means.  But the address
space is the microkernel's to give, not the buddy's, the way
.CW brk
already is, and
.CW legacyp9.c
already asks for
.CW rfork(RFPROC|RFMEM)
twice and gets it.  So
.CW proccreate
is answered where it belongs and the file half still crosses the ring.
.PP
And rio is not the only binary to carry.  The
.CW p9pair
container has no 9front userland at all, so
.CW /dev/draw ,
.CW /dev/mouse
and
.CW /dev/kbd
have to be served inside it, which means the draw server and the mouse
and keyboard servers come in beside rio, or the personality serves them
itself.  On
.CW pc64
those are built natively on the disk by
.CW riorun.rc ;
they are four more binaries, not one.
.PP
.B "2.3a: the calls beyond the files, and the two that were files."
Six of the nine were genuinely missing.
.CW sleep ,
.CW notify
and
.CW noted
were already in, as the plan said.  All six are in now, each answered
where it belongs, and two of them turned out to be files rather than
calls.
.PP
.CW chdir (2)
and
.CW unmount (2)
are the buddy's, because a working directory and a mount point are name
space and the buddy is the name space.  The working directory is the
.I container's ,
not the worker's: the buddy answers a call on one of four shared worker
processes, so setting
.CW up->dot
would put whichever container chdir'd last in front of every other.  It
is kept beside the container's
.CW Pgrp
and swapped in around its calls the same way, and swapped back with a
flag rather than with a nil test, since a worker's own dot may be nil
and nil would then mean both "nothing saved" and "put nil back".  It
crosses a fork with the name space, as Plan 9's does: the child of a
container that had chdir'd would otherwise start with none and fall
back to the worker's, which is the buddy's own root, and its relative
names would resolve somewhere its parent had never been.  It does not
cross a migration, and that is a limit and not an oversight: a crossing
rebuilds the private name space by replaying the binds recorded for it,
and the working directory has no such record in the wire form.  A
container that chdirs and then moves is at the buddy's root on the far
side \- and since a move carries a group, a parent that chdir'd, forked
and then moved loses it on both sides, the child's inherited directory
with it.  Carrying it wants a record in the migration's wire form
beside the binds, which is a change to a layout two machines read and
is not made here.
.CW unmount
is
.CW sysunmount 's
body, which this configuration cuts: the mount point is named with
.CW Amount
and what is taken off it with
.CW Aunmount ,
and
.CW cunmount
takes the mount point first.  Written the other way round it
dereferences a nil at
.CW mnt->umh
and takes the buddy down, which is what the first run did.
.PP
.CW alarm (2)
and
.CW rendezvous (2)
are the kernel's, because a clock and a place to block are not files.
.CW alarm
is two lines over
.CW procalarm ,
and the two lines were not the work: nothing on this path had ever
started the alarm kproc.
.CW init0
starts it for the full personality;
.CW proc0 's
microkernel branch did not, so
.CW procalarm
recorded the deadline and no process ever read it - an alarm set was an
alarm that could not arrive.
.CW rendezvous
is Plan 9's
.CW sysrendezvous ,
also cut with sysproc.c, over machinery that is not cut: the
.CW Rgrp
and its hash, the
.CW Rendezvous
process state proc.c already unwinds when a note arrives, and
.CW newrgrp .
The group is made on the first
.CW rfork(RFPROC|RFMEM)
and shared with the child, so a thread and the process that made it can
meet and a plain fork's child cannot meet a stranger's tag.  This is
what
.CW proccreate
is built on, and rio makes six of them.
.PP
.B "nsec(2) is not a system call, and neither is postnote."
The measurement above counted names in the sources and called all of
them calls.  Two are not.  9front's
.CW nsec (2)
reads
.CW /dev/bintime
and takes the first eight bytes of it, big-endian; the
.CW _NSEC
trap is there for binary compatibility and no current libc uses it.  So
a program asking the time is asking its
.I name space ,
and the file has to be in it.  It is now:
.CW devtime.c ,
one file, bound as
.CW #T
onto
.CW /dev ,
in the personality that holds a legacy program's name space.  The clock
behind it is not the personality's - this is a user task and
.CW p9shim.c 's
.CW seconds ()
answers 0 - so each read asks the kernel (a new request,
.CW ReqNsec ,
beside the
.CW ReqSettime
that sets it) rather than caching a value that would be stale by the
next read.
.CW _NSEC
is answered too, in the kernel beside it, for a program whose libc is
old enough to use it.
.PP
That left a program still dying on its first
.CW nsec ,
and the reason is worth keeping.  libc's
.CW nsec
keeps its
.CW /dev/bintime
descriptor in a
.I private
\- one word per process, from
.CW privalloc (2)
\- and its callers do not check what
.CW privalloc
returns.  It returns nil when there are no privates, and there were
none: the block is set up by
.CW _callmain ,
which runs from libc's own
.CW _main ,
which is a member of the archive this host's linker cannot read, and
.CW init9.c
is the entry instead.  So every legacy program this tree builds had no
privates and no Tos at all, and the first call that wanted either stored
through a nil.  Both are
.CW init9.c 's
now, since it is what stands in for
.CW _main :
the privates are an array on its own
.I frame ,
not in the bss, because
.CW rfork(RFPROC|RFMEM)
copies the stack and shares the bss and a private has to be per process;
and the Tos is filled by the kernel and its address passed one word past
the argument vector's nil, because the first argument register carries
the vector where Plan 9 would have carried the Tos.
.CW ospreyenteruservec
lays it out, which is where
.CW ospreyenteruserargs
and so every exec goes as well.
.PP
There are two entries now, and the reason is a segment.
.CW init9.c
is the entry a flat-loaded program takes: the file server of the
microkernel configurations is loaded by
.CW ospreyloadprog
as one
.CW "SG_TEXT | SG_RONLY"
segment, its strings on the stack and no data segment at all, so it
cannot store into libc's data - and setting
.CW _privates
is exactly that store.  The first sweep with one entry showed it at
once: every microkernel configuration faulted writing an address in its
own image four instructions into the program.
.CW init9prog.c
is the entry for a program that has a data segment of its own, which is
every legacy binary the buddy lays out, and it is the one that takes the
Tos and gives libc its privates.  The two differ in nothing else, and
the word past the vector's nil is there for both: one reads it, one
ignores it.
.PP
.B "postnote, the sixth, and where the authority for a note lives."
.CW postnote (PNGROUP, ...)
is how rio interrupts what it started
.CW ( wind.c 's
.CW interruptproc ),
and libc's postnote is not a call either: it writes
.CW /proc/n/notepg ,
with the process id in the name.  It is the only one of the six whose
answer was not already written somewhere:
.CW chdir
and
.CW unmount
had bodies in
.CW sysfile.c
to port,
.CW alarm
and
.CW rendezvous
had bodies in
.CW sysproc.c
over machinery this kernel still links, and this had neither.
.PP
.CW devnote.c
is the file tree, bound as
.CW #p
onto
.CW /proc ,
and it holds two files under any number:
.CW note
and
.CW notepg .
The number is a container's identity, which is what a legacy program has
for a process id \-
.CW rfork (2)
returns it and
.CW await (2)
reports it \- and any number walks, because this personality does not
hold the kernel's table of containers and a listing it invented would be
a listing of nothing real.  Nothing lists there, and the code says so
rather than papering over it.
.PP
The write is where the two halves meet.  The personality serves the
file, because a name space is the personality's; the kernel posts the
note, because the processes are the kernel's.  So the write becomes one
request
.CW ( ReqPostnote ),
and the request carries three words, which is all a request carries
.CW ( Ospreynarg ):
the container to post to, the container asking, and whether it is the
group form, with the text at a fixed window in the caller's data area
.CW ( Odnote )
rather than at an offset, because an offset would have cost the word the
group flag needs.  A count above three is refused by the call with no
word about why, which is how the first version failed \- silently, and
looking like an authority refusal.
.PP
Authority is the part worth stating, and it is two questions, both
asked.  The caller is the personality and not the program, so the first
is whether this personality may speak for the container it names: is
that container one it serves?  The second is the program's own: may that
container post to the target \- is the target itself, or a container it
started?  The child table the kernel already keeps for
.CW await
is what answers it, so a container may interrupt exactly what it
started.  That is the least that lets a window system stop the command
in a window, and it is not "any container may note any other": the
program's note to container 1, which it did not start, is refused, and
the refusal is the kernel's, the personality only saying who is asking.
.PP
The group form is the one rio uses, and it is the one worth exercising
rather than merely writing: a note to a container reaches every
container that one started, so the demonstration's child forks one of
its own before it waits, which is a window's command with something
under it.  One write to
.CW /proc/n/notepg
and both the child and the grandchild take the note and end on it.  One
thing that demonstration leaves behind is worth writing down: the
grandchild's entry in the kernel's child table is never reclaimed.  The
table is freed only by a successful
.CW await ,
its parent ends on the same note, and nobody waits for it, so a group
noted this way costs an entry of the eight for the rest of the boot.
The demonstration leaks one and the run is clean; a program that
interrupted groups all day would fill it, and the failure then is
.CW rfork
returning \-1 somewhere else entirely.
.PP
What does not cross is the exit status.  A container's wait message is
.CW "0 0 0 ''"
whatever it exited with, which is older than this work and is not
claimed here: the criteria are that the note arrived at the handler and
the program ended on it, which is what the log shows.
.PP
One ordering fault came out of the runs.  The user-fault dump in
.CW trap.c
was
.CW iprint ,
which writes the port directly.  That is right when the machine is going
down and wrong for a fault a program survives \- two of the
demonstrations fault on purpose \- because it crosses whatever the
console task is pushing and cuts a line in half, and a criterion that
matches a whole sentence then fails on a sentence with a register dump
spliced through it.  It goes through the console queue now, in order
with everything else, except for a fault taken by the console task
itself: that one still writes the port, because the queue it would go
into is the one only that task drains.
.PP
The three kernel-side entries are
.CW p9pair 's
alone, as
.CW xbrk
and
.CW xexec
already were:
.CW p9buddy
and
.CW p9linux
carry neither the alarm nor the rendezvous nor the
.CW _NSEC
entry, and their demonstrations do not reach for them.  What is shared
by every configuration is the rest of it \-
.CW init9.c ,
.CW ospreyenteruservec ,
the buddy, the request the clock is read through, and the console
ordering.
.PP
Ten criteria of the pair check hold the six calls, the fork's working
directory and the Tos apart, and the pair check is 81 where it was 71.
.PP
.B "2.3c: the userland this tree builds itself."
The correction above is what made 2.3c worth trying, and the trying
took an afternoon.
.CW 9front/src
holds 471 files imported from 9front at
.CW a0a079f4054f88eabcb2c2e6d20f3ee4a1908b78 ,
the revision this work has been reading all along: 52 headers, 220
files of
.CW libc
.CW ( port ,
.CW fmt ,
.CW 9sys ,
.CW amd64 ),
63 of
.CW libdraw ,
35 of
.CW libthread ,
25 of
.CW lib9p ,
21 of
.CW libmemdraw ,
17 of
.CW libauth ,
13 of
.CW libmemlayer ,
9 of
.CW libframe ,
3 of
.CW libplumb ,
1 of
.CW libcomplete ,
and the 12 of
.CW cmd/rio .
.CW 9front/src/README
records the revision, what was left out and why, and that there are no
local changes to any of it \- the import is verbatim, and the two files
deliberately not taken are
.CW main9.s
and
.CW main9p.s ,
whose job this tree's own entry glue does.
.PP
.CW os/osprey/cmd/p9/build9front.sh
compiles the ten libraries with this tree's
.CW 6c
into
.CW 9front/amd64/lib-src :
.CW libc9.a
is 524102 bytes,
.CW libdraw.a
376296,
.CW libmemdraw.a
320356, and the rest smaller.
.CW build9bin.sh
links four binaries into
.CW 9front/amd64/bin-src
against them and the prebuilt archive behind them: rio at 369713 bytes,
and the draw, mouse and keyboard servers of
.CW os/osprey/cmd/draw
at 298081, 158217 and 158893.  Two link lines, not one, because rio
brings its own
.CW main
and
.CW lib9p
brings another.
.PP
The part that matters more than the four binaries is what the same
archive did to the programs that already boot.
.CW buildcat.sh ,
.CW buildexec.sh ,
.CW buildsh.sh
and
.CW buildlegacy.sh
each used to compile four modules out of
.CW lib9/
and link them ahead of
.CW Osprey/amd64/lib/libc.a :
.CW utfnlen ,
.CW vsnprint ,
.CW dofmt ,
.CW vfprint ,
the workaround named in the paragraphs above.  All four are gone.  The
line is now
.CW libc9.a
first and the prebuilt archive behind it, and the archive is there for
one thing only \- the generated system-call stubs, which are the part
no source at that revision contains.  So the source-built C library is
not an artifact off to the side that was linked once and measured: it
is in the boot image, and the criteria of the pair check are what say
it runs.
.PP
What exactly it runs is worth being exact about, because the check
cannot say it and I had to ask the linker.  Removing
.CW libc9.a
and adding back one member at a time until the link is clean names the
members each program actually requires from the unreadable 34, and for
all four programs it is the same three:
.CW vfprint ,
.CW dofmt ,
.CW vsnprint .
Every line those programs print \- which is every criterion the pair
check matches \- goes through formatting code compiled here from
source.  The fourth module the old workaround carried,
.CW utfnlen ,
was never required at all; it was linked because it was named on the
command line.  What the criteria do
.I not
reach is
.CW pool ,
.CW malloc
and the Dir conversions: those are in
.CW libc9.a ,
they build, and nothing that boots calls them yet.  That is not a
weakness of the arrangement, it is the same observation as before from
the other side \- they are exactly what rio reaches and these four
programs do not.
.PP
.B "What the switch found: the entry spilled its argument onto the vector."
The first sweep after the four programs were pointed at
.CW libc9.a
failed 25 of the 81 pair criteria, and the console says where: the
legacy program printed its working-directory lines and then
.CW "user fault: read addr=0x40 pc=0x201b1a" .
The linker's own listing
.CW ( 6l
.CW -a )
names that instruction
.CW "MOVL 64(CX),CX" ,
two instructions after
.CW "MOVQ _tos+0(SB),CX" ,
and the register dump has
.CW "cx 0x0" .
Offset 0x40 of a
.CW Tos
is
.CW pid ,
and the line is
.CW nsec.c 's
.CW "*pidp == _tos->pid" .
So
.CW _tos
was nil, and nsec(2) was simply the first code this tree has ever run
that dereferences it.
.PP
It was nil because the entry overwrote the vector it was given.  6c on
amd64 passes a function's first argument in
.CW RARG
and gives that register a home in the caller's frame at
.CW 8(SP) ;
a function that wants the argument after a call spills it there.  The
kernel entered a program with
.CW SP
equal to the argument vector, so that home is the vector's own second
word.  For a program with an argument it is
.CW argv[1] ;
for a program with none it is the nil that ends the vector, and the
entry's walk to that nil then runs off into whatever is above and reads
the word past the end - the address of the Tos - from the wrong place.
.CW touserv
in
.CW pc64/l.s
is the fix: it sets the stack two words below the vector and leaves
.CW RARG
naming the vector, which is the only thing the two ever had to agree
about.
.PP
The archive switch did not cause this and it is worth being exact about
what did, because the two arrived in the same sweep.
.CW init9prog.6
is not built any differently by it.  The spill arrived with
.CW init9tos.c ,
the factoring that put a call between receiving the vector and using
it; before that
.CW _main
had no call in between and 6c had no reason to spill.
.CW 6c
.CW -S
shows it plainly:
.CW init9.c ,
the flat-loaded entry, compiles to no such store, which is why
.CW pc64 ,
whose
.CW init0
enters that one, was never affected and stays on
.CW touser ;
.CW init9prog.c ,
which the four legacy programs take, and
.CW init9main.c ,
which so far only the four graphics binaries take and nothing has run,
both open with
.CW "MOVQ BP,argv+0(FP)" .
This is the first sweep since that factoring, and it caught both halves
of the clobber at once: the nil-terminator half in the program with no
arguments, and the
.CW argv[1]
half in
.CW /boot/cat ,
which is given a file to print.  Nothing latent shipped -
.CW init9tos.c
is part of this same piece of work and was never committed broken - but
the ordering is worth keeping: the factoring was written, tested against
the check it was written for, and the sweep that would have caught it
was the one this section is about.
.PP
The switch found one more, in the build script rather than the kernel.
.CW iar
.CW vu
replaces a member only if the new one is newer, and
.CW libc/amd64
is compiled seconds after
.CW libc/port
in the same run: fourteen of 9front's amd64 implementations \-
.CW memmove.s ,
.CW strcpy.s ,
.CW getcallerpc.s
and eleven others \- were losing to the portable C they are meant to
replace, which is not what 9front's own build does.  It is
.CW iar
.CW rvc
now, and the set of source files each of the four programs is built
from is the set the old link had, exactly, less
.CW utfnlen.c ,
which the old link carried because it was named on the command line and
which nothing needs.  This was not the cause of the 25 failures; it was
found looking for it.
.PP
.CW scripts/osprey-check-userland.sh
is the twelfth check, and it is a build check, which is the honest
name for it: it asserts that the ten libraries build, that the four
binaries link, and that each is a Plan 9 amd64
.CW a.out
with the 40-byte header and the entry at
.CW UTZERO+0x28
where the loader enters one.  Rio and the three servers have not been
run.  Nothing yet carries them into a container; that is 2.3d, and the
size to know before starting it is that the four binaries come to
984904 bytes, which at the five bytes of C an
.CW .i
array spends per byte of program is about 5.0 megabytes of source on
top of the 3428634 that
.CW p9prog.i
already is.
.PP
.B "2.3d: the first of the four, run."
The four binaries of 2.3c built and had not been run, so the next step
was to run one, and the one to pick was the smallest: the keyboard
server,
.CW os/osprey/cmd/draw/kbd.c ,
a hundred kilobytes of image where every legacy program before it was a
few tens.
.CW build9prog.sh
turns it into
.CW kbdsrvprog.i
and the personality carries it as
.CW /boot/kbdsrv ;
the pair client execs it with an argument.  What the log says, in order:
the buddy laid it out
.CW ( "a Plan 9 a.out, text 74648 data 26224 bss 1400" ),
the kernel demand-paged its five pages from the buddy, it was entered at
.CW 0x200028
through
.CW os/osprey/pc/init9main.c
\- the entry nothing had run until now \-
.CW ARGBEGIN
parsed the
.CW -m/dev
it was given, it asked for the segment it needs, said why it could not
have it, and exited 0 to a client that reaped it.  So a program of that
shape runs: three segments, its own
.CW main () ,
.CW libthread
and
.CW lib9p
above the source-built libc.  The pair check is 83 at this point.
.PP
It could only fail, and that is the point of it: this machine has no
keyboard ring to attach.  What it found on the way is that it could not
say so.  The line was
.CW "segattach kbdring: " ,
a colon and nothing, because
.CW errstr (2)
is a call like any other and the buddy answers it out of the error
string it keeps per container \- which is right for every call the buddy
served and empty for the ones this kernel served itself, which the buddy
never saw fail.
.CW up->errstr
is now both the message and the flag: a call forwarded to the buddy
clears it, because from then on the buddy owns the answer; a
kernel-served call that fails leaves its message there through
.CW error ();
and
.CW errstr (2)
is answered in the kernel whenever there is one to answer with, and
forwarded when there is not.  The line is
.CW "/boot/kbdsrv: segattach kbdring: bad arg in system call"
now, and that is a criterion.
.CW p9buddy
has the same arrangement for the same reason.
.CW p9linux
does not and should not: a Linux binary has no
.CW errstr (2)
to ask.
.PP
The limit is worth writing down rather than leaving to be discovered.
The invariant is only "a forwarded call clears it", so a kernel-served
call that
.I succeeds
between the failure and the
.CW errstr (2)
leaves the older message standing.  Plan 9 has that hazard too and for
the same reason, and what makes the keyboard server's line right is that
.CW sysfatal 's
own write to descriptor 2 is kernel-served and does not clear it.
.PP
I expected the frame buffer to be what stood in the way of the other
three, and the same log says it does not.  The
.CW p9pair
kernel carries
.CW headless
and its check boots QEMU with no display, so I read the draw server's
.CW segattach(0, ""framebuffer"", ...)
as unanswerable there.  Line 65 of the boot says otherwise:
.CW "osprey fb: exposed 1280x800x32 at pa 0x80000000 size 4992000 as \(dqframebuffer\(dq" .
The EFI loader writes
.CW *bootscreen
into
.CW plan9.ini
by itself, and
.CW ospreyframebuffer ()
in the microkernel boot path reads it, so a container on this
personality can map the screen today.  What the pair personality really
does not have is the keyboard and mouse rings, and that is deliberate
rather than missing:
.CW ospreymouseexpose ()
is called only where the kernel is the full personality, and the
library-OS boot arms the same interrupt into a container instead.
.PP
So the next of the four is the draw server, which wants the frame
buffer and nothing else \-
.CW oscursorstart ()
returns quietly when there is no mouse ring \- and which is also the
first thing in this tree that will reach
.CW malloc
and
.CW pool
out of
.CW libc9.a ,
the members 2.3c could only say were built.
.PP
.B "2.3e: the draw server, and the compiler bug under it."
The draw server is the second of the four and the first thing in this
tree to call
.CW malloc
in a container.  It ran, and it panicked:
.CW "bad magic" ,
out of
.CW blockcheck ()
in libc's
.CW pool.c ,
on the very first block the program allocated.
.PP
The block was not corrupt.
.CW panicblock ()
dumps what it rejected, and every field of the dump was right: the
magic was
.CW 0x0A110C09 ,
which is
.CW ALLOC_MAGIC ;
the size was 96, which is the header, the two words
.CW malloc
puts in front for its tags, sixty-four bytes of data and the tail; the
tail's two magic bytes were
.CW 0xBE
and
.CW 0xEF ,
its back pointer reached the header again, and the four guard bytes
past the end of the data were the
.CW datamagic
pattern for their addresses.  The string the program had just written
was there to read.  So the value the
.CW switch
had read and the value the dump printed were not the same value, and
that is not something memory does between two instructions of one
thread.
.PP
It was the compiler.
.CW blockcheck ()
switches on
.CW b->magic ,
a
.CW ulong ,
with six cases, and six is enough that
.CW swit1 ()
compiles a binary search rather than a chain of tests.
.CW "6c -S"
shows the pivot:
.CW "CMPL AX,$-894431969"
then
.CW JGT ,
a
.I signed
branch \-
.CW UNALLOC_MAGIC ,
and the half it selects holds
.CW DEAD_MAGIC
and
.CW ARENATAIL_MAGIC
only.
.CW "6c -K"
shows the table it was searching, and it was sorted
.I unsigned :
.CW ALLOC_MAGIC
first, because
.CW 0x0A110C09
is the smallest of the six as an unsigned number and the largest as a
signed one.  Sorted one way, searched the other.  Every allocated block
in the program fell through to
.CW default ,
which is
.CW "bad magic" .
.PP
The front end is where it comes from, and the comment two lines above
the fault says what was intended.
.CW gen ()
in
.CW utils/cc/pgen.c
coerces a switch expression to
.CW long
and writes
.CW "/* always signed */" ,
so every backend's pivot branch is signed on purpose; and
.CW doswit ()
in
.CW utils/cc/pswt.c
wrote
.CW "q->val = (long)c->val" ,
with a comment saying the cast is what gets a 32-bit switch right on a
64-bit machine.  It is \- on Plan 9, where
.CW long
is 32 bits and the cast sign-extends.  These compilers are built by the
host's own C compiler, where
.CW long
is 64 bits and the cast does nothing at all, so a case value with the
top bit set stayed positive and sorted above every other.  The fix is
to sign-extend from 32 bits without naming a type whose width can move
again.  It is in the front end, where the table is built, so every
backend that takes its cases from
.CW doswit ()
is fixed at once rather than eleven times; the pivot branch was read
back out of
.CW "6c -S"
for
.CW 6c ,
.CW 8c ,
.CW 7c
and
.CW 5c ,
which are the four this tree builds kernels with.
.PP
How far it reached is a question worth answering rather than assuming,
and the answer is measurable: build the old compiler beside the new one
and compile every file twice.  Of the 9front userland \- libc,
libthread, libdraw, libframe, libplumb, libcomplete, libmemdraw,
libmemlayer, lib9p, libauth, rio and the four servers \- exactly one
file's code changed, and it is
.CW pool.c .
Of the 59 files the
.CW p9pair
configuration compiles for itself, none.  That sweep did not recompile
the libraries the kernel links \-
.CW libospreykern ,
.CW libosprey ,
.CW libaml ,
.CW libkern ,
.CW libsec ,
.CW libmp
and
.CW libfis
\- so nothing is claimed about them beyond the shape of the bug: a
switch of five cases or more on an unsigned value, one of whose case
constants has bit 31 set.  A grep is more alarming than the truth here:
.CW date.c ,
.CW rio.c
and
.CW wctl.c
all switch on a value with
.CW "case -1:"
among small positives, which looks like the same shape, but a negative
constant was stored as a negative number by the old front end too, so
those tables were always sorted and searched the same way.  What was
wrong was only the unsigned constant with bit 31 set, and in this whole
userland only
.CW pool.c
has one.
.PP
Two build traps came out of the same afternoon and are fixed with it.
.CW utils/mkfile
listed neither
.CW 6a/6c/6l ,
the amd64 toolchain every kernel in this branch is built with, nor
.CW 0a/0c/0l ,
the riscv one: they had been built once by hand and never again, so
.CW "mk install"
in
.CW utils
rebuilt ten compilers and quietly not those six.  They are in the list
now.  And
.CW build9prog.sh
linked its program only
.I "if the binary was missing" ,
so a boot ran a drawsrv from an earlier build and reported symptoms
that had already been fixed.  mk decides when that script runs, from
the sources the
.CW pc64
mkfile names; the script now always links.
.PP
With the compiler right, the draw server runs.
.CW memimageinit ()
sets up memdraw's shared images, the device's own
.CW reset ()
and
.CW init ()
run,
.CW oscursorstart ()
returns quietly because there is no mouse ring on this personality, and
.CW postmountsrv ()
forks a container that answers 9P on a pipe and mounts it at
.CW /dev .
The screen is the frame buffer the microkernel exposed: 1280x800,
.CW x8r8g8b8 ,
4096000 bytes, the same one
.CW "osprey fb: exposed"
names at boot.
.PP
The mount is only half an answer, so the program is its own first
client.  It opens
.CW /dev/draw/new
through the mount it just made, reads back from the ctl file the client
number and the screen's channel and rectangle, and writes five draw
messages to the data file beside it: three
.CW b 's
to allocate a blue pixel, a green pixel and a one-bit mask of ones, and
two
.CW d 's
to fill the screen with the blue and put a 300x200 box of green in it.
That is what libdraw does, written out by hand so the demonstration is
the protocol and not a second library.  Every one of those opens, reads
and writes crosses the pipe to the other container.
.PP
And then it reads the frame buffer back, because a return code is not a
picture.  The word inside the box is
.CW 0x00ff00
and the word outside it
.CW 0x0000ff ,
which are the two colours asked for, in the order
.CW x8r8g8b8
puts them in memory.  Those are checked as numbers in the check, not
matched as text.  The pair check is 87.
.PP
Getting there cost one more finding, and it is about the shape of a
program rather than about draw.
.CW segattach (2)
adds a segment to the address space of the process that calls it, and
.CW RFMEM
shares the segments that exist at the fork.  The server attached the
screen lazily, on the first client's attach \- which happens in the
9P child, after the fork \- so the parent held the pointer with nothing
mapped under it and faulted the first time it read a pixel.  The screen
belongs to the program, not to one of its processes, so it is attached
before the program has more than one:
.CW ospreyfbattach ()
in
.CW kshim.c ,
called from
.CW main ()
ahead of
.CW postmountsrv .
.PP
That fault also showed up a defect in the personality itself worth
fixing on the way.
.CW panic ()
in
.CW p9shim.c
was
.CW "USED(fmt); print(\(dqp9: panic: %s\(dq, fmt)" ,
so every panic printed its format string and threw its arguments away:
the line that came out was
.CW "no runnable proc (deadlock), tick %lud" ,
literally.  It formats now.
.PP
One property the draw server leans on was worth proving on its own,
so the legacy demonstration proves it: the fork
.CW postmountsrv
makes is
.CW RFMEM ,
and what that shares has to include the heap, or the parent and the
9P child would each be allocating out of what they both believed was
their own arena.  The
.CW rfork (RFPROC|RFMEM)
in
.CW legacyp9.c
now writes into a buffer
.CW malloc
gave the parent before the fork and the parent reads it back after, so
"one address space" is checked for
.CW sbrk
memory and not only for the bss the migration test already covered.
That is one more criterion, and it is what lets one
.CW mainmem
serve both halves of a lib9p server.
.PP
The honest limit of 2.3e was the name space: the mount lived in the
name space of the process that made it, and that process exits.  2.3f
below lifts it.
.PP
.B "2.3f: the server reached from another container."
The limit above was the name space: the draw server mounted itself in
the name space of the process that started it, and that process exits.
.CW postsrv ()
already knows how to do better \- given a name it creates
.CW /srv/<name>
and writes the pipe's end into it, which is how a Plan 9 server is
found by anything else on the machine \- so the draw server posts as
.CW draw ,
and the pair client execs the same binary a second time with
.CW -c ,
in a container of its own, as nothing but a client.  It opens
.CW /srv/draw ,
mounts it at
.CW /dev
for itself, is given a client number of its own on the same
1280x800 screen, and draws a box of red inside the green one the first
client drew.  Then it reads the frame buffer back: inside its own box
the word is
.CW 0x00ff0000 ,
and inside the first client's box but outside its own it is still
.CW 0x0000ff00 .
One screen, two containers, one server between them.  The pair check is
89.
.PP
Five things were in the way, and each was a real defect rather than a
missing feature.
.PP
First,
.CW /srv
was not in any name space.  The personality reaches the service
registry as
.CW #s
and had never needed the name; a program does, because
.CW postsrv
creates by path.  The create landed on the root device, which refuses
it, and
.CW postmountsrv
failed with
.CW Eperm .
.CW #s
is bound onto
.CW /srv
now, in the name space at boot, which is the one containers share
until they rfork one of their own.  It is bound
.CW MREPL|MCREATE :
without
.CW MCREATE
the same create said
.CW Enocreate ,
because a mount point that does not permit creation is not a place a
file may be made.
.PP
Second, the descriptor a container posts is the container's.
.CW postsrv
writes the number of one of its own descriptors into the file it made
in
.CW /srv ,
and the srv device resolves that number in the file table of whoever
writes \- which for a forwarded call is the buddy's worker, not the
container.  So
.CW /srv/draw
held whatever channel the worker happened to have at that number, and
mounting it spoke 9P at an unrelated device, which answered
.CW "unknown control request" .
The buddy translates now: a write to a file of the srv device has its
decimal descriptor rewritten from the container's table to the
worker's, and the count the caller wrote is what it is told it wrote.
.PP
Third, the personality could not say what was wrong.
.CW namelenerror ()
in the name space names the file an error is about with
.CW "%s: %#q" ,
and
.CW %q
is a verb
.CW quotefmtinstall ()
adds \- which nothing here had called, and whose
.CW fmtquote.c
was not linked.  Every error from the name space came out with a
literal
.CW %q
in it; the draw server's failure read
.CW "Eperm: %q" ,
which named neither the file nor, therefore, the missing bind.
.CW fmtquote
is linked now, with
.CW runestrlen ,
which it calls and which is one of the 34 members of the prebuilt
archive this linker cannot read, and
.CW quotefmtinstall ()
is called where the name space is set up.
.PP
Fourth, and worst,
.CW exits (2)
threw its status away.  The handler was
.CW "USED(list); ospreyexits(0)" ,
so every program that died \- in
.CW sysfatal ,
say \- was reaped by its parent as having succeeded, and every "exited
with status 0" in every log said nothing whatever.  The status string
is copied out, printed, and a non-empty one is a non-zero exit; an
unreadable status pointer is a failure too, and not a success by
default.  Two criteria had to be corrected rather than kept: the
keyboard server, which
.I sysfatal s
on the ring it has not got, exits 1 and says so, and the moved legacy
process, which ends by catching the fault it was given, exits with the
status
.CW "note handled" .
Both were asserting 0, and both were only ever true because the status
was discarded.
.PP
Fifth, and the one that took the most boots to see: a container's
forwarded call failed whenever the page holding the name it was called
with was not yet resident.  The first
.CW open (2)
a fresh container made returned \-1 with no error string set anywhere,
and the second of the same name succeeded; opening one directory twice
showed it, and naming a different directory first moved the failure to
that one.  That made it look like a property of the first call, and it
is not.  The first open of a string faults its page in and every later
open of the same string finds it there, so what the ordering was
showing is resident or not, not first or not.  That is also why
.CW /boot/cat ,
.CW /boot/sh
and
.CW /boot/kbdsrv
never tripped it: nothing they opened faulted in the middle of being
copied.
.PP
Three plausible causes were tried first and each was disproved by its
own instrumentation never firing: the request queue was ready
.CW ( ospreysubmit
never failed), the container's data area was mapped
.CW ( ospreydata
never returned nil), and the buddy was delegated
.CW ( ospreyserverof
was not nil).  Each of those three fixes was taken back out, because a
retry loop on the path of every forwarded call in every configuration
is not something to leave behind on a hunch.
.PP
The kernel log said the rest, in order: the call reaches
.CW ospreybuddyforward ()
with a good name pointer \-
.CW 0x22ff62 ,
the string in the program's own data \- the page holding it faults and
is supplied by the buddy from the program's file, and then there is a
request for the page at address
.CW 0 ,
which the buddy declines because no segment of the program covers it,
and
.CW "container 123's call 101 gave \-1: no reason set" .
101 is the page request's own operation, not the open's.  The call
being submitted was the page request, with the page request's
arguments, a second time.
.PP
.CW ospreybuddyforward ()
packs a forwarded call into the argument block the container shares
with the buddy, and it wrote the operation number into the first word
of that block
.I before
the switch that copies the rest.  Copying a name out of the container's
address space is what faults, and the fault is served by a nested
request to the same buddy through the same argument block; when that
returns, the first word and the arguments under it are the page
request's.  The outer call was then submitted carrying them.  The
operation number is written last now, immediately before the submit,
and the pages a call will read are faulted in before the block is
filled at all:
.CW ospreytouch ()
reads one byte of each page of a name or of a write buffer, so the
fault happens with nothing packed rather than half way through packing.
The touch is bounded by the length of the data block, because the
copy below it refuses a longer count anyway and walking a segment to be
told no is not work worth doing.
.PP
This is not a regression.  It predates every phase here \- it is on the
path of every forwarded call in every configuration with a buddy, and
has been since the forwarder was written.  What is new is that a
program finally opened a file whose name had not been touched yet.
.PP
.B "2.3g: the keyboard and the mouse, as the two files rio reads."
rio reads three files:
.CW /dev/draw ,
.CW /dev/mouse
and
.CW /dev/kbd .
2.3f put the first of them in a container's name space.  The other two
are there now, and the container that has all three started none of
them.
.PP
The plan said the keyboard and mouse rings the pair personality does
not arm are what stands in the way, and that was wrong twice over.  It
does arm them \- 
.CW ospreyuserprep ()
calls
.CW ospreykbdenable ,
.CW ospreymouseenable
and
.CW ospreyinputarm
on every microkernel configuration \- and what it arms is not the
polled physical segments
.CW kbdring
and
.CW mousering
that the full personality exposes and that
.CW kbd.c
and
.CW mouse.c
segattach.  It arms the other mechanism: the two interrupts as bare
notifications to the container, with the i8042's ports granted to it,
so that
.CW p9kbd.c
\- a driver in this personality, in user space \- owns the whole
controller and reads every byte off port
.CW 0x60
with its own
.CW inb .
.PP
The two cannot both run, and trying it hangs the boot.  Exposing the
rings arms the kernel's own handler on IRQ1; the driver's command-byte
handshake then spins for a reply the kernel's handler has already
drained off
.CW 0x60 ,
in the unbounded
.CW "while(!(inb(Kbdstat) & Kbdready));"
that
.CW ospreykbdenable
opens with.  The boot stops between the input print and the console
hand-off, which is what a single added print bisected it to.  The
comment above
.CW ospreyinputarm
had said exactly this would happen, about arming one device while the
other's command byte is being written; the same hazard holds for the
two mechanisms.
.PP
So the driver stays where the configuration put it, and what was
missing was never a ring: it was that
.CW p9kbd.c
printed what it read.  It decodes the scancodes and it assembles the
three-byte PS/2 packets already; the whole gap was between that and a
file.
.CW devinput.c
is that file \-
.CW #m ,
two entries,
.CW kbd
and
.CW mouse .
The driver hands it each rune it has translated (the keymap and the
shift and control state are
.CW kbd.c 's,
unchanged, because there is one keyboard whichever driver reads it) and
each mouse packet as it decoded it; the device keeps the queue and the
absolute position, and answers reads in the two forms a Plan 9 program
expects \-
.CW c
and the rune,
.CW m
and four twelve-column fields.  A write of
.CW "m x y"
moves the pointer, which is how a window system warps it.
.PP
Which means the driver is where it should be and the file is where it
should be: a container asks its name space for
.CW /dev/mouse ,
the call is forwarded to the buddy, and the buddy is the personality
that holds the driver.  Nothing new was asked of the kernel \- no
segment, no second owner of the controller.  The check has the pair
client's second draw container mount
.CW /srv/draw
at
.CW /dev
as before and then read
.CW /dev/mouse
and open
.CW /dev/kbd
beside it: one container, three files, and the mouse record is checked
as four numbers on the 1280x800 screen rather than matched as a string.
The pair check is 91.
.PP
That much is the plumbing, and the plumbing is not the decode: nothing
moves a mouse in that check, so the position it reads back is the
centre the device seeded, and no key is pressed, so the queue is never
filled.  The keyboard check is where a key and a movement actually
arrive \- it injects both over QMP - and it had been checking only that
the driver printed what it read off the port.  It checks the other half
now: that the scancodes became the runes
.CW a ,
.CW b ,
.CW c
and space in
.CW /dev/kbd 's
queue, translated through the keymap, and that the packets moved
.CW /dev/mouse 's
position off the centre it was seeded at.  The device says both, for
the first eight of each and no more, because a keyboard in use is not a
log.  That check is 8.
.PP
Two things found on the way.
.CW #I
is
.I devip 's
letter, so the bind of an input device by that name succeeded, put the
IP stack's files on
.CW /dev ,
and left the open of
.CW /dev/mouse
saying only that it did not exist \- a letter collision reads exactly
like a missing file.  It is
.CW #m
now, which is where Plan 9 keeps
.CW /dev/mouse ;
.CW /dev/kbd
is on the console device there and is here too, because here it is one
driver reading one controller and one letter cannot be two.
.PP
And a read of either file waits on a buddy worker, because that is
where a forwarded call runs, and there are four of them.  rio will park
two for as long as it runs.  That is not a problem yet and it is
written down here so that the fifth blocking reader is not a surprise.
.PP
What
.CW kbd.c
and
.CW mouse.c
are for is unchanged: they are the full personality's drivers, on the
configurations where the kernel exposes the rings.  Both post their
service under a name now, so that a container which never had their
mount can find them, and
.CW kbd.c
takes the segment to attach as an argument \- which is what the check's
negative control for the error path uses, a name no kernel has, rather
than depending on the real ring being absent from this configuration.
.PP
.B "2.3h: rio runs."
9front's window system runs on the server personality, its system calls
answered by a peer container over the ring.  It is the 6407 lines of
.CW 9front/src/cmd/rio
this tree builds itself, and not a line of it was written or changed for
this machine.  It opens
.CW /dev/draw ,
takes the whole 1280x800 screen, allocates a screen of its own on it,
paints it with its own background \- so the frame buffer word at the
centre and at four points inside the corners is
.CW 0x00777777 ,
read back by a container that drew nothing \- brings up its 9P file
server, forks its libthread procs, and is still running, all of it, when
the machine idles at the end of the boot.  The pair check is 94.
.PP
It is started by the draw binary again, with
.CW -x :
that container mounts
.CW /srv/draw
at
.CW /dev
and execs rio in place, so rio opens
.CW /dev/draw
and finds the screen where a window system expects it.  A program that
only opens the file cannot find a server posted in
.CW /srv
by itself, and on a real machine it is whatever starts the window system
that puts the screen in its name space.  Here that is the exec, and the
mount stays under the program it becomes.
.PP
Six things were in the way, and rio named five of them itself \- its
startup is a fixed sequence and each step has its own message, so the
log said which.
.PP
.CW /mnt/temp
did not exist.  rio's
.CW cexecpipe
binds the pipe device onto it, opens the two ends through it and
unmounts it again, and a bind whose mount point does not exist fails:
.CW "rio: can't create file system server: Enonexist: '/mnt/temp'" .
On a real Plan 9 machine the root a program sees is the file server's
and that directory is in it; here the root device is the root, so the
mount point has to be there.  The root device holds one level of
directories and now holds two, with
.CW temp
in
.CW /mnt .
.PP
The environment was not in the name space.
.CW getenv (2)
and
.CW putenv (2)
are opens of
.CW /env/<name> ,
not system calls, so
.CW #e
is bound onto
.CW /env
now; rio puts the name of the pipe it posted in
.CW /srv
there, under
.CW wsys ,
which is how a command in a window finds the window system that started
it.
.PP
.CW /dev/time
was not there.  It is devcons's text form \- seconds, nanoseconds, the
fast-tick counter, its frequency and the monotonic clock, in devcons's
own column widths \- and rio reads its first field as the time it stamps
its own files with.  A program that opens it and gets nothing stamps them
from whatever was on its stack.  It is a second file of
.CW #T
now, beside
.CW bintime .
.PP
.CW /dev/cons
and
.CW /dev/consctl
were not there either, and rio will not believe it has a keyboard
without them: its keyboard proc opens both and gives up if either fails,
and only then looks for
.CW /dev/kbd
and prefers it.  Both are files of
.CW #m
now, beside the two 2.3g added:
.CW cons
is the same runes as
.CW kbd
without the leading
.CW c ,
which is what cons is on a Plan 9 machine, and
.CW consctl
takes
.CW rawon
and
.CW rawoff
and does nothing with them, because nothing here is cooked \- this
device never echoes and never assembles a line.
.PP
Then the one that was not rio's to name.  A forwarded call waited
fifteen thousand two-millisecond sleeps \- thirty seconds \- and then
returned \-1 with no reason.  A read of a keyboard is answered when a key
is pressed and not before, and nobody is at this machine's keyboard, so
rio's keyboard reader took that \-1 thirty seconds in, ended its loop and
shut rio down; its mouse reader did the same.  The screen was already
grey by then, which is why the pixels alone do not tell a window system
that started from one that runs, and why the criterion is the kernel's
last dump of what is running instead.  A call that blocks is not a call
that failed.  The wait is not bounded by a count now; what ends it is
the two things that mean no answer is coming \- the server is gone, or a
note is pending for this process, which is how Plan 9 interrupts a
blocked call and which now sets
.CW interrupted
as the reason.
.PP
The first cut of that wait was a poll, and the poll took the machine
down.  A blocked caller woke every two milliseconds, serviced its ring
and looked for the reply, for as long as it stayed blocked; rio parks
three readers, so three kernel processes woke five hundred times a
second for as long as rio ran.  The server loop was driven through a
hundred and ninety-two thousand requests in one boot of the two-machine
check, and that boot ended in
.CW "panic: ilock ... key 0xdeaddead ... held by pc ..." ,
which is
.CW timerdel
spinning a million times on the timer list that
.CW timerintr
was holding \- the same signature, and the same cause, as the flood of
frames recorded higher up in this document.  The symbols came out of the
kernel's own table:
.CW 0xdeaddead
is not freed memory, it is what
.CW tas
writes into a lock word, so the panic says only that a lock was held too
long.
.PP
So the wait is not a poll.  It sleeps on the container's own reply
rendezvous \-
.CW ospreyawaitreply (),
which the server's routing wakes when a reply for that container lands,
and which was already there and had no caller \- with twenty
milliseconds as the backstop for a reply arriving by some path that does
not wake it.  The same boot now serves a third of the requests it did,
and fewer per tick.  Two other ways of ending the wait were tried and
taken out: a note pending for the process, which is what Plan 9 does and
is wrong here because migration posts a note to park a process and the
call it is making must still finish on the way out; and a single look at
whether the server is gone, which failed six of the migration criteria
in one run in four, because a container carried over the wire has its
delegation taken down and put up again and a call in flight sees no
server for a moment.  Fifty consecutive looks with no server is what
ends it now.
.PP
And the buddy's workers went from four to twelve.  A forwarded call runs
on a worker and a blocking read holds one for as long as it blocks: rio
parks one on
.CW /dev/kbd ,
one on
.CW /dev/mouse
and one on its own 9P pipe, and holds them for as long as it runs.  Four
left one worker for everything else.
.PP
Two things found on the way and written down rather than fixed.
.PP
The client personality's cooperative scheduler has no idle.  A first cut
had the pair client
.CW tsleep
for six seconds to let rio paint, and the machine died with
.CW "p9sched: no runnable proc (deadlock), tick 0" :
if every proc of that personality is in a timed sleep, nothing advances
the clock that would wake them, and
.CW sched ()
panics rather than waiting.  The waiting belongs in a container \-
.CW sleep (2)
there is the kernel's, and the kernel has a clock \- so the probe that
reads the screen waits six seconds itself, in a container of its own,
and the client does not sleep at all.  That the personality's scheduler
cannot idle is still true, and is a thing to fix rather than to route
around twice.
.PP
And a note is addressed by a number that means two things.  rio's
.CW killprocs
writes
.CW /proc/<pid>/note
with the pid
.CW getpid (2)
gave it, and the kernel resolves that number as a container id:
.CW "osprey: a note was asked for container 32, which is not a container"
while the container whose pid is 32 is container 124.  It does not fire
while rio stays up, and it is what breaks first when a window tries to
kill the command in it.  2.3j below is that defect fixed; the paragraph
is kept as it was written, because what it says about where the number
came from is what led to the fix.
.PP
And a window system is a standing load, which is why rio is started
because the machine was configured to start one:
.CW *riodemo=
in
.CW plan9.ini ,
which the pair check and the rio check set and nothing else does.  The
two-machine check boots the same kernel, so it had been running two
window systems while carrying processes between them; with rio off it
is clean three runs in a row, and a check that is not about rio boots
the machine it was written against.
.PP
What those runs turned up before the gate is worth having.  Two of them
ended in
.CW "panic: ilock ... key 0xdeaddead ... held by pc ..." ,
and the kernel's own symbol table says the waiter was
.CW timerdel
and the holder
.CW timeradd ,
on the timer list \- two short critical sections that walk a list and
program a clock, and cannot take long.  What
.CW ilock
does when a lock is held is spin a million turns of a load and then
panic, and a million turns of a load on an emulated processor is about
ten milliseconds.  Ten milliseconds is not a deadlock: it is what
happens when the host takes away the virtual processor that holds the
lock and runs something else, which two of these machines and a build
on the same host will do.  The bound is wall time now \- ten seconds.
.PP
Which clock measures it is the whole of the care in that change.  The
obvious one,
.CW fastticks ,
is wrong: it goes through
.CW arch\->fastclock ,
and on a machine without a usable cycle counter that is
.CW i8253read ,
which takes an
.CW ilock
of its own.  A processor spinning for the i8253's lock would have
called the very thing it was waiting for, and spun inside its own spin
until the stack ran out.  So the spin reads
.CW spinticks ,
which is the cycle counter and nothing else \- a register read, no lock
\- and which returns a zero frequency when there is no cycle counter to
read, in which case the count is what the panic is on, as it always
was.  On the machine these checks boot,
.CW spinticks
answers 999220880 ticks a second \- measured with a probe put in
.CW timersinit
for one boot and taken out again, since nothing in the tree prints it
\- so it is the wall-clock bound that is in force here and not the
fallback.
.PP
One more care, of the same kind.  The lock is not held while this
spins, so nothing pins the proc to a processor:
.CW splx
at the top of each turn lets it be preempted and come back on another
one, whose cycle counter is a different counter and can read lower.
Subtracting one processor's ticks from another's is an unsigned wrap
and an instant false panic, so the machine number is kept beside the
start and the measurement begins again when it changes.  QEMU
synchronises the counters it presents, so nothing here would ever have
shown it.
.PP
One more thing the sweep turned up, and it is not rio's.  The two
criteria about pi-p across the cable failed in one sweep in three and
passed in the others, and this document's own standard is that a
transient recorded three times is a finding.  It is one: the two-machine
check gave each machine four minutes, and a machine that had done the
whole migration exchange - every process carried both ways with its
pages, its descriptors and its name space - was sometimes still paging
.CW /boot/cat
in when its time ran out.  Both kept logs ended mid-boot, six hundred
lines short of where a passing run ends, and the ticket lines the two
criteria match had simply not been printed yet.  The failure was for
want of a boot, not for want of a ticket.  Seven minutes now: the
deadline is not part of what is being checked, and it is set where load
cannot reach it.
.PP
That last paragraph is wrong, and 2.3k below is what it should have
said.  The lines really had not been printed, and the reason really was
that the machine was stopped before printing them \- but not because it
ran out of time.  It was stopped by the check, on a marker that arrives
before the phase those two criteria are about, in the runs where two
independent things finish in the other order.  The deadline went to
seven minutes and the check went on failing.  The paragraph is left as
it was written because being confidently wrong in a way that fits the
evidence is the thing this document is for.
.PP
.B "2.3i: rio hears the button."
Painting the screen is not listening to a mouse: a window system that
started and then sat deaf would leave the same pixels.  So the button is
pressed at it.
.CW scripts/osprey-check-rio.py
boots the machine twice, moves the mouse the same way in both, and holds
button 3 down in one of them; QEMU dumps the screen it is scanning out
at the end of each, and the two are compared.  They differ by a block of
pixels the size of a menu, where the pointer is, every one of which was
the background before, and most of what they became is
.CW 0xeaffea
and
.CW 0x448844
\- with
.CW 0x88cc88
around them.  Those are libdraw's, not rio's: they are what
.CW genmenuhit.c 's
.CW menucolors
asks for \- the body is
.CW allocimagemix(DPalegreen,\ DWhite) ,
the highlight and the text
.CW DDarkgreen ,
the border
.CW DMedgreen
\- with black text on them.  This document and the check first called
them rio's own
.CW DPalegreygreen
and
.CW DGreygreen ,
which is where a window's title bar gets its colours and not where a
menu gets its; the numbers were right and the names were wrong, and the
names are fixed here and in the check.
.PP
What that press crossed, in order: QEMU's PS/2 controller, the IRQ12 the
microkernel routes to the personality's container as a bare
notification, the user-space i8042 driver that reads port
.CW 0x60
with its own
.CW inb ,
.CW devinput.c 's
decode of the three-byte packet into a position and a button mask,
.CW /dev/mouse ,
a forwarded read answered by the buddy over the ring, rio's mouse proc,
and then back the other way through
.CW /dev/draw
to the draw server in a container of its own, which wrote the frame
buffer the emulator then dumped.  Nothing on that path is a stub.
.PP
The first cut of the check looked for white, because rio's
.CW cols[BACK]
is white, and found none: the menu is not drawn in
.CW cols[BACK] .
Comparing the two screens rather than counting one colour is what
turned "no white" into a bounding box and a histogram, and the
histogram named the colours.
.PP
What is not claimed.  No window has been made and none swept.  A sweep
is a drag with the button down over the menu's New, and the check holds
a button rather than driving a gesture.  There is
no pointer on the screen either \- the arrow is drawn by the draw
server's cursor out of the mouse ring, and this configuration exposes no
mouse ring, so the position
.CW /dev/mouse
reports is right and there is nothing drawn at it.  2.3q is that one.
.B "2.3j: the pid a program reads for itself."
The kernel used to print, several times in a boot with rio in it,
.CW "osprey: a note was asked for container 32, which is not a container" .
It was right, and the fault was not rio's.
.PP
Everything a legacy program is told about a process here is a
container's identity.
.CW rfork
returns one to the parent,
.CW await
reports one in the wait message, and
.CW /proc/<n>/note
\- which is what
.CW postnote (2)
writes, and which
.CW devnote.c
in the personality serves \- parses one out of the path.  Three
agreed.  The fourth did not:
.CW getpid (2)
on Plan 9 is a read of one word of the Tos the kernel filled, and this
kernel filled it, in
.CW kexit
and in
.CW userinit.c ,
with
.CW up->pid ,
the kernel's own process number.
.CW #c/pid
in
.CW devcons.c
gave the same number.
.PP
That is enough to break a threaded program.  libthread's
.CW sched.c
does
.CW "p->pid = getpid()"
for each proc it starts, and
.CW threadexitsall
walks that list and posts
.CW threadint
to every pid in it.  So rio, at the end, posted notes to kernel process
numbers, and the kernel looked for containers with those numbers and
found none.  Which is also why the printed complaint named 32 while the
process list in the same log said
.CW "container 124 pid 32" .
.PP
The fix is one number in two places: a process in a container reads its
container's identity for its own pid, in the Tos and in
.CW #c/pid ,
and the kernel's pid everywhere else, which is what the native side
wants.
.CW #c/ppid
answers the parent out of the child table, and 0 once the parent has
reaped, where Plan 9's persists; that asymmetry is real and is written
here rather than papered over with a fourth table to keep in step with
container lifetime.
.PP
The check is a legacy program that does what rio does.  A child reads
.CW getpid ()
and writes it up a pipe; the parent compares it with the id
.CW rfork
handed back, then posts a note to the child's own number and waits for
the child's handler to catch it.  Three criteria.  A fourth, in the rio
check, is a guard and not a result: it says no boot had the kernel
refuse a note for want of a container, and a boot in which rio posted
no note at all would pass it too \- rio only posts those when it
exits, and the check keeps it running.  An accepted note prints
nothing, so there is no positive line to look for on that side; the
evidence that the number is right is the legacy program's, where the
note is posted and caught in the same boot.  The read is bounded by an
alarm, because without
.CW RFFDG
the child shares this descriptor table and the pipe's write end is open
in the parent too: a child that died before writing would otherwise
leave the parent waiting on itself, and take the other ninety-odd
criteria with it.
.PP
The negative control is the same kernel with the two Tos lines put
back.  The child is id 108 to its parent and reads 16 for itself, the
note to 16 is refused with
.CW Eperm ,
the kernel prints that a note was asked for container 16 which is not
one, and after a move
.CW getpid ()
still reads 17 while the container is 109.  With the fix, all four of
those read the same number as the parent's, the note arrives, and the
number follows the process into the container a move gives it \- the
new
.CW Proc
has not run yet when the move returns, so its first
.CW kexit
fills the Tos with the identity it has now.
.PP
One behaviour changes with this that is worth writing down.  libthread's
.CW tinterrupt
tries
.CW writeprocctl
first and falls back to
.CW postnote ;
on this personality the
.CW ctl
write has always failed, and until now the
.CW postnote
failed too, so a thread interrupt reached nothing.  It lands now.  A
threaded program that interrupts its own procs will start doing so, and
that is the intended behaviour rather than a side effect to watch for
\- but it is new, and if a window system stops behaving as it did, this
is the change that did it.
.B "2.3k: the two-machine check was not slow, it was early."
The two-machine check had been failing its two pi-p ticket criteria
about one run in three, and 2.3h says why: the machines were running out
of time.  That was wrong, and the way it was wrong is worth writing
down, because the evidence for it looked good.  Both kept logs ended
mid-boot, six hundred lines short of where a passing run ends, which is
exactly what a deadline looks like.  So the deadline went from four
minutes to seven, and the check went on failing one run in three.
.PP
A run of that check takes twenty-seven seconds.  Four timed runs said
so \- 28, 27, 27, 27, one of them a failure \- and none of them came
within six minutes of the deadline that had just been raised.  Nothing
was slow.  What ends a run is a marker: the console stops the machine
when it sees a line, and the line was
.CW "osprey migrate: the exchange is complete on this machine" .
.PP
A machine here does two independent things.  The migration exchange runs
in the kernel and in the migrate kprocs.  The personality's pi-p over
the cable runs at the end of the wire client's kproc,
.CW pipacrosscable ,
after the bandwidth test.  Nothing sequences them, so they finish in
either order.  In a passing run machine 2's cable lines are at 645 and
its migration marker at 1217; in a failing run the marker is at 606 and
the cable phase has not started.  The check was stopping the machines in
the middle of the thing two of its criteria are about.
.PP
The fix is to stop on more than one line.
.CW osprey-console.py 's
.CW -u
is repeatable now, and every marker given has to be seen before the
machine is stopped, in any order.  Machine 2 waits for the migration
marker and for the end of its own cable pi-p; machine 1 waits for the
migration marker and for the cable's connection to close, which is what
tells it the far machine has finished asking.  For that second one the
server's close line had to say where the connection came from \- it
already said so when it accepted one, and now says so when it closes
one, so the cable's connection reads differently from the client
container's.  The end-of-cable line is printed on the failure path too,
and the connection dropped there, so a cable phase that fails ends the
run instead of leaving the other machine waiting for a line that cannot
come.
.PP
Fourteen consecutive clean runs after, against one failure in four and
one in three before, and the deadline is back at four minutes where the
timings put it.
.PP
The sweep that gated this turned up a second one of the same family, in
a different check.  The one-machine wire check failed
.CW "a key agreed over the wire, the same on both" ,
and the kept logs say why in one line each: one machine printed
.CW "key none"
and the other
.CW "key e262215259b4e333" .
The key is agreed between the two machines, so when it appears is not
either machine's to say, and the check read it after a fixed sleep \-
fourteen seconds on one, ten on the other.  It now waits for the
agreement, up to forty seconds past the sleep it already did, and prints
what it finds either way so a real failure still reads as one.  The
sleeps are kept as a floor so that nothing later in the script starts
any earlier than it did.  Four clean runs after.
.PP
Both of these were the same mistake in two places: a check that decides
when something is finished by counting seconds rather than by looking
for the thing.  Neither was a kernel fault, and both had been showing up
as "the sweep is flaky", which is the shape a check defect takes when
nobody reads its logs.  The lesson is the one the sweep was written for: a log
that stops early has two explanations, and "it ran out of time" is only
one of them.  The measurement that separated them was a stopwatch, and
it took four runs.
.B "2.3l: a window."
The menu's New is chosen, a rectangle is swept with the button down, and
a window is made where it was swept.  Four things had to be fixed to get
there, and finding the first of them took an afternoon because nothing
said anything.
.PP
.B "The fork ran out of table."
rio's window is
.CW proccreate(winshell) ,
which libthread turns into
.CW rfork(RFPROC|RFMEM|RFNOWAIT) ,
and that fork returned \-1.  libthread's scheduler retries a failed
.CW _schedfork
on every pass and says nothing, so a window system that cannot make a
window looks exactly like a window system that has stopped.  The kernel
kept one table of who started whom,
.CW ospreychildren ,
eight entries for the whole machine, and it was full.
.PP
The size was not the fault, though eight is small.  The fault is that
.CW RFNOWAIT
was ignored.  A child forked that way is one the parent has said it will
never wait for \- libthread forks every one of its procs that way \-
so its entry must be freed when it exits rather than held with a status
for a reap that will not come.  The entry cannot simply not exist: the
same table is what says a container may note what it started, which is
how a window system stops the command in a window, so parentage has to
outlive nothing but the child.  The fix is a flag: the entry is made,
and an exit frees it instead of keeping a status.  With that the table
holds one entry per live child, and it is sixty-four now because eight
is the number that ran out.
.PP
A fork that fails for want of the table says so now.  So does a draw
server that cannot allocate a window, and for the same reason: rio's
.CW allocwindow
returns nil and rio abandons the sweep without a word, so the only
evidence was a rectangle that never became a window.  Neither of those
prints was there before; both were what the afternoon was spent doing by
hand.
.PP
.B "The mount point, and who the mount was from."
.CW winshell
mounts rio's own file server for the window on
.CW /mnt/wsys ,
which did not exist \-
.CW devroot
had grown
.CW /mnt/temp
for the pipe and nothing else.  With the directory there the mount was
refused:
.CW "mount failed: permission denied" .
rio's file server compares the attach's
.CW uname
with the user it thinks it is running as, and it gets that from
.CW getuser (2),
which stats
.CW /proc/<pid>/status
and takes the uid out of the stat message.  This personality's
.CW /proc
served
.CW note
and
.CW notepg
and nothing else, so
.CW getuser
answered
.CW none
while the attach said
.CW osprey ,
and rio refused its own window.  So
.CW devnote.c
serves
.CW status
too, in the shape
.CW devproc (3)
gives it, with the owner right \- which is the whole of what anything
here reads it for.
.PP
What that gets: the sweep ends, rio forks the process for the window,
that process mounts the window's file server on
.CW /mnt/wsys ,
binds it over
.CW /dev
and opens
.CW /dev/cons
there, and the frame is drawn in
.CW titlecol .
The check has seven criteria now and asserts the swept rectangle from
the screendump and the rest from the log, because which of the two
borders a screendump catches \- 
.CW sizecol
while the sweep is still being drawn,
.CW titlecol
once it is a window \- depends on when it is taken, and 2.3k is about
what happens when a check decides by timing.
.PP
What is not claimed: the window does not stay.  What
.CW winshell
execs is
.CW /bin/rc ,
hard-coded in rio, and this personality has no
.CW /bin/rc :
the exec fails, the process exits "exec failed", and rio takes the
window down again.  Giving it a shell to run is the next piece, and it
is not a small one \- the personality's
.CW /boot/sh
is a demonstration shell that reads a script, not something that reads a
line at a time from a window's
.CW /dev/cons .
.B "2.3m: the shell a window would run, and why it does not run yet."
rio execs
.CW /bin/rc
in a window, hard-coded, and this personality had neither the name nor
anything to put behind it.  Both are here now.
.CW /boot
is bound onto
.CW /bin ,
and the small shell this personality already had,
.CW /boot/sh ,
is registered under the name
.CW rc
as well \- the same bytes under two names, not a copy.  It is not rc and
does not pretend to be: one command a line, words at blanks, stages at
.CW | ,
no quoting and no variables.  It is a shell a window can run.
.PP
It had to learn to be one.  It read a whole script out of a named file
and said what it was doing with
.CW print ,
which goes to the machine's console.  A window's shell reads a line at a
time from descriptor 0 - which in a window is that window's
.CW /dev/cons
- and writes its prompt to descriptor 1, which is the same file; saying
it on the console would say it where the person at the window cannot see
it.  So there is an interactive mode, taken when no script is named or
when the argument is the
.CW -i
rio passes.
.PP
It does not run yet, and what stops it is exact.  rio's window process
does not call
.CW exec (2)
itself: it calls libthread's
.CW procexec ,
which wants exec's semantics out of a call that happens in another
process, and gets them with a pipe \- the write end opened
close-on-exec, so that the read of the other end fails if the exec
worked and returns the error text if it did not.  Opening that end is
.CW open("/fd/<n>",\ OWRITE|OCEXEC) ,
and this personality serves no
.CW /fd .
The open fails, procexec returns before it has forked anything, and
winshell exits "exec failed" with no exec ever attempted.  The instrument
that showed it was a print on every
.CW rfork
the container made: the last one is
.CW 0x7 ,
which is winshell's own
.CW RFNAMEG|RFENVG|RFFDG ,
and libthread's exec fork never follows it.
.PP
So the next piece is a
.CW #d ,
the dup device, whose
.CW /fd/<n>
names descriptor n of the container that opens it.  The descriptors are
the buddy's, so it is the personality's device to write, beside the ones
it has.
.PP
The rest of this section is a list of refusals that used to be silent and
are not any more, because every one of them cost an hour: a fork refused
for want of the child table or of a container, a fork with no server or
no register frame to copy, a draw server that cannot allocate a window,
an exec whose program the buddy cannot open, an exec by a process with no
buddy image, and an exec the buddy refused.  Each returned \-1 to a
caller whose library turned it into "failed" and nothing else.  A
microkernel that refuses should say which rule refused.
.B "2.3n: a shell in the window."
The window has a shell in it, and what it writes is drawn in the window.
Three defects stood between 2.3m and that, and each was a place where
this personality answered a call the way it was convenient rather than
the way Plan 9 defines it.
.PP
.B "The dup device."
libthread's
.CW procexec
opens
.CW /fd/<n>
before it execs anything, and there was no
.CW /fd .
.CW devdup.c
is that device.  Whose descriptor n is, is the question it exists to
answer: the descriptors of a container are the buddy's, kept per
container in the buddy's image record, so the open asks the buddy which
container it is answering for
.CW ( p9servingcontainer )
and what that container's fd n stands for
.CW ( p9containerfd ),
and hands back the channel that descriptor of the buddy's holds.  A
worker with no container to answer for gets nothing, because
.CW /fd/<n>
would then name a descriptor of the server itself and a container could
reach the server's files through it.
.PP
.B "The lowest free descriptor."
.CW open (2)
returns the lowest-numbered free descriptor.  That is not a detail: it
is how a program replaces its own standard input or output, by closing
the one and opening the other, and it is exactly what rio's
.CW winshell
does to put a window's
.CW /dev/cons
on 0 and 1.  The buddy searched from 3, and its
.CW close
of 0, 1 or 2 put the console sentinel back rather than freeing the slot,
so neither half of that could work: the closes were not closes and the
opens landed on 5 and 6.  Both are fixed, and the sentinel stays as what
a container starts with rather than as what a close restores.
.PP
.B "Which writes are the console's."
The kernel keeps a mark, a bit per standard descriptor, saying that this
descriptor has been redirected and its writes go to the buddy; without
one, a write to 0, 1 or 2 goes straight out of the console and a legacy
program's print stays one call instead of a ring round trip.  The mark
was set by watching
.CW dup
and cleared by watching
.CW close ,
which was right while a closed 0, 1 or 2 went back to being the console.
It does not now.  So the mark goes on at the close: from there that
descriptor is whatever the buddy has for it - nothing, until something
is opened onto it - and the write is the buddy's to answer or to refuse.
With the mark still being cleared, the window's shell wrote its first
words to the machine's console, which is where they appeared, and the
window stayed empty.
.PP
What that gets, and the check now asserts: the buddy lays
.CW /bin/rc
out for the window's container; none of the shell's words appear on the
console this check reads; and the swept rectangle holds 3745 pixels of
.CW cols[TEXT] ,
counted inside the window, which is rio's font drawn through rio's own
file server by the command running in it.  Ten criteria, three
consecutive runs, the same numbers each time.  Rendered as characters
the window holds the shell's three lines of banner and a prompt, with
rio's scroll bar down the left of them.
.PP
.PP
And something has been typed at it.  The word
.CW nosuchthing
is typed at the window one key at a time through the emulated keyboard,
with Enter after it, and the shell in the window asks the buddy for a
program of that name:
.CW "buddy: exec nosuchthing: file does not exist: 'nosuchthing'" .
The word is one the shell cannot run on purpose \- what the criterion
is about is the path, not the program.  A key crosses QEMU's i8042, the
IRQ1 the microkernel routes to the personality's container as a bare
notification, the user-space driver that reads port
.CW 0x60
with its own
.CW inb ,
the keymap,
.CW /dev/kbd ,
rio, the window's own
.CW /dev/cons ,
and the shell's reader; and the shell's answer goes back out
descriptor 1 and is drawn, which the pixel count says: 3745 of
.CW cols[TEXT]
before the typing and 5763 after.  The complaint does not appear on the
machine's console, which is the other half of saying that descriptor 1
is the window.
.PP
.PP
And a program runs in it.
.CW /bin/cat
is typed at the window and Enter after it, then a line for it to echo.
The shell forks, the fork is given the window's descriptors, and the
buddy lays that binary out for a container of the window's own:
.CW "buddy: exec /bin/cat for container N: a Plan 9 a.out" .
cat with no argument reads its standard input and writes it out, and in
a window both of those are the window: it says how it started, echoes
the line, and neither appears on the machine's console.
.PP
That last is a distinction worth drawing rather than assuming.  The boot
runs a
.CW /boot/cat
of its own, on the console, as part of what the pair check exercises, so
a criterion that looked for
.CW "cat: started with"
would have passed on that one and said nothing about the window's.  What
it looks for is the argument vector:
.CW "argv[0] = /bin/cat"
must not be on the console, and
.CW "argv[0] = /boot/cat"
must be, so the criterion fails if the console falls silent for some
other reason.
.PP
Fourteen criteria, three consecutive runs, the same numbers each time.
The text inside the window goes 3745 pixels with nothing typed, 5763
after the word, 6033 after cat has run and echoed; rendered as
characters it is the shell's banner, its complaint about the word, cat's
own line and the line cat echoed back.
.PP
What was not claimed at 2.3n: the window was not swept away, moved,
resized or deleted, and no second window was made.  2.3p is those.
.B "2.3o: abort() is a read of address zero."
The sweep that gated 2.3n failed one criterion of the full personality's
check,
.CW "a container held to its reservation" ,
and the kept log said the process bound to the strict container was
.CW Broken
rather than
.CW Stopped ,
with
.CW "rc 2792: suicide: sys: trap: fault read addr=0x0 pc=0x20d555"
above it.  The throttle had not failed to stop it; it had faulted and
killed itself first.
.PP
The obvious suspect was the throttle, because the criterion after it \-
a second spinning process, not bound to the strict container \- passed
every time, and the only difference between the two was being stopped
and started again.  That was wrong, and the way it was shown wrong is
the useful part: the same experiment with the container in best-effort
mode, where nothing is ever stopped, killed the process twice in four
runs at the same instruction.  What the two had in common was not the
stop.  It was
.CW bindproc :
both put a running process into a container.
.PP
The cause is 2.3j, four commits earlier in this same session.  That made
.CW getpid (2)
report the container's identity, which is right for a legacy program the
buddy loaded and wrong for a native process of this kernel that is bound
into a container while it runs.  Such a process was started by this
kernel with this kernel's pid, and its library has already keyed state
to that number.  One of those keys is libc's allocator:
.CW plock
stores
.CW _tos->pid
in the pool's private record and
.CW punlock
compares it and calls
.CW abort ()
if it has changed, and
.CW abort ()
on Plan 9 is
.CW "while(*(int*)0)" .
So
.CW bindproc
changed the number under a process in the middle of a
.CW malloc ,
and the next
.CW punlock
read address zero.  A fixed faulting pc across every occurrence is what
said it was deliberate code and not corruption.
.PP
The rule is narrower now: the container's identity is the pid of a
program the buddy loaded
.CW ( up->buddyimage ),
and a native process bound into a container keeps the kernel's.  Four
runs with the old number and four with the new, on the same experiment:
four faults against none.  The check waits for the throttle rather than
looking once eight seconds in, which is the shape 2.3k argues for and
costs nothing when the throttle is merely late; it was not what was
wrong here.
.PP
Two lessons, and the second is the one worth keeping.  The first is that
.CW abort ()
looks exactly like a wild pointer.  The second is that the criterion
that pointed at the throttle was a difference between two cases, and a
difference is a hypothesis, not a cause; the cheap way to tell them
apart was to remove the difference and see whether the failure went with
it.  It did not.
.B "2.3p: the rest of the window system, and why only one window could ever be made."
Making a second window did not work, and neither did moving, resizing or
deleting the first.  What the screen showed was that after one window
was made rio never drew anything again: the same 1280x800 pixels in
every screendump, while the log went on saying the user-space i8042
driver had read each mouse packet off port 0x60 and
.CW /dev/mouse
had them.  The keyboard still worked \- that is what 2.3n types with \-
so it was not that rio had died.
.PP
Five presses in one boot said where the line was.  Open the menu and
slide off it: the menu appears.  Choose New and then press and release
without moving, which is a sweep of nothing, so
.CW sweep ()
returns nil and no window is made: open the menu again, and it appears.
Choose New and sweep a real rectangle: the window is made, and from then
on the menu never appears again.  So it was not the menu, not New and
not the sweep.  It was a window existing.
.PP
rio's
.CW new ()
ends with
.CW "pid = recvul(cpid)" ,
and the pid comes from libthread's
.CW procexec ,
which gets it this way: it makes a pipe, opens the write end again
through
.CW /fd/<n>
with
.CW OCEXEC ,
hands that to the proc that will exec, and reads the read end.  The read
ends when every write end is closed, and the exec is what closes the
child's \- that is the whole mechanism by which
.CW procexec
learns whether the exec worked.  This buddy recorded
.CW OCEXEC
in the descriptor's mode and did nothing with it, so the child kept the
write end open, the read never ended, no pid was ever sent, and rio's
mouse thread sat inside
.CW new ()
forever.  The window it had just made worked, and the machine looked
alive, because the keyboard thread is a different thread.
.PP
So the buddy closes them now, at the point an exec commits, and only
there: the same layout routine runs again when a migration record is
replayed to rebuild an arrived container's image, and that is not an
exec \- its descriptors come out of the record after the image line and
closing any of them would throw away what the record is restoring.
.CW dup
clears the flag on the new descriptor, as
.CW sysdup 's
.CW "newfd(c, 0)"
does, so
.CW "dup(1, 2)"
in rio's winshell does not hand the command a descriptor that closes
itself.  And the descriptor table's own refusal is named: sixteen is few
for a window system that holds a
.CW notepg
descriptor per window on top of draw, mouse, cursor, keyboard, console
and its file server, and a silent \-1 there is the shape of bug that
cost this document two sections already.
.PP
.CW scripts/osprey-check-riowin.py
drives the rest of the gestures on one booted machine and photographs it
after each.  The menu is aimed at by arithmetic rather than by guessing:
.CW genmenuhit.c
pops the menu with the last item hit centred under the pointer and lays
the items out
.CW font->height+Vspacing
apart, so item
.I k
is
.I "(k \- lasthit)"
pitches below where the button went down, and
.CW menuhit
remembers the last, so the offsets are relative to the previous choice.
The pitch is measured, not assumed: a first boot opens the menu and
photographs it, the menu's border is
.CW DMedgreen
and nothing else on the screen is, and its height less the two margins
divided by the six items is 18 \- the built-in font is 16 high and
.CW Vspacing
is 2.
.PP
Nine criteria: a window swept; a second one beside it, each counted
inside its own rectangle because both are the same white, with the new
one bordered in
.CW titlecol
and the first redrawn in
.CW lighttitlecol
now that it is not current; two
.CW /bin/rc
laid out for two different containers; Move, chosen two items below New,
leaving the box it came from as background and the box it went to
filled; Resize, chosen one above Move, making it a rectangle of a
different size; Delete, chosen two below Resize, leaving background
where the window was; the other window still there afterwards, bordered
in
.CW lighttitlecol
because deleting the current window leaves rio with no current window
rather than promoting the other; the measured pitch; and a release
outside the menu choosing nothing.
.PP
Delete is asserted from both sides, the window there in the shot before
and gone in this one.  It was not, at first, and the first run of this
check printed
.CW ok
for it while nothing after the first window had happened at all \- a
rectangle that never held a window is background too.  A criterion that
only looks for absence passes hardest when the thing it is checking
never ran.
.PP
The screendump op is new:
.CW --input
now takes
.CW S:<file> ,
which photographs the screen there and then over QMP rather than at the
end of the boot, so one machine can be looked at after each gesture
instead of one boot per gesture.
.B "2.3q: an arrow on the screen."
The draw server has had a software cursor since it was written:
.CW cursor.c
composites the Plan 9 arrow onto the frame buffer and lifts it again,
under a lock it shares with the 9P write path, so a draw and the cursor
never touch the frame buffer at once.  It never ran here.  What it does
first is
.CW "segattach(0, \(dqmousering\(dq, 0, 4096)" ,
and on this configuration that fails \-
.CW "osprey user: segattach(mousering) failed: bad arg in system call"
is in every log of every rio boot in this document, unremarked.
.PP
It fails for a good reason.  On the full personality the kernel's aux
interrupt fills a page with raw PS/2 bytes, publishes it as the physical
segment
.CW mousering ,
and a user-level mouse driver decodes a position into the same page for
the cursor to read.  On the microkernel personalities the controller is
granted whole to one container, whose driver reads port 0x60 with its
own
.CW inb ,
and arming the kernel's handler as well drains the byte that driver's
handshake is waiting for \- which is written down at 2.2 and is why
.CW devinput.c
exists at all.  So there is no mouse ring, and the container that knows
where the pointer is is not the container that owns the frame buffer,
and neither can name the other's memory.
.PP
A page holding two numbers is not an arrangement for reading the
hardware.  The kernel publishes one as the physical segment
.CW pointerpos ,
x then y at offset zero, wherever a frame buffer is exposed;
.CW devinput.c
attaches it and writes the position every time a packet moves the
pointer or a program writes
.CW /dev/mouse ;
and
.CW cursor.c
takes the mouse ring's position if there is a mouse ring and this page's
if there is not.  Two containers of one kernel share the one page the
kernel gave them, which is the whole of the mechanism.
.PP
It is worth being plain about which half was missing.  The compositing,
the sprite, the save-and-restore, the lock against the draw path: all
of that was already written and already correct.  What was missing was
that nobody told it where the pointer was.
.PP
The check is the strong form.  The window-gesture check takes five
screendumps, and the input sequence leaves the pointer at a different
known point for each, so the criterion is a matrix: the arrow's black
pixels in the 16x16 sprite box at this shot's point, and nothing at the
other four shots' points.  It comes out diagonal \- 145 on it and 0
off it, five times over, the same 145 pixels the arrow's mask has.  An
arrow that were painted and never lifted would fill the matrix rather
than its diagonal, and an arrow drawn at a stale position would put the
145 in the wrong column.
.PP
The arrow waits to be told where it is.  The first cut had
.CW cursor.c
seed the centre of the screen and draw there, which is what it had
always done on the full personality \- and the pair check failed at
once:
.CW "and it paints the screen" ,
which reads back the middle of the frame buffer and four points inside
its corners and wants rio's
.CW 0x777777 ,
found the arrow's black in the middle instead.  It was right to.  Until
a packet has arrived there is no pointer, and an arrow before then is a
mark on the screen that nothing put there.  So the position carries a
third number saying it has been reported, both drivers set it when they
publish, and the sprite draws nothing until it is set.  On the full
personality that changes nothing, because
.CW mouse.c
publishes a position as it starts.
.PP
One number in the check moved because of this and is worth naming: after
the second window is deleted, the rectangle it occupied holds 56 white
pixels rather than none, and they are the arrow's outline, because the
pointer is still where the window was pointed at.  The criterion says
so and bounds them rather than leaving a threshold with room in it for
something unexplained.
.NH 2
Track three: the library-OS personality execs a program, then rio
.PP
.B "Phase 3.1: exec in place."
The library-OS task is its own program; to run another it execs in
place \- a library
.CW exec
that reads a binary through the task's own name space, lays its
segments over the current address space, and jumps to its entry, the
personality library part of the new binary as of the old.  Proof: the
library-OS task execs a second library-OS program that prints and exits,
the name space it built still under it.
.PP
.B "Done, and the plan as phrased is not what was built."
The two halves of that sentence cannot both hold, and the link map says
why.  The personality's live state \-
.CW up ,
the arena's cursor, the cooperative scheduler's run queue, the ring
mappings, the IP stack's route generations \- is in the
.I data
segment, not the bss:
.CW 6l
puts a file-scope scalar there whether it is initialised or not, and of
the three hundred and forty-one named data symbols in the linked
personality, those are among them, while
.CW arena
itself and
.CW slices
are in the bss.  Replace the data segment, as an exec in place would,
and the name space's roots go with it \- the arena's bytes survive in
the bss with nothing pointing at them, which is worse than losing them.
Keep the data segment and the new binary has none of its own, its string
constants included, since
.CW 6c
emits those as data.  There is no cut between the two, so "lays its
segments over the current address space" and "the name space it built
still under it" name different programs.
.PP
What is built keeps the half that was the point.  The personality is not
reloaded; the program is loaded.
.CW /boot/prog2
is a separately linked binary, at
.CW 0x1000000
\- above the personality's image, which ends near seven megabytes, and
well below the stack \- read through the name space the first program
built, laid into the address space beside it, and called at its entry
with a table of the personality's own entry points
.CW ( p9lib.h ).
It opens
.CW /greeting
and reads it by
.I calling
the personality, an ordinary call in its own address space with no trap
and no ring, which is what track three of the plan is for; and it
creates a file of its own that the first program reads back afterwards,
so the name space under it is not merely of the same kind but the same
one, still live, never rebuilt.  Three criteria of the
.CW p964
check (twenty now) hold the three claims apart: that it was loaded and
entered, that it reached the file system by call, and that the name
space survived.
.PP
The one thing it asks a kernel for is the address space, and that is the
whole of what a library operating system should have to ask.
.CW segattach
with the name
.CW code
is a region the caller may write a program into and then run
.CW ( ospreysegcode ):
demand-zero, so nothing is carried until it is touched, writable because
the loader writes the program in, and executable because the program
then runs there \-
.CW flushme
on the segment, the same mark exec puts on a text segment, which is what
.CW fault ()
reads to leave
.CW PTENOEXEC
off.  A real
.CW SG_TEXT
segment will not do: it is mapped read-only and pages from an image, and
this memory has no file behind it, only the loader's copy.  The
microkernel's address-space service keeps its one call rather than
growing another number; every configuration that offers
.CW segattach
offers it.
.PP
.B "3.2a: a real command, its operating system a library in its own address space.  Done."
.CW /boot/libcat
is
.CW catp9.c
\- the same source as the cat that runs under the buddy on the server
personality, with no line changed.  What differs is the link.  It is
linked against
.CW p9crt.c ,
which defines
.CW open ,
.CW create ,
.CW read ,
.CW write ,
.CW close ,
.CW seek ,
.CW dup ,
.CW fd2path ,
.CW sbrk
and
.CW exits
itself, so the linker never pulls libc's system-call stub for any of
them: those calls go to the personality in the program's own address
space instead.  One program, two arrangements \- a process boundary and
a ring on the server personality, and here none at all.  It takes an
argument vector, grows a heap, opens
.CW /hello ,
dups the descriptor, asks its path and reads the file, and the file it
reads is one the 9P server holds across the ring, named with no device
in it and resolved through the personality's own mount.  Then it exits,
and exit is a call to the loader: the operating system outlives the
program it ran.
.PP
Two things the program needed that a kernel would otherwise have given
it.  Its descriptors are its own: the personality hands out whatever
number is free, which may be 0, 1 or 2, and for a program those three
are the console, which the personality does not hold \- so
.CW p9crt.c
keeps a table, as the buddy keeps one for the legacy binary it serves,
and numbers the program's files from three up.  Without it a program
that opened a file and got 1 would write its output into that file, or
to the console, by luck rather than by meaning.  And its heap is its
own, a megabyte in its own bss, because
.CW brk
on this address space is the personality's business \- the personality's
segments are laid out around the program, not below it \- so a loaded
program brings its heap rather than asking the kernel for one.
.PP
.B "3.2b: processes, and a shell that uses them.  Done."
3.2a left one thing named as what a shell would need: the library-OS
task had no processes to give a program, its own concurrency being the
cooperative kprocs of
.CW p9sched.c ,
which are threads of the personality.  That is now what a program can
ask for, and it is asked for in the shape the arrangement allows rather
than in Plan 9's.
.PP
fork is not a thing a library operating system can offer.
.CW rfork(RFPROC)
splits a flow of control inside one address space, and a library cannot
split its caller's C stack \- not without copying it, pointers into it
and all.  So the primitive is the one a shell was using fork and exec
together for, fused.
.CW spawn
loads a program, gives it a kproc of its own and a descriptor table of
its own, and answers with a number;
.CW wait
blocks until that number ends and yields its status;
.CW pipe
is the personality's own.  The three are new entries in the table a
loaded program is handed
.CW ( p9lib.h ,
version 3), and the program's standard descriptors come with it: a
loaded program is entered as
.CW "p9start(P9lib *lib, char **argv, int *std)" ,
where each of
.CW std[0..2]
is a descriptor of the personality's or \-1 for the machine's console,
which the personality does not hold.
.PP
Two things a spawned program gets that the personality's own kprocs do
not.  Its own
.CW Fgrp :
.CW kproc ()
shares the creating proc's descriptor table by pointer, which is right
for the stack's read kprocs and wrong for a program, because a pipeline
only reaches end of file when every copy of the write end is closed.  So
the child's table is built empty \-
.CW dupfgrp(nil)
\- and only the descriptors
.CW spawn
was handed are put in it, referenced again so that the parent closing
its own copies does not take the child's away.  And its own exit: a
program the personality runs to completion ends by longjmp back into
.CW p9exec ,
a spawned one by ending its kproc, and
.CW p9anyexits
decides which from the flow of control it is called on, so both kinds of
program are handed the same table.
.PP
.CW /boot/libsh
is that shell.  It is
.I not
.CW shp9.c ,
the shell that runs on the server personality, and the reason is the
arrangement rather than an omission: that shell forks and execs, and
neither is a thing this one can do.  The claim 3.2a earned \- one
program, two arrangements \- is a claim about commands, and it still
holds:
.CW catp9.c
is the same source on both.  It is not a claim about shells, and the
source says so rather than pretending.  What both shells understand is
the same script: one command a line, words on blanks, stages on
.CW | ,
.CW #
to end of line a comment.
.PP
The script the personality writes and runs has four lines.
.CW "/boot/libcat /hello"
runs a command on a spawned process and the shell waits for its status.
.CW "/boot/libcat /hello | /boot/libwc"
is a pipeline: two programs at two addresses, each with a descriptor
table of its own, the first's standard output and the second's standard
input the two ends of one pipe of the personality's, and the shell
closing its own copies of both.  The third,
.CW "/boot/libgen 200000 | /boot/libwc" ,
is there because the second proves less than it looks: 454 bytes fit in
a pipe, so nothing had to block and "a pipeline ran" would only mean the
writer finished before the reader started.  200000 bytes do not fit in
32768, so the writer blocks and the reader must run to drain it, six
times over, and the far end counts all 200000 \- the two stages are
alive at once, in one address space, with no process boundary and no
trap but the console.  The fourth,
.CW "/boot/libcat /hello | /boot/libcat" ,
asks for two of one image at once, and is there so that the limit below
is a thing that happens rather than a thing written down.  It was
refused when it was written.  It is not refused now: cat became a
relocatable module later in this document, and the line the personality
refuses is the fifth, which asks for two of
.CW /boot/libgen .
.PP
The honest limit is the link map.  A program is at the address it was
linked for and nothing here relocates it, so two of the same program
cannot run at once: they would be the one image, sharing its one data
segment, and each program's descriptor table and heap live in that
segment.
.CW p9spawn
refuses that by name \- a script line asks for it and is told no, and
the shell carries on \- rather than letting two instances
quietly corrupt each other, and each program that may run beside another
is linked at a base of its own \- prog2 at 16M, libcat at 20M, libwc at
24M, libsh at 28M, libgen at 32M.  (cat gave its base back when it
became a module; the rest still hold theirs.)  A program run twice in
succession is fine: the loader
zeroes the region before laying the file in it again, so its bss starts
empty the second time as it did the first.  Lifting the limit wants
either relocation or every mutable thing in a program's image reached
through a per-process pointer, and neither is here.
.PP
There are three ways out of a loaded program, and the third was nearly
missed: a raise.  A fresh kproc has no error label of its own, and the
personality's entry points do raise \- a write into a pipe whose reader
has gone is an error and not a short count, and
.CW p9write 's
own handler ends in
.CW nexterror ().
Without a label in
.CW procstart
that raise would unwind off the top of a spawned program's stack into
nothing.  The fourth script line is what shows it: the stage that was
started writes into a pipe whose reader was refused, and the error
becomes that program's wait status,
.CW "i/o on hungup channel" ,
which the shell prints before finishing its script.
.PP
One thing the checks turned up on the way.
.CW conf.pipeqsize
was never set, so it was zero and every pipe write filled its queue by
definition: the writer slept until the far end drained it, every time.
That worked, and hid what a pipeline does \- there was no size to
exceed.  It is 32K now, which is Plan 9's, and the third script line is
what proves the flow control is real.
.B "3.2c: a screen, and a program that draws on it.  Done."
The library-OS personality had no screen at all: its twenty-nine
criteria covered the name space, 9P, descriptors, pipes, spawn, a shell
and pipelines, and nothing that reached the frame buffer.  This is that.
.PP
The plan says rio here draws "to the same /dev/draw the draw server
holds", and the way it says it has to be read against what this
configuration is.  On the pair personality the draw server is a legacy
binary in a container of its own, started by the client asking the
buddy to exec it; this personality has no buddy, and giving it one
would make it the pair personality.  It also has, in the same section,
"no process boundary and no kernel personality" \- so the reading that
holds is the service, not the server: the same
.CW devdraw.c ,
here compiled into the personality.
.PP
Which turned out to be nearly free.  The kernel's draw device compiles
against this personality's headers with two changes and no shim at all:
the user-level draw server needs
.CW kshim.h
to stand in for Chan, Dev, the error stack and the allocator, and this
personality
.I is
the kernel's own upper half, so those are the types its name space is
already built from.  The two changes are an include guard, so the file
can be reached through a wrapper that supplies the personality's
headers instead
.CW ( devdrawp9.c ),
and the kernel's
.CW readstr
under the name the shim gave it.  Thirty-four files of
.CW libmemdraw
and
.CW libmemlayer
compile against the same headers with none.  What the device draws onto
is
.CW drawscreen.c :
.CW segattach
of the physical segment
.CW framebuffer ,
handed back as the Memdata whose pixels are the display's, so a draw
lands on the screen and there is nothing to flush.
.PP
One thing it needed that the personality did not have.  memdraw takes
image pixels from a Pool called
.CW imagmem ,
not from malloc, so that a window system's images are reused rather
than accumulated; the personality's allocator is a bump arena whose
free is a no-op, which is right for a name space and wrong for a
screen.  So image memory is the kernel's own
.CW pool.c
over chunks taken from the bump arena as it needs them: the chunks are
never given back, which is what a bump arena means, and the pixels
inside them are, which is what a window system needs.
.PP
.CW /boot/libdraw
is the program.  It speaks the draw protocol itself \- open
.CW /dev/draw/new ,
read the twelve fields, open the client's data file, write
.CW b
to allocate an image and
.CW d
to draw one into another \- rather than linking libdraw, because what
is being shown is the path and not the library.  It paints the screen
.CW 0x112233
and the rectangle (200,150)-(600,450)
.CW 0xCC7722 ,
and those numbers are in the program and in the check, both written
before the machine was ever booted: 120000 pixels of the one in that
box and 904000 of the other, which is what the screendump holds.
.PP
Two defects in the way, and the second is the one worth keeping.
.PP
The first: libc's allocator keys its pool on
.CW _tos->pid ,
and
.CW _tos
is set up by libc's own
.CW _main
out of the page the kernel leaves at the top of the stack.  A loaded
program is entered at
.CW p9start ,
not at
.CW _main ,
and shares the personality's address space, so it had none: the first
.CW malloc
read address 0x40, which is where
.CW pid
sits in a Tos.  A graphics program mallocs before it draws anything, so
that was the first thing that happened.
.CW p9crt.c
gives a loaded program a Tos of its own.
.PP
The second: the name space raises.
.CW p9open
calls
.CW namec ,
and a name that is not there unwinds rather than returning \-1.  That
is right for the personality, whose own callers are written around
.CW waserror ,
and wrong for the table handed to a loaded program, because that table
is the program's libc and a libc does not raise \- a program tests the
return and reads
.CW errstr .
Handing the raw entry points out meant the first open a program made of
a file that was not there unwound off the top of the program's frames
into whatever label the personality had up, which was not where the
program's stack was.  It faulted, jumping to nothing:
.CW "fault read addr=0xffffffff" ,
with the pc the same.
.PP
What found it is worth saying, because it is so ordinary.
.CW iounit (2)
opens
.CW /fd/<n>ctl ,
expects the open to fail on a system that has no such file, and carries
on with a default buffer size.  Every Plan 9 graphics program does it,
by way of libdraw's
.CW initdisplay ,
and nothing in this personality had ever done it before.  Each entry
point is now under an error label of its own and answers the way a libc
answers, and the table has an
.CW errstr
of its own as well, because a library operating system that refuses
should be able to say what it refused in the program's own words.
.PP
That changed one criterion, honestly rather than quietly.  The pipeline
whose reader never arrives used to end because the write raised and the
error label under a spawned program turned the raise into a wait status.
Now the write answers \-1 with a reason, and
.CW cat
does what cat has always had to do: reports it and makes it its exit
status, which the shell reads out of the wait.  The message goes to
descriptor 2, because descriptor 1 is the pipe that just refused.
.PP
Three of the four faults in this section were found the same way, and
the tool is worth naming: this configuration's
.CW donotify
now prints the user pc and the note before it panics.  A pc inside a
loaded program's image names the program, one inside the personality's
names the personality, and the a.out symbol table turns it into a
function \-
.CW plock ,
in the first case, which is how the Tos was found.  Before that the
console FIFO dropped everything the personality had queued behind the
panic and there was nothing to go on at all.
.PP
.B "3.2d: the real libdraw, unmodified, linked against the personality.  Done."
.CW /boot/libdraw
spoke the draw protocol by hand because that showed the path.  Now it
does both: it paints as before, pauses, and then calls
.CW initdraw
\- the real
.CW libdraw ,
built from the source in
.CW 9front/src
by this tree's own
.CW 6c ,
linked without a line changed against
.CW p9crt.c .
.CW initdraw
opens
.CW /dev/draw ,
reads the twelve fields, opens the client's data and refresh files,
builds the default font out of libdraw's own compiled-in subfont, reads
.CW /dev/winname
and attaches to the image the draw device named there; then
.CW allocimage ,
.CW draw
and
.CW string
paint (700,150)-(1100,450)
.CW 0x33AA55
with a line of text in it.  Every one of those calls is a call into the
personality in the program's own address space.
.PP
Getting there meant finding what was still a trap, and the way to find
it was to link the program against
.I only
the source-built libraries \- leaving out the prebuilt
.CW libc.a ,
whose members are the generated system-call stubs \- and read the
linker's undefined symbols.  That is the whole list of what stands
between a program and the personality, in one pass, rather than one
fault per boot.  It was five:
.CW pread ,
which
.CW namedimage
uses to read the draw device's control file at offset 0;
.CW stat
and
.CW fstat ,
which
.CW dirstat
and
.CW dirfstat
are;
.CW sleep ,
which libc's own
.CW lock
calls while it spins; and
.CW _onexit ,
the hook
.CW atexit
sets and
.CW exits
runs.  Each of those was libc's stub before, which on this personality
is a trap into a microkernel that does not answer the Plan 9 table: a
program that reached one did not get an error, it faulted.
.PP
So the table a loaded program is handed
.CW ( P9lib ,
version 5) has
.CW pread ,
.CW pwrite ,
.CW stat ,
.CW fstat
and
.CW sleep
in it.
.CW p9file.c
grew the offset-carrying halves of read and write, written as 9front's
.CW sysfile.c
writes them \- one body taking an offset where nil means use and
maintain the channel's own \- because the difference between
.CW read
and
.CW pread
is exactly where the offset comes from, and two bodies is how they
drift apart.
.PP
.CW pwrite
is in that table too, and the linker did not ask for it.  It was
already resolved \- by the prebuilt archive, whose stub is the console
call, which is what
.CW p9crt.c
was using it for: descriptors 0, 1 and 2 of a loaded program are the
machine's console, which the personality does not hold.  That works
only for as long as
.CW p9crt.c
does not define
.CW pwrite
itself, and a
.CW pwrite
of a file the personality holds must go to the personality and not out
of the console, so it has to.  The console call is therefore given a
name of its own:
.CW p9cons.s ,
one stub, the one trap in a loaded program.  Worth being exact about,
because the enumeration is the transferable part of this section and it
found four of these five: a call that is already wrong but resolved is
not a call the linker will name.
.PP
All five loaded programs link the stub and four of them reach it:
.CW libcat ,
.CW libwc
and
.CW libsh
each print to a standard descriptor the personality left as the console,
and so does
.CW libdraw .
.CW libgen 's
output is the near end of a pipe and never touches it.
.PP
Two more faults, and both were the same shape as the Tos of 3.2c: a
thing libc's
.CW _main
sets up that a program entered at
.CW p9start
never had.
.PP
The first was
.CW _privates .
.CW nsec (2)
is not a system call \- libc reads
.CW /dev/bintime
\- and it keeps its descriptor in a
.CW privalloc (2)
word.
.CW privalloc
returns nil when
.CW _privates
is unset and its callers do not check, so the store was to address 0.
This tree already knew that trap:
.CW init9tos.c
does the same job for the programs the buddy loads, and says in its own
comment why the block belongs on the caller's frame.
.CW p9start
now has one.
.PP
The second was the scheduler, and it is the defect this document had
already written down as missing: the cooperative scheduler had no idle.
.CW sleep (2)
put the only proc there was to sleep, and
.CW sched
found an empty run queue and panicked
.CW "no runnable proc (deadlock), tick 0" .
The tick was 0 because the cooperative clock is advanced by the
personality's event loops, and no event loop was running \-
.CW main.c
runs its programs one after another on the server's own flow of
control.
.PP
Whether an empty run queue is a deadlock depends on why it is empty.
If every proc is asleep on a rendezvous, nothing but another proc could
ready one and there is no other proc: it is a deadlock.  If some proc
is asleep on a deadline, it is an idle machine, and the way out is time
passing.  So
.CW sched
asks the microkernel what time it is
.CW ( p9nsec ,
the same clock
.CW /dev/bintime
reads) and turns the answer into the ticks the sleepers are counting.
It is a busy wait and the comment says so: blocking would mean downing
the tick semaphore, and that reservation belongs to whichever event
loop asked for it, not to the scheduler.
.PP
The check photographs the screen twice, because the screen is painted
twice and the second painting takes the whole of it.  An ordinary Plan
9 graphics program gets a window and gets it blank:
.CW gengetwindow
allocates one over the whole screen and clears it to white, so what the
first half painted is gone the moment
.CW initdraw
returns.  Both paintings are real and only one can be on the screen at
a time.  So
.CW osprey-console.py
gained
.CW --shot-at ,
which screendumps the moment a line appears and lets the boot carry on,
and the program pauses four seconds between its two paintings for the
shot to be taken in.  The first screendump holds 120000 pixels of
.CW 0xCC7722
in (200,150)-(600,450) and 904000 of
.CW 0x112233 ;
the second holds 120000 of
.CW 0x33AA55
and black glyphs together inside (700,150)-(1100,450), 904000 of white,
and not one pixel of either colour the first half painted.
.PP
That pause is also the only evidence
.CW sleep
works, so the program times it: it asks for 4000 ms and prints what
.CW nsec (2)
says elapsed, which is libc reading
.CW /dev/bintime
through the personality's own
.CW pread .
It says 4000.
.PP
The write path is the one piece of this that changed under something
already working, so it has a check of its own.  A write that is refused
has to leave the descriptor's offset where it found it: the offset is
advanced before the device is called and wound back by what the device
did not take, and a wind-back that was wrong would go unnoticed until
some later write to the same channel landed in the wrong place.  A pipe
whose reader has gone is the write that fails, and seek cannot be used
to look at the offset because a pipe is a stream and refuses one, so the
channel is asked directly
.CW ( p9fdoffset ).
The check reads the offset before and after and both must be 0.  With
the wind-back taken out the same boot prints 19, which is what makes the
criterion worth having.
.PP
One thing is not implemented, and 3.2e below says why more exactly than
this section first did:
.CW rendezvous .
It resolved to the prebuilt archive's stub, which is a trap this
microkernel does not answer, so a program that reached it faulted with
nothing to say why \- and this section could not see who would reach it,
because libc's
.CW qlock
names it as its default way to wait and nothing here contends a qlock.
That reading was incomplete: libthread's own scheduler is its second
caller, and 3.2f below implements it for real.  What stands from this
section is
.CW noted (2),
which is linked because libthread's
.CW note.c
also holds the two functions its scheduler calls and a file is linked
whole; no note is ever raised on a loaded program, so it resolves to
.CW p9crt.c ,
which says so and ends the program rather than answering.
.PP
.B "3.2e: a threaded program, on the real libthread.  Done."
.CW /boot/libthread
is an ordinary Plan 9 libthread program \-
.CW threadmain ,
.CW threadcreate ,
.CW chancreate ,
.CW send ,
.CW recv
\- on the real libthread, built from the source in
.CW 9front/src
with no line changed.  It sends five values, 1 through 5, across an
unbuffered channel from one thread to another and they sum to 15,
which are numbers stated in the program and in the check before either
was run.  An unbuffered send is a hand-off and not a buffer: the sender
blocks until the receiver takes each value, so neither thread could get
through the sequence alone, and what runs the other is libthread's own
scheduler inside the one flow of control the personality gave it.
.PP
libthread is written to be ported, and 9front keeps the porting layer
by itself:
.CW main ,
.CW _schedexec ,
.CW _schedfork
and
.CW _schedexit
are the system a port supplies, and they are the whole of
.CW libthread/main.c .
.CW threadmain9.c
is that file for this personality.  Three things it leaves out, each
for a reason:
.CW rfork(RFREND) ,
because libthread's own rendezvous is the one
.CW _qlockinit
installs and that one is entirely in user space and makes no system
call, so there is no group to leave;
.CW notify(_threadnote) ,
because the personality raises no notes on a program it loaded, and
leaving the call out is also what keeps
.CW notify (2)
unreferenced; and
.CW setjmp(mainjmp) ,
because on Plan 9 a new proc is
.CW rfork(RFPROC|RFMEM) ,
whose child gets a copy of the stack at the same addresses and can
longjmp onto it, and two stacks cannot be at one address here.
.PP
The enumeration was run again before any of it was written \- link
against the source-built libraries only and read the undefined symbols
\- and it gave three:
.CW rendezvous ,
.CW noted
and
.CW _exits .
.CW _exits
is real and was missing: it is what
.CW exits
runs the
.CW atexit
handlers before, and a flow of control that is not the last one uses it
directly.
.CW noted
is linked because a file is linked whole and nothing calls it.
.CW rendezvous
was defined the same way at first, and that was wrong \- it is called,
by libthread's own scheduler, as soon as a program has two procs; 3.2f
implements it.
.PP
Then the enumeration was run once more, with those three defined, and
it came back empty.  That is the sentence this section is for: a
threaded program on this personality links with the prebuilt
.CW libc.a
\- the archive of generated system-call stubs \- left out altogether.
Every call it and its libc make is either the personality's, through
the table, or code in its own image.  The one system call a threaded
program makes here is the console write, and the console is the one
thing the personality does not hold.
.PP
What that first commit did not have was a second proc; 3.2f is that.
.PP
.B "3.2f: a proc of a program's own, and the per-process word under it.  Done."
.CW proccreate
is libthread's
.CW _schedfork ,
and where Plan 9 answers it with
.CW rfork(RFPROC|RFMEM)
this personality starts a kproc of its cooperative scheduler at a
function.  The program sends its five values a second time, from a proc
of its own, and they sum to 15 again \- but by a different mechanism:
between threads of one proc libthread simply runs the other thread,
while between procs the receiving proc has no ready thread at all, goes
to sleep, and is woken by the sending proc.
.PP
Two things had to exist first.
.PP
The per-process word.
.CW privalloc (2)
is one word of storage that is this process's own, and libthread takes
the address of one in
.CW main
and then reads and writes it from every proc it has \-
.CW _threadgetproc
is a dereference of that one pointer.  In a kernel the word is on the
process's own page.  Here every flow of control is a kproc of one
address space, so there is one address and the scheduler swaps its
contents at the switch: the outgoing proc's copy is saved into its Proc
and the incoming proc's is loaded, both before the jump.  Before the
jump on purpose \- restoring after
.CW setlabel
returns 1 would leave a brand-new kproc, which arrives through
.CW launch
and not through a
.CW setlabel ,
running on whatever the last proc left behind.
.PP
And
.CW rendezvous (2),
which 3.2d and the first half of 3.2e both said was unreachable.  It
was, while a program had one proc.  libthread's scheduler is its second
caller: 
.CW runthread
puts a proc with nothing to run to sleep on the address of its ready
queue and
.CW _threadready
wakes it there
.CW ( sched.c ),
and without that a program's second proc would be started and never
woken.  So the personality has a real one now \- a tag table over
.CW ksleep
and
.CW wakeup ,
symmetric the way Plan 9's is, because libthread's sleeper drops its
lock before it rendezvouses and the waker can get there first.  It
needs no locks of its own: this scheduler switches only where it is
asked to, so the scan and the claim are one indivisible step already.
.PP
.CW getpid (2)
is the personality's too now, and it had to be.  libc's reads
.CW _tos->pid ,
and a program's Tos is in its image and shared by every flow it has, so
libthread would have stamped one number on all of its procs.  It is the
kproc's own number instead, and the check requires the two the program
prints to differ \- two flows reading one number would mean the
per-process word was not per-process.
.PP
And the personality has to wait for the flows a program made for
itself.  When the flow it entered the program on returns, the program's
own stack is done with but a proc it made may still be running in its
image, and loading something else over that image would be the end of
it.  The wait is a
.CW tsleep
and not a loop of
.CW sched ,
and the difference is the whole of it:
.CW sched
advances the cooperative clock only when the run queue is empty, and a
loop that calls
.CW sched
puts itself back on that queue every time round, so a proc still in a
timed sleep of its own would never see its deadline pass.  The two
would wait for each other for good.
.PP
That case is in the program rather than only in a comment: the second
proc sleeps 300 ms past the end of the first, and the check reads the
three lines in order \- the first flow's exit, then the second proc's
report of its sleep, then the personality returning from the exec.  It
is a negative control as well: with the wait written as a loop of
.CW sched ,
the same boot stops at the first of those three and eight criteria
fail.
.PP
.CW pexit
needed the same idle
.CW sched
had, and for the same reason: a program's second flow of control ending
while the flow waiting for it sleeps leaves an empty run queue that is
not the end of the machine.  It used to panic there.  It also has to
load the resumed proc's private words, which it did not \- without that
the next proc would run on whatever the dead one left in the block.
Both of those are faults this section's own test found, because nothing
before it had a program with two flows of control in it.
.PP
The swap is the load-bearing part, so it has a negative control too:
with the two memmoves taken out of
.CW sched ,
the same boot does not merely lose the second proc \- it fails at the
shell and dumps stack, six criteria before this section's own.  All of
this is compiled into four other configurations as well \-
.CW p9sched.c
is p9pair's and p9buddy's and p9linux's and the two-machine check's \-
so the whole set was run, not just p964.
.PP
.B "What rio still needs, and it is not libthread."
3.2c named rio's wants as
.CW /dev/draw ,
.CW /dev/mouse ,
.CW /dev/kbd
and a name space holding them, with libdraw and libthread linked
against
.CW p9crt.c .
All of that is now here or was already:
.CW #i
is bound and is this personality's own draw device,
.CW #m
is bound and is the user-space i8042 driver's keyboard and mouse,
libdraw runs unmodified and so does libthread.  The blocker rio is
actually behind is none of them.
.PP
It is relocation.  A loaded program is laid at the address it was
linked for and nothing here relocates one, which is why
.CW p9lib.h
has seven fixed bases and why spawn refuses a second instance of an
image already running.  rio makes a window and starts a shell in it,
and then makes another window and starts another shell: two instances
of one image, which here would be one image sharing its one data
segment, descriptor table and heap.  No amount of libthread makes that
work.
.PP
So the next item is named for what it is: relocation, or
position-independent loading, of a program the personality loads.  Two
roads were named here, and one of them was named wrongly, so the
correction is worth more than the original sentence.
.PP
This said the loader could not relocate an image because that wants
relocation records this compiler does not emit.  It emits them.
.CW 6l -u
is Plan 9's dynamically-loadable-module link, and it appends a table
after the symbol table:
.CW asmdyn ()
in
.CW utils/6l/span.c
writes a length, an import table, a count, and then the relocations
delta-encoded with a mode byte each.  Linking
.CW /boot/libthread
that way gives 516 relocations and no imports, and every one of them is
mode 0.
.PP
Mode 0 is
.CW ABSD ,
an absolute reference to a defined symbol, and the set is right for the
job rather than merely non-empty:
.CW modemap
maps the relative kinds to \-1, so a relative reference inside the image
is deliberately not recorded \- moving a whole image does not disturb
one.  What the table holds is exactly the addresses that would be wrong
at a different base.  The link also puts the image at 0 rather than at
.CW -T ,
which is what a thing meant to be placed anywhere should do.
.PP
Two more things the tree already knows, found by looking for the code
that consumes this table rather than by reasoning about the format.
.PP
.CW libdynld/dynld-amd64.c
is that code, and it settles what a relocation means here without
guessing: mode 0 reads a
.CW uintptr
at the offset \- eight bytes on amd64 \- adds the load base to it and
writes it back.  Modes 1 and 2 are for imported symbols and take their
value from the import table, which a self-contained program has none of.
So applying the table is one addition per entry at a known width, and
the width was the one thing a reader would have had to guess.
.PP
And the
.I entry
in a module's header is not a code entry.
.CW dynld.c
reads it as the address of the export table
.CW ( l->export
.CW "= (Dynsym*)(base+entry)" ),
which is why it points past the end of the text and into the data.  A
loader that relocates one of these cannot recover
.CW p9start
the way
.CW p9load
recovers it now, from the entry less the header; it has to look the name
up, in the export table the module was linked with or in its symbol
table.  That is not a difficulty, but it is the kind of thing that would
have been discovered by a program that ran and then jumped into its own
data.
.PP
.PP
.B "The answer, and a bug in the linker."
The question was whether the set is complete, and it was settled the way
it had to be: by relocating a program to a base it was not linked for
and running it.
.CW /boot/reloc
is that program, built to notice a correction that did not happen \- a
table of pointers to functions and a table of pointers to strings, both
in its data, and arithmetic over both, so a pointer nobody fixed is a
wrong number or a fault rather than a subtly different string.  The
loader for it is
.CW p9loadreloc ,
which lays the module contiguously (text, data, bss with no page
between, because a single base is added to every one of its addresses
and they must keep the distance the linker gave them) and applies the
table the way
.CW libdynld/dynld-amd64.c
does.
.PP
It faulted at once, storing through
.CW 0x308c8 ,
an address in nobody's image.  The instruction was
.CW "MOVQ AX, [0x48c8]" ,
whose
.CW disp32
is at offset 0x23 of the module, and the relocation table named 0x22.
Applying an eight-byte add at 0x22 reads the SIB byte as the low byte of
the value, and the address comes out shifted.
.PP
Counting made it exact rather than anecdotal.  Of the module's 287
relocations, 242 name an offset holding a plausible in-image address and
45 do not \- and all 45 become plausible one byte later, and all 45 have
a rex prefix in the four bytes before them, and all 45 are in text.
.PP
.CW utils/6l/span.c
says why.
.CW asmins ()
assembles the instruction into a buffer, and
.CW put4
and
.CW put8
record a relocation as it goes, at
.CW "curp->pc + andptr - &and[0]" ,
which is right at the time.  Then, if the instruction needs a rex
prefix, the prefix is
.I inserted
at the front afterwards \-
.CW "memmove(and+np+1, and+np, n-np)"
\- which moves every byte at or after np up by one and leaves the
recorded offsets behind.  Every rex-prefixed instruction with an
absolute operand gets a relocation naming the byte before its field.
.PP
The fix is four lines: move the offsets with the bytes.  With it the
same module has 287 relocations and none of them names a value outside
the image, and the program runs \- at
.CW 0x2c00000
and at
.CW 0x3000000 ,
the same module laid down twice, both copies reading their own pointers
correctly.  That is the thing the seven fixed bases cannot do.
.PP
The bug is in the
.CW -u
path, which nothing in this tree used until now: before this work there
was no
.CW -u
link anywhere under
.CW os/ ,
.CW mkfiles/
or
.CW utils/*/mkfile ,
and all twenty board configurations say
.CW nodynld .
.CW buildreloc.sh
is the tree's first.  The amd64 half of the loader that consumes it had
plainly never been exercised either \-
.CW dynld-amd64.c 's
.CW dynmagic ()
returns
.CW I_MAGIC ,
which is the 386's.  A constant that is wrong for the architecture and
has never drawn a complaint is itself evidence about what the absence of
complaints is worth.
.PP
The blast radius, since
.CW utils/
is shared and the fix lands in it: the other session on this machine
audited the four other linkers and I checked the two claims that are
checkable.
.CW 8l
cannot have this bug \- its whole
.CW asmins
is
.CW "andptr = and; doasm(p);" ,
with no prefix insertion and nothing that shifts after emission \- which
matters because
.CW os/inferno/boot/pc
is the one place this tree uses it.
.CW 5l ,
.CW 7l
and
.CW jl
cannot either: fixed-width instruction sets, and none of the four has a
.CW memmove
into the instruction buffer at all.  So the fix is
.CW 6l 's
alone, and it changes nothing that anything else in the tree links
today.
.PP
One more thing the doing of it taught, and it cost a sweep.  After
proving the fix by putting the bug back and watching the boot die, I
restored the linker and reinstalled it \- and did not rebuild the
module.  mk had no reason to: its prerequisites are the shell script and
the sources, and none of them had changed.  So the next full sweep ran
the module that had been built by the broken linker and p964 came back
32 of 43, minutes after the same code had been 43 of 43 by hand.
.PP
The general form is that a generated artifact depends on the tool that
generated it, and a make file that lists only sources cannot see that.
The narrow answer is a check in
.CW buildreloc.sh :
every recorded offset must name a value that is an address inside the
module, because a self-contained module's absolute addresses all point
into itself.  With the bug present it says
.CW "45 of 287 relocations name a value outside the module (first at 0x22)"
and refuses to write the image, instead of writing one that looks fine
and faults on the first instruction that uses it.
.PP
And one more, which was not a bug in anything I wrote.  With the module
in place the two-machine check failed six of its twenty criteria, three
runs running, and passed at the commit before.  The linker was not the
cause \- an ordinary link is byte-identical across the fix, which was
checked by building the same objects both ways and comparing \- and
neither was the demonstration, which does not run in that configuration
at all.  What differed was the personality image, about forty kilobytes
larger for carrying the module.
.PP
.CW osprey-check-p9wire.py
says why in a comment it already had.  A machine there does several
independent things that finish in either order, and it is stopped when
its markers have all been seen; the comment records an earlier round of
exactly this, where the cable phase was caught one run in four and the
answer was to wait for more than one marker.  The markers were the
exchange completing and the cable closing \- and most of the criteria
are about what the process that came over the wire says afterwards,
which the exchange completing does not imply.  Forty kilobytes was
enough to reorder them, and machine 2 was stopped in the middle of
supplying pages.
.PP
So the check waits for a third thing now: the arrived process having
exited.  That is the event the criteria are about, rather than a proxy
that can precede it.  A check that stops before the thing it measures
has happened is not measuring it, and it fails for a reason that has
nothing to do with the change in front of it.
.PP
So the road is open, the records are complete now that the offsets are
right, and what remains of the original question is narrower: whether
.CW 6l
calls
.CW dynreloc
at every site that produces an absolute address, in data as well as in
text.  It is called from the data path
.CW ( asm.c )
as well as the instruction path
.CW ( span.c ),
which is the right shape, but a set that is nearly complete is worse
than none \- it would lay down an image that runs until it reaches the
one pointer nobody fixed.  That is settled by relocating a program to a
base it was not linked for and seeing whether it still paints the same
pixels, not by reading the compiler.  Which is the phase, and it is a
phase and not a paragraph.
.PP
The other road is not needed for this: every mutable thing in a
program's image reached through a per-process pointer, which is the same
problem
.CW privalloc
has and a much larger instance of it.
.PP
.B "And then two of one program at once."
The mechanism above still asked the caller for a base, which is only
half of what a fixed base was.  It is an allocator now:
.CW p9lib.h
names a range and a slot size rather than an address per program, spawn
takes a free slot for a module and
.CW procdone
gives it back, and
.CW p9spawn
tells a module from an ordinary program by its magic
.CW ( p9isreloc )
and loads it accordingly.
.PP
So the personality spawns
.CW /boot/reloc
twice and waits for both.  They run at
.CW 0x2c00000
and
.CW 0x3000000 ,
at the same time, each reading its own pointers - which are different
addresses in the two copies.  A few lines earlier in the same boot the
shell is refused a second copy of
.CW /boot/libgen
and the check confirms the refusal, so the two claims stand side by
side: a program that is its address cannot be run twice, and a program
that is not can.
.PP
The slots are given back.  The two sequential runs that follow are laid
at the same two addresses the spawned pair had, which the check requires
- an address used, released and used again is what makes this an
allocator rather than a longer list of names.
.PP
What it is not yet is rio.  Both of the things this paragraph named as
open \- four slots, and nothing sizing a slot to its module \- are
settled below, and so is the shape of the whole shell: every one of its
programs but the one kept as a control is a module now.  What was in
doubt is settled too, and it was the whole of the doubt: the records
exist, they are complete once the linker's offsets are right, a real
program runs where it was not linked, and two of it run at once.
.PP
.B "The shell runs one of them."
.CW /boot/reloc
is a probe: it exists to be relocated, and nothing else asks for it.  So
the next step was to make a program the shell already runs into a
module and change nothing else.
.CW /boot/libcat
is linked with
.CW "6l -u"
now, by
.CW buildlibcat.sh ,
and the module check that
.CW buildreloc.sh
grew is shared between them as
.CW scripts/checkmodule.py :
the magic is a module's,
.CW p9start
is at offset 0 (read out of the symbol table, not assumed), there are no
imports, every relocation is mode 0, and every offset it names holds a
value inside the image.  A build that fails any of those does not emit
an image, which is what caught a stale linker twice.
.PP
.CW p9exec
takes a slot for a module and gives it back, so the shell's own
.CW cat
is no longer a fixed address.  The script's fourth line is
.CW "/boot/libcat /hello | /boot/libcat" ,
and the check requires two spawns of that one image at two different
addresses and two clean exits: the pipeline the personality could not
have run a boot earlier.  The fifth line asks for
.CW "/boot/libgen | /boot/libgen"
and gets the refusal, by name, with the first generator ending on the
write that had no reader - so the same boot shows both a module run
twice and a fixed-address program that cannot be.
.PP
.PP
.B "A slot is sized to a module, not to the first module in it."
Nothing did that, and the shape of the mistake is worth writing down
because it would not have looked like this mistake.  The loader asks the
kernel for a region once and uses it again afterwards, and it remembered
only the address it asked at.  A fixed base holds one program for the
life of the boot, so the size it was asked for is the size it needs, and
that was true for as long as every program had a base.  A slot is not
that: it holds one module and then another, and the second may be the
larger of the two.  Attached for the first and reused for the second, it
is a region a program writes past, reported - if at all - as a fault
somewhere else entirely.
.PP
So the record has a size in it now, a slot is asked for at the size a
slot is rather than at the size of whatever went in it first, and a
module larger than a slot is refused by name before it is laid anywhere.
The first of those \- the refusal to lay a program in a region attached
for something smaller \- cannot fire against the programs in this tree,
since every slot is attached at the full size and anything too large for
one never reaches it.  It is a guard against what a slot may hold in
principle, and the way to know a guard like that works is to make it
fire.
Both are checked against a boot, and both were made to fail on purpose
to see that the check would notice: with the fit bound shrunk to a page
the boot reports
.CW "/boot/libcat is 1077248 bytes and a slot is 4194304; it does not fit one"
and the check falls from 47 to 36; with the remembered size forced to a
page it reports
.CW "/boot/reloc needs 1077248 bytes at 0x2c00000 and only 4096 are attached there"
and falls to 39.  The message in the first is built from
.CW P9relocslot ,
which is why it still says 4194304 while the shrunk bound is what
refused it.
.PP
The count found something.  The table held eight records, and a boot
takes eight: prog2, libdraw, libthread, libsh, libwc and libgen at bases
of their own, and two slots.  It was exactly full.  One more of the
shell's programs made into a module would have overflowed it, and the
old code did not say so - it attached the region and then quietly failed
to record it, so the next load of that program would have asked the
kernel for ground it already held.  There are sixteen records now and
running out is refused out loud, and the boot prints which attachment it
is taking so the count is a thing the check reads rather than a thing
assumed.
.PP
.PP
.B "wc too, and three modules in one pipeline."
.CW /boot/libwc
is a module now as well, so the two programs a pipeline was made of are
both without addresses, and the script has a line with three stages in
it:
.CW "/boot/libcat /hello | /boot/libcat | /boot/libwc" .
Three modules are alive at once, in three slots the loader chose \-
0x2c00000, 0x3000000 and 0x3400000 in the boot the check reads \- and
the far end counts 645 bytes.
.PP
That number is worth explaining, because it is larger than the 454 the
two-stage line counts and the file did not grow.
.CW print
on this personality writes descriptor 1, so what a stage says about
itself goes into its own pipe rather than to the console whenever its
descriptor 1 is a pipe.  454 is the first cat and the file; the other
191 is the middle cat, whose descriptor 1 is the second pipe.  Nothing
of either is lost, which is the point: the bytes are counted at the far
end of two pipes and both stages' words are among them.
.PP
Two more falsifications.  With
.CW Nrelocslot
cut to two the third stage is refused \-
.CW "/boot/libwc: all 2 relocation slots are taken"
\- the shell says it cannot start it and carries on, and exactly the two
criteria that name three slots fail; that path had never run before.
With wc still holding its old base the check would have gone on passing
a criterion that named 0x1800000, so that criterion now asks for a slot
rather than for a number.
.PP
.PP
.B "The shell itself, and every slot at once."
.CW /boot/libsh
is a module as well now, and that is a different path through the
loader: the shell is the program the personality
.I execs
rather than one the shell spawns, so the slot is taken in
.CW p9exec
and not in
.CW p9spawn .
Until the shell was a module, nothing had ever gone that way \- the code
was written when cat became one and never ran.  The slot it is given,
0x2c00000, is one an earlier module gave back, so the allocator is being
used rather than a list of names.  Its free had no witness while the shell was the last module to run, so
one more module goes down through
.CW p9exec
after the shell has ended, and the slot it is given is the one the shell
held.  Disabling that free moves it to another slot and costs the check
two criteria, not one: the two earlier runs of
.CW /boot/reloc
leak their slots as well, and the five-stage pipeline runs out.
.PP
Closing that led to a hole worth naming.
.CW p9execreloc
is told which slot to lay a module in \- it is the demonstration that one
image runs at two addresses \- and it named the address without telling
the allocator, so the allocator would have handed the same slot to
somebody else.  Nothing did, because those runs are sequential and
nothing else is loading, but a mechanism with a way round it is not the
mechanism.  It claims the slot now and frees it, by
.CW p9relocclaim
and
.CW p9relocslotof ,
and what shows it is the shell: the shell asks for a slot rather than
naming one, and the slot it is given is one of the two those named runs
used, which it can only be if they gave them back.
.PP
The shell holding a slot is what makes the count reachable.  A count of
slots nothing ever reaches says nothing about them, so the shell's stage
limit went to five and the script has a five-stage line:
.CW "/boot/libcat /hello | /boot/libcat | /boot/libcat | /boot/libcat | /boot/libwc" .
Five modules beside the shell is six, which is every slot there is
\- 0x2c00000 for the shell and 0x3000000 through 0x4000000 for the
pipeline \- and none is left over.  1027 bytes come out of the far end,
which is the arithmetic the three-stage line establishes carried on: 454
for the file and the first cat, and 191 more for each cat that relays
it, of which there are three.  It is checked, because five stages that
exited cleanly while relaying nothing would satisfy every other part of
this.  With
.CW Nrelocslot
cut to five the last stage is refused,
.CW "/boot/libwc: all 5 relocation slots are taken" ,
the shell says it cannot start it and carries on, and exactly one
criterion fails: the one that says every slot is held.
.PP
Two criteria had to be rewritten and the reason is the same as twice
before.  Several script lines spawn the same programs, so a criterion
that searched the whole log for
.CW "cat runs as"
took one line's spawns for another's the moment a five-stage line was
added below it.  They are scoped to their own script line now, by a
helper that slices the log between one line the shell echoes and the
next \- and the boundary has to know that the shell says three things
beginning
.CW "libsh: /boot/" :
the line it is about to run, a line that ended, and a line it could not
start.  Only the first is a boundary, which the first version of the
helper got wrong and the check caught.
.PP
What is left is
.CW /boot/libgen ,
which stays at an address on purpose: it is what shows that a program
which is its address cannot be two.
.PP
.B "3.2g: the name space is the program's to change, and what rio still wants."
Everything up to here reads through the personality's name space.  A
program could open a name and could not change what a name meant, and a
library operating system whose caller cannot bind is offering a fixed
list of names rather than a name space.
.PP
What said so was rio.  The technique from 3.2e works on it unchanged:
link rio's own objects against the source-built libraries and
.CW p9crt.c
with the prebuilt archive of generated system-call stubs left off the
line entirely, and read the undefined symbols.  Eight, in one pass:
.CW bind ,
.CW mount ,
.CW unmount ,
.CW chdir ,
.CW rfork ,
.CW notify ,
.CW exec
and
.CW await .
The first four were the personality's own calls with nothing but a table
entry between them and the program \-
.CW p9bind ,
.CW p9mount ,
.CW p9unmount
and
.CW p9chdirchan
were all already written and all already used by the personality itself.
The table is version 7 and holds them, and the same link now names four
undefined symbols instead of eight.
.PP
.CW /boot/libns
is what shows they work, and it is written so that it cannot pass by
accident.  It reads
.CW /boot/libcat
by its whole name, then
.CW chdir s
to
.CW /boot
and reads
.CW libcat
with no slash in it, which can only resolve through the working
directory the chdir set; then binds
.CW /boot
onto
.CW /n
and reads
.CW /n/libcat ,
which can only resolve through the binding.  Then it unmounts
.CW /n
and reads
.CW /n/libcat
again, which has to fail: an unmount that did nothing would leave a test
of bind alone passing, so the refusal is as much of the claim as the
three that work.  Three ways to one file, 4096 bytes off each, and the
fourth refused.
.PP
Falsified by making
.CW libchdir
answer yes and do nothing \- the shape of an error that a test of
"chdir returned 0" would miss entirely.  The program says
.CW "by chdir -1"
against 4096 for the other two, one criterion fails and no other, 52 ok
1 fail.
.PP
The name space a program changes is the personality's, because there is
one of them: every flow of control here is handed
.CW up->pgrp
by pointer with no count between them, so a program that binds over
.CW /dev
has bound over the library's own.
.CW /boot/libns
puts
.CW #K
back on
.CW /n
before it ends for exactly that reason, which is a program being polite
and not a system enforcing anything.
.PP
.B "3.2h: a name space of the program's own."
Plan 9's way out of that is
.CW rfork(RFNAMEG) ,
and it is now what this personality means by rfork.
.CW p9forkns
answers the two name-space bits and refuses every other one by name:
.CW RFNAMEG
is a new
.CW Pgrp
with
.CW pgrpcpy
of the current one,
.CW RFCNAMEG
an empty one, and the old
.CW Pgrp
is not closed because it is the library's and is held by pointer.  A
.CW Pgrp
a program made for itself is closed when the program ends.
.PP
The rest of rfork is refused rather than granted, and the refusal names
the flags:
.CW "rfork 0x10: this personality answers RFNAMEG and RFCNAMEG only" .
.CW RFPROC
would split the caller's own C stack, which spawn and proccreate are
what there is for;
.CW RFMEM
and
.CW RFNOMNT
ask about an address space that is one address space;
.CW RFFDG
is what spawn gives every program it starts.  A success that did nothing
would leave a program believing it was two.
.PP
The check for this had to be in two halves, and finding out why is the
part worth writing down.  A program cannot see whether its name space is
private \- it has only its own name space to look through - so
.CW /boot/libns
rforks, binds
.CW /boot
onto
.CW /n
in its copy, and says so; and the script's next line asks
.CW /boot/libcat
for
.CW /n/libcat
in the shell's name space, where it must not be found.
.PP
Falsified by making
.CW p9forkns
answer yes and share anyway.  Every line
.CW /boot/libns
prints still reads correctly \- including
.CW "rfork(RFNAMEG) gave me a name space of my own"
and
.CW "the personality should not see it"
\- and the only thing that changes in the whole boot is that cat then
opens
.CW /n/libcat
and reads it.  One criterion fails, 54 ok 1 fail.  A check that had
asked only the program would have passed.
.PP
.CW mount
is in the table and no program here calls it \- exercising it wants a
9P server a loaded program can speak to, which is a later thing.
.PP
.PP
.B "3.2i: the other two groups, and the ones that are refused."
rio does not ask for
.CW RFNAMEG
alone.
.CW winshell
asks
.CW RFNAMEG|RFFDG|RFENVG
and
.CW main
asks
.CW RFENVG|RFFDG|RFNOTEG|RFNAMEG ,
so an environment group and a descriptor group had to be real too.  They
are:
.CW RFENVG
is
.CW newegrp
and
.CW envcpy ,
.CW RFCENVG
an empty one,
.CW RFFDG
is
.CW dupfgrp
of the current table and
.CW RFCFDG
of nil \- the same call spawn already uses to give a program its own
descriptors.  The old group is never closed, for the same reason the old
.CW Pgrp
is not: it is the library's and every flow of control holds it by
pointer with no count between them.
.PP
The environment is checked the same way the name space was, in two
halves, because a program cannot see out of its own groups either.
.CW /boot/libns
sets
.CW libnsshared
before it rforks and
.CW libnsprivate
after, and the script's next line asks cat for both: the first opens and
the second cannot.  Falsified by making
.CW RFENVG
answer yes and share anyway \- one criterion fails, 56 ok 1 fail.
.PP
The descriptor table is different, and the difference is worth being
exact about.  A spawned program's table is already its own, so what
.CW RFFDG
separates is the program from itself after the call, and nothing outside
it can see that.  What can be seen is that the two bits do different
things: a descriptor opened beforehand still reads after
.CW RFFDG ,
which is a copy, and reads \-1 after
.CW RFCFDG ,
which is an empty table.  That is the whole of the claim made for them,
and it is what the check asks.
.PP
Three groups more are refused, each for a reason that is a fact about
this configuration rather than a shrug.
.CW RFREND
wants an
.CW Rgrp
on the
.CW Proc ,
and the Proc this configuration carries has no such member \- rendezvous
here is the personality's own tag table in
.CW p9sched.c
and not the kernel's rendezvous group.
.CW RFNOTEG
wants
.CW setnoteid ,
which looks the process up in the port's pid table with
.CW pidlookup
and dereferences what it gets; the kprocs this scheduler makes are
numbered by
.CW p9sched.c
and never entered in that table, so the lookup would answer nil and be
dereferenced.
.CW RFNOMNT
wants
.CW devmask
and the
.CW nomntdevs
list, which this configuration does not carry.  The message names the
bits it cannot mean rather than saying no in general.
.PP
And one thing the first version of this got wrong, which the kernel's
own
.CW sysrfork
does not:
.CW notallowed ,
the devices a name space is refused, was not carried across to the copy.
A program that rforked was quietly given back devices its parent had
been refused.  It is copied now.
.PP
.PP
.B "3.2j: await, and what "mine" has to mean."
.CW await (2)
is what libc's
.CW wait ()
is written on, and rio's wait is written on that.  It waits for a
program without naming it, which the personality could not do:
.CW p9waitpid
takes a pid and sleeps on that program's own
.CW Rendez ,
which is no use to a flow that does not yet know which program it is
waiting for.  So there is one
.CW Rendez
that every ending program wakes, and
.CW p9waitany
sleeps on it.
.PP
Two things about that were worth getting right rather than nearly right.
.PP
The first is the sleep condition.  A wakeup on a shared
.CW Rendez
is news that a program ended, not news of which, so the condition has to
do the looking; and a condition of
.CW return0
\- sleep until woken \- would lose a program that ended between the look
and the sleep.  This scheduler is cooperative and would not have run the
other flow in that gap, so it would have worked.  A condition that is
only correct because of how the scheduler happens to work is a bug
written down as an assumption, so the condition is a real predicate.
.PP
The second is what
.CW await
means by a program of one's own.  A
.CW Proc9
records the flow that spawned it, and
.CW p9waitany
takes only those.  Without that it would be any program at all, and the
falsification is the loudest in this document: with
.CW mine
made global,
.CW /boot/libns 's
waits take the shell's children out from under it, the shell never
learns what its programs did, the rest of the script derails, and
.B eleven
criteria fail rather than one.  That is the shape of the bug
.CW ppid
is there to prevent, and it is not subtle once it happens \- it is only
subtle before.
.PP
.CW /boot/libns
starts two copies of cat, waits for both without naming either, and
parses each line with
.CW tokenize ,
which is the same parser libc's
.CW wait ()
uses on it: five fields or it is not an await line.  Then a third wait,
with none of its own left, which is refused \-
.CW "no living processes"
\- rather than answered with somebody else's program or left asleep.
.PP
The three times in the line are zeroes, and that is said rather than
left to be inferred from a plausible-looking number: this personality
does not account processor time to a loaded program, since every flow of
control is a kproc of one cooperative scheduler and nothing charges the
clock to one of them.
.PP
One thing this cost that is worth recording because it was my mistake
and not the mechanism's: the first version handed the spawned cats the
megabyte of
.CW /boot/libcat
to copy to the console, and the console write failed part way through,
so both children ended with
.CW "write failed"
as their status.  The await was working perfectly.  A test's argument
can be the thing that is wrong.
.PP
.PP
.B "3.2k: notify, and a truncation it found."
.CW notify (2)
has one thing it can honestly mean here and it is the thing rio asks
for.
.CW winshell
calls
.CW notify(nil) ,
which says "no note handler", and there is none: nothing on this
personality posts a note to a loaded program.  A loaded program is a
kproc of a cooperative scheduler the microkernel does not know about,
the note tree in
.CW devnote.c
is the buddy's and is about the kernel's own containers, and a program's
flow of control is never interrupted between one instruction and the
next.  So nil is answered truthfully, and it is not a bit that does
nothing: it asks for no handler and gets none.
.PP
A handler is refused, by name.  Recording one that nothing would ever
call is the failure this table has been refusing throughout - a caller
would write a handler, be told it was installed, and find out otherwise
only when a note it was counting on went nowhere.
.PP
That refusal is the first code in this tree that ever wrote an errstr
from a program rather than reading one, and it found a bug at once.
.CW liberrstr
is an exchange, as errstr(2) is on Plan 9, and the half that installs
the program's string did
.CW "kstrcpy(up->errstr, tmp, sizeof up->errstr)" .
.CW up->errstr
is a
.CW char* ,
so that sizeof is 8, and the message came back seven characters long:
.CW "notify:" .
The read half was always right, which is why nothing had seen it - every
message a program had ever read was one the personality had written.
It is ERRMAX now, and the check asks for the whole sentence rather than
for the word "refused", because a check that asked for less would have
passed over the bug that found.
.PP
Where that leaves rio: linked this way, one symbol is undefined rather
than four.
.CW rfork ,
.CW await
and
.CW notify
all resolve, and
.CW winshell 's
rfork and its
.CW notify(nil)
are both answered \- but
.CW main 's
rfork is not, because it asks for
.CW RFNOTEG ,
which is the one of the three refusals rio actually needs.  So the note
group is owed, and it is owed for a reason written down above rather
than discovered later.
.PP
And then it was none, because the last one was my own mistake.
.CW exec
was on the list because the enumeration linked 9front's own
.CW libthread/main.c ,
and this tree does not use it: the real build substitutes
.CW threadmain9.c ,
whose
.CW _schedexec
refuses \-
.CW "procexec: the library operating system has no exec; use the personality's spawn"
\- and never calls exec at all.  With the enumeration corrected to link
what the real build links, rio has no undefined symbols whatever.
.PP
.B "3.2l: rio runs."
.CW /boot/rio
is the real 9front rio, out of
.CW 9front/src/cmd/rio ,
linked against
.CW p9crt.c
and
.CW threadmain9.c
and the source-built libraries, with the prebuilt archive of generated
system-call stubs left off the line entirely \- so a call it makes that
this personality does not answer is a link error and not a fault on a
booted machine.  It is a
.CW "6l -u"
module of 1318912 bytes with 2004 absolute addresses in it, and it
passes every check in
.CW checkmodule.py .
.PP
On the machine it is laid in a slot, entered at
.CW p9start ,
and it runs.  It takes flows of control of its own through the
personality's
.CW proccreate ,
which is libthread's
.CW procrfork
underneath, and it makes its own file system server.
.PP
It stopped on a name first, and the name was the personality's fault
rather than rio's.
.CW "rio: can't create file system server: Enonexist: '/mnt/temp'" .
rio's
.CW cexecpipe
binds the pipe device onto
.CW /mnt/temp ,
opens both ends through it and unmounts it again, and the root device
keeps
.CW /mnt/temp
and
.CW /mnt/wsys
for exactly that program \- the comment in
.CW devroot.c
says so and names rio.  What hid them was the personality's own
demonstration of bind, which put the environment device over
.CW /mnt
with
.CW MREPL
and never took it off.  The name space a library operating system holds
is the one every program it loads is given, so a demonstration that
rearranges it and walks away has taken a mount point out from under a
program that has not run yet.  It puts
.CW /mnt
back now.
.PP
With that, rio makes its file server and a fourth flow of control and
runs on.  That is the whole of the claim.  It does not draw a window,
the boot ends with rio still inside
.CW p9exec ,
and where it goes after its file system is not established here.  What
is established is that the last thing between this personality and rio
was a name space rather than a mechanism, twice over.
.PP
.B "3.2m: what a window system finds, and two more of the same family."
Guessing at where rio blocks is no good, so the personality asks the
name space the questions rio is about to ask and puts the answers in the
log before it starts:
.CW /dev/draw ,
.CW /dev/mouse ,
.CW /dev/kbd ,
.CW /dev/cons
and
.CW /dev/winname
all open, and
.CW /dev/snarf
does not exist \- which rio opens with
.CW OCEXEC
and carries on without, so that is a fact about this name space rather
than a failure of it.  A mouse and a keyboard are there, which was the
thing most likely not to be.
.PP
Writing that probe found two more bugs of the family this whole section
keeps turning up.
.PP
The first was the personality's.
.CW procdone
frees the
.CW Pgrp
and the
.CW Egrp
a program made for itself, and left
.CW up->
pointing at both \- it does the careful "put it in up->, close it, set
up-> to nil" dance for the descriptor table and not for the other two.
The proc is ending and will not use them again, but a live
.CW Proc
with a freed
.CW Pgrp
in it is a pointer the next thing to walk the proc list follows.  It
showed up the way these do: adding six lines to
.CW main.c
moved the text, and the boot died at the end of
.CW /boot/libns
with a jump to
.CW 0xffffffff .
Clearing them cured it.
.PP
.B "3.2n: rio draws."
With the devices there, rio is not blocked on anything: it makes its
file server, opens the draw device, allocates its screen, paints it, and
waits for a mouse click.  Nothing clicks, so nothing more happens \- an
idle window system with no input to read looks, from outside, like the
personality's server loop spinning, which is what the watchdog notices.
.PP
rio is therefore spawned rather than run to completion.  The personality
gives it three seconds of the clock, says so, and lets the task end \-
which also ends the boot on a sentence rather than on the harness giving
up.  A third screendump is taken at that sentence, and the screen QEMU
scans out is 1280 by 800 with every one of its 1024000 pixels 0x777777.
.PP
The first version of that shot fired at the watchdog noticing the
personality's server loop spinning, which is what an idle window system
looks like from outside.  It passed on its own and failed the moment the
whole sweep ran two configurations at a time: a timing artifact is not a
marker.  A screendump wants something the machine says, and the machine
now says it.
.PP
Spawning it improved the log as well.  A spawned program's kproc carries
its own name, so the four flows rio makes are reported as rio's rather
than the server's:
.CW "p9 proccreate: /boot/rio gets a second flow of control as 126" .
.PP
That number is rio's and can be nobody else's.  It is the constant on
line 190 of
.CW 9front/src/cmd/rio/data.c ,
where rio allocates its background image, in source this tree did not
write and has not changed \- and the screendump taken a moment earlier,
before rio ran, has none of that colour and all of libdraw's: 119130
pixels of 0x33AA55, 870 of black glyphs and 904000 of white.  The
control is in the same boot as the claim.
.PP
The real 9front rio, linked against a library operating system and
loaded into a slot the loader chose, paints a microkernel's frame buffer
its own grey.  It has no window in it, because nothing has clicked.
.PP
.PP
.B "3.2o: what a window costs, and /proc/<n>/args."
rio makes a window when a mouse button is pressed, and nothing here
presses one.  It has one other way in:
.CW -k ,
which allocates a window over the bottom third of the screen at startup
and creates it without a click.  That was tried, and following it is how
the next gap was found.
.PP
.CW new ()
hands the window to
.CW winshell ,
which rforks
.CW RFNAMEG|RFFDG|RFENVG
\- all three answered \- mounts its own wsys, opens
.CW /dev/cons
twice, and then renames itself by writing
.CW /proc/<n>/args ,
which this personality did not serve.  Its
.CW devnote.c
had
.CW note ,
.CW notepg
and
.CW status
under
.CW /proc/<n>
and not
.CW args ,
so the walk failed; making it walk got
.CW Eperm ,
because rio
.I writes
that file rather than reading it, which is what a program renaming
itself does on Plan 9.
.PP
Both halves are served now, and both are answered from something the
personality genuinely knows: spawn already copies a program's argument
vector into its slot, so a read is that vector blank-separated, and a
second flow of control made by
.CW proccreate
carries the same one because it is the same program running.  A write
stores what was written.  A number that is not a flow of this
personality's is answered with nothing rather than with a guess.
.PP
And then rio still has no window, for a reason that is the design
question rather than a gap.
.CW winshell
ends by execing
.CW /bin/rc ,
.CW threadmain9.c 's
.CW _schedexec
refuses because a library operating system has no exec,
.CW new ()
gets the failure back on its pid channel, and rio takes the window down
again and aborts its file server.  The window exists for exactly as long
as the exec takes to fail.
.PP
So a window costs exec.
.PP
.B "3.2p: exec is spawn, and the two things that were not about exec."
libthread does not ask for exec on its own account.
.CW _schedexec
rforks and execs in the child and answers the parent with the child's
pid \- fork and exec, fused, which is exactly what the personality's
spawn is.  So
.CW threadmain9.c
answers it with spawn, and procexec cannot tell the difference: it gets
a pid back, the program runs, and the wait after it finds it.  This is
not a stub standing in for exec; it is the same operation libthread was
asking for, done by the primitive this system has.
.PP
.CW /boot/libthread
proves it rather than rio does, which is the right way round: it is the
program written to exercise libthread, and it now runs
.CW procexec
on
.CW /boot/libcat
and reports the pid.  cat runs on that pid and reads the file it was
given, so the descriptors went across with it.
.PP
Two things had to be fixed to get there and neither was about exec.
.PP
procexec makes a pipe and then opens
.CW /fd/<the\ write\ end>
to get a close-on-exec copy of it, which is how it tells an exec that
worked from one that failed.  A loaded program's descriptor numbers are
its own \-
.CW p9crt.c
keeps a table and hands the personality the number behind each one \-
so the number procexec writes into that path was not the number that
path meant.
.CW p9crt.c
translates the number in the path now, the same job it already does for
a number in a call, and only for the plain forms of it: /fd is a
directory with other things in it and this is a translation, not a
takeover.
.PP
And
.CW #d
answered only for the buddy's containers.  A container's fd n is a
number in the buddy's own table, so the device asks which container it
is answering for and refuses when there is none \- which is every call
made by a flow of this personality.  It answers
.CW up->fgrp
now when no container is asking, which is what "the calling process's
descriptors" means when the caller is not a container: exactly where
.CW fdtochan
was going to look anyway.
.PP
.PP
.B "3.2q: a window, and a descriptor table that was one table too few."
With exec answered,
.CW -k
got as far as having the window's own 9P channel closed under it, and
the reason was the same shape as everything else in this section: a
thing that has to be per-something was per-something-larger.
.PP
.CW winshell
begins by closing the server end of the pipe its file server reads.
That is safe on Plan 9 exactly because winshell rforked
.CW RFFDG
first, so the close is to its own copy.  The personality-side table was
per-flow already \- that was built two sections ago \- but
.CW p9crt.c 's
is the program's own numbering, and it was one array for the whole
program.  So the close freed the number in every flow of rio at once,
and rio's file server, reading the descriptor it still thought it had,
got end of file on its own channel and shut the window system down.
.PP
The table is per-flow now, and the word that says which one is a
.CW privalloc (2)
word \- the one mechanism here for something a flow has of its own,
whose contents the scheduler swaps at every switch.  Nil means the
program's table, so a flow that never rforked and a flow made after
another one did both share, which is right.
.PP
Two things about that were found by the boot rather than by reading.
.PP
.CW privalloc
hands out a word and never takes one back, and claiming one at every
program's start spent them all on programs that never rfork \- so the
ones that did were refused, and fifteen criteria failed.  It is claimed
when a flow first asks for a table of its own and not before.
.PP
And
.CW RFCFDG
empties the table, which silenced the program that was reporting on it.
The machine's console is not a descriptor here: it is the one trap a
loaded program makes, reachable whether or not the program has a
descriptor table at all.  So it survives an emptying, and a program that
empties its table can still say that it did \- which on Plan 9 it could
not, because there the console is a descriptor like any other.  That is
a difference from Plan 9 and it is written down rather than smoothed
over.
.PP
One more, and it is the one that made the window a window.
.CW fdnew
allocated from 3 upwards, keeping the standard descriptors out of the
way.  A Plan 9 program does not expect that:
.CW winshell
closes 0 and opens
.CW /dev/cons
expecting the window to become its standard input, closes 1 and opens it
again for output, and never looks at the numbers it got.  Starting at 3
handed it 3 and 4 and left 0 and 1 as the machine's console, so the
shell rio then started read and wrote the console instead of the window.
It allocates the lowest free number now, which is what
.CW open (2)
answers.
.PP
So: rio allocates a window over the bottom third of the screen, hands it
to
.CW winshell ,
which rforks a name space, an environment and a descriptor table of its
own, mounts its own wsys, opens the window's
.CW /dev/cons
twice, renames itself through
.CW /proc/<n>/args
and execs
.CW /bin/rc
\- which is spawn here, and which the personality lays in a slot as
.CW "/bin/rc runs as 133 at 0x3000000, with its own descriptor table (0 1 -1)" .
Those two numbers are the window.  The shell's own complaint about the
arguments rio gave it goes into the window rather than to the console,
which is how the log shows it arrived.
.PP
.PP
.B "3.2r: the shell in the window, and what it writes."
The shell rio starts is
.CW /boot/libsh
under the name
.CW /bin/rc ,
and rio runs it as
.CW "rc -c <command>" ,
which it did not understand.  It does now: one line given outright,
run, and the shell ends, which is what
.CW -c
means.  The script path it already had is its other way in and the two
do not overlap.
.PP
That was not enough, and the thing it uncovered had been true since the
shell was written.  Its pipeline gave the ends of a pipeline as \-1,
which means the machine's console, and closed anything it was handed
that was not negative.  That was invisible while the only shell was the
one the personality starts, whose own 0 and 1 are the console anyway.  A
shell rio starts in a window has the window there, and a command it runs
with no redirection of its own should get the window.  The ends are the
shell's own 0 and 1 now, and what it closes is a pipe end it made rather
than either of those.
.PP
So the window's shell runs
.CW "/boot/libcat /hello"
and cat is started
.CW "with its own descriptor table (0 1 -1)"
\- those two numbers are the window \- and the 454 bytes it reads go
there.  They are not in the console log, which is where every other cat
in this boot puts them, and that absence is what the check asks for.
.PP
.PP
.B "3.2s: the window is on the screen."
The screen stayed the background alone for a while, and I wrote down
that the composite of a layered window was what had not been shown to
happen.  That was wrong, and finding out how it was wrong is the point
of this paragraph.
.PP
rio does not flush after every draw.  libdraw buffers, and rio flushes
when it has handled an event \- which is why the background appeared at
all: rio calls
.CW flushimage
itself, once, after painting it.  This configuration has no keyboard or
mouse driver running behind
.CW /dev/kbd
and
.CW /dev/mouse ,
so no event ever arrives, so nothing is ever flushed again.  Driving
QEMU's mouse over QMP changed nothing, which is what said the events
were not reaching rio rather than that rio was ignoring them.
.PP
The way to see it without an event is to give libdraw more than its
buffer holds.  The window's shell runs
.CW "/boot/libgen 20000" ,
20000 bytes go into the window, the buffer fills and flushes itself, and
the window is on the screen: 296135 pixels of the white text area,
29651 of black glyphs in it, 12304 of rio's own border colour around it
and 2390 of its scrollbar, against 683520 of background.  Those five
account for every pixel of a 1280 by 800 screen, and the text area is
rows 538 to 795 \- the bottom third, which is where
.CW -k
puts a window.
.PP
So the real 9front rio, linked against a library operating system and
loaded into a slot the loader chose, draws a window on a microkernel's
frame buffer with a program's output in it.  What is missing is input, and chasing that down changed what "missing"
means.
.PP
.B "3.2t: the driver is there; nothing wakes it."
There is a driver.
.CW p9kbd.c
is this personality's own user-space i8042 driver \- it takes the
controller's ports at CPL3, registers IRQ1 and IRQ12 as notifications on
two semaphores, does the handshake itself and reads every byte off port
0x60 with its own
.CW inb .
It is only ever started by the network demonstration in
.CW p9ip.c ,
which this boot does not run, so
.CW #m
is bound onto
.CW /dev
with nothing behind it at all.
.PP
Starting it from
.CW p9setup
is the obvious repair and it is wrong, which is worth having written
down.  It was tried: three checks broke \- kbd, rio and riowin, in
detail, no PS/2 packet decoded, no menu when the button is pressed, no
window swept.  Making the start idempotent did not fix them, which is
what said the trouble was not two drivers but
.I when .
.CW p9ip.c
starts it late, after the personality's loop is up, and the driver's own
comment says why that matters: the kernel side enables each device's
interrupt and unmasks the line last, so nothing fires until the kproc is
blocked in select.  Started during setup, before there is a loop to be
blocked in, it breaks the ordering on the configurations where it
already worked.  So it is not started here, and the change came out
again rather than being left in with three checks red.
.PP
And even started, that would not be input, for a reason worth being
exact about.  The driver blocks waiting to be told an interrupt fired,
and what tells it is the select loop in
.CW p9pairsrv.c
\- the personality's loop when it serves a peer over a ring, which arms
.CW Kbdsem
and
.CW Mousesem
beside the clock and the ring and calls
.CW p9kbdnotify
when either fires.  This boot is a script rather than a loop: it has no
select, so nothing turns a notification into a wakeup and no byte ever
reaches
.CW /dev/kbd
or
.CW /dev/mouse .
.PP
Driving QEMU's keyboard and mouse over QMP produces nothing in the log
\- not a scancode, not a packet \- which is what says the notifications
are not being serviced rather than that the driver is failing to read
them.  The same driver in the same tree does read them: the kbd check
boots
.CW 9p9pair ,
where that loop is running, and watches four keys and six mouse packets
arrive.
.PP
So the next thing was not a driver.  It was that a personality which
wants input has to have a loop.
.PP
.B "3.2u: a loop, and rio hears the mouse."
.CW p9input.c
is the smallest thing that is one: for as long as it is asked for,
select over the keyboard's and the mouse's semaphores, hand each
notification to the driver, and let the cooperative scheduler run.  It
is not a server \- it answers no ring and forwards no call \- and it is
not the clock; a personality that wants both will want
.CW serve1 's
shape rather than this one's.  The driver is started at the top of it,
which is the ordering the failed attempt got wrong: there is a loop, and
it is about to run.
.PP
The arms go in this container's own data area, and to write there the
slice has to be mapped, and to map it the container has to know which
slot is its own.  It could not: the server is
.I told
its slot, in the argument the kernel exec'd it with, and a container
that was not told has no way to find out.  Mapping every slot the kernel
allows and taking the one that looks right is not finding out \- the
probe that established this mapped four, with container ids 1, 3, 6 and
5, and nothing in them says which is the asker.
.PP
The kernel knows, because it is the container of the calling process.
.CW ReqWhoami
answers it, and that is the whole of the addition: one request, which
tells the caller only about itself, and which costs the kernel a lookup
it already does on every call.
.PP
With that, input works.  Two keys pressed over QMP come back as
.CW "scancode 0x1e read from port 0x60 in user space"
and
.CW "/dev/kbd queued the rune 0x61, 'a'" ;
a mouse move comes back as
.CW "dx=60 dy=-40"
and
.CW "/dev/mouse is at 700 440" .
The chain is QEMU's PS/2 controller, the microkernel's interrupt
notification, this container's semaphore, this loop's select, the
user-space driver's own
.CW inb ,
and the two files
.CW devinput.c
serves.
.PP
And rio hears it.  With the pointer moved into its screen and a button
held down, rio opens its menu: 4063 pixels of
.CW DPalegreen ,
which is the colour libdraw's
.CW genmenuhit
paints a menu item's body with, and which the shot taken a moment
earlier in the same boot \- same rio, no button \- has none of at all.
The press crossed all of the above and then rio and
.CW /dev/draw ,
and came back as pixels.
.PP
The check drives it.  It stops reading at rio's start, photographs rio's
screen, moves the pointer and holds a button, photographs that, and lets
the input path go on draining the serial line so the rest of the boot is
still there to be read.  The control is in the same boot as the claim,
which is the shape every screendump here has.
.PP
.B "3.2v: a machine to use rather than to check."
Two things stood between the checked boot and one a person can sit in
front of, and both are small enough to say in a paragraph.
.PP
The shell had no interactive mode.  rio starts the shell in a window it
sweeps with no arguments at all, and
.CW shlib.c
answered no arguments with a usage line and an exit \- so a new window
ran a shell that printed one line and died, and the window went with it.
A window system whose windows close as fast as they open is not one you
can use.  No arguments is a shell to type at now: it reads a line at a
time from descriptor 0, which in a rio window is that window's own
.CW /dev/cons ,
and does not echo, because rio has already drawn what was typed.
.PP
And the personality's loop runs for fifteen seconds, which is what a
check wants and no use to a person.
.CW scripts/osprey-play.sh
boots an image built with that number set long, with a display instead of
.CW "-display none"
and the serial console on a file instead of on stdout.  It is the same
kernel otherwise: the same personality, the same rio, the same driver.
The committed source keeps the fifteen seconds, because that is what the
check reads, and the script says in its own comment how to build the
other one.
.PP
The second was the probe itself, and it is the plainest lesson here.
.CW p9open
is the personality's own open and it
.I raises
rather than answering \-1 \- which every other caller in
.CW main.c
already knew, and which I did not.  A probe whose entire purpose is to
ask about names that may not be there had no
.CW waserror
of its own, so the first missing name unwound out of
.CW p9main
and came back as a wild jump with the half-built message still on the
stack:
.CW "0x7665642f27203a74"
is
.CW "t: '/dev" ,
and the next word is
.CW "/snarf'" .
Reading the stack dump as text is what named it.
.PP
.B "Two bugs that only rio was big enough to find."
The first was not rio running.  Adding rio to the boot files at all
killed the machine at
.CW touser ,
before the personality printed a word, with every check failing at once.
The boot files are byte arrays in the personality's own data, so rio's
373KB moved the end of its image: bss ended at 16.31MB and
.CW P9progbase ,
where the first loaded program is linked, was 0x1000000 - 16MB exactly.
Shrinking p9shim.c's arena until the bss ended below 16MB brought the
entire boot back, 59 of 59, which is what identified it; the personality
had been within 300KB of that cliff for some time and nothing said so.
.CW P9progbase
is 0x1c00000 now, in ground one of the freed bases used to hold, and
.CW p9setup
prints the distance at every boot \-
.CW "my image ends at 0x104ff48, 12255416 bytes below 0x1c00000"
\- because the quantity that closes the gap is the personality's own
size, and that grows whenever a program is added to the boot files.
.PP
The second was mine, and rio only exposed it by shifting the text far
enough to change which memory a freed pointer pointed at.
.CW libchdir
closed the
.CW Chan
it was replacing.  kproc on this personality hands its child
.CW up->dot
by pointer and increments no count, so every flow of control holds the
same one: closing it took the working directory away from the shell and
from the personality, and what came back was a read of address 0 in
.CW incref ,
which is nowhere near a chdir.  It is the same rule that was already
written down two functions away for the
.CW Pgrp
a program rforks, and I had not applied it here.
.PP
Which raised the question that rule always raises: what puts things
back?  A spawned program has nothing to put back because its flow ends.
A program
.CW p9exec
runs to completion is on the personality's own flow, so a name space, an
environment, a descriptor table or a directory it takes for itself is
one the personality is left with.  rio takes all of them.  So
.CW p9saveflow
and
.CW p9restoreflow
save the four and put them back, closing what the program made and
leaving alone what it was given, and the boot says which of the four a
program had changed.
.PP
One check had to move rather than change.  The second screendump fired
at the end of the run, which was the same thing as "when the drawing
program is done" for as long as
.CW /boot/libdraw
was the last thing to touch the screen.  rio is not: it calls
.CW initdraw
afterwards and takes the whole screen.  The shot is taken where the
claim is now, which is where the painting ends.
The pieces exist \-
.CW p9spawn
starts a program on a flow of its own,
.CW p9waitpid
waits for it, the loader lays a module in a free slot \- so these are a
matter of shape rather than of mechanism, and the shape is the question
of what
.CW rfork
can mean where there is one address space.
.PP
.B "3.2w: what a shell in a window is, and what it is not."
rio runs
.CW "/bin/rc -i"
in a window it sweeps, because that is what it does on Plan 9, and this
personality answers that name with a shell of its own.  That is a
substitution and it is written down rather than left to the name: the
boot says
.CW "/bin/rc is /boot/libsh, this tree's own small shell, and not rc" ,
and the first line in every window says it again.
.PP
There is no rc here.  The 9front source this tree vendors is rio and its
libraries, not the command set, and real rc could not run as it stands
anyway: it forks without execing \- for subshells, for pipeline stages
that are builtins, for functions \- and a library operating system has
no fork to give it.  Fork and exec fused is spawn, and that covers rc's
simple commands and nothing else.  Naming that limit is worth more than
a shell that answers to rc's name and hopes.
.PP
One line of rio's own
.CW -D
found the bug underneath this, which no check had: a swept window ran
.CW "/bin/rc -i" ,
the shell took
.CW -i
for a file to open, said
.CW "cannot open -i"
into the window and exited, and rio took the window down with it.  What
a person saw was a window that would not stay.  A check that swept a
window and looked for pixels would have caught it; there was none,
because until this session nothing could sweep a window at all.
.PP
.B "Phase 3.3: the personality runs executables, not libraries."
The arrangement this document has built is a library per program: every
one of them is linked against
.CW p9crt.c ,
which turns its libc calls into calls on the
.CW P9lib
table.  That is what makes rio work here, and it is not what a library
operating system is for.  A personality should run
.I an
executable \- an ordinary Plan 9 a.out, built the ordinary way, whose
libc makes ordinary system calls \- and answer those calls itself.
.PP
The mechanism to do it already exists in this tree, pointed the other
way.
.CW p9buddy 's
.CW dosyscall
sends a call it has no entry for to the container's server
.CW ( ospreybuddyforward ),
and a peer personality answers it; that is how an unmodified Plan 9
binary runs on the server side.  The library-OS form of the same thing
is that the personality answers the calls of programs in its own address
space: the library operating system is its own buddy.
.PP
What that needs, in the order it will have to be built: a
.CW dosyscall
on this configuration that hands an unimplemented call to this
container rather than printing that it is unimplemented; a way for the
kernel to block the calling flow and wake the personality's own service
on it, which is what
.CW p9buddy.c 's
workers already do for containers it answers for; and nothing at all for
the arguments, because a pointer a program passes is a pointer the
personality can already follow \- one address space, which is the whole
point of the arrangement and the one place it is easier than the server.
.PP
When that works,
.CW p9crt.c
is not needed to run a program, and the programs this document has been
linking against it are the special case rather than the rule.
.PP
.B "3.3a: the question asked, and the address in the way."
.CW /boot/legacy
is the program to ask it with.  It is an ordinary Plan 9 binary \- libc,
the generated system-call stubs, a body of ordinary
.CW open ,
.CW create ,
.CW write ,
.CW read ,
.CW fstat ,
.CW remove
\- and it is the one the buddy runs unmodified on the server side.  It is
a file of this personality now
.CW ( p9legacyfile ),
and
.CW p9execlegacy
enters it the way a kernel enters a program, with argv and nothing else,
rather than the way this personality enters its own, with the table.
.PP
The loader refused it, and the refusal is the finding:
.CW "/boot/legacy: it is linked at 0x200000, which is not a page boundary above my own image (0x10564f8)" .
.PP
An ordinary Plan 9 binary is linked at 0x200000, because that is where
Plan 9 puts one.  This personality is linked at 0x200000, because that
is where this linker puts a program.  They are the same address and
there is one address space, so the one thing a library operating system
must be able to do \- run the program, not a program built for it \- is
the one thing this arrangement had made impossible, and nothing had
noticed because every program so far was linked against
.CW p9crt.c
at an address chosen to miss the personality.
.PP
That is not a limit of the idea; it is a limit of where this personality
put itself.  The library is supposed to get out of the way of the
address the program was built for, which means linking the personality
somewhere an ordinary binary is not: high, above everything, with the
low addresses left for the programs.  The loader's own check \- it works
the address out of the binary's entry and refuses one that would land on
the personality \- is what caught this, and it is the check that will
say when the move has worked.
.PP
.B "3.3b: the library moves, and the program is entered."
The personality is linked at
.CW 0x40000000
now, and the low addresses are left to the programs.  Three things had
to follow it and the third is the useful finding.  The kernel's a.out
loader lays an image where the binary says it goes rather than at
.CW UTZERO
always, working the text base out of the entry the way
.CW p9exec.c
does.  The entry
.CW touser
and
.CW touserv
jump to is the task's
.CW ( up->aoutentry ),
set by whichever loader laid the image out.  A kernel-wide word for that
entry was the first attempt and this machine falsifies it in one boot:
it loads more than one kind of image, the personality's load overwrote
the flat tasks' entry before they had used it, and
.CW osprey-fs
died at
.CW 0x40000028 ,
which is the personality's entry and no address of its own.
.PP
.CW init0
also had to stop entering the vector with the stack pointer on it.  The
entry spills its argument register into the caller's frame at
.CW 8(SP) ,
and with
.CW SP
naming the vector that spill lands on
.CW argv[1] .
That was nil and unread while the personality took no arguments; the
moment it took one, the argument went in and never came out.
.CW touserv
leaves two words below the vector for exactly this reason and
.CW init0
uses it now.
.PP
.B "3.3c: the traps of a program that was not built for this."
The personality asks the kernel for its program's system calls
.CW ( ReqSyscallup ),
naming the image they must come from, and the kernel hands each one up:
the frame the call arrived on is copied to the stack and the task is
re-entered at
.CW p9syscall.c ,
with the call's number, its arguments where the caller left them, and
that frame.  The handler does the work with the name space it already
has \- the same
.CW libopen
and
.CW libpread
that serve a program linked against the table \- and hands the frame
back with a value in it
.CW ( ReqSyscallret ),
which is
.CW noted(NCONT)
with a return substituted.  The program's libc sees an ordinary
system-call return.
.PP
What tells the program's traps from the personality's own is where they
were made.  A task here has many flows, and while the program runs the
personality's own are still asking the kernel for
.CW select
and for the console; those come from the personality's text, a gigabyte
above the program's image, and are not calls to hand to a name space.
A flag alone would not have done it, and the address range is not a
heuristic: the trap came from inside the program's image or it did not.
.PP
.CW /boot/legacy
runs.  Its
.CW open(2)
is answered with a descriptor, its
.CW read(2)
with the bytes of a directory read through
.CW namec ,
and
.CW pipe ,
.CW rfork(RFNAMEG) ,
.CW bind ,
.CW unmount
and
.CW chdir
are served too, so it changes a name space of its own and the
personality gets its own back afterwards.  A request of the
microkernel's own \- number 60, above the Plan 9 table \- is passed on
rather than answered, because a program making one is asking the kernel
and not this name space.
.PP
Two of the calls matter more than the rest.
.CW exits(2)
returns to the personality rather than ending the task: on this
microkernel
.CW EXITS
idles the machine, and a library operating system whose program's exit
stopped the machine could run one program and no more.  And a fault in
the program is handed up the same way a system call is
.CW ( ReqFaultup ),
so the personality catches it the way a kernel catches a process's \-
the program ends there and the machine goes on.  The program faults on
purpose, reading address 0 to test a note handler it cannot have here,
and the personality runs the window system afterwards in the same boot.
The honest part of that claim is what it does not say: the personality
shares an address space with what it is catching, so it can report that
the program is over and cannot claim the program did no damage on its
way out.
.PP
And the claim this phase was for, put plainly.
.CW catp9.c
is one source.  Linked against
.CW p9crt.c
it is
.CW /boot/libcat ,
which calls this personality as a library; built the ordinary Plan 9 way
\- libc, the generated stubs, an argument vector, a heap grown with
.CW sbrk
\- it is
.CW /boot/cat ,
which traps.  Both run in the same boot, and the second reads the same
file, grows half a megabyte of heap through
.CW brk(2) ,
duplicates a descriptor and names it with
.CW fd2path .
.CW p9crt.c
is the special case here now, not the rule.
.PP
.B "3.3d: notes, and where a note may be delivered."
Three calls stay with the kernel while the personality serves the rest:
.CW notify(2)
and
.CW noted(2) ,
because the frame they act on is the frame the trap arrived on and that
is the kernel's, and
.CW alarm(2) ,
because that is the kernel's clock.  A personality that took them would
have to hand them straight back.  They are the buddy configuration's
own, moved across.
.PP
With them, an unmodified binary's notes work the way Plan 9's do.
.CW /boot/legacy
sets
.CW alarm(150) ,
its handler is called with
.CW alarm ,
it calls
.CW noted(NCONT) ,
and it comes back to the instruction after the call.  Then it registers
a handler and reads address 0 on purpose, and its own handler catches
the fault and exits on it.
.PP
The thing that had to be got right is when a note may be delivered.  A
note arriving while the personality is running is not the program's to
take: the frame it would bend is the library's, and the handler would
return into the middle of the call it was serving.  So a note that is
not a fault is held and delivered on the way back into the program,
which is the first moment the program's own registers are the ones being
returned to.  That is what a kernel does \- a note is delivered at a
safe point rather than at the instant it is posted \- and here the unsafe
points are most of the time, because the program's flow spends it inside
the personality.  A note that
.I is
a fault is about the instruction that made it, so one outside the
program's image is the personality's own and is the panic it always was.
.PP
And the other half:
.CW /boot/faulty
is an ordinary Plan 9 program with no note handler, which is what most
programs are.  There is nobody in it to give the note to, so the
personality ends it and goes on \- and the proof that it did is that the
boot reaches the window system afterwards.  Writing that control found a
real bug at once: the handler belongs to the program, and leaving
.CW up->notify
set across programs sent the next program's fault to an address in an
image that had been overwritten, which faulted again at the same pc for
ever.
.PP
What is not served, and is named in the log as it is asked for:
.CW rfork(RFPROC) ,
which is a flow of control a library cannot split for its caller
.CW ( p9lib.h
says why); and a second legacy program at the same time as the first,
since the kernel keeps one outstanding call and one image range and
p9syscall.c one descriptor table \- a second is refused by name rather
than served as though it were the first.
.PP
The demonstration is behind
.CW *legacydemo=
in plan9.ini, because what it does to the machine \- run a program that
deliberately faults \- is not what the boot every other check is written
against should do.
.CW *legacycontrol=
runs the same binary in the same kernel with the service not asked for,
and it dies at
.CW "unimplemented syscall 14" ,
which is where every Plan 9 binary died here before.
.CW scripts/osprey-check-p9legacy.py
is fifteen criteria over the two boots.
.PP
.B "Phase 3.2: a real program, then rio, linked with the library."
A real program \- a command, then a shell, then rio \- is linked with
the personality library into one microkernel task and run by the exec of
3.1, drawing to the same
.CW /dev/draw
the draw server holds.  This is the exokernel end of the paper: rio with
its operating system a library in its own address space, on the
microkernel, no process boundary and no kernel personality.  It is the
longest of the phases, and honestly named as the last.
.NH 1
Does an interrupt give back every register?
.PP
The trap entry is the one piece of code every configuration runs
through, and a register it failed to give back would not look like a
trap-entry fault from outside.  It would look like whatever the
interrupted instruction was about to do with that register.  Compiled
code holds a called function's return value in a register for the one
or two instructions before it stores it, so most interrupts land where
nothing cares, and the ones that do not become a nil where a pointer
belonged, a fault reading a struct at a small address, or an allocator
asked for a size with the top bit set.  All three are shapes this
branch has seen.
.PP
The occasion was the sibling kernel's, not this one's.
.CW os/inferno/pc64 's
.CW _intrcommon
built the Ureg's segment words with AX as its scratch
.I before
it pushed AX, and
.CW MOVW
from a segment register assembles to the 32-bit form, which
zero-extends over the whole of RAX: every interrupt handed the
interrupted code the DS selector \- zero \- in place of its AX.  That
was found by another session on this machine, which measured it rather
than reasoned it, and passed the method over.
.PP
This kernel's entry does not have that shape.  I checked by extracting
.CW _strayintr
through the start of
.CW vectortable
from
.CW os/osprey/pc64/l.s
and from
.CW os/9front/pc64/l.s
and diffing them: 72 lines each, no difference.  It never writes a
segment register through a scratch at all \- it reserves those words
with
.CW SUBQ
and fills the two it needs \- and AX is pushed before it is used to
reach the vector byte.  The syscall entry, which is this kernel's own
and not upstream's, is symmetric too: the user SP is parked at
.CW GS:8
before SP becomes the scratch that loads
.CW m
and
.CW m->proc ,
AX is stored to its Ureg slot before being reused to fetch that parked
SP, and
.CW forkret 's
loads match the stores one for one.
.PP
A reading is not a measurement, though, and a one-instruction window is
exactly what a reading misses.  So
.CW os/osprey/pc64/regtorture.s
measures: twelve registers loaded with distinct values and compared in
a spin with interrupts on, called from
.CW init0
once the alarm kproc is up.  Both halves are required and the check
reads both, because a loop that never ran would pass the first on its
own: the interrupts-on run clean, and the same loop under
.CW CLI
clean in the same boot as the control.  The tick count is reported and
required to be non-zero, since it is the evidence that any interrupt
happened.
.PP
The loop runs a fixed number of iterations and reads the clock either
side of it, rather than spinning until the clock has moved, and that is
a correction rather than the first idea.  The first idea was the bound,
and it was measured on two machines with results two orders of magnitude
apart: on the sibling kernel's guest four ticks cost thirty seconds of
boot, and on this one twenty ticks cost the two hundred milliseconds
they are worth \- 241.26 seconds for the whole check against 242.69 with
the bound gone, which is no difference at all.  A tick here is about a
million iterations, so the loop was working the whole time rather than
waiting.
.PP
So the reason to drop the bound is not that it is slow, because here it
is not.  It is that its cost is set by the guest's clock rather than by
the work: cheap where the clock is healthy and unbounded where it is
not, which is backwards for a boot-time check meant to run on machines
nobody has seen yet.  Neither of us could have said which we had without
measuring.  Four million iterations, and however many ticks that turns
out to span \- five, here.
.PP
A few ticks is enough for what this catches.  An entry that loses a
register loses it on every interrupt, not on a rare one: the bug that
prompted all this handed back the DS selector every single time.
.PP
It runs on
.CW pc64
only, because
.CW init0
is the full personality's and the six microkernel configurations say so
themselves \- they skip it.  That is not a gap in coverage of the thing
being measured: the trap entry is
.CW l.$O ,
one object, linked into all seven, so measuring it once measures the
code every one of them runs through.
.PP
What it does not cover, said plainly so that a clean run is not read
for more than it holds.  Not the syscall path: a kproc spinning with
interrupts on is only ever preempted through
.CW _strayintr ,
so it never goes near
.CW syscallentry ,
.CW forkret
or
.CW touser
\- which is to say the one part of this kernel's entry that is its own
code rather than 9front's is the part this test does not reach.
That half is
.CW os/osprey/pc64/userregtorture.s ,
below.  What is still not covered is R13, R14 and R15, which the kernel
loop itself uses; nor the segment registers, the flags, or any of the
x87 and SSE state.
.PP
The file is copied from
.CW os/inferno/pc64/regtorture.s
rather than shared, because kernels in this tree are self-contained: no
file under one flavour names another's source directory.
.PP
.B "And the other entry."
The syscall path is the half that matters more here, because it is the
half this kernel wrote: 9front's
.CW _strayintr
is shared byte for byte, while
.CW syscallentry
and
.CW forkret
carry both the Plan 9 and the Linux ABI and so save and restore every
register rather than the few upstream needs.  A kproc spinning with
interrupts on never reaches them.
.PP
.CW userregtorture.s
asks the question from where a system call can be asked from, which is
user mode.  It runs in the xup64 task
.CW ( userprog.c ),
sets eleven registers, makes a real system call and compares them, a
hundred times over.  The call is
.CW "pwrite(2, sp, 0, -1)" ,
a write of no bytes to the console: answered by even the cut
microkernel, without effect, and repeatable.  Its arguments go on the
stack because that is where
.CW syscall ()
reads them,
.CW ureg->sp+BY2WD ,
skipping the word a return address would occupy; they are written once
before the loop so the body is the call and the comparisons and nothing
else.
.PP
Four registers are excluded and each is named rather than quietly
skipped.  AX is the call's result.  CX and R11 are where SYSCALL puts
the user's ip and flags and what SYSRET consumes, so no program can
expect them back.  BP is RARG, which carries the call number.  The
eleven that remain include R14 and R15, which are the ones most worth
having: syscallentry loads
.CW m
and
.CW up
into them, so if a register in this kernel were going to be lost across
a call it would be one of those.
.PP
The Linux ABI is the other half of that entry and has its own loop, in
.CW linuxlegacy.c
\- the unmodified Linux binary the p9linux configuration runs, which is
built here from source, so the loop goes in it as a file-scope
.CW __asm__
block beside the one that already defines its
.CW _start .
Twelve registers there, not eleven, and the difference is the ABI's:
Linux promises back everything but rax, rcx and r11, argument registers
included, so rdi, rsi and rdx are checked against the argument values
they were given rather than against invented ones \- the same question
asked of the same three registers.  It reaches code nothing else does:
.CW syscall ()
in
.CW trap.c
takes a Linux process's number from rax and copies rdi, rsi, rdx, r10,
r8 and r9 into the argument block, a branch the Plan 9 loop never
enters.
.PP
Adding it broke a criterion that had nothing to do with it, and the
criterion was wrong rather than the change.  The p9linux check pinned
the Linux binary's entry to
.CW 0x4010xx ,
a 256-byte window, and adding a function to
.CW linuxlegacy.c
moved
.CW _start
to
.CW 0x4011f5 .
That address is not an invariant of anything \- it is where clang
happened to put the entry.  What the criterion means to claim is that
the buddy laid the binary out at the entry its own ELF header names, and
that the two halves of the buddy report the same address; a fixed window
tested neither, and would have gone on passing if they had disagreed
inside it.  It now reads the entry out of both messages and requires
them to agree.
.PP
That program already kept one register, rbx, across every call it made,
and that check stays: its scope is wider than the loop's \- every
syscall the program makes, of every kind, rather than a hundred of one
\- and the two answer different questions.  Twelve registers over one
call, and one register over every call.
.PP
A hundred calls, against the interrupt half's four million, and the
difference is not a compromise.  Whether an interrupt lands in the
window that matters is chance, so that test buys confidence by
repeating; a system call goes through the same save and restore every
time, so a register lost there is lost on the first call and on all of
them.  A hundred is also what it costs: a console write is about four
milliseconds on this guest, and a thousand of them made the boot sit
for four seconds.
.PP
Then the part worth writing down, because I did the thing I had said in
this document I would avoid.  The first version read its iteration
count from the stack.  On this compiler the first argument arrives in
RARG and only has a
.I home
on the stack, which the caller fills if it needs to spill \-
.CW ospreyxcall
in
.CW xcall.s
begins by storing RARG into that home for exactly this reason.  So the
loop ran a number nobody had chosen.  It still finished, and it still
found every register intact, and it printed the count the caller had
asked for because that count was a constant in the C.  It passed.  The
only reason it did not stay passed is that a larger count made the boot
hang long enough to look wrong.
.PP
So the number printed is now the number the loop counted, returned
through the caller's pointer, and the check requires the two to agree.
That is the negative control as well: putting the stack read back gives
a count that does not match and the criterion fails, in the same boot
where the registers are still all intact.  A test of a calling
convention that does not check it used the convention correctly is a
test of nothing, and "the registers survived" was true either way.
.NH 1
Checking, all of it
.PP
One thing to get out of the way first, because it is the kind of
mistake that reads as a clean result.  Two of the check scripts \-
.CW osprey-check-user.py
and
.CW osprey-check-rio.py
\- were committed without their executable bit.  The sweep runs every
check as
.CW "python3 <script>" ,
so it never noticed and never could; but running one by hand as
.CW ./scripts/osprey-check-user.py
fails with
.CW "permission denied" ,
and a hand-written
.CW "./check | grep FAIL || echo clean"
then prints
.I clean
\- because there is no FAIL line in a permission error either.  I did
that three times in a row and reported the result as evidence that a
failure had been a transient.  The conclusion was right, and two full
sweeps at 10 of 10 say so, but the evidence I gave for it was worth
nothing.
.PP
The general form is worth more than the incident: a check that cannot
run must not be able to look like a check that passed.  Grepping for
what failure looks like has that hole in it, and grepping for what
success looks like does not.  The bits are set now.
.PP
There are fifteen checks in
.CW scripts/ ,
one for each thing that boots, one for each pair of machines, and one
for the userland this tree builds from source, and for most of this
work I was running eight of them.  The three I was not
running were
.CW osprey-check.py ,
which boots the full 9front personality on
.CW pc64 ,
.CW osprey-check-net.py
and
.CW osprey-check-wire.py .
That is how
.CW pc64
came to be broken for four commits.  Phase 2.1 gave a loaded program an
argument vector by changing what
.CW _main
in
.CW os/osprey/pc/init9.c
takes \- the name of the program became the whole vector \- and every
path that enters a program through
.CW ospreyenteruservec
was given the matching stack in the same commit.
.CW init0 ()
in
.CW os/osprey/pc64/main.c
was not, because it is the one caller that does not go through that
vector: it is the full personality's own path, the one configuration of
the seven that takes neither
.CW ospreyuser
nor
.CW ospreymicro .
It went on building the 9front layout, in which the top word of the
stack is the nil return PC and the vector starts above it, so
.CW argv[0]
was that nil and
.CW sysexec
refused it:
.CW "boot process died: bad arg in system call" .
It builds the vector now, and the slot that held the return PC holds
.CW argv[0] ,
which nothing returns through because
.CW startboot
ends in
.CW _exits .
.PP
The general shape is worth keeping: a calling convention was changed
and tested against the callers that the same commit changed.
.CW scripts/osprey-check-all.sh
is the answer \- seven configuration builds, then all fifteen checks in
order, with
.CW -w
to repeat the two-machine check, which is the one that has shown
transients.
.PP
This document said until now that it had been flaky and, since 2.3k, is
not.  That is no longer true and the sweep that added the syscall
register measurement is what falsified it: the first two-machine run
came back 12 of 20, with every criterion from
.I migration:
onward failing together, and the second run in the same sweep on the
same binaries came back 20 of 20.  Three more runs afterwards were 20 of
20 each, so four consecutive clean runs stand against one failure.
.PP
The shape of that failure was worth recording even before it was
understood, because it was not the shape of a real regression: the
twelve criteria that passed were the setup half and the eight that
failed were the whole migration half, all at once, which is what a stall
looks like rather than what a broken mechanism looks like \- a broken
mechanism takes out one criterion and leaves its neighbours.
.PP
It is probably understood now.  The relocation work later made the same
check fail reproducibly, in the same shape but truncated at a different
point, and that one was chased down: the check stopped its machines when
the exchange had completed and the cable had closed, and most of its
criteria are about what the arrived process says afterwards.  It now
waits for the arrival to have exited as well.  No log survived the first
failure, so this is a probable cause rather than a demonstrated one \-
but it is the same check, the same shape, and a race the file's own
comment had already recorded one earlier instance of.
The tally as this is written, every configuration building and every
check clean, the two-machine check run twice in the sweep:
.CW pc64
62,
.CW p9pair
97,
.CW p9buddy
5,
.CW p9linux
13,
.CW p964
44, keyboard 8, rio 14, the window gestures 10, micro 7, user 11, net
13, wire 14, two-machine 20 twice over, the
six criteria of the userland the tree builds itself, and two portable
builds.  A criterion is a sentence a booted kernel printed
in answer to a command typed at its prompt, so a clean check is also
the prompt having been reached.
