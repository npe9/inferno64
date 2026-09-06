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
 */
typedef struct P9lib P9lib;
struct P9lib {
	int	version;
	int	(*open)(char *name, int mode);
	int	(*create)(char *name, int mode, ulong perm);
	long	(*read)(int fd, void *buf, long n);
	long	(*write)(int fd, void *buf, long n);
	void	(*close)(int fd);
};

enum {
	P9libversion	= 1,
	/*
	 * Where a loaded program is linked and laid down: well above the
	 * personality's own image (its bss ends near 7MB) and well below the
	 * stack.  The program is linked at this address and the library
	 * asks the kernel for the address space at it, so the two agree by
	 * a constant rather than by relocation, which this compiler does
	 * not do.
	 */
	P9progbase	= 0x1000000,
};
