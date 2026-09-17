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
	WSTAT	= 44,
	ERRSTR	= 41,
	PIPE	= 21,
	RFORK	= 19,
	BIND	= 2,
	MOUNT	= 46,
	FD2PATH	= 23,
	CHDIR	= 3,
	UNMOUNT	= 35,
	/*
	 * RFPROC, which the shim headers here do not carry.  RFNAMEG and
	 * RFCNAMEG were beside it until the library-OS personality needed
	 * them too and they went into nsdat.h, where the name-space model
	 * is; a second definition here is a redeclaration, not a copy.
	 */
	RFPROC	 = (1<<4),

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
	Chan	*dot;			/* its own working directory once it chdirs; nil = the buddy's own */
	int	nsforked;		/* it rforked a private name space (RFNAMEG) */
	int	nbind;			/* path binds it made in that name space, recorded so migration can replay them */
	struct { char new[80], old[80]; int flag; } bind[8];
};
/*
 * A record per container the buddy answers for, freed when the kernel
 * says the container is gone (p9buddy_gone, on ReqGone).  Eight was
 * enough while one program ran at a time; a shell running a two-stage
 * pipeline holds two at once beside whatever else the boot is running,
 * so there is room for more of them now.
 */
enum { Nimg = 32 };
static Img imgs[Nimg];

static void fdcloseexec(Img*);

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
 *
 * Nothing of the container's current image is touched until the new one
 * has parsed.  A process that execs is running on the image this record
 * describes, and it goes on faulting pages out of it: an exec that fails
 * - a name that is not there, a file that is neither an ELF nor an amd64
 * a.out - must leave the process able to run, so the new file is opened
 * and read into locals and only then committed here.  Before this, a
 * failed exec closed the running image's file and left the process
 * unpageable, which is not a refusal but a killing.
 */
static long
p9buddy_exec(uvlong container, char *name, uchar *out)
{
	Img *img;
	uchar hdr[64], ph[56];
	uvlong phoff, *d, nentry;
	int phentsize, phnum, i, nfd, nkind, nnph;
	struct { uvlong off, va, filesz, memsz, flags; } nphs[Maxph];

	if((img = imgof(container, 1)) == nil)
		return -1;
	if(waserror()){
		print("buddy: exec %s: %s\n", name, up->errstr);
		return -1;
	}
	nfd = p9open(name, 0);
	poperror();
	if(nfd < 0){
		/* say so: a silent -1 here is an exec that fails with no
		 * reason anywhere, and the caller usually cannot report one */
		print("buddy: exec %s for container %llud: cannot open it in this personality's name space\n",
			name, container);
		return -1;
	}
	if(readat(nfd, 0, hdr, sizeof hdr) < 0){
		p9close(nfd);
		return -1;
	}
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
			p9close(nfd);
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
		nkind = 1;
		nentry = Utzero + hdrsz;
		nnph = 3;
		nphs[0].flags = 5; nphs[0].off = 0;    nphs[0].va = Utzero; nphs[0].filesz = tseg;   nphs[0].memsz = tseg;
		nphs[1].flags = 6; nphs[1].off = tseg; nphs[1].va = adata;  nphs[1].filesz = datasz; nphs[1].memsz = datasz;
		nphs[2].flags = 6; nphs[2].off = 0;    nphs[2].va = abss;   nphs[2].filesz = 0;      nphs[2].memsz = ebss - abss;
		print("buddy: exec %s for container %llud: a Plan 9 a.out, text %llud data %llud bss %llud\n",
			name, container, textsz, datasz, bsssz);
	} else {
		nkind = 0;
		nentry = le(hdr+24, 8);
		phoff = le(hdr+32, 8);
		phentsize = le(hdr+54, 2);
		phnum = le(hdr+56, 2);
		nnph = 0;
		for(i = 0; i < phnum && nnph < Maxph; i++){
			if(readat(nfd, phoff + (uvlong)i*phentsize, ph, sizeof ph) < 0){
				p9close(nfd);
				return -1;
			}
			if(le(ph, 4) != 1)		/* PT_LOAD */
				continue;
			nphs[nnph].flags = le(ph+4, 4);
			nphs[nnph].off = le(ph+8, 8);
			nphs[nnph].va = le(ph+16, 8);
			nphs[nnph].filesz = le(ph+32, 8);
			nphs[nnph].memsz = le(ph+40, 8);
			nnph++;
		}
		print("buddy: exec %s for container %llud: entry %#llux, %d loadable segments\n",
			name, container, nentry, nnph);
	}

	/*
	 * Committed: the new binary parsed, so the old image's file is
	 * closed and this one takes its place.  Up to here nothing of the
	 * running image had changed, which is what lets a failed exec
	 * return -1 to a process that goes on running.
	 */
	if(img->fd >= 0)
		p9close(img->fd);
	img->fd = nfd;
	img->kind = nkind;
	img->entry = nentry;
	img->nph = nnph;
	for(i = 0; i < nnph; i++){
		img->ph[i].off = nphs[i].off;
		img->ph[i].va = nphs[i].va;
		img->ph[i].filesz = nphs[i].filesz;
		img->ph[i].memsz = nphs[i].memsz;
		img->ph[i].flags = nphs[i].flags;
	}
	kstrcpy(img->name, name, sizeof img->name);
	d = (uvlong*)out;
	d[0] = img->entry;
	d[1] = img->kind;
	for(i = 0; i < img->nph; i++){
		d[2+3*i] = img->ph[i].va;
		d[3+3*i] = img->ph[i].memsz;
		d[4+3*i] = img->ph[i].flags;
	}
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
	/*
	 * Every descriptor, 0, 1 and 2 included: the console sentinel is
	 * negative and passes over, but a shell that redirected a stage put
	 * a real one there, and a pipe's write end left open outlives the
	 * process that held it - the reader at the other end then never sees
	 * end of file.  Starting at 3 was right only while nothing redirected;
	 * what it cost was a pipeline whose second stage read every byte and
	 * then waited for the call's own bound to give up, with the same byte
	 * count to show for it either way.
	 */
	for(i = 0; i < Nfd; i++)
		if(img->fds[i] >= 0)
			p9close(img->fds[i]);
	if(img->pgrp != nil)
		closepgrp(img->pgrp);		/* the container's own name space, if it rforked one */
	if(img->dot != nil)
		cclose(img->dot);		/* and its own working directory, if it chdir'd */
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

