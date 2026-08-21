implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "sparse.m";
include "krylov.m";
include "gpu.m";
	gpu: Gpu;
	Backend: import gpu;

# A standalone handle onto gpu(2)'s own Backend - useful on its own
# (checking ${gpu available}, or building a backend to hand off) even
# though fem(2)'s own "backend ..." spec line is the more usual way a
# script reaches gpu(2): see sh-fem(1).
Handle: adt {
	id:	int;
	b:	ref Backend;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("gpu: cannot load self: %r"));
	gpu = load Gpu Gpu->PATH;
	if (gpu == nil)
		ctxt.fail("bad module",
			sys->sprint("gpu: cannot load %s: %r", Gpu->PATH));
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("gpu", myself);
	ctxt.addsbuiltin("gpu", myself);
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
#   id := ${gpu new}
#   gpu $id device gpu
#   gpu $id precision f32
#   gpu $id resident on
#   echo ${gpu available}
#   gpu del $id
# device/precision/resident are gpu(2)'s own Backend.cmd() vocabulary,
# unchanged - this file adds only the handle bookkeeping, the same
# division of labour sh-pde.b/sh-fem.b already keep with pde(2)/fem(2).
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", "usage: gpu (new|del|<id> ...) args...");
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := ref Handle(nexthandle++, gpu->new());
		addhandle(h);
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: gpu (new|del|<id> ...) args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: gpu <id> (device|precision|resident) args...");
	err := h.b.cmd(concat(rest));
	if (err != nil)
		ctxt.fail("gpu", "gpu: " + err);
	return nil;
}

# usage: gpu available | gpu <id> (device|precision|resident|lasterror)
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "gpu")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: gpu new | gpu available");
	w := (hd argv).word;
	if (w == "new") {
		h := ref Handle(nexthandle++, gpu->new());
		addhandle(h);
		return ref Listnode(nil, string h.id) :: nil;
	}
	if (w == "available")
		return ref Listnode(nil, string gpu->available()) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: gpu new | gpu available | gpu <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: gpu <id> (device|precision|resident|lasterror)");
	case (hd rest).word {
	"device" =>
		return ref Listnode(nil, h.b.device) :: nil;
	"precision" =>
		return ref Listnode(nil, h.b.precision) :: nil;
	"resident" =>
		v := "off";
		if (h.b.resident)
			v = "on";
		return ref Listnode(nil, v) :: nil;
	"lasterror" =>
		e := h.b.lasterror;
		if (e == nil)
			e = "";
		return ref Listnode(nil, e) :: nil;
	}
	return nil;
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "gpu: unknown handle " + w);
	return h;
}

hashslot(id: int): int
{
	return id % len handles;
}

addhandle(h: ref Handle)
{
	slot := hashslot(h.id);
	handles[slot] = h :: handles[slot];
}

gethandle(id: int): ref Handle
{
	for (hl := handles[hashslot(id)]; hl != nil; hl = tl hl)
		if ((hd hl).id == id)
			return hd hl;
	return nil;
}

delhandle(id: int)
{
	slot := hashslot(id);
	nhl: list of ref Handle;
	for (hl := handles[slot]; hl != nil; hl = tl hl)
		if ((hd hl).id != id)
			nhl = hd hl :: nhl;
	handles[slot] = nhl;
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
