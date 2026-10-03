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
dhcpclient bug into a panic.
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
domain.  Not yet: interrupt remapping, queued invalidation, AMD-Vi.
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
and switches to it.  Next: M2, M8 and M3 on VMX (Bochs), now that the
host keeps time; the MTTCG triple fault; and the workstation (phase 13).
