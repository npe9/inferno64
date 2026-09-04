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
 * and supplies each page as the process first touches it (PAGE), and
 * the same for a Plan 9 a.out, laid out as three pieces of the shape an
 * ELF's program headers take.
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
	CREATE	= 22,
	REMOVE	= 25,
	FSTAT	= 43,

	/*
	 * Not system calls: the kernel's requests for the legacy process's
	 * image, numbered above any Plan 9 system call.  EXEC lays the
	 * binary out from this personality's file system; PAGE supplies one
	 * page of it, which is how a page fault reaches the buddy.
	 */
	EXEC	= 100,
	PAGE	= 101,
	MAPPAGE	= 102,		/* a page of a file the process mapped */
	Nfd	= 16,		/* descriptors a legacy process may hold */
	Fdcons	= -2,		/* 0, 1 and 2: the console, which this personality has no file for */
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
typedef struct Img Img;
struct Img {
	uvlong	container;	/* whose image this is; 0 when free */
	int	fds[Nfd];	/* the process's descriptors: this personality's fd each stands for */
	int	fd;
	int	kind;		/* 0 an ELF, 1 a Plan 9 a.out */
	uvlong	entry;
	int	nph;
	struct {
		uvlong	off, va, filesz, memsz, flags;
	} ph[Maxph];
};
enum { Nimg = 8 };
static Img imgs[Nimg];

/* the image of a container, making one when told to */
static Img*
imgof(uvlong container, int make)
{
	int i;

	for(i = 0; i < Nimg; i++)
		if(imgs[i].container == container)
			return &imgs[i];
	if(!make)
		return nil;
	for(i = 0; i < Nimg; i++)
		if(imgs[i].container == 0){
			int j;

			memset(&imgs[i], 0, sizeof imgs[i]);
			imgs[i].container = container;
			imgs[i].fd = -1;
			for(j = 0; j < Nfd; j++)
				imgs[i].fds[j] = j < 3 ? Fdcons : -1;
			return &imgs[i];
		}
	return nil;
}

static uvlong
be(uchar *p, int n)
{
	uvlong v;
	int i;

	v = 0;
	for(i = 0; i < n; i++)
		v = (v<<8) | p[i];
	return v;
}

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
p9buddy_exec(uvlong container, char *name, uchar *out)
{
	Img *img;
	uchar hdr[64], ph[56];
	uvlong phoff, *d;
	int phentsize, phnum, i;

	if((img = imgof(container, 1)) == nil)
		return -1;
	if(img->fd >= 0){
		p9close(img->fd);
		img->fd = -1;
	}
	if(waserror()){
		print("buddy: exec %s: %s\n", name, up->errstr);
		return -1;
	}
	img->fd = p9open(name, 0);
	poperror();
	if(readat(img->fd, 0, hdr, sizeof hdr) < 0)
		return -1;
	if(hdr[0] != 0x7f || hdr[1] != 'E'){
		/*
		 * A Plan 9 a.out: eight big-endian words - magic, text, data,
		 * bss, syms, entry, spsz, pcsz - and a 64-bit entry after them
		 * when the magic has HDR_MAGIC set, which amd64's does.  It
		 * is laid out the way the kernel's own loader lays one out:
		 * the text, header and all, at UTZERO (mem.h); the data on the next
		 * page after it; the bss on the page after that.  Presented
		 * to the kernel as three loadable pieces, the same shape an
		 * ELF's program headers take, so the kernel needs no second
		 * loader and pages both kinds the same way.
		 */
		uvlong magic, textsz, datasz, bsssz, hdrsz, tseg, adata, abss, ebss;
		enum { Utzero = 0x200000 };	/* UTZERO in the kernel's mem.h: the first user text address */

		magic = be(hdr, 4);
		if((magic & 0xffff) != 0x8a97){	/* amd64's magic */
			print("buddy: exec %s: neither an ELF nor an amd64 a.out\n", name);
			return -1;
		}
		textsz = be(hdr+4, 4);
		datasz = be(hdr+8, 4);
		bsssz = be(hdr+12, 4);
		hdrsz = (magic & 0x8000) ? 40 : 32;
		tseg = hdrsz + textsz;
		adata = (Utzero + tseg + Pagesz-1) & ~(uvlong)(Pagesz-1);
		abss = (adata + datasz + Pagesz-1) & ~(uvlong)(Pagesz-1);
		ebss = (adata + datasz + bsssz + Pagesz-1) & ~(uvlong)(Pagesz-1);
		img->kind = 1;
		img->entry = Utzero + hdrsz;
		img->nph = 3;
		img->ph[0].flags = 5; img->ph[0].off = 0;    img->ph[0].va = Utzero; img->ph[0].filesz = tseg;   img->ph[0].memsz = tseg;
		img->ph[1].flags = 6; img->ph[1].off = tseg; img->ph[1].va = adata;  img->ph[1].filesz = datasz; img->ph[1].memsz = datasz;
		img->ph[2].flags = 6; img->ph[2].off = 0;    img->ph[2].va = abss;   img->ph[2].filesz = 0;      img->ph[2].memsz = ebss - abss;
		d = (uvlong*)out;
		d[0] = img->entry;
		d[1] = img->kind;
		for(i = 0; i < img->nph; i++){
			d[2+3*i] = img->ph[i].va;
			d[3+3*i] = img->ph[i].memsz;
			d[4+3*i] = img->ph[i].flags;
		}
		print("buddy: exec %s for container %llud: a Plan 9 a.out, text %llud data %llud bss %llud\n",
			name, container, textsz, datasz, bsssz);
		return img->nph;
	}
	img->kind = 0;
	img->entry = le(hdr+24, 8);
	phoff = le(hdr+32, 8);
	phentsize = le(hdr+54, 2);
	phnum = le(hdr+56, 2);
	img->nph = 0;
	for(i = 0; i < phnum && img->nph < Maxph; i++){
		if(readat(img->fd, phoff + (uvlong)i*phentsize, ph, sizeof ph) < 0)
			return -1;
		if(le(ph, 4) != 1)		/* PT_LOAD */
			continue;
		img->ph[img->nph].flags = le(ph+4, 4);
		img->ph[img->nph].off = le(ph+8, 8);
		img->ph[img->nph].va = le(ph+16, 8);
		img->ph[img->nph].filesz = le(ph+32, 8);
		img->ph[img->nph].memsz = le(ph+40, 8);
		img->nph++;
	}
	d = (uvlong*)out;
	d[0] = img->entry;
	d[1] = img->kind;
	for(i = 0; i < img->nph; i++){
		d[2+3*i] = img->ph[i].va;
		d[3+3*i] = img->ph[i].memsz;
		d[4+3*i] = img->ph[i].flags;
	}
	print("buddy: exec %s for container %llud: entry %#llux, %d loadable segments\n",
		name, container, img->entry, img->nph);
	return img->nph;
}

