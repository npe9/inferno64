/*
 * What a host tool needs that this tree's host lib9 does not have.
 * 9front's libc provides _assert, which assert() expands to; lib9
 * does not.
 */
/*
 * fcntl first, and with the Darwin extensions asked for by name:
 * lib9.h asks for a POSIX-only namespace, under which F_GETPATH --
 * the only way to ask this system what a file descriptor is called --
 * is not declared.
 */
#define _DARWIN_C_SOURCE 1
#include <fcntl.h>

#include <lib9.h>
#include <time.h>

void
_assert(char *s)
{
	fprint(2, "assert failed: %s\n", s);
	abort();
}

/*
 * libmp calls mallocz, which 9front's libc has and lib9 does not.
 * mpc, the generator libsec and libauthsrv run over their .mp
 * sources, is linked against this tree's host libmp and wants it.
 */
void*
mallocz(ulong size, int clr)
{
	void *v;

	v = malloc(size);
	if(clr && v != nil)
		memset(v, 0, size);
	return v;
}

/*
 * Plan 9's ctime: the seconds by value, and a string with the time
 * zone in it, which is the format cpp's macro.c indexes into.  See
 * the note in host/include/time.h.
 */
#undef ctime
char*
_p9ctime(long sec)
{
	static char buf[64];
	time_t t;

	t = sec;
	strftime(buf, sizeof buf, "%a %b %e %H:%M:%S %Z %Y\n", localtime(&t));
	return buf;
}

/*
 * 9front's Bio lets a program hand it a function to call when a read
 * or a write fails, and yacc does that so a bad input is fatal rather
 * than quietly short.  The field it sets lives in 9front's Biobufhdr
 * and this tree's Bio has no equivalent, so there is nothing for this
 * to do but accept the handler and drop it.  What that costs: a Bio
 * error in the host yacc is reported by the return value alone, the
 * way it is everywhere else in this tree, instead of ending the
 * program.  Nothing else calls it.
 */
void
Blethal(void *bp, void (*errorf)(char*))
{
	USED(bp);
	USED(errorf);
}

/*
 * fd2path: the name a file descriptor was opened with.  9front's yacc
 * uses it in one message, to say where the temporary file it could
 * not reopen had gone.  Darwin has the same thing as an fcntl; where
 * there is no such fcntl the name is simply not available, and the
 * caller is told so the way Plan 9 tells it.
 */
int
fd2path(int fd, char *buf, int nbuf)
{
#ifdef F_GETPATH
	char path[1024];

	if(fcntl(fd, F_GETPATH, path) >= 0){
		strncpy(buf, path, nbuf);
		if(nbuf > 0)
			buf[nbuf-1] = 0;
		return 0;
	}
#else
	USED(fd);
#endif
	if(nbuf > 0)
		buf[0] = 0;
	return -1;
}
