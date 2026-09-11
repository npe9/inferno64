implement Spireshop;

#
# A room for spire(1): a market on a ledge, which sells things for the
# coins picked up on the climb.
#
# This is a whole room.  It is this short because roomsrv(2) does the
# serving and this file is only what the market stocks and what it will
# refuse - and even the stock is not here, it is /lib/tiles/shop.stock.
# Writing another room means writing another one of these; the game does
# not change and does not know which of them it has mounted.
#
# It is served on standard input and output, so it can be started by
# spire(1) down a pipe, or by styxlisten(1) over a network, or by hand
# from a shell to look at what it serves.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "roomsrv.m";
	roomsrv: Roomsrv;
	Room, Ware: import roomsrv;

Spireshop: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

STOCK:	con "/lib/tiles/shop.stock";

wares: array of ref Ware;
coins: int;

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
	# Read the stock before anything else: a server usually drops its
	# namespace once it is serving, and then this file is not there.
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
		# The game says what the climber is carrying.  The market
		# takes its word for it: it has no way to check, and a room
		# that could be lied to about money is a room, not a bank.
		if(n != 2)
			return "!coins wants a number";
		coins = int hd tl a;
		return sys->sprint("coins %d", coins);
	"buy" =>
		if(n != 2)
			return "!buy wants a ware";
		w := roomsrv->ware(wares, hd tl a);
		if(w == nil)
			return "!nothing of that name here";
		if(w.gone)
			return "!that one is gone";
		if(coins < w.price)
			return sys->sprint("!that is %d coin and you have %d", w.price, coins);
		w.gone = 1;
		coins -= w.price;
		return sys->sprint("ok %s %d", w.key, w.price);
	}
	return "!no such instruction: " + hd a;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "spireshop: %s\n", s);
	raise "fail:error";
}
