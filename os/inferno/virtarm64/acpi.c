#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"

/*
 * ACPI on arm64, as far as reading the tables.
 *
 * A PC finds the RSDP by scanning the BIOS area; there is no such area
 * on an AArch64 machine and the pointer comes from the UEFI system
 * table instead, which is why os/inferno/boot/efi has to exist before
 * any of this can.  The loader puts it in the configuration block as
 * *acpi= and os/inferno/virtarm64/bootargs.c parses that, so all this
 * has to do is follow it.
 *
 * Every value read here is printed beside the one mem.h compiles in,
 * because this board's addresses are fixed and agreement on a machine
 * whose layout is already known is the evidence that the reader is
 * right.  Three are then used rather than only printed: the PCIe ECAM
 * window (see the end of acpiinit), the PSCI conduit, and the
 * processor list, which startcpu.c hands to PSCI CPU_ON.  The GIC
 * bases and the console UART are still taken from mem.h.
 *
 * Fields are read a byte at a time.  ACPI tables are byte-packed and
 * several of the fields this wants are not naturally aligned -- the
 * GICC structure puts an eight-byte physical address at offset 32 of
 * an entry that itself starts at an odd offset from the table.
 *
 * The MMU is off on this board, so a physical address is usable as it
 * stands.  The tables sit in EfiACPIReclaimMemory, which the loader
 * reports in *e820 as type 3; nothing reserves it yet, so this runs
 * early -- from main(), before xinit() -- and keeps only the values,
 * never a pointer into the tables.
 */

uvlong acpimcfg;		/* PCIe ECAM base, 0 if the MCFG says nothing */
int acpimcfgbus0, acpimcfgbus1;	/* and the bus range it covers */
uvlong acpigicd;		/* GIC distributor */
uvlong acpigicr;		/* GIC redistributor (GICv3) */
uvlong acpigicc;		/* GIC cpu interface (GICv2) */
uvlong acpiuart;		/* console UART base, from the SPCR */
int acpiuartiface;		/* SPCR interface type: 3 pl011, 0x0d/0x0e sbsa */
int acpiuartspace;		/* address space: 0 system memory, 1 i/o */
int acpiuartwidth;		/* register bit width */
int acpiuartaccess;		/* GAS access size */
int acpiuartintr;		/* interrupt type bitmap */
int acpiuartirq;		/* PC-style irq, meaningless on arm64 */
int acpiuartgsi;		/* global system interrupt -- the GIC number */
int acpiuartbaud;		/* 0 as-is, 3 9600, 4 19200, 6 57600, 7 115200 */

/*
 * The processor list.  A GICC structure is one processor: its MPIDR is
 * what PSCI CPU_ON wants as a target, and there is no other way to
 * learn it -- MPIDR_EL1 reads only the one the code is running on.
 * The MADT's order is not the MPIDR order and neither is the ACPI
 * processor UID, so all three are kept.
 */
Acpicpu acpicpu[Nacpicpu];
Acpimsi acpimsiframe[Nacpimsi];
int acpinmsiframe;
Acpiits acpiits[Nacpiits];
int acpinits;
int acpincpudesc;		/* GICC entries recorded, at most Nacpicpu */
int acpincpuall;		/* GICC entries seen, however many that is */
int acpincpu;			/* of those, the ones the Enabled bit is set in */
int acpicpushort;		/* GICC entries too short to carry an MPIDR */

/*
 * The architected timer, from the GTDT.  The GSIVs are interrupt
 * numbers in the GIC's own numbering, so the virtual timer at PPI 11
 * reads as 27 here and the non-secure EL1 physical one at PPI 14 as
 * 30.  The clock is the virtual timer; see cycles() in l.s.
 */
uvlong acpicntctl;		/* CntControlBase */
uvlong acpicntread;		/* CntReadBase */
int acpitimersec;		/* secure EL1 physical */
int acpitimernsec;		/* non-secure EL1 physical */
int acpitimernsecflags;
int acpitimervirt;		/* virtual EL1 -- the one used */
int acpitimerel2;		/* EL2 physical */
int acpinplattimer;		/* platform timer structures, not read */

