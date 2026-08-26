implement Ssh2rsatest;

# Regression test for auth/ssh2rsa - see ssh2rsa.b's own header comment
# for the translation decisions this exercises.
#
# No prebuilt binary and no plan9port copy of this command exist on
# this host (confirmed by search, same situation urlencodetest.b was
# first in - see inferno-rio-cmd-device-oracle) - so instead of a
# binary oracle, this test generates a FRESH real OpenSSH key every
# run via #C (`ssh-keygen`), strips the PEM armor and base64-decodes
# it (also via #C - the real pipeline's own `auth/pemdecode` job, see
# ssh2rsa.b's own header comment on why that stays out of this file's
# scope), and feeds the raw binary blob straight to ssh2rsa->run().
#
# Correctness is then checked INDEPENDENTLY of any Plan 9 code, using
# this tree's own module/ipints.m arithmetic directly: the extracted
# (n, ek, dk, p, q) must satisfy p*q==n and ek*dk===1 (mod p-1) and
# (mod q-1) - the actual mathematical definition of a valid RSA
# private key, not a comparison against anyone else's implementation.
# (The same identities were checked once by hand with Python during
# development, cross-checked against `openssl rsa -text`'s own
# independent decoding of the same key material - see
# doc/plan9-port.md for that derivation; this test re-derives the
# check itself, live, every run, rather than replaying that one
# session's fixed numbers.)

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;

Ssh2rsatest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Ssh2rsa: module
{
	PATH:	con "/dis/auth/ssh2rsa.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string, input: array of byte): string;
};

ssh2rsamod: Ssh2rsa;
stderr: ref FD;
npass, nfail: int;

fail(s: string)
{
	sys->fprint(stderr, "ssh2rsatest: %s\n", s);
	raise "fail:ssh2rsatest";
}

# --- #C host-command device, byte-output variant: the freshly
# generated key blob is raw binary, so accumulate as array of byte
# throughout (asciitest.b's own runhost() pattern), not string. ---

cfd: ref FD;

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhostbytes(cmd: string): array of byte
{
	ensurecmd();
	cfd = sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		fail("cannot open /cmd/clone: no host command device");
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		fail("cannot read /cmd/clone");
	convdir := "/cmd/"+string buf[0:n];

	waitfd := sys->open(convdir+"/wait", Sys->OREAD);
	if(sys->fprint(cfd, "exec /bin/sh -c %q", cmd) < 0)
		fail("cannot exec: no host command device");

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);

	outbuf := array[0] of byte;
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		old := outbuf;
		outbuf = array[len old+rn] of byte;
		outbuf[0:] = old;
		outbuf[len old:] = rb[0:rn];
	}
	for(;;){
		rn := sys->read(errcmd, rb, len rb);
		if(rn <= 0)
			break;
	}
	if(waitfd != nil){
		sb := array[1024] of byte;
		sys->read(waitfd, sb, len sb);
	}
	return outbuf;
}

# genkeyblob: a fresh, unencrypted, 1024-bit OpenSSH key, PEM-armor
# stripped and base64-decoded, all on the host side.
genkeyblob(tag: string): array of byte
{
	tmp := "/tmp/ssh2rsatest-inferno-rio-"+tag;
	cmd := "rm -f "+tmp+" "+tmp+".pub; "+
		"ssh-keygen -q -t rsa -b 1024 -N '' -C '' -f "+tmp+" && "+
		"sed -n '/BEGIN OPENSSH/,/END OPENSSH/p' "+tmp+
		" | sed '1d;$d' | base64 -d; "+
		"rm -f "+tmp+" "+tmp+".pub";
	return runhostbytes(cmd);
}

genenckeyblob(tag: string): array of byte
{
	tmp := "/tmp/ssh2rsatest-inferno-rio-"+tag;
	cmd := "rm -f "+tmp+" "+tmp+".pub; "+
		"ssh-keygen -q -t rsa -b 1024 -N 'somepassphrase' -C '' -f "+tmp+" && "+
		"sed -n '/BEGIN OPENSSH/,/END OPENSSH/p' "+tmp+
		" | sed '1d;$d' | base64 -d; "+
		"rm -f "+tmp+" "+tmp+".pub";
	return runhostbytes(cmd);
}

