#
# The HID boot protocol, which is the small fixed subset of HID that a
# machine's own firmware drives before any driver is loaded: an eight
# byte keyboard report and a three byte mouse report, both with a
# layout that is the same on every device that claims to speak it.
#
# It is here rather than in a program because two transports carry it.
# usbd(1) reads it off an interrupt endpoint; bthid reads it out of a
# GATT characteristic.  Above the transport the reports are identical,
# and a keyboard map with two homes is a keyboard map that will come
# to disagree with itself.
#
Hidboot: module
{
	PATH:	con "/dis/lib/hidboot.dis";

	init:	fn();

	# What a key in an eight byte keyboard report means, given the
	# modifier byte: the text to write to /dev/keyboard, or nil for
	# a key this does not map -- caps lock, the function keys and
	# the arrows, which need more than a character each.
	keysym:	fn(k, mod: int): string;

	# The keys in a report, in order, ignoring the empty slots and
	# the rollover code a keyboard sends when too many are down.
	keysof:	fn(rep: array of byte): array of int;

	# is this key in that set
	held:	fn(keys: array of int, k: int): int;

	# A three byte mouse report: the movement, and the buttons in
	# the order /dev/pointer wants them, which is not the order HID
	# reports them in.
	mouse:	fn(rep: array of byte): (int, int, int);
};
