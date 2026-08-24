#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "armv7m.h"

/*
 * What the MPS2 AN500 has that the shared ARMv7-M code cannot know: how
 * much memory, and the fact that both blocks of it are ordinary static
 * RAM with nothing to turn on first.
 */

void
archreset(void)
{
	/*
	 * Bring the console up before anything wants to say something.
	 * os/inferno/armv7m/main.c prints its first line before it has
	 * called uartconsole, and on a board whose console needs setting
	 * up that line is where a bad memory map first shows itself.
	 */
	uartboardinit();
	/*
	 * QEMU starts the core with caches and the FPU in their reset
	 * state and no clock tree to program, so there is nothing to do
	 * here.  A real board's archreset is where its clocks are set up;
	 * see os/inferno/teensy41/archteensy41.c.
	 */
}

extern char bdata[];

void
archconfinit(void)
{
	uintptr imgend;

	/*
	 * Bank 0 is what is left of the block the data segment was linked
	 * into, from the end of bss upwards; os/inferno/armv7m/main.c
	 * works that out from end and topofmem.
	 */
	conf.topofmem = TOPOFMEM;

	/*
	 * Bank 1 is what is left of the block the image was loaded into.
	 * The image is the text followed by the data, so it ends that far
	 * above the link address, and everything above that is free.
	 */
	imgend = (uintptr)etext + ((uintptr)edata - (uintptr)bdata);
	imgend = PGROUND(imgend);
	conf.base1 = imgend;
	conf.npage1 = (SSRAM1+SSRAM1SIZE - imgend)/BY2PG;
}

void
archconsole(void)
{
}

void
kbdinit(void)
{
}

void
idlehands(void)
{
	idle();
}