findattr(toks: list of string, name: string): string
{
	pfx := name+"=";
	for(l := toks; l != nil; l = tl l){
		t := hd l;
		if(len t >= len pfx && t[0:len pfx] == pfx)
			return t[len pfx:];
	}
	return nil;
}

# verify: the real mathematical validity check - see this file's own
# header comment.
verify(line: string): int
{
	if(len line < 4 || line[0:4] != "key ")
		return 0;
	nlline := line;
	if(len nlline > 0 && nlline[len nlline-1] == '\n')
		nlline = nlline[0:len nlline-1];
	(nil, toks) := sys->tokenize(nlline[4:], " ");

	eks := findattr(toks, "ek");
	ns := findattr(toks, "n");
	dks := findattr(toks, "!dk");
	ps := findattr(toks, "!p");
	qs := findattr(toks, "!q");
	if(eks == nil || ns == nil || dks == nil || ps == nil || qs == nil)
		return 0;

	ek := IPint.strtoip(eks, 16);
	n := IPint.strtoip(ns, 16);
	dk := IPint.strtoip(dks, 16);
	p := IPint.strtoip(ps, 16);
	q := IPint.strtoip(qs, 16);
	if(ek == nil || n == nil || dk == nil || p == nil || q == nil)
		return 0;

	if(p.mul(q).cmp(n) != 0)
		return 0;
	one := IPint.inttoip(1);
	pm1 := p.sub(one);
	qm1 := q.sub(one);
	if(ek.mul(dk).mod(pm1).cmp(one) != 0)
		return 0;
	if(ek.mul(dk).mod(qm1).cmp(one) != 0)
		return 0;
	return 1;
}

t1freshkey()
{
	blob := genkeyblob("a");
	if(len blob == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t1freshkey\n  could not generate a test key (ssh-keygen missing?)\n");
		return;
	}
	line := ssh2rsamod->run(nil, blob);
	if(verify(line))
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL t1freshkey\n  got: %q\n  (independent p*q==n / ek*dk===1 check failed)\n", line);
	}
}

t2secondfreshkey()
{
	blob := genkeyblob("b");
	if(len blob == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t2secondfreshkey\n  could not generate a test key\n");
		return;
	}
	line := ssh2rsamod->run(nil, blob);
	if(verify(line))
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL t2secondfreshkey\n  got: %q\n", line);
	}
}

t3badmagic()
{
	got: string;
	ok := 0;
	{
		got = ssh2rsamod->run(nil, array of byte "not an openssh key at all, too short even");
		ok = 1;
	} exception {
	"fail:ssh2rsa" =>
		ok = 0;
	}
	if(ok){
		nfail++;
		sys->fprint(stderr, "FAIL t3badmagic\n  want: raise\n  got:  %q\n", got);
	} else
		npass++;
}

t4encryptedkey()
{
	blob := genenckeyblob("enc");
	if(len blob == 0){
		nfail++;
		sys->fprint(stderr, "FAIL t4encryptedkey\n  could not generate an encrypted test key\n");
		return;
	}
	got: string;
	ok := 0;
	{
		got = ssh2rsamod->run(nil, blob);
		ok = 1;
	} exception {
	"fail:ssh2rsa" =>
		ok = 0;
	}
	if(ok){
		nfail++;
		sys->fprint(stderr, "FAIL t4encryptedkey\n  want: raise (private key seems encrypted)\n  got:  %q\n", got);
	} else
		npass++;
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	ipints = load IPints IPints->PATH;
	ssh2rsamod = load Ssh2rsa Ssh2rsa->PATH;
	if(ssh2rsamod == nil)
		fail("cannot load "+Ssh2rsa->PATH);

	t1freshkey();
	t2secondfreshkey();
	t3badmagic();
	t4encryptedkey();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:ssh2rsatest";
}
