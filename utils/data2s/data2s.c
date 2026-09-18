#include <lib9.h>
#include <bio.h>

/*
 * Turn a file into assembler that carries its bytes.
 *
 * The default puts them in the data segment, as DATA lines under a
 * GLOBL.  With -t they go in the text segment instead, as WORD lines
 * under a TEXT symbol -- the same thing os/inferno/armv7m/l.s does for
 * its vector table.  That matters for a kernel whose text is in flash
 * and whose data is copied into RAM at boot: a built-in file emitted
 * this way stays in the flash and is read where it lies, which is what
 * os/inferno/port/devroot.c's xip method hands out.
 *
 * -t packs four bytes to a WORD low byte first, so it is correct on a
 * little-endian target and wrong on a big-endian one.  Every target in
 * this tree that bundles a root file system is little-endian; a
 * big-endian one would want the packing reversed here rather than a
 * workaround at the call site.
 */

static void
usage(void)
{
	fprint(2, "usage: data2s [-t] name\n");
	exits("usage");
}

void
main(int argc, char *argv[])
{
	Biobuf bin, bout;
	long len;
	int n, i, textseg;
	ulong v;
	uchar block[8], *c;

	textseg = 0;
	ARGBEGIN{
	case 't':
		textseg = 1;
		break;
	default:
		usage();
	}ARGEND
	if(argc != 1)
		usage();

	setbinmode();
	Binit(&bin, 0, OREAD);
	Binit(&bout, 1, OWRITE);

	len = 0;
	if(textseg){
		Bprint(&bout, "TEXT %scode(SB), 1, $-4\n", argv[0]);
		for(;;){
			for(n = 0; n < 4; n++){
				i = Bgetc(&bin);
				if(i < 0)
					break;
				block[n] = i;
			}
			if(n == 0)
				break;
			for(i = n; i < 4; i++)
				block[i] = 0;		/* pad the last word */
			v = (ulong)block[0] | ((ulong)block[1]<<8) |
			    ((ulong)block[2]<<16) | ((ulong)block[3]<<24);
			Bprint(&bout, "\tWORD\t$%#lux\n", v);
			len += n;
			if(n < 4)
				break;
		}
		if(len == 0)
			Bprint(&bout, "\tWORD\t$0\n");	/* a symbol must exist */
	}
	else{
		for(; (n=Bread(&bin, block, sizeof(block))) > 0; len += n){
			Bprint(&bout, "DATA %scode+%ld(SB)/%d, $\"", argv[0], len, n);
			for(c=block; c < block+n; c++)
				if(*c)
					Bprint(&bout, "\\%uo", *c);
				else
					Bprint(&bout, "\\z");
			Bprint(&bout, "\"\n");
		}
		if(len == 0)
			Bprint(&bout, "GLOBL %scode+0(SB), $1\n", argv[0]);
		else
			Bprint(&bout, "GLOBL %scode+0(SB), $%ld\n", argv[0], len);
	}

	/* the length stays a data word either way: four bytes per file */
	Bprint(&bout, "GLOBL %slen+0(SB), $4\n", argv[0]);
	Bprint(&bout, "DATA %slen+0(SB)/4, $%ld\n", argv[0], len);
	exits(0);
}
