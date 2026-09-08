implement L2cap;

#
# L2CAP.  On an LE link this is length and CID framing and nothing
# else: the channels that matter are fixed -- 4 for ATT, 5 for LE
# signalling, 6 for security management -- so there is no channel
# establishment to do.  What there is: demultiplex a frame to the
# process that asked for that CID, and answer the signalling
# commands a peripheral sends, of which the one that actually
# arrives is the request to change the connection parameters.
#
# The demultiplexer must never block on a consumer, or the HCI
# reader behind it stops and the whole controller goes quiet.  Each
# CID's queue is therefore buffered, and a frame for a CID nobody
# opened is dropped.
#
# On 9front this is one C file: a proc per link and a Queue per CID.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	hci: Hci;
	Conn: import Hci;

Qdepth:	con 8;

# LE signalling command codes
Creject:	con 16r01;
# BR/EDR signalling, which is a different set of codes on a different
# CID from the LE ones below
Cbconnreq:	con 16r02;
Cbconnresp:	con 16r03;
Cconfreq:	con 16r04;
Cconfresp:	con 16r05;
Cinforeq:	con 16r0a;
Cinforesp:	con 16r0b;
Cdiscreq:	con 16r06;
Cdiscresp:	con 16r07;
Cparamreq:	con 16r12;
Cparamresp:	con 16r13;
Cconnreq:	con 16r14;
Cconnresp:	con 16r15;
Ccredit:	con 16r16;

# the CIDs a dynamically allocated LE channel may take
Cdynlo:	con 16r0040;
Cdynhi:	con 16r007f;

# The response timer.  The specification allows a signalling request
# to wait between one and sixty seconds for its answer; ten is far
# longer than a link that is working takes and short enough that a
# link that is not does not hold a program up for a minute.
Rtx:	con 10000;

# The largest SDU we will take.  A reader has to offer a buffer this
# big to be sure of not truncating, and btfs(4) says so.
Cmtu:	con 512;

# Credits are per PDU and the reader consumes whole SDUs, so the
# credits outstanding have to cover a whole SDU or a peer sending one
# could never finish it: nothing would be handed to the reader, so no
# credit would come back.  Twice that leaves a second SDU in flight
# while the first is being read.
Cslack:	con 2;

init(b: Bt, h: Hci): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	hci = h;
	return nil;
}

start(c: ref Conn): ref Mux
{
	m := ref Mux;
	m.c = c;
	#
	# Which signalling channel this link has, and what a channel on
	# it may carry before anything is negotiated: 23 bytes on LE,
	# 672 on BR/EDR, both of them the specification's own defaults.
	#
	m.sig = Cle;
	m.psms = nil;
	m.mtu = 23;
	if(c.classic){
		m.sig = Cbredr;
		m.mtu = 672;
	}
	m.chans = nil;
	m.nextid = 1;
	m.pend = nil;
	m.reply = chan[1] of int;
	m.reply <-= 1;
	spawn demux(m);
	return m;
}

open(m: ref Mux, cid: int): chan of array of byte
{
	<-m.reply;
	c := lookup(m, cid);
	if(c == nil){
		c = ref Chan;
		#
		# The credit fields too, though a fixed channel never
		# reads them: a ref adt's integer fields are whatever was
		# in the heap, and a channel whose dcid or credit count
		# is garbage is a channel that looks open to anything
		# that walks the list.
		#
		c.cid = cid;
		c.state = Sfixed;
		c.basic = 0;
		c.confin = 0;
		c.rq = chan[Qdepth] of array of byte;
		c.dcid = 0;
		c.psm = 0;
		c.mtu = 0;
		c.mps = 0;
		c.dmtu = 0;
		c.dmps = 0;
		c.rxcred = 0;
		c.txcred = 0;
		c.have = 0;
		c.pdus = 0;
		c.sdu = nil;
		c.err = nil;
		m.chans = c :: m.chans;
	}
	m.reply <-= 1;
	return c.rq;
}

#
# lookup runs with the mux lock already held; find takes it.  Keeping
# the two apart is what lets the demultiplexer hold the lock across a
# lookup and the work that follows from it.
#
lookup(m: ref Mux, cid: int): ref Chan
{
	for(l := m.chans; l != nil; l = tl l)
		if((hd l).cid == cid)
			return hd l;
	return nil;
}

find(m: ref Mux, cid: int): ref Chan
{
	<-m.reply;
	c := lookup(m, cid);
	m.reply <-= 1;
	return c;
}

send(m: ref Mux, cid: int, p: array of byte): string
{
	f := array[4 + len p] of byte;
	bt->put16(f, 0, len p);
	bt->put16(f, 2, cid);
	f[4:] = p;
	return hci->acl(m.c, f);
}

