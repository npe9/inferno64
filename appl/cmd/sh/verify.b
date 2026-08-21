implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "verify.m";
	verify: Verify;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("verify: cannot load self: %r"));
	verify = load Verify Verify->PATH;
	if (verify == nil)
		ctxt.fail("bad module",
			sys->sprint("verify: cannot load %s: %r", Verify->PATH));
	ctxt.addsbuiltin("laplacianorder", myself);
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

runbuiltin(nil: ref Context, nil: Sh,
			nil: list of ref Listnode, nil: int): string
{
	return nil;
}

# usage: laplacianorder n0 levels
# one line of output per level: "n error order", the same fields
# verify(2)'s own Level carries - a shell loop can watch the order
# column climb toward 2.0 without needing to write a driver program,
# e.g.:
#   for (r in `{laplacianorder 8 5}) echo $r
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "laplacianorder")
		return nil;
	argv = tl argv;
	if (len argv != 2 || !isnum((hd argv).word) || !isnum((hd tl argv).word))
		ctxt.fail("usage", "usage: laplacianorder n0 levels");
	n0 := int (hd argv).word;
	levels := int (hd tl argv).word;
	(results, err) := verify->laplacianorder(n0, levels);
	if (err != nil)
		ctxt.fail("laplacianorder", "laplacianorder: " + err);
	rl: list of ref Listnode;
	for (i := len results-1; i >= 0; i--)
		rl = ref Listnode(nil, sys->sprint("%d %g %.3f",
			results[i].n, results[i].error, results[i].order)) :: rl;
	return rl;
}

isnum(s: string): int
{
	if (s == nil)
		return 0;
	for (i := 0; i < len s; i++)
		if (s[i] > '9' || s[i] < '0')
			return 0;
	return 1;
}
