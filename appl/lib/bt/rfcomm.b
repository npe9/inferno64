implement Rfcomm;

#
# RFCOMM: serial ports over L2CAP.
#
# It is TS 07.10 with a Bluetooth adaptation layer, and it is a
# multiplexer inside a multiplexer: one L2CAP channel to PSM 3 carries
# a session, the session carries up to thirty data link connections,
# and each of those is a serial port.  A DLC is named by a server
# channel number, which is what an SDP record's protocol descriptor
# list gives -- so a device is found with SDP and reached with this.
#
# The framing is the old GSM one.  Address, control, length, an
# optional credit byte, the information, and a frame check sequence
# over the header: two bytes of it for a UIH frame and three for
# everything else, which is the one place the layout is not uniform.
#
# Flow control is credits, as in LE L2CAP but negotiated rather than
# given: the parameter negotiation on the control channel asks for the
# credit based convergence layer, and after that a frame with the poll
# bit set carries a credit byte in front of its information.
#
# On 9front this is one C file: the same frame reader and the same
# three handshakes.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;
	l2cap: L2cap;
	Mux, Chan: import L2cap;

# frame types, without the poll/final bit
Fsabm:	con 16r2f;
Fua:	con 16r63;
Fdm:	con 16r0f;
Fdisc:	con 16r43;
Fuih:	con 16ref;
Pf:	con 16r10;

# multiplexer control message types, already shifted into place
Mpn:	con 16r80;
Mmsc:	con 16re0;
Mnsc:	con 16r10;

#
# What a DLC will take in one frame, and how many frames the peer may
# send before it has to wait.  The frame size is negotiated down to
# whatever the peer will do; the credits are ours to give.
#
Framesize:	con 330;
Credits:	con 7;

Rtx:		con 10000;	# ms to wait for an answer
Qdepth:		con 8;

fcstab:	array of int;

init(b: Bt, l: L2cap): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	l2cap = l;
	#
	# The frame check sequence is a CRC-8 with the polynomial
	# reversed to 0xE0, started at 0xFF and complemented at the end.
	# The table is generated rather than written down: the
	# polynomial is the specification and the table is arithmetic,
	# and a table typed out by hand is 256 chances to be wrong
	# where this is one.
	#
	fcstab = array[256] of int;
	for(i := 0; i < 256; i++){
		c := i;
		for(j := 0; j < 8; j++){
			if(c & 1)
				c = (c >> 1) ^ 16re0;
			else
				c >>= 1;
		}
		fcstab[i] = c;
	}
	return nil;
}

#
# over as many bytes as the frame type says: address and control for a
# UIH frame, and those plus the length for every other kind
#
fcs(p: array of byte): int
{
	f := 16rff;
	for(i := 0; i < len p; i++)
		f = fcstab[f ^ int p[i]];
	return 16rff - f;
}

Dlc.chanof(d: self ref Dlc): int
{
	return d.dlci >> 1;
}

#
# A session on one L2CAP channel.  The reader process is the whole of
# the demultiplexing: every frame that arrives belongs to a DLC or to
# the control channel, and nothing else here reads the L2CAP channel.
#
start(m: ref Mux, ch: ref Chan): (ref Sess, string)
{
	if(ch == nil)
		return (nil, "no channel to the serial port multiplexer");
	s := ref Sess;
	s.m = m;
	s.ch = ch;
	s.up = 0;
	s.dead = nil;
	s.dlcs = nil;
	s.chans = nil;
	s.lock = chan[1] of int;
	s.lock <-= 1;
	s.reply = chan[1] of (int, int, array of byte);
	spawn reader(s);

	#
	# SABM on DLCI 0 starts the multiplexer.  Nothing may be sent
	# on any other DLCI until this is answered.
	#
	if((e := command(s, 0, Fsabm)) != nil){
		stop(s);
		return (nil, e);
	}
	<-s.lock;
	s.up = 1;
	s.lock <-= 1;
	return (s, nil);
}

