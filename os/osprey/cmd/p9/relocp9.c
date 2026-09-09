/*
 * relocp9.c - a program built to notice a relocation that did not happen.
 *
 * The personality lays a program at the address it was linked for, which
 * is why there are seven fixed bases in p9lib.h and why two instances of
 * one image cannot run at once.  Relocation is the way out of that, and
 * the question it turns on is not whether this linker emits relocation
 * records - it does, 6l -u writes them - but whether it emits one for
 * every absolute address it lays down.  A set that is nearly complete is
 * worse than none: the image runs until it reaches the one pointer
 * nobody fixed.
 *
 * So this program is mostly absolute addresses, in the two forms a C
 * program produces them: a table of pointers to strings, and a table of
 * pointers to functions.  Both live in the data segment, both hold the
 * address the linker gave them, and both are wrong at a different base
 * unless something corrected them.  Nothing here is reached through an
 * offset the compiler could have made relative.
 *
 * What it prints is arithmetic over both tables, so a pointer that was
 * missed shows as a wrong number or a fault rather than as a subtly
 * different string nobody reads.  The numbers are stated here and in the
 * check, and neither was written after seeing a machine.
 */
#include <u.h>
#include <libc.h>

static int	one(void);
static int	two(void);
static int	three(void);
static int	four(void);
static int	five(void);

/* pointers to functions: each is an absolute address in the data */
static int (*fns[])(void) = { one, two, three, four, five };

/* pointers to strings: the same, to text the linker placed */
static char *words[] = {
	"relocation",
	"is",
	"the",
	"way",
	"out",
};

static int one(void)	{ return 1; }
static int two(void)	{ return 2; }
static int three(void)	{ return 3; }
static int four(void)	{ return 4; }
static int five(void)	{ return 5; }

enum {
	Nfn	= 5,
	Fnsum	= 15,		/* 1+2+3+4+5 */
	Nword	= 5,
	Lensum	= 21,		/* 10+2+3+3+3 */
};

void
startboot(char *argv0, char **argv)
{
	int i, fsum, lsum;

	USED(argv0); USED(argv);

	fsum = 0;
	for(i = 0; i < Nfn; i++)
		fsum += (*fns[i])();

	lsum = 0;
	for(i = 0; i < Nword; i++)
		lsum += strlen(words[i]);

	/*
	 * Each word is passed through its own pointer, so the sentence is
	 * five separate absolute addresses read at the moment of printing
	 * rather than one buffer built earlier.
	 */
	print("reloc: %d function pointers summing to %d, %d string pointers of total length %d: \"%s %s %s %s %s\"\n",
		Nfn, fsum, Nword, lsum,
		words[0], words[1], words[2], words[3], words[4]);
	if(fsum != Fnsum || lsum != Lensum)
		print("reloc: that is not the %d and %d this program was written to produce\n",
			Fnsum, Lensum);
	exits(nil);
}
