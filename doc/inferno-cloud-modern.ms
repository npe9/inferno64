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
