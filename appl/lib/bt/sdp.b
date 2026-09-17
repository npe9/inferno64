implement Sdp;

#
# The Service Discovery Protocol, the client half.
#
# SDP is not GATT and the difference is not cosmetic.  A GATT database
# is a flat table of handles a client walks, so a client can discover
# it a piece at a time and hold on to what it found.  An SDP server
# holds records, each a set of attributes whose values are trees of
# typed data elements, and a client asks for whole records by UUID and
# gets them back in one answer -- or in several, joined by a
# continuation state, because an answer that does not fit is not an
# answer that may be truncated.
#
# So there are two halves here: reading a data element, which is a
# recursive descent over a length-prefixed encoding; and one request,
# Service Search Attribute, asked until the server says there is no
# more to come.
#
# On 9front this is one C file with the same two halves.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	l2cap: L2cap;
	Mux, Chan: import L2cap;

# protocol data unit identifiers
Perror:		con 16r01;
Pssareq:	con 16r06;
Pssaresp:	con 16r07;

#
# How much of an answer to ask for at once.  The channel's MTU is what
# actually fits; this stays under it with room for the response header
# and the continuation state, and the continuation state is what makes
# a small number here correct rather than merely slow.
#
Maxbytes:	con 512;

# a server that will not stop is a server that has to be stopped
Maxrounds:	con 64;

#
# SDP is big endian, from its header to its UUIDs to the parameters
# inside a data element.  Everything else in this stack -- HCI, L2CAP,
# ATT, SMP -- is little endian, so bt's get16 and put16 are the wrong
# way round here and using them was the first mistake made writing
# this.  These are the right way round and are used throughout.
#
get16b(a: array of byte, o: int): int
{
	if(o + 2 > len a)
		return 0;
	return (int a[o] << 8) | int a[o+1];
}

put16b(a: array of byte, o, v: int)
{
	if(o + 2 > len a)
		return;
	a[o] = byte (v >> 8);
	a[o+1] = byte v;
}

init(b: Bt, l: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	l2cap = l;
	return nil;
}

Elem.at(e: self ref Elem, i: int): ref Elem
{
	if(e == nil)
		return nil;
	for(l := e.l; l != nil; l = tl l){
		if(i == 0)
			return hd l;
		i--;
	}
	return nil;
}

Elem.text(e: self ref Elem): string
{
	if(e == nil)
		return "";
	case e.ty {
	Enil =>		return "nil";
	Euint or Esint =>
		return sys->sprint("%bd", e.n);
	Ebool =>
		if(e.n != big 0)
			return "true";
		return "false";
	Euuid =>	return e.uuid;
	Etext or Eurl =>
		return e.s;
	Eseq or Ealt =>
		s := "";
		for(l := e.l; l != nil; l = tl l){
			if(s != nil)
				s += " ";
			s += (hd l).text();
		}
		return "(" + s + ")";
	}
	return "";
}

Rec.attr(r: self ref Rec, id: int): ref Elem
{
	for(l := r.attrs; l != nil; l = tl l){
		(i, e) := hd l;
		if(i == id)
			return e;
	}
	return nil;
}

