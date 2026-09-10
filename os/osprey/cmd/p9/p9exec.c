/*
 * The library operating system's own exec: it reads a program through
 * the name space it built, lays it in its own address space, and calls
 * it.
 *
 * The plan asked for this as "exec in place": lay the new binary's
 * segments over the current address space and jump to its entry, with
 * the name space the task built still under it.  Both halves of that
 * cannot hold at once here, and the link map says why.  The
 * personality's live state - up, the arena cursor, the scheduler's run
 * queue, the ring mappings, the IP stack's route generations - is in the
 * data segment, not the bss (6l puts a file-scope scalar there whether
 * it is initialised or not).  Replace the data segment and the name
 * space's roots go with it, though the arena's bytes survive in bss with
 * nothing pointing at them; keep the data segment and the new binary has
 * none of its own, string constants included.  There is no cut between
 * them.
 *
 * So the personality is kept, not reloaded, and the program is what is
 * loaded: a separately linked binary at an address of its own, above the
 * personality's image, entered with a table of the personality's entry
 * points (p9lib.h).  The program calls open and read as ordinary
 * functions in its own address space, which is what track three of the
 * plan is for, and the name space is not merely still under it - it is
 * the same one, in the same memory, built by the program that loaded it.
 *
 * The address space is the one thing it must ask the kernel for:
 * segattach with the name "code" is a demand-zero region the caller may
 * execute from - writable, because the loader writes the program into
 * it, and executable, because the program then runs there.  That is the
 * microkernel's address-space service and the whole of what this needs
 * from a kernel.
 */
#include <u.h>
#include <libc.h>
#include "p9lib.h"
#include "prog2.i"		/* uchar prog2[]: the second program, as a file */
#include "libcatprog.i"		/* uchar libcatprog[]: cat, linked against this personality */
#include "libwcprog.i"		/* uchar libwcprog[]: wc, the far end of a pipeline */
#include "libnsprog.i"		/* uchar libnsprog[]: the program that changes the name space */
#include "rioprogp9.i"		/* uchar rioprogp9[]: the real rio, as a module for this personality */
#include "libshprog.i"		/* uchar libshprog[]: the shell that runs on this personality */
#include "libgenprog.i"		/* uchar libgenprog[]: the near end of a pipeline */
#include "libdrawprog.i"		/* uchar libdrawprog[]: the program that draws */
#include "libthreadprog.i"		/* uchar libthreadprog[]: the program with threads in it */
#include "relocprog.i"		/* uchar relocprog[]: the relocatable module */

extern int	p9open(char *name, int mode);
extern int	p9create(char *name, int mode, ulong perm);
extern long	p9read(int fd, void *buf, long n);
extern long	p9write(int fd, void *buf, long n);
extern void	p9close(int fd);
extern vlong	p9seek(int fd, vlong off, int type);
extern int	p9dup(int fd);
extern int	p9fd2path(int fd, char *buf, int nbuf);
extern char	end[];		/* the personality's own image ends here */
extern void	addbootfile(char *name, uchar *data, ulong len);
extern int	p9pipe(int fd[2]);
extern int	p9spawn(char *name, char **argv, int *std);
extern int	p9waitpid(int pid, char *status, int nstatus);
extern void	p9anyexits(char *status);
extern int	p9procbusy(uvlong base);
extern int	p9relocalloc(void);		/* p9proc.c: the slots a module is laid in */
extern int	p9relocclaim(int slot);
extern void	p9relocfree(int slot);
extern uvlong	p9relocaddr(int slot);
extern int	p9relocslotof(uvlong progbase);

/*
 * The second program is a file in this personality's own file system,
 * embedded the way the legacy binaries are, so that the exec below
 * reads it through the name space and not out of a global.
 */
