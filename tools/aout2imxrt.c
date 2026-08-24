/*
 * aout2imxrt: wrap a raw kernel image in the headers an i.MX RT boot ROM
 * reads out of serial NOR flash, and write it out as a binary and as
 * Intel hex for the Teensy loader.
 *
 * The input is what utils/tl writes with -H4: no header at all, the text
 * segment followed immediately by the data segment.  The kernel's text
 * is linked at IMAGE (0x60002000 for os/inferno/teensy41), which is
 * where the vector table has to be, so the first 0x2000 bytes of flash
 * are headers and padding:
 *
 *	0x0000	FlexSPI NOR configuration block, 512 bytes.  The ROM reads
 *		this before anything else and uses the lookup table in it
 *		to fetch the rest of the flash.
 *	0x1000	image vector table: where the vector table is, and where
 *		the boot data is.
 *	0x1020	boot data: where the image starts, and how long it is.
 *	0x2000	the kernel.
 *
 * The layout and the field names are the ones in chapter 9 of the
 * i.MX RT1060 reference manual, "System Boot".  Nothing here has been
 * programmed onto a device; see teensy41(6).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define	FLASHBASE	0x60000000u
#define	HEADERS		0x2000u		/* flash taken by the headers */
#define	FCBOFF		0x0000u
#define	IVTOFF		0x1000u
#define	BDOFF		0x1020u

static int verbose;

/*
 * FlexSPI lookup table instructions.  Each word holds two of them, low
 * half first; an instruction is opcode(6) pad(2) operand(8), where pad
 * 0 is one pad, 1 is two and 2 is four.
 */
#define	LUT(op, pad, opnd)	(((op)<<10) | ((pad)<<8) | ((opnd)&0xff))
#define	LUT2(a, b)		((uint32_t)(b)<<16 | (uint32_t)(a))
enum {
	Lstop	= 0,
	Lcmd	= 1,		/* CMD_SDR */
	Lraddr	= 2,		/* RADDR_SDR */
	Lwrite	= 8,		/* WRITE_SDR */
	Lread	= 9,		/* READ_SDR */
	Ldummy	= 12,		/* DUMMY_SDR */

	Pad1	= 0,
	Pad4	= 2,
};

static uint32_t fcb[128];

/*
 * A serial NOR part in quad mode: read with 0xeb (fast read quad I/O),
 * which every W25Q and its equivalents implement, and the six dummy
 * cycles that go with it below 80MHz.  The programming sequences are
 * here because the ROM's flashloader uses them; a kernel that is only
 * ever run out of flash does not.
 */
static void
fcbinit(uint32_t flashsize)
{
	memset(fcb, 0, sizeof fcb);

	fcb[0x000/4] = 0x42464346;	/* tag, "FCFB" */
	fcb[0x004/4] = 0x56010000;	/* version, "V" 1 0 0 */
	/* readSampleClkSrc=1 (loopback from DQS pad), csHoldTime=3, csSetupTime=3 */
	fcb[0x00c/4] = 0x00030301;
	/* deviceType=1 (serial NOR), sflashPadType=4 (quad), serialClkFreq=3 (60MHz) */
	fcb[0x044/4] = 0x00030401;
	fcb[0x050/4] = flashsize;	/* sflashA1Size */

	/* sequence 0: read */
	fcb[0x080/4] = LUT2(LUT(Lcmd, Pad1, 0xeb), LUT(Lraddr, Pad4, 24));
	fcb[0x084/4] = LUT2(LUT(Ldummy, Pad4, 6), LUT(Lread, Pad4, 4));
	/* sequence 1: read status */
	fcb[0x090/4] = LUT2(LUT(Lcmd, Pad1, 0x05), LUT(Lread, Pad1, 4));
	/* sequence 3: write enable */
	fcb[0x0b0/4] = LUT2(LUT(Lcmd, Pad1, 0x06), LUT(Lstop, Pad1, 0));
	/* sequence 5: erase sector */
	fcb[0x0d0/4] = LUT2(LUT(Lcmd, Pad1, 0x20), LUT(Lraddr, Pad1, 24));
	/* sequence 9: page program */
	fcb[0x100/4] = LUT2(LUT(Lcmd, Pad1, 0x02), LUT(Lraddr, Pad1, 24));
	fcb[0x104/4] = LUT2(LUT(Lwrite, Pad1, 4), LUT(Lstop, Pad1, 0));
	/* sequence 11: chip erase */
	fcb[0x120/4] = LUT2(LUT(Lcmd, Pad1, 0x60), LUT(Lstop, Pad1, 0));

	/* the serial NOR block that follows the common one, at 0x1c0 */
	fcb[0x1c0/4] = 256;		/* pageSize */
	fcb[0x1c4/4] = 4096;		/* sectorSize */
	fcb[0x1c8/4] = 1;		/* ipCmdSerialClkFreq */
	fcb[0x1d0/4] = 64*1024;		/* blockSize */
}

