.TL
Diagnosing the raspi3b SD-under-preemption corruption
.PP
A plan to find and fix the one bug that keeps a scheduler tick - and so a
filesystem - off the Raspberry Pi 3B.  Everything else on the board (I2C,
SPI, GPIO, and a native-SD block device at
.CW /dev/sdM0/data )
works; the board ships cooperative only because turning the tick on
corrupts SD writes under load.  Read
.CW doc/inferno-driver-plan.ms
first for how the board got here.
.NH 1
The bug
.PP
With the generic-timer tick enabled, a heavy stream of block I/O through
the SDHOST driver fails intermittently: a write (or, less often, a read)
returns
.CW "file does not exist"
at a varying block.  It is not a benign short count - the transfer's
control flow is diverted to an error path.  Light use never reaches it;
a kfs ream (thousands of blocks) always does, which is why a filesystem
will not come up.
.NH 1
The reproducer
.PP
This is the whole reason the bug is now tractable: it reproduces in one
process, with no filesystem, in seconds, three times out of three.
.IP 1. 4
Re-enable the tick.  In
.CW os/inferno/raspi3b/clock.c ,
at the end of
.CW clockinit() ,
after
.CW timerie() ,
add
.CW "*(u32*)(0x40000000+0x40) = 1<<1;"
(the BCM2836 Core0 timer-control register, routing CNTPNSIRQ to the
core's IRQ).  The write needs a define; the register block is at
0x40000000.
.IP 2.
Add a stress loop to
.CW os/inferno/init/raspi3binit.b
after the block-device check: open
.CW /dev/sdM0/data ,
then in one process write two thousand distinct 512-byte blocks with
.CW pwrite
at ascending offsets and read them back with
.CW pread ,
reporting the first block whose write or read returns an error.  A
companion four-thousand-iteration
.CW open / close
loop on
.CW /dis/sh.dis
is the control: it must stay clean, proving the fault is SD-specific and
not the namespace layer.
.IP 3.
Boot
.CW "qemu-system-aarch64 -M raspi3b -m 1G -nographic -sd <img> -kernel iraspi3b" .
The write loop fails at a varying block; the open loop passes.
.NH 1
What is established
.PP
Each of these survived a falsification test; do not re-open them without
new evidence.
.IP \(bu 4
.I SD-specific.
The four-thousand-open namespace loop is clean under the same tick, so it
is not a generic vector or scheduler fault that would hit any syscall.
.IP \(bu
.I Single-process.
No file server, no mount, no second proc is needed; the stress loop
reproduces it alone.  This retired the earlier multi-proc-concurrency and
mount/Styx theories (the
.CW "T110 R107"
mount-walk message that looked like a desync prints on sifive_u too, just
before its
.CW SD-FS-OK ).
.IP \(bu
.I "Not a clock callee."
A no-op
.CW clockintr
(re-arm the timer and bump the tick count, nothing else) still corrupts,
so it is the exception entry-and-return around the transfer, not
.CW checkalarms ,
.CW timercheck ,
.CW kproftick ,
or a
.CW clock0link
callback.
.IP \(bu
.I "Not the partition."
.CW sdinitpart()
runs exactly once (instrumented), so the partition and its version are
stable; the corruption is not a devsd teardown.
.IP \(bu
.I "Not a QEMU-model timeout."
.CW hw/sd/bcm2835_sdhost.c
holds only a timeout
.I register ,
no active QEMU timer, and
.CW hw/sd/sd.c 's
only timer is the ACMD41 power-up delay, dead by transfer time.  So the
model does not fault the transfer while the guest is off in its handler;
the corruption is guest-side.
.IP \(bu
.I "Cured by masking, but not usably."
.CW splhi()
around the per-block transfer makes the single-proc stress pass, so a
timer IRQ taken mid-transfer is the trigger - but it deadlocks the
multi-proc file-server path in a lock loop, so it is a diagnostic, not a
fix.
.IP \(bu
.I "Vector code is shared with a board that works."
.CW vectrap
and its runtime-built stub in
.CW trap.c 's
.CW vectorbuild()
are byte-identical (verified by diff) to virtarm64's, which is stable
under its own GICv2 timer.  Either virtarm64 has the same latent bug and
has never exercised it, or something outside the vector text differs.
.NH 1
The experiments, in order
.PP
The first one splits the search space in half and should be run before
any single-stepping.
.IP "E1 (pivotal)." 4
.I "Does virtarm64 fail the same stress?"
Give virtarm64 a writable block device it can drive under its working
timer (a virtio-blk disk, or whatever devsd/#S storage it can mount) and
run the identical two-thousand-block write/read loop.
.I "If it fails" ,
the bug is in shared arm64 kernel code - the vector, the trap tail, or a
common syscall path - exercised for the first time by high-volume I/O
under preemption, and virtarm64 becomes a second reproducer on simpler
hardware.
.I "If it passes" ,
the bug is raspi3b-specific and the suspects narrow to what differs: the
BCM2836 timer routing itself, the EL3-to-EL1 boot drop leaving some
system-register or stack-alignment state the fault path assumes, or the
SDHOST driver's exact register cadence.
.IP "E2."
.I "Find where the error is raised."
Under the failing run, mark each of devsd's
.CW error(Enonexist)
sites (and the generic
.CW syswrite / walk
path) uniquely, or print the caller PC and
.CW up->errstr
at the moment the
.CW pwrite
returns the error.  Knowing which site fires says whether the corruption
lands in the Chan/qid resolution, the partition bounds, or an errstr that
is stale from an earlier benign walk - three different bugs.
.IP "E3."
.I "Single-step the fault."
Boot under the QEMU gdbstub
.CW ( "-s -S" )
with lldb (the pc64 heisenbug work,
.CW doc/inferno-ports.ms ,
has the recipe).  Put a hardware watchpoint on the failing proc's Chan
pointer and on the stress buffer, breakpoint the timer vector slot, and
let the stress run until a watchpoint trips inside or just after an IRQ.
That shows the exact word that changes across the exception.
.IP "E4."
.I "Test the FP/SIMD gap."
.CW vectrap
saves R0-R30, SP, PC and SPSR but no V (FP/SIMD) registers.  The kernel's
.CW memmove
on this target may use them, and devsd copies the I/O buffer.  Add
V0-V31 save/restore to
.CW vectrap
and re-run the stress.  A caveat that makes this lower priority:
.CW "file does not exist"
is a control-flow error, and clobbered vector state corrupts
.I data ,
not control - so a pass here would be surprising and would itself need
explaining.
.IP "E5."
.I "Rule out stack overflow."
A timer IRQ taken deep in a syscall stacks a Ureg frame plus
.CW trap() 's
frame on the same kernel stack.  Double
.CW KSTACK
and re-run; if the fault vanishes, the frame was overrunning the stack
into an adjacent structure.  Cheap, and it removes a whole class.
.IP "E6."
.I "Isolate the pure vector."
Make
.CW trap()
return immediately for the timer IRQ - re-arm and
.CW ERET ,
no C work at all beyond the arm.  Still corrupting means the fault is in
.CW vectrap 's
save/restore or the mere act of taking the exception, and E3's
watchpoint is then aimed squarely at the entry/exit.
.NH 1
Likely fixes, by outcome
.PP
If E4 wins, the fix is the V-register save in
.CW vectrap
(and the same gap should be closed on every arm64 board, virtarm64
included).  If E5 wins, enlarge
.CW KSTACK
or move the IRQ handler to its own stack.  If E3 pins a specific
clobbered register or a stale
.CW up->errstr ,
the fix is local to the vector or the error path.  If E1 shows the bug is
raspi3b-only and E3 traces it no further than the timer path, the
fallback is to make the SDHOST transfer atomic against the tick without
the lock-loop deadlock
.CW splhi()
caused under a file server.  Note the deadlock is not the obvious
ordering slip: bio already takes its
.CW QLock
before
.CW splhi() ,
so nothing sleeps with interrupts off in the driver itself; the lock
loop is some other spinlock reached while a proc holds the transfer with
IRQs disabled, and finding which (its address is printed in the loop
message) is a sub-task of its own.  Candidates once it is understood: a
much shorter
.CW splhi
window around only the register burst that actually needs it rather than
the whole multi-block
.CW bio ,
or a per-controller
.CW Lock
(spin, never sleeps) in place of the QLock so no sleep can ever occur
inside the disabled region.  Any of these ships a correct board with the
tick on even if the deeper cause stays open.
.NH 1
Success test
.PP
The bug is fixed when, with the tick enabled, the two-thousand-block
write/read stress passes five of five, and a kfs reams, mounts and
round-trips a file on
.CW /dev/sdM0/data
(the
.CW SD-FS-OK
that already works on sifive_u).  Then re-land the timer routing and the
kfs mount, and raspi3b joins sifive_u as a board with a filesystem.
