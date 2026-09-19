implement Mkradiokeys;

#
# Make a signer and two certified identities under it, in the Keyring
# format keyring->auth() reads.  Run on a host, never on the board: a
# satellite has no business holding a signer key, and generating one on
# a Cortex-M4 would be generating it somewhere it cannot be kept.
#
#	mkradiokeys dir signer user1 user2 ...
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "ipints.m";
include "keyring.m";
	kr: Keyring;

Mkradiokeys: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Bits:	con 1024;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->print("mkradiokeys: load %s: %r\n", Keyring->PATH);
		return;
	}

	argv = tl argv;
	if(argv == nil || tl argv == nil){
		sys->print("usage: mkradiokeys dir signer user ...\n");
		return;
	}
	dir := hd argv;
	argv = tl argv;
	signer := hd argv;
	argv = tl argv;

	si := ref Keyring->Authinfo;
	si.mysk = kr->genSK("rsa", signer, Bits);
	if(si.mysk == nil){
		sys->print("mkradiokeys: genSK failed\n");
		return;
	}
	si.mypk = kr->sktopk(si.mysk);
	si.spk = si.mypk;
	buf := array of byte kr->pktostr(si.mypk);
	st := kr->sha1(buf, len buf, nil, nil);
	si.cert = kr->sign(si.mysk, 0, st, "sha1");
	(si.alpha, si.p) = kr->dhparams(Bits);
	if(kr->writeauthinfo(dir + "/" + signer, si) < 0){
		sys->print("mkradiokeys: write signer: %r\n");
		return;
	}
	sys->print("signer %s\n", signer);

	for(; argv != nil; argv = tl argv){
		u := hd argv;
		info := ref Keyring->Authinfo;
		info.alpha = si.alpha;
		info.p = si.p;
		info.mysk = kr->genSKfromPK(si.spk, u);
		info.mypk = kr->sktopk(info.mysk);
		info.spk = si.mypk;
		b := array of byte kr->pktostr(info.mypk);
		s := kr->sha1(b, len b, nil, nil);
		info.cert = kr->sign(si.mysk, 0, s, "sha1");
		if(kr->writeauthinfo(dir + "/" + u, info) < 0){
			sys->print("mkradiokeys: write %s: %r\n", u);
			return;
		}
		sys->print("user %s\n", u);
	}
	sys->print("MKRADIOKEYS-OK\n");
}
