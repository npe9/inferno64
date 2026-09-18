/*
 * libc's two words for 386, which upstream keeps in the machine
 * directory's argv0.s and this tree has for amd64 only
 * (9front/src/libc/amd64/argv0.s, eight bytes each).  Four bytes here,
 * which is what a pointer is.
 *
 * Their own file, and so their own archive member, for the reason the
 * stubs in sys-386.s are one member each: a program that defines one of
 * libc's names itself must not drag the rest in with it.
 */
GLOBL	argv0(SB), $4
GLOBL	_tos(SB), $4
