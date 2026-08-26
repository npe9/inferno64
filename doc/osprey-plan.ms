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
What is built here follows the parts of that which fit a Plan 9 kernel.
The sections below are the plan as it was written, before the talk was
read; everything in them is done, and so are the parts of the talk they
did not describe \- the select call and its arms, semaphores an
interrupt gives, a driver served by a task waiting on the three things
the talk gives it, a reservation with best effort beyond it, and
\[*p]p, which is spoken over a file and on a wire of its own and
carries an attribute at a fixed rate when it is asked to.
.I doc/osprey-progress.ms
is what was built and in what order, and says plainly which parts of the
talk a kernel of this shape cannot reach: the microkernel itself, and
processes that share an address space migrating as a group.

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
request ABI.  File-system policy for the boards this tree already targets
means two device classes, not one: eMMC and SD, and raw NOR or NAND flash
with no controller of its own.
.CW os/inferno/port/devsd.c
and
.CW sdscsi.c
are the reference for the first;
.CW devflash.c ,
.CW "flashcfi8.c / flashcfi16.c" ,
and
.CW flashnand.c
are the reference for the second.  Osprey does not reuse them \- the
architecture adapter is where a board's storage controller is bound \- but
they say what the adapter must expose upward: block read/write for eMMC and
SD, and page program/erase with bad-block tracking for raw flash.
.NH 1
Storage tradespace
.PP
The boards this tree already builds for split cleanly into two storage
tiers, and they need different filesystem designs, not different tuning of
one design.
.IP \(bu 2
.B "eMMC and SD"
(the class
.CW virt ,
.CW sifiveu ,
and
.CW mangopi
target): wear-leveling, bad-block remapping, and erase are inside the
controller.  The kernel sees an ordinary block device.  Any conventional
file system works; the open question is only which one, and \[*p]p's own
protocol \- attributes as strings, versions committed on close \- does not
require any of them to support in-place update.
.IP \(bu 2
.B "Raw NOR/SPI-NAND flash"
(the class
.CW mps2 ,
.CW nucleof303 ,
and
.CW teensy41
target): no controller between the kernel and the cells.  Wear-leveling,
bad-block tracking, and erase-before-write are the file system's problem,
not hidden below it.  A conventional in-place file system \- even a
journaled one \- writes the same physical cells enough times to wear them
out inside a normal deployment lifetime, and journal replay after a crash
is not bounded by anything the scheduler knows about.
.PP
That second constraint is the one that matters most for a kernel whose
whole premise is predictability.  Log-structured storage \- write only to
fresh space, reclaim old space by copying its still-live data forward \-
solves wear-leveling and power-loss safety in the same design, and it is
already what \[*p]p asks of a file: a version is immutable once written,
and committed as a unit when the file closes.  Nothing in that protocol
wants an in-place overwrite.  What a log-structured file system does need,
and what a Plan 9 kernel does not normally give it, is a place to put
reclamation.  JFFS2, UBIFS, and F2FS all run compaction as background
kernel work with no accounting against anything \- exactly the unbounded
stall this plan's own scheduler section rules out for interrupt handling.
Osprey already has the right primitive for it: reclamation is a task, it
reports the period it needs, and time beyond its reservation is accounted
as best-effort the same as any other task's.  A compaction task that
misses its reservation shows up in the same accounting a slow network
driver would, instead of vanishing into an unmeasured kernel stall.
.PP
The tradeoff this leaves is where the reservation is spent.  A tight
reservation makes reclamation fall behind under sustained write load,
which shows up as write latency once free segments run out \- a
measurable, boundable failure, not a silent one, but a real one on a
teensy41-class node logging continuously.  A generous reservation
protects write latency at the cost of CPU the rest of the system could
have used.  Sizing it is a per-board decision (log volume expected of a
sensor node is not log volume expected of a gateway), not a kernel-wide
constant, so the request ABI should carry it as a parameter the storage
service task sets at start, not a compiled-in default.
.PP
Recommendation: build the block-device path first \- it is the eMMC/SD
tier, it needs no new erase/wear-leveling logic, and it validates the
user-level file-system-as-service model this plan already calls for.
Build the raw-flash log-structured service second, against the same
request ABI, with reclamation as an ordinary scheduled task from the
start rather than added once compaction stalls are already visible on
real hardware.
.NH 1
Checkpoint and validation
.PP
Define serializable process, container, namespace, queue, and buffer state.
Implement restart and migration after the single-host kernel is stable.
Validate each layer with compiler builds, QEMU boot, queue and EDF tests,
deadline accounting, and asynchronous file and network requests.
