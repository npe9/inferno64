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
 *	-X	print the file's declarations and uses (xref.c)
 */

static	int	toterrors;
static	int	dumpast;
static	int	geniface;	/* -i: print the module's interface file */
static	int	testmain;	/* -t: add an init that runs every test_ function */
static	int	fmtsrc;		/* -F: print the source formatted */
static	int	tokdump;
static	int	dumpchecked;
static	int	dumpxref;
static	int	checkonly;
static	char	*outarg;

static void
usage(void)
{
	fprint(2, "usage: ember [-A] [-C] [-X] [-T] [-F] [-c] [-i] [-t] [-D name] [-f] [-I path] [-o outfile] file.e\n");
	exits("usage");
}

/*
 * "ember -t": append
 *
 *	import .sys "sys"
 *	func init() {
 *		.failed := 0
 *		try { test_a() } catch .e { .sys.print("FAIL test_a: %s\n", .e); .failed++ }
 *		...
 *		if .failed == 0 { .sys.print("PASS %d tests\n", n) } else { raise "fail:tests" }
 *	}
 *
 * for every top-level "func test_xxx()" in the source, in order
 */
static Node*
tname(Src *src, char *s)
{
	return mkname(src, enter(s, 0));
}

static Node*
tsprint(Src *src, Node *args)
{
	Node *dot, *call;

	dot = mkbin(Odot, tname(src, ".sys"), tname(src, "print"));
	dot->sym = dot->right->sym;
	dot->src = *src;
	call = mkn(Ocall, dot, args);
	call->src = *src;
	return mkunary(Oexpr, call);
}

static void
addtestmain(Node *tree)
{
	Node *p, *d, *stmts, *call, *try, *msg, *imp, *imp2, *fn, *sig, *body, *cond, *last, *ctx, *params;
	Src *src;
	int n;

	src = &tree->src;
	stmts = nil;
	n = 0;
	for(p = tree->right; p != nil; p = p->right){
		d = p->op == Oseq ? p->left : p;
		if(d->op == Ofndecl && d->left->op == Oname && strncmp(d->left->sym->name, "test_", 5) == 0 && d->aux != nil){
			call = mkunary(Oexpr, mkn(Ocall, tname(src, d->left->sym->name), nil));
			call->src = d->src;
			try = mkn(Otry, mkn(Oscope, call, nil), nil);
			try->aux = tname(src, ".e");
			msg = mksconst(src, enter("FAIL ", 0));
			msg = mkbin(Oadd, msg, mksconst(src, d->left->sym));
			msg = mkbin(Oadd, msg, mksconst(src, enter(": %s\n", 0)));
			try->right = mkn(Oscope, mkseq(tsprint(src, rotater(mkseq(msg, tname(src, ".e")))), mkunary(Oinc, tname(src, ".failed"))), nil);
			try->src = d->src;
			stmts = mkseq(stmts, try);
			n++;
		}
		if(p->op != Oseq)
			break;
	}
	if(n == 0){
		fprint(2, "ember: -t: no test_ functions in %s\n", infile);
		return;
	}
	stmts = mkseq(mkbin(Odas, tname(src, ".failed"), mkconst(src, 0)), stmts);
	cond = mkbin(Oeq, tname(src, ".failed"), mkconst(src, 0));
	last = mkn(Oif, cond, mkn(Oscope, tsprint(src, rotater(mkseq(mksconst(src, enter("PASS %d tests\n", 0)), mkconst(src, n)))), nil));
	last->aux = mkn(Oscope, mkunary(Oraise, mksconst(src, enter("fail:tests", 0))), nil);
	stmts = mkseq(stmts, last);
	body = mkn(Oscope, rotater(stmts), nil);
	/* init(.ctxt ref .draw.Context, .args list string): the command signature emuinit links against */
	ctx = mkbin(Odot, tname(src, ".draw"), tname(src, "Context"));
	ctx->sym = ctx->right->sym;
	ctx = mkn(Otref, nil, ctx);
	params = mkseq(mkbin(Ofield, tname(src, ".ctxt"), ctx), mkbin(Ofield, tname(src, ".args"), mkn(Otlist, nil, tname(src, "string"))));
	sig = mkn(Otfunc, rotater(params), nil);
	fn = mkn(Ofndecl, tname(src, "init"), sig);
	fn->aux = body;
	fn->src = *src;
	imp = mkn(Oimport, tname(src, ".sys"), tname(src, "sys"));
	imp->src = *src;
	imp2 = mkn(Oimport, tname(src, ".draw"), tname(src, "draw"));
	imp2->src = *src;
	tree->right = rotater(mkseq(mkseq(mkseq(imp2, imp), tree->right), fn));
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
	if(fmtsrc){
		rawparse = 1;
		keepcomments = 1;
	}
	tree = parse(in);
	if(tree == nil){
		toterrors += errors;
		return;
	}
	if(fmtsrc){
		if(errors == 0){
			Binit(&bo, 1, OWRITE);
			fmtsource(&bo, tree);
			Bterm(&bo);
		}
		toterrors += errors;
		return;
	}
	if(testmain)
		addtestmain(tree);
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
	if(geniface){
		Binit(&bo, 1, OWRITE);
		ifacegen(tree, &bo);
		Bterm(&bo);
		return;
	}
	if(dumpxref){
		/* -X: the names this file declares and every use of one */
		Binit(&bo, 1, OWRITE);
		xref(tree, &bo, emberfns(), emberfnc());
		Bterm(&bo);
		return;
	}
	if(dumpchecked){
		/* -C: the tree after checking, every node with its type --
		 * the oracle for the self-hosted checker */
		Binit(&bo, 1, OWRITE);
		asttypes = 1;
		astprint(&bo, tree, 0);
		asttypes = 0;
		Bterm(&bo);
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
	case 'i':
		geniface = 1;
		break;
	case 't':
		testmain = 1;
		break;
	case 'F':
		fmtsrc = 1;
		break;
	case 'A':
		dumpast = 1;
		break;
	case 'T':
		tokdump = 1;
		break;
	case 'C':
		dumpchecked = 1;
		break;
	case 'X':
		dumpxref = 1;
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
