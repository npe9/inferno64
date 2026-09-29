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
Phase D \- done, and the default is flipped
.PP
Full numbers and the bug hunts are in
.CW doc/multicore-plan.ms .
.IP
.nf
                                 gain   instances   panics
channel traffic, amd64            2.5x      6         0
module loading, amd64             3.7x      6         0
channel traffic, arm64            4.1x      6         0
.fi
.PP
.CW "parallelvm = 1"
is the default.
.CW *parallelvm=0
still selects the old behaviour.
.PP
.B "Three bugs stood in the way and all three are fixed."
The process-group lists had no lock, which corrupted memory on three
amd64 instances in four;
.CW uartintr()
cleared every interrupt cause including a transmit interrupt it never
handled, which killed the arm64 console; and
.CW virtarm64_kick()
disabled the transmit interrupt while output was still queued.  The
first was found with
.CW *progquar=N ,
the second by running QEMU with something on stdin for the first time,
and the third by a counter that read zero locally and 92 on hardware.
.PP
.B "Two instrument lessons the plan carries forward."
.CW CHANTEST-OK
is a serial-console print and measures the console: four instances
returned exactly 645, and so did the one-processor controls.  Use Dis
quanta per tick.  And do not divide work by Dis quanta to remove host
speed \(em a quantum is a slice of Dis work, so the ratio is a constant
of the program.  Proved: loading a host cut quanta per tick from 35.9
to 19.5 while the ratio moved one per cent.
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
.NH 1
The JIT crossed with the parallel VM, on both architectures
.PP
This plan named five phases and no JIT test, which is a gap rather than a
decision: the plan's own front matter says the interpreter cannot be made
parallel partly because
.I "every JIT backend compiles the register file's absolute address into
.I "the code it emits,"
and no phase here asked whether that was still true.
.CW scripts/check-arm64-jitmatrix.sh
and
.CW scripts/check-pc64-jitmatrix.sh
are the two-by-two of
.CW *parallelvm
against
.CW *cflag ,
one kernel per architecture, nothing relinked between cells.
.PP
.B "arm64: all four cells, and the JIT is real."
.CW comp-aarch64.c
was forty-five lines whose
.CW compile()
returned 0; it is the hosted
.CW comp-arm64.c
now, with a kernel's allocator and cache flush.  Three boots per cell on
virtarm64 under QEMU at
.CW "-smp 4" ,
twelve of twelve reaching an interactive shell, and the two
.CW cflag=1
cells reaching it with the JIT on rather than with the option silently
dropped:
.IP
.nf
parallelvm=0 cflag=0   ok ok ok        to shell (ms): 9152 8685 8390
parallelvm=0 cflag=1   ok-jit x3                      9191 9283 9053
parallelvm=1 cflag=0   ok ok ok                       8769 8695 8956
parallelvm=1 cflag=1   ok-jit x3                      8821 8750 8945
.fi
.PP
.B "The times are not a benchmark and the spread says so."
Every cell is between 8.4 and 9.3 seconds, the ranges overlap, and the
number covers the UEFI firmware and the kernel's own device probes, which
the JIT cannot touch.  Nothing here supports a claim that the JIT is
faster or slower.  Nor is the host steady: a later run of the same four
cells, on a kernel that differed by one comment, came back at 7428, 7423,
7441 and 7441 milliseconds \(em a second faster than every cell above,
because the machine was idle rather than building.  A difference between
cells has to be larger than a difference between afternoons.  It is also compile-cost dominated by construction \(em a
boot runs each module about once, which is the worst case a JIT can be
asked for \(em so a speed claim would need a program that loops, and that
means adding one to the root file system, which has not been done.
.PP
.CW "parallelvm=1 cflag=1"
is legitimate rather than tolerated:
.CW comp-aarch64.c
sets
.CW jitrefsatomic=1 ,
updating
.CW Heap.ref
with LDXRW/STXRW retry loops at all four sites, so
.CW disinit()
has nothing to refuse.  What made the generated code safe for more than
one executor was one instruction: a move from the context register in
place of
.CW con((uvlong)&R) ,
at seven sites, because
.CW REG
is the first member of
.CW Pctx
and
.CW curP
on aarch64 is X25.
.PP
.B "amd64: three cells right, and the generator is the broken one."
Two boots per cell against a fresh
.CW CONF=pc64dev
at
.CW "-smp 2" :
.IP
.nf
parallelvm=0 cflag=0   ok ok
parallelvm=1 cflag=0   ok ok
parallelvm=0 cflag=1   PANIC[invalid opcode] x2   (a page fault now; see below)
parallelvm=1 cflag=1   refused refused
.fi
.PP
The panic is with the VM lock held and no second executor anywhere, so it
is
.CW comp-amd64.c
and not the parallel VM.  It already has
.CW uintptr
for
.CW patch[]
and the literal pool, so the two bugs that stood between
.CW comp-aarch64.c
and working are not this \(em but a third one of the same family was:
.CW genw()
wrote a four-byte x86 field and advanced by
.CW IBY2WD ,
which is eight here, leaving four bytes of nothing after every immediate,
displacement and branch offset.  That was the invalid opcode.  Fixed, the
first module is 15104 bytes rather than 27792 and decodes as x86 end to
end, and the cell panics with a page fault instead, because the generator
stores 32-bit halves of 64-bit Dis registers.  See the amended section in
.CW doc/multicore-plan.ms ;
correcting it means REX.W through the emitters, which is the job Phase 6
names.  The refusal in the last cell is correct: it
sets
.CW jitrefsatomic=0
and
.CW disinit()
says so on the console.
.PP
.B "And the pc64 harness was measuring its own marker."
It judged every cell on reaching an interactive shell, and
.CW CONF=pc64dev
cannot reach one \(em
.CW pc64devinit.b
prints "DEVTEST: done" and sleeps for ever.  So the control cell failed on
a kernel that had booted and finished, and what got written down from that
reading was "pc64 does not boot in this environment", which is false.  The
rule at the end of "How to run any of this" is about controls that are
missing; this is the other half of it, a control that is present and
broken, and it is the more expensive of the two because it looks like a
result.
.PP
.B "What is left, as items rather than caveats."
.IP \(bu
.B "Nothing on silicon."
.CW raspi3b
links the same generator \(em checked, it builds and links
.CW comp-aarch64.7
\(em and its
.CW segflush()
is real, cleaning the range with
.CW cachebcm.c 's
.CW cacheflush()
and dropping the I-cache with
.CW cacheiinv() ,
so a JIT it now claims is a JIT it can flush.  It has never been booted
with
.CW cflag=1 .
.IP \(bu
.B "Closed:"
.IR disbench (1)
is that workload, it is in virtarm64's root file system, and every cell of
the arm64 matrix runs it.  The numbers are below.
.IP \(bu
.B "Fixing"
.CW comp-amd64.c ,
unchanged as its own job and now specified: REX.W through the emitters.  It
is the only architecture in this tree with a generator that does not work,
rather than one of eight with a generator that was not there.
.NH 2
What the JIT is worth, measured
.PP
.B "And the instrument that had to come out first."
.CW checktracked()
runs once per Dis instruction and walks all 1024 slots of a table
.CW initmem()
fills with every pointer word of every object, and on this branch it had
no off switch.  Profiled with
.CW sample
against
.IR disbench (1):
2410 of 2498 samples inside it, against eleven in the Dis opcodes.  The
same run takes 9.2 seconds with it and 0.15 without.  It is guarded by
.CW distrack
now, default 0, turned on with
.CW *distrack=1
or
.CW INFERNO_DISTRACK=1 .
.PP
.B "That is a caveat on this branch's own numbers, not only on these."
Every interpreted measurement here was taken through it, and the parallel
speedups most of all: a per-instruction walk of a private table with no
shared state is the most scalable work a multiprocessor can be given, so
it inflates a parallel speedup by construction.  Those numbers need
retaking.
.PP
.B "virtarm64, QEMU -smp 4, one boot per cell, *disbench=20, milliseconds."
.IP
.nf
                  cflag=0    cflag=1
int                  3100         50
loop                  670         10
call                 9690         90
array                1360         30
real                 1280         30
string                330        220
boot to DISBENCH    11100       7544
.fi
.PP
.CW parallelvm=1
is within ten per cent of every one of these, which is what a
single-threaded benchmark should say.
.PP
.B "Between 30x and 100x on the compiled paths, and 1.4x on string."
.CW string
is allocation and copying, punted to C in both arms, and it is the control
that says the rest is the code generator and not the allocator.  The other
control is
.CW loop ,
which is
.CW call
without the call: by difference, a Dis call costs 277ns interpreted and
3.5ns compiled on the host.
.PP
.B "Read them as QEMU numbers."
TCG emulates the interpreter's dispatch instruction by instruction and
emulates far fewer instructions of compiled code, so it flatters a JIT.
The same benchmark on the host, where both arms run natively, gives 7x to
64x.  Nothing has been run on silicon.
.PP
.B "The boot is 1.5x faster compiled,"
7.5 seconds against 11.1 to the same marker \(em and the old instrument
could not see it.  With ninety-six per cent of the interpreter spent in
something both arms paid equally, all four cells came back at 7.4 seconds
and the matrix reported no difference at all.
.NH 2
And the hunt the instrument belongs to
.PP
.CW distrack
defaulting to 0 blinds nothing that was watching.  Checked rather than
assumed: nothing in
.CW scripts/
or
.CW tests/
greps for
.CW track:
or
.CW "CHANGED TO BAD VALUE" ,
and
.CW check-pc64-parallelvm.sh
judges on panics, "illegal dis instruction", "registers for" and "counts
disagree", none of which the tracker prints.  Phase E's first item is the
one thing that wants it, and it turns it on with
.CW *distrack=1 .
.PP
.B "That item is still live, and the pc64 matrix caught it."
Two boots per cell against a freshly built
.CW CONF=pc64dev
at
.CW "-smp 2" :
.IP
.nf
parallelvm=0 cflag=0   ok ok
parallelvm=0 cflag=1   PANIC[page fault] x2
parallelvm=1 cflag=0   PANIC[general protection violation], then ok
parallelvm=1 cflag=1   refused refused
.fi
.PP
The control cell is clean in the same run, so
.CW parallelvm=1
faulting where
.CW parallelvm=0
does not is the signal
.CW check-pc64-parallelvm.sh
exists to raise, and the matrix reports
.B PC64JITMATRIX-FAIL
rather than widening its expectation to cover it.
.PP
.B "The rate, and two runs of it that disagree."
Eight boots an arm, same kernel, same ISO recipe, run alone on the host:
.IP
.nf
parallelvm=1   3 of 8 bad
parallelvm=0   0 of 8 bad
.fi
.PP
.CW scripts/check-pc64-parallelvm.sh ,
which is the tree's own instrument for this and does the same thing, then
reported
.B "0 of 8 faulted"
on both arms against the same kernel.  Both are recorded rather than one
of them chosen.  Pooled, that is three failures in sixteen boots at
.CW parallelvm=1
and none in sixteen at
.CW parallelvm=0 ,
and a clean sweep of eight is exactly what a nineteen per cent rate
produces about one time in five \(em which is what that script's own
warning says and why it is written on its output.  The lesson is the
sample size, not a contradiction.
.PP
The three were
.CW "panic: lost pid" ,
.CW "vmachine: error \(dq<nil>\(dq with no current prog"
and
.CW "vmachine: error \(dq\(dq with no current prog" .
Two of the three are one shape \(em an error raised with no current
.CW Prog
\(em which is the register-file desync this plan's Phase E describes,
seen from the other end.  None in sixteen in the control is what makes
three in sixteen mean anything.  It is enough to say the item is open and
roughly how open, and not enough for a rate to be quoted to a second
digit.
