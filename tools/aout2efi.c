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
	unsigned char h[32], *data;
	uint32_t text, dat, bss, entry, image;
	int p, n;
	if(argc != 3){ fprintf(stderr, "usage: aout2efi input output\n"); return 2; }
	if((in=fopen(argv[1], "rb")) == NULL) return 1;
	if(fread(h, 1, sizeof h, in) != sizeof h) return 1;
	text=be32(h+4); dat=be32(h+8); bss=be32(h+12); entry=be32(h+20);
	image=0x200+text+dat+bss;
	data=malloc(text+dat); if(data == NULL) return 1;
	if(fread(data, 1, text+dat, in) != text+dat) return 1;
	memset(b, 0, sizeof b); p=0;
	raw(&p, "MZ", 2); p=0x3a; w32(&p, 0x40); p=0x40;
	raw(&p, "PE\0\0", 4); w16(&p, 0x8664); w16(&p, 1); w32(&p,0); w32(&p,0); w32(&p,0); w16(&p,0xf0); w16(&p,2223);
	w16(&p,0x20b); b[p++]=9; b[p++]=0; w32(&p,0); w32(&p,0); w32(&p,0); w32(&p,entry-0x8000); w32(&p,0);
	w64(&p,0x8000); w32(&p,0x200); w32(&p,0x200); w16(&p,4); w16(&p,0); w16(&p,0); w16(&p,0); w16(&p,4); w16(&p,0); w32(&p,0); w32(&p,image); w32(&p,0x200); w32(&p,0); w16(&p,10); w16(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w32(&p,0); w32(&p,16); w64(&p,0);
	p=0x178; raw(&p, ".text\0\0\0", 8); w32(&p,text+dat); w32(&p,0x200); w32(&p,text+dat); w32(&p,0x200); w32(&p,0); w32(&p,0); w16(&p,0); w16(&p,0); w32(&p,0x86000020);
	if((out=fopen(argv[2], "wb")) == NULL) return 1;
	fwrite(b,1,sizeof b,out); fwrite(data,1,text+dat,out); n=(0x200+text+dat+bss+0x1ff)&~0x1ff; while((int)ftell(out)<n) fputc(0,out); fclose(out); free(data); return 0;
}
