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
 * getenv, with Plan 9's contract rather than POSIX's: the value is a
 * copy the caller owns and frees.  9front's code is written to that
 * -- libdisk's proto reader does
 *
 *	s = getenv(*buf+1);
 *	...
 *	free(*buf);
 *	*buf = s;
 *
 * and frees it later -- and against the C library's getenv, which
 * returns a pointer into the environment itself, that free aborts the
 * program.  Defining it here gives every host tool built from 9front
 * sources the semantics those sources were written against; a tool
 * that does not free what it gets leaks the copy, which is a few
 * bytes once.
 *
 * The environment is walked here rather than asked through the C
 * library's own getenv, because this definition is that name: calling
 * it would be calling itself.
 */
extern char **environ;

char*
getenv(const char *name)
{
	char **p;
	int n;

	n = strlen(name);
	for(p = environ; *p != nil; p++)
		if(strncmp(*p, name, n) == 0 && (*p)[n] == '=')
			return strdup(*p + n + 1);
	return nil;
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
#undef localtime
#undef gmtime
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
 * Plan 9's localtime and gmtime, over the host's: the seconds by
 * value and a Tm back, rather than a pointer to the seconds and a
 * struct tm.  The two structures agree field for field as far as
 * yday; what Plan 9 has after that is the zone name and its offset,
 * which the host keeps under different names, and disk/9660 -- the
 * caller that found this -- reads neither.  They are filled anyway so
 * that the next caller is not surprised.
 */
static Tm*
fillTm(Tm *tm, struct tm *t)
{
	if(t == nil)
		return nil;
	tm->sec = t->tm_sec;
	tm->min = t->tm_min;
	tm->hour = t->tm_hour;
	tm->mday = t->tm_mday;
	tm->mon = t->tm_mon;
	tm->year = t->tm_year;
	tm->wday = t->tm_wday;
	tm->yday = t->tm_yday;
	strncpy(tm->zone, t->tm_zone ? t->tm_zone : "", sizeof tm->zone - 1);
	tm->zone[sizeof tm->zone - 1] = 0;
	tm->tzoff = t->tm_gmtoff;
	return tm;
}

Tm*
_p9localtime(long sec)
{
	static Tm tm;
	time_t tt;

	tt = sec;
	return fillTm(&tm, localtime(&tt));
}

Tm*
_p9gmtime(long sec)
{
	static Tm tm;
	time_t tt;

	tt = sec;
	return fillTm(&tm, gmtime(&tt));
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
