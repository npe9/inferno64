/*
 * An EFI application that prints one line and returns.
 *
 * It is not a boot loader and it is not on the way to being one: it is
 * the test for everything underneath a boot loader on this
 * architecture.  A PE/COFF image built by this tree's own compiler has
 * three separate ways to be rejected or to fault before any of the
 * loader's own code matters -- the machine type in the header, the
 * image base the firmware is asked for, and the two calling
 * conventions that meet in eficall() -- and a firmware that refuses an
 * image says only "Not a valid application" while one that faults says
 * an address.  So this exists to say EFI-AA64-OK from inside edk2, and
 * every one of those three was wrong once on the way to it.  See
 * aa64.s, tools/aout2efi.c and doc/inferno-ports.ms.
 *
 * The system table is read through word offsets rather than through
 * efi.h's structures on purpose: this file has to work before anything
 * else is trusted, and the two offsets it uses (ConOut at 0x40,
 * OutputString at 8 into that) are fixed by the EFI specification.
 */

typedef unsigned long long u64;
typedef unsigned short u16;

extern u64 eficall(void *proc, ...);
extern void *imagehandle;		/* set by start in aa64.s */

static void
puts(u64 *st, char *s)
{
	u64 *conout;
	u16 w[128];
	int i;

	conout = (u64*)st[8];			/* SystemTable->ConOut */
	for(i = 0; i < 127 && s[i] != 0; i++)
		w[i] = (u16)s[i];
	w[i] = 0;
	eficall((void*)conout[1], conout, w);	/* ConOut->OutputString */
}

/*
 * Returns EFI_SUCCESS, which is zero.  A firmware that gets anything
 * else back from an application it launched says so on the console, so
 * the status is as much a part of the test as the line above it.
 */
u64
efistart(u64 *st)
{
	USED(imagehandle);
	puts(st, "EFI-AA64-OK inferno\r\n");
	return 0;
}