stop(m: ref Mux)
{
	<-m.reply;
	l := m.chans;
	m.chans = nil;
	pend := m.pend;
	m.pend = nil;
	for(cl := l; cl != nil; cl = tl cl){
		c := hd cl;
		if(c.state != Sfixed){
			c.state = Sdown;
			if(c.err == nil)
				c.err = "the link went away";
		}
	}
	m.reply <-= 1;
	for(; l != nil; l = tl l){
		c := hd l;
		if(c.state == Sfixed){
			alt {
			c.rq <-= nil =>	;
			* =>	;
			}
		} else
			poke(c);
	}
	#
	# anyone waiting for an answer to a signalling request will
	# never get one now.
	#
	for(; pend != nil; pend = tl pend){
		(nil, nil, rc) := hd pend;
		alt {
		rc <-= nil =>	;
		* =>	;
		}
	}
}

demux(m: ref Mux)
{
	for(;;){
		alt {
		f := <-m.c.up =>
			if(f == nil)
				continue;
			if(len f < 4)
				continue;
			dlen := bt->get16(f, 0);
			cid := bt->get16(f, 2);
			if(len f < 4 + dlen)
				continue;
			p := f[4:4+dlen];
			if(cid == m.sig){
				signal(m, p);
				continue;
			}
			<-m.reply;
			c := lookup(m, cid);
			if(c == nil){
				m.reply <-= 1;
				continue;	# nobody opened that channel
			}
			if(c.state != Sfixed && !c.basic){
				#
				# a credit-based channel: absorb the
				# segment under the lock, because the
				# credit accounting and the reassembly
				# buffer are what the lock is for.  Never
				# blocks: the queue is as deep as the
				# credits granted, and a segment cannot
				# arrive without one.
				#
				kframe(m, c, p);
				m.reply <-= 1;
				continue;
			}
			if(c.basic){
				#
				# a basic mode channel: one frame is one
				# SDU whole, there is nothing to
				# reassemble and no credit to account
				# for.  It goes on the same queue a
				# credit-based channel's SDUs go on, so
				# that crecv reads both the same way; the
				# PDU count is 0, which is what stops
				# crecv giving back a credit for it.
				#
				alt {
				c.sq <-= ref Sdu(p, 0) =>	;
				* =>	;	# the reader is behind: drop
				}
				m.reply <-= 1;
				poke(c);
				continue;
			}
			m.reply <-= 1;
			alt {
			c.rq <-= p =>	;
			* =>	;		# the consumer is behind: drop
			}
		why := <-m.c.closed =>
			if(why == nil)
				why = "disconnected";
			#
			# Put it back.  The reason is a broadcast with
			# one token in it, and the process watching the
			# device is waiting on the same channel; taking
			# it and keeping it left that process asleep on
			# a link that had gone, and the name space
			# saying the device was still connected.
			#
			alt {
			m.c.closed <-= why =>	;
			* =>	;
			}
			stop(m);
			return;
		}
	}
}

#
# LE signalling.  A peripheral asks the central to change the
# connection parameters, and accepting is not a courtesy: a peripheral
# cannot change them itself, so the central that says yes is
# undertaking to perform the update.  This used to answer yes to
# anything and then do nothing, which is the one answer that is worse
# than no -- the peripheral believes the link is running at what it
# asked for and adjusts its behaviour to match.
#
# So the parameters are checked, a request outside what a controller
# will take is refused, and an accepted one is carried out.  Anything
# that is not a parameter request gets a command reject saying the
# command is not understood.
#
doupdate(c: ref Hci->Conn, min, max, latency, timeout: int)
{
	if((e := hci->leconnupdate(c, min, max, latency, timeout)) != nil)
		sys->fprint(sys->fildes(2),
			"l2cap: accepted a parameter update and could not do it: %s\n", e);
}

