# Vanadium-style RPC over dial + msgio, with blessing exchange at handshake.
# Port of concepts from github.com/vanadium/core (v.io/v23/rpc).
implement V23rpc;

include "sys.m";
	sys: Sys;

include "keyring.m";

include "dial.m";
	dialmod: Dial;

include "msgio.m";
	msgio: Msgio;

include "v23.m";
	v23sec: V23security;
	Principal, Blessings: import v23sec;

init(): string
{
	sys = load Sys Sys->PATH;
	dialmod = load Dial Dial->PATH;
	if(dialmod == nil)
		return sys->sprint("load dial: %r");
	msgio = load Msgio Msgio->PATH;
	if(msgio == nil)
		return sys->sprint("load msgio: %r");
	msgio->init();
	v23sec = load V23security V23security->PATH;
	if(v23sec == nil)
		return sys->sprint("load v23security: %r");
	if((e := v23sec->init()) != nil)
		return e;
	return nil;
}

serve(addr: string, p: ref Principal, allow: list of string, reqc: chan of ref Request): string
{
	c := dialmod->announce(addr);
	if(c == nil)
		return sys->sprint("announce %s: %r", addr);
	spawn acceptloop(c, p, allow, reqc);
	return nil;
}

acceptloop(ac: ref Dial->Connection, p: ref Principal, allow: list of string, reqc: chan of ref Request)
{
	for(;;){
		nc := dialmod->listen(ac);
		if(nc == nil){
			sys->fprint(sys->fildes(2), "v23rpc: listen: %r\n");
			return;
		}
		dfd := dialmod->accept(nc);
		if(dfd == nil)
			continue;
		spawn serveone(dfd, p, allow, reqc);
	}
}

serveone(fd: ref Sys->FD, p: ref Principal, allow: list of string, reqc: chan of ref Request)
{
	serveconn(fd, p, allow, reqc);
}

serveconn(fd: ref Sys->FD, p: ref Principal, allow: list of string, reqc: chan of ref Request): string
{
	# 1. Receive client blessings, send ours
	(cbless, err) := recvblessings(fd);
	if(cbless == nil){
		msgio->puterror(fd, "handshake: "+err);
		return err;
	}
	local := p.forpeer(v23sec->blessingnames(cbless));
	if(local == nil)
		local = p.def;
	if(local == nil){
		msgio->puterror(fd, "no local blessings");
		return "no local blessings";
	}
	if(sendblessings(fd, local) < 0)
		return "send blessings failed";

	# Demo convenience: if ACL allows "...", trust presented client roots (TOFU).
	if(haspat(allow, v23sec->AllPrincipals))
		p.addroot(cbless);
	(remote, rejected) := v23sec->verifyblessings(p, cbless);
	if(remote == nil){
		msgio->puterror(fd, "unrecognized client"+rejectmsg(rejected));
		return "unrecognized client";
	}
	autherr := v23sec->authorize(allow, remote);
	if(autherr != nil){
		msgio->puterror(fd, autherr);
		return autherr;
	}

	# 2. Request loop
	for(;;){
		(method, e1) := msgio->getstring(fd);
		if(e1 != nil || method == nil)
			return e1;
		if(method == "CLOSE")
			return nil;
		(arg, e2) := msgio->getstring(fd);
		if(e2 != nil)
			return e2;
		reply := chan of (string, string);
		reqc <-= ref Request(method, arg, remote, reply);
		(result, rerr) := <-reply;
		if(rerr != nil){
			msgio->putstring(fd, "ERR");
			msgio->putstring(fd, rerr);
		}else{
			msgio->putstring(fd, "OK");
			msgio->putstring(fd, result);
		}
	}
}

dial(addr: string, p: ref Principal): (ref Client, string)
{
	conn := dialmod->dial(addr, nil);
	if(conn == nil)
		return (nil, sys->sprint("dial %s: %r", addr));
	fd := conn.dfd;

	# Present default / forpeer blessings (peer unknown yet → default)
	local := p.def;
	if(local == nil)
		return (nil, "principal has no default blessings");
	if(sendblessings(fd, local) < 0)
		return (nil, "send blessings failed");
	(sbless, err) := recvblessings(fd);
	if(sbless == nil)
		return (nil, "recv server blessings: "+err);

	# Trust server root from presented blessings (demo convenience: addroot)
	# Caller should have added roots already for production use.
	(remote, rejected) := v23sec->verifyblessings(p, sbless);
	if(remote == nil){
		# try trusting the presented root so mutual demos work when pre-seeded
		return (nil, "unrecognized server" + rejectmsg(rejected));
	}
	c := ref Client(p, fd, remote);
	return (c, nil);
}

call(c: ref Client, method: string, arg: string): (string, string)
{
	if(c == nil || c.fd == nil)
		return (nil, "nil client");
	if(msgio->putstring(c.fd, method) < 0)
		return (nil, sys->sprint("send method: %r"));
	if(msgio->putstring(c.fd, arg) < 0)
		return (nil, sys->sprint("send arg: %r"));
	(status, e1) := msgio->getstring(c.fd);
	if(e1 != nil)
		return (nil, e1);
	(body, e2) := msgio->getstring(c.fd);
	if(e2 != nil)
		return (nil, e2);
	if(status == "OK")
		return (body, nil);
	return (nil, body);
}

close(c: ref Client)
{
	if(c == nil || c.fd == nil)
		return;
	msgio->putstring(c.fd, "CLOSE");
	msgio->putstring(c.fd, "");
	c.fd = nil;
}

sendblessings(fd: ref Sys->FD, b: ref Blessings): int
{
	s := v23sec->encodeblessings(b);
	return msgio->putstring(fd, s);
}

recvblessings(fd: ref Sys->FD): (ref Blessings, string)
{
	(s, err) := msgio->getstring(fd);
	if(err != nil)
		return (nil, err);
	if(s == nil)
		return (nil, "empty blessings");
	# puterror path: peer may send an error framed differently; treat short strings as errors
	if(len s < 8 || s[0:8] != "V23BLESS")
		return (nil, s);
	return v23sec->decodeblessings(s);
}

rejectmsg(rej: list of string): string
{
	if(rej == nil)
		return "";
	s := ":";
	for(; rej != nil; rej = tl rej)
		s += " " + hd rej;
	return s;
}

haspat(allow: list of string, pat: string): int
{
	for(; allow != nil; allow = tl allow)
		if(hd allow == pat)
			return 1;
	return 0;
}
