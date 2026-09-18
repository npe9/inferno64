implement Modchk;

#
# Every builtin module a kernel carries, loaded and made to answer.
#
# A builtin module's exported functions are found by name: libinterp/
# link.c's linkm() walks the Link array that builtinmod() built from the
# module's Runtab and does a strcmp against the name the loading module
# asked for.  Since those names stopped being copied into the pool and
# are read where the Runtab holds them, that comparison reads kernel
# text rather than a pool block -- so it is worth a check that does not
# just load the module but calls through it and gets a known answer
# back.
#
# fptest already covers $Math and every Dis program covers $Sys.  This
# is for $Keyring, $Crypt and $IPints, which nothing else on a small
# board loads, and $IPints in particular: it is registered from both
# Keyring and Crypt and the guard that keeps that to one registration
# has no other test.
#
# A module a kernel is not configured with is reported absent and
# counted apart, because a check that could not run must not look like
# one that passed.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "keyring.m";
	keyring: Keyring;
include "crypt.m";
	crypt: Crypt;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;

Modchk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

nrun, nfail, nabsent: int;

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

ck(mod, what, want, got: string)
{
	nrun++;
	if(want == got)
		sys->print("%s %s ok\n", mod, what);
	else{
		nfail++;
		sys->print("%s %s FAIL want %s got %s\n", mod, what, want, got);
	}
}

absent(mod: string)
{
	nabsent++;
	sys->print("%s absent, not configured in this kernel\n", mod);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	abc := array of byte "abc";

	math = load Math Math->PATH;
	if(math == nil)
		absent("$Math");
	else{
		ck("$Math", "sqrt(9)", "3", sys->sprint("%g", math->sqrt(9.0)));
		ck("$Math", "pow(2,10)", "1024", sys->sprint("%g", math->pow(2.0, 10.0)));
	}

	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		absent("$Keyring");
	else{
		d := array[Keyring->SHA1dlen] of byte;
		keyring->sha1(abc, len abc, d, nil);
		ck("$Keyring", "sha1(abc)",
			"a9993e364706816aba3e25717850c26c9cd0d89d", hex(d));
		m := array[Keyring->MD5dlen] of byte;
		keyring->md5(abc, len abc, m, nil);
		ck("$Keyring", "md5(abc)",
			"900150983cd24fb0d6963f7d28e17f72", hex(m));
	}

	crypt = load Crypt Crypt->PATH;
	if(crypt == nil)
		absent("$Crypt");
	else{
		d := array[Crypt->SHA256dlen] of byte;
		crypt->sha256(abc, len abc, d, nil);
		ck("$Crypt", "sha256(abc)",
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			hex(d));
	}

	# Loaded last on purpose: Keyring and Crypt each register $IPints
	# on the way up, so by now it has been asked for twice.
	ipints = load IPints IPints->PATH;
	if(ipints == nil)
		absent("$IPints");
	else{
		i := IPint.strtoip("123456789", 10);
		ck("$IPints", "strtoip(123456789)", "123456789",
			sys->sprint("%d", i.iptoint()));
		b := IPint.inttoip(2);
		e := IPint.inttoip(10);
		m := IPint.inttoip(1000);
		ck("$IPints", "2^10 mod 1000", "24",
			sys->sprint("%d", b.expmod(e, m).iptoint()));
	}

	sys->print("%d checks, %d failed, %d modules absent\n",
		nrun, nfail, nabsent);
	if(nfail == 0 && nrun > 0)
		sys->print("MODCHK-OK\n");
}
