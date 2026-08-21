implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "sequencer.m";
	sequencer: Sequencer;
	Session: import sequencer;

# A handle wraps one sequencer(2) Session (one master Inst, playing at
# most one score at a time) - the handle bookkeeping is this file's
# only job; every verb below is exactly Session.cmd()'s own vocabulary,
# documented there in full, the same division of labour sh-pde.b/
# sh-gpu.b already keep with pde(2)/gpu(2).
Handle: adt {
	id:	int;
	s:	ref Session;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("synth: cannot load self: %r"));
	sequencer = load Sequencer Sequencer->PATH;
	if (sequencer == nil)
		ctxt.fail("bad module",
			sys->sprint("synth: cannot load %s: %r", Sequencer->PATH));
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("synth", myself);
	ctxt.addsbuiltin("synth", myself);
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
#   id := ${synth new}
#   synth $id noteon 0 60
#   synth $id noteoff 0
#   synth $id play /appl/lib/bachtest.ski
#   synth $id stop
#   synth del $id
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", "usage: synth (new|del|<id> ...) args...");
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := ref Handle(nexthandle++, sequencer->newsession());
		addhandle(h);
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: synth (new|del|<id> ...) args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: synth <id> (noteon|noteoff|play|stop) args...");
	err := h.s.cmd(concat(rest));
	if (err != nil)
		ctxt.fail("synth", "synth: " + err);
	return nil;
}

# usage: synth new (only sbuiltin verb this file adds beyond the
# builtin form above - included for the ${synth new} substitution-call
# style sh-pde.b/sh-gpu.b also both support)
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "synth")
		return nil;
	argv = tl argv;
	if (argv == nil || (hd argv).word != "new")
		ctxt.fail("usage", "usage: synth new");
	h := ref Handle(nexthandle++, sequencer->newsession());
	addhandle(h);
	return ref Listnode(nil, string h.id) :: nil;
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
		ctxt.fail("bad id", "synth: unknown handle " + w);
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
