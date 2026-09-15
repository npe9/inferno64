.TL
A cloud system built out of namespaces
.AU
.SH
Abstract
.PP
.CW os/inferno/pc64
boots on Compute Engine, on both of an
.CW e2-micro 's
processors, holds state on a persistent disk across a reboot, takes a
DHCP lease from Google's server and answers a keystroke on the serial
console.  That is a port, not a system.  This is the plan for what to
build on top of it, what claim it is meant to test, and what result
would show the claim to be wrong.
.PP
Everything said here about the tree was run.  Everything not yet run is
marked as such.
.NH 1
The claim
.PP
An ordinary cloud workload is a Linux virtual machine, containers on
top of it for namespace isolation, a service mesh above that for naming
and routing, a provider SDK for each service it touches, and a
configuration language to tie the parts together.  Four of those five
layers exist to supply something the operating system does not.
.PP
Inferno already has three of them as kernel primitives.  A per-process
namespace is what a container approximates.  Styx makes a remote
resource a name you mount rather than an endpoint you call.  Dis is
portable, so one binary runs on any processor the kernel runs on.
.PP
The claim is that putting distribution in the operating system is
cheaper than assembling it above one.  It is a claim about cost, so it
is settled by measurement and not by argument, and the measurements do
not exist.  That is the largest single gap in this plan.
.NH 1
What is true today
.PP
Verified in this tree, by running it:
.IP \(bu
The kernel with its entire root is 8.3 MB; the whole bootable cloud
image is 2.1 MB compressed, which is smaller than most container base
layers.
.IP \(bu
Both vCPUs of an
.CW e2-micro
come up and stay up.  Until the interrupt-return fix, a two-processor
instance had roughly even odds of panicking before reaching a shell.
.IP \(bu
State survives a reboot.
.CW scripts/check-pc64-disk.sh
reams a file system onto a raw virtio disk, writes a file, cold-boots
the kernel and reads it back, with a fresh nonce each run, for both
.CW disk/kfs
and
.CW disk/kfs64 .
.IP \(bu
The network works: virtio-net, a DHCP lease from the provider's own
server, and the loader's
.CW *e820
path through UEFI.
.IP \(bu
Console input works, which is the only way in without a network
service.
.NH 1
What is missing
.PP
Stated plainly, because the plan below is mostly about closing these:
.IP \(bu
No HTTP client.
.CW appl/lib/url.b
parses a URL and nothing speaks the protocol.
.IP \(bu
No TLS on this branch.  It exists on
.CW inferno-rio
as
.CW tls12(2)
and
.CW https(2) ,
with a frozen CA bundle, and it is Limbo over
.CW libkeyring ,
which the native kernel already links.
.IP \(bu
No object storage client.
.CW s3.b
and
.CW awsv4.b
exist on
.CW inferno-rio .
.IP \(bu
No network service in the kernel root.
.CW styxlisten.dis
is built and simply not listed in
.CW os/inferno/pc64/pc64 .
.IP \(bu
No measurements of anything: not latency, not boot time, not memory
floor.
.IP \(bu
No supervision, no log or metric story, and no notion of a fleet.  One
image is one machine.
.NH 1
The plan
.NH 2
Phase 1: credentials and reach
.PP
Everything else needs these, and they are small.
.IP "1." 5
An HTTP/1.1 client in Limbo.  The metadata service is plain HTTP on a
link-local address, so this is needed before TLS and is useful without
it.
.IP "2." 5
.CW /cloud
as a namespace: the provider's metadata served as a file tree by a
.CW styxservers
program \(em instance identity, zone, machine type, attributes, and the
service-account token.  End state:
.CW "cat /cloud/token"
instead of an SDK.  This is the seed of the whole idea, because every
cloud SDK's first act is exactly this fetch.
.IP "3." 5
.CW tls12
and
.CW https
carried across from
.CW inferno-rio .
.IP "4." 5
A GCS client.  Google's authentication is a bearer token in a header
with no request signing, so with 2 and 3 done this is small.  End
state: durable storage that survives the zone, not just the instance.
.CW s3.b
and
.CW awsv4.b
then give AWS, and GCS's S3-compatible endpoint gives a second route.
.NH 2
Phase 2: the fleet as a namespace
.IP "5." 5
.CW styxlisten
in the kernel root, and a service that exports a namespace.
.IP "6." 5
Two instances on the provider's internal network: one exports
.CW /dis
and a work directory, the other mounts it and runs a program out of it.
Nothing is installed on the second machine.  End state: a distributed
system assembled from
.CW bind
and
.CW mount .
.IP "7." 5
Authentication between them:
.CW factotum
with a secret fetched from the metadata service or from object storage,
so that two machines that have never met can agree on who they are.
.NH 2
Phase 3: measure the claim
.PP
This is the part that produces knowledge rather than software, and it is
the part most likely to be skipped.
.IP "8." 5
Styx round-trip between two instances against raw TCP on the same pair,
and against a conventional RPC on Linux on the same instance shape.  If
mounting a remote namespace costs three times a direct call, that is an
argument against the whole design and should be published as one.  If
it costs a tenth more, that is a much more interesting result.  Nobody
has this number for a real cloud network.
.IP "9." 5
Boot to shell, against a minimal Linux image on the same shape.  A
2.1 MB image with its root compiled in is a different point in the
cold-start design space and the difference should be a number.
.IP "10." 5
The memory floor: the smallest instance the kernel will run useful work
on.  Density is what cloud economics is made of.
.IP "11." 5
The same Dis binary, unmodified, on an amd64 instance and an arm64
instance, sharing one namespace.  GCE rents both, and this tree already
boots arm64 under UEFI \(em the disk script does not yet emit a GCE
tarball, which is the only gap.  Migrating between processor families
is a live and expensive industry problem that is normally solved by
recompiling and re-qualifying an entire stack; here there is nothing to
recompile, and that is worth demonstrating rather than asserting.
.NH 2
Phase 4: what a service actually needs
.IP "12." 5
Supervision: notice a failed process and restart it.
.CW /prog
already exposes every process as files, so this is a program and not a
kernel change.
.IP "13." 5
Logs and metrics as a mountable file tree, so that observing a machine
is the same operation as reading one.
.IP "14." 5
Update: republish the image and recreate the instance, or mount a new
.CW /dis
and restart.  The second is the interesting one, because it is a
deployment with no image build.
.NH 1
Principles to hold to
.PP
These are what would make the result modern rather than a revival.
.IP \(bu
The provider's control plane is a namespace, not an SDK.
.IP \(bu
The unit of deployment is a namespace, not a container image.
.IP \(bu
Code is mounted, not installed.  A small immutable image plus a mounted
.CW /dis
is the shape.
.IP \(bu
Heterogeneous processors are free, because Dis is portable.  Do not
spend that advantage on native code.
.IP \(bu
Publish the measurements even when they are bad.  The claim in section
1 is falsifiable and should be treated that way.
.NH 1
Non-goals
.PP
This is not a replacement for a container orchestrator, and saying so
early is cheaper than being asked later.  It has no multi-tenancy
story: namespace isolation protects a process from mistakes, not a
tenant from an adversary, and nothing here has been examined by anyone
looking for a way through.  It is not ready to carry production
traffic, and will not be until at minimum TLS, supervision and the
Phase 3 numbers exist.
.NH 1
What would falsify the claim
.PP
Three results would sink it, and all three are cheap to obtain.  If
Styx round-trips cost several times a conventional RPC on the same
network, the file abstraction is too expensive for the thing it is
meant to replace.  If the kernel cannot hold a useful working set in
the memory of the smallest rentable instance, the density argument goes
with it.  And if a namespace mounted across two machines turns out to
need a supervisor, a retry policy and a naming service to be usable in
practice, then the four layers have been reinvented rather than
removed, and the honest conclusion is that they were load-bearing all
along.
.NH 2
Phase 2: one Inferno mounts another, and the line that stopped it
.LP
Item 5 is
.CW styxlisten
in the root and a service that exports a namespace; item 6 is a second
machine mounting it.  Both work now:
.DS
.CW
(kernel)  cloudinit; styxlisten -A -s tcp!*!6666 export /
(client)  mount -A tcp!127.0.0.1!PORT /n/remote
          ls /n/remote
          /n/remote/chan  /n/remote/dev  /n/remote/dis  /n/remote/net
          /n/remote/prog  /n/remote/proc ...
.DE
That is a hosted
.CW emu
reading the whole namespace of a kernel on the other side of a TCP
connection, on two processors, with nothing installed on either side
for the purpose.
.PP
Underneath it, the listening half of the stack is now proved and has a
regression test.  Nothing this branch had written for the cloud ever
listened \(em
.CW hget ,
.CW gcs ,
.CW cloudfs
and
.CW cloudinit
all dial out \(em so
.CW announce()
and
.CW accept()
had never run on a native kernel.
.CW tcpserve (1)
and
.CW scripts/check-pc64-tcp.sh
run them.
.PP
.B "What stopped it was one missing line in qlock()."
A client mount killed the kernel with
.DS
.CW
RDY: pid 21 state 8 r 0xe696698 from 0x29df11
e696698 e696698 2
panic: wakeup: state
.DE
.CW qlock()
appends
.CW up
to the queue and sets
.CW up->eql ,
.CW up->state
and
.CW up->qpc
\(em but never
.CW up->qnext .
It is the only enqueue in
.CW os/inferno/port/qlock.c
that did not:
.CW eqlock ,
.CW rlock
and
.CW wlock
all clear it, and so does
.CW os/9front/port/qlock.c ,
which this came from.
.PP
So the tail of the queue kept whatever
.CW qnext
that process had the last time it was queued anywhere, and
.CW qunlock 's
.DS
.CW
q->head = p->qnext;
.DE
walked off into that stale value and installed a process that had long
since moved on as the queue head.  A later
.CW qunlock
then readied it wherever it was \(em caught above readying pid 21 in
state 8
.CW ( Wakeme )
with its
.CW Rendez
still set, from
.CW qunlock+0x6f ,
one instruction before
.CW wakeup()
found
.CW r->p
naming a process that was
.CW Ready
rather than
.CW Wakeme
and panicked.
.PP
Exporting a namespace is what exposed it:
.CW exportfs 's
slaves queue on one
.CW QLock
and sleep on one
.CW Rendez ,
which is the combination that turns a stale link into a wakeup of the
wrong process.  It is not an SMP race \(em it happens with one
processor \(em and it was in the port for every board, not just this
one.
.NH 2
Phase 3 begun: the first measurement, and why its number does not count
.LP
Section "measure the claim" above says the claim this plan rests on is
about cost, that it is settled by measurement rather than argument, and
that the measurements do not exist.  The first of them now half exists.
.PP
.CW styxbench (1)
times the same exchange three ways against one server: a write and read
on a bare TCP connection, sequential reads of a file on a mounted
namespace, and reads of that file at offsets a megabyte apart so the
mount driver's readahead cannot answer one from another.
.CW tcpserve (1)
gained an echo mode to be the raw half's other end.
.PP
.B "The number it produces is not usable, and the reason is the useful part."
Across three runs of 3000 iterations it reports Styx at 0.4 times the
cost of raw TCP, stable to one decimal.  An abstraction cannot cost
less than the transport it is carried on, and that is how the flaw was
found rather than published: the Styx half is answered by the kernel,
.CW exportfs
reading
.CW /dev/zero
in C, while the raw half is answered by
.CW tcpserve ,
a Limbo program paying Dis interpretation on every exchange.  The ratio
measures which language the server is written in.
.PP
A sound version needs both halves answered by the same kind of server:
a raw echo served by the kernel, which does not exist, or the Styx half
served by a Limbo file server so that both pay Dis.  That is the next
piece of work on this item.
.PP
Two smaller results are sound and worth keeping.  The transport here is
QEMU's user-mode networking and it is jittery: at 300 iterations the
ratio ranged from 0.3 to 1.3 across runs and only settled at 3000, so
any version of this experiment needs its iteration count justified
rather than assumed.  And the gap between sequential and jumping reads
is the mount driver's readahead, which is real and is what the file
abstraction buys back on a sequential caller \(em that part of the
comparison is between like and like, because both halves of it are
Styx.
.NH 2
The first sound number: a Styx round trip costs 1.2 to 1.5 times a TCP exchange
.LP
The measurement above was rejected because its two halves were answered
by different kinds of server.
.CW zerofs (1)
fixes that: a file server written in Limbo, serving one file of zeros,
so that the Styx half pays Dis interpretation exactly as
.CW tcpserve
.CW -e
does on the raw half.  Both ends are then the same kind of program, the
same client drives both, and what is left between them is the protocol.
.PP
Three runs of 3000 iterations of 64 bytes, client a hosted
.CW emu ,
server a native kernel, transport QEMU user-mode networking:
.TS
center;
l r r r.
_
	raw tcp	styx seq	styx jumping
_
run 1	2040 us	2439 us (1.1x)	2611 us (1.2x)
run 2	1446 us	1902 us (1.3x)	2257 us (1.5x)
run 3	1057 us	1214 us (1.1x)	1680 us (1.5x)
_
.TE
.PP
.B "A Styx round trip costs about 1.2 to 1.5 times a bare TCP exchange"
on this path.  The absolute figures swing by a factor of two between
runs, which is the transport and not the protocol; the ratio is what
holds, and the ratio is what should be quoted.
.PP
Section "what would falsify this" names the threshold: if Styx
round-trips cost several times a conventional call, the file
abstraction is too expensive for the thing it replaces.  One and a half
times is not several times.  On this evidence the cost objection does
not sink the design \(em with three caveats that keep it from being the
final word.  The transport is a NAT on one host, not a network.  The
comparison is against a raw TCP exchange, not against a conventional
RPC with its own framing and serialisation, which would be a fairer
stand-in for what the design replaces and would very likely narrow the
gap further.  And client and server are not two like machines.  The
plan's own version \(em two instances on a real network \(em is still
the one that settles it.
.PP
The readahead result stands separately and is like-for-like, both
halves of it being Styx: sequential reads cost consistently less than
reads at offsets a megabyte apart, which is the mount driver answering
from a buffer rather than from the wire.  That is what the file
abstraction buys back on a caller that reads in order.
.NH 2
The experiment this plan actually specified: two instances, real network
.LP
Section "measure the claim" asks for the Styx round trip between two
instances, not between a hosted client and a guest through a NAT.  Two
Compute Engine
.CW e2-micro
instances, both running this kernel, on the provider's internal network
\(em
.CW inferno-bench-a
at 10.128.0.29 serving
.CW zerofs
and
.CW "tcpserve -e" ,
.CW inferno-bench-b
at 10.128.0.30 mounting and measuring:
.TS
center;
l r r r.
_
size	raw tcp	styx seq	styx jumping
_
64	440 us	373 us (0.8x)	393 us (0.8x)
64	397 us	367 us (0.9x)	367 us (0.9x)
64	367 us	470 us (1.2x)	397 us (1.0x)
512	327 us	387 us (1.1x)	433 us (1.3x)
_
.TE
.PP
.B "On a real network a Styx round trip costs about what a raw TCP"
.B "request and reply costs"
\(em 0.8 to 1.3 times it across these samples, which is parity within
the run-to-run spread, with a little more cost at the larger payload.
The absolute figures are also four to five times better than the QEMU
ones, and far steadier, which says most of what the earlier numbers
measured was the NAT.
.PP
.B "What the comparison still is not."
Both sides are one network round trip, so the transport dominates and
what separates them is implementation.  On the Styx side the client is
the kernel's mount driver, in C, and the whole exchange is one system
call.  On the raw side the client is a Limbo program making two \(em a
write and a read \(em and paying Dis for the loop between them.  That
asymmetry cannot be removed while comparing "read a file" with "send a
request and wait for a reply", because the first genuinely is one
operation and the second genuinely is two.  It is arguably the
design's advantage rather than a flaw in the measurement, but it is not
a measurement of the protocol in isolation and should not be quoted as
one.
.PP
The earlier figure of 1.2 to 1.5 times, from the QEMU pair, used a
hosted
.CW emu
as the client, whose mount driver is emu's own C rather than a
kernel's.  Both numbers are kept above; the two-instance one is the
one this plan asked for.
.PP
So the cost objection in "what would falsify this" is answered as far
as this experiment can answer it: a mounted namespace is not several
times more expensive than the raw exchange it replaces.  It costs about
the same.  What remains untested is the comparison against a
conventional RPC with its own framing and serialisation, which is the
thing a real service would otherwise use, and which would carry costs
Styx does not.
.NH 2
Merging the multicore branch
.PP
The
.CW multicore
branch carries arm64 SMP and a parallel Dis VM.  An earlier note in
this document said the two branches had forked architecturally over the
per-Dis-word-size generated headers
.CW ( libinterp/w4 ,
.CW libinterp/w8 ),
and that the fork needed a decision.  That was wrong, and wrong in the
direction that makes it worth recording: it was
.I multicore
that tracked those 22 headers and this branch that did not, and the
generation rules in the two mkfiles are byte-identical.  The claim came
from reading a
.CW "git ls-tree"
diff in the wrong direction.  There was no fork, only ordinary merge
work, and this section is what that work turned out to be.
.PP
.B "What was taken."
The Dis VM wholesale \(em
.CW libinterp/xec.c ,
.CW heap.c ,
.CW gc.c
and
.CW include/interp.h ,
which carries the
.CW Prog.R
to
.CW Prog.reg
rename, the
.CW disreg.h
context register and the
.CW trackpoint
declaration \(em together with
.CW os/inferno/port/dis.c ,
the two
.CW utils/6c
files that reserve the register it needs, and
.CW libkern/ainc-aarch64.s .
The parallel VM is board-independent, so every board gets it.
.PP
.B "What was not taken: the arm64 secondary bring-up."
Both branches wrote it, in different files.  This one has
.CW os/inferno/virtarm64/startcpu.c
driven from
.CW main.c 's
.CW startcpus() ;
multicore has no
.CW startcpu.c
at all and does the work inline in
.CW main.c ,
with its own
.CW _secondary
in
.CW l.s .
Taking either side discards a working implementation, and neither is a
verified baseline: this branch's secondaries answer, report their
MPIDRs and then idle at
.CW "conf.nmach 1" ,
and multicore's are switched off because one boot in ten shows Dis heap
corruption.  So
.CW os/inferno/virtarm64
is left exactly as this branch had it \(em which is the configuration
that passes UEFI 10/10,
.CW "-smp 4"
and
.CW "-smp 17"
to an interactive shell, and
.CW ARM64-DISK-OK .
Reconciling the two designs is the arm64 session's call, not a merge
conflict to be resolved by picking a side.
.PP
That also keeps the fix this branch made to that board.  Its trap
return does not reload
.CW up
and
.CW m
from the saved
.CW Ureg
.CW ( 2f640d0f ),
and multicore's still does \(em
.CW "MOV UR_R26(RSP), R26"
and
.CW UR_R27 .
On one processor that is harmless.  Once cpu1 runs processes it is the
arm64 twin of the
.CW "POPQ R14; POPQ R15"
that was the whole of pc64's SMP corruption, where the fix took 4-of-4
boots faulting to 20-of-20 clean.  It is therefore the first thing to
try against multicore's one-in-ten, and it is a live bug there rather
than a latent one.
.PP
.B "Four things the merge broke that the build caught, and one it did not."
Taking a side wholesale lost real work each time, and only reading the
removed lines found it.  Taking multicore's
.CW pc64/l.s
dropped this branch's PVH entry point, the direct-boot ABI Xen,
Firecracker and Cloud Hypervisor use.  Taking its
.CW pc64/trap.c
dropped the
.CW #GP
recovery for
.CW rdmsr / wrmsr
.CW ( 761f7bbb ),
without which
.CW devarch.c 's
"returns \-1 if it trapped" contract does not exist \(em one of the two
bugs only real hardware found.  Both were spliced back onto multicore's
files rather than resolved by picking a side.  Going the other way,
multicore's
.CW devprog.c
called a
.CW disracepid
probe whose other half this branch had deliberately retired, and its
.CW xec.c
calls
.CW printfreehist() ,
whose ring this branch removed because its per-caller print hung
riscv64 permanently in five boots of five; that one gets a stub saying
there is no record, the way
.CW emu/port/alloc.c
already does, because silence is indistinguishable from "no".
.PP
The one the build did not catch:
.CW libinterp/gc.c
carried a temporary probe comparing a type's
.CW mark
pointer against
.CW etext ,
which the host linker does not define \(em
.CW libinterp.a
is built once and shared by
.CW emu
and every kernel, so there is no
.CW -DEMU
to key it on, and a host stand-in would make the bound wrong and the
aborts false.  It is dropped.  The other 23 probes multicore is
carrying were audited rather than assumed: none of them aborts on a
correct
.CW parallelvm=0
run \(em they print once under a rare guard, or run only inside
.CW panic() ,
or are silent counters.  Two that printed on every boot
.CW ( probenewtype ,
.CW probearrtype )
are gated behind a flag rather than deleted, because they belong to a
hunt that is still open and a serial log this branch reads to verify a
boot is not the place for them.
.PP
.B "parallelvm stays 0."
At 0 the VM lock is taken as before and the merged VM should behave
exactly as the old one.  Turning it to 1 in the same change would make
any failure unattributable between the merge and the parallel VM, and
would throw away the control arm every other result in this document
rests on.
.PP
.B "A gitignore rule that was quietly eating source."
Untracking build outputs left a rule,
.CW /os/inferno/*/i[a-z0-9]* ,
meant for linked kernels \(em they are named for their board, as in
.CW os/inferno/pc64/ipc64 .
No glob can say "named for its own directory", and every attempt to
approximate it took source with it:
.CW os/inferno/init/init.b
(hand-written Limbo, a sibling of
.CW bootinit.b ),
then
.CW os/inferno/port/inferno.c
(16K of kernel C), then
.CW pcidb.acid
and
.CW sd53c8xx.i ,
then the whole of
.CW os/inferno/virt/icons ,
because a directory named
.CW icons
matches too.  Excepting every dotted name in turn un-ignored 104
.CW .7
objects and every generated
.CW .root.[sch] .
The rule is now a list, one line per board: a list cannot over-match,
and a board added later shows up as an untracked kernel, which is
visible, rather than quietly untracking that board's source, which is
not.  Separately, the object-suffix rules covered
.CW .j ,
.CW .z ,
.CW .t ,
.CW .0
and
.CW .2
but not
.CW .5 ,
.CW .6 ,
.CW .7 ,
.CW .8 ,
.CW .q
or
.CW .v ,
so every amd64 and aarch64 kernel object counted as source \(em 151 of
them.
.PP
.B "The merge did not boot, and the reason was the compiler."
With everything resolved and every board linking, pc64 panicked
.CW "vmachine: error \(dqillegal dis instruction\(dq with no current prog"
immediately after the device binds, deterministically, on one processor
and on two.  The same
.CW disinit.dis
ran past that point under hosted
.CW emu ,
which shares the same
.CW libinterp ,
and
.CW libinterp/optab.h
and
.CW include/isa.h
are byte-identical on both branches \(em so it was not an opcode table
and not SMP.
.PP
The difference between the two is
.CW -DDISCTXREG ,
which puts the Dis context
.CW curP
in an external register (R13 on amd64) for the kernel and leaves it an
ordinary global for
.CW emu .
multicore's
.CW utils/6c
reserves four external registers instead of two so that no compiled
file uses R13 or R12 as scratch.  But
.CW MacOSX/arm64/bin/6c
is a checked-in host binary, and it was four days older than the
.CW utils/6c
sources the merge brought in.  Every amd64 object was therefore
compiled by a
.CW 6c
that reserved two registers, while
.CW libinterp
kept the Dis context in the third \(em so ordinary C code used R13 as
scratch and
.CW curP
was whatever the last expression left there.  Rebuilding the toolchain
and every
.CW .6
from scratch gives 0 panics on one processor and 0 on two.
.PP
Two lessons, and the second is the one that cost the time.
.B "Merging a branch that changes the compiler means rebuilding the compiler" ,
and then rebuilding everything it compiled \(em a kernel that links is
not evidence that its objects agree.  And the cleanup
.CW rm
that should have forced that rebuild silently did not run at all: under
.CW zsh
a glob matching nothing aborts the whole command, so one
.CW libmp/*.6
with no matches cancelled the
.CW rm
of eleven other directories, and the build that followed looked clean
because it had nothing to do.  The command printed its error; it was
read as a warning.
.PP
.B "One real bug this exposed."
.CW os/inferno/pc64/main.c 's
.CW userinit()
did
.CW "strcpy(p->text, \(dq*init*\(dq)" .
.CW Proc.text
is a
.CW char* ,
nothing has set it for that process yet, and so this wrote through a
nil pointer into physical address 0, which is mapped here and took the
write without complaining.  It was harmless for as long as nothing read
a pointer back out of address 0; with
.CW curP
clobbered, something did, and the fault came back with CR2
.CW 0x2a74696e692a ,
which is
.CW *init*
in little-endian ASCII.  The other eleven boards in this tree all say
.CW "kstrdup(&p->text, \(dqinterp\(dq)" ;
pc64 was the only one that did not.  Fixed.
.PP
.B "check-pc64-tcp.sh has always exited 1 on success."
It prints
.CW "ok \-\- the kernel accepted an inbound connection"
and then returns 1, so every previous "pass" of it was read from its
text and not from its status.  The script runs under
.CW "set -e" ,
and its
.CW EXIT
trap calls
.CW pkill ,
which returns 1 when it matches nothing \(em the normal case once the
guest is already gone.  That aborted the trap before the shell could
restore the status.  The trap now latches
.CW $?
first, makes every cleanup command succeed, and exits with the latched
value; the same pattern is applied to
.CW check-pc64-disk.sh
and
.CW check-pc64-smp.sh ,
which had the shorter form of the same trap.
.PP
.B "And check-pc64-disk.sh was reporting a harness timeout as a broken write path."
It failed with "nothing reached the disk image on the host", which
reads as the kernel not writing.  The kernel writes.
.CW type-at-console.py
leaves the guest running for fourteen seconds after it types the
command \(em right for a command that prints and exits, and wrong for
this one, because
.CW kfs 's
ream of a 64M file system runs well over a minute on a loaded machine.
The guest was being killed in the middle of the ream.  Given a longer
window the nonce is on the image and both file servers pass,
.CW disk/kfs
and
.CW disk/kfs64 .
The hold is now an environment variable
.CW ( INFERNO_CONSOLE_HOLD ,
default 14 so existing callers are unchanged) and the disk check asks
for 150 seconds.
.PP
That is three harness bugs in one session \(em a status lost to
.CW "set -e" ,
a hold too short, and an
.CW rm
cancelled by a zsh glob \(em each of which presented as a failure of
the thing under test.  Two of them would have been caught by asking
what a passing run looks like before trusting a failing one.
.NH 2
The parallel Dis VM does not work on pc64 yet
.PP
.CW scripts/check-pc64-parallelvm.sh
boots
.CW ipc64dev
on a two-processor machine at
.CW *parallelvm=1
and at
.CW *parallelvm=0 ,
from one kernel and one ISO recipe \(em
.CW main.c
reads the option at boot, so nothing is rebuilt between the arms.
.PP
It engages.  At
.CW *parallelvm=1
the log says
.CW "nvm: 2 hold the vm" ,
and
.CW "nvm: 3"
and
.CW "nvm: 4"
in other runs, so more than one interpreter really is inside
.CW xec()
at once, which is the whole point of the change.  At
.CW *parallelvm=0
that count never exceeds 1.
.PP
And it is broken.
.CW dis.c 's
own consistency check \(em
.CW "runq: 2 linked + 0 global but 1 in Pready \-\- the counts disagree"
\(em fired on
.B every
.CW parallelvm=1
boot measured, six of six, including the boots that completed, and on
.B none
of the eleven
.CW parallelvm=0
boots.  Separately, most
.CW parallelvm=1
boots never reach
.CW "DEVTEST: done" ,
while
.CW parallelvm=0
reached it 26 times in 26.  Nothing panics in either arm; the failure
is silent.
.PP
.B "The rate is not worth quoting and the difference is."
Runs of this gave 8-of-10, then 5-of-6, then 2-of-6 not finishing,
which is host load rather than three different phenomena.  The first
of those numbers was worse than the truth for a reason worth recording:
each boot was given 45 seconds, and
.CW parallelvm=1
does more work per boot, so a slower boot that would have finished was
counted as a failure.  That is the same mistake as the disk check's
fourteen-second hold, made again within the hour, which is why the
per-boot window is a variable now and why the script reports the
count-disagreement as well \(em that signal fires on a boot that
completes as readily as on one that does not, so it separates the arms
without any judgement about how long a boot should take.
.PP
.B "What this says, and what it does not."
It says the parallel VM is not ready on pc64 and that the first thing
to look at is the run queue bookkeeping, not the collector: the counts
disagree on runs that otherwise finish normally, so it is not a
stop-the-world failure.  It does not say the design is wrong, and it is
not a measurement of multicore's own tree \(em that branch has arm64
work and instrumentation this one deliberately did not take, and its
own report is of Dis heap corruption on arm64 rather than of this.
.CW parallelvm
stays 0 here, which is what it was set to when the VM was merged.
.NH 2
Phase 3 item 10: the memory floor
.PP
.CW scripts/check-pc64-memfloor.sh
bisects the smallest
.CW -m
this kernel runs on.  Two thresholds, because a kernel that boots and
then cannot run anything is not a machine anyone can rent: the smallest
that reaches the end of the bind list, and the smallest that runs a
typed command and answers.
.PP
.B "Boot is 66 MiB."
Below that the kernel says what is wrong rather than wandering: 65 MiB
gives
.CW "panic: no memory"
and 64 MiB gives
.CW "panic: cannot allocate 125 procs (0MB)" ,
which is the proc table sized from what is left.
.PP
.B "This section first said both thresholds were 66 MiB, and that was wrong."
The way it was wrong is worth more than the number.
The second arm typed a command at the console and looked for its output
with
.CW "grep -q WORK-OK" .
A console
.I echoes
what is typed at it, so the token was in the log whether or not anything
ran: the check was answering "were the characters delivered".  It has to
be
.CW "grep -qx" ,
an exact line, which only execution can produce.
.PP
Underneath that, the harness waited for
.CW "bound #S"
before typing, and pc64 prints that well before
.CW /dis/sh.dis
is reading.  Characters typed then are echoed by the console driver and
lost, and the shell starts afterwards and prints its first prompt
.I below
the echo.  Proved by writing explicitly to
.CW /dev/cons
and getting nothing; with the shell's prompt as the token the same
kernel prints
.CW WORKOK
and
.CW /dev/time 's
four fields.  The token must be
.CW "\en; "
and not
.CW ";" ,
because the firmware's ANSI
.CW ( [01;01H )
carries a semicolon in the first line of every boot.
.PP
Two arms of a measurement agreeing exactly is a reason to check the
predicate, not a result.
.PP
.B "Corrected, the two thresholds differ \(em and the boundary is not sharp."
Bisecting 56\-128 gives 66 MiB to boot and 68 MiB to run a command.
Bisecting 66\-68 immediately afterwards gives 67 for both.  That is not
a third answer: the predicate near the boundary is not deterministic, a
bisect assumes the property is monotone, and over a noisy predicate it
returns an arbitrary point inside the noisy band while looking exact.
The script takes
.CW REPS
now and sweeps with repeats instead, which is the only honest way to
say where the edge is.  Three runs at each size:
.PP
.TS
center box tab(;);
c | c | c
n | c | c .
MiB;boots;runs a command
_
65;0/3;0/3
66;3/3;0/3
67;3/3;2/3
68;3/3;3/3
69;3/3;3/3
.TE
.PP
So the boot floor is sharp at 66 MiB and the useful-work floor is 68,
with 67 the band where it depends on the run.  Two megabytes separate
"reaches a shell" from "can run a program in it", and a number quoted
from a single bisect would have landed anywhere in that gap.
.PP
.B "The floor is mostly the image."
The kernel is 9.19 MB with its root compiled in and reserves memory up
to
.CW "MemMin 0xa93000" ,
about 11.1 MB, before any of it is available.  A smaller root moves this
number and a bigger one moves it the other way; 66 MiB is a fact about
this kernel, not about Inferno.
.PP
.B "And it is a fact about one virtual machine."
The first version of this measurement had the two arms on different
hardware without noticing: one passed
.CW "-netdev user -device virtio-net"
and the other let QEMU attach its default e1000e.  With the e1000e the
boot stalls just after
.CW "link up"
at 68 MiB and needs 80 MiB, where the virtio machine runs at 66.  So the
driver is worth more than 10 MiB of the floor, which is a real result,
and "two floors measured on two machines" was not one.  The script now
defines the machine once and both arms use it.
.PP
.B "What it says about density."
Nothing rentable is this small \(em Compute Engine's smallest shapes are
around 0.6 to 1 GB \(em so the number does not buy a cheaper instance
today.  What it measures is headroom: on the smallest shape GCE rents,
this kernel uses under a tenth of the memory before the workload starts.
The cloud-economics claim in item 10 needs the other half, which is how
many useful processes fit in what is left, and that is not measured
here.
.NH 2
Phase 4 items 12 and 13: supervision, and metrics as files
.PP
.B "supervise(1)"
keeps a set of commands running.  Item 12 says this should be a program
and not a kernel change because
.CW /prog
already exposes every process as files, and it is: it opens its own
.CW /prog/ pid /wait
before it spawns anything and blocks reading it.
.CW dis.c 's
.CW newprog()
gives each new process a pointer to its parent's wait queue and
.CW delprog()
posts
.CW "pid \(dqmodule\(dq:cause"
there when it ends.  Nothing is polled.
.PP
Only direct children appear, because a grandchild posts to its own
parent's queue, which is empty unless that parent also opened its wait
file.  That is what makes it a supervisor of the things it started.  It
also has a consequence worth stating rather than hiding: a service given
as a shell command line is supervised as the shell running it, so when
that shell's child is killed the service restarts but the cause reported
is the shell's
.CW exited ,
not the child's
.CW killed .
The console shows
.CW "5 \(dqSleep\(dq:killed"
while
.CW supervise
reports pid 4 exited.
.PP
.B "metricfs(4)"
serves the machine's own numbers as one file per measurement.  Item 13
asks for logs and metrics as a mountable file tree "so that observing a
machine is the same operation as reading one", and that is the whole
design: no scrape endpoint, no exposition format, no metrics protocol at
all.  Each leaf is one column of a file the kernel already keeps \(em
.CW /dev/sysstat ,
.CW /dev/memory ,
.CW /dev/time ,
.CW /dev/kmesg ,
.CW /prog
\(em named, so that a reader does not have to know that
.CW /dev/memory 's
third column is the high-water mark.
.PP
.B "Demonstrated between two machines."
A pc64 kernel under QEMU mounted it, exported it with
.CW "styxlisten -A tcp!*!6666 export /n" ,
and a separate Inferno mounted that over TCP and read the remote
machine's numbers as files:
.CW uptime
83,
.CW cpu/0/intr
11183,
.CW mem/main/used
3804032.  Both processors appear as
.CW /n/cpu/0
and
.CW /n/cpu/1 .
The reading side is
.CW cat .
.PP
.B "A file is offered only if it can be measured."
A leaf exists only when its source can be read, so the tree is smaller
on some machines than others.  A metrics tree that answers 0 for
something it cannot measure is worse than one that omits the file,
because the zero is indistinguishable from a reading.  Under
.CW emu
there is no
.CW /dev/sysstat ,
no
.CW /dev/osversion
and no
.CW /dev/kmesg ,
so those are absent; and there is no uptime, because
.CW emu 's
.CW /dev/msec
reads 0 forever and its
.CW /dev/time
is a wall-clock microsecond count that says nothing about when the
machine started.  The source is chosen by its value, not by whether the
file opens \(em which is a distinction this document has had to learn
twice today.
.NH 2
Phase 4 item 14: deployment with no image build
.PP
Item 14 offers two ways to update a machine \(em republish the image and
recreate the instance, or mount a new
.CW /dis
and restart \(em and says the second is the interesting one.
.CW scripts/check-pc64-redeploy.sh
is the second, in the sharpest form available: the program it runs is
not in the kernel, not in the kernel's compiled-in root, and never
touches the machine's disk.  It is fetched over Styx from another
machine at the moment it is run.
.PP
The deployment side is a directory and
.CW styxlisten .
There is no package format, no image registry and no agent on the
target.  The target does
.IP
.EX
mount -A tcp!host!port /n/remote
bind -a /n/remote /dis
hello
.EE
.PP
and the next command resolves there.  Then
.CW "supervise -n 2 hello"
runs it twice more, which is the "and restart" half: a supervisor that
has never seen the program either keeps it running.  The check requires
all three runs.
.PP
.B "With a negative control, because the alternative is believing it."
Run with the deployment server not started, the same check fails.  That
is what makes the passing run evidence that the mount did the work
rather than something in the image.
.PP
Two details that cost a run each, and both are about the harness rather
than the system.
.CW "bind -b"
puts the remote directory
.I before
.CW /dis ,
so every lookup of every other program asks a server that holds one
file, and the console fills with
.CW "mountrpc: Rerror file does not exist" .
.CW "bind -a"
searches the local
.CW /dis
first and is both quieter and the right meaning for "add programs this
machine does not have".
.PP
And the test could not use an exact-line match for its token, which is
the opposite of the correction two sections above.  The kernel prints
mount diagnostics with no trailing newline, so a program's output can
share a line with them.  A substring match is safe
.I here
for the reason the exact match was needed
.I there :
the token
.CW HELLO-FROM-REMOTE-DIS
does not appear in the command, which says
.CW hello ,
so only the program can produce it.  The rule is not "always use
.CW -x ";
it is that the predicate must be something only the thing under test can
satisfy.
.NH 2
Phase 2 item 7: two machines that have never met
.PP
Item 7 asks for authentication between instances "with a secret fetched
from the metadata service or from object storage, so that two machines
that have never met can agree on who they are".
.PP
Inferno's authentication already has the shape the cloud needs.  It is
mutual and certificate-based: each side holds an
.CW Authinfo
signed by a common signer, exchanges it, and verifies the other against
the signer's public key that its own certificate carries.  Neither side
has to have met the other, and \(em this is the part that matters here
\(em neither has to reach an authentication server while they talk.  On
a provider the instance that has just booted may be the only one
running, and an auth server that must be up before anything else is a
dependency the design does not need.
.PP
So the whole problem is the bootstrap, and the provider already solves
it.  An instance is created with metadata only it can read, served on a
link-local address that asks for no credential of its own.
.CW cloudauth(1)
fetches a certificate from there \(em or from a signed object-storage
URL, or from a file served by
.CW cloudfs(4)
\(em and installs it.
.PP
.B "Demonstrated, with the control that makes it mean something."
.CW scripts/check-cloudauth.sh
generates one signer and two certificates, serves them over HTTP, and
has each party fetch its own with
.CW cloudauth
before doing anything else.  The server runs
.CW styxlisten
and the client
.CW mount ,
neither with
.CW -A .
The client reads the file.
.PP
Then a third party fetches a certificate from a
.I different
signer and is refused:
.CW "mount: authentication failed: pk doesn't match certificate" .
That arm is not decoration.  "The mount worked" is also exactly what it
looks like when authentication is not happening at all, and without a
party that must fail, a passing run is evidence of nothing.
.PP
.B "Where the identity lives on a kernel."
The root is compiled into the image and read-only, so
.CW /usr/inferno/keyring
cannot be written until something writable is bound over it.  On an
instance that is
.CW memfs ,
verified on the booted kernel:
.CW "memfs /usr/inferno/keyring"
and the directory takes writes.  The certificate then lives in memory
and is gone at reboot, which is the right shape \(em the instance takes
its identity from the provider every time it starts, so revoking it is
a metadata change rather than a visit to the machine.
.CW cloudauth ,
.CW memfs
and
.CW styxlib
are in the pc64 root now, with a
.CW /usr/inferno/keyring
to bind over.
.PP
.B "What is trusted."
The certificate carries a private key, so it is exactly as secret as a
password, and putting it in instance metadata makes the provider's
access control the thing protecting it.  That is the same trust the
instance already places in the provider to boot the right image, but it
should be said rather than assumed: anything that can read the
instance's metadata can be that instance.
.PP
.B "Two bugs found getting here, and neither was in the protocol."
Nothing in this tree could generate a signer key at all on a 64-bit
host:
.CW libsec/dsaprimes.c 's
.CW Hrand()
wrote five
.CW ulong s
into a 20-byte seed, which is 20 bytes where
.CW ulong
is 32 bits and 40 where it is 64, and the stack protector aborted
.CW emu
silently.  And
.CW auth/mkauthinfo
computed the output file named in its own usage line and then ignored
it, writing every certificate to standard output.  Both are fixed;
neither is cryptography.
.NH 2
Phase 3 item 8 completed: Styx against a conventional RPC
.PP
The section above left this open in as many words: "what remains
untested is the comparison against a conventional RPC with its own
framing and serialisation, which is the thing a real service would
otherwise use".  It is tested now.
.PP
.CW rpcserve (1)
answers a length-prefixed request that has to be formatted and parsed
on both sides \(em
.CW "GET <offset> <count>"
in, a
.CW "OK <n>"
header and
.CW n
bytes back \(em which is what most hand-rolled RPCs and every
JSON-over-TCP service amount to.
.CW styxbench 's
.CW -r
arm drives it over
.B "one connection, reused" ,
exactly as the Styx and raw arms are.  That detail decides the result:
.CW httpclient (2)
here sends
.CW "Connection: close" ,
so measuring against it would have charged the RPC a new TCP connection
per request while Styx read an already-open fid, and flattered Styx by a
whole connection setup instead of comparing protocols.
.PP
The arm to compare is
.CW jumping ,
not
.CW seq :
it strides far enough that readahead cannot answer one read from
another, so each iteration is a real
.CW Tread
on the wire, which is what an RPC call is.
.PP
.B "On the kernel, Styx is slightly cheaper than the RPC."
Three runs of 300 iterations, pc64 under QEMU serving all three arms,
a hosted client:
.PP
.TS
center box tab(;);
c | c | c | c
n | n | n | c .
raw tcp;styx jumping;rpc framed;styx/rpc
_
7477 us;14010 us;14447 us;0.9
7873 us;14150 us;15077 us;0.9
10050 us;16417 us;18500 us;0.8
.TE
.PP
Hosted, two
.CW emu s
over loopback, the ratio runs the other way and is noisier \(em 1.0,
1.4, 1.3, 1.2 across four runs \(em which is what one would expect when
the Styx server is a Limbo program rather than the kernel's own
.CW exportfs .
Taken together: a Styx round trip and a conventional framed RPC cost
about the same, within a factor of about one and a half in either
direction, and on the kernel Styx is the cheaper of the two.
.PP
.B "This settles the first of the three falsification criteria."
The claim was that "if Styx round-trips cost several times a
conventional RPC on the same network, the file abstraction is too
expensive for the thing it is meant to replace".  They do not.  They
cost about the same thing, and the mounted namespace is had for free.
.PP
.B "What this measurement is not."
The absolute numbers are QEMU user-mode networking and mean nothing
outside it; only the ratios are claimed, and both arms cross the same
path in the same run.  Both ends are Inferno, so this is not "Styx
versus a service on Linux" \(em it isolates protocol cost with the
runtime held constant, which is the narrower and more answerable
question.  The cross-stack comparison item 8 also asks for still wants
two rented instances.
.NH 2
Phase 3 item 9 begun: where a cold start actually goes
.PP
Item 9 wants boot-to-shell against a minimal Linux image on the same
instance shape.  The comparison needs two rented instances and a Linux
image; what can be had now is the Inferno half, measured properly, and
it turned out to be worth having on its own.
.PP
.B "The guest cannot time its own boot."
The obvious method \(em read
.CW /dev/time
at the prompt \(em is wrong here.  pc64's tick counter runs from machine
reset, so it counts the firmware as uptime.  Measured rather than
assumed: the kernel's uptime at the prompt agrees with the host's own
clock from the moment QEMU was launched, to within the harness's settle.
So the timing has to come from outside, and
.CW scripts/boot-profile.py
does it \(em every console line stamped with seconds since launch and
the gap since the previous line, so a stall is one large gap rather than
something inferred from a total.
.PP
.B "Half the kernel's boot was a test."
The largest single gap in the profile was 6.4 seconds in
.CW regtorture ,
a register torture test, on a boot whose entire kernel half was 14.6.
It was written for the interrupt heisenbug that
.CW _intrcommon 's
.CW AX=0
turned out to be; that is fixed, and the instrument had been running on
every boot since.  Its own comment said two million iterations "cost
under two" seconds, which was true when written and is not now \(em a
number in a comment that nothing re-checked.
.PP
It is now behind
.CW *regtorture=1
in plan9.ini rather than deleted: it is the reproducer for a class of
bug that cost this branch weeks, and keeping it costs nothing when it
is not asked for.  Verified both ways \(em with the flag it reports
"12 registers survived 2M iterations over 479 ticks, control clean" and
costs 6.47 seconds; without it, it does not run at all.
.PP
.B "The numbers."
Three runs each, one machine, OVMF firmware:
.PP
.TS
center box tab(;);
c | c | c | c
l | n | n | n .
;firmware;kernel+init;total
_
before;6.4\-7.5 s;14.6\-15.1 s;21.0\-22.6 s
after;7.1\-8.8 s;10.1\-11.0 s;17.4\-19.8 s
.TE
.PP
The firmware half is OVMF and is not this tree's to improve; it is
reported separately for that reason, and because a cloud instance runs
different firmware and will not pay the same.  What remains on the
kernel side after
.CW regtorture
is 4.5 seconds around Dis start-up, where the profile shows
interpreters queueing on the VM lock, and 1.8 seconds at
.CW "Initial Dis" .
Those are the next things to look at and have not been.
.PP
.B "And the premise has drifted."
Item 9 says "a 2.1 MB image with its root compiled in".  The kernel is
9.2 MB now, because this branch's own work \(em TLS, the cloud
commands, metricfs, supervise, cloudauth \(em is in that root.  The
cold-start argument is still a real one, but it should be made about
the image that exists rather than the one the plan was written about.
