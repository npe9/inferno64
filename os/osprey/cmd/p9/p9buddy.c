#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"p9file.h"

/*
 * The buddy operating system's syscall emulation, in the paper's sense:
 * an unmodified Plan 9 binary runs in a container of its own and traps in
 * the Plan 9 system-call ABI; the microkernel forwards each trap to this
 * peer, which emulates the syscall against its own name space and file-
 * descriptor table - open, read, write, close - and hands the answer
 * back.  The legacy binary never knows a peer served it.  This is per-
 * process interposition (the buddy holds the descriptor table that stands
 * for the legacy process's), not a shared server.  For the Linux binary
 * it interposes page faults too: the binary is a file in this
 * personality's file system, this buddy lays it out for the kernel (EXEC)
 * and supplies each page as the process first touches it (PAGE).  The
 * Plan 9 legacy binary is still eager-mapped by the kernel.
 *
 * The kernel has copied any pointer argument (a name, a data buffer) into
 * the legacy container's data area, which this peer reaches as cdata; the
 * handler reads names from there and writes read data back there.
 */

enum {
	/* Plan 9 amd64 system-call numbers (os/osprey/port/sys.h) */
	CLOSE	= 4,
	OPEN	= 14,
	_READ	= 15,
	OSEEK	= 16,
	_WRITE	= 20,
	SEEK	= 39,
	PREAD	= 50,
	PWRITE	= 51,

	/*
	 * Not system calls: the kernel's requests for the legacy process's
	 * image, numbered above any Plan 9 system call.  EXEC lays the
	 * binary out from this personality's file system; PAGE supplies one
	 * page of it, which is how a page fault reaches the buddy.
	 */
	EXEC	= 100,
	PAGE	= 101,
	Maxph	= 8,		/* loadable program headers kept */
	Pagesz	= 4096,

	Argoff	= 64,		/* where the kernel left the arg block, in cdata */
	Nameoff	= 256,		/* where the kernel left a name, in cdata */
	Dataoff	= 1024,		/* where read/write data goes, in cdata */
};

/*
 * The legacy image this buddy is loader and pager for: the file, open in
 * this personality's descriptor table for as long as the process runs,
 * its entry, and its loadable program headers.
 */
static struct {
	int	fd;
	uvlong	entry;
	int	nph;
	struct {
		uvlong	off, va, filesz, memsz, flags;
	} ph[Maxph];
} img = { -1 };

static uvlong
le(uchar *p, int n)
{
	uvlong v;
	int i;

	v = 0;
	for(i = n-1; i >= 0; i--)
		v = (v<<8) | p[i];
	return v;
}

/* read exactly n bytes at off, or fail */
static int
readat(int fd, vlong off, uchar *buf, long n)
{
	long r, got;

	p9seek(fd, off, 0);
	for(got = 0; got < n; got += r){
		r = p9read(fd, buf+got, n-got);
		if(r <= 0)
			return -1;
	}
	return 0;
}

/*
 * EXEC: open the named file in this personality's name space, read the
 * ELF header and the program headers, keep the loadable ones, and write
 * the layout for the kernel at out: entry, the count, then each
 * segment's address, memory size and flags.  Returns the count, or -1.
 */
static long
p9buddy_exec(char *name, uchar *out)
{
	uchar hdr[64], ph[56];
	uvlong phoff, *d;
	int phentsize, phnum, i;

	if(img.fd >= 0){
		p9close(img.fd);
		img.fd = -1;
	}
	if(waserror()){
		print("buddy: exec %s: %s\n", name, up->errstr);
		return -1;
	}
	img.fd = p9open(name, 0);
	poperror();
	if(readat(img.fd, 0, hdr, sizeof hdr) < 0 || hdr[0] != 0x7f || hdr[1] != 'E')
		return -1;
	img.entry = le(hdr+24, 8);
	phoff = le(hdr+32, 8);
	phentsize = le(hdr+54, 2);
	phnum = le(hdr+56, 2);
	img.nph = 0;
	for(i = 0; i < phnum && img.nph < Maxph; i++){
		if(readat(img.fd, phoff + (uvlong)i*phentsize, ph, sizeof ph) < 0)
			return -1;
		if(le(ph, 4) != 1)		/* PT_LOAD */
			continue;
		img.ph[img.nph].flags = le(ph+4, 4);
		img.ph[img.nph].off = le(ph+8, 8);
		img.ph[img.nph].va = le(ph+16, 8);
		img.ph[img.nph].filesz = le(ph+32, 8);
		img.ph[img.nph].memsz = le(ph+40, 8);
		img.nph++;
	}
	d = (uvlong*)out;
	d[0] = img.entry;
	d[1] = img.nph;
	for(i = 0; i < img.nph; i++){
		d[2+3*i] = img.ph[i].va;
		d[3+3*i] = img.ph[i].memsz;
		d[4+3*i] = img.ph[i].flags;
	}
	print("buddy: exec %s: entry %#llux, %d loadable segments\n", name, img.entry, img.nph);
	return img.nph;
}

