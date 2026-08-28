# hoc's real module interface - see appl/lib/hoc.b's own header comment
# for the full translation write-up (this file is just the exported shape).
#
# compile()/eval()/symbol()/setvar()/getvar()/reset() are library entry
# points added for callers that want hoc's real expression grammar and
# evaluator directly - a named-variable equation language, not a REPL -
# rather than hoc(1)'s own file/stdin-driven init()/run(). See appl/lib/
# hoc.b's own header comment on those functions for how they're meant to
# be used (parse once per model load, rebind and eval() many times).

include "draw.m";

Hoc: module
{
	PATH: con "/dis/lib/hoc.dis";

	Sym: adt
	{
		name:	string;
		kind:	int;
		val:	real;		# for SKUNDEF/SKVAR
		fdefn:	ref Fn;		# for SKFUNC/SKPROC
	};

	Fn: adt
	{
		kind:	int;		# SKFUNC or SKPROC
		params:	list of string;
		body:	list of ref Stmt;
	};

	Expr: adt
	{
		pick {
		Num =>
			v:	real;
		Var =>
			sym:	ref Sym;
		Assign =>
			sym:	ref Sym;
			op:	int;	# TASSIGN or a compound-assign token
			e:	ref Expr;
		Bin =>
			op:	int;
			l, r:	ref Expr;
		Un =>
			e:	ref Expr;	# unary minus only
		Not =>
			e:	ref Expr;
		PreIncDec =>
			sym:	ref Sym;
			op:	int;	# TINC or TDEC
		PostIncDec =>
			sym:	ref Sym;
			op:	int;
		Call =>
			sym:	ref Sym;	# kind == SKFUNC
			args:	list of ref Expr;
		Bltin =>
			name:	string;
			arg:	ref Expr;
		ReadE =>
			sym:	ref Sym;
		}
	};

	PrItem: adt
	{
		pick {
		PExpr =>
			e:	ref Expr;
		PStr =>
			s:	string;
		}
	};

	Stmt: adt
	{
		pick {
		SExpr =>
			e:	ref Expr;
		SBlock =>
			body:	list of ref Stmt;
		SIf =>
			cond:	ref Expr;
			then:	list of ref Stmt;
			els:	list of ref Stmt;	# nil if no else
		SWhile =>
			cond:	ref Expr;
			body:	list of ref Stmt;
		SFor =>
			init:	ref Expr;	# any may be nil
			cond:	ref Expr;
			incr:	ref Expr;
			body:	list of ref Stmt;
		SReturn =>
			e:	ref Expr;	# nil for a bare `return`
		SPrint =>
			items:	list of ref PrItem;
		SCall =>
			sym:	ref Sym;	# kind == SKPROC
			args:	list of ref Expr;
		}
	};

	init:	fn(ctxt: ref Draw->Context, argv: list of string);

	# in-process test seam: run the given command-line-style argument
	# list (files, "-", "-e expr") exactly as init() would, returning
	# captured stdout and an ok flag (0 if any runtime/parse error was
	# ever reported to stderr during the run, matching the fact that
	# the real hoc itself always exits 0 regardless - this seam adds
	# the ok flag purely so hoctest.b can tell the two cases apart
	# without scraping stderr text).
	run:	fn(argv: list of string): (string, int);

	# library entry points, added for callers that want hoc's real
	# expression grammar and evaluator directly - a named-variable
	# equation language, not a REPL. compile() parses ONE hoc
	# expression (which may itself be an assignment, e.g.
	# "dprey = birth*prey - predation*prey*predators") from a string
	# and returns its already-resolved tree; every Var/Assign node
	# inside it holds a ref Sym directly (see the Expr adt below), so
	# the SAME compiled tree can be eval()ed again after rebinding a
	# variable's value with symbol().val = ... - it does not need to
	# be recompiled per call. This is what makes it usable inside a
	# tight per-step integration loop: parse once per model load,
	# rebind and eval() many times. reset() starts a fresh symbol
	# table (the same constants/builtins init() itself installs) -
	# call it once before compiling a new, unrelated set of equations
	# so an earlier caller's variable names can't leak into a new one.
	compile:	fn(src: string): ref Expr;
	eval:		fn(e: ref Expr): real;
	symbol:		fn(name: string): ref Sym;
	setvar:		fn(name: string, v: real);
	getvar:		fn(name: string): real;
	reset:		fn();
};

