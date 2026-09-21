implement Authchk;

#
# Run keyring->auth() and say whether it fits.
#
# doc/pycubed-plan.ms rests on a satellite authenticating a ground
# station before it exports anything, and man/1/radiossl says plainly
# that no part of keyring(2) has ever been run here: radiossl writes the
# same constant into both ends, which demonstrates the transport and
# not the authentication.
#
# The question underneath all of it is whether the protocol runs at all
# on the target core.  keyring->auth() is Diffie-Hellman and a signature
# check over 1024-bit numbers on a board whose heap measured 73728 bytes
# at a shell prompt, and no argument settles that.  So this runs it over
# a pipe first, both ends in one kernel, with no radio in the way: if it
# does not fit here it will not fit over a link, and the radio plumbing
# would have been spent finding that out.
#
#	authchk			over a pipe, both ends here
#	authchk fd n [ground]	over an open file descriptor, one end
#	authchk lora ground [noack]	over a /net/lora conversation
#	authchk lora satellite [noack]	over one, the other end
#
# The second form is the same exchange over whatever a caller has open.
# The third is that with the radio underneath, which is the claim
# doc/radio-evidence.ms calls C1 and has never run: ssl(3) over the
# link is measured, and the authentication under it is not.
#

include "sys.m";
	sys: Sys;
include "ipints.m";
include "keyring.m";
	kr: Keyring;

Authchk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

include "draw.m";

Ground:	con "/keys/ground";
Sat:	con "/keys/satellite";
Radio:	con "/dev/radio0/data";
Lctl:	con "#L/ctl";
Clone:	con "#L/clone";

nrun, nfail: int;

ck(what: string, ok: int, detail: string)
{
	nrun++;
	if(ok)
		sys->print("%s ok\n", what);
	else{
		nfail++;
		sys->print("%s FAIL %s\n", what, detail);
	}
}

mem(): string
{
	fd := sys->open("#c/memory", Sys->OREAD);
	if(fd == nil)
		return sys->sprint("%r");
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return sys->sprint("%r");
	return string b[0:n];
}

# One line per pool from os/inferno/port/alloc.c:poolread(): seven
# numbers and then the name, of which the first is the bytes in use.
# Printing the whole table twice would bury the one number this is
# about.
inuse(s, name: string): int
{
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf < 2)
			continue;
		first := hd f;
		last := "";
		for(l := f; l != nil; l = tl l)
			last = hd l;
		if(last == name)
			return int first;
	}
	return -1;
}

#
# keyring->auth() returns the identity the other end proved, or, when
# it proved nothing, the reason.  The two are told apart by the secret:
# libinterp/keyring.c sets the first element to the peer's name and the
# second to the shared secret on success, and leaves the second nil and
# puts the error in the first otherwise.  Reading the first as an error
# is easy and wrong -- it reports "satellite" as a failure -- so this
# asks the secret.
#
#
# A conversation on #L over the packet device.  Both ends connect;
# neither announces, and that is not a detail.  keyring->auth() is
# symmetric: each end sends its version message before either has
# received anything, so an announced conversation -- which has nobody
# to send to until it has been spoken to -- cannot be one end of it.
# Worse, when that first write fails, libinterp/keyring.c:1836 goes on
# to send an error and then loops reading a reply that cannot come, so
# what should be an immediate failure is a hang with nothing printed.
#
# The conversation's ctl has to stay open for as long as its data is
# used, so it is returned alongside.
#
loraconv(announcing, ack: int): (ref Sys->FD, ref Sys->FD)
{
	rfd := sys->open(Radio, Sys->ORDWR);
	if(rfd == nil){
		sys->print("authchk: %s: %r\n", Radio);
		return (nil, nil);
	}
	lfd := sys->open(Lctl, Sys->ORDWR);
	if(lfd == nil){
		sys->print("authchk: %s: %r\n", Lctl);
		return (nil, nil);
	}
	me := 1;
	if(announcing)
		me = 2;
	if(sys->fprint(lfd, "addr %d", me) < 0 ||
	   sys->fprint(lfd, "fd %d", rfd.fd) < 0){
		sys->print("authchk: attach: %r\n");
		return (nil, nil);
	}
	cfd := sys->open(Clone, Sys->ORDWR);
	if(cfd == nil){
		sys->print("authchk: %s: %r\n", Clone);
		return (nil, nil);
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		sys->print("authchk: read clone: %r\n");
		return (nil, nil);
	}
	num := int string b[0:n];
	peer := 2;
	if(announcing)
		peer = 1;
	n = sys->fprint(cfd, "connect %d", peer);
	# Acknowledgement and retry by default, because the exchange
	# above is symmetric and a half-duplex radio loses whatever two
	# stations say at once.  Settable, so what it is worth can be
	# measured rather than assumed.
	if(n >= 0 && ack)
		n = sys->fprint(cfd, "ack on");
	if(n >= 0 && ack)
		n = sys->fprint(cfd, "retries 8");
	if(n < 0){
		sys->print("authchk: conversation ctl: %r\n");
		return (nil, nil);
	}
	dfd := sys->open(sys->sprint("#L/%d/data", num), Sys->ORDWR);
	if(dfd == nil){
		sys->print("authchk: #L/%d/data: %r\n", num);
		return (nil, nil);
	}
	sys->print("AUTHCHK-LORA #L/%d addr %d iounit %d\n",
		num, me, sys->iounit(dfd));
	return (dfd, cfd);
}

