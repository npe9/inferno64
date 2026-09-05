#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"p9file.h"
#include	"ospreydata.h"

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
	STAT	= 42,
	ERRSTR	= 41,
	PIPE	= 21,
	RFORK	= 19,
	BIND	= 2,
	MOUNT	= 46,
	/* rfork flags (portdat.h), which the shim headers here do not carry */
	RFNAMEG	 = (1<<0),
	RFPROC	 = (1<<4),
	RFCNAMEG = (1<<10),

	/*
	 * Not system calls: the kernel's requests for the legacy process's
	 * image, numbered above any Plan 9 system call.  EXEC lays the
	 * binary out from this personality's file system; PAGE supplies one
	 * page of it, which is how a page fault reaches the buddy.
	 */
	EXEC	= 100,
	PAGE	= 101,
	MAPPAGE	= 102,		/* a page of a file the process mapped */
	FORKFDS	= 103,		/* clone this container's descriptor table into a0's, at fork */
	DUPFD	= 104,		/* dup(oldfd, newfd): duplicate a process descriptor */
	Nfd	= 16,		/* descriptors a legacy process may hold */
	Fdcons	= -2,		/* 0, 1 and 2: the console, which this personality has no file for */
	Maxph	= 8,		/* loadable program headers kept */
	Pagesz	= 4096,

	Argoff	= Odbuddyarg,	/* where the kernel left the arg block, in cdata */
	Nameoff	= Odbuddyname,	/* where the kernel left a name, in cdata */
	Dataoff	= Odbuddydata,	/* where read/write data goes, in cdata */
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
	char	fdname[Nfd][96];	/* what each was opened as, and how: what crosses a wire with the process, to be reopened there */
	int	fdmode[Nfd];
	char	name[128];	/* the image's file, named the same in the far personality's file system */
	int	fd;
	int	kind;		/* 0 an ELF, 1 a Plan 9 a.out */
	uvlong	entry;
	int	nph;
	struct {
		uvlong	off, va, filesz, memsz, flags;
	} ph[Maxph];
	char	err[ERRMAX];		/* the last error, for the process's errstr(2) */
	Pgrp	*pgrp;			/* its own name space once it rforks RFNAMEG; nil = the buddy's shared one */
	int	nsforked;		/* it rforked a private name space (RFNAMEG) */
	int	nbind;			/* path binds it made in that name space, recorded so migration can replay them */
	struct { char new[80], old[80]; int flag; } bind[8];
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
	kstrcpy(img->name, name, sizeof img->name);
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
	if((img = imgof(container, 0)) == nil || img->fd < 0){
		print("buddy: page %#llux for container %llud: %s\n", va, container, img == nil ? "no image held for it" : "its image has no file open");
		return -1;
	}
	found = 0;
	for(i = 0; i < img->nph; i++){
		if(va + Pagesz <= img->ph[i].va || va >= img->ph[i].va + img->ph[i].memsz)
			continue;
		found = 1;
		lo = va > img->ph[i].va ? va : img->ph[i].va;
		fend = img->ph[i].va + img->ph[i].filesz;
		hi = va + Pagesz < fend ? va + Pagesz : fend;
		if(lo < hi && readat(img->fd, img->ph[i].off + (lo - img->ph[i].va), out + (lo - va), hi - lo) < 0){
			print("buddy: page %#llux for container %llud: the image file (%s, fd %d) could not be read\n", va, container, img->name, img->fd);
			return -1;
		}
	}
	if(found)
		print("buddy: page %#llux of the legacy image supplied from its file\n", va);
	else
		print("buddy: page %#llux for container %llud: no loadable segment of %s covers it\n", va, container, img->name);
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
	if(img->pgrp != nil)
		closepgrp(img->pgrp);		/* the container's own name space, if it rforked one */
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
fdnew(Img *img, int bfd, char *name, int mode)
{
	int i;

	for(i = 3; i < Nfd; i++)
		if(img->fds[i] == -1){
			img->fds[i] = bfd;
			if(name != nil)
				kstrcpy(img->fdname[i], name, sizeof img->fdname[i]);
			else
				img->fdname[i][0] = 0;	/* a pipe's end: no name to reopen it by elsewhere */
			img->fdmode[i] = mode;
			return i;
		}
	p9close(bfd);
	return -1;
}

/*
 * What a process takes with it over a wire, as text: its image's name
 * and kind, and each open descriptor's number, mode, offset and name.
 * The far personality reopens each by name in its own file system and
 * seeks to the offset; the descriptor table is the buddy's, so it is
 * the buddy's to carry, not the kernel's.  A pipe's end has no name
 * and is left behind, said so.
 */
