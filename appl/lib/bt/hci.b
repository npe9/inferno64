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
Sltkreq:	con 16r05;

Cstate: adt {
	c:	ref Conn;
	acc:	array of byte;	# an L2CAP frame being reassembled
	want:	int;
};

Reply: adt {
	op:	int;
	status:	int;
	p:	array of byte;
	err:	string;
};

t:	Bttransport;
cmdlock:	chan of int;
replyc:		chan of ref Reply;
advc:		chan of ref Adv;
connc:		chan of (ref Conn, string);
credits:	chan of int;
states:		list of ref Cstate;
statelock:	chan of int;
running:	int;

laddr:	array of byte;
lver:	string;
aclsize:	int;
aclbufs:	int;

init(b: Bt, tr: Bttransport): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	t = tr;
	cmdlock = chan[1] of int;
	replyc = chan of ref Reply;
	# buffered: a report is dropped only when nothing has read the
	# queue for a while, not merely because the reader of it
	# happened to be busy when the last one arrived
	advc = chan[16] of ref Adv;
	connc = chan of (ref Conn, string);
	statelock = chan[1] of int;
	statelock <-= 1;
	aclsize = 27;
	aclbufs = 1;
	credits = chan[1] of int;
	return nil;
}

#
# reset the controller, then ask it what it is and how much it can
# hold.  Nothing above here works until this has run.
#
start(): string
{
	running = 1;
	spawn reader();

	(st, nil, e) := cmd(bt->opcode(Ogctl, 16r0003), nil);	# Reset
	if(e != nil)
		return "reset: " + e;
	if(st != 0)
		return "reset: " + bt->hcierr(st);

	p: array of byte;
	(st, p, e) = cmd(bt->opcode(Oginfo, 16r0001), nil);	# Read Local Version
	if(e == nil && st == 0 && len p >= 8)
		lver = sys->sprint("hci %d rev %#4.4ux lmp %d subver %#4.4ux manufacturer %#4.4ux",
			int p[0], bt->get16(p, 1), int p[3], bt->get16(p, 6), bt->get16(p, 4));

	(st, p, e) = cmd(bt->opcode(Oginfo, 16r0009), nil);	# Read BD_ADDR
	if(e != nil)
		return "read BD_ADDR: " + e;
	if(st != 0)
		return "read BD_ADDR: " + bt->hcierr(st);
	if(len p < Bt->Baddrlen)
		return "read BD_ADDR: short answer";
	laddr = array[Bt->Baddrlen] of byte;
	laddr[0:] = p[0:Bt->Baddrlen];

	# the event mask a controller powers up with hides the LE meta
	# event, so ask for everything
	mask := array[8] of byte;
	for(i := 0; i < 8; i++)
		mask[i] = byte 16rff;
	cmd(bt->opcode(Ogctl, 16r0001), mask);			# Set Event Mask
	lemask := array[8] of byte;
	for(i = 0; i < 8; i++)
		lemask[i] = byte 0;
	lemask[0] = byte 16r1f;		# connection complete .. long term key request
	cmd(bt->opcode(Ogle, 16r0001), lemask);			# LE Set Event Mask

	(st, p, e) = cmd(bt->opcode(Ogle, 16r0002), nil);	# LE Read Buffer Size
	if(e == nil && st == 0 && len p >= 3){
		aclsize = bt->get16(p, 0);
		aclbufs = int p[2];
	}
	if(aclsize == 0 || aclbufs == 0){
		# a controller with no separate LE buffers shares the
		# BR/EDR ones, which is what Read Buffer Size reports
		(st, p, e) = cmd(bt->opcode(Oginfo, 16r0005), nil);
		if(e == nil && st == 0 && len p >= 7){
			aclsize = bt->get16(p, 0);
			aclbufs = bt->get16(p, 3);
		}
	}
	if(aclsize < 27)
		aclsize = 27;
	if(aclbufs < 1)
		aclbufs = 1;
	credits = chan[aclbufs] of int;
	for(i = 0; i < aclbufs; i++)
		credits <-= 1;
	return nil;
}

stop()
{
	running = 0;
	if(t != nil)
		t->close();
}

localaddr(): array of byte
{
	return laddr;
}

localver(): string
{
	return lver;
}

aclmtu(): (int, int)
{
	return (aclsize, aclbufs);
}

advs(): chan of ref Adv
{
	return advc;
}

conns(): list of ref Conn
{
	<-statelock;
	l: list of ref Conn;
	for(s := states; s != nil; s = tl s)
		l = (hd s).c :: l;
	statelock <-= 1;
	return l;
}

#
# one command at a time: take the lock, send it, wait for the
# controller's answer or for the clock to run out
#
cmd(op: int, p: array of byte): (int, array of byte, string)
{
	cmdlock <-= 1;
	r := docmd(op, p);
	<-cmdlock;
	return (r.status, r.p, r.err);
}

