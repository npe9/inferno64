#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * ACPI tables, found by signature.
 *
 * This is the portable half of reading ACPI on a board that is handed
 * an RSDP rather than having to go looking for one.  os/inferno/pc's
 * archacpi.c does the x86 version of the same job and is not shared:
 * it scans the BIOS area for the pointer, maps every table through
 * vmap(), checks each against the e820 map, and carries the whole AML
 * interpreter behind it.  None of that applies here.  A SystemReady
 * machine hands the pointer to the boot loader, which hands it to the
 * kernel, and the tables are ordinary memory in the map the firmware
 * already described.
 *
 * Like os/inferno/port/fdt.c, this runs before mmuinit() and before
 * print() -- addresses are physical because the MMU is still off --
 * so it reads, records and says nothing.  The board reports later.
 *
 * Every table is checksummed before it is believed, including the RSDP
 * itself, which has two checksums: the first twenty bytes for the
 * ACPI 1.0 part and the whole thing for 2.0 and up.  A firmware that
 * hands over a table that does not sum is a firmware whose table
 * contents are not worth reading, and saying so is better than
 * deriving a GIC base from rubbish.
 */

typedef struct Rsdp Rsdp;
typedef struct Acpitbl Acpitbl;

struct Rsdp {
	uchar	sig[8];			/* "RSD PTR " */
	uchar	csum;			/* of the first 20 bytes */
	uchar	oemid[6];
	uchar	rev;			/* 0 for 1.0, 2 for 2.0 and up */
	uchar	rsdt[4];		/* 32-bit table pointer */
	uchar	len[4];			/* of the whole structure */
	uchar	xsdt[8];		/* 64-bit table pointer */
	uchar	xcsum;			/* of the whole structure */
	uchar	pad[3];
};

struct Acpitbl {
	uchar	sig[4];
	uchar	len[4];
	uchar	rev;
	uchar	csum;
	uchar	oemid[6];
	uchar	oemtid[8];
	uchar	oemrev[4];
	uchar	cid[4];
	uchar	crev[4];
	uchar	data[];
};

enum {
	Hdrlen	= 36,			/* an Acpitbl up to data[] */
	Maxtbl	= 1<<20,		/* nothing sane is bigger */
};

static uchar	*sdt;			/* the XSDT, or the RSDT */
static int	sdtwide;		/* 8-byte entries, not 4 */
static int	nsdt;			/* how many entries it has */
static int	acpirev;

static uint
le32(uchar *p)
{
	return (uint)p[0] | (uint)p[1]<<8 | (uint)p[2]<<16 | (uint)p[3]<<24;
}

static uvlong
le64(uchar *p)
{
	return (uvlong)le32(p) | (uvlong)le32(p+4)<<32;
}

static int
sums(uchar *p, int n)
{
	uchar s;

	for(s = 0; --n >= 0; p++)
		s += *p;
	return s == 0;
}

/*
 * Believe the pointer the loader passed only as far as it checks out.
 * The signature, then the checksum, then the table it names.
 */
void
acpiinit(uintptr pa)
{
	Rsdp *r;
	uchar *t;
	uvlong tpa;
	uint len;

	sdt = nil;
	nsdt = 0;
	if(pa == 0)
		return;
	r = (Rsdp*)pa;
	if(memcmp(r->sig, "RSD PTR ", 8) != 0)
		return;
	if(!sums((uchar*)r, 20))
		return;
	acpirev = r->rev;
	if(r->rev >= 2){
		if(!sums((uchar*)r, le32(r->len)))
			return;
		tpa = le64(r->xsdt);
		sdtwide = 1;
	} else {
		tpa = le32(r->rsdt);
		sdtwide = 0;
	}
	if(tpa == 0)
		return;
	t = (uchar*)(uintptr)tpa;
	if(memcmp(t, sdtwide ? "XSDT" : "RSDT", 4) != 0)
		return;
	len = le32(t+4);
	if(len < Hdrlen || len > Maxtbl || !sums(t, len))
		return;
	sdt = t;
	nsdt = (len - Hdrlen) / (sdtwide ? 8 : 4);
}

int
acpivalid(void)
{
	return sdt != nil;
}

int
acpirevision(void)
{
	return acpirev;
}

/*
 * The first table with this signature whose own checksum is good.
 * nil when there is none, which is the answer a board acts on: every
 * caller here falls back to what it would have used anyway.
 */
void*
acpitable(char *sig)
{
	uchar *p, *t;
	uvlong tpa;
	uint len;
	int i;

	if(sdt == nil)
		return nil;
	for(i = 0; i < nsdt; i++){
		p = sdt + Hdrlen + i*(sdtwide ? 8 : 4);
		tpa = sdtwide ? le64(p) : le32(p);
		if(tpa == 0)
			continue;
		t = (uchar*)(uintptr)tpa;
		if(memcmp(t, sig, 4) != 0)
			continue;
		len = le32(t+4);
		if(len < Hdrlen || len > Maxtbl)
			continue;
		if(!sums(t, len))
			continue;
		return t;
	}
	return nil;
}

/*
 * The signature of the i'th table, or nil past the end.  For a board
 * that wants to say what the firmware actually handed it, which is the
 * first thing worth knowing when a table that should be there is not.
 */
char*
acpisig(int i, char buf[5])
{
	uchar *p, *t;
	uvlong tpa;

	if(sdt == nil || i < 0 || i >= nsdt)
		return nil;
	p = sdt + Hdrlen + i*(sdtwide ? 8 : 4);
	tpa = sdtwide ? le64(p) : le32(p);
	if(tpa == 0)
		return nil;
	t = (uchar*)(uintptr)tpa;
	memmove(buf, t, 4);
	buf[4] = 0;
	return buf;
}

/*
 * How long a table is, for a caller walking the entries inside it.
 */
uint
acpitablen(void *t)
{
	if(t == nil)
		return 0;
	return le32((uchar*)t + 4);
}
