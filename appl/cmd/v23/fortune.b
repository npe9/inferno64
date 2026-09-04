# Vanadium Fortune client — Limbo port of x/ref/examples/fortune.
implement Fortune;

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "keyring.m";

include "dial.m";

include "msgio.m";

include "v23.m";
	v23sec: V23security;
	v23rpc: V23rpc;
	Principal: import v23sec;
	Client: import v23rpc;

Fortune: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

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
	arg->setusage("v23/fortune [-a addr] [-n name] [get | add text | has text]");
	addr := "tcp!127.0.0.1!3242";
	name := "alice";
	while((o := arg->opt()) != 0)
		case o {
		'a' =>
			addr = arg->earg();
		'n' =>
			name = arg->earg();
		* =>
			arg->usage();
		}
	args = arg->argv();
	cmd := "get";
	text := "";
	if(args != nil){
		cmd = hd args;
		args = tl args;
		if(args != nil)
			text = hd args;
	}

	(p, err) := v23sec->createprincipal(512, name);
	if(p == nil)
		fail(err);
	(b, err2) := p.blessself(name, v23sec->unconstrained() :: nil);
	if(b == nil)
		fail(err2);
	p.setdefault(b);
	p.addroot(b);

	# Trust any server root presented at dial time for the demo.
	# Production: addroot from a known blessing file instead.
	(c, err3) := dial_tofu(addr, p);
	if(c == nil)
		fail(err3);

	case cmd {
	"get" or "Get" =>
		(r, e4) := v23rpc->call(c, "Get", "");
		if(e4 != nil)
			fail(e4);
		sys->print("%s\n", r);
	"add" or "Add" =>
		if(text == nil)
			fail("usage: fortune add text");
		(nil, e5) := v23rpc->call(c, "Add", text);
		if(e5 != nil)
			fail(e5);
		sys->print("added\n");
	"has" or "Has" =>
		if(text == nil)
			fail("usage: fortune has text");
		(r, e6) := v23rpc->call(c, "Has", text);
		if(e6 != nil)
			fail(e6);
		sys->print("%s\n", r);
	* =>
		fail("unknown command "+cmd);
	}
	v23rpc->close(c);
}

# Dial, and if server roots are unrecognized, add them and retry once (demo TOFU).
dial_tofu(addr: string, p: ref Principal): (ref Client, string)
{
	(c, nil) := v23rpc->dial(addr, p);
	if(c != nil)
		return (c, nil);
	# Server root not pre-trusted: TOFU handshake.
	return dial_trustany(addr, p);
}

dial_trustany(addr: string, p: ref Principal): (ref Client, string)
{
	# Use V23rpc dial after injecting a permissive root if we can decode from error — not available.
	# Fallback: duplicate handshake here with TOFU.
	dialm := load Dial Dial->PATH;
	msgio := load Msgio Msgio->PATH;
	if(dialm == nil || msgio == nil)
		return (nil, "load dial/msgio");
	msgio->init();
	conn := dialm->dial(addr, nil);
	if(conn == nil)
		return (nil, sys->sprint("dial: %r"));
	fd := conn.dfd;
	local := p.def;
	enc := v23sec->encodeblessings(local);
	if(msgio->putstring(fd, enc) < 0)
		return (nil, "send blessings");
	(s, e1) := msgio->getstring(fd);
	if(e1 != nil)
		return (nil, e1);
	(sb, e2) := v23sec->decodeblessings(s);
	if(sb == nil)
		return (nil, e2);
	p.addroot(sb);
	(remote, nil) := v23sec->verifyblessings(p, sb);
	if(remote == nil)
		return (nil, "still unrecognized server");
	return (ref Client(p, fd, remote), nil);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "v23/fortune: %s\n", s);
	raise "fail:"+s;
}
