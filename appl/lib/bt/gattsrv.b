implement Gattsrv;

#
# The GATT server: the same database gatt.b discovers, read the other
# way round.  gatt.b walks a peer's attributes and turns them into
# files; this takes attributes out of a table and answers a peer that
# has connected to us and is walking ours.
#
# A GATT database is a flat list of attributes in handle order and
# nothing else.  The structure everyone talks about -- services
# holding characteristics holding descriptors -- is a convention about
# what the attributes contain and where the boundaries fall: a service
# runs from its declaration to the handle before the next declaration,
# and a characteristic's value is the attribute after its declaration.
# So there is one table here and the shape is computed from it, rather
# than a tree that the table has to be kept in step with.
#
# Handles are given out in the order attributes are added and never
# given out again.  A peer caches them, so a database that grew under
# a connected peer would be a database that peer had a stale picture
# of -- which is what Service Changed exists for, and there is none
# here yet.  Adding to a database with a link on it is refused.
#
# On 9front this is one C file with the same table and the same switch.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	l2cap: L2cap;
	Mux: import L2cap;

# ATT, server side
Rerror:		con 16r01;
Rmtureq:	con 16r02;
Rmturesp:	con 16r03;
Rfindinfo:	con 16r04;
Rfindinforesp:	con 16r05;
Rreadtype:	con 16r08;
Rreadtyperesp:	con 16r09;
Rread:		con 16r0a;
Rreadresp:	con 16r0b;
Rreadblob:	con 16r0c;
Rreadblobresp:	con 16r0d;
Rreadgroup:	con 16r10;
Rreadgroupresp:	con 16r11;

# the errors this side can raise
Einvalidhandle:	con 16r01;
Ereadnotperm:	con 16r02;
Ewritenotperm:	con 16r03;
Enotsupported:	con 16r06;
Einvalidoffset:	con 16r07;
Enotfound:	con 16r0a;

Uprimary:	con 16r2800;
Uchar:		con 16r2803;

Defmtu:	con 23;
Maxmtu:	con 247;

init(b: Bt, l2: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	l2cap = l2;
	return nil;
}

newdb(): ref Db
{
	d := ref Db;
	d.attrs = nil;
	d.n = 0;
	d.lock = chan[1] of int;
	d.lock <-= 1;
	return d;
}

# with the lock held: append in handle order
add(d: ref Db, a: ref Attr): int
{
	a.handle = ++d.n;
	l: list of ref Attr;
	for(al := d.attrs; al != nil; al = tl al)
		l = hd al :: l;
	l = a :: l;
	d.attrs = nil;
	for(; l != nil; l = tl l)
		d.attrs = hd l :: d.attrs;
	return a.handle;
}

uuid16(v: int): array of byte
{
	a := array[2] of byte;
	bt->put16(a, 0, v);
	return a;
}

addsvc(d: ref Db, uuid: array of byte): (int, string)
{
	if(len uuid != 2 && len uuid != 16)
		return (0, "a UUID is two bytes or sixteen");
	<-d.lock;
	h := add(d, ref Attr(0, uuid16(Uprimary), uuid, 1, 0));
	d.lock <-= 1;
	return (h, nil);
}

#
# A characteristic is two attributes: the declaration, which says what
# may be done with it and where its value is, and the value itself.
# The declaration's value has the value handle in it, so the two have
# to be added together or the handle in the first would be a guess.
#
addchar(d: ref Db, uuid: array of byte, props: int, val: array of byte): (int, int, string)
{
	if(len uuid != 2 && len uuid != 16)
		return (0, 0, "a UUID is two bytes or sixteen");
	<-d.lock;
	if(d.attrs == nil){
		d.lock <-= 1;
		return (0, 0, "no service to put it in");
	}
	dh := d.n + 1;
	vh := d.n + 2;
	dec := array[3 + len uuid] of byte;
	dec[0] = byte props;
	bt->put16(dec, 1, vh);
	dec[3:] = uuid;
	add(d, ref Attr(0, uuid16(Uchar), dec, 1, 0));
	rd := (props & 16r02) != 0;			# read
	wr := (props & (16r04|16r08)) != 0;		# write, with or without response
	add(d, ref Attr(0, uuid, val, rd, wr));
	d.lock <-= 1;
	return (dh, vh, nil);
}

find(d: ref Db, h: int): ref Attr
{
	for(l := d.attrs; l != nil; l = tl l)
		if((hd l).handle == h)
			return hd l;
	return nil;
}

setval(d: ref Db, h: int, v: array of byte): string
{
	<-d.lock;
	a := find(d, h);
	if(a != nil)
		a.val = v;
	d.lock <-= 1;
	if(a == nil)
		return sys->sprint("no attribute at handle %#4.4ux", h);
	return nil;
}

