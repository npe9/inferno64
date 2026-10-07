.TL
Inferno as a Hypervisor
.AB
The native Inferno kernel can now run other operating systems as
guests.  It owns the processor's virtualization extension (Intel VMX,
AMD SVM, or the RISC-V hypervisor extension), the IOMMU and the PCI
Express fabric, and it serves everything about a virtual machine as
files: a machine is made by opening a file, given memory, processors,
devices, disks and networks by writing commands, run, inspected and
destroyed through more files.  Because they are files, the same
operations work over Styx from another machine, and a machine can be
assembled from a namespace of resources gathered from several hosts.
Linux boots unmodified on four processors under both x86 backends and
under the RISC-V one, with whole PCI functions and SR-IOV virtual
functions assigned to it behind VT-d, AMD-Vi or the RISC-V IOMMU, and
with the hypervisor's own virtio disks and networks.  This paper
describes the design, the division of work between the kernel and
Limbo, the emulators that had to be corrected or extended to test it,
and the faults that testing found in the kernel, the emulators and the
hypervisor itself.
.AE
.NH 1
Introduction
.PP
The work began as a plan for Plan 9 as a hypervisor with Inferno as its
control plane.  Here both roles are Inferno's: the native kernel
.CW os/inferno/pc64 ) (
is the hypervisor, and Limbo programs \(em on the same kernel, or on
other machines over Styx \(em are the control plane.  Nothing about a
machine is reached through a system call of its own or an
.CW ioctl :
the machine is a directory.
.PP
Three devices carry it:
.TS
center;
l l l.
#H	\f(CW/dev/vm\fP	virtual machines (VMX, SVM, RISC-V H)
#Q	\f(CW/dev/iommu\fP	DMA remapping (VT-d, AMD-Vi, RISC-V IOMMU)
#$	\f(CW/dev/pci\fP	PCI Express functions, MSI-X, SR-IOV
.TE
.LP
and two Limbo commands use them:
.I vmlinux (1)
loads and runs a Linux kernel, and
.I vmsched (1)
places machines on hosts.
.PP
Every result below names the backend it was obtained on (VMX, SVM or
RISC-V H) and the bench (QEMU's TCG, Bochs, or hardware), because the
two x86 backends are different code and an emulator is not a
processor.  So far every result is from an emulator; the target
machine, a dual-Xeon workstation with an Intel X520, has none yet.
.NH 1
A machine is a directory
.PP
Opening
.CW /dev/vm/clone
makes a machine; the open file becomes its
.CW ctl ,
and reading it gives the machine's number
.I n .
Commands written to
.CW ctl
give it memory
.CW "mem 268435456" ), (
processors
.CW "vcpus 4" ), (
a PCI function
.CW "assign 0000:05:00.0" ), (
a virtio disk served from a file in the writer's namespace
.CW "virtio blk /tmp/root.img" ), (
a virtio network interface on an
.I ether (3)
device
.CW "virtio net #l1/ether1" ), (
and finally
.CW kill .
.CW /dev/vm/\fIn\fP/mem
is guest-physical memory at file offset equal to address, so loading a
kernel is a
.CW pwrite .
Each vCPU has a directory: its
.CW ctl
takes
.CW go ,
.CW skip
and
.CW stop ;
.CW regs
reads and writes the registers as text; and
.CW exit
blocks until the vCPU stops and says why.
.CW status
reports the machine's exits by kind and what the kernel handled, and
.CW /dev/vm/host
what the host has left for machines, which is what a scheduler needs.
.PP
.I Vmlinux
uses nothing else.  It reads a bzImage, writes it and its initrd into
the machine's memory (streamed, not held), builds the
.CW boot_params
with an e820 map, writes ACPI tables (an RSDP, RSDT and a MADT with a
local APIC per vCPU, the I/O APIC and IRQ 0's override) when the
machine has more than one processor, sets the registers for the
32-bit boot protocol and writes
.CW go .
It then copies the guest's console to its standard output and its
standard input to the console.  Because it uses only files,
.CW /dev/vm
may be another machine's, mounted.
.NH 1
What the kernel does and what Limbo does
.PP
9front's
.CW devvmx
does only the processor's half of virtualization and hands every exit
to a C program in user space.  Native Inferno has no C user space, and
a round trip through Dis for every timer tick would be too slow.  So
the split is different: everything on the exit path that a guest
expects to be fast is in the kernel, on the vCPU's own processor, and
everything that is policy is in Limbo.
.PP
In the kernel: nested page faults on mapped memory, CPUID, the MSRs,
HLT, the local APIC and its timer (one-shot, periodic and TSC
deadline, xAPIC and x2APIC), the I/O APIC, the 8259 pair, the 8254,
the 16550, the guest's PCI configuration cycles, forwarding of
assigned functions' MSI-X, the virtio queues, and a paravirtual clock.
In Limbo: making a machine, laying out its memory, loading its kernel,
choosing its devices, connecting a disk to a file and a network to an
interface, starting and stopping it, and placing machines on hosts.
.PP
An exit the kernel does not handle is neither dropped nor faked.  The
vCPU stops and the exit is delivered on
.CW exit ,
where a Limbo program may emulate it and resume the vCPU, or report
it.  That is the slow path, and it is also how a missing piece of
emulation shows itself: the first boots of Linux were a sequence of
such exits, each turned into kernel code once understood.
.NH 2
The backends
.PP
The portable layer
.CW port/devvm.c ) (
holds machines, vCPUs, guest memory and the device models, and
reaches the processor through a table,
.CW Vmops :
probe, per-processor init (VMXON, or EFER.SVME), make and free a vCPU
(a VMCS or VMCB), run it and return a decoded exit, get and set
registers, inject an event, and make, extend and flush the nested page
tables.  Exits are decoded into a portable form (I/O, MMIO with its
guest-physical address, CPUID, MSR, HLT, interrupt window, external
interrupt, triple fault, shutdown) so no device model sees a VMX or
SVM exit code.  EPT and NPT are both four-level x86 tables with
different leaf bits; the walk is shared.
.PP
.CW pc64/vmx.c
began as 9front's
.CW devvmx.c ,
cut down to the backend.
.CW pc64/svm.c
was written to the same table; it enters the guest with
.CW "CLGI; STI; VMRUN; CLI; STGI"
and V_INTR_MASKING, so a guest spinning with interrupts off still
leaves for the host's.
.CW virt/vmrv.c
is the RISC-V backend.  Inferno's riscv64 kernel runs in M-mode, so it
enters a guest by
.CW MRET
with MPV set and MPP at S, that is in VS-mode, with G-stage
translation through
.CW hgatp
(Sv39x4, 2 MiB pages); everything not delegated to the guest returns
through one trap entry.
.PP
Each vCPU is a kernel process wired to one processor.  It does all the
work on the processor's virtualization state itself, so a read of
.CW regs
from Limbo is a request to that process, not a VMREAD on whatever
processor the Limbo program happens to be running on.
.NH 2
The platform
.PP
An x86 guest sees an 8259 pair, an 8254 on IRQ 0, a 16550 on IRQ 4, an
I/O APIC at
.CW 0xFEC00000
with the PIT on its input 2, a local APIC per vCPU, and a PCI bus.  The
PIT is not optional: without MP or ACPI tables Linux never starts the
local APIC's clock.  Nor is the I/O APIC: without it Linux, given an
MADT, chose symmetric I/O mode, masked the 8259's inputs, and its user
programs' output never came.  CPUID is the host's with what the
hypervisor does not provide hidden and the hypervisor bit set.
.PP
The guest runs on the host's TSC, unoffset, and the kernel offers KVM's
paravirtual clock, kvmclock, which Linux knows.  This hypervisor's own
CPUID signature is at
.CW 0x40000000 ;
KVM's is put at
.CW 0x40000100 ,
where Linux's search for it finds it, offering only the clock and its
stable flag.  A guest writes the address of a per-vCPU record to an
MSR and the kernel fills it: the TSC at that moment, nanoseconds since
the machine was made, and the scale between them.  Since the TSC is
shared and unoffset, one record stays good for the life of the
machine.  A second MSR gets the host's time of day at the machine's
time zero.  Testing it found that the native host's own clock counted
from boot: Plan 9's init sets the time from the hardware clock
.CW #r/rtc "" (
into
.CW #c/time ),
and the hosts used for testing did not, so their guests' clocks
started in 1970.  Now they do, and a Linux guest's time of day comes
out within seconds of the machine running the emulator.
.PP
The RISC-V platform is the SBI (base, timer, IPI, remote fence, hart
state management, debug console, and shutdown as an exit), a timer
through
.CW hvip ,
and either a PLIC or AIA: an APLIC emulated in MSI mode writing into
the hardware's IMSIC guest interrupt files.  The 16550 is shared
between the platforms
.CW port/vuart.c ). (
.NH 1
Devices
.NH 2
Assignment and the IOMMU
.PP
.CW assign
gives a machine a whole PCI function.  The guest sees it on its own
PCI bus, at guest-physical BAR addresses chosen as firmware would;
its memory BARs are mapped uncached in the nested page tables, except
the page of its MSI-X table, which traps.  An entry the guest enables
gets a host vector of its own on the real function, whose handler
delivers the guest's message to the guest's local APIC (or, on RISC-V,
writes it into the guest's IMSIC file).  Its DMA goes through an IOMMU
domain that maps guest-physical addresses onto the machine's memory, so
the guest programs the function with guest-physical addresses and it
can reach nothing else.
.PP
.CW #Q
serves the domains as files over a backend table:
.CW pc/vtd.c
(VT-d, with queued invalidation and interrupt remapping),
.CW pc/amdvi.c
(AMD-Vi, from IVRS) and
.CW virt/rviommu.c
(the RISC-V IOMMU).  Once translation is on, every function is in a
pass-through host domain until attached elsewhere.  A domain can be
given kernel memory of its own and can report its faults, which is
how the IOMMU is tested: QEMU's
.CW edu
device, a DMA engine, is attached to a domain mapping two pages,
copies between them through the domain, and is then aimed at a host
physical address the domain does not map, which must fault and leave
the page untouched.
.PP
VT-d's interrupt remapping is on wherever the platform and every unit
have it.  All of the I/O APIC's entries and every MSI are routed through
one table, with the requester ID checked: a boot traced in QEMU
remapped 2509 interrupts in 90 seconds, every one checked.
.NH 2
Releasing a function
.PP
When a machine ends, the functions it had are released before its
memory is freed.  Each loses its MSI-X vectors and bus mastering, is
moved straight from the machine's domain into a
.I "blocking domain"
\(em a domain that maps nothing \(em and is reset, by function-level
reset where it has one, or by a secondary bus reset where it is alone
below its bridge, with the host's configuration of it put back from
the kernel's
.CW Pcidev
record (the same restoration
.CW pcienable
does after D3).  It stays blocked until it is assigned again or
claimed through
.CW #Q .
.PP
This replaced a release that was worse than it looked.  It had run when
the machine's last reference went, after its memory had been freed,
so until then the function's domain still mapped memory being handed
to others; and it then put the function in the host domain, which
reaches everything.  The test assigns
.CW edu
to a machine, kills the machine, turns bus mastering back on behind
the kernel's back, and tells
.CW edu
to write to a host page by its physical address: the write faults and
the page is unchanged, on VT-d and AMD-Vi.  With the old release
compiled back in, the same test fails: the device is in the host
domain and the page is overwritten.  Moving a function between
domains also had a hole on AMD-Vi: the device table entry was cleared
between the two, and a cleared entry passes DMA through untranslated;
it is now made valid with no permissions while it changes.
.NH 2
SR-IOV
.PP
.CW #$
parses the SR-IOV capability, makes virtual functions on request, and
enumerates them with their BARs; the IOMMU puts new functions in its
host domain.  A virtual function is useless without a physical function
driver to answer its mailbox, so two Inferno Ethernet drivers became
physical function drivers.
.CW ether82563 ,
on the 82576, with
.CW *igbvfs= \fIn\fP:
pools for the VFs, its own traffic in the pool after theirs, sorting
by destination address, a switch looping traffic between pools, and
the mailbox (reset, address, multicast, VLAN, frame size).
.CW ether82598 ,
on the 82599 of the Intel X520, does the same with
.CW *ixgbevfs= \fIn\fP.
Two Linux guests, each given a virtual function, ping each other
through the controller's switch with the physical function being
Inferno's, on both NICs and both x86 backends.
.NH 2
Virtio
.PP
The hypervisor's own functions are virtio 1.0, over a PCI transport
on x86 and virtio-mmio on RISC-V.  A disk is served from a file named
in the namespace of whoever wrote the command, so it may be a local
file, one mounted from another machine, or one a Limbo program serves.
A network interface is a bridge port on an
.I ether (3)
device, which learns the guest's address.  A Linux guest makes an ext2
root on one virtio disk and a second guest boots on it.
.NH 1
Control from elsewhere
.PP
Because the interface is files, remote control needs no protocol of
its own: a host exports its
.CW /dev
over Styx, and hosted Inferno on another machine mounts it and runs
.I vmlinux
against the mounted
.CW /dev/vm :
a machine made, given memory, assigned a function, booted from files
on the remote machine, typed at and read back, every step a file
operation over the mount.
.PP
.I Vmsched
reads every mounted host's
.CW /dev/vm/host
and starts each machine on the host running the fewest, ties going to
the most contiguous free memory, by running
.I vmlinux
in a namespace with that host's
.CW /dev
bound in.  Two hosts, three guests: two land on the larger, one on the
smaller, and each answers naming its host.
.PP
This is also where the design leaves KVM's shape on purpose.
.I vmlinux
.CW -N
.I dir
makes a machine from a directory: its kernel, initrd, command line,
memory and processor count are files there, and its disks, networks
and assigned functions are entries of subdirectories.  The directory
is assembled with
.I bind
and
.I mount
before the machine starts, so a machine's disk can be a file on
another computer over Styx and its network an interface on this one.
The test builds one from four places: the kernel and initrd from the
root, the disk image from the machine running the emulator, and the
network from the host's virtio interface.
.NH 1
The benches, and the emulators made whole
.PP
Every check boots a kernel.  The x86 bench is QEMU's
.CW q35
machine under TCG with four processors, PCIe root ports, an Intel or
AMD IOMMU, NVMe, an 82576 with SR-IOV, and UEFI firmware
.CW scripts/vmhost.sh ). (
The second is Bochs, built with VMX (EPT, unrestricted guest) and SVM.
RISC-V uses QEMU's
.CW virt
machine with and without AIA and with the RISC-V IOMMU.
.PP
The benches were not adequate as found, and the rule adopted
(phase 16 of the plan) is that an emulator feature and the kernel's
use of it are one piece of work: nothing is added to a model that the
kernel does not then use and check, nothing is added to the kernel
that a bench cannot exercise, and an emulator change is checked first
against a client that is not this kernel \(em Linux's own drivers,
kvm-unit-tests \(em so a bug on one side cannot hide one on the other.
The changes to QEMU 10.1.3 are a series of patches applied by
.CW scripts/mkqemu.sh :
.IP 0001-0003 10
QEMU's
.CW igb
disagreed with the 82576 three ways: no autonegotiation out of reset,
no link bit in PHY register 17, and advanced receive descriptors
written when legacy ones were selected.
.IP 0004 10
A multi-threaded TCG race: the chipset's IGNNE# is kept in the first
processor's flags, which any processor's FPU instructions rewrote
non-atomically; under MTTCG that undid
.CW #VMEXIT 's
and
.CW VMRUN 's
own updates, and the host ran on the guest's page tables.  Three of
three four-processor runs failed before; three of three pass after.
.IP 0005 10
The AMD IOMMU model took a device's bus number before firmware had
numbered the buses, so every device behind a bridge used bus 0's
entry: the host domain.  The first IOMMU test overwrote the host's
interrupt table.  Also: missing I/O page faults, and fault addresses
always zero.
.IP 0006 10
VMX for TCG: VMXON and the VMCS instructions, VM entry with its checks,
VM exit, the MSR lists, event injection, the execution controls, EPT
beside NPT, VPID and unrestricted guest.  It is checked by
kvm-unit-tests (vmx: 6930 tests, two unexpected passes, 21 skipped;
ept: 9998, 6 skipped) and Linux's
.CW kvm_intel .
They also found TCG faults outside VMX: CR0's upper bits accepted,
MWAIT with nothing armed halting forever, IA32_TSC reading 0, #GP for
#SS, NPT reads reported as writes, the accessed bit set in a PDPTE,
the descriptor accessed and TSS busy flags never set, and STI and
MOV SS sharing one interrupt shadow.  With it, every milestone short
of the hardware one holds on VMX as on SVM, on one bench.
.IP 0007 10
An Intel 82599 (the X520) with 63 virtual functions, modelled from the
datasheet down to what drivers depend on: the EEPROM checksum, the
SFP+ module over bit-banged I\s-2\u2\d\s+2C, the software/firmware
semaphores, the mailbox, pools and the internal switch, checksum and
segmentation offloads, and receive-side scaling.
.IP 0008 10
NVMe's host memory buffer (the controller marks each lent chunk and
checks it on return, so a host that overwrites lent memory is caught)
and autonomous power state transitions.
.IP 0009 10
The Fresco Logic FL1100 xHCI, from its datasheet and Linux's history
with it.  A first model built from remembered quirks was contradicted
by Linux and replaced.  QEMU's xHCI itself needed event rings of more
than one segment (Linux died at its first command) and scratchpad
buffers.
.IP 0010 10
The alignment check: TCG never raised #AC.
.IP 0011 10
The
.CW edu
device had no reset; a bus reset cleared its configuration space and
left its registers and buffer, which no real function does.
.LP
Bochs needed two: its TSC-deadline timer ran against the raw tick
count rather than the TSC, and it did not recompute interrupt masking
at VM entry and exit.
.PP
Each model then has its Inferno use and an Inferno check.  The
82599's are the clearest.  The IP stack never left a checksum to
hardware; TCP and UDP now leave the pseudo-header's sum in the field
and mark the block, and IP finishes it in software unless the
outgoing interface will.  TCP now builds segments of many maximum
segment sizes for an interface that cuts them, and the driver gives
them to the hardware with a context descriptor.  The driver gives each
processor a receive queue, with the hardware spreading flows over
them.  The check is the remote-control test with the 82599 as the
host's interface: 89 of the host's files read back over Styx and
compared, 132 segments cut by the hardware, packets on all four
receive queues.  One limit is recorded rather than hidden: the model
recomputes the segment checksum seed itself, so the seed the driver
writes is shown right by the datasheet, not by the bench.
.NH 1
Faults found
.PP
Booting on new benches found faults that had been in the kernel all
along.
.IP \(bu 2
.CW wrmsr
took its value as two
.CW ulong s,
which are 32 bits: every MSR write lost its upper half.  Once the TSC
passed 2\u32\d every TSC deadline was already past and the timer
interrupted without end.  PAT, MTRR masks and machine-check enables
were cut the same way, on hardware too.  Only Bochs showed it, because
QEMU's TCG had no TSC-deadline timer; its debugger showed no process
running and the timer taken every 415 instructions.
.IP \(bu 2
A PML4 entry above 512 GiB was made only in the calling processor's
table, and application processors copied only every eighth entry: a
64-bit BAR placed high by UEFI faulted on the second processor.
.IP \(bu 2
Page 0 was mapped, so a Limbo nil dereference read zeros instead of
raising an exception; one such read panicked the kernel in DHCP.  Page
0 is now unmapped, and a fault in an interpreter becomes the Limbo
exception.
.IP \(bu 2
.CW canlock
raised a process's priority and nothing lowered it, so the clock
interrupt raised whatever it interrupted, and a vCPU that never slept
always beat Limbo.  A multiprocessor hid it; a one-hart RISC-V host
did not.
.IP \(bu 2
On riscv64 the M-mode trap entry used the thread pointer register to
build addresses, losing the interrupted value: an interrupt between
the compiler's two-instruction address formation sent a load
elsewhere.  It showed as a Dis fault, depending on code layout, in five
of six runs of one build and none of another.
.PP
And in the hypervisor:
.IP \(bu 2
VMX's current VMCS belongs to the processor, not the process: a vCPU
preempted on a processor shared with another vCPU came back on the
other's VMCS.  The process now carries its VMCS and reloads it when
rescheduled, like KVM's preempt notifiers.
.IP \(bu 2
Without V_INTR_MASKING, an SVM guest spinning with interrupts off never
exited, so on a one-processor host its other vCPUs never ran.
.IP \(bu 2
The virtio network receive queue's notification was served as a
request, returning every buffer empty: 954,000 length errors before
the check began requiring none.
.IP \(bu 2
A guest moving one BAR off a page another had just taken left the
second unmapped; a move now remaps every BAR.  Only RISC-V Linux moved
them.
.IP \(bu 2
Function release, above.
.NH 1
Status
.PP
.TS
center box;
l | c | c | c | c.
milestone	SVM	VMX	VMX	RISC-V H
	QEMU	QEMU	Bochs	QEMU
_
M1 a tiny guest	yes	yes	yes	yes
M2 Linux	yes	yes	yes	yes
M3 four processors	yes	yes	yes	yes
M4 the IOMMU	VT-d, AMD-Vi	VT-d, AMD-Vi	\-	yes
M5 function assignment	yes	yes	\-	yes (AIA)
M6, M7 SR-IOV, a VF in Linux	82576, 82599	82576, 82599	\-	\-
M8 virtio	yes	yes	yes	yes
M9 control over Styx	yes	yes	\-	\-
M10 placement across hosts	yes	yes	\-	\-
M11 the workstation	\-	\-	\-	\-
.TE
.LP
Bochs has no IOMMU, hence the gaps in its column; nothing has yet been
run on nested KVM or on hardware.
.PP
What is not done is recorded in the plan.  Interrupts are injected,
never posted: APIC virtualization, posted interrupts and AVIC are in no
model the benches have.  A machine cannot be saved, restored or moved,
because the platform's devices have no state files.  A machine's
memory is one contiguous run, with no ballooning.  Nothing is
hot-plugged.  Guests cannot nest.  A function with neither FLR nor a
bus of its own is released blocked but not reset, and the device that
would test release properly \(em one that starts DMA on its own after
it \(em is still to be designed.  Models of a Mellanox ConnectX-4 Lx and
of a GPU are wanted.  And the milestone that matters most, the
workstation with its X520, is still to come.
.SH
Sources
.PP
.CW doc/genesize-plan.ms
is the plan and the record of each result as it landed, with what the
booted kernels printed.  The manual pages are
.I vm (3),
.I iommu (3),
.I ether (3),
.I sd (3),
.I vmlinux (1),
.I vmsched (1),
.I pci (10),
.I allocb (10)
and
.I plan9.ini (10).
The kernel sources are under
.CW os/inferno/port
.CW devvm.c , (
.CW deviommu.c ,
.CW vmpci.c ,
.CW vmvirtio.c ,
.CW pci.c ),
.CW os/inferno/pc64
.CW vmx.c , (
.CW svm.c ),
.CW os/inferno/pc
.CW vmplat.c , (
.CW vmdev.c ,
.CW vtd.c ,
.CW amdvi.c ,
.CW ether82563.c ,
.CW ether82598.c )
and
.CW os/inferno/virt ;
the checks are
.CW scripts/check-*.sh
and the emulator patches
.CW scripts/qemu-patches .
