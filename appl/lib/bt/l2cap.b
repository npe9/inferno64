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
Cparamreq:	con 16r12;
Cparamresp:	con 16r13;

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
	m.mtu = 23;
	m.chans = nil;
	m.reply = chan[1] of int;
	m.reply <-= 1;
	spawn demux(m);
	return m;
}

open(m: ref Mux, cid: int): chan of array of byte
{
	<-m.reply;
	for(l := m.chans; l != nil; l = tl l){
		(id, ch) := hd l;
		if(id == cid){
			m.reply <-= 1;
			return ch;
		}
	}
	ch := chan[Qdepth] of array of byte;
	m.chans = (cid, ch) :: m.chans;
	m.reply <-= 1;
	return ch;
}

find(m: ref Mux, cid: int): chan of array of byte
{
	<-m.reply;
	ch: chan of array of byte;
	for(l := m.chans; l != nil; l = tl l){
		(id, c) := hd l;
		if(id == cid){
			ch = c;
			break;
		}
	}
	m.reply <-= 1;
	return ch;
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
	m.reply <-= 1;
	for(; l != nil; l = tl l){
		(nil, ch) := hd l;
		alt {
		ch <-= nil =>	;
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
			if(cid == Cle){
				signal(m, p);
				continue;
			}
			ch := find(m, cid);
			if(ch == nil)
				continue;	# nobody opened that channel
			alt {
			ch <-= p =>	;
			* =>	;		# the consumer is behind: drop
			}
		why := <-m.c.closed =>
			if(why == nil)
				why = "disconnected";
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
		send(m, Cle, r);
		#
		# after the answer, not before: the peer is entitled to
		# see the response before the link changes under it.
		#
		if(result == 0)
			spawn doupdate(m.c, min, max, latency, timeout);
	Cparamresp =>
		;
	* =>
		r := array[6] of byte;
		r[0] = byte Creject;
		r[1] = byte id;
		bt->put16(r, 2, 2);
		bt->put16(r, 4, 0);	# command not understood
		send(m, Cle, r);
	}
}
