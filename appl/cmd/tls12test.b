implement Command;

# tls12test(1) - live end-to-end test of tls12(2)'s TLS 1.2 client:
# full handshake (ClientHello through both Finished messages) plus real
# encrypted application data against the two real hosts
# doc/ssl-modernization-plan.md measured its scope from, one per AEAD:
#
#   1. bsky.social:     offer both suites -> server picks AES-128-GCM
#   2. mastodon.social: offer ChaCha20-Poly1305 only -> exercises the
#      other record-protection path (mastodon prefers GCM when both are
#      offered, checked live 2026-09-02, so the narrowing is what makes
#      this leg reach the ChaCha code at all)
#
# each leg sends a real HTTP/1.1 GET over the established session and
# requires a decrypted response starting "HTTP/1." back.
#
# Negative controls (in-test, per this repo's evidence discipline):
#
#   3. corrupt the receive sequence number before reading -> record
#      authentication MUST fail (the AAD covers the sequence number;
#      if reads still succeed, the tag check is not actually wired to
#      the AAD and the test must fail)
#   4. corrupt the send sequence number before writing -> the server
#      MUST refuse the request (bad_record_mac alert or a dead
#      connection; a normal HTTP response back means record
#      authentication is not actually protecting writes)
#
# What a PASS does NOT establish (doc/ssl-modernization-plan.md's open
# gap): the server's certificate chain is not verified and the
# ServerKeyExchange signature is not checked, so a passing handshake
# proves a working, encrypted session - NOT an authenticated one.

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;
include "keyring.m";
include "security.m";
include "tls12.m";
	tls12: TLS12;
	Session: import tls12;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
failures := 0;

# real IPs looked up once outside emu - /net/cs does not resolve names
# in this emu instance (dialtest(1)'s tracked gap)
BSKYIP: con "3.226.75.19";
MASTOIP: con "151.101.1.55";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	tls12 = load TLS12 TLS12->PATH;
	stderr = sys->fildes(2);
	if(dial == nil || tls12 == nil){
		sys->fprint(stderr, "tls12test: cannot load support modules\n");
		raise "fail:load";
	}
	if((err := tls12->init()) != nil){
		sys->fprint(stderr, "tls12test: %s\n", err);
		raise "fail:init";
	}

	# 1: AES-128-GCM path against bsky.social
	(s, herr) := connect(BSKYIP, "bsky.social", nil);
	if(herr != nil)
		fail(sys->sprint("bsky handshake: %s", herr));
	else{
		if(s.cipher != TLS12->CS_ECDHE_RSA_AES128_GCM_SHA256)
			fail(sys->sprint("bsky negotiated cipher %04x, expected %04x",
				s.cipher, TLS12->CS_ECDHE_RSA_AES128_GCM_SHA256));
		if(len s.certs < 1)
			fail("bsky sent no certificates");
		resp := httpget(s, "bsky.social");
		if(resp == nil)
			fail(sys->sprint("bsky GET over the session failed: %s", s.err));
		else
			sys->print("bsky.social: cipher %04x, %d certs (unverified), %d byte response: PASS\n",
				s.cipher, len s.certs, len resp);
	}

	# 2: ChaCha20-Poly1305 path against mastodon.social
	(s2, herr2) := connect(MASTOIP, "mastodon.social",
		TLS12->CS_ECDHE_RSA_CHACHA20_POLY1305 :: nil);
	if(herr2 != nil)
		fail(sys->sprint("mastodon handshake: %s", herr2));
	else{
		if(s2.cipher != TLS12->CS_ECDHE_RSA_CHACHA20_POLY1305)
			fail(sys->sprint("mastodon negotiated cipher %04x, expected %04x",
				s2.cipher, TLS12->CS_ECDHE_RSA_CHACHA20_POLY1305));
		resp := httpget(s2, "mastodon.social");
		if(resp == nil)
			fail(sys->sprint("mastodon GET over the session failed: %s", s2.err));
		else
			sys->print("mastodon.social: cipher %04x, %d byte response: PASS\n",
				s2.cipher, len resp);
	}

	# 3: negative control, read side - a corrupted receive sequence
	# number must make record authentication fail
	(s3, herr3) := connect(BSKYIP, "bsky.social", nil);
	if(herr3 != nil)
		fail(sys->sprint("negative-control handshake: %s", herr3));
	else{
		req := array of byte request("bsky.social");
		if(s3.write(req, len req) != len req)
			fail(sys->sprint("negative-control write: %s", s3.err));
		else{
			s3.rseq++;	# desynchronize the AAD
			buf := array[512] of byte;
			n := s3.read(buf, len buf);
			if(n >= 0)
				fail(sys->sprint("read with corrupted rseq SUCCEEDED (%d bytes) - tag check not tied to AAD", n));
			else
				sys->print("corrupted rseq: read refused (%s): PASS\n", s3.err);
		}
	}

	# 4: negative control, write side - a corrupted send sequence
	# number must make the server refuse the request
	(s4, herr4) := connect(BSKYIP, "bsky.social", nil);
	if(herr4 != nil)
		fail(sys->sprint("negative-control handshake: %s", herr4));
	else{
		s4.wseq++;	# desynchronize the AAD the server will check
		resp := httpget(s4, "bsky.social");
		if(resp != nil)
			fail("server ACCEPTED a record with a corrupted wseq - its mac check saw nothing wrong");
		else
			sys->print("corrupted wseq: server refused the request (%s): PASS\n", s4.err);
	}

	if(failures){
		sys->fprint(stderr, "tls12test: %d FAILURE(S)\n", failures);
		raise "fail:test";
	}
	sys->print("all tests passed (handshake + record layer only - certificate chain NOT verified)\n");
}

connect(ip, hostname: string, suites: list of int): (ref TLS12->Session, string)
{
	c := dial->dial("tcp!"+ip+"!443", nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", ip));
	return tls12->client(c.dfd, hostname, suites);
}

request(host: string): string
{
	return "GET / HTTP/1.1\r\nHost: "+host+"\r\nUser-Agent: inferno-tls12test\r\nConnection: close\r\n\r\n";
}

# send a GET, read the response until EOF/error; returns nil unless a
# plausible decrypted HTTP response came back
httpget(s: ref TLS12->Session, host: string): array of byte
{
	req := array of byte request(host);
	if(s.write(req, len req) != len req)
		return nil;
	resp: array of byte;
	buf := array[8192] of byte;
	while((n := s.read(buf, len buf)) > 0){
		nr := array[len resp + n] of byte;
		nr[0:] = resp;
		nr[len resp:] = buf[0:n];
		resp = nr;
		if(len resp >= 64*1024)
			break;	# plenty to judge by; don't slurp a whole page
	}
	if(len resp < 12)
		return nil;
	if(string resp[0:7] != "HTTP/1.")
		return nil;
	return resp;
}

fail(msg: string)
{
	sys->fprint(stderr, "FAIL: %s\n", msg);
	failures++;
}