/*
 * FADT ARM Boot Architecture Flags, and the two bits of it that
 * matter: whether PSCI is there at all and whether its conduit is HVC
 * or SMC.  -1 means no FADT said.
 */
int acpiarmboot = -1;
int acpipsci;
int acpipscihvc;

/*
 * What the walk saw, kept so acpiinit() can print it afterwards: the
 * walk itself runs before there is a console to print on.
 */
Acpitab acpitab[Nacpitab];
int acpintab;			/* entries filled, at most Nacpitab */
int acpintaball;		/* entries the root table named */
int acpirev;
int acpixsdt;			/* 1 XSDT, 0 RSDT */
uvlong acpiroot;
int acpibad;			/* 1 no RSDP, 2 bad root table */

static uint
le16(uchar *p)
{
	return p[0] | p[1]<<8;
}

static uint
le32(uchar *p)
{
	return p[0] | p[1]<<8 | p[2]<<16 | (uint)p[3]<<24;
}

static uvlong
le64(uchar *p)
{
	return (uvlong)le32(p) | (uvlong)le32(p+4)<<32;
}

static int
sumok(uchar *p, int n)
{
	int s;

	for(s = 0; n > 0; n--)
		s += *p++;
	return (s & 0xFF) == 0;
}

static void
madt(uchar *t, int len)
{
	uchar *p, *e;
	Acpicpu *c;
	int n;

	p = t + 44;			/* header, LocalApicAddress, Flags */
	e = t + len;
	while(p + 2 <= e){
		n = p[1];
		if(n < 2 || p + n > e)
			break;
		switch(p[0]){
		case 0x0B:		/* GICC */
			/*
			 * Guarded field by field, not once for the whole
			 * structure: GICC grew from 40 bytes in ACPI 5.0 to
			 * 76 in 5.1 (GICR base and MPIDR) to 80 in 6.0, and
			 * a length that covers the cpu interface does not
			 * mean it covers the MPIDR at 68..75.
			 */
			if(n < 16)
				break;
			acpincpuall++;
			if(le32(p+12) & 1)
				acpincpu++;
			if(n >= 40 && acpigicc == 0)
				acpigicc = le64(p+32);
			if(n >= 68 && acpigicr == 0)
				acpigicr = le64(p+60);
			if(n < 76){
				acpicpushort++;
				break;
			}
			if(acpincpudesc < Nacpicpu){
				c = &acpicpu[acpincpudesc++];
				c->uid = le32(p+8);
				c->flags = le32(p+12);
				c->mpidr = le64(p+68);
				c->gicr = le64(p+60);
			}
			break;
		case 0x0C:		/* GICD */
			if(n >= 16)
				acpigicd = le64(p+8);
			break;
		case 0x0E:		/* GICR */
			if(n >= 12)
				acpigicr = le64(p+4);
			break;
		/*
		 * The two ways an arm64 machine turns a PCI MSI write into
		 * an interrupt.  A GICv2 has an MSI frame -- a page whose
		 * doorbell register takes an SPI number as its data -- and a
		 * GICv3 has an ITS, which translates a device id and an
		 * event id into an LPI.  Neither is driven yet; this is the
		 * discovery half, and which one a machine has is the first
		 * thing a driver would need to know.
		 */
		case 0x0D:		/* GIC MSI frame (GICv2m) */
			if(n >= 24 && acpinmsiframe < Nacpimsi){
				acpimsiframe[acpinmsiframe].id = le32(p+4);
				acpimsiframe[acpinmsiframe].base = le64(p+8);
				acpimsiframe[acpinmsiframe].flags = le32(p+16);
				acpimsiframe[acpinmsiframe].spicount = le16(p+20);
				acpimsiframe[acpinmsiframe].spibase = le16(p+22);
				acpinmsiframe++;
			}
			break;
		case 0x0F:		/* GIC ITS (GICv3) */
			if(n >= 20 && acpinits < Nacpiits){
				acpiits[acpinits].id = le32(p+4);
				acpiits[acpinits].base = le64(p+8);
				acpinits++;
			}
			break;
		}
		p += n;
	}
}