signal(m: ref Mux, p: array of byte)
{
	if(len p < 4)
		return;
	code := int p[0];
	id := int p[1];
	dlen := bt->get16(p, 2);
	if(len p < 4 + dlen)
		return;
	case code {
	Cparamreq =>
		result := 0;		# accepted
		min := 0;
		max := 0;
		latency := 0;
		timeout := 0;
		if(dlen < 8)
			result = 1;	# rejected
		else {
			min = bt->get16(p, 4);
			max = bt->get16(p, 6);
			latency = bt->get16(p, 8);
			timeout = bt->get16(p, 10);
			if((e := hci->paramsok(min, max, latency, timeout)) != nil){
				sys->fprint(sys->fildes(2),
					"l2cap: refusing %d-%d latency %d timeout %d: %s\n",
					min, max, latency, timeout, e);
				result = 1;
			}
		}
		r := array[6] of byte;
		r[0] = byte Cparamresp;
		r[1] = byte id;
		bt->put16(r, 2, 2);
		bt->put16(r, 4, result);
		send(m, m.sig, r);
		#
		# after the answer, not before: the peer is entitled to
		# see the response before the link changes under it.
		#
		if(result == 0)
			spawn doupdate(m.c, min, max, latency, timeout);
	Cparamresp =>
		;
	Cconnresp or Cdiscresp or Cbconnresp or Cconfresp =>
		#
		# the answer to a request some other process is waiting
		# for.  Handing it over rather than acting on it here is
		# what lets connect and cclose read their own result.
		#
		answer(m, id, code, p[4:4+dlen]);
	Cbconnreq =>
		#
		# A peer opening a BR/EDR channel to us.  If something
		# is listening on that PSM it gets a channel; if not it
		# is refused with the reason that is true -- the PSM is
		# not supported -- rather than left to time out.
		#
		if(dlen < 4)
			return;
		psm := bt->get16(p, 4);
		scid := bt->get16(p, 6);
		<-m.reply;
		lc := listener(m, psm);
		cid := 0;
		c: ref Chan;
		if(lc != nil){
			cid = newcid(m);
			if(cid != 0)
				c = newbasic(m, psm, cid, scid);
		}
		m.reply <-= 1;
		res := 2;			# PSM not supported
		if(lc != nil && c == nil)
			res = 4;		# no resources
		if(c != nil)
			res = 0;
		r := array[12] of byte;
		r[0] = byte Cbconnresp;
		r[1] = byte id;
		bt->put16(r, 2, 8);
		bt->put16(r, 4, cid);
		bt->put16(r, 6, scid);
		bt->put16(r, 8, res);
		bt->put16(r, 10, 0);
		spawn later(m, r);
		if(c != nil)
			spawn accepted(m, c, lc);
	Cconfreq =>
		config(m, id, p[4:4+dlen]);
	Cinforeq =>
		#
		# What this side can do beyond basic mode: nothing, and
		# a zero feature mask says exactly that.  Anything else
		# it asks about is answered "not supported", which is a
		# legal answer and the true one.
		#
		if(dlen < 2)
			return;
		ty := bt->get16(p, 4);
		if(ty == 2){
			r := array[12] of byte;
			r[0] = byte Cinforesp;
			r[1] = byte id;
			bt->put16(r, 2, 8);
			bt->put16(r, 4, ty);
			bt->put16(r, 6, 0);	# success
			bt->put16(r, 8, 0);	# no extended features
			bt->put16(r, 10, 0);
			spawn later(m, r);
		} else {
			r := array[8] of byte;
			r[0] = byte Cinforesp;
			r[1] = byte id;
			bt->put16(r, 2, 4);
			bt->put16(r, 4, ty);
			bt->put16(r, 6, 1);	# not supported
			spawn later(m, r);
		}
	Cinforesp =>
		;
	Ccredit =>
		if(dlen < 4)
			return;
		cid := bt->get16(p, 4);
		n := bt->get16(p, 6);
		<-m.reply;
		c := bydcid(m, cid);
		if(c == nil || c.state != Sup){
			m.reply <-= 1;
			return;
		}
		if(n == 0 || c.txcred + n > 16rffff){
			fail(m, c, sys->sprint("%d credits on top of %d, which is more than a channel can hold", n, c.txcred));
			m.reply <-= 1;
			return;
		}
		c.txcred += n;
		m.reply <-= 1;
		poke(c);
	Cdiscreq =>
		if(dlen < 4)
			return;
		dcid := bt->get16(p, 4);	# ours, from where the peer sits
		scid := bt->get16(p, 6);
		<-m.reply;
		c := lookup(m, dcid);
		if(c != nil && c.state != Sfixed){
			c.state = Sdown;
			c.err = "the peer closed the channel";
			c.sdu = nil;
			unchan(m, c);
		} else
			c = nil;
		m.reply <-= 1;
		if(c != nil)
			poke(c);
		r := array[8] of byte;
		r[0] = byte Cdiscresp;
		r[1] = byte id;
		bt->put16(r, 2, 4);
		bt->put16(r, 4, dcid);
		bt->put16(r, 6, scid);
		send(m, m.sig, r);
	* =>
		r := array[6] of byte;
		r[0] = byte Creject;
		r[1] = byte id;
		bt->put16(r, 2, 2);
		bt->put16(r, 4, 0);	# command not understood
		send(m, m.sig, r);
	}
}

#
# BR/EDR L2CAP: basic mode.
#
# The shape is not the LE one.  A channel is asked for by PSM and
# answered with a CID, as on LE, but the sizes are not in that answer:
# both sides then send a Configuration Request and answer the other's,
# and the channel is open only when both have been answered.  There
# are no credits and no segmentation -- one frame is one SDU, up to
# the MTU the other side asked for -- so the flow control is the
# link's and not L2CAP's.
#
Bmtu:		con 672;	# what this side will take, the default
Omtu:		con 16r01;	# the MTU configuration option