/*
 * PAGE: the page of the image at va, into out - zero throughout, then
 * the file's bytes wherever a loadable header has them in this page.
 * Returns 0 when some header covers the page and -1 when none does, in
 * which case the address is the legacy process's own bad one.
 */
static long
p9buddy_page(uvlong container, uvlong va, uchar *out)
{
	Img *img;
	uvlong lo, hi, fend;
	int i, found;

	memset(out, 0, Pagesz);
	if((img = imgof(container, 0)) == nil || img->fd < 0)
		return -1;
	found = 0;
	for(i = 0; i < img->nph; i++){
		if(va + Pagesz <= img->ph[i].va || va >= img->ph[i].va + img->ph[i].memsz)
			continue;
		found = 1;
		lo = va > img->ph[i].va ? va : img->ph[i].va;
		fend = img->ph[i].va + img->ph[i].filesz;
		hi = va + Pagesz < fend ? va + Pagesz : fend;
		if(lo < hi && readat(img->fd, img->ph[i].off + (lo - img->ph[i].va), out + (lo - va), hi - lo) < 0)
			return -1;
	}
	if(found)
		print("buddy: page %#llux of the legacy image supplied from its file\n", va);
	return found ? 0 : -1;
}

/* a container has gone: let go of the image held for it */
void
p9buddy_gone(uvlong container)
{
	Img *img;

	int i;

	if((img = imgof(container, 0)) == nil)
		return;
	if(img->fd >= 0)
		p9close(img->fd);
	for(i = 3; i < Nfd; i++)
		if(img->fds[i] >= 0)
			p9close(img->fds[i]);
	memset(img, 0, sizeof *img);
}

/*
 * The process's descriptors are its own numbers, kept apart from this
 * personality's: 0, 1 and 2 are the console, which this personality has
 * no file for, so a read there is end of file and a write goes out the
 * way this personality's own prints do; the rest stand for files opened
 * here on the process's behalf.
 */
static int
fdof(Img *img, uvlong fd)
{
	if(img == nil || fd >= Nfd)
		return -1;
	return img->fds[fd];
}

