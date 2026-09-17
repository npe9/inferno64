#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * QEMU serial configuration: multiboot video data is deliberately
 * ignored.  The same file stands in pc64; it is two hooks the vga
 * driver would otherwise supply, and a configuration with no vga has to
 * supply them itself, so each machine directory carries its own rather
 * than one naming the other's.
 */
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
