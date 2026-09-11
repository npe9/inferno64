#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

/*
 * What arm64 reads out of ACPI: the GIC from the MADT, and the
 * PCI-requester-to-DeviceID map from the IORT.
 *
 * This is the other half of what os/inferno/port/fdt.c does for a
 * device tree, and it exists for one reason: a SystemReady machine --
 * an Ampere Altra, a SolidRun HoneyComb, Arm's own reference parts --
 * hands the kernel ACPI and no device tree at all.  QEMU's virt
 * machine is the only place this can be exercised, and only through
 * UEFI, because QEMU builds the tables and edk2 is what installs an
 * RSDP where a guest can find it.
 *
 * Like fdtfind(), this runs before mmuinit() and before print(): it
 * reads, records, and says nothing.  acpireport() prints later, beside
 * what mem.h assumed, which is the only way to see a machine whose
 * layout differs from the compiled-in constants.
 *
 * Everything here falls back.  A board with no tables, or with tables
 * that do not checksum, or with a MADT that describes a GIC version
 * this kernel does not drive, boots exactly as it did before any of
 * this existed -- on mem.h.  That is deliberate and it is also why the
 * suite needs the falsify test rather than a marker count to show the
 * discovery is doing anything: see virtarm64-noscan in
 * tools/boardsuite/README.
 */

enum {
	/* MADT entry types (ACPI 6.5 table 5.21) */
	Madtgicc	= 0x0B,
	Madtgicd	= 0x0C,
	Madtgicmsi	= 0x0D,
	Madtgicr	= 0x0E,
	Madtgicits	= 0x0F,

	Madthdr		= 44,		/* header, then Local Interrupt Controller Address and Flags */

	/* IORT node types (IORT rev E.e table 4) */
	Iortits		= 0,
	Iortnamed	= 1,
	Iortrc		= 2,
	Iortsmmu	= 3,
	Iortsmmuv3	= 4,
};

static uvlong	gicdbase;
static uvlong	gicrbase, gicrlen;
static uvlong	gicitsbase;
static int	gicversion;

static ulong	ridbase, devidbase, ridcount;
static int	haveridmap;
static int	ridviasmmu;		/* the map goes through an SMMU */

static int	tablesfound;
static uvlong	rsdppa;			/* where the loader said they are */

/*
 * The signature line, built while the tables are still safe to read.
 *
 * acpireport() runs after xinit() and poolinit(), and the tables sit
 * wherever the firmware put them -- 0x7cb43018 on this machine, most of
 * a gigabyte into DRAM, which with no device tree is inside the memory
 * this kernel sized from mem.h and handed to the allocator.  Reading
 * them there works only because xalloc starts low.  That is the same
 * hazard confcopy() exists for, so the answer is the same: take the
 * copy early and print the copy.
 */
static char	sigline[256];

static uint
le32(uchar *p)
{
	return (uint)p[0] | (uint)p[1]<<8 | (uint)p[2]<<16 | (uint)p[3]<<24;
}

static ushort
le16(uchar *p)
{
	return (ushort)p[0] | (ushort)p[1]<<8;
}

static uvlong
le64(uchar *p)
{
	return (uvlong)le32(p) | (uvlong)le32(p+4)<<32;
}

/*
 * The MADT, which ACPI still calls APIC in its signature field.
 *
 * The entries are a flat list of (type, length) records and the length
 * is what the walk trusts: a zero length would spin forever and a
 * length past the end of the table would walk off it, so both end the
 * walk rather than being worked around.
 */
static void
madt(void)
{
	extern void *acpitable(char*);
	extern uint acpitablen(void*);
	uchar *t, *p, *e;
	int n;

	t = acpitable("APIC");
	if(t == nil)
		return;
	e = t + acpitablen(t);
	for(p = t + Madthdr; p + 2 <= e; p += n){
		n = p[1];
		if(n < 2 || p + n > e)
			break;
		switch(p[0]){
		case Madtgicd:
			if(n >= 24){
				gicdbase = le64(p+8);
				gicversion = p[20];
			}
			break;
		case Madtgicr:
			if(n >= 16){
				gicrbase = le64(p+4);
				gicrlen = le32(p+12);
			}
			break;
		case Madtgicits:
			if(n >= 16)
				gicitsbase = le64(p+8);
			break;
		case Madtgicc:
			/*
			 * The per-cpu entry also carries a redistributor
			 * base, for parts that have no discovery range.
			 * Only taken when the GICR entry did not appear,
			 * because the range is the better answer: it
			 * describes every redistributor and this one
			 * describes one cpu's.
			 */
			if(n >= 76 && gicrbase == 0)
				gicrbase = le64(p+60);
			break;
		}
	}
}

/*
 * The IORT, and the walk from a PCI requester id to a DeviceID the ITS
 * will accept.
 *
 * The node header is Type at 0, Length at 1 -- one, not two, and the
 * two-byte field is unaligned on purpose.  Reading it at 2 gives every
 * node a length of 256 on this machine, so the first step of the walk
 * lands past the end of the table and the answer is silently "no root
 * complex here".
 *
 * A root complex node carries a list of id mappings; each says that
 * inputs from base for count map to outputs from base on some other
 * node, named by an offset from the start of the table.  Follow that
 * reference: an ITS group node is the end of the walk, and an SMMU in
 * between means the real map is the composition of two, which this does
 * not do.  It says so rather than composing the first one and hoping,
 * because a wrong DeviceID is an interrupt that is delivered to some
 * other device's vector.
 */