static void
putle32(unsigned char *p, uint32_t v)
{
	p[0] = v;
	p[1] = v>>8;
	p[2] = v>>16;
	p[3] = v>>24;
}

/* Intel hex, with the extended linear address records the 32 bit space needs */
static void
hexrec(FILE *f, int type, uint32_t addr, const unsigned char *d, int n)
{
	int i, sum;

	fprintf(f, ":%02X%04X%02X", n, (unsigned)(addr & 0xffff), type);
	sum = n + ((addr>>8) & 0xff) + (addr & 0xff) + type;
	for(i = 0; i < n; i++){
		fprintf(f, "%02X", d[i]);
		sum += d[i];
	}
	fprintf(f, "%02X\r\n", (-sum) & 0xff);
}

static void
writehex(FILE *f, const unsigned char *image, uint32_t n, uint32_t base)
{
	unsigned char rec[2];
	uint32_t off, hi, lasthi;
	int m;

	lasthi = 0xffffffff;
	for(off = 0; off < n; off += 16){
		hi = (base+off) >> 16;
		if(hi != lasthi){
			rec[0] = hi>>8;
			rec[1] = hi;
			hexrec(f, 4, 0, rec, 2);
			lasthi = hi;
		}
		m = n-off < 16? n-off: 16;
		hexrec(f, 0, (base+off) & 0xffff, image+off, m);
	}
	hexrec(f, 1, 0, NULL, 0);
}

static void
usage(void)
{
	fprintf(stderr, "usage: aout2imxrt [-v] kernel out.bin out.hex\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	FILE *in, *out;
	unsigned char *image;
	uint32_t klen, total, entry, i;
	long n;

	if(argc > 1 && strcmp(argv[1], "-v") == 0){
		verbose = 1;
		argc--;
		argv++;
	}
	if(argc != 4)
		usage();

	if((in = fopen(argv[1], "rb")) == NULL){
		fprintf(stderr, "aout2imxrt: %s: cannot open\n", argv[1]);
		return 1;
	}
	fseek(in, 0, SEEK_END);
	n = ftell(in);
	fseek(in, 0, SEEK_SET);
	if(n <= 0){
		fprintf(stderr, "aout2imxrt: %s: empty\n", argv[1]);
		return 1;
	}
	klen = n;
	total = HEADERS + klen;
	if((image = calloc(total, 1)) == NULL)
		return 1;
	if(fread(image+HEADERS, 1, klen, in) != klen){
		fprintf(stderr, "aout2imxrt: %s: short read\n", argv[1]);
		return 1;
	}
	fclose(in);

	/*
	 * The ROM wants the address of the vector table, not of the entry
	 * point: it takes the stack pointer and the reset address out of
	 * it the way the core does.  That table is the first thing in the
	 * kernel's text, which the linker put at FLASHBASE+HEADERS.
	 */
	entry = FLASHBASE + HEADERS;

	fcbinit(8*1024*1024);
	for(i = 0; i < 128; i++)
		putle32(image + FCBOFF + 4*i, fcb[i]);

	putle32(image + IVTOFF + 0x00, 0x412000d1);	/* tag d1, length 0x20, version 0x40 */
	putle32(image + IVTOFF + 0x04, entry);
	putle32(image + IVTOFF + 0x08, 0);		/* reserved */
	putle32(image + IVTOFF + 0x0c, 0);		/* no device configuration data */
	putle32(image + IVTOFF + 0x10, FLASHBASE + BDOFF);
	putle32(image + IVTOFF + 0x14, FLASHBASE + IVTOFF);
	putle32(image + IVTOFF + 0x18, 0);		/* no command sequence file */
	putle32(image + IVTOFF + 0x1c, 0);		/* reserved */

	putle32(image + BDOFF + 0x00, FLASHBASE);	/* start of what to boot */
	putle32(image + BDOFF + 0x04, total);		/* how much of it there is */
	putle32(image + BDOFF + 0x08, 0);		/* not a plugin */

	if(verbose){
		printf("kernel %u bytes at %#x\n", klen, entry);
		printf("image  %u bytes at %#x\n", total, FLASHBASE);
		printf("ivt    entry %#x bootdata %#x self %#x\n",
			entry, FLASHBASE+BDOFF, FLASHBASE+IVTOFF);
	}

	if((out = fopen(argv[2], "wb")) == NULL)
		return 1;
	fwrite(image, 1, total, out);
	fclose(out);

	if((out = fopen(argv[3], "w")) == NULL)
		return 1;
	writehex(out, image, total, FLASHBASE);
	fclose(out);
	free(image);
	return 0;
}
