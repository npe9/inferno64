.TL
Genesize: Inferno as the hypervisor
.AU
.PP
This branch, cut from
.CW cloud-port
at
.CW 921fec3cf ,
adds a bare-metal virtualization layer to Inferno Cloud.  The native
Inferno kernel,
.CW os/inferno/pc64 ,
owns the machine: the processor's virtualization extensions, the PCIe
fabric, the IOMMU and the physical devices.  It runs conventional guest
systems, Linux first, and exposes creating a machine, giving it devices,
networking, storage and its life cycle as files served over Styx.
Inferno, running Limbo on the same kernel and on other machines, is the
distributed control plane that mounts those files.
.PP
The plan this follows was written for Plan 9 as the hypervisor and
Inferno as the control plane.  Here both roles are Inferno: the kernel
is the hypervisor, Limbo is the control plane.  Section 2 says what that
substitution changes, which is more than the names.  Section 9 is the
progress record; keep it current as each piece lands, with what a
booted kernel printed.
.NH 1
The shape of the system
.PP
.DS
.ft CW
                 Inferno Cloud (Limbo)
             registry, scheduler, images,
              network manager, vm manager
                          |
                          | Styx
                          v
              +-----------------------+
              |  Inferno pc64 kernel  |
              |                       |
              |  #H  /dev/vm          |  portable VM layer
              |      vmx | svm        |  per-processor backends
              |  #Q  /dev/iommu       |  portable IOMMU layer
              |      vtd | amdvi      |
              |  #$  /dev/pci         |  PCIe, MSI-X, SR-IOV
              |  virtio backends      |
              +-----------+-----------+
                          |
            +-------------+-------------+
            |             |             |
         Linux VM     Inferno VM     Linux VM
            |             |             |
         NIC VF       virtio-net      NVMe
