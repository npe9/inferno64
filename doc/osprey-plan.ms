.TL
Osprey Implementation Plan
.AU
Inferno RIO
20 August 2026
.PP
This plan follows the architecture described in
.I "Osprey: Operating System for Predictable Clouds"
while preserving the Inferno source layout.  Osprey is a kernel flavor, not
an architecture.  Its portable code belongs in
.CW os/osprey .
The source tree is separated by flavor: Inferno, 9front, and Osprey use
.CW os/inferno ,
.CW os/9front ,
and
.CW os/osprey
respectively.  The top-level
.CW Inferno ,
.CW 9front ,
and
.CW Osprey
directories are target build output.
.NH 1
What Osprey is
.PP
This plan was written from the architecture of a predictable-cloud
operating system.  The name is older than that: Osprey is Noah Evans's
own system, presented in October 2010, and the talk describes something
more particular than a scheduler and a set of queues.
.PP
Osprey is a microkernel with library operating systems above it.  The
kernel holds only fast message passing, address space maintenance,
interrupt handling and process scheduling.  Message passing is between
cores, flipping pages where it can; the talk measures a send, a receive
and a context switch together at 270 nanoseconds.  Segments may be shared
at different addresses, and processes that share an address space migrate
as a group.
.PP
The unit of execution is a task, not a Plan 9 process, and the central
call is
.CW select ,
which waits on an array of arms the caller owns and returns the one that
fired.  An arm is a message queue to receive from, or a semaphore to take.
An arm can be turned off in place rather than the array rebuilt.  A device
driver is a task that selects on its own message queue, on a semaphore an
interrupt raises, and on its output queue: interrupt handling stays short
and the driver runs in the scheduler like everything else.
.PP
The scheduler is real time.  A task reports the periods it has seen and
the best-effort time it has used, so a reservation is time the task is
owed and anything beyond it is best effort, accounted apart.
.PP
Files are reached over
.I \[*p]p ,
a protocol of the 9P family in which a session outlives the connection
that carried it, transactions group into one round trip, files carry
string attributes rather than control files, and versions are immutable
and committed when a file is closed.
.PP
What is built here follows the parts of that which fit a Plan 9 kernel:
the scheduler, the resource containers, the asynchronous rings and the
shared arena.  The task model, the select call, the semaphores and
\[*p]p are not built, and the sections below still describe the plan as
it was written rather than the talk.

.NH 1
Portable kernel layer
.PP
Complete the Osprey port layer in
.CW os/osprey :
process and resource-container state, per-core scheduling, asynchronous
request and reply queues, process lifecycle, and the portable syscall
contract.  This layer must not include
.CW Mach ,
trap frames, device registers, or architecture headers.
.NH 1
Architecture adapter
.PP
Build the machine-dependent adapter in the Osprey source tree.  It binds the
portable Osprey layer to the architecture implementation:
bootstrap, traps, interrupts, timers, MMU, page allocation, coherence, and
inter-core wakeups.  The adapter is selected by
.CW OBJTYPE
and the architecture mkfile; it is not a second Osprey source tree.
.NH 1
Native target
.PP
Add an Osprey native target mkfile that combines
.CW os/osprey
with the existing shared amd64 hardware sources and installs its result in
.CW Osprey/amd64/bin .
The first milestone is a kernel that boots to a serial console in QEMU while
the existing Inferno and 9front targets continue to build unchanged.
.NH 1
Queues and system calls
.PP
Map request and reply rings into user processes, provide architecture memory
barriers, and add the queue-full and wait paths.  Implement the portable
request dispatcher for file, process, IPC, and network operations.  Traps are
only the exceptional path; ordinary calls use batched asynchronous messages.
.NH 1
Isolation and scheduling
.PP
Enforce CPU budgets and deadlines in the per-core scheduler.  Add bounded
memory, network-byte, and packet accounting, private identifier namespaces,
local locks, and controlled process migration.  Keep device interrupts short
and wake driver tasks through the scheduler.
.NH 1
User-level services
.PP
Move protocol stacks, packet processing, and most file-system policy into
user-space services.  Add shared packet buffers and zero-copy paths, then
provide a buddy operating system and a library OS against the native Osprey
request ABI.
.NH 1
Checkpoint and validation
.PP
Define serializable process, container, namespace, queue, and buffer state.
Implement restart and migration after the single-host kernel is stable.
Validate each layer with compiler builds, QEMU boot, queue and EDF tests,
deadline accounting, and asynchronous file and network requests.
