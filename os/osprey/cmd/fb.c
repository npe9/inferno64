/*
 * fb - draw to the firmware frame buffer the microkernel exposes.
 *
 * This runs as an ordinary program of the full 9front personality (off
 * the disk), not on the microkernel path.  The kernel publishes the UEFI
 * frame buffer as a physical segment named "framebuffer" (see
 * ospreyframebuffer in devosprey.c), so a process maps it with segattach
 * and writes pixels straight into it.  It proves the exposed-address-
 * space way in reaches the full personality: the memory a driver needs is
 * handed to a user program by name, and the program draws with no kernel
 * graphics stack in the way.  It is the foundation a user-level draw
 * server for rio stands on.
 *
 * The mode is the one the boot arg names, 1280x800 32-bit; a real driver
 * would read the geometry rather than assume it.
 */
#include <u.h>
#include <libc.h>

enum {
	W = 1280,
	H = 800,
};

/* the library's own _main/print members do not link here, so the program
 * supplies its own tiny output, as ring.c does */
static void
outs(char *s)
{
	write(2, s, strlen(s));
}

void
_main(char *argv0)
{
	ulong *fb;
	int x, y;
	char e[ERRMAX];

	USED(argv0);
	fb = (ulong*)segattach(0, "framebuffer", 0, (ulong)W*H*4);
	if(fb == (ulong*)-1){
		e[0] = 0;
		errstr(e, sizeof e);
		outs("fb: segattach framebuffer: ");
		outs(e);
		outs("\n");
		exits("segattach");
	}

	/* a colour gradient, so it is unmistakably this program that drew */
	for(y = 0; y < H; y++)
		for(x = 0; x < W; x++)
			fb[y*W + x] = ((ulong)(x*255/W) << 16)
				    | ((ulong)(y*255/H) << 8)
				    | 0x40;

	/* a solid block a person can point at */
	for(y = 120; y < 360; y++)
		for(x = 140; x < 620; x++)
			fb[y*W + x] = 0x00ff8000;	/* orange */

	outs("fb: a disk-personality process drew to the exposed frame buffer\n");
	/* keep repainting for a few seconds so any display refresh catches it */
	{
		int t;
		for(t = 0; t < 60; t++){
			for(x = 0; x < W; x++){
				fb[10*W + x] = 0x0000ff00;	/* a bright top bar */
				fb[(H-10)*W + x] = 0x0000ff00;	/* and a bottom bar */
			}
			sleep(50);
		}
	}
	exits(nil);
}
