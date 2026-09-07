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
loader or a multiboot boot loader.  A cloud machine is UEFI class 3,
has no CSM, and cannot start that image at all.  Until this round
there was no path onto any of the hardware in section 1.
.PP
.B "MSI is already wired, MSI-X is not."
.CW os/inferno/port/pci.c
has
.CW pcimsienable
and
.CW pcimsidisable ,
and
.CW os/inferno/pc/mp.c 's
.CW mpintrassign
tries MSI before the INTx path, gated on
.CW *nomsi .
Any driver that calls
.CW intrenable
with a PCI
.CW tbdf
gets a single MSI vector under
.CW archacpi
without doing anything.  What does not exist anywhere in
.CW os/inferno
is MSI-X: no capability walk, no BAR-mapped vector table, no
multi-vector allocation.  That distinction decides section 4.
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
Ten boots under
.CW "qemu -kernel" :
seven reach a shell prompt, three panic in the Dis heap.  The same
measurement in
.CW doc/inferno-ports.ms
recorded fifteen crashes out of fifteen, and the difference is not a
kernel fix: it is that
.CW dis/init
carried a three-hundred-iteration
.CW "sh -n -c 'true'"
loop marked TEMPORARY from that hunt, and
.CW true
is not in
.CW pc64 's
root, so every boot spun on the error and drove the allocator into the
fault.  Reverted.  The remaining three in ten are the real heap bug,
and they are the same fault the UEFI path hits.
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
Three boots in ten panic in the Dis heap, on both boot paths.
Everything below is worth less on a kernel that fails one boot in
three, and a rented machine is the worst place to debug one.  The
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
.B "Boot on GCE."
UEFI, virtio-net, a compiled-in root: every piece exists.  This is the
first cloud machine Inferno can run on and it needs no new driver.
The work is image plumbing \(en a raw disk with a GPT and an EFI
system partition, packed the way Compute Engine wants it \(en not
kernel work.
.IP 4.
.B "MSI-X."
.CW pcimsixenable ,
the vector table in its own BAR, and multi-vector allocation in
.CW mpintrassign .
This is the gate on AWS, on X710/E810 metal, and on anything modern.
.IP 5.
.B "ENA."
Then AWS, first on a cheap virtual instance, then on
.CW *.metal .
The image path is raw image to S3, snapshot import, register AMI.
.IP 6.
.B "Rented metal."
Hetzner or Vultr, chosen for an Intel 1G NIC and AHCI or NVMe, using
the drivers already linked.  This is the first genuine bare-metal boot
and it can happen in parallel with 4 and 5 because it needs neither.
Vultr additionally wants the ISO to be a hybrid image.
.IP 7.
.B "OCI."
Custom iPXE at launch, chaining the loader's own PXE path
.CW ( os/inferno/boot/efi/pxe.c ,
which is built and untested), with the root compiled in so the iSCSI
boot volume is not needed.
.IP 8.
.B "Big machines."
x2APIC, more than 255 logical processors, memory regions above 4GB,
and a MADT with hundreds of entries.  SMP is blocked on item 1 today.
A metal box is where all four arrive at once.
.IP 9.
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
