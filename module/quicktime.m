#
# Apple QuickTime File Format
#
QuickTime: module
{
	PATH:	con "/dis/lib/quicktime.dis";

	DEFBUF:		con 8192;

	AtomHDR:	con 8;

	Tkhdr: adt
	{
		version:	int;
		creation:	int;
		modtime:	int;
		trackid:	int;
		timescale:	int;
		duration:	int;
		timeoff:	int;
		priority:	int;
		layer:		int;
		altgrp:		int;
		volume:		int;
		matrix:		array of int;
		width:		int;
		height:		int;
	};

	MvhdrSIZE:	con 100;
	Mvhdr: adt
	{
		version:	int;
		create:		int;
		modtime:	int;
		timescale:	int;
		duration:	int;
		rate:		int;
		vol:		int;
		r1:		int;
		r2:		int;
		matrix:		array of int;
		r3:		int;
		r4:		int;
		pvtime:		int;
		posttime:	int;
		seltime:	int;
		seldurat:	int;
		curtime:	int;
		nxttkid:	int;
	};

	# QuickTime descriptor
	QD: adt
	{
		fd:	ref sys->FD;		# descriptor of QuickTime file
		buf:	array of byte;		# buffer
		nbyte:	int;			# bytes remaining
		ptr:	int;			# buffer pointer

		mvhdr:	ref Mvhdr;		# movie header desctiptor

		readn:		fn(r: self ref QD, b: array of byte, l: int): int;
		skip:		fn(r: self ref QD, size: int): int;
		skipatom:	fn(r: self ref QD, size: int): int;
		atomhdr:	fn(r: self ref QD): (string, int);
		mvhd:		fn(r: self ref QD, l: int): string;
		trak:		fn(r: self ref QD, l: int): string;
	};

	# One coded sample: where it is in the file, how big, how long it
	# lasts, and whether it can be decoded without what came before.
	Sample: adt
	{
		off:	big;		# file offset
		size:	int;		# bytes
		delta:	int;		# duration, in the track's timescale
		# Composition offset: presentation time is decode time plus
		# this. Non-zero only when the stream has frames coded out of
		# display order - B-frames - in which case samples arrive in
		# decode order and a player must reorder by presentation time.
		coff:	int;
		sync:	int;		# non-zero if a sync (key) sample
	};

	Track: adt
	{
		id:		int;
		kind:		string;	# "vide", "soun", ...
		codec:		string;	# "avc1", "mp4a", ...
		timescale:	int;	# units per second
		width:		int;	# vide only
		height:		int;
		chans:		int;	# soun only: channel count
		rate:		int;	# soun only: sample rate in Hz
		# Codec setup, verbatim: the avcC payload for avc1, which is
		# what a hardware decoder needs to be configured before it can
		# be given any sample.
		extra:		array of byte;
		samples:	array of Sample;
	};

	init:	fn();
	open:	fn(file: string): (ref QD, string);

	# Sample tables, which the QD reader above does not have: it parses
	# movie and track headers only. This walks the file by seeking, since
	# the tables live in moov while the samples they point at are in mdat,
	# and returns everything needed to feed a decoder a frame at a time.
	tracks:	fn(file: string): (array of ref Track, string);
};