stop(s: ref Sess)
{
	if(s == nil)
		return;
	<-s.lock;
	if(s.dead == nil)
		s.dead = "the session was closed";
	dl := s.dlcs;
	s.dlcs = nil;
	s.up = 0;
	s.lock <-= 1;
	for(; dl != nil; dl = tl dl)
		wake(hd dl);
}

#
# Open one data link connection: parameter negotiation on the control
# channel, then SABM on the DLC itself, then modem status both ways.
#
# The modem status is not a courtesy.  A device is entitled to hold
# its end shut until it has seen one, so a stack that opened the DLC
# and started sending would be sending into a port that is not ready.
#
open(s: ref Sess, ch: int): (ref Dlc, string)
{
	if(s == nil)
		return (nil, "no session");
	if(ch < 1 || ch > 30)
		return (nil, "a server channel is 1 to 30");
	#
	# The direction bit is 0 for the station that started the
	# multiplexer, which is this one; a device that opened the
	# session to us would use 1 for the same server channel.
	#
	dlci := ch << 1;
	<-s.lock;
	if(s.dead != nil){
		e := s.dead;
		s.lock <-= 1;
		return (nil, e);
	}
	if(bydlci(s, dlci) != nil){
		s.lock <-= 1;
		return (nil, "that channel is already open");
	}
	d := ref Dlc;
	d.s = s;
	d.dlci = dlci;
	d.state = 0;
	d.mtu = Framesize;
	d.credits = 0;
	d.given = 0;
	d.err = nil;
	d.rq = chan[Qdepth] of array of byte;
	d.wake = chan[1] of int;
	s.dlcs = d :: s.dlcs;
	s.lock <-= 1;

	if((e := negotiate(s, d)) != nil){
		drop(s, d);
		return (nil, e);
	}
	if((e = command(s, dlci, Fsabm)) != nil){
		drop(s, d);
		return (nil, e);
	}
	<-s.lock;
	d.state = 1;
	#
	# The credits the peer may spend on us.  They are given here
	# rather than in the negotiation because the negotiation's
	# initial credits are the peer's to us, and these are ours to
	# it -- two counts going opposite ways, which is the part of
	# this that is easy to conflate.
	#
	d.given = Credits;
	s.lock <-= 1;
	if((e = msc(s, d)) != nil){
		drop(s, d);
		return (nil, e);
	}
	#
	# and a first grant, so the peer may send before this side has
	# written anything
	#
	if((e = grant(d, Credits)) != nil){
		drop(s, d);
		return (nil, e);
	}
	return (d, nil);
}

#
# A session a peer opened.  The multiplexer is already up -- the peer
# put it up with a SABM on DLCI 0 -- so there is nothing to ask for
# and nothing to wait for; what this does is take the channel and
# start reading it.
#
accept(m: ref Mux, ch: ref Chan): ref Sess
{
	s := ref Sess;
	s.m = m;
	s.ch = ch;
	s.up = 0;
	s.dead = nil;
	s.dlcs = nil;
	s.chans = nil;
	s.lock = chan[1] of int;
	s.lock <-= 1;
	s.reply = chan[1] of (int, int, array of byte);
	spawn reader(s);
	return s;
}

#
# Say this side answers on a server channel.  A second serve of the
# same channel is the first one's, for the same reason two listens on
# one PSM are one.
#
serve(s: ref Sess, ch: int): chan of ref Dlc
{
	<-s.lock;
	c := served(s, ch);
	if(c == nil){
		c = chan[4] of ref Dlc;
		s.chans = (ch, c) :: s.chans;
	}
	s.lock <-= 1;
	return c;
}

# with the lock held
served(s: ref Sess, ch: int): chan of ref Dlc
{
	for(l := s.chans; l != nil; l = tl l){
		(n, c) := hd l;
		if(n == ch)
			return c;
	}
	return nil;
}

