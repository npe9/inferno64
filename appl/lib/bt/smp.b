implement Smp;

#
# SMP: LE legacy pairing, as the initiator.
#
# This is the part of Bluetooth that is a real state machine rather
# than a parser, and it is the part worth keeping in one place: the
# confirm/random exchange, the key derivation, starting encryption
# and taking the keys the peer distributes afterwards.
#
# Legacy pairing needs nothing but AES-128, because its two key
# functions are built out of it:
#
#	e(k, m)		AES-128 of one block
#	c1(k, r, ...)	e(k, e(k, r^p1) ^ p2)	the commitment
#	s1(k, r1, r2)	e(k, r2' || r1')	the short term key
#
# and crypt(2) has AES, so nothing here asks the controller to do
# arithmetic.  AES works most significant byte first and Bluetooth
# works least significant byte first, so e() reverses its arguments
# and its result; that reversal is the single thing most likely to
# be got wrong, and it is done in exactly one function.
#
# What this does NOT do is LE Secure Connections, which needs P-256
# elliptic curve Diffie-Hellman and AES-CMAC.  A device that insists
# on it will not pair here.  Nor does it do a passkey or numeric
# comparison: the temporary key is zero, which is Just Works, and
# Just Works gives no protection against a man in the middle.  Both
# are said again in btfs(4) rather than left to be discovered.
#
# On 9front this is one C file over libsec's aes_encrypt.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	hci: Hci;
	l2cap: L2cap;
	Conn: import Hci;
	Mux: import L2cap;
include "ipints.m";
include "keyring.m";
include "crypt.m";
	crypt: Crypt;

Timeout:	con 30000;	# ms, the specification's SMP timeout
Encwait:	con 10000;	# ms to wait for encryption to come up

# SMP command codes
Preq:		con 16r01;
Presp:		con 16r02;
Pconfirm:	con 16r03;
Prandom:	con 16r04;
Pfailed:	con 16r05;
Penckey:	con 16r06;
Pmasterid:	con 16r07;
Pidkey:		con 16r08;
Pidaddr:	con 16r09;
Psignkey:	con 16r0a;

# key distribution bits
Kenc:		con 16r01;
Kid:		con 16r02;
Ksign:		con 16r04;

# authentication request bits
Abonding:	con 16r01;
Amitm:		con 16r04;
Asc:		con 16r08;

init(b: Bt, h: Hci, l: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	hci = h;
	l2cap = l;
	crypt = load Crypt Crypt->PATH;
	if(crypt == nil)
		return sys->sprint("cannot load %s: %r", Crypt->PATH);
	return nil;
}

Bond.text(b: self ref Bond): string
{
	s := sys->sprint("%s %s ltk %s ediv %d rand %s irk %s csrk %s",
		b.addr, bt->atypestr(b.atype), bt->hex(b.ltk), b.ediv,
		bt->hex(b.rand), bt->hex(b.irk), bt->hex(b.csrk));
	#
	# which controller the bond was made on.  A long term key is
	# agreed between one peripheral and one radio, and the
	# peripheral stores this side's identity address with it, so a
	# bond made on one radio is not a bond on another.
	#
	if(b.local != nil)
		s += " on " + b.local;
	return s;
}

parse(s: string): ref Bond
{
	(n, f) := sys->tokenize(s, " \t\n");
	if(n < 2)
		return nil;
	b := ref Bond;
	b.addr = hd f;
	f = tl f;
	case hd f {
	"public" =>	b.atype = Bt->Apublic;
	"random" =>	b.atype = Bt->Arandom;
	* =>		b.atype = Bt->Apublic;
	}
	f = tl f;
	while(f != nil){
		k := hd f;
		f = tl f;
		if(f == nil)
			break;
		v := hd f;
		f = tl f;
		case k {
		"ltk" =>	b.ltk = bt->unhex(v);
		"ediv" =>	b.ediv = int v;
		"rand" =>	b.rand = bt->unhex(v);
		"irk" =>	b.irk = bt->unhex(v);
		"csrk" =>	b.csrk = bt->unhex(v);
		"on" =>		b.local = v;
		}
	}
	return b;
}

