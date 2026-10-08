.TL
Osprey: gap analysis against the paper and the talk
.AU
Inferno RIO
26 August 2026
.PP
This measures the current kernel against
.I "Osprey: Operating System for Predictable Clouds"
and Noah Evans's October 2010 talk, as summarised in
.I doc/osprey-plan.ms .
It says, component by component, what the paper asks for, what is built,
and what is missing.  It is written to be honest about size: some gaps
are a feature away and some are a userland away.
.NH 1
The four kernels this is measured across
.IP \(bu 2
.B pc64
\- the full Osprey kernel: a 9front-derived Plan 9 kernel with the
Osprey policy layer as the
.CW #O
device.  It boots a partial 9front userland (rc and basic commands from
the bootfs) to an rc prompt.  It is where the paper's mechanisms live and
are tested (58 checks).
.IP \(bu 2
.B upc64
\- the pure microkernel: the same core with the Plan 9 personality cut
out, leaving message passing, address spaces, interrupts and scheduling
and nothing else (7 checks).  This is the microkernel the plan said a
Plan 9 kernel could not reach; it is reached now, from the other side.
.IP \(bu 2
.B xup64
\- the microkernel running a user program whose OS personality is a
user-space library, reaching a file server over the ring by a minimal
open/read protocol (10 checks).  This is the library-operating-system
shape, in miniature.
.IP \(bu 2
.B p964
\- the same microkernel running the Plan 9 file personality proper: the
name-space machinery (chan, dev, pgrp, devroot) compiled as a user
library, which builds a name space, mounts devices, is a 9P client of a
server container over the ring and a 9P server of its own tree, and gives
a program a file-descriptor interface (12 checks).  This is where the
library operating system stops being in miniature.
.NH 1
Component by component
.NH 2
Message passing \- PARTIAL
.PP
Built: asynchronous request and reply rings in a shared slice, worked
from user space with no trap for submit or collect, one trap to service;
the select call over arms; semaphores an interrupt gives; forwarding a
request to a server's ring.  This is the mechanism the paper centres on
and it works end to end.
.PP
Missing: the paper's message passing is
.I between cores ,
flipping pages where it can, and it measures a send, a receive and a
context switch at 270 nanoseconds.  What is built is single-slice rings
in shared memory, not page-flipping cross-core transfer, and nothing here
is measured against that number.  The performance claim is untested and
the cross-core page-flip path is unbuilt.
.NH 2
Address spaces \- PARTIAL
.PP
Built: segments as the address-space service; a container's slice mapped
into a user program with segattach; the server reaching a client's slice
by the same right, which delegation grants.
.PP
Built since: the paper's
.I "segments shared at different addresses"
\- one slice attached twice, at two addresses, and the ring worked
through the second (doc/osprey-progress.ms, "The same slice at two
addresses").
.PP
Missing:
.I "processes that share an address space migrating as a group."
The plan once named group migration as a thing a Plan 9 kernel cannot
reach.  With the microkernel built that is no longer the reason: what
stands in the way now is that a container carries one process, so there
is no group to migrate.  It is unbuilt, and it is reachable.
.NH 2
Interrupts and the driver-as-a-task \- PARTIAL
.PP
Built: a uart driven by a task that selects on its interrupt's semaphore,
tested on pc64; the clock's interrupt giving a container a semaphore,
shown in the microkernel.  The shape the talk gives a driver \- a task on
its message queue, its interrupt's semaphore, and its output queue \- is
present.
.PP
Built since: the console is a task too on the microkernel \- every print
goes through a console container's uart task, the kernel writing the port
itself only for a panic or before the task exists (doc/osprey-progress.ms,
item 5).  Missing: the clock's accounting still runs in the kernel's own
interrupt, and rtc's register access is still the kernel's; the thin
register primitives stay in the kernel by design.  The kernel is nearly
but not entirely emptied of driver policy.
.NH 2
Scheduling \- PARTIAL
.PP
Built: an EDF scheduler with reservations and best-effort time accounted
apart, tested.
.PP
Built since: the uart task runs on the microkernel too, in a container
of its own, given work over its output queue by the server personality,
its bytes leaving on the second serial port (doc/osprey-progress.ms,
item 5).  Built since: the reservation is a parameter the storage task sets at
start by request (ReqReserve), the clock reaches it by request (ReqTick),
and the log-structured store's reclamation runs on that tick under that
reservation, on a block device driven from user space
(doc/osprey-progress.ms).  Missing: the raw-flash tier, which needs a
board this tree has no Osprey target for.
.NH 2
Files over \[*p]p \- PARTIAL
.PP
Built: \[*p]p, spoken over a file and on a wire, with a session that
outlives its connection and attributes carried as strings; the
delegation path by which a container's opens and reads are answered by a
server, not the kernel.
.PP
Grown since: the library OS's own file access is no longer a held pair
of files reached by an ad-hoc open/read.  On p964 it is the kernel's own
name space (chan/dev/pgrp/devroot) as a user library, speaking real 9P
\- Tversion, Tattach, Twalk, Topen, Tread, Twrite, Tclunk, Tstat, with
convS2M/convM2S \- through devmnt to a file-server container across the
ring, and answering 9P about its own tree through an exportfs.  It is
9P2000, and since then the talk's \[*p]p as well: the server personality
speaks pip(5) about its files (cmd/p9/pipfsrv.c) \- sessions, a grouped
open-read-write-close in one round trip, named attributes, a version
made by a write that nobody else sees until the close commits it \-
over the ring, checked on p9pair.  What is missing of \[*p]p there is a
wire of its own; the kernel's \[*p]p about containers has one.
.PP
Built since: a log-structured file store on a block device the kernel
exposed, mounted into the server personality and served to the client
over 9P, versions committed on close, persistent across boots, the log
reclaimed on the clock tick.  Missing: create and remove over 9P, and
the raw-flash tier.
.NH 2
Library OS and buddy OS \- PARTIAL
.PP
Built: a library-OS program on the microkernel whose personality is a
user-space library, opening and reading files over the ring from a server
that is itself a second user program - two user tasks exchanging the open
and read, the kernel only routing them, which is the shape the paper
draws; the buddy relationship on pc64, where what the policy layer cannot
answer the Plan 9 kernel around it does; and, on p9pair, a Plan 9
personality served by a second Plan 9 personality - each its own
container, the client delegating to the server and mounting its exported
name space over the ring by 9P, the kernel only routing - which is the
paper's "library operating systems on top of the Osprey kernel" with two
of them.  This is NOT the paper's buddyOS, and not only a different mechanism but a
different shape: the paper's buddy is a per-process peer, one bound to one
unmodified legacy binary, interposing on that binary's own system calls
and page faults and emulating a legacy OS for it (/dev, /proc) - the
recursive user-level-VM interposition of vx32 and the Fluke nested
process (the paper grounds it in Wine), not a shared personality server.
p9pair is a shared file server two library OSes talk through, a
different shape.  The buddyOS itself is now built, for the Plan 9 ABI:
the p9buddy configuration runs an unmodified Plan 9 binary in one
container, and the microkernel forwards each Plan 9 system call it does
not implement - open, read, close - to a peer that emulates it against
its own name space and hands the answer back, the legacy binary none the
wiser.  That is the per-process trap interposition the paper describes,
system calls and, since exec, page faults too (the binary is a file in
the buddy's file system, laid out and paged by it), and for the Linux
binary file mappings, its own descriptor table with the console at 0, 1
and 2, and SIGSEGV delivered to a handler or killing it.  The Linux ABI is served too: the p9linux
configuration runs an unmodified static Linux x86-64 binary (an ELF,
raw syscalls, no libc), the SYSCALL entry stores every register so the
Linux convention can be read and its callee-saved registers returned,
and the same buddy answers its open, read and close.  Its page faults
are interposed too: the binary is a file in the buddy's file system,
the buddy lays it out for the kernel and supplies each page as it is
first touched, so the kernel carries no copy of it; brk, anonymous
mmap and munmap are answered by the kernel's address-space service.
Only the file calls the demonstration makes are mapped.  p9pair is the library-OS
mechanism, one-directional (the client mounts the server, not the
reverse).
.PP
Closed since, and it was the largest gap: the library OS was minimal \-
a couple of files, no name space, no mount, an ad-hoc four-call protocol.
On p964 it now has a real Plan 9 name space (the kernel's own chan.c and
devices as a user library), mount and union walk through cmount, real 9P
to a server container over the ring and an exportfs back the other way,
and a file-descriptor interface \- open, read, write, close, seek, stat
and directory-list \- lifted from sysfile.c as a library.
.PP
The name space with bind and mount that the rio list asks for is built:
p964 binds a device onto a name and mounts a 9P server, creates files and
walks names across both.  Still missing toward a real 9front personality
that could run rio: exec;
the file operations as microkernel syscalls over the ring rather than an
in-process library (the exokernel shape keeps them a library, but a
process boundary would need the ring); a real file-system service behind
the 9P; and the draw stack.  That personality is described in its own
section below.
.NH 2
Checkpoint and migration \- PARTIAL
.PP
Built: serializable container state, checkpoint and restore, tested on
pc64.
.PP
Missing: group migration (see address spaces).  Migration between hosts
is built and checked since this was written \- a container's checkpoint
in an ethernet frame of its own type, restarted on a second machine and
destroyed at the first only after the second has said so
(scripts/osprey-check-wire.py) \- with the limits doc/osprey-progress.ms
records: one process, one frame, packets, pages and kernel channels not
carried.
.NH 1
The gap to running rio
.PP
The instruction is to get the 9front userspace working in the library OS
far enough to run rio.  This is the honest measure of the distance.
.PP
rio is 9front's window manager.  Running it needs, in the environment it
runs in: the draw device
.CW #i
and a frame buffer behind it; a mouse and a keyboard; libdraw and libc;
rc and the commands rio launches; a name space with bind and mount; and a
way to start programs \- exec.  In the library-OS environment as it
stands, none of these is present: xup64's personality library has no name
space, no exec, no graphics, and a four-call kernel interface.
.PP
Built since: exec.  A container submits the
.B exec
request with a program's name and the kernel starts it in a container of
its own, laid out, paged and answered for by the container's server; and
.B wait
returns its exit status (doc/osprey-progress.ms, the p9pair paragraph
under "The gaps").  What it starts is a Linux ELF or a Plan 9 a.out the
buddy answers for; rc or rio would need the buddy to answer far more of
the Plan 9 ABI than the file calls it maps.
.PP
What the tree has, and does not have, sharpens this:
.IP \(bu 2
The draw device (\f(CWos/osprey/port/devdraw.c\fP), a mouse device, and
a full set of VGA drivers including \f(CWvgavesa.c\fP are present in the
Osprey source \- but disabled in every config's device list.  Graphics is
a build-and-enable away on the kernel, not a port away.
.IP \(bu 2
The kernel already boots a partial 9front userland (rc, ls, cat, mount,
kbdfs) from the bootfs on pc64.  So a 9front userspace does run on this
kernel \- through the kernel's own personality, not through the library
OS.
.IP \(bu 2
libdraw, libmemdraw and libmemlayer \- the compositing libraries \- are
present, as C source (\f(CWlibdraw/\fP, \f(CWlibmemdraw/\fP) and prebuilt
in \f(CW9front/amd64/lib\fP.  So the pixel-pushing a draw service needs is
in hand.
.IP \(bu 2
rio itself, and the 9front graphics commands, are NOT present as source
in this tree, and there is no 9front \f(CWsys/src\fP.  This is an Inferno
tree with a 9front kernel; the window manager and its userland would have
to be brought in from 9front.  This is the hard boundary on the word
\(lqrun rio\(rq: the architecture can be built to the edge of it here,
but the rio binary is an import, not a build.
.PP
The draw stack does not go back in the kernel.  The architecture is the
exokernel one throughout: the microkernel exposes the hardware \- the
frame buffer as a physical segment a program may map, the mouse and
keyboard interrupts as semaphores a task selects on \- and the draw stack
itself runs in user space, in the library OS, as a user-level driver.
The kernel multiplexes the display; it does not know what a window is.
This rules out enabling devdraw and a VGA driver in the kernel config;
those move above the kernel.
.PP
So the path to rio is one direction, built up:
.IP "1." 4
.B "The microkernel exposes the frame buffer."
UEFI hands the kernel a linear frame buffer (the boot arg names it:
1280x800x32 at physical 0x80000000).  The microkernel publishes it as a
named physical segment, the way it publishes a container's slice, so a
user program may segattach it.  A program that maps it and writes pixels
is the first user-level driver, and it proves the model for graphics.
.IP "2." 4
.B "A user-level draw service."
The draw device's logic \- devdraw.c, the memdraw library \- moves into a
user-space graphics server that owns the mapped frame buffer and answers
draw requests over the ring, the way the file server answers reads.  A
mouse and keyboard driver task selects on the interrupt semaphores the
microkernel gives it.
.IP "3." 4
.B "The 9front personality as a library, and rio on it."
The library OS grows a real name space (bind, mount), the full syscall
set over the ring, and exec; rio and libdraw run as user programs against
that personality, talking to the draw service.  This is a userland of
work, brought in one service at a time over the ring, not one leap.
.PP
Recommendation, matching the plan's build-a-service-then-grow order:
build step 1 now \- the microkernel exposing the frame buffer to a
user-level driver \- because it is bounded and it is the graphics analogue
of segattaching the ring, which already works; then grow the draw service
and the personality above it.  rio is the far end of that line, and every
step toward it keeps the draw stack in the library OS where it belongs.
.NH 1
The 9front disk as the milestone
.PP
The disk image the tests already mount \- \f(CW.qemu/9front-root.qcow2\fP,
a full 9front installation with an hjfs root \- is the milestone, because
it already holds rio.  Booted from it, the Osprey kernel reaches a 9front
rc prompt as glenda, and \f(CW/bin/rio\fP is there.  So rio is not an
import after all: the userland, rio included, is on the disk.  What is
missing is only the way to run it.
.PP
Two concrete blockers were found by trying:
.IP \(bu 2
rio wants \f(CW/dev/draw\fP, and it is not there \- the kernel that boots
the disk carries no draw device, no frame-buffer driver, no mouse.  They
can be added to the config, but:
.IP \(bu 2
the draw device does not compile.  \f(CWos/osprey/port/devdraw.c\fP and the
\f(CWdraw.h\fP it includes are from different draw-protocol versions:
devdraw.c indexes \f(CWWarp\fP as a 3x3 array (\f(CWw[i][j]\fP), the header
defines it as a struct (\f(CWlong m[3][3]\fP).  That one is a line to fix,
but it is a symptom \- the draw code and the headers must be reconciled
to one protocol version, the same version the disk's rio speaks, before
any draw device links at all.
.PP
So the milestone has a clear shape and a real first task.  The draw-code
reconciliation is needed on either path \- a user-space devdraw is
derived from this same code \- so it is the honest next step, ahead of the
architectural choice of where the draw device runs.  After it: the frame
buffer (already exposed to user space here), a mouse and keyboard path,
and a devdraw that speaks the disk rio's protocol version \- in user
space, per the architecture.  rio then runs against it, off the disk.
.NH 1
Status of the graphics path
.PP
Built and shown: step 1 is done, and the input half with it.  The
microkernel exposes the firmware's frame buffer as a physical segment; a
user program maps it with segattach and draws \- colour bars first, then a
windowed desktop of two overlapping windows with borders, title bars and a
cursor \- entirely in user space, the kernel knowing nothing of what is
drawn.  And the two input devices are exposed the seL4 way as well: the
keyboard's interrupt and the mouse's are each a short kernel handler that
reads the one byte and hands it on into a ring in the container's mapped
data area, raising a semaphore; the user program's keyboard driver draws a
square per key and its mouse driver assembles the PS/2 packets, moves the
cursor and reads the buttons, all above the kernel.  Driven from the
outside, keys echo their scancodes and the cursor moves to where it is
aimed and marks a click there.  That is the exokernel model for the
display and its input, working and screenshotted.
.PP
Built since: the user-level draw service (os/osprey/cmd/draw, devdraw.c
behind a lib9p shim serving /dev/draw on the frame buffer, with mouse.c
and kbd.c serving /dev/mouse and /dev/kbd from the exposed interrupt
rings), and rio from the 9front disk running unmodified on it, on pc64
(doc/osprey-progress.ms, "Toward rio").
.PP
Not built: the 9front personality as a library with a name space and
exec, under which rio would run on the microkernel rather than on the
Plan 9 kernel; that is item 1 of "Next, in order" in
doc/osprey-progress.ms.  rio itself is still an import from the disk,
not a build of this tree.
.NH 1
Reconciled against the tree, 5 September 2026
.PP
The component-by-component sections above were written on 26 August and
several gaps they name have been closed since, in the run recorded under
"Making the demonstrations real" in
.I doc/osprey-progress.ms .
What that body still lists as missing but the tree now has, each checked
on a booted kernel:
.IP \(bu
Create and remove over 9P: the log store answers
.CW create ,
and refuses
.CW remove
because it is immutable, both over 9P
.CW osprey-check-p9pair ). (
.IP \(bu
A wire of its own for \[*p]p: the personality's \[*p]p is served on a
TCP wire (stack B over the ring, stack A over the cable), one connection
per kproc
.CW pipconn ), (
and it authenticates \- a session proves who it is with a ticket the
kernel signs and checks, and an open of a file that is somebody's is
refused to a session that is nobody's
.CW osprey-check-p9wire , (
.CW osprey-check-p9pair ).
.IP \(bu
A second machine: two kernels on a socket cable, each driving a
user-space virtio-net device, run tcp.c to tcp.c, carry a megabyte, and
migrate a process \- its pages, its descriptor table and its private
name space \- from one to the other
.CW osprey-check-p9wire , (
twenty criteria).  It is two amd64 machines under QEMU; a non-amd64 one
is the part that still wants a board.
.IP \(bu
Group migration: a process that shares its address space with a thread
crosses the wire with it, the thread made to share the arrived memory
and reaped by the arrived parent \- slide 15, whole, on one machine and
across a wire.
.IP \(bu
The authentication the replicated data and the caching file system
lacked: both now speak over the authenticated \[*p]p wire.
.IP \(bu
The caching file system is a file system: write-through commits a
version on the server, its directory lists what the cache holds, a
ninth file evicts the least recently used, and a stream is the lease's
heartbeat
.CW osprey-check-p9pair ). (
.IP \(bu
Configuration read, not derived: each machine reads
.CW /n/net
for its address, peer, role and ports, seeded from the MAC on a fresh
disk and read from then on.
.IP \(bu
The i8042 driver owns the whole controller: the one-time command-byte
enable is the driver's now, at CPL3, not the kernel's
.CW osprey-check-kbd ); (
the interrupt-path bug that had kept it in the kernel was run down with a
trap-return checksum and fifty-two reproduction boots and did not
reproduce.
.PP
What is genuinely left is what this analysis's own last section and the
progress doc's latency section name, and it is of two kinds.
.PP
Structural, and one of the two named here on 5 September is closed.  rio
runs unmodified on
.CW pc64 ,
the full personality, with a user-level draw service and user-level
mouse and keyboard drivers above the microkernel-exposed frame buffer
and interrupt rings; and it runs on the microkernel itself as well now,
on the
.CW p964
library personality \- which has exec, a name space, processes, a window
and input (phase 3.2 of the progress doc), and which serves the Plan 9
system calls of an ordinary binary that was not built for it at all
(phase 3.3): an unmodified a.out is laid at
.CW UTZERO ,
its traps are handed up to the personality in the address space it
shares with it, and its
.CW open ,
.CW read ,
.CW pipe ,
.CW bind ,
.CW rfork(RFNAMEG) ,
.CW brk ,
.CW notify ,
.CW alarm
and
.CW exits
are answered by the library.  A shell on that personality runs one as a
command.
.PP
The honest remainder of that is what a library cannot do for a program
in its own address space:
.CW rfork(RFPROC)
splits the caller's flow of control, which is not a thing a library can
do for its caller, so it is refused by name \- and that, not the name
space or the system calls, is why rio on
.CW p964
is rio relinked against the library rather than rio unmodified.  The
other structural item stands: the talk's 270-nanosecond round trip needs
a task that is not a Plan 9 process, which this kernel's is.
.PP
Board-bound: the raw-flash storage tier, a non-amd64 second machine, and
the hardware latency figure each want a board this tree has no Osprey
target for.  Everything else the paper and the talk describe is built
and checked.