#
# One data element.  The descriptor byte is five bits of type and
# three of size index: 0 to 4 mean 1, 2, 4, 8 and 16 bytes of data,
# and 5, 6 and 7 mean the length itself is 1, 2 or 4 bytes and follows.
# A nil element is the one exception: size index 0 means no data at
# all, not one byte of it.
#
parse(a: array of byte, o: int): (ref Elem, int, string)
{
	if(o >= len a)
		return (nil, 0, "a data element off the end of the answer");
	d := int a[o];
	ty := d >> 3;
	si := d & 7;
	hdr := 1;
	n := 0;
	case si {
	0 =>	n = 1;
	1 =>	n = 2;
	2 =>	n = 4;
	3 =>	n = 8;
	4 =>	n = 16;
	5 or 6 or 7 =>
		w := 1 << (si - 5);
		if(o + 1 + w > len a)
			return (nil, 0, "a data element length off the end");
		n = 0;
		for(i := 0; i < w; i++)
			n = (n << 8) | int a[o+1+i];
		hdr = 1 + w;
	}
	if(ty == Enil){
		#
		# the one element with no data.  Its size index is 0,
		# which everywhere else means one byte.
		#
		e := ref Elem(Enil, big 0, nil, nil, nil, nil);
		return (e, 1, nil);
	}
	if(n < 0 || o + hdr + n > len a)
		return (nil, 0, "a data element of " + string n + " bytes off the end");
	b := a[o+hdr:o+hdr+n];
	e := ref Elem(ty, big 0, nil, nil, nil, nil);
	case ty {
	Euint or Ebool =>
		for(i := 0; i < len b && i < 8; i++)
			e.n = (e.n << 8) | big int b[i];
	Esint =>
		#
		# sign extended from its own width, which is what makes
		# a one byte -1 read as -1 and not as 255
		#
		v := big 0;
		for(i := 0; i < len b && i < 8; i++)
			v = (v << 8) | big int b[i];
		if(len b > 0 && len b <= 8 && (int b[0] & 16r80))
			v -= big 1 << (8 * len b);
		e.n = v;
	Euuid =>
		#
		# and not bt->uuid(), which reverses: a UUID is little
		# endian on an ATT wire and big endian on this one, so
		# the bytes are already in the order they are written
		# in.
		#
		e.uuid = bt->lower(bt->hex(b));
	Etext or Eurl =>
		#
		# both: the string for anything that is a name, and the
		# bytes for anything that is not.  A HID report
		# descriptor arrives in one of these and is full of
		# bytes that are not characters.
		#
		e.s = string b;
		e.data = b;
	Eseq or Ealt =>
		#
		# built head first and turned round, so what a caller
		# walks is the order the server wrote
		#
		rl: list of ref Elem;
		for(i := 0; i < len b;){
			(c, used, ce) := parse(b, i);
			if(ce != nil)
				return (nil, 0, ce);
			if(used <= 0)
				return (nil, 0, "a data element of no length");
			rl = c :: rl;
			i += used;
		}
		for(; rl != nil; rl = tl rl)
			e.l = hd rl :: e.l;
	* =>
		return (nil, 0, sys->sprint("data element type %d, which is not one", ty));
	}
	return (e, hdr + n, nil);
}

#
# Ask for every record holding that service class, with every
# attribute the server has for it, and keep asking while it says there
# is more.
#
search(m: ref Mux, ch: ref Chan, uuid: string): (list of ref Rec, string)
{
	if(ch == nil)
		return (nil, "no channel to the service discovery server");
	u := bt->unhex(uuid);
	if(len u != 2 && len u != 4 && len u != 16)
		return (nil, "a UUID of " + string len u + " bytes");

	cont := array[0] of byte;
	acc := array[0] of byte;
	tid := 1;
	for(round := 0; ; round++){
		if(round >= Maxrounds)
			return (nil, "the server never stopped continuing");
		req := ssareq(u, cont);
		p := array[5 + len req] of byte;
		p[0] = byte Pssareq;
		put16b(p, 1, tid);
		put16b(p, 3, len req);
		p[5:] = req;
		if((e := l2cap->csend(m, ch, p)) != nil)
			return (nil, e);
		(r, re) := l2cap->crecv(m, ch);
		if(re != nil)
			return (nil, re);
		if(len r < 5)
			return (nil, "a service discovery answer of " + string len r + " bytes");
		if(int r[0] == Perror){
			code := 0;
			if(len r >= 7)
				code = get16b(r, 5);
			return (nil, sdperr(code));
		}
		if(int r[0] != Pssaresp)
			return (nil, sys->sprint("the server answered pdu %#2.2ux", int r[0]));
		if(get16b(r, 1) != tid)
			return (nil, "the server answered a transaction nobody asked");
		plen := get16b(r, 3);
		if(len r < 5 + plen)
			return (nil, "a service discovery answer shorter than it says");
		b := r[5:5+plen];
		if(len b < 3)
			return (nil, "a service discovery answer with no attribute list");
		alen := get16b(b, 0);
		if(2 + alen > len b)
			return (nil, "an attribute list longer than the answer holding it");
		#
		# The bytes are joined before anything is parsed, and
		# that is the whole point of a continuation: a record
		# can be cut in the middle of a data element, so an
		# answer is not a tree until the last piece has arrived.
		#
		na := array[len acc + alen] of byte;
		na[0:] = acc;
		na[len acc:] = b[2:2+alen];
		acc = na;

		cl := int b[2+alen];
		if(2 + alen + 1 + cl > len b)
			return (nil, "a continuation state longer than the answer holding it");
		if(cl == 0)
			break;
		cont = b[2+alen+1:2+alen+1+cl];
		tid++;
	}

	#
	# What has arrived is one sequence holding one sequence per
	# record, each of those an alternating list of attribute id and
	# value.
	#
	#
	# A server with nothing matching answers with an empty
	# attribute list, and one that answers with no bytes at all has
	# said the same thing badly.  Neither is an error: what the
	# caller asked is what services there are, and the answer is
	# none.
	#
	if(len acc == 0)
		return (nil, nil);
	(lists, nil, pe) := parse(acc, 0);
	if(pe != nil)
		return (nil, pe);
	if(lists == nil || lists.ty != Eseq)
		return (nil, "the attribute lists are not a sequence");
	rl: list of ref Rec;
	for(l := lists.l; l != nil; l = tl l){
		one := hd l;
		if(one.ty != Eseq)
			continue;
		r := ref Rec;
		r.handle = 0;
		r.attrs = nil;
		al: list of (int, ref Elem);
		el := one.l;
		while(el != nil && tl el != nil){
			id := hd el;
			v := hd tl el;
			el = tl tl el;
			if(id.ty != Euint)
				continue;
			ai := int id.n;
			al = (ai, v) :: al;
			if(ai == Ahandle && v.ty == Euint)
				r.handle = int v.n;
		}
		for(; al != nil; al = tl al)
			r.attrs = hd al :: r.attrs;
		rl = r :: rl;
	}
	nl: list of ref Rec;
	for(; rl != nil; rl = tl rl)
		nl = hd rl :: nl;
	return (nl, nil);
}