static void
mcfg(uchar *t, int len)
{
	uchar *p;

	if(len < 36+8+16)
		return;
	p = t + 36 + 8;			/* header, then eight reserved bytes */
	acpimcfg = le64(p);
	acpimcfgbus0 = p[10];
	acpimcfgbus1 = p[11];
}

/*
 * What os/inferno/port/pciecam.c asks a board for, in the shape
 * os/inferno/pc/pcipc.c's pciecam already has.
 */
static uvlong
mcfgbase(int *bus0, int *bus1)
{
	if(acpimcfg == 0)
		return 0;
	*bus0 = acpimcfgbus0;
	*bus1 = acpimcfgbus1;
	return acpimcfg;
}

/*
 * The GTDT.  Every field this wants is at a fixed offset and the table
 * is 104 bytes on the machines here, so one length test covers them:
 * the last of them, the platform timer offset, ends at 96.
 */
static void
gtdt(uchar *t, int len)
{
	if(len < 96)
		return;
	acpicntctl = le64(t + 36);
	acpitimersec = le32(t + 48);
	acpitimernsec = le32(t + 56);
	acpitimernsecflags = le32(t + 60);
	acpitimervirt = le32(t + 64);
	acpitimerel2 = le32(t + 72);
	acpicntread = le64(t + 80);
	acpinplattimer = le32(t + 88);
}

/*
 * The FADT's ARM Boot Architecture Flags say whether PSCI is there and
 * whether it answers HVC or SMC.  The field is at offset 129 and only
 * exists from FADT revision 5.1 onwards; before that the byte is
 * reserved and zero, which the revision test below excludes anyway.
 * The major revision is the table header's, at offset 8; the minor is
 * a field of its own at 131.
 */
static void
facp(uchar *t, int len)
{
	if(len < 132)
		return;
	if(t[8] < 5 || (t[8] == 5 && t[131] < 1))
		return;
	acpiarmboot = le16(t+129);
	acpipsci = acpiarmboot & 1;
	acpipscihvc = (acpiarmboot>>1) & 1;
}

/*
 * SPCR, the Serial Port Console Redirection table: where the firmware
 * says its console is.  The address sits inside a Generic Address
 * Structure at offset 40, whose own address field is eight bytes at
 * offset 4 of it, hence 44.  Everything else here is fixed-offset.
 *
 * Interface types worth knowing: 3 is a PL011, 0x0D and 0x0E are the
 * SBSA generic UART, which is a PL011 with the modem and DMA parts
 * removed and is register-compatible over the subset this driver uses.
 * 0 and 1 are 16550s, which this board has no driver for.
 */
static void
spcr(uchar *t, int len)
{
	if(len < 62)
		return;
	acpiuartiface = t[36];
	acpiuartspace = t[40];		/* GAS address space id: 0 memory, 1 i/o */
	acpiuartwidth = t[41];
	acpiuartaccess = t[43];
	acpiuart = le64(t + 44);
	acpiuartintr = t[52];
	acpiuartirq = t[53];
	acpiuartgsi = le32(t + 54);
	acpiuartbaud = t[58];
}

/*
 * Walk the tables and fill in the globals above, printing nothing.
 *
 * This is separate from acpiinit() and runs much earlier -- before
 * uartconsole() -- for one reason: the console.  A board whose mem.h
 * names the wrong UART cannot be rescued by an SPCR read after the
 * fact, because uartconsole() programs the PL011 at that wrong address
 * and the resulting data abort arrives before trapinit() has installed
 * a handler, so it is taken by the firmware's own exception handler
 * and the kernel never reaches acpiinit() at all.  Measured, not
 * assumed: pointing this board's UART0 at 0x9030000 produced
 * "Synchronous Exception at ..." from EDK2's ArmCpuDxe with X2 holding
 * that address, and no kernel output whatsoever.  The console has to
 * be right before anything touches it.
 *
 * Nothing here allocates, locks, or keeps a pointer into the tables,
 * so running it this early costs nothing.
 */
