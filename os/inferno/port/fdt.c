#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * A flattened-device-tree reader.  QEMU hands the kernel a DTB at boot
 * (in x0 on arm64, a1 on riscv), and a real board's addresses vary
 * where the QEMU virt machines' are fixed - so a board can find its
 * UART, its virtio and PCI windows, and its interrupt controller here
 * instead of naming them as constants in mem.h.  This is only the
 * reader; wiring a board to use it in place of its constants is done
 * per board.
 *
 * The format (devicetree.org's specification): a big-endian header,
 * then a structure block of tokens - BEGINNODE(1), ENDNODE(2),
 * PROP(3), NOP(4), END(9) - and a strings block the property names
 * point into.  Everything multi-byte is big-endian; #address-cells
 * and #size-cells (default 2 each) give the width of a reg entry's
 * base and size.
 */

enum {
	FdtMagic	= 0xd00dfeed,
	TBeginNode	= 1,
	TEndNode	= 2,
	TProp		= 3,
	TNop		= 4,
	TEnd		= 9,
};

typedef struct Fdthdr Fdthdr;
struct Fdthdr {
	u32int	magic;
	u32int	totalsize;
	u32int	off_dt_struct;
	u32int	off_dt_strings;
	u32int	off_mem_rsvmap;
	u32int	version;
	u32int	last_comp_version;
	u32int	boot_cpuid_phys;
	u32int	size_dt_strings;
	u32int	size_dt_struct;
};

static void *fdt;		/* the DTB, saved by the board's boot code */

static u32int
be32(void *p)
{
	uchar *b = p;
	return (u32int)b[0]<<24 | (u32int)b[1]<<16 | (u32int)b[2]<<8 | b[3];
}

static uvlong
fdtbecells(uchar *p, int cells)
{
	uvlong v;

	v = 0;
	while(cells-- > 0){
		v = (v<<32) | be32(p);
		p += 4;
	}
	return v;
}

/* the board hands us the pointer it captured at boot */
void
fdtinit(void *dtb)
{
	Fdthdr *h;

	h = dtb;
	if(h == nil || be32(&h->magic) != FdtMagic)
		return;
	fdt = dtb;
}

int
fdtvalid(void)
{
	return fdt != nil;
}

static char*
fdtstrat(u32int off)
{
	Fdthdr *h = fdt;
	return (char*)fdt + be32(&h->off_dt_strings) + off;
}

/*
 * Walk the structure block.  For each node track its depth and read
 * its #address-cells/#size-cells; call the visitor with the node name,
 * its property list start, and the cell widths inherited from the
 * parent.  A visitor that returns non-zero stops the fdtwalk and that
 * value is returned.
 */
static uintptr
fdtwalk(uintptr (*visit)(char *name, uchar *props, int acells, int scells, void *a), void *a)
{
	Fdthdr *h = fdt;
	uchar *p, *e;
	char *name;
	int depth, ac[32], sc[32];
	uintptr r;

	if(fdt == nil)
		return 0;
	p = (uchar*)fdt + be32(&h->off_dt_struct);
	e = p + be32(&h->size_dt_struct);
	depth = 0;
	ac[0] = 2;
	sc[0] = 2;
	while(p+4 <= e){
		switch(be32(p)){
		case TBeginNode:
			p += 4;
			name = (char*)p;
			p += (strlen(name)+4) & ~3;
			depth++;
			if(depth < nelem(ac)){
				ac[depth] = ac[depth-1];
				sc[depth] = sc[depth-1];
			}
			if(visit != nil){
				r = (*visit)(name, p, depth>0?ac[depth-1]:2, depth>0?sc[depth-1]:2, a);
				if(r != 0)
					return r;
			}
			break;
		case TProp:
			{
				u32int len, noff;
				char *pn;
				len = be32(p+4);
				noff = be32(p+8);
				pn = fdtstrat(noff);
				if(depth < nelem(ac)){
					if(strcmp(pn, "#address-cells") == 0)
						ac[depth] = be32(p+12);
					else if(strcmp(pn, "#size-cells") == 0)
						sc[depth] = be32(p+12);
				}
				p += 12 + ((len+3) & ~3);
			}
			break;
		case TEndNode:
			p += 4;
			if(depth > 0)
				depth--;
			break;
		case TNop:
			p += 4;
			break;
		case TEnd:
			return 0;
		default:
			return 0;	/* malformed */
		}
	}
	return 0;
}

/* a property's value within a node's property list, or nil */
static uchar*
fdtprop(uchar *props, char *want, u32int *plen)
{
	Fdthdr *h = fdt;
	uchar *p;
	int depth;

	p = props;
	depth = 0;
	while(p != nil){
		switch(be32(p)){
		case TProp:
			{
				u32int len, noff;
				len = be32(p+4);
				noff = be32(p+8);
				if(depth == 0 && strcmp(fdtstrat(noff), want) == 0){
					if(plen != nil)
						*plen = len;
					return p+12;
				}
				p += 12 + ((len+3) & ~3);
			}
			break;
		case TBeginNode:
			depth++;
			p += 4;
			p += (strlen((char*)p)+4) & ~3;
			break;
		case TEndNode:
			if(depth == 0)
				return nil;	/* end of this node's own props */
			depth--;
			p += 4;
			break;
		case TNop:
			p += 4;
			break;
		default:
			return nil;
		}
		USED(h);
	}
	return nil;
}

typedef struct Findc Findc;
struct Findc {
	char	*compat;
	uvlong	base;
	uvlong	size;
	int	found;
};

static uintptr
matchcompat(char *name, uchar *props, int acells, int scells, void *a)
{
	Findc *f = a;
	uchar *cv, *rv;
	u32int clen, rlen;
	char *c, *ce;

	USED(name);
	cv = fdtprop(props, "compatible", &clen);
	if(cv == nil)
		return 0;
	/* compatible is a list of null-terminated strings */
	c = (char*)cv;
	ce = c + clen;
	for(; c < ce; c += strlen(c)+1){
		if(strcmp(c, f->compat) != 0)
			continue;
		rv = fdtprop(props, "reg", &rlen);
		if(rv == nil || rlen < (u32int)(acells+scells)*4)
			return 0;
		f->base = fdtbecells(rv, acells);
		f->size = fdtbecells(rv + acells*4, scells);
		f->found = 1;
		return 1;
	}
	return 0;
}

/*
 * Find the first node whose compatible list contains compat and read
 * its reg base and size.  Returns 1 and fills *base/*size, else 0.
 */
int
fdtreg(char *compat, uvlong *base, uvlong *size)
{
	Findc f;

	memset(&f, 0, sizeof f);
	f.compat = compat;
	fdtwalk(matchcompat, &f);
	if(!f.found)
		return 0;
	if(base != nil)
		*base = f.base;
	if(size != nil)
		*size = f.size;
	return 1;
}

/*
 * Like matchcompat, but never stops the walk (returns 0 always) and
 * keeps the lowest base seen, so fdtregmin can visit every matching
 * node.  Used where one compatible names several instances - QEMU's
 * eight virtio-mmio slots - and the caller wants the base of the first
 * to scan upward from, which the DTB may list last.
 */
static uintptr
matchcompatmin(char *name, uchar *props, int acells, int scells, void *a)
{
	Findc *f = a;
	uchar *cv, *rv;
	u32int clen, rlen;
	char *c, *ce;
	uvlong b;

	USED(name);
	cv = fdtprop(props, "compatible", &clen);
	if(cv == nil)
		return 0;
	c = (char*)cv;
	ce = c + clen;
	for(; c < ce; c += strlen(c)+1){
		if(strcmp(c, f->compat) != 0)
			continue;
		rv = fdtprop(props, "reg", &rlen);
		if(rv == nil || rlen < (u32int)(acells+scells)*4)
			return 0;
		b = fdtbecells(rv, acells);
		if(!f->found || b < f->base){
			f->base = b;
			f->size = fdtbecells(rv + acells*4, scells);
			f->found = 1;
		}
		return 0;	/* keep walking to see the other instances */
	}
	return 0;
}

/*
 * The lowest reg base among all nodes whose compatible list contains
 * compat.  Returns 1 and fills *base/*size from that node, else 0.
 */
int
fdtregmin(char *compat, uvlong *base, uvlong *size)
{
	Findc f;

	memset(&f, 0, sizeof f);
	f.compat = compat;
	fdtwalk(matchcompatmin, &f);
	if(!f.found)
		return 0;
	if(base != nil)
		*base = f.base;
	if(size != nil)
		*size = f.size;
	return 1;
}

typedef struct Findm Findm;
struct Findm {
	uvlong	base;
	uvlong	size;
	int	found;
	int	nbank;
};

/*
 * /memory nodes are not found by compatible: they carry
 * device_type = "memory" and no compatible property at all, so
 * matchcompat walks straight past them.  Keep the lowest base seen
 * and total the sizes of every bank at that base or above, which on
 * a QEMU virt machine is the single bank -m gave it.
 */
static uintptr
matchmem(char *name, uchar *props, int acells, int scells, void *a)
{
	Findm *f = a;
	uchar *dv, *rv;
	u32int dlen, rlen;
	uvlong base, size;

	USED(name);
	dv = fdtprop(props, "device_type", &dlen);
	if(dv == nil || dlen < 7 || strcmp((char*)dv, "memory") != 0)
		return 0;
	rv = fdtprop(props, "reg", &rlen);
	if(rv == nil || rlen < (u32int)(acells+scells)*4)
		return 0;
	base = fdtbecells(rv, acells);
	size = fdtbecells(rv + acells*4, scells);
	if(size == 0)
		return 0;
	if(!f->found || base < f->base)
		f->base = base;
	f->size += size;
	f->found = 1;
	f->nbank++;
	return 0;	/* keep walking: a board may have several banks */
}

/*
 * The lowest base and the total size of RAM as the tree describes it.
 * Returns the number of banks it summed -- 0 if the tree names no
 * memory -- because base and size describe one contiguous extent only
 * when that count is 1.  A caller that hands the pair to an allocator
 * must check it: every QEMU -M virt tree from -m 256 to -m 16G has a
 * single memory@40000000, but a board with two banks would otherwise
 * have the hole between them handed out as RAM.
 */
int
fdtmemory(uvlong *base, uvlong *size)
{
	Findm f;

	memset(&f, 0, sizeof f);
	fdtwalk(matchmem, &f);
	if(!f.found)
		return 0;
	if(base != nil)
		*base = f.base;
	if(size != nil)
		*size = f.size;
	return f.nbank;
}
