implement Hci;

#
# HCI: the controller.  This is the layer that has to be careful,
# because a controller is a device with rules -- one command at a
# time, a fixed number of ACL buffers, events that arrive whether or
# not anyone asked for them -- and everything above it is parsing.
#
# One process reads the transport and does nothing else: it hands a
# command's answer to whoever is waiting for it, reassembles ACL
# fragments into whole L2CAP frames, gives back ACL buffer credits,
# and drops advertising reports on the floor when nobody is
# listening rather than stopping the world.  Sending a command takes
# a lock, so only one is ever outstanding.  Sending ACL data takes a
# credit, so a write waits for the controller instead of overrunning
# it.
#
# On 9front this is one C file: a proc reading the transport, a
# QLock for the command, and a Rendez for the credits.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;

Cmdtimeout:	con 10000;	# ms a controller has to answer a command
Conntimeout:	con 20000;	# ms to establish an LE connection
Cancelwait:	con 3000;	# ms for the completion a cancel is promised

# opcode groups
Oglink:		con 16r01;
Ogctl:		con 16r03;
Oginfo:		con 16r04;
Ogle:		con 16r08;

# events
Edisconn:	con 16r05;
Eencchange:	con 16r08;
Ecmdcomplete:	con 16r0e;
Ecmdstatus:	con 16r0f;
Enumpkts:	con 16r13;
Elemeta:	con 16r3e;

# LE meta subevents
Sconn:		con 16r01;
Sadv:		con 16r02;
Supdate:	con 16r03;
Sltkreq:	con 16r05;

#
# Nothing here is module state any more.  A controller is a ref Ctlr
# and every function takes one, or takes a Conn and reaches the
# controller through it: two radios in one program are then two
# objects rather than two programs.
#
init(b: Bt): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	return nil;
}

#
# reset a controller, then ask it what it is and how much it can
# hold.  Nothing above here works until this has run.
#
start(tr: Bttransport): (ref Ctlr, string)
{
	x := ref Ctlr;
	x.t = tr;
	x.cmdlock = chan[1] of int;
	#
	# A controller will have one LE Create Connection outstanding
	# and no more, so two callers starting a connection at once is
	# not something to serialise inside the controller -- the second
	# command is simply refused.  It is something to serialise here,
	# because both callers then wait on connc and either can take
	# the other's answer.  The command path has had this since it
	# was written; this is the same thing for the one other request
	# whose answer comes back as an event.
	#
	x.connlock = chan[1] of int;
	x.replyc = chan of ref Reply;
	# buffered: a report is dropped only when nothing has read the
	# queue for a while, not merely because the reader of it
	# happened to be busy when the last one arrived
	x.advc = chan[16] of ref Adv;
	#
	# Buffered by one.  The event process offers the completion with
	# a default arm and drops it if nobody is waiting, and there is a
	# window between the Command Status coming back and the caller
	# reaching its alt where nobody is.  Losing it there costs the
	# whole connection timeout and leaves a live link on the
	# controller that nothing here owns.
	#
	x.connc = chan[1] of (ref Conn, string);
	#
	# Buffered, because a peer connects when it feels like it and
	# not when something here is reading.  A link that does not fit
	# is closed rather than dropped: nothing above would own it, and
	# a link nothing owns stays up on the controller for ever.
	#
	x.inc = chan[4] of ref Conn;
	x.statelock = chan[1] of int;
	x.statelock <-= 1;
	x.aclsize = 27;
	x.aclbufs = 1;
	x.credits = chan[1] of int;

	x.running = 1;
	spawn reader(x);

	(st, nil, e) := cmd(x, bt->opcode(Ogctl, 16r0003), nil);	# Reset
	if(e != nil)
		return (nil, "reset: " + e);
	if(st != 0)
		return (nil, "reset: " + bt->hcierr(st));

	p: array of byte;
	(st, p, e) = cmd(x, bt->opcode(Oginfo, 16r0001), nil);	# Read Local Version
	if(e == nil && st == 0 && len p >= 8)
		x.lver = sys->sprint("hci %d rev %#4.4ux lmp %d subver %#4.4ux manufacturer %#4.4ux",
			int p[0], bt->get16(p, 1), int p[3], bt->get16(p, 6), bt->get16(p, 4));

	(st, p, e) = cmd(x, bt->opcode(Oginfo, 16r0009), nil);	# Read BD_ADDR
	if(e != nil)
		return (nil, "read BD_ADDR: " + e);
	if(st != 0)
		return (nil, "read BD_ADDR: " + bt->hcierr(st));
	if(len p < Bt->Baddrlen)
		return (nil, "read BD_ADDR: short answer");
	x.laddr = array[Bt->Baddrlen] of byte;
	x.laddr[0:] = p[0:Bt->Baddrlen];

	# the event mask a controller powers up with hides the LE meta
	# event, so ask for everything
	mask := array[8] of byte;
	for(i := 0; i < 8; i++)
		mask[i] = byte 16rff;
	cmd(x, bt->opcode(Ogctl, 16r0001), mask);		# Set Event Mask
	lemask := array[8] of byte;
	for(i = 0; i < 8; i++)
		lemask[i] = byte 0;
	lemask[0] = byte 16r1f;		# connection complete .. long term key request
	cmd(x, bt->opcode(Ogle, 16r0001), lemask);		# LE Set Event Mask

	(st, p, e) = cmd(x, bt->opcode(Ogle, 16r0002), nil);	# LE Read Buffer Size
	if(e == nil && st == 0 && len p >= 3){
		x.aclsize = bt->get16(p, 0);
		x.aclbufs = int p[2];
	}
	if(x.aclsize == 0 || x.aclbufs == 0){
		# a controller with no separate LE buffers shares the
		# BR/EDR ones, which is what Read Buffer Size reports
		(st, p, e) = cmd(x, bt->opcode(Oginfo, 16r0005), nil);
		if(e == nil && st == 0 && len p >= 7){
			x.aclsize = bt->get16(p, 0);
			x.aclbufs = bt->get16(p, 3);
		}
	}
	if(x.aclsize < 27)
		x.aclsize = 27;
	if(x.aclbufs < 1)
		x.aclbufs = 1;
	x.credits = chan[x.aclbufs] of int;
	for(i = 0; i < x.aclbufs; i++)
		x.credits <-= 1;
	return (x, nil);
}

