# Vanadium wm demo: in-process fortuned + Tk client (blessings + string RPC).
implement V23fortune;

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "keyring.m";

include "v23.m";
	v23sec: V23security;
	v23rpc: V23rpc;
	Principal, Blessings: import v23sec;
	Client, Request: import v23rpc;

V23fortune: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Selftest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Listen: con "tcp!*!3242";
Dialaddr: con "tcp!127.0.0.1!3242";
Bits: con 256;	# demo speed; CLI fortuned uses 512

top: ref Tk->Toplevel;
serverp: ref Principal;
clientp: ref Principal;
fortunes: list of string;
nfortune: int;
ready: int;

cfg := array[] of {
	"frame .f -borderwidth 2 -relief ridge",
	"label .f.title -text {Vanadium Fortune} -anchor w",
	"label .f.status -text {Starting...} -anchor w",
	"label .f.peer -text {} -anchor w",
	"frame .f.b",
	"button .f.b.get -text {Get fortune} -command {send cmd get}",
	"button .f.b.has -text Has -command {send cmd has}",
	"button .f.b.add -text Add -command {send cmd add}",
	"button .f.b.selftest -text Selftest -command {send cmd selftest}",
	"pack .f.b.get .f.b.has .f.b.add .f.b.selftest -side left -padx 2",
	"frame .f.e",
	"label .f.e.l -text {Text:}",
	"entry .f.e.t -width 40",
	"pack .f.e.l -side left",
	"pack .f.e.t -side left -fill x -expand 1",
	"text .f.log -height 12 -width 52 -wrap word -state disabled",
	"pack .f.title -anchor w -padx 4 -pady 2",
	"pack .f.status -anchor w -padx 4",
	"pack .f.peer -anchor w -padx 4 -pady 2",
	"pack .f.b -anchor w -padx 4 -pady 4",
	"pack .f.e -fill x -padx 4 -pady 2",
	"pack .f.log -fill both -expand 1 -padx 4 -pady 4",
	"pack .f -fill both -expand 1",
	"bind .f.e.t <Key-\n> {send cmd add}",
	"pack propagate . 0",
	". configure -width 420 -height 340",
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	v23sec = load V23security V23security->PATH;
	v23rpc = load V23rpc V23rpc->PATH;
	if(v23sec == nil || v23rpc == nil)
		fail(sys->sprint("load v23: %r"));

	sys->pctl(Sys->NEWPGRP, nil);
	ensurenet();

	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(t, menubut) := tkclient->toplevel(ctxt, "", "V23 Fortune", Tkclient->Appl);
	top = t;

	cmdch := chan of string;
	tk->namechan(t, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		tkcmd(cfg[i]);

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "ptr"::"kbd"::nil);

	# Slow keygen off the event loop.
	bootc := chan of string;
	spawn bootstrap(bootc);

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq or
	s = <-menubut =>
		if(s == "exit")
			killgrp();
		tkclient->wmctl(t, s);
	press := <-cmdch =>
		if(ready)
			docmd(press);
		else
			log("still starting...");
	msg := <-bootc =>
		if(msg != nil && len msg > 5 && msg[0:5] == "fail:"){
			setstatus(msg[5:]);
			log(msg);
		}else{
			ready = 1;
			setstatus("Serving "+Listen+" (ACL ...)");
			if(msg != nil)
				setpeer(msg);
			log("ready - Get a fortune or Add one");
		}
	}
}