long
p9buddy_migout(uvlong container, char *buf, long max)
{
	Img *img;
	long n;
	int i, nopen, nleft;

	if((img = imgof(container, 0)) == nil || img->name[0] == 0){
		print("buddy: container %llud departs with no record: %s\n", container, img == nil ? "no table held for it" : "its image has no name");
		return -1;
	}
	n = snprint(buf, max, "image %s %d\n", img->name, img->kind);
	nopen = nleft = 0;
	for(i = 3; i < Nfd; i++){
		if(img->fds[i] < 0)
			continue;
		if(img->fdname[i][0] == 0){
			nleft++;
			continue;
		}
		n += snprint(buf + n, max - n, "fd %d %d %lld %s\n", i, img->fdmode[i], (vlong)p9seek(img->fds[i], 0, 1), img->fdname[i]);
		nopen++;
	}
	if(img->nsforked){
		int b;
		n += snprint(buf + n, max - n, "ns\n");	/* it had a private name space */
		for(b = 0; b < img->nbind; b++)
			n += snprint(buf + n, max - n, "bind %d %s %s\n", img->bind[b].flag, img->bind[b].new, img->bind[b].old);
		print("buddy: container %llud departs: image %s, %d descriptors, a private name space with %d binds in its record%s\n",
			container, img->name, nopen, img->nbind, nleft > 0 ? ", a pipe's end left behind" : "");
	} else
		print("buddy: container %llud departs: image %s, %d descriptors in its record%s\n", container, img->name, nopen,
			nleft > 0 ? ", a pipe's end left behind" : "");
	return n;
}

static vlong
migrecnum(char **pp)
{
	char *p = *pp;
	vlong v = 0;
	int neg = 0;

	while(*p == ' ')
		p++;
	if(*p == '-'){ neg = 1; p++; }
	while(*p >= '0' && *p <= '9')
		v = v*10 + (*p++ - '0');
	*pp = p;
	return neg ? -v : v;
}

