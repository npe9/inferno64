# Vanadium Fortune server (Get/Add/Has) — Limbo port of x/ref/examples/fortune.
implement Fortuned;

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "keyring.m";

include "v23.m";
	v23sec: V23security;
	v23rpc: V23rpc;
	Principal: import v23sec;
	Request: import v23rpc;

Fortuned: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

fortunes: list of string;
nfortune: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	v23sec = load V23security V23security->PATH;
	v23rpc = load V23rpc V23rpc->PATH;
	if(v23sec == nil || v23rpc == nil)
		fail(sys->sprint("load v23: %r"));
	if((e := v23sec->init()) != nil)
		fail(e);
	if((e = v23rpc->init()) != nil)
		fail(e);

	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("v23/fortuned [-a addr] [-n name]");
	addr := "tcp!*!3242";
	name := "fortuned";
	while((o := arg->opt()) != 0)
		case o {
		'a' =>
			addr = arg->earg();
		'n' =>
			name = arg->earg();
		* =>
			arg->usage();
		}

	fortunes = "A journey of a thousand miles begins with a single step." ::
		"Inferno is a distributed operating system." ::
		"Blessings bind names to principals." :: nil;
	nfortune = 3;

	(p, err) := v23sec->createprincipal(512, name);
	if(p == nil)
		fail(err);
	(b, err2) := p.blessself(name, v23sec->unconstrained() :: nil);
	if(b == nil)
		fail(err2);
	p.setdefault(b);
	p.addroot(b);

	reqc := chan of ref Request;
	spawn dispatcher(reqc);
	err3 := v23rpc->serve(addr, p, v23sec->AllPrincipals :: nil, reqc);
	if(err3 != nil)
		fail(err3);
	sys->print("v23/fortuned: serving as %s on %s\n", name, addr);
	# park
	done := chan of int;
	<-done;
}

dispatcher(reqc: chan of ref Request)
{
	for(;;){
		r := <-reqc;
		spawn handlereq(r);
	}
}

handlereq(r: ref Request)
{
	case r.method {
	"Get" =>
		if(nfortune <= 0){
			r.reply <-= (nil, "no fortunes");
			return;
		}
		# pick by millisec
		i := sys->millisec() % nfortune;
		if(i < 0)
			i = -i;
		f := nth(fortunes, i);
		r.reply <-= (f, nil);
	"Add" =>
		if(r.arg == nil){
			r.reply <-= (nil, "empty fortune");
			return;
		}
		fortunes = r.arg :: fortunes;
		nfortune++;
		r.reply <-= ("ok", nil);
	"Has" =>
		for(l := fortunes; l != nil; l = tl l)
			if(hd l == r.arg){
				r.reply <-= ("true", nil);
				return;
			}
		r.reply <-= ("false", nil);
	* =>
		r.reply <-= (nil, "unknown method "+r.method);
	}
}

nth(l: list of string, i: int): string
{
	for(; l != nil; l = tl l){
		if(i == 0)
			return hd l;
		i--;
	}
	return nil;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "v23/fortuned: %s\n", s);
	raise "fail:"+s;
}
