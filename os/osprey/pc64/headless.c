#include "u.h"
#include "../lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/* QEMU serial configuration: multiboot video data is deliberately ignored. */
char*
rgbmask2chan(char *buf, int, u32int, u32int, u32int)
{
	buf[0] = 0;
	return buf;
}

char*
vesabootscreenconf(char *s, char*, uchar*)
{
	return s;
}

void
i8042reset(void)
{
}

void
vmxshutdown(void)
{
}

void
vmxprocrestore(Proc*)
{
}