#
# What a peer's Configuration Request says, answered here rather than
# in whoever asked for the channel: it may arrive before this side has
# sent its own, and a request that goes unanswered is a channel that
# never opens.
#
config(m: ref Mux, id: int, p: array of byte)
{
	if(len p < 4)
		return;
	dcid := bt->get16(p, 0);	# ours, from where the peer sits
	flags := bt->get16(p, 2);
	mtu := 0;
	for(o := 4; o + 2 <= len p; ){
		ty := int p[o] & 16r7f;
		l := int p[o+1];
		if(o + 2 + l > len p)
			break;
		if(ty == Omtu && l == 2)
			mtu = bt->get16(p, o+2);
		o += 2 + l;
	}
	<-m.reply;
	c := lookup(m, dcid);
	if(c != nil && c.basic){
		#
		# the largest frame this side may send.  A peer that
		# names none is asking for the default, which is what it
		# already has.
		#
		if(mtu >= 48)
			c.dmtu = mtu;
		#
		# The continuation flag says more options are coming in
		# another request, so the configuration is not done
		# until one arrives without it.
		#
		if((flags & 1) == 0)
			c.confin = 1;
	} else
		c = nil;
	m.reply <-= 1;

	r := array[10] of byte;
	r[0] = byte Cconfresp;
	r[1] = byte id;
	bt->put16(r, 2, 6);
	bt->put16(r, 4, dcid);
	bt->put16(r, 6, flags & 1);
	if(c == nil)
		bt->put16(r, 8, 2);	# rejected: no such channel
	else
		bt->put16(r, 8, 0);	# success, and no options of our own
	#
	# From a process of its own, for the reason fail() gives:
	# sending takes an ACL buffer, which may not be there, and this
	# runs in the demultiplexer.  A demultiplexer waiting for a
	# buffer is a demultiplexer not reading the answer that would
	# free one, which is a link that stops -- and that is exactly
	# what happened here the first time.
	#
	spawn later(m, r);
	if(c != nil)
		poke(c);
}

later(m: ref Mux, p: array of byte)
{
	send(m, m.sig, p);
}

#
# Say this side will answer on a PSM.  What comes back is where the
# channels arrive; a second listen on the same PSM is the first one's
# channel rather than a second one, because two owners of a PSM is a
# channel handed to whichever happened to be reading.
#
listen(m: ref Mux, psm: int): chan of ref Chan
{
	<-m.reply;
	c := listener(m, psm);
	if(c == nil){
		#
		# Buffered: a peer connects when it feels like it and
		# not when something here is reading, and a channel that
		# does not fit is closed rather than dropped, because a
		# channel nobody owns stays open on the peer for ever.
		#
		c = chan[4] of ref Chan;
		m.psms = (psm, c) :: m.psms;
	}
	m.reply <-= 1;
	return c;
}

# with the lock held
listener(m: ref Mux, psm: int): chan of ref Chan
{
	for(l := m.psms; l != nil; l = tl l){
		(p, c) := hd l;
		if(p == psm)
			return c;
	}
	return nil;
}

# with the lock held: a basic mode channel this side did not ask for
newbasic(m: ref Mux, psm, cid, dcid: int): ref Chan
{
	c := ref Chan;
	c.cid = cid;
	c.state = Swait;
	c.basic = 1;
	c.confin = 0;
	c.psm = psm;
	c.dcid = dcid;
	c.mtu = Bmtu;
	c.mps = 0;
	c.dmtu = m.mtu;
	c.dmps = 0;
	c.rxcred = 0;
	c.txcred = 0;
	c.have = 0;
	c.pdus = 0;
	c.sdu = nil;
	c.err = nil;
	c.sq = chan[Qdepth] of ref Sdu;
	c.wake = chan[1] of int;
	c.rwake = chan[1] of int;
	c.rq = chan[1] of array of byte;
	m.chans = c :: m.chans;
	return c;
}

#
# A channel a peer opened, once the connection response has gone.  The
# configuration is the same exchange either way round -- both sides
# ask and both answer -- so this is bconnect's second half with the
# first half already done by the peer.
#
accepted(m: ref Mux, c: ref Chan, lc: chan of ref Chan)
{
	#
	# A configuration that does not finish is not a channel, and
	# there is nobody to tell: whoever would have taken it does not
	# know it exists yet.  So it goes, and the peer sees the
	# disconnection abandon sends.
	#
	if(configure(m, c) != nil){
		abandon(m, c, 0);
		return;
	}
	<-m.reply;
	c.state = Sup;
	m.reply <-= 1;
	alt {
	lc <-= c =>	;
	* =>
		# nothing is listening any more, and a channel nobody
		# owns is worse than one that was never opened
		cclose(m, c);
	}
}

