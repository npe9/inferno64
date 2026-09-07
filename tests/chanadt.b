implement Chanadt;

#
# A buffered channel whose size comes out of an adt reached through a
# ref.  That is the middle operand of newc*, which cannot be an
# indirect addressing mode; the compiler used to emit one and die in
# resolvepcs with "can't deal with ...'s m mode".  Every kind of
# channel is made here, because the width is chosen per element type
# and only some of them go through the same instruction.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Chanadt: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

Pt: adt {
	x:	int;
	y:	int;
};

Ctlr: adt {
	n:	int;
	m:	big;
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	x := ref Ctlr(3, big 2);

	ci := chan[x.n] of int;
	cb := chan[x.n] of byte;
	cr := chan[x.n] of real;
	cs := chan[x.n] of string;
	ca := chan[x.n] of array of byte;
	ct := chan[x.n] of (int, string);
	cp := chan[x.n] of Pt;
	cl := chan[x.n] of list of int;

	# through a big field as well: the size is an int expression
	# either way, and the cast is where a second indirect operand
	# could hide
	cw := chan[int x.m] of int;

	for(i := 0; i < x.n; i++){
		ci <-= i;
		cb <-= byte i;
		cr <-= real i;
		cs <-= string i;
		ca <-= array[1] of byte;
		ct <-= (i, "t");
		cp <-= Pt(i, i);
		cl <-= i :: nil;
	}
	for(i = 0; i < int x.m; i++)
		cw <-= i;

	ok := 1;
	for(i = 0; i < x.n; i++){
		if(<-ci != i)
			ok = 0;
		if(int <-cb != i)
			ok = 0;
		if(<-cr != real i)
			ok = 0;
		if(<-cs != string i)
			ok = 0;
		if(len <-ca != 1)
			ok = 0;
		(ti, ts) := <-ct;
		if(ti != i || ts != "t")
			ok = 0;
		p := <-cp;
		if(p.x != i || p.y != i)
			ok = 0;
		if(hd <-cl != i)
			ok = 0;
	}
	for(i = 0; i < int x.m; i++)
		if(<-cw != i)
			ok = 0;

	if(ok)
		sys->print("chanadt: ok\n");
	else
		sys->print("chanadt: FAILED\n");
}
