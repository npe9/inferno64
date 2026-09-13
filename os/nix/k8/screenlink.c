#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void (*drawscreeninit)(void);

void
screenlinklink(void)
{
	drawscreeninit = bochsscreeninit;
}
