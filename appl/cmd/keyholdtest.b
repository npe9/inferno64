implement Command;

# Checks keyhold(2), which is one small thing: turning the stream of key
# events a window delivers into the set of actions held down right now.
#
# The interesting half is the release.  include/keyboard.h encodes it as
# Keyup | (key & 0x7ff), and Keyup is Spec|0x800 - so the special-key
# prefix that every arrow and function key already carries makes a naive
# `k & Keyup` say a plain Left arrow is a release.  Two of the checks
# below are about exactly that, because getting it wrong leaves a game
# that walks left for ever the moment you touch an arrow key.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyboard.m";
include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

LEFT, RIGHT, FIRE, MENU: con 1 << iota;

nfail := 0;

ck(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s = %d\n", what, got);
		return;
	}
	sys->print("FAIL %s = %d, want %d\n", what, got, want);
	nfail++;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	if(keyhold == nil){
		sys->print("keyholdtest: cannot load keyhold: %r\n");
		raise "fail:load";
	}
	b := keyhold->mk(array[] of {
		(Keyboard->Left, LEFT), ('a', LEFT),
		(Keyboard->Right, RIGHT), ('d', RIGHT),
		(' ', FIRE), ('x', FIRE),
		('\t', MENU),
	});

	h := 0;
	h = b.key(h, Keyboard->Left);
	ck("an arrow key presses", h, LEFT);
	h = b.key(h, ' ');
	ck("and a second action as well", h, LEFT|FIRE);
	ck("edge is only what is new", keyhold->edge(h, LEFT), FIRE);
	h = b.key(h, Keyboard->Keyup | (Keyboard->Left & 16r7ff));
	ck("the arrow releases", h, FIRE);
	h = b.key(h, Keyboard->Keyup | ' ');
	ck("and so does the space bar", h, 0);

	# A second key on the same action.
	h = b.key(0, 'a');
	ck("a letter works the same action", h, LEFT);
	h = b.key(h, Keyboard->Keyup | 'a');
	ck("and releases it", h, 0);

	# The trap.  A plain arrow key carries Spec, and Keyup is
	# Spec|0x800, so a mask that tests only 0x800 - or that tests
	# `k & Keyup` - calls this a release.
	h = b.key(0, Keyboard->Right);
	ck("a plain arrow is not read as a release", h, RIGHT);
	h = b.key(h, Keyboard->Left);
	ck("and neither is another one", h, RIGHT|LEFT);

	# Tab is a real key and not a shifter.
	h = b.key(0, '\t');
	ck("tab is an ordinary binding", h, MENU);
	h = b.key(h, Keyboard->Keyup | '\t');
	ck("and releases", h, 0);

	# Anything not in the table leaves the set alone rather than
	# clearing it - a game must not lose its held keys because someone
	# leaned on a key it does not use.
	h = b.key(0, Keyboard->Left);
	h = b.key(h, 'q');
	ck("an unbound key changes nothing", h, LEFT);
	h = b.key(h, Keyboard->Keyup | 'q');
	ck("and neither does its release", h, LEFT);

	if(nfail == 0)
		sys->print("keyholdtest: PASSED\n");
	else{
		sys->print("keyholdtest: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}