int
acpitables(void)
{
	char *cp, sig[5];
	uchar *rsd, *root, *t;
	uvlong a;
	int i, n, len, rev, e8;

	if((cp = getconf("*acpi")) == nil)
		return 0;
	a = strtoull(cp, nil, 0);
	if(a == 0)
		return 0;
	rsd = (uchar*)a;
	if(memcmp(rsd, "RSD PTR ", 8) != 0 || !sumok(rsd, 20)){
		acpibad = 1;
		return 0;
	}
	rev = rsd[15];
	if(rev >= 2 && sumok(rsd, le32(rsd+20)) && le64(rsd+24) != 0){
		root = (uchar*)le64(rsd+24);
		e8 = 1;			/* XSDT: eight-byte pointers */
	} else {
		root = (uchar*)(uvlong)le32(rsd+16);
		e8 = 0;			/* RSDT: four */
	}
	if(root == nil)
		return 0;
	acpirev = rev;
	acpixsdt = e8;
	acpiroot = (uvlong)(uintptr)root;
	len = le32(root+4);
	if(len < 36 || !sumok(root, len)){
		acpibad = 2;
		return 0;
	}
	n = (len - 36) / (e8 ? 8 : 4);
	acpintaball = n;
	for(i = 0; i < n; i++){
		if(e8)
			t = (uchar*)le64(root + 36 + i*8);
		else
			t = (uchar*)(uvlong)le32(root + 36 + i*4);
		if(t == nil)
			continue;
		len = le32(t+4);
		memmove(sig, t, 4);
		sig[4] = 0;
		if(acpintab < Nacpitab){
			memmove(acpitab[acpintab].sig, sig, 5);
			acpitab[acpintab].addr = (uvlong)(uintptr)t;
			acpitab[acpintab].len = len;
			acpitab[acpintab].ok = len >= 36 && sumok(t, len);
			acpintab++;
		}
		if(len < 36 || !sumok(t, len))
			continue;
		if(memcmp(t, "FACP", 4) == 0)
			facp(t, len);
		else if(memcmp(t, "APIC", 4) == 0)
			madt(t, len);
		else if(memcmp(t, "MCFG", 4) == 0)
			mcfg(t, len);
		else if(memcmp(t, "SPCR", 4) == 0)
			spcr(t, len);
		else if(memcmp(t, "GTDT", 4) == 0)
			gtdt(t, len);
	}
	return 1;
}

/*
 * Print what the walk found, and act on it.  Runs where it always did,
 * after printinit(); by now the console is wherever acpitables() and
 * spcrconsole() between them decided it should be.
 */
