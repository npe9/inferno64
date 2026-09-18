#include <lib9.h>
#include <bio.h>

/*
 * Pack files into the image os/inferno/port/devflash.c serves.
 *
 * The point of the format is that a file's bytes can be handed out
 * where they lie, so a Dis module in memory-mapped flash is executed in
 * place rather than copied into RAM.  That makes two demands: every
 * file's data is contiguous, and it is aligned well enough for the
 * interpreter's Inst array, which wants a word.  Nothing else about it
 * is clever, because nothing else needs to be.
 *
 *	offset	size		what
 *	0	8		"flashfs\0"
 *	8	4		version, 1
 *	12	4		nfile
 *	16	4		total length of the image
 *	20	4		0
 *	24	nfile*Fent	the directory
 *	...			the file data, each 4-aligned
 *
 * An Fent is
 *	0	4		offset of the data from the start
 *	4	4		length in bytes
 *	8	NAMELEN		the name, NUL padded, no directories
 *
 * All numbers are little-endian, which every target in this tree that
 * would carry one of these is.  A big-endian port would byte-swap here
 * and in devflash.c rather than work around it at either.
 *
 * Names have no slashes: this is one flat directory, which is what a
 * board's spare flash is for.  Anything wanting a tree can mount
 * several.
 */

enum {
	NAMELEN	= 56,
	HDRLEN	= 24,
	ENTLEN	= 8+NAMELEN,
	MAGIC	= 1,
};

static void
usage(void)
{
	fprint(2, "usage: mkflashfs -o image file ...\n");
	exits("usage");
}

static void
put32(uchar *p, u32int v)
{
	p[0] = v;
	p[1] = v>>8;
	p[2] = v>>16;
	p[3] = v>>24;
}

void
main(int argc, char *argv[])
{
	char *out, *name;
	uchar *img, *e;
	int i, fd, nfile;
	long *len, off, total, n;
	Dir *d;

	out = nil;
	ARGBEGIN{
	case 'o':
		out = EARGF(usage());
		break;
	default:
		usage();
	}ARGEND
	if(argc < 1 || out == nil)
		usage();
	nfile = argc;

	len = malloc(nfile*sizeof(long));
	if(len == nil)
		sysfatal("malloc: %r");

	/* first pass: sizes, so the directory can be written before the data */
	total = HDRLEN + nfile*ENTLEN;
	while(total & 3)
		total++;
	for(i = 0; i < nfile; i++) {
		if((d = dirstat(argv[i])) == nil)
			sysfatal("stat %s: %r", argv[i]);
		len[i] = d->length;
		free(d);
		name = strrchr(argv[i], '/');
		name = name != nil? name+1: argv[i];
		if(strlen(name) >= NAMELEN)
			sysfatal("%s: name longer than %d", name, NAMELEN-1);
		total += len[i];
		while(total & 3)
			total++;
	}

	img = malloc(total);
	if(img == nil)
		sysfatal("malloc %ld: %r", total);
	memset(img, 0, total);
	memmove(img, "flashfs", 8);
	put32(img+8, MAGIC);
	put32(img+12, nfile);
	put32(img+16, total);

	off = HDRLEN + nfile*ENTLEN;
	while(off & 3)
		off++;
	for(i = 0; i < nfile; i++) {
		e = img + HDRLEN + i*ENTLEN;
		put32(e+0, off);
		put32(e+4, len[i]);
		name = strrchr(argv[i], '/');
		name = name != nil? name+1: argv[i];
		strcpy((char*)e+8, name);

		if((fd = open(argv[i], OREAD)) < 0)
			sysfatal("open %s: %r", argv[i]);
		n = readn(fd, img+off, len[i]);
		if(n != len[i])
			sysfatal("read %s: got %ld of %ld", argv[i], n, len[i]);
		close(fd);
		off += len[i];
		while(off & 3)
			off++;
	}
	if(off != total)
		sysfatal("internal: laid out %ld of %ld", off, total);

	if((fd = create(out, OWRITE, 0666)) < 0)
		sysfatal("create %s: %r", out);
	if(write(fd, img, total) != total)
		sysfatal("write %s: %r", out);
	close(fd);
	exits(nil);
}
