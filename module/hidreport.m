#
# HID report descriptors: the thing a device sends when it will not do
# the boot protocol, saying where in its reports each field is.
#
# It is here rather than in a program for the same reason hidboot(2)
# is: usbd(1) and bthid both meet devices that speak only the report
# protocol, the descriptor is the same in both, and one parser with
# two homes is a parser that will come to disagree with itself.
#
# What this does is walk the descriptor and say, for every input
# report, what fields it holds and where.  What it does not do is
# decide what a device is for; that is the caller's, and kbd() and
# ptr() below are the two answers this stack needs.
#
Hidreport: module
{
	PATH:	con "/dis/lib/hidreport.dis";

	# usage pages, of the ones that matter here
	Pgeneric:	con 16r01;	# generic desktop
	Pkeyboard:	con 16r07;
	Pbutton:	con 16r09;

	# generic desktop usages
	Upointer:	con 16r01;
	Umouse:		con 16r02;
	Ukeyboard:	con 16r06;
	Ux:		con 16r30;
	Uy:		con 16r31;
	Uwheel:		con 16r38;

	# what a Main item is
	Input, Output, Feature: con iota;

	# the bits of an Input item's data that this cares about
	Fconst:		con 1<<0;	# padding, not data
	Fvar:		con 1<<1;	# one usage each, not an array
	Frel:		con 1<<2;	# a change, not a position

	#
	# One field of one report: a run of count items, each size bits
	# wide, starting off bits into the report's data.  The offset
	# does not count a report id: over GATT the id is in the Report
	# Reference descriptor and not in the value, and over USB the
	# caller strips it, so the data is what is left either way.
	#
	Field: adt {
		page:	int;	# usage page
		usage:	int;	# the usage, for a variable field
		umin:	int;	# for an array, the range it selects from
		umax:	int;
		lmin:	int;	# logical minimum, which says the signedness
		lmax:	int;
		off:	int;	# bit offset into the report's data
		size:	int;	# bits per item
		count:	int;
		flags:	int;

		# the nth item of this field, sign extended when the
		# logical minimum is negative
		val:	fn(f: self ref Field, rep: array of byte, n: int): int;
	};

	#
	# One report: everything the descriptor said goes in the report
	# with this id, in the order it said it.
	#
	Report: adt {
		id:	int;	# 0 when the device uses no report ids
		kind:	int;	# Input, Output or Feature
		bits:	int;	# how long the data is
		app:	int;	# the application collection's usage,
				# page in the top 16 bits, or 0
		fields:	list of ref Field;

		# the field carrying that usage on that page, or nil
		find:	fn(r: self ref Report, page, usage: int): ref Field;
	};

	init:	fn();

	# Walk a report descriptor.  The reports come back in the order
	# the descriptor declared them; the string is an error, and then
	# the list is what was understood before it.
	parse:	fn(d: array of byte): (list of ref Report, string);

	# The one with that id and kind, or nil.
	report:	fn(rl: list of ref Report, id, kind: int): ref Report;

	#
	# Does this input report look like a keyboard, and if so, read
	# it: the modifier byte in the order the boot protocol uses it,
	# and the key codes that are down.  A keyboard is an array field
	# on the keyboard page; the modifiers are the variable field on
	# the same page covering the eight usages E0 to E7.
	#
	kbd:	fn(r: ref Report): int;
	keys:	fn(r: ref Report, rep: array of byte): (int, array of int);

	#
	# And a pointer: X and Y on the generic desktop page.  The
	# movement, then the buttons in the order /dev/pointer wants
	# them -- which is not the order HID reports them in -- and then
	# the wheel, which is 0 on a device that has none.  The first
	# three are what hidboot(2)'s mouse() returns, in that order, so
	# a caller that already handles the boot protocol handles this.
	#
	ptr:	fn(r: ref Report): int;
	mouse:	fn(r: ref Report, rep: array of byte): (int, int, int, int);
};