/*
 * The buddy descriptor that a container's descriptor stands for, or -1.
 * The dup device (devdup.c) needs it: a container that opens /fd/<n>
 * means its own descriptor n, and what the buddy holds for it is a
 * descriptor of the buddy's.  Nothing else outside this file has any
 * business with the table, so this is the only way out of it.
 */
int
p9containerfd(uvlong container, int fd)
{
	Img *img;

	if(fd < 0 || (img = imgof(container, 0)) == nil)
		return -1;
	return fdof(img, (uvlong)fd);
}

/*
 * Is this descriptor of the buddy's open on a file of the srv device?
 * A container that posts a service writes the number of one of its own
 * descriptors into a file it created in /srv, and the srv device
 * resolves that number in the file table of whoever writes - which here
 * is the buddy's worker, not the container.  Without a translation the
 * name in /srv ends up holding whatever channel the worker happened to
 * have at that number: lib9p's postsrv posted the draw server that way,
 * and mounting the result spoke 9P at an unrelated device, which
 * answered "unknown control request".
 */
static int
issrvchan(int bfd)
{
	Chan *c;
	int is;

	if(waserror())
		return 0;
	c = fdtochan(bfd, -1, 0, 1);
	is = devtab[c->type]->dc == 's';
	cclose(c);
	poperror();
	return is;
}

/*
 * What open(2)'s OCEXEC means, at the moment it means anything: the
 * descriptors so opened are closed by exec and the rest are kept.
 *
 * This is not a nicety.  libthread's procexec - which is how rio starts
 * the command in a window - opens the write end of a pipe OCEXEC, hands
 * it to the proc that execs, and then reads the read end: the read ends
 * when the write end is closed everywhere, which is the exec telling it
 * the exec worked.  With the flag ignored the child kept the write end
 * open, the read never ended, procexec never sent the pid, rio's new()
 * never returned from recvul(), and rio's mouse thread sat inside it -
 * so the first window a machine made was the last, and the menu never
 * opened again.  The keyboard thread went on working, which is what
 * made it look like rio was alive.
 */
static void
fdcloseexec(Img *img)
{
	int i;

	for(i = 0; i < Nfd; i++){
		if(img->fds[i] < 0 || (img->fdmode[i] & OCEXEC) == 0)
			continue;
		p9close(img->fds[i]);
		img->fds[i] = -1;
		img->fdname[i][0] = 0;
		img->fdmode[i] = 0;
	}
}

