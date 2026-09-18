#include <lib9.h>
#include <bio.h>
#include <isa.h>

/* interp.h's Timmortal, which this cannot include: it needs a kernel dat.h */
#define	TIMMORTAL	0x40000000

/*
 * Turn a Dis module into the decoded instruction array the interpreter
 * would otherwise build in RAM at load time, as assembler that puts it
 * in the text segment.
 *
 * libinterp/load.c:/^parsemod walks the instruction stream and fills an
 * Inst for each instruction: the opcode, the addressing byte, the
 * middle operand and the two Adrs.  Nothing in that array depends on
 * which instance of the module is running -- the per-instance state is
 * the module data segment, which is elsewhere -- and the only pointers
 * in it are branch targets, which point into the array itself.  So it
 * can be built once, at build time, and read where it lies.
 *
 * That is what this writes, as
 *	GLOBL	<sym>prog(SB), RODATA, $<12*n>
 *	DATA	<sym>prog+0(SB)/4, $...
 * with each branch target emitted as $<sym>prog+<12*target>(SB) and
 * left for the linker to resolve, so nothing here needs to know where
 * the array will land.  RODATA is what puts it in the text segment;
 * see utils/tl/l.h and doc/xip.ms.
 *
 * The layout written is the target's, not this host's: three 32-bit
 * words per Inst, little-endian, being
 *	op | add<<8 | reg<<16
 *	s
 *	d
 * which is sizeof(Inst) == 12 with a four-byte Dis word and a four-byte
 * pointer.  A target with eight-byte Dis words lays Inst out at 24 and
 * is not handled: it is also not a target that wants this, since the
 * point is parts with kilobytes of RAM.
 *
 * A .c file is written as well, naming everything that was emitted, for
 * the kernel to match a module being loaded against.  It is a separate
 * stem from the .s because both compile to an object and the two would
 * otherwise collide.
 *
 * Several modules go in one pair of files.  Each is named either as
 *	<what the module is loaded as>=<the file to read>
 * or, with -r and -p given, as a bare name that stands for
 *	<prefix>/<name>=<dir>/<name>
 * which is the shape of a built-in root: the same relative name under
 * the directory the Dis was installed in and under the path it is
 * loaded as.  Each module gets its own symbol, derived from the path it
 * is loaded as.
 */

static int	nerr;

static void
usage(void)
{
	fprint(2, "usage: dis2s -o stem -c stem [-r dir -p prefix] [dispath=file | name] ...\n");
	exits("usage");
}

static uchar	*code;
static long	length;
static long	pos;

/*
 * operand() and the decode below mirror libinterp/load.c.  They have to
 * agree with it exactly: what this writes is what that would have built.
 */
static long
operand(void)
{
	int c;

	if(pos >= length){
		fprint(2, "dis2s: instruction stream runs off the end\n");
		nerr++;
		return 0;
	}
	c = code[pos];
	switch(c & 0xC0) {
	case 0x00:
		pos += 1;
		return c;
	case 0x40:
		pos += 1;
		return c|~0x7F;
	case 0x80:
		pos += 2;
		if(c & 0x20)
			c |= ~0x3F;
		else
			c &= 0x3F;
		return (c<<8)|code[pos-1];
	default:
		pos += 4;
		if(c & 0x20)
			c |= ~0x3F;
		else
			c &= 0x3F;
		return (c<<24)|(code[pos-3]<<16)|(code[pos-2]<<8)|code[pos-1];
	}
}

/*
 * The opcodes whose destination Adr is a branch target rather than an
 * immediate, from libinterp/load.c:/^brpatch.
 */
static int
isbranch(int op)
{
	switch(op) {
	case ICALL: case IJMP: case ISPAWN:
	case IBEQW: case IBNEW: case IBLTW: case IBLEW: case IBGTW: case IBGEW:
	case IBEQB: case IBNEB: case IBLTB: case IBLEB: case IBGTB: case IBGEB:
	case IBEQF: case IBNEF: case IBLTF: case IBLEF: case IBGTF: case IBGEF:
	case IBEQC: case IBNEC: case IBLTC: case IBLEC: case IBGTC: case IBGEC:
	case IBEQL: case IBNEL: case IBLTL: case IBLEL: case IBGTL: case IBGEL:
		return 1;
	}
	return 0;
}

/*
 * A symbol name for the module: the path it is loaded as, with
 * everything that is not a letter or a digit turned into an underscore,
 * so that /dis/sh/std.dis becomes dis_sh_std_dis.  The names only have
 * to be distinct from each other and legal, and the paths already are
 * distinct.
 */
static char*
symof(char *path)
{
	char *s, *p;

	s = strdup(path);
	if(s == nil)
		sysfatal("strdup: %r");
	for(p = s; *p != 0; p++)
		if(!('a' <= *p && *p <= 'z') && !('A' <= *p && *p <= 'Z')
		&& !('0' <= *p && *p <= '9'))
			*p = '_';
	return s;
}

/*
 * Lay out one module, returning its instruction count and, through
 * ntypep, the number of type descriptors.
 */