#
# the request body: the pattern to search for, how much of an answer
# to take, which attributes, and where the last answer stopped
#
ssareq(u, cont: array of byte): array of byte
{
	#
	# A service search pattern is a sequence of UUIDs; one is
	# enough, and the range 0x0000 to 0xffff asks for every
	# attribute a record has rather than a list this side chose,
	# because what an unknown service holds is not known here.
	#
	pat := array[2 + 1 + len u] of byte;
	pat[0] = byte (Eseq << 3 | 5);		# sequence, one byte of length
	pat[1] = byte (1 + len u);
	pat[2] = byte (Euuid << 3 | uuidsize(len u));
	pat[3:] = u;

	att := array[2 + 5] of byte;
	att[0] = byte (Eseq << 3 | 5);
	att[1] = byte 5;
	att[2] = byte (Euint << 3 | 2);		# a four byte unsigned: a range
	put16b(att, 3, 16r0000);
	put16b(att, 5, 16rffff);

	p := array[len pat + 2 + len att + 1 + len cont] of byte;
	o := 0;
	p[o:] = pat;
	o += len pat;
	put16b(p, o, Maxbytes);
	o += 2;
	p[o:] = att;
	o += len att;
	p[o] = byte len cont;
	o++;
	if(len cont > 0)
		p[o:] = cont;
	return p;
}

uuidsize(n: int): int
{
	case n {
	2 =>	return 1;
	4 =>	return 2;
	}
	return 4;			# sixteen bytes
}

sdperr(code: int): string
{
	case code {
	16r0001 =>	return "the server does not speak that version of SDP";
	16r0002 =>	return "an invalid service record handle";
	16r0003 =>	return "the request syntax is wrong";
	16r0004 =>	return "the request is too long";
	16r0005 =>	return "the server has no resources";
	16r0006 =>	return "an invalid continuation state";
	}
	return sys->sprint("the server refused the request: %#4.4ux", code);
}

#
# A protocol descriptor list is a sequence of sequences, each of them
# a UUID and then whatever parameters that protocol takes: for L2CAP
# the PSM, for RFCOMM the channel number.  Reading it is the whole
# reason a client asks for a record at all -- it is where the number
# an RFCOMM connection needs comes from.
#
protos(r: ref Rec): list of string
{
	e := r.attr(Aprotos);
	if(e == nil || e.ty != Eseq)
		return nil;
	rl: list of string;
	for(l := e.l; l != nil; l = tl l){
		one := hd l;
		if(one.ty != Eseq || one.l == nil)
			continue;
		u := hd one.l;
		if(u.ty != Euuid)
			continue;
		s := uuidname(u.uuid);
		for(pl := tl one.l; pl != nil; pl = tl pl)
			s += " " + (hd pl).text();
		rl = s :: rl;
	}
	nl: list of string;
	for(; rl != nil; rl = tl rl)
		nl = hd rl :: nl;
	return nl;
}