static long
fdnew(Img *img, int bfd, char *name, int mode)
{
	int i;

	/*
	 * From 0, not from 3.  open(2) returns the lowest-numbered free
	 * descriptor, and a program that wants to replace its standard
	 * input or output does it by closing the one and opening the
	 * other - rio's winshell does exactly that to put a window's
	 * /dev/cons on 0 and 1.  Searching from 3 left those opens landing
	 * on 5 and 6 while 0 and 1 still held the console, so the command
	 * in a window wrote to the machine's console instead of to the
	 * window.  A container that has not closed them still has them:
	 * they hold the console sentinel, which is not -1.
	 */
	for(i = 0; i < Nfd; i++)
		if(img->fds[i] == -1){
			img->fds[i] = bfd;
			if(name != nil)
				kstrcpy(img->fdname[i], name, sizeof img->fdname[i]);
			else
				img->fdname[i][0] = 0;	/* a pipe's end: no name to reopen it by elsewhere */
			img->fdmode[i] = mode;
			return i;
		}
	/*
	 * Say so.  A silent -1 here is a descriptor a program asked for and
	 * did not get, with nothing anywhere saying why; rio holds one
	 * notepg descriptor per window on top of draw, mouse, cursor,
	 * keyboard, console and its own file server, so this table is a
	 * thing a window system can actually run out of.
	 */
	print("buddy: container %llud has all %d of its descriptors; %s not opened\n",
		img->container, Nfd, name != nil ? name : "a pipe");
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
	Chan *saveddot = nil;
	/*
	 * A separate flag, not saveddot != nil: a worker's dot may itself
	 * be nil, and then nil cannot mean both "nothing saved" and "put
	 * nil back".  Skipping the restore would leave a container's own
	 * directory installed on a shared worker, which is the thing the
	 * swap exists to prevent.
	 */
	int dotsaved = 0;

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
	 * And its own working directory, for the same reason and swapped the
	 * same way: a relative name a container opens has to resolve against
	 * the directory that container chdir'd to, not the worker's, which is
	 * the buddy's own and shared by every container at once.
	 */
	if(img != nil && img->dot != nil){
		saveddot = up->dot;
		dotsaved = 1;
		up->dot = img->dot;
	}

	/*
	 * Any file trap that raises an error is answered -1, and the error
	 * string is stashed per-container so the process's next errstr(2)
	 * returns the real reason - not a lie, and not the buddy's own errstr.
	 */
	if(waserror()){
		if(savedpgrp != nil)
			up->pgrp = savedpgrp;
		if(dotsaved)
			up->dot = saveddot;
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
		/*
		 * and only here, where a running container has really exec'd:
		 * p9buddy_exec is called again when a migration record is
		 * replayed to rebuild an arrived container's image, and that
		 * is not an exec - its descriptors come out of the record
		 * after the image line, and closing any of them there would
		 * throw away what the record is in the middle of restoring.
		 */
		if(r >= 0)
			fdcloseexec(img);
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
		/*
		 * And the working directory, which a fork inherits on Plan 9.
		 * Without this a child of a container that had chdir'd starts
		 * with none and falls back to the worker's - the buddy's own
		 * root - so its relative names resolve somewhere its parent
		 * never was.  The channel is referenced again, since each
		 * container closes its own on the way out.
		 */
		if(img->dot != nil){
			if(cimg->dot != nil)
				cclose(cimg->dot);
			cimg->dot = img->dot;
			incref(cimg->dot);
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
		/* the new descriptor is not close-on-exec whatever the old one
		 * was: sysdup gives it flag 0, and dup(1, 2) in rio's winshell
		 * would otherwise hand the exec'd command a descriptor that
		 * closed itself */
		if((int)a1 == -1){
			r = fdnew(img, nd, img->fdname[a0], img->fdmode[a0] & ~OCEXEC);
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
			img->fdmode[nf] = img->fdmode[a0] & ~OCEXEC;
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
			/*
			 * Free, including 0, 1 and 2.  These used to go back to
			 * the console sentinel, so a close of them was not a
			 * close: the descriptor a program had just given up was
			 * still the console, and the open that was meant to
			 * replace it went somewhere else.
			 */
			img->fds[a0] = -1;
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
			/*
			 * Clamped here too, and not only where the call is
			 * built: this is the side that does the writing, and a
			 * count larger than the block would put the answer
			 * over whatever the data area holds next.
			 */
			if(a1 > Odbuddydatalen)
				a1 = Odbuddydatalen;
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
			uchar *wp = cdata + Dataoff;
			long wn = (long)a1;
			char sbuf[32];
			int translated = 0;

			/*
			 * And bounded here too, on the side that reads the
			 * block: a count larger than it would read past the
			 * data area and write whatever lies beyond to the
			 * file.
			 */
			if(wn > Odbuddydatalen)
				wn = Odbuddydatalen;



			/*
			 * A descriptor number written to a srv file is the
			 * container's; the srv device wants the worker's.
			 */
			if(issrvchan(bfd)){
				long cfd, i;

				for(cfd = 0, i = 0; i < wn && wp[i] >= '0' && wp[i] <= '9'; i++)
					cfd = cfd*10 + (wp[i] - '0');
				if(i == 0 || fdof(img, cfd) < 0){
					r = -1;
					break;
				}
				wn = snprint(sbuf, sizeof sbuf, "%d", fdof(img, cfd));
				wp = (uchar*)sbuf;
				translated = 1;
			}
			if(scallnr == PWRITE && (vlong)a2 >= 0)
				p9seek(bfd, (vlong)a2, 0);
			r = p9write(bfd, wp, wn);
			if(translated && r >= 0)
				r = (long)a1;	/* the count the caller wrote */
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

	case FD2PATH:
		/*
		 * fd2path(fd, buf, nbuf): the path the descriptor resolved to,
		 * written to cdata[Dataoff], a1 = nbuf.  The buddy holds the
		 * descriptor table, so the name space that answers is this
		 * personality's - the path the process sees is the one its
		 * container's name space gave.  The byte count goes back, the
		 * terminator included; the kernel turns it into fd2path's 0.
		 * The three console descriptors have no file behind them here,
		 * so they answer with the name a Plan 9 program expects.
		 */
		bfd = fdof(img, a0);
		if(bfd == Fdcons && (int)a1 > 0){
			char *cons = "/dev/cons";
			int n = strlen(cons) + 1;

			if(n > (int)a1)
				n = (int)a1;
			memmove(cdata + Dataoff, cons, n);
			((char*)(cdata + Dataoff))[n-1] = 0;
			r = n;
		} else if(bfd < 0)
			r = -1;
		else
			r = p9fd2path(bfd, (char*)(cdata + Dataoff), (int)a1);
		break;

	case STAT:
		/* stat(name, edir, nedir): name at cdata[Nameoff], message to cdata[Dataoff], a1 = nedir */
		r = p9statraw((char*)(cdata + Nameoff), cdata + Dataoff, (int)a1);
		break;

	case WSTAT:
		/*
		 * wstat(name, edir, nedir): the name at cdata[Nameoff] and the
		 * message the program marshalled at cdata[Dataoff].  It is the
		 * one call whose argument is a Dir the caller built, so the
		 * data travels out with the request rather than back with the
		 * reply.
		 */
		r = p9wstatraw((char*)(cdata + Nameoff), cdata + Dataoff, (int)a1);
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

	case CHDIR:
	{
		/*
		 * chdir(name): name at Nameoff.  The container's working
		 * directory is its own, kept here beside its name space, so
		 * that two containers can be in two directories at once - which
		 * they could not be if this set the worker's dot, since the
		 * worker is shared and the next call would run in whatever
		 * directory the last container chose.
		 */
		Chan *nc = p9chdirchan((char*)(cdata + Nameoff));

		if(img == nil){
			cclose(nc);
			r = -1;
			break;
		}
		if(img->dot != nil)
			cclose(img->dot);
		img->dot = nc;
		if(!dotsaved){
			saveddot = up->dot;
			dotsaved = 1;
		}
		up->dot = nc;		/* the rest of this call runs there too */
		r = 0;
		break;
	}

	case UNMOUNT:
		/* unmount(name, old): name at Nameoff, old at Nameoff+128; an
		 * empty name means everything mounted on old */
		r = p9unmount((char*)(cdata + Nameoff), (char*)(cdata + Nameoff + 128));
		break;

	default:
		r = -1;		/* a trap this buddy does not emulate */
		break;
	}
	poperror();
	if(savedpgrp != nil)
		up->pgrp = savedpgrp;
	if(dotsaved)
		up->dot = saveddot;
	return r;
}

/*
 * Plain-typed entry the user-header ring loop calls.  The kernel left the
 * forwarded call's number and scalar arguments as a block of uvlongs at
 * cdata[Argoff]: number, then the three scalars.
 */
/*
 * Which container is this process serving right now?
 *
 * A device the personality serves - the note tree below /proc - has to
 * know whose call it is answering, and devtab->write is handed only a
 * Chan.  The buddy serves one call at a time on each of its worker
 * processes, so the answer is a property of the running process, and it
 * is recorded here around the call rather than in one global that four
 * workers would overwrite each other in.
 */
enum { Nserving = 8 };
static struct {
	Proc	*p;
	uvlong	container;
} serving[Nserving];

static void
p9serving(uvlong container)
{
	int i, free;

	free = -1;
	for(i = 0; i < Nserving; i++){
		if(serving[i].p == up){
			/*
			 * container 0 gives the slot back rather than storing
			 * a zero in it.  A Proc comes out of a pool and is
			 * reused, so a slot left standing on a dead one would
			 * hand its container to whatever process took that
			 * Proc next - and that container is the ASKER in the
			 * note's authority check, so a stale slot is authority
			 * given to the wrong container.
			 */
			if(container == 0)
				serving[i].p = nil;
			serving[i].container = container;
			return;
		}
		if(serving[i].p == nil && free < 0)
			free = i;
	}
	if(container == 0 || free < 0)
		return;			/* nothing to give back, or more servers than slots: the device asks and is told nobody */
	serving[free].p = up;
	serving[free].container = container;
}

/* the container the running process is answering for, or 0 for none */
uvlong
p9servingcontainer(void)
{
	int i;

	for(i = 0; i < Nserving; i++)
		if(serving[i].p == up)
			return serving[i].container;
	return 0;
}

long
p9buddy_serve(uchar *cdata, uvlong container)
{
	uvlong *ab;
	long r;

	ab = (uvlong*)(cdata + Argoff);
	p9serving(container);
	r = p9buddy_syscall(container, ab[0], ab[1], ab[2], ab[3], cdata);
	p9serving(0);			/* the slot goes back before this process serves anything else */
	return r;
}

/*
 * The workers that serve a forwarded system call, so that one which
 * blocks does not block the service loop.  A pipe is what makes this
 * necessary: a shell's second stage reads a pipe its first stage has not
 * written yet, and the read waits for a process the same loop would have
 * had to carry.  The pool lives here rather than in the ring loop
 * because a kproc and a Rendez are kernel-header things and that loop is
 * compiled against the user headers; what crosses is three plain-typed
 * calls.
 *
 * A pool of four, not a kproc per container: a kproc costs a 32K stack
 * and a slot in the scheduler's table, and a container that never blocks
 * would spend both for the whole boot.  With all four busy the caller
 * serves the call itself, as it always did, which is no worse than
 * before.  The workers are started from the service task so they inherit
 * its name space, which is the buddy's own - the one a container without
 * a private name space runs its calls in; a container with one has it
 * swapped in and out around the call, on the worker's own Proc, so two
 * workers cannot restore over each other.
 */
/*
 * Twelve, not four.  A forwarded call runs on a worker and a blocking
 * read holds one for as long as it blocks: rio parks one on /dev/kbd,
 * one on /dev/mouse and one on its own 9P pipe, and holds them for as
 * long as it runs.  Four left one worker for everything else.
 */
enum { Nworker = 12 };
typedef struct Job Job;
struct Job {
	int	busy;			/* a worker holds it */
	/*
	 * Written by the worker, read by the service loop, with no barrier
	 * and no lock: this scheduler is cooperative and nothing else runs
	 * personality code, so a switch happens only where a proc sleeps and
	 * the two never touch this word at once.  A preemptive tick here
	 * would break that quietly.
	 */
	int	done;			/* it has an answer waiting to be posted */
	uvlong	container, sequence;	/* whose call, and which, so the reply can be addressed */
	uchar	*cdata;			/* the caller's data area, where its arguments are */
	long	result;
	Rendez	r;
};
static Job jobs[Nworker];

static int
havework(void *a)
{
	Job *j = a;

	return j->busy && !j->done;
}

static void
buddyworker(void *a)
{
	Job *j = a;

	for(;;){
		ksleep(&j->r, havework, j);
		j->result = p9buddy_serve(j->cdata, j->container);
		j->done = 1;
	}
}

int
p9buddy_workers(void)
{
	int w;

	for(w = 0; w < Nworker; w++)
		kproc("p9-buddyworker", buddyworker, &jobs[w]);
	return 1;
}

int
p9buddy_dispatch(uchar *cdata, uvlong container, uvlong sequence)
{
	Job *j;

	for(j = jobs; j < jobs + Nworker; j++)
		if(!j->busy){
			j->container = container;
			j->sequence = sequence;
			j->cdata = cdata;
			j->result = -1;
			j->done = 0;
			j->busy = 1;
			wakeup(&j->r);
			return 1;
		}
	return 0;
}

int
p9buddy_reap(uvlong *container, uvlong *sequence, long *result)
{
	Job *j;

	for(j = jobs; j < jobs + Nworker; j++)
		if(j->busy && j->done){
			*container = j->container;
			*sequence = j->sequence;
			*result = j->result;
			j->busy = 0;
			j->done = 0;
			return 1;
		}
	return 0;
}
