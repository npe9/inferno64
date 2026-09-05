/*
 * A host tool's <libc.h>: this tree's host lib9.  See u.h beside it.
 */
#include <lib9.h>

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
