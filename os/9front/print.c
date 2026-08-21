#include "u.h"
#include "../9front/lib.h"
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

int
errfmt(Fmt *f)
{
	if(up == nil)
		return fmtstrcpy(f, "");
	return fmtstrcpy(f, up->errstr);
}