/*
 * PAGE: the page of the image at va, into out - zero throughout, then
 * the file's bytes wherever a loadable header has them in this page.
 * Returns 0 when some header covers the page and -1 when none does, in
 * which case the address is the legacy process's own bad one.
 */
static long
p9buddy_page(uvlong va, uchar *out)
{
	uvlong lo, hi, fend;
	int i, found;

	memset(out, 0, Pagesz);
	if(img.fd < 0)
		return -1;
	found = 0;
	for(i = 0; i < img.nph; i++){
		if(va + Pagesz <= img.ph[i].va || va >= img.ph[i].va + img.ph[i].memsz)
			continue;
		found = 1;
		lo = va > img.ph[i].va ? va : img.ph[i].va;
		fend = img.ph[i].va + img.ph[i].filesz;
		hi = va + Pagesz < fend ? va + Pagesz : fend;
		if(lo < hi && readat(img.fd, img.ph[i].off + (lo - img.ph[i].va), out + (lo - va), hi - lo) < 0)
			return -1;
	}
	if(found)
		print("buddy: page %#llux of the legacy image supplied from its file\n", va);
	return found ? 0 : -1;
}

/*
 * Serve one forwarded Plan 9 system call.  scallnr is the trap number;
 * a0..a2 are its scalar arguments (a descriptor, a count, an offset, a
 * mode); cdata is the legacy container's data area.  Returns the value
 * the system call yields, which the kernel puts back in the legacy
 * process's result register.
 */
long
p9buddy_syscall(uvlong scallnr, uvlong a0, uvlong a1, uvlong a2, uchar *cdata)
{
	long r;

	switch(scallnr){
	case EXEC:
		/* lay out the binary named at cdata[Nameoff]; layout to cdata[Dataoff] */
		r = p9buddy_exec((char*)(cdata + Nameoff), cdata + Dataoff);
		break;

	case PAGE:
		/* the image's page at a0, to cdata[Dataoff] */
		r = p9buddy_page(a0, cdata + Dataoff);
		break;

	case OPEN:
		/* open(name, mode): name at cdata[Nameoff], mode a1 */
		r = p9open((char*)(cdata + Nameoff), (int)a1);
		break;

	case CLOSE:
		p9close((int)a0);
		r = 0;
		break;

	case _READ:
		/* read(fd, buf, n): fd a0, n a1; data to cdata[Dataoff] */
		r = p9read((int)a0, cdata + Dataoff, (long)a1);
		break;

	case PREAD:
		/* pread(fd, buf, n, off): fd a0, n a1, off a2 */
		if((vlong)a2 >= 0)
			p9seek((int)a0, (vlong)a2, 0);
		r = p9read((int)a0, cdata + Dataoff, (long)a1);
		break;

	case _WRITE:
		/* write(fd, buf, n): data already at cdata[Dataoff] */
		r = p9write((int)a0, cdata + Dataoff, (long)a1);
		break;

	case PWRITE:
		if((vlong)a2 >= 0)
			p9seek((int)a0, (vlong)a2, 0);
		r = p9write((int)a0, cdata + Dataoff, (long)a1);
		break;

	case SEEK:
	case OSEEK:
		r = (long)p9seek((int)a0, (vlong)a1, (int)a2);
		break;

	default:
		r = -1;		/* a trap this buddy does not emulate */
		break;
	}
	return r;
}

/*
 * Plain-typed entry the user-header ring loop calls.  The kernel left the
 * forwarded call's number and scalar arguments as a block of uvlongs at
 * cdata[Argoff]: number, then the three scalars.
 */
long
p9buddy_serve(uchar *cdata)
{
	uvlong *ab;

	ab = (uvlong*)(cdata + Argoff);
	return p9buddy_syscall(ab[0], ab[1], ab[2], ab[3], cdata);
}