void
acpiinit(void)
{
	int i;

	if(acpibad == 1){
		print("acpi: no RSDP where the loader said\n");
		return;
	}
	if(acpibad == 2){
		print("acpi: bad %s\n", acpixsdt ? "XSDT" : "RSDT");
		return;
	}
	if(acpintab == 0)
		return;
	print("acpi: rev %d %s at %#llux, %d tables\n",
		acpirev, acpixsdt ? "XSDT" : "RSDT", acpiroot, acpintaball);
	for(i = 0; i < acpintab; i++)
		print("acpi: %s at %#llux len %d%s\n", acpitab[i].sig,
			acpitab[i].addr, acpitab[i].len,
			acpitab[i].ok ? "" : ": bad checksum");
	if(acpintaball > acpintab)
		print("acpi: %d tables beyond the %d this keeps\n",
			acpintaball - acpintab, Nacpitab);

	/*
	 * Beside what mem.h and io.h compile in, so the log says whether
	 * the firmware and the board agree.
	 */
	print("acpi: gicd %#llux (mem.h %#p) gicr %#llux (mem.h %#p) gicc %#llux (mem.h %#p)\n",
		acpigicd, (void*)GICD, acpigicr, (void*)GICR, acpigicc, (void*)GICC);
	print("acpi: ecam %#llux (mem.h %#p) bus %d..%d cpus %d\n",
		acpimcfg, (void*)PCIECAM, acpimcfgbus0, acpimcfgbus1, acpincpu);

	/*
	 * The processor list.  conf.nmach is printed beside it so a log
	 * cannot be read as saying this kernel runs on more than one:
	 * these are the processors the firmware describes, not the ones
	 * anything schedules.
	 */
	print("acpi: %d processors described, %d enabled, %lud used%s\n",
		acpincpuall, acpincpu, conf.nmach,
		acpicpushort ? ", some too short for an MPIDR" : "");
	for(i = 0; i < acpincpudesc; i++){
		if(i == 32 && acpincpudesc > 32){
			print("acpi: ... and %d more\n", acpincpudesc - 32);
			break;
		}
		print("acpi: cpu%d uid %ud mpidr %#llux gicr %#llux%s%s\n",
			i, acpicpu[i].uid, acpicpu[i].mpidr, acpicpu[i].gicr,
			acpicpu[i].flags & 1 ? " enabled" : "",
			acpicpu[i].flags & 2 ? " online-capable" : "");
	}
	if(acpincpuall > acpincpudesc)
		print("acpi: %d processors beyond the %d this keeps\n",
			acpincpuall - acpincpudesc, Nacpicpu);

	/*
	 * The console.  Acted on long before this, in main() before
	 * uartconsole(); this only reports what happened.
	 */
	print("acpi: uart %#llux (mem.h %#p) type %#ux space %d access %d gsi %d baud %d\n",
		acpiuart, (void*)UART0, acpiuartiface, acpiuartspace,
		acpiuartaccess, acpiuartgsi, acpiuartbaud);
	if(spcrstate == 2)
		print("spcr: console moved from %#llux to %#llux; this line is proof\n",
			spcrwas, acpiuart);
	else
		print("spcr: %s\n", spcrwhy());

	/*
	 * The architected timer.  The interrupt this board has always
	 * used came from the device tree QEMU also publishes; the GTDT
	 * is where a server says it, and it is the one value here whose
	 * being right or wrong is the difference between a kernel that
	 * has a clock and one that does not.
	 */
	print("acpi: timer virt %d (io.h %d) ns-el1 %d flags %#ux sec %d el2 %d\n",
		acpitimervirt, GicPPITimer, acpitimernsec, acpitimernsecflags,
		acpitimersec, acpitimerel2);
	if(acpicntctl != 0 || acpicntread != 0 || acpinplattimer != 0)
		print("acpi: cntctl %#llux cntread %#llux %d platform timers\n",
			acpicntctl, acpicntread, acpinplattimer);
	/* the virtual timer's, because that is the one the clock uses */
	if(acpitimervirt != 0 && acpitimervirt != timerirq){
		print("timer: irq %d from the firmware, io.h says %d\n",
			acpitimervirt, timerirq);
		timerirq = acpitimervirt;
		gicenable(timerirq);
	}

	/*
	 * How a PCI MSI reaches the GIC on this machine.  Nothing drives
	 * either yet -- os/inferno/port/pci.c's pcimsixintrenable is
	 * still nil on this board and sdnvme falls back to INTx -- but a
	 * driver's first question is which of the two exists, and this
	 * answers it from the firmware rather than from a guess.
	 */
	for(i = 0; i < acpinmsiframe; i++)
		print("acpi: gic msi frame %ud at %#llux flags %#ux spi %d..%d\n",
			acpimsiframe[i].id, acpimsiframe[i].base,
			acpimsiframe[i].flags, acpimsiframe[i].spibase,
			acpimsiframe[i].spibase + acpimsiframe[i].spicount - 1);
	for(i = 0; i < acpinits; i++)
		print("acpi: gic its %ud at %#llux\n",
			acpiits[i].id, acpiits[i].base);
	if(acpinmsiframe == 0 && acpinits == 0)
		print("acpi: no gic msi frame and no its; msi is not available\n");
	msiinit();

	/*
	 * PSCI.  Which instruction reaches it is firmware's to say, and
	 * getting it wrong is not a wrong answer but an undefined
	 * instruction or a fault, so the default when nothing says
	 * stays what this board has always done.
	 */
	if(acpiarmboot < 0)
		print("acpi: no ARM boot flags; psci through hvc, as before\n");
	else
		print("acpi: arm boot flags %#ux: psci %s, conduit %s\n",
			acpiarmboot, acpipsci ? "yes" : "no",
			acpipscihvc ? "hvc" : "smc");
	if(acpipsci && !acpipscihvc)
		pscismcconduit = 1;

	/*
	 * The one value used rather than only printed.  A real arm64
	 * server does not put its ECAM window where QEMU does, and this
	 * is the piece of the firmware description that nothing else can
	 * supply -- the rest of what is read above the board still takes
	 * from mem.h.
	 */
	if(acpimcfg != 0){
		extern uvlong (*pciecam)(int*, int*);

		pciecam = mcfgbase;
	}
}

