implement Gatt;

#
# GATT: a database convention over ATT.  A server's attributes are
# grouped into services, each service holds characteristics, each
# characteristic has a value and may have descriptors -- which is a
# directory of directories of files, and is why btfs(4) can serve a
# remote device's whole database as one.
#
# Discovery is three ATT requests used in a loop, each one asking
# for the next handle range and stopping when the server says there
# is nothing more of that kind.
#
# On 9front this is one C file: the same three loops.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	att: Att;
	Sess: import Att;

Notfound:	con "attribute not found";

init(b: Bt, a: Att): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	att = a;
	return nil;
}

#
# every primary service: Read By Group Type over the whole handle
# space, walking forward until the server runs out
#
services(s: ref Sess): (list of ref Service, string)
{
	r: list of ref Service;
	start := 1;
	for(;;){
		q := array[7] of byte;
		q[0] = byte Att->Rreadgroup;
		bt->put16(q, 1, start);
		bt->put16(q, 3, 16rffff);
		bt->put16(q, 5, Uprimary);
		(p, e) := att->request(s, q);
		if(e != nil){
			if(iserr(e, Notfound))
				break;
			return (rev(r), e);
		}
		if(len p < 2)
			return (rev(r), "short read by group type response");
		l := int p[1];
		if(l < 6)
			return (rev(r), "bad read by group type response");
		last := 0;
		for(o := 2; o + l <= len p; o += l){
			h := bt->get16(p, o);
			end := bt->get16(p, o+2);
			r = ref Service(h, end, bt->uuid(p, o+4, l-4)) :: r;
			last = end;
		}
		if(last == 0 || last >= 16rffff)
			break;
		start = last + 1;
	}
	return (rev(r), nil);
}

#
# every characteristic of one service: Read By Type over that
# service's handle range.  The last handle of a characteristic is
# the one before the next characteristic starts, or the end of the
# service -- which is what says where its descriptors are.
#
chars(s: ref Sess, svc: ref Service): (list of ref Char, string)
{
	r: list of ref Char;
	start := svc.start;
	for(;;){
		if(start > svc.end)
			break;
		q := array[7] of byte;
		q[0] = byte Att->Rreadtype;
		bt->put16(q, 1, start);
		bt->put16(q, 3, svc.end);
		bt->put16(q, 5, Uchar);
		(p, e) := att->request(s, q);
		if(e != nil){
			if(iserr(e, Notfound))
				break;
			return (fixends(rev(r), svc), e);
		}
		if(len p < 2)
			return (fixends(rev(r), svc), "short read by type response");
		l := int p[1];
		if(l < 7)
			return (fixends(rev(r), svc), "bad read by type response");
		last := 0;
		for(o := 2; o + l <= len p; o += l){
			dh := bt->get16(p, o);
			props := int p[o+2];
			vh := bt->get16(p, o+3);
			u := bt->uuid(p, o+5, l-5);
			r = ref Char(dh, vh, 0, props, u, 0) :: r;
			last = dh;
		}
		if(last == 0 || last >= svc.end)
			break;
		start = last + 1;
	}
	return (fixends(rev(r), svc), nil);
}

fixends(l: list of ref Char, svc: ref Service): list of ref Char
{
	a := array[len l] of ref Char;
	i := 0;
	for(x := l; x != nil; x = tl x)
		a[i++] = hd x;
	for(i = 0; i < len a; i++){
		if(i + 1 < len a)
			a[i].ehandle = a[i+1].dhandle - 1;
		else
			a[i].ehandle = svc.end;
	}
	return l;
}

#
# the descriptors of one characteristic, which for a client means:
# find its client characteristic configuration, the handle a
# subscription is written to
#
descriptors(s: ref Sess, c: ref Char): string
{
	if(c.vhandle >= c.ehandle)
		return nil;
	start := c.vhandle + 1;
	for(;;){
		if(start > c.ehandle)
			break;
		q := array[5] of byte;
		q[0] = byte Att->Rfindinfo;
		bt->put16(q, 1, start);
		bt->put16(q, 3, c.ehandle);
		(p, e) := att->request(s, q);
		if(e != nil){
			if(iserr(e, Notfound))
				break;
			return e;
		}
		if(len p < 2)
			return "short find information response";
		fmt := int p[1];
		ul := 2;
		if(fmt == 2)
			ul = 16;
		else if(fmt != 1)
			return "unknown find information format";
		last := 0;
		for(o := 2; o + 2 + ul <= len p; o += 2 + ul){
			h := bt->get16(p, o);
			u := bt->uuid(p, o+2, ul);
			if(u == "2902")
				c.cccd = h;
			last = h;
		}
		if(last == 0 || last >= c.ehandle)
			break;
		start = last + 1;
	}
	return nil;
}

