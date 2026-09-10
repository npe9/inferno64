.TL
Inferno on rented metal
.AU
.PP
This is the plan for getting
.CW os/inferno/pc64
onto the machines a cloud provider rents, written after the round that
made the tree's own UEFI loader build and boot the kernel.  It says
which providers will let a stranger's operating system near their
hardware and which will not, what each one demands before it will boot
anything, what this tree already has, and the order the missing pieces
unlock each other in.  Every claim about the tree here was run, not
remembered; every claim about a provider is either cited to its
documentation or marked as unconfirmed.
.NH 1
What is actually rentable
.PP
"Bare metal in the cloud" is four different products wearing one name,
and only two of the five large providers sell a version of it that
will boot an operating system they have never heard of.
.IP "\f(CWAWS\fP" 12
.CW *.metal
instances are real machines and take a custom operating system, but
not by uploading an ISO: the route in is a raw disk image written to
S3, imported as an EBS snapshot and registered as an AMI.  The
VM Import path proper rejects a guest it cannot identify, so the
snapshot route is the one that works.  Every Nitro machine, virtual
and metal alike, presents exactly two device families: ENA for the
network and NVMe for storage.  There is no fallback NIC.  EC2 Serial
Console has been generally available on bare-metal instances since
April 2023, which is the console this port will live on.
.IP "\f(CWOCI\fP" 12
Oracle rents genuine bare-metal shapes and is the friendliest of the
five: it takes a Bring Your Own Image custom image, and it also lets
an instance boot from a
.I custom
iPXE script supplied at launch, which is the shortest path from a
build on a laptop to a running kernel on someone else's hardware.  The
catch is that an OCI bare-metal instance's boot volume is iSCSI \(en
the default iPXE script attaches
.CW iqn.2015-02.oracle.boot
at
.CW 169.254.0.2
\(en so a kernel that wants to boot from its own disk needs an iSCSI
initiator before it needs anything else.  A kernel whose root is
compiled into the image, which is what
.CW os/inferno/pc64/pc64 's
.CW root
section builds, does not, and that is the reason to go this way first.
.IP "\f(CWGCP\fP" 12
Bare Metal Solution is not a general-purpose product.  It is an
allowlist-only colocation offering aimed at Oracle databases, its
servers are certified for a fixed list of distributions, and anything
else needs Google Cloud Sales to agree.  There is no honest bare-metal
target here.  The achievable GCP target is a Compute Engine virtual
machine, and it is a good one: it is UEFI, and its default NIC is
virtio-net, which this tree already drives.
.IP "\f(CWAzure\fP" 12
BareMetal Infrastructure is the same shape as Google's: SAP HANA and
Oracle workloads, with the operating system chosen from Microsoft's
list at provisioning.  The achievable Azure target is a Generation 2
virtual machine, and it is the most expensive of the three to reach,
because an Azure guest talks to no PCI device at all for its disk or
its network.  It talks to Hyper-V's VMBus, and needs
.CW hv_vmbus ,
.CW storvsc
and
.CW netvsc
\(en a bus driver and two class drivers \(en before it sees a byte.
.IP "\f(CWEquinix\ Metal\fP" 12
Was the right first target, and is gone: the service was sunset on
30 June 2026 and its documentation is scheduled for removal on
30 September 2026.  Its custom-iPXE flow is what the OCI plan below
imitates.  Do not start here.
.PP
Below the five, the providers that simply hand over the machine are
where the first real bare-metal boot should happen, because none of
them require a driver this tree does not have:
.CW Hetzner
dedicated servers (a KVM-over-IP console with virtual media, or, with
no KVM, the rescue system running
.CW qemu-kvm
against an ISO and
.CW dd
to the disk),
.CW Vultr
Bare Metal (a custom ISO, written to the second SSD \(en it must be a
.I hybrid
image, which the ISO this tree builds is not yet),
.CW Scaleway
Elastic Metal,
.CW OVHcloud ,
.CW phoenixNAP
and
.CW Latitude.sh .
The last four are unconfirmed here and should be checked against their
own documentation before one is rented.
.NH 1
What the tree does today
.PP
All of this was run on 7 September 2026 against a kernel built from
this branch, not taken from the record.
.PP
.B "pc64 boots through UEFI."
The loader is
.CW os/inferno/boot/efi ,
which is 9front's
.CW efiboot
already sitting in this tree, and which nothing had built.  It builds
now, and under edk2 (OVMF) on QEMU q35 it reads
.CW cfg/plan9.ini ,
builds
.CW *acpi ,
.CW *bootscreen
and a
.CW *e820
line out of the UEFI memory map, calls
.CW ExitBootServices
and jumps into the
.CW a.out
kernel.  The kernel reaches
.CW "Welcome to Inferno..." ,
binds every device, and loads
.CW /dis/sh.dis .
.CW scripts/mkinferno-efi-iso.sh
builds the image and
.CW scripts/qemu-inferno-efi.sh
boots it.  This matters more than it sounds: the multiboot header in
.CW os/inferno/pc64/l.s ,
which is what
.CW os/inferno/pc64/qemu-boot.sh
uses, is reachable only from QEMU's own
.CW -kernel
loader or a multiboot boot loader, and no provider offers either.
Until this round there was no path onto any of the hardware in
section 1.
.PP
Which firmware a provider offers is not uniform, and the plan should
not assume it is.  AWS reports the boot modes of an instance type
through
.CW "describe-instance-types" ,
and the Xen generations answer
.CW legacy-bios
alone \(en
.CW t2.xlarge
is the example in AWS's own documentation \(en while Nitro types
generally answer both.  So UEFI is the way onto a modern machine and
onto every second-generation cloud VM, but it is not the only firmware
in the field, and
.CW os/inferno/boot/pc
\(en the BIOS loader, the third one in this tree, also unbuilt \(en is
what a legacy-BIOS-only instance needs.  It has not been built or
booted here.
.PP
.B "The image shapes the providers take."
.CW scripts/mkinferno-efi-iso.sh
builds a UEFI ISO, which is what a KVM-over-IP console with virtual
media mounts.
.CW scripts/mkinferno-efi-disk.sh
builds the other one, and it is the one that matters: a raw disk with a
GPT and an EFI system partition holding the loader, the kernel and
.CW plan9.ini .
That single image is what AWS imports as an EBS snapshot and registers
as an AMI, what Compute Engine takes as
.CW disk.raw
inside a gzipped tar (which the script writes when
.CW INFERNO_GCE_TAR
names one), what OCI's Bring Your Own Image takes, and what a rented
machine in rescue mode
.CW dd s
to its disk.  Verified: the image boots under edk2 on QEMU q35 from a
virtio-blk disk \(en no CD, no multiboot \(en to an interactive shell
prompt at 128 MiB, and into
.CW /dis/init
at the 1 GiB Compute Engine insists on (its importer wants a whole
number of gigabytes, the file named
.CW disk.raw ,
and the archive in the old GNU tar format, all of which the script now
produces; the archive itself has not been through that importer, only
the disk inside it has been booted).
.CW scripts/mkgptdisk.py
writes the partition table, because a Mac has no
.CW sgdisk ,
.CW gdisk
or
.CW parted
and the layout is too small to take a dependency for.
.PP
.B "PXE is built and still untested."
.CW os/inferno/boot/efi/pxe.c
compiles and links into the loader, and would fetch
.CW /cfg/pxe/<mac>
or
.CW /cfg/pxe/default
over TFTP and then the kernel named by
.CW bootfile= .
It could not be exercised here: the edk2 firmware available on this
host has no network stack compiled in, so it offers no network boot
entry at all and drops to the EFI shell whether or not QEMU is given a
UEFI option ROM for the NIC.  Testing it wants an OVMF built with
NetworkPkg.  This matters for OCI, whose custom-iPXE flow is the
cheapest way onto its bare metal.
.PP
.B "MSI was already wired; MSI-X is now."
.CW os/inferno/port/pci.c
had
.CW pcimsienable
and
.CW pcimsidisable ,
and
.CW os/inferno/pc/mp.c 's
.CW mpintrassign
tries MSI before the INTx path, gated on
.CW *nomsi ,
so any driver calling
.CW intrenable
with a PCI
.CW tbdf
already got a single MSI vector under
.CW archacpi
without doing anything.  What did not exist anywhere in
.CW os/inferno
was MSI-X, and it does now:
.CW pcimsixcount
reports how many vectors a device's table holds and
.CW pcimsixenable
.CW vmap s
that table out of the BAR its capability names and writes one 16-byte
entry.  That is the whole difference from MSI \(en the message lives in
the device's own memory rather than in configuration space \(en and it
is what a part with no INTx pin and no MSI capability needs.
.PP
.CW mpintrassign
takes MSI-X only when
.CW *msix
is set in
.CW plan9.ini ,
and the reason it is not the default was measured rather than assumed.
With
.CW *msix=1 ,
.CW ipc64dev
on QEMU q35 reports
.CW "msix: sdN (nvme) ... enabled"
and then reads back the sector the host wrote into the NVMe disk, so
MSI-X really carries that completion interrupt; on the same boot the
virtio NIC also takes a vector and then never interrupts again, and
DHCP fails, because a virtio-pci device sends nothing until its driver
has written a vector into its own
.CW queue_msix_vector
register.  Turning MSI-X on underneath a driver that does not know
about it silences the device.  So the flag exercises the plumbing, and
a driver that wants MSI-X \(en ENA, one vector per queue \(en is
written against
.CW pcimsixcount
and
.CW pcimsixenable
directly.
.PP
.B "The drivers that are linked."
.CW pc64
carries
.CW ether82563 ,
.CW etherigbe ,
.CW etheri225 ,
.CW etherx550 ,
.CW ether82598 ,
.CW etherbcm ,
.CW etheryuk ,
.CW ether8169 ,
.CW ether8139 ,
.CW ethervirtio
and
.CW ethervirtio10
for the network;
.CW sdnvme ,
.CW sdiahci ,
.CW sdvirtio ,
.CW sdvirtio10
and
.CW sdmmc
for storage;
.CW usbxhcipci ;
and reaches PCIe configuration space through the ACPI MCFG window.
Between them that is enough silicon to drive a Hetzner or Vultr box
without writing a line of driver code.  It is not enough for any of
the five large providers.
.PP
.B "Boot stability."
Three sets of ten boots of the same kernel, counted the same way \(en a
run counts only if the log ends at the shell's
.CW ;
prompt:
.IP
.nf
\f(CW-kernel\fP, 512 MiB     6 prompt   2 panic   2 module load failed
\f(CW-kernel\fP, 1 GiB       6 prompt   4 panic   0
UEFI ISO, 1 GiB       4 prompt   4 panic   2 module load failed
PVH ELF, 1 GiB        3 prompt   2 panic   1 module load failed  (of 6)
.fi
.PP
The comparison
.CW doc/inferno-ports.ms
records is fifteen crashes out of fifteen, and the difference is not a
kernel fix: it is that
.CW dis/init
carried a three-hundred-iteration
.CW "sh -n -c 'true'"
loop marked TEMPORARY from that hunt, and
.CW true
is not in
.CW pc64 's
root, so every boot spun on the error and drove the allocator into the
fault.  Reverted.
.PP
What is left is one bug, not several.  Every failure in all thirty runs
is the Dis heap:
.CW "movp: bad dv" ,
.CW "alloc:D2B:destroy-entry" ,
a page fault on a pointer read out of a corrupted object, a general
protection violation, and the two quieter shapes \(en
.CW "cannot load /dis/lib/styx.dis: file does not exist"
and a module whose type signature no longer matches \(en which are the
same corruption landing on a name or a tag rather than a pointer.  A
run that fails that way does not panic, which is why counting panics
alone overstates how often a boot succeeds.
.PP
Four in ten on the UEFI path against six on the other, at the same
memory size, is the only difference between them, and ten runs is not
enough to say it is real rather than noise.  If it is real, the likely
reason is that the UEFI path has a framebuffer: the loader hands over
.CW *bootscreen ,
.CW bootscreeninit
draws through
.CW imagmem ,
and the image pool is exercised before
.CW /dis/init
ever runs, where under
.CW -kernel
it is untouched.  That is worth knowing because every cloud machine
hands over a framebuffer, so the port will live on the busier of the
two paths.
.NH 1
The three bugs the UEFI path found
.PP
Recorded here because each is the kind that only appears off the
emulator's beaten path, which is the whole risk of this port.
.IP 1.
.CW os/inferno/pc64/memory.c 's
.CW meminit
assigned
.CW memmapalloc 's
result back to the variable it was walking the memory map with.  On
the \-1 failure path the loop step then restarted from
.CW "memmapnext(-1, MemRAM)"
\(en the first entry again \(en and never terminated.  A multiboot
memory map never took that path.  A UEFI one takes it on the first
entry, so every EFI boot hung there printing
.CW "base == -1"
forever.
.IP 2.
.CW os/inferno/port/alloc.c 's
.CW poolsize
sized its contiguous probe as the whole pool, which fits only while
nothing has been allocated from that pool yet.  Every UEFI machine
hands over a framebuffer, so
.CW bootscreeninit
has already drawn through
.CW imagmem
by then; the request could not fit under
.CW maxsize
and the kernel panicked
.CW "poolsize: don't have 202468352 bytes"
on a machine with a gigabyte free.
.IP 3.
.CW os/inferno/boot/efi/mkfile
named
.CW 9front/386/include
and
.CW 9front/amd64/include ,
an
.CW os/inferno
build rule reaching into another flavour's target tree.  The loader
needs only
.CW <u.h>
and
.CW <a.out.h> ,
both of which Inferno has.
.PP
A fourth was latent and is fixed here.
.CW os/inferno/boot/efi/efi.c 's
.CW memconf
emitted one
.CW *e820
range per UEFI memory descriptor, with no end pointer at all, into a
boot-argument area that is
.CW BOOTARGSLEN
\(en
.CW 4096\-0x200\-64 ,
3520 bytes \(en sitting hard against
.CW REBOOTADDR
at
.CW 0x2000 .
Each range costs 36 bytes in that fixed-width format, so about
ninety-seven of them fill the area and anything past that runs into
the reboot code.  That was never reached here and is not a fault
anyone has seen: QEMU's map is small, and no map from a real machine
has been measured in this tree.  It is an unbounded write against a
fixed 3520 bytes, which is enough reason to bound it before the first
machine is rented rather than after.
.CW memconf
now merges adjacent descriptors of the same kind into one range and
stops at an entry boundary before
.CW confmax ,
so a map too large to fit leaves the kernel's
.CW e820scan
a short but parseable line instead of a corrupted low memory.  On QEMU
q35 with a gigabyte the map merges to 27 ranges, 977 bytes, and the
kernel finds the same 1012346880 bytes it found before the change.
.PP
One observation in the logs is worth writing down so it is not
mistaken for a bug next time: the
.CW "Boot configuration"
dump appears to cut the
.CW *e820
line off in the middle of a number.  That is
.CW PRINTSIZE
in
.CW os/inferno/port/portdat.h ,
1024 bytes, clipping one
.CW print
call.  The configuration value itself is whole, and
.CW e820scan
parses all of it.
.NH 1
The heap fault, and what a capture is worth
.PP
Item 1 is not closed.  What this round added is three things about it
that were not known, and one about the instrument rather than the bug.
.PP
.B "A new signature, on the Chan side."
.CW "panic: cclone: c 0xae0d40 ref 0 flag 0x10" ,
where
.CW 0x10
is
.CW CFREE
\(en a Chan on the free list \(en with the caller pc resolving through
the kernel's own symbol table to
.CW cunique+0x30 ,
which is
.CW namec 's
.CW Aopen
path.  So a Chan that
.CW namec
is still holding gets released underneath it.  That is not the Dis
heap, and it is the first time this fault has been seen on the kernel's
own reference counts.
.CW os/inferno/port/chan.c 's
.CW chanok
now asserts the Chan is live at
.CW namec:after-walk ,
.CW namec:before-domount ,
.CW namec:after-domount
and
.CW cunique:before-cclone ,
so the next occurrence names the step rather than the victim.  It has
not fired in twelve boots since.
.PP
.B "The Dis side, from the allocator's own record."
.CW alloc:D2B:destroy-entry
with
.CW _poolfault
reporting the same block freed twice from the same pc, once under
module
.CW $Sys
and once under
.CW Sh .
The pc resolves inside
.CW destroy
both times.  Neither signature reliably precedes the other in a log:
in three failures the Dis one was first with no Chan complaint before
it, and in the fourth the Chan one was first with no Dis complaint.
They are not obviously one causing the other.
.PP
.B "The fault moves when the code moves."
Twelve boots of the kernel before
.CW chanok
was added reached a shell four times; twelve of the same kernel with it
added reached a shell nine times, and the failures changed shape
.CW ( "dup pid" ,
.CW "movp: bad sv" ,
a page fault, where before they were
.CW destroy-entry
and
.CW cclone ).
Adding an assertion cannot fix a refcount bug.  What that says is that
the fault is sensitive to layout or timing, and the practical
consequence is a warning: a change that only moves code around will
look like a fix on a twelve-boot sample and will not be one.  Nothing
here should be called fixed on a boot count alone.
.PP
.B "A tracker report is not by itself evidence."
One boot printed three
.CW "track: CHANGED TO BAD VALUE"
reports and then reached the shell prompt normally.  Their "old" values
decode to ASCII shell text and the
.CW Type
they name reported
.CW "size 10 np 10"
on the first report and
.CW "size 0 np 0"
on the next two \(en freed and reused memory that the tracker's
.CW typetagp
staleness check did not catch.  The capture this section's first
paragraph rests on is not of that kind: a
.CW "movp: bad dv 0"
panic on the same address followed it immediately.  That is the test to
apply.  A
.CW track:
line with no panic on the same address behind it is noise, and chasing
one costs a round.
.PP
One hypothesis is ruled out rather than left open:
.CW os/inferno/pc64/l.s 's
.CW _clearbss
does clear
.CW edata
to
.CW end
before
.CW main ,
so an unzeroed BSS is not why
.CW proghash
held a process at the first
.CW newprog .
It rounds the count down to a whole number of doublewords, so up to
three bytes at
.CW end
are left, which is not enough to matter and is noted so it is not
re-derived.
.PP
.B "A deterministic trigger, on a board that boots every time."
The ndb work of section 10 turned one up by accident.
.CW os/inferno/virtarm64/virtarm64ndb
running
.CW os/inferno/init/ndbinit.b
prints exactly nine
.CW "track: CHANGED TO BAD VALUE"
events, and two runs of the same kernel produce the identical sequence
of events \(em same checkpoints, same instruction, same object types
and word indices, differing only in addresses.  The plain
.CW virtarm64
kernel booting to a shell prints none.  So the workload, not the boot,
is what provokes it, and the board it provokes it on reaches its
prompt every time, which is the opposite of
.CW pc64 's
one boot in twenty-four.
.PP
All nine have
.CW "diff 0x18" ,
which
.CW libinterp/heap.c 's
own comment says means the tracked object is a
.CW Frame ;
seven fire at
.CW "checkpoint instr"
inside
.CW Styx
and
.CW Daytime ,
and two at
.CW readmod:after-parsemod
and
.CW freemodlink:after-unload
around a
.CW load
of
.CW /dis/ndb/query.dis .
Two of them record a word going from
.CW -0x1
to
.CW 0 ,
which is not a pointer value at either end.
.PP
All nine were the instrument, and the reproducer is what made that
answerable in one experiment instead of a boot batch.
.CW libinterp/heap.c 's
own comment above
.CW NTRACK
predicted the channel and left it open: "\c
.CW trackclear()
only runs on
.I creation ;
nothing runs on teardown".  The
.CW typetagp
validation added for the first stale-registration capture only catches
the case where the next occupant of the memory overwrites
.CW &f->t ;
a frame built at a different base leaves that word alone, so the
registration survives and the next write anywhere in the dead frame's
range is reported against a frame that returned long ago.
.PP
.CW freeptrs
is the one place both callers \(em
.CW OP(ret)
and
.CW OP(mcall) 's
native branch \(em pass through at the moment a frame stops existing,
and it has the frame and its Type in hand.  One
.CW trackclear(v,
.CW t->size)
there and the nine events become none, with every assertion of the ndb
test still passing.  That is the second channel closed the way the
first was, and it removes false positives from every board the tracker
runs on, not just this one.
.PP
.B "What the quiet instrument then caught."
Twelve boots of
.CW pc64
rebuilt on top of it, on
.CW "qemu-system-x86_64 -kernel ipc64.elf -append console=0" ,
printed one
.CW track:
event in total \(em and that one is real.  Eight of the twelve reached
a prompt, and the three that did not failed with
.CW "panic: general protection violation" ,
.CW "panic: page fault"
and
.CW "panic: movp: bad sv 0x0" .
The
.CW movp
one is the boot that carries the event, four instructions ahead of it:
.IP
.DS L
.CW
track: CHANGED TO BAD VALUE addr 0xb283c0 old -0x1 new 0x0 regpid 1 checkpoint kopen:after-newfd
track: instruction that just ran: PC 0xb2a920 op 0x09 add 0x48 module Init pid 1 inst 292
track: object 0xb28368 word 11, type 0xb2b0c0 size 128 np 2 map 0x00 0xb1
track: R.FP 0xb28368 R.SP 0xb283e8 R.MP 0xdf674d0 R.d 0xdf67698
movp: bad sv 0, running Dis pid 1 module Init PC 0xb2a998 inst 296
.R
.DE
.PP
That is not a stale registration:
.CW "R.FP 0xb28368"
is the object's own base, so the frame that owns the word is the one
executing.
.CW "old -0x1"
is
.CW H
\(em
.CW include/interp.h
defines it as
.CW "((void*)(-1))"
\(em so a declared pointer local that was nil became
.CW 0 ,
and four instructions later
.CW movp
read it and panicked on the same address.  Word 11 is at frame offset
88, past the four header words, and the map byte
.CW 0xb1
does mark it a pointer.  The checkpoint is inside
.CW kopen ,
which
.CW os/inferno/port/inferno.c 's
.CW Sys_open
reaches across a
.CW release() / acquire()
pair \(em the one window in that call where this process is not
holding the interpreter and another Dis process, or the collector, can
run.  Nothing in
.CW Sys_open
writes
.CW 0
to
.CW "*f->ret" ;
it writes
.CW H
and then
.CW mkfd .
Where the zero comes from is the next thing to find, and the boot that
produces it now prints one line instead of a page.
.PP
.B "A second branch's numbers, at a scale this one did not run."
The multicore branch measured the same kernel either side of the fix,
96 boots each, same command line and same timeout, each batch confirmed
to be a single build by
.CW etext .
Before: 82 of 96 panicked.  After: 2 of 96.
.IP
.DS L
.CW
                                before  after
  no panic                          14     94
  page fault                        26      0
  general protection violation      20      2
  movp: bad sv/dv                   13      0
  alloc:D2B:destroy                  5      0
  invalid opcode                     4      0
  incref/decref: bad r               4      0
  cclose / cclone                    3      0
  smalloc: huge size                 1      0
  assert failed: m                   1      0
  freetype: static Type underflow    3      0
.R
.DE
.LP
Every signature that branch had been chasing is gone but two general
protection violations, which resolve to
.CW modstatus+0x18
faulting on a non-canonical pointer whose upper half is the real-mode
BIOS stub
.CW F000:FF53
\(em a different and far rarer bug, two samples, not theorised about
there or here.  The three
.CW freetype
hits are the interesting confirmation:
.CW Tptr
and
.CW Tlist
are file-scope statics in
.CW libinterp ,
so a pointer landing on
.CW Tptr+0x0
is what a slot holds when it never held a heap pointer at all, and
they went to zero with everything else.  That branch also reports
.CW "-smp 2"
booting with
.CW cpu1
up, which follows: the APs come up through the same
.CW _intrcommon
and were losing
.CW AX
on every interrupt too.
.PP
The eight-in-twelve is
.I not
offered as evidence that anything was fixed.  Section 3.1 of
.CW doc/inferno-platforms.ms
says why: the same kernel has measured one in twenty-four and nine in
twelve.  What changed measurably is the instrument's noise floor, from
nine deterministic false positives per arm64 run and a page per
.CW pc64
boot to zero and one.
.PP
.B "The bug, and how the quiet instrument found it."
Six captures came out of twenty-five boots on the build with those
extra checkpoints, and read side by side they say something none of
them says alone:
.IP
.DS L
.CW
b4  addr 0xb296b8 old -0x1 new 0x18 op 0x10 R.d 0xb296b8 module Sh
b6  addr 0xb296b8 old -0x1 new 0x18 op 0x10 R.d 0xb296b8 module Sh
b23 addr 0xe178e28 old -0x1 new 0x18 op 0x10 R.d 0xe178e28 module Sh
b5  addr 0xb29860 old 0xdf6c3d0 new 0x0 op 0x71 R.d 0xb29860 module String
b7  addr 0xb29708 old -0x1 new 0x0 op 0x53 R.d 0xb29708 module Env
b15 addr 0xb297c0 old -0x1 new 0x0 op 0x51 R.d 0xb297c0 module Sh
.R
.DE
.PP
In every one the corrupted address is
.CW R.d ,
the destination of the instruction that just ran, and in every one the
opcode is one that stores an allocator's result:
.CW 0x10
is
.CW INEW ,
.CW 0x71
.CW ISLICEC ,
.CW 0x53
.CW IADDC ,
.CW 0x51
.CW IINSC .
So the question stopped being "who wrote over this word".
.CW 0x18
is 24, which is
.CW sizeof(Heap)
and therefore
.CW H2D()
of a nil
.CW Heap* ;
.CW 0
is a nil
.CW String* .
Every one of these instructions had been handed
.CW 0
by a function that cannot return it \(em
.CW heap() ,
.CW nheap() ,
.CW heapz() ,
.CW addstring() ,
.CW slicer()
all check and
.CW error(exHeap) ,
and
.CW os/inferno/port/proc.c 's
.CW error()
ends in
.CW gotolabel .
.CW 6c -S
on
.CW libinterp/xec.c
confirms
.CW OP(new) 's
own code is right:
.CW "CALL heap; MOVQ AX,CX; ADDQ $24,CX; MOVQ CX,(AX)" .
.PP
That leaves the value being lost between the callee's
.CW RET
and the caller's store, which on this port can only be an interrupt.
.CW os/inferno/pc64/regtorture.s
asks that directly: load twelve registers with distinct values, spin
comparing them, report the first that changes.
.IP
.DS L
.CW
regtorture: interrupts off, 1M iterations: clean
regtorture: interrupts on: REGISTER 1 became 0x0
.R
.DE
.PP
Register 1 is
.CW AX ,
and it became
.CW 0 ,
which is the value every capture had.  The cause is four instructions
in
.CW os/inferno/pc64/l.s 's
interrupt entry:
.IP
.DS L
.CW
	PUSHW	GS
	PUSHW	FS
	MOVW	ES, AX	/* PUSHW ES is invalid in amd64 */
	PUSHW	AX
	MOVW	DS, AX	/* PUSHW DS is invalid in amd64 */
	PUSHW	AX

	PUSHQ	R15
	...
	PUSHQ	AX
.R
.DE
.PP
.CW Ureg.ds
and
.CW Ureg.es
were built
.I before
.CW "PUSHQ AX"
saved the interrupted code's
.CW AX ,
using
.CW AX
as the scratch the reads need.
.CW MOVW
from a segment register assembles to the 32-bit form, which
zero-extends into the whole of
.CW RAX ,
so what got pushed as
.CW Ureg.ax
\(em and what
.CW _intrestore
faithfully popped back \(em was the
.CW DS
selector, which is
.CW 0
on this kernel.  Every interrupt, every time, on every
.CW pc64
boot since the port began.
.PP
It survived this long because compiled code keeps a value in
.CW AX
for only the one or two instructions between a call returning and the
store of its result, so the great majority of interrupts land somewhere
that does not care.  When one lands in that window the caller gets
.CW 0 :
.CW OP(new)
stores
.CW H2D(nil) ,
.CW OP(addc)
and
.CW OP(slicec)
and
.CW OP(insc)
store a nil
.CW String* ,
and a few instructions later
.CW movp
panics, or
.CW addstring
faults reading
.CW D2H(0)->ref
at
.CW 0xffffffffffffffec ,
or the mark phase computes a garbage
.CW Heap* .
It also explains the non-Dis signatures this hunt collected \(em
.CW "panic: general protection violation"
in
.CW mntrpcread ,
.CW "panic: smalloc: size 18446744073441179738" ,
.CW alloc:D2B:destroy-entry :
kernel C code has the same one-instruction windows.
.PP
The fix reserves the eight bytes with
.CW "SUBQ $8, SP"
and fills
.CW ds ,
.CW es ,
.CW fs
and
.CW gs
in afterwards, at
.CW 120(SP)
through
.CW 126(SP) ,
once
.CW AX
is safely on the stack and free to be the scratch.
.CW _intrestore
is unchanged: it already skipped the four words on the way out.
.PP
Afterwards, on the same machine and the same command line:
.IP
.DS L
.CW
regtorture: interrupts off, 1M iterations: clean
regtorture: interrupts on, 2M iterations: clean
.R
.DE
.PP
and thirty consecutive boots of
.CW pc64
reached a shell prompt, with no
.CW track:
event, no
.CW movp
or
.CW freeptrs
or
.CW markheap
capture and no panic of any kind.  The measurements before it were one
in twenty-four, nine in twelve, eight in twelve, ten in twenty-five and
eight in thirteen.
.PP
.CW os/inferno/pc64/regtorture.s
stays, called once from
.CW init0
with interrupts on, so a kernel that reintroduces this prints it on
every boot instead of losing a pointer once an hour.  That claim was
checked rather than assumed: the two hunks of the bug were put back in
.CW l.s ,
the kernel rebuilt and booted, and it printed
.CW "regtorture: interrupts on: REGISTER 1 became 0x0" ;
the file was then restored, verified byte-identical to the fixed one,
and the line came back clean.
.PP
It reports two things beyond the verdict, both because the osprey-port
branch pointed out that it could otherwise lie.  It prints how many
clock ticks the run spanned, and says
.CW INCONCLUSIVE
at zero, because a fixed count of iterations proves nothing on a
machine whose clock has stopped \(em that is the case a bare "the
registers survived" passes hardest.  And it runs the identical loop
with interrupts disabled in the same boot and requires that control to
come back clean, because "the registers survived" and "the loop never
ran" are otherwise the same sentence.
.PP
The obvious way to guarantee coverage \(em spin until the tick counter
moves \(em was tried and abandoned, and what it turned into is a better
lesson than what it looked like at first.  Bounding the loop at four
ticks made a boot take 39.6 seconds to reach a shell prompt where the
same kernel without the call takes 9.6, and shrinking the pass size did
not help.  The reading here was "waiting on the clock is slow"; the
osprey-port branch then measured the same bound on its own guest and
got 191 passes over 20 ticks for a whole-check cost of 241.26 seconds
against 242.69 for the fixed form \(em no difference at all.  So the
general statement is not about waiting.  A tick bound takes its cost
from the guest's clock rather than from the work, which makes it free
where the clock is healthy and unbounded where it is not: two orders of
magnitude apart on the same code, and neither branch could have said
which it had without measuring.  A boot-time check has to run on
machines nobody has seen, so the count is bounded by iterations and the
ticks are reported \(em two million spans 167 ticks here anyway.
.PP
One trap for anyone scripting around it: the console prompt in these
kernels is
.CW "; " ,
and the success line first read "ticks; control clean", so every batch
that grepped for the prompt matched the instrument's own output and
scored thirty clean boots as thirty hangs.  The line carries no
semicolon now.  The
.CW newfd()
and
.CW growfd()
checkpoints are reverted, and it is worth saying that they never
narrowed anything: the inference that put them there \(em the hit fired
at
.CW kopen:after-newfd
and the earlier checkpoints were quiet, so the write must be in between
\(em does not follow, because a hit clears its own watch, so a quiet
earlier checkpoint says nothing unless the watch already existed when
it ran.  The inferno-ports branch reached the same correction
independently on raspi3b.  What made the captures legible was the
instrument going quiet, not the bisection.
.CW libinterp/heap.c 's
teardown
.CW trackclear
and the nil-result checks in
.CW OP(new) ,
.CW OP(addc)
and
.CW OP(slicec)
stay, being invariants rather than probes.
.PP
.B "Why everyone in this hunt wrote their own symbol reader."
Resolving a captured pc to a name was done here with an ad-hoc Python
reader, and the multicore branch landed one of its own, because
.CW inm
prints nothing for these kernels and exits 0, and
.CW acid
says "no symbol information".  Both are
.CW utils/libmach ,
and the cause is the fourth instance of the rule AGENTS.md already
states:
.CW "struct Exec" 's
eight fields are 32-bit words in the file, written four bytes at a
time by
.CW lput() ,
and were declared
.CW long ,
which is 64 bits on the hosts these tools are built on.  So the struct
was twice the width of the record, and
.CW fp->symsz
came from the top half of the 64-bit entry word, which is zero.
.CW hswal
had the matching bug, stepping a
.CW ulong*
through a sequence of 32-bit words.
.PP
.CW Exec
now has fixed-width fields,
.CW hswal
steps and counts in
.CW u32 s,
and
.CW utils/libmach/elf.h 's
32-bit ELF records are fixed the same way.
.CW inm
now agrees symbol for symbol with an independent reader on
.CW ipc64
\(em 4675 text symbols, and
.CW "0x2ef5fc"
resolves to
.CW movp
in both, which is where one of the captures panicked.
.CW utils/nm/nm.c
also swallowed the failure silently, returning with no message when
.CW syminit
failed or the table was empty; it says which now.
.PP
.B "And then the rest of the boards."
The arm boards worked as soon as the width bug was fixed.  The others
did not, for two further reasons, and both are closed now.
.CW libmach
knew arm64 objects and not arm64 executables \(em
.CW R_MAGIC
had no
.CW exectab
entry and there was no
.CW Mach ,
so
.CW crackhdr
said "Can't read header" for every
.CW 7l
output;
.CW utils/libmach/7.c
and
.CW ureg7.h
add it.  There is no arm64 disassembler, so it is deliberately not in
.CW setmach.c 's
.CW machines[] :
a
.CW Mach
is all
.CW crackhdr
and
.CW syminit
need, and a
.CW Machdata
would claim something that does not exist.
.PP
And every board but
.CW pc64
and
.CW armv7
links its kernel as ELF64, which
.CW libmach
read only to reject: "bad ELF class \(em not 32 bit", at
.CW executable.c 's
.CW elfdotout .
There was an ELF reader; it was 32-bit only.  The Plan 9 layout is the
same at both widths \(em one LOAD segment R|X for text, one R|W for
data, and the symbol table in a
.CW PT_NULL
segment whose
.CW filesz
is the symbols and whose
.CW memsz
is the pc/line table \(em so
.CW elf64dotout
is that routine with the wider header.
.PP
One thing had to be found by running it.  The symbol value width is a
property of the loader that wrote the file, not of the ELF class.
.CW utils/7l/span.c 's
.CW putsymb
writes eight-byte values only for
.CW HEADTYPE
2, the Plan 9 a.out, and four for its ELF output, and
.CW utils/6l
does the same;
.CW utils/jl 's
writes eight unconditionally, on
.CW "if(thechar == 'j')" .
So a riscv64 ELF has eight-byte values where an arm64 one has four,
and read at the wrong width the table decodes into nonsense that still
looks like a symbol table \(em
.CW "74696e69 t"
for a symbol whose name is "init".
.CW Fhdr
carries the width now, in the field that used to be
.CW spare ;
.CW crackhdr
sets the a.out default and
.CW elf64dotout
sets its own.
.PP
Ten of the fifteen boards' kernels now resolve, each starting at
.CW _main
at its own load address:
.CW pc64
4675 text symbols,
.CW virt
and
.CW sifiveu
and
.CW shakti
and
.CW spike
and
.CW mangopi
and
.CW virts
on RISC\-V,
.CW virtarm64
2436 and
.CW raspi3b
on arm64, and
.CW armv7 .
Both readings were checked against an independent reader written for
the purpose, on both formats: 4675 against 4675 on
.CW pc64 's
a.out, and 2436 against 2436 on
.CW virtarm64 's
ELF with the sampled entries matching name and address.
.CW virt32
and
.CW virt32s
are ELF32 RISC\-V and would want an
.CW mriscv32 ,
which
.CW libmach
does not have;
.CW mps2 ,
.CW nucleof303
and
.CW teensy41
are raw binaries with no header at all, so refusing them is right.
.PP
.B "The width is derived, so it is checked."
Which width to use is worked out in
.CW executable.c
from which loader wrote the file, and a derivation is worth checking
against the thing it claims to describe.
.CW syminit
now does two checks, and it is worth being exact about which one does
the work.
.PP
The first is that the table must be consumed exactly: each record is a
value, a type byte and a name, and a well-formed table's records sum
to
.CW symsz .
That catches a width that is too small \(em
.CW virt 's
table read with four-byte values reports "symbol table is 427742
bytes, 4-byte values consume 427746" \(em and it is
.I not
enough on its own.  Read
.CW virtarm64 's
table with eight-byte values and the records happen to land on
.CW symsz
exactly: 563 records of rubbish come back looking like a symbol table,
starting
.CW "6d63636f6e647569 t" ,
and nothing complains.  So the arithmetic check catches one direction
of the mistake and not the other, which is the sort of thing only a
control in both directions shows.
.PP
The second is the one that works.  Every symbol record this tree's
loaders write has
.CW 0x80
set in its type byte \(em the new-style, length-prefixed name \(em and
a type from
.CW TtLlDdBbapmzZf .
That is measured rather than assumed: a survey counting exceptions
across all ten readable boards, covering
.CW 6l ,
.CW 7l ,
.CW jl
and
.CW 5l
output and both header types, found none.  With it in,
.CW virtarm64
read at eight bytes fails at symbol 0 and
.CW virt
read at four fails at symbol 2, each naming the byte it found, and all
ten boards read exactly as before \(em the same symbol counts, 6011 on
.CW pc64
through 3316 on
.CW spike .
.PP
Two smaller things came out of running that.
.CW ksize
reported "bad ELF class \(em not 32 bit" on
.CW ivirtarm64
long after
.CW libmach
had stopped containing that sentence: the installed binary was linked
against the old library, which is the stale-artifact trap AGENTS.md
already records \(em rebuilding a library does not rebuild what was
linked against it, and
.CW mk
lists only sources.  All ten programs that use
.CW libmach 's
interface are rebuilt now, and
.CW ksize
sizes all ten readable boards.  And
.CW elfdotout 's
machine
.CW default
returned 0 without setting
.CW errstr ,
so a caller printing
.CW %r
printed "Undefined error: 0" and a reader could not tell a corrupt
file from a kind
.CW libmach
has no table for.  It says "unsupported ELF32 machine 243" now, which
names the
.CW mriscv32
gap rather than hiding it.
.PP
One more thing fell out.
.CW srclist
runs on
.CW libmach ,
so it had been listing no sources at all: every board's
.CW i$CONF.acid
was one line long.  With it working, the acid rule in
.CW os/inferno/port/portmkfile
compiles all 312 of
.CW pc64 's
sources, which exposed that it hands foreign sources the board's own
include path \(em
.CW libinterp/keyring.c 's
.CW "#include <mp.h>"
found
.CW os/inferno/pc64/mp.h ,
the MP/APIC table header.
.CW ip.h
and
.CW mp.h
are the only two names that collide between
.CW $ROOT/include
and the kernel directories, and each file now gets the include path of
the tree it came from.
.PP
Which boards that is evidence from is worth being exact about, because
it is easy to over-claim: of the fifteen boards that build,
.CW pc64
is the
.I only
one whose
.CW default
target names
.CW i$CONF.acid
\(em every other board's is
.CW i$CONF
alone \(em so "the boards still build" says nothing about this rule.
.CW "mk acid"
on
.CW armv7
is the independent check, and it now writes a 6.7 MB listing over 211
sources where it used to write one line.  The remaining boards cannot
exercise it at all: their kernels are ELF, and
.CW libmach
has no Elf64, so
.CW srclist
still has nothing to say about them.
.NH 2
Taking the instruments back out
.PP
The hunt's instruments came out once the fix had thirty boots behind
it, together, and with thirty boots of their own \(em because removal
is code motion, and this section's own warning is that code motion
looks like a fix on a small sample and can look like a regression the
same way.
.PP
The reason to hurry was not the slowdown.
.CW libinterp
is shared with the hosted
.CW emu ,
and the instruments had put kernel-only symbols into it:
.CW gc.c
and
.CW heap.c
called
.CW dumpstack() ,
which only
.CW os/inferno
defines, and
.CW xec.c 's
.CW OP(movp)
called
.CW printfreehist() ,
which lives in
.CW os/inferno/port/alloc.c .
So the hosted
.CW emu
did not link at all from this tree.  The
.CW emu-cocoa
and
.CW emu-g
binaries committed under
.CW MacOSX/arm64/bin
predate the hunt, so nothing that ran them noticed; anyone building
.CW emu
from source on this branch could not.  That is the lesson worth
keeping: an instrument in shared code is not paid for only by the
board being debugged.
.PP
Sorted by what each cost when nothing was wrong.  Per Dis instruction:
.CW checktracked()
scanned a 1024-entry table after every one, and the per-proc
.CW wmtrace
ring did five stores into a 256-entry array in every
.CW Prog .
Per allocation and per free:
.CW initmem() 's
registration walk,
.CW freeptrs() 's
.CW checkfreeptr()
per pointer word,
.CW alloc.c 's
4096-entry free-history ring with a
.CW currun()
and a module-name lookup on every
.CW poolfree() ,
.CW gc.c 's
.CW checkmarkptr()
per marked word, and
.CW scanframe()
on every frame teardown.  And the prints on an ordinary boot:
.CW "new:" ,
.CW "newa:" ,
the
.CW progpid()
counter, the
.CW delprog
window report and the print before each
.CW error(exHeap) .
.PP
Two of those prints had been reporting something, which is the case
where deleting the reporter needs an argument rather than a shrug.
.CW delprog 's
instrument fired in two boots of thirty \(em an overlap, and the GC
running inside the window.  Both are the window being entered, which
is what it was built to watch, and both are benign on inspection:
.CW disracepid
was a single global, so an overlap means only that two
.CW delprog s
interleaved, and
.CW release()
inside that window is exactly what lets the GC run.  Neither ever
coincided with a failure.
.PP
What stays is everything that costs nothing when nothing is wrong and
can only fire on a defect:
.CW chan.c 's
.CW chanok() ,
.CW destroy() 's
.CW h->ref
underflow guard,
.CW markheap() 's
bad-Type* guard (both now
.CW panic()
with their own message rather than a
.CW dumpstack
and an
.CW abort ),
the
.CW alloc:D2B
consistency checks, and
.CW os/inferno/pc64/regtorture.s ,
which is a real regression test for the bug with a working control.
.PP
Measured after: the hosted
.CW emu
links, and a 2M-iteration Dis array loop runs in 45 ms against the
committed pre-hunt binary's 51 ms.  Thirty boots of the ISO, six at a
time, thirty shells and no panic.  virtarm64 through AAVMF with ACPI,
the v2m frame and both NVMe vectors; the seventeen-processor run;
virtarm64ndb end to end; ipc64dev with NVMe over UEFI;
.CW pc64fp .
Every board relinked from a nuked
.CW libinterp .
.NH 1
A function that did the opposite of its comment
.PP
.CW os/inferno/port/proc.c 's
.CW userureg()
returned
.CW Proc.kp
where the paragraph directly above it says to return
.CW !Proc.kp .
Every kernel process's trap was therefore classified as coming from
user mode, and the one process
.CW newproc()
makes without
.CW kp
was classified as a kernel trap.  Both backwards, since the day it was
written.
.PP
This was found by the multicore branch, which also caught the
consequence in the act on
.CW pc64 :
a general protection fault on the
.CW IRETQ
in
.CW _intrr ,
twelve times in about 864 boots, with a probe at both ends of
.CW trap()
watching a newly created kproc's frame have its
.CW SS
word overwritten between entry and exit, and the fault's error code
equal to the low half of the value the probe had just seen written.
Their narrowing was by elimination, one region per batch: a probe at
trap entry silent over 52 boots including two faults, one across
.CW irqhandled()
silent over 192 including one, and the one inside
.CW trap()
firing.
.PP
What was checked here rather than taken on trust.  The code is present
verbatim in this tree, and a probe in
.CW os/inferno/pc64 's
.CW trap()
printing what
.CW userureg()
says about each kind of process shows the inversion directly, in one
boot:
.IP
.DS L
.CW
UUPROBE pid 1 kp 0 userureg 0 vno 81
UUPROBE pid 2 kp 1 userureg 1 vno 50
.R
.DE
.LP
\(em the real user process told it is not one, a kernel process told it
is.  With the fix, the same probe on the same boot path prints
.CW "pid 1 kp 0 userureg 1"
and
.CW "pid 2 kp 1 userureg 0" .
Vector 50 is the one their capture named.
.PP
The blast radius here is one board.
.CW userureg()
is called from
.CW os/inferno/pc64 's
.CW trap.c
and
.CW fpu.c
and from
.CW kenter()
in the shared
.CW proc.c ,
and no other board in
.CW os/inferno
calls
.CW kenter() ,
.CW kexit()
or
.CW notify()
at all \(em they trap without a user tail.  The
.CW os/9front
and
.CW os/osprey
trees have their own
.CW userureg
macro, testing the code segment's privilege level, and are untouched.
.PP
Ninety-six boots with the fix in, six at a time under QEMU/TCG, all
ninety-six reaching the shell with no panic and no general protection
fault.  That is a regression check and nothing more, and it is worth
saying why: at the multicore branch's measured rate of twelve in about
864, the chance of ninety-six clean boots happening anyway is about one
in four.  The weight is on the classification having been seen wrong
and then seen right, not on the batch.  The other fourteen boards were
rebuilt against the changed
.CW proc.c
and the two that are booted routinely still are \(em
.CW virtarm64
starts sixteen processors on a seventeen-processor machine and reaches
a shell,
.CW virt
prints its eleven
.CW DEVTEST
lines.
.PP
One thing this does not settle, and the comment in the source says so:
on a port where the kernel and the user share a code segment, whether
any frame should be called a user frame is a real question, and
"always 0" may be the right answer.  This makes the function do what
it says, no more.
.NH 1
Floating point, and a comparison that forgot its mask
.PP
The multicore branch raised a possible regression from the
.CW userureg()
fix: a
.CW "panic: math emu pid 1"
they had not seen in 880 boots before it and saw once in 304 after.
One sample, Fisher about
.CW "p = 0.26" ,
so nothing on counts \(em but the panic is in one of the three call
sites the fix touches, and it names the one process whose
classification changed.  That is worth answering with evidence rather
than with an opinion.
.PP
.B "First, an instrument."
Waiting for a 0.3% panic is the wrong tool, for the reason section 5
gives.
.CW os/inferno/init/fpinit.b
is
.CW disinit.b
with a floating-point stress in front of it and nothing else changed:
six Dis threads, three rounds, each summing 0 to 199999 as reals and
doubling and halving as it goes.  Every intermediate is a small
integer times a power of two, so the sum is exact and can be written
in closed form, and each worker folds its own id in so no two compute
the same number.  A corrupted register file, or two threads' state
swapped, is then a wrong number rather than only a panic.
.CW os/inferno/pc64/pc64fp
is the
.CW pc64
configuration with that init, so a boot of one and a boot of the other
differ in exactly one thing.  Dis programs run in kernel processes and
do their arithmetic inside the interpreter, and
.CW os/inferno/port/dis.c
pushes and pops FPU state through
.CW fpusave()
and
.CW fpurestore()
around every
.CW r->xec(r) ,
so several threads doing real arithmetic at once is what makes those
pushes interleave.
.PP
Forty-four boots of it in four arms, eight to twelve each, differing in
one thing at a time: the tree as it stands, the tree with
.CW userureg()
put back to its inversion, the tree again as a repeat, and the tree
with the
.CW notify()
mask below.  Every boot printed
.CW FP-STRESS-OK ,
which is 3.6 million exact floating-point results per boot across
eighteen Dis threads, with no
.CW "math emu" ,
no
.CW fpslot
panic and no wrong value in any arm.  Two things follow, and the second
matters more than the first: the fix does no harm under heavy floating
point, and the stress does not discriminate between the arms at all \(em
so it is evidence about
.I damage ,
not about the reported panic, which it never reproduced in any
configuration.
.PP
.B "Second, where the bug actually is."
On this board the bits
.CW userureg()
controls in
.CW mathemu
are write-only.
.CW FPnouser
and
.CW FPkernel
are read in exactly one place that does not mask them,
.CW fpuprocfork 's
switch at
.CW fpu.c:293 ,
and
.CW fpuprocfork
is never called: there is no
.CW procfork
hook in
.CW os/inferno/port/proc.c ,
.CW newproc()
sets
.CW "p->fpstate = FPinit"
inline, and the comment at
.CW proc.c:701
still reads "TODO fpusetup() and procsetup() of 9front".  Every other
comparison masks them \(em
.CW fpu.c:177 ,
.CW 314 ,
.CW 351 ,
.CW 361 ,
.CW 366
\(em and the assignments at 200 and 217 preserve them.  So the only
reachable behaviour the answer changes inside
.CW fpu.c
is which processes can reach the
.CW "fpslot index %d != 0 for user"
panic, which is a different panic from the one reported.
.PP
.CW notify()
is where it does matter, and
.CW notify()
is also where the multicore branch's other observation comes from.
.CW os/inferno/pc64/trap.c 's
copy ends:
.IP
.DS L
.CW
	ureg->cs = UESEL;
	ureg->ss = UDSEL;
	...
	if(up->fpstate == FPactive){
		fpsave(up->fpsave);
		up->fpstate = FPinactive;
	}
	up->fpstate |= FPillegal;
.R
.DE
.LP
The first two lines explain their capture completely: before the fix,
kernel processes were classified as user, so
.CW trap() 's
tail called
.CW notify()
on a
.CW Ureg
sitting on a kernel stack, rewrote its
.CW ss
to
.CW UDSEL
and returned into it \(em which is a probe watching the frame's
.CW SS
word change under a kproc's first interrupt, and a general protection
fault whose error code is the low half of that word.
.PP
The third is the one still there.  That comparison is unmasked where
every sibling masks, so a process carrying
.CW FPnouser ,
.CW FPkernel
or a non-zero
.CW FPindex
fails it:
.CW fpsave()
is skipped, the FPU is left live with
.CW TS
clear, and
.CW FPillegal
is set anyway.
.CW mathemu
then tests
.CW FPillegal
first and returns without repairing anything, so the state stays out
of step.  And the fix changes which way that goes for the one process
that reaches
.CW notify() :
before it, that process had
.CW FPnouser|FPkernel
set permanently, so the comparison was always false and the save never
happened; after it, the process is clean except for whatever
.CW FPindex
.CW fpusave()
pushed, so the same comparison is true sometimes and false others.
Which is a mechanism by which a correct fix makes a second, older bug
start to matter.
.PP
.B "What was done about it."
.CW notify() 's
comparison is masked now, like its siblings, and the assignment
preserves the bits the same way
.CW fpu.c:200
and
.CW 217
do.  That is written down for what it is: found by reading, consistent
with another branch's report, and
.I not
reproduced here \(em reaching it wants a note delivered, and a clean
boot delivers none.  What is measured is only that it breaks nothing:
forty-four boots of the stress above and forty-eight of the ordinary
.CW pc64
kernel with it in.
.PP
.B "A third bare call, and where this file actually came from."
The multicore branch's three checks, run in the order suggested, found
that the panicking process had taken no note \(em so
.CW notify()
never ran, and neither its unmasked comparison nor
.CW fpu.c 's
own branch could have been the mechanism.  They resolved the panic's pc
to
.CW _fxsave+0x0 ,
which says the fault is the save instruction itself.
.PP
That points at a third site with the same shape.
.CW matherror()
and
.CW simderror()
call
.CW fpsave()
with no
.CW _clts()
and no state test at all.
.CW fpsave
is
.CW _fxsave()
followed by
.CW _stts() ,
so calling it with
.CW TS
already set faults on its own first instruction, reported at
.CW _fxsave+0x0 ,
with no intermediate step needed.  And the window where
.CW TS
is set while
.CW fpstate
still says active is not hypothetical:
.CW fpusave()
sets
.CW TS
and stores
.CW FPpush|FPactive ,
and
.CW os/inferno/port/dis.c
holds every Dis program inside exactly that window, between
.CW fpusave()
and
.CW fpurestore()
around
.CW r->xec(r) .
.PP
This one can be settled against a source rather than by reading.
.CW os/9front/pc64/fpu.c
is in this tree, and its
.CW matherror
does three things this copy does not: returns early for a trap from
kernel mode, guards on
.CW "up->fpstate != FPinactive" ,
and does
.CW _clts()
before
.CW fpsave() .
All three were lost in the port.  The two that cannot change the state
machine are back \(em a nil check on
.CW up->fpsave
and the
.CW _clts()
\(em and the third is left alone, for a reason worth recording on its
own.
.PP
.B "The 9front file in this tree is not this file's upstream."
.CW os/9front/pc64/fpu.c
has no
.CW fpusave ,
no
.CW fpurestore ,
no
.CW FPpush ,
no
.CW FPnouser ,
no
.CW FPkernel
and no
.CW fpslot
array; it uses
.CW m->fpsave
and
.CW up->kfpsave
instead.  So the Inferno
.CW pc64
floating-point design came from somewhere else, and a diff against the
9front copy shows a different design rather than a drift.  That is a
general caution about this tree: a file under
.CW os/9front
with the same name as one under
.CW os/inferno
is not necessarily what the Inferno one was copied from, and treating
it as the upstream will produce confident wrong answers.  Here it was
still useful \(em it showed three things missing from two functions
that
.I are
recognisably the same two functions \(em but only because the
difference was checked rather than assumed.
.PP
The other half of the answer to that report is a coverage claim rather
than a fix.  This board's
.CW fpuprocfork
is dead code, so the flags are write-only here; on a branch that has
wired it for SMP they are not, and the fork path's switch at
.CW fpu.c:293
is the other place that does not mask.  That is where to look next on
a tree where this board's reasoning does not apply.
.NH 1
The arm64 EFI loader
.PP
.CW doc/inferno-platforms.ms
section 4.3 makes an AArch64 build of
.CW os/inferno/boot/efi
the gate for the arm64 server: ACPI on arm64 takes the RSDP from the
UEFI system table rather than from a scan of low memory, so nothing
below it can start until the loader runs.  It builds, AAVMF loads it,
and it executes.  What follows is what was found by running it, and
what is still in the way.
.PP
.B "The static base was never set."
.CW efimain 's
third instruction is
.CW "STR X0, [X28]" ,
.CW "IH = ih" ,
and it took a data abort at address
.CW 0
\(em ESR
.CW 0x96000047 ,
translation fault third level, FAR
.CW 0 .
.CW R28
is
.CW SB ,
the static base every 7c reference to a global goes through, and
nothing had set it: the firmware enters at
.CW start(SB)
and
.CW reloc()
copies the image, so there is no runtime startup doing what
.CW os/inferno/virtarm64/l.s 's
.CW _main
does with
.CW "MOV $setSB(SB), R28"
before it calls
.CW main .
One instruction in
.CW entry ,
and the fault moved from address
.CW 0
to real addresses.
.PP
That diagnosis needed a symbol for
.CW 0x48000D18 ,
which is why
.CW utils/libmach
was repaired first and then given the arm64 half it never had \(em see
the section above and
.CW utils/libmach/7.c .
.CW inm
now reads
.CW 7l
output, and said in one line what the address was.
.PP
.B "The PE the loader is wrapped in was not a valid one."
.CW tools/aout2efi
wrote
.CW SectionAlignment
.CW 0x200 ,
a single section spanning text, data and bss, and
.CW Characteristics
.CW 0x86000020
\(em
.CW MEM_WRITE
.CW | MEM_DISCARDABLE
.CW | MEM_NOT_CACHED
.CW | CNT_CODE ,
with neither
.CW MEM_READ
nor
.CW MEM_EXECUTE
set and two flags inviting the firmware to discard the section or map
it uncached.  EDK2 can only apply per-section memory attributes to an
image whose sections are whole EFI pages; with
.CW 0x200
it printed "ProtectUefiImage failed to create image properties record"
and the image's pages kept whatever the default policy gave them,
which on AArch64 is not executable \(em an instruction abort on the
loader's first instruction, ESR
.CW 0x8600000E ,
deterministic three runs out of three.
.PP
.CW aout2efi
now emits a page-aligned image with
.CW SectionAlignment
and
.CW FileAlignment
both a whole EFI page, one section claiming
.CW CNT_CODE
.CW | CNT_INITIALIZED_DATA
.CW | MEM_EXECUTE
.CW | MEM_READ
.CW | MEM_WRITE ,
and
.CW AddressOfEntryPoint
computed as the entry's RVA rather than as
.CW entry-base ,
which is only the same thing while the two bases coincide.
.PP
Both loaders are linked
.CW -R4096
now, which page-aligns the data segment, and that turned up a defect of
its own: in the a.out file data follows text immediately, but its
virtual address is a page-rounded distance above the text's, so a
single PE section has to reproduce that gap in the file or every
address in the data segment lands short by it.  It does.
.PP
That the whole change is right and not merely different is measured on
the platform where the path can be run end to end: with it,
.CW bootx64.efi
under OVMF still loads
.CW ipc64
and reaches a shell prompt.  That was checked again after every shape
the image took.
.PP
.B "Two sections was tried and is not what is in the tree."
Two sections \(em
.CW .text
read-only and executable,
.CW .data
writable and not \(em is the shape a compiler emits and the shape EDK2
protects properly, and it is the obvious fix for a code section that
holds the data too.  With it, this AAVMF build loads the image away
from its
.CW ImageBase
and leaves
.CW .text
non-executable, so nothing runs at all and the loader's own
.CW reloc
never gets the chance to copy itself down.  Reproduced three times,
with and without
.CW RELOCS_STRIPPED ,
at two image bases.  One section costs nothing here, because the
loader never writes to the image the firmware loaded \(em
.CW start
and
.CW reloc
only read it, copy it to the address it was linked for, and enter the
copy \(em so read-only at the load address is the right protection for
it, which is what EDK2 gives a code section.
.PP
.B "What the firmware will not do, and what was built for it."
Copying the image to its link address puts it in memory the firmware
still believes is free, and ArmVirtQemu marks free conventional memory
non-executable: the copy takes an instruction abort at its own first
instruction, ESR
.CW 0x8600000E .
That was seen directly, by giving the PE an
.CW ImageBase
different from the address the code runs at \(em
.CW aout2efi
takes it as a third argument now, and
.CW PEBASEARM
in the mkfile supplies it \(em so that the firmware could not place the
image where
.CW reloc
was going to put it.
.CW efiallocpages
in
.CW efi.c
is the answer: it asks
.CW BootServices->AllocatePages
for the destination range by address and as
.CW EfiLoaderCode
before the copy.
.PP
.B "Three more, each found by the one before it."
.CW eficall
kept the link register in
.CW R10
and the caller's stack pointer in
.CW R11
across the firmware call.  Both are caller-saved in AAPCS64, so the
firmware is free to destroy them, and restoring
.CW RSP
and
.CW R30
from them afterwards returns to wherever the firmware happened to
leave
.CW X10
\(em an instruction abort in the firmware's own address range.  Nothing
had noticed because no EFI call had ever completed on this port: the
loader faulted before its first print.  They live on the stack now.
.PP
.CW reloc
copied text and data and stopped at
.CW edata ,
and nothing zeroed the bss.  The a.out carries no image for it, so
every uninitialised global held whatever the firmware had left in the
pages just allocated.  It also asked for only
.CW edata-IMAGEBASE
bytes, so the bss was not in the allocation at all.  Both fixed: the
request covers through
.CW end ,
and a zeroing loop follows the copy.  This was invisible while the
image ran from a fixed address that happened to be zeroed RAM.
.PP
And
.CW confaddr ,
which
.CW sub.c 's
.CW BOOTLINE
and
.CW BOOTARGS
are defined in terms of, was
.CW CONFADDR ,
.CW 0x1200 :
a fixed address in low memory that the amd64 kernel reads by
convention.  There is no such convention on AArch64 and 0x1200 is not
memory this loader owns, so
.CW configure
took a data abort on the first thing it does.  It points at a page of
the loader's own bss now.
.PP
.B "Four more, and then it boots."
.CW eficall
kept the link register in
.CW R10
and the caller's stack pointer in
.CW R11
across the firmware call.  Both are caller-saved in AAPCS64, so the
firmware is free to destroy them, and restoring
.CW RSP
and
.CW R30
from them afterwards returns to wherever the firmware happened to leave
.CW X10 .
Nothing had noticed because no EFI call had ever completed on this
port: the loader faulted before its first print.  They live on the
stack now.
.PP
.CW reloc
copied text and data and stopped at
.CW edata ,
and nothing zeroed the bss.  The a.out carries no image for it, so
every uninitialised global held whatever the firmware had left in the
pages just allocated; the allocation did not cover the bss either.
Both fixed.  Invisible while the image ran from a fixed address that
happened to be zeroed RAM.
.PP
.CW confaddr ,
which
.CW sub.c 's
.CW BOOTLINE
and
.CW BOOTARGS
are defined in terms of, was
.CW CONFADDR ,
.CW 0x1200 :
a fixed low-memory address the amd64 kernel reads by convention.
There is no such convention on AArch64 and it is not memory this
loader owns, so
.CW configure
took a data abort on the first thing it does.  It points at a page of
the loader's own bss now.
.PP
And
.CW jump
did not spin.  It was
.CW "B ,-4(PC)" ,
which in this assembler branches back four instructions rather than to
itself \(em out of the one-instruction function and into whatever
preceded it.  Control came back through
.CW bootkern
to
.CW efimain 's
.CW print(bootkern(f)) ,
after
.CW ExitBootServices ,
where the console protocol is gone: a data abort in
.CW putc
at
.CW FAR
.CW 8 ,
which is
.CW ConOut->OutputString
through a null
.CW ConOut .
.PP
.B "Loading the kernel."
.CW bootkern
accepted only Plan 9 a.out, and every board in this tree but
.CW pc64
and
.CW armv7
links its kernel as ELF, because that is what QEMU's
.CW -kernel
takes.  It reads ELF64 now:
.CW loadelf
in
.CW sub.c
walks the program headers and loads each
.CW PT_LOAD
at its physical address.  The file interface is open/read/close with
no seek, so it reads forward and skips, which is enough because the
loaders write their segments in ascending offset order.  The
.CW R_MAGIC
case also lost its
.CW "& 0x0FFFFFFF" ,
a PC convention for turning a high-mapped amd64 entry into its low
physical alias, which gives 0 for an arm64 kernel linked at
.CW 0x40000000 .
.PP
.CW memconf 's
96 KiB memory-map buffer moved from the stack to bss on the way past:
that is more stack than a UEFI application can count on, and it is
called three deep.
.PP
.B "And the handover."
.CW jump
now clears
.CW SCTLR_EL1 's
.CW M ,
.CW C
and
.CW I
and branches to the entry with
.CW X0
zero.  Clearing
.CW M
does not move the instruction stream because the firmware maps RAM
one-to-one.
.CW X0
is what
.CW os/inferno/virtarm64/l.s 's
.CW _main
stores as
.CW dtbptr ,
and it is zero because a UEFI machine describes itself with ACPI \(em
the RSDP is in the configuration block as
.CW *acpi= .
One thing is deliberately not there: the kernel image was written with
the D-cache on and is not cleaned to the point of unification before
.CW C
is cleared, so a machine with real caches may fetch stale lines.  QEMU
models no cache, so that loop could not be exercised, and this tree
does not ship loops it cannot run \(em the reason
.CW os/inferno/raspi3b/l.s
gives for leaving its own CLIDR/CCSIDR walk out.
.PP
.B "What it does."
Booted from the removable-media path with stock AAVMF and a fresh
variable store:
.IP
.DS L
.CW
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x0)
*acpi=0x5cb43018
bootfile=/aarch64/ivirtarm64
console=0
boot
Inferno/arm64 virt
...
Inferno Fourth Edition (20151010)
conf virtarm64 (1788913460) jit 0
Initial Dis: "/osinit.dis"
** Inferno/arm64 virt **
VIRTARM64-OK
interactive sh
;
.R
.DE
.PP
That is the arm64 server's gate, open:
.CW doc/inferno-platforms.ms
section 4.3 makes an AArch64 build of
.CW os/inferno/boot/efi
the thing everything else waits on, because on arm64 the RSDP comes
from the UEFI system table and from nowhere else.  The loader now
finds it, and the kernel boots from UEFI to a shell.
.PP
.B "And the configuration reaches the kernel."
The loader's block lives in the loader's own memory, and there is no
low memory on this board for a fixed
.CW CONFADDR
\(em RAM starts at
.CW KTZERO ,
where the kernel is linked.  So
.CW jump
passes the block's address in
.CW x1 ,
which the AArch64 Linux boot protocol reserves as zero and QEMU's
.CW -kernel
path therefore leaves zero: a boot with no loader sees nothing and
behaves as before.
.CW os/inferno/virtarm64/l.s
records it beside
.CW dtbptr ,
and a new
.CW os/inferno/virtarm64/bootargs.c
\(em the generic half of
.CW os/inferno/pc/bootargs.c ,
without the multiboot and PVH readers, which this board has no use for
\(em copies and parses it.  The copy matters: the block is in memory
the kernel is free to allocate over, so
.CW main
calls
.CW bootargsinit
first, immediately after zeroing bss.
.CW getconf
was a stub returning nil on this board and is real now, and
.CW init0
calls
.CW setconfenv
the way
.CW pc64 's
does.
.IP
.DS L
.CW
Boot configuration
	*acpi=0x5cb43018
	bootfile=/aarch64/ivirtarm64
	console=0
	*e820=1 0000000040000000 0000000044000000 2 0000000044000000 ...
.R
.DE
.LP
so the RSDP, the boot file, the console setting and the firmware's
whole memory map are all in
.CW /env
by the time Dis starts.
.CW os/inferno/init/virtarm64init.b
prints
.CW ARM64-ACPI-OK
with the RSDP on a UEFI boot and
.CW ARM64-ACPI-NONE
on the
.CW -kernel
path, so the difference is visible in a boot log rather than assumed.
.NH 1
ACPI on arm64
.PP
.CW os/inferno/virtarm64/acpi.c
follows the pointer.  A PC finds the RSDP by scanning the BIOS area;
an AArch64 machine has no such area and the pointer comes from the UEFI
system table, which is why the loader had to exist first.  Now
.CW acpiinit
takes
.CW *acpi=
from the configuration, checks the RSDP's signature and both its
checksums, walks the XSDT or the RSDT, checksums every table it names,
and reads what an arm64 kernel needs: the GIC distributor,
redistributor and cpu-interface bases and the processor list from the
MADT, the PCIe ECAM base from the MCFG, the console UART from the
SPCR, and the ARM boot architecture flags from the FADT.  Fields are read a byte at a time, because ACPI tables
are byte-packed and several of these are not naturally aligned \(em the
GICC structure puts an eight-byte physical address at offset 32 of an
entry that itself starts at an odd offset from the table.
.PP
Every value is printed beside the constant
.CW mem.h
compiles in, because agreement on a machine whose layout is already
known is what shows the reader is right.  Three are then used rather
than only printed \(em the ECAM window, the PSCI conduit and the
processor list \(em and each has a machine below that shows the
difference between a reader that parses and a reader that works.  The
GIC bases and the console UART are still the compiled-in ones.
.PP
On the default machine, which is GICv2 with one processor:
.IP
.DS L
.CW
acpi: rev 2 XSDT at 0x5cb43f18, 8 tables
acpi: FACP at 0x5cb43b18 len 276
acpi: APIC at 0x5cb43c98 len 172
acpi: PPTT at 0x5cb43d98 len 96
acpi: GTDT at 0x5cb43098 len 104
acpi: MCFG at 0x5cb43a98 len 60
acpi: SPCR at 0x5cb43e98 len 80
acpi: DBG2 at 0x5cb43818 len 87
acpi: IORT at 0x5cb43898 len 128
acpi: gicd 0x8000000 (mem.h 0x8000000) gicr 0x0 (mem.h 0x80a0000) gicc 0x8010000 (mem.h 0x8010000)
acpi: ecam 0x4010000000 (mem.h 0x4010000000) uart 0x9000000 (mem.h 0x9000000) cpus 1
.R
.DE
.LP
and on
.CW "-M virt,gic-version=3 -smp 2" :
.IP
.DS L
.CW
acpi: gicd 0x8000000 (mem.h 0x8000000) gicr 0x80a0000 (mem.h 0x80a0000) gicc 0x0 (mem.h 0x8010000)
acpi: ecam 0x4010000000 (mem.h 0x4010000000) uart 0x9000000 (mem.h 0x9000000) cpus 2
.R
.DE
.PP
Every value the reader extracts matches what the board knows, on both
GIC versions, and the two that come back zero are zero for the right
reason: a GICv2 machine has no redistributor and a GICv3 machine has no
MMIO cpu interface, so each is absent from the MADT of the machine that
does not have it.  The processor count follows
.CW -smp .
That is the check \(em not that it parsed something, but that what it
parsed agrees with an independently known answer twice, and disagrees
in exactly the places the architecture says it should.
.PP
The
.CW -kernel
path prints none of it and reports
.CW ARM64-ACPI-NONE ,
because there is no configuration and therefore no pointer, which is
the behaviour that board had before any of this.
.PP
.B "One value is used, and there is a machine that proves it."
The PCIe ECAM window comes from the MCFG now.
.CW os/inferno/port/pciecam.c
gained a
.CW "uvlong (*pciecam)(int*, int*)"
\(em the same name and the same shape as
.CW os/inferno/pc/pcipc.c 's,
which
.CW archacpi.c
sets from the PC's MCFG \(em and
.CW acpi.c
points it at its reader.  A board with no firmware description leaves
it nil and keeps
.CW mem.h 's
constant, which is every RISC\-V board here.
.PP
That the value is used rather than merely equal is not something QEMU's
default machine can show, because there the two agree.
.CW "-M virt,highmem-ecam=off"
moves the window into the 32-bit space, and then they do not:
.IP
.DS L
.CW
acpi: ecam 0x3f000000 (mem.h 0x4010000000) bus 0..15 uart 0x9000000 (mem.h 0x9000000) cpus 1
pci: ecam 0x3f000000 from the firmware, mem.h says 0x4010000000
pci PCI.0.0.0: 1b36/0008 class 060000 irq 255
pci PCI.0.1.0: 1af4/1000 class 020000 irq 36
pci PCI.0.2.0: 1af4/1001 class 010000 irq 37
.R
.DE
.LP
All three devices, at a base and a bus range the kernel could only have
learned from the firmware.  The control is the same kernel with the one
assignment removed, so the value is still read and printed and not
used: on that machine it panics in configuration space and prints "Hit
the reset button", where with the assignment it reaches a shell.  That
is the difference between a reader that parses and a reader that works.
.PP
.B "The processor list, and the first thing it is for."
Each GICC structure in the MADT is one processor, and its MPIDR is the
only way a kernel can learn the affinity of a processor other than the
one it is running on:
.CW MPIDR_EL1
reads the current processor and nothing else.  PSCI's
.CW CPU_ON
takes exactly that value as its target, so the MADT's list is not a
convenience, it is the whole input to starting a second processor.
.CW acpi.c
now keeps the MPIDR, the ACPI processor UID, the flags and the
per-processor redistributor base of each in
.CW io.h 's
.CW Acpicpu ,
and guards field by field rather than once for the whole structure:
GICC grew from 40 bytes in ACPI 5.0 to 76 in 5.1, which is where the
MPIDR at offset 68 first appears, to 80 in 6.0, and a length that
covers the cpu interface at offset 32 does not mean it covers the
MPIDR.  The count that was there before is now named for what it is,
the entries with the Enabled bit set, since ACPI 6.3's Online Capable
bit makes "enabled" and "startable" two different questions.
.PP
.CW os/inferno/virtarm64/startcpu.c
starts them, and the log is written so that nobody can read it as SMP.
.CW MAXMACH
is 1 on this board,
.CW conf.nmach
is 1, there is one
.CW Mach
and one scheduler, and a processor started here parks in
.CW l.s 's
.CW _secondary
and never runs anything else.  What it is, is the proof that the two
pieces SMP will need are right before anything is built on them: that
the MPIDRs read out of the MADT are the ones the machine answers to,
and that PSCI's conduit and calling convention are what this kernel
thinks they are.
.PP
The proof is that the value comes back from the other side.  The MPIDR
handed to
.CW CPU_ON
is the firmware's; the MPIDR that appears in the slot is read from
.CW MPIDR_EL1
by the processor that woke up.  Each started processor is handed the
address of its own slot as
.CW CPU_ON 's
context id, which arrives in x0, so
.CW _secondary
needs no stack, no static base, no lock and no shared cursor, and is
four instructions.  The wait for them is bounded and the bound is
reported, so a processor that never answers is a number in a line
rather than a boot that stops.
.PP
The machine that discriminates is
.CW "-M virt,gic-version=3 -smp 17" ,
because QEMU packs sixteen processors into Aff0 and steps Aff1 for the
seventeenth.  Everywhere below that the MPIDR and the array index are
the same number and a reader that used the index would pass:
.IP
.DS L
.CW
acpi: 17 processors described, 17 enabled, 1 used
acpi: cpu0 uid 0 mpidr 0x0 gicr 0x0 enabled
 ... cpu1 through cpu14, mpidr 0x1 through 0xe ...
acpi: cpu15 uid 15 mpidr 0xf gicr 0x0 enabled
acpi: cpu16 uid 16 mpidr 0x100 gicr 0x0 enabled
cpu: this one is mpidr 0x0; entry 0x40000054, cpu_on through hvc
cpu: 16 started, 16 answered in 0ms, 16 mpidrs match; parked, conf.nmach 1
.R
.DE
.LP
The control is the same kernel with
.CW CPU_ON 's
target changed from the MADT's MPIDR to the array index, which is the
bug a smaller machine could not have caught:
.IP
.DS L
.CW
cpu: mpidr 0x100 cpu_on: invalid parameters (-2)
cpu: 15 started, 15 answered in 3ms, 15 mpidrs match; parked, conf.nmach 1
.R
.DE
.LP
Fifteen of the sixteen start, because for them the two numbers agree,
and the sixteenth is refused by name.  The
.CW gicr
column is zero throughout: QEMU describes its redistributors in a GICR
structure rather than per-GICC, which is allowed and is why the GICR
base is read from both places.
.PP
.B "The conduit, and a bug that had been there since the beginning."
Which instruction reaches PSCI is the firmware's to say \(em a guest at
EL1 under a hypervisor uses HVC, a machine whose firmware sits at EL3
uses SMC \(em and the FADT's ARM Boot Architecture Flags, at offset 129
from FADT revision 5.1 onwards, carry the answer.
.CW acpi.c
reads them,
.CW l.s
has an
.CW HVC
and an
.CW SMC
entry point, and
.CW archvirtarm64.c 's
.CW psci()
picks between them.  Nothing said leaves it HVC, which is what this
board did before there was any ACPI.  QEMU's virt machine says
.CW "arm boot flags 0x3: psci yes, conduit hvc" ,
and that is a free self-check on the offset: the same firmware's
.CW SYSTEM_OFF
demonstrably answers HVC, so a
.CW PSCI_COMPLIANT
bit that read 0 would have meant the field was being read from the
wrong place.
.PP
Writing
.CW CPU_ON
found a bug that had been in
.CW psci
since it was written.  kencc passes the first argument in a register
and every other one on the stack \(em
.CW utils/7c/7.out.h
sets
.CW REGARG
to 0 and
.CW utils/7c/txt.c
uses it only for
.CW "curarg == 0"
\(em so the assembly stub, written on the assumption that a
four-argument call arrives in x0 through x3, got one right and three
wrong.  Nothing had caught it because the only PSCI calls this kernel
made were
.CW SYSTEM_OFF
and
.CW SYSTEM_RESET ,
which take no arguments, so the wrong registers were never read \(em
and the paragraph below turns that from an argument into a
measurement.
.CW CPU_ON ,
which takes three, answered
.CW INVALID_PARAMETERS
on every processor of every machine, on the first boot.  The fix is the
three loads
.CW os/inferno/boot/efi/aa64.s 's
.CW eficall
already had.  An assembly entry point whose extra arguments have never
been read is not evidence that it passes them.
.PP
That bug's discovery left two PSCI calls that had been in this board
since it was written and had never been observed to do anything.
.CW archshutdown 's
.CW SYSTEM_OFF
and
.CW archreboot 's
.CW SYSTEM_RESET
are reached only from a panic, and a panic's log ends at "Hit the reset
button" whether the machine then stopped or not.  Called deliberately
from
.CW main()
on the
.CW -kernel
path, each of them stops QEMU on its own \(em exit status 0, and the
.CW print
placed after the call never appears \(em where the same kernel with no
call at all is killed by the 45-second timeout, exit status 124.  They
were unaffected by the argument bug because they take no arguments,
which was an argument; this is a measurement.
.PP
The SMC half cannot be exercised here, because no QEMU aarch64 machine
this port can boot presents a firmware that wants it: the one that
does,
.CW "-M virt,virtualization=on" ,
runs the guest at EL2, and everything in
.CW l.s
\(em
.CW VBAR_EL1 ,
.CW ICC_SRE_EL1 ,
the whole trap path \(em is written for EL1.  That is a port, not a
test.  What can be shown is that the branch is reached and the
instruction is real, by forcing the conduit to SMC on a machine whose
firmware said HVC:
.IP
.DS L
.CW
acpi: arm boot flags 0x3: psci yes, conduit hvc
cpu: this one is mpidr 0x0; entry 0x40000054, cpu_on through smc
trap type 0 esr 0x2000000 pc 0x40000044
 r0 0xc4000003 r30 0x400646ac
.R
.DE
.LP
.CW pscismc
begins at
.CW 0x40000038 ,
so
.CW 0x40000044
is its fourth instruction, which is the
.CW SMC ;
.CW ESR_EL1
of
.CW 0x2000000
is exception class 0, unknown reason, which is what
.CW SMC
is on a machine with no EL3; and
.CW x0
holds
.CW 0xC4000003 ,
.CW CPU_ON 's
function number, where SMCCC wants it.  So the dispatcher picks the
branch, the assembler encodes the instruction and the argument arrives.
Whether an EL3 firmware answers it is untested and is written here as
untested.
.PP
.PP
.B "The architected timer, and a kernel that boots without a clock."
The GTDT is where a server says which interrupt its timer raises.  This
board had the number from the device tree QEMU also publishes, compiled
into
.CW io.h
as
.CW GicPPITimer ;
.CW acpi.c
reads all four GSIVs now and
.CW trap.c 's
.CW timerirq
is a variable rather than that constant, set from the non-secure EL1
one when the firmware names a different one.
.IP
.DS L
.CW
acpi: timer ns-el1 30 (io.h 30) flags 0x4 sec 29 virt 27 el2 26
acpi: cntctl 0xffffffffffffffff cntread 0xffffffffffffffff 0 platform timers
.R
.DE
.LP
Four independent numbers, all agreeing with the architecture's own PPI
assignments \(em 14, 13, 11 and 10, which are INTIDs 30, 29, 27 and 26
\(em and flags of 4, level-triggered, active high, always-on capable.
The two counter base addresses come back as all ones, which is ACPI's
"not provided" and is right: QEMU's
.CW virt
has no memory-mapped counter frame.  A reader that invented those
would have had to invent five consistent things.
.PP
Agreement does not show the value is used, and here the usual trick of
finding a machine where the two differ does not work: no QEMU
.CW virt
puts its timer anywhere else.  So the constant was made wrong instead.
Three kernels, one variable at a time, each measuring
.CW m->ticks
across a 300 ms delay from
.CW init0
after
.CW spllo()
\(em only
.CW clockintr()
advances that count, and
.CW clockpoll()
does not, so a count that stays put means no clock:
.IP
.DS L
.CW
io.h 30, acpi used     TICKPROBE irq 30 ticks 1 -> 25   [reached shell]
io.h 31, acpi used     timer: irq 30 from the firmware, io.h says 31
                       TICKPROBE irq 30 ticks 1 -> 27   [reached shell]
io.h 31, acpi unused   TICKPROBE irq 31 ticks 0 -> 0    [reached shell]
.R
.DE
.LP
The middle one is the point: with the compiled-in number deliberately
wrong, the clock runs anyway, on the number the firmware gave.  The
third is why a boot log alone would not have shown it \(em all three
reach an interactive shell, because nothing between
.CW main()
and the prompt needs the timer interrupt.  A kernel with no clock looks
exactly like a kernel with one until something asks it the time.
.PP
The first probe of this was in the wrong place and said so: put in
.CW main()
after
.CW startcpus() ,
it read
.CW "ticks 0 -> 0"
on a kernel whose timer was entirely correct, because interrupts are
masked for the whole of
.CW main()
and are not enabled until
.CW init0
calls
.CW spllo() .
.PP
.B "The console the firmware names, and why the PC's shape does not port."
The SPCR is where a server says where its console is, and
.CW os/inferno/pc
has read it since section 7.  On arm64 the plan said this was harder
than it looks because the console is up long before
.CW acpiinit
runs.  It is harder than that: the PC's shape does not work here at
all, and finding out why took falsifying the constant rather than
reading the code.
.PP
Reading the table is the easy half and it is right on every field:
.IP
.DS L
.CW
acpi: uart 0x9000000 (mem.h 0x9000000) type 0x3 space 0 access 3 gsi 33 baud 3
.R
.DE
.LP
Interface type 3 is a PL011, address space 0 is system memory, access
size 3 is DWord, and baud 3 is 9600 in the SPCR's own encoding \(em all
correct for QEMU's
.CW virt .
The
.CW gsi
is the one worth pausing on: 33 is the number this board had compiled
in from the device tree, with a comment deriving it by hand as
"pl011@9000000's SPI is 1 -> GIC IRQ 33".  The firmware arrives at the
same number by a different route, which is a check on both.
.PP
.B "Then the control, which failed in a way worth keeping."
No QEMU
.CW virt
puts its console anywhere else, so the constant was falsified instead,
as with the ECAM and the timer.  The kernel did not go quiet.  It died:
.IP
.DS L
.CW
Synchronous Exception at 0x0000000040064E20
  ...  X2 0x0000000009030000  ...
ASSERT [ArmCpuDxe] .../DefaultExceptionHandler.c(343)
.R
.DE
.LP
That is EDK2's own exception handler, with the falsified base in
.CW X2 .
.CW uartconsole()
programs the PL011 in
.CW main() ,
long before
.CW trapinit()
installs a vector table, so a wrong base is a data abort the kernel
cannot take: the firmware's handler gets it and the kernel never
reaches
.CW acpiinit()
at all.  Reading the SPCR there and moving the console afterwards \(em
which is what
.CW os/inferno/pc
does, and what this board did first \(em is useless on precisely the
machine the code exists for.
.PP
.B "So the walk was split."
.CW acpitables()
parses every table into globals and prints nothing; it runs in
.CW main()
right after
.CW confinit() ,
before anything touches the UART.
.CW spcrconsole()
moves the base there, also silently, because there is nowhere to print
yet, and records what it did.
.CW acpiinit()
keeps its old place after
.CW printinit()
and prints what the two of them found, then acts on everything that is
not the console.  Nothing in the early half allocates, locks, or keeps
a pointer into the tables, so running it that early costs nothing.
.PP
With that, the same falsified constant gives a boot instead of a
firmware exception, and the three arms separate:
.IP
.DS L
.CW
mem.h right, spcr used     2751 bytes  [shell]
    spcr: console already where the SPCR says
mem.h wrong, spcr used     2777 bytes  [shell]
    spcr: console moved from 0x9030000 to 0x9000000; this line is proof
mem.h wrong, spcr unused   5184 bytes  [NO SHELL]
.R
.DE
.LP
The middle one is the result.  The compiled-in base is an address that,
in the third arm, kills the kernel inside the firmware's exception
handler before it prints a byte; with the SPCR read first, the console
is at the right place before anything touches it and the whole boot log
arrives \(em twenty-six bytes more than the first arm, which is the
extra line saying so.  The third arm is the control and it is the one
that shows the second arm is not luck: 5184 bytes of EDK2 register dump
and no shell.
.PP
The interrupt moved too.
.CW uartconsolesetup()
took the SPCR's global system interrupt when it differs from the
board's 33, which on every machine here it does not.  What is still not
acted on: the access size, the register bit width and the baud rate.
The first two matter for the SBSA generic UART's 32-bit-only variant,
interface type 0x0D, and the third only for a firmware that hands over
at a rate the kernel is expected to keep.  Interface types this board
accepts are 3, 0x0D and 0x0E; anything else \(em a 16550, say \(em is
named and refused rather than driven with PL011 register offsets.
.PP
What is left of ACPI is the IORT, which is what an SMMU would be found
through; it is read and checksummed and not parsed.
And a started processor still only parks.  Giving it a
.CW Mach ,
a stack and a scheduler is SMP, which is item 9 and wants
.CW MAXMACH
above 1, a real
.CW cmpswap
rather than the spl-masked one
.CW archvirtarm64.c
has, and per-processor GIC redistributor setup.
.NH 1
MSI-X on arm64, and an interrupt that was allocated and dead
.PP
On arm64 a PCI MSI is a memory write and something has to turn it into
an interrupt.  A GICv2 machine does it with an MSI frame: a page whose
.CW SETSPI
register takes an SPI number as its data and raises that SPI.  A GICv3
machine does it with an ITS, which translates a device id and an event
id into an LPI and wants command queues and two levels of table.  Which
one a machine has is in the MADT \(em GIC MSI frame structures, type
0x0D, and GIC ITS structures, type 0x0F \(em so the board asks the
firmware rather than inferring it from the GIC version.  Three machines
give three answers:
.IP
.DS L
.CW
gic-version=2          acpi: gic msi frame 0 at 0x8020000 flags 0x1 spi 80..143
gic-version=3          acpi: gic its 0 at 0x8080000
gic-version=3,its=off  acpi: no gic msi frame and no its; msi is not available
.R
.DE
.LP
The frame's range is the reason
.CW io.h 's
.CW GicIRQMax
is 224 and not 96: QEMU puts the MSI SPIs at 80..143, above the 32
virtio slots that start at 48.
.PP
.CW os/inferno/virtarm64/msivirtarm64.c
drives the v2m half.  One SPI per vector out of the frame's range,
.CW pcimsixenable()
programming the device's table with the frame's
.CW SETSPI
address and the SPI number as data, and
.CW intrenable()
for the handler.  There is no affinity to set, because the frame raises
an ordinary SPI and
.CW gicenable()
already routes SPIs to processor 0.  The ITS half is not written.
.PP
.B "It did not work, and the thing that looked like proof was not."
The first version allocated its vectors, programmed the table, reported
.CW "sdN (nvme): msix, 2 of 65 vectors" ,
and read the disk successfully.  None of that is evidence.
.CW os/inferno/port/sdnvme.c 's
completion wait is
.CW "while(!wdone(ws)){ nvmeintr(nil, ctlr); tsleep(ws->sleep, wdone, ws, 10); }"
\(em it polls the completion queue on a timer, so a read succeeds
whether or not any interrupt is delivered.  The line that does prove it
is the driver's own
.CW "nvme: msix vector %d delivered" ,
printed on each vector's first interrupt, and it was absent.  The same
.CW ARM64-DISK-OK
appeared with the mechanism working and with it entirely dead, which is
the clock's shape again: an outcome that survives its own cause.
.PP
.B "Then a probe that separates the two halves."
The question is whether the frame reaches the distributor at all, and
that can be asked with interrupts still masked and no device involved:
write an unallocated SPI number to the frame's
.CW SETSPI
register and read
.CW GICD_ISPENDR .
.IP
.DS L
.CW
MSIPROBE spi 143 ispendr 0x0 -> 0x0     (before)
MSIPROBE spi 143 ispendr 0x0 -> 0x8000  (after)
.R
.DE
.LP
Nothing became pending, so the fault was the controller's and not the
device's.  A GICv2m frame raises an MSI by
.I pulsing
the SPI \(em QEMU's
.CW hw/intc/arm_gicv2m.c
calls
.CW qemu_irq_pulse() ,
raise and drop in one step \(em and a level-triggered input latches
nothing from a pulse: the pending bit clears as the line falls.
.CW GICD_ICFGR
has to say edge, two bits per interrupt and sixteen to a register, and
.CW gicenable()
had never touched it.
.CW gicedge()
in
.CW trap.c
does now.
.PP
With that, both vectors deliver:
.IP
.DS L
.CW
acpi: gic msi frame 0 at 0x8020000 flags 0x1 spi 80..143
msix: v2m frame at 0x8020000, spi 80..143, 64 vectors
msix: sdN (nvme) tbdf 0xc001000 vec 0 -> spi 80: enabled
msix: sdN (nvme) tbdf 0xc001000 vec 1 -> spi 81: enabled
sdN (nvme): msix, 2 of 65 vectors
nvme: msix vector 0 delivered
nvme: msix vector 1 delivered
ARM64-DISK-OK /dev/sdN0/data read 512 bytes
.R
.DE
.LP
and the GICv3 machine says what it can and cannot do rather than
failing quietly:
.CW "msix: this machine has an ITS and no v2m frame; msi-x is not"
.CW available ,
after which
.CW sdnvme
falls back to INTx and reads its disk.
.PP
The probe stayed, as a silent self-test in
.CW msiinit() :
it writes an unallocated SPI to the frame, checks
.CW ISPENDR ,
clears it again, and prints only if the path is dead.  A boot log that
says nothing there means the MSI path was tested on this machine and
works, which is a better thing for a log to mean than that nobody
looked.
.NH 1
If a guest counts
.PP
Everything above takes "bare metal" literally.  Relax it to "the
operating system of the machine, talking to whatever the platform
presents, real or paravirtual" and the answer changes completely,
because the expensive part of this port was never the hypervisor: it
was the device model behind it.
.PP
There are three device models worth the name, and the tree's position
in each is different.
.IP "\f(CWvirtio\fP" 12
The device model of every KVM host, which is Compute Engine, DigitalOcean,
Linode, Vultr's cloud instances, Hetzner Cloud, OpenStack and Proxmox.
.CW ethervirtio10
and
.CW sdvirtio10
are linked into
.CW pc64
and work, and with UEFI now booting there is nothing left to write.
This is not a GCE-specific win, as this document said before it: it is
most of the market, and GCE is only the one with a documented import
path for an image nobody recognises.
.IP "\f(CWXen\fP" 12
Three shapes, and they cost very different amounts.  See below.
.IP "\f(CWHyper-V\fP" 12
Azure.  No PCI device at all for disk or network: VMBus, with
.CW storvsc
and
.CW netvsc
as its clients.  Unchanged from section 4 \(en still the largest item.
.NH 2
The three shapes of a Xen guest
.IP "\f(CWPV\fP" 10
The classic paravirtualised guest: no hardware virtualisation, the
guest's page tables are the hypervisor's business, and every privileged
operation is a hypercall.  It is the most work of the three and the
least useful: AWS dropped PV AMI support on everything modern, and a PV
kernel is a different port, not a driver.  Do not start here.
.IP "\f(CWHVM\fP" 10
A full machine: firmware, an emulated NIC and an emulated IDE
controller from the device model in dom0, and PV drivers optional and
only for speed.  This was the cheapest Xen by a wide margin and it is now free, because
the one driver it wanted is in.
.CW pc64
already had the NICs \(en
.CW ether8139 ,
.CW etherigbe ,
.CW ether82563 ,
whichever the host presents \(en and lacked IDE.
.CW os/inferno/pc/sdata.c ,
this tree's own, is not the driver to use: it was written against the
older Inferno
.CW SDifc ,
and since 9front's
.CW devsd
and
.CW sd.h
were taken into
.CW os/inferno
it does not compile here at all.
.CW os/9front/pc/sdide.c
is written against exactly the
.CW sd.h
this tree now has, so it is copied in under the flavour rule and
compiles unchanged, with no edits of any kind, linked as
.CW "sdide pci sdscsi" .
.PP
Verified live on
.CW "qemu -machine pc"
\(en i440fx and PIIX3 IDE, which is the machine a Xen HVM domain's
device model presents: both channels enumerate
.CW ( "QEMU HARDDISK"
with DMA and LBA48,
.CW "QEMU DVD-ROM"
as ATAPI),
.CW /dev/sdC0/data
returns the sector the host wrote into it, and DHCP gets a lease over
the emulated NIC \(en tested with both an RTL8139 and an e1000, since
which of the two a host offers varies.  That is the whole Xen HVM
device set working at once.
.IP "\f(CWPVH\fP" 10
Hardware virtualisation, no emulated devices, no firmware: the guest is
entered directly and everything it talks to is a PV device.  The entry
half of this is done and verified \(en see below \(en and the device
half is xenbus and XenStore, grant tables, event channels, and then
.CW blkfront
and
.CW netfront .
That is a bus and two class drivers, the same order of magnitude as
Azure's VMBus, and it is what a PVH guest needs before it can read a
disk or send a packet.
.NH 2
The entry point, which is done
.PP
The x86/HVM direct boot ABI is what a PVH guest is started through, and
it is not Xen's alone: QEMU's own
.CW -kernel
loader, Firecracker and Cloud Hypervisor all implement it for an ELF
kernel with a
.CW XEN_ELFNOTE_PHYS32_ENTRY
note.  One entry point, four hosts.
.PP
.CW os/inferno/pc64/l.s
has
.CW _pvhentry
now.  The ABI hands over 32-bit protected mode with flat segments,
paging off and interrupts off, which is exactly the state
.CW _protected
already expects, so the entry records
.CW BX
\(en the physical address of a
.CW "struct hvm_start_info"
\(en and jumps.
.CW os/inferno/pc/bootargs.c 's
.CW pvhargs
turns that structure into the boot arguments the kernel already reads:
the memory map into
.CW *e820= ,
merged and bounded for the same reasons the EFI loader's
.CW memconf
is, the RSDP into
.CW *acpi=
(a PVH guest has no BIOS area to scan for one), and the command line
into configuration lines.
.CW tools/aout2elf
puts the kernel in an ELF with that note, beside
.CW tools/aout2efi
which puts it in a PE.
.PP
Verified:
.CW "qemu-system-x86_64 -kernel ipc64.elf -append console=0" ,
with no firmware involved in the load, prints an
.CW *e820=
built from
.CW hvm_start_info ,
finds its memory, reaches
.CW "Welcome to Inferno..."
and spawns
.CW "sh -n /dis/init" .
Three of six boots reach the interactive
.CW ;
prompt, two panic and one fails a module load \(en the same rate and
the same two faults
.CW ( "movp: bad dv"
and a general protection violation) the other two boot paths show, so
the PVH path is no worse than they are and no better.
What that verifies is QEMU's implementation of the ABI.  Booting as a
Xen PVH domU is the same entry point and the same structure, but no
Xen runs on this host and it is not claimed.
.PP
One trap is worth repeating from
.CW tools/aout2elf 's
own comment, because it cost a boot: QEMU scans the first 8192 bytes
of a
.CW -kernel
file for a multiboot header before it looks for the PVH note, and
.CW l.s
carries one 0x20 bytes into the text.  With the text at file offset
0x1000 QEMU took the multiboot path, loaded text and data contiguously
over an ELF laid out with data on its own page, and the kernel printed
nothing whatever.  The text sits at 0x3000 so that header falls
outside the window.
.NH 2
So what does it cost, per platform
.PP
Counting only what is not already in the tree:
.IP
.nf
KVM / virtio        nothing.  Works today.
QEMU, Firecracker,
Cloud Hypervisor    nothing.  The PVH entry is in.
Xen HVM             nothing.  Works today: IDE landed.
Xen PVH             xenbus, grant tables, event channels,
                    blkfront, netfront.
AWS Nitro           multi-vector MSI-X, then ENA.
Azure               VMBus, storvsc, netvsc.
Rented metal        nothing, for a box with an Intel 1G NIC
                    and AHCI or NVMe.
.fi
.PP
The order that follows from this is not the order section 5 had.  A
KVM guest costs nothing and is most of the market; the PVH entry costs
nothing more and adds the three microVM monitors; Xen HVM costs one
driver.  All of that is cheaper than ENA, and none of it needs the
multi-vector MSI-X that ENA does.
.NH 1
What each provider needs that is not here
.PP
The network device is what discriminates the list.  Everything else is
shared.
.IP "\f(CWENA\fP\ (AWS)" 12
The only NIC on any Nitro instance.  It implements no INTx path in
hardware: MSI-X is not an optimisation there, it is the only way to
receive an interrupt.  So AWS costs MSI-X plus the driver.  Develop it
on a
.CW t3
or
.CW m5
virtual instance, which presents the same PCIe device as
.CW *.metal
for a fraction of the price, and move to metal only when it works.
.IP "\f(CWvirtio-net\fP\ (GCE)" 12
Already driven, by
.CW ethervirtio10 .
This is the cheapest first cloud target in the whole plan and should be
attempted before any driver is written.  gVNIC is Google's own adapter
and is needed only for the higher-bandwidth shapes; it is a second
driver, not a prerequisite.
.IP "\f(CWnetvsc\fP\ (Azure)" 12
Not a NIC driver.  VMBus is a whole bus \(en channel setup through
hypercalls, ring buffers in guest pages, a synthetic interrupt
controller \(en with
.CW storvsc
and
.CW netvsc
as clients.  It is the largest single item on this plan and it should
be last.
.IP "\f(CWIntel\ and\ Broadcom\fP\ (rented metal)" 12
An i210, i350, X550, X710 or a Broadcom NetXtreme.  The first three
are driven today by
.CW etherigbe ,
.CW ether82563
and
.CW etherx550 ,
all through INTx, which those parts do support.  X710 and E810
(\f(CWi40e\fP, \f(CWice\fP) are not driven and would want MSI-X as
well.  Choose the first machine to rent by its NIC, not its brand.
.PP
Storage is easier.
.CW sdnvme
covers AWS (EBS is presented as NVMe on Nitro) and nearly every rented
metal box;
.CW sdiahci
covers the SATA ones.  OCI bare metal is the exception, needing either
an iSCSI initiator or a root compiled into the kernel image.
.PP
The console is easier still.  A 16550 at
.CW 0x3F8 ,
which
.CW uarti8250
drives, is what EC2 Serial Console, OCI's console connection and IPMI
serial-over-LAN all present, and a machine that puts it elsewhere is
now handled: see the next section.
.NH 1
The console ACPI names
.PP
The port was assumed rather than discovered, and a machine whose
console is not the 16550 at
.CW 0x3F8
was silent for that reason alone.  It is now read out of ACPI's SPCR
table (Serial Port Console Redirection, in the ACPI registry), which
is what a server's firmware writes to say where its console is.
.PP
.CW os/inferno/pc/archacpi.c
gained
.CW acpispcr() ,
which finds the table the same way
.CW acpimcfg()
finds MCFG and hands back the address space, the address, the access
size, the interrupt and the baud rate; it sets
.CW spcrconsole
beside
.CW pciecam .
.CW os/inferno/pc/uarti8250.c
gained a third
.CW Ctlr
and
.CW Uart ,
a
.CW mmio
pointer and a register
.CW shift
in
.CW Ctlr ,
and
.CW "csr8r, csr8w and csr8o"
as functions rather than macros, so a register access can go to
memory as well as to a port.
.CW i8250spcrconsole()
does the move, and
.CW os/inferno/pc64/main.c
calls it immediately after
.CW archinit() ,
which is the first moment the tables are mapped.
.PP
That ordering has a consequence worth stating plainly: the prints
before
.CW archinit()
still go wherever
.CW console=
sent them.  On a machine whose console is elsewhere they are lost, and
everything from the switch onwards arrives.  Reading SPCR earlier
would mean mapping the tables earlier, since the boot page tables in
.CW os/inferno/pc64/l.s
cover only the first 468 MiB and ACPI's tables on a 1 GiB machine sit
above that.
.PP
Verified under QEMU q35 with the table injected by
.CW "-acpitable sig=SPCR,rev=2,data=..." ,
two serial ports written to separate files:
.IP \(bu 4
SPCR naming
.CW 0x2F8 :
COM1 ends with
.CW "spcr: console 16550 at port 0x2f8 irq 3"
and COM2 begins with
.CW "spcr: console is SPCR" ,
carrying every line from there to the end of the boot \(en 2627 bytes
on the first port, 4153 on the second.
.IP \(bu 4
SPCR naming
.CW 0x3F8 :
.CW "spcr: console already at port 0x3f8" ,
no move, 6754 bytes on COM1 and nothing on COM2.
.IP \(bu 4
No SPCR at all: no
.CW spcr:
line, 7889 bytes on COM1, nothing on COM2.  The fallback is intact.
.IP \(bu 4
SPCR naming system memory at
.CW 0xFEB00000
with access size 3:
.CW "spcr: console 16550 at 0xfeb00000 stride 4 irq -1" ,
so the address-space decode, the stride arithmetic and the
.CW vmap
all work, and the console then moves to an address with no UART behind
it and the boot goes silent, which is what should happen.  The
byte-level register access over memory is
.I not
verified: no QEMU x86 machine presents a memory-mapped 16550 to point
the table at.  That half is written and compiled and nothing more.
.NH 1
A vector per queue
.PP
Single-vector MSI-X was already there.  What was missing was the
thing ENA and the current Intel and Mellanox parts are actually
built around: several vectors on one device, a queue behind each,
each with its own handler and its own idt vector.
.PP
.CW intrenable()
cannot express it \(en its
.CW irq
argument has no room for "the third of this device's MSI-X vectors"
\(en so there is a second entry point.
.CW os/inferno/pc/irq.c 's
.CW intrenable()
was split: the list work is now
.CW intrenablev() ,
which takes a filled
.CW Vctl ,
and
.CW intrenable()
fills one the old way while
.CW msixintrenable()
fills one with a new
.CW Vctl
member,
.CW msixvec ,
set to the table index.
.CW intrenable()
sets it to \-1, which is what says "not an MSI-X request".
.CW os/inferno/pc/mp.c 's
.CW msiintrenable()
then takes the MSI-X path whenever
.CW msixvec
is not \-1, without consulting the
.CW *msix
flag \(en a driver that names a vector has already said what it wants
\(en and
.CW msixirqenable()
programs that entry rather than entry 0.
.CW msixirqdisable()
masks the one vector through a new
.CW os/inferno/port/pci.c
call,
.CW pcimsixmask() ,
instead of turning the whole capability off underneath the device's
other queues.
.PP
The two entry points reach
.CW ../port 's
drivers as the function pointers
.CW pcimsixintrenable
and
.CW pcimsixintrdisable ,
declared in
.CW os/inferno/port/pci.h
and set by
.CW irqinit() ,
the same shape as
.CW pciecam .
They are nil on every board but
.CW pc64 ,
and a driver must test before using them.
.PP
.CW os/inferno/port/sdnvme.c
is the first driver to use them, and it is the right first one:
NVMe fixes the admin completion queue on interrupt vector 0 and lets
the Create I/O Completion Queue command name the vector for every
other queue, so two vectors is the smallest arrangement that proves
anything.  The driver takes vector 0 and vector 1 when the device's
table has at least two entries, sets
.CW "IV<<16"
in dword 11 of that command, and counts the interrupts each vector
delivers in a new
.CW Ivec
structure.
.PP
Verified under QEMU q35 with
.CW "-device nvme" ,
booting
.CW ipc64dev :
.DS L
.CW
msix: sdN (nvme) tbdf C001000 msixvec 0 vector 97 cpu 0: enabled
msix: sdN (nvme) tbdf C001000 msixvec 1 vector 105 cpu 0: enabled
sdN (nvme): msix, 2 of 65 vectors
nvme: msix vector 0 delivered
sdN (nvme): using 1 submit queues
inquiry QEMU NVMe Ctrl
nvme: msix vector 1 delivered
DEVTEST: /dev/sdN0/data sector 0 (512 bytes): INFERNO-MSIX-TEST-SECTOR
.R
.DE
Two distinct idt vectors, 97 and 105; vector 0 delivering during the
admin work; vector 1 delivering only once the I/O completion queue
had something on it; and the sector the host wrote read back through
it.  The
.CW *msix
flag was not set for that boot \(em the driver asked directly.
.PP
The single-vector path the flag drives was re-checked after the
refactor, because nothing in the new test covers it any more:
.CW sdnvme
asks for two vectors directly, so it no longer takes that route at
all.  Booting
.CW ipc64dev
with
.CW "*msix=1"
and a modern virtio disk and NIC
.CW ( disable-legacy=on )
gives
.DS L
.CW
msix: ether0 tbdf C001800 msixvec 0 vector 65 cpu 0: enabled
msix: sdF (virtio10) tbdf C001000 msixvec 0 vector 97 cpu 0: enabled
DEVTEST: /dev/sdF0/data sector 0 (512 bytes): INFERNO-MSIX-TEST-SECTOR
DEVTEST: /net/ether0 DHCP-FAIL no response
.R
.DE
and the same boot without the flag gives
.CW "DHCP-OK ip=10.0.2.15"
and the same sector.  So the disk works either way and the NIC goes
silent under MSI-X \(em which is the behaviour
.CW os/inferno/pc/mp.c 's
comment already describes, not a regression: a virtio device sends
nothing until its driver writes a vector into
.CW queue_msix_vector ,
and
.CW ethervirtio10
does not.  That is why the flag is opt-in.
.PP
The
UEFI path was rebooted after all of this \(em
.CW scripts/mkinferno-efi-iso.sh
then
.CW scripts/qemu-inferno-efi.sh
\(em and reaches its interactive prompt, which matters because
.CW irqinit()
is reached through
.CW trapinit()
and that early sequence is not multiboot's.
.PP
.B "But the device was not on that boot, and when it was put there it
.B "did not attach."
Every run above is the multiboot
.CW -kernel
path, where SeaBIOS assigns the BARs.  Under OVMF the same kernel with
the same
.CW "-device nvme"
prints
.DS L
.CW
vmap pa=c000000000 size=16384 pc=0x2b8ccb
nvme: can't vmap bar0
.R
.DE
and stops there.  OVMF on
.CW q35
puts a 64-bit BAR at 0xc000000000, 768 GiB, and
.CW os/inferno/pc64/mmu.c 's
.CW vmap()
refused any physical address at or above
.CW VMAPSIZE ,
a constant 512 GiB in
.CW mem.h .
Every cloud machine boots UEFI, so all of the above was unreachable
where it is meant to be used, and so was every other PCIe device whose
BAR the firmware puts up there.
.PP
The ceiling comes from the machine now.  This kernel's mapping is the
identity, so a physical address is also the virtual address it is
reached at, and two things bound it: what the processor can address
physically \(em CPUID 80000008H, EAX bits 7..0 \(em and what the
four-level page table this kernel builds can name, which is the low
canonical half, 2**47.  The smaller of the two, floored at the old 512
GiB, computed on the first
.CW vmap()
since
.CW cpuidentify()
has run by then.  With it the UEFI boot gives the same six lines the
multiboot one does, ending in
.CW INFERNO-MSIX-TEST-SECTOR .
That the CPUID read is what drives it, rather than the fallback,
follows from the number: the fallback is 512 GiB and would still refuse
0xc000000000.
.PP
One thing to know before trying to reproduce the failure: the firmware
sizes its own 64-bit MMIO window from the same CPUID leaf.  Booting
with
.CW "-cpu qemu64,phys-bits=36"
does not reproduce it, because OVMF then places the BAR below 4 GiB
instead.  The two ends move together, which is why the bug appears only
on a machine wide enough to have somewhere high to put it \(em and why
it was invisible for as long as the device was only ever attached to
the multiboot path.
.PP
Two fallbacks were checked as well.  With
.CW "-device nvme,msix_qsize=1"
the device's table holds one entry, the driver takes the old
.CW intrenable()
path, no
.CW msix:
line is printed and the sector still reads.  And on
.CW os/inferno/virt
under
.CW qemu-system-riscv64 ,
where
.CW pcimsixintrenable
is nil because that board has no MSI-X plumbing at all, the same
driver falls back the same way and reads the same sector \(em which is
the check that matters, since
.CW sdnvme.c
is a
.CW ../port
file shared with every board.
.PP
The release path was checked too, because masking a vector and
leaving the capability enabled is right only while the device's other
queues are still running.
.CW msixintrdisable()
walks
.CW vctl[]
after unlinking and calls
.CW pcimsixdisable()
when nothing on that device is left.  Exercising it needed a way to
detach a controller from a booted kernel, which
.CW os/inferno/port/devsd.c
already has:
.CW "config switch off spec N"
written to
.CW #S/sdctl
runs the controller's
.CW disable() .
.CW os/inferno/init/pc64devinit.b
now does that and then checks the device has gone:
.DS L
.CW
sdN (nvme): msix vector 0 delivered 5
sdN (nvme): msix vector 1 delivered 1
DEVTEST: MSIX-DETACH-OK sdN gone after switch off
DEVTEST: MSIX-REATTACH not available: sd type cannot probe
.R
.DE
Five interrupts on the admin vector, one on the I/O queue's, both
released, and the device gone.  The last line is recorded rather than
fixed: devsd's
.CW "switch on"
needs an
.CW SDifc
.CW probe() ,
and
.CW sdnvme 's
is nil, so a controller detached this way cannot be put back, and no
boot therefore reaches a second
.CW nvmeenable
after an
.CW nvmedisable .
Two of three boots reached that point; the third died in the heap
fault first.
.NH 1
Joining the database
.PP
A rented fleet is not a laboratory: instances come up, take an address
from the provider's DHCP, do some work and go away.  The tree's network
database is
.CW /lib/ndb/local ,
a text file, and a machine is in it because somebody wrote it there.
That is the wrong shape for anything this plan is aiming at.
.PP
Half of the answer was already in the tree and unconnected to the other
half.
.CW registry(4)
is a file server for services that come and go: an entry lives exactly
as long as the file descriptor that created it, and vanishes when that
descriptor closes, when the process holding it dies, or when the
connection to a remote registry drops.  It has an
.CW index
of every entry and an
.CW event
file whose read blocks until something changes.
.CW appl/svc/registry.sh
already exports one over
.CW "tcp!*!registry" .
What nothing did was let a reader of the network database see any of
it:
.CW cs(8)
opens
.CW /lib/ndb/local
and
.CW /net/ndb
through
.CW attrdb(2)
and knows nothing about registries.
.PP
.CW ndb/regndb
is the missing link \(em a file server that renders a registry as an
.CW attrdb(6)
database, and
.CW ndb/register
is the command that joins one.  Both are in
.CW appl/cmd/ndb
and documented in
.CW regndb(4) .
The design and what was measured are in
.CW doc/inferno-ndb.ms ;
three things decide whether such a bridge works and all three are
recorded there: the served file's
.CW Qid.vers
has to move on every rendering or
.CW attrdb
caches the first version forever; the rendered file has to begin with a
.CW database=
entry naming
.CW /lib/ndb/local
so the static entries come with it and
.CW cs
needs no change; and only registrations carrying the key attribute may
become host entries, because a registry holds a mixture.
.PP
It was run on
.CW os/inferno/virtarm64/virtarm64ndb ,
the
.CW virtarm64
kernel with
.CW os/inferno/init/ndbinit.b
as its init, under QEMU
.CW "-M virt -cpu cortex-a72" .
Three phases.  A machine joins over a pipe-mounted registry and is
resolved by
.CW attrdb
and by
.CW ndb/query ;
its process is killed and the same lookups come back empty:
.IP
.DS L
.CW
NDB-EMPTY-OK joiner1 absent before anyone joins
NDB-JOIN-OK joiner1 ip=10.42.0.7 after 100 ms
NDB-CHANGED-OK quiet database reports no change
NDB-KILL pid 11
NDB-CHANGED-OK Db.changed() true 100 ms after the leave
NDB-LEAVE-OK joiner1 gone after 0 ms
.R
.DE
.LP
Then the awkward registrations \(em a value with a space, a value with
a quote, and an attribute called
.CW regsvc ,
which is the name
.CW regndb
gives the registry's own service name:
.CW "note='it''s'"
and
.CW "desc='a b c'"
round-trip through both quoting schemes, and the registration's own
.CW regsvc
is dropped and counted rather than written out beside the real one.
.PP
Then the registry is exported over a real TCP connection on loopback
and mounted back, a second machine joins through the mount, and the
connection is broken with
.CW hangup
\(em nothing clunked, nothing unmounted, the way a machine that has
gone away breaks it:
.IP
.DS L
.CW
NDB-NET-MOUNTED /mnt/netreg over tcp!127.0.0.1!6699
NDB-NET-JOIN-OK joiner2 ip=10.42.0.8 after 100 ms
NDB-NET-HANGUP tcp!127.0.0.1!6699
NDB-NET-LEAVE-OK joiner2 gone 100 ms after the connection dropped
.R
.DE
.PP
.PP
.B "Then cs itself, which found a bug."
Everything above looks names up through
.CW attrdb
and
.CW ndb/query
\(em the same library and the same file
.CW cs
would open, but not the same program.  A fourth phase starts the real
connection server with
.CW "-f /mnt/regndb/ndb"
and asks it to translate a name, then kills the machine and asks
again.  The second question is the point, and
.CW cs
kept answering: it went on translating
.CW joiner3
to
.CW 10.42.0.10!564
after the registering process was killed and the rendered file had
gone back to zero entries.
.PP
.CW appl/cmd/ndb/cs.b 's
.CW refresh()
re-read the database and left the cache alone, and
.CW xlate()
consults the cache before it consults
.CW ndb
at all.  Against a static
.CW /lib/ndb/local
that only meant a stale answer for the 120 seconds a cache entry
lives.  Against a registry it means the opposite of what
.CW regndb
is for: an entry disappears the moment a machine leaves, and the whole
purpose of the refresh is that the next query must miss.
.CW refresh()
drops every cached answer now, which is what re-reading the database
has to mean.  The refresh check also compared the control write for
exact equality, so
.CW "echo refresh > /net/cs"
\(em the obvious way to do it from a shell \(em came back
.CW "bad format request" ;
a trailing newline is accepted.
.IP
.DS L
.CW
NDB-CS-STARTED /net/cs after 100 ms, -f /mnt/regndb/ndb
NDB-CS-OK cs translated joiner3 to '/net/tcp/clone 10.42.0.10!564'
NDB-CS-GONE-OK cs no longer translates joiner3 ('')
.R
.DE
.LP
That was reproduced and fixed against the hosted
.CW emu
first, which turns a three-minute kernel boot into a five-second run,
and then confirmed on the booted arm64 kernel.  Worth remembering: a
Limbo program that a kernel test drives is usually reachable from
.CW emu-g
with the same arguments, and the loop is forty times shorter.  Two
gotchas in that path on this branch \(em
.CW emu
cannot create a directory (its
.CW setid()
runs Dis as uid \-1), so a mount point has to exist on the host
filesystem first; and a shell heredoc into
.CW emu 's
stdin never sees EOF, so the script has to be a file.
.PP
Two kernels talking over a wire have not been run, and the registry was
exported with no authentication.  Both are named in
.CW doc/inferno-ndb.ms
as what is demonstrated rather than done.
.NH 1
Towards a second processor on arm64
.PP
Item 9's arm64 half is the only thing left on this plan that does not
need an account or a rented box, so it is what this round went at.  It
lists a
.CW Mach ,
a stack and a scheduler per processor,
.CW MAXMACH
above 1, a real
.CW cmpswap
and per-processor redistributor setup.  Four of those are done, and
the list was missing the one that has to come first.
.PP
.B "The atomics were spl-masked C."
.CW cmpswap() ,
.CW ainc()
and
.CW adec()
in
.CW archvirtarm64.c
masked interrupts, did the read-modify-write and restored \(em correct
on one processor and silent about what another is doing to the same
word.  They are exclusive-monitor loops in
.CW l.s
now, with LDAXRW for the acquire side and STLXRW for the release side,
beside
.CW _tas ,
which already was one.  This tree has the counter-example for why the
barriers are not decoration: emu's
.CW unlock()
had no release barrier and the scheduler deadlocked in roughly one run
in two, with a signature that reads as a lock bug and is a
memory-ordering one.
.PP
7l could not encode them.  7a has accepted LDAXR and STLXR all along
and
.CW asmout.c
had the encodings, but the
.CW oprange
entry that maps them onto the ldxr/stxr forms was missing, so 7l
answered "illegal combination LDAXRW NONE NONE REG".  Two rows were
also wrong: ALDAXRW had o2 set, which encodes LDLARW \(em a load that
does not take the exclusive monitor at all, so any compare-and-swap
built on it would spin forever \(em and ASTLXP/ASTLXPW had their sizes
swapped.  The encodings 7l emits were checked against an independent
disassembler (assembled as data by clang, read back by objdump) rather
than against a second reading of the manual.
.PP
.B "And a second 7l bug, found by a line of C that lied."
A literal too wide for an instruction goes in 7l's constant pool, and
.CW addpool()
chose the pool entry's width from the mnemonic: eight bytes for
.CW MOV ,
four for everything else.  So
.CW CMP ,
.CW ADD ,
.CW SUB ,
.CW AND
\(em the whole of
.CW asmout.c 's
case 13 \(em got a four-byte word and a 32-bit LDR to read it back, and
a constant wider than 32 bits lost its top half with no diagnostic.
.CW "if(x >= 0x100000000ULL)"
in C became
.CW "CMP $4294967296,R2"
in the listing and
.CW "ldr w17" ,
.CW "cmp x2,x17"
in the machine, which is a comparison against zero and true for every
.CW x .
It was found by writing that line: a test in
.CW os/inferno/port/pciecam.c
meant to name a PCI bar above 4 GiB named every bar on the machine.
The width now follows the value \(em a top word of 0 or \-1 still fits
in four bytes, because
.CW omovlit()
zero-extends or sign-extends the load.  How much this had already
corrupted is worth saying exactly, because it is less than it sounds:
linking both arm64 kernels with the old linker and the new one and
diffing the listings, one instruction changes in each, and it is the
threshold of a debug print in
.CW os/inferno/port/tod.c .
Every other wide literal in either kernel had been pooled as a
.CW DWORD
by some
.CW MOV
of the same value first, and
.CW addpool()
shares entries.  The bug was latent, not active, and the next wide
constant written anywhere would have woken it.
.PP
.CW atomiccheck()
runs once, before any other processor exists, and checks the value
stored, the value returned, and that a failed
.CW cmpswap
stores nothing and says so.  The negative case is the point: a
.CW cmpswap
that always succeeds passes every positive check there is.
.PP
.B "m and up were globals."
A global has exactly one of itself, so every processor would have
shared one "which
.CW Mach
am I" and one "which
.CW Proc
am I running".  They are extern registers now, R27 and R26, the same
mechanism
.CW os/inferno/pc64
uses for R15 and R14.  Nothing in the toolchain had to change: 7c's
.CW ginit()
already reserves REGEXT and REGEXT-1 in
.CW resvreg
before any declaration is seen, so no C it compiles ever allocates
them, in any translation unit \(em which is why libinterp and libsec,
which never see this board's
.CW dat.h ,
are unaffected.  Two things are load-bearing and the header now says
so: declaration order is the register assignment, since
.CW exreg()
counts down from REGEXT; and
.CW l.s 's
.CW _main
must load R27 before it calls
.CW main() .
The proof it is real rather than a rename is the symbol table \(em the
kernel before it has
.CW "400eb100 D m"
and
.CW "400eb338 D up" ,
and the one after has neither.
.PP
.B "The kernel used 256 MB of whatever machine it was given."
.CW archconfinit()
set
.CW conf.topofmem
to
.CW PHYSDRAM+DRAMSIZE ,
and
.CW mem.h 's
.CW DRAMSIZE
is 256 MiB commented "matches -m 256".  The firmware already knows, and
.CW bootargsinit()
had already parsed its map into
.CW /env
as
.CW *e820= .
What was needed was to read all of it: a UEFI map is not one run, and
on this machine with
.CW "-m 1024"
the usable memory comes back as eight type-1 stretches with the
firmware's own reserved regions between them \(em the run containing
the kernel being the smallest of them at 64 MiB, so taking only that
one is worse than the constant it replaces.  Every run goes into
.CW conf.mem[] ,
which
.CW xinit()
already walks in full.  Measured: 476 MB at
.CW "-m 512" ,
988 at
.CW "-m 1024" ,
4060 at
.CW "-m 4096" ,
and the main Dis pool follows \(em a 100 MB contiguous chunk against
851 MB \(em where before it was the same either way.
.PP
.B "And then the MMU, which was not on the list."
With
.CW SCTLR_EL1.M
clear every data access is Device-nGnRnE, and LDXR/STXR on Device
memory is CONSTRAINED UNPREDICTABLE.  QEMU's TCG implements a global
monitor regardless of memory type, so the new atomics behave correctly
under it and would not necessarily behave correctly on a core.  That
makes the MMU a prerequisite for the rest of item 9 rather than an
optimisation, and it is recorded here because the plan did not have
it.
.PP
Four levels and a 48-bit virtual address, where
.CW os/inferno/raspi3b/mmu.c
has three and 39 bits: this machine's ECAM is at 0x4010000000 and its
high PCIe MMIO window at 0x8000000000, which 39 bits cannot reach.  The
map comes from the firmware's own memory map, entry by entry, and the
page tables get a 2 MiB block of their own mapped read-only \(em the
tripwire raspi3b keeps, so a wild store into them faults at the store.
.PP
.B "Entry by entry, and not a span."
The first version of this mapped
.CW conf.mem[]
and then mapped everything from
.CW PHYSDRAM
to
.CW conf.topofmem
Normal on top of it, to cover the ACPI tables
.CW acpiinit()
reads, which are not in a usable run.  The span subsumed the loop, so
the map was decided entirely by two numbers, and it is right here for
one reason: QEMU's virt has a single contiguous bank.  Give a machine
two banks with an MMIO hole between them and the hole is mapped
Normal, Normal permits speculative reads, and a speculative read into
a hole is an imprecise external abort \(em a fault that arrives with
no address and nothing to blame.  The emulator cannot produce it, so
it would have been found on the rented board.  What is there now maps
each firmware entry by its type: 1 usable, 3 ACPI reclaim and 4 ACPI
NVS are memory and are mapped; 2 is not, because
.CW os/inferno/boot/efi/efi.c 's
.CW memtype[]
gives 2 to EfiMemoryMappedIO and EfiRuntimeServicesData alike, and
this kernel calls no runtime service.  The machine's own map says why
that matters: two of its type-2 runs are 0x4000000\-0x8000000 and
0x9010000\-0x9011000, which are the flash and the PL031, not memory.
100 MB is now left unmapped at
.CW "-m 4096" ,
the RSDP at 0x13cb43018 is inside the one type-3 run, and the tables
went from 8 to 7.
.PP
.B "IPS was a constant, and is now a derivation."
.CW TCR_EL1.IPS
said 4 \(em 44 bits \(em because that covered the map.  Writing an IPS
larger than
.CW ID_AA64MMFR0_EL1.PARange
is CONSTRAINED UNPREDICTABLE, so a constant is the wrong kind of
answer whatever its value: it was within PARange on the cores this has
run on and that was the whole of the evidence for it.
.CW mmuinit()
now takes the highest address it actually mapped, picks the narrowest
IPS that covers it, clamps that to PARange and says so if the clamp
bites.  The answer on this machine is 2, which is 40 bits, for a map
that tops out at exactly 0x10000000000.
.PP
Three bugs, each found a different way.
.CW mmuenable()
called
.CW dcinvalidate() ,
which reads CLIDR_EL1 into R0 \(em REGARG, holding the table pointer
\(em so TTBR0 was loaded with cache geometry and the machine died at
the SCTLR write with a correct set of tables nothing pointed at; found
by writing single characters to the PL011 and seeing which arrived.
.CW "base &= ~((uvlong)1<<L2SHIFT)-1"
is not that mask, because unary
.CW ~
binds tighter than
.CW - ,
so it cleared two bits and left the rest; every other caller had an
aligned base and was unharmed, and the one it broke made the kernel's
own text and stack read-only.  And
.CW subtable()
refused to split a block, which was a deliberate choice and a wrong
one: the order a map is built in is not the caller's to control when
it comes from a firmware map, and the same code panicked under UEFI
and not under
.CW -kernel .
.PP
.B "What a bench cannot say."
.CW memspeed()
reads 16 MB and reports 15503 MB/s with the MMU on against 14427 with
it off.  That is not evidence the mapping is right; it is evidence
this bench cannot weigh it, because TCG models no cache and so
cacheable and Device memory cost the same under it.  The same applies
to
.CW dcinvalidate() 's
set/way walk, which DC ISW makes a no-op here.  What is evidence is
that the machine boots with
.CW SCTLR.M ,
.CW .C
and
.CW .I
set, that NVMe works over an ECAM 256 GiB up, and that 7 or 8 tables
were built rather than a number that happens to be right.
.PP
.B "A Mach and a stack per processor."
.CW MACHP(n)
was a macro that ignored
.CW n .
It is an array now,
.CW MAXMACH
is 8, and
.CW startcpus()
gives each processor it starts a
.CW Mach
and a 32 KiB stack of its own out of
.CW xspanalloc() ,
together with a record carrying the stack top, the static base, that
.CW Mach ,
the page-table base and the TCR.  CPU_ON's context id is the address of
that record, so a processor touches its own and nothing else and there
is no lock and no shared cursor.
.CW _secondary
sets SP, R28, R27 and R26 from it, turns the MMU on with the same
tables the first processor built, and calls C.
.PP
The claim this supports is narrow and worth stating as exactly what it
is: each processor reports the
.CW machno
it read out of its own
.CW m ,
and they are different.  That is the one thing that has to be true
before anything else in SMP can be built, and it cannot pass if
.CW m
is shared.  Under
.CW "-smp 4" :
3 started, 3 answered in 1ms, 3 mpidrs match, 3 own machnos, machnos 1
2 3.  Under
.CW "-smp 17" :
nine clipped at MAXMACH and said so, 7 started, machnos 1 through 7.
The negative control is the half that makes it mean anything \(em the
same kernel with every record's
.CW Mach
pointed at
.CW mach0 ,
which is what a shared
.CW m
would look like, reports "machno 1 reported 0", "machno 2 reported 0",
"machno 3 reported 0" and 0 own machnos.
.PP
.B "What the first processor owes the ones it starts."
A processor enters
.CW _secondary
with its MMU off, so it reads memory and not a cache, while the
processor that filled the record wrote it through one.  The AArch64
boot protocol puts that obligation on the caller \(em the memory a
starting processor reads must be cleaned to the point of coherency,
and the requirement applies to all processors, not only the first \(em
so
.CW startcpus()
cleans the record, the
.CW Mach
and the stack with a new
.CW dccleanrange() ,
by virtual address out of CTR_EL0's line size rather than by set/way,
because a set/way walk cleans whatever is in the cache and not a set
of addresses.  Nothing is written from the far side until the MMU is
on: the two answers come back from C, through Normal inner-shareable
memory, rather than from a location two processors touch with
different cacheability, which is the arrangement that works on an
emulator with no cache and does not work on a core with one.  Under
TCG all of this is exercised and none of it is tested.
.PP
A parked processor deliberately does not set
.CW active.machs[] .
That array is what the portable code walks to find processors running
a scheduler, and
.CW devcons.c 's
.CW Qsysstat
sizes its buffer from
.CW conf.nmach
while looping over it, so setting it now would be a heap overflow
rather than a step forward.  It belongs with
.CW conf.nmach ,
in the increment that makes these processors schedule.
.PP
.B "Its own redistributor, its own timer."
A GICv3 gives every processor a redistributor frame of its own, and
which frame is which is not an index: the order they appear in is the
implementation's, so each carries its own affinity in GICR_TYPER and a
processor looks for the one that matches its MPIDR.  The MADT can name
them and on this machine the firmware leaves the field zero, so the
walk is what there is; it ends on GICR_TYPER.Last rather than on a
count from elsewhere, and the frame stride comes from
GICR_TYPER.VLPIS.
.CW gicinit()
is split into the distributor, which is the machine's, and
.CW giccpuinit() ,
which is one processor's: the cpu interface, its own redistributor,
and the interrupts private to it.
.CW m->gicr
is where the answer lives, so
.CW gicenable()
of a PPI reaches this processor's SGI frame and not processor 0's.
.PP
A started processor now installs VBAR_EL1, calls
.CW giccpuinit()
and
.CW clockinit() ,
drops
.CW spl
and idles.  Its timer interrupt goes to
.CW clocksecondary() ,
which re-arms and counts and nothing else \(em
.CW clockintr() 's
.CW checkalarms()
and
.CW timercheck()
belong to a scheduler this processor is not in yet, and the increment
is not entitled to run them.  What the count proves is exactly this
much: the processor is taking its own interrupts, through its own
redistributor, into its own
.CW Mach .
Under
.CW "-smp 4" ,
measured from
.CW init0()
because that is the first point at which processor 0 is itself taking
interrupts: ticks in 300ms, cpu0 25, cpu1 25, cpu2 25, cpu3 25.
.PP
And the control, which is the half that makes it a measurement.  The
same kernel with
.CW gicrfind()
replaced by the constant \(em every processor using processor 0's
frame, which is what the code did before this \(em reports cpu0 26,
cpu1 0, cpu2 0, cpu3 0.  The count is per-\c
.CW Mach
and not a total for the same reason: a total cannot tell three idle
processors from one fast one.
.PP
Two things this uncovered and one it leaves behind.
.CW splhi()
and
.CW splx()
recorded
.CW m->splpc
through
.CW $mach0(SB) ,
which was the same address as
.CW m
while there was one
.CW Mach
and is processor 0's the moment there is more than one: a secondary
taking a trap would have written the first word of a structure another
processor was using.  They go through R27 now, which is what
.CW m
is.  And the secondaries run with
.CW up
nil and interrupts on, for good:
.CW clocksecondary()
never touches
.CW up ,
but anything added to that path that does will fault on a processor
with no
.CW Proc
and no
.CW dumpstack()
context to explain it.  That is a constraint the next increment
inherits.
.PP
.B "And where this work should have started."
The
.CW multicore
branch had already done most of the above, and this was written without
looking.  It has, on this same board: a second processor under PSCI, a
per-processor
.CW Mach
through TPIDR_EL1,
.CW m
and
.CW up
in registers, the secondary's exception vectors,
.CW MACHP
as an array with
.CW MAXMACH
4, the secondary on its own timer, and cpu1 inside
.CW schedinit()
running processes \(em turned off, because one boot in ten shows Dis
heap corruption with it on and ten in ten are clean with it off.  It
also has aarch64 atomics in
.CW libkern ,
6c and 7c reserving four external registers rather than two, and the
parallel Dis VM work behind
.CW doc/multicore-plan.ms .
Two of the three increments above are therefore re-derivations, and
the
.CW splpc
fix is a third; that is recorded here rather than quietly dropped
because the cost of not looking is the point.
.PP
Three things this branch has that
.CW multicore
does not, and two of them it needs.  7l's constant-pool width bug is
unfixed there.  The GICv3 per-processor redistributor is the gap that
branch's own commit names \(em its
.CW gicsecondary()
returns \-1 on a GICv3 \(em and
.CW gicrfind()
above is that piece.  And its
.CW virtarm64/mmu.c
is a stub whose comment says the MMU stays off, so its
.CW _tas
and
.CW cmpswap
run on Device-nGnRnE memory, where the architecture promises nothing
about the exclusive monitor.  That is not an explanation for the
corruption it is chasing \(em TCG implements a global monitor whatever
the memory type, so the emulator cannot show the difference \(em but it
is a prerequisite before any of that is sound on a core.
.PP
What it would cost that branch to take them, checked against its own
tree rather than guessed.  7l's fix is a clean cherry-pick of
.CW d79cd026 :
.CW utils/7l/span.c
is untouched there since the merge base, and the patch applies without
a reject.  The MMU is not a single pick \(em
.CW virtarm64/mmu.c
is untouched there and would drop straight in, but
.CW l.s ,
.CW main.c ,
.CW fns.h
and
.CW archvirtarm64.c
have all diverged, and the version here reads its map from
.CW bootargs.c ,
which that branch does not have at all.  What ports without any of
that is the smaller MMU: the same four-level tables over one run from
.CW PHYSDRAM ,
which is what
.CW archconfinit()
falls back to when there is no
.CW *e820 .
GICv3 is a manual merge either way, since
.CW trap.c
is where that branch put
.CW gicsecondary() .
.PP
So what is left of item 9 on arm64 is not this branch's to build twice.
Secondaries that reach
.CW schedinit() ,
.CW conf.nmach
from the MADT and
.CW active.machs[]
alongside it belong on
.CW multicore ,
where they are already further along; the evidence standard recorded
here \(em a per-\c
.CW Mach
count of scheduler passes, different under
.CW "-smp 1"
and
.CW "-smp 4"
\(em is the one that branch has already met and then switched off for
cause.  What this branch owes that one is the three pieces above.
.NH 1
The order
.IP 1.
.B "The heap fault."
Found and fixed, in section 6.
.CW os/inferno/pc64/l.s 's
interrupt entry built
.CW Ureg.ds
and
.CW Ureg.es
with
.CW AX
as its scratch
.I before
.CW "PUSHQ AX"
saved the interrupted code's
.CW AX ,
and
.CW MOVW
from a segment register zero-extends, so every interrupt on this
machine handed the interrupted code back an
.CW AX
of
.CW 0 .
Thirty consecutive boots reach a shell with no capture and no panic;
before it, one in twenty-four, nine in twelve, eight in twelve, ten in
twenty-five and eight in thirteen.  Re-measured on a tree rebuilt from
source after the fix landed, six QEMU instances at a time rather than
serially \(em different timing, arguably a harder test, not the same
test \(em thirty of thirty reached an interactive shell with no panic
and no tracker capture.  What made it findable was the
instrument going quiet: the teardown
.CW trackclear
in
.CW libinterp/heap.c 's
.CW freeptrs
removed the last false positives, and the captures that were left all
had the corrupted word equal to
.CW R.d .
Everything below is worth less on a kernel that fails most of its
boots, and a rented machine is the worst place to debug one.  The
mechanism is recorded in
.CW doc/inferno-ports.ms ;
it is not this plan's to re-derive, but it is this plan's blocker.
.IP 2.
.B "Make the memory map safe."
Done, in section 3: merging and a bound in
.CW memconf .
The console half is done too, in section 7: the kernel now reads
ACPI's SPCR table and moves the console to whatever UART it names.
.IP 3.
.B "Run as a KVM guest, on somebody's hardware."
UEFI, virtio-net, virtio-blk, a compiled-in root: every piece exists,
and the image plumbing is done \(en
.CW scripts/mkinferno-efi-disk.sh
with
.CW INFERNO_GCE_TAR
writes an archive to Compute Engine's documented requirements, though
not yet one that has been through its importer.  This costs no driver
at all and it is most of the market, not one provider: GCE is only the
one with a documented import path for an image nobody recognises.
What is left of it is an account, an upload and a boot log.
.IP 4.
.B "Xen HVM."
Done: 9front's
.CW sdide
copied in, verified on i440fx with PIIX3 IDE and both emulated NICs.
That is the whole Xen HVM population, on a self-managed host or a
provider's.  AWS's remaining Xen generations additionally need
.CW os/inferno/boot/pc ,
since they answer
.CW legacy-bios
alone.  That loader is a 386 target and the 386 headers are there:
.CW Inferno/386/include
holds
.CW lib9.h ,
.CW u.h
and
.CW ureg.h .
Its first two stages build today \(em
.CW mk
.CW mbr
.CW pbs
in
.CW os/inferno/boot/pc
links a 407-byte master boot record and a 473-byte partition boot
sector with
.CW 8l
.CW -H3 .
What is not built is the second stage
.CW 9bootfat ,
.CW 9bootiso ,
.CW 9bootpxe
and
.CW 9boothyb ,
which want 386 builds of
.CW libkern ,
.CW libfis
and
.CW libflate ,
and a host-side program to lay the pieces into a disk image.
On a Xen host one controls, OVMF for the domain avoids all of it.
.IP
.I "The 386 kernel is a separate thing and still does not build."
.CW os/inferno/pc
stopped at
.CW i8259.c:199 ,
"not a member of struct/union: enable", which was one declaration left
behind: that board's
.CW irq.c
is already the 9front one that assigns
.CW v->vno ,
.CW v->cpu
and
.CW v->local
and calls
.CW v->enable ,
and its
.CW i8259.c
sets
.CW v->enable
and
.CW v->disable ,
but
.CW os/inferno/pc/io.h 's
.CW Vctl
was still the older layout.  It has
.CW pc64 's
shape now and the board compiles past that file.  The Chan naming, the
.CW FPU
typedef,
.CW active.machs ,
a stale
.CW i8250.$O
in its mkfile, a private copy of
.CW waserror()
and an
.CW ip
line naming three drivers that are not in the tree are all fixed too.
Where it stops now is the floating point, and that is a real piece of
work rather than a declaration:
.DS L
.CW
main.c:229 name not declared: FPINIT
main.c:329 syntax error, last name: FPsave
.R
.DE
.CW FPsave
is a type in this tree rather than a routine and
.CW Proc.fpsave
is a pointer, so that board's floating point has to come forward the
way
.CW os/inferno/pc64/fpu.c
did, on a 386 where there is x87 and not necessarily SSE \(em and
there is no 386 machine here to boot the result on, so writing it blind
would be a change nothing could verify.  Nothing on
this plan needs it \(em item 4 wants
.CW os/inferno/boot/pc ,
the loader, which is a different program \(em so it is recorded here
rather than done.
.IP 5.
.B "MSI-X."
Done, both halves: section 8 has the multi-vector plumbing and the
NVMe driver that takes two vectors through it, verified live.  What
a new driver has to do is call
.CW pcimsixintrenable
once per queue.  Attaching that driver on the UEFI path found a second
thing, now also fixed:
.CW vmap() 's
ceiling was a 512 GiB constant and OVMF puts a 64-bit BAR above it, so
NVMe did not attach at all under the firmware every cloud machine
runs.  It takes the limit from CPUID now.
.IP 6.
.B "ENA."
Then Nitro AWS, first on a cheap virtual instance, then on
.CW *.metal .
The image path is raw image to S3, snapshot import, register AMI.
Item 4 reaches AWS sooner and more cheaply, on older and slower
machines; this one reaches the current ones.
.IP 7.
.B "Rented metal."
Hetzner or Vultr, chosen for an Intel 1G NIC and AHCI or NVMe, using
the drivers already linked.  This is the first genuine bare-metal boot
and it can happen in parallel with 4 and 5 because it needs neither.
Vultr additionally wants the ISO to be a hybrid image.
.IP 8.
.B "OCI."
Custom iPXE at launch, chaining the loader's own PXE path
.CW ( os/inferno/boot/efi/pxe.c ,
which is built and untested), with the root compiled in so the iSCSI
boot volume is not needed.
.IP 9.
.B "Big machines."
x2APIC, more than 255 logical processors, memory regions above 4GB,
and a MADT with hundreds of entries.  Item 1, which used to block this,
is fixed.  On arm64 five pieces are now in and measured, and section
14 has them: real acquire/release atomics (and the 7l fix that made
them encodable),
.CW m
and
.CW up
as extern registers,
.CW conf.mem[]
built from the firmware's memory map instead of a 256 MiB constant,
the MMU \(em which was not on this list and has to be, since LDXR/STXR
on the Device memory an MMU-off kernel runs in is CONSTRAINED
UNPREDICTABLE \(em and a
.CW Mach ,
a stack and a real
.CW MACHP()
per processor, with
.CW MAXMACH
at 8 and each started processor reporting the
.CW machno
it read out of its own
.CW m .
What is left there \(em secondaries that reach
.CW schedinit()
rather than idling on their own timers, and
.CW conf.nmach
from the MADT \(em belongs on the
.CW multicore
branch, which is past this point already; see the end of section 14.  A metal box is where the x86 half arrives.
.IP 10.
.B "Xen PVH's devices."
xenbus and XenStore, grant tables, event channels,
.CW blkfront ,
.CW netfront .
The entry point is already in; this is what a PVH guest needs before
it can read a disk or send a packet.  Worth doing only after item 4
has shown Xen is a platform this port wants to be on, since HVM
reaches the same hosts for one driver.
.IP 11.
.B "Azure."
VMBus,
.CW storvsc ,
.CW netvsc .
.IP 12.
.B "Machines that join and leave."
Done, in section 10, and independent of everything above it:
.CW ndb/regndb
renders a
.CW registry(4)
as an
.CW attrdb(6)
database and
.CW ndb/register
joins one, so a machine can be looked up by name for exactly as long as
it is running.  A fleet wants this before it wants item 9.
.PP
Per-provider differences belong in new configuration files beside
.CW os/inferno/pc64/pc64
and
.CW pc64dev
\(en the tree's own mechanism \(en and not in preprocessor
conditionals, which is what AGENTS.md says and which cloud work is
exactly where one is tempted to break.
.NH 1
Typing at a console, which nothing here could do
.PP
Every board in this tree has a serial console and, until
.CW scripts/type-at-console.py ,
nothing in the repository could press a key at one.  The scripts drive QEMU with
.CW "-serial file:" ,
which is output-only; piping into
.CW "-serial mon:stdio"
does not deliver characters to the guest at all \(em established by
control, not assumed: the same pipe against
.CW virtarm64 ,
whose console input works, is ignored exactly as pc64 ignores it.  Two
attempts at a socket-backed harness
.CW ( -chardev
.CW socket
plus a client that waits for the prompt and writes to it) connected and
then failed to deliver, and are not in the tree.
.PP
That is not a small gap.  It is why
.CW os/inferno/pc/uarti8250.c
went without a
.CW consuart->putc
for the life of the board while the other eight boards had one: no test
ever pressed a key.  The bug was found by connecting to a Compute
Engine instance's serial console by hand, and the fix (e383ca73) is
verified the same way, because there is no other way to verify it.
.PP
What works is QEMU's
.CW pipe
chardev:
.CW "-chardev pipe,id=c0,path=BASE"
reads
.CW BASE.in
and writes
.CW BASE.out
as ordinary FIFOs, and a client holding both open O_RDWR can write into
one while reading the other.
.CW scripts/type-at-console.py
is that client.  It was validated against arm64, whose console input
already worked, before being pointed at pc64 \(em
.CW "echo PIPE-WORKS"
came back from one and
.CW "echo PC64-TYPING-WORKS"
from the other, and against the committed tree with no instrumentation
in it,
.CW "echo COMMITTED-STATE-WORKS" .
.PP
That ordering is the point and it is why this section is still here
after the gap closed.  A claim that "serial input has never worked on
pc64" was made in this branch on the strength of a test that could not
have shown it either way, and was withdrawn only when the same test was
finally pointed at a board known to answer.  Validate the instrument
against a positive before trusting it on a negative.
.NH 1
What this needs that is not code
.PP
Every item left on the list above is blocked on something that cannot
be built: an account, a machine, or a console.  This section says
which, so the blocking is a purchase decision rather than a vague
"needs hardware".  Nothing here is large; the largest single line is a
few hundred dollars, and most of the list is under ten.
.PP
.B "A serial console is the requirement underneath all of them."
This port is verified by reading a boot log.  A provider that offers a
graphical console and no serial one is not usable for this work at any
price, because the failures being chased \(en a hang before the first
print, a panic with a register dump \(en are invisible on a VGA
console that the kernel may never reach.  Check for it before paying
for anything else.
.IP "\f(CWGoogle\ Cloud\fP" 12
Item 3, and the cheapest first boot on somebody else's hardware \(em
now taken, and it earned its keep on the first try: see section 18.  What
is needed: an account with billing enabled, a Cloud Storage bucket, and
the Compute Engine custom-image path \(en
.CW "gcloud compute images create --source-uri"
against the tar.gz that
.CW scripts/mkinferno-efi-disk.sh
already writes when
.CW INFERNO_GCE_TAR
is set.  Serial console access is on by default and is read with
.CW "gcloud compute instances get-serial-port-output" .
An e2-micro or e2-small is pennies an hour and the image import is
free.  This is the one to buy first: it is UEFI with virtio-net and
virtio-blk, every piece of which this tree already drives, so what it
buys is a boot log rather than a driver.
.IP "\f(CWAWS\fP" 12
Item 6, in two stages.  What is needed: an account, an S3 bucket, and
the
.CW vmimport
IAM role that
.CW ImportSnapshot
requires \(en the snapshot route, not VM Import proper, which rejects a
guest it cannot identify.  EC2 Serial Console must be enabled at the
account level and granted in IAM; it is off until someone turns it on.
Stage one is a cheap Nitro virtual instance (a
.CW t3.micro
or
.CW m5.large )
to write the ENA driver against, for cents an hour.  Stage two is
.CW *.metal ,
which needs a quota increase for the instance family and runs to a few
dollars an hour, so it is rented for an afternoon and released.
.IP "\f(CWRented\ metal\fP" 12
Item 7, and the first genuine bare-metal boot.  Hetzner or Vultr.
Hetzner is a monthly dedicated server with a KVM console on request;
Vultr is bare metal by the hour with custom-ISO upload, and wants the
ISO to be a hybrid image, which was a change to
.CW scripts/mkinferno-efi-iso.sh
rather than a purchase and is done: the ESP is appended as a real GPT
partition of type 0xEF with El Torito pointed at that same partition,
so the one file boots as a disc and as a disk.  Both were checked under
OVMF \(en as
.CW -cdrom
and as a raw
.CW virtio-blk
volume, each reaching
.CW "spawn sh -n /dis/init"
and a prompt.  What to specify when ordering, checked against what
.CW os/inferno/pc64/pc64dev
actually links rather than against the driver directory: Intel 1G
.CW ( etherigbe ,
.CW ether82563 ),
Intel 2.5G
.CW ( etheri225 ),
Intel 10G
.CW ( etherx550 ,
.CW ether82598 ),
Realtek
.CW ( ether8169 ),
Broadcom
.CW ( etherbcm )
or Marvell
.CW ( etheryuk ) ,
with AHCI
.CW ( sdiahci ),
NVMe
.CW ( sdnvme )
or IDE, and IPMI or serial-over-LAN.  That is broad enough that a
typical box from either provider needs no driver written, which is what
makes this the cheapest genuine hardware boot on the list.
.PP
Checked rather than inferred from the config: the same 1 GiB raw image
built for Compute Engine boots on an AHCI disk with an Intel 82574
NIC \(em a rented-metal shape rather than a virtio one \(em reaching
.CW "#l0: i82574: 1000Mbps" ,
.CW "#l0: i82574: link up: 1000Mbps" ,
.CW "#S/sdE: ich: sata-I with 6 ports"
and a shell prompt.  So the driver binds, the link comes up and the
SATA controller enumerates, on the image that would be written to the
disk.  With the hybrid ISO above, either route into such a box works:
.CW dd
the raw image, or attach the ISO.  This is independent of the cloud items and can be
bought at any time.
.IP "\f(CWOracle\ Cloud\fP" 12
Item 8, and the one item with a second blocker that is not an account.
.CW os/inferno/boot/efi/pxe.c
is still built and untested, and it cannot be tested here: the OVMF
that ships with this machine's QEMU has no UEFI network stack, so the
firmware never enumerates a network boot option.  Three attempts \(em
plain
.CW "-boot n" ,
the iPXE UEFI option ROM
.CW ( efi-e1000.rom )
attached explicitly, and a pristine NVRAM instead of the saved one \(em
produced byte-identical logs, each dropping to the EFI shell with a
mapping table listing only the SATA disk.  Testing it wants an OVMF
built with NETWORK_ENABLE, or an
.CW ipxe.efi
to chain from the shell; neither is a purchase, and neither is on this
machine.  What is needed besides that: an account, and a bare-metal
shape, which is not in the free tier \(en the always-free Ampere shapes are virtual
machines and do not take a custom iPXE script.  The custom-iPXE-at-launch
option is what makes this the shortest path from a build here to a
kernel on someone else's hardware, and with the root compiled in the
iSCSI boot volume is not needed.
.IP "\f(CWA\ Xen\ host\fP" 12
Item 10, and no account at all: Xen installs on any spare x86 machine,
so this is hardware that may already be on the desk rather than
something to rent.  Item 4 has already measured what HVM costs under
QEMU; what a real host adds is a dom0 to test xenbus, XenStore, grant
tables and event channels against.  Worth doing only after item 4 says
Xen is a platform this port wants to be on.
.IP "\f(CWA\ Hyper-V\ host\fP" 12
Item 11, and likewise no account: Windows Pro or Server on a spare
machine runs Generation 2 guests, which is the same VMBus,
.CW storvsc
and
.CW netvsc
an Azure guest talks to.  Writing those three against a local Hyper-V
is far cheaper than writing them against an Azure bill, and an Azure
account is then only needed to confirm the result.
.IP "\f(CWA\ big\ machine\fP" 12
Item 9's x86 half: x2APIC, more than 255 logical processors, memory
above 4 GiB and a MADT with hundreds of entries.  The AWS
.CW *.metal
rental above is the same purchase; nothing separate is needed, only a
large enough instance and an hour on it.
.PP
What is worth buying first, if only one thing is: the Google Cloud
account.  It costs almost nothing, it needs no driver written, and it
turns "every piece exists" into a boot log \(en which is the only kind
of evidence this document accepts.
.NH 1
The first boot on hardware nobody here owns
.PP
An e2-micro in
.CW us-central1-a ,
booted from a 1 GiB raw GPT image imported as a Compute Engine custom
image with
.CW --guest-os-features=UEFI_COMPATIBLE .
It reached the loader, read its own memory map, printed the
configuration and the page tables, and then panicked:
.DS
.CW
  CS 0008   SS 0000    PC 0000000000200322
TYPE 0D  ERROR 0000 FLAGS 00010046
panic: general protection violation
.DE
0x200322 is
.CW _wrmsrinst ,
reached from
.CW cpuidentify+0x4d0
from
.CW main+0x65 .
A WRMSR to a register the hypervisor does not implement raises #GP,
which is expected \(em
.CW rdmsr()
and
.CW wrmsr()
in
.CW l.s
zero BP for exactly that reason and say so in a comment.  Nothing ever
set BP: the recovery
.CW os/9front/pc/trap.c
performs at
.CW _rdmsrinst ,
.CW _wrmsrinst
and
.CW _peekinst
had never been carried across to pc64, so the contract every
.CW "if(rdmsr(...) != -1)"
in
.CW os/inferno/pc/devarch.c
is written against did not exist, and
.CW peek() ,
the fault-proof memcpy, was not fault-proof.
.PP
What makes this worth a section rather than a line: twelve local boots
through OVMF never touched the path, because on this laptop the
instruction simply succeeds.  QEMU implements whatever MSR this kernel
asked for and Google's does not.  AGENTS.md says to expect exactly this
and to note where the emulator is more forgiving than hardware; this is
the first time the port has been shown one rather than argued about it,
and it cost about a cent.
.PP
.B "The second bug, which the first was hiding."
With the MSR fault survivable the kernel reached
.CW intrinit()
and died there:
.DS
.CW
cpu0: 0MHz GenuineIntel P6 (AX 000406F0 ...)
panic: assert failed at 0x2dd21b: v >= (100*HZ)
.DE
Not an APIC bug.
.CW lapictimerinit()
calibrates the local APIC against
.CW fastticks(&hz) ,
and
.CW hz
was zero, so its hundred-millisecond delay loop returned at once, the
APIC counter had not moved, and the assert was the first thing
downstream to complain.
.CW i8253init()
had never measured the processor's frequency:
.CW guesscpuhz()
has been in
.CW os/inferno/pc/i8253.c ,
declared in both
.CW fns.h ,
and called from nowhere in the tree, while
.CW hpetinit()
\(em the other
.CW arch->clockinit
\(em sets all four of
.CW cpuhz ,
.CW cpumhz ,
.CW cyclefreq
and
.CW loopconst .
.CW archacpi.c
picks
.CW hpetinit
when ACPI describes an HPET and QEMU always does; Compute Engine does
not.  Fixed in 4a9ec166.
.PP
.B "And then it booted."
.DS
.CW
Inferno release built at 1789054866
cpu0: 2196MHz GenuineIntel P6 (AX 000406F0 ...)
#l0: virtio: 1000Mbps port 0xC000 irq 11 ea 42010a800005
Welcome to Inferno...
loading /dis/sh.dis
spawn sh -n /dis/init
;
.DE
An e2-micro in
.CW us-central1-a ,
on a Broadwell vCPU whose frequency the kernel now measures correctly,
with its virtio NIC bound.  Item 3 is no longer "every piece exists";
it is a boot log.
.PP
.B "And a third, still open, in the dev configuration."
.CW ipc64dev
\(em the configuration that links every driver and whose init runs a
DHCP client \(em was put on the same machine to find out whether the
virtio NIC passes packets on real hardware.  It does not get that far:
.DS
.CW
#l0: virtio: 1000Mbps port 0xC000 irq 11 ea 42010a800006
Initial Dis: "/osinit.dis"
panic: cpu0: ilockdepth -1, last lock 0x0 at 0x0,
       sched called from 0x28dd6e
.DE
0x28dd6e is
.CW acquire+0xff ,
and the stack is
.CW init0
\(->
.CW disinit
\(->
.CW vmachine
\(->
.CW startup
\(->
.CW xec
\(->
.CW mcall
\(->
.CW Sys_bind
\(->
.CW acquire :
the first Dis module's first blocking system call releases the VM lock,
reaches
.CW sched() ,
and
.CW sched()
finds
.CW m->ilockdepth
at \-1 \(em an
.CW iunlock()
with no matching
.CW ilock() .
.PP
It is the machine and not the configuration.  The same
.CW ipc64dev
booted here under QEMU runs the whole test to
.CW "DEVTEST: done" ,
with
.CW "DEVTEST: /net/ether0 DHCP-OK ip=10.0.2.15 gw=10.0.2.2"
and no panic at all.  So the virtio driver's transmit and receive paths
are known good against an emulator and remain untested against a
hypervisor, and what differs is some interrupt path that machine takes
and this one does not.  .PP
.B "Characterised, on the second round."
It is intermittent and it is an interrupt handler that sleeps.  Adding
a print to
.CW iunlock()
for a depth gone negative did not fix it and did not need to: the same
kernel booted twice on that machine reached
.CW "DEVTEST: done"
once and panicked once, so it is roughly half there and has never
happened here.  The second failure names the path the first could not:
.DS
.CW
qlock: 0x29a7f6: ilockdepth 1
panic: cpu0: ilockdepth 1, last lock 0x0 at 0x0,
       sched called from 0x2965b7
.DE
0x29a7f6 is
.CW kproc+0x42
and 0x2965b7 is
.CW irqhandled+0x113 .
So
.CW sched()
is entered from interrupt context, and a
.CW qlock()
is taken with an ilock held.  The first boot's \-1 from
.CW acquire+0xff
and this boot's +1 from
.CW irqhandled
are the same fault seen from either side of the counter: something in
this configuration's interrupt path reaches code that sleeps, on a
machine whose interrupts arrive where QEMU's do not.
.PP
The networking question it was sent to answer is answered, and
positively:
.DS
.CW
DEVTEST: /net/ether0 DHCP-OK ip=10.128.0.7 gw=10.128.0.1
DEVTEST: done
.DE
That is a Compute Engine address from Google's own DHCP server, not
QEMU's 10.0.2.15, so the virtio-net driver's transmit and receive paths
work on real hardware.  Item 3 has a network as well as a shell.
.PP
The obvious guess has been tried and is wrong: the
HPET is not the difference.  The same
.CW ipc64dev
under
.CW "-machine q35,hpet=off"
\(em the knob that reproduced the frequency bug \(em still reaches
.CW "DHCP-OK ip=10.0.2.15"
here with no panic.  So this one does not come home the way that one
did, and finding it wants instrumentation on the machine itself:
.CW m->ilockdepth
printed where it changes, which is a boot's worth of cloud round-trip
per iteration.  Open, and NOT confined to that configuration \(em see below.
.PP
.B "Caught, and it is iallocb."
The instrument in
.CW b50ee696
records which caller holds each ilock level and prints them before the
panic.  Six resets of an instance later, on the boot that failed:
.DS
.CW
  ilock 0 held from 0x285a85
panic: cpu0: ilockdepth 0, last lock 0x0 at 0x0,
       sched called from 0x28dd6e
.DE
0x285a85 is
.CW iallocb+0xa5
and 0x28dd6e is
.CW acquire+0xff .
So the held lock is
.CW &ialloc ,
taken at
.CW os/inferno/port/allocb.c :135
by the interrupt-context block allocator, which is the one place a lock
is taken with no process current \(em matching the
.CW "last lock 0x0"
that made this opaque for so long.
.PP
Two things about that are strange and both constrain what it can be.
The
.CW ilock(&ialloc)
at line 135 is unlocked at line 137, straight-line code with an
addition between; there is no path that skips it.  And the panic prints
.CW "ilockdepth 0"
while
.CW sched()
only panics when the depth is
.I not
zero \(em so the value fell between the test and the print, which means
an interrupt ran in that window and performed a net unlock.  A handler
that unlocks more than it locks, or a counter sampled while a handler
is inside that two-line region, are the two readings; distinguishing
them is the next step, and it is a smaller question than the one this
started as.
.PP
.B "And on the second catch, the holder is timerintr."
A sharper instrument \(em recording the depth that tripped the test,
because the message races with itself \(em and a second failing boot:
.DS
.CW
qlock: 0x29a807: ilockdepth 1
qlock: 0x29a807: ilockdepth 1
  ilock 0 held from 0x202d80
panic: cpu0: ilockdepth 1 (now 0), last lock 0x0 at 0x0,
       sched called from 0x2965b7
.DE
0x202d80 is
.CW timerintr+0x10c ,
0x29a807 is
.CW kproc+0x42 ,
0x2965b7 is
.CW irqhandled+0x113 .
So the held lock is
.CW timers[m->machno] ,
taken by the soft-timer handler in
.CW os/inferno/port/portclock.c ,
and
.CW "1 (now 0)"
settles the earlier puzzle: the depth really was 1 when tested and fell
to 0 while the panic was printing, so both the leak and the race in the
message are real.
.PP
The order matters.  Both
.CW qlock
warnings come from
.CW kproc ,
which ether attach calls twice, and they print a depth of 1 \(em so the
lock was already leaked before
.CW "bound #l0" .
.CW kproc
survived both, and it was the next clock interrupt, through
.CW irqhandled 's
.CW "ctl == vclock"
arm, that turned a warning into a panic.  The first catch named
.CW iallocb
and this one names
.CW timerintr ;
both are interrupt-context lock holders, and which of them leaks
\(em or whether the two are the same event seen at different moments
\(em is what remains.
.CW timerintr 's
own
.CW ilock/iunlock
pairs are balanced on every path including the early return, so the
answer is not a missing unlock in its source.
.PP
.B "And the third catch joins it to a hunt already running."
Recording the
.CW Mach
alongside the caller killed the best hypothesis and produced a better
finding:
.DS
.CW
 checkb 0 %s %#p %#p checkb 1 %s %#p %#p checkb 2 %s ...
  ilock 0 held from 0x29c35e, m was 0x102000, m now 0x102000
panic: cpu0: ilockdepth 1 (now 1), ... sched called from 0x2965b7
.DE
.CW "m was"
equals
.CW "m now" ,
so the counter is not being split between two
.CW Mach
structures \(em which also matches
.CW os/inferno/pc64/l.s ,
where interrupt entry pushes R15 and R14 and
.CW _intrr
pops them in mirrored order.  And
.CW "1 (now 1)"
says the depth is genuinely stuck, with no race in the message this
time.  So it is a real leak.
.PP
0x29c35e is
.CW qconsume+0x21 ,
a third holder after
.CW iallocb
and
.CW timerintr ,
and the lines above it are the giveaway: those are
.CW checkb 's
own format strings from
.CW os/inferno/port/qio.c
being emitted verbatim, one after another out of the string table.
That is not a message, it is the block checker firing on a malformed
Block and printing through a bad pointer.
.PP
Which means this is not a new bug.
.CW os/inferno/port/allocb.c
already carries a comment on exactly this signature \(em "every
.CW "checkb 0 qaddlist 1"
capture this hunt has caught downstream showed base > lim by EXACTLY
Hdrspc (64) bytes" \(em and
.CW doc/inferno-ports.ms
has tracked it for a long time.  The Compute Engine panic is that
corruption reaching a queue lock: a malformed Block sends
.CW qconsume
down an error path that never reaches its
.CW iunlock ,
the depth stays at 1, and the next clock interrupt through
.CW irqhandled
turns it into a panic.  What the rented machine adds is that the
corruption is still live after the
.CW _intrcommon
fix, on hardware, where this laptop does not show it \(em and a second
symptom, the leaked lock, that is easier to catch than the corruption
itself.
.PP
.B "A consistent holder, and a contradiction to resolve."
With
.CW checkb
made legible (2e285f65) the next two failures on one instance were
identical, which none of the earlier ones were:
.DS
.CW
 ilock 0 held from 0x25355b, m was 0x102000, m now 0x102000
panic: cpu0: ilockdepth 1 (now 0), ... sched from 0x2966d1
.DE
0x25355b is
.CW uartkick+0x2b
\(em the
.CW ilock(&p->tlock)
in
.CW os/inferno/port/devuart.c
\(em and 0x2966d1 is
.CW irqhandled+0x113
again.  Both boots, the same address.
.PP
And
.CW checkb
printed nothing on either, so these two are not the Block corruption:
the earlier catch that showed
.CW checkb 's
strings and the ones that do not are different events, and treating
them as one was wrong.
.PP
What is left is a contradiction worth stating precisely, because it
constrains the answer.
.CW uartkick 's
.CW ilock
and
.CW iunlock
have straight-line code between them \(em
.CW "(*p->phys->kick)(p)" ,
which is
.CW i8250kick ,
bounded at 128 iterations with no early exit that skips a return.  And
.CW ilock()
begins with
.CW splhi() ,
which on pc64 really does
.CW CLI
(checked in
.CW l.s ,
not assumed).  So if that lock were simply leaked, interrupts would
stay masked and no clock interrupt could arrive to panic.  For this
panic to happen at all, something must re-enable interrupts while the
lock is still held.  That is the next thing to find, and it is a
narrower question than any asked so far.
.PP
.B "And it is the shipped kernel too."
Recorded here as a correction, because this document said twice that
.CW ipc64
was unaffected.  It is not.  A stock e2-micro running the shipped
configuration panicked on the boot after
.CW "bound #e" :
.DS
.CW
panic: cpu0: ilockdepth 1, last lock 0x0 at 0x0,
       sched called from 0x2965bc
.DE
and on the next reset, with
.CW "ilockdepth 2"
and
.CW "qlock: 0x29a7fb: ilockdepth 2" .
Those two addresses sit a few bytes from
.CW kproc+0x42
and
.CW irqhandled+0x113
in the other configuration's kernel, so the signature is the same in
both:
.CW qlock()
called from
.CW kproc()
with an ilock held, and
.CW sched()
entered from the interrupt path.
.PP
The console fix is not the cause, which was worth establishing rather
than assuming: every panic seen on the shipped kernel was on a build
carrying it, and the one instance without it had been up for hours.  So
the instance running the pre-fix image was reset three times, and it
panicked too \(em three
.CW ilockdepth
panics in its log against one clean boot.  The bug is older than the
fix and independent of it.
.PP
It matters more than a dev-configuration bug would, and it also
explains an hour spent on the wrong thing.  A panicked kernel and a
console that ignores a keypress look identical from the far end of a
serial line: the console-input work below was begun because typing at
an instance produced nothing, and the instance was dead.  The next
thing to instrument is which handler leaves an ilock held \(em
.CW ethervirtio.c 's
.CW attach()
uses
.CW lock/unlock
and releases before
.CW kproc() ,
so it is not that one.
.PP
.B "What the exercise cost and what it bought."
Four images, four instances, under an hour, and small change.  It
bought two bugs that twelve local boots could not have found, and the
second of them is now reproducible here \(em QEMU will hide its HPET
with
.CW "-machine q35,hpet=off" ,
and under it the old kernel prints
.CW "cpu0: 0MHz"
and panics exactly as Compute Engine did while the new one reaches a
shell at
.CW "cpu0: 983MHz" .
That is the pattern worth repeating on the rest of the list: rent the
machine, read the log, and bring the failure home where a regression
can be caught for nothing.
.NH 2
The ilockdepth panic was never about the cloud
.LP
Everything above reads the
.CW ilockdepth
panic as something Compute Engine does and this laptop does not, and
hunts it with rented instances at ten to twelve minutes an image.  That
reading was wrong, and the thing that made it wrong was in the boot
scripts, not in the kernel.
.PP
A Compute Engine
.CW e2-micro
has two vCPUs.  Every local boot script in this tree runs QEMU with
one.  So the kernel started a second processor on every instance and on
none of the local runs, and the difference that was being attributed to
real hardware, or to the missing HPET, or to Google's virtio devices,
was that
.CW mpstartap()
had run.
.PP
With
.CW "-smp 2"
it reproduces here, in well under a minute:
.DS
.CW
iunlock: cpu0 shadow 2 but m->ilockdepth 3, m 0x102000, pc 0x29d833
iunlock: interrupts on at ilockdepth 1, pc 0x29d833, lock pc 0x29c46f
panic: cpu0: ilockdepth -1 (now -1)
.DE
.CW scripts/check-pc64-smp.sh
is that, with the arm that makes it mean something: the same
two-processor QEMU machine, the same kernel, the same ISO recipe, but
.CW *ncpu=1
in
.CW plan9.ini
so the kernel leaves the second processor alone.  Four runs each at the
time of writing: four faults with the AP started, none without.  A
failure without that control could be blamed on the extra vCPU rather
than on the kernel's use of it.
.PP
.B "What the instruments say, and what they do not."
Every lock and unlock this hunt has caught is balanced and local \(em
.CW poolalloc+0x5b
with
.CW poolalloc+0x141 ,
.CW timerintr+0x47
with
.CW timerintr+0x77 ,
.CW uartkick+0x2b
with
.CW uartkick+0x4b ,
.CW qiwrite+0x91
with
.CW qiwrite+0xf3 .
No function leaks a lock.  What is wrong is the count.
.PP
A shadow of
.CW m->ilockdepth
kept outside
.CW Mach ,
one per processor, moved at exactly the two places the counter is
moved, parts company with it \(em and in both directions
.CW ( "shadow 2 but m->ilockdepth 3" ,
.CW "shadow 1 but m->ilockdepth 0" ).
Both words are private to cpu0: the second processor gets its own
.CW Mach
.CW ( "cpu1: squidboy m 0xda9d000, MACHP(0) 0x102000, MACHP(1) 0xda9d000" ),
and a detector that reports the first time two different
.CW Mach
pointers claim one
.CW machno
has never fired.  Two private counters written at adjacent statements
under
.CW splhi ,
diverging, is a wild write, not an unbalanced count.
.PP
Ruled out by reading the machine rather than guessing at it:
.CW tas()
is
.CW "XCHGL AX, (RARG)" ,
which is implicitly locked on x86;
.CW ainc/adec
are
.CW "LOCK; XADDL" ;
.CW unlock()
and
.CW iunlock()
both have a
.CW coherence()
before releasing the key; the run queue is locked.  Every literal
.CW Mach
offset in
.CW pc64/l.s
was checked against what
.CW 6c
actually lays out, and every literal
.CW Ureg
offset in the interrupt path with it \(em
.CW ax
0,
.CW r15
112,
.CW ds/es/fs/gs
120 to 126,
.CW type
128,
.CW pc
144 \(em and the interrupt path is correct.
.PP
Not ruled out, and stated so plainly: the check for a lock released on
a different processor than took it compares
.CW l->m
with
.CW MACHP(m->machno) ,
which cannot see the case where two processors share one
.CW Mach .
It has not fired, and that is not evidence.
.PP
.B "Where this leaves the cloud target."
Inferno boots on Compute Engine and gets a DHCP lease there; that
stands.  What does not stand is running it on a multi-vCPU instance
with the AP started, and until the wild write is found the honest
setting for a cloud image is
.CW *ncpu=1
in
.CW plan9.ini .
That is a real restriction, not a fix, and it should be written on the
image rather than discovered by a user.
.NH 2
Two more things the two-processor boot says
.LP
.B "cpu1 faults in the scheduler."
One two-processor boot in four dies on the second processor rather than
in the counter:
.DS
.CW
cpu1: registers for kernel
 R14 up 0000000000000000 R15 m 000000000DA9D000
  CS A7F0   SS 31B1    PC 0000000000298E74  SP 000000000DAACF08
 CR2 0000000000000000
panic: page fault
.DE
.CW 0x298E74
is
.CW dequeueproc+0x108 ,
.CW CR2
is zero, so it is a nil dereference inside the run queue with
.CW up
nil, on cpu1's own stack
.CW ( estackx
.CW daad000 ,
and cpu1's Mach is
.CW 0xda9d000 ).
Whether this is the same fault as the stray write or a second one is
not established.
.PP
.B "The hardware watchpoint fires, and cannot say so."
The question the counters cannot answer is which processor makes the
stray store, and x86 can answer it directly: cpu1 has no business
writing cpu0's
.CW Mach ,
so point cpu1's
.CW DR0
at
.CW 0x102074
.CW ( "m->ilockdepth" ,
offset 116 in
.CW Mach ,
which is
.CW PMach 's
field now) and trap on any write.
.CW squidboy() 's
.CW ilockwatch()
does that under
.CW *ilockwatch
in
.CW plan9.ini .
.PP
It does not work, and the way it fails is worth writing down.  With
.CW *ilockwatch=test
cpu1 writes the watched word itself, on purpose, as a positive control
\(em and the machine stops dead at that instruction, both processors,
with nothing printed.  Not the handler's
.CW iprint ,
not
.CW trap() 's
own
.CW "unknown trap/intr" ,
not even a handler cut back to storing the pc in a global for cpu0 to
print later.  A
.CW trapenable(VectorDE)
handler is installed and says so at boot.  So the write does trap; the
debug exception simply is not survivable on an application processor
here, and every quiet
.CW *ilockwatch
run is a run in which nothing happened to trap, not a run that proves
cpu1 innocent.
.PP
That distinction is the whole reason the control was written.  Four
watched boots were silent before it existed, and reading that silence
as "cpu1 does not write cpu0's Mach" would have been the same mistake
as the serial-input claim earlier in this document: a negative from an
instrument that had never been shown capable of a positive.
.PP
So the open question stays open, and it is now two questions: which
processor stores into cpu0's
.CW m->ilockdepth ,
and why a debug exception kills this kernel.  The second is a
prerequisite for answering the first this way.
