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
};

enum {
	P9libversion	= 3,
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
	P9progbase2	= 0x1400000,	/* libcat */
	P9progbase3	= 0x1800000,	/* libwc, the far end of a pipeline */
	P9progbase4	= 0x1c00000,	/* libsh, the shell */
	P9progbase5	= 0x2000000,	/* libgen, the near end of a pipeline */
};