/*
 * The IORT, as far as one question: what device id does the ITS see
 * when PCI function `rid` (bus:dev.fn) writes to GITS_TRANSLATER?
 *
 * The answer is usually rid itself, and assuming that is how this
 * board first got MSI-X working under QEMU and delivered nothing at
 * all on a Compute Engine t2a, where every vector was accepted and
 * mapped and no interrupt ever arrived.  A mapping the firmware
 * publishes and the driver ignores fails exactly that quietly: the
 * ITS is asked about a device that never writes to it.
 *
 * Only the root complex nodes are walked, and only their ID mappings.
 * SMMU nodes in the path would make this a two-step translation, and
 * this says so rather than guessing: a machine with one gets the
 * identity answer and a printed warning, which is the same silence as
 * before but with a reason attached.
 *
 * Layout is ARM DEN 0049: table header, then node count and the offset
 * of the first node; each node has a type, a length, a mapping count
 * and a mapping offset; each mapping is input base, count minus one,
 * output base, the offset of the target node, and flags whose bit 0
 * means "map the whole range to one id".
 */
static uchar*
iortfind(void)
{
	int i;

	for(i = 0; i < acpintab; i++)
		if(strcmp(acpitab[i].sig, "IORT") == 0 && acpitab[i].ok)
			return (uchar*)(uintptr)acpitab[i].addr;
	return nil;
}

int
acpiitsdevid(int rid, u32int *devid)
{
	uchar *t, *node, *map;
	int nnode, i, j, nmap, type, len;
	u32int inbase, nid, outbase, outref, flags;
	static int warned;

	*devid = rid;
	if((t = iortfind()) == nil)
		return 0;
	nnode = le32(t + 36);
	node = t + le32(t + 40);
	for(i = 0; i < nnode; i++){
		type = node[0];
		len = le16(node+1);
		if(len <= 0)
			return 0;
		if(type == 3 || type == 4){
			if(!warned){
				warned = 1;
				print("acpi: the IORT has an SMMU node;"
					" device ids are not translated through it\n");
			}
		}
		if(type == 2){			/* PCI root complex */
			nmap = le32(node+8);
			map = node + le32(node+12);
			for(j = 0; j < nmap; j++, map += 20){
				inbase = le32(map);
				nid = le32(map+4);
				outbase = le32(map+8);
				outref = le32(map+12);
				flags = le32(map+16);
				if(flags & 1){		/* single mapping */
					*devid = outbase;
					USED(outref);
					return 1;
				}
				if((u32int)rid >= inbase && (u32int)rid - inbase <= nid){
					*devid = outbase + ((u32int)rid - inbase);
					return 1;
				}
			}
		}
		node += len;
	}
	return 0;
}
