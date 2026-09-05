/*
 * As much of 9front's <mach.h> as a build host tool uses, which is
 * five fields of an Fhdr, the machine type, and crackhdr to fill
 * them.
 *
 * aux/aout2efi is the tool: it turns the a.out that 6l writes for the
 * EFI loader into the PE32+ image firmware will load, and to do that
 * it needs the three segment sizes, the entry point, and the size of
 * the header in front of them.  9front gets those from libmach, which
 * knows every executable format Plan 9 has ever read and is a great
 * deal more of 9front than five numbers are worth bringing across --
 * the same judgement, and for the same reason, as the host size in
 * size.c beside this.
 *
 * So this declares the shape and machhdr.c reads a Plan 9 a.out into
 * it.  Nothing else is here: a tool that wants symbols or a core file
 * wants the real libmach and must say so.
 */
#ifndef __9FRONT_HOST_MACH_H
#define __9FRONT_HOST_MACH_H

typedef struct Fhdr Fhdr;
struct Fhdr {
	char	*name;		/* as the loader magic names it */
	ulong	magic;
	vlong	txtsz;
	vlong	datsz;
	vlong	bsssz;
	vlong	symsz;
	uvlong	entry;
	long	hdrsz;		/* bytes before the text */
};

/* mach->mtype, the one field of Mach a host tool reads */
enum {
	MI386 = 1,
	MAMD64,
	MARM64,
};

typedef struct Mach Mach;
struct Mach {
	char	*name;
	int	mtype;
};

extern Mach *mach;

extern int crackhdr(int fd, Fhdr *fp);

#endif
