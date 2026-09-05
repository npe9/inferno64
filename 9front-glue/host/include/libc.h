/*
 * A host tool's <libc.h>: this tree's host lib9.  See u.h beside it.
 */
#include <lib9.h>

/*
 * And the Plan 9 spellings of the time functions.  They live in
 * time.h beside this, with the note that explains them, but a Plan 9
 * source says "#include <libc.h>" and means to have ctime, localtime
 * and gmtime with it: disk/9660 calls gmtime without ever naming
 * time.h, and got the host's, which takes a pointer and was handed a
 * number.  The host directory is searched first, so this is that
 * time.h and not the system one.
 */
#include <time.h>

/*
 * The one Plan 9 mode bit this tree's lib9.h has not got.  9front's
 * libc.h has it and libdisk's proto reader uses it: a proto file can
 * mark an entry temporary, and a bit that does not exist cannot be
 * read or written.  Defined here rather than in lib9.h because that
 * header exists once per platform, a dozen committed copies of it,
 * and nothing but a host tool built against 9front's sources wants
 * this.
 */
#ifndef DMTMP
#define DMTMP	0x04000000	/* mode bit for non-backed-up files */
#endif

/*
 * Plan 9's USED takes any number of arguments; this tree's lib9.h
 * declares it with one, and a 9front source that names two -- as
 * disk/9660's plan9.c does in fdtruncate -- does not compile.  The
 * arguments are only there to say "deliberately unused", so a
 * variadic macro that expands to nothing says the same thing.
 */
#undef USED
#define USED(...)	do{}while(0)

/*
 * 9front's default 9P transfer size.  This tree's lib9.h has not got
 * it and a host tool that only ever wants a buffer size -- aux/aout2efi
 * copies the loader's text through one -- would otherwise not compile.
 * The value is 9front's own, from sys/include/libc.h.
 */
#ifndef IOUNIT
#define IOUNIT	32768U	/* default buffer size for 9p io */
#endif