#
# Open a BR/EDR channel.  Connection request, then configuration in
# both directions, and only then is it a channel.
#
bconnect(m: ref Mux, psm: int): (ref Chan, string)
{
	if(m.sig != Cbredr)
		return (nil, "not a BR/EDR link");
	<-m.reply;
	cid := newcid(m);
	if(cid == 0){
		m.reply <-= 1;
		return (nil, "no free channel identifier on this link");
	}
	c := ref Chan;
	c.cid = cid;
	c.state = Swait;
	c.basic = 1;
	c.confin = 0;
	c.psm = psm;
	c.dcid = 0;
	c.mtu = Bmtu;
	c.mps = 0;
	c.dmtu = m.mtu;		# until the peer asks for something else
	c.dmps = 0;
	c.rxcred = 0;
	c.txcred = 0;
	c.have = 0;
	c.pdus = 0;
	c.sdu = nil;
	c.err = nil;
	c.sq = chan[Qdepth] of ref Sdu;
	c.wake = chan[1] of int;
	c.rwake = chan[1] of int;
	c.rq = chan[1] of array of byte;
	m.chans = c :: m.chans;
	id := nextid(m);
	rc := chan[1] of array of byte;
	m.pend = (id, Cbconnresp, rc) :: m.pend;
	m.reply <-= 1;

	req := array[8] of byte;
	req[0] = byte Cbconnreq;
	req[1] = byte id;
	bt->put16(req, 2, 4);
	bt->put16(req, 4, psm);
	bt->put16(req, 6, cid);
	if((e := send(m, m.sig, req)) != nil){
		abandon(m, c, id);
		return (nil, e);
	}
	(r, we) := await(m, id, rc);
	if(we != nil){
		abandon(m, c, id);
		return (nil, we);
	}
	if(len r < 8){
		abandon(m, c, 0);
		return (nil, "a connection response of only " + string len r + " bytes");
	}
	#
	# Result 1 is "pending", which is a real answer and not a
	# failure: the peer is asking somebody, and the answer that
	# settles it comes as a second response with the same
	# identifier.  Waiting again is what a pending means.
	#
	res := bt->get16(r, 4);
	if(res == 1){
		<-m.reply;
		rc2 := chan[1] of array of byte;
		m.pend = (id, Cbconnresp, rc2) :: m.pend;
		m.reply <-= 1;
		(r2, we2) := await(m, id, rc2);
		if(we2 != nil){
			abandon(m, c, id);
			return (nil, we2);
		}
		if(len r2 < 8){
			abandon(m, c, 0);
			return (nil, "a connection response of only " + string len r2 + " bytes");
		}
		r = r2;
		res = bt->get16(r, 4);
	}
	if(res != 0){
		abandon(m, c, 0);
		return (nil, bconnerr(res));
	}
	dcid := bt->get16(r, 0);
	if(dcid < Cdynlo){
		abandon(m, c, 0);
		return (nil, sys->sprint("the peer answered with CID %#4.4ux, which is not a dynamic one", dcid));
	}
	<-m.reply;
	c.dcid = dcid;
	m.reply <-= 1;

	if((ce := configure(m, c)) != nil){
		abandon(m, c, 0);
		return (nil, ce);
	}
	<-m.reply;
	c.state = Sup;
	m.reply <-= 1;
	return (c, nil);
}

#
# Both directions.  This side asks for what it will take and waits for
# the answer; the peer's own request is answered by config() above, in
# the demultiplexer, which may already have happened.
#
configure(m: ref Mux, c: ref Chan): string
{
	<-m.reply;
	id := nextid(m);
	rc := chan[1] of array of byte;
	m.pend = (id, Cconfresp, rc) :: m.pend;
	dcid := c.dcid;
	m.reply <-= 1;

	req := array[12] of byte;
	req[0] = byte Cconfreq;
	req[1] = byte id;
	bt->put16(req, 2, 8);
	bt->put16(req, 4, dcid);
	bt->put16(req, 6, 0);		# no continuation
	req[8] = byte Omtu;
	req[9] = byte 2;
	bt->put16(req, 10, Bmtu);
	if((e := send(m, m.sig, req)) != nil){
		unpend(m, id);
		return e;
	}
	(r, we) := await(m, id, rc);
	if(we != nil)
		return we;
	if(len r < 6)
		return "a configuration response of only " + string len r + " bytes";
	res := bt->get16(r, 4);
	if(res != 0)
		return conferr(res);

	#
	# and the peer's own request, which config() answers.  It may
	# have arrived first, in which case there is nothing to wait
	# for.
	#
	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	for(;;){
		<-m.reply;
		done := c.confin;
		st := c.state;
		m.reply <-= 1;
		if(done)
			return nil;
		if(st == Sdown)
			return "the channel went away while it was being configured";
		alt {
		<-c.wake =>	;
		<-tick =>
			return "the peer never asked for its own configuration";
		}
	}
}

#
# wait for one answer, with the retransmission timeout every L2CAP
# request has.  It is one function because four requests want it.
#
await(m: ref Mux, id: int, rc: chan of array of byte): (array of byte, string)
{
	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	r: array of byte;
	alt {
	r = <-rc =>	;
	<-tick =>
		unpend(m, id);
		return (nil, "the peer never answered");
	}
	unpend(m, id);
	if(r == nil)
		return (nil, "the link went away");
	return (r, nil);
}

bconnerr(res: int): string
{
	case res {
	2 =>	return "PSM not supported";
	3 =>	return "security block";
	4 =>	return "no resources";
	}
	return sys->sprint("the peer refused the channel: reason %#4.4ux", res);
}

