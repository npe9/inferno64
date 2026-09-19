.TL
Running the multicore kernel on real processors
.AU
.NH 1
Why
.PP
Everything this branch has established lately is counted in events:
panics, boots to a shell, stopped-world audits, whether a processor
runs a Dis quantum.  Those do not depend on how fast the host is or
what else it is doing, and they stand.
.PP
One question is not like that, and it is the one left open:
.I "does the parallel Dis VM buy throughput" .
It has been answered badly twice on this laptop.  A seven per cent
figure was committed and then withdrawn, and the
.CW nwoken
spawn gate's "about a sixth fewer cycles" was not reproduced, both for
the same reason \(em this machine runs other sessions' QEMU guests,
four at once on one occasion with one of them at 322 per cent of a
processor.  Alternating arms and discarding contended boots narrows it;
it does not fix that every guest processor here is a thread on a host
that has its own ideas.
.PP
The
.CW cloud-port
branch already boots this kernel on Google Compute Engine, on real
hardware, with the processors the instance actually has.  That is the
instrument this question wants.  The work is to get the multicore
scheduler onto that path.
.NH 1
What the two branches hold
.PP
Merge base
.CW f55c7251 ;
.CW multicore
is 85 commits past it and
.CW cloud-port
170.  The base already contains the shared Dis VM work, because
cloud-port took a snapshot of it in September as an ordinary commit \(em
so this is not a re-import, it is two lines of development from a
common core.
.PP
Eighteen files are touched on both sides.  The ones that matter, in
lines changed against the base:
.IP
.nf
                              multicore   cloud-port
os/inferno/port/dis.c            1497         121
libinterp/gc.c                    684          59
libinterp/xec.c                   250          49
os/inferno/pc64/main.c             78         115
os/inferno/virtarm64/main.c       251         263
.fi
.PP
The shape of that table is the whole merge in miniature.  The Dis
scheduler and collector are multicore's, overwhelmingly, and cloud-port
has only tweaked them; the board files are genuinely contested, and
.CW virtarm64/main.c
most of all \(em both branches wrote arm64 secondary bring-up, in
different files, neither aware of the other.
.PP
What cloud-port has that multicore needs is mostly in files multicore
has never touched:
.IP
.nf
os/inferno/boot/efi/{efi.c,sub.c,aa64.s,fns.h,mkfile}   a UEFI loader
tools/aout2efi.c                                        a.out -> EFI
scripts/mkinferno-efi-disk.sh                           a raw GPT disk
scripts/mkinferno-efi-iso.sh, qemu-inferno-efi.sh       local testing
scripts/gce-console.py, gce-boot-stamp.py               the harness
os/inferno/virtarm64/virtarm64cloud{,.c}                an arm64 config
.fi
.PP
.CW "os/inferno/pc64/pc64"
on cloud-port already carries
.CW mp ,
.CW apic
and
.CW squidboy ,
so that kernel brings up the instance's processors.  It has been seen
to fault once in six runs in the TCP ack path on a second processor \(em
which is a real-hardware SMP bug, and exactly the kind of thing this
exercise is for.
.NH 1
Two routes, and which one first
.PP
.B "Route 1, the graft: take the boot machinery, leave the rest."
Every file in the list above except the two board files is one
multicore has not modified, so taking them conflicts with nothing.  The
kernel being packaged is multicore's own
.CW ipc64 ,
with its scheduler, its interpreter ceiling and its collector.  No
userland comes across, because a soak benchmark needs no network: the
workload is
.CW chantest
and
.CW sh ,
the output is the serial console, and Compute Engine hands that back
without the guest having an address.
.PP
.B "Route 2, the merge: reconcile the two lines properly."
Eighteen files, of which five need real thought and one \(em
.CW virtarm64/main.c
\(em needs a decision about whose arm64 bring-up survives.  This is
where the tree ends up, and it brings the cloud userland with it
.CW ( cloudinit ,
.CW cloudfs ,
.CW gcs ,
TLS).
.PP
Route 1 first, because it answers the question in days rather than
weeks and because its failures are informative on their own.  Route 2
after, with Route 1's boot experience in hand.
.NH 1
Route 1, step by step
.PP
Each step says what proves it.
.IP 1.
.B "Graft the boot machinery onto a branch off multicore."
Take the files, not the commits: the commits that introduced them also
touch
.CW os/inferno/pc64
files that multicore has changed (the e820 fix in
.CW 6888cb29
is the example), so a cherry-pick will conflict where a file copy will
not.  The pc64-side fixes those commits carry have to be read and
applied by hand, which is a small, bounded reading job.
.I Proves :
.CW "mk bootx64.efi"
builds and
.CW scripts/mkinferno-efi-disk.sh
writes a disk image.
.IP 2.
.B "Boot that image locally, under OVMF."
.CW scripts/qemu-inferno-efi.sh
exists for this.
.I Proves :
the multicore kernel reaches the same markers through the UEFI path
that it reaches today through
.CW "qemu -kernel" .
This is the step that separates "the loader works" from "the kernel
works on this path", and it costs nothing.
.IP 3.
.B "Make the image and boot it on Compute Engine."
.I Proves :
the serial console shows the boot markers, and
.CW "smp: N processors"
matches the instance's vCPU count \(em which is the same
.CW conf.nmach
the interpreter ceiling is sized by.
.IP 4.
.B "Check the real-hardware prerequisites the scheduler leans on."
The clock especially: cloud-port found that pc64 never called
.CW todset(rtctime())
though the hardware always had it, and that
.CW daytime->now()
divided by a million on a native kernel.  A scheduler measured against
a clock that does not tick is not measured.
.I Proves :
uptime advances, and the soak line's tick count matches wall clock.
.IP 5.
.B "Then, and only then, the measurement."
The soak workload at 1, 2, 4 and 8 vCPUs, with
.CW *parallelvm
0 against 1 and
.CW *spawncap
0 against 1, alternating arms, counting completed
.CW chantest
runs and quanta per processor.  On a machine with nothing else on it,
and with
.CW "pgrep qemu"
no longer a thing that needs checking, because there is no QEMU.
.IP 6.
.B "Decide the parallelvm default on the numbers."
That is the item this branch has been carrying unanswered.
.NH 1
What will go wrong, so it is not a surprise
.PP
.B "Real hardware runs paths TCG never did."
cloud-port's one-in-six SMP fault in the TCP ack path is the existing
evidence.  Expect more, expect them in the kernel rather than in Dis,
and treat each as the point of the exercise rather than an obstacle to
it.
.PP
.B "The arm64 halves have to be reconciled, and not by merging blindly."
multicore starts every processor PSCI offers and runs Dis on four of
them under QEMU; cloud-port boots
.CW virtarm64cloud
on a real t2a with a gVNIC driver and a
.CW screennone
console.  Those are complementary, not competing, but they were written
in the same file.  The arm64 bare-metal run is worth having \(em Ampere
gives sixteen real processors where an n2 gives eight \(em and it is a
second piece of work, after amd64 has produced a number.
.PP
.B "Nested virtualisation is not a substitute and was tried."
An n2-standard-8 with
.CW --enable-nested-virtualization
has
.CW /dev/kvm ,
and QEMU on it would give each guest processor a real core.  It is
still a guest inside a guest, it still needs QEMU's device model, and
it answers a question one step removed from the one being asked.  It is
the fallback if the UEFI path fights back, not the plan.
.PP
.B "Cost is small but not zero."
An n2-standard-8 is about forty cents an hour and the batches are
minutes.  Instances and custom images are deleted when the run ends;
an idle instance left running is the only way this gets expensive.
