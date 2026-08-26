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
The three kernels this is measured across
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
user-space library, reaching a file server over the ring by an open/read
protocol (6 checks).  This is the library-operating-system shape, in
miniature.
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
Missing: the paper's
.I "segments shared at different addresses"
and, above all,
.I "processes that share an address space migrating as a group."
The plan itself names group migration as a thing a Plan 9 kernel cannot
reach.  It is unbuilt and, in this kernel's shape, unreachable.
.NH 2
Interrupts and the driver-as-a-task \- PARTIAL
.PP
Built: a uart driven by a task that selects on its interrupt's semaphore,
tested on pc64; the clock's interrupt giving a container a semaphore,
shown in the microkernel.  The shape the talk gives a driver \- a task on
its message queue, its interrupt's semaphore, and its output queue \- is
present.
.PP
Missing: cons, uart and rtc still leave their register access in the
kernel rather than in a userspace driver task; the microkernel keeps six
devices where seL4 keeps none.  The driver-as-a-task exists but the
kernel has not been emptied of drivers.
.NH 2
Scheduling \- PARTIAL
.PP
Built: an EDF scheduler with reservations and best-effort time accounted
apart, tested.
.PP
Missing: the reservation is not yet a parameter a storage or driver task
sets at start; the storage-tradespace plan (a compaction task with a
per-board reservation) is unbuilt \- there is no log-structured flash
service and no block-device file-system service.
.NH 2
Files over \[*p]p \- PARTIAL
.PP
Built: \[*p]p, spoken over a file and on a wire, with a session that
outlives its connection and attributes carried as strings; the
delegation path by which a container's opens and reads are answered by a
server, not the kernel.
.PP
Missing: the library OS's own file protocol is a two-file held name
space, not \[*p]p to a real file system; there is no user-level file
system service (block-device or log-structured) behind it.
.NH 2
Library OS and buddy OS \- PARTIAL
.PP
Built: a library-OS program on the microkernel whose personality is a
user-space library, opening and reading files over the ring from a server
task; the buddy relationship on pc64, where what the policy layer cannot
answer the Plan 9 kernel around it does.
.PP
Missing, and this is the largest gap: the library OS is minimal.  It has
a couple of files, no name space (no bind or mount), no exec, and a
syscall interface of four calls.  A real 9front personality \- the one
that could run rio \- is a different order of thing, described in its own
section below.
.NH 2
Checkpoint and migration \- PARTIAL
.PP
Built: serializable container state, checkpoint and restore, tested on
pc64.
.PP
Missing: migration between hosts is untested here, and group migration is
unreachable (see address spaces).
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
present, as C source ((CWlibdraw/P, (CWlibmemdraw/P) and prebuilt
in (CW9front/amd64/libP.  So the pixel-pushing a draw service needs is
in hand.
.IP \(bu 2
rio itself, and the 9front graphics commands, are NOT present as source
in this tree, and there is no 9front (CWsys/srcP.  This is an Inferno
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
Status of the graphics path
.PP
Built and shown: step 1 is done and then some.  The microkernel exposes
the firmware's frame buffer as a physical segment; a user program maps it
with segattach and draws \- colour bars first, then a windowed desktop of
two overlapping windows with borders, title bars and a cursor \- entirely
in user space, the kernel knowing nothing of what is drawn.  That is the
exokernel model for the display, working and screenshotted.
.PP
Not built: a user-level draw service (the (CW/dev/drawP role) that
multiplexes the display among clients using libmemdraw, which is what rio
and its clients would talk to; input driver tasks on the mouse and
keyboard interrupt semaphores; and the 9front personality as a library
with exec, under which rio would run.  And rio itself is an import this
tree does not contain.  The distance to a real rio is therefore a draw
service and an input path here, and a userland import from 9front there.