conferr(res: int): string
{
	case res {
	1 =>	return "the peer will not take those configuration options";
	2 =>	return "the peer rejected the configuration";
	3 =>	return "the peer does not know one of those options";
	4 =>	return "the configuration is still going";
	}
	return sys->sprint("the peer refused the configuration: reason %#4.4ux", res);
}

#
# LE credit-based channels.
#
# A fixed channel needs no setup: everyone agrees what CID 4 is for.
# A credit-based channel is asked for by PSM, answered with a CID and
# a set of limits, and then flow-controlled: the receiver hands out
# credits, one per PDU, and the sender may not send a PDU it has no
# credit for.  That is the whole of it, and it is the only way bulk
# data moves over LE.
#
# Two sizes matter and they are not the same size.  The MTU is the
# largest SDU -- the largest thing a reader gets in one piece.  The
# MPS is the largest PDU -- the largest thing that goes on the link at
# once.  An SDU longer than the MPS is segmented; the first segment
# carries a two byte length, and that length counts toward the MPS,
# which is the detail everyone gets wrong once.
#
# The credits are the reason this can be done without dropping
# anything.  Elsewhere in this file a frame for a consumer that is
# behind is dropped, because the alternative is to stop the HCI reader
# and with it the controller.  Here dropping is not allowed: a
# receiver that has granted N credits has promised to take N PDUs, and
# a dropped segment does not lose one message, it desynchronises the
# reassembly and every message after it is garbage.  So the credits
# granted and the depth of the queue they feed are the same number,
# and the credits for an SDU are given back when the reader takes it.
# The demultiplexer then cannot block and cannot drop.
#

