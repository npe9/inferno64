Keyhold: module
{
	PATH:	con "/dis/lib/keyhold.dis";

	# Which of a set of named actions are held down right now.
	#
	# This exists because of two facts about Inferno, not about games.
	#
	# The first is that a window gets key RELEASES only if it asked for
	# them: wmclient(2)'s startinput must be given "keyup" as well as
	# "kbd", and wm(1) drops releases on the floor for a client that did
	# not (see Keyupstarted in appl/wm/wm.b).  Without that a program
	# sees only presses and every key sticks down for ever.
	#
	# The second is how a release arrives.  include/keyboard.h encodes
	# it as Keyup | (key & 0x7ff), where Keyup is Spec|0x800 - so a
	# release carries only the low eleven bits of the key, and the
	# special-key prefix that ordinary arrow and function keys already
	# have makes a bare `k & Keyup` match those too.  Getting that test
	# wrong is why wm.b has an iskeyup() rather than a mask.
	#
	# So: a caller gives a table of (key, bit) pairs - as many keys to a
	# bit as it likes - and folds each event into a held set.  Nothing
	# here names the buttons, because what a button means is the
	# caller's business: the same bit is jump in one game and fire in
	# another.

	Binding: adt {
		code:	array of int;	# key, as the kbd channel delivers it
		bit:	array of int;	# what it holds down

		# One event in, the new held set out.  Press or release; a key
		# the table does not mention changes nothing, rather than
		# clearing the set.
		key:	fn(h: self ref Binding, held, k: int): int;
	};

	# binds is (key, bit) pairs.  A bit may appear more than once, which
	# is how a game offers both the arrow keys and wasd for the same
	# action.
	mk:	fn(binds: array of (int, int)): ref Binding;

	# What is held now that was not held then: for the actions that
	# should happen once a press rather than every frame it is down.
	edge:	fn(held, prev: int): int;
};
