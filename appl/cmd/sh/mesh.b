implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "mesh.m";
	mesh: Mesh;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("mesh: cannot load self: %r"));
	mesh = load Mesh Mesh->PATH;
	if (mesh == nil)
		ctxt.fail("bad module",
			sys->sprint("mesh: cannot load %s: %r", Mesh->PATH));
	ctxt.addsbuiltin("mesh", myself);
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

# usage: mesh NXxNY [domain WxH] [bc clamp|periodic|zero]
# result (5 words): nx ny dx dy bcname - the same shape mesh(2)'s own
# Grid holds, so a caller can do
#   (nx ny dx dy bc) := `{mesh 64x64 domain 1x1 bc periodic}
# and pass nx/ny/dx/dy straight on to pde(2) or any other consumer.
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "mesh")
		return nil;
	line := "mesh " + concat(tl argv);
	(g, err) := mesh->parse(line);
	if (err != nil)
		ctxt.fail("mesh", "mesh: " + err);
	bcname := "clamp";
	case g.bc {
	Mesh->PERIODIC => bcname = "periodic";
	Mesh->ZERO => bcname = "zero";
	}
	return ref Listnode(nil, string g.nx) ::
		ref Listnode(nil, string g.ny) ::
		ref Listnode(nil, sys->sprint("%g", g.dx)) ::
		ref Listnode(nil, sys->sprint("%g", g.dy)) ::
		ref Listnode(nil, bcname) :: nil;
}

word(n: ref Listnode): string
{
	if (n.word != nil)
		return n.word;
	if (n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}

concat(argv: list of ref Listnode): string
{
	if (argv == nil)
		return nil;
	s := word(hd argv);
	for (argv = tl argv; argv != nil; argv = tl argv)
		s += " " + word(hd argv);
	return s;
}
