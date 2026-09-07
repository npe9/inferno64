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
Rwrite:		con 16r12;
Rwriteresp:	con 16r13;
Rnotify:	con 16r1b;
Rindicate:	con 16r1d;
Rconfirm:	con 16r1e;
Rwritecmd:	con 16r52;

# the errors this side can raise
Einvalidhandle:	con 16r01;
Ereadnotperm:	con 16r02;
Ewritenotperm:	con 16r03;
Enotsupported:	con 16r06;
Einvalidoffset:	con 16r07;
Enotfound:	con 16r0a;
Ebadlength:	con 16r0d;

Uprimary:	con 16r2800;
Uchar:		con 16r2803;
Ucccd:		con 16r2902;

# what a peer writes into a client characteristic configuration
Cnotify:	con 16r0001;
Cindicate:	con 16r0002;

# how long a peer has to confirm an indication.  The specification
# allows thirty seconds; ten is longer than a working link takes and
# short enough that a peer that has stopped answering does not hold a
# writer up for half a minute.
Ackwait:	con 10000;

Defmtu:	con 23;
Maxmtu:	con 247;

init(b: Bt, l2: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	l2cap = l2;
	return nil;
}

#
# Every database begins with the Generic Attribute service and the
# Service Changed characteristic in it, so it is always handles one to
# four and a peer that wants to be told when the database grows has
# something to subscribe to from the start.  Adding it later would be
# adding it after the peer had already looked.
#
newdb(): ref Db
{
	d := ref Db;
	d.attrs = nil;
	d.n = 0;
	d.sess = nil;
	d.lock = chan[1] of int;
	d.lock <-= 1;
	addsvc(d, uuid16(Ugattsvc));
	(nil, vh, nil, nil) := addchar(d, uuid16(Uchanged), 16r20, nil);
	d.changed = vh;
	return d;
}

changedh(d: ref Db): int
{
	return d.changed;
}

#
# The database grew.  Tell every peer that asked, with the range of
# handles that appeared: a peer that caches -- which is what the
# handles are for -- has to know which part of its picture is short.
# Sent as an indication, so a peer that is listening confirms it and
# this side knows it got there.
#
announce(d: ref Db, first, last: int)
{
	if(d.changed == 0 || first > last)
		return;
	<-d.lock;
	any := d.sess != nil;
	d.lock <-= 1;
	if(!any)
		return;
	v := array[4] of byte;
	bt->put16(v, 0, first);
	bt->put16(v, 2, last);
	setval(d, d.changed, v);
	if((e := notify(d, d.changed, v)) != nil)
		sys->fprint(sys->fildes(2), "gattsrv: announcing %#4.4ux-%#4.4ux: %s\n",
			first, last, e);
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
	announce(d, h, h);
	return (h, nil);
}

