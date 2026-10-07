.TL
The raspi3b SD-under-preemption corruption: a vectrap argument-clobber
.PP
This was the one bug that kept a scheduler tick - and so a filesystem -
off the Raspberry Pi 3B.  Everything else on the board (I2C, SPI, GPIO,
and a native-SD block device at
.CW /dev/sdM0/data )
worked; the board shipped cooperative only because turning the tick on
corrupted SD writes under load.  It is now
.B fixed
(commit
.CW 2cdae759 )
and the tick is enabled.  Read
.CW doc/inferno-driver-plan.ms
first for how the board got here.
.NH 1
Resolution
.PP
The bug was not in the SD driver, not in the atomics, and not in QEMU.
It was in
.CW vectrap
(l.s).  The AArch64 interrupt entry builds the
.CW Ureg
frame on the interrupted stack at
.CW SP
and then calls
.CW trap(&ureg) .
Plan 9's arm64 calling convention gives a callee a stack home for its
first argument at caller-
.CW SP+8 ,
and with
.CW SP
sitting on the Ureg base that slot is exactly
.CW UR_R1 .
So trap()'s prologue, spilling its
.CW Ureg*
argument to its home, overwrote the saved
.CW R1
on every single interrupt.  It hid for the life of the port because
.CW R1
is almost always dead at an interrupt - except when a timer IRQ lands in
.CW irestore 's
fixed-size
.CW "R = p->R"
register-block copy, where
.CW R1
is the live loop counter.  Clobbering it turned a ten-iteration copy into
an unbounded one that walked memory upward from the global
.CW R :
silent corruption with the MMU off (the
.CW "file does not exist"
heisenbug), a read-only-page-table fault with it on.
.PP
The fix is four instructions: reserve sixteen bytes of argument-home
scratch below the Ureg before the call (
.CW "SUB $16, SP" ;
pass
.CW "&Ureg = SP+16" ;
.CW "ADD $16, SP"
after), in both raspi3b and virtarm64
.CW l.s .
Verified against an instrumented qemu 10.1.3: the saved
.CW x1
slot was overwritten with the frame base on 600 of 600 interrupts before
the fix and 0 after; the tick-on SD write+readback stress that used to
fault about one run in eight now passes 24 of 24 with a no-op clock
handler and 24 of 24 with the real preemptive
.CW clockintr .
QEMU is correct; no emulator patch was needed.
.PP
Two things from the hunt were real and are kept, though neither was the
root cause.  The identity MMU (raspi3b/mmu.c) gives RAM Normal write-back
inner-shareable, which is what makes the
.CW "LDXRW / STXRW"
spinlocks sound (exclusives are unpredictable on the Device memory an
MMU-off board provides), and it maps the page tables read-only - the
tripwire that turned the otherwise-silent wild store into a catchable
fault and let the bug be localised at all.  The
.CW CLREX
on exception entry is architecturally harmless and stays.  The rest of
this document is the investigation, kept as evidence of the false trails
(atomics, a QEMU residual, a multi-kproc race) the symptoms led through
before the argument-home collision was found.
.NH 1
The bug
.PP
With the generic-timer tick enabled, a heavy stream of block I/O through
the SDHOST driver fails intermittently.  What the caller sees is a
.CW pwrite
that returns 0 with a stale
.CW "file does not exist"
errstr, but the underlying event (established below) is narrower: a timer
IRQ taken during one block's data transfer leaves that write unfinished,
and the next block's command then fails.  Light use never reaches it; a
kfs ream (thousands of blocks) always does, which is why a filesystem
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
.CW "open / close"
loop on
.CW /dis/sh.dis
is the control: it must stay clean, proving the fault is SD-specific and
not the namespace layer.
.IP 3.
Boot
.CW "qemu-system-aarch64 -M raspi3b -m 1G -nographic -sd <img> -kernel iraspi3b" .
The write loop fails at a varying block; the open loop passes.
.NH 1
The plan: isolate, test, fix
.PP
The exploratory experiments below (E1-E8) are the record of how the bug
was cornered; they are kept as evidence, but the mechanism is now known
well enough that the work from here is a short, ordered line, not a fan of
guesses.  The bug is a register corruption in the SDHOST FIFO loop when a
timer IRQ is taken mid-block: a store's base register (or the loop's data
pointer) comes back wrong across the exception, so the store either drops
its data (MMU off) or lands on a stray address (MMU on).  The one probe
that survives is the MMU-on Data Abort, because it needs no guest-side
instrumentation - and every guest-side probe masks the fault.
.NH 2
Step 1: isolate - name the corrupted register
.PP
Turn the diagnostics on together and let the wild store fault at its own
instruction, with the machine state still intact to read.
.IP 1. 4
In
.CW mmu.c
set
.CW Mmuon
to 1, and add the timer routing (step 1 of the reproducer).  Rebuild.
.IP 2.
Narrow the identity map so a stray store is caught rather than absorbed.
As it stands the map covers all of 0-1GB, so a wild store into RAM just
writes RAM and only faults later, on an innocent access, once the page
table itself is hit - which is why the current abort spins in prefetch
faults (the page table it needs is already gone).  Instead map only what
the kernel touches - the used RAM, the peripheral window, the BCM2836
block - and leave the rest of the address space unmapped, and map the two
page-table pages themselves
.I read-only .
Now a store to a corrupted address faults
.I "at the store" ,
translation- or permission-faulting before it damages anything, and the
page table and stack survive for the handler to use.
.IP 3.
In
.CW trap() 's
.CW default
(non-IRQ) arm, before the
.CW panic ,
.CW iprint
the whole saved frame - every
.CW ur->rN ,
plus
.CW ur->pc
.CW ( ELR),
.CW ur->tval
.CW ( FAR)
and
.CW ur->cause
.CW ( ESR)
- and also
.CW iprint
the faulting instruction word,
.CW "*(u32*)ur->pc" .
The console UART is Device-mapped and reachable even with most of RAM
unmapped, so this prints where the old dump could not.
.IP 4.
Run the write stress.  On the abort, decode the store at
.CW ELR :
its base register field names the corrupted register, and
.CW FAR
is the value it held.  Compare against what the loop intended (the SDHOST
base, or the block pointer).  One clean catch is the whole answer.
.NH 2
Step 2: test - locate the corruption's source
.PP
With the register named, decide where it goes wrong, and prove it.
.IP \(bu 4
If it is a callee-saved register (R19-R28) that
.CW vectrap
is meant to preserve, the save/restore is suspect despite matching
virtarm64's text byte for byte - so look for what the tight loop does
that no other code on any board does with that register, and confirm by
rewriting the loop to avoid it (does the fault move or vanish?).
.IP \(bu
If it is caller-saved, it is the compiler's allocation for the loop and
the exception's handling of it - narrow by simplifying the loop until the
fault changes.
.IP \(bu
Either way, check whether the fault only fires when the interrupted
.CW ELR
(logged for the IRQ just before the abort, under
.CW "-d int" )
sits inside the FIFO loop - that ties the corruption to the loop, not to
devsd or the syscall path.
.IP \(bu
The decisive fork: is it the guest or QEMU?  If the named register is one
.CW vectrap
demonstrably round-trips correctly (add a self-check on the exception
path that is off the hot loop), the drop is in QEMU's TCG taking the IRQ
mid-block - reproduce it on a newer QEMU and, if it persists, reduce it to
a minimal test case and file it, because then no guest change is the real
fix.
.NH 2
Step 3: fix, then verify
.PP
The fix follows the source.  A
.CW vectrap
bug is a local correction to the save/restore.  A compiler/allocation
interaction is dodged by making the loop store through a base the
corruption cannot reach - recomputed from an immediate each iteration, or
pinned to a register the exception path provably preserves.  A QEMU drop
is worked around the same guest-side way until the emulator is fixed, and
the SDEDM detect-and-retry already in the plan is the fallback that ships a
correct board even if the cause stays in QEMU.
.PP
Declare it fixed only when, with the MMU and the tick both on, the
two-thousand-block write/read verifying stress passes five of five with
every byte correct, and a kfs reams, mounts and round-trips a file on
.CW /dev/sdM0/data .
Then turn to the second, separate fault the retry uncovered - the
mount-phase hang - and first ask whether it is the same corruption on the
read path (extend the fix and re-test) or a distinct scheduling stall in
the pipe mount (a different hunt).  Only after both are green do the timer
routing, the MMU, and the kfs mount land as defaults.
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
.I "A short write, not a lost file (E2 is done)."
The
.CW "file does not exist"
is a red herring: the
.CW pwrite
returns 0, not -1, so it is a short count and the message is a stale
.CW errstr
from an earlier benign walk.  Traced at
.CW sdbio ,
the failing write arrives with a sane qid, version and sector count, so
nothing in the Chan or partition is corrupted.  What is set is the
driver's own
.CW Failflag :
the SDHOST
.I write
transfer leaves the card with data-count non-zero (the block is not fully
clocked out), so the card stays in receiving-data state and the
.I next
block's CMD24 fails at send-command time.  The fault is one interrupted
transfer poisoning the following command.
.IP \(bu
.I "Masks under any observation."
A guest
.CW print
in the loop, a single extra register read after the write, and QEMU's own
.CW bcm2835_sdhost
trace events each make the two-thousand-block stress pass.  So it is not
observable by adding instrumentation; it needs a tool that does not
perturb guest timing at all, or a fix that does not depend on seeing the
failing moment.
.IP \(bu
.I "splhi helps but is not a clean fix."
.CW splhi()
does mask the timer (it sets
.CW DAIF.I ,
and the routed timer is an IRQ, not an FIQ), and wrapping the per-block
transfer in it passes the stress two or three times in three - but not
reliably, which is odd, since a masked IRQ should make the transfer
atomic.  Either a rarer non-IRQ path remains or the corruption is a TCG
artifact partly independent of the guest mask.  The full-
.CW bio
.CW splhi
deadlocks the file server, as noted below.
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
.IP "E2 (done)."
.I "Where the error is raised."
Already answered: it is not raised at all in the sense first assumed.
The
.CW pwrite
returns a short count of 0 and the errstr is stale; the driver's
.CW Failflag
on the next block's CMD24 is the real signal, and one interrupted
transfer leaving data-count non-zero is the cause.  This is why the
remaining experiments target the transfer, not the namespace.
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
.IP "E7 (done - and it pinned the mechanism)."
.I "Turn the MMU on."
This board ran with the MMU off, so every access took Device-nGnRnE
ordering.  The MMU is now built (gated off) in
.CW mmu.c :
a flat identity map, RAM Normal write-back cacheable, the peripheral and
BCM2836 windows Device.  Turning it on with the tick enabled did not fix
the corruption - it reshaped it decisively.  Three of five stress runs
pass with every block correct; the other two fault with a level-1
translation abort at a
.I RAM
address and then spin in prefetch aborts.  QEMU models no caches, so this
is not coherency - it is a
.I "wild store" :
the corruption is corrupting the base register of a store so the store
lands on the page table (which is why the whole map dies and every later
fetch aborts), where the MMU-off board had only ever shown the milder
symptom of a lost SDDATA write.  So the bug is not a lost write, it is a
.I "register corruption"
in the tight FIFO loop under the interrupt - a single register (a store
base, or the loop's data pointer) coming back wrong across the exception,
even though
.CW vectrap
saves and restores all of R0-R30 and is byte-identical to virtarm64's.
Crucially, the MMU-on abort survives QEMU's own
.CW "-d int"
logging where every guest-side probe masked the fault, so it is the first
handle on the failing moment.
.IP "E8 (the next move)."
.I "Catch the wild store."
With
.CW Mmuon
set and the tick on, make the synchronous-exception path stop dead on the
first Data Abort - before the page table is walked again, so it does not
spin in prefetch aborts - and dump the Ureg it saved plus
.CW ELR ,
.CW FAR
and
.CW ESR .
The faulting PC lands you on the exact store instruction, and comparing
its base register in the Ureg against what the loop intended shows which
register was corrupted and to what.  That is the whole answer: once the
register is named, either
.CW vectrap
mishandles it in some path the tight loop alone reaches, or QEMU's TCG
drops it taking the IRQ mid-block - and the second is worth a check
against a newer QEMU or a bug report, since nothing in the guest can then
fix it.
.NH 1
Likely fixes, by outcome
.PP
The most promising practical fix does not need the mechanism at all,
because E2 turned the bug into something the driver can check for and
undo.  A poisoned write leaves the card's data-count non-zero, which the
SDHOST
.CW SDEDM
register exposes as an FSM state other than data-mode.  So
.CW bio()
can, after each block, read
.CW SDEDM
and - if the transfer did not finish - reset the controller and re-issue
the block, a bounded number of times.  This is protocol-level recovery,
independent of why the interrupt corrupted the transfer, and it does not
disable interrupts, so it cannot reintroduce the file-server deadlock.
The one caution is that the extra
.CW SDEDM
read is itself enough to perturb the timing and hide the failure in the
stress, so the retry must be written to act on the FSM state it reads,
not to rely on the read having "fixed" anything; verify it against a card
image, not just against the stress passing.
.PP
This was built and measured, and it half-works, which is the useful part.
A
.CW bio()
that after each write reads
.CW SDEDM ,
drains any stuck data-count, and re-issues the block up to eight times
passes a byte-for-byte verifying stress with correct data - so the
recovery is real, not a timing accident.  But two things stop it being
the answer.  It is slow: the corruption is frequent enough that many
blocks need draining and re-issuing, so a run that used to take seconds
takes a minute or more, and a kfs ream crawls.  And it exposes that the
write corruption was not the only bug.  With the retry in, a kfs
.I reams
to completion and reaches
.CW "initializing minimal user table" -
the block it always died on before - and then hangs in the mount and
file-create phase, which never finishes even given four minutes.  So
there are two faults, now cleanly separated: the transfer corruption
(recoverable, but the recovery is too dear to ship), and a second hang in
the multi-process pipe-mount path that only the first bug had been hiding.
Both want the mechanism, not a workaround.
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