#
# the peer's reasons for refusing, in its own words
#
connerr(res: int): string
{
	case res {
	16r0002 =>	return "PSM not supported";
	16r0004 =>	return "no resources";
	16r0005 =>	return "insufficient authentication";
	16r0006 =>	return "insufficient authorization";
	16r0007 =>	return "encryption key size too short";
	16r0008 =>	return "insufficient encryption";
	16r0009 =>	return "invalid source CID";
	16r000a =>	return "source CID already in use";
	16r000b =>	return "unacceptable parameters";
	}
	return sys->sprint("refused, reason %#4.4ux", res);
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

#
# wake anyone waiting on this channel.  The sender and the receiver
# wait on separate channels: one token would otherwise be taken by
# whichever of them happened to be there, and the other would sleep
# through the thing it was waiting for.
#
poke(c: ref Chan)
{
	alt {
	c.wake <-= 1 =>	;
	* =>	;
	}
	alt {
	c.rwake <-= 1 =>	;
	* =>	;
	}
}

# both with the mux lock held
nextid(m: ref Mux): int
{
	id := m.nextid++;
	if(m.nextid > 255)
		m.nextid = 1;
	return id;
}

newcid(m: ref Mux): int
{
	for(cid := Cdynlo; cid <= Cdynhi; cid++)
		if(lookup(m, cid) == nil)
			return cid;
	return 0;
}

unchan(m: ref Mux, c: ref Chan)
{
	l: list of ref Chan;
	for(cl := m.chans; cl != nil; cl = tl cl)
		if(hd cl != c)
			l = hd cl :: l;
	m.chans = l;
}

unpend(m: ref Mux, id: int)
{
	<-m.reply;
	l: list of (int, int, chan of array of byte);
	for(pl := m.pend; pl != nil; pl = tl pl)
		if((hd pl).t0 != id)
			l = hd pl :: l;
	m.pend = l;
	m.reply <-= 1;
}

#
# The channel is finished and the peer needs telling.  Called with the
# lock held, so the disconnection request goes out from a separate
# process: sending it takes an ACL buffer, which may not be there yet,
# and the demultiplexer must not be the thing that waits for one.
#
fail(m: ref Mux, c: ref Chan, why: string)
{
	c.state = Sdown;
	c.err = why;
	c.sdu = nil;
	unchan(m, c);
	poke(c);
	spawn discon(m, c.cid, c.dcid);
}

discon(m: ref Mux, cid, dcid: int)
{
	<-m.reply;
	id := nextid(m);
	m.reply <-= 1;
	req := array[8] of byte;
	req[0] = byte Cdiscreq;
	req[1] = byte id;
	bt->put16(req, 2, 4);
	bt->put16(req, 4, dcid);
	bt->put16(req, 6, cid);
	send(m, m.sig, req);
}

connect(m: ref Mux, psm: int): (ref Chan, string)
{
	#
	# The MPS is what fits in one ACL packet: four bytes of that go
	# to the L2CAP header.  A controller that will take only the
	# 27 byte minimum therefore gives a 23 byte MPS, which is the
	# specification's own floor, and every SDU worth sending is
	# segmented.  That is the ordinary case on a small controller,
	# not a corner of one.
	#
	(aclsz, nil) := hci->aclmtu(m.c.x);
	mps := aclsz - 4;
	if(mps < 23)
		mps = 23;
	if(mps > Cmtu + 2)
		mps = Cmtu + 2;
	ncred := (Cmtu + 2 + mps - 1) / mps;
	cred := ncred * Cslack;

	<-m.reply;
	cid := newcid(m);
	if(cid == 0){
		m.reply <-= 1;
		return (nil, "no free channel identifier on this link");
	}
	c := ref Chan;
	c.cid = cid;
	c.state = Swait;
	c.basic = 0;
	c.confin = 0;
	c.dcid = 0;
	c.dmtu = 0;
	c.dmps = 0;
	c.txcred = 0;
	c.have = 0;
	c.pdus = 0;
	c.sdu = nil;
	c.err = nil;
	c.psm = psm;
	c.mtu = Cmtu;
	c.mps = mps;
	c.rxcred = cred;
	c.sq = chan[cred] of ref Sdu;
	c.wake = chan[1] of int;
	c.rwake = chan[1] of int;
	c.rq = chan[1] of array of byte;
	m.chans = c :: m.chans;
	id := nextid(m);
	rc := chan[1] of array of byte;
	m.pend = (id, Cconnresp, rc) :: m.pend;
	m.reply <-= 1;

	req := array[14] of byte;
	req[0] = byte Cconnreq;
	req[1] = byte id;
	bt->put16(req, 2, 10);
	bt->put16(req, 4, psm);
	bt->put16(req, 6, cid);
	bt->put16(req, 8, c.mtu);
	bt->put16(req, 10, c.mps);
	bt->put16(req, 12, cred);
	if((e := send(m, m.sig, req)) != nil){
		abandon(m, c, id);
		return (nil, e);
	}

	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	r: array of byte;
	alt {
	r = <-rc =>	;
	<-tick =>
		abandon(m, c, id);
		return (nil, "the peer never answered the connection request");
	}
	unpend(m, id);
	if(r == nil){
		abandon(m, c, 0);
		return (nil, "the link went away");
	}
	if(len r < 10){
		abandon(m, c, 0);
		return (nil, "a connection response of only " + string len r + " bytes");
	}
	res := bt->get16(r, 8);
	if(res != 0){
		abandon(m, c, 0);
		return (nil, connerr(res));
	}
	dcid := bt->get16(r, 0);
	dmtu := bt->get16(r, 2);
	dmps := bt->get16(r, 4);
	if(dcid < Cdynlo || dcid > Cdynhi){
		abandon(m, c, 0);
		return (nil, sys->sprint("the peer answered with CID %#4.4ux, which is not a dynamic one", dcid));
	}
	if(dmtu < 23 || dmps < 23){
		abandon(m, c, 0);
		return (nil, sys->sprint("the peer answered with MTU %d MPS %d, below the smallest allowed", dmtu, dmps));
	}
	<-m.reply;
	c.dcid = dcid;
	c.dmtu = dmtu;
	c.dmps = dmps;
	c.txcred = bt->get16(r, 6);
	c.state = Sup;
	m.reply <-= 1;
	return (c, nil);
}

abandon(m: ref Mux, c: ref Chan, id: int)
{
	<-m.reply;
	c.state = Sdown;
	unchan(m, c);
	m.reply <-= 1;
	if(id != 0)
		unpend(m, id);
	poke(c);
}

cclose(m: ref Mux, c: ref Chan): string
{
	if(c == nil)
		return "no channel";
	<-m.reply;
	if(c.state != Sup){
		m.reply <-= 1;
		return nil;
	}
	c.state = Sdown;
	c.err = "closed here";
	cid := c.cid;
	dcid := c.dcid;
	id := nextid(m);
	rc := chan[1] of array of byte;
	m.pend = (id, Cdiscresp, rc) :: m.pend;
	unchan(m, c);
	m.reply <-= 1;
	poke(c);

	req := array[8] of byte;
	req[0] = byte Cdiscreq;
	req[1] = byte id;
	bt->put16(req, 2, 4);
	bt->put16(req, 4, dcid);
	bt->put16(req, 6, cid);
	if((se := send(m, m.sig, req)) != nil){
		unpend(m, id);
		return se;
	}
	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	e: string;
	alt {
	<-rc =>	e = nil;
	<-tick =>	e = "the peer never answered the disconnection request";
	}
	unpend(m, id);
	return e;
}

#
# one SDU out.  It is segmented at the peer's MPS, a credit is spent
# per segment, and when the peer has given us none this waits rather
# than dropping: the writer of a file is entitled to have its bytes
# arrive.
#
csend(m: ref Mux, c: ref Chan, p: array of byte): string
{
	if(c == nil)
		return "no channel";
	<-m.reply;
	st := c.state;
	e := c.err;
	dmtu := c.dmtu;
	m.reply <-= 1;
	if(st != Sup){
		if(e == nil)
			e = "the channel is not open";
		return e;
	}
	if(len p > dmtu)
		return sys->sprint("an SDU of %d bytes: the peer will take %d", len p, dmtu);

	#
	# A basic mode channel has no credits and no segmentation: one
	# frame is one SDU, and the check above is the whole of the flow
	# control L2CAP does for it.  Everything below is the
	# credit-based path.
	#
	if(c.basic)
		return send(m, c.dcid, p);

	first := 1;
	off := 0;
	for(;;){
		<-m.reply;
		if(c.state != Sup){
			e = c.err;
			m.reply <-= 1;
			if(e == nil)
				e = "the channel closed while sending";
			return e;
		}
		if(c.txcred == 0){
			m.reply <-= 1;
			<-c.wake;
			continue;
		}
		c.txcred--;
		more := c.txcred > 0;
		dcid := c.dcid;
		mps := c.dmps;
		m.reply <-= 1;
		if(more)
			poke(c);

		hdr := 0;
		if(first)
			hdr = 2;
		n := len p - off;
		if(n > mps - hdr)
			n = mps - hdr;
		f := array[hdr + n] of byte;
		if(first)
			bt->put16(f, 0, len p);
		f[hdr:] = p[off:off+n];
		if((se := send(m, dcid, f)) != nil)
			return se;
		off += n;
		first = 0;
		if(off >= len p)
			break;
	}
	return nil;
}

#
# one whole SDU in.  The credits it cost go back to the peer only now,
# which is what keeps the queue it came off from ever being full.
#
crecv(m: ref Mux, c: ref Chan): (array of byte, string)
{
	if(c == nil)
		return (nil, "no channel");
	for(;;){
		alt {
		sdu := <-c.sq =>
			credit(m, c, sdu.pdus);
			return (sdu.data, nil);
		* =>	;
		}
		<-m.reply;
		st := c.state;
		e := c.err;
		m.reply <-= 1;
		if(st != Sup){
			alt {
			sdu := <-c.sq =>
				return (sdu.data, nil);
			* =>	;
			}
			if(e == nil)
				e = "the channel is closed";
			return (nil, e);
		}
		alt {
		sdu := <-c.sq =>
			credit(m, c, sdu.pdus);
			return (sdu.data, nil);
		<-c.rwake =>	;
		}
	}
}

credit(m: ref Mux, c: ref Chan, n: int): string
{
	if(n <= 0)
		return nil;
	<-m.reply;
	if(c.state != Sup){
		m.reply <-= 1;
		return nil;
	}
	c.rxcred += n;
	cid := c.cid;
	id := nextid(m);
	m.reply <-= 1;
	p := array[8] of byte;
	p[0] = byte Ccredit;
	p[1] = byte id;
	bt->put16(p, 2, 4);
	bt->put16(p, 4, cid);
	bt->put16(p, 6, n);
	return send(m, m.sig, p);
}

#
# a segment has arrived.  Runs with the mux lock held, inside the
# demultiplexer, and must never block.
#
kframe(m: ref Mux, c: ref Chan, p: array of byte)
{
	if(c.state != Sup)
		return;
	if(len p > c.mps){
		fail(m, c, sys->sprint("a %d byte segment where the most is %d", len p, c.mps));
		return;
	}
	if(c.rxcred <= 0){
		fail(m, c, "a segment the peer had no credit for");
		return;
	}
	c.rxcred--;
	if(c.sdu == nil){
		if(len p < 2){
			fail(m, c, "a first segment with no SDU length in it");
			return;
		}
		n := bt->get16(p, 0);
		if(n > c.mtu){
			fail(m, c, sys->sprint("an SDU of %d bytes where the MTU is %d", n, c.mtu));
			return;
		}
		c.sdu = array[n] of byte;
		c.have = 0;
		c.pdus = 0;
		p = p[2:];
	}
	if(c.have + len p > len c.sdu){
		fail(m, c, "more data than the SDU said it would be");
		return;
	}
	c.sdu[c.have:] = p;
	c.have += len p;
	c.pdus++;
	if(c.have == len c.sdu){
		sdu := ref Sdu(c.sdu, c.pdus);
		c.sdu = nil;
		alt {
		c.sq <-= sdu =>	;
		* =>
			#
			# cannot happen: the queue is as deep as the
			# credits granted and a segment cannot arrive
			# without one.  If it ever does, say so rather
			# than quietly losing a message.
			#
			fail(m, c, "the receive queue overran its credits");
			return;
		}
		poke(c);
	}
}

answer(m: ref Mux, id, code: int, p: array of byte)
{
	<-m.reply;
	rc: chan of array of byte;
	for(pl := m.pend; pl != nil; pl = tl pl){
		(pid, want, c) := hd pl;
		if(pid == id && want == code){
			rc = c;
			break;
		}
	}
	m.reply <-= 1;
	if(rc == nil)
		return;		# nobody is waiting: a late or a duplicate answer
	alt {
	rc <-= p =>	;
	* =>	;
	}
}

# with the lock held: the channel the peer receives on
bydcid(m: ref Mux, dcid: int): ref Chan
{
	for(cl := m.chans; cl != nil; cl = tl cl){
		c := hd cl;
		if(c.state != Sfixed && c.dcid == dcid)
			return c;
	}
	return nil;
}
