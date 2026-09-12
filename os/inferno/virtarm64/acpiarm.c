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

	Nredist		= 8,		/* redistributor ranges kept */

	Madthdr		= 44,		/* header, then Local Interrupt Controller Address and Flags */

	/* IORT node types (IORT rev E.e table 4) */
	Iortits		= 0,
	Iortnamed	= 1,
	Iortrc		= 2,
	Iortsmmu	= 3,
	Iortsmmuv3	= 4,
};

static uvlong	gicdbase;
static uvlong	giccbase;		/* the v2 MMIO cpu interface */

/*
 * Every redistributor range the MADT names, not the first.
 *
 * QEMU's virt machine publishes a second one as soon as more cpus are
 * asked for than the first range holds -- 124 is enough, and the second
 * lands at 0x4000000000 -- and a machine with two sockets has at least
 * two.  The frames inside them are what a cpu finds its own
 * redistributor in, so the ranges have to be kept rather than reduced
 * to a base.
 */
static uvlong	gicrbase[Nredist], gicrlen[Nredist];
static int	ngicr;
static int	gicrlost;		/* more ranges than this board keeps */
static uvlong	gicitsbase;
static int	gicversion;


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
				if(ngicr >= Nredist)
					gicrlost++;
				else {
					gicrbase[ngicr] = le64(p+4);
					gicrlen[ngicr] = le32(p+12);
					ngicr++;
				}
			}
			break;
		case Madtgicits:
			if(n >= 16)
				gicitsbase = le64(p+8);
			break;
		case Madtgicc:
			/*
			 * The per-cpu entry carries two bases.  Physical
			 * Base Address at offset 32 is the GICv2 MMIO cpu
			 * interface -- the only ACPI source for it, and
			 * the one a version 2 machine with tables and no
			 * tree has nothing else to go on.
			 *
			 * GICR Base Address at offset 60 is this cpu's
			 * redistributor, for parts that have no discovery
			 * range.  Only taken when the GICR entry did not
			 * appear, because the range is the better answer:
			 * it describes every redistributor and this one
			 * describes one cpu's.
			 */
			if(n >= 40 && giccbase == 0)
				giccbase = le64(p+32);
			if(n >= 76 && ngicr == 0 && le64(p+60) != 0){
				gicrbase[0] = le64(p+60);
				gicrlen[0] = 0;	/* one frame, size unstated */
				ngicr = 1;
			}
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
 * node, named by an offset from the start of the table.  A mapping that
 * points at an ITS group is the end of the walk.  One that points at an
 * SMMU is not: the requester's DeviceID is then the composition of two
 * mappings, the root complex's requester-id-to-StreamID and the SMMU's
 * StreamID-to-DeviceID, and the result is the intersection of the two
 * ranges rather than either of them.  A root complex can have both
 * kinds, which is exactly what QEMU's -M virt,iommu=smmuv3 produces and
 * what an Ampere Altra has.
 *
 * So this keeps a list of windows rather than one window.  Composing is
 * not optional on a machine like that: QEMU's direct window covers
 * 0x100..0xffff and every device on bus 0 is below it, so a board that
 * read only the direct window refused them all and they fell back to
 * INTx -- correctly, and silently.
 */

enum {
	Nwindow		= 16,		/* composed windows kept */
	Smsingle	= 1<<0,		/* mapping flags: Single Mapping */
};

static struct {
	ulong	rid;			/* first requester id covered */
	ulong	count;			/* how many */
	ulong	devid;			/* what the first one becomes */
	int	single;			/* every rid maps to devid, not devid+i */
	int	viasmmu;		/* composed through an SMMU */
} window[Nwindow];
static int	nwindow;
static int	windowlost;		/* more than Nwindow of them */
static int	smmuskipped;		/* a mapping shape not composed */

static void
addwindow(ulong rid, ulong count, ulong devid, int single, int viasmmu)
{
	if(count == 0)
		return;
	if(nwindow >= Nwindow){
		windowlost++;
		return;
	}
	window[nwindow].rid = rid;
	window[nwindow].count = count;
	window[nwindow].devid = devid;
	window[nwindow].single = single;
	window[nwindow].viasmmu = viasmmu;
	nwindow++;
}

