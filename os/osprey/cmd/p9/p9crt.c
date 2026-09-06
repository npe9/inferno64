/*
 * The library operating system as a program's libc.
 *
 * An ordinary Plan 9 program calls open, read, write and close, and on
 * Plan 9 those are system calls.  Here they are not: the file system is
 * a library in the program's own address space, and this is what makes
 * the program's own libc call it.  Each of these definitions comes
 * before libc.a on the link line, so the linker takes this one and never
 * pulls libc's system-call stub for it - the program's source is
 * unchanged and does not know.
 *
 * What is still a trap is what the personality does not hold: the
 * machine's console (descriptors 0, 1 and 2, through the microkernel's
 * pwrite) and nothing else.  Even exit is not a trap: a program that
 * ends returns to the personality that loaded it, which goes on running.
 *
 * The heap is the program's own, a fixed arena in its bss.  brk on this
 * address space is the personality's business - its segments are laid
 * out around this program, not below it - so a loaded program does not
 * ask the kernel for memory, it brings its own.
 */
#include <u.h>
#include <libc.h>
#include "p9lib.h"

P9lib *p9lib;

extern void startboot(char *argv0, char **argv);

/*
 * p9start must be the first thing in this file: it is the first thing in
 * the linked program's text, and that is how the loader recovers the
 * address the program was linked at (p9exec.c).  Everything else, the
 * descriptor table below included, comes after it.
 */
static void fdinit(int *std);
static int fdof(int fd);
static int fdnew(int pfd);

void
p9start(P9lib *lib, char **argv, int *std)
{
	static char *noargv[] = { "prog", nil };

	fdinit(std);
	p9lib = lib;
	if(lib == nil || lib->version != P9libversion){
		/* nothing to call: say so on the console, which is the kernel's */
		char *m = "p9crt: the library handed me a table I do not know\n";
		pwrite(2, m, strlen(m), -1LL);
		return;
	}
	if(argv == nil || argv[0] == nil)
		argv = noargv;
	startboot(argv[0], argv);
	lib->exits(nil);
}
/*
 * The program's own descriptor table.
 *
 * The personality's descriptors are its own small integers and it hands
 * out whatever is free, which may be 0, 1 or 2 - and for a program those
 * three are the console, which the personality does not hold.  Without a
 * table of its own a program that opened a file and got 1 would write
 * its output into that file, or into the console, by luck rather than by
 * meaning.  So the program keeps a table, the way the buddy keeps one
 * for the legacy binary it serves: every file the program opens is
 * numbered from three up and stands for a descriptor of the
 * personality's.
 *
 * 0, 1 and 2 are what the loader handed the program in std: a
 * descriptor of the personality's when it was started with one - a pipe
 * from a shell, say - and the machine's console when it was not, which
 * is what a program the personality runs itself gets.
 */
enum {
	Nfd	= 32,
	Fdfree	= -1,
	Fdcons	= -2,
};
static int fdmap[Nfd];

static void
fdinit(int *std)
{
	int i;

	for(i = 0; i < Nfd; i++)
		fdmap[i] = Fdfree;
	for(i = 0; i < 3; i++)
		fdmap[i] = (std == nil || std[i] < 0) ? Fdcons : std[i];
}

/* the personality's descriptor a program's number stands for, or Fdfree */
static int
fdof(int fd)
{
	if(fd < 0 || fd >= Nfd)
		return Fdfree;
	return fdmap[fd];
}

/* a program number for a personality descriptor just opened */
static int
fdnew(int pfd)
{
	int i;

	if(pfd < 0)
		return -1;
	for(i = 3; i < Nfd; i++)
		if(fdmap[i] == Fdfree){
			fdmap[i] = pfd;
			return i;
		}
	p9lib->close(pfd);
	return -1;
}


/*
 * The file calls, into the personality.  Nothing here traps.
 */
int
open(char *name, int mode)
{
	return fdnew(p9lib->open(name, mode));
}

int
create(char *name, int mode, ulong perm)
{
	return fdnew(p9lib->create(name, mode, perm));
}

