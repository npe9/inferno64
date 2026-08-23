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
the device, and a kernel task of the container's waits on that semaphore
beside its request ring, does the register work, and lets the device
interrupt again.
.PP
.B "The packet path."
An ethernet interface handed to a container: its packets are charged
against the container's network caps and queued for it whole, each giving
a semaphore, without reaching the rest of the network stack.  The
interface takes its receive buffers from the container's own slice, so a
packet is written straight into memory the container has mapped and
reading one is being told where it is.
.PP
.B "A service outside the kernel."
A container may name another as its server.  Requests the kernel does not
implement are put on the server's ring with the container and sequence
they came from, an ordinary process takes them and answers them through
the same rings and the same select, and the answer is routed home.
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
.B "Pages handed over."
A container may take a page and hand it to another; what was written in
it is there afterwards, neither copied nor moved.  Both ends map the
whole span, so nothing is mapped or unmapped and what moves is which
container's map names the page: the copy is saved, which is the point,
but no page table is touched.
.PP
.B "Migration."
A container carried to another machine over a wire: its checkpoint in an
ethernet frame of its own type, read back into a kernel that had never
heard of it, and destroyed where it came from so that it is in one place
afterwards.
.PP
.B "Checkpoint and restart."
Every container as text: what it is, what it is allowed, what it has
used, and where it was running.  Reading it is a checkpoint and writing
one back is a restart, into this kernel or another one -- a container
that was running when it was written out is running again when it is read
back.
.NH 1
Next, in order
.PP
Everything the plan and the presentation describe that a kernel of this
shape can do is done.  What is left is either a different kernel, or work
neither source spells out.
.PP
.B "1.  A segment for each container."
The span is one segment and every process that attaches it has all of
it, so a container can read another's rings and a flipped page is only a
change of name.  A segment for each container would answer both, and
make a flip an operation on a page table.
.PP
.B "2.  Delegated authentication."
The presentation asks for authentication delegated across a distributed
system.  Nothing here does anything about who is asking: a container is
whoever can write to the device.
.PP
.B "3.  \[*p]p as its own transport."
It is spoken over a file.  The presentation has it able to be the
transport itself, and to carry isochronous data.
.NH 1
Not attempted
.PP
The presentation describes a microkernel with library operating systems
above it.  This is a Plan 9 kernel with an Osprey policy layer inside it,
and the parts of Osprey that are about where code runs rather than what
it does -- the microkernel itself, processes that share an address space
migrating as a group -- are not reachable from here without writing a
different kernel.  What is built follows the contracts rather than the
structure, and says so.