#
# A characteristic is two attributes: the declaration, which says what
# may be done with it and where its value is, and the value itself.
# The declaration's value has the value handle in it, so the two have
# to be added together or the handle in the first would be a guess.
#
addchar(d: ref Db, uuid: array of byte, props: int, val: array of byte): (int, int, int, string)
{
	if(len uuid != 2 && len uuid != 16)
		return (0, 0, 0, "a UUID is two bytes or sixteen");
	<-d.lock;
	if(d.attrs == nil){
		d.lock <-= 1;
		return (0, 0, 0, "no service to put it in");
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
	#
	# A characteristic that notifies or indicates carries the
	# descriptor a peer writes to say it wants them.  Without it the
	# properties would promise something a peer has no way to ask
	# for.
	#
	ch := 0;
	if(props & (16r10|16r20))
		ch = add(d, ref Attr(0, uuid16(Ucccd), array[2] of {byte 0, byte 0}, 1, 1));
	last := d.n;
	d.lock <-= 1;
	announce(d, dh, last);
	return (dh, vh, ch, nil);
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
	s := ref Sess;
	s.m = m;
	s.mtu = Defmtu;
	s.cccd = nil;
	s.confirm = chan[1] of int;
	s.up = 1;
	<-d.lock;
	d.sess = s :: d.sess;
	d.lock <-= 1;
	spawn server(d, s);
}

server(d: ref Db, s: ref Sess)
{
	rq := l2cap->open(s.m, L2cap->Cattr);
	for(;;){
		p := <-rq;
		if(p == nil)
			break;
		if(len p < 1)
			continue;
		if(int p[0] == Rconfirm){
			#
			# the answer to an indication.  Non-blocking: a
			# confirmation nobody is waiting for is a peer
			# answering something already given up on, and
			# the reader must not stop for it.
			#
			alt {
			s.confirm <-= 1 =>	;
			* =>	;
			}
			continue;
		}
		r := request(d, s, p);
		if(r != nil)
			l2cap->send(s.m, L2cap->Cattr, r);
	}
	#
	# the link has gone: take the session out, so a value written
	# here is not offered to a peer that is no longer there
	#
	<-d.lock;
	s.up = 0;
	l: list of ref Sess;
	for(sl := d.sess; sl != nil; sl = tl sl)
		if(hd sl != s)
			l = hd sl :: l;
	d.sess = l;
	d.lock <-= 1;
}

# what this peer wrote into a configuration descriptor
cccdof(s: ref Sess, h: int): int
{
	for(l := s.cccd; l != nil; l = tl l){
		(ch, v) := hd l;
		if(ch == h)
			return v;
	}
	return 0;
}

setcccd(s: ref Sess, h, v: int)
{
	l: list of (int, int);
	for(cl := s.cccd; cl != nil; cl = tl cl)
		if((hd cl).t0 != h)
			l = hd cl :: l;
	s.cccd = (h, v) :: l;
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
request(d: ref Db, s: ref Sess, p: array of byte): array of byte
{
	op := int p[0];
	case op {
	Rmtureq =>
		if(len p < 3)
			return err(op, 0, Einvalidhandle);
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
		s.mtu = n;
		return r;
	Rreadgroup =>
		return readgroup(d, s.mtu, p);
	Rreadtype =>
		return readtype(d, s.mtu, p);
	Rfindinfo =>
		return findinfo(d, s.mtu, p);
	Rread =>
		return read(d, s, p);
	Rreadblob =>
		return readblob(d, s, p);
	Rwrite or Rwritecmd =>
		return write(d, s, p);
	}
	return err(op, 0, Enotsupported);
}

#
# A peer writing.  A configuration descriptor is this peer's own and
# is kept with the session; anything else is the value, which is what
# the file in the name space then reads.  A Write Command gets no
# answer at all, not even an error: that is what makes it a command.
#
write(d: ref Db, s: ref Sess, p: array of byte): array of byte
{
	op := int p[0];
	if(len p < 3){
		if(op == Rwritecmd)
			return nil;
		return err(op, 0, Einvalidhandle);
	}
	h := bt->get16(p, 1);
	v := p[3:len p];
	<-d.lock;
	a := find(d, h);
	e := 0;
	iscccd := 0;
	if(a == nil)
		e = Einvalidhandle;
	else if(!a.wr)
		e = Ewritenotperm;
	else if(len a.uuid == 2 && bt->get16(a.uuid, 0) == Ucccd){
		if(len v < 2)
			e = Ebadlength;
		else
			iscccd = 1;
	}
	if(e == 0 && !iscccd){
		nv := array[len v] of byte;
		nv[0:] = v;
		a.val = nv;
	}
	d.lock <-= 1;
	if(e == 0 && iscccd)
		setcccd(s, h, bt->get16(v, 0));
	if(op == Rwritecmd)
		return nil;
	if(e != 0)
		return err(op, h, e);
	r := array[1] of byte;
	r[0] = byte Rwriteresp;
	return r;
}

subscribed(d: ref Db, vh: int): int
{
	<-d.lock;
	ch := cccdfor(d, vh);
	sl := d.sess;
	d.lock <-= 1;
	if(ch == 0)
		return 0;
	for(; sl != nil; sl = tl sl)
		if(cccdof(hd sl, ch) & (Cnotify|Cindicate))
			return 1;
	return 0;
}

#
# The descriptor that belongs to a value: the next attribute after it
# whose type says so, and only before the next characteristic
# declaration -- otherwise a characteristic with no descriptor would
# borrow the next one's.  With the lock held.
#
cccdfor(d: ref Db, vh: int): int
{
	seen := 0;
	for(l := d.attrs; l != nil; l = tl l){
		a := hd l;
		if(a.handle == vh){
			seen = 1;
			continue;
		}
		if(!seen)
			continue;
		if(len a.uuid == 2){
			u := bt->get16(a.uuid, 0);
			if(u == Ucccd)
				return a.handle;
			if(u == Uchar || u == Uprimary)
				return 0;
		}
	}
	return 0;
}

#
# The value changed on this side.  Every peer that asked for
# notifications gets one; every peer that asked for indications gets
# one and is waited for, because the specification allows one
# indication outstanding at a time and sending the next before the
# first is confirmed is how a peer ends up dropping them.
#
notify(d: ref Db, vh: int, v: array of byte): string
{
	<-d.lock;
	ch := cccdfor(d, vh);
	sl := d.sess;
	d.lock <-= 1;
	if(ch == 0)
		return nil;		# nothing may subscribe to it
	e := "";
	for(; sl != nil; sl = tl sl){
		s := hd sl;
		if(!s.up)
			continue;
		c := cccdof(s, ch);
		if(c & Cnotify){
			if((se := send(s, Rnotify, vh, v)) != nil)
				e = se;
		}else if(c & Cindicate){
			if((se := send(s, Rindicate, vh, v)) != nil){
				e = se;
				continue;
			}
			tick := chan[1] of int;
			spawn timer(Ackwait, tick);
			alt {
			<-s.confirm =>	;
			<-tick =>
				e = "the peer never confirmed the indication";
			}
		}
	}
	if(e == "")
		return nil;
	return e;
}

send(s: ref Sess, op, h: int, v: array of byte): string
{
	n := len v;
	if(n > s.mtu - 3)
		n = s.mtu - 3;
	r := array[3 + n] of byte;
	r[0] = byte op;
	bt->put16(r, 1, h);
	r[3:] = v[0:n];
	return l2cap->send(s.m, L2cap->Cattr, r);
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
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

read(d: ref Db, s: ref Sess, p: array of byte): array of byte
{
	mtu := s.mtu;
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
readblob(d: ref Db, s: ref Sess, p: array of byte): array of byte
{
	mtu := s.mtu;
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
