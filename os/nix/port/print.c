#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

static Lock fmtl;

void
_fmtlock(void)
{
	lock(&fmtl);
}

void
_fmtunlock(void)
{
	unlock(&fmtl);
}

int
_efgfmt(Fmt*)
{
	return -1;
}

/*
 * %r in the kernel.  The fmt library the kernel links, the tree's
 * libkern, names errfmt in its verb table; upstream's libc supplies one
 * built on rerrstr, which is a system call.  The 9front kernel in this
 * tree defines it this way in its own port/print.c.
 */
int
errfmt(Fmt *f)
{
	if(up == nil)
		return fmtstrcpy(f, "");
	return fmtstrcpy(f, up->errstr);
}

int
mregfmt(Fmt* f)
{
	Mreg mreg;

	mreg = va_arg(f->args, Mreg);
	if(sizeof(Mreg) == sizeof(uvlong))
		return fmtprint(f, "%#16.16llux", (uvlong)mreg);
	return fmtprint(f, "%#8.8ux", (uint)mreg);
}

void
fmtinit(void)
{
	quotefmtinstall();
	fmtinstall('m', mregfmt);
}
