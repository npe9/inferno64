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