long
read(int fd, void *buf, long n)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return 0;		/* end of file on the console: nothing types here */
	if(pfd == Fdfree)
		return -1;
	return p9lib->read(pfd, buf, n);
}

/*
 * write: the console is the machine's, not the personality's, so 0, 1
 * and 2 go to the microkernel through the one call it offers for it and
 * everything else goes to the file system beside us.
 */
long
write(int fd, void *buf, long n)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return pwrite(fd, buf, n, -1LL);
	if(pfd == Fdfree)
		return -1;
	return p9lib->write(pfd, buf, n);
}

int
close(int fd)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdfree)
		return -1;
	if(pfd != Fdcons)
		p9lib->close(pfd);
	fdmap[fd] = Fdfree;
	return 0;
}

vlong
seek(int fd, vlong off, int type)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd < 0)
		return -1;
	return p9lib->seek(pfd, off, type);
}

/*
 * dup(old, new): the personality's descriptor table allocates the lowest
 * free number, which is dup(old, -1); a dup onto a named descriptor is
 * not offered and is refused rather than quietly done wrong.
 */
int
dup(int oldfd, int newfd)
{
	int pfd;

	pfd = fdof(oldfd);
	if(pfd == Fdfree)
		return -1;
	if(newfd != -1)
		return -1;		/* a dup onto a named descriptor is not offered */
	if(pfd == Fdcons){
		int i;

		for(i = 3; i < Nfd; i++)
			if(fdmap[i] == Fdfree){
				fdmap[i] = Fdcons;
				return i;
			}
		return -1;
	}
	return fdnew(p9lib->dup(pfd));
}

/*
 * fd2path(2) yields 0, not a count; the personality answers with the
 * number of bytes it wrote, which is what says the path fitted.
 */
int
fd2path(int fd, char *buf, int nbuf)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdfree)
		return -1;
	if(pfd == Fdcons){
		if(nbuf < 10)
			return -1;
		strcpy(buf, "/dev/cons");
		return 0;
	}
	return p9lib->fd2path(pfd, buf, nbuf) > 0 ? 0 : -1;
}

/*
 * Processes, for a program that starts other programs.  A pipe is the
 * personality's, in the program's own numbering; spawn is given the
 * program's numbers for what the child's standard input and output are
 * to be and hands the personality its own; a program number that is the
 * console, or is not open, is -1 - the child gets the console for it.
 */
int
pipe(int fd[2])
{
	int p[2];

	if(p9lib->pipe(p) < 0)
		return -1;
	fd[0] = fdnew(p[0]);
	fd[1] = fdnew(p[1]);
	if(fd[0] < 0 || fd[1] < 0){
		/* fdnew closes what it could not find a number for, so what is
		 * still open here is only what it did place */
		if(fd[0] >= 0)
			close(fd[0]);
		if(fd[1] >= 0)
			close(fd[1]);
		return -1;
	}
	return 0;
}

int
spawn(char *name, char **argv, int in, int out)
{
	int std[3];

	/* a number that is the console, or is not open, is Fdcons or
	 * Fdfree: both negative, and both mean the console to the child */
	std[0] = in < 0 || fdof(in) < 0 ? -1 : fdof(in);
	std[1] = out < 0 || fdof(out) < 0 ? -1 : fdof(out);
	std[2] = -1;
	return p9lib->spawn(name, argv, std);
}

int
awaitpid(int pid, char *status, int nstatus)
{
	return p9lib->wait(pid, status, nstatus);
}

void
exits(char *status)
{
	p9lib->exits(status);
	for(;;)			/* the loader does not return here */
		;
}

/*
 * The program's own heap, in its own bss: enough for a command, and a
 * refusal rather than a wrong answer when it runs out.
 */
enum { Nheap = 1024*1024 };
static char heaparena[Nheap];
static long heapused;

void*
sbrk(uvlong n)
{
	char *p;

	if(heapused + (long)n > Nheap)
		return (void*)-1;
	p = heaparena + heapused;
	heapused += n;
	return p;
}

int
brk(void *p)
{
	long want;

	want = (char*)p - heaparena;
	if(want < 0 || want > Nheap)
		return -1;
	heapused = want;
	return 0;
}