getval(d: ref Db, h: int): array of byte
{
	<-d.lock;
	a := find(d, h);
	v: array of byte;
	if(a != nil)
		v = a.val;
	d.lock <-= 1;
	return v;
}

#
# A service runs to the handle before the next service declaration, or
# to the end of the database.  Computed rather than stored: one table
# cannot fall out of step with itself.
#
groupend(d: ref Db, h: int): int
{
	last := h;
	seen := 0;
	for(l := d.attrs; l != nil; l = tl l){
		a := hd l;
		if(a.handle == h){
			seen = 1;
			continue;
		}
		if(!seen)
			continue;
		if(len a.uuid == 2 && bt->get16(a.uuid, 0) == Uprimary)
			break;
		last = a.handle;
	}
	return last;
}

sameuuid(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

serve(d: ref Db, m: ref Mux)
{
	spawn server(d, m);
}

server(d: ref Db, m: ref Mux)
{
	rq := l2cap->open(m, L2cap->Cattr);
	mtu := Defmtu;
	for(;;){
		p := <-rq;
		if(p == nil)
			return;
		if(len p < 1)
			continue;
		(r, nmtu) := request(d, mtu, p);
		mtu = nmtu;
		if(r != nil)
			l2cap->send(m, L2cap->Cattr, r);
	}
}

err(op, h, e: int): array of byte
{
	r := array[5] of byte;
	r[0] = byte Rerror;
	r[1] = byte op;
	bt->put16(r, 2, h);
	r[4] = byte e;
	return r;
}

#
# One request, one answer.  Everything not answered here is answered
# with Request Not Supported, which is what the specification says a
# server does and what a client can act on -- as against silence,
# which a client can only time out on.
#
request(d: ref Db, mtu: int, p: array of byte): (array of byte, int)
{
	op := int p[0];
	case op {
	Rmtureq =>
		if(len p < 3)
			return (err(op, 0, Einvalidhandle), mtu);
		peer := bt->get16(p, 1);
		mine := Maxmtu;
		r := array[3] of byte;
		r[0] = byte Rmturesp;
		bt->put16(r, 1, mine);
		#
		# the smaller of the two, and it takes effect for both
		# sides once the answer is sent
		#
		n := peer;
		if(mine < n)
			n = mine;
		if(n < Defmtu)
			n = Defmtu;
		return (r, n);
	Rreadgroup =>
		return (readgroup(d, mtu, p), mtu);
	Rreadtype =>
		return (readtype(d, mtu, p), mtu);
	Rfindinfo =>
		return (findinfo(d, mtu, p), mtu);
	Rread =>
		return (read(d, mtu, p), mtu);
	Rreadblob =>
		return (readblob(d, mtu, p), mtu);
	}
	return (err(op, 0, Enotsupported), mtu);
}

#
# Read By Group Type: the primary services in a handle range, each
# with the range it covers.  Every entry in one answer has to be the
# same length, so a 16 bit service and a 128 bit one cannot travel
# together and the answer stops at the first that does not match.
#
readgroup(d: ref Db, mtu: int, p: array of byte): array of byte
{
	if(len p < 7)
		return err(int p[0], 0, Einvalidhandle);
	first := bt->get16(p, 1);
	last := bt->get16(p, 3);
	ty := p[5:len p];
	if(first == 0 || first > last)
		return err(int p[0], first, Einvalidhandle);
	if(!(len ty == 2 && bt->get16(ty, 0) == Uprimary))
		return err(int p[0], first, Enotsupported);

	<-d.lock;
	ents: list of (int, int, array of byte);
	n := 0;
	esz := 0;
	for(l := d.attrs; l != nil; l = tl l){
		a := hd l;
		if(a.handle < first || a.handle > last)
			continue;
		if(!(len a.uuid == 2 && bt->get16(a.uuid, 0) == Uprimary))
			continue;
		sz := 4 + len a.val;
		if(esz == 0)
			esz = sz;
		if(sz != esz)
			break;		# a different sized value ends the answer
		if(2 + (n+1)*esz > mtu)
			break;
		ents = (a.handle, groupend(d, a.handle), a.val) :: ents;
		n++;
	}
	d.lock <-= 1;
	if(n == 0)
		return err(int p[0], first, Enotfound);
	r := array[2 + n*esz] of byte;
	r[0] = byte Rreadgroupresp;
	r[1] = byte esz;
	o := 2 + (n-1)*esz;
	for(; ents != nil; ents = tl ents){
		(h, e, v) := hd ents;
		bt->put16(r, o, h);
		bt->put16(r, o+2, e);
		r[o+4:] = v;
		o -= esz;
	}
	return r;
}

#
# Read By Type: every attribute of one type in a range.  Used for
# characteristic declarations, and for reading a characteristic by its
# UUID without discovering it first.
#
readtype(d: ref Db, mtu: int, p: array of byte): array of byte
{
	if(len p < 7)
		return err(int p[0], 0, Einvalidhandle);
	first := bt->get16(p, 1);
	last := bt->get16(p, 3);
	ty := p[5:len p];
	if(first == 0 || first > last)
		return err(int p[0], first, Einvalidhandle);

	<-d.lock;
	ents: list of (int, array of byte);
	n := 0;
	esz := 0;
	for(l := d.attrs; l != nil; l = tl l){
		a := hd l;
		if(a.handle < first || a.handle > last)
			continue;
		if(!sameuuid(a.uuid, ty))
			continue;
		if(!a.rd)
			continue;
		sz := 2 + len a.val;
		if(esz == 0)
			esz = sz;
		if(sz != esz)
			break;
		if(2 + (n+1)*esz > mtu)
			break;
		ents = (a.handle, a.val) :: ents;
		n++;
	}
	d.lock <-= 1;
	if(n == 0)
		return err(int p[0], first, Enotfound);
	r := array[2 + n*esz] of byte;
	r[0] = byte Rreadtyperesp;
	r[1] = byte esz;
	o := 2 + (n-1)*esz;
	for(; ents != nil; ents = tl ents){
		(h, v) := hd ents;
		bt->put16(r, o, h);
		r[o+2:] = v;
		o -= esz;
	}
	return r;
}

#
# Find Information: the handles and types in a range, which is how a
# client finds descriptors -- the attributes that are not a service, a
# characteristic declaration or a value.
#
findinfo(d: ref Db, mtu: int, p: array of byte): array of byte
{
	if(len p < 5)
		return err(int p[0], 0, Einvalidhandle);
	first := bt->get16(p, 1);
	last := bt->get16(p, 3);
	if(first == 0 || first > last)
		return err(int p[0], first, Einvalidhandle);

	<-d.lock;
	ents: list of (int, array of byte);
	n := 0;
	usz := 0;
	for(l := d.attrs; l != nil; l = tl l){
		a := hd l;
		if(a.handle < first || a.handle > last)
			continue;
		if(usz == 0)
			usz = len a.uuid;
		if(len a.uuid != usz)
			break;		# the format is one or the other
		if(2 + (n+1)*(2+usz) > mtu)
			break;
		ents = (a.handle, a.uuid) :: ents;
		n++;
	}
	d.lock <-= 1;
	if(n == 0)
		return err(int p[0], first, Enotfound);
	fmt := 1;
	if(usz == 16)
		fmt = 2;
	esz := 2 + usz;
	r := array[2 + n*esz] of byte;
	r[0] = byte Rfindinforesp;
	r[1] = byte fmt;
	o := 2 + (n-1)*esz;
	for(; ents != nil; ents = tl ents){
		(h, u) := hd ents;
		bt->put16(r, o, h);
		r[o+2:] = u;
		o -= esz;
	}
	return r;
}

read(d: ref Db, mtu: int, p: array of byte): array of byte
{
	if(len p < 3)
		return err(int p[0], 0, Einvalidhandle);
	h := bt->get16(p, 1);
	<-d.lock;
	a := find(d, h);
	v: array of byte;
	e := 0;
	if(a == nil)
		e = Einvalidhandle;
	else if(!a.rd)
		e = Ereadnotperm;
	else
		v = a.val;
	d.lock <-= 1;
	if(e != 0)
		return err(int p[0], h, e);
	n := len v;
	if(n > mtu - 1)
		n = mtu - 1;
	r := array[1 + n] of byte;
	r[0] = byte Rreadresp;
	r[1:] = v[0:n];
	return r;
}

#
# Read Blob: the rest of a value that did not fit.  An offset equal to
# the length is not an error -- it is how a client that read exactly
# mtu-1 bytes finds out there is no more -- and an offset past it is.
#
readblob(d: ref Db, mtu: int, p: array of byte): array of byte
{
	if(len p < 5)
		return err(int p[0], 0, Einvalidhandle);
	h := bt->get16(p, 1);
	off := bt->get16(p, 3);
	<-d.lock;
	a := find(d, h);
	v: array of byte;
	e := 0;
	if(a == nil)
		e = Einvalidhandle;
	else if(!a.rd)
		e = Ereadnotperm;
	else {
		v = a.val;
		if(off > len v)
			e = Einvalidoffset;
	}
	d.lock <-= 1;
	if(e != 0)
		return err(int p[0], h, e);
	n := len v - off;
	if(n > mtu - 1)
		n = mtu - 1;
	r := array[1 + n] of byte;
	r[0] = byte Rreadblobresp;
	r[1:] = v[off:off+n];
	return r;
}
