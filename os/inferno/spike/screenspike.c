/*
 * Serial-only board — no ramfb/draw yet.
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

/* was screensifiveu.c */
