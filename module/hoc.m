# hoc's real module interface - see appl/lib/hoc.b's own header comment
# for the full translation write-up (this file is just the exported shape).
#
# compile()/eval()/symbol()/setvar()/getvar()/reset() are library entry
# points added for callers that want hoc's real expression grammar and
# evaluator directly - a named-variable equation language, not a REPL -
# rather than hoc(1)'s own file/stdin-driven init()/run(). See appl/lib/
# hoc.b's own header comment on those functions for how they're meant to
# be used (parse once per model load, rebind and eval() many times).
#
# No "include draw.m" here, deliberately - this file's own Expr/Sym/
# compile/eval/evalarray shape needs no Draw type at all, only init()'s
# and run()'s command-entry signatures do. Forcing draw.m on every
# includer broke every existing Draw-using caller that also
# (transitively, via pde.m) ends up including this one - Limbo has no
# include-guard, so two paths to the same .m file is a hard
# redeclaration error, not a no-op. tk.m/wmclient.m/meshview.m already
# follow the same rule (see meshview.m's own header comment): a caller
# needing init()/run() (i.e. implementing this module, not just calling
# compile()/eval()/evalarray()/symbol()) must include "draw.m" itself,
# before this file.

Hoc: module
{
	PATH: con "/dis/lib/hoc.dis";

	Sym: adt
	{
		name:	string;
		kind:	int;
		val:	real;		# for SKUNDEF/SKVAR
		fdefn:	ref Fn;		# for SKFUNC/SKPROC
		vals:	array of real;	# for evalarray(): nil means "use val,
					# broadcast" - see evalarray's own
					# comment below for how the SAME Sym
					# and compiled Expr serve both a
					# scalar caller (eval()) and an
					# array-context caller at once.
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

	# compileeqn: like compile(), but src is eqn(7) syntax (see
	# eqn2hoc(2)) rather than hoc's own expression grammar directly -
	# the eqn(7)->hoc(2) translation step lives HERE, inside the
	# library, so a caller whose equations are written in eqn never
	# needs to load or even know about eqn2hoc(2) itself; it just asks
	# hoc to compile eqn source, same as compile() for hoc source
	# directly. Returns (nil, an error string) on either a translation
	# error or a hoc compile error - the same "no silently wrong
	# answer" discipline compile() alone doesn't need, since ordinary
	# hoc source has no separate translation stage to fail at.
	compileeqn:	fn(src: string): (ref Expr, string);

	eval:		fn(e: ref Expr): real;
	symbol:		fn(name: string): ref Sym;
	setvar:		fn(name: string, v: real);
	getvar:		fn(name: string): real;
	reset:		fn();

	# evalarray(): the SAME compiled Expr - the same tree compile()
	# returned, with its Var/Assign nodes holding the same ref Sym
	# handles eval() uses - walked in a different context: once per
	# CALL rather than once per element. Any Sym referenced by e whose
	# .vals is non-nil contributes its array elementwise (all such
	# arrays must have length n); any Sym whose .vals is nil
	# contributes its scalar .val, broadcast. This is what lets one
	# parsed equation drive both a scalar per-model evaluator (Danby)
	# and a whole-grid one (a PDE field) without reparsing or a second
	# grammar - see appl/lib/hoc.b's header comment for the walker and
	# its real, stated limits (Assign/PreIncDec/PostIncDec/Call/ReadE
	# are not supported in array context; division by zero and domain
	# errors produce IEEE Inf/NaN silently rather than hocerror's
	# printed message, since a whole-grid walk expects to hit both at
	# individual cells routinely).
	evalarray:	fn(e: ref Expr, n: int): array of real;
};

