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
.B "Checkpoint."
The serialisable part of a container: identity, core, state, accounting,
ring indices, namespace.
.NH 1
Next, in order
.PP
.B "1.  The packet path."
Packet descriptors carrying the driver's Block through a bounded queue
that charges the owning container, so that the network accounting already
in the policy layer has something charging it.  Then shared packet
buffers in the span, so a packet crosses to a user-level service without
being copied.
.PP
.B "2.  A service outside the kernel."
The request ABI as a library, so a process can be given a file system or
a protocol stack to serve rather than the kernel serving it.  This is
what the plan means by user-level services and what the presentation
means by a library operating system.
.PP
.B "3.  \[*p]p."
A session that outlives the connection carrying it, transactions grouped
into one round trip, string attributes in place of control files,
immutable versions committed when a file is closed, and leases.
.PP
.B "4.  Restart and migration."
Writing a checkpoint out and reading it into a fresh container, then
moving one between machines.
.PP
.B "5.  Page flipping."
Handing a page between containers instead of copying its contents, for
messages large enough to be worth it.
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
