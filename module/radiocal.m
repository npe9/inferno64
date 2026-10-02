#
# The per-radio calibration file, read once and used by more than one
# program.
#
# /lib/radio is attrdb(6) format keyed by the board's own #P/uid, and
# radiocfg(1) applies it at a prompt while an init applies it on a board
# that runs no shell.  Those are two callers and the format deserves one
# reader: the alternative tried first was each of them scanning the file
# itself, which is two sets of bugs in a parser whose whole job is to
# decide what numbers a radio is configured with.
#
# It is NOT attrdb(2), and that is measured rather than preferred.  On
# the stm32f407, with 147456 bytes of Dis pool and a shell in it,
# attrdb(2) found the right entry and then ran out of heap -- from a
# fresh boot as well.  So this is the subset the file actually uses: an
# entry begins in column one, indented lines continue it, "#" starts a
# comment, and pairs are attr=value separated by white space.  One pass,
# one fixed buffer, no lists.  The file stays attrdb(6) and attrdb(2)
# still reads it on a host, which is where it is edited.
#
Radiocal: module
{
	PATH:	con "/dis/lib/radiocal.dis";

	Uid:	con "#P/uid";
	Cal:	con "/lib/radio";

	init:	fn();

	# The board's own serial number, or nil.  An identity a board is
	# told is circular, so this is the microcontroller's: RM0090
	# 39.1, a 96-bit factory serial, as twenty-four hex digits.
	boarduid:	fn(path: string): string;

	# The values of the wanted attributes for the entry whose "uid"
	# is this one.  Returns what it found, how many pairs it could
	# not parse -- reported and not swallowed, because a subset
	# parser that silently ignores what it does not understand is
	# how a calibration file comes to say one thing and mean another
	# -- and an error: nil, "noentry", or something to print.
	lookup:	fn(path, uid: string, want: array of string):
			(array of string, int, string);
};
