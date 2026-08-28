implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "hoc.m";
	hocmod: Hoc;
	Expr: import Hoc;

# A loadable sh(1) module giving shell scripts direct access to
# hoc(2)'s own expression grammar and evaluator - nothing more, the
# same narrow scope hoc(2) itself has (compile/compileeqn/eval/
# symbol/setvar/getvar/reset). This is deliberately a single shared
# instance, not a handle table like sh-pde/sh-mesh/sh-fem have for
# their own Problem/Mesh handles: those hold heavyweight, independently
# steppable simulations a script may want several of at once; hoc here
# is a desk calculator with one persistent symbol table, the same
# single-instance shape hoc(1) itself already is. A script wanting two
# independent symbol tables at once (two unrelated equations, say)
# still has that option - just "mload" a second Namespace (see
# sh-mload(1)) and load a second copy of this module into it.
#
# There is no vocabulary here beyond hoc(2)'s own: this module never
# recognizes "state"/"derivative"/anything else - that belongs to
# dynsys(2) (see sh-dynsys(1)), a different layer built out of hoc
# expressions the same way pde(2) is. Assignment is already part of
# hoc's own grammar ("x = 3"), so there is no separate "set"/"get"
# verb either - ${hoc x} reads a variable, hoc x = 3 (or ${hoc x = 3},
# if the value is wanted too) writes one, exactly hoc(2)'s own
# compile()/eval() applied to whatever expression the words joined
# back into.
initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if(myself == nil)
		ctxt.fail("bad module", sys->sprint("hoc: cannot load self: %r"));
	hocmod = load Hoc Hoc->PATH;
	if(hocmod == nil)
		ctxt.fail("bad module", sys->sprint("hoc: cannot load %s: %r", Hoc->PATH));
	# the one required call before compile()/compileeqn()/symbol() -
	# see hoc.b's own header comment on reset() for why (it lazily
	# loads bufio/math, which compile() needs internally).
	hocmod->reset();
	ctxt.addbuiltin("hoc", myself);
	ctxt.addsbuiltin("hoc", myself);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

getself(): Shellbuiltin
{
	return myself;
}

# usage:
#   hoc reset               - fresh symbol table, forgets every variable
#   hoc EXPR...             - hoc(2) grammar; evaluated for effect only
#                              (an assignment's usual reason to appear
#                              as a bare statement)
#   hoc eqn EXPR...         - eqn(7) syntax instead, via compileeqn()
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if(tl argv == nil)
		ctxt.fail("usage", "usage: hoc (reset|[eqn] expr...)");
	rest := tl argv;
	if((hd rest).word == "reset" && tl rest == nil){
		hocmod->reset();
		return nil;
	}
	(e, err) := parse(rest);
	if(e == nil)
		ctxt.fail("hoc", "hoc: " + err);
	hocmod->eval(e);
	return nil;
}

# usage: ${hoc [eqn] expr...}
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if((hd argv).word != "hoc")
		return nil;
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: ${hoc [eqn] expr...}");
	(e, err) := parse(rest);
	if(e == nil)
		ctxt.fail("hoc", "hoc: " + err);
	v := hocmod->eval(e);
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

# shared by both entry points: "eqn" as the first word selects
# compileeqn() (eqn(7) syntax); anything else is hoc(2)'s own grammar,
# via compile() - the identical choice hoc(2)'s own SEE ALSO
# (danby-aerobraking(1) vs. plain hoc(1) use) already documents.
parse(rest: list of ref Listnode): (ref Expr, string)
{
	if((hd rest).word == "eqn"){
		rest = tl rest;
		if(rest == nil)
			return (nil, "usage: hoc eqn expr...");
		return hocmod->compileeqn(concat(rest));
	}
	e := hocmod->compile(concat(rest));
	if(e == nil)
		return (nil, "parse error");	# already reported to stderr by compile() itself
	return (e, nil);
}

word(n: ref Listnode): string
{
	if(n.word != nil)
		return n.word;
	if(n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}

concat(argv: list of ref Listnode): string
{
	if(argv == nil)
		return nil;
	s := word(hd argv);
	for(argv = tl argv; argv != nil; argv = tl argv)
		s += " " + word(hd argv);
	return s;
}