#
# pair over a connection this side made
#
pair(c: ref Conn, m: ref Mux, iocap: int): (ref Bond, string)
{
	ch := l2cap->open(m, L2cap->Csmp);

	# what we ask for and what we offer.  No man in the middle
	# protection is claimed, because Just Works gives none.
	preq := array[7] of byte;
	preq[0] = byte Preq;
	preq[1] = byte iocap;
	preq[2] = byte 0;			# no out of band data
	preq[3] = byte Abonding;		# bond, legacy, no MITM
	preq[4] = byte 16;			# maximum key size
	preq[5] = byte 0;			# we distribute nothing
	preq[6] = byte (Kenc|Kid|Ksign);	# we want its keys

	if((e := l2cap->send(m, L2cap->Csmp, preq)) != nil)
		return (nil, e);
	(pres, e2) := await(ch, Presp);
	if(e2 != nil)
		return (nil, e2);
	if(len pres < 7)
		return (nil, "short pairing response");
	if(int pres[3] & Asc)
		return (nil, "the device wants LE Secure Connections, which this stack does not do");
	respkeys := int pres[6];

	# the temporary key of Just Works is zero
	tk := array[16] of byte;
	for(i := 0; i < 16; i++)
		tk[i] = byte 0;

	(mrand, e3) := random16(c.x);
	if(e3 != nil)
		return (nil, e3);

	ia := hci->localaddr(c.x);
	iat := Bt->Apublic;
	ra := c.addr;
	rat := c.atype;

	mconfirm := c1(tk, mrand, preq, pres, iat, rat, ia, ra);
	cf := array[17] of byte;
	cf[0] = byte Pconfirm;
	cf[1:] = mconfirm;
	if((e6 := l2cap->send(m, L2cap->Csmp, cf)) != nil)
		return (nil, e6);

	(sc, e4) := await(ch, Pconfirm);
	if(e4 != nil)
		return (nil, e4);
	if(len sc < 17)
		return (nil, "short pairing confirm");
	sconfirm := sc[1:17];

	rf := array[17] of byte;
	rf[0] = byte Prandom;
	rf[1:] = mrand;
	if((e7 := l2cap->send(m, L2cap->Csmp, rf)) != nil)
		return (nil, e7);

	(sr, e5) := await(ch, Prandom);
	if(e5 != nil)
		return (nil, e5);
	if(len sr < 17)
		return (nil, "short pairing random");
	srand := sr[1:17];

	# the peer committed to its random before seeing ours; check it
	want := c1(tk, srand, preq, pres, iat, rat, ia, ra);
	if(!same(want, sconfirm))
		return (nil, "pairing confirm does not match: the peer is not who it said");

	stk := s1(tk, srand, mrand);

	zero := array[8] of byte;
	for(i = 0; i < 8; i++)
		zero[i] = byte 0;
	if((e8 := hci->lestartencrypt(c, zero, 0, stk)) != nil)
		return (nil, "start encryption: " + e8);

	for(i = 0; i < Encwait/100 && !c.encrypted; i++)
		sys->sleep(100);
	if(!c.encrypted)
		return (nil, "the link did not become encrypted");

	# the peer now distributes what it said it would, in whatever
	# order it likes, and then stops
	b := ref Bond;
	b.addr = bt->addrstr(c.addr);
	b.local = bt->addrstr(hci->localaddr(c.x));
	b.atype = c.atype;
	nwant := 0;
	if(respkeys & Kenc)
		nwant += 2;		# the key, then its identifier
	if(respkeys & Kid)
		nwant += 2;		# the identity key, then the address
	if(respkeys & Ksign)
		nwant += 1;
	for(i = 0; i < nwant; i++){
		(p, ke) := awaitany(ch);
		if(ke != nil)
			break;		# a peer that stops early has given what it has
		if(len p < 1)
			continue;
		case int p[0] {
		Penckey =>
			if(len p >= 17){
				b.ltk = array[16] of byte;
				b.ltk[0:] = p[1:17];
			}
		Pmasterid =>
			if(len p >= 11){
				b.ediv = bt->get16(p, 1);
				b.rand = array[8] of byte;
				b.rand[0:] = p[3:11];
			}
		Pidkey =>
			if(len p >= 17){
				b.irk = array[16] of byte;
				b.irk[0:] = p[1:17];
			}
		Pidaddr =>
			if(len p >= 8){
				b.atype = int p[1];
				b.addr = bt->addrstr(p[2:8]);
			}
		Psignkey =>
			if(len p >= 17){
				b.csrk = array[16] of byte;
				b.csrk[0:] = p[1:17];
			}
		Pfailed =>
			return (nil, failstr(p));
		}
	}
	if(b.ltk == nil){
		# no long term key: the link is encrypted with the
		# short term key for as long as it lasts, and there is
		# nothing to remember
		b.ltk = stk;
		b.ediv = 0;
		b.rand = zero;
	}
	return (b, nil);
}

