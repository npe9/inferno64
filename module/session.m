#
# What a person did to a session, rather than what the hardware reported.
#
# A recording made by INFERNO_INPUT_RECORD (see emu(1)) is key presses and
# releases and pointer states, which reproduces a session exactly and reads
# like nothing at all. This turns it into actions - type this, click there,
# wait - which can be printed, edited, and run.
#
# The actions are shell verbs, so a recording becomes a script, and a script
# stops wherever you stop it. That is the whole mechanism for interrupting a
# replay and taking the machine over: there is no protocol, because a script
# that has stopped is just a shell that has not been given the next line, and
# the system underneath it is live the whole time.
#
Session: module
{
	PATH:	con "/dis/lib/session.dis";

	# a release is Keyup | (key & 16r7ff), from keyboard(2)
	Keyup:	con 16rE800;
	Spec:	con 16rE000;

	Atype, Akey, Aclick, Adouble, Adrag, Amove, Await, Aresize, Apause: con iota;

	Action: adt {
		kind:	int;
		at:	int;		# ms from the start of the session
		text:	string;		# Atype: the characters. Akey: the name.
		x, y:	int;
		x2, y2:	int;		# where a drag ended
		b:	int;		# which button

		script:	fn(a: self ref Action): string;
		play:	fn(a: self ref Action): string;
	};

	init:	fn(): string;

	# decode a recording into actions
	read:	fn(path: string): (array of ref Action, string);

	# one action from the words of a script line, so that a script edited by
	# hand is read by the same code that wrote it
	parse:	fn(words: list of string): (ref Action, string);

	# how long to run a whole recording, in milliseconds
	span:	fn(a: array of ref Action): int;
};
