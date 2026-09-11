#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char b[0x200];
static void w16(int *p, uint32_t v){ b[(*p)++]=v; b[(*p)++]=v>>8; }
static void w32(int *p, uint32_t v){ w16(p,v); w16(p,v>>16); }
static void w64(int *p, uint64_t v){ w32(p,v); w32(p,v>>32); }
static void raw(int *p, const void *s, int n){ memcpy(b+*p,s,n); *p += n; }
static uint32_t be32(const unsigned char *p){ return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }

int
main(int argc, char **argv)
{
	FILE *in, *out;
	unsigned char h[40], *data;
	uint32_t text, dat, bss, image;
	uint64_t entry;
	uint32_t magic;
	uint64_t base;
	int machine;
	long hdrsz;
	int p, n;
	if(argc < 3 || argc > 4){ fprintf(stderr, "usage: aout2efi input output [imagebase]\n"); return 2; }
	if((in=fopen(argv[1], "rb")) == NULL) return 1;
	if(fread(h, 1, sizeof h, in) != sizeof h) return 1;
	magic=be32(h+0);
	text=be32(h+4); dat=be32(h+8); bss=be32(h+12);
	/* The 32-bit entry field at offset 20 is PADDR(entry), which on
	 * arm64 has had the kernel segment cut off it: a loader linked at
	 * 0x48000200 reports 0x08000200 there and 0x48000200 in the
	 * 64-bit field the fat header adds at offset 32.  Take the wide
	 * one whenever it is present. */
	entry = (uint64_t)be32(h+32)<<32 | be32(h+36);
	if((magic & 0x00008000) == 0)
		entry = be32(h+20);
	/* The 64-bit Plan 9 a.out formats set HDR_MAGIC and carry an
	 * additional eight-byte entry record after Exec.  Do not copy
	 * that record into the EFI text.  S_MAGIC is amd64 and R_MAGIC
	 * is arm64; the PE machine type follows from which one it is,
	 * because a firmware that is handed the wrong one refuses the
	 * image with "Not a valid application" and no more detail than
	 * that. */
	switch(magic){
	case 0x00008a97:	machine = 0x8664; break;	/* S_MAGIC */
	case 0x00008c47:	machine = 0xAA64; break;	/* R_MAGIC */
	default:
		fprintf(stderr, "aout2efi: %s: magic %#x is not amd64 or arm64\n",
			argv[1], magic);
		return 1;
	}
	hdrsz = (magic & 0x00008000) ? 40 : 32;
	/* Where the image is linked, which is also where it asks the
	 * firmware to put it.  0x8000 is where the x86 loader lives and
	 * stays the default; arm64 has no low memory to live in and
	 * passes its own. */
	base = argc == 4 ? strtoull(argv[3], NULL, 0) : 0x8000;
	image=0x200+text+dat+bss;
	if(entry < base){
		fprintf(stderr, "aout2efi: entry %#llx is below the image base %#llx\n",
			(unsigned long long)entry, (unsigned long long)base);
		return 1;
	}
	data=malloc(text+dat); if(data == NULL) return 1;
	if(fseek(in, hdrsz, SEEK_SET) != 0) return 1;
	if(fread(data, 1, text+dat, in) != text+dat) return 1;
	memset(b, 0, sizeof b); p=0;
	raw(&p, "MZ", 2); p=0x3c; w32(&p, 0x40); p=0x40;
	raw(&p, "PE\0\0", 4); w16(&p, machine); w16(&p, 1); w32(&p,0); w32(&p,0); w32(&p,0); w16(&p,0xf0); w16(&p,2223);
	w16(&p,0x20b); b[p++]=9; b[p++]=0; w32(&p,0); w32(&p,0); w32(&p,0); w32(&p,(uint32_t)(entry-base)); w32(&p,0);
	w64(&p,base); w32(&p,0x200); w32(&p,0x200); w16(&p,4); w16(&p,0); w16(&p,0); w16(&p,0); w16(&p,4); w16(&p,0); w32(&p,0); w32(&p,image); w32(&p,0x200); w32(&p,0); w16(&p,10); w16(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w32(&p,0); w32(&p,16);
	p=0x148; raw(&p, ".text\0\0\0", 8); w32(&p,text+dat); w32(&p,0x200); w32(&p,text+dat); w32(&p,0x200); w32(&p,0); w32(&p,0); w16(&p,0); w16(&p,0); w32(&p,0x86000020);
	if((out=fopen(argv[2], "wb")) == NULL) return 1;
	fwrite(b,1,sizeof b,out); fwrite(data,1,text+dat,out); n=(0x200+text+dat+bss+0x1ff)&~0x1ff; while((int)ftell(out)<n) fputc(0,out); fclose(out); free(data); return 0;
}
