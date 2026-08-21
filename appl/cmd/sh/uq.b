implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "uq.m";
	uq: Uq;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("uq: cannot load self: %r"));
	uq = load Uq Uq->PATH;
	if (uq == nil)
		ctxt.fail("bad module",
			sys->sprint("uq: cannot load %s: %r", Uq->PATH));
	ctxt.addsbuiltin("uq", myself);
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

# usage: uq spec ; template
# spec and template are each a single word - a script builds each with
# ^ (sh's own concatenation operator) joining literal pieces and \n, the
# same way any other multi-line spec in this tree is assembled from sh.
# Result: "n nfailed mean stddev min max", then n more words, the raw
# samples - the same fields uq(2)'s own Summary carries, so a script
# doing its own analysis beyond the summary statistics still has them.
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "uq")
		return nil;
	argv = tl argv;
	if (len argv != 2)
		ctxt.fail("usage", "usage: uq spec template");
	spec := word(hd argv);
	template := word(hd tl argv);
	(s, err) := uq->run(spec, template);
	if (err != nil)
		ctxt.fail("uq", "uq: " + err);
	rl := ref Listnode(nil, sys->sprint("%d %d %g %g %g %g",
		s.n, s.nfailed, s.mean, s.stddev, s.min, s.max)) :: nil;
	for (i := 0; i < len s.samples; i++)
		rl = ref Listnode(nil, sys->sprint("%g", s.samples[i])) :: rl;
	rrl: list of ref Listnode;
	for (; rl != nil; rl = tl rl)
		rrl = hd rl :: rrl;
	return rrl;
}

word(n: ref Listnode): string
{
	if (n.word != nil)
		return n.word;
	if (n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}
