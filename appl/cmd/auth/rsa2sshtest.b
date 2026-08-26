implement Rsa2sshtest;

# Regression test for auth/rsa2ssh - see rsa2ssh.b's own header comment
# for the translation decisions this exercises.
#
# THE ORACLE, run live via #C every test run: plan9port's real
# rsa2ssh binary (this host's only installed copy). It needs "-2" to
# get the ssh-rsa-format output this file translates - unpatched,
# plan9port's copy still defaults to the OLDER plain-decimal format
# 9front's own rsa2ssh.c dropped entirely (see rsa2ssh.b's own header
# comment on the two trees' real divergence there) - confirmed
# directly against the binary before writing this test, not assumed.
#
# Test keys: real RSA moduli, generated once via `openssl genrsa` and
# `ssh-keygen`, cross-checked field-by-field against openssl's own
# independent decoding (see doc/plan9-port.md for the full derivation)
# - not randomly-looking placeholder hex.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Rsa2sshtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Rsa2ssh: module
{
	PATH:	con "/dis/auth/rsa2ssh.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string, keyline: string): string;
};

rsa2sshmod: Rsa2ssh;
stderr: ref FD;
npass, nfail: int;

fail(s: string)
{
	sys->fprint(stderr, "rsa2sshtest: %s\n", s);
	raise "fail:rsa2sshtest";
}

check(name, got, want: string)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

# --- #C host-command device: the winfd=nil pattern established by
# dctest.b/urlencodetest.b (see inferno-rio-cmd-device-oracle) - the
# oracle's stdin needs its write side explicitly dropped to force a
# real EOF, since it's reading a "key ..." line from stdin. ---

cfd: ref FD;

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runoracle(args, stdintext: string): string
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
	if(sys->fprint(cfd, "exec /Users/npe/src/plan9port/bin/rsa2ssh %s", args) < 0)
		fail("cannot exec rsa2ssh: no host command device");

	winfd := sys->open(convdir+"/data", Sys->OWRITE);
	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);

	sin := array of byte stdintext;
	sys->write(winfd, sin, len sin);
	winfd = nil;	# force EOF on the oracle's stdin - see header comment

	outbuf := "";
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		outbuf += string rb[0:rn];
	}
	for(;;){
		rn := sys->read(errcmd, rb, len rb);
		if(rn <= 0)
			break;
		outbuf += string rb[0:rn];
	}
	if(waitfd != nil){
		sb := array[1024] of byte;
		sys->read(waitfd, sb, len sb);
	}
	return outbuf;
}

checkoracle(name, args: string, argv: list of string, keyline: string)
{
	got := rsa2sshmod->run(argv, keyline);
	want := runoracle("-2 "+args, keyline);
	check(name, got, want);
}

# --- test keys ---
# 1024-bit RSA modulus from `openssl genrsa`, verified against openssl
# rsa -text's own decoding of the same key before use here.
KEY1: con "key proto=rsa size=1024 ek=10001 n=935e6d960f371da3477cb677d0b19b7e8aa7c7559c6968031d7eb2a36cc371b59f06715f8e5d025792c846051e42514d1cd1457465bfc725cdc64efd1fbed97b2a4434da83f7c33926f62bee939b93e4dc0517162a0f4c66e18bf0b84ccd58cfc4d96c73f430299ad0541dfc07f34276a81e247c6b44d616b83d64a2a170b0f1\n";

# a second, distinct real 1024-bit modulus (a fresh `ssh-keygen`
# public key's own n/e, extracted the same way) - covers a different
# real bit pattern, in particular one whose top byte does NOT need
# the putmp2() leading-zero rule's OTHER branch exercised by KEY1.
KEY2: con "key proto=rsa size=1024 ek=10001 n=a86236f4ea22b7a6fe2636b61b1bae6a661df7bd80d22f0c456bb30092f18da0820be98ea0422fa7915eaacaeb69ce472dfa1e56d4e30c7dba5737c5856a0a137010c82aa1d271acc00c4c022df6664d3f5d0d2303054702c25fc166d0678d5bbb6ce6d5e92f61d5eaed774a6aa0ce2df391c85f1b794f9bb6e514b39beab59f\n";

t1nocomment()
{
	checkoracle("t1nocomment", "", nil, KEY1);
}

t2comment()
{
	checkoracle("t2comment", "-c hello", list of {"-c", "hello"}, KEY1);
}

t3secondkey()
{
	checkoracle("t3secondkey", "-c k2", list of {"-c", "k2"}, KEY2);
}

t4nonewline()
{
	# same as KEY1 with the trailing newline stripped - convert()
	# tolerates either, since it strips one itself if present. Not a
	# vacuous check: convert()'s strip is CONDITIONAL (only chops a
	# byte that actually is '\n'); an unconditional strip would still
	# pass t1-t3 (which all end in '\n') but wrongly truncate this
	# case's last real hex digit - confirmed with a genuine negative
	# control (an unconditional strip broke exactly this case, none
	# of the others).
	nonl := KEY1[0:len KEY1-1];
	got := rsa2sshmod->run(nil, nonl);
	want := runoracle("-2", KEY1);	# the oracle gets the real file, WITH its newline
	check("t4nonewline", got, want);
}

t5badproto()
{
	got: string;
	ok := 0;
	{
		got = rsa2sshmod->run(nil, "key proto=dsa ek=10001 n=ff\n");
		ok = 1;
	} exception {
	"fail:rsa2ssh" =>
		ok = 0;
	}
	if(ok){
		nfail++;
		sys->fprint(stderr, "FAIL t5badproto\n  want: raise\n  got:  %q\n", got);
	} else
		npass++;
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	rsa2sshmod = load Rsa2ssh Rsa2ssh->PATH;
	if(rsa2sshmod == nil)
		fail("cannot load "+Rsa2ssh->PATH);

	t1nocomment();
	t2comment();
	t3secondkey();
	t4nonewline();
	t5badproto();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:rsa2sshtest";
}
