#include <lib9.h>
#include <bio.h>

/*
 * Turn a file into assembler that carries its bytes, as DATA lines
 * under a GLOBL.
 *
 * -t asks for the text segment rather than the data segment, by putting
 * RODATA on the GLOBL -- see utils/tl/l.h.  That matters for a kernel
 * whose text is in flash and whose data segment is copied into RAM at
 * boot: a built-in file emitted this way stays in the flash and is read
 * where it lies, which is what os/inferno/port/devroot.c's xip method
 * hands out.
 *
 * This used to emit a TEXT symbol with WORD lines, the way
 * os/inferno/armv7m/l.s does for its vector table.  That worked, but a
 * reference to a text symbol on an ARM target carries the Thumb bit, so
 * every user of the pointer had to mask it off -- which announced
 * itself as a panic of "bad magic" loading /osinit.dis the first time
 * one did not.  A RODATA symbol is data that happens to live in the
 * text segment, and its address is its address.
 *
 * A linker that does not know RODATA ignores the flag and lays the
 * symbol out in the data segment, which is the behaviour without -t.
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
	long len, size;
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
		/*
		 * Guarded: os/inferno/port/mkroot runs this once per file
		 * and concatenates the results into one assembler file.
		 */
		Bprint(&bout, "#ifndef\tRODATA\n");
		Bprint(&bout, "#define\tRODATA\t8\t/* utils/tl/l.h */\n");
		Bprint(&bout, "#endif\n");
	}
	for(; (n=Bread(&bin, block, sizeof(block))) > 0; len += n){
		Bprint(&bout, "DATA %scode+%ld(SB)/%d, $\"", argv[0], len, n);
		for(c=block; c < block+n; c++)
			if(*c)
				Bprint(&bout, "\\%uo", *c);
			else
				Bprint(&bout, "\\z");
		Bprint(&bout, "\"\n");
	}
	/*
	 * A symbol must have a size even when the file is empty, but the
	 * length word below still has to say zero.
	 */
	size = len != 0? len: 1;
	if(textseg)
		Bprint(&bout, "GLOBL %scode+0(SB), RODATA, $%ld\n", argv[0], size);
	else
		Bprint(&bout, "GLOBL %scode+0(SB), $%ld\n", argv[0], size);

	/* the length stays a data word either way: four bytes per file */
	Bprint(&bout, "GLOBL %slen+0(SB), $4\n", argv[0]);
	Bprint(&bout, "DATA %slen+0(SB)/4, $%ld\n", argv[0], len);
	exits(0);
}