static long
fdnew(Img *img, int bfd)
{
	int i;

	for(i = 3; i < Nfd; i++)
		if(img->fds[i] == -1){
			img->fds[i] = bfd;
			return i;
		}
	p9close(bfd);
	return -1;
}

/* the file's bytes at off, up to n, zero past its end; -1 for a bad descriptor */
static long
readupto(int bfd, vlong off, uchar *buf, long n)
{
	long got, r;

	memset(buf, 0, n);
	if(bfd < 0)
		return -1;
	p9seek(bfd, off, 0);
	for(got = 0; got < n; got += r){
		r = p9read(bfd, buf+got, n-got);
		if(r <= 0)
			break;
	}
	return got;
}

/*
 * Serve one forwarded Plan 9 system call.  scallnr is the trap number;
 * a0..a2 are its scalar arguments (a descriptor, a count, an offset, a
 * mode); cdata is the legacy container's data area.  Returns the value
 * the system call yields, which the kernel puts back in the legacy
 * process's result register.
 */
long
p9buddy_syscall(uvlong container, uvlong scallnr, uvlong a0, uvlong a1, uvlong a2, uchar *cdata)
{
	Img *img;
	long r;
	int bfd;

	img = imgof(container, 1);
	switch(scallnr){
	case MAPPAGE:
		/* the page of the process's file a0 at offset a1, to cdata[Dataoff] */
		r = readupto(fdof(img, a0), (vlong)a1, cdata + Dataoff, (long)a2) < 0 ? -1 : 0;
		break;

	case EXEC:
		/* lay out the binary named at cdata[Nameoff]; layout to cdata[Dataoff] */
		r = p9buddy_exec(container, (char*)(cdata + Nameoff), cdata + Dataoff);
		break;

	case PAGE:
		/* the image's page at a0, to cdata[Dataoff] */
		r = p9buddy_page(container, a0, cdata + Dataoff);
		break;

	case OPEN:
		/* open(name, mode): name at cdata[Nameoff], mode a1; the process's own number back */
		r = fdnew(img, p9open((char*)(cdata + Nameoff), (int)a1));
		break;

	case CLOSE:
		bfd = fdof(img, a0);
		if(bfd >= 0)
			p9close(bfd);
		if(bfd != -1)
			img->fds[a0] = a0 < 3 ? Fdcons : -1;
		r = bfd == -1 ? -1 : 0;
		break;

	case _READ:
	case PREAD:
		/* read(fd, buf, n) / pread(fd, buf, n, off): data to cdata[Dataoff] */
		bfd = fdof(img, a0);
		if(bfd == Fdcons)
			r = 0;			/* end of file on the console */
		else if(bfd < 0)
			r = -1;
		else {
			if(scallnr == PREAD && (vlong)a2 >= 0)
				p9seek(bfd, (vlong)a2, 0);
			r = p9read(bfd, cdata + Dataoff, (long)a1);
		}
		break;

	case _WRITE:
	case PWRITE:
		/* write(fd, buf, n): data already at cdata[Dataoff] */
		bfd = fdof(img, a0);
		if(bfd == Fdcons){
			print("%.*s", (int)a1, (char*)(cdata + Dataoff));
			r = (long)a1;
		} else if(bfd < 0)
			r = -1;
		else {
			if(scallnr == PWRITE && (vlong)a2 >= 0)
				p9seek(bfd, (vlong)a2, 0);
			r = p9write(bfd, cdata + Dataoff, (long)a1);
		}
		break;

	case SEEK:
	case OSEEK:
		bfd = fdof(img, a0);
		r = bfd < 0 ? -1 : (long)p9seek(bfd, (vlong)a1, (int)a2);
		break;

	case CREATE:
		/* create(name, mode, perm): name at cdata[Nameoff], a1 mode, a2 perm */
		if(waserror()){
			r = -1;
			break;
		}
		r = fdnew(img, p9create((char*)(cdata + Nameoff), (int)a1, (ulong)a2));
		poperror();
		break;

	case REMOVE:
		/* remove(name): name at cdata[Nameoff] */
		r = p9remove((char*)(cdata + Nameoff));
		break;

	case FSTAT:
		/* fstat(fd, edir, nedir): the raw stat message to cdata[Dataoff], a1 = nedir */
		bfd = fdof(img, a0);
		r = bfd < 0 ? -1 : p9fstatraw(bfd, cdata + Dataoff, (int)a1);
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
p9buddy_serve(uchar *cdata, uvlong container)
{
	uvlong *ab;

	ab = (uvlong*)(cdata + Argoff);
	return p9buddy_syscall(container, ab[0], ab[1], ab[2], ab[3], cdata);
}
