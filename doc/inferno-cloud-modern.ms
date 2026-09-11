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
Phase 2 so far: the listening half works, styxlisten does not
.LP
Item 5 is
.CW styxlisten
in the root and a service that exports a namespace.  The root now
carries
.CW styxlisten
and
.CW export ,
and the piece underneath them is proved: nothing this branch had
written for the cloud ever listened \(em
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
run them: with a forwarded port, a client on the host connects to the
kernel and reads back
.CW INFERNO-ACCEPTED-YOUR-CONNECTION .
.PP
.CW styxlisten
itself does not yet serve, and the shape of the failure is recorded
here rather than guessed at.  It prints no diagnostic \(em not its own
.CW "cannot announce on" ,
which is the only thing it says when
.CW dial->announce
fails \(em and no listener appears in
.CW /net/tcp ,
with or without
.CW -s ,
whose synchronous path keeps the listener in the foreground.  With a
command that exits immediately
.CW ( "styxlisten -A tcp!*!6666 echo hi" )
the command runs and the shell returns, so
.CW popen()
is reached, which puts the failure after the announce rather than
before it.  The same address under
.CW tcpserve
announces and accepts without trouble, so it is not the address and it
is not the stack.
.PP
The next thing to look at is
.CW dial->netmkaddr(addr,
.CW "tcp" ,
.CW "styx") ,
which is the one transformation
.CW styxlisten
applies and
.CW tcpserve
does not.