docmd(op: int, p: array of byte): ref Reply
{
	if(len p > 255)
		return ref Reply(op, 0, nil, "command parameters too long");
	w := array[3 + len p] of byte;
	bt->put16(w, 0, op);
	w[2] = byte len p;
	if(p != nil)
		w[3:] = p;
	if((e := t->write(Bt->Hcicmd, w)) != nil)
		return ref Reply(op, 0, nil, e);
	# buffered, so the timer process can put its tick down and
	# leave; an unbuffered one would block for ever on a command
	# that answered in time, leaking a process per command
	tick := chan[1] of int;
	spawn timer(Cmdtimeout, tick);
	for(;;){
		alt {
		r := <-replyc =>
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

lescan(on: int): string
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
		(st, nil, e) := cmd(bt->opcode(Ogle, 16r000b), p);
		if(e != nil)
			return e;
		if(st != 0)
			return bt->hcierr(st);
	}
	q := array[2] of byte;
	q[0] = byte on;
	q[1] = byte 0;		# report duplicates: btfs wants the rssi to move
	(st, nil, e) := cmd(bt->opcode(Ogle, 16r000c), q);
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
leconnect(atype: int, addr: array of byte): (ref Conn, string)
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

	(st, nil, e) := cmd(bt->opcode(Ogle, 16r000d), p);
	if(e != nil)
		return (nil, e);
	if(st != 0)
		return (nil, bt->hcierr(st));

	tick := chan[1] of int;
	spawn timer(Conntimeout, tick);
	alt {
	(c, err) := <-connc =>
		if(err != nil)
			return (nil, err);
		return (c, nil);
	<-tick =>
		cmd(bt->opcode(Ogle, 16r000e), nil);	# LE Create Connection Cancel
		return (nil, "connection timed out");
	}
}

disconnect(c: ref Conn): string
{
	p := array[3] of byte;
	bt->put16(p, 0, c.handle);
	p[2] = byte 16r13;		# remote user terminated the connection
	(st, nil, e) := cmd(bt->opcode(Oglink, 16r0006), p);
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
		if(n > aclsize)
			n = aclsize;
		pb := 16r01;		# a continuing fragment
		if(first)
			pb = 16r02;	# the first packet of a message
		w := array[4 + n] of byte;
		bt->put16(w, 0, (c.handle & 16r0fff) | (pb << 12));
		bt->put16(w, 2, n);
		w[4:] = p[off:off+n];
		<-credits;
		if((e := t->write(Bt->Hciacl, w)) != nil){
			credits <-= 1;
			return e;
		}
		off += n;
		first = 0;
	}
	return nil;
}

lerand(): (array of byte, string)
{
	(st, p, e) := cmd(bt->opcode(Ogle, 16r0018), nil);
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
leencrypt(key, plain: array of byte): (array of byte, string)
{
	if(len key != 16 || len plain != 16)
		return (nil, "LE Encrypt takes two 16 byte arguments");
	p := array[32] of byte;
	p[0:] = key;
	p[16:] = plain;
	(st, r, e) := cmd(bt->opcode(Ogle, 16r0017), p);
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
	(st, nil, e) := cmd(bt->opcode(Ogle, 16r0019), p);
	if(e != nil)
		return e;
	if(st != 0)
		return bt->hcierr(st);
	return nil;
}

#
# the one process that reads the transport
#
reader()
{
	while(running){
		(ptype, p, e) := t->read();
		if(e != nil){
			if(running)
				sys->fprint(sys->fildes(2), "hci: %s\n", e);
			running = 0;
			return;
		}
		case ptype {
		Bt->Hcievt =>	event(p);
		Bt->Hciacl =>	acldata(p);
		}
	}
}

event(p: array of byte)
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
		post(ref Reply(op, st, r, nil));
	Ecmdstatus =>
		if(len b < 4)
			return;
		post(ref Reply(bt->get16(b, 2), int b[0], nil, nil));
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
				credits <-= 1 =>	;
				* =>	;	# the controller gave back more than it took
				}
		}
	Edisconn =>
		if(len b < 4)
			return;
		closeconn(bt->get16(b, 1), bt->hcierr(int b[3]));
	Eencchange =>
		if(len b < 4)
			return;
		s := findstate(bt->get16(b, 1));
		if(s != nil && int b[0] == 0)
			s.c.encrypted = int b[3] != 0;
	Elemeta =>
		if(len b < 1)
			return;
		lemeta(int b[0], b[1:]);
	}
}

post(r: ref Reply)
{
	alt {
	replyc <-= r =>	;
	* =>	;	# nobody is waiting: the command already gave up
	}
}

lemeta(sub: int, b: array of byte)
{
	case sub {
	Sconn =>
		if(len b < 1)
			return;
		st := int b[0];
		if(st != 0){
			alt {
			connc <-= (nil, bt->hcierr(st)) =>	;
			* =>	;
			}
			return;
		}
		if(len b < 18)
			return;
		c := ref Conn;
		c.handle = bt->get16(b, 1);
		c.role = int b[3];
		c.atype = int b[4];
		c.addr = array[Bt->Baddrlen] of byte;
		c.addr[0:] = b[5:5+Bt->Baddrlen];
		c.encrypted = 0;
		c.up = chan of array of byte;
		c.closed = chan[1] of string;
		<-statelock;
		states = ref Cstate(c, nil, 0) :: states;
		statelock <-= 1;
		alt {
		connc <-= (c, nil) =>	;
		* =>	;	# nobody asked for it
		}
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
			advc <-= ref Adv(evtype, atype, addr, rssi, data) =>	;
			* =>	;	# nobody is scanning: drop it
			}
		}
	}
}

#
# ACL up: fragments of one L2CAP frame, in order, on a handle.  The
# frame's own length header says how much is coming.
#
acldata(p: array of byte)
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
	s := findstate(handle);
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

findstate(handle: int): ref Cstate
{
	<-statelock;
	r: ref Cstate;
	for(l := states; l != nil; l = tl l)
		if((hd l).c.handle == handle){
			r = hd l;
			break;
		}
	statelock <-= 1;
	return r;
}

closeconn(handle: int, why: string)
{
	<-statelock;
	nl: list of ref Cstate;
	s: ref Cstate;
	for(l := states; l != nil; l = tl l)
		if((hd l).c.handle == handle)
			s = hd l;
		else
			nl = hd l :: nl;
	states = nl;
	statelock <-= 1;
	if(s == nil)
		return;
	if(why == nil)
		why = "disconnected";
	alt {
	s.c.closed <-= why =>	;
	* =>	;
	}
}
