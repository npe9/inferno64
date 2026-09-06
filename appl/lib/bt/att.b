implement Att;

#
# ATT: the attribute protocol.  Small, because the protocol itself
# forbids the hard part: a client may have one request outstanding
# at a time, and the server answers it or sends an error response
# naming the handle that failed.  Notifications and indications
# arrive whenever the server likes, in between.
#
# One process reads the channel and routes: an answer goes to
# whoever is waiting for it, a notification goes on the notify
# queue, an indication is confirmed as well.  That process never
# blocks, so L2CAP below it never blocks either.
#
# On 9front this is one C file: a proc, a QLock and a Rendez.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	l2cap: L2cap;
	Mux: import L2cap;

Timeout:	con 30000;	# ms; the specification's ATT transaction timeout

init(b: Bt, l: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	l2cap = l;
	return nil;
}

start(m: ref Mux): ref Sess
{
	s := ref Sess;
	s.m = m;
	s.mtu = Dmtu;
	s.rq = l2cap->open(m, L2cap->Cattr);
	s.resp = chan[1] of array of byte;
	s.notify = chan[16] of array of byte;
	# a mutex taken by sending into it: empty means free.  It is
	# NOT primed here -- priming it would mean the first request
	# blocked for ever, which is exactly what it did.
	s.lock = chan[1] of int;
	spawn router(s);
	return s;
}

stop(s: ref Sess)
{
	# nil up the queue the router reads, which ends it; the link
	# going away does the same thing from below
	alt {
	s.rq <-= nil =>	;
	* =>	;
	}
}

notifies(s: ref Sess): chan of array of byte
{
	return s.notify;
}

router(s: ref Sess)
{
	for(;;){
		p := <-s.rq;
		if(p == nil)
			return;
		if(len p < 1)
			continue;
		op := int p[0];
		case op {
		Rnotify =>
			alt {
			s.notify <-= p =>	;
			* =>	;	# nobody is reading: drop it
			}
		Rindicate =>
			alt {
			s.notify <-= p =>	;
			* =>	;
			}
			c := array[1] of byte;
			c[0] = byte Rconfirm;
			l2cap->send(s.m, L2cap->Cattr, c);
		* =>
			# a response, or an error response; either way
			# it belongs to the outstanding request
			alt {
			s.resp <-= p =>	;
			* =>	;	# nothing outstanding: drop it
			}
		}
	}
}

#
# a request and its answer.  The error response carries the request
# it failed, the handle and the reason, and this turns that into a
# string rather than making every caller decode it.
#
request(s: ref Sess, req: array of byte): (array of byte, string)
{
	if(len req < 1)
		return (nil, "empty request");
	if(len req > s.mtu)
		return (nil, "request longer than the ATT MTU");
	s.lock <-= 1;
	drain(s);
	if((e := l2cap->send(s.m, L2cap->Cattr, req)) != nil){
		<-s.lock;
		return (nil, e);
	}
	r: array of byte;
	tick := chan[1] of int;
	spawn timer(Timeout, tick);
	alt {
	r = <-s.resp =>	;
	<-tick =>
		<-s.lock;
		return (nil, "ATT transaction timed out");
	}
	<-s.lock;
	if(r == nil)
		return (nil, "link closed");
	if(int r[0] == Rerror){
		if(len r < 5)
			return (nil, "malformed error response");
		#
		# an error response names the request it failed, and that
		# has to be this one.  A server that answers something
		# which is not a request at all -- a Handle Value
		# Confirmation, say -- puts an error in front of whatever
		# the client asks next, and without this the client wears
		# it: seen live, a rediscovery after a Service Changed
		# failing with "request not supported" for a confirmation
		# it had just sent.
		#
		if(int r[1] != int req[0])
			return (nil, sys->sprint("an error for request %#2.2ux, not %#2.2ux",
				int r[1], int req[0]));
		return (nil, sys->sprint("handle %#4.4ux: %s", bt->get16(r, 2), errstr(int r[4])));
	}
	if(int r[0] != (int req[0]) + 1)
		return (nil, sys->sprint("answer %#2.2ux to request %#2.2ux", int r[0], int req[0]));
	return (r, nil);
}

#
# throw away an answer left over from a request that timed out, so
# it is not mistaken for the answer to this one
#
drain(s: ref Sess)
{
	for(;;)
		alt {
		<-s.resp =>	;
		* =>	return;
		}
}

#
# a command has no answer at all
#
command(s: ref Sess, req: array of byte): string
{
	if(len req > s.mtu)
		return "command longer than the ATT MTU";
	return l2cap->send(s.m, L2cap->Cattr, req);
}

exchangemtu(s: ref Sess, want: int): (int, string)
{
	if(want < Dmtu)
		want = Dmtu;
	q := array[3] of byte;
	q[0] = byte Rmtureq;
	bt->put16(q, 1, want);
	(r, e) := request(s, q);
	if(e != nil)
		return (s.mtu, e);
	if(len r < 3)
		return (s.mtu, "short MTU response");
	m := bt->get16(r, 1);
	if(m < Dmtu)
		m = Dmtu;
	if(m > want)
		m = want;
	s.mtu = m;
	return (m, nil);
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

errstr(e: int): string
{
	case e {
	16r01 =>	return "invalid handle";
	16r02 =>	return "read not permitted";
	16r03 =>	return "write not permitted";
	16r04 =>	return "invalid PDU";
	16r05 =>	return "insufficient authentication";
	16r06 =>	return "request not supported";
	16r07 =>	return "invalid offset";
	16r08 =>	return "insufficient authorisation";
	16r09 =>	return "prepare queue full";
	16r0a =>	return "attribute not found";
	16r0b =>	return "attribute not long";
	16r0c =>	return "insufficient encryption key size";
	16r0d =>	return "invalid attribute value length";
	16r0e =>	return "unlikely error";
	16r0f =>	return "insufficient encryption";
	16r10 =>	return "unsupported group type";
	16r11 =>	return "insufficient resources";
	}
	return sys->sprint("ATT error %#2.2ux", e);
}
