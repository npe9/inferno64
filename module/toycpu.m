Toycpu: module
{
	PATH: con "/dis/lib/toycpu.dis";

	Mem: con 100;	# 100 mailboxes, 000..999 each - Bucky's Wristwatch/Rock
			# Bottom territory: how few instructions does something
			# still recognisable as a *computer* actually need?

	Machine: adt {
		mem:		array of int;	# Mem mailboxes, each 0..999
		acc:		int;		# accumulator, 0..999
		negflag:	int;		# set when the last SUB went negative
		pc:		int;		# program counter, 0..Mem-1
		halted:		int;
		inq:		list of int;	# values queued for the next INP
		outq:		list of int;	# values OUT has produced, oldest first
	};

	init:		fn();
	assemble:	fn(src: string): (array of int, string);
	newmachine:	fn(mem: array of int): ref Machine;
	step:		fn(m: ref Machine): string;
	input:		fn(m: ref Machine, v: int);
};
