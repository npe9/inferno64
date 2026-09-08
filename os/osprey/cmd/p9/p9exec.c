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
#include "libshprog.i"		/* uchar libshprog[]: the shell that runs on this personality */
#include "libgenprog.i"		/* uchar libgenprog[]: the near end of a pipeline */
#include "libdrawprog.i"		/* uchar libdrawprog[]: the program that draws */
#include "libthreadprog.i"		/* uchar libthreadprog[]: the program with threads in it */

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
	addbootfile("libsh", libshprog, sizeof libshprog);
	addbootfile("libgen", libgenprog, sizeof libgenprog);
	addbootfile("libdraw", libdrawprog, sizeof libdrawprog);
	addbootfile("libthread", libthreadprog, sizeof libthreadprog);
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
enum { Nattach = 8 };
static uvlong attached[Nattach];
static int nattached;

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
	int fd, i, have;
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
	have = 0;
	for(i = 0; i < nattached; i++)
		if(attached[i] == progbase)
			have = 1;
	if(have)
		base = (uchar*)(uintptr)progbase;
	else {
		base = (uchar*)segattach(0, "code", (void*)(uintptr)progbase, (ulong)imgsz);
		if(base == (uchar*)-1 || (uvlong)(uintptr)base != progbase){
			print("p9 exec: the kernel would not give me %llud bytes of address space at %#llux for the program\n",
				imgsz, progbase);
			p9close(fd);
			return -1;
		}
		if(nattached < Nattach)
			attached[nattached++] = progbase;
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
 * Load and run the program named in this task's name space, with the
 * argument vector given, to completion on this flow of control.
 * Returns 0 when it ran, -1 when it could not be loaded.
 */
int
p9exec(char *name, char **argv)
{
	uvlong entry, progbase;
	int std[3];

	if(p9load(name, &entry, &progbase) < 0)	/* it refuses an image already running */
		return -1;
	USED(progbase);
	/* its standard descriptors are the machine's console, which the
	 * personality does not hold: -1 says so */
	std[0] = std[1] = std[2] = -1;
	print("p9 exec: entering %s at %#llux with the personality's own name space under it\n", name, entry);
	p9execstatus = nil;
	if(setjmp(p9execjmp) == 0)
		((void(*)(P9lib*, char**, int*))(uintptr)entry)(p9libtable(), argv, std);
	else
		print("p9 exec: %s exited with status \"%s\", into the personality that loaded it, not out of the task\n",
			name, p9execstatus == nil ? "" : p9execstatus);
	/*
	 * A program may have made flows of control of its own, and one of
	 * them may still be running in its image.  The personality must not
	 * go on to load something else over it.
	 */
	p9procwaitinproc();
	print("p9 exec: %s returned; the personality is still here, its name space never reloaded\n", name);
	return 0;
}