#
# wait for one particular SMP command; a pairing failure is an
# answer to anything
#
await(ch: chan of array of byte, want: int): (array of byte, string)
{
	for(;;){
		(p, e) := awaitany(ch);
		if(e != nil)
			return (nil, e);
		if(len p < 1)
			continue;
		if(int p[0] == Pfailed)
			return (nil, failstr(p));
		if(int p[0] == want)
			return (p, nil);
		# anything else at this point is out of order
	}
}

awaitany(ch: chan of array of byte): (array of byte, string)
{
	tick := chan[1] of int;
	spawn timer(Timeout, tick);
	alt {
	p := <-ch =>
		if(p == nil)
			return (nil, "the link closed during pairing");
		return (p, nil);
	<-tick =>
		return (nil, "pairing timed out");
	}
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

failstr(p: array of byte): string
{
	r := 0;
	if(len p >= 2)
		r = int p[1];
	case r {
	16r01 =>	return "pairing failed: passkey entry failed";
	16r02 =>	return "pairing failed: out of band data not available";
	16r03 =>	return "pairing failed: authentication requirements cannot be met";
	16r04 =>	return "pairing failed: confirm value failed";
	16r05 =>	return "pairing failed: pairing not supported";
	16r06 =>	return "pairing failed: encryption key size";
	16r07 =>	return "pairing failed: command not supported";
	16r08 =>	return "pairing failed: unspecified reason";
	16r09 =>	return "pairing failed: repeated attempts";
	16r0a =>	return "pairing failed: invalid parameters";
	}
	return sys->sprint("pairing failed: reason %#2.2ux", r);
}

random16(x: ref Hci->Ctlr): (array of byte, string)
{
	(a, e) := hci->lerand(x);
	if(e != nil)
		return (nil, e);
	(b, e2) := hci->lerand(x);
	if(e2 != nil)
		return (nil, e2);
	r := array[16] of byte;
	r[0:] = a;
	r[8:] = b;
	return (r, nil);
}

#
# e(k, m): AES-128 of one block.  Bluetooth writes both arguments
# least significant byte first and AES takes them most significant
# byte first, so both are reversed going in and the answer is
# reversed coming out.  A fresh key schedule per block with a zero
# initialisation vector is ECB of that block.
#
e(k, m: array of byte): array of byte
{
	kb := reverse(k);
	b := reverse(m);
	st := crypt->aessetup(kb, nil);
	crypt->aescbc(st, b, 16, Crypt->Encrypt);
	return reverse(b);
}

#
# ah(k, r): the random address hash.  r is the three random bytes a
# peripheral chose; r' is r padded to a block with zeros, and the
# hash is e(k, r') taken modulo 2^24 -- its low three bytes, which
# is to say the first three, because everything here is least
# significant byte first.
#
# Checked against a published vector rather than only against our own
# controller model, since the model and this are written in the same
# place and a shared byte-order mistake would agree with itself.  The
# vector is bluez unit/test-crypto.c's test_sih:
#
#	k    cdcc72dd868ccdce22fda121097d7d45
#	r    63f569
#	ah   da4819
#
# all three in Bluetooth order.  btbench runs it before it does
# anything else.
#
ah(k, r: array of byte): array of byte
{
	if(len k != 16 || len r != 3)
		return nil;
	rp := array[16] of byte;
	rp[0:] = r;
	for(i := 3; i < 16; i++)
		rp[i] = byte 0;
	return e(k, rp)[0:3];
}

#
# does this bond's identity resolving key account for this address?
# The top three bytes of a resolvable private address are the random
# the peripheral chose, the bottom three the hash it computed over
# them; recomputing the hash with the key the peer distributed is the
# whole of recognising it.
#
resolve(b: ref Bond, atype: int, addr: array of byte): int
{
	if(b == nil || b.irk == nil || len b.irk != 16)
		return 0;
	if(!bt->resolvable(atype, addr))
		return 0;
	h := ah(b.irk, addr[3:6]);
	if(h == nil)
		return 0;
	return same(h, addr[0:3]);
}

reverse(a: array of byte): array of byte
{
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[len a - 1 - i];
	return r;
}

xor(a, b: array of byte): array of byte
{
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[i] ^ b[i];
	return r;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int (a[i] ^ b[i]);
	return d == 0;
}

#
# c1(k, r, preq, pres, iat, rat, ia, ra), the commitment both sides
# compute over the whole exchange so far, so neither can choose its
# random number after seeing the other's
#
c1(k, r, preq, pres: array of byte, iat, rat: int, ia, ra: array of byte): array of byte
{
	p1 := array[16] of byte;
	p1[0] = byte iat;
	p1[1] = byte rat;
	p1[2:] = preq[0:7];
	p1[9:] = pres[0:7];

	p2 := array[16] of byte;
	p2[0:] = ra[0:6];
	p2[6:] = ia[0:6];
	for(i := 12; i < 16; i++)
		p2[i] = byte 0;

	return e(k, xor(e(k, xor(r, p1)), p2));
}

#
# s1(k, r1, r2): the short term key, the low halves of the two
# random numbers encrypted under the temporary key
#
s1(k, r1, r2: array of byte): array of byte
{
	r := array[16] of byte;
	r[0:] = r2[0:8];
	r[8:] = r1[0:8];
	return e(k, r);
}

#
# The responder: a peer has connected to us and asked to pair.
#
# The same state machine as pair() with the two sides exchanged, and
# the differences are worth naming because they are where a
# transliteration goes wrong.  The initiator commits first, so here the
# peer's confirm arrives before ours goes out, and ours is computed
# from our own random which the peer has not seen.  c1() takes the
# initiator's address and then the responder's, in that order, whoever
# is calling it -- so the arguments that were "us, them" in pair() are
# "them, us" here.  And the confirm to check is the peer's, against the
# random it sends afterwards.
#
# Then the peer starts encryption and the controller asks us for the
# key, which is the one thing a peripheral does that a central never
# does.
#
respond(c: ref Conn, m: ref Mux, known: ref Bond): (ref Bond, string)
{
	ch := l2cap->open(m, L2cap->Csmp);
	#
	# Two things can arrive first.  A peer that has never been here
	# asks to pair.  A peer that has been here starts encryption
	# straight away, and what arrives is the controller asking for
	# the key it named -- which is the bond, and answering it is the
	# whole point of having kept one.
	#
	preq: array of byte;
	e0: string;
	for(;;){
		alt {
		p := <-ch =>
			if(p == nil)
				return (nil, "the link went away");
			if(len p >= 1 && int p[0] == Preq){
				preq = p;
				break;
			}
			# anything else before pairing has begun is
			# nothing this side asked for
			continue;
		(rand, ediv) := <-c.ltkreq =>
			if(known != nil && known.ltk != nil && ediv == known.ediv
			&& same(rand, known.rand)){
				if((ke := hci->leltkreply(c, known.ltk)) != nil)
					sys->fprint(sys->fildes(2),
						"smp: answering a key request: %s\n", ke);
			}else{
				#
				# a key we do not have.  Say so, rather
				# than leaving the peer waiting: a
				# negative reply is what tells it to
				# pair again.
				#
				hci->leltknegreply(c);
			}
			continue;
		}
		break;
	}
	if(e0 != nil)
		return (nil, e0);
	if(len preq < 7)
		return (nil, "short pairing request");
	if(int preq[3] & Asc){
		fail(m, 16r05);		# pairing not supported
		return (nil, "the peer wants LE Secure Connections, which this stack does not do");
	}

	#
	# What we will distribute: a long term key and the numbers that
	# name it, so the peer can come back without pairing again.  We
	# ask for nothing: this side does not resolve a central's
	# private address and has nothing to do with its keys.
	#
	pres := array[7] of byte;
	pres[0] = byte Presp;
	pres[1] = byte Ionoio;
	pres[2] = byte 0;			# no out of band data
	pres[3] = byte Abonding;
	pres[4] = byte 16;
	pres[5] = byte Kenc;			# we distribute the key
	pres[6] = byte 0;			# and want none of theirs
	if((e := l2cap->send(m, L2cap->Csmp, pres)) != nil)
		return (nil, e);

	tk := array[16] of byte;
	for(i := 0; i < 16; i++)
		tk[i] = byte 0;

	(srand, e1) := random16(c.x);
	if(e1 != nil)
		return (nil, e1);

	# the initiator is the peer; the responder is us
	ia := c.addr;
	iat := c.atype;
	ra := hci->localaddr(c.x);
	rat := Bt->Apublic;

	(mc, e2) := await(ch, Pconfirm);
	if(e2 != nil)
		return (nil, e2);
	if(len mc < 17)
		return (nil, "short pairing confirm");
	mconfirm := mc[1:17];

	sconfirm := c1(tk, srand, preq, pres, iat, rat, ia, ra);
	cf := array[17] of byte;
	cf[0] = byte Pconfirm;
	cf[1:] = sconfirm;
	if((e3 := l2cap->send(m, L2cap->Csmp, cf)) != nil)
		return (nil, e3);

	(mr, e4) := await(ch, Prandom);
	if(e4 != nil)
		return (nil, e4);
	if(len mr < 17)
		return (nil, "short pairing random");
	mrand := mr[1:17];

	# the peer committed before it had seen ours; check it did not
	# choose its random afterwards
	want := c1(tk, mrand, preq, pres, iat, rat, ia, ra);
	if(!same(want, mconfirm)){
		fail(m, 16r04);		# confirm value failed
		return (nil, "pairing confirm does not match: the peer is not who it said");
	}

	rf := array[17] of byte;
	rf[0] = byte Prandom;
	rf[1:] = srand;
	if((e5 := l2cap->send(m, L2cap->Csmp, rf)) != nil)
		return (nil, e5);

	stk := s1(tk, srand, mrand);

	#
	# The peer now starts encryption with the short term key and
	# the controller asks us for it.  Nothing above can carry on
	# until that is answered: an unanswered key request is a link
	# that never becomes encrypted and a peer that waits for one.
	#
	tick := chan[1] of int;
	spawn timer(Encwait, tick);
	alt {
	(nil, nil) := <-c.ltkreq =>
		if((e6 := hci->leltkreply(c, stk)) != nil)
			return (nil, "answering the key request: " + e6);
	<-tick =>
		return (nil, "the peer never asked for the key");
	}

	for(i = 0; i < Encwait/100 && !c.encrypted; i++)
		sys->sleep(100);
	if(!c.encrypted)
		return (nil, "the link did not become encrypted");

	#
	# and now our keys, so the peer can come back.  The long term
	# key is ours to choose; the diversifier and random name it, and
	# a later key request carrying them is how we know which one is
	# wanted.
	#
	(ltk, e7) := random16(c.x);
	if(e7 != nil)
		return (nil, e7);
	(rnd, e8) := hci->lerand(c.x);
	if(e8 != nil)
		return (nil, e8);
	ediv := (int rnd[0] | (int rnd[1] << 8)) & 16rffff;

	ek := array[17] of byte;
	ek[0] = byte Penckey;
	ek[1:] = ltk;
	if((e9 := l2cap->send(m, L2cap->Csmp, ek)) != nil)
		return (nil, e9);
	mi := array[11] of byte;
	mi[0] = byte Pmasterid;
	bt->put16(mi, 1, ediv);
	mi[3:] = rnd;
	if((e10 := l2cap->send(m, L2cap->Csmp, mi)) != nil)
		return (nil, e10);

	b := ref Bond;
	b.addr = bt->addrstr(c.addr);
	b.local = bt->addrstr(hci->localaddr(c.x));
	b.atype = c.atype;
	b.ltk = ltk;
	b.ediv = ediv;
	b.rand = rnd;
	return (b, nil);
}

#
# tell the peer why, rather than going quiet.  A peer that gets no
# answer waits out its own thirty second timeout and learns nothing.
#
fail(m: ref Mux, reason: int)
{
	p := array[2] of byte;
	p[0] = byte Pfailed;
	p[1] = byte reason;
	l2cap->send(m, L2cap->Csmp, p);
}
