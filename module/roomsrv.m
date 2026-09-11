Roomsrv: module
{
	PATH:	con "/dis/lib/roomsrv.dis";

	# A room, as spire(1) understands one: four files served over Styx.
	#
	#	name	one line, what the room calls itself
	#	wares	zero or more lines of "KEY PRICE TEXT..."
	#	ctl	written to; "coins N" and "buy KEY"
	#	status	one line, the answer to the last write
	#
	# The point of the arrangement is that the game mounts this and then
	# knows nothing else about the room.  Whatever is behind the door
	# decides what it stocks, what it charges and what it will refuse;
	# the game only spends what the room says it spent.  A room may be
	# a program in this tree, a program somebody else wrote, or a
	# filesystem imported from another machine - the game cannot tell
	# and does not ask.
	#
	# KEY is what the game does about it, and the game knows only a few
	# words: see spire(1).  PRICE is in coins and may be nought.
	#
	# This library is the serving; a room is the policy, and that is
	# usually under a hundred lines.  See spireshop(1).

	init:	fn(): string;

	Room: adt {
		name:	string;
		# A write to ctl arrives here.  Answer with the line status is
		# to hold; a line beginning with "!" is returned to the writer
		# as an error instead, and status keeps what it had.
		ctl:	chan of (string, chan of string);
		# A read of wares arrives here.  Answer with the whole text.
		wares:	chan of chan of string;
		# serve() sends here when the connection has gone, so a room
		# can exit rather than waiting for ever on a visitor who has
		# already left.
		done:	chan of int;
	};

	room:	fn(name: string): ref Room;

	# What a room stocks, kept in a file so that a room's contents are
	# data like everything else here.  The file is a header of
	# "name WORDS..." lines, then a line of %, then one ware a line:
	#
	#	KEY PRICE TEXT...
	#
	# Lines beginning with ; are comments.
	Ware: adt {
		key:	string;
		price:	int;
		text:	string;
		gone:	int;		# already taken this visit
	};

	stock:	fn(path: string): (string, array of ref Ware, string);
	# The wares file's contents: what is left, one line each.
	wares:	fn(w: array of ref Ware): string;
	ware:	fn(w: array of ref Ware, key: string): ref Ware;

	# Run a Dis program as a file server on a pipe and mount what it
	# serves at mntpt.  The program serves Styx on its standard input
	# and output, which is what "mount {prog} dir" and styxlisten(1)
	# already expect, so the same program works down a pipe, over a
	# network, or started by hand from a shell to look at.  The server
	# process ends when mntpt is unmounted and the connection closes.
	#
	# Returns nil, or why not.  Nothing here falls back to anything: a
	# caller that cannot mount has not got the thing, and must say so
	# rather than carrying on with something it had already.
	mountprog:	fn(prog: string, argv: list of string, mntpt: string,
				flags: int): string;

	# Serve r on fd until the far end goes away.  Runs until then, so a
	# caller with anything else to do spawns it.
	serve:	fn(fd: ref Sys->FD, r: ref Room);
};