# with the lock held
newdlc(s: ref Sess, dlci: int): ref Dlc
{
	d := ref Dlc;
	d.s = s;
	d.dlci = dlci;
	d.state = 0;
	d.mtu = Framesize;
	d.credits = 0;
	d.given = 0;
	d.err = nil;
	d.rq = chan[Qdepth] of array of byte;
	d.wake = chan[1] of int;
	s.dlcs = d :: s.dlcs;
	return d;
}

#
# A connection a peer opened, once the UA has gone.  The grant is what
# lets it send; handing it over is what lets something above read it.
#
opened(d: ref Dlc, sc: chan of ref Dlc)
{
	grant(d, Credits);
	alt {
	sc <-= d =>	;
	* =>
		# nothing is serving it any more, and a port nobody owns
		# is worse than one that was never opened
		close(d);
	}
}

close(d: ref Dlc): string
{
	if(d == nil)
		return "no channel";
	s := d.s;
	<-s.lock;
	up := d.state == 1;
	d.state = 2;
	s.lock <-= 1;
	e: string;
	if(up)
		e = command(s, d.dlci, Fdisc);
	drop(s, d);
	return e;
}

#
# One frame out.  A write longer than the frame the peer agreed to is
# cut into frames, because a serial line is a stream and not a record:
# what a program writes is bytes, and where the frame boundaries fall
# is this layer's business and nobody else's.
#
write(d: ref Dlc, p: array of byte): string
{
	if(d == nil)
		return "no channel";
	off := 0;
	for(;;){
		s := d.s;
		<-s.lock;
		if(d.state != 1){
			e := d.err;
			if(e == nil)
				e = s.dead;
			if(e == nil)
				e = "the channel is not open";
			s.lock <-= 1;
			return e;
		}
		if(d.credits == 0){
			s.lock <-= 1;
			<-d.wake;
			continue;
		}
		d.credits--;
		mtu := d.mtu;
		s.lock <-= 1;
		n := len p - off;
		if(n > mtu)
			n = mtu;
		if((e := uih(d.s, d.dlci, 0, p[off:off+n])) != nil)
			return e;
		off += n;
		if(off >= len p)
			return nil;
	}
}

read(d: ref Dlc): (array of byte, string)
{
	if(d == nil)
		return (nil, "no channel");
	for(;;){
		alt {
		p := <-d.rq =>
			#
			# a frame taken is a frame the peer may replace,
			# and giving the credit back here rather than on
			# arrival is what makes the queue the bound
			#
			grant(d, 1);
			return (p, nil);
		* =>	;
		}
		s := d.s;
		<-s.lock;
		st := d.state;
		e := d.err;
		if(e == nil)
			e = s.dead;
		s.lock <-= 1;
		if(st != 1){
			alt {
			p := <-d.rq =>
				return (p, nil);
			* =>	;
			}
			if(e == nil)
				e = "the channel is closed";
			return (nil, e);
		}
		alt {
		p := <-d.rq =>
			grant(d, 1);
			return (p, nil);
		<-d.wake =>	;
		}
	}
}

#
# the credit-carrying frame: the poll bit says a credit byte is in
# front of the information, and a frame with no information is a grant
# and nothing else
#
grant(d: ref Dlc, n: int): string
{
	if(n <= 0)
		return nil;
	s := d.s;
	<-s.lock;
	if(d.state != 1){
		s.lock <-= 1;
		return nil;
	}
	d.given += n;
	s.lock <-= 1;
	return uih(s, d.dlci, n, nil);
}

#
# A command that expects an answer of its own kind: SABM answered by
# UA, DISC answered by UA or DM.  One at a time, which the session
# lock does not give -- so this waits on a channel the reader fills,
# and nothing else sends a command while it waits.
#
command(s: ref Sess, dlci, ty: int): string
{
	<-s.lock;
	if(s.dead != nil){
		e := s.dead;
		s.lock <-= 1;
		return e;
	}
	s.lock <-= 1;

	f := array[4] of byte;
	f[0] = byte (16r03 | (dlci << 2));
	f[1] = byte (ty | Pf);
	f[2] = byte 16r01;			# no information
	f[3] = byte fcs(f[0:3]);
	if((e := l2cap->csend(s.m, s.ch, f)) != nil)
		return e;

	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	for(;;){
		alt {
		(rd, rt, nil) := <-s.reply =>
			if(rd != dlci)
				continue;
			if(rt == Fua)
				return nil;
			if(rt == Fdm)
				return "the peer refused the channel";
			continue;
		<-tick =>
			return "the peer never answered";
		}
	}
}

