implement Shellbuiltin;

# A shell interface to frame(2): a structure written down, solved, and
# asked what it did, without writing a Limbo program.
#
# The one thing here that is not a thin wrapper is `member': it returns
# a member's two endpoints, and with `deflected' it returns them moved
# by the displacements times a scale.  A structure has no natural curve
# to plot - it is a set of segments, not a series - so what a drawing of
# one needs is exactly that, one member at a time.  Displacements in a
# real structure are far too small to see, which is why the scale is
# there and why it is the caller's choice rather than a fixed factor.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "frame.m";
	fr: Frame;
	Struct: import fr;

Handle: adt {
	id:	int;
	spec:	string;
	st:	ref Struct;
	solved:	int;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("frame: cannot load self: %r"));
	fr = load Frame Frame->PATH;
	if (fr == nil)
		ctxt.fail("bad module",
			sys->sprint("frame: cannot load %s: %r", Frame->PATH));
	fr->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("frame", myself);
	ctxt.addsbuiltin("frame", myself);
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

USAGE: con "usage: frame (new|del|<id> ...) args...";
VERBS: con "usage: frame <id> (spec|read|solve) args...";

runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", USAGE);
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := newhandle();
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", USAGE);
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", VERBS);
	verb := (hd rest).word;
	a := tl rest;
	case verb {
	"spec" =>
		if (h.st != nil)
			ctxt.fail("frame", "frame: the structure is already read; use a new "+
				"handle to change it");
		line := concat(a);
		if (h.spec == nil)
			h.spec = line;
		else
			h.spec += "\n" + line;
	"read" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: frame <id> read file");
		(txt, err) := readfile(word(hd a));
		if (err != nil)
			ctxt.fail("frame", "frame: " + err);
		if (h.spec == nil)
			h.spec = txt;
		else
			h.spec += "\n" + txt;
	"solve" =>
		s := eparsed(ctxt, h);
		e := fr->solve(s);
		if (e != nil)
			ctxt.fail("frame", "frame: " + e);
		h.solved = 1;
	* =>
		ctxt.fail("usage", "frame: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: frame <id> (displacement|reaction|force|equilibrium|member|nodes|nnodes|nmembers|heldrot|text) args...";

dirof(ctxt: ref Context, w: string): int
{
	case w {
	"x" =>	return fr->DX;
	"y" =>	return fr->DY;
	"r" or "rot" =>	return fr->DR;
	}
	ctxt.fail("usage", "frame: the directions are x, y and r");
	return 0;
}

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "frame")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: frame new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: frame new | frame <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"displacement" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: frame <id> displacement node (x|y|r)");
		s := esolved(ctxt, h);
		return num(s.displacement(word(hd a), dirof(ctxt, word(hd tl a))));
	"reaction" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: frame <id> reaction node (x|y|r)");
		s := esolved(ctxt, h);
		return num(s.reactionat(word(hd a), dirof(ctxt, word(hd tl a))));
	# axial, then the shear and moment at each end, in the member's own
	# directions
	"force" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: frame <id> force n");
		s := esolved(ctxt, h);
		f := fr->memberforces(s, int word(hd a));
		if (f == nil)
			ctxt.fail("frame", "frame: no such member");
		return ref Listnode(nil, sys->sprint("%g", f.axial)) ::
		       ref Listnode(nil, sys->sprint("%g", f.shear1)) ::
		       ref Listnode(nil, sys->sprint("%g", f.moment1)) ::
		       ref Listnode(nil, sys->sprint("%g", f.shear2)) ::
		       ref Listnode(nil, sys->sprint("%g", f.moment2)) :: nil;
	"equilibrium" =>
		s := esolved(ctxt, h);
		(fx, fy, mo) := fr->equilibrium(s);
		return ref Listnode(nil, sys->sprint("%g", fx)) ::
		       ref Listnode(nil, sys->sprint("%g", fy)) ::
		       ref Listnode(nil, sys->sprint("%g", mo)) :: nil;
	# a member's two ends: x1 y1 x2 y2, either where they are or where
	# they went, the displacements multiplied by a scale because a real
	# structure's are far too small to see
	"member" =>
		if (len a != 1 && len a != 3)
			ctxt.fail("usage", "usage: frame <id> member n [deflected scale]");
		s := eparsed(ctxt, h);
		k := int word(hd a);
		if (k < 0 || k >= len s.members)
			ctxt.fail("frame", sys->sprint("frame: there is no member %d; there "+
				"are %d, numbered from 0", k, len s.members));
		m := s.members[k];
		(ax, ay) := (s.nodes[m.a].x, s.nodes[m.a].y);
		(bx, by) := (s.nodes[m.b].x, s.nodes[m.b].y);
		if (len a == 3) {
			if (word(hd tl a) != "deflected")
				ctxt.fail("usage", "usage: frame <id> member n deflected scale");
			esolved(ctxt, h);
			sc := real word(hd tl tl a);
			ax += sc*s.u[3*m.a + fr->DX];
			ay += sc*s.u[3*m.a + fr->DY];
			bx += sc*s.u[3*m.b + fr->DX];
			by += sc*s.u[3*m.b + fr->DY];
		}
		return ref Listnode(nil, sys->sprint("%g", ax)) ::
		       ref Listnode(nil, sys->sprint("%g", ay)) ::
		       ref Listnode(nil, sys->sprint("%g", bx)) ::
		       ref Listnode(nil, sys->sprint("%g", by)) :: nil;
	"nodes" =>
		s := eparsed(ctxt, h);
		l: list of ref Listnode;
		for (i := len s.nodes - 1; i >= 0; i--)
			l = ref Listnode(nil, s.nodes[i].name) :: l;
		return l;
	"nnodes" =>
		return ref Listnode(nil, string len eparsed(ctxt, h).nodes) :: nil;
	"nmembers" =>
		return ref Listnode(nil, string len eparsed(ctxt, h).members) :: nil;
	# how many rotations were held because nothing resisted them, which
	# frame(2) counts rather than doing silently
	"heldrot" =>
		esolved(ctxt, h);
		return ref Listnode(nil, string h.st.heldrot) :: nil;
	"text" =>
		return ref Listnode(nil, h.spec) :: nil;
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

num(v: real): list of ref Listnode
{
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

eparsed(ctxt: ref Context, h: ref Handle): ref Struct
{
	if (h.st != nil)
		return h.st;
	if (h.spec == nil)
		ctxt.fail("frame", "frame: no structure - use \"frame <id> spec ...\" or "+
			"\"frame <id> read file\"");
	(s, e) := fr->parse(h.spec);
	if (e != nil)
		ctxt.fail("frame", "frame: " + e);
	h.st = s;
	return s;
}

esolved(ctxt: ref Context, h: ref Handle): ref Struct
{
	s := eparsed(ctxt, h);
	if (!h.solved)
		ctxt.fail("frame", "frame: nothing has been solved - run \"frame <id> "+
			"solve\" first");
	return s;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if (fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	s := "";
	buf := array[8192] of byte;
	for (;;) {
		n := sys->read(fd, buf, len buf);
		if (n < 0)
			return (nil, sys->sprint("reading %s: %r", path));
		if (n == 0)
			break;
		s += string buf[0:n];
	}
	return (s, nil);
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, 0);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "frame: unknown handle " + w);
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