bootstrap(c: chan of string)
{
	if((e := v23sec->init()) != nil){
		c <-= "fail:"+e;
		return;
	}
	if((e = v23rpc->init()) != nil){
		c <-= "fail:"+e;
		return;
	}

	fortunes = "A journey of a thousand miles begins with a single step." ::
		"Inferno is a distributed operating system." ::
		"Blessings bind names to principals." ::
		"Vanadium RPC authenticates with blessing chains." :: nil;
	nfortune = 4;

	(sp, e1) := v23sec->createprincipal(Bits, "fortuned");
	if(sp == nil){
		c <-= "fail:server principal: "+e1;
		return;
	}
	(sb, e2) := sp.blessself("fortuned", v23sec->unconstrained() :: nil);
	if(sb == nil){
		c <-= "fail:server bless: "+e2;
		return;
	}
	sp.setdefault(sb);
	sp.addroot(sb);
	serverp = sp;

	(cp, e3) := v23sec->createprincipal(Bits, "alice");
	if(cp == nil){
		c <-= "fail:client principal: "+e3;
		return;
	}
	(cb, e4) := cp.blessself("alice", v23sec->unconstrained() :: nil);
	if(cb == nil){
		c <-= "fail:client bless: "+e4;
		return;
	}
	cp.setdefault(cb);
	cp.addroot(cb);
	# Same-process demo: client trusts the server’s self-blessing root.
	cp.addroot(sb);
	clientp = cp;

	reqc := chan of ref Request;
	spawn dispatcher(reqc);
	if((e5 := v23rpc->serve(Listen, sp, v23sec->AllPrincipals :: nil, reqc)) != nil){
		c <-= "fail:serve: "+e5;
		return;
	}

	peer := "server "+namestr(sb)+" / client "+namestr(cb);
	c <-= peer;
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
		i := sys->millisec() % nfortune;
		if(i < 0)
			i = -i;
		r.reply <-= (nth(fortunes, i), nil);
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

docmd(press: string)
{
	case press {
	"get" =>
		rpc("Get", "");
	"add" =>
		text := tk->cmd(top, ".f.e.t get");
		if(text == nil){
			log("Add: enter text first");
			return;
		}
		rpc("Add", text);
		tkcmd(".f.e.t delete 0 end");
	"has" =>
		text := tk->cmd(top, ".f.e.t get");
		if(text == nil){
			log("Has: enter text first");
			return;
		}
		rpc("Has", text);
	"selftest" =>
		spawn runselftest();
	}
}

rpc(method, arg: string)
{
	(c, err) := v23rpc->dial(Dialaddr, clientp);
	if(c == nil){
		log(method+": dial: "+err);
		return;
	}
	setpeer("peer "+join(c.remote));
	(r, e2) := v23rpc->call(c, method, arg);
	v23rpc->close(c);
	if(e2 != nil){
		log(method+": "+e2);
		return;
	}
	case method {
	"Get" =>
		log("fortune: "+r);
	"Add" =>
		log("added");
	"Has" =>
		log("has → "+r);
	* =>
		log(method+": "+r);
	}
}

runselftest()
{
	log("selftest: running...");
	m := load Selftest "/dis/v23/selftest.dis";
	if(m == nil){
		log(sys->sprint("selftest load: %r"));
		return;
	}
	{
		m->init(nil, "v23/selftest" :: nil);
		log("selftest: ok");
	} exception e {
	"fail:*" =>
		log("selftest: "+e);
	}
}

ensurenet()
{
	(ok, nil) := sys->stat("/net/tcp");
	if(ok >= 0)
		return;
	if(sys->bind("#I", "/net", Sys->MAFTER) < 0)
		sys->fprint(sys->fildes(2), "v23fortune: bind #I: %r\n");
}

setstatus(s: string)
{
	tkcmd(".f.status configure -text "+tk->quote(s)+"; update");
}

setpeer(s: string)
{
	tkcmd(".f.peer configure -text "+tk->quote(s)+"; update");
}

log(s: string)
{
	tkcmd(".f.log configure -state normal");
	tkcmd(".f.log insert end "+tk->quote(s+"\n"));
	tkcmd(".f.log see end");
	tkcmd(".f.log configure -state disabled; update");
}

tkcmd(s: string): string
{
	r := tk->cmd(top, s);
	if(len r > 0 && r[0] == '!')
		sys->fprint(sys->fildes(2), "v23fortune tk: %s: %s\n", s, r);
	return r;
}

namestr(b: ref Blessings): string
{
	return join(v23sec->blessingnames(b));
}

join(l: list of string): string
{
	if(l == nil)
		return "";
	s := hd l;
	for(l = tl l; l != nil; l = tl l)
		s += " "+hd l;
	return s;
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

killgrp()
{
	fd := sys->open("#p/"+string sys->pctl(0, nil)+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "v23fortune: %s\n", s);
	raise "fail:"+s;
}
