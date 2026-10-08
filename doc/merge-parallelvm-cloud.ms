.TL
Putting the parallel VM and the cloud work on one line
.AU
.NH 1
The state, which is not what the question assumes
.PP
The two lines have already been merged, in the other direction.
.CW multicore
merged
.CW cloud-port
at
.CW 8fcc14cd
on the morning of 19 September, six conflicts across 951 files, and has
gone on from there.  Measured rather than remembered:
.IP \(bu
.CW "git merge-base cloud-port multicore"
is
.CW c694e428 ,
which is
.CW cloud-port 's
own head.  So
.CW cloud-port
is an
.I ancestor
of
.CW multicore .
There was nothing to reconcile and no merge commit to write: adoption
was a fast-forward of 95 commits.
.B "That window has since closed" ,
and by this branch's own hand \(em the work below it put eight commits
on top, so
.CW "--ff-only"
will now refuse and adoption is a merge again.  A small one: the
conflict surface is those eight commits' files against theirs, and one
of them,
.CW mkconfig ,
is a certain conflict, because their
.CW ROOT
line differs from this tree's and this tree has added
.CW SYSMODULES=
beside it.  Keep this tree's
.CW ROOT ,
keep the
.CW SYSMODULES
line.  The lesson is the one in the ownership section below rather than
a new one: the cheap merge is the one taken the same day, and this
branch spent that day's credit within the hour.
.IP \(bu
200 files, +23265 \-235 lines, of which 14219 insertions are a vendored
.CW 9front/include
reference tree that this kernel does not build.  The kernel change is
.CW os/inferno/port
+1553,
.CW libinterp
+959,
.CW os/inferno/virtarm64
+470,
.CW appl
+304,
.CW os/inferno/pc64
+119,
.CW include
+100,
.CW libkern
+100, and 5267 lines of documentation.
.IP \(bu
Nothing of this branch's was lost in their merge.  Checked file by file:
.CW libinterp/ipint.c ,
.CW module/keyring.m ,
.CW module/ipints.m ,
.CW appl/cmd/ipinttest.b ,
.CW appl/cmd/p256test.b ,
.CW appl/lib/crypt/p256.b ,
.CW man/1/ipinttest
and all four check scripts are byte-identical on both sides.  One file
differs \(em
.CW os/inferno/pc64/pc64
gains three lines putting
.CW /dis/chantest.dis
in the root, marked
.CW TEMPORARY
by its own comment.
.IP \(bu
.CW scripts/
is untouched on their side.  All fifteen checks in
.CW check-all.sh
are this branch's, and
.B "none of them has ever been run on the merged tree" :
that branch measures boards, soaks and Compute Engine boots, not this
suite.
.PP
So the work is not a merge.  It is a verification, two obstacles, and a
decision about what the two branch names mean from here.
.NH 1
Two obstacles, both found by trying rather than reading
.PP
.B "1. Two untracked build products stand in the way of the checkout."
.CW os/inferno/boot/efi/bootx64.efi
and
.CW bootx64.out
exist here as untracked files and are
.I tracked
on the other side, so a checkout refuses rather than overwriting them.
They are the only two such files out of 131 the merge adds.  Move them
aside, adopt, and compare.
.PP
A built EFI loader in the repository is also the hazard this tree keeps
paying for \(em
.CW tools/aout2efi ,
.CW tools/aout2elf ,
.CW 7a ,
.CW 7l
are all checked-in binaries that
.CW mk
rebuilds only when the object is older than the source, and each has
cost a debugging cycle.  Adopting the file is not the same as agreeing
it should be there.
.PP
.B "2. The console is noisy again, and the gate cannot see it."
.CW hzclock()
on their side calls
.CW stalldump()
at 60 and 70 seconds and
.CW soakline()
every 120 seconds
.B "with no flag on either" ;
.CW *disdump
gates
.CW disdump()
alone, three prints of ninety-four.  Their own Phase C is about exactly
this.  The trouble for the merge is that
.CW scripts/check-disdump.sh ,
written here yesterday, greps the off arm for the
.CW disdump()
strings only \(em so it would pass a kernel that prints
.CW soak:
lines down an instance's serial console for the life of the machine.
The gate has to grow before it can hold, and that is step 0 below.
.PP
.B "3. mkconfig carries an absolute ROOT, and adoption would point it at
the other worktree."
.CW 225c058c 's
.CW mkconfig
says
.CW ROOT=/Users/npe/src/inferno64-branches/multicore ,
so the fast-forward replaces this tree's line with theirs and the next
.CW "mk install"
here installs its libraries and host binaries
.I "into that worktree" .
Nothing errors.  Their own notes record the same thing happening to
them in the other direction when their merge carried our line across.
.PP
This one is now caught rather than remembered:
.CW check-all.sh
refuses to run when
.CW mkconfig 's
.CW ROOT
is not the tree it is running in.  Verified both ways \(em with the line
edited to a wrong path it exits 1 and names both paths; restored, it
runs.  The repository has thirty worktrees, so this is a standing
hazard and not a one-off of this merge.
.NH 1
What the two names should mean
.PP
One trunk, two roles.
.CW multicore
is the development tip: the scheduler, the collector, the parallel VM,
arm64 SMP.
.CW cloud-port
is
.B "the last tip that passed the whole suite" ,
and the branch images are built from.  The difference between the names
stops being "which work is in it" \(em after today that answer is
"both" \(em and becomes "has it been checked".
.PP
That only stays cheap with a rule about who writes where.  From the
diff, the regions are already nearly disjoint:
.TS
center box tab(;);
c | c
l | l .
region;owner
_
port/dis.c, gc.c, xec.c, interp.h;multicore
libkern/ainc-*, the context pool, disreg.h;multicore
ethergve.c, its*virtarm64.c, port/pci.c;cloud-port
crypt/*, keyring builtins, scripts/, man/;cloud-port
pc64/main.c, virtarm64/main.c;the seam
the root configs, dis/init, doc/;the seam
.TE
.PP
The rule: sync one direction at a time, at most a day apart; whoever is
behind fast-forwards; and nobody edits the other's region without
saying so in the commit message.  Today's merge cost six conflicts
because the two branches were a morning apart, and four of the six were
in the seam \(em
.CW dis.c ,
.CW virtarm64/dat.h ,
.CW dis/init ,
.CW gc.c .
That is the cheap case, and it is cheap only at that cadence.
.NH 1
The gate
.PP
What has to be true before this branch's pointer moves:
.IP "G1" 6
All fifteen checks pass.  Five of them assert things the other branch
cannot know it has broken:
.CW check-tls
(an https fetch from a booted kernel, with plain http as the control),
.CW check-ipint
(the arithmetic that used to end in
.CW sysfatal
raises instead),
.CW check-cabundle ,
.CW check-crossarch
(one Dis binary, two processor families, one namespace) and
.CW check-disdump
(the console is quiet unless asked).
.IP "G2" 6
All fourteen boards build, exit status checked rather than output
grepped: "not declared" and "undefined external" do not contain
.CW rror .
.IP "G3" 6
pc64 and virtarm64 reach a first Dis quantum at
.CW parallelvm=0 ,
which is the default the series must not disturb.
.IP "G4" 6
Two rented instances from the adopted tip: an
.CW e2-small
amd64 and a
.CW t2a
arm64.  DHCP, an https fetch,
.CW ipinttest ,
.CW p256test .
.CW dis.c ,
.CW gc.c
and
.CW xec.c
sit underneath both the crypto and the network, and neither has run on
hardware with these changes.
.IP "G5" 6
.CW check-pc64-parallelvm
run, and its verdict written down.  This paper still says the parallel
VM is broken on pc64 and that the check is expected to fail; their
measurements withdraw the evidence for that \(em the run-queue check was
wrong, not the queues.  Whichever way it comes out, this paper and
.CW check-all.sh 's
comment change.
.PP
G1 fails on the current tip, and it has been shown failing rather than
predicted: fourteen of the fifteen checks pass on
.CW 225c058c
and
.CW check-disdump
is the one that does not, because the kernel prints
.CW stall:
down the console with no flag asked for.  That is the gate working, and
it is the only thing between this branch and adoption.
.NH 1
The procedure
.PP
.IP "0." 5
.B Done .
.CW check-disdump.sh 's
quiet arm now asserts the absence of
.CW soak: ,
.CW stall: ,
.CW nvm: ,
.CW audit: ,
the run-queue watermark and the vm-lock depth as well as the dump, and
still passes here.  Their kernel, built from their working tree and
booted under this one's QEMU with no
.CW *disdump ,
reaches a shell and prints
.B "43 stall: lines" ,
which is the prediction from reading
.CW hzclock()
confirmed by a boot.  And
.CW check-all.sh
refuses a tree whose
.CW mkconfig
names another worktree.
.IP "1." 5
Pin a SHA \(em not "the tip", which moves: that session committed six
minutes before this was written and has uncommitted
.CW pc64/memory.c
and
.CW mmu.c .
Trial it in a scratch worktree, run G1 through G3 there, and hand the
results back.  The branch pointer does not move for a trial.
.IP "2." 5
Rebuild in this order, from clean: the host tools first, meaning
.CW utils
and what it installs into
.CW MacOSX/arm64/bin ,
then the libraries per architecture, then the boards.  Remove the
objects
.I and
.CW Inferno/*/lib/*.a :
.CW mk
does not notice a
.CW CFLAGS
change and compares the archive against the sources rather than the
objects.  The merge changes what registers the compilers reserve; a
stale object compiled by the old one put garbage in
.CW curP
last time and cost a day.
.IP "3." 5
Adopt once G1 passes, which means once their Phase C1 and C3 have
landed.  Not
.CW "--ff-only"
any more \(em see section 1 \(em so it is
.CW "git merge <sha>"
with
.CW mkconfig
resolved by hand: this tree's
.CW ROOT ,
and keep
.CW SYSMODULES= .
Leave nothing staged: the index is shared with every other worktree.
.IP "4." 5
Then G4 and G5, and rewrite the two paragraphs of this paper that
adoption makes false.
.NH 1
What this branch owes their Phase D
.PP
Their plan says
.CW parallelvm=1
needs a second workload and a second architecture before it can be a
default.  Both exist here already.
.PP
.B "The second architecture, now run rather than offered."
.CW virtarm64cloud
boots on a
.CW t2a :
gVNIC because that machine takes no other card, a GICv3 ITS so the card
takes interrupts, the kernel-stack alignment fix, and the image recipe.
That is the vehicle for "arm64 on real hardware", and it has now been
driven: the instruments are in that root, and a
.CW t2a-standard-1
runs
.CW ipinttest
clean and
.CW "p256test -s 60"
at 94 cycles in 60.4 seconds, 430 ms a verification and 220 ms an
agreement, with the field costs and both ratios in
.I "The same arithmetic on the other processor family"
in the cloud paper.  What remains for Phase D is the same thing on four
processors with their kernel \(em a
.CW t2a-standard-4
and
.CW "*parallelvm=1" .
.PP
.B "The second workload, with a baseline, and now countable."
.CW p256test (1)
and
.CW chainbench (1)
are in the
.CW pc64
root and run natively, and
.CW "p256test -s "
.I secs
now repeats the arithmetic as a workload instead of measuring it once:
.CW P256-CYCLE
a pass, between
.CW P256-SOAK-START
and
.CW P256-SOAK-END ,
which a serial log can count the way their harness counts
.CW CHANTEST-OK .
The correctness controls stay inside the loop, so a pass that stops
verifying fails the command rather than being counted as work.  Hosted
and interpreted here it manages 69 cycles in six seconds; on an
.CW e2-small
a cycle is about 450 ms of the numbers below.  They are allocation- and module-heavy where
.CW chantest
is channel-heavy, which is the difference their plan asks for, and they
already have numbers on an
.CW e2-small :
about 300 ms an ECDSA verification, 150 ms an ECDH agreement, 37.50
\(*ms a modular multiply, and 3.2 s for a whole https fetch against
0.17 s in the clear.  A scheduler change that moves those moves a
number that is not chantest.
.NH 1
What adoption changes in this paper
.IP \(bu
.CW parallelvm
stays 0.  Flipping it is their Phase D and not a consequence of
adopting.
.IP \(bu
"And one thing that is known broken", in
.I "Where this stands" ,
is obsolete: it rests on the run-queue count disagreement, which was
the check and not the kernel.  It has to be rewritten from their
measurements, including the 4x on four real processors and the
uniprocessor component of it.
.IP \(bu
The density argument acquires a ceiling.  pc64 uses about 462 MiB of a
16 GiB machine, because
.CW mapkzero()
stops at 1 GiB and
.CW pmap()
maps 4 KiB pages only.  The 66 MiB boot floor and 78 KiB a service are
unaffected \(em they were measured in small guests \(em but "thousands of
services on the smallest rentable shape" must not be restated as
anything about a big one until their Phase B lands.
.IP \(bu
The console-quiet property is lost until Phase C.  Say so rather than
letting
.CW check-disdump
imply otherwise.
.NH 1
What not to do
.IP \(bu
Do not flip
.CW parallelvm
here.  The evidence for it is theirs to complete, and a default is a
claim about workloads nobody has run yet.
.IP \(bu
Do not edit that worktree or its region.  It is another session's, it
has uncommitted work in
.CW pc64/mmu.c
as this is written, and its dirty state is not ours to reason about.
.IP \(bu
Do not measure throughput on this host.  Four foreign QEMU guests have
been seen running at once here; their branch withdrew two throughput
claims to that, and a rented instance is the only quiet machine.  Do
not measure SMP throughput under TCG at all \(em on that path one
processor outruns four.
.IP \(bu
Do not adopt an unpinned tip, and do not adopt one whose own session
has uncommitted changes in the files the gate exercises.
.NH 1
What the trial found
.PP
Step 1 was run against
.CW 225c058c
in a detached worktree with
.CW mkconfig 's
.CW ROOT
pointed at it.  Seven findings, in the order they appeared, and a caution.
.PP
.B "1. A clean checkout could not build, for four separate reasons, none
of them the merge's."
The output directories
.CW mk
writes into are not in the repository \(em
.CW MacOSX/*/lib ,
.CW Inferno/*/lib ,
.CW acme/dis
and many more \(em so
.CW ar
and
.CW cp
failed until they were created.  The top level listed
.CW libprefab ,
which nothing links and which cannot compile since
.CW runt.h
moved under
.CW w$DISWORD .
Four directory mkfiles never set
.CW SYSMODULES ,
which
.CW mk
answers with "don't know how to make 'SYSMODULES'".  And
.CW mkdis 's
install rule assumed somebody had made
.CW dis/danby/plugin
by hand.  The last three are fixed here; the first is a documented step
until somebody writes the host-side equivalent of
.CW lib/emptydirs .
.PP
.B "2. The merged tree does not build virtarm64cloud, and neither branch
could have seen it."
.CW bootargs.c
on their side reads the boot options out of fw_cfg, and the fw_cfg
reader \(em
.CW fwcfgdma() ,
.CW fwcfgfile()
\(em lives in
.CW screenarm.c ,
which
.CW virtarm64cloud
deliberately does not link: probing ramfb at a fixed address kills a
.CW t2a .
So the link fails with
.CW "fwcfgbootargs: undefined: fwcfgfile" .
They do not build that configuration; this branch did not have
.CW fwcfgbootargs .
.PP
The fix is to put the reader where every configuration gets it.  Moving
.CW fwcfgsel ,
.CW fwcfgdma ,
.CW fwcfgfile ,
the
.CW FwDmaDesc
descriptor and the byte-swap helper out of
.CW screenarm.c
and into
.CW bootargs.c ,
which is in the board's
.CW OBJ
list, builds both configurations \(em verified in the trial tree, 1848059
and 2205080 bytes.  It belongs on their line rather than this one,
because their
.CW screenarm.c
is the version that survives: they made
.CW fwcfgdma
non-static and gave it a static descriptor, since the options are read
before the allocator exists.
.PP
.B "3. Five boards failed, and it was the worktree rather than the
merge."
.CW virt32 ,
.CW virt32s ,
.CW armv7 ,
.CW mps2
and
.CW teensy41
stopped at
.CW "don't know how to make dis32/basename.dis" .
The 32-bit boards want a second Dis tree at a 32-bit word size, built
with
.CW "mk DISROOT=dis32 DISWORD=4 install"
in
.CW appl/lib
and
.CW appl/cmd
as
.CW AGENTS.md
says, and a clean worktree has none.  The control that established this
was building the same five boards in
.I this
tree, where they all succeed \(em which is the only reason it was not
written up as a regression.  It is the same trap as the eight-day-old
ISO: an input the check does not build.
.PP
.B "4. An assembler trapped on a long path, which is why the boards
looked worse than they are."
With
.CW dis32
built,
.CW armv7
still died at
.CW "Trace/BPT trap: 5"
and nothing else.  Ten assemblers copy the source path into
.CW "char ofile[100]"
with
.CW strcpy ,
and the host's fortified
.CW strcpy
answers an overflow with a breakpoint; a worktree under a session's
scratch directory passes 100 characters easily.  Controlled: the same
file at a 105-character path traps and at a short path assembles, with
both the old binary and a freshly built one.  Fixed here \(em 1024 bytes
and a refusal that names the length \(em and with
.CW ROOT
a short path the merged tip builds
.B "all fourteen boards" .
.PP
.B "5. The suite on the merged tip: fourteen of fifteen."
.TS
center box tab(;);
c | c
l | l .
check;result
_
man-pages, config-portlines, cabundle;ok
cloudauth, discovery-retry, ipint;ok
pc64-timers, pc64-tcp, pc64-disk;ok
pc64-redeploy, pc64-smp, tls;ok
arm64-smp (8 processors ticking);ok
crossarch (one binary, two arches);ok
disdump;FAIL
.TE
.PP
So the scheduler work does not break anything this branch checks for,
including TLS from a booted kernel and one Dis binary running on both
architectures out of one mount.
.CW check-arm64-smp
reports eight processors ticking rather than the old four.
.PP
The one failure is the console:
.DS
.CW
*disdump=off: shell=yes instrumentation=yes
check-disdump: FAIL -- instrumentation printed with no *disdump:
    | stall: cpu0 ticks 6000 proc -1
    | stall: gcsema locked 0 head -1 gcstw 0 by -1 npctx 6 phase 5
    | stall: gcnruns 17568 stwwaits 0 gcidlepass 17565 ...
.DE
.PP
.B "And the same kernel passes the check as it was written yesterday."
The trial tree's copy of
.CW check-disdump.sh
came from
.CW 225c058c ,
which predates the extension, and it reported
.CW ok
on this kernel at both 90 and 150 seconds.  The extended one fails it.
That is what a blind instrument looks like from the inside: the gate was
not wrong about a different kernel, it was silent about this one.
.PP
.B "6. Three of the trial's own failures were the trial."
.CW check-arm64-smp
and
.CW check-crossarch
failed for want of
.CW .qemu/edk2-aarch64-code.fd ,
which had not been copied in; five boards failed for want of
.CW dis32 ;
.CW armv7
failed for the path length.  All three were setup, and all three would
have read as regressions in the merged tree if they had gone back
unchecked.  Re-run with the firmware present, both checks pass.
.PP
.B "7. The rest built."
The tree, the host compilers, pc64 and pc64dev, virtarm64, virtarm64cloud
with the patch, and all fourteen boards, from clean.
.PP
.B "And the caution: nothing from the suite goes back to them until it
has run alone."
Five QEMU processes were live when the trial's suite started, four of
them another session's, and
.CW check-crossarch
has already failed here once on contention alone.  A failure handed to
an active session that turns out to be this host is expensive in both
directions, so any failure is re-run by itself before it is reported.
.PP
The verified fix from finding 2 is in
.CW doc/fwcfg-move.txt ,
because a diff that exists only in a worktree about to be deleted is not
a durable thing.  Note that the trial tree carries five local edits, not
one: that patch,
.CW mkconfig 's
.CW ROOT
and
.CW SYSMODULES ,
the
.CW mkdis
install rule, the
.CW libprefab
removal, and 1319 created directories.
.NH 1
Order
.PP
Steps 0 and 1 are done, and their results are the section above: the
merged tip passes fourteen of fifteen, the one failure is the console
noise their Phase C is already about, and the arm64 cloud kernel needs
.CW doc/fwcfg-move.txt
to link at all.  Steps 2 and 3 wait on Phase C1 and C3; there is nothing
else outstanding on this side.  Then Phase D's two arms \(em a
.CW t2a
for arm64 on real hardware, and the crypto benchmarks as a workload that
is not chantest \(em which is where this branch's hardware and their
scheduler are worth more together than apart.
.PP
.CW main
is a separate question and a later one.  It sits 95 commits plus this
whole line behind, and merging to it is a decision about the tree, not
about these two branches.
.NH 1
What is left, in order, as of 21 September
.PP
Their side has moved: Phases A to D landed on the 19th, the
instrumentation is behind one switch, pc64 maps large pages, the
.CW parallelvm=1
corruption turned out to be
.CW "addgrp() and delgrp()"
keeping the process-group list with no lock, and Phase D now reads 2.5x
on the channel workload and 3.7x on module loading over twelve instances
with no panic.  Their plan has one acceptance item left and it is arm64.
This is what remains here, and the order is by dependency rather than by
importance.
.NH 2
1. Two checks that need nothing from anybody \(em done
.PP
.B "1a. Root parity between the two configurations of one board."
.CW virtarm64
and
.CW virtarm64cloud
are 176 and 237 lines and genuinely different products \(em one has the
draw stack and
.CW screenarm ,
the other
.CW ethergve ,
.CW screennone
and the cloud userland \(em so they are not collapsible.  What is
collapsible is the cost of that: every addition has to be made twice and
twice it was not.
.CW chantest
went into
.CW virtarm64
and not the cloud one, which made an arm64 measurement print "file does
not exist" three times a cycle for ten minutes; the same shape put
.CW fw_cfg
inside
.CW screenarm.c
and broke the cloud board's link.  A script that compares the two root
lists and reports what one has and the other lacks, against a short
allow-list of the differences that are deliberate, would have caught
both in a second.
.PP
.CW scripts/check-rootparity.sh
is that script, in the quick tier.  The invariant it encodes is the one
that actually holds on both branches: the cloud root is a
.I superset
of the plain one \(em 49 entries of the plain root, plus 53 of its own
\(em so what it fails on is an entry the plain configuration has and the
cloud one lacks, which is exactly the shape of both incidents.
Directory entries are compared too, since a missing mount point is as
much a failure as a missing file.  Controlled: one line removed from the
cloud root, and it names that line and exits 1.
.PP
.B "1b. A boot with more than 4 GiB."
Their first Phase E item is the pool overlap checker firing for the
first time, on a machine with memory above 4 GiB \(em which is every
cloud machine and no local test.  It reports a chain head whose magic
reads 0x2103 rather than
.CW MAGIC_E ,
with the next entry unaligned and zero-length; it does not panic and the
kernel runs Dis, so it is a corruption signal rather than a failure.
.CW "qemu -m 16384"
is how the last big-memory fault was reproduced locally, and a check
that boots pc64 that way and fails on
.CW pooloverlap
costs one boot.  It also gives them a reproduction that is free rather
than rented.
.PP
.CW scripts/check-pc64-bigmem.sh
is that check, and running it settled something this branch had only
inferred:
.B "pc64 here does not boot a 16 GiB machine at all."
The 1 GiB control reaches a shell; at 16 GiB the kernel counts 4179427
pages, which is the memory, and then panics with a page fault.  That is
the fault their
.CW 131bce57
fixed \(em a 32-bit chunk size, not the mapping \(em so the check fails
here on purpose, in the slow tier beside
.CW check-pc64-parallelvm ,
and flips to passing on adoption.
.PP
It is also the sharpest argument for adopting.  Every machine worth
renting has more than 4 GiB; this branch cannot boot one.
.PP
.B "1c. Housekeeping."
61 test images and 165 MiB of tarballs in the project, no instances
running.  They are disposable and reproducible in minutes; a sweep needs
saying out loud because it is 61 irreversible deletes.
.NH 2
2. Adopt, which needs permission
.PP
The merge is two files: this paper's section 1 for
.CW mkconfig
and, in
.CW os/inferno/virtarm64/virtarm64cloud ,
their
.CW chantest
line against this branch's two instruments \(em keep all three.  Then the
procedure in
.I "The procedure"
above, and the gate: fifteen checks, fourteen boards on exit status, a
first Dis quantum at
.CW parallelvm=0 ,
two rented instances, and
.CW check-pc64-parallelvm
run so its verdict is on the record.
.CW "git merge"
into this branch was refused as a shared-resource change and is the one
step here that is not mine to take.
.PP
.B "So it was done in a worktree instead, and the merge is clean."
.CW /tmp/adopt ,
detached, short path.  Git reports no conflict at all: their
.CW mkconfig
hunk and this branch's are in different places, and so are the two root
additions.  All three
.CW virtarm64cloud
entries survive \(em
.CW chantest ,
.CW p256test ,
.CW ipinttest
\(em and
.CW check-rootparity
passes on the result.
.PP
.B "And that is the problem with it."
A clean merge takes
.I their
.CW ROOT
line, so the merged
.CW mkconfig
names the other worktree and the first
.CW "mk install"
afterwards would install into it.  Nothing in git says a word about it.
.CW check-all 's
guard catches it, which is why that guard exists, but the resolution
belongs in the merge commit rather than in a later fix: set
.CW ROOT
back to this tree, keep
.CW SYSMODULES= .
.PP
.B "Everything builds."
The tree, the host tools, all four kernels \(em including
.CW virtarm64cloud ,
which their
.CW fwcfg.c
fixes \(em the 32-bit Dis tree, and all fourteen boards, in four minutes
on a quiet machine.
.PP
.B "The gate: fourteen of sixteen, plus the one that was meant to flip."
.CW check-pc64-bigmem
.B passes
on the merged tree: 16 GiB reaches a shell with 4171621 pages counted,
where this branch page-faults.  The pool overlap checker did
.I not
fire there, which is a finding about the reproduction rather than about
the bug \(em their instance saw it on hardware with a different memory
map, so 16 GiB under QEMU is not sufficient to raise it.
.CW check-disdump
passes, which was the blocker: Phase C's switch does what it says.
.PP
Two checks failed, and neither was the kernel.  Re-run alone, both
failed on
.I this
branch too, at the same moment, with twenty-odd other sessions' guests
on the host.
.PP
.CW check-pc64-tcp
knocked once, twelve seconds after the boot's ready marker.  On a loaded
host
.CW cloudinit
and
.CW tcpserve
take longer than that, so the single attempt landed before anything was
listening and the check said "no connection accepted" \(em a kernel
verdict for a harness timeout.  It retries now, and passes on both trees
under the load that failed both.
.PP
.CW check-crossarch
passed on retry with no change at all, but its failure was unreadable
and is worth recording.  The merged tree's guest had received
.CW "mount -A tcp!10.0.2.2!52293 /n/.x"
for a command that said
.CW /n/x :
one character gained on a console that types one character at a time.
The bind then found nothing and every later line \(em the
.CW Rerror ,
the
.CW mntwalk
complaints, "sh: crossarch: file does not exist" \(em was an honest
report about a command nobody sent.  The check now compares the echoed
line against what was typed and says
.CW "CANNOT TELL" ,
naming both, rather than blaming the kernel.
.PP
.B "So the trial's verdict is sixteen of sixteen."
Every check passes on the merged tree, all four kernels and all fourteen
boards build, and the two checks that were meant to flip on adoption did:
.CW check-disdump
and
.CW check-pc64-bigmem .
.CW check-pc64-parallelvm
was stopped rather than finished \(em it is ten boots whose result moves
with host load, and the host had twenty other guests on it, so the
number would have meant nothing.  That one is worth running on a quiet
machine after adoption.
.NH 2
3. Three paragraphs that adoption makes false
.IP \(bu
.I "Where this stands" 's
"one thing that is known broken" rests on the run-queue count
disagreement, which was the check and not the kernel, and on
.CW parallelvm
being broken on pc64, which their twelve instances contradict.
.IP \(bu
The 462 MiB ceiling on a big machine: large pages landed.
.IP \(bu
.CW check-all.sh 's
comment that
.CW check-pc64-parallelvm
is expected to fail.  Whichever way the run comes out, the comment has
to say what is true.
.NH 2
4. The arm64 console fault, which is this branch's board
.PP
Five
.CW t2a-standard-4
instances bring up four processors and run the parallel VM without
panicking, and then four of them stop producing console output and never
resume \(em the serial API's byte offset frozen while the instance stays
.CW RUNNING ,
and one of the two
.CW parallelvm=0
controls did it too, so it is the board rather than the scheduler.
.PP
It cannot be chased from this branch as it stands, and that is worth
knowing before anyone tries: the transmit-interrupt fix is on their side
only.  Here,
.CW virtarm64_kick()
still leaves
.CW UartIMSC
at RX alone and
.CW uartintr()
never calls
.CW uartkick() ,
which is the older bug that loses the tail of every log.  Reproducing on
this tree would reproduce the wrong fault.  So this item follows
adoption, not the other way round.
.PP
Then the discriminators, cheapest first, each of which separates two
causes rather than confirming a guess:
.IP \(bu
Is the kernel still generating output?  A kproc that
.CW iprint s
a counter every few seconds bypasses the queue.  If
.CW iprint
still reaches the wire while
.CW print
does not, it is the queue or the transmit path; if neither does, it is
the UART, the routing, or a lock held forever.
.IP \(bu
Is the transmit interrupt still arriving?  Count entries to
.CW uartintr
and its TX branch in globals and report them from that same
.CW iprint .
.IP \(bu
Is the console lock held?  Their
.CW putstrn
takes a best-effort lock with a short spin; record the holder's
processor and pc and dump it.
.IP \(bu
Is the interrupt stuck active?  Read
.CW GICD_IROUTER
for the uart SPI and its
.CW ISPENDR / ISACTIVER
bits.  An SPI left active means an EOI that never happened, which would
explain permanent silence on a running machine.
.IP \(bu
The width control:
.CW *ncpu=1
on the same instance shape.  Their data has the fault at
.CW parallelvm=0
but not at one processor, and that is the arm the conclusion needs.
.NH 2
5. The pool overlap signal
.PP
After 1b has a local reproduction, or after it does not \(em if 16 GiB
under QEMU does not fire it, the signal is about the hardware's memory
map rather than the size, and that is itself the finding.  The allocator
is their region; the reproduction and the check are this branch's.
.NH 2
6. What the default flip needs, and whose call it is
.PP
Items 4 and 5 answered, the arm64 throughput measurement Phase D lacks
can be taken \(em
.CW t2a-standard-4 ,
.CW "*parallelvm=1"
against
.CW "*parallelvm=0" ,
Dis quanta per tick rather than console prints, which is the instrument
lesson their plan already paid for.  Then
.CW parallelvm=1
as a default is a decision on their plan, with this branch supplying the
hardware arm and the second workload.
.PP
.CW "p256test -s"
is still unexercised at four processors: their second workload was
module loading.  It is the cheaper of the two to run and the one with a
baseline on both architectures, so it is worth carrying into item 6
rather than being left as a thing that was built and never used.
.NH 2
The trial, re-measured after a day of both sides moving
.PP
Two days on, with their side 156 commits past the base and this one 29,
the question is whether the merge is still cheap.  Measured rather than
assumed, twice: once when this branch was 23 ahead and again at 29,
after seven fixes went in here.
.PP
.B "Nine files are touched on both sides and exactly one conflicts."
.TS
center box tab(;);
c | c
l | l .
file;outcome
_
utils/7l/span.c;CONFLICT, 2 hunks, comments only
libinterp/xec.c;auto-merged
libinterp/comp-arm64.c;auto-merged
os/inferno/port/dis.c;auto-merged
emu/port/devmnt.c;auto-merged
appl/cmd/mkfile;auto-merged
man/1/INDEX;auto-merged
mkconfig;auto-merged, and wrongly
os/inferno/virtarm64/virtarm64cloud;auto-merged
.TE
.PP
The one conflict is the same fix twice: both branches carried
.CW b42059ba9
independently, so the code is identical and only the comments differ.
.CW libinterp/xec.c
and
.CW comp-arm64.c
are the files their Dis VM work lives in and the files this branch's
zero-divide and JIT-handler fixes touch, and they still merged without a
word, because the changes are in different functions.  So "files touched
on both sides" overstates the cost by nine to one.
.PP
.B "And every fix survives the merge, checked rather than hoped."
.CW exZdiv
in the interpreter's divide and modulo, the JIT's own guard and its
.CW R.PC
repair,
.CW "bflag = 1" ,
.CW ~0U
in the device wstats,
.CW nochange ()
in
.CW styx.b ,
and the CASE guard in both
.CW 7l
and
.CW 5l .
One of those checks was itself wrong and worth recording: grepping
.CW xec.c
for "zero divide" found nothing, because the fix raises
.CW exZdiv
and the string lives in
.CW raise.c .
The count was the blind instrument, not the merge.
.PP
.B "mkconfig still comes across wrong, and that has not changed."
A clean merge takes their
.CW ROOT ,
so the first
.CW "mk install"
after adoption would install into the other worktree.
.CW check-all 's
guard catches it; the resolution belongs in the merge commit.
.PP
.B "Everything builds."
Tree, host tools, four kernels, the 32-bit Dis tree and all fourteen
boards, in three minutes.