static int
emit(Biobuf *bs, char *sym, char *file, int *ntypep)
{
	int fd, i, op, add, reg, isize, hsize, tid, tsz, tnp, j;
	long s, d, br;
	Dir *dir;

	if((fd = open(file, OREAD)) < 0)
		sysfatal("open %s: %r", file);
	if((dir = dirfstat(fd)) == nil)
		sysfatal("stat %s: %r", file);
	length = dir->length;
	free(dir);
	code = malloc(length);
	if(code == nil)
		sysfatal("malloc %ld: %r", length);
	if(readn(fd, code, length) != length)
		sysfatal("read %s: %r", file);
	close(fd);
	pos = 0;

	i = operand();
	if(i == SMAGIC)
		sysfatal("%s is signed: dis2s cannot skip the signature", file);
	if(i != XMAGIC)
		sysfatal("%s: bad magic %d", file, i);
	operand();		/* rt */
	operand();		/* ss */
	isize = operand();
	operand();		/* dsize */
	hsize = operand();
	operand();		/* lsize */
	operand();		/* entry */
	operand();		/* entryt */
	if(isize <= 0)
		sysfatal("%s: %d instructions", file, isize);

	Bprint(bs, "\nGLOBL\t%s(SB), RODATA, $%d\n", sym, isize*12);
	for(i = 0; i < isize; i++) {
		if(pos+2 > length)
			sysfatal("%s: instruction stream runs off the end", file);
		op = code[pos++];
		add = code[pos++];
		reg = 0;
		s = 0;
		d = 0;
		switch(add & ARM) {
		case AXIMM:
		case AXINF:
		case AXINM:
			reg = operand();
			break;
		}
		switch(UXSRC(add)) {
		case SRC(AFP):
		case SRC(AMP):
		case SRC(AIMM):
			s = operand();
			break;
		case SRC(AIND|AFP):
		case SRC(AIND|AMP):
			s = operand() & 0xffff;
			s |= (operand() & 0xffff) << 16;
			break;
		}
		br = -1;
		switch(UXDST(add)) {
		case DST(AFP):
		case DST(AMP):
			d = operand();
			break;
		case DST(AIMM):
			d = operand();
			if(isbranch(op)) {
				if(d < 0 || d >= isize)
					sysfatal("%s: instruction %d branches to %ld",
						file, i, d);
				br = d;
			}
			break;
		case DST(AIND|AFP):
		case DST(AIND|AMP):
			d = operand() & 0xffff;
			d |= (operand() & 0xffff) << 16;
			break;
		}
		Bprint(bs, "DATA\t%s+%d(SB)/4, $%#lux\n", sym, i*12,
			(ulong)((op & 0xff) | ((add & 0xff) << 8) | ((reg & 0xffff) << 16)));
		Bprint(bs, "DATA\t%s+%d(SB)/4, $%#lux\n", sym, i*12+4, (ulong)s);
		if(br >= 0)
			Bprint(bs, "DATA\t%s+%d(SB)/4, $%s+%ld(SB)\n",
				sym, i*12+8, sym, br*12);
		else
			Bprint(bs, "DATA\t%s+%d(SB)/4, $%#lux\n", sym, i*12+8, (ulong)d);
	}

	if(pos > length)
		sysfatal("%s: instruction stream runs off the end", file);

	/*
	 * The type descriptors come next, and they are laid out too: a
	 * Type is a size, a pointer count and a pointer map, none of which
	 * depends on the instance, plus a reference count and two function
	 * pointers that parsemod always gives the same values.  The count
	 * is Timmortal, which says the kernel does not own this one; free
	 * is freeheap and mark is markheap, both of which the linker
	 * resolves here, and destroy and initialize are nil, which is what
	 * dtype() leaves them (kernel malloc zeroes).
	 *
	 * Laid out as
	 *	ref, free, mark, size, np, destroy, initialize, map[]
	 * which is struct Type in include/interp.h, padded to a multiple
	 * of four so the next descriptor is aligned.
	 */
	*ntypep = hsize;
	for(j = 0; j < hsize; j++) {
		tid = operand();
		if(tid < 0 || tid >= hsize)
			sysfatal("%s: type id %d of %d", file, tid, hsize);
		tsz = operand();
		tnp = operand();
		if(tsz < 0 || tnp < 0)
			sysfatal("%s: implausible type descriptor", file);
		if(pos+tnp > length)
			sysfatal("%s: type map runs off the end", file);
		Bprint(bs, "\nGLOBL\t%st%d(SB), RODATA, $%d\n", sym, tid,
			(28+tnp+3) & ~3);
		Bprint(bs, "DATA\t%st%d+0(SB)/4, $%#lux\n", sym, tid, (ulong)TIMMORTAL);
		Bprint(bs, "DATA\t%st%d+4(SB)/4, $freeheap(SB)\n", sym, tid);
		Bprint(bs, "DATA\t%st%d+8(SB)/4, $markheap(SB)\n", sym, tid);
		Bprint(bs, "DATA\t%st%d+12(SB)/4, $%#lux\n", sym, tid, (ulong)tsz);
		Bprint(bs, "DATA\t%st%d+16(SB)/4, $%#lux\n", sym, tid, (ulong)tnp);
		Bprint(bs, "DATA\t%st%d+20(SB)/4, $0\n", sym, tid);
		Bprint(bs, "DATA\t%st%d+24(SB)/4, $0\n", sym, tid);
		for(i = 0; i < tnp; i++)
			Bprint(bs, "DATA\t%st%d+%d(SB)/1, $%#ux\n", sym, tid,
				28+i, code[pos+i]);
		pos += tnp;
	}
	if(pos > length)
		sysfatal("%s: type descriptors run off the end", file);

	/* and the array of pointers to them, which is what Module.type is */
	Bprint(bs, "\nGLOBL\t%stype(SB), RODATA, $%d\n", sym, hsize*4);
	for(j = 0; j < hsize; j++)
		Bprint(bs, "DATA\t%stype+%d(SB)/4, $%st%d(SB)\n", sym, j*4, sym, j);

	/*
	 * What follows is the module data segment, the links and the
	 * handlers.  None of that is laid out here: it is either
	 * per-instance or it holds pointers into memory the kernel owns.
	 */
	free(code);
	code = nil;
	return isize;
}