stop(x: ref Ctlr)
{
	if(x == nil)
		return;
	x.running = 0;
	if(x.t != nil)
		x.t->close();
}

localaddr(x: ref Ctlr): array of byte
{
	return x.laddr;
}

localver(x: ref Ctlr): string
{
	return x.lver;
}

#
# The ranges a controller will take, from the specification, and the
# one rule between them that matters: a link whose supervision timeout
# is shorter than the longest the peripheral may stay silent drops
# every time the peripheral exercises its latency.
#
paramsok(min, max, latency, timeout: int): string
{
	if(min < 6 || min > 3200 || max < 6 || max > 3200)
		return "connection interval out of range";
	if(min > max)
		return "the smallest connection interval is larger than the largest";
	if(latency < 0 || latency > 499)
		return "peripheral latency out of range";
	if(timeout < 10 || timeout > 3200)
		return "supervision timeout out of range";
	#
	# both sides in milliseconds: the interval is 1.25ms and the
	# timeout 10ms, so the specification's "the timeout shall be
	# greater than (1 + latency) * interval * 2" becomes
	# timeout * 4 > (1 + latency) * max.  Greater, not at least:
	# equality is refused, which matters because a peripheral
	# minding its battery asks for exactly the boundary.
	#
	if((1 + latency) * max >= timeout * 4)
		return "the supervision timeout is too short for that latency";
	return nil;
}