/* the record above, arriving: the image laid out for the new container, its descriptors reopened */
int
p9buddy_migin(uvlong container, char *rec)
{
	Img *img;
	uvlong scratch[4 + 3*Maxph];
	char *line, *next, *name, *e;
	vlong off;
	int fd, mode, bfd, nfd, nsforked, nbind;
	struct { char *newp, *oldp; int flag; } binds[8];

	nfd = 0;
	nsforked = 0;
	nbind = 0;
	img = nil;
	for(line = rec; line != nil && *line != 0; line = next){
		next = strchr(line, '\n');
		if(next != nil)
			*next++ = 0;
		if(strncmp(line, "image ", 6) == 0){
			name = line + 6;
			if((e = strchr(name, ' ')) != nil)
				*e = 0;
			if(p9buddy_exec(container, name, (uchar*)scratch) < 0)
				return -1;
			img = imgof(container, 0);
			continue;
		}
		if(strncmp(line, "ns", 2) == 0 && (line[2] == 0 || line[2] == ' ')){
			nsforked = 1;
			continue;
		}
		if(strncmp(line, "bind ", 5) == 0 && nbind < (int)nelem(binds)){
			/* bind <flag> <new> <old>: replayed after the whole record is read, in the rebuilt name space */
			char *p = line + 5;
			binds[nbind].flag = (int)migrecnum(&p);
			while(*p == ' ')
				p++;
			binds[nbind].newp = p;
			while(*p != 0 && *p != ' ')
				p++;
			if(*p == ' ')
				*p++ = 0;
			binds[nbind].oldp = p;
			if(binds[nbind].newp[0] != 0 && binds[nbind].oldp[0] != 0)
				nbind++;
			continue;
		}
		if(strncmp(line, "fd ", 3) != 0 || img == nil)
			continue;
		e = line + 3;
		fd = migrecnum(&e);
		mode = migrecnum(&e);
		off = migrecnum(&e);
		while(*e == ' ')
			e++;
		if(fd < 3 || fd >= Nfd)
			continue;
		if(waserror()){
			print("buddy: container %llud arrived: descriptor %d, %s, could not be reopened: %s\n", container, fd, e, up->errstr);
			continue;
		}
		bfd = p9open(e, mode);
		poperror();
		p9seek(bfd, off, 0);
		if(img->fds[fd] >= 0)
			p9close(img->fds[fd]);
		img->fds[fd] = bfd;
		img->fdmode[fd] = mode;
		kstrcpy(img->fdname[fd], e, sizeof img->fdname[fd]);
		nfd++;
	}
	if(img == nil)
		return -1;
	print("buddy: container %llud arrived: image %s laid out for it, %d descriptors reopened at their offsets\n", container, img->name, nfd);
	/* the private name space, rebuilt the way it was made: a fresh pgrp forked from the buddy's, then each bind replayed */
	if(nsforked && img->pgrp == nil){
		Pgrp *ng = newpgrp();
		Pgrp *saved;
		int b;

		pgrpcpy(ng, up->pgrp);		/* the buddy's shared mounts, /n and all, as on the machine it left */
		img->pgrp = ng;
		img->nsforked = 1;
		saved = up->pgrp;
		up->pgrp = ng;
		for(b = 0; b < nbind; b++){
			if(waserror())
				continue;
			p9bind(binds[b].newp, binds[b].oldp, binds[b].flag);
			poperror();
		}
		up->pgrp = saved;
		print("buddy: container %llud arrived: its private name space rebuilt, %d binds replayed\n", container, nbind);
	}
	return 0;
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
	Pgrp *savedpgrp = nil;

	img = imgof(container, 1);

	if(scallnr == ERRSTR){
		/* errstr(buf, nbuf): the last error this container's syscalls left,
		 * to cdata[Dataoff] for the kernel to copy into the process's buf */
		long m;
		char *e = img != nil ? img->err : "";
		for(m = 0; m < (long)a1 - 1 && e[m] != 0; m++)
			(cdata + Dataoff)[m] = e[m];
		(cdata + Dataoff)[m] = 0;
		return m + 1;
	}

	/*
	 * If this container has rforked its own name space, run its call in
	 * that name space, not the buddy's shared one, so its binds and mounts
	 * are its own; restore the buddy's on the way out.  Inert until a
	 * container rforks (img->pgrp stays nil), so the common path is
	 * unchanged.
	 */
	if(img != nil && img->pgrp != nil){
		savedpgrp = up->pgrp;
		up->pgrp = img->pgrp;
	}

	/*
	 * Any file trap that raises an error is answered -1, and the error
	 * string is stashed per-container so the process's next errstr(2)
	 * returns the real reason - not a lie, and not the buddy's own errstr.
	 */
	if(waserror()){
		if(savedpgrp != nil)
			up->pgrp = savedpgrp;
		if(img != nil)
			kstrcpy(img->err, up->errstr, sizeof img->err);
		return -1;
	}

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

	case FORKFDS:
	{
		/* fork: clone this container's descriptor table into a0's (the
		 * child's).  Each real descriptor is dup'd, so parent and child
		 * hold their own and each closes its own on exit; the console
		 * sentinels (Fdcons) and empty slots are copied as they are. */
		Img *cimg;
		int k;

		cimg = imgof(a0, 1);
		if(cimg == nil){
			r = -1;
			break;
		}
		for(k = 0; k < Nfd; k++){
			if(img->fds[k] >= 0)
				cimg->fds[k] = p9dup(img->fds[k]);
			else
				cimg->fds[k] = img->fds[k];
			memmove(cimg->fdname[k], img->fdname[k], sizeof cimg->fdname[k]);
			cimg->fdmode[k] = img->fdmode[k];
		}
		/* the image too: the child's text and data are the same binary's, and it may cross a wire, where the far buddy needs its name */
		if(img->fd >= 0){
			if(cimg->fd >= 0)
				p9close(cimg->fd);
			cimg->fd = p9dup(img->fd);
			cimg->kind = img->kind;
			cimg->entry = img->entry;
			cimg->nph = img->nph;
			memmove(cimg->ph, img->ph, sizeof cimg->ph);
			memmove(cimg->name, img->name, sizeof cimg->name);
		}
		print("buddy: container %llud's descriptors cloned to container %llud%s\n", container, a0,
			img->fd >= 0 ? ", and its image with them" : "; it has no image of its own");
		/*
		 * The name space too: a fork without RFNAMEG shares the parent's,
		 * so if the parent rforked a private one, the child holds the same
		 * Pgrp (incref'd, so each container closes its own reference on
		 * exit); otherwise both use the buddy's shared name space.
		 */
		if(img->pgrp != nil){
			cimg->pgrp = img->pgrp;
			incref(img->pgrp);
			cimg->nsforked = img->nsforked;	/* the child holds the same private ns, and its record of the binds that made it, for its own migration */
			cimg->nbind = img->nbind;
			memmove(cimg->bind, img->bind, sizeof cimg->bind);
		}
		r = 0;
		break;
	}

	case DUPFD:
	{
		/* dup(oldfd, newfd): the process's oldfd duplicated to newfd, or to
		 * the lowest free descriptor when newfd is -1; the console sentinel
		 * copied as it is, a real descriptor dup'd on this personality. */
		int old, nd, nf;

		if(a0 >= Nfd || (old = img->fds[a0]) == -1){
			r = -1;
			break;
		}
		nd = old == Fdcons ? Fdcons : p9dup(old);
		if((int)a1 == -1){
			r = fdnew(img, nd, img->fdname[a0], img->fdmode[a0]);
		} else {
			nf = (int)a1;
			if(nf < 0 || nf >= Nfd){
				if(nd != Fdcons)
					p9close(nd);
				r = -1;
				break;
			}
			if(img->fds[nf] >= 0)
				p9close(img->fds[nf]);
			img->fds[nf] = nd;
			kstrcpy(img->fdname[nf], img->fdname[a0], sizeof img->fdname[nf]);
			img->fdmode[nf] = img->fdmode[a0];
			r = nf;
		}
		break;
	}

	case OPEN:
		/* open(name, mode): name at cdata[Nameoff], mode a1; the process's own number back */
		r = fdnew(img, p9open((char*)(cdata + Nameoff), (int)a1), (char*)(cdata + Nameoff), (int)a1);
		break;

	case CLOSE:
		bfd = fdof(img, a0);
		if(bfd >= 0)
			p9close(bfd);
		if(bfd != -1){
			img->fds[a0] = a0 < 3 ? Fdcons : -1;
			img->fdname[a0][0] = 0;
		}
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
		r = fdnew(img, p9create((char*)(cdata + Nameoff), (int)a1, (ulong)a2), (char*)(cdata + Nameoff), (int)a1);
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

	case STAT:
		/* stat(name, edir, nedir): name at cdata[Nameoff], message to cdata[Dataoff], a1 = nedir */
		r = p9statraw((char*)(cdata + Nameoff), cdata + Dataoff, (int)a1);
		break;

	case PIPE:
		/* pipe(fd[2]): two descriptors, written back as two ints at cdata[Dataoff] */
		{
			int bfd[2];

			r = p9pipe(bfd);
			if(r == 0){
				((int*)(cdata + Dataoff))[0] = fdnew(img, bfd[0], nil, ORDWR);
				((int*)(cdata + Dataoff))[1] = fdnew(img, bfd[1], nil, ORDWR);
			}
		}
		break;

	case RFORK:
		/*
		 * rfork(flags): only the name-space flags are answered here - the
		 * container gets its own name space, forked from the buddy's
		 * (RFNAMEG) or empty (RFCNAMEG).  RFPROC (a new process) never
		 * reaches this case: the kernel intercepts it in ospreyforkkern
		 * and forks the container itself, then asks the buddy (FORKFDS) to
		 * clone the descriptor table and the name space into the child.
		 */
		r = 0;
		if((a0 & (RFNAMEG|RFCNAMEG)) != 0 && img->pgrp == nil){
			Pgrp *ng = newpgrp();
			if(a0 & RFNAMEG)
				pgrpcpy(ng, up->pgrp);		/* inherit the buddy's mounts, /n and all */
			img->pgrp = ng;
			img->nsforked = 1;		/* the far side rebuilds it the same way on a migration */
		}
		if(a0 & RFPROC)
			r = -1;				/* cannot fork a process here */
		break;

	case BIND:
		/* bind(name, old, flag): name at Nameoff, old at Nameoff+128, a0 the flag */
		r = p9bind((char*)(cdata + Nameoff), (char*)(cdata + Nameoff + 128), (int)a0);
		if(r >= 0 && img != nil && img->nbind < nelem(img->bind)){
			/* recorded, so a migration can replay it: the name space is the container's, and it crosses with the process */
			int b = img->nbind++;
			kstrcpy(img->bind[b].new, (char*)(cdata + Nameoff), sizeof img->bind[b].new);
			kstrcpy(img->bind[b].old, (char*)(cdata + Nameoff + 128), sizeof img->bind[b].old);
			img->bind[b].flag = (int)a0;
		}
		break;

	case MOUNT:
		/* mount(fd, afd, old, flag, spec): old at Nameoff, spec at Nameoff+128,
		 * a0 the process fd of the 9P connection, a1 the flag */
		bfd = fdof(img, a0);
		r = bfd < 0 ? -1 : p9mount(bfd, (char*)(cdata + Nameoff), (int)a1, (char*)(cdata + Nameoff + 128));
		break;

	default:
		r = -1;		/* a trap this buddy does not emulate */
		break;
	}
	poperror();
	if(savedpgrp != nil)
		up->pgrp = savedpgrp;
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