child(fd: ref Sys->FD, info: ref Keyring->Authinfo, c: chan of (string, int))
{
	(who, secret) := kr->auth(fd, info, 0);
	n := 0;
	if(secret != nil)
		n = len secret;
	c <-= (who, n);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->print("authchk: load %s: %r\n", Keyring->PATH);
		return;
	}

	gi := kr->readauthinfo(Ground);
	ck("ground-key-read", gi != nil, sys->sprint("%s: %r", Ground));
	si := kr->readauthinfo(Sat);
	ck("satellite-key-read", si != nil, sys->sprint("%s: %r", Sat));
	if(gi == nil || si == nil){
		verdict();
		return;
	}

	argv = tl argv;
	if(argv != nil && hd argv == "lora"){
		which := si;
		announcing := 1;
		if(tl argv != nil && hd tl argv == "ground"){
			which = gi;
			announcing = 0;
		}
		ack := 1;
		for(a1 := argv; a1 != nil; a1 = tl a1)
			if(hd a1 == "noack")
				ack = 0;
		(dfd, cfd) := loraconv(announcing, ack);
		if(dfd == nil)
			return;
		if(tl argv != nil && tl tl argv != nil &&
		   hd tl tl argv == "probe"){
			pb := array of byte "probe";
			pn := sys->write(dfd, pb, len pb);
			sys->print("PROBE write %d %r\n", pn);
			return;
		}
		t0 := sys->millisec();
		(who, secret) := kr->auth(dfd, which, 0);
		ms := sys->millisec() - t0;
		ck("auth-over-lora", secret != nil, who);
		if(secret != nil)
			sys->print("peer %q, secret %d bytes in %d ms\n",
				who, len secret, ms);
		if(cfd == nil)
			sys->print("authchk: no conversation ctl\n");
		verdict();
		return;
	}
	if(argv != nil && hd argv == "fd"){
		if(tl argv == nil){
			sys->print("usage: authchk fd n\n");
			return;
		}
		fd := sys->fildes(int hd tl argv);
		if(fd == nil){
			sys->print("authchk: fildes: %r\n");
			return;
		}
		which := si;
		if(tl tl argv != nil && hd tl tl argv == "ground")
			which = gi;
		t0 := sys->millisec();
		(who, secret) := kr->auth(fd, which, 0);
		ms := sys->millisec() - t0;
		ck("auth", secret != nil, who);
		if(secret != nil)
			sys->print("peer %q, secret %d bytes in %d ms\n",
				who, len secret, ms);
		verdict();
		return;
	}

	before := inuse(mem(), "main");
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("authchk: pipe: %r\n");
		return;
	}
	c := chan of (string, int);
	spawn child(p[1], si, c);

	t0 := sys->millisec();
	(gpeer, gsec) := kr->auth(p[0], gi, 0);
	(speer, slen) := <-c;
	ms := sys->millisec() - t0;
	after := inuse(mem(), "main");

	glen := 0;
	if(gsec != nil)
		glen = len gsec;
	ck("ground-side", glen > 0, gpeer);
	ck("satellite-side", slen > 0, speer);
	ck("same-length", glen == slen,
		sys->sprint("ground %d satellite %d", glen, slen));

	# The point of the whole exchange: each end learns which
	# certified identity the other holds, and neither was told.
	ck("ground-learned-satellite", gpeer == "satellite",
		sys->sprint("got %q", gpeer));
	ck("satellite-learned-ground", speer == "ground",
		sys->sprint("got %q", speer));

	sys->print("auth took %d ms\n", ms);
	sys->print("main in use %d before, %d after\n", before, after);
	verdict();
}

verdict()
{
	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("AUTHCHK-OK\n");
}
