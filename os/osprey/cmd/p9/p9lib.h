/*
 * What a library operating system hands a program it has loaded: the
 * entry points of its own name space, as ordinary function pointers in
 * the one address space they share.
 *
 * This is the exokernel shape of the paper, made concrete.  The program
 * does not trap to a kernel to open a file and it does not ask a peer
 * over a ring: it calls the personality, which is code already in memory
 * beside it, the way it would call any library.  Only the microkernel's
 * own services - the console, exit, address space - are traps.
 *
 * The two are linked separately, so what crosses between them is this
 * table and nothing else; version says which table, and a program that
 * does not know it refuses rather than calls into the wrong offsets.
 *
 * exits is the loader's own: a program that ends does not end the task,
 * it returns to the personality that called it.
 *
 * A loaded program is entered as
 *	void p9start(P9lib *lib, char **argv, int *std)
 * and p9start must be the first thing in its text, since that is how the
 * loader recovers the address the program was linked at (p9exec.c).
 * std[0..2] are the descriptors of the personality's that the program is
 * to use for its standard input, output and error, or -1 for the
 * machine's console, which the personality does not hold.
 *
 * spawn runs a program on a flow of control of its own, with a
 * descriptor table of its own holding only what std names, and answers
 * with a number wait takes.  This is what a library operating system has
 * instead of fork and exec: a program in one address space cannot split
 * its own thread of control the way rfork(RFPROC) does, so the library
 * does not pretend to - it starts a program, which is what a shell
 * wanted fork and exec for.
 */
typedef struct P9lib P9lib;
struct P9lib {
	int	version;
	int	(*open)(char *name, int mode);
	int	(*create)(char *name, int mode, ulong perm);
	long	(*read)(int fd, void *buf, long n);
	long	(*write)(int fd, void *buf, long n);
	void	(*close)(int fd);
	vlong	(*seek)(int fd, vlong off, int type);
	int	(*dup)(int fd);
	int	(*fd2path)(int fd, char *buf, int nbuf);
	void	(*exits)(char *status);
	int	(*pipe)(int fd[2]);
	int	(*spawn)(char *name, char **argv, int *std);
	int	(*wait)(int pid, char *status, int nstatus);
	/*
	 * And why the last call failed.  The name space keeps its reason in
	 * up->errstr, and without a way to ask for it a program's %r was
	 * empty - libc's errstr is a system call, and the microkernel does
	 * not answer it.  A library operating system that refuses should be
	 * able to say what it refused, in the program's own words.
	 */
	int	(*errstr)(char *buf, uint nbuf);
	/*
	 * And the calls a real library wants that the first table did not
	 * have.  Each of these was libc's system-call stub before, which on
	 * this personality is a trap the microkernel does not answer: a
	 * program that reached one did not get an error, it faulted.  They
	 * are here because unmodified libdraw reaches them - namedimage
	 * preads the draw device's control file, openfont fstats a font,
	 * and libc's own lock sleeps while it spins.
	 */
	long	(*pread)(int fd, void *buf, long n, vlong off);
	long	(*pwrite)(int fd, void *buf, long n, vlong off);
	int	(*stat)(char *name, uchar *edir, int nedir);
	int	(*fstat)(int fd, uchar *edir, int nedir);
	int	(*sleep)(long ms);
	/*
	 * And what a program needs to have more than one flow of control
	 * of its own.  This is what a library operating system has instead
	 * of rfork(RFPROC|RFMEM): the memory is shared because there is one
	 * address space, so what is new is only the flow of control - a
	 * kproc of the personality's cooperative scheduler.
	 *
	 * privalloc is the hard half.  privalloc(2) is one word that is the
	 * process's own, and a program takes the address of it once and
	 * then reads and writes it from every flow it has - libthread's
	 * _threadgetproc is a dereference of exactly one such pointer,
	 * captured in main.  So the word is at a fixed address and the
	 * scheduler swaps its contents at the switch.
	 *
	 * pid is the flow's own number, which is what getpid(2) is.  It is
	 * not _tos->pid: a program's Tos is in its image and its flows
	 * share it.
	 */
	void**	(*privalloc)(void);
	int	(*proccreate)(void (*f)(void*), void *arg);
	int	(*pid)(void);
	void*	(*rendezvous)(void *tag, void *val);
	/*
	 * And the name space itself, which the personality had for its own
	 * use and a program it loaded could not reach.  rio is what named
	 * these: linked against this library with the archive of system-call
	 * stubs left off, its undefined symbols are bind, mount, unmount and
	 * chdir - and rfork, exec, await and notify, which are the flow of
	 * control rather than the name space and are not here yet.
	 *
	 * A program that binds binds the personality's own name space,
	 * because there is one of it: the program and the library share an
	 * address space and a Pgrp both.  That is what a library operating
	 * system is.  Plan 9 separates them with rfork(RFNAMEG) and this
	 * personality has no such thing yet.
	 */
	int	(*bind)(char *name, char *old, int flag);
	int	(*mount)(int fd, char *old, int flag, char *spec);
	int	(*unmount)(char *name, char *old);
	int	(*chdir)(char *name);
};

enum {
	P9libversion	= 7,
	/*
	 * Where a loaded program is linked: well above the personality's own
	 * image (its bss ends near 7MB) and well below the stack.  The
	 * loader does not take this on trust - it works the address out of
	 * the binary's entry and refuses one that would land on the
	 * personality - so a program only has to be linked somewhere clear.
	 *
	 * A program is at the address it was linked for and this compiler
	 * does not relocate, so two of the same program cannot run at once;
	 * two different ones can, which is what a pipeline is.  Lifting that
	 * wants either relocation or every mutable thing in a program's
	 * image reached through a per-process pointer, and neither is here.
	 */
	P9progbase	= 0x1000000,	/* prog2, the first loaded program */
	P9progbase2	= 0x1400000,	/* free: libcat is a module now, and has no base */
	P9progbase3	= 0x1800000,	/* free: libwc is a module now, and has no base */
	P9progbase4	= 0x1c00000,	/* free: libsh is a module now, and has no base */
	P9progbase5	= 0x2000000,	/* libgen, the near end of a pipeline */
	P9progbase6	= 0x2400000,	/* libdraw, the program that draws */
	P9progbase7	= 0x2800000,	/* libthread, the program with threads in it */
	/*
	 * And the ground a relocatable module is laid on, which is not a
	 * base per program but a range with slots in it.  A module has no
	 * address of its own, so nothing here has to name one: the loader
	 * takes a free slot, and gives it back when the program ends.  Six
	 * of them, at the same spacing as the fixed bases above.
	 *
	 * Six rather than four because the shell is a module as well now
	 * and holds a slot for as long as its script runs, with its
	 * pipeline in the slots beside it: a three-stage pipeline under the
	 * shell is four at once, which four slots met exactly and with
	 * nothing to spare.
	 *
	 * This is the difference the whole thing is for.  Above, a program
	 * is its address, and two of one image cannot run at once because
	 * there is only the one address to run it at.  Below, an image is
	 * not anywhere in particular, and two of it can run at two slots.
	 */
	P9relocbase	= 0x2c00000,
	P9relocslot	= 0x400000,
	Nrelocslot	= 6,
};
