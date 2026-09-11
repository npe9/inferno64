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
			 * One hop.  A root complex that points straight at
			 * an ITS group is the whole answer; one that points
			 * at an SMMU means the real map is the composition
			 * of this mapping with the SMMU's own, and that is
			 * not implemented.  It is reported rather than
			 * half-applied, because a DeviceID that is wrong by
			 * a constant is an interrupt delivered to some
			 * other device's vector.
			 */
			outref = le32(map+12);
			if(outref == 0 || t + outref + 16 > e)
				continue;
			out = t + outref;
			if(out[0] == Iortits){
				ridbase = le32(map+0);
				ridcount = le32(map+4) + 1;
				devidbase = le32(map+8);
				haveridmap = 1;
				return;
			}
			if(out[0] == Iortsmmu || out[0] == Iortsmmuv3)
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
	acpiinit(pa);
	if(!acpivalid())
		return;
	tablesfound = 1;
	madt();
	iort();
}

void
acpireport(void)
{
	extern int acpirevision(void);

	if(!tablesfound){
		if(bootconfline("*acpi=") != nil)
			print("acpi: the rsdp the loader passed is not one\n");
		return;
	}
	{
		extern char *acpisig(int, char[5]);
		char buf[5], line[256], *e;
		int i;

		e = seprint(line, line+sizeof line, "acpi: revision %d:",
			acpirevision());
		for(i = 0; acpisig(i, buf) != nil && e < line+sizeof line - 8; i++)
			e = seprint(e, line+sizeof line, " %s", buf);
		print("%s\n", line);
	}
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
	else if(ridviasmmu)
		print("acpi: iort maps through an smmu; not walked\n");
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
