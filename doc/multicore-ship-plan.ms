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
Phase D \- the evidence that would justify flipping the default
.PP
What exists is one workload, one architecture, one boot per arm.  What
is needed before
.CW "parallelvm = 1"
is a default:
.IP \(bu
Three boots an arm at
.CW "-smp 4" ,
instrumentation off, plus the
.CW *ncpu=1
control on the same hardware.  The control is not optional: on the
laptop it put the uniprocessor component at 2.7x and on real hardware it
was 1.6x, so it has to be re-run per platform rather than carried over.
.IP \(bu
A second workload that is not chantest.  Channel traffic is the case
the parallel VM is best at; something allocation-heavy or
module-loading-heavy would say whether the 4x is the workload or the
kernel.
.IP \(bu
arm64 on real hardware.  virtarm64 has never run anywhere but QEMU on
this branch, and cloud-port's
.CW virtarm64cloud
boots on a t2a, which is the obvious vehicle.
.PP
.B Acceptance:
a consistent gain at four processors across two workloads and two
architectures, with no panic in the batch, or an honest statement of
which workloads it does not help.
.NH 1
Phase E \- the open correctness items
.IP \(bu
.CW stoptheworld()
waits only for contexts with
.CW inxec
set, so "stopped" does not mean quiescent.  Documented, not fixed.
.IP \(bu
One stopped-world audit disagreement in ten thousand, shape "ready and
in no queue", consistent with
.CW addrun()
setting
.CW Pready
before it links.  The persistence check is in place and has not fired.
.IP \(bu
.CW nucleof303
does not link \(em
.CW "utflen: span looping !"
out of
.CW tl
\(em and did not before this work.
.NH 1
How to run any of this
.PP
.B "Boards."
.CW "for b in pc64 virtarm64 raspi3b virt virts virt32 virt32s shakti sifiveu spike armv7 mangopi mps2 teensy41; do (cd os/inferno/$b && mk install); done"
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
