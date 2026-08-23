/*
 * SiFive SPI0 — NOR flash @ SPI0, MMC-SPI @ SPI1 on sifive_u.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

#ifndef SPI0
#define SPI0	0
#endif
#ifndef SPI1
#define SPI1	0
#endif

static void
spiinit1(uintptr base, char *name)
{
	u32 *r;

	if(base == 0)
		return;
	r = (u32*)base;
	r[SspiSckdiv/4] = 8;
	r[SspiFmt/4] = (8<<16);	/* 8-bit frames */
	print("spi ");
	print(name);
	print(" at ");
	print("%#p", base);
	print(" (stub)\n");
}

void
spiinit(void)
{
	spiinit1((uintptr)SPI0, "spi0-nor");
	spiinit1((uintptr)SPI1, "spi1-mmc");
}