/*
 * Which of an SMMUv3 node's mappings is the SMMU's own MSI DeviceID
 * rather than a translation for the devices behind it, or -1 when none
 * is.  Composing that one maps device traffic onto the SMMU's own event
 * vector.
 *
 * Three conditions, all of them from the spec and all of them load
 * bearing on the machine in front of this: the field only exists from
 * node revision 1, it is ignored when all four of the SMMU's control
 * interrupts are wired (which is how QEMU's virt wires them -- event
 * 106, PRI 107, GERR 109, sync 108, so the index of 0 in its table is
 * not an index at all and taking it would have discarded the only
 * mapping the node has), and it has to be inside the mapping array.
 */
static int
smmudidindex(uchar *node, uint len, uint nmap)
{
	uint idx;

	if(node[0] != Iortsmmuv3 || node[3] < 1 || len < 68)
		return -1;
	if(le32(node+44) != 0 && le32(node+48) != 0 &&
	   le32(node+52) != 0 && le32(node+56) != 0)
		return -1;
	idx = le32(node+64);
	if(idx >= nmap)
		return -1;
	return (int)idx;
}

/*
 * Compose one root-complex mapping with the mappings of the SMMU node
 * it points at.
 *
 * The root complex turns requester ids [rid, rid+count) into StreamIDs
 * [sid, sid+count).  Each of the SMMU's mappings turns StreamIDs
 * [sb, sb+n) into DeviceIDs [db, db+n).  What comes out is one window
 * per overlapping pair, and the overlap is computed rather than assumed:
 * on QEMU the root complex offers 0..0xff and the SMMU accepts
 * 0..0xffff, so the answer is 0..0xff, but an Altra's SMMU is one of
 * several and each accepts a slice.
 */
static void
compose(uchar *e, uchar *smmu, ulong rid, ulong count, ulong sid)
{
	uchar *map;
	uint nmap, mapoff, len, j;
	int didx;
	ulong sb, n, db, lo, hi;

	len = le16(smmu+1);
	nmap = le32(smmu+8);
	mapoff = le32(smmu+12);
	if(mapoff == 0 || smmu + mapoff > e)
		return;
	didx = smmudidindex(smmu, len, nmap);
	for(j = 0; j < nmap; j++){
		if((int)j == didx)
			continue;
		map = smmu + mapoff + j*20;
		if(map + 20 > e)
			break;
		db = le32(map+8);
		if(le32(map+16) & Smsingle){
			/*
			 * Every StreamID the SMMU sees becomes one
			 * DeviceID, so every requester id in this
			 * mapping does too.  Input base and count are
			 * meaningless when this bit is set and reading
			 * them as a range gives a one-requester window
			 * that looks plausible.
			 */
			addwindow(rid, count, db, 1, 1);
			continue;
		}
		sb = le32(map+0);
		n = (ulong)le32(map+4) + 1;
		lo = sid > sb ? sid : sb;
		hi = sid + count < sb + n ? sid + count : sb + n;
		if(lo >= hi)
			continue;
		addwindow(rid + (lo - sid), hi - lo, db + (lo - sb), 0, 1);
	}
}

