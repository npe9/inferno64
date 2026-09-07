/*
 * Turn a Plan 9 amd64 a.out kernel into an ELF64 executable carrying
 * the XEN_ELFNOTE_PHYS32_ENTRY note, which is what the x86/HVM direct
 * boot ABI ("PVH") wants: a Xen PVH domain builder, QEMU's own -kernel
 * loader, Firecracker and Cloud Hypervisor all read that note and jump
 * to the address in it in 32-bit protected mode with paging off.
 *
 * The two program headers matter as much as the note.  A multiboot
 * loader lays text and data down contiguously and os/inferno/pc64/l.s's
 * _multibootentry has to slide the data up to the page boundary the
 * kernel was linked for; giving data a header of its own puts it there
 * to begin with, so the PVH entry has nothing to move.
 *
 * The entry address is not hard-coded here.  os/inferno/pc64/l.s plants
 * a four-byte magic followed by the entry, and this scans for it, the
 * same arrangement by which a multiboot loader finds its own header.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
	Hdrsz64	= 40,		/* Exec plus the amd64 8-byte entry record */
	Amd64	= 0x00008a97,	/* S_MAGIC */
	Pgsz	= 4096,
	/*
	 * File offset of the text segment.  It is 0x3000 and not 0x1000
	 * for one reason: QEMU's -kernel loader scans the first 8192
	 * bytes of the file for a multiboot header and takes the
	 * multiboot path if it finds one, before it ever looks for the
	 * PVH note.  os/inferno/pc64/l.s carries a multiboot header 0x20
	 * bytes into the text, and the multiboot path then loads text and
	 * data contiguously, which is not how this file is laid out --
	 * data sits at its own page-aligned offset -- so the kernel came
	 * up on a corrupted data segment and printed nothing at all.
	 * Putting the text past 8192 keeps the multiboot header out of
	 * the window, and the ELF is read as what it is.  The a.out is
	 * still there for a multiboot loader to take whole.
	 */
	Elfoff	= 0x3000,
	Pvhmagic = 0x21485650,	/* "PVH!" as l.s writes it */
	Scan	= 8192,		/* how far into the text to look for it */

	Note	= 18,		/* XEN_ELFNOTE_PHYS32_ENTRY */
};

static unsigned char *b;
static long bp;

static void w8(uint8_t v){ b[bp++] = v; }
static void w16(uint16_t v){ w8(v); w8(v>>8); }
static void w32(uint32_t v){ w16(v); w16(v>>16); }
static void w64(uint64_t v){ w32(v); w32(v>>32); }
static void raw(const void *s, int n){ memcpy(b+bp, s, n); bp += n; }
static uint32_t be32(const unsigned char *p){
	return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static uint32_t le32(const unsigned char *p){
	return (uint32_t)p[3]<<24 | (uint32_t)p[2]<<16 | (uint32_t)p[1]<<8 | p[0];
}

static void
phdr(uint32_t type, uint32_t flags, uint64_t off, uint64_t addr,
	uint64_t filesz, uint64_t memsz, uint64_t align)
{
	w32(type); w32(flags); w64(off); w64(addr); w64(addr);
	w64(filesz); w64(memsz); w64(align);
}

int
main(int argc, char **argv)
{
	FILE *in, *out;
	unsigned char h[Hdrsz64], *text, *data;
	uint32_t magic, tsz, dsz, bsz, entry, pvh;
	uint64_t taddr, daddr, doff;
	long i, n;

	if(argc != 3){
		fprintf(stderr, "usage: aout2elf input output\n");
		return 2;
	}
	if((in = fopen(argv[1], "rb")) == NULL){
		fprintf(stderr, "aout2elf: cannot open %s\n", argv[1]);
		return 1;
	}
	if(fread(h, 1, sizeof h, in) != sizeof h){
		fprintf(stderr, "aout2elf: short header\n");
		return 1;
	}
	magic = be32(h+0);
	if(magic != Amd64){
		fprintf(stderr, "aout2elf: %s is not an amd64 a.out (magic %#x)\n",
			argv[1], magic);
		return 1;
	}
	tsz = be32(h+4);
	dsz = be32(h+8);
	bsz = be32(h+12);
	entry = be32(h+20);

	text = malloc(tsz);
	data = malloc(dsz);
	if(text == NULL || data == NULL)
		return 1;
	if(fread(text, 1, tsz, in) != tsz || fread(data, 1, dsz, in) != dsz){
		fprintf(stderr, "aout2elf: short text or data\n");
		return 1;
	}
	fclose(in);

	/* the entry the loader is to jump to, as l.s recorded it */
	pvh = 0;
	n = tsz < Scan ? tsz : Scan;
	for(i = 0; i+8 <= n; i += 4)
		if(le32(text+i) == Pvhmagic){
			pvh = le32(text+i+4);
			break;
		}
	if(pvh == 0){
		fprintf(stderr, "aout2elf: no PVH header in the first %ld bytes"
			" of text; is _pvhheader still in l.s?\n", n);
		return 1;
	}

	/*
	 * The kernel is linked with KZERO 0, so its addresses are
	 * physical and the a.out entry is where the text begins.  Data
	 * goes at the page boundary after the text, which is where the
	 * kernel's own edata and the multiboot path both put it.
	 */
	taddr = entry;
	daddr = (taddr + tsz + Pgsz-1) & ~(uint64_t)(Pgsz-1);
	doff = Elfoff + ((tsz + Pgsz-1) & ~(uint64_t)(Pgsz-1));

	b = calloc(1, Elfoff);
	if(b == NULL)
		return 1;
	bp = 0;

	/* Elf64_Ehdr */
	raw("\177ELF", 4);
	w8(2); w8(1); w8(1); w8(0); w8(0);	/* 64 bit, LSB, version, SysV */
	for(i = 0; i < 7; i++) w8(0);
	w16(2); w16(62);			/* ET_EXEC, EM_X86_64 */
	w32(1); w64(taddr); w64(64); w64(0); w32(0);
	w16(64); w16(56); w16(3); w16(64); w16(0); w16(0);

	/* Elf64_Phdr: text, data, note */
	phdr(1, 5, Elfoff, taddr, tsz, tsz, Pgsz);		/* PT_LOAD r-x */
	phdr(1, 6, doff, daddr, dsz, (uint64_t)dsz+bsz, Pgsz);	/* PT_LOAD rw- */
	phdr(4, 4, 64+3*56, 0, 4+4+4+4+4, 4+4+4+4+4, 4);	/* PT_NOTE */

	/* the note itself: namesz, descsz, type, "Xen\0", entry */
	w32(4); w32(4); w32(Note);
	raw("Xen\0", 4);
	w32(pvh);

	if((out = fopen(argv[2], "wb")) == NULL){
		fprintf(stderr, "aout2elf: cannot create %s\n", argv[2]);
		return 1;
	}
	fwrite(b, 1, Elfoff, out);
	fwrite(text, 1, tsz, out);
	while(ftell(out) < (long)doff)
		fputc(0, out);
	fwrite(data, 1, dsz, out);
	fclose(out);

	fprintf(stderr, "aout2elf: text %#x at %#llx, data %#x+%#x bss at %#llx,"
		" pvh entry %#x\n", tsz, (unsigned long long)taddr, dsz, bsz,
		(unsigned long long)daddr, pvh);
	return 0;
}
