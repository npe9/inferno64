implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "dynsys.m";
	dynsys: Dynsys;
	Model: import Dynsys;

# A loadable sh(1) module giving shell scripts direct access to
# dynsys(2)'s own ODE-system language, the same relationship sh-pde(1)
# already has to pde(2): a handle table (dynsys(2) problems are
# independently steppable, like pde(2)'s own) around the library's
# five entry points, adding no vocabulary of its own.
#
# Unlike sh-pde(1) (which accumulates spec TEXT lines and defers
# parsing to one later "commit"), dynsys(2)'s own cmd() already
# executes each line immediately - see module/dynsys.m's own header
# comment ("one line in, effect immediate ... never staged for a later
# pass"). So there is no "commit" verb here either: this module simply
# forwards whatever words follow the handle id straight to
# dynsys->cmd(), UNSEEN - the same discipline aerobraking(1)'s own
# cmd() now follows (see its header comment): this file must not
# recognize "param"/"maxtime"/"state"/"derivative"/"eq"/"observable"
# itself, only pass them on to whichever parser owns them.
Handle: adt {
	id:	int;
	model:	ref Model;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if(myself == nil)
		ctxt.fail("bad module", sys->sprint("dynsys: cannot load self: %r"));
	dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		ctxt.fail("bad module", sys->sprint("dynsys: cannot load %s: %r", Dynsys->PATH));
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("dynsys", myself);
	ctxt.addsbuiltin("dynsys", myself);
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
#   id := ${dynsys new}
#   dynsys $id param apoapsis 1.18 1.02 2.0
#   dynsys $id maxtime 40.0
#   dynsys $id state x0 apoapsis
#   dynsys $id derivative x0 vx0
#   dynsys $id eq r "sqrt(x0^2+y0^2)"
#   dynsys $id observable altitude "r-1.0"
#   dynsys del $id
# Every verb after the handle id is dynsys(2)'s own - see dynsys(2)
# for the vocabulary in full; this file never names any of it.
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if(tl argv == nil)
		ctxt.fail("usage", "usage: dynsys (new|del|<id> args...)");
	argv = tl argv;
	w := (hd argv).word;
	if(w == "del"){
		for(argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if(!isnum(w))
		ctxt.fail("usage", "usage: dynsys (new|del|<id> args...)");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: dynsys <id> args...");
	a := towords(rest);
	(claimed, err) := dynsys->cmd(h.model, a);
	if(err != nil)
		ctxt.fail("dynsys", "dynsys: " + err);
	if(!claimed)
		ctxt.fail("dynsys", "dynsys: unknown command " + a[0]);
	return nil;
}

# usage:
#   ${dynsys new}
#   ${dynsys $id check}                      - "" if ready, else an error
#   ${dynsys $id initialstate}                - one word per state, in order
#   ${dynsys $id rhs t v0 v1 ...}              - one word per derivative
#   ${dynsys $id observables v0 v1 ...}        - one word per observable
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if((hd argv).word != "dynsys")
		return nil;
	argv = tl argv;
	if(argv == nil)
		ctxt.fail("usage", "usage: dynsys new");
	w := (hd argv).word;
	if(w == "new"){
		h := ref Handle(nexthandle++, dynsys->newmodel());
		addhandle(h);
		return ref Listnode(nil, string h.id) :: nil;
	}
	if(!isnum(w))
		ctxt.fail("usage", "usage: dynsys new | dynsys <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: dynsys <id> (check|initialstate|rhs|observables) args...");
	m := h.model;
	case (hd rest).word {
	"check" =>
		err := dynsys->check(m);
		if(err == nil)
			err = "";
		return ref Listnode(nil, err) :: nil;
	"initialstate" =>
		return reals2listnodes(dynsys->initialstate(m));
	"rhs" =>
		a := tl rest;
		n := len m.statenames;
		if(len a != n+1)
			ctxt.fail("usage", sys->sprint("usage: dynsys <id> rhs t v0..v%d", n-1));
		t := real (hd a).word;
		values := array[n] of real;
		a = tl a;
		for(i := 0; i < n; i++){
			values[i] = real (hd a).word;
			a = tl a;
		}
		derivative := array[n] of real;
		dynsys->rhs(m, t, values, derivative);
		return reals2listnodes(derivative);
	"observables" =>
		a := tl rest;
		n := len m.statenames;
		if(len a != n)
			ctxt.fail("usage", sys->sprint("usage: dynsys <id> observables v0..v%d", n-1));
		values := array[n] of real;
		for(i := 0; i < n; i++){
			values[i] = real (hd a).word;
			a = tl a;
		}
		return reals2listnodes(dynsys->observables(m, values));
	}
	return nil;
}

reals2listnodes(a: array of real): list of ref Listnode
{
	r: list of ref Listnode;
	for(i := len a - 1; i >= 0; i--)
		r = ref Listnode(nil, sys->sprint("%g", a[i])) :: r;
	return r;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if(h == nil)
		ctxt.fail("bad id", "dynsys: unknown handle " + w);
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
	for(hl := handles[hashslot(id)]; hl != nil; hl = tl hl)
		if((hd hl).id == id)
			return hd hl;
	return nil;
}

delhandle(id: int)
{
	slot := hashslot(id);
	nhl: list of ref Handle;
	for(hl := handles[slot]; hl != nil; hl = tl hl)
		if((hd hl).id != id)
			nhl = hd hl :: nhl;
	handles[slot] = nhl;
}

isnum(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] > '9' || s[i] < '0')
			return 0;
	return 1;
}

word(n: ref Listnode): string
{
	if(n.word != nil)
		return n.word;
	if(n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}

towords(argv: list of ref Listnode): array of string
{
	a := array[len argv] of string;
	i := 0;
	for(; argv != nil; argv = tl argv)
		a[i++] = word(hd argv);
	return a;
}