#
# Parameter negotiation, on the control channel and about another one.
# What is asked for is the credit based convergence layer, a frame
# size, and how many frames this side may send before the peer says
# more; what comes back is what the peer will actually do, and the
# frame size may only come down.
#
negotiate(s: ref Sess, d: ref Dlc): string
{
	v := array[8] of byte;
	v[0] = byte d.dlci;
	v[1] = byte 16rf0;		# credit based flow control, requested
	v[2] = byte 0;			# priority: the peer's to choose
	v[3] = byte 0;			# acknowledgement timer, not used
	v[4] = byte Framesize;
	v[5] = byte (Framesize >> 8);
	v[6] = byte 0;			# no retransmissions
	v[7] = byte Credits;		# what the peer may send us to begin
	(r, e) := mcc(s, Mpn, v);
	if(e != nil)
		return e;
	if(len r < 8)
		return "a parameter negotiation answer of " + string len r + " bytes";
	if((int r[1] & 16rf0) != 16rf0)
		return "the peer will not do credit based flow control";
	#
	# A frame size may only come down, and how far down is the
	# peer's to say: TS 07.10 allows 1 to 32767 and defaults to
	# 127, so there is no floor here beyond a frame having to be
	# able to carry a byte.  The 23 that was here first was L2CAP's
	# minimum, which is a different layer's number and has no
	# business in this one.
	#
	fsize := int r[4] | (int r[5] << 8);
	if(fsize < 1 || fsize > 32767)
		return sys->sprint("the peer asked for %d byte frames", fsize);
	<-s.lock;
	if(fsize < d.mtu)
		d.mtu = fsize;
	d.credits = int r[7] & 7;
	s.lock <-= 1;
	return nil;
}

#
# Modem status: what this side's imaginary serial line is doing.  Data
# terminal ready and request to send are both on, because a program
# that opened the file has said so by opening it.
#
msc(s: ref Sess, d: ref Dlc): string
{
	v := array[2] of byte;
	v[0] = byte (16r03 | (d.dlci << 2));
	v[1] = byte 16r8d;	# ea, ready to communicate, ready to receive, valid
	(nil, e) := mcc(s, Mmsc, v);
	return e;
}

#
# One multiplexer control message and its answer.  These travel as UIH
# frames on DLCI 0 with a type byte, a length byte and the value; the
# answer has the same type with its command bit clear.
#
mcc(s: ref Sess, ty: int, v: array of byte): (array of byte, string)
{
	p := array[2 + len v] of byte;
	p[0] = byte (ty | 16r03);	# a command, with the extension bit
	p[1] = byte ((len v << 1) | 1);
	p[2:] = v;
	if((e := uih(s, 0, 0, p)) != nil)
		return (nil, e);
	tick := chan[1] of int;
	spawn timer(Rtx, tick);
	for(;;){
		alt {
		(rd, rt, rp) := <-s.reply =>
			if(rd != 0 || rt != ty)
				continue;
			return (rp, nil);
		<-tick =>
			return (nil, "the peer never answered " + mccname(ty));
		}
	}
}

mccname(ty: int): string
{
	case ty {
	Mpn =>	return "the parameter negotiation";
	Mmsc =>	return "the modem status";
	}
	return sys->sprint("control message %#2.2ux", ty);
}

