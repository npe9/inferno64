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
serial-over-LAN all present.  The one gap is that the port is assumed
rather than discovered: a machine that puts it at
.CW 0x2F8 ,
or describes it in the ACPI SPCR table, is not handled.
.NH 1
The order
.IP 1.
.B "The heap fault."
Four boots in ten reach a shell on the UEFI path, six on the other.
Everything below is worth less on a kernel that fails half its boots,
and a rented machine is the worst place to debug one.  The
mechanism is recorded in
.CW doc/inferno-ports.ms ;
it is not this plan's to re-derive, but it is this plan's blocker.
.IP 2.
.B "Make the memory map safe."
Done, in section 3: merging and a bound in
.CW memconf .
What is left of it is the console \(en the 16550 at
.CW 0x3F8
is assumed rather than read out of ACPI's SPCR table \(en and a machine
that puts its console elsewhere is silent in exactly the same way.
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
alone, and that loader is a 386 target this tree does not build \(en
no
.CW Inferno/386/include ,
no 386
.CW libkern ,
.CW libfis
or
.CW libflate .
On a Xen host one controls, OVMF for the domain avoids all of it.
.IP 5.
.B "MSI-X."
The single-vector half is done and verified against NVMe, per section
2.  What is left is multi-vector allocation \(en a vector per queue,
which is how ENA and the current Intel parts are meant to be driven \(en
and it is better done alongside the first driver that needs it than
before.
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
and a MADT with hundreds of entries.  SMP is blocked on item 1 today.
A metal box is where all four arrive at once.
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
.PP
Per-provider differences belong in new configuration files beside
.CW os/inferno/pc64/pc64
and
.CW pc64dev
\(en the tree's own mechanism \(en and not in preprocessor
conditionals, which is what AGENTS.md says and which cloud work is
exactly where one is tempted to break.
