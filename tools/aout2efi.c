#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PALIGN	0x1000		/* SectionAlignment: one EFI page */
/*
 * FileAlignment is the same page as SectionAlignment, so that every
 * VirtualAddress, PointerToRawData and SizeOfRawData in the image is
 * page-aligned and the headers occupy a whole page of their own.  EDK2
 * only applies per-section memory attributes to an image whose
 * sections it can account for page by page; with FileAlignment 0x200
 * the two-section image came out non-executable and the firmware took
 * an instruction abort on the loader's first instruction (ESR
 * 0x8600000E, permission fault second level).
 */
#define FALIGN	0x1000		/* FileAlignment */
#define ROUNDUP(x, a)	(((x)+(a)-1)&~((a)-1))

static unsigned char b[0x1000];
static void w16(int *p, uint32_t v){ b[(*p)++]=v; b[(*p)++]=v>>8; }
static void w32(int *p, uint32_t v){ w16(p,v); w16(p,v>>16); }
static void w64(int *p, uint64_t v){ w32(p,v); w32(p,v>>32); }
static void raw(int *p, const void *s, int n){ memcpy(b+*p,s,n); *p += n; }
static uint32_t be32(const unsigned char *p){ return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static uint64_t be64(const unsigned char *p){ return (uint64_t)be32(p)<<32 | be32(p+4); }

int
main(int argc, char **argv)
{
	FILE *in, *out;
	unsigned char h[40], *data;
	uint32_t text, dat, bss, image;
	uint32_t tva, traw, tfsz, dgap;
	uint64_t entry, base;
	uint32_t magic;
	int machine;
	long hdrsz;
	int p;
	if(argc != 3 && argc != 4){ fprintf(stderr, "usage: aout2efi input output [imagebase]\n"); return 2; }
	if((in=fopen(argv[1], "rb")) == NULL) return 1;
	if(fread(h, 1, sizeof h, in) != sizeof h) return 1;
	magic=be32(h+0);
	text=be32(h+4); dat=be32(h+8); bss=be32(h+12);
	/* amd64 Plan 9 a.out files carry an additional eight-byte entry
	 * record after Exec.  Do not copy that record into the EFI text. */
	/* Plan 9 a.out magic to PE machine type: S_MAGIC is amd64,
	 * R_MAGIC arm64 (see utils/include/a.out.h).  Both carry
	 * HDR_MAGIC, so both have the extra eight-byte entry record. */
	switch(magic){
	case 0x00008a97:	/* S_MAGIC */
		machine = 0x8664;
		break;
	case 0x00008c47:	/* R_MAGIC */
		machine = 0xaa64;
		break;
	default:
		fprintf(stderr, "aout2efi: %s: magic %#x is not amd64 or arm64\n",
			argv[1], magic);
		return 1;
	}
	/* Exec's entry field is 32 bits and holds PADDR(entry); the real
	 * 64-bit one is the eight-byte record HDR_MAGIC adds after it,
	 * which is what an image linked above 4 GiB (or, on arm64, above
	 * whatever PADDR masks) needs read instead. */
	hdrsz = (magic & 0x00008000) ? 40 : 32;
	entry = hdrsz == 40 ? be64(h+32) : be32(h+20);
	/*
	 * The text sits one 4 KiB page above the image base at run time,
	 * so that is how far below the link address the base is.  It was
	 * 0x200, matching FileAlignment, and that is what a PE image may
	 * not do: EDK2 can only build an image properties record, and so
	 * apply its NX policy per section, when SectionAlignment is a
	 * whole EFI page.  With 0x200 it printed "ProtectUefiImage failed
	 * to create image properties record" and left the image's pages
	 * under the default policy for their memory type -- which on
	 * AArch64 is not executable, so the firmware took an instruction
	 * abort (ESR 0x8600000E, permission fault second level) on the
	 * loader's very first instruction, deterministically, three runs
	 * out of three.  See os/inferno/boot/efi/mkfile's LINKBASE and
	 * LINKBASEARM, which are IMAGEBASE + 0x1000 to match.
	 */
	base = entry - 0x1000;
	/*
	 * The firmware may be told to put the image somewhere other than
	 * where it is linked to run.  The arm64 loader needs that: it
	 * relocates itself to its link address and can only do so if the
	 * firmware did not already place it there, because an image the
	 * firmware has loaded carries the firmware's own protection --
	 * a code section is read-only, so the loader faults writing its
	 * first global.  Give a third argument and the PE says one
	 * address while the code runs at another; leave it out, as the
	 * amd64 loader does, and the two are the same.
	 */
	if(argc == 4)
		base = strtoull(argv[3], NULL, 0);

	/*
	 * One section, holding text, data and bss together, claiming
	 * CNT_CODE | CNT_INITIALIZED_DATA | MEM_EXECUTE | MEM_READ |
	 * MEM_WRITE.
	 *
	 * Two sections is the shape a compiler emits and the shape EDK2
	 * protects properly -- .text read-only and executable, .data
	 * writable and not -- and it was tried.  This firmware then
	 * loads the image away from its ImageBase and leaves .text
	 * non-executable, so nothing runs at all; with one section it
	 * loads at the ImageBase and executes.  Reproduced three times
	 * each, with and without RELOCS_STRIPPED, at two different
	 * image bases.  Why the section count should decide either is
	 * not explained here and is not guessed at.
	 *
	 * One section costs nothing here because the loader never
	 * writes to the image the firmware loaded: start() and reloc()
	 * only read it, copy it to the address it was linked for, and
	 * enter the copy.  Read-only at the load address is therefore
	 * the right protection for it, which is what EDK2 gives a code
	 * section.
	 *
	 * The old value was 0x86000020 -- MEM_WRITE | MEM_DISCARDABLE |
	 * MEM_NOT_CACHED | CNT_CODE, with neither MEM_READ nor
	 * MEM_EXECUTE, and two flags inviting the firmware to discard
	 * the section or map it uncached.  Nothing noticed while
	 * SectionAlignment was 0x200, because EDK2 could not build an
	 * image properties record at all and so never applied
	 * per-section attributes.
	 */
	tva = PALIGN;
	traw = PALIGN;
	/*
	 * The loaders are linked with -R4096, so the data segment starts
	 * on a page boundary after the text: in the a.out file data
	 * follows text immediately, but its virtual address is
	 * ROUNDUP(text, page) above the text's.  A single section has to
	 * reproduce that gap in the file, or every address in the data
	 * segment lands short by it.
	 */
	dgap = ROUNDUP(text, PALIGN) - text;
	tfsz = ROUNDUP(text+dgap+dat, FALIGN);
	image = tva + ROUNDUP(text+dgap+dat+bss, PALIGN);

	data=malloc(text+dat); if(data == NULL) return 1;
	if(fseek(in, hdrsz, SEEK_SET) != 0) return 1;
	if(fread(data, 1, text+dat, in) != text+dat) return 1;
	memset(b, 0, sizeof b); p=0;
	raw(&p, "MZ", 2); p=0x3c; w32(&p, 0x40); p=0x40;
	raw(&p, "PE\0\0", 4); w16(&p, machine); w16(&p, 1); w32(&p,0); w32(&p,0); w32(&p,0); w16(&p,0xf0); w16(&p,2223);
	w16(&p,0x20b); b[p++]=9; b[p++]=0; w32(&p,text); w32(&p,dat); w32(&p,bss); w32(&p,tva);			/* AddressOfEntryPoint: the entry is the first thing in .text */ w32(&p,tva);
	w64(&p,base); w32(&p,PALIGN); w32(&p,FALIGN); w16(&p,4); w16(&p,0); w16(&p,0); w16(&p,0); w16(&p,4); w16(&p,0); w32(&p,0); w32(&p,image); w32(&p,PALIGN); w32(&p,0); w16(&p,10); w16(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w64(&p,0); w32(&p,0); w32(&p,16);
	/*
	 * .text: code, read and execute.  .data: initialised data,
	 * read and write, no execute.  The old single section claimed
	 * 0x86000020 -- MEM_WRITE | MEM_DISCARDABLE | MEM_NOT_CACHED |
	 * CNT_CODE, with neither MEM_READ nor MEM_EXECUTE, and two
	 * flags inviting the firmware to discard the section or map it
	 * uncached.  Nothing noticed while SectionAlignment was 0x200,
	 * because EDK2 could not build an image properties record at
	 * all and so never applied per-section attributes.
	 */
	p=0x148;
	raw(&p, ".text\0\0\0", 8); w32(&p,text+dgap+dat+bss); w32(&p,tva); w32(&p,tfsz); w32(&p,traw); w32(&p,0); w32(&p,0); w16(&p,0); w16(&p,0); w32(&p,0xE0000060);
	if((out=fopen(argv[2], "wb")) == NULL) return 1;
	fwrite(b,1,sizeof b,out);
	fwrite(data,1,text,out);
	while((uint32_t)ftell(out) < traw+text+dgap) fputc(0,out);
	fwrite(data+text,1,dat,out);
	while((uint32_t)ftell(out) < traw+tfsz) fputc(0,out);
	fclose(out); free(data); return 0;
}
