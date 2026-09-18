/*
 * The system-call stubs a 386 libc needs, which on amd64 are not built
 * at all.
 *
 * On a real Plan 9 these are generated: libc/9syscall/mkfile reads a
 * sys.h and the kernel's table and writes one stub per call.  This tree
 * imports 9front's libc source but not that generator, and takes the
 * stubs for amd64 out of the prebuilt archive 9front/amd64/lib/libc.a -
 * build9front.sh says so, and says why: "there is no source file to
 * build here; they are also small and every one of them is readable."
 * There is no prebuilt 386 archive, so for that object type the same
 * twenty-one calls are written out.
 *
 * Which twenty-one is measured rather than chosen: all 196 portable
 * files of 9front's libc here compile with 8c, and these are the
 * symbols left undefined that the prebuilt archive answers on amd64 -
 * the same names, member for member, as iar t lists in it.
 *
 * The convention is this kernel's own, named by its trap entry rather
 * than assumed: os/osprey/pc/trap.c takes the call number from AX and
 * the arguments from the user stack at sp+BY2WD, and os/osprey/pc/l.s
 * vectors INT $64 to _syscallintr.  So a stub is the number in AX and
 * the interrupt; the arguments are already where the kernel looks.
 * os/osprey/boot/bootsys-386.s is the same shape for the nine calls the
 * boot programs and the file server use.
 *
 * The numbers are os/osprey/port/sys.h's, which is the kernel's table.
 *
 * seek is _seek here, as it is in the archive on amd64: the raw call
 * takes a place to put the result, and the vlong-returning seek(2) that
 * wraps it is C, in 9front/src/libc/amd64/_seek.c, which compiles for
 * either object type.
 *
 * The two words at the end are libc's own and are not calls at all.
 * Upstream they are the machine directory's argv0.s, which this tree
 * has for amd64 (9front/src/libc/amd64/argv0.s, eight bytes each) and
 * not for 386; four bytes each here, which is what a pointer is.
 */
#define SYSCALL1(name, number) \
	TEXT name(SB), 1, $0; \
	MOVL $number, AX; \
	INT $64; \
	RET

SYSCALL1(close, 4)
SYSCALL1(exec, 7)
SYSCALL1(_exits, 8)
SYSCALL1(open, 14)
SYSCALL1(sleep, 17)
SYSCALL1(rfork, 19)
SYSCALL1(create, 22)
SYSCALL1(fd2path, 23)
SYSCALL1(brk_, 24)
SYSCALL1(notify, 28)
SYSCALL1(noted, 29)
SYSCALL1(rendezvous, 34)
SYSCALL1(_seek, 39)
SYSCALL1(errstr, 41)
SYSCALL1(stat, 42)
SYSCALL1(fstat, 43)
SYSCALL1(wstat, 44)
SYSCALL1(fwstat, 45)
SYSCALL1(await, 47)
SYSCALL1(pread, 50)
SYSCALL1(pwrite, 51)

GLOBL	argv0(SB), $4
GLOBL	_tos(SB), $4
