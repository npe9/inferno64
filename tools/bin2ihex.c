/*
 * Turn a raw image into Intel hex at a given address.
 *
 * A kernel linked with -H4 is already a raw image: the first two words
 * are the initial stack pointer and the reset vector, which is what a
 * Cortex-M reads out of flash and what qemu's -kernel takes.  Some
 * loaders want the same bytes as Intel hex instead -- MikroElektronika's
 * USB HID bootloader, for one, which is the only way into a stock
 * clicker 2 for STM32 without soldering a programming header on.
 *
 * The hex writer is the one in aout2imxrt.c, which needs it for the
 * same reason and has nothing else in common with this.  Built with the
 * host's own compiler, like the rest of tools: nothing here is Inferno.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

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
	fprintf(stderr, "usage: bin2ihex image address out.hex\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	FILE *in, *out;
	unsigned char *image;
	long n;
	uint32_t base;
	char *e;

	if(argc != 4)
		usage();
	base = (uint32_t)strtoul(argv[2], &e, 0);
	if(*e != '\0')
		usage();

	in = fopen(argv[1], "rb");
	if(in == NULL){
		perror(argv[1]);
		return 1;
	}
	if(fseek(in, 0, SEEK_END) != 0 || (n = ftell(in)) < 0){
		perror(argv[1]);
		return 1;
	}
	rewind(in);
	image = malloc(n);
	if(image == NULL || fread(image, 1, n, in) != (size_t)n){
		fprintf(stderr, "bin2ihex: cannot read %s\n", argv[1]);
		return 1;
	}
	fclose(in);

	out = fopen(argv[3], "wb");
	if(out == NULL){
		perror(argv[3]);
		return 1;
	}
	writehex(out, image, (uint32_t)n, base);
	if(fclose(out) != 0){
		perror(argv[3]);
		return 1;
	}
	return 0;
}