void
p9execfile(void)
{
	addbootfile("prog2", prog2, sizeof prog2);
	addbootfile("libcat", libcatprog, sizeof libcatprog);
	addbootfile("libwc", libwcprog, sizeof libwcprog);
	addbootfile("libns", libnsprog, sizeof libnsprog);
	addbootfile("rio", rioprogp9, sizeof rioprogp9);
	addbootfile("libsh", libshprog, sizeof libshprog);
	addbootfile("libgen", libgenprog, sizeof libgenprog);
	addbootfile("libdraw", libdrawprog, sizeof libdrawprog);
	addbootfile("libthread", libthreadprog, sizeof libthreadprog);
	addbootfile("reloc", relocprog, sizeof relocprog);
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

/*
 * Read the whole of a file into a buffer through the name space.
 * Returns the byte count, or -1.
 */
static long
readall(int fd, uchar *buf, long max)
{
	long n, got;

	for(got = 0; got < max; got += n){
		n = p9read(fd, buf+got, max-got);
		if(n < 0)
			return -1;
		if(n == 0)
			break;
	}
	return got;
}

/*
 * A program that ends returns here rather than ending the task: exits in
 * the table is this, and it jumps back to the frame p9exec left.  The
 * personality goes on running, which is the whole point of loading a
 * program beside it rather than over it.
 */
static jmp_buf p9execjmp;
static char *p9execstatus;

void
p9execexits(char *status)
{
	p9execstatus = status;
	longjmp(p9execjmp, 1);
}

/*
 * The table's entry points are p9file.c's lib* wrappers, not the name
 * space's raw ones: see the comment there.  This file is compiled
 * against the user headers - it needs libc's segattach for the address
 * space it lays a program into - so it cannot put up an error label
 * itself, and the wrappers are where waserror is in scope.
 */
extern int	libopen(char*, int);
extern int	libcreate(char*, int, ulong);
extern long	libread(int, void*, long);
extern long	libwrite(int, void*, long);
extern void	libclose(int);
extern vlong	libseek(int, vlong, int);
extern int	libdup(int);
extern int	libfd2path(int, char*, int);
extern int	libpipe(int[2]);
extern int	libspawn(char*, char**, int*);
extern int	libwait(int, char*, int);
extern int	liberrstr(char*, uint);
extern long	libpread(int, void*, long, vlong);
extern long	libpwrite(int, void*, long, vlong);
extern int	libstat(char*, uchar*, int);
extern int	libbind(char*, char*, int);
extern int	libmount(int, char*, int, char*);
extern int	libunmount(char*, char*);
extern int	libchdir(char*);
extern int	p9forkns(int);
extern int	p9waitany(char*, int);
extern void	p9saveflow(void);		/* p9proc.c: the groups and dot this flow had */
extern void	p9restoreflow(char *name);
extern int	libfstat(int, uchar*, int);
extern int	libsleep(long);
extern int	libpid(void);
extern void**	p9privalloc(void);
extern int	p9proccreate(void (*f)(void*), void *arg);
extern void*	p9rendezvous(void *tag, void *val);
extern void	p9procwaitinproc(void);

/*
 * The one table every loaded program is handed.  It is read-only and the
 * same for all of them; what differs between a program the personality
 * runs to completion and one it spawns is where exits goes, and that is
 * decided by p9anyexits from the flow of control it is called on, not by
 * a table of its own.
 */
static P9lib p9thelib;

P9lib*
p9libtable(void)
{
	p9thelib.version = P9libversion;
	p9thelib.open = libopen;
	p9thelib.create = libcreate;
	p9thelib.read = libread;
	p9thelib.write = libwrite;
	p9thelib.close = libclose;
	p9thelib.seek = libseek;
	p9thelib.dup = libdup;
	p9thelib.fd2path = libfd2path;
	p9thelib.exits = p9anyexits;
	p9thelib.pipe = libpipe;
	p9thelib.spawn = libspawn;
	p9thelib.wait = libwait;
	p9thelib.errstr = liberrstr;
	p9thelib.pread = libpread;
	p9thelib.pwrite = libpwrite;
	p9thelib.stat = libstat;
	p9thelib.fstat = libfstat;
	p9thelib.sleep = libsleep;
	p9thelib.privalloc = p9privalloc;
	p9thelib.proccreate = p9proccreate;
	p9thelib.pid = libpid;
	p9thelib.rendezvous = p9rendezvous;
	p9thelib.bind = libbind;
	p9thelib.mount = libmount;
	p9thelib.unmount = libunmount;
	p9thelib.chdir = libchdir;
	p9thelib.forkns = p9forkns;
	p9thelib.waitany = p9waitany;
	return &p9thelib;
}

/*
 * The address space a loaded program is given is asked for once and
 * kept.  A program run a second time is laid into the same region, so
 * the region is zeroed before the file is copied into it and the
 * program's bss starts empty the second time as it did the first - which
 * is what a fresh image means, and what a program that keeps a table or
 * a heap cursor in its bss (p9crt.c does both) depends on.
 *
 * The consequence is the honest limit of this arrangement: two of the
 * same program cannot run at once, because they would be the one image
 * sharing its one data segment.  Two different programs can, which is
 * what a pipeline is.  p9spawn refuses the first rather than letting two
 * instances quietly corrupt each other.
 */
/*
 * A region asked of the kernel once and used again afterwards.  The
 * size is here because the base alone is not enough: a slot holds one
 * module and then another, and the second may be the larger of the two.
 * Attached for the first and reused for the second, it would be a
 * region a program writes past - reported, if at all, as a fault a long
 * way from its cause.  So what was attached is remembered, and a
 * program that does not fit what is there is refused by name.
 *
 * Sixteen of them because the count is not obvious: six programs at
 * bases of their own and four relocation slots is ten, and the old
 * eight would have been reached by converting one more program to a
 * module.  Running out is said out loud now rather than passed over,
 * which is what the old code did - it attached the region and then
 * silently failed to record it, so the next load of the same program
 * asked the kernel for ground it already held.
 */
enum { Nattach = 16 };
static uvlong attachbase[Nattach];
static uvlong attachsize[Nattach];
static int nattached;

/*
 * Ground for a program at progbase: need bytes of it, and want bytes
 * asked of the kernel if it is not there yet (a slot asks for the whole
 * slot, so that any module small enough to fit one can be laid in it
 * afterwards).  Answers the base, or nil with the reason printed.
 */
static uchar*
attachfor(char *name, uvlong progbase, uvlong need, uvlong want)
{
	uchar *base;
	int i;

	if(want < need)
		want = need;
	for(i = 0; i < nattached; i++)
		if(attachbase[i] == progbase){
			if(need > attachsize[i]){
				print("p9 load: %s needs %llud bytes at %#llux and only %llud are attached there\n",
					name, need, progbase, attachsize[i]);
				return nil;
			}
			return (uchar*)(uintptr)progbase;
		}
	if(nattached >= Nattach){
		print("p9 load: %s: all %d attachment records are taken; %#llux cannot be asked for\n",
			name, Nattach, progbase);
		return nil;
	}
	base = (uchar*)segattach(0, "code", (void*)(uintptr)progbase, (ulong)want);
	if(base == (uchar*)-1 || (uvlong)(uintptr)base != progbase){
		print("p9 load: the kernel would not give me %llud bytes of address space at %#llux for %s\n",
			want, progbase, name);
		return nil;
	}
	attachbase[nattached] = progbase;
	attachsize[nattached] = want;
	nattached++;
	print("p9 load: %llud bytes of address space at %#llux for %s, attachment %d of %d\n",
		want, progbase, name, nattached, Nattach);
	return base;
}

/*
 * Read the program named in this task's name space and lay it in this
 * address space at the address it was linked for.  Answers 0 with its
 * entry and its base, or -1.
 */
int
p9load(char *name, uvlong *entryp, uvlong *basep)
{
	uchar hdr[40];
	uvlong magic, textsz, datasz, bsssz, hdrsz, entry, tseg, adata, imgsz, progbase;
	uchar *base;
	int fd;
	long n;

	if((fd = p9open(name, OREAD)) < 0){
		print("p9 exec: cannot open %s through my own name space\n", name);
		return -1;
	}
	if(readall(fd, hdr, sizeof hdr) != sizeof hdr){
		print("p9 exec: %s: no header\n", name);
		p9close(fd);
		return -1;
	}
	magic = be(hdr, 4);
	if((magic & 0xffff) != 0x8a97){
		print("p9 exec: %s: not an amd64 a.out (magic %#llux)\n", name, magic);
		p9close(fd);
		return -1;
	}
	textsz = be(hdr+4, 4);
	datasz = be(hdr+8, 4);
	bsssz = be(hdr+12, 4);
	hdrsz = (magic & 0x8000) ? 40 : 32;
	entry = hdrsz == 40 ? be(hdr+32, 8) : be(hdr+20, 4);
	tseg = hdrsz + textsz;
	/*
	 * Where it was linked, from the binary itself: p9start is the first
	 * thing in a loaded program's text (p9lib.h), so the entry is the
	 * header's length above the address the file is laid down at.  The
	 * loader takes nothing on trust about it: the address must be a page
	 * boundary, and it must be above this personality's own image, or
	 * the program would be laid over the operating system that is
	 * loading it.
	 */
	progbase = entry - hdrsz;
	if((progbase & 4095) != 0 || progbase < (uvlong)(uintptr)end){
		print("p9 exec: %s: it is linked at %#llux, which is not a page boundary above my own image (%#llux)\n",
			name, progbase, (uvlong)(uintptr)end);
		p9close(fd);
		return -1;
	}
	/*
	 * Before anything is written: an image with a program running in it
	 * is not free to be laid over, and the zeroing below would take that
	 * program's data out from under it.
	 */
	if(p9procbusy(progbase)){
		print("p9 exec: %s is already running at %#llux; it is one image and cannot be two programs\n",
			name, progbase);
		p9close(fd);
		return -1;
	}
	adata = (progbase + tseg + 4095) & ~(uvlong)4095;
	imgsz = (adata + datasz + bsssz + 4095) & ~(uvlong)4095;
	imgsz -= progbase;

	/*
	 * The address space, from the kernel: a region this task may write
	 * a program into and then run.  Everything after this is the
	 * library's own work.
	 */
	/* a program at a base of its own needs exactly its own image */
	base = attachfor(name, progbase, imgsz, imgsz);
	if(base == nil){
		p9close(fd);
		return -1;
	}
	print("p9 exec: %s: text %llud, data %llud, bss %llud; %llud bytes of address space at %#llux, entry %#llux\n",
		name, textsz, datasz, bsssz, imgsz, progbase, entry);

	/* a fresh image: whatever a previous run of it left is not its own */
	memset(base, 0, (long)imgsz);
	/* the text, its header with it, exactly as the file has it */
	p9seek(fd, 0, 0);
	if((n = readall(fd, base, (long)tseg)) != (long)tseg){
		print("p9 exec: %s: read %ld of %llud text bytes\n", name, n, tseg);
		p9close(fd);
		return -1;
	}
	/* the data, on the page after it; the bss after that is already zero */
	if(datasz > 0){
		p9seek(fd, (vlong)tseg, 0);
		if((n = readall(fd, base + (adata - progbase), (long)datasz)) != (long)datasz){
			print("p9 exec: %s: read %ld of %llud data bytes\n", name, n, datasz);
			p9close(fd);
			return -1;
		}
	}
	p9close(fd);
	*entryp = entry;
	*basep = progbase;
	return 0;
}

/*
 * Is this file a relocatable module rather than an ordinary program?
 * The magic says so: 6l -u sets the top bit of it.  Asked before
 * loading, so that spawn knows whether it needs a slot.
 */
int
p9isreloc(char *name)
{
	uchar hdr[4];
	uvlong magic;
	int fd;

	if((fd = p9open(name, OREAD)) < 0)
		return 0;
	if(readall(fd, hdr, sizeof hdr) != sizeof hdr){
		p9close(fd);
		return 0;
	}
	p9close(fd);
	magic = be(hdr, 4);
	return (magic & 0x80000000) != 0 && (magic & 0xffff) == 0x8a97;
}

/*
 * Load a relocatable module and lay it at a base of the caller's
 * choosing.
 *
 * p9load above lays a program at the address it was linked for, which is
 * why p9lib.h has a fixed base per program and why two instances of one
 * image cannot run at once.  A module built with 6l -u has no address of
 * its own - the linker sets INITTEXT and INITDAT to 0 - and carries a
 * table of every absolute address in it, so it can be laid anywhere and
 * corrected.
 *
 * The layout is not the a.out one.  A module is loaded contiguously,
 * text then data then bss with no page between them, because that is
 * what its relocations were computed against: each one adds a single
 * base, so text and data must keep the distance the linker gave them.
 * libdynld/dynld.c is where that is written down for the rest of the
 * tree, and this follows it.
 *
 * The table sits after the symbol table: a four-byte length, an import
 * count, then a relocation count, then one entry each - a byte whose top
 * two bits say how wide the offset delta is and whose low four are the
 * mode, then the delta.  Mode 0 is an absolute reference to a defined
 * symbol, and applying it is what libdynld/dynld-amd64.c does: read a
 * uintptr at the offset, add the base, write it back.  The other modes
 * take their value from the import table, which a self-contained
 * program does not have, so a module with imports is refused by name
 * rather than half-loaded.
 *
 * The entry is offset 0, which is p9start: the same invariant the
 * ordinary loader relies on - p9crt.c linked first, p9start first in its
 * text - and with the text linked at 0 it is simply 0.  The module's
 * header entry is NOT that; with -u the linker points it at the export
 * table, which is why nothing here reads it.  buildreloc.sh checks the
 * offset against the module's own symbol table.
 */
static int
readat(int fd, vlong off, void *buf, long n)
{
	p9seek(fd, off, 0);
	return readall(fd, buf, n) == n;
}

int
p9loadreloc(char *name, uvlong progbase, uvlong *entryp, uvlong *basep)
{
	uchar hdr[40], rh[12];
	uvlong magic, textsz, datasz, bsssz, hdrsz, symsz, spsz, pcsz;
	uvlong imgsz, relsize, off, a;
	uchar *base, *rel, *rp, *ep;
	int fd, i, nimport, nrel, m, w;
	long n;

	if((fd = p9open(name, OREAD)) < 0){
		print("p9 reloc: cannot open %s through my own name space\n", name);
		return -1;
	}
	if(readall(fd, hdr, sizeof hdr) != sizeof hdr){
		print("p9 reloc: %s: no header\n", name);
		p9close(fd);
		return -1;
	}
	magic = be(hdr, 4);
	if((magic & 0x80000000) == 0 || (magic & 0xffff) != 0x8a97){
		print("p9 reloc: %s: not an amd64 loadable module (magic %#llux)\n", name, magic);
		p9close(fd);
		return -1;
	}
	textsz = be(hdr+4, 4);
	datasz = be(hdr+8, 4);
	bsssz = be(hdr+12, 4);
	symsz = be(hdr+16, 4);
	spsz = be(hdr+24, 4);
	pcsz = be(hdr+28, 4);
	hdrsz = 40;

	if((progbase & 4095) != 0 || progbase < (uvlong)(uintptr)end){
		print("p9 reloc: %s: %#llux is not a page boundary above my own image (%#llux)\n",
			name, progbase, (uvlong)(uintptr)end);
		p9close(fd);
		return -1;
	}
	if(p9procbusy(progbase)){
		print("p9 reloc: %s: something is already running at %#llux\n", name, progbase);
		p9close(fd);
		return -1;
	}

	imgsz = (textsz + datasz + bsssz + 4095) & ~(uvlong)4095;
	/*
	 * A module goes in a slot, and the slot is the size a module may
	 * be.  This is the check that was missing: nothing sized a slot to
	 * its module, so a module larger than the spacing would have been
	 * laid over the next slot's ground and two of them would have been
	 * the same memory.
	 */
	if(imgsz > (uvlong)P9relocslot){
		print("p9 reloc: %s is %llud bytes and a slot is %d; it does not fit one\n",
			name, imgsz, P9relocslot);
		p9close(fd);
		return -1;
	}
	/*
	 * The whole slot is asked for, not this module's size: the slot is
	 * used again by the next module laid in it, which may be larger.
	 */
	base = attachfor(name, progbase, imgsz, (uvlong)P9relocslot);
	if(base == nil){
		p9close(fd);
		return -1;
	}

	/* text and data, adjacent, then the bss zeroed after them */
	memset(base, 0, (long)imgsz);
	if(!readat(fd, (vlong)hdrsz, base, (long)(textsz + datasz))){
		print("p9 reloc: %s: short read of text and data\n", name);
		p9close(fd);
		return -1;
	}

	/* the table, after the symbol table */
	off = hdrsz + textsz + datasz + symsz + spsz + pcsz;
	if(!readat(fd, (vlong)off, rh, 4)){
		print("p9 reloc: %s: no relocation table\n", name);
		p9close(fd);
		return -1;
	}
	relsize = be(rh, 4);
	if(relsize < 8 || relsize > 1024*1024){
		print("p9 reloc: %s: relocation table is %llud bytes, which is not a size it can be\n",
			name, relsize);
		p9close(fd);
		return -1;
	}
	rel = malloc((long)relsize);
	if(rel == nil){
		print("p9 reloc: %s: no room for %llud bytes of relocation table\n", name, relsize);
		p9close(fd);
		return -1;
	}
	if(!readat(fd, (vlong)(off + 4), rel, (long)relsize)){
		print("p9 reloc: %s: short read of the relocation table\n", name);
		free(rel);
		p9close(fd);
		return -1;
	}
	p9close(fd);

	rp = rel;
	ep = rel + relsize;
	nimport = (int)be(rp, 4);
	rp += 4;
	if(nimport != 0){
		print("p9 reloc: %s wants %d imported symbols; this loader resolves none\n",
			name, nimport);
		free(rel);
		return -1;
	}
	nrel = (int)be(rp, 4);
	rp += 4;
	a = 0;
	for(i = 0; i < nrel; i++){
		if(rp >= ep){
			print("p9 reloc: %s: the relocation table ends after %d of %d entries\n",
				name, i, nrel);
			free(rel);
			return -1;
		}
		m = *rp++;
		w = m >> 6;
		if(rp + (1 << w) > ep){
			print("p9 reloc: %s: relocation %d runs off the end of the table\n", name, i);
			free(rel);
			return -1;
		}
		switch(w){
		case 0:
			a += *rp++;
			break;
		case 1:
			a += be(rp, 2);
			rp += 2;
			break;
		default:
			a += be(rp, 4);
			rp += 4;
			break;
		}
		if((m & 0xf) != 0){
			print("p9 reloc: %s: relocation %d is mode %d, and only 0 has no import behind it\n",
				name, i, m & 0xf);
			free(rel);
			return -1;
		}
		if(a + sizeof(uintptr) > textsz + datasz){
			print("p9 reloc: %s: relocation %d is at %#llux, past the %llud bytes of text and data\n",
				name, i, a, textsz + datasz);
			free(rel);
			return -1;
		}
		*(uintptr*)(base + a) += (uintptr)base;
	}
	free(rel);

	print("p9 reloc: %s laid at %#llux, %llud bytes, %d absolute addresses corrected; it was linked at 0\n",
		name, progbase, imgsz, nrel);
	*entryp = progbase;		/* p9start is offset 0: see above */
	*basep = progbase;
	return 0;
}


/*
 * Load and run the program named in this task's name space, with the
 * argument vector given, to completion on this flow of control.
 * Returns 0 when it ran, -1 when it could not be loaded.
 */
int
p9exec(char *name, char **argv)
{
	uvlong entry, progbase;
	int std[3], slot;

	/*
	 * A module has no address, so this takes a slot for it and gives it
	 * back when the program returns; an ordinary program is laid at its
	 * own address as before.
	 */
	slot = -1;
	if(p9isreloc(name)){
		if((slot = p9relocalloc()) < 0){
			print("p9 exec: %s: no free relocation slot\n", name);
			return -1;
		}
		if(p9loadreloc(name, p9relocaddr(slot), &entry, &progbase) < 0){
			p9relocfree(slot);
			return -1;
		}
	} else if(p9load(name, &entry, &progbase) < 0)	/* it refuses an image already running */
		return -1;
	USED(progbase);
	/* its standard descriptors are the machine's console, which the
	 * personality does not hold: -1 says so */
	std[0] = std[1] = std[2] = -1;
	print("p9 exec: entering %s at %#llux with the personality's own name space under it\n", name, entry);
	/*
	 * A program run to completion runs on the personality's own flow of
	 * control, so what it changes about that flow it changes for the
	 * personality.  rfork gives it a Pgrp, an Egrp or an Fgrp of its
	 * own by putting one in up->; chdir puts a Chan in up->dot.  None
	 * of those is restored by the program, and a spawned program has
	 * nothing to restore because its flow ends - this one's does not.
	 * So they are saved here and put back, and the personality goes on
	 * with the name space, environment, descriptors and working
	 * directory it had.
	 *
	 * What a program made for itself is closed; what it was given is
	 * not, because every flow holds those by pointer with no count.
	 */
	p9saveflow();
	p9execstatus = nil;
	if(setjmp(p9execjmp) == 0)
		((void(*)(P9lib*, char**, int*))(uintptr)entry)(p9libtable(), argv, std);
	else
		print("p9 exec: %s exited with status \"%s\", into the personality that loaded it, not out of the task\n",
			name, p9execstatus == nil ? "" : p9execstatus);
	p9restoreflow(name);
	/*
	 * A program may have made flows of control of its own, and one of
	 * them may still be running in its image.  The personality must not
	 * go on to load something else over it.
	 */
	p9procwaitinproc();
	if(slot >= 0)
		p9relocfree(slot);
	print("p9 exec: %s returned; the personality is still here, its name space never reloaded\n", name);
	return 0;
}

/*
 * The same, for a relocatable module, at a base the caller names.  What
 * this is for is the thing the fixed bases cannot do: the module has no
 * address of its own, so the caller chooses, and the same module can be
 * laid at a second address while the first is still there.
 */
int
p9execreloc(char *name, char **argv, uvlong progbase)
{
	uvlong entry, gotbase;
	int std[3], slot;

	/*
	 * The caller names the slot, so the allocator is told rather than
	 * asked: a slot laid in without being claimed is a slot the
	 * allocator would still hand to somebody else.
	 */
	slot = p9relocslotof(progbase);
	if(slot < 0 || p9relocclaim(slot) < 0){
		print("p9 exec: %s: %#llux is not a free relocation slot\n", name, progbase);
		return -1;
	}
	if(p9loadreloc(name, progbase, &entry, &gotbase) < 0){
		p9relocfree(slot);
		return -1;
	}
	USED(gotbase);
	std[0] = std[1] = std[2] = -1;
	print("p9 exec: entering %s at %#llux, where it was put rather than where it was linked\n",
		name, entry);
	p9execstatus = nil;
	if(setjmp(p9execjmp) == 0)
		((void(*)(P9lib*, char**, int*))(uintptr)entry)(p9libtable(), argv, std);
	else
		print("p9 exec: %s exited with status \"%s\", into the personality that loaded it\n",
			name, p9execstatus == nil ? "" : p9execstatus);
	p9procwaitinproc();
	p9relocfree(slot);
	print("p9 exec: %s returned; the personality is still here\n", name);
	return 0;
}
