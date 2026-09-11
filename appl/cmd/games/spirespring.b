implement Spirespring;

#
# Another room for spire(1), and the reason there are two: nothing in
# the game distinguishes them.  Both are mounted the same way, both
# serve the same four files, and which one is behind a door is decided
# by /lib/tiles/spire.doors, not by any code.
#
# This one sells nothing.  It gives one draught to whoever reaches it
# and is then still until they leave - and "until they leave" needs no
# state, because the room is served by a process that lives exactly as
# long as the visit.  The namespace is the lifetime.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "roomsrv.m";
	roomsrv: Roomsrv;
	Room, Ware: import roomsrv;

Spirespring: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

STOCK:	con "/lib/tiles/spring.stock";

wares: array of ref Ware;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	roomsrv = load Roomsrv Roomsrv->PATH;
	if(roomsrv == nil)
		fail(sys->sprint("cannot load %s: %r", Roomsrv->PATH));
	e := roomsrv->init();
	if(e != nil)
		fail(e);

	path := STOCK;
	if(tl argv != nil)
		path = hd tl argv;
	(name, w, err) := roomsrv->stock(path);
	if(err != nil)
		fail(err);
	wares = w;

	r := roomsrv->room(name);
	spawn roomsrv->serve(sys->fildes(0), r);
	for(;;) alt{
	(cmd, reply) := <-r.ctl =>
		reply <-= docmd(cmd);
	wc := <-r.wares =>
		wc <-= roomsrv->wares(wares);
	<-r.done =>
		# The visitor has gone and the connection with them.  A room
		# lasts exactly as long as the visit, which is why neither of
		# these rooms has to remember anything between visits.
		exit;
	}
}

docmd(cmd: string): string
{
	(n, a) := sys->tokenize(cmd, " \t");
	if(n == 0)
		return "!empty";
	case hd a {
	"coins" =>
		# Taken and ignored.  The spring does not want anything, but
		# the game tells every room what it is carrying and a room
		# that refused the message would look broken.
		return "the spring wants nothing";
	"buy" or "drink" =>
		key := "heart";
		if(n == 2)
			key = hd tl a;
		w := roomsrv->ware(wares, key);
		if(w == nil)
			return "!there is none of that here";
		if(w.gone)
			return "!the spring is still";
		w.gone = 1;
		return sys->sprint("ok %s %d", w.key, w.price);
	}
	return "!no such instruction: " + hd a;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "spirespring: %s\n", s);
	raise "fail:error";
}
