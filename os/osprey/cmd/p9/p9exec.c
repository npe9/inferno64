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

static void
p9execexits(char *status)
{
	p9execstatus = status;
	longjmp(p9execjmp, 1);
}

/*
 * Load and run the program named in this task's name space, with the
 * argument vector given.  Returns 0 when it ran, -1 when it could not
 * be loaded.
 */
int
p9exec(char *name, char **argv)
{
	uchar hdr[40];
	uvlong magic, textsz, datasz, bsssz, hdrsz, entry, tseg, adata, imgsz, progbase;
	uchar *base;
	P9lib lib;
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
	adata = (progbase + tseg + 4095) & ~(uvlong)4095;
	imgsz = (adata + datasz + bsssz + 4095) & ~(uvlong)4095;
	imgsz -= progbase;

	/*
	 * The address space, from the kernel: a region this task may write
	 * a program into and then run.  Everything after this is the
	 * library's own work.
	 */
	base = (uchar*)segattach(0, "code", (void*)(uintptr)progbase, (ulong)imgsz);
	if(base == (uchar*)-1 || (uvlong)(uintptr)base != progbase){
		print("p9 exec: the kernel would not give me %llud bytes of address space at %#llux for the program\n",
			imgsz, progbase);
		p9close(fd);
		return -1;
	}
	print("p9 exec: %s: text %llud, data %llud, bss %llud; %llud bytes of address space at %#llux, entry %#llux\n",
		name, textsz, datasz, bsssz, imgsz, progbase, entry);

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

	lib.version = P9libversion;
	lib.open = p9open;
	lib.create = p9create;
	lib.read = p9read;
	lib.write = p9write;
	lib.close = p9close;
	lib.seek = p9seek;
	lib.dup = p9dup;
	lib.fd2path = p9fd2path;
	lib.exits = p9execexits;
	print("p9 exec: entering %s at %#llux with the personality's own name space under it\n", name, entry);
	p9execstatus = nil;
	if(setjmp(p9execjmp) == 0)
		((void(*)(P9lib*, char**))(uintptr)entry)(&lib, argv);
	else
		print("p9 exec: %s exited with status \"%s\", into the personality that loaded it, not out of the task\n",
			name, p9execstatus == nil ? "" : p9execstatus);
	print("p9 exec: %s returned; the personality is still here, its name space never reloaded\n", name);
	return 0;
}
