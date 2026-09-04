implement Secstoretest;

#
# hermetic regression test for the secstore(2) network round-trip.
#
# It stands up a minimal secstore server on a loopback socket (using the
# library's own pakserver plus a tiny in-memory GET/PUT loop that speaks
# the same wire protocol as secstore->getfile/putfile), then, as a client,
# runs the full library path: dial, ssl connect, PAK auth, putfile an
# encrypted blob, getfile it back, and check it is byte-identical. It also
# runs a negative control - a client with the wrong password must fail to
# authenticate - so a pass means the PAK verifier is actually being checked,
# not waved through.
#
# This is the regression guard for the two trailing-newline bugs that made
# the round-trip fail with "bad digest": pakserver comparing the client's
# "k'=...\n" verifier line with the newline still attached, and the server
# answering the completed exchange with "OK\n" when the client wants "OK".
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;
include "keyring.m";
	kr: Keyring;
include "security.m";
	ssl: SSL;
include "secstore.m";
	secstore: Secstore;

Secstoretest: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

USER: con "tester";
PASS: con "correct horse battery staple";
STORE: con "teststore";
PORT: con "17771";

failed := 0;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	secstore = load Secstore Secstore->PATH;
	if(secstore == nil || ssl == nil || dial == nil || kr == nil){
		sys->fprint(sys->fildes(2), "secstoretest: load failed: %r\n");
		raise "fail:load";
	}
	secstore->init();

	# the IP stack, if it is not already bound
	sys->bind("#I", "/net", Sys->MAFTER);

	addr := "tcp!127.0.0.1!" + PORT;
	hexH := secstore->mkverifier(USER, PASS);

	ac := dial->announce("tcp!*!" + PORT);
	if(ac == nil){
		sys->fprint(sys->fildes(2), "secstoretest: announce: %r\n");
		raise "fail:announce";
	}
	spawn server(ac, hexH);

	# --- positive: correct password round-trips a file ---
	plain := array of byte "the quick brown fox jumps over the lazy dog";
	got := roundtrip(addr, PASS, plain);
	if(got == nil)
		fail("correct-password round trip failed");
	else if(!eq(got, plain))
		fail("round-tripped file differs from the original");
	else
		ok("correct password: file round-trips byte-identical");

	# --- negative control: wrong password must not authenticate ---
	seckey := secstore->mkseckey("wrong password entirely");
	conn := secstore->dial(dial->netmkaddr(addr, "net", "secstore"));
	if(conn == nil)
		fail("negative control: dial failed");
	else{
		(srv, nil) := secstore->auth(conn, USER, seckey);
		secstore->bye(conn);
		if(srv != nil)
			fail("negative control: wrong password AUTHENTICATED");
		else
			ok("wrong password: authentication correctly rejected");
	}

	if(failed)
		sys->fprint(sys->fildes(2), "secstoretest: FAIL (%d)\n", failed);
	else
		sys->print("secstoretest: PASS\n");
	if(failed)
		raise "fail:test";
}

# client: authenticate, encrypt+putfile, getfile+decrypt, return the plaintext.
roundtrip(addr, pass: string, plain: array of byte): array of byte
{
	seckey := secstore->mkseckey(pass);
	filekey := secstore->mkfilekey(pass);
	conn := secstore->dial(dial->netmkaddr(addr, "net", "secstore"));
	if(conn == nil){
		sys->fprint(sys->fildes(2), "roundtrip: dial: %r\n");
		return nil;
	}
	(srv, diag) := secstore->auth(conn, USER, seckey);
	if(srv == nil){
		sys->fprint(sys->fildes(2), "roundtrip: auth: %s\n", diag);
		secstore->bye(conn);
		return nil;
	}
	enc := secstore->encrypt(plain, filekey);
	if(secstore->putfile(conn, "t", enc) < 0){
		sys->fprint(sys->fildes(2), "roundtrip: putfile: %r\n");
		secstore->bye(conn);
		return nil;
	}
	raw := secstore->getfile(conn, "t", 0);
	secstore->bye(conn);
	if(raw == nil){
		sys->fprint(sys->fildes(2), "roundtrip: getfile: %r\n");
		return nil;
	}
	return secstore->decrypt(raw, filekey);
}

# server: accept connections forever, one handler proc each.
server(ac: ref Dial->Connection, hexH: string)
{
	for(;;){
		lc := dial->listen(ac);
		if(lc == nil)
			continue;
		dfd := dial->accept(lc);
		if(dfd != nil)
			spawn handle(dfd, hexH);
	}
}

handle(dfd: ref Sys->FD, hexH: string)
{
	(cerr, conn) := ssl->connect(dfd);
	if(cerr != nil)
		return;
	buf := array[512] of byte;
	n := sys->read(conn.dfd, buf, len buf);
	if(n <= 0)
		return;
	(u, hexm) := parsereq(string buf[0:n]);
	if(u != USER || hexm == "" || hexm == "0")
		return;
	if(secstore->pakserver(conn, u, hexm, hexH, STORE) != nil)
		return;			# pakserver told the client
	sys->fprint(conn.dfd, "OK");	# exactly "OK", no newline
	files: list of (string, array of byte);
	for(;;){
		m := sys->read(conn.dfd, buf, len buf);
		if(m <= 0)
			return;
		cmd := string buf[0:m];
		while(len cmd > 0 && (cmd[len cmd-1] == '\n' || cmd[len cmd-1] == '\r'))
			cmd = cmd[0:len cmd-1];
		(verb, arg) := split2(cmd);
		case verb {
		"GET" =>
			data := lookup(files, arg);
			if(data == nil){
				sys->fprint(conn.dfd, "-1\n");
			}else{
				sys->fprint(conn.dfd, "%d\n", len data);
				sys->write(conn.dfd, data, len data);
			}
		"PUT" =>
			lb := array[64] of byte;
			ln := sys->read(conn.dfd, lb, len lb);
			if(ln <= 0)
				return;
			nb := int string lb[0:ln];
			if(nb < 0 || nb > secstore->Maxfilesize)
				return;
			d := array[nb] of byte;
			for(nr := 0; nr < nb;){
				k := sys->read(conn.dfd, d[nr:], nb-nr);
				if(k <= 0)
					return;
				nr += k;
			}
			files = (arg, d) :: files;
		"BYE" or "" =>
			return;
		}
	}
}

parsereq(s: string): (string, string)
{
	(nil, lines) := sys->tokenize(s, "\n");
	u := "";
	hexm := "";
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l >= 2 && l[0:2] == "C=")
			u = l[2:];
		else if(len l >= 2 && l[0:2] == "m=")
			hexm = l[2:];
	}
	return (u, hexm);
}

split2(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' '){
			j := i;
			while(j < len s && s[j] == ' ')
				j++;
			return (s[0:i], s[j:]);
		}
	return (s, "");
}

lookup(files: list of (string, array of byte), name: string): array of byte
{
	for(; files != nil; files = tl files){
		(nm, d) := hd files;
		if(nm == name)
			return d;
	}
	return nil;
}

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

ok(m: string)
{
	sys->print("secstoretest: ok - %s\n", m);
}

fail(m: string)
{
	failed++;
	sys->fprint(sys->fildes(2), "secstoretest: FAIL - %s\n", m);
}