void
main(int argc, char *argv[])
{
	Biobuf *bs, *bc;
	char *stem, *cstem, *dir, *prefix, *sym, buf[512];
	char **dispaths, **files, **syms;
	int i, isize, *isizes, *ntypes;
	long *lengths;

	stem = nil;
	cstem = nil;
	dir = nil;
	prefix = nil;
	ARGBEGIN{
	case 'o':
		stem = EARGF(usage());
		break;
	case 'c':
		cstem = EARGF(usage());
		break;
	case 'r':
		dir = EARGF(usage());
		break;
	case 'p':
		prefix = EARGF(usage());
		break;
	default:
		usage();
	}ARGEND
	if(argc < 1 || stem == nil || cstem == nil)
		usage();

	syms = malloc(argc*sizeof(char*));
	dispaths = malloc(argc*sizeof(char*));
	files = malloc(argc*sizeof(char*));
	isizes = malloc(argc*sizeof(int));
	ntypes = malloc(argc*sizeof(int));
	lengths = malloc(argc*sizeof(long));
	if(syms == nil || dispaths == nil || files == nil
	|| isizes == nil || ntypes == nil || lengths == nil)
		sysfatal("malloc: %r");

	for(i = 0; i < argc; i++) {
		dispaths[i] = argv[i];
		files[i] = strchr(argv[i], '=');
		if(files[i] != nil)
			*files[i]++ = 0;
		else {
			if(dir == nil || prefix == nil)
				usage();
			dispaths[i] = smprint("%s/%s", prefix, argv[i]);
			files[i] = smprint("%s/%s", dir, argv[i]);
			if(dispaths[i] == nil || files[i] == nil)
				sysfatal("smprint: %r");
		}
	}

	snprint(buf, sizeof buf, "%s.s", stem);
	if((bs = Bopen(buf, OWRITE)) == nil)
		sysfatal("create %s: %r", buf);
	Bprint(bs, "/* Generated by utils/dis2s.  Do not edit. */\n");
	Bprint(bs, "#define\tRODATA\t8\t/* utils/tl/l.h */\n");

	for(i = 0; i < argc; i++) {
		sym = symof(dispaths[i]);
		Bprint(bs, "\n/* %s, from %s */\n", dispaths[i], files[i]);
		isize = emit(bs, sym, files[i], &ntypes[i]);
		syms[i] = sym;
		isizes[i] = isize;
		lengths[i] = length;
	}
	if(Bterm(bs) < 0)
		sysfatal("write %s.s: %r", stem);

	snprint(buf, sizeof buf, "%s.c", cstem);
	if((bc = Bopen(buf, OWRITE)) == nil)
		sysfatal("create %s: %r", buf);
	Bprint(bc, "/* Generated by utils/dis2s.  Do not edit. */\n");
	Bprint(bc, "#include \"u.h\"\n");
	Bprint(bc, "#include \"../port/lib.h\"\n");
	Bprint(bc, "#include \"mem.h\"\n");
	Bprint(bc, "#include \"dat.h\"\n");
	Bprint(bc, "#include \"fns.h\"\n");
	Bprint(bc, "#include \"interp.h\"\n\n");
	for(i = 0; i < argc; i++) {
		Bprint(bc, "extern Inst %s[];\n", syms[i]);
		Bprint(bc, "extern Type* %stype[];\n", syms[i]);
	}
	Bprint(bc, "\nstatic Xipmod tab[] = {\n");
	for(i = 0; i < argc; i++)
		Bprint(bc, "\t{ \"%s\", %ld, %d, %s, %d, %stype },\n",
			dispaths[i], lengths[i], isizes[i], syms[i],
			ntypes[i], syms[i]);
	Bprint(bc, "\t{ nil, 0, 0, nil, 0, nil },\n");
	Bprint(bc, "};\n\n");
	Bprint(bc, "Xipmod *xipmods = tab;\n");
	if(Bterm(bc) < 0)
		sysfatal("write %s.c: %r", cstem);

	exits(nerr ? "errors" : nil);
}