#
# Ask the controller to run the link at different parameters.  A
# central does this itself; a peripheral asks for it over L2CAP and
# the central does it on the peripheral's behalf, which is what makes
# accepting an L2CAP request an obligation rather than a courtesy.
#
# This returns when the controller has taken the request.  The link
# changes later, and the Connection Update Complete event is what
# writes the new values into the Conn.
#
leconnupdate(c: ref Conn, min, max, latency, timeout: int): string
{
	if(c == nil)
		return "not connected";
	if((e := paramsok(min, max, latency, timeout)) != nil)
		return e;
	p := array[14] of byte;
	bt->put16(p, 0, c.handle);
	bt->put16(p, 2, min);
	bt->put16(p, 4, max);
	bt->put16(p, 6, latency);
	bt->put16(p, 8, timeout);
	bt->put16(p, 10, 0);	# minimum connection length
	bt->put16(p, 12, 0);	# maximum
	(st, nil, ce) := cmd(c.x, bt->opcode(Ogle, 16r0013), p);
	if(ce != nil)
		return ce;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

scodropped(x: ref Ctlr): int
{
	return x.scodrop;
}

aclmtu(x: ref Ctlr): (int, int)
{
	return (x.aclsize, x.aclbufs);
}

advs(x: ref Ctlr): chan of ref Adv
{
	return x.advc;
}

incoming(x: ref Ctlr): chan of ref Conn
{
	return x.inc;
}

advertising(x: ref Ctlr): int
{
	return x.adv;
}

#
# Advertising.  A hundred to a hundred and fifty milliseconds on all
# three advertising channels, from this controller's own address,
# accepting a connection from anyone.  Connectable undirected is the
# only kind worth having here: the point of advertising at all is to
# be connected to.
#
Advmin:	con 16r00a0;	# 100 ms in 0.625 ms units
Advmax:	con 16r00f0;	# 150 ms

leadvparams(x: ref Ctlr, connectable: int): string
{
	p := array[15] of byte;
	bt->put16(p, 0, Advmin);
	bt->put16(p, 2, Advmax);
	if(connectable)
		p[4] = byte 16r00;	# ADV_IND
	else
		p[4] = byte 16r03;	# ADV_NONCONN_IND
	p[5] = byte Bt->Apublic;	# our own address
	p[6] = byte 0;			# no directed peer, so the
	for(i := 0; i < Bt->Baddrlen; i++)	# address below is unused
		p[7+i] = byte 0;
	p[13] = byte 16r07;		# all three advertising channels
	p[14] = byte 0;			# accept anyone
	(st, nil, e) := cmd(x, bt->opcode(Ogle, 16r0006), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

#
# Both data commands take a fixed 32 byte block: a length and 31 bytes
# of which only that many are significant.  Sending fewer is a common
# way to have a controller refuse the command.
#
advblock(x: ref Ctlr, ocf: int, ad: array of byte): string
{
	if(len ad > 31)
		return sys->sprint("%d bytes of advertising data: the most is 31", len ad);
	p := array[32] of byte;
	p[0] = byte len ad;
	for(i := 0; i < 31; i++)
		p[1+i] = byte 0;
	p[1:] = ad;
	(st, nil, e) := cmd(x, bt->opcode(Ogle, ocf), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

leadvdata(x: ref Ctlr, ad: array of byte): string
{
	return advblock(x, 16r0008, ad);
}

leadvresp(x: ref Ctlr, ad: array of byte): string
{
	return advblock(x, 16r0009, ad);
}

leadvertise(x: ref Ctlr, on: int): string
{
	p := array[1] of byte;
	p[0] = byte on;
	(st, nil, e) := cmd(x, bt->opcode(Ogle, 16r000a), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	x.adv = on;
	return nil;
}

conns(x: ref Ctlr): list of ref Conn
{
	<-x.statelock;
	l: list of ref Conn;
	for(s := x.states; s != nil; s = tl s)
		l = (hd s).c :: l;
	x.statelock <-= 1;
	return l;
}

#
# one command at a time: take the lock, send it, wait for the
# controller's answer or for the clock to run out
#
cmd(x: ref Ctlr, op: int, p: array of byte): (int, array of byte, string)
{
	x.cmdlock <-= 1;
	r := docmd(x, op, p);
	<-x.cmdlock;
	return (r.status, r.p, r.err);
}

docmd(x: ref Ctlr, op: int, p: array of byte): ref Reply
{
	if(len p > 255)
		return ref Reply(op, 0, nil, "command parameters too long");
	w := array[3 + len p] of byte;
	bt->put16(w, 0, op);
	w[2] = byte len p;
	if(p != nil)
		w[3:] = p;
	if((e := x.t->write(Bt->Hcicmd, w)) != nil)
		return ref Reply(op, 0, nil, e);
	# buffered, so the timer process can put its tick down and
	# leave; an unbuffered one would block for ever on a command
	# that answered in time, leaking a process per command
	tick := chan[1] of int;
	spawn timer(Cmdtimeout, tick);
	for(;;){
		alt {
		r := <-x.replyc =>
			if(r.op != op)
				continue;	# an answer to something already given up on
			return r;
		<-tick =>
			return ref Reply(op, 0, nil, sys->sprint("no answer to command %#4.4ux", op));
		}
	}
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

lescan(x: ref Ctlr, on: int): string
{
	if(on){
		# passive scan, a 60 ms window in a 60 ms interval, our
		# own public address, accept everything
		p := array[7] of byte;
		p[0] = byte 0;			# passive
		bt->put16(p, 1, 16r0060);	# interval, 0.625 ms units
		bt->put16(p, 3, 16r0060);	# window
		p[5] = byte 0;			# own address: public
		p[6] = byte 0;			# accept all advertisements
		(st, nil, e) := cmd(x, bt->opcode(Ogle, 16r000b), p);
		if(e != nil)
			return e;
		if(st != 0)
			return bt->hcierr(st);
	}
	q := array[2] of byte;
	q[0] = byte on;
	q[1] = byte 0;		# report duplicates: btfs wants the rssi to move
	(st, nil, e) := cmd(x, bt->opcode(Ogle, 16r000c), q);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

#
# LE Create Connection answers with a command status; the connection
# itself arrives later as an LE Connection Complete event
#
leconnect(x: ref Ctlr, atype: int, addr: array of byte): (ref Conn, string)
{
	if(len addr != Bt->Baddrlen)
		return (nil, "not an address");
	p := array[25] of byte;
	bt->put16(p, 0, 16r0060);	# scan interval
	bt->put16(p, 2, 16r0030);	# scan window
	p[4] = byte 0;			# no white list: use the address below
	p[5] = byte atype;
	p[6:] = addr;
	p[12] = byte Bt->Apublic;	# our own address type
	bt->put16(p, 13, 16r0018);	# connection interval min, 1.25 ms units
	bt->put16(p, 15, 16r0028);	# max
	bt->put16(p, 17, 0);		# peripheral latency
	bt->put16(p, 19, 16r002a);	# supervision timeout, 10 ms units
	bt->put16(p, 21, 0);		# minimum connection length
	bt->put16(p, 23, 0);		# maximum

	x.connlock <-= 1;
	r := doleconnect(x, p);
	<-x.connlock;
	return r;
}

doleconnect(x: ref Ctlr, p: array of byte): (ref Conn, string)
{
	#
	# Load bearing, not tidiness.  Nothing filters which completion
	# a waiter accepts -- with connlock held there is only one
	# attempt, so nothing needs to -- which means an answer left in
	# the channel by an attempt that gave up would be handed to this
	# one as its own.  The wait after a cancel below is what should
	# stop one ever being left, and this is what stops a controller
	# that does not answer even that from poisoning every connection
	# afterwards.
	#
	# What is discarded here may be a connection.  The event that
	# carried it has already put a Cstate in states, and nothing
	# will ever take it out again: closeconn runs on a Disconnection
	# Complete, and no such event is coming for a handle nobody
	# above knows about.  So a discarded connection is closed rather
	# than merely dropped -- otherwise the leak this whole thing is
	# about survives in the one place that throws a link away on
	# purpose.
	#
	alt {
	(c, err) := <-x.connc =>
		if(err == nil && c != nil)
			disconnect(c);
	* =>
		;
	}

	(st, nil, e) := cmd(x, bt->opcode(Ogle, 16r000d), p);
	if(e != nil)
		return (nil, e);
	if(st != 0)
		return (nil, bt->hcierr(st));

	#
	# No filter on which completion this is.  With connlock held
	# there is one attempt outstanding, so a completion that arrives
	# is necessarily this one's -- including on a controller that
	# does address resolution itself and reports the peer's identity
	# address rather than the address we dialled, where matching the
	# two would throw a live connection away.
	#
	tick := chan[1] of int;
	spawn timer(Conntimeout, tick);
	alt {
	(c, err) := <-x.connc =>
		if(err != nil)
			return (nil, err);
		return (c, nil);
	<-tick =>
		return cancelled(x);
	}
}

#
# The attempt has run out of time.  Cancelling it does not make the
# completion go away: the specification says a successful cancel is
# followed by an LE Connection Complete carrying Unknown Connection
# Identifier, and that a cancel which arrives after the connection is
# up is refused with Command Disallowed and the real completion stands.
# So there is always one more event to take, and taking it is the
# difference between a tidy failure and a connection left up on the
# controller that nothing here knows about.
#
# A connection that arrives this way is returned rather than torn down.
# It is the connection the caller asked for; it was only late.
#
cancelled(x: ref Ctlr): (ref Conn, string)
{
	cmd(x, bt->opcode(Ogle, 16r000e), nil);	# LE Create Connection Cancel
	tick := chan[1] of int;
	spawn timer(Cancelwait, tick);
	alt {
	(c, err) := <-x.connc =>
		#
		# what the controller said, not what this side assumed.
		# A cancelled attempt comes back Unknown Connection
		# Identifier and reads as a timeout; anything else is a
		# real failure and the reason is the useful part of it,
		# which is exactly the case that matters on hardware.
		#
		if(err != nil)
			return (nil, "connection timed out: " + err);
		return (c, nil);
	<-tick =>
		#
		# a controller that owes an event and does not send it.
		# The next attempt drains the channel before it starts,
		# so a late one cannot be mistaken for that attempt's.
		#
		return (nil, "connection timed out, and the cancel was not answered either");
	}
}

disconnect(c: ref Conn): string
{
	p := array[3] of byte;
	bt->put16(p, 0, c.handle);
	p[2] = byte 16r13;		# remote user terminated the connection
	(st, nil, e) := cmd(c.x, bt->opcode(Oglink, 16r0006), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

#
# a whole L2CAP frame down the link, cut into the controller's ACL
# packet size, one credit per packet
#
acl(c: ref Conn, p: array of byte): string
{
	off := 0;
	first := 1;
	while(off < len p){
		n := len p - off;
		if(n > c.x.aclsize)
			n = c.x.aclsize;
		pb := 16r01;		# a continuing fragment
		if(first)
			pb = 16r02;	# the first packet of a message
		w := array[4 + n] of byte;
		bt->put16(w, 0, (c.handle & 16r0fff) | (pb << 12));
		bt->put16(w, 2, n);
		w[4:] = p[off:off+n];
		<-c.x.credits;
		if((e := c.x.t->write(Bt->Hciacl, w)) != nil){
			c.x.credits <-= 1;
			return e;
		}
		off += n;
		first = 0;
	}
	return nil;
}

lerand(x: ref Ctlr): (array of byte, string)
{
	(st, p, e) := cmd(x, bt->opcode(Ogle, 16r0018), nil);
	if(e != nil)
		return (nil, e);
	if(st != 0)
		return (nil, bt->hcierr(st));
	if(len p < 8)
		return (nil, "short LE Rand");
	r := array[8] of byte;
	r[0:] = p[0:8];
	return (r, nil);
}

#
# LE Encrypt: the parameters go to the controller exactly as given.
# SMP's own e() wants its arguments most significant byte first, so
# whoever calls this reverses them; smp here uses crypt(2) and does
# not need the controller at all.
#
leencrypt(x: ref Ctlr, key, plain: array of byte): (array of byte, string)
{
	if(len key != 16 || len plain != 16)
		return (nil, "LE Encrypt takes two 16 byte arguments");
	p := array[32] of byte;
	p[0:] = key;
	p[16:] = plain;
	(st, r, e) := cmd(x, bt->opcode(Ogle, 16r0017), p);
	if(e != nil)
		return (nil, e);
	if(st != 0)
		return (nil, bt->hcierr(st));
	if(len r < 16)
		return (nil, "short LE Encrypt");
	o := array[16] of byte;
	o[0:] = r[0:16];
	return (o, nil);
}

lestartencrypt(c: ref Conn, rand: array of byte, ediv: int, ltk: array of byte): string
{
	if(len rand != 8 || len ltk != 16)
		return "LE Start Encryption takes an 8 byte random number and a 16 byte key";
	p := array[28] of byte;
	bt->put16(p, 0, c.handle);
	p[2:] = rand;
	bt->put16(p, 10, ediv);
	p[12:] = ltk;
	(st, nil, e) := cmd(c.x, bt->opcode(Ogle, 16r0019), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

#
# the one process that reads the transport
#
reader(x: ref Ctlr)
{
	while(x.running){
		(ptype, p, e) := x.t->read();
		if(e != nil){
			if(x.running)
				sys->fprint(sys->fildes(2), "hci: %s\n", e);
			x.running = 0;
			return;
		}
		case ptype {
		Bt->Hcievt =>	event(x, p);
		Bt->Hciacl =>	acldata(x, p);
		Bt->Hcisco =>
			#
			# The transport frames these and nothing above
			# wants them: there is no audio here, and a voice
			# channel needs a great deal more than a reader
			# case.  They are counted and the first is said
			# out loud rather than vanishing -- a controller
			# sending SCO to a host that asked for none is
			# worth knowing about, and a silent drop is
			# indistinguishable from a transport losing them.
			#
			if(x.scodrop == 0)
				sys->fprint(sys->fildes(2),
					"hci: a SCO packet arrived and there is nothing to do with it; counting the rest\n");
			x.scodrop++;
		}
	}
}

event(x: ref Ctlr, p: array of byte)
{
	if(len p < 2)
		return;
	code := int p[0];
	plen := int p[1];
	if(len p < 2 + plen)
		return;
	b := p[2:2+plen];
	case code {
	Ecmdcomplete =>
		if(len b < 3)
			return;
		op := bt->get16(b, 1);
		r := b[3:];
		st := 0;
		if(len r > 0){
			st = int r[0];
			r = r[1:];
		}
		post(x, ref Reply(op, st, r, nil));
	Ecmdstatus =>
		if(len b < 4)
			return;
		post(x, ref Reply(bt->get16(b, 2), int b[0], nil, nil));
	Enumpkts =>
		if(len b < 1)
			return;
		nh := int b[0];
		for(i := 0; i < nh; i++){
			o := 1 + 4*i;
			if(o + 4 > len b)
				break;
			n := bt->get16(b, o+2);
			for(j := 0; j < n; j++)
				alt {
				x.credits <-= 1 =>	;
				* =>	;	# the controller gave back more than it took
				}
		}
	Edisconn =>
		if(len b < 4)
			return;
		closeconn(x, bt->get16(b, 1), bt->hcierr(int b[3]));
	Eencchange =>
		if(len b < 4)
			return;
		s := findstate(x, bt->get16(b, 1));
		if(s != nil && int b[0] == 0)
			s.c.encrypted = int b[3] != 0;
	Elemeta =>
		if(len b < 1)
			return;
		lemeta(x, int b[0], b[1:]);
	}
}

post(x: ref Ctlr, r: ref Reply)
{
	alt {
	x.replyc <-= r =>	;
	* =>	;	# nobody is waiting: the command already gave up
	}
}

lemeta(x: ref Ctlr, sub: int, b: array of byte)
{
	case sub {
	Sconn =>
		if(len b < 1)
			return;
		st := int b[0];
		if(st != 0){
			alt {
			x.connc <-= (nil, bt->hcierr(st)) =>	;
			* =>	;
			}
			return;
		}
		if(len b < 18)
			return;
		c := ref Conn;
		c.x = x;
		c.handle = bt->get16(b, 1);
		c.role = int b[3];
		c.atype = int b[4];
		c.addr = array[Bt->Baddrlen] of byte;
		c.addr[0:] = b[5:5+Bt->Baddrlen];
		c.encrypted = 0;
		c.interval = bt->get16(b, 11);
		c.latency = bt->get16(b, 13);
		c.timeout = bt->get16(b, 15);
		c.up = chan of array of byte;
		c.closed = chan[1] of string;
		<-x.statelock;
		x.states = ref Cstate(c, nil, 0) :: x.states;
		x.statelock <-= 1;
		if(c.role == Rperipheral){
			#
			# A peer opened this one.  It must not go to
			# connc: with connlock held there is one attempt
			# outstanding and nothing filters what it
			# accepts, so a link nobody asked for would be
			# handed to a leconnect as its own answer -- the
			# right shape of thing, the wrong device.
			#
			alt {
			x.inc <-= c =>	;
			* =>
				# nothing above is listening, so nothing
				# would own it
				spawn dropconn(c);
			}
			return;
		}
		alt {
		x.connc <-= (c, nil) =>	;
		* =>	;	# nobody asked for it
		}
	Supdate =>
		#
		# the link is now running at something else, either
		# because this side asked or because the peripheral did
		# and this side agreed.  A failure says so and leaves the
		# parameters as they were, which is what the controller
		# does.
		#
		if(len b < 9)
			return;
		if(int b[0] != 0){
			sys->fprint(sys->fildes(2),
				"hci: connection update refused: %s\n", bt->hcierr(int b[0]));
			return;
		}
		s := findstate(x, bt->get16(b, 1));
		if(s == nil)
			return;
		s.c.interval = bt->get16(b, 3);
		s.c.latency = bt->get16(b, 5);
		s.c.timeout = bt->get16(b, 7);
	Sadv =>
		if(len b < 1)
			return;
		n := int b[0];
		o := 1;
		for(i := 0; i < n; i++){
			if(o + 9 > len b)
				return;
			evtype := int b[o];
			atype := int b[o+1];
			addr := array[Bt->Baddrlen] of byte;
			addr[0:] = b[o+2:o+2+Bt->Baddrlen];
			dlen := int b[o+8];
			if(o + 10 + dlen > len b)
				return;
			data := array[dlen] of byte;
			data[0:] = b[o+9:o+9+dlen];
			rssi := int b[o+9+dlen];
			if(rssi > 127)
				rssi -= 256;
			o += 10 + dlen;
			alt {
			x.advc <-= ref Adv(evtype, atype, addr, rssi, data) =>	;
			* =>	;	# nobody is scanning: drop it
			}
		}
	}
}

#
# ACL up: fragments of one L2CAP frame, in order, on a handle.  The
# frame's own length header says how much is coming.
#
acldata(x: ref Ctlr, p: array of byte)
{
	if(len p < 4)
		return;
	h := bt->get16(p, 0);
	handle := h & 16r0fff;
	pb := (h >> 12) & 3;
	dlen := bt->get16(p, 2);
	if(len p < 4 + dlen)
		return;
	d := p[4:4+dlen];
	s := findstate(x, handle);
	if(s == nil)
		return;
	case pb {
	16r02 =>			# the first packet of a frame
		s.acc = d;
		s.want = 0;
		if(len d >= 2)
			s.want = 4 + bt->get16(d, 0);
	16r01 =>			# a continuation
		if(s.acc == nil)
			return;
		a := array[len s.acc + len d] of byte;
		a[0:] = s.acc;
		a[len s.acc:] = d;
		s.acc = a;
	* =>
		return;
	}
	if(s.want > 0 && len s.acc >= s.want){
		f := s.acc[0:s.want];
		s.acc = nil;
		s.want = 0;
		s.c.up <-= f;
	}
}

findstate(x: ref Ctlr, handle: int): ref Cstate
{
	<-x.statelock;
	r: ref Cstate;
	for(l := x.states; l != nil; l = tl l)
		if((hd l).c.handle == handle){
			r = hd l;
			break;
		}
	x.statelock <-= 1;
	return r;
}

closeconn(x: ref Ctlr, handle: int, why: string)
{
	<-x.statelock;
	nl: list of ref Cstate;
	s: ref Cstate;
	for(l := x.states; l != nil; l = tl l)
		if((hd l).c.handle == handle)
			s = hd l;
		else
			nl = hd l :: nl;
	x.states = nl;
	x.statelock <-= 1;
	if(s == nil)
		return;
	if(why == nil)
		why = "disconnected";
	alt {
	s.c.closed <-= why =>	;
	* =>	;
	}
}

dropconn(c: ref Conn)
{
	disconnect(c);
}
