#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"

/*
 * A frame buffer for a machine whose loader did not leave one.
 *
 * This is not the amd64 arrangement made to work on 386; it is a thing
 * neither machine had.  pc64 is booted by the EFI loader, which sets a
 * mode and writes *bootscreen into the configuration, and the port
 * layer reads it there (ospreyframebuffer in devosprey.c).  This tree
 * has no BIOS loader, so a 386 kernel loaded by qemu's multiboot loader
 * is handed no mode and no frame buffer at all, and the program that
 * draws to one was told there was none.
 *
 * The card qemu gives a 386 by default is its stdvga, which carries the
 * Bochs display interface: two I/O ports, an index and a data word, and
 * a register each for width, height, depth and an enable.  A mode is
 * set by writing them, and no BIOS call is needed - which matters,
 * because the kernel's other way to a mode is vgavesa.c, and that one
 * opens /dev/realmode through namec, a name space the microkernel does
 * not have.
 *
 * What this does not do: it sets the mode and answers where the memory
 * is.  It draws nothing, it owns no screen, and the kernel's own
 * console stays on the serial line and the text-mode CGA.  The frame
 * buffer is for the user-level driver that maps it, as on amd64.
 */
enum {
	Dispiindex	= 0x01CE,	/* index port */
	Dispidata	= 0x01CF,	/* data port */

	Id		= 0,		/* the registers, by index */
	Xres		= 1,
	Yres		= 2,
	Bpp		= 3,
	Enable		= 4,
	Virtwidth	= 6,
	Virtheight	= 7,
	Xoff		= 8,
	Yoff		= 9,

	Disabled	= 0x00,		/* the enable register's bits */
	Enabled		= 0x01,
	Lfb		= 0x40,		/* the memory is a linear frame buffer */

	Id0		= 0xB0C0,	/* what the ID register answers, oldest */
	Id5		= 0xB0C5,	/* and newest this knows of */

	Qemuvid		= 0x1234,	/* qemu's stdvga */
	Qemudid		= 0x1111,

	Fbw		= 1280,		/* the mode: what the drawing program expects */
	Fbh		= 800,
	Fbd		= 32,
};

static void
dispiw(int index, int v)
{
	outs(Dispiindex, index);
	outs(Dispidata, v);
}

static int
dispir(int index)
{
	outs(Dispiindex, index);
	return ins(Dispidata);
}

/*
 * Set the mode and answer where the memory is, or -1 if this machine
 * has no card this knows how to ask.  The port layer calls it when the
 * configuration named no *bootscreen.
 */
int
ospreymachfb(int *wp, int *hp, int *dp, uvlong *pap, ulong *szp)
{
	Pcidev *p;
	uvlong pa;
	int id;

	if((p = pcimatch(nil, Qemuvid, Qemudid)) == nil)
		return -1;
	/*
	 * The ID register says whether the interface is really there, and
	 * is read before anything is written: a card that answers with
	 * something else is left alone rather than programmed blind.
	 */
	id = dispir(Id);
	if(id < Id0 || id > Id5)
		return -1;
	pa = p->mem[0].bar & ~(uvlong)0xF;
	if(pa == 0)
		return -1;

	dispiw(Enable, Disabled);	/* the registers are set with it off */
	dispiw(Xres, Fbw);
	dispiw(Yres, Fbh);
	dispiw(Bpp, Fbd);
	dispiw(Virtwidth, Fbw);
	dispiw(Virtheight, Fbh);
	dispiw(Xoff, 0);
	dispiw(Yoff, 0);
	dispiw(Enable, Enabled|Lfb);

	if((dispir(Enable) & Enabled) == 0)	/* it did not take */
		return -1;

	*wp = Fbw;
	*hp = Fbh;
	*dp = Fbd;
	*pap = pa;
	*szp = Fbw*Fbh*(Fbd/8);
	print("osprey fb: %dx%dx%d set through the Bochs display registers (id %#ux), memory at %#llux\n",
		Fbw, Fbh, Fbd, id, pa);
	return 0;
}
