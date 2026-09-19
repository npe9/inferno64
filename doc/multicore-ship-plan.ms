.TL
What stands between this branch and shipping
.AU
.NH 1
The state this plan starts from
.PP
Read this first, and
.CW doc/multicore-plan.ms
for how any of it was arrived at.  The short form:
.IP \(bu
The parallel VM is worth 4x on four real processors for the chantest
workload, measured on Compute Engine, and the split is roughly 1.7x
from removing
.CW vmlock
itself and 2.2x from the other three processors doing work.  With the
lock in place four processors do what one does.
.IP \(bu
.CW parallelvm
still defaults to 0, and turning it on is what shipping would mean.
.IP \(bu
pc64 uses about 462 MiB of a 16 GiB machine, because
.CW mapkzero()
stops at 1 GiB and
.CW pmap()
maps 4 KiB pages only.  Correct, and unacceptable in a product.
.IP \(bu
.CW os/inferno/port/dis.c
carries 34 blocks marked "MULTICORE INSTRUMENTATION - temporary" and 94
prints, three of them behind
.CW *disdump .
.CW stalldump()
and
.CW soakline()
are wired into the clock.
.CW dis/init
runs a workload marked "Revert before finishing".
.PP
So there are two separable things here: a set of correctness fixes that
are ready, and a feature that is not.  They should not travel together.
.NH 1
Phase A \- the fixes that are ready, as their own series
.PP
None of these depend on
.CW parallelvm
and each is a strict improvement:
.IP
.nf
a0bc469a  Mach.splpc is eight bytes (all eight 64-bit boards)
          raspi3b DISCTXREG, screen.h blankscreen declarations
5fb16e57  nprop read-and-clear; aclr() for five architectures
          mkfile-os-aarch64 gets -DDISCTXREG
5f17fdd2  count the gclocks gcunwind() gave back, not gchalt
660c116f  take only the memory the kernel has mapped
.fi
.PP
.B Acceptance:
all fourteen boards build; pc64, virtarm64 and the five riscv64 boards
reach a first Dis quantum; no board regresses at
.CW parallelvm=0 ,
which is the default the series must not disturb.
.PP
.B "Not done here, deliberately:"
how they reach
.CW main
is a branch decision, and this branch is not the place to make it
unilaterally.
.NH 1
Phase B \- a big machine's memory, which blocks everything else
.PP
.B "B1. pmap() learns 2 MiB pages."
.CW os/inferno/pc64/mmu.c 's
.CW pmap()
says "reducing complexity, use 4096 byte pages all through".  Mapping
16 GiB that way is four million PTEs and 32 MiB of page tables from the
early allocator.  With
.CW PTESIZE
at level 1 it is eight thousand entries.  Use a 2 MiB entry when the
physical address, the virtual address and the remaining size are all 2
MiB aligned, and fall back to 4 KiB at the edges.
.PP
.B "B2. mapkzero() stops refusing RAM above 1 GiB."
The limit is arbitrary by its own comment and exists because of B1.
.PP
.B "B3. Keep the meminit clamp."
.CW 660c116f
makes
.CW meminit()
take only mapped memory.  With B1 and B2 it should find everything
mapped and clamp nothing; it stays as the thing that makes the two
numbers unable to disagree again.
.PP
.B Acceptance:
.CW "qemu -m 16384"
through the UEFI path reports
.CW conf.npage
within a few per cent of the machine's RAM, skips no bank, and reaches a
Dis quantum; the same image on an
.CW n2-standard-4
reports about 16 GiB and boots to a shell.  The reproduction for the
original fault is
.CW "qemu -m 16384" ,
not the 512 MiB guest every earlier test used.
.NH 1
Phase C \- one switch for the instrumentation
.PP
.B "C1."
Every temporary print behind one flag.
.CW *disdump
already exists and gates three of ninety-four.
.PP
.B "C2."
The per-quantum work goes when the flag is off, not just the printing:
the run-queue watermark still walks every context's
.CW nlocal
on every quantum.
.PP
.B "C3."
.CW stalldump()
and
.CW soakline()
come out of
.CW portclock.c
and
.CW virtarm64/clock.c
unless asked for.
.PP
.B "C4."
.CW dis/init
loses the workload from its default path; the
.CW *soak
block stays, because that is what the measurements drive.
.PP
.B Acceptance:
a default boot prints no line containing "stall:", "soak:", "runq:",
"nvm:" or "audit:"; with
.CW *disdump=1
it prints them all.  And the number that matters for a product, which
nobody has yet: the throughput difference between the flag off and on,
measured the way Phase D measures everything else.
.NH 1
Phase D \- answered twice, and the second answer is different
.PP
Full numbers and the instrument fixes are in
.CW doc/multicore-plan.ms .
.PP
.B "First answer: no."
Twenty Compute Engine instances, four Xeons each, UEFI disk boot.  Three
of four channel-workload instances panicked at four processors with
.CW "parallelvm = 1"
\(em two page faults inside
.CW dis
processes and one
.CW "checkb 4 qconsume" ,
memory corruption.  No QEMU batch on this branch had ever produced any
of these at any width.
.PP
.B "The cause, found and fixed."
.CW addgrp()
and
.CW delgrp()
maintained the process-group list with no lock, because the global
.CW vmlock
used to mean one executor at a time.  Details in the plan; the
instrument that named it is
.CW *progquar=N .
.PP
.B "Second answer: yes on amd64, not yet on arm64."
Nine instances with the fix, 84,000 guest ticks:
.IP
.nf
                        panics   Dis quanta per tick
lock on  (parallelvm=0)   0/3    42.6  43.0  43.3
lock off (parallelvm=1)   0/6    86.3  110.1  110.2  111.5
.fi
.PP
Six of six clean and 2.5x at the median, against 1.4x before \(em which
was being dragged down by the runs on their way to dying.
.PP
.B "What is still missing before the default can be flipped."
Only one thing, and it is not the VM:
.IP \(bu
arm64.  Five
.CW t2a-standard-4
instances boot, bring up four processors and run the parallel VM
without panicking, and then four of the five stop producing console
output.  It is a board-level fault, not the VM \(em one of the two
lock-on controls stopped too \(em but until it is fixed there is no
arm64 throughput measurement.
.PP
.B "The second workload is done."
Module loading re-measured on the fixed kernel over six instances and
108,000 ticks: 3.2, 3.2, 3.2 against 11.0, 12.3, 12.6, which is 3.7x.
That makes twelve
.CW parallelvm=1
instances across two workloads with no panic on any of them.
.PP
.B "Two instrument lessons that the plan should carry forward."
.CW CHANTEST-OK
is a serial-console print and measures the console: four instances
returned exactly 645, and so did the one-processor controls.  Use Dis
quanta per tick.  And do not divide work by Dis quanta to remove host
speed \(em a quantum is a slice of Dis work, so the ratio is a constant
of the program.  Proved: loading a host cut quanta per tick from 35.9 to
19.5 while the ratio moved one per cent.
.NH 1
Phase E \- the open correctness items
.IP \(bu
.B "The parallelvm memory corruption," above.  This is now the first
item, not a Phase D footnote.
.IP \(bu
The group-list walks in
.CW killgrp() ,
.CW printgrp()
and
.CW propex() .
.B Closed:
.CW propex()
snapshots pids under the lock and acts outside it, the others take the
lock for their reads.
.IP \(bu
Nested virtualisation hangs at
.CW schedinit
with the clock running and no Dis quantum ever executed, on both boot
paths, at 1, 2 and 4 vCPUs but not 8.  Not a platform this kernel has
to run on; recorded, not chased.
.IP \(bu
.CW _allocb
carries a comment recording
.CW msize()
returning two different values for the same block on a single-vCPU
harness.  That is the allocator disagreeing with itself, and it is now
a suspect in the corruption above rather than a curiosity.
.PP
.B "Two items are answered rather than open."
.CW stoptheworld()
waiting only on
.CW inxec
is correct, not a shortcut: what the stopped world exists for is
.CW rootset()
reading another context's live register file through
.CW progreg() ,
and
.CW inxec
is exactly "this context's register file is live".  A context outside
.CW xec
can mutate the heap, which the write barrier handles by design, and can
call
.CW addrun() ,
which cannot cost a root because roots come from
.CW isched.head
and never from the run queues.
.PP
And the one-in-ten-thousand audit disagreement is that same
.CW addrun()
window \(em
.CW "p->state = Pready"
is set before the Prog is linked \(em seen by an audit while a context
that is not
.CW inxec
is inside it.  The persistence check that asks whether the same pid is
still like that at the next audit has never fired.  The window is in
the audit, not in the kernel.
.PP
.B "Closed since this plan was written:"
.CW nucleof303
links and builds; the process-group race is found and fixed; and
.CW gcunlock()
no longer gives
.CW rungc() 's
lost-increment check a false positive of its own.
.NH 1
How to run any of this
.PP
.B "Boards."
.CW "for b in pc64 virtarm64 raspi3b virt virts virt32 virt32s shakti sifiveu spike armv7 mangopi mps2 teensy41 nucleof303; do (cd os/inferno/$b && mk install); done"
\(em check the exit status, not the output: the words "not declared"
and "undefined external" do not contain "rror".
.PP
.B "mk gotchas that have each cost a cycle."
It does not notice a
.CW CFLAGS
change (remove the objects), and it compares the archive against the
sources rather than the objects (remove
.CW Inferno/*/lib/*.a
too).  Several host tools are checked-in binaries \(em
.CW tools/aout2efi ,
.CW tools/aout2elf ,
.CW MacOSX/arm64/bin/7a ,
.CW 7l
\(em and are rebuilt only when the object is older than the source.
.PP
.B "The UEFI disk and Compute Engine."
.IP
.nf
INFERNO_KERNEL=$PWD/os/inferno/pc64/ipc64 \\
INFERNO_INI='*soak=1
*parallelvm=1' \\
INFERNO_GCE_TAR=/tmp/gce.tar.gz \\
	sh scripts/mkinferno-efi-disk.sh /tmp/disk.raw 1024
gcloud storage cp /tmp/gce.tar.gz gs://BUCKET/
gcloud compute images create NAME --source-uri=gs://BUCKET/gce.tar.gz \\
	--guest-os-features=UEFI_COMPATIBLE
gcloud compute instances create NAME --zone=us-central1-a \\
	--machine-type=n2-standard-4 --image=NAME --boot-disk-size=10GB
gcloud compute instances get-serial-port-output NAME --zone=us-central1-a --port=1
.fi
.PP
Locally the same disk boots under OVMF with
.CW .qemu/edk2-code.fd
and
.CW edk2-vars.fd
copied from
.CW /opt/homebrew/share/qemu .
Delete instances, images and the bucket afterwards; an idle instance is
the only way this costs anything.
.PP
.B "And the rule this branch keeps relearning."
Every strong number produced today without a control was measuring
something other than what it appeared to: the run-queue check, the
stopped-world audit, "leaks seen 63", the 7 per cent, the first 4x.
Build the control first.
.NH 1
Phase B, as it landed \(em and what it uncovered
.PP
.B "The 16 GiB fault was a 32-bit size, not the mapping."
.CW Pool.chunk
in
.CW os/inferno/port/alloc.c
was an
.CW int .
.CW poolsize()
sets it to what is left of the pool \(em 3.4 GiB on a 16 GiB machine \(em
and
.CW poolalloc()
takes it as a
.CW uintptr :
negative as an int, sign-extended on the way in, and the size
arithmetic wrapped.  The block was built at the address
.CW xalloc()
correctly returned, with a nonsense length, and the first write through
its tail landed in the PCI hole below 4 GiB.  Printing the sizes named
it \(em
.CW "size -875209856"
\(em after two rounds of treating it as a mapping bug.
.PP
The mapping work stands anyway:
.CW pmap()
uses a 2 MiB entry where the addresses and the remaining size allow one
and the page-directory entry is empty,
.CW mapkzero()
no longer refuses RAM above 1 GiB, and
.CW meminit()
maps each bank before taking it.
.PP
.B Acceptance, met:
.CW "qemu -m 16384"
reports
.CW "conf.npage 4179631" ,
skips no bank, allocates and frees the 3.4 GiB chunk and reaches Dis on
two processors.  On an
.CW n2-standard-4 :
.CW "conf.npage 4177338" ,
the same chunk allocated and freed, four Xeons, a Dis quantum, no
panic.  It was 462 MiB of that machine before.
.NH 2
New, and the first item of Phase E
.PP
.B "The pool overlap checker fires on a large machine, for the first time."
Its comment says it had never fired.  With the whole machine in use it
reports, from the clock:
.IP
.nf
pooloverlap(clock): image [0x100000010,0x200007113) magic 0x2103
	overlaps image [0x100006103,0x100006103) magic 0x0
.fi
.PP
0x100000010 is exactly what
.CW xalloc()
returned for the 3.4 GiB chunk, so the chain head points where it
should \(em and the magic there reads 0x2103 rather than
.CW MAGIC_E ,
with the second entry unaligned, zero-length and magic 0.  A chain is
leaders only and
.CW clink / csize
share a union with the block's own data, so this is either a leader
that has been overwritten or a chain that has walked into data.  The
checker names the magic now, which is how this much is known.
.PP
It does not panic and the kernel reaches a shell and runs Dis, so it is
a corruption signal rather than a failure, and it is only visible on a
machine with memory above 4 GiB \(em which is every cloud machine.  It
is the first thing to chase, ahead of the rest of Phase E.
