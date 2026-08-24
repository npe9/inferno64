/*
 * Serial console only.  None of these boards has a framebuffer wired up.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "screen.h"

void (*screenputs)(char*, int);

void
screeninit(void)
{
	screenputs = nil;
}

void
screenstats(void)
{
}
