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
# connection parameters; accepting is the polite answer and keeps
# battery-powered devices from dropping the link.  Anything else
# gets a command reject saying the command is not understood.
#
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
		r := array[6] of byte;
		r[0] = byte Cparamresp;
		r[1] = byte id;
		bt->put16(r, 2, 2);
		bt->put16(r, 4, 0);	# accepted
		send(m, Cle, r);
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
