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
There is nothing to reconcile and no merge commit to write: adoption is
a fast-forward of 95 commits.
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
predicted: their kernel prints 43
.CW stall:
lines on a default boot.  That is the gate working.
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
Adopt \(em
.CW "git merge --ff-only <sha>"
\(em once G1 passes, which means once their Phase C1 and C3 have landed.
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
.B "The second architecture."
.CW virtarm64cloud
boots on a
.CW t2a :
gVNIC because that machine takes no other card, a GICv3 ITS so the card
takes interrupts, the kernel-stack alignment fix, and the image recipe.
That is the vehicle for "arm64 on real hardware", and it is one script
invocation away.
.PP
.B "The second workload, with a baseline."
.CW p256test (1)
and
.CW chainbench (1)
are in the
.CW pc64
root and run natively.  They are allocation- and module-heavy where
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
Order
.PP
Step 0 today.  Step 1 against
.CW 225c058c ,
whose result is useful to them whichever way it goes, because nobody has
run this suite over that tree.  Steps 2 and 3 when Phase C lands.  Then
Phase D's two arms, which is where this branch's hardware and their
scheduler are worth more together than apart.
.PP
.CW main
is a separate question and a later one.  It sits 95 commits plus this
whole line behind, and merging to it is a decision about the tree, not
about these two branches.
