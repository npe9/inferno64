implement Command;

# sshtest(1) - exercise the ssh(2) Stage 1 transport against a real
# sshd (github.com:22 by default). It proves three things end to end:
#
#  1. the curve25519 key exchange and RSA host-key signature verify -
#     connect() only returns if the server's rsa-sha2-256 signature
#     over the exchange hash checks out;
#  2. the host-key thumbprint we compute equals GitHub's published RSA
#     fingerprint (an independent oracle - `ssh-keyscan -t rsa
#     github.com | ssh-keygen -lf -` yields the same SHA256:... value);
#     connect() is asked to fail closed unless it matches;
#  3. the chacha20-poly1305@openssh.com packet cipher round-trips:
#     after NEWKEYS we send an ENCRYPTED SERVICE_REQUEST and must read
#     back a validly-tagged SERVICE_ACCEPT. That single exchange is
#     what validates the KDF, the cs1/cs2 key split, the per-packet IV,
#     block-1 payload alignment and the padding rule together - none of
#     which the (plaintext) key exchange touches.
#
# The name is resolved through this tree's own DoH resolver (doh(2)),
# since dial-by-name is not wired up in hosted emu.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "encoding.m";
include "asn1.m";
include "pkcs.m";
include "doh.m";
	doh: DOH;
include "ssh.m";
	ssh: Ssh;
	Conn: import ssh;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

# GitHub's published RSA host-key fingerprint (stable, from
# docs.github.com "GitHub's SSH key fingerprints").
GITHUB_RSA_THUMB: con "sha256=uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	host := "github.com";
	want := GITHUB_RSA_THUMB;
	argv = tl argv;
	if(argv != nil){
		host = hd argv;
		want = "";		# a caller-supplied host has no baked oracle
	}

	doh = load DOH DOH->PATH;
	if(doh == nil)
		fail(sys->sprint("load doh: %r"));
	if((e := doh->init()) != nil)
		fail("doh init: " + e);
	ssh = load Ssh Ssh->PATH;
	if(ssh == nil)
		fail(sys->sprint("load ssh: %r"));
	ssh->init();

	# resolve the host's A record through our own DoH resolver
	(ips, derr) := doh->resolve(nil, host);
	if(derr != nil)
		fail("resolve " + host + ": " + derr);
	if(ips == nil)
		fail("resolve " + host + ": no addresses");
	ip := hd ips;
	sys->print("resolved %s -> %s\n", host, ip);

	addr := "tcp!" + ip + "!22";

	# 1+2: key exchange, host-key signature verify, thumbprint match
	(c, cerr) := ssh->connect(addr, host, want);
	if(cerr != nil)
		fail(cerr);
	sys->print("connected; host key %s\n", c.thumb);
	sys->print("KEX + curve25519 + RSA host-key signature: PASS\n");
	if(want != "" && c.thumb == want)
		sys->print("host-key thumbprint matches GitHub oracle: PASS\n");

	# 3: encrypted round trip - SERVICE_REQUEST("ssh-userauth")
	req := servicereq("ssh-userauth");
	if((werr := c.writepkt(req)) != nil)
		fail("writepkt SERVICE_REQUEST: " + werr);

	got := 0;
	for(tries := 0; tries < 8 && !got; tries++){
		(pkt, rerr) := c.readpkt();
		if(rerr != nil)
			fail("readpkt: " + rerr);
		if(len pkt == 0)
			continue;
		t := int pkt[0];
		if(t == Ssh->MSG_SERVICE_ACCEPT)
			got = 1;
		else if(t == Ssh->MSG_IGNORE || t == Ssh->MSG_DEBUG || t == Ssh->MSG_GLOBAL_REQUEST)
			continue;	# transport chatter
		else
			fail(sys->sprint("unexpected reply msg %d", t));
	}
	if(!got)
		fail("no SERVICE_ACCEPT");
	sys->print("encrypted SERVICE_REQUEST -> SERVICE_ACCEPT round trip: PASS\n");
	c.close();

	# negative control: with a deliberately wrong expected thumbprint,
	# connect() must fail closed rather than accept the host key. This
	# is a safe, automated control - a refused connection computes
	# nothing dangerous.
	if(want != ""){
		bad := "sha256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
		(c2, e2) := ssh->connect(addr, host, bad);
		if(e2 == nil){
			c2.close();
			fail("wrong thumbprint was ACCEPTED (fail-open!)");
		}
		sys->print("wrong-thumbprint negative control: refused, as expected: PASS\n");
	}

	sys->print("all tests passed\n");
}

# SERVICE_REQUEST payload: byte(5) || string(name)
servicereq(name: string): array of byte
{
	nb := array of byte name;
	a := array[1 + 4 + len nb] of byte;
	a[0] = byte Ssh->MSG_SERVICE_REQUEST;
	a[1] = byte (len nb >> 24);
	a[2] = byte (len nb >> 16);
	a[3] = byte (len nb >> 8);
	a[4] = byte len nb;
	a[5:] = nb[0:];
	return a;
}

fail(m: string)
{
	sys->fprint(stderr, "sshtest: FAIL: %s\n", m);
	raise "fail:test";
}