#
# A UIH frame.  cred is the credit to carry, and a frame with credit
# has the poll bit set -- which is the only thing that says the byte
# is there, so getting it wrong reads the first byte of the
# information as a credit count.
#
uih(s: ref Sess, dlci, cred: int, p: array of byte): string
{
	n := len p;
	hlen := 3;
	if(n > 127)
		hlen = 4;
	extra := 0;
	if(cred > 0)
		extra = 1;
	f := array[hlen + extra + n + 1] of byte;
	f[0] = byte (16r03 | (dlci << 2));
	f[1] = byte Fuih;
	if(cred > 0)
		f[1] = byte (Fuih | Pf);
	if(hlen == 3)
		f[2] = byte ((n << 1) | 1);
	else {
		f[2] = byte (n << 1);
		f[3] = byte (n >> 7);
	}
	if(cred > 0)
		f[hlen] = byte cred;
	if(n > 0)
		f[hlen+extra:] = p;
	#
	# two bytes for a UIH frame and three for anything else: the
	# length is not covered here, which is the one place the frame
	# check sequence is not over the whole header
	#
	f[len f - 1] = byte fcs(f[0:2]);
	return l2cap->csend(s.m, s.ch, f);
}

#
# Every frame that arrives.  It runs alone, so a frame is dealt with
# whole before the next is looked at, and the answers it hands to
# whoever is waiting go through a channel rather than a lock.
#
reader(s: ref Sess)
{
	for(;;){
		(p, e) := l2cap->crecv(s.m, s.ch);
		if(e != nil){
			<-s.lock;
			if(s.dead == nil)
				s.dead = e;
			dl := s.dlcs;
			s.up = 0;
			s.lock <-= 1;
			for(; dl != nil; dl = tl dl)
				wake(hd dl);
			return;
		}
		frame(s, p);
	}
}

frame(s: ref Sess, p: array of byte)
{
	if(len p < 4)
		return;
	dlci := int p[0] >> 2;
	ctl := int p[1] & ~Pf;
	pf := (int p[1] & Pf) != 0;
	o := 2;
	n := int p[o] >> 1;
	if((int p[o] & 1) == 0){
		if(o + 2 > len p)
			return;
		n |= int p[o+1] << 7;
		o += 2;
	} else
		o++;
	cred := 0;
	if(ctl == Fuih && pf){
		if(o >= len p)
			return;
		cred = int p[o];
		o++;
	}
	if(o + n > len p)
		return;
	body := p[o:o+n];

	case ctl {
	Fua or Fdm =>
		alt {
		s.reply <-= (dlci, ctl, nil) =>	;
		* =>	;	# nobody is waiting
		}
	Fdisc =>
		#
		# the peer closing one.  It is answered whatever state
		# this side thinks the channel is in: a DISC left
		# unanswered is a peer waiting for ever.
		#
		spawn answer(s, dlci, Fua);
		<-s.lock;
		d := bydlci(s, dlci);
		if(d != nil){
			d.state = 2;
			d.err = "the peer closed the channel";
		}
		s.lock <-= 1;
		if(d != nil)
			wake(d);
	Fsabm =>
		#
		# A peer opening something.  DLCI 0 is the multiplexer
		# and is always answered -- a peer may start the session
		# rather than this side.  Any other is a server channel,
		# and is answered only if something here serves it.
		#
		if(dlci == 0){
			<-s.lock;
			s.up = 1;
			s.lock <-= 1;
			spawn answer(s, 0, Fua);
			return;
		}
		<-s.lock;
		sc := served(s, dlci >> 1);
		d := bydlci(s, dlci);
		if(sc != nil && d == nil)
			d = newdlc(s, dlci);
		s.lock <-= 1;
		if(sc == nil){
			spawn answer(s, dlci, Fdm);
			return;
		}
		spawn answer(s, dlci, Fua);
		<-s.lock;
		d.state = 1;
		d.given = Credits;
		s.lock <-= 1;
		#
		# and the first grant, so the peer may send without
		# waiting for this side to say anything
		#
		spawn opened(d, sc);
	Fuih =>
		if(cred > 0){
			<-s.lock;
			d := bydlci(s, dlci);
			if(d != nil)
				d.credits += cred;
			s.lock <-= 1;
			if(d != nil)
				wake(d);
		}
		if(dlci == 0){
			control(s, body);
			return;
		}
		if(n == 0)
			return;		# a grant and nothing else
		<-s.lock;
		d := bydlci(s, dlci);
		if(d != nil)
			d.given--;
		s.lock <-= 1;
		if(d == nil)
			return;
		alt {
		d.rq <-= body =>	;
		* =>	;		# the reader is behind: drop
		}
		wake(d);
	}
}

