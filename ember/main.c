#include "ember.h"

/*
 * ember bootstrap compiler driver (C).
 *
 *	parse -> typecheck -> lower -> .dis
 *
 * this tree is the bootstrap, matching limbo/.  the lasting compiler
 * is intended to be self-hosted as appl/cmd/ember/ *.e -> ember.dis.
 *
 * usage: ember [-A] [-c] [-f] [-I path] [-o outfile] file.e
 *	-A	print the ast and exit
 *	-c	typecheck only (no .dis)
 *	-D name	dump the interface signature computed for decl "name"
 *	-f	abort on fatal errors (debugging)
 *	-I	add a directory to the .ei interface search path
 *	-o	output .dis path (default: replace .e with .dis)
 */

static	int	toterrors;
static	int	dumpast;
static	int	tokdump;
static	int	checkonly;
static	char	*outarg;

static void
usage(void)
{
	fprint(2, "usage: ember [-A] [-T] [-c] [-D name] [-f] [-I path] [-o outfile] file.e\n");
	exits("usage");
}

static char*
defout(char *in)
{
	char *p, *o;
	int n;

	n = strlen(in);
	o = allocmem(n + 5);
	strcpy(o, in);
	p = strrchr(o, '.');
	if(p != nil && strchr(p, '/') == nil)
		strcpy(p, ".dis");
	else
		strcat(o, ".dis");
	return o;
}

static void
translate(char *in)
{
	Node *prog;
	Biobuf bo;
	char *out;

	infile = in;
	errors = 0;
	tree = parse(in);
	if(tree == nil){
		toterrors += errors;
		return;
	}
	if(dumpast){
		Binit(&bo, 1, OWRITE);
		astprint(&bo, tree, 0);
		Bterm(&bo);
		toterrors += errors;
		return;
	}
	check(tree);
	if(errors){
		toterrors += errors;
		return;
	}
	if(checkonly){
		toterrors += errors;
		return;
	}
	out = outarg;
	if(out == nil)
		out = defout(in);
	outfile = out;
	bout = Bopen(out, OWRITE);
	if(bout == nil){
		fprint(2, "ember: can't write %s: %r\n", out);
		errors++;
		toterrors += errors;
		return;
	}
	modcom();
	Bterm(bout);
	bout = nil;
	prog = tree;
	USED(prog);
	toterrors += errors;
}

void
main(int argc, char *argv[])
{
	char *s;
	int i;

	lexinit();
	typeinit();

	ARGBEGIN{
	case 'A':
		dumpast = 1;
		break;
	case 'T':
		tokdump = 1;
		break;
	case 'c':
		checkonly = 1;
		break;
	case 'f':
		isfatal = 1;
		break;
	case 'I':
		s = ARGF();
		if(s == nil)
			usage();
		addincpath(s);
		break;
	case 'D':
		signdump = ARGF();
		if(signdump == nil)
			usage();
		break;
	case 'o':
		outarg = ARGF();
		if(outarg == nil)
			usage();
		break;
	default:
		usage();
		break;
	}ARGEND

#ifdef INCPATH
	/*
	 * the built-in default goes LAST so every -I directory can
	 * shadow it, cc-style; added first (the original) it won every
	 * lookup, and a -I pointing at a modified sys.ei was silently
	 * ignored.
	 */
	addincpath(INCPATH);
#endif

	if(argc == 0)
		usage();
	if(argc > 1 && outarg != nil){
		fprint(2, "ember: -o with multiple files\n");
		exits("usage");
	}
	for(i = 0; i < argc; i++){
		if(tokdump){
			lexdump(argv[i]);
			continue;
		}
		if(argc > 1)
			print("%s:\n", argv[i]);
		translate(argv[i]);
	}
	if(toterrors)
		exits("errors");
	exits(0);
}
