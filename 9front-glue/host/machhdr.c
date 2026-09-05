/*
 * crackhdr for a build host: read the a.out header this tree's own
 * loaders write.  See the note in host/include/mach.h for why this
 * exists rather than libmach.
 *
 * The header is eight big-endian 32-bit words -- magic, text, data,
 * bss, syms, entry, spsz, pcsz -- and on the machines whose magic has
 * HDR_MAGIC in it a big-endian 64-bit entry point follows them, which
 * is the entry that counts there and makes the header 40 bytes rather
 * than 32.  a.out.h beside the loaders is where the magic numbers
 * come from, so this and they cannot drift apart.
 */
#include <u.h>
#include <libc.h>
#include <a.out.h>
#include <mach.h>

static Mach mi386 = { "386", MI386 };
static Mach mamd64 = { "amd64", MAMD64 };
static Mach marm64 = { "arm64", MARM64 };

Mach *mach;

static ulong
beswal(uchar *p)
{
	return ((ulong)p[0]<<24) | ((ulong)p[1]<<16) | ((ulong)p[2]<<8) | p[3];
}

static uvlong
beswav(uchar *p)
{
	return ((uvlong)beswal(p)<<32) | beswal(p+4);
}

int
crackhdr(int fd, Fhdr *fp)
{
	uchar hdr[10*4];
	ulong magic;

	if(seek(fd, 0, 0) != 0)
		return 0;
	if(readn(fd, hdr, 8*4) != 8*4){
		werrstr("short header");
		return 0;
	}
	memset(fp, 0, sizeof *fp);
	magic = beswal(hdr) & ~DYN_MAGIC;
	switch(magic){
	case I_MAGIC:
		mach = &mi386;
		fp->name = "386 plan 9 executable";
		break;
	case S_MAGIC:
		mach = &mamd64;
		fp->name = "amd64 plan 9 executable";
		break;
	case R_MAGIC:
		mach = &marm64;
		fp->name = "arm64 plan 9 executable";
		break;
	default:
		werrstr("unknown magic %#lux", magic);
		return 0;
	}
	fp->magic = magic;
	fp->txtsz = beswal(hdr+4);
	fp->datsz = beswal(hdr+8);
	fp->bsssz = beswal(hdr+12);
	fp->symsz = beswal(hdr+16);
	fp->entry = beswal(hdr+20);
	fp->hdrsz = 8*4;
	if(magic & HDR_MAGIC){
		if(readn(fd, hdr+8*4, 8) != 8){
			werrstr("short expanded header");
			return 0;
		}
		fp->entry = beswav(hdr+8*4);
		fp->hdrsz = 8*4 + 8;
	}
	return 1;
}
