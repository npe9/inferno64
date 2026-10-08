implement Init;

#
# DOES keyring->auth() FIT ON THIS PART?
#
# doc/radio-plan.ms step 5's identity half wants auth over the radio
# link, and authchk(1) says where to start: "If it does not fit over a
# pipe it will not fit over a radio, and the radio would have been the
# expensive way to find out."  That pipe test has only ever been run on
# an mps2-an386.  This part has about 118K of main pool and auth is a
# Diffie-Hellman exchange and a signature check over 1024-bit numbers,
# so the question is real and it is not about the radio at all.
#
# An init rather than a shell command because the shell image cannot
# hold $Keyring: declaring the module costs 197K of flash and that image
# is already within 6K of the limit.  This one carries authchk, the two
# Authinfos and nothing else.
#
# It runs under qemu, which is the point -- a kernel that cannot do this
# should not cost two flashes and a walk to the bench to find out.
#

include "sys.m";
include "draw.m";

Init: module
{
	init:	fn();
};

Command: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

sys: Sys;

init()
{
	sys = load Sys Sys->PATH;
	sys->print("armv7m auth init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	# THE POOLS BEFORE AND AFTER, because the answer is as much about
	# what is left as about whether it completed.  A run that finishes
	# having taken the pool to its ceiling has not shown that a
	# station can also serve Styx afterwards.
	pools("before");

	c := load Command "/dis/authchk.dis";
	if(c == nil){
		sys->print("auth: load /dis/authchk.dis: %r\n");
		sys->print("ARMV7M-AUTH-NOCMD\n");
		return;
	}
	sys->print("ARMV7M-AUTH-RUNNING\n");
	c->init(nil, "authchk" :: nil);
	pools("after");
	sys->print("ARMV7M-AUTH-DONE\n");
}

pools(when: string)
{
	fd := sys->open("#c/memory", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return;
	for(l := sys->tokenize(string b[0:n], "\n").t1; l != nil; l = tl l)
		sys->print("auth: %s pool %s\n", when, hd l);
}