#
# a characteristic value.  A value longer than the MTU comes back
# truncated, so keep asking with Read Blob until the server hands
# back less than a full one.
#
read(s: ref Sess, h: int): (array of byte, string)
{
	q := array[3] of byte;
	q[0] = byte Att->Rread;
	bt->put16(q, 1, h);
	(p, e) := att->request(s, q);
	if(e != nil)
		return (nil, e);
	v := p[1:];
	if(len v < s.mtu - 1)
		return (v, nil);
	for(;;){
		b := array[5] of byte;
		b[0] = byte Att->Rreadblob;
		bt->put16(b, 1, h);
		bt->put16(b, 3, len v);
		(bp, be) := att->request(s, b);
		if(be != nil){
			# a server that will not do blob reads has
			# already given everything it has
			break;
		}
		more := bp[1:];
		if(len more == 0)
			break;
		nv := array[len v + len more] of byte;
		nv[0:] = v;
		nv[len v:] = more;
		v = nv;
		if(len more < s.mtu - 1)
			break;
	}
	return (v, nil);
}

#
# A value that fits in one request is written with one.  A longer one
# is queued at the server in pieces with Prepare Write and then
# committed with Execute Write, which is the only way ATT has of
# writing more than an MTU and the counterpart of the Read Blob loop
# above.
#
write(s: ref Sess, h: int, v: array of byte): string
{
	if(3 + len v <= s.mtu){
		q := array[3 + len v] of byte;
		q[0] = byte Att->Rwrite;
		bt->put16(q, 1, h);
		q[3:] = v;
		(nil, e) := att->request(s, q);
		return e;
	}
	return longwrite(s, h, v);
}

#
# Prepare Write carries a handle, an offset and as much of the value
# as the MTU leaves room for: the opcode, the handle and the offset
# are five bytes of it.  The server echoes back what it queued, and
# this checks the echo -- a server that queued something else would
# otherwise be committed to it by the Execute below, which is the one
# place in ATT where not looking at the answer writes the wrong bytes
# to the device rather than merely losing them.
#
# Anything that goes wrong cancels the queue rather than leaving the
# server holding half a value for the next client to commit.
#
longwrite(s: ref Sess, h: int, v: array of byte): string
{
	chunk := s.mtu - 5;
	if(chunk < 1)
		return "the ATT MTU leaves no room for a long write";
	for(off := 0; off < len v; off += chunk){
		n := len v - off;
		if(n > chunk)
			n = chunk;
		q := array[5 + n] of byte;
		q[0] = byte Att->Rprepare;
		bt->put16(q, 1, h);
		bt->put16(q, 3, off);
		q[5:] = v[off:off+n];
		(p, e) := att->request(s, q);
		if(e != nil)
			return cancelwrite(s, e);
		if(len p != 5 + n || bt->get16(p, 1) != h || bt->get16(p, 3) != off)
			return cancelwrite(s, "the server queued a different handle or offset");
		for(i := 0; i < n; i++)
			if(p[5+i] != v[off+i])
				return cancelwrite(s, "the server queued different bytes");
	}
	x := array[2] of byte;
	x[0] = byte Att->Rexecute;
	x[1] = byte Att->Xwrite;
	(nil, xe) := att->request(s, x);
	return xe;
}

cancelwrite(s: ref Sess, why: string): string
{
	x := array[2] of byte;
	x[0] = byte Att->Rexecute;
	x[1] = byte Att->Xcancel;
	att->request(s, x);
	return why;
}

#
# subscribing is writing to the characteristic's own configuration
# descriptor: 1 for notifications, 2 for indications, 0 for neither
#
subscribe(s: ref Sess, c: ref Char, on: int): string
{
	if(c.cccd == 0){
		if((e := descriptors(s, c)) != nil)
			return e;
	}
	if(c.cccd == 0)
		return "the characteristic has no client configuration descriptor";
	v := array[2] of byte;
	bits := 0;
	if(on){
		if(c.props & Pnotify)
			bits = 1;
		else if(c.props & Pindicate)
			bits = 2;
		else
			return "the characteristic neither notifies nor indicates";
	}
	bt->put16(v, 0, bits);
	return write(s, c.cccd, v);
}

propstr(p: int): string
{
	s := "";
	if(p & Pbroadcast)
		s += " broadcast";
	if(p & Pread)
		s += " read";
	if(p & Pwritenoresp)
		s += " writenoresp";
	if(p & Pwrite)
		s += " write";
	if(p & Pnotify)
		s += " notify";
	if(p & Pindicate)
		s += " indicate";
	if(s == nil)
		return "none";
	return s[1:];
}

iserr(e, what: string): int
{
	for(i := 0; i + len what <= len e; i++)
		if(e[i:i+len what] == what)
			return 1;
	return 0;
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