#
# The report descriptor out of a HID record.  It is the same
# descriptor an LE device serves as its 2a4b characteristic, so what
# reads one reads the other: the transport differs and the bytes do
# not.
#
hiddesc(r: ref Rec): array of byte
{
	e := r.attr(Ahiddesc);
	if(e == nil || e.ty != Eseq)
		return nil;
	for(l := e.l; l != nil; l = tl l){
		one := hd l;
		if(one.ty != Eseq || one.l == nil || tl one.l == nil)
			continue;
		ty := hd one.l;
		v := hd tl one.l;
		if(ty.ty != Euint || int ty.n != Dreport)
			continue;
		if(v.ty != Etext && v.ty != Eurl)
			continue;
		#
		# A descriptor of no bytes is no descriptor.  Returning
		# an empty array rather than nil would put an empty
		# hiddesc line in front of a reader, which reads as a
		# device that has one.
		#
		if(len v.data == 0)
			continue;
		return v.data;
	}
	return nil;
}

#
# Building a record.  A server's records are the same trees a client
# reads, so they are built out of the same Elem and turned into bytes
# by one function -- there is no second encoding here to disagree with
# the decoding above.
#
uint(v, width: int): ref Elem
{
	e := ref Elem(Euint, big v, nil, nil, nil, nil);
	e.n = big v;
	#
	# the width is carried in the element by making the bytes now:
	# an integer's size index is part of its encoding and not of
	# its value, and packing it later would have to guess.
	#
	e.data = array[width] of byte;
	for(i := 0; i < width; i++)
		e.data[width-1-i] = byte (v >> (8*i));
	return e;
}

uuidof(u: string): ref Elem
{
	e := ref Elem(Euuid, big 0, nil, nil, nil, nil);
	e.uuid = u;
	e.data = bt->unhex(u);
	return e;
}

text(s: string): ref Elem
{
	e := ref Elem(Etext, big 0, s, array of byte s, nil, nil);
	return e;
}

seq(l: list of ref Elem): ref Elem
{
	return ref Elem(Eseq, big 0, nil, nil, nil, l);
}

#
# One element's bytes.  The descriptor byte is five bits of type and
# three of size index, and a length that will not fit in the index is
# written after it -- the same rule parse() reads, from the other
# side.
#
pack(e: ref Elem): array of byte
{
	if(e == nil)
		return array[1] of {byte (Enil << 3)};
	case e.ty {
	Euint or Esint =>
		return leaf(e.ty, e.data);
	Euuid =>
		return leaf(Euuid, e.data);
	Etext or Eurl =>
		return leaf(e.ty, e.data);
	Ebool =>
		b := array[1] of byte;
		b[0] = byte 0;
		if(e.n != big 0)
			b[0] = byte 1;
		return leaf(Ebool, b);
	Eseq or Ealt =>
		body := array[0] of byte;
		for(l := e.l; l != nil; l = tl l){
			one := pack(hd l);
			nb := array[len body + len one] of byte;
			nb[0:] = body;
			nb[len body:] = one;
			body = nb;
		}
		return leaf(e.ty, body);
	}
	return array[1] of {byte (Enil << 3)};
}

#
# A leaf of that type holding those bytes.  A fixed width type says
# its length in the size index; anything else says it after the
# descriptor, in as few bytes as it fits.
#
leaf(ty: int, b: array of byte): array of byte
{
	n := len b;
	si := -1;
	if(ty == Euint || ty == Esint || ty == Euuid || ty == Ebool){
		case n {
		1 =>	si = 0;
		2 =>	si = 1;
		4 =>	si = 2;
		8 =>	si = 3;
		16 =>	si = 4;
		}
	}
	if(si >= 0){
		r := array[1 + n] of byte;
		r[0] = byte ((ty << 3) | si);
		r[1:] = b;
		return r;
	}
	if(n <= 255){
		r := array[2 + n] of byte;
		r[0] = byte ((ty << 3) | 5);
		r[1] = byte n;
		r[2:] = b;
		return r;
	}
	r := array[3 + n] of byte;
	r[0] = byte ((ty << 3) | 6);
	put16b(r, 1, n);
	r[3:] = b;
	return r;
}

#
# One record as a sequence of alternating attribute ids and values,
# which is what a client walks.
#
packrec(r: ref Rec): array of byte
{
	l: list of ref Elem;
	for(al := r.attrs; al != nil; al = tl al){
		(id, v) := hd al;
		l = v :: uint(id, 2) :: l;
	}
	rl: list of ref Elem;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return pack(seq(rl));
}