static void
iort(void)
{
	extern void *acpitable(char*);
	extern uint acpitablen(void*);
	uchar *t, *e, *node, *map, *out;
	uint nnode, off, nmap, mapoff, outref;
	int i, j;

	t = acpitable("IORT");
	if(t == nil)
		return;
	e = t + acpitablen(t);
	if(t + 44 > e)
		return;
	nnode = le32(t+36);
	off = le32(t+40);
	if(off < 48 || t + off > e)
		return;
	node = t + off;
	for(i = 0; i < (int)nnode && node + 16 <= e; i++){
		if(node[0] != Iortrc)
			goto next;
		nmap = le32(node+8);
		mapoff = le32(node+12);
		if(mapoff == 0 || node + mapoff > e)
			goto next;
		for(j = 0; j < (int)nmap; j++){
			map = node + mapoff + j*20;
			if(map + 20 > e)
				break;
			/*
			 * One hop, and every mapping of the node is looked
			 * at rather than stopping at the first useful one.
			 *
			 * A mapping that points straight at an ITS group is
			 * a window this board can use.  One that points at
			 * an SMMU means the real map for those requesters
			 * is the composition of this mapping with the
			 * SMMU's own, which is not implemented -- and a
			 * root complex can have both, which is exactly what
			 * QEMU's -M virt,iommu=smmuv3 produces.  There the
			 * direct window is 0x100..0xffff and the devices
			 * below it go through the SMMU, so taking the first
			 * ITS mapping and stopping would have hidden the
			 * fact that half the bus is unreachable.  It is not
			 * composed and it is not guessed: a DeviceID wrong
			 * by a constant is an interrupt delivered to some
			 * other device's vector, and ridtodevid() refusing
			 * a requester outside the window costs that device
			 * MSI and nothing else.
			 */
			outref = le32(map+12);
			if(outref == 0 || t + outref + 16 > e)
				continue;
			out = t + outref;
			if(out[0] == Iortits && !haveridmap){
				ridbase = le32(map+0);
				ridcount = le32(map+4) + 1;
				devidbase = le32(map+8);
				haveridmap = 1;
			} else if(out[0] == Iortsmmu || out[0] == Iortsmmuv3)
				ridviasmmu = 1;
		}
	next:
		if(le16(node+1) == 0)
			break;
		node += le16(node+1);
	}
}

void
acpifind(void)
{
	extern void acpiinit(uintptr);
	extern int acpivalid(void);
	extern char *bootconfline(char*);
	char *p;
	uintptr pa;

	p = bootconfline("*acpi=");
	if(p == nil)
		return;
	pa = (uintptr)strtoull(p, nil, 16);
	rsdppa = pa;
	acpiinit(pa);
	if(!acpivalid())
		return;
	tablesfound = 1;
	{
		extern char *acpisig(int, char[5]);
		extern int acpirevision(void);
		char buf[5], *e;
		int i;

		e = seprint(sigline, sigline+sizeof sigline,
			"acpi: revision %d:", acpirevision());
		for(i = 0; acpisig(i, buf) != nil && e < sigline+sizeof sigline - 8; i++)
			e = seprint(e, sigline+sizeof sigline, " %s", buf);
	}
	madt();
	iort();
}

void
acpireport(void)
{
	if(!tablesfound){
		if(bootconfline("*acpi=") != nil)
			print("acpi: the rsdp the loader passed is not one\n");
		return;
	}
	print("%s\n", sigline);
	if(gicdbase != 0)
		print("acpi: madt gicv%d dist @ %#llux (mem.h GICD %#p)\n",
			gicversion, gicdbase, (uintptr)GICD);
	if(gicrbase != 0)
		print("acpi: madt redist @ %#llux size %#llux (mem.h GICR %#p)\n",
			gicrbase, gicrlen, (uintptr)GICR);
	if(gicitsbase != 0)
		print("acpi: madt its @ %#llux, ACPI-ITS-OK\n", gicitsbase);
	if(haveridmap)
		print("acpi: iort rid %#lux..%#lux -> devid %#lux, ACPI-IORT-OK\n",
			ridbase, ridbase + ridcount - 1, devidbase);
	if(ridviasmmu)
		print("acpi: iort also maps requesters through an smmu;"
			" those keep intx\n");
	/*
	 * Whether the tables are inside the memory the allocator owns.
	 *
	 * This is the check the whole *memtop= path exists to pass.  The
	 * kernel sizes memory from the loader's number and confinit()
	 * claims one range from the bottom of DRAM to it; if the tables
	 * are under that top they are in the heap, and every read of them
	 * after xinit() is a read of memory something else may already
	 * have been handed.  It survived that way for a while, which is
	 * the same "nothing had allocated that far up yet" the riscv
	 * boards were caught by, and it is not evidence of anything.
	 *
	 * Printed either way.  A board where it goes wrong should say so
	 * rather than going quiet, because going quiet is what it did.
	 */
	if(rsdppa != 0){
		if(rsdppa < (uvlong)conf.topofmem)
			print("acpi: tables at %#llux are below topofmem %#p --"
				" xalloc owns them, ACPI-IN-HEAP\n",
				rsdppa, (uintptr)conf.topofmem);
		else
			print("acpi: tables at %#llux above topofmem %#p,"
				" ACPI-OUTSIDE-HEAP\n",
				rsdppa, (uintptr)conf.topofmem);
	}
	if(gicdbase == 0 && gicitsbase == 0 && !haveridmap)
		print("acpi: tables carry nothing this board reads\n");
}

/*
 * What the rest of the board asks.  Each returns 0 or nil when ACPI
 * said nothing, and every caller falls back to the device tree or to
 * mem.h -- which is why none of these can break a board that has no
 * tables.
 */
uvlong
acpiits(void)
{
	return gicitsbase;
}

int
acpiridmap(ulong *rid, ulong *devid, ulong *count)
{
	if(!haveridmap)
		return 0;
	*rid = ridbase;
	*devid = devidbase;
	*count = ridcount;
	return 1;
}
