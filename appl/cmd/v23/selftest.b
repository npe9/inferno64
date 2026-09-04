# Exercise Vanadium security: BlessSelf, Bless, verify, patterns, encode/decode.
implement Selftest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";

include "v23.m";
	v23: V23security;
	Principal, Blessings, Caveat: import v23;

Selftest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	v23 = load V23security V23security->PATH;
	if(v23 == nil)
		fail(sys->sprint("load v23security: %r"));
	if((e := v23->init()) != nil)
		fail(e);

	(alice, err) := v23->createprincipal(256, "alice");
	if(alice == nil)
		fail("alice: "+err);
	(bob, err2) := v23->createprincipal(256, "bob");
	if(bob == nil)
		fail("bob: "+err2);

	(ab, err3) := alice.blessself("alice", v23->unconstrained() :: nil);
	if(ab == nil)
		fail("blessself: "+err3);
	alice.setdefault(ab);
	alice.addroot(ab);

	names := v23->blessingnames(ab);
	if(names == nil || hd names != "alice")
		fail("expected blessing name alice");

	(bb, err4) := alice.bless(bob.publickey(), ab, "friend", v23->unconstrained() :: nil);
	if(bb == nil)
		fail("bless: "+err4);
	bob.setdefault(bb);
	bob.addroot(ab);	# trust alice as root

	bn := v23->blessingnames(bb);
	if(bn == nil || hd bn != "alice:friend")
		fail("expected alice:friend, got "+hd bn);

	(ok, bad) := v23->verifyblessings(bob, bb);
	if(ok == nil)
		fail("verify failed: "+hd bad);
	if(hd ok != "alice:friend")
		fail("verify name "+hd ok);

	enc := v23->encodeblessings(bb);
	(db, err5) := v23->decodeblessings(enc);
	if(db == nil)
		fail("decode: "+err5);
	if(v23->encodeblessings(db) != enc)
		fail("encode not stable");
	(ok2, bad2) := v23->verifyblessings(bob, db);
	if(ok2 == nil)
		fail("verify decoded: "+hd bad2);

	if(!v23->pattern_match("alice", "alice:friend" :: nil))
		fail("pattern alice should match alice:friend");
	if(v23->pattern_match("alice:"+v23->NoExtension, "alice:friend" :: nil))
		fail("alice:$ should not match alice:friend");
	if(!v23->pattern_match(v23->AllPrincipals, "x" :: nil))
		fail("... should match");

	# expiry caveat
	past := v23->expiry(1);	# long ago
	(eb, err6) := alice.blessself("expired", past :: nil);
	if(eb == nil)
		fail("expired blessself: "+err6);
	alice.addroot(eb);
	(ok3, bad3) := v23->verifyblessings(alice, eb);
	if(ok3 != nil)
		fail("expired blessing should be rejected");
	if(bad3 == nil)
		fail("expected rejection reason");

	sys->print("v23 selftest: ok\n");
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "v23/selftest: %s\n", s);
	raise "fail:"+s;
}