static void
iort(void)
{
	extern void *acpitable(char*);
	extern uint acpitablen(void*);
	uchar *t, *e, *node, *map, *out;
	uint nnode, off, nmap, mapoff, outref;
	int i, j;
	ulong rid, count, ob;

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
			outref = le32(map+12);
			if(outref == 0 || t + outref + 16 > e)
				continue;
			out = t + outref;
			rid = le32(map+0);
			count = (ulong)le32(map+4) + 1;
			ob = le32(map+8);
			if(le32(map+16) & Smsingle){
				/*
				 * A root complex with Single Mapping set has
				 * no requester range to compose: every id it
				 * produces is one output, and the table does
				 * not say which ids it produces.  Counted and
				 * reported rather than guessed at.
				 */
				smmuskipped++;
				continue;
			}
			if(out[0] == Iortits)
				addwindow(rid, count, ob, 0, 0);
			else if(out[0] == Iortsmmuv3 || out[0] == Iortsmmu)
				compose(e, out, rid, count, ob);
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

/* how many of the windows came through an SMMU */
static int
smmucomposed(void)
{
	int i, n;

	for(n = 0, i = 0; i < nwindow; i++)
		if(window[i].viasmmu)
			n++;
	return n;
}

void
acpireport(void)
{
	int i;

	if(!tablesfound){
		if(bootconfline("*acpi=") != nil)
			print("acpi: the rsdp the loader passed is not one\n");
		return;
	}
	print("%s\n", sigline);
	if(gicdbase != 0)
		print("acpi: madt gicv%d dist @ %#llux\n",
			gicversion, gicdbase);
	for(i = 0; i < ngicr; i++)
		print("acpi: madt redist %d @ %#llux size %#llux\n",
			i, gicrbase[i], gicrlen[i]);
	if(gicrlost > 0)
		print("acpi: madt has %d more redistributor range(s) than this"
			" board keeps\n", gicrlost);
	if(giccbase != 0)
		print("acpi: madt gicc @ %#llux\n", giccbase);
	if(gicitsbase != 0)
		print("acpi: madt its @ %#llux, ACPI-ITS-OK\n", gicitsbase);
	for(i = 0; i < nwindow; i++){
		if(window[i].single)
			print("acpi: iort rid %#lux..%#lux -> devid %#lux for all"
				" via smmu, ACPI-IORT-OK\n",
				window[i].rid, window[i].rid + window[i].count - 1,
				window[i].devid);
		else
			print("acpi: iort rid %#lux..%#lux -> devid %#lux%s,"
				" ACPI-IORT-OK\n",
				window[i].rid, window[i].rid + window[i].count - 1,
				window[i].devid,
				window[i].viasmmu ? " via smmu" : "");
	}
	if(nwindow > 0 && smmucomposed())
		print("acpi: iort composed %d of %d window(s) through an smmu,"
			" ACPI-IORT-SMMU-OK\n", smmucomposed(), nwindow);
	if(windowlost > 0)
		print("acpi: iort has %d more window(s) than this board keeps;"
			" those requesters keep intx\n", windowlost);
	if(smmuskipped > 0)
		print("acpi: iort has %d mapping(s) in a shape this board does"
			" not compose; those requesters keep intx\n", smmuskipped);
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
	if(gicdbase == 0 && gicitsbase == 0 && nwindow == 0)
		print("acpi: tables carry nothing this board reads\n");
}

/*
 * What the rest of the board asks.  Each returns 0 or nil when ACPI
 * said nothing, and every caller falls back to the device tree or to
 * mem.h -- which is why none of these can break a board that has no
 * tables.
 */
/*
 * The GIC the MADT describes, for trap.c to use rather than print.
 * Zero for anything the tables did not carry, and the caller falls back
 * one source at a time -- a MADT with a distributor and no cpu
 * interface is an ordinary GICv3 table, not a broken one.
 */
int
acpigic(uvlong *d, uvlong *c, int *version)
{
	if(gicdbase == 0)
		return 0;
	*d = gicdbase;
	*c = giccbase;
	*version = gicversion;
	return 1;
}

/*
 * The redistributor ranges, one call per range.  Separate from
 * acpigic() because a machine can have several and because the caller
 * walks the frames inside them: a length of zero means the MADT gave a
 * single redistributor rather than a range, which is what a GICC entry
 * carries, and the caller treats that as one frame.
 */
int
acpinredist(void)
{
	return ngicr;
}

int
acpiredist(int i, uvlong *base, uvlong *len)
{
	if(i < 0 || i >= ngicr)
		return 0;
	*base = gicrbase[i];
	*len = gicrlen[i];
	return 1;
}

uvlong
acpiits(void)
{
	return gicitsbase;
}

/*
 * How many windows the IORT gave, and what a requester id becomes.
 *
 * Two calls rather than one because the caller has to be able to tell
 * "the table says nothing, fall back" from "the table says this
 * requester is not covered".  They are not the same answer: a board
 * with no IORT uses the identity, which is right often enough to boot,
 * and a board whose IORT does not cover a requester must refuse it --
 * a DeviceID wrong by a constant is an interrupt delivered to another
 * device's vector, where refusing costs that one device MSI.
 *
 * The lookup takes a requester id and nothing else, which is the limit
 * worth stating: an IORT can have several root complexes distinguished
 * by PCI segment number, and this collapses them into one list.  On a
 * machine with one segment -- QEMU, and a single-socket Altra -- that
 * is the same thing.  On a multi-segment machine it is not, and the
 * segment would have to come down from the PCI code, which does not
 * carry one.
 */
int
acpinwindow(void)
{
	return nwindow;
}

int
acpiridtodevid(ulong rid, ulong *devid)
{
	int i;

	for(i = 0; i < nwindow; i++){
		if(rid < window[i].rid || rid >= window[i].rid + window[i].count)
			continue;
		if(window[i].single)
			*devid = window[i].devid;
		else
			*devid = window[i].devid + (rid - window[i].rid);
		return 1;
	}
	return 0;
}