#
# Answer one request.  Only the search-and-attributes one is served:
# it is what a client that wants whole records asks, and the other two
# are answered with an error rather than with silence, because a
# request nobody answers is a client that waits.
#
answer(db: list of ref Rec, p: array of byte): array of byte
{
	if(len p < 5)
		return nil;
	pdu := int p[0];
	tid := get16b(p, 1);
	plen := get16b(p, 3);
	if(len p < 5 + plen)
		return errresp(tid, 16r0003);	# invalid request syntax
	body := p[5:5+plen];
	if(pdu != Pssareq)
		return errresp(tid, 16r0003);

	#
	# the search pattern, and then how much of an answer to give,
	# the attributes wanted, and where the last answer stopped
	#
	(pat, o, pe) := parse(body, 0);
	if(pe != nil || pat == nil || pat.ty != Eseq)
		return errresp(tid, 16r0003);
	if(o + 2 > len body)
		return errresp(tid, 16r0003);
	maxb := get16b(body, o);
	o += 2;
	(nil, n2, ae) := parse(body, o);
	if(ae != nil)
		return errresp(tid, 16r0003);
	o += n2;
	off := 0;
	if(o < len body){
		cl := int body[o];
		if(cl > 0){
			if(o + 1 + cl > len body)
				return errresp(tid, 16r0006);
			for(i := 0; i < cl; i++)
				off = (off << 8) | int body[o+1+i];
		}
	}

	#
	# every record whose service class list holds every UUID the
	# pattern named.  A pattern is an and, not an or: a client
	# asking for two classes wants a record that is both.
	#
	l: list of ref Elem;
	for(rl := db; rl != nil; rl = tl rl)
		if(matches(hd rl, pat))
			l = ref Elem(Eseq, big 0, nil, packrec(hd rl), nil, nil) :: l;
	body2 := array[0] of byte;
	for(; l != nil; l = tl l){
		one := (hd l).data;
		nb := array[len body2 + len one] of byte;
		nb[0:] = body2;
		nb[len body2:] = one;
		body2 = nb;
	}
	whole := leaf(Eseq, body2);

	if(off > len whole)
		return errresp(tid, 16r0006);	# invalid continuation state
	take := len whole - off;
	if(maxb > 0 && take > maxb)
		take = maxb;
	piece := whole[off:off+take];
	more := off + take < len whole;
	cont := array[1] of {byte 0};
	if(more){
		cont = array[3] of byte;
		cont[0] = byte 2;
		put16b(cont, 1, off + take);
	}
	params := array[2 + len piece + len cont] of byte;
	put16b(params, 0, len piece);
	params[2:] = piece;
	params[2+len piece:] = cont;
	r := array[5 + len params] of byte;
	r[0] = byte Pssaresp;
	put16b(r, 1, tid);
	put16b(r, 3, len params);
	r[5:] = params;
	return r;
}

#
# whether a record's service class list holds every UUID the pattern
# named
#
matches(r: ref Rec, pat: ref Elem): int
{
	cl := r.attr(Aclasses);
	if(cl == nil)
		return 0;
	for(l := pat.l; l != nil; l = tl l){
		want := hd l;
		if(want.ty != Euuid)
			continue;
		got := 0;
		for(gl := cl.l; gl != nil; gl = tl gl)
			if((hd gl).ty == Euuid && (hd gl).uuid == want.uuid)
				got = 1;
		#
		# and the browse group, which a client searching for
		# everything a device offers asks for and which is not
		# in the class list
		#
		if(!got){
			bg := r.attr(Abrowse);
			if(bg != nil)
				for(bl := bg.l; bl != nil; bl = tl bl)
					if((hd bl).ty == Euuid && (hd bl).uuid == want.uuid)
						got = 1;
		}
		if(!got)
			return 0;
	}
	return 1;
}

#
# An error response carries the code and nothing else: the
# specification allows an info field after it and there is nothing
# here to put in one.
#
errresp(tid, code: int): array of byte
{
	r := array[7] of byte;
	r[0] = byte Perror;
	put16b(r, 1, tid);
	put16b(r, 3, 2);
	put16b(r, 5, code);
	return r;
}

#
# The few UUIDs worth a name here.  Everything else keeps its number:
# a table of every assigned number would be a table to keep up to
# date, and what a client above needs is the ones it acts on.
#
uuidname(u: string): string
{
	case u {
	"0001" =>	return "sdp";
	"0003" =>	return "rfcomm";
	"0008" =>	return "obex";
	"000c" =>	return "http";
	"0100" =>	return "l2cap";
	"0011" =>	return "hidp";
	"0019" =>	return "avctp";
	"001b" =>	return "avdtp";
	"000f" =>	return "bnep";
	}
	return u;
}