#
# a multiplexer control message.  A command is answered; an answer is
# handed to whoever asked.
#
control(s: ref Sess, p: array of byte)
{
	if(len p < 2)
		return;
	ty := int p[0] & 16rfc;
	cr := (int p[0] & 2) != 0;
	o := 1;
	n := int p[o] >> 1;
	if((int p[o] & 1) == 0){
		if(o + 2 > len p)
			return;
		n |= int p[o+1] << 7;
		o += 2;
	} else
		o++;
	if(o + n > len p)
		return;
	v := p[o:o+n];
	if(!cr){
		alt {
		s.reply <-= (0, ty, v) =>	;
		* =>	;
		}
		return;
	}
	#
	# a command from the peer.  Modem status is answered with the
	# same value, which is what says it was understood; anything
	# else is answered "not supported", which is a real answer and
	# better than silence.
	#
	if(ty == Mmsc){
		spawn answermcc(s, Mmsc, v);
		return;
	}
	if(ty == Mpn && len v >= 8){
		#
		# A peer asking about a channel before it opens one.  It
		# is answered here and not left to the SABM: the answer
		# is what settles the frame size and the credits, and a
		# peer told "not supported" gives up rather than asking
		# again.
		#
		dlci := int v[0] & 16r3f;
		fsize := int v[4] | (int v[5] << 8);
		if(fsize > Framesize || fsize < 1)
			fsize = Framesize;
		r := array[len v] of byte;
		r[0:] = v;
		r[1] = byte 16rf0;		# credit based, which is all this does
		r[4] = byte fsize;
		r[5] = byte (fsize >> 8);
		r[7] = byte Credits;		# what the peer may send us
		<-s.lock;
		if(served(s, dlci >> 1) != nil){
			d := bydlci(s, dlci);
			if(d == nil)
				d = newdlc(s, dlci);
			d.mtu = fsize;
			#
			# and what it has given us to send with, which is
			# in its request and nowhere else
			#
			d.credits = int v[7] & 7;
		}
		s.lock <-= 1;
		spawn answermcc(s, Mpn, r);
		return;
	}
	nsc := array[1] of byte;
	nsc[0] = p[0];
	spawn answermcc(s, Mnsc, nsc);
}

answermcc(s: ref Sess, ty: int, v: array of byte)
{
	p := array[2 + len v] of byte;
	p[0] = byte (ty | 16r01);	# an answer: the command bit is clear
	p[1] = byte ((len v << 1) | 1);
	p[2:] = v;
	uih(s, 0, 0, p);
}

answer(s: ref Sess, dlci, ty: int)
{
	f := array[4] of byte;
	f[0] = byte (16r03 | (dlci << 2));
	f[1] = byte (ty | Pf);
	f[2] = byte 16r01;
	f[3] = byte fcs(f[0:3]);
	l2cap->csend(s.m, s.ch, f);
}

# with the session lock held
bydlci(s: ref Sess, dlci: int): ref Dlc
{
	for(l := s.dlcs; l != nil; l = tl l)
		if((hd l).dlci == dlci)
			return hd l;
	return nil;
}

drop(s: ref Sess, d: ref Dlc)
{
	<-s.lock;
	nl: list of ref Dlc;
	for(l := s.dlcs; l != nil; l = tl l)
		if(hd l != d)
			nl = hd l :: nl;
	s.dlcs = nl;
	d.state = 2;
	s.lock <-= 1;
	wake(d);
}

wake(d: ref Dlc)
{
	alt {
	d.wake <-= 1 =>	;
	* =>	;
	}
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}
