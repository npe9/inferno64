#include "ember.h"

/*
 * ember compiler driver.
 *
 * the full pipeline is
 *
 *	parse -> resolve -> typecheck -> elaborate -> core ir -> lower -> dis
 *
 * milestone 1 implements parse -> ast only.  ember compiles to
 * dis directly; the limbo compiler is used as a reference for
 * layout, signatures, and instruction selection, not linked in.
 *
 * usage: ember [-A] [-f] file.e ...
 *	-A	print the ast and exit
 *	-f	abort on fatal errors (debugging)
 */

static	int	toterrors;
static	int	dumpast;

static void
usage(void)
{
	fprint(2, "usage: ember [-A] [-f] file.e ...\n");
	exits("usage");
}

static void
translate(char *in)
{
	Node *prog;
	Biobuf bo;

	infile = in;
	errors = 0;
	tree = parse(in);
	if(errors == 0 && dumpast && tree != nil){
		Binit(&bo, 1, OWRITE);
		astprint(&bo, tree, 0);
		Bterm(&bo);
	}
	prog = tree;
	USED(prog);
	toterrors += errors;
}

void
main(int argc, char *argv[])
{
	int i;

	lexinit();

	ARGBEGIN{
	case 'A':
		dumpast = 1;
		break;
	case 'f':
		isfatal = 1;
		break;
	default:
		usage();
		break;
	}ARGEND

	if(argc == 0)
		usage();
	for(i = 0; i < argc; i++){
		if(argc > 1)
			print("%s:\n", argv[i]);
		translate(argv[i]);
	}
	if(toterrors)
		exits("errors");
	exits(0);
}