.ft
.DE
.PP
The device letters are provisional:
.CW H
and
.CW Q
are free in the pc64 kernel today, and
.CW $
is the existing
.CW devpci .
.NH 1
What changes when the hypervisor is Inferno rather than Plan 9
.IP "Where the code goes." 4
Processor- and chipset-specific code goes in
.CW os/inferno/pc64
(VMX, SVM, EPT/NPT, the VMCS and VMCB) and
.CW os/inferno/pc
(VT-d, AMD-Vi, the PF drivers); the portable VM, IOMMU, SR-IOV and
virtio-backend layers go in
.CW os/inferno/port .
The flavour rule in
.CW AGENTS.md
holds: nothing under
.CW os/inferno
names
.CW os/9front
or
.CW os/osprey ;
a file taken from 9front is copied in and then belongs to Inferno.
.IP "Styx, not 9P." 4
The same protocol by another name, and Inferno's
.CW mount ,
.CW export
and
.CW listen
already carry it.  Section 10 of the original plan, "9P as the
hypervisor control interface", needs no new protocol at all: the
kernel's
.CW #H
tree exported with
.I export (1)
is the remote interface.
.IP "There is no C userland." 4
This is the substitution with consequences.  9front's
.CW devvmx
does only the processor half: VM entry, the VMCS, EPT, and handing each
exit to a C program,
.CW vmx (1),
which decodes instructions, emulates the LAPIC, the PIT, the serial
port and virtio, and loops back into the kernel.  Native Inferno cannot
run that program.  Limbo can read and write the same files, but a
round trip through Dis for every timer tick or port access is not a
hypervisor anyone would run.  The split is therefore:
.RS
.IP \(bu 2
In the kernel, on the exit path, with no trip to Limbo: nested-page
faults on mapped memory, CPUID, MSRs, HLT, the local APIC and its
timer, the I/O APIC, the 16550 the guest's console uses, PCI
configuration cycles for the guest's virtual topology, MSI/MSI-X
forwarding for assigned devices, and the virtqueue backends for
console, block and network.
.IP \(bu 2
In Limbo, over
.CW #H :
creating a machine, laying out its memory, loading a kernel and its
boot parameters, choosing devices, connecting a virtio backend to a
file, a disk image or a network interface, starting, stopping,
inspecting, and everything in the cloud control plane.
.IP \(bu 2
An exit the kernel does not handle is not dropped and not faked.  It
stops the vCPU and is delivered on
.CW /dev/vm/N/vcpuM/exit ,
so a Limbo program can see it, emulate it if it chooses, and resume.
That is the slow path, and it is also how a missing piece of emulation
shows itself.
.RE
.IP "Commands are Limbo." 4
.CW vmctl ,
.CW iommu
and
.CW pcictl
are
.CW appl/cmd
programs; the control plane is
.CW appl/cloud .
.IP "Tests boot a kernel." 4
Each phase has a
.CW scripts/check-*.sh
that boots the kernel on the bench below and looks at what it printed,
the same discipline as the rest of the tree.
.NH 1
One hypervisor layer, two processor backends
.PP
The portable layer,
.CW os/inferno/port/devvm.c ,
knows about machines, vCPUs, guest-physical memory, the exit file, and
the in-kernel device models.  It reaches the processor through a table
of operations:
.DS
.ft CW
typedef struct Vmops Vmops;
struct Vmops {
	char	*name;			/* "vmx", "svm" */
	int	(*probe)(void);		/* processor supports it */
	int	(*cpuinit)(void);	/* VMXON / EFER.SVME, per processor */
	void*	(*vcpunew)(Vcpu*);	/* VMCS or VMCB */
	void	(*vcpufree)(Vcpu*);
	int	(*run)(Vcpu*, Vmexit*);	/* enter, return the exit decoded */
	int	(*getreg)(Vcpu*, int, uvlong*);
	int	(*setreg)(Vcpu*, int, uvlong);
	int	(*inject)(Vcpu*, int vec, int type, u32int err);
	void*	(*gpmapnew)(Vm*);	/* EPT or NPT root */
	int	(*gpmap)(Vm*, uvlong gpa, uvlong pa, uvlong len, int prot);
	int	(*gpunmap)(Vm*, uvlong gpa, uvlong len);
	void	(*gpflush)(Vm*);	/* INVEPT / TLB flush by ASID */
};
.ft
.DE
.PP
Exits are decoded into a portable
.CW Vmexit
(I/O port, MMIO with the faulting guest-physical address, CPUID, MSR,
HLT, interrupt window, external interrupt, triple fault, unknown with
the raw code), so the device models never see VMX or SVM exit codes.
EPT and NPT are both four-level x86 page tables with different leaf
bits; the walk is shared and the bit encoding is per backend.
.PP
VMX is the reference backend: the target workstation is a dual Xeon.
It starts from 9front's
.CW devvmx.c
(2433 lines), copied into
.CW os/inferno/pc64/vmx.c ,
shimmed to this kernel and cut down to the backend side of the table.
SVM is written to the same table and is the backend the local QEMU
bench can run.  A result is always reported with the backend and the
bench it came from; a milestone below that names VMX is not met by SVM.
.PP
The same split is what the original plan's phase 15 asks for: RISC-V's
H extension and G-stage translation are a third backend under the same
table, and the RISC-V IOMMU a third IOMMU under
.CW #Q .
.NH 1
The test benches
.PP
No single emulator on this (Apple-silicon) host provides everything.
.IP "QEMU q35, TCG" 4
The platform bench:
.CW scripts/vmhost.sh ,
with
.CW "mk vmhost" ,
.CW "mk vmhost-run"
and
.CW "mk vmhost-debug"
in
.CW os/inferno/pc64 .
q35, four processors, PCIe root ports, Intel IOMMU with interrupt
remapping, MSI/MSI-X, NVMe, igb (82576, with SR-IOV), serial console,
edk2.  TCG implements SVM with nested paging; it does not implement VMX
and says so ("TCG doesn't support requested feature: CPUID[eax=01h].ECX.vmx").
So this bench carries phases 0\-2 and 6\-9 for real, and phases 3\-5
on the SVM backend only.
.IP "Bochs" 4
The processor bench:
.CW scripts/mkbochs-vmx.sh
builds Bochs with
.CW --enable-vmx=2
(VMX with EPT, unrestricted guest, VMCS shadowing) and
.CW --enable-svm
(SVM with nested paging) into
.CW .bochs .
Both backends run against the portable layer on the same emulator,
which is the direct test of "one layer, two backends".  Its platform
is i440FX-class \(en no q35, no ECAM, no VT-d \(en and it boots a
legacy BIOS, so the kernel comes in by its multiboot header through a
loader on a disk image.
.IP "Nested KVM" 4
VMX at speed, with q35 and VT-d: an Intel Compute Engine instance with
nested virtualization enabled, running the same
.CW vmhost.sh
configuration under
.CW "-accel kvm"
with
.CW kernel-irqchip=split
for the emulated IOMMU.  Before relying on it, check that the machine
type allows nesting, that
.CW kvm_intel
has
.CW nested=Y ,
and that the booted Inferno kernel sees VMX in CPUID.
.IP "The workstation" 4
Real hardware is the target and the conformance test (phase 13).
Where an emulator is more forgiving than the hardware the code follows
the hardware and says so at the place it matters.
.NH 1
Phases
.PP
The phases are the original plan's, translated.  The critical path is
VMX/EPT, Linux, VT-d, PCI assignment, SR-IOV, virtio, then Styx
orchestration.
.IP "0. The bench." 4
.CW scripts/vmhost.sh
and the three
.CW mk
targets; the configuration lives in the tree.  Done when the kernel
boots repeatedly on it and every device on the command line is
enumerated by
.CW #$ .
.IP "1. PCIe." 4
Extend
.CW os/inferno/port/pci.c
and
.CW devpci.c ,
do not replace them: ECAM through MCFG, MSI and MSI-X already exist.
Add extended configuration space (4096 bytes per function), the
extended-capability walk from 0x100, 64-bit BARs reported as such, the
PCI Express capability, ARI, and SR-IOV capability parsing.  The
directory per function:
.CW /dev/pci/0000:00:00.0/{ctl,config,caps,bar0..5,irq} ,
keeping the existing flat files for their current readers.  No SR-IOV
policy in this layer.
.IP "2. IOMMU." 4
DMAR from ACPI in
.CW os/inferno/pc/archacpi.c ,
beside MCFG and SPCR; remapping units; a portable
.CW os/inferno/port/deviommu.c
(#Q,
.CW /dev/iommu/{ctl,N/{ctl,map,devices,faults}} )
over an
.CW Iommuops
table with VT-d in
.CW os/inferno/pc/vtd.c .
Done when a QEMU DMA-capable device is put in a domain and a DMA
outside it faults and is reported.
.IP "3. The hypervisor." 4
.CW os/inferno/port/devvm.c
and
.CW os/inferno/pc64/vmx.c ,
.CW svm.c ,
.CW npt.c .
VMXON or EFER.SVME per processor, the VMCS or VMCB, entry and exit,
register state, nested paging, guest memory, exception and interrupt
injection, CPUID and MSR handling.  Machines are made by opening
.CW /dev/vm/clone .
Done (M1) when a small freestanding payload runs and exits cleanly.
.IP "4. Linux." 4
One vCPU, memory, a 16550, a minimal PIC/PIT or LAPIC, the Linux boot
protocol (a 64-bit entry with boot parameters, loaded from Limbo).  No
PCI.  Done (M2) at an initramfs shell.
.IP "5. SMP guests." 4
Several vCPUs, INIT/SIPI, LAPIC and IPIs, timer virtualization, vCPU
scheduling on kprocs.  Done (M3) when Linux boots with four processors
and survives a stress run.
.IP "6. Whole-device assignment." 4
.CW "assign 0000:04:00.0"
on a machine's
.CW ctl :
detach the host driver, put the function in the machine's IOMMU domain
mapped to its guest memory, map BARs, virtualize configuration space,
forward MSI/MSI-X through interrupt remapping.  Done (M5) when Linux's
own driver runs a device this kernel has no driver for.
.IP "7. SR-IOV." 4
TotalVFs, InitialVFs, NumVFs, VF enable, VF BARs, offset and stride,
VF device ID, ARI;
.CW /dev/pci/F/sriov/{ctl,vfN} .
Done (M6) when QEMU's igb VFs are created and enumerated.
.IP "8. igb." 4
A PF driver for the 82576 in
.CW os/inferno/pc ,
VF0 and VF1 to two Linux guests running the stock
.CW igbvf .
Done (M7) when the two guests talk through their VFs at once.
.IP "9. virtio backends." 4
Console, then net, then block; enough PCI transport and no more.  Done
(M8) when Linux boots on Inferno-provided virtio disk and network.
.IP "10. Styx control." 4
The
.CW #H ,
.CW #Q
and
.CW #$
trees exported as one host tree.  Done (M9) when another Inferno
machine runs a guest entirely through the mounted files.
.IP "11. Inferno Cloud." 4
.CW appl/cloud/{host,vm,scheduler,network,storage}.b ;
each host exports
.CW /hosts/name/{status,cpu,memory,pci,vm} ;
placement is Limbo policy.  Done (M10) when guests are scheduled
across several hosts.
.IP "12. Resource namespaces." 4
A machine is assembled from a namespace of resources \(en synthetic
devices, Styx services, physical functions, VFs, disk images \(en built
before it starts.  This is where the design leaves KVM's shape on
purpose.
.IP "13. The workstation." 4
Bare metal, then VMX/EPT, Linux, VT-d, FL1100, NVMe, whole X520, the
82599 PF driver, SR-IOV, an X520 VF to Linux (M11).
.IP "14. Newer hardware." 4
ConnectX-4 Lx, a PCIe FPGA as a deliberately misbehaving DMA test
device, newer NVMe, then GPUs.
.IP "15. RISC-V." 4
The H extension, G-stage translation, AIA/IMSIC and the RISC-V IOMMU
as further backends of the same tables (M12).
.IP "16. The emulators made whole." 4
QEMU's TCG implements SVM and not VMX, and Bochs implements VMX and
has no IOMMU, no igb and no virtio-serial, so no one bench runs every
milestone on VMX.  QEMU is given VMX
.CW scripts/qemu-patches ): (
VMXON, the VMCS and its instructions, the controls
.CW pc64/vmx.c
and Linux's
.CW kvm_intel
use, EPT, event injection, and the entry checks real processors make,
with the capability MSRs advertising only what is implemented.  It is
checked against a client that is not this kernel \(en kvm-unit-tests'
VMX and EPT tests, and a Linux guest running
.CW kvm_intel
\(en before
.CW vmx.c
runs on it, so that a bug on one side cannot hide one on the other.
Then check-vm runs every stage on VMX as on SVM (M1\-M8, M5\-M7
included), Bochs staying as a second VMX to disagree with.  After
that, two device models: an 82599 with SR-IOV, from QEMU's igb, for
the X520's PF and VF drivers; and a device that misbehaves on purpose
\(en DMA outside its domain, after bus mastering is turned off, after
an FLR, under another requester ID, and MSIs its IRTE does not allow
\(en in place of phase 14's FPGA.  A model may carry a part's quirks
as well as its architecture, so the rest of the workstation's devices
follow, in this order: the FL1100's quirks on QEMU's xHCI, newer NVMe,
the ConnectX-4 Lx, and a GPU.  Each is checked against Linux's own
driver before this kernel's runs on it.  M11 itself, the workstation's
X520, stays on the hardware.  The X520 modelled is the single-port
82599 (8086:10fb) with a direct-attach SFP+ cable; which one the
workstation has is not recorded here.
.IP
Codesign.  An emulator feature and this kernel's use of it are one
piece of work, not two.  Nothing is added to a model that this kernel
does not then use and check, and nothing is added to this kernel that
a bench cannot exercise: a model's feature lands with the Inferno
driver or hypervisor change that drives it, and a check that runs
Inferno on it, beside the check against Linux.  A feature a model
carries only because the real part has it, and which this kernel
leaves alone on purpose, says so in the plan and in the driver, with
the reason.  The same holds the other way: a kernel feature that needs
hardware the benches lack (APIC virtualization, posted interrupts)
waits on the model or is listed as needing real hardware, not merged
untested.  Where this was not done, it is owed:
.RS
.IP \(bu 2
NVMe APST (patch 0008): paid.  sdnvme programs the transition table
(Features 0Ch) as Linux does, from the drive's power states, the exit
latency bounded by
.CW *nvmeapstlat
(100 ms by default;
.CW *nvmenoapst
leaves it off), and its ctl file says the state Get Features found.
On
.CW VMHOST_NVME=new ,
ipc64dev: "apst on, idle to ps3 after 100ms"; after 3 s idle "power
ps4", after a read "power ps0".
.IP \(bu 2
The FL1100's MSI-X (patch 0009): paid.  usbxhci takes MSI-X vector 0
where the board delivers MSI-X (the bus glue's hooks; the pin with
.CW *usbxhcipin ),
and on
.CW VMHOST_USB=fl1100
enumerates the stick and the keyboard on it ("usbxhci: PCI.6.0.0: msix
vector 0").
.IP \(bu 2
The 82599's offloads (patch 0007): checksum, TSO and RSS are modelled
and checked against Linux.  Receive checksums ether82598 already
reported, IP and TCP honoured them, and now UDP does too (Budpck).
Transmit checksums are paid, which took the IP stack's help, since it
never left a checksum to hardware: TCP and UDP over IPv4 now put the
pseudo-header's sum in the field and mark the Block (Btxck, with the
field's offset in Block.checksum); ipoput4, which alone knows the
outgoing interface, finishes it in software unless that interface's
hardware will (Ipifc.txck, from the driver's Ether.feat through
netiffeatures when ethermedium binds), and always for a packet it
will fragment or NAT; padblock, copyblock and pullupblock now keep a
block's checksum state.  ether82598 inserts it with the legacy
descriptor's CSS, CSO and IC, and counts it ("txck" in ifstats).  M9
with the 82599 as the host's interface (VMHOST_NIC1=ixgbe,
ether0=type=i82598), QEMU's user network checking every checksum:
"VMSERVE: ether0 txck 6673", check-styxvm passes; on the 82576, whose
driver does not offload, the stack's own checksums, check-styxvm
passes.  RSS: QEMU's 82599 hashes (Toeplitz, over MRQC's fields, with
RSSRK's key) and steers by RETA, writing the hash into the descriptor
when RXCSUM.PCSD asks; check-qemu-ixgbe's rss stage sends eight UDP
flows and Linux's per-queue interrupts count them on more than one
("eth0-TxRx-0 +94, eth0-TxRx-1 +14").  ether82598 now has a receive
queue a processor, up to four, on an 82599 without VFs (one with VFs,
or with
.CW *ixgbenorss ):
each its own ring, kproc and interrupt cause (IVAR by queue pair), a
random key and RETA spread round them, and "rxq" lines in ifstats.
check-styxvm with
.CW VMHOST_NIC1=ixgbe
(SVM, QEMU TCG, four processors) opens eight more Styx connections
before M9's run and reads the queues back: "rxq0 pkts 3, rxq1 pkts 95,
rxq2 pkts 11332, rxq3 pkts 0", "rss pass -- 3 of the host's 4 receive
queues took packets"; check-vf on the 82599's VFs (one queue) passes.
Transmit is still one queue.
TSO: paid.  TCP over IPv4, once established and checksummed, builds a
segment of as many MSS's as fit in an IP packet when the interface its
route leaves by cuts segments (Ipifc.tso, from Ether.feat's Etso);
the block is marked (Btso, the MSS in the new Block.mss) and its
checksum field seeded with the pseudo-header's sum without the
length, as the 82599's datasheet asks.  ipoput4 sends it whole to
such an interface and drops it for any other (the route changed since;
TCP sends it again its usual size), devether lets it past maxmtu, and
ether82598 gives it a context descriptor (MACLEN, IPLEN, L4LEN, MSS)
and an advanced data descriptor with TSE; a context descriptor's slot
is freed with the data descriptor after it, whose DD alone says both
are done.  check-styxvm, its new stage reading the host's 89 Dis files
back over the mount and comparing them: on
.CW VMHOST_NIC1=ixgbe
(SVM, QEMU TCG) "read back pass -- 89 of the host's files alike",
"VMSERVE: ether0 tso 132 bad 0", "tso pass"; on the 82576 (no TSO),
read back and M9 pass.  The model is kinder than the hardware here:
QEMU's net_tx_pkt recomputes the pseudo-header's sum itself, so a
wrong seed would pass on the bench; the datasheet, not the bench, is
the evidence for the seed.  check-styxvm also now clears the last
run's host log first, which had let it start against a stale
"listening".
.IP \(bu 2
#AC: paid.
.CW scripts/qemu-patches/0010
makes TCG raise it: data and stack accesses at CPL 3 with CR0.AM and
EFLAGS.AC set go through MMU indexes of their own; translated code's
2, 4 and 8 byte accesses there carry MO_ALIGN (TCG drops atomicity in
serial mode, so the TLB's own alignment check, which goes by
atomicity, never sees them), helpers' are checked by the TLB; the 16
and 32 byte forms are exempt or #GP as ever.
.CW tests/vm/kut-actest.c
(5 checks) and kvm-unit-tests' VMX #AC case (vmx 6937 checks, the
build without it gone) pass in check-qemu-vmx.  Neither backend
intercepts #AC (VMX's exception bitmap is empty unless
.CW *vmxexcbitmap ,
SVM's exception intercepts are never set), so a guest's is its own:
check-vm's M2 guest runs
.CW tests/vm/acguest.c ,
which sets EFLAGS.AC and stores to a 4-byte boundary, and its Linux
sends SIGBUS ("trap alignment check", status 135) on SVM and on VMX.
.IP \(bu 2
Found while checking #AC, QEMU's and not this kernel's: kvm-unit-tests'
svm_exception_test fails after its single-step case.  The run whose
#DB L1 intercepts exits with L2's RFLAGS.TF still set, the test
carries that RFLAGS into the next VMRUN, and that guest's first
instruction traps.  Whether real hardware leaves TF set in the saved
RFLAGS there is not settled; to be, against the APM, before QEMU's
SVM is changed.
.RE
.IP "17. What a hypervisor still lacks." 4
Found by looking at
.CW devvm.c ,
.CW vmx.c ,
.CW svm.c
and
.CW vmplat.c
against what QEMU's models now offer and what hardware has.  Each
item, under phase 16's codesign, is a model change (where an emulator
lacks the feature), the kernel's support, and a check on both
backends; or, where only hardware has it, a check on the workstation.
In rough order of consequence:
.RS
.IP \(bu 2
Device release: paid, but for functions without FLR.  It was worse
than written here: the release ran in
.CW vmpcifree ,
when the machine's last reference went, after
.CW killvm
had freed the guest's memory, so until then the function's domain
still mapped memory given back to the host, and then it went to the
host domain.  Now
.CW vmpcistop
(from
.CW killvm ,
before the memory goes) releases each function: its MSI-X vectors
off, bus mastering off, then straight from the guest's domain into
the IOMMU's blocking domain
.CW iommurelease "" (
in
.CW deviommu.c :
a numbered domain that maps nothing, not killed nor given memory;
the backend repoints the function from one domain to the other, never
through the host domain; a function leaves it when attached elsewhere
or detached), the guest's domain killed, and an FLR
.CW pciflr "" (
in
.CW pci.c :
transactions pending waited out, the reset, 100 ms, the host's BARs
and command register put back).  AMD-Vi's attach, repointing a
device, cleared its DTE in between, which passes DMA through
untranslated; it now writes V and TV with neither IR nor IW, which
refuses everything.  Checks, on SVM and on VMX (QEMU TCG, the
patched QEMU's VMX), the same results: check-vm's M1 boot
assigns QEMU's edu to a machine that is killed, turns bus mastering
back on behind the kernel's back and has edu write its buffer to a
host page by its physical address: on VT-d "vm0.PCI.4.0.0: released:
blocked, no FLR", "RELEASE-BLOCKED-OK ... faulted (1 new faults) and
page B is untouched", then claimed back through #Q, "RELEASE-CLAIMED-OK";
the same on AMD-Vi (64 new faults).  With the old release the same
test fails ("edu in the host domain", "page B untouched 0, new faults
0").  M2's boot: the virtio-serial function M5 assigned, when vmlinux
ends, "vm0.PCI.5.0.0: released: blocked, reset by FLR", and it is
assigned again to the next boot, whose console it carries
("device release and reuse: pass"); check-styxvm's M9 releases it
the same way, and check-vf's VFs of the 82576 and the 82599, each
with FLR, pass.
.IP
The reset, then, on the PCI layer this kernel already had rather than
beside it: the release stops the function with
.CW pcidisable
(MSI, MSI-X, bus mastering, keeping the Pcidev's copy of the command
register), and
.CW pcifnreset
resets it by FLR
.CW pciflr ) (
or, for a function alone below its bridge, a secondary bus reset
.CW pcisbr ), (
both putting back the configuration the host keeps in the Pcidev
.CW pcirestore , (
taken out of
.CW pcienable 's
return from D3, which did the same).  QEMU's edu had no reset at all:
a bus reset cleared its configuration space and left its registers,
DMA buffer and interrupt status, which no real function does;
.CW scripts/qemu-patches/0011
gives it one.  check-vm's release test (SVM and VMX, QEMU TCG) now
sets one of edu's registers before the machine is killed and finds it
clear after: "vm0.PCI.4.0.0: released: blocked, reset by secondary bus
reset", "RELEASE-RESET-OK edu answers at its BAR (ident 10000ed) and
its liveness register is clear", on VT-d and on AMD-Vi.  Not yet: a
function with neither, or sharing its bus (the PM capability's D3hot
reset, where NoSoftRst is clear: no bench function has one without
FLR), and a function that DMAs on its own after release (the
misbehaving device of phase 16; edu only DMAs when told).
.IP \(bu 2
Interrupt virtualization.  Interrupts reach guests by injection only:
no APIC virtualization or posted interrupts (VMX), no AVIC (SVM).
QEMU's TCG VMX does not advertise them (phase 16), so this needs them
modelled first or waits for the workstation.  The assigned functions'
MSIs go through the host and are re-delivered; with posted interrupts
the IRTE would post them straight to the vCPU.
.IP \(bu 2
The VMX features QEMU's model lacks and the backend therefore cannot
use or be tested with: virtual NMIs, the preemption timer, MTF, PML,
VMCS shadowing, VM functions.  Each is taken up when the kernel has a
use for it (PML for migration's dirty tracking, the preemption timer
for scheduling), model first.
.IP \(bu 2
Save, restore and migration.
.CW #H
gives registers and memory but not the state of the platform's
devices (APIC, I/O APIC, PIT, 16550, virtio queues), so a machine
cannot be stopped, written out and resumed, here or on another host
\(en which phase 11's scheduler would want.  A machine's whole state
as files under
.CW #H/vm/N ,
then copying one between hosts over Styx.  (QEMU's own migration of
VMX state and of the 82599 model is the emulators' half and is
housekeeping, item 8.)
.IP \(bu 2
Memory.  A machine's memory is one contiguous run of host memory,
allocated whole: no ballooning, no overcommit, no huge-page choice,
and a host's largest free run caps the largest machine.  Memory in
pieces mapped by NPT/EPT, and a balloon (virtio-balloon in vmvirtio).
.IP \(bu 2
A paravirtual clock.  Guests run on the TSC; there is no kvmclock or
Hyper-V reference time, so a guest's clock across a stop, or on
another host, is not kept.  Needed with migration.
.IP \(bu 2
Hotplug.  A machine's PCI devices are fixed at creation; nothing is
added or removed while it runs (PCIe native hotplug on the guest's
bus, or ACPI).  Wanted for phase 12's namespace-built machines.
.IP \(bu 2
Nesting.  A guest cannot run a hypervisor of its own: VMX and SVM are
not exposed to guests.  The patched QEMU's VMX and the kvm-unit-tests
are the model and the check for it.
.IP \(bu 2
Limits.  At most 16 machines (\f(CWNvm\fP in
.CW devvm.c ).
.RE
.NH 1
Where things go
.DS
.ft CW
os/inferno/port/  devvm.c vm.h deviommu.c iommu.h sriov.c virtio*.c
os/inferno/pc64/  vmx.c svm.c npt.c (and the assembler entry points in l.s)
os/inferno/pc/    vtd.c amdvi.c the PF drivers
appl/cmd/         vmctl.b iommu.b pcictl.b
appl/cloud/       host.b vm.b scheduler.b network.b storage.b
scripts/          vmhost.sh mkbochs-vmx.sh check-vm*.sh check-iommu.sh ...
tests/vm/         freestanding guest payloads
.ft
.DE
.NH 1
Milestones
.PP
M1 a tiny guest under VMX (and separately under SVM); M2 Linux; M3
SMP; M4 the emulated VT-d under control; M5 PCI assignment; M6 igb
VFs created; M7 a VF in Linux; M8 virtio; M9 control over Styx from
another machine; M10 scheduling across hosts; M11 the workstation and
the X520; M12 RISC-V.
.NH 1
The first sprint
.PP
Bench, baseline boots of the unchanged kernel on it, PCIe extended
space and capabilities, DMAR discovery.  Then VMXON, the VMCS, EPT, a
16\-64 MB guest, a tiny guest, a Linux kernel.  The first deliverable
is Linux booted as a guest of Inferno under emulation with the machine
made and run through
.CW #H ;
the second is a QEMU SR-IOV VF assigned to it through
.CW #Q ;
the third is a Limbo program on another machine making, starting,
stopping and inspecting that guest over Styx.
.NH 1
Progress
.PP
Newest last.  Each entry says which bench and, for phases 3\-5, which
backend.
.IP "2 October 2026." 4
Branch cut from
.CW cloud-port
.CW 921fec3cf ;
.CW mkconfig
pointed at this tree; the tree builds from clean on the Mac host
.CW "mk install" "" (
after
.CW scripts/mkemptydirs.sh ).
QEMU 10.1.3 TCG confirmed to refuse VMX and accept SVM.  9front's
.CW devvmx.c
found in
.CW os/9front/pc
as the starting point for the VMX backend.
.CW scripts/mkbochs-vmx.sh
written for the VMX/SVM processor bench.
.IP "Phase 0, the bench (QEMU q35, TCG)." 4
.CW scripts/vmhost.sh
builds the ISO and boots the reference host:
.CW "build" ,
.CW "run [seconds]"
(serial captured to
.CW .qemu/vmhost.log )
and
.CW "debug"
(stopped, gdb on :1234).  The
.CW mk
targets in
.CW os/inferno/pc64
are not written yet; the script is the interface.
The unchanged
.CW cloud-port
kernel did not survive it.  Fixed, each found on this bench:
.RS
.IP \(bu 2
.CW pmap()
built a PML4 entry above 512 GiB only in the calling processor's
table, and
.CW mpstartap()
copied only every eighth PML4 entry to an AP, so a virtio NIC whose
64-bit BAR edk2 put at
.CW 0xc000000000
faulted in its attach on cpu1
.CW 33dbee6b7 ). (
.IP \(bu 2
.CW pcibusno()
returned \-1 for a host bridge with no
.CW _BBN ,
which q35 and much real firmware have, dropping every PCI interrupt
route
.CW b4bd57516 ). (
.IP \(bu 2
.CW dhcpclient 's
.CW setup()
returned a nil error with a nil request when the DHCP port was busy,
and the nil dereference panicked the kernel
.CW de0533b75 ). (
.IP \(bu 2
QEMU's igb disagreed with the 82576 three ways \(en no autonegotiation
out of reset, no link bit in PHY register 17, and advanced receive
descriptors written when legacy ones were selected \(en and is patched,
.CW scripts/mkqemu.sh
and
.CW scripts/qemu-patches
.CW d16222e94 ). (
The driver is unchanged.
.RE
.IP
Four boots since, each clean, DHCP over the igb.  Still open:
.RS
.IP \(bu 2
a second
.CW dhcp()
straight after a failed one finds port 68 still held: the failed
attempt's process holds the UDP descriptor until it exits, which races
the caller.  It now fails with the true error.
.IP \(bu 2
page 0 is mapped on pc64, so a Limbo nil dereference that should raise
"dereference of nil" reads zeros instead.  This is what turned the
dhcpclient bug into a panic.  (Done later: page 0 is unmapped once the
processors are started, mapped for a moment only where the BIOS's
warm-reset vector and warm-boot flag are written
.CW page0 ), (
and a page fault in an interpreter process is its Limbo program's
exception through
.CW disfault ,
as on the 32-bit pc; riscv64's trap does the same with its load and
store faults.  Limbo's nil is H, -1, so a nil field at offset k is
address k-1: the M1 inits read one through nil at the top page and
one in page 0, and check-vm and check-rv pass only if both come back
as "dereference of nil".)
.IP \(bu 2
Bochs is built
.CW scripts/mkbochs-vmx.sh ) (
but the kernel has not been booted on it: it needs a legacy-BIOS loader
for the multiboot image.
.RE
.IP "Phase 1, PCIe (QEMU q35)." 4
Done but for BAR files and the
.CW mk
targets
.CW fece67393 ). (
Extended configuration space through ECAM, the extended capability
walk, PCI Express port type, ARI, and SR-IOV parsing including VF BAR
sizes, in
.CW port/pci.c ;
.CW #$/pci/0000:bb:dd.f/{ctl,config,caps} .
On the bench the igb PF reports TotalVFs 8, offset 128, stride 2, VF
device
.CW 10ca ,
two 64-bit 16 KiB VF BARs, VF0 at 02:10.0; the root ports report ARI
forwarding.
.CW bar N
files are not there: Inferno has no user mapping, so they would be
read/write windows, and nothing needs one yet.
.IP "Phase 2, IOMMU (QEMU q35): discovery only." 4
.CW acpidmar()
reads DMAR into
.CW pc/dmar.h
.CW e9a3a18e4 ): (
haw 48, interrupt remapping, one unit at
.CW 0xfed90000
whose scope covers the IOAPIC, the root-complex functions and the three
root ports.  No unit is programmed;
.CW vtd.c
and
.CW #Q
are next.
.IP "Regression gate." 4
.CW scripts/check-all.sh
on this branch after phases 0\-2: 14 of 16 passed outright; the two
arm64 checks lacked
.CW .qemu/edk2-aarch64-code.fd
in the new worktree.  With it,
.CW check-arm64-smp
passes;
.CW check-crossarch
said "CANNOT TELL" (its arm64 console garbled the typed command) on a
host loaded with two other emulators, and is to be rerun quiet.
.IP "Phase 3, the hypervisor: M1 on SVM (QEMU TCG); VMX open (superseded below)." 4
.CW port/vm.h
and
.CW port/devvm.c
.CW #H ) (
are the portable layer, with
.CW pc64/vmx.c
and
.CW pc64/svm.c
behind the same
.CW Vmops
.CW 61414747c ). (
Each vCPU is a kproc wired to a processor and does all VMCS/VMCB work
itself; unhandled exits go to Limbo through
.CW vcpuN/exit .
.CW os/inferno/init/vmtestinit.b
(the
.CW pc64vm
configuration's init) runs a 32-bit payload that writes "Hi" to port
0xe9 and halts.  On QEMU's SVM it passes: two decoded i/o exits, a
clean
.CW hlt
at 0x1008.  The VMX backend registers on Bochs
.CW corei7_skylake_x
("vm: vmx": EPT and unrestricted guest present), but on Bochs the
kernel stops after
.CW schedinit
and never runs Dis \(en plain
.CW pc64
too \(en so M1 on VMX is not yet shown.  That stall is being located.
Bochs boots the kernel through
.CW os/inferno/boot/pc 's
.CW 9bootiso
from a CD built by
.CW scripts/bochs-vm.sh ;
the same image boots to a shell under QEMU's BIOS.
.IP "Phase 3: M1 on VMX (Bochs)." 4
The Bochs stall was Bochs's: its TSC-deadline timer was scheduled
against the raw tick count, not the TSC, which this kernel rewrites at
boot, so the halted idle loop was never woken.  Patched
.CW scripts/bochs-patches ), (
and M1 passes on the VMX backend as on SVM
.CW 2ebf3e7a7 ). (
.IP "Phase 4: M2 on SVM (QEMU TCG)." 4
An unmodified Alpine 6.6 kernel
.CW scripts/mklinuxguest.sh ) (
boots under
.CW #H
to a busybox shell that runs a command typed from Limbo
.CW e65802bc6 ). (
.CW vmlinux (1)
loads it by the 32-bit boot protocol.  The platform
.CW pc/vmplat.c ,
.CW pc/vmdev.c ) (
is an 8259 pair, an 8254, a 16550 and a local APIC, with CPUID, MSRs,
HLT and the APIC's MMIO page (through a small instruction decoder and
a guest page walk) handled in the kernel.  The PIT is required: with no
MP or ACPI configuration Linux never starts the APIC's clock, and the
first platform tried without it reached a prompt that ran nothing \(en
an earlier note claiming otherwise was wrong and is corrected in the
commit.
.CW scripts/check-vm.sh
runs M1, M2 and M5.  M2 on VMX: Bochs got as far as the guest's
speculation-mitigation messages and stalled there once; being rerun
with status reporting.
.IP "Phase 2: M4 (QEMU, intel-iommu)." 4
.CW #Q
.CW port/deviommu.c ) (
and the VT-d backend
.CW pc/vtd.c ) (
.CW ee2dc9c15 ). (
With translation on, QEMU's edu device in its own domain copies
through IOVA 0x100000 correctly, and a copy aimed at the host physical
address of one of its own pages \(en which the domain does not map \(en
faults (requester 04:00.0, reason 5) and leaves that page untouched,
while the host's own devices keep working through the pass-through host
domain.  Not yet: interrupt remapping, queued invalidation, AMD-Vi
(all three came after, below).
.IP "Phase 2: VT-d queued invalidation (QEMU q35, intel-iommu, TCG)." 4
Where a unit has it (ECAP.QI), invalidation goes through a queue of
descriptors now, the registers only where it does not: a page of 256
128-bit descriptors, a global context-cache and a global IOTLB
invalidation (draining reads and writes where the unit can) followed by
an invalidation wait whose status write is polled; an invalidation
queue error is reported with the head it stopped at.  Real units
increasingly have only this, and interrupt remapping needs it.
.DS
.ft CW
vtd: unit 0 at 0xfed90000 translating (host domain pass-through, queued invalidation)
DEVTEST: IOMMU-DMA-MAPPED-OK 256 bytes A -> edu -> B through IOVA 0x100000
DEVTEST: IOMMU-DMA-BLOCKED-OK DMA to host pa 1bcb8000 faulted and page B is untouched
.ft
.DE
.IP "Phase 2: VT-d interrupt remapping (QEMU q35, intel-iommu,intremap=on, TCG)." 4
Every interrupt a device or an I/O APIC sends is a write to 0xFEExxxxx;
with remapping on, the unit covering the sender looks it up in a table
of IRTEs \(en vector, destination, trigger, and for an MSI the requester
ID it must come from \(en so a function assigned to a guest can raise
only the interrupts its entries allow.  It comes on as the VT-d backend
is linked, where DMAR says the platform has it and every unit has it
and queued invalidation: one table of 256 IRTEs every unit shares,
pointed to (SIRTP), its cache invalidated, IRE on, and compatibility
format not let through (CFI clear) \(en the only way it protects
anything.
.CW pc/mp.c
routes the I/O APICs' entries and every MSI and MSI-X vector through
.CW irroute
then, in the remappable format (the IRTE's index where the vector and
processor were), and
.CW intrreroute
routes again everything routed before, the clock and the console among
them.  Requester IDs are checked (SVT 1): an MSI's is its function's,
an I/O APIC's the one its DMAR scope gives (QEMU's: bus FFh, 00.0),
where the scope's path is one step.  A boot under QEMU's
.CW vtd_ir_*
trace remapped 2509 interrupts in 90 seconds, every one checked, and
the kernel ran M1 on top of it:
.DS
.ft CW
vtd: interrupt remapping on, 1 units, 256 entries
vtd_ir_irte_get index 3 low 0x4ff00 high 0x30000590001
VMTEST: M1 PASS
.ft
.DE
.LP
The whole of
.CW check-vm
then ran on kernels with remapping on (SVM backend, QEMU TCG, q35
with intel-iommu,intremap=on, four processors, MTTCG for M3) \(en every
host interrupt, the guests' assigned functions' MSI-X among them, went
through an IRTE:
.DS
.ft CW
check-vm: M1 (svm): pass
check-vm: nil dereference (svm host): pass
check-vm: M2 (svm): pass
check-vm: M5 (svm): pass
check-vm: M8 disk (svm): pass
check-vm: M8 net (svm): pass
check-vm: M8 boot on the virtio disk (svm): pass
check-vm: M4 (vt-d): pass
check-vm: M4 (amd-vi): pass
check-vm: M3 (svm): pass
.ft
.DE
.IP "Phase 2: AMD-Vi (QEMU q35, amd-iommu, TCG)." 4
.CW pc/amdvi.c
is the IOMMU layer's AMD backend, found through the IVRS table
.CW archacpi.c 's (
.CW acpiivrs ):
one device table of 65536 entries, each function valid and
untranslated (the host domain) until attached; a domain is a four-level
AMD I/O page table and a domain ID; changes go through the command
buffer (invalidate the entry or the domain's pages, then a completion
wait whose store is polled) and faults come back through the event
log.  The VT-d test
.CW pc64devinit.b ) (
run with
.CW VMHOST_IOMMU=amd :
.DS
.ft CW
ivrs: amd-vi regs 0xfed80000 device 00:02.0 segment 0 pasize 40
iommu: vtd: no DMAR table
iommu: amd-vi
amdvi: translating, device table 0x1bcb6000, 65536 entries
DEVTEST: IOMMU-DMA-MAPPED-OK 256 bytes A -> edu -> B through IOVA 0x100000
0 04:00.0 write 0x1beb8000 reason 0x2 I/O page fault
DEVTEST: IOMMU-DMA-BLOCKED-OK DMA to host pa 1beb8000 faulted and page B is untouched
.ft
.DE
QEMU's amd-iommu disagreed with the hardware three ways, now
.CW scripts/qemu-patches/0005 .
It took a device's bus number when the device's address space was
made, before firmware numbered the bus behind its bridge, so every
device behind a bridge had bus 0 for requester ID \(en edu at 04:00.0
used 00:00.0's device table entry, the host domain, and its "IOVA"
0x100000 was the host's IDT; the first run wrote over it.  Address
spaces are kept by bus now and the number read at translation.  A
not-present page table entry below the top level returned without an
I/O page fault; and an event's address, bits 64 to 127, was masked
with the field's bit offset in the whole event rather than in its
quadword, so it was always 0.  (The page fault's flags also carried
QEMU's permission bits where the specification has RW.)
.IP "Phase 6: M5 on SVM (QEMU)." 4
.CW pc/vmpci.c
.CW d91115e3c ): (
the guest's PCI bus through configuration mechanism 1, an assigned
function's configuration space virtualised (BARs, MSI-X, ROM), its
BARs mapped uncached but for the trapped MSI-X table, MSI-X forwarded
from per-entry host vectors into the guest's APIC, and DMA through an
IOMMU domain mapping guest-physical onto guest memory.  The bench's
virtio-serial function, which Inferno has no driver for, is assigned to
the Linux guest, and its own
.CW virtio_console
writes "hello-from-the-guest" through it to QEMU's chardev.  The bench
device needs
.CW iommu_platform=on :
QEMU's virtio otherwise bypasses the emulated IOMMU, which no real
device can.
.IP "Phase 7: M6 (QEMU igb)." 4
.CW #$/pci/F/sriov
.CW 6e89830d2 ): (
"vfs 4" sets ARI Capable Hierarchy, NumVFs and VF Enable, waits the
specified 100 ms, and enumerates VFs 02:10.0, .2, .4, .6 as functions
with their VF BARs; "vfs 0" removes them.  VFs made after translation
is on get host-domain contexts.  What it exposed for phase 8:
.CW ether82563
is not an SR-IOV PF driver \(en queue 0 is VF0's pool once VFs exist,
and VF0's reset disables it \(en so the PF loses its receive queue.
.IP "Phase 10: M9 (QEMU + emu)." 4
.CW os/inferno/init/vmserveinit.b
exports the host's namespace on tcp!*!5640, and
.CW scripts/check-styxvm.sh
has hosted Inferno on the Mac mount it and run
.CW vmlinux
against the remote
.CW /dev/vm :
a machine made, given memory, assigned a device, booted from files on
the Mac, typed at and read back, all over Styx
.CW 1c3c4b338 ). (
.IP "Phase 11: M10 (QEMU + emu)." 4
Each host's
.CW #H
has a
.CW host
file \(en backend, processors, free memory, the largest contiguous run
of it, machines, vCPUs and guest memory in use \(en and
.CW vmsched (1)
.CW appl/cloud/vmsched.b ) (
reads it from every mounted host and places guests on the host running
the fewest machines, ties to the most contiguous memory, then runs each
with
.CW vmlinux
in a namespace with that host's
.CW /dev
bound in.
.CW scripts/check-cloud.sh
boots two hosts (2 and 1 GiB) and has emu place three 256 MiB guests:
0 and 2 on the larger, 1 on the smaller, and each answers a line typed
at its console naming the host it was put on.  Two bugs found on the
way: the kernel's
.CW xallocz
zeroed its block's size from the data rather than the header, clearing
the next block's header, so killing a guest whose memory lay just
above another allocation panicked in
.CW xfree ;
and
.CW vmlinux
read the kernel and initrd whole, which ran a hosted emu loading three
at once out of heap \(en it now streams them.  Freed guest memory does
not always coalesce back into the largest run (the hosts report less
contiguous memory after the guests are gone than before), since the
kernel's own allocations land between; a guest-memory arena of its own
would fix it.
.IP "VMX, Linux." 4
On Bochs (one processor) the host stalled with the guest early in its
boot, at a different line each run.  It was not the hypervisor.  With
Bochs's debugger reachable by SIGINT
.CW BOCHS_CMDS ) (
the stopped host showed no process running and the local APIC's timer
taken every 415 instructions; Bochs, instrumented, showed the TSC
deadline written each time was the TSC's low 32 bits plus a tick.
.CW pc64/fns.h
declared
.CW "wrmsr(ulong, ulong)" ,
and ulong is 32 bits here, so every MSR write lost its upper half: once
the TSC passed 2^32 every deadline was already gone and the timer
interrupted without end, starving every process (QEMU's TCG processor
has no TSC-deadline timer, which is why only Bochs showed it).  PAT's
upper entries, the MTRR masks and the machine-check enables were cut
the same way, on real hardware too.  Fixed in the prototype; the
assembly always took 64 bits.  The heartbeat (ctl
.CW trace )
now also reads processor 0's ticks, since an application processor's
need not advance, and a watchdog prints the processes when a traced
vCPU stops taking exits.
.IP "Phases 4 and 9: M2 and M8 on VMX (Bochs)." 4
With the host keeping time,
.CW pc64linux
.CW linuxtestinit.b ) (
ran to the end on Bochs, one processor, the VMX backend
.CW "vm: vmx" "" (
on the console): the linux-virt guest booted to its shell and ran the
typed command; read the marker on its virtio disk and wrote the next
sector, which Limbo read back; made an ext2 root on its second virtio
disk; and the second guest booted on that disk alone.  The booted host
printed
.DS
.ft CW
vm 0 backend vmx mem 268435456 vcpus 1
LINUXGUEST: up 6.6.142-0-virt cpus 1 uptime 5.07
LINUXGUEST: vda says INFERNO-VIRTIO-DISK
LINUXGUEST: made a root on vdb
platform handled cpuid 655 msr 36 io 155346 mmio 2198 hlt 3196 intr 8243 gp 5 msi 976
LINUXTEST: disk sector 1: guest-wrote-this
LINUXTEST: booting on the virtio disk
LINUXGUEST: root /dev/vda ext2
LINUXGUEST: on disk
LINUXGUEST: ran
.ft
.DE
M2 and M8's disk half are met on VMX.  M8's network half and M5 were
not exercised there: the Bochs bench has neither the second NIC nor the
virtio-serial function.  The run took about an hour of Bochs.
.IP "Phase 5: M3 on VMX (Bochs, two processors): done." 4
The last of it, below, was the VMX backend's.  Two vCPUs wired to one
processor take turns on it, and a VMCS is that processor's current one
until another is loaded; the backend loaded a vCPU's VMCS
.CW vmxload ) (
and then read or entered it, and a vCPU preempted between the two came
back to the other vCPU's VMCS.  The HLT exits read with IF clear were
the other vCPU's RFLAGS, and the all-zero exit another entry's.  The
vCPU's process now carries its VMCS
.CW up->vmx ), (
and
.CW procrestore
makes it current again whenever the process is scheduled (KVM's
preempt notifiers do the same).  SVM has no current VMCB, and the
RISC-V backend keeps the VS CSRs in the vCPU and enters at splhi, so
neither had the fault.  On Bochs (corei7_skylake_x, two processors,
1 GiB) the four-vCPU guest
.CW pc64smp ) (
then ran M3's test through:
.DS
.ft CW
[    3.525745] smp: Brought up 1 node, 4 CPUs
LINUXGUEST: up 6.6.142-0-virt cpus 4 uptime 14.99
LINUXGUEST: smp 4 processors, online 0-3
LINUXGUEST: worker 2 done
\&...
LINUXGUEST: worker 7 done
LINUXGUEST: cpu0 38 0 767 1289 0 122 0 0 0 0
LINUXGUEST: cpu1 17 0 424 980 0 31 0 0 0 0
LINUXGUEST: cpu2 21 0 218 1266 0 10 0 0 0 0
LINUXGUEST: cpu3 21 0 134 848 0 0 0 0 0 0
LINUXGUEST: irq LOC:       2217       1447       1507       1004   Local timer interrupts
LINUXGUEST: irq RES:         26         26         34         20   Rescheduling interrupts
LINUXGUEST: irq CAL:        239        410        205        401   Function call interrupts
LINUXGUEST: irq TLB:          3          1          1          0   TLB shootdowns
LINUXGUEST: ran
.ft
.DE
The history:
.IP
The four-processor guest
.CW pc64smp ) (
does not boot on VMX.  On a two-processor Bochs host it halts at once
in
.CW native_halt ,
the early boot's halt loop, having printed nothing (not even with
.CW earlyprintk ):
.CW vmlinux
now dumps an x86 guest's stack at such an exit, through its page
tables, and the frame there is
.CW early_idt_handler_common
for a fault in
.CW copy_bootdata +0x26,
the first read of boot_params through the direct map \(en a page
fault that
.CW early_make_pgtable
should have satisfied, with the guest's CR2 left at
0xffffffffffffffe6.  No other exception was taken first (the new
.CW *vmxexcbitmap=
in plan9.ini intercepts the guest's exceptions, here all but #PF).  On
a one-processor host it does not halt there, but nothing comes, not
even the vCPU's heartbeat, in over an hour.  The same kernel boots on
SVM with four processors, and on VMX with one.
.IP
The one-processor guest fails the same way on the two-processor host,
whose vCPU is then on the host's application processor: it is the
processor, not the guest's four.  A trace of every exit (rip, the
guest's CR2 before and after) showed an external-interrupt exit taken
with the guest's RIP still on the faulting load and CR2 already holding
its address \(en a #PF begun and not delivered, with no IDT-vectoring
information \(en and the guest, resumed there, next fault at
0xffffffffffffffe6.  Real hardware does not write CR2 for a #PF it then
leaves undelivered; Bochs's #PF path writes it before delivery, and its
external-interrupt exits are taken only at instruction boundaries, so
where it goes wrong inside Bochs is not found yet.  With
.CW *vmxexcbitmap=0x4000
the backend takes the guest's page faults itself and gives them back as
the processor would, CR2 set (a VMM's ordinary choice without EPT), and
the guest gets past it: Linux printed its banner on the application
processor.  Run that way, the four-processor guest printed its first
two lines and then nothing more, the vCPU heartbeat included, for half
an hour: the same as the four-vCPU guest on the one-processor host.
So there are two problems: the lost CR2 on Bochs's application
processor, and a host that stops when a VMX guest has four vCPUs.  M3
on VMX is still open.
.IP
The stopped host was Bochs's.  Under its debugger the processor was in
the guest, spinning with IF clear, and never left: Bochs recomputes
whether external interrupts are masked only when IF changes, and VM
entry changes what masks them (with external-interrupt exiting, IF
does not) without recomputing \(en so a guest entered with IF clear
from a host with IF clear kept the host's interrupts masked until it
set IF itself.  VM exit had the mirror fault: the host, back with IF
clear, could be handed an interrupt.  Real processors do neither.
.CW scripts/bochs-vmx-intmask.patch ,
which
.CW mkbochs-vmx.sh
applies, recomputes the mask at both.  (SVM had its own version of
this, in the kernel: below.)  With it the four-vCPU guest runs on
Bochs, and two more things showed.  An INIT for an application
processor that was running only marked it to wait for a SIPI, and it
went on running its old code until a SIPI happened to find it stopped;
a processor stops at INIT, and now a running vCPU does too (the
platform's
.CW vmplatinit ,
looked at on its own processor between exits), and waits for its SIPI
as one never started.  And on Bochs the application processors still
took HLT exits that the platform read with IF clear, and once an exit
of all zeros \(en with two vCPUs sharing a processor's VMCSs: the
VMCS fault above.
.IP "Phase 5: a four-vCPU guest on one processor (SVM, QEMU TCG)." 4
The four-processor guest on a one-processor host stopped after its
first lines, the vCPU heartbeat with it.  The QEMU monitor
.CW VMHOST_MON= , (
new) showed the processor in the guest at one instruction with the
guest's interrupts off, and the host's timer interrupt pending in its
local APIC's IRR and never taken.  The VMCB left V_INTR_MASKING clear,
under which a physical interrupt is masked by the guest's IF: a guest
spinning with interrupts off \(en Linux waiting for an application
processor to come up \(en never exited, and with one processor that
application processor's vCPU never ran.  With more processors it ran
elsewhere, which is why M3 passed.  V_INTR_MASKING is set now and
.CW svmrun
executes VMRUN with IF set under a clear GIF
.CW "CLGI; STI; VMRUN; CLI; STGI" ), (
as KVM does, so a host interrupt always takes the guest out; the guest
also gets a TPR of its own rather than writing the host's.  The same
guest on the one-processor host then ran M3's test through: four
processors online, the eight workers done, every processor taking
timer, rescheduling, function-call and TLB-shootdown interrupts.
.IP "Phase 9: M8 on SVM (QEMU)." 4
.CW pc/vmvirtio.c :
virtio functions of the hypervisor's own on the guest's PCI bus, the
virtio 1.0 PCI transport (one trapped BAR: common, ISR, device and
notify structures, MSI-X table), split rings in guest memory with every
address checked.  blk serves a file in the namespace of whoever wrote
"virtio blk
.I path "
\(en a Limbo memfs file in the check \(en on the vCPU's own kproc;
net opens a bridge port on an ether(3) device (every type, promiscuous,
bridge mode, so devether keeps the guest's source address and learns
it), with a receiving kproc stopped before the guest's memory goes.
The guest (now
.CW linux-virt-6.6.142-r0.apk ,
pinned by package checksum, with its virtio_blk, virtio_net and
af_packet modules) finds vda, reads the marker Limbo wrote and writes a
sector Limbo reads back; and gets a DHCP lease from QEMU's user network
through the bridge port on the bench's virtio NIC.  The first net run
returned every receive buffer the moment the driver posted it, empty
\(en a notification on the receive queue was served like a request \(en
which the guest counted as 954,000 length errors; the check now
requires none.  Also fixed:
.CW vmlinux 's
.CW -q
matched its pattern in the console's echo of the typed command and
stopped guests early; it now matches only at a line's start.
.IP "Phase 5: M3 on SVM (QEMU, one TCG thread)." 4
"vcpus
.I n "
on a machine's ctl makes processors 1 to n\-1, each a kproc wired to a
processor of its own where there are enough, waiting as an application
processor waits.  The platform delivers what a guest APIC's ICR sends
(fixed, lowest-priority, NMI, INIT, SIPI; physical, logical flat or
cluster, and shorthand destinations) and MSIs to the APICs they name;
a SIPI starts a vCPU in real mode at its page, set on its own
processor; a vCPU in guest mode elsewhere is taken out by a host IPI
(LAPIC IRQ 21) to see what it was sent.  An NMI is injected only when
an interrupt could be (so not into the guest's NMI handler, which a VM
entry would refuse; one sent to a processor spinning with interrupts
off waits), and an INIT to a processor already running does not stop
it.  There is an I/O APIC (vmdev.c: 24 entries at 0xFEC00000, the PIT
on input 2, the UART on 4; edge delivery, no remote IRR).
.CW vmlinux
.CW -c
writes ACPI (RSDP, RSDT, and a MADT with a local APIC per vCPU, the
I/O APIC and IRQ 0's override to GSI 2) rather than an MP table, which
Alpine's kernel does not parse, and names it in
.CW boot_params.acpi_rsdp_addr .
.CW scripts/check-vm.sh 's
M3 stage boots
.CW pc64smp 's
guest with four: all online, eight busy workers run at once and finish,
every processor accounts user and system time and takes rescheduling,
function-call and TLB-shootdown IPIs, and the guest reports no BUG,
lockup or stall.  Linux passes its NMI self-tests.  Without an I/O APIC
described, Linux took "symmetric
I/O mode", masked the PIC's timer and UART inputs and expected them
from an I/O APIC that was not there: the kernel's own printk (polled)
went on but user programs' output never came \(en hence the I/O APIC.
.IP
QEMU's multi-threaded TCG: with four host processors each running a
vCPU, the host triple-faulted on processor 0 at the instruction after
VMRUN, reading its IDT, with the guest's TR and GS still loaded (which
they are there, until the VMLOAD after it), found with QEMU's
.CW cpu_reset
log
.CW VMHOST_D=cpu_reset , (
.CW VMHOST_REBOOT=1 ).
With
.CW VMHOST_ACCEL=tcg,thread=single ,
which the M3 stage uses, it has not happened.  That points at QEMU's
nested SVM under MTTCG rather than the exit path, but does not prove
it: one thread also serialises the host's own processors.  Still open;
nested KVM on real hardware is the arbiter.
.IP
Three MTTCG runs after V_INTR_MASKING (below): one host reset right
after the guest started, as before; and twice the guest's vCPU 3 took a
triple fault instead (exit 0x7f), CR2 0xfffffe0000000080 \(en its
IDT's base plus 0x80, gate 8: delivering a double fault, it found its
own IDT page, which Linux maps at boot and never changes, not mapped.
Never with one thread.  The pattern still points at QEMU's nested paging
under MTTCG.
.IP
It was QEMU's, and it is fixed
.CW scripts/qemu-patches/0004-i386-ignne-atomic.patch ). (
Paused at the triple fault
.CW "-action shutdown=pause" , (
and a monitor), processor 0's page tables mapped its kernel text after
all; QEMU's interrupt log showed the host's first fault to be an
instruction fetch at that text, right after a #VMEXIT, as if the host
were translating through its guest's nested page tables.  A check
added to QEMU's page walker confirmed it \(en a stage-2 walk with the
processor out of guest mode, hflags2 0x40, HF2_NPT_MASK alone \(en and
checks through
.CW do_vmexit
found the flag set again immediately after the line that clears it.
Something else wrote that word: QEMU emulates the chipset's IGNNE# as
a bit of the first processor's hflags2, which
.CW cpu_set_fpus
clears on every FNCLEX, FLDENV, FRSTOR and FXRSTOR, on whichever
processor executes it, with a plain read-modify-write from that
processor's thread.  Under MTTCG it raced processor 0's own thread:
landing across #VMEXIT's clear of the nested-paging flag, the host ran
on its guest's page tables (the host reset); landing across VMRUN's
set, the guest ran without them (its IDT "not mapped").  Always
processor 0, the first.  The patch changes the bit only when it must
and atomically, so no other bit is written back stale.  Before it,
three MTTCG M3 runs failed three times; after, three of three passed:
.DS
.ft CW
LINUXGUEST: smp 4 processors, online 0-3
LINUXGUEST: cpu0 9 0 333 98 0 0 1 0 0 0
LINUXGUEST: cpu1 5 0 9 327 0 0 0 0 0 0
LINUXGUEST: cpu2 7 0 12 316 0 0 0 0 0 0
LINUXGUEST: cpu3 9 0 19 296 0 0 0 0 0 0
LINUXGUEST: irq RES:         10         64         25         47   Rescheduling interrupts
LINUXGUEST: irq CAL:        440        348        327        211   Function call interrupts
LINUXGUEST: ran
.ft
.DE
and check-vm's M3 runs multi-threaded now, as its other stages do.
.IP
Also found here: the test's typed command grew past 1024 characters,
the most busybox's shell takes on a line, which dropped the rest and
left the shell waiting for a closing parenthesis; it is typed as
several lines now.
.IP "Phase 8: M7 (QEMU igb)." 4
.CW ether82563
is the 82576's SR-IOV PF: with
.CW *igbvfs= \fIn
in plan9.ini it makes
.I n
VFs when the interface is attached and runs the switch for them as
Linux's igb does \(en pools 0 to
.I n \-1
the VFs', the PF in pool and queue
.I n
(VT_CTL's default pool; its ring registers move with it), VMDq sorting
by destination address, the transmit switch looping between pools,
.CW RCTL.SECRC
(QEMU strips the CRC only on it) \(en and serves the VF mailbox:
reset (the VF's address back, its filter and pool enables set),
address, multicast hashes, VLAN (accepted, not filtered) and frame
size, then PFRSTD once.  The VFs' interrupts work only in MSI-X mode,
so the PF runs on one MSI-X vector of its own.  vmpci gives an assigned
VF the vendor and device IDs its configuration space reads as all ones.
.CW scripts/check-vf.sh
boots
.CW pc64vf
.CW vftestinit.b ): (
two linux-lts guests (Alpine's linux-virt has no igbvf) on the two
VFs at once; igbvf takes the address the PF gives, its link comes up,
and each pings the other through the 82576's switch, nothing lost.
The research behind it (QEMU's igb model, Linux's igb and igbvf) found
what the M6 note had seen: VF0's reset disables queue 0 because queue 0
is pool 0's, which is why the PF moves.
.IP "Phase 12: a machine from a namespace (QEMU + emu)." 4
.CW vmlinux
.CW -N
.I dir
builds a machine from a directory \(en kernel, initrd, cmdline, mem,
cpus, and disk/, net/, pci/ with an entry per device \(en put together
with bind and mount; the kernel's virtio backends open each device by
its path in that namespace, so what is bound there is what the guest
gets.
.CW scripts/check-nsvm.sh
has the native host
.CW pc64nsvm , (
.CW nsvminit.b )
mount a directory the Mac exports from emu, assemble
.CW /tmp/m
in a memfs from four places \(en the kernel and initrd from its root,
the disk image from the Mac's mount, the bench's virtio NIC's
.CW #l1
directory as its network \(en and boot it.  The guest reads the marker
the Mac wrote, writes a sector that the check then reads from the file
on the Mac, and gets a DHCP lease on the bound network.
.IP
Found here: a shell started by calling
.CW sh->init
with
.CW -c
from the init's own thread ends that thread when its command is done
\(en sh finishes with Limbo's
.CW exit ,
which is the caller's \(en so the init stopped, silently, after each
shell (vmserveinit never noticed, its servers living on in other
threads).  It looked first like a hang in the mount, then in ndb/cs,
then in sh with
.CW #e
bound; it was none of them.  nsvminit does without the shell.
.IP "Phase 15: M12 begun, M1 on RISC-V (QEMU riscv64 virt, TCG)." 4
.CW virt/vmrv.c
is a third backend of the same
.CW Vmops ,
for the H extension.  This port's kernel runs in machine mode, so the
hypervisor does too: a guest is entered by MRET with
.CW mstatus.MPV
set and MPP supervisor, which is VS-mode, its addresses put through
the G stage (hgatp, Sv39x4, guest RAM in 2 MiB pages); what the
guest's own supervisor handles is delegated to it through medeleg,
hedeleg and hideleg, and everything else comes back through
.CW rvexit
.CW l.s ) (
\(en its ecalls, the G stage's faults, WFI (hstatus.VTW), the host's
interrupts.  The C calling convention keeps nothing in registers across
a call but SP, the link and SB, so that is all of the host the switch
saves, with the floating-point registers swapped whole.  A PMP entry
over all of memory is needed for anything below machine mode to reach
memory at all.
.CW virt/vmplat.c
is the platform, which on RISC-V is the SBI: base, the legacy console,
TIME, DBCN, answered in the kernel; SRST handed up as a new portable
exit,
.CW shutdown .
The guest's timer is hvip.VSTIP, and a WFI with it armed sleeps until
it is due.  To make room for a register set that is not x86's, the
register names are the backend's now
.CW Vmops.regname , (
.CW nreg ,
.CW pc ),
the x86 ones moved to
.CW pc/vm86.h .
.CW scripts/check-rv.sh
boots
.CW virtvm
.CW rvtestinit.b ) (
under
.CW "qemu-system-riscv64 -M virt" ,
whose rv64 has H, and passed first time:
.DS
.ft CW
RVTEST: backend riscv-h misa 0x80000000001411ad hstatus 0x200000000 g-stage sv39x4
RVTEST: exit mmio rip 0x1034 ilen 4 raw 0x17 qual 0x10000000 gpa 0x10000000 gva 0x10000000 access 2
RVTEST: exit shutdown rip 0x1098 ilen 4 raw 0x0 qual 0x0
vcpu0 handled 5 exits mmio 1 hlt 1 vmcall 5
platform sbi calls 5 time 1819480
RVTEST: the guest said "Hi from VS-mode
T"
RVTEST: M1 PASS (riscv-h)
.ft
.DE
The guest printed by the legacy putchar and by DBCN, stored to an
address with no RAM (the mmio exit, stepped past from Limbo), armed
its timer and waited in WFI; the timer interrupt reached its stvec by
hvip
.CW vscause "" (
0x8000000000000005), and it shut down.
.IP "Phase 15: M2 on RISC-V (QEMU riscv64 virt, TCG)." 4
An unmodified Linux \(en Alpine 3.22's riscv64
.CW linux-lts
6.12.111, its Image uncompressed by
.CW scripts/mklinuxguest.sh ,
with busybox-static 1.37 and the same
.CW /init
\(en boots under
.CW riscv-h
to a shell and runs a command typed from Limbo.
.CW vmlinux
has a RISC-V path: the Image at its text offset, a0 the hart, a1 a
flattened device tree it writes itself (one hart with its
.CW riscv,cpu-intc ,
the timebase, the memory, a 16550 at 0x10000000 with no interrupt,
which Linux polls).  The platform gained the 16550 \(en the x86
platform's, moved to
.CW port/vuart.c
so both use one \(en done by decoding the faulting load or store, from
mtinst's transformed instruction or, where there is none, the
instruction itself read through the guest's own page tables; and SBI
IPI, RFENCE, HSM and the legacy calls.
.CW scripts/check-rv.sh
runs it after M1; the booted host printed
.DS
.ft CW
[    0.294637] 10000000.serial: ttyS0 at MMIO 0x10000000 (irq = 0, base_baud = 230400) is a 16550A
LINUXGUEST: up 6.12.111-0-lts cpus 1 uptime 0.45
LINUXGUEST: typed
Linux 6.12.111-0-lts riscv64
LINUXGUEST: cpuinfo isa		: rv64imafdc_zicntr_zicsr_zifencei_zihpm_zca_zcd
LINUXGUEST: dmesg [    0.000000] SBI HSM extension detected
LINUXGUEST: ran
vcpu0 handled 6784 exits mmio 5463 hlt 242 vmcall 1079 extint 56
check-rv: M2 (riscv-h, QEMU TCG): pass
.ft
.DE
.IP
Found on the way, in order:
.RS
.IP \(bu
Nothing ever lowered a process's priority after
.CW canlock
raised it to PriLock: the clock interrupt's
.CW canlock(&clock0lock)
raised whatever it interrupted, a vCPU's kproc never sleeps to have it
recomputed, and the scheduler always picked it again over Limbo, which
then never ran \(en no console, no timeout.  On a PC with more than one
processor the vCPU has a processor of its own, which hid it.
.CW canlock
no longer raises it (lock never did).
.IP \(bu
The riscv64 clock never marked a long-running process for
rescheduling; it calls
.CW hzsched
now, as portclock does, which is what devvm's loop looks at.
.IP \(bu
The riscv64 console UART sent at most 128 bytes per kick and had no
transmit interrupt, so the rest of a long write waited for the next
write; it now finishes on the THRE interrupt.
.IP \(bu
The backend re-entered the guest in VS-mode after a host interrupt
that had taken it out of VU-mode \(en user code run as supervisor, a
store fault on its own
.CW tp ,
and a guest looping in
.CW handle_exception .
The mode it left (MPP) is kept with it now.
.IP \(bu
busybox 1.37's line editor asks the terminal where its cursor is
(ESC [ 6 n) and takes no input until it has the answer; 1.35, the x86
guest's, asks and goes on.  A canonical read in the guest had the typed
line, so the UART was right.
.CW vmlinux ,
which is the guest's terminal, answers now.
.RE
.IP "Phase 15: M8 on RISC-V (QEMU riscv64 virt, TCG)." 4
The virtio backends moved to
.CW port/vmvirtio.c
and gained a second transport beside PCI: virtio-mmio, version 2, its
interrupt a level on a line of the platform's interrupt controller
(the platform sets
.CW vvirq ,
as the x86 one sets
.CW vvmsi ).
The RISC-V platform has that controller now: a PLIC as Linux's
.CW irq-sifive-plic
drives it, one context (the hart's supervisor, hvip.VSEIP),
level-triggered sources pending again at completion while still up.
.CW "virtio blk|net"
on the machine's ctl puts a device in the next window from 0x10001000
on the next source from 1, where QEMU's virt machine has its, and
.CW vmlinux
describes the PLIC and each window from what status says.  The
riscv64 guest's initramfs carries the virtio modules (all of virtio is
modular in that kernel).
.CW scripts/check-rv.sh
boots the host with a second NIC; the guest read the marker Limbo put
on its disk, wrote the next sector, which Limbo read back, and got a
lease on a bridge port on the second NIC:
.DS
.ft CW
riscv-plic: plic@c000000: mapped 31 interrupts with 1 handlers for 1 contexts.
LINUXGUEST: vda says INFERNO-VIRTIO-DISK
LINUXGUEST: dhcp udhcpc: lease of 10.0.2.15 obtained from 10.0.2.2, lease time 86400
LINUXGUEST: irq  12:          5  SiFive PLIC   1 Edge      virtio1
LINUXGUEST: irq  13:          6  SiFive PLIC   2 Edge      virtio0
plic pend 0x0 enable 0x6 claimed 0x0 thresh 0 eip 0 claims 17
RVLINUX: disk sector 1: guest-wrote-this
check-rv: M8 disk (riscv-h, virtio-mmio, QEMU TCG): pass
check-rv: M8 net (riscv-h, virtio-mmio, QEMU TCG): pass
.ft
.DE
.IP "Phase 15: M3 on RISC-V (QEMU riscv64 virt, TCG)." 4
More than one hart: hart 0 starts from Limbo, the rest by the SBI's
HSM \(en
.CW hart_start
recorded by the platform and taken up by the started vCPU's own kproc
through devvm's start hook (the one SIPI uses on x86), with a0 the hart
and a1 the opaque word; IPIs between harts are a flag each vCPU puts in
its own hvip before it enters.  The host port has one processor, so the
four vCPUs share it, all with VMID 0 and the same ASIDs in different
page tables: the backend flushes the guest's translations
.CW hfence.vvma ) (
whenever the processor switches from one vCPU to another.
.CW vmlinux
.CW -c
writes a node per hart.
.CW virtsmp
.CW rvsmpinit.b ) (
passed first time:
.DS
.ft CW
smp: Brought up 1 node, 4 CPUs
LINUXGUEST: smp 4 processors, online 0-3
LINUXGUEST: cpu0 0 0 37 251 0 0 1 0 0 0
LINUXGUEST: cpu1 1 0 15 264 0 0 0 0 0 0
LINUXGUEST: cpu2 1 0 17 249 0 0 0 0 0 0
LINUXGUEST: cpu3 0 0 13 289 0 0 0 0 0 0
LINUXGUEST: irq IPI0:         3         41         32         25  Rescheduling interrupts
LINUXGUEST: irq IPI1:       173        111         24         27  Function call interrupts
platform sbi calls 3441 ipis 450 time 116085610
.ft
.DE
with all eight workers done.  A later run ended early: a secondary
hart, idle with no timer armed and no external interrupt (the PLIC's
one context is hart 0's), waited in WFI, and the platform took that for
a hart nothing could wake and handed it up; an IPI can, so such a WFI
sleeps now.
.IP
And on x86, answering the cursor query broke M8's boot on the disk:
vmlinux typed the command when the shell marker came, before the
prompt, so busybox 1.35 ran it at once and the answer arrived in the
middle, where the guest's tty echoed it as
.CW ^[[1;1R
into the output.  The command is now typed after the answer, or three
seconds after the marker if the shell asks nothing.
.IP "Phase 15: M4 on RISC-V, the RISC-V IOMMU (QEMU riscv-iommu-pci, TCG)." 4
.CW virt/rviommu.c
is the portable IOMMU layer's second backend.  The device directory is
two levels deep, indexed by requester ID; every function behind the
IOMMU has a device context, valid with both stages bare while in the
host domain, and a domain is a second-stage table in Sv39x4 \(en the
format of a guest's own G stage
.CW vmrv.c ), (
tagged by its GSCID.  Commands (IODIR to drop a cached context,
IOTINVAL.GVMA a domain's translations, IOFENCE.C to wait) go through
the command queue and faults come back through the fault queue, both
polled.  The register layout and the rules for changing the directory's
mode (only by way of Off or Bare) are from QEMU's own source.  The
IOMMU is a PCI function, found at link time, so
.CW pciinit
now scans once, whoever calls it first.  The same edu test as VT-d's,
.CW rviommuinit.b ,
in
.CW virtiommu :
.DS
.ft CW
rviommu: PCI.0.1.0 translating, 64-byte device contexts
IOMMUTEST: domain /dev/iommu/0 devices 0000:00:02.0
IOMMUTEST: IOMMU-DMA-MAPPED-OK 256 bytes A -> edu -> B through IOVA 0x100000
0 00:02.0 write 0x3783000 reason 0x17 second-stage (guest) page fault
IOMMUTEST: IOMMU-DMA-BLOCKED-OK DMA to host pa 83783000 faulted and page B is untouched
.ft
.DE
(edu masks its DMA addresses to 28 bits, hence the fault's address.)
Found on the way: riscv64's
.CW jc
passes an int vararg after a vlong one wrongly \(en the fault lines
stopped at "reason" \(en so
.CW #Q
formats its numbers as 64 bits now; the compiler is not fixed yet.
.CW scripts/check-rv.sh
runs it as its last stage.
.IP "Phase 15: AIA on RISC-V (QEMU virt,aia=aplic-imsic, TCG)." 4
The host first: the riscv64 port drives AIA where the device tree has
it instead of a PLIC \(en the root APLIC domain in MSI mode, every
wired source a message to this hart's machine-level IMSIC with its
source number for identity, claimed through mtopei
.CW trap.c ). (
Then the guest: where the processor's IMSIC has guest interrupt files
(riscv,guest-index-bits), hart h of a machine runs with file h+1
(hstatus.VGEIN, vsiselect swapped with it), so the guest's IMSIC CSRs
\(en its claims, enables, threshold \(en are the hardware's.  The
platform emulates an APLIC in MSI mode for the guest's devices: a
source that becomes pending is written, as its identity, straight into
the target hart's guest file, and the hart woken.  The guest's IMSIC
pages are left unmapped, so an IPI one hart sends another comes to the
platform too, is put in the target's file the same way, and wakes it
\(en a write in hardware would not: the guest-external interrupt is
supervisor-level and this kernel runs in machine mode.
.CW vmlinux
describes an IMSIC and the APLIC when the status says there is a file
for every hart, and the harts' ISA gains ssaia.  Linux:
.DS
.ft CW
riscv-intc: 64 local interrupts mapped using AIA
riscv-imsic: imsics@28000000: providing IPIs using interrupt 1
riscv-aplic d000000.aplic: 31 interrupts forwarded to MSI base 0x0000000028000000
LINUXGUEST: irq  11:          5  APLIC-MSI-d000000.aplic   1 Level   -fasteoi   virtio1
LINUXGUEST: irq  12:          6  APLIC-MSI-d000000.aplic   2 Level   -fasteoi   virtio0
aia imsic 0x28000000 files 3 aplic 0xd000000 domaincfg 0x104 ie 0x6 ip 0x0 msis 17
.ft
.DE
and with four harts (seven guest files) all came online, the eight
workers finished, and every hart took rescheduling and function-call
IPIs, 977 messages through the platform.
.CW "CHECKRV_AIA=1 scripts/check-rv.sh"
runs every stage on the AIA machine.
.IP
On the AIA machine the host at first panicked in about one run in four
\(en a return into
.CW collect
through a saved return address with bits 49 and 50 set \(en with the
guest on AIA and with it on the PLIC alike, never in eight runs on the
PLIC machine.  The host's AIA path lost interrupts: in MSI mode an
APLIC makes a level source pending only when it rises, so a device
still asserting when its handler returned (more had come meanwhile)
was not sent again, and the virtio drivers ran on their 100 ms polls.
The host now sends such a source again after its handler, as Linux
does at EOI; eight runs since, none panicked.  What the polls
corrupted is not found: the drivers' rings give buffers back only once
used, and the receive length is the block's own.  Boot is slower with
AIA too (21 seconds of guest uptime to its shell with four harts,
against under one).  The RISC-V IOMMU and a host of more than one
hart came after (below).
.IP
The corruption was found later, and was not AIA's: the riscv64 port's
machine-mode trap entry lost R4 on every trap.  Its frame offsets are
all past a 12-bit immediate (the Ureg sits 2048 bytes up the stack),
so the assembler builds every address in its temporary, R4 (tp) \(en
whose first use, making the frame, overwrote the interrupted R4, and
whose slot in the Ureg then took the address being formed.  The
compiler uses R4 the same way, between an AUIPC and the load or store
it addresses, so an interrupt between the two sent that access
somewhere else.  It showed as a Dis interpreter fault in D89, its
register file's pointer
.CW curR ) (
read as zero while in memory it was right (gdb on QEMU's stub, a
breakpoint at
.CW panic );
a host that panicked in 5 runs of 6 with one build of
.CW trap.c
and in none with another of different length.  The entry now parks R4
in mscratch \(en free in the host, where mtvec is
.CW trapvec
and not the guest's
.CW rvexit
\(en until the frame is made, and puts it back through mscratch after
the frame's last use; 0 panics in 12.  The AIA host's earlier panics,
a return address with bits 49 and 50 set, fit the same fault; the
re-sent level sources are right regardless.
.IP "Phase 15: M5 on RISC-V (QEMU virt,aia=aplic-imsic, riscv-iommu-pci, TCG)." 4
.CW pc/vmpci.c
is
.CW port/vmpci.c
now: the bus is the same on both, reached through configuration
mechanism 1 on a PC
.CW vmpciio ) (
and through an ECAM window elsewhere
.CW vmpciecam ), (
with the guest's BAR window the platform's to give.  On RISC-V, with
AIA, the platform has the ECAM window at 0x30000000 and the BARs from
0x40000000, where QEMU's virt machine has its, and
.CW vmlinux
describes a
.CW pci-host-ecam-generic
bridge whose
.CW msi-parent
is the guest's IMSIC (no INTx: a PLIC guest gets no PCI bus).  An
assigned function's MSI-X entry, as the guest wrote it, gets a host
vector of its own: the host's MSI-X (new on riscv64,
.CW trap.c 's
.CW pcimsixintrenable )
gives each vector an identity of the machine-level IMSIC from 128 up,
and its handler writes the guest's identity into the target hart's
guest interrupt file
.CW vmplatmsi ). (
The device's DMA goes through an IOMMU domain over the guest's memory;
the riscv-iommu's device contexts have no MSI page table here, so the
device's message to the host IMSIC is a DMA write like any other, and
every domain maps the IMSIC's page at its own address
.CW rviommu.c ). (
The bench's virtio console function behind its riscv-iommu is assigned
to the Linux guest, whose own
.CW virtio_pci
and
.CW virtio_console
write through it to QEMU's chardev:
.DS
.ft CW
vm0: PCI.0.2.0 assigned as 00:01.0
LINUXGUEST: pci 0000:00:00.0 0x8086 0x29c0
LINUXGUEST: pci 0000:00:01.0 0x1af4 0x1043
LINUXGUEST: wrote hvc0
LINUXGUEST: irq  11:          0  PCI-MSIX-0000:00:01.0   0 Edge      virtio2-config
LINUXGUEST: irq  12:          5  PCI-MSIX-0000:00:01.0   1 Edge      virtio2-virtqueues
pci ecam 0x30000000 0x100000 mem 0x40000000 0x40000000 msis 5 lost 0
pci 00:01.0 is PCI.0.2.0 domain 0 bar1 0x40004000->0x40000000 bar4 0x40000000->0x40004000 msix on 2/2 hosted
.ft
.DE
and the chardev holds "hello-from-the-guest".  Found on the way, in the
bus itself: Linux swapped the function's two BARs, and moving BAR 1
off the page BAR 4 had just moved onto unmapped BAR 4's first page; a
move now maps every BAR on the bus again after taking the old pages.
The x86 guests had never moved a BAR.
.CW "CHECKRV_AIA=1 scripts/check-rv.sh"
runs it as stage M5.
.IP "Phase 15: a riscv64 host of four harts (QEMU virt -smp 4, TCG)." 4
The riscv64 port ran one hart: every hart QEMU starts runs
.CW _main ,
and only hart 0 got anywhere sensible.  Now
.CW m
and
.CW up
are extern registers, R7 and R6 (jc gives the first two extern
registers those, and compiled code allocates only R8 to R15, so no
library touches them); harts other than 0 wait in
.CW l.s ,
asleep in WFI with only the machine software interrupt enabled, until
.CW startharts
gives each a Mach and a stack and rings its CLINT MSIP; each runs its
own clock on its own comparator and schedules, while the soft timers,
the alarms and the console's UART stay hart 0's.  A trap does not
reload R7 on its way out \(en a process preempted inside
.CW trap()
may come back on another hart \(en and the guest's world switch keeps
the host's R6 and R7 across the guest's run.
.IP
What it took, besides:
.CW splhi
stored
.CW m->splpc
with a 64-bit store into a 32-bit
.CW ulong ,
whose other half was
.CW machno \(en
hart 0's is 0, so it never showed, and every other hart's first
.CW splhi
made it hart 0.  A vCPU's kick (an IPI, a device's line, console
input, hart_start) now pokes the processor it runs on
.CW hartpoke ): (
in the guest there it exits at once rather than at that processor's
next tick, and asleep in WFI it wakes.  SBI's remote fences fenced only
the calling hart, which on one hart was every vCPU's; now each target
fences on its own processor before its next entry, and one in the
guest is poked out and waited for.  With AIA a vCPU's guest interrupt
file is on the processor that runs it
.CW gfilepage ). (
Dis's context pointer
.CW curP
is a global on this port, not a register (DISCTXREG, which amd64
has): there is one executor, the VM lock's holder, and
.CW sched()
set
.CW curP
for every process it switched to \(en on another hart, taking the
context from under the holder; now it is set when the VM is acquired
and when its holder is resumed, and left alone otherwise.  And stale
wakeups: the guest's console store on one hart moved the output index
and woke the reader after, by when the reader, on another, had taken
that output and slept again; woken with nothing, its read returned 0,
which
.CW vmlinux
took for the end of the console and stopped copying it.  The console
read and
.CW devvm 's
exit and command waits loop on their conditions now.
.IP
The four-hart guest on the four-hart host, a vCPU on each:
.DS
.ft CW
4 harts
[    0.128215] smp: Brought up 1 node, 4 CPUs
LINUXGUEST: up 6.12.111-0-lts cpus 4 uptime 1.26
LINUXGUEST: smp 4 processors, online 0-3
LINUXGUEST: worker 1 done
\&...
LINUXGUEST: worker 8 done
LINUXGUEST: cpu0 1 0 15 155 0 0 1 0 0 0
LINUXGUEST: cpu1 1 0 14 160 0 0 0 0 0 0
LINUXGUEST: cpu2 0 0 11 159 0 0 0 0 0 0
LINUXGUEST: cpu3 0 0 6 181 0 0 0 0 0 0
LINUXGUEST: irq IPI0:        46         82         57         30  Rescheduling interrupts
LINUXGUEST: irq IPI1:        94        151         69        130  Function call interrupts
.ft
.DE
(1.26 and 1.71 seconds of guest uptime to its shell in two runs,
against 0.92 on one hart; why it is not faster is not looked into.)
On the AIA machine too, each vCPU's interrupt file on its own hart's
IMSIC and the IPIs all through them (none through the SBI):
.DS
.ft CW
[    0.243315] smp: Brought up 1 node, 4 CPUs
LINUXGUEST: smp 4 processors, online 0-3
LINUXGUEST: irq IPI0:        52         36         33         60  Rescheduling interrupts
LINUXGUEST: irq IPI1:       259        371        295        366  Function call interrupts
platform sbi calls 5324 ipis 0 time 75040880
.ft
.DE
.CW scripts/check-rv.sh
runs M3 on a host of one hart and on a host of four, and every stage
passes on both machines.  The console read on the PC platform had the
same stale wakeup and loops the same way; check-vm passes every stage
on SVM with these changes.
.IP "Phase 9: M8's network half on VMX (Bochs)." 4
The Bochs bench had one NIC and no second for a guest's virtio-net to
bridge to.
.CW scripts/bochs-vm.sh
now takes
.CW BOCHS_NICS=n :
n of Bochs's e1000s (82540EM, which
.CW etherigbe
drives), each on a slirp network of its own, so that
.CW #l1/ether1
is there as on the QEMU bench.
.CW vmhost.sh 's
.CW VMHOST_NIC1
puts QEMU's e1000 in the igb's place the same way.
.IP
The first run with two NICs did not reach
.CW vmlinux
in 45 minutes.  Stopped in Bochs's debugger, every sample of RIP was in
.CW checktracked() ,
which
.CW xec()
called after every Dis instruction to scan a table of 1024 watched
words: the crash hunt's instruments in
.CW libinterp ,
taken out in
.CW 9681d0087
and put back with the multicore Dis VM
.CW 39e1da263 ), (
whose
.CW libinterp
predated their removal.  They are out again \(en the tracker and its
registration in
.CW initmem() ,
the per-Prog
.CW wmtrace
ring, the
.CW movp
and
.CW destroy
probes,
.CW scanframe()
on every frame teardown, and
.CW gc.c 's
per-cell checks \(en with what the multicore VM added kept:
.CW framerefs ,
the collector handover in
.CW destroy() ,
whose underflow report is now a panic.  The same run then took 37
minutes from power-on to the end, on the VMX backend, one processor,
1 GiB, two e1000s:
.DS
.ft CW
#l0: i82543: 1000Mbps port 0xC0000000 irq 9 ea 525400123450
#l1: i82543: 1000Mbps port 0xC0020000 irq 11 ea 525400123451
vmlinux: virtio net on #l1/ether1
vm 0 backend vmx mem 268435456 vcpus 1
LINUXGUEST: vda says INFERNO-VIRTIO-DISK
LINUXGUEST: made a root on vdb
LINUXGUEST: dhcp udhcpc: lease of 10.0.2.15 obtained from 10.0.2.2, lease time 86400
LINUXGUEST: eth0 rx 2 packets 0 length errors tx 3
LINUXTEST: disk sector 1: guest-wrote-this
LINUXTEST: booting on the virtio disk
LINUXGUEST: root /dev/vda ext2
LINUXGUEST: on disk
LINUXTEST: done
.ft
.DE
M8 is met on VMX, network half included.  M5 is not exercised on
VMX: Bochs has no IOMMU to assign a function through.
On QEMU, with every kernel rebuilt without the instruments, check-vm
(SVM; M4 under VT-d and AMD-Vi, interrupt remapping on) and check-rv
(M1 to M4, M3 on hosts of one and four harts) pass every stage.
.IP "Phase 16: VMX in QEMU's TCG (QEMU q35, TCG, VMX backend)." 4
QEMU's TCG emulated SVM and not VMX.
.CW scripts/qemu-patches/0006-i386-tcg-vmx.patch
gives it VMX
.CW target/i386/tcg/system/vmx_helper.c ): (
VMXON, VMXOFF and the VMCS instructions, with the VMfail errors the SDM
lists; VM entry with the checks a processor makes of the controls, the
host state and the guest state, a failed entry exiting with reason 33
or 34; VM exits that save the guest and load the host, the MSR lists
both ways, IDT-vectoring information for an exit in the middle of an
event's delivery, and event injection; the execution controls at SVM's
intercept points, plus the control-register guest/host masks, the I/O
and MSR bitmaps, interrupt-window, external-interrupt and NMI exiting
and acknowledge-on-exit; EPT as a second stage-2 format beside NPT,
with violation and misconfiguration exits; VPID; unrestricted guest; an
INIT held in root operation and taken as an exit in non-root.  The
capability MSRs advertise only that: no APIC virtualization, posted
interrupts, virtual NMIs, preemption timer, MTF, PML, VMCS shadowing
or VM functions.
.CW VMHOST_CPU=vmx
selects an Intel processor with VMX and no SVM; the bench's default
stays SVM.
.IP
It was checked against clients that are not this kernel before
.CW vmx.c
ran on it
.CW scripts/check-qemu-vmx.sh ): (
kvm-unit-tests' VMX tests (at a pinned commit), and Linux's own
.CW kvm_intel ,
loaded in the bench's guest kernel on the patched QEMU, running a
real-mode guest through
.CW /dev/kvm
.CW tests/vm/kvmtest.c ). (
What they found wrong was mostly TCG's processor, not its VMX, and it
is fixed in the same patch: MOV to CR0 took bits 63:32 without #GP;
MWAIT with no MONITOR armed halted forever; IA32_TSC read 0; a
non-canonical stack address raised #GP, not #SS; a page walk under
nested paging reported its reads as writes; a PAE walk set the accessed
flag in a PDPTE, where bit 5 is reserved; there were no PDPTE
registers; a #DB that exits wrote DR6; loading CS or SS did not set the
descriptor's accessed flag, nor LTR the TSS's busy flag, in the cache
or the table; STI and MOV SS shared one interrupt shadow.  The last two
were Linux's to find: the second guest's VM entry failed on a CS of
type 10, and the first's on a TR of type 9.
.DS
.ft CW
check-qemu-vmx: kvm-unit-tests vmx: pass
	SUMMARY: 6930 tests, 2 unexpected failures, 21 skipped
	XPASS: Expected pending debug exceptions 0 (actual 0)
	XPASS: Expected exit qualification 4001 (actual 4001)
check-qemu-vmx: kvm-unit-tests ept: pass
	SUMMARY: 9998 tests, 6 skipped
check-qemu-vmx: kvm-unit-tests init_signal: pass
check-qemu-vmx: kvm-unit-tests apic_passthrough_thread: pass
check-qemu-vmx: kvm_intel: pass
	KVMTEST: guest said "Hi", sum 20440 (want 20440), 1000 port exits, halted
.ft
.DE
The two unexpected results are XPASSes: checks kvm-unit-tests marks as
failing under KVM's emulation of a MOV SS shadow, which this processor
passes.  The skips are the features not advertised.  Left out, as
TCG's and not VMX's: the #AC case (TCG has no alignment checking) and
the TSC-delta test (TCG's TSC is the host clock, here at a
microsecond).  Not modelled: debug exceptions pending in a MOV SS
shadow with RFLAGS.TF clear wait for the next #DB rather than the next
instruction; VMX state is not in QEMU's migration stream.
.IP
Then check-vm with
.CW CHECKVM_BACKEND=vmx ,
every stage on the VMX backend, QEMU TCG, q35 with VT-d and interrupt
remapping, four processors:
.DS
.ft CW
vm: vmx
VMTEST: backend vmx rev 0x12 ept unrestricted ept-wb 1 pin 0x1f proc 0xb58065f2
	proc2 0x82 exit 0x3f6fff entry 0xd1ff cr0fixed 0x80000021/0xffffffff
	cr4fixed 0x2000/0x1773fff
check-vm: M1 (vmx): pass
check-vm: nil dereference (vmx host): pass
check-vm: M2 (vmx): pass
	platform handled cpuid 672 msr 25 io 150485 mmio 2386 hlt 51 intr 5298 gp 3 msi 983
check-vm: M5 (vmx): pass
check-vm: M8 disk (vmx): pass
check-vm: M8 net (vmx): pass
	LINUXGUEST: dhcp udhcpc: lease of 10.0.2.15 obtained from 10.0.2.2, lease time 86400
check-vm: M8 boot on the virtio disk (vmx): pass
check-vm: M4 (vt-d): pass
check-vm: M4 (amd-vi): pass
check-vm: M3 (vmx): pass
	LINUXGUEST: smp 4 processors, online 0-3
	LINUXGUEST: irq CAL:        364        339        272        355   Function call interrupts
.ft
.DE
So M1\-M5 and M8 hold on VMX on one bench, M5 now included: a function
assigned behind VT-d with interrupt remapping, which Bochs could not
have.  check-vm on VMX ran on the patched source built in place;
.CW scripts/mkqemu.sh 's
build of the release and the six patches then passed the conformance
checks above and check-vm on SVM, every stage, unchanged.
.IP
On that build, with
.CW VMHOST_CPU=vmx ,
the rest of the milestones on the VMX backend:
.DS
.ft CW
vm 0 backend vmx mem 268435456 vcpus 1
vm 1 backend vmx mem 268435456 vcpus 1
check-vf: M7 pass -- two Linux guests on two VFs of the 82576 ping each other at once, the PF being Inferno's
check-styxvm: M9 pass -- a Linux guest made, assigned a device, run and talked to from hosted Inferno over Styx
emu: vmsched: host /n/h0 now: backend vmx cpus 2 memfree 1642506888 ...
check-cloud: M10 pass -- three guests placed across two hosts by Limbo, each answering from its host
check-nsvm: pass -- a machine built from a namespace: its disk a file on the Mac over Styx, ...
.ft
.DE
Every milestone short of M11 now holds on VMX as on SVM, on one bench.
.IP
The 82599 model (phase 16):
.CW scripts/qemu-patches/0007
adds
.CW "-device ixgbe" ,
an X520-DA1's 82599 (8086:10fb) and its 63 SR-IOV VFs (8086:10ed), in
.CW hw/net/ixgbe.c .
What a driver for the part depends on is modelled, its quirks
included: the EEPROM with its checksum over the pointed-to sections,
the SFP+ init list programmed into CORECTL and the firmware block
whose patch version the driver wants before it calls the part
production; a passive direct-attach cable's SFF-8472 bytes read over
I2C bit-banged through I2CCTL; the SDP pins (SDP2 says a module is in
the cage, and the link checks it; SDP3 turns the transmitter off, and
the link goes down with it); SWSM/GSSR semaphores; MDIO with no PHY;
AUTOC and ANLP1; LINKS at 10Gb/s; FWSM's valid bit; the packet
buffers' reset sizes.  128 queue pairs, advanced and legacy
descriptors, TSO, checksum and VLAN offloads, receive checksum
validation; EICR with EIAC/EIAM and the extended registers, IVAR, in
legacy, MSI and MSI-X mode.  Pools of 2, 4 or 8 queues, MAC
(RAR/MPSAR), multicast, VLAN (VLVF) and VMOLR filtering, VFRE/VFTE,
anti-spoofing, VMVIR, the internal switch; the PF/VF mailbox with its
ownership bits, VF reset and FLR (VFLRE), RSTI/RSTD.
.CW scripts/check-qemu-ixgbe.sh
checks it against Linux's own drivers (linux-lts 6.6.142's ixgbe and
ixgbevf), QEMU TCG, q35, the 82599 behind a root port:
.DS
.ft CW
ixgbe 0000:01:00.0: MAC: 2, PHY: 14, SFP+: 3, PBA No: E7B560-005
ixgbe 0000:01:00.0 eth0: NIC Link is Up 10 Gbps, Flow Control: RX/TX
check-qemu-ixgbe: pf: pass
check-qemu-ixgbe: vf: pass
check-qemu-ixgbe: switch: pass
	pf link up speed 10000
	dhcp udhcpc: lease of 10.0.2.15 obtained from 10.0.2.2, lease time 86400
	pf ping 3 packets transmitted, 3 packets received, 0% packet loss
	vf 0000:01:10.0 eth1 a6:d8:1b:cf:4e:51
	vf 0000:01:10.2 eth2 b2:a8:c3:37:3f:88
	switch ping 3 packets transmitted, 3 packets received, 0% packet loss
	switch ping back 3 packets transmitted, 3 packets received, 0% packet loss
	switch tcp vf to vf 2097152 bytes md5 75baa7b9fdb90d0103c99f329797328f
	switch tcp pf to vf 2097152 bytes md5 75baa7b9fdb90d0103c99f329797328f
	irq 28:          0        185  PCI-MSIX-0000:01:10.0   0-edge      eth1-TxRx-0
	irq 31:        217          0  PCI-MSIX-0000:01:10.2   0-edge      eth2-TxRx-0
.ft
.DE
The VFs are made through
.CW sriov_numvfs ,
ixgbevf binds each over the mailbox, and with one VF in a network
namespace of its own the two ping and move 2MB over TCP through the
82599's switch, as does the PF to a VF.  Not modelled: flow-director
filtering (its commands complete), RSC, DCB, IPsec, timestamps, the
flash; statistics beyond the counters drivers read on each pass; the
model is not migratable.
.IP
This kernel on the 82599.
.CW pc/ether82598.c
claimed the part but programmed it as an 82598: the interrupt vector
table (IVAR) in the 82598's layout, which left the 82599's transmit
interrupt unmapped, receive checksums taken from the wrong status bit
and never checked against the error bits, the transmit queue enabled
before transmit DMA (the 82599 wants it the other way round), and
1Gb/s read as 10.  Those are fixed, and with
.CW *ixgbevfs=n
in plan9.ini it is an SR-IOV PF, after the 82576's in
.CW ether82563.c :
64 pools of two queue pairs, the VFs in pools 0 to n\-1, the PF in
pool n on queue 2n, frames sorted to pools by address (RAR, MPSAR),
broadcasts to all, the switch looping between them; one MSI-X vector
for the PF's queue, the link and the mailbox; ixgbevf's messages
answered (reset with its address, the API negotiated to 1.1, its
queues, multicast, frame size).
.CW scripts/check-vf.sh
with
.CW CHECKVF_NIC=ixgbe
is M7 on the X520's VFs, on both backends (QEMU TCG, the 82599 of
patch 0007):
.DS
.ft CW
VFTEST: VFs 0000:02:10.0 0000:02:10.2
ixgbevf 0000:00:01.0: 52:54:00:82:00:10
ixgbevf 0000:00:01.0: Intel(R) 82599 Virtual Function
ixgbevf 0000:00:01.0: NIC Link is Up 10 Gbps
LINUXGUEST: ping 3 packets transmitted, 3 packets received, 0% packet loss
LINUXGUEST: ping 3 packets transmitted, 3 packets received, 0% packet loss
VFTEST: pf sriov: vfs 2 pf pool 2 queue 4 mbox 42 vfresets 2 vflr 0 msix 96 vfre 00000007 vfte 00000007
VFTEST: pf vf0: 525400820010 api 2 vmolr 0b000000
check-vf: M7 pass -- two Linux guests on two VFs of the 82599 ping each other at once, the PF being Inferno's
.ft
.DE
That is the SVM run; with
.CW VMHOST_CPU=vmx
the same passes on VMX (vm 0 and vm 1, backend vmx; mbox 42, msix
90).  With
.CW CHECKVF_NIC=ixgbe-pf
the whole 82599 goes to one guest, whose ixgbe drives the PF through
the assignment \(en EEPROM, SFP+ over I2C, MSI-X \(en and gets a
lease, on SVM and on VMX:
.DS
.ft CW
ixgbe 0000:00:01.0: MAC: 2, PHY: 14, SFP+: 3, PBA No: E7B560-005
ixgbe 0000:00:01.0 eth0: NIC Link is Up 10 Gbps, Flow Control: RX/TX
LINUXGUEST: dhcp udhcpc: lease of 10.0.2.15 obtained from 10.0.2.2, lease time 86400
LINUXGUEST: ping 3 packets transmitted, 3 packets received, 0% packet loss
LINUXGUEST: irq 16:         22  PCI-MSIX-0000:00:01.0   0-edge      eth0-TxRx-0
check-vf: pass -- the whole 82599 assigned to a Linux guest, whose ixgbe gets a lease and pings through it
.ft
.DE
And M9 with the 82599 as the host's own interface
.CW VMHOST_NIC1=ixgbe "" ( "INFERNO_INI='ether0=type=i82598'" ),
which takes the driver's path without VFs: DHCP and the Styx export
over it (SVM):
.DS
.ft CW
#l0: i82598: link up: 10000Mbps
VMSERVE: /net/ether0 10.0.2.15
check-styxvm: M9 pass -- a Linux guest made, assigned a device, run and talked to from hosted Inferno over Styx
.ft
.DE
check-vf on the 82576 passes unchanged.  On
.CW scripts/mkqemu.sh 's
build of the release and the seven patches, check-qemu-ixgbe and
check-vf on the X520's VFs pass again.
.IP
Newer NVMe (phase 16).  What drives newer than QEMU's model have that
it did not, added by
.CW scripts/qemu-patches/0008 :
the host memory buffer a DRAM-less drive asks for (Identify's HMPRE,
HMMIN, HMMINDS, HMMAXD; Set and Get Features 0Dh with its descriptor
list and Memory Return), the controller writing a header into each
chunk it is lent and reading it back when the buffer is returned, so
that a host writing over lent memory is caught as a real drive's
corrupted tables would be; and five power states, two of them
non-operational, with autonomous transitions (APSTA, Features 0Ch):
idle for an entry's ITPT the controller goes to its ITPS, and the
next command brings it back (Get Features 02h reports the state the
command found it in).  4096-byte sectors and several namespaces QEMU
had already.
.CW scripts/check-qemu-nvme.sh
checks it against Linux's nvme (linux-lts 6.6.142), QEMU TCG, one
controller with a 4K-sector namespace and a 512-byte one, through a
freestanding admin client,
.CW tests/vm/nvmetest.c :
.DS
.ft CW
nvme nvme0: allocated 32 MiB host memory buffer.
check-qemu-nvme: hmb: pass
check-qemu-nvme: apst: pass
check-qemu-nvme: ns: pass
	ns nvme0n1 lbs 4096 sectors 131072 1MiB written and read back md5 2d3ee6b8...
	ns nvme0n2 lbs 512 sectors 131072 1MiB written and read back md5 c14e6691...
	identify hmpre 8192 hmmin 2048 hmminds 1 hmmaxd 32 npss 4 apsta 1
	hmb enabled 1 hsize 8192 pages descriptors 8
	apst ps0 -> ps3 after 100 ms
	apst ps3 -> ps4 after 2000 ms
	idle 3s found in ps4
	after a read found in ps0
	after reset hmb enabled 1 hsize 8192 pages descriptors 8
.ft
.DE
Linux gives the buffer back after a controller reset with the
contents untouched (no complaint in QEMU's log).  Then this kernel:
.CW port/sdnvme.c
now lends a drive that asks up to 32 MiB of host memory in 1 MiB
chunks, never less than its minimum, and frees it only after
disabling the controller has taken it back.  On the bench with
.CW VMHOST_NVME=new
(the NVMe asking for a buffer, with APST, its image a namespace of
4096-byte sectors and a second of 512),
.CW ipc64dev :
.DS
.ft CW
sdN (nvme): host memory buffer 32 MiB in 32 chunks
DEVTEST: /dev/sdN0/ctl: ... geometry 16384 4096  hmb 32 MiB in 32 chunks
DEVTEST: /dev/sdN1/ctl: ... geometry 32768 512
DEVTEST: /dev/sdN0/data sector 0 (512 bytes): INFERNO-NVME-NS1-4K
DEVTEST: MSIX-DETACH-OK sdN gone after switch off
.ft
.DE
QEMU's guest-error log found a fault of sdnvme's own there: it wrote
INTMS and INTMC, the pin and MSI interrupt masks, while on MSI-X,
which the specification leaves undefined (a real controller may do
anything).  It masked and unmasked them on every interrupt.  It now
writes them only when the controller is not on MSI-X; the rerun has
no guest errors, and check-vm's M4 still passes under VT-d and AMD-Vi.
On
.CW scripts/mkqemu.sh 's
build of the release and the eight patches, check-qemu-nvme passes
again (hmb, apst, ns).
.IP
The FL1100 (phase 16).  A first model carried two behaviours recalled
from memory of Linux's quirk table, MSI that never arrives and short
transfers completed as Success; Linux 6.6's xhci-pci, given 1b73:1100,
contradicted the first (it drives the part on MSI-X, and with the
messages lost no USB device appeared), and that model was taken out.
Read instead: Fresco Logic's FL1100 datasheet (revision 1.10, August
2012) for the part's registers, and two Linux commits for its
behaviour \(en "xhci: Enable trust tx length quirk for Fresco FL11 USB
controller" (5.15: a short transfer completes as Success with the
residual, found streaming video) and "xhci: Fresco FL1100 controller
should not have BROKEN_MSI quirk set" (5.16: the broken MSI was the
older Fresco parts', given to the FL1100 by mistake).  Linux 6.9 then
made trusting the length its default, which is why 6.6.142 (with that
backported) shows no FL1100 quirk at all.
.CW scripts/qemu-patches/0009
adds
.CW "-device fl1100-xhci" :
revision 00h; power management at 40h, MSI at 50h (eight vectors,
64-bit, no masking), PCI Express at 70h, MSI-X at B0h with its table
in BAR 2 and pending bits in BAR 4; HCSPARAMS1 08000820h (eight
ports, four USB 2 and four USB 3, eight interrupters, 32 slots),
HCSPARAMS2 84000054h (16 scratchpad buffers, ERST Max 5), HCSPARAMS3
00040001h, HCCPARAMS with NSS; runtime registers at 2000h, doorbells
at 3000h; short bulk, interrupt and isochronous transfers completed as
Success (not control transfers, of which Linux would warn at every
enumeration).  QEMU's extended capabilities pointer is kept and light
HC reset not claimed, QEMU's xHCI not doing it.  Two things QEMU's
xHCI lacked came out of it.  It had event rings of one segment only,
and Linux, told of ERST Max 5, makes more, so the controller died
(HCE) at the first command; event rings of up to 32 segments are now
done (xHCI 1.0, 4.9.4).  And scratchpad buffers: a part that asks for
them now uses them, a header in each page written at Run and checked
at Stop, so a driver that gives none or writes over them is caught.
.CW scripts/check-qemu-fl1100.sh ,
Linux's xhci (linux-lts 6.6.142), QEMU TCG, a USB stick on the
FL1100:
.DS
.ft CW
check-qemu-fl1100: pci: pass
check-qemu-fl1100: irq: pass
check-qemu-fl1100: disk: pass
	pci 0000:01:00.0 0x1b73 0x1100 rev 0x00
	pci bar 2 0x00000000fe804000-0x00000000fe804fff
	pci bar 4 0x00000000fe805000-0x00000000fe805fff
	disk 4MiB written and read back md5 30374fa906c35d9f5127f6d3056f07e2
	irq after 25:          0        174  PCI-MSIX-0000:01:00.0   0-edge      xhci_hcd
	xhci_hcd 0000:01:00.0: hcc params 0x00087081 hci version 0x100 quirks 0x0000000000000010
.ft
.DE
QEMU's own qemu-xhci passes the same disk and interrupt checks after
the change.  Then this kernel's usbxhci, unchanged, on the bench with
.CW VMHOST_USB=fl1100
(the FL1100 behind a sixth root port, a stick and a keyboard on it),
.CW ipc64dev ,
on the pin interrupt, with no complaint from the controller about its
scratchpad pages:
.DS
.ft CW
usbxhci: 0x1b73 0x1100: port 81000000 size 16384 irq 11
usbd: ep2.0: port 1: super ep3.0 vid 46f4 did 0001 class 0
usbd: ep3.0: disk "QEMU    QEMU HARDDISK   2.5+" 32768 blocks x 512 bytes
usbd: ep3.0: block 0 read, no boot signature
usbd: ep1.0: port 2: high ep4.0 vid 0627 did 0001 class 0
usbd: ep4.0: boot keyboard on ep4.1
.ft
.DE
On
.CW scripts/mkqemu.sh 's
build of the release and the nine patches, check-qemu-fl1100 passes
again (pci, irq, disk).
.IP "Next." 4
The M7 guest is
.CW linux-lts ,
since Alpine's
.CW linux-virt
does not build igbvf (an earlier note here said it was a module, which
was wrong); M8's is
.CW linux-virt ,
whose
.CW virtio_blk
and
.CW virtio_net
are modules.  M8 is done on SVM, including Linux booting on the virtio
disk: the first guest makes an ext2 root (busybox's mke2fs, a copy of
its /bin, /lib and /init) on its second disk, and a second guest given
that disk alone and linuxguest.root=vda mounts it from the initramfs
and switches to it.  M3 is done on VMX too (Bochs, two processors), and M8 with its network half (Bochs, two e1000s).
Since: the RISC-V IOMMU (M4) and a device assigned through it (M5) on
RISC-V; a riscv64 host of four harts; M3 under MTTCG (a QEMU race,
fixed); AMD-Vi, VT-d queued invalidation and interrupt remapping; Limbo
nil dereferences as exceptions on pc64 and riscv64; VMX in QEMU's TCG
(phase 16), on which check-vm passes every stage on the VMX backend.
M1\-M10 all hold on VMX there.  The 82599 model is done, checked
against Linux's ixgbe and ixgbevf, and this kernel is its PF: M7 on
the X520's VFs and the whole PF to a Linux guest, on SVM and VMX.
The newer NVMe features are done, checked against Linux's nvme, and
sdnvme uses them.  The FL1100 is modelled from its datasheet and Linux's
history with it, and usbxhci runs on it.  The codesign debts of
APST, the FL1100's MSI-X, #AC and the 82599's checksums are paid.
Next: TSO and RSS for ether82598; the misbehaving
DMA device (its design to come) with phase 17's device release; the
ConnectX-4 Lx; then the rest of phase 17 and the
workstation (phase 13), and real hardware for everything QEMU and Bochs
have stood in for.  On QEMU, check-vm (SVM; M4 under VT-d and AMD-Vi)
and check-rv, on both the PLIC and the AIA machine and on hosts of one
and four harts, pass every stage.
