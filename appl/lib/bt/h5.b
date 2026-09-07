implement Bttransport;

#
# The H5 HCI transport, the three-wire UART one: what a module speaks
# when it has no hardware flow control to spare.  H4 puts a type byte
# in front of a packet and trusts the wire; H5 does not trust it, and
# adds framing, a header, sequence numbers, acknowledgement and
# retransmission on top of the same two wires.
#
# Three things stacked on each other:
#
#	SLIP framing.  0xc0 delimits a packet; 0xdb escapes, with
#	0xdc for a delimiter and 0xdd for an escape.  So a packet's
#	boundaries survive any payload, which is what H4 has no
#	answer for at all when a byte is dropped.
#
#	A four byte header.  Three bits of sequence, three of
#	acknowledgement, a bit saying whether a CRC follows, a bit
#	saying whether the packet is reliable; then the packet type
#	and a twelve bit length split across two bytes; then a
#	checksum of the other three, which is their sum complemented.
#
#	A link protocol.  Sync until the peer answers, configure
#	until it answers, and only then is the link up.  A controller
#	that resets underneath us starts sending sync again, and that
#	is how this side finds out.
#
# The window is one packet.  H5 allows up to seven outstanding, and
# more would be faster; one is what makes the sender a loop rather
# than a queue with a timer per entry, and the difference matters only
# on a link fast enough that the round trip dominates -- which a
# 115200 baud uart carrying HCI is not.  The configuration field says
# one, so a conforming peer sends one at a time as well.
#
# No CRC.  The bit is there and the configuration negotiates it; this
# advertises that it does not want one, and a packet that arrives with
# one anyway is dropped with a word rather than misread.  The header
# checksum covers the header, and the SLIP framing plus the length
# catch a truncated payload; what a CRC adds is detection of a
# corrupted payload of the right length, which on a short uart run is
# not what goes wrong.
#
# On 9front this is one C file over the same /dev/eia*.
#

include "sys.m";
	sys: Sys;
include "dial.m";
	dial: Dial;
include "bt.m";
	bt: Bt;

# SLIP
Delim:		con 16rc0;
Escape:		con 16rdb;
Escdelim:	con 16rdc;
Escescape:	con 16rdd;

# H5 packet types, in the header's type field
Tack:		con 16r00;	# an acknowledgement and nothing else
Tlink:		con 16r0f;	# link establishment

# link establishment messages
Msyncreq :=	array[] of {byte 16r01, byte 16r7e};
Msyncresp :=	array[] of {byte 16r02, byte 16r7d};
Mconfreq :=	array[] of {byte 16r03, byte 16rfc, byte 16r01};
Mconfresp :=	array[] of {byte 16r04, byte 16r7b};

Retry:		con 250;	# ms before a reliable packet goes again
Tries:		con 20;		# how many times before giving up
Linkwait:	con 100;	# ms between sync or configuration attempts
Linktries:	con 100;	# how long to keep trying, in those units

Maxpkt:		con 4095;	# the header's length field is twelve bits

# link states
Uninit, Init, Active: con iota;

fd:	ref Sys->FD;
opened:	int;
state:	int;

txseq:	int;			# the sequence number of the next packet out
txack:	int;			# what to acknowledge in the next packet out
rxack:	int;			# what the peer has acknowledged
lock:	chan of int;		# one sender at a time
acked:	chan of int;		# the reader tells the sender an ack arrived
up:	chan of (int, array of byte);	# whole HCI packets, to read()
crcseen: int;

init(b: Bt, spec: string): string
{
	sys = load Sys Sys->PATH;
	bt = b;

	(n, f) := sys->tokenize(spec, "!");
	if(n < 1)
		return "no controller named";
	if(hd f == "tcp" || hd f == "net" || hd f == "il"){
		dial = load Dial Dial->PATH;
		if(dial == nil)
			return sys->sprint("cannot load %s: %r", Dial->PATH);
		c := dial->dial(spec, nil);
		if(c == nil)
			return sys->sprint("cannot dial %s: %r", spec);
		fd = c.dfd;
	}else{
		fd = sys->open(hd f, Sys->ORDWR);
		if(fd == nil)
			return sys->sprint("cannot open %s: %r", hd f);
		if(n > 1)
			setspeed(hd f, hd tl f);
	}
	opened = 1;
	state = Uninit;
	txseq = 0;
	txack = 0;
	rxack = 0;
	lock = chan[1] of int;
	lock <-= 1;
	acked = chan[1] of int;
	up = chan[8] of (int, array of byte);
	spawn reader();
	return establish();
}

setspeed(name, speed: string)
{
	cfd := sys->open(name + "ctl", Sys->OWRITE);
	if(cfd != nil)
		sys->fprint(cfd, "b%s", speed);
}

#
# Sync, then configure.  Both are sent again until they are answered,
# which is what the specification says to do and what makes this
# survive a controller that is not listening yet -- a module powered
# up a moment ago, which is the ordinary case.
#
establish(): string
{
	for(i := 0; i < Linktries && state == Uninit; i++){
		send(0, 0, Tlink, Msyncreq);
		sys->sleep(Linkwait);
	}
	if(state == Uninit)
		return "the controller never answered a sync";
	for(i = 0; i < Linktries && state == Init; i++){
		send(0, 0, Tlink, Mconfreq);
		sys->sleep(Linkwait);
	}
	if(state != Active)
		return "the controller never answered the configuration";
	return nil;
}

#
# One packet out, framed.  Nothing here waits: the reliability is in
# write() above it, because an acknowledgement is only meaningful for
# a reliable packet and this is also how acks and link messages go.
#
send(seq, rel, ptype: int, p: array of byte): string
{
	if(len p > Maxpkt)
		return sys->sprint("a %d byte packet: the most H5 frames is %d", len p, Maxpkt);
	h := array[4] of byte;
	h0 := seq & 7;
	h0 |= (txack & 7) << 3;
	if(rel)
		h0 |= 16r80;
	h[0] = byte h0;
	h[1] = byte ((ptype & 16r0f) | ((len p & 16r0f) << 4));
	h[2] = byte ((len p >> 4) & 16rff);
	h[3] = byte (16rff - ((int h[0] + int h[1] + int h[2]) & 16rff));

	#
	# The worst case is every byte escaped, so the buffer is twice
	# the packet plus the two delimiters.  Built whole and written
	# once: a write to a uart is atomic in the kernel's output
	# queue, and a packet written in pieces could be interleaved
	# with another sender's.
	#
	w := array[2 + 2*(4 + len p)] of byte;
	n := 0;
	w[n++] = byte Delim;
	for(i := 0; i < 4; i++)
		n = slip(w, n, int h[i]);
	for(i = 0; i < len p; i++)
		n = slip(w, n, int p[i]);
	w[n++] = byte Delim;
	if(sys->write(fd, w[0:n], n) != n)
		return sys->sprint("%r");
	return nil;
}

slip(w: array of byte, n, c: int): int
{
	case c {
	Delim =>
		w[n++] = byte Escape;
		w[n++] = byte Escdelim;
	Escape =>
		w[n++] = byte Escape;
		w[n++] = byte Escescape;
	* =>
		w[n++] = byte c;
	}
	return n;
}

#
# A reliable packet, and the retransmission that makes it reliable.
# One at a time: the window is one, so the sequence number cannot get
# ahead of what has been acknowledged.
#
write(ptype: int, p: array of byte): string
{
	if(!opened)
		return "the transport is not open";
	<-lock;
	if(state != Active){
		lock <-= 1;
		return "the H5 link is not up";
	}
	#
	# drain a stale acknowledgement before starting: one left over
	# from the packet before would end this one immediately, and
	# the packet would go once and never be checked.
	#
	alt {
	<-acked =>	;
	* =>	;
	}
	seq := txseq;
	e: string;
	for(i := 0; i < Tries; i++){
		if((e = send(seq, 1, ptype, p)) != nil)
			break;
		tick := chan[1] of int;
		spawn timer(Retry, tick);
		alt {
		<-acked =>
			if(((rxack - seq) & 7) >= 1){
				txseq = (seq + 1) & 7;
				lock <-= 1;
				return nil;
			}
			# an acknowledgement of something else: keep waiting
		<-tick =>
			;
		}
		if(state != Active){
			e = "the H5 link went down";
			break;
		}
	}
	if(e == nil)
		e = sys->sprint("no acknowledgement for packet %d after %d tries", seq, Tries);
	lock <-= 1;
	return e;
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

read(): (int, array of byte, string)
{
	if(!opened)
		return (0, nil, "the transport is not open");
	(ptype, p) := <-up;
	if(ptype == 0 && p == nil)
		return (0, nil, "the H5 link closed");
	return (ptype, p, nil);
}

close()
{
	opened = 0;
	fd = nil;
}

#
# The one process that reads the byte stream.  It unframes, checks the
# header, acknowledges what arrives, answers the link protocol, and
# passes HCI packets up.  Everything that has to happen whether or not
# anyone is reading happens here, which is why acknowledgement cannot
# live in read().
#
reader()
{
	buf := array[512] of byte;
	pkt := array[2 + 4 + Maxpkt] of byte;
	n := 0;
	esc := 0;
	inframe := 0;
	while(opened){
		nr := sys->read(fd, buf, len buf);
		if(nr <= 0)
			break;
		for(i := 0; i < nr; i++){
			c := int buf[i];
			if(c == Delim){
				#
				# A delimiter both ends a packet and
				# begins the next, and two in a row are
				# allowed, so an empty frame is not an
				# error -- it is the idle pattern some
				# controllers send.
				#
				if(inframe && n > 0)
					frame(pkt[0:n]);
				n = 0;
				esc = 0;
				inframe = 1;
				continue;
			}
			if(!inframe)
				continue;	# rubbish before the first delimiter
			if(esc){
				esc = 0;
				case c {
				Escdelim =>	c = Delim;
				Escescape =>	c = Escape;
				* =>
					sys->fprint(sys->fildes(2),
						"h5: %#2.2ux after an escape, dropping the packet\n", c);
					n = 0;
					inframe = 0;
					continue;
				}
			}else if(c == Escape){
				esc = 1;
				continue;
			}
			if(n >= len pkt){
				sys->fprint(sys->fildes(2), "h5: a packet longer than %d, dropping it\n", len pkt);
				n = 0;
				inframe = 0;
				continue;
			}
			pkt[n++] = byte c;
		}
	}
	opened = 0;
	alt {
	up <-= (0, nil) =>	;
	* =>	;
	}
}

frame(p: array of byte)
{
	if(len p < 4)
		return;
	sum := (int p[0] + int p[1] + int p[2]) & 16rff;
	if(int p[3] != 16rff - sum){
		sys->fprint(sys->fildes(2), "h5: header checksum %#2.2ux, wanted %#2.2ux\n",
			int p[3], 16rff - sum);
		return;
	}
	seq := int p[0] & 7;
	ack := (int p[0] >> 3) & 7;
	crc := (int p[0] >> 6) & 1;
	rel := (int p[0] >> 7) & 1;
	ptype := int p[1] & 16r0f;
	dlen := ((int p[1] >> 4) & 16r0f) | (int p[2] << 4);
	if(len p < 4 + dlen){
		sys->fprint(sys->fildes(2), "h5: %d bytes of payload, header said %d\n",
			len p - 4, dlen);
		return;
	}
	if(crc){
		#
		# We said in the configuration that we do not want one.
		# A peer that sends one anyway is not conforming, and
		# reading past it would be reading the CRC as payload.
		#
		if(!crcseen++)
			sys->fprint(sys->fildes(2),
				"h5: the controller sends a CRC we did not ask for; dropping those packets\n");
		return;
	}
	body := p[4:4+dlen];

	#
	# What the peer has acknowledged, for the sender to see.  Sent
	# whether or not anyone is waiting: the sender drains a stale
	# one before it starts.
	#
	rxack = ack;
	alt {
	acked <-= 1 =>	;
	* =>	;
	}

	if(ptype == Tlink){
		linkmsg(body);
		return;
	}
	if(rel){
		#
		# In order or not at all.  A packet whose sequence is
		# not the one expected is one the peer sent again
		# because our acknowledgement was lost: acknowledge it
		# again and drop it, or it would be delivered twice.
		#
		if(seq != txack){
			send(0, 0, Tack, nil);
			return;
		}
		txack = (txack + 1) & 7;
		send(0, 0, Tack, nil);
	}
	if(ptype == Tack)
		return;			# it was only an acknowledgement
	if(state != Active)
		return;			# nothing above is listening yet
	q := array[dlen] of byte;
	q[0:] = body;
	alt {
	up <-= (ptype, q) =>	;
	* =>
		sys->fprint(sys->fildes(2), "h5: nothing is reading; dropping a packet\n");
	}
}

linkmsg(p: array of byte)
{
	if(len p < 2)
		return;
	if(same(p, Msyncreq)){
		#
		# The peer is synchronising.  If we thought the link was
		# up, it has reset underneath us and everything in
		# flight is gone; say so and go back to the beginning.
		#
		if(state == Active)
			sys->fprint(sys->fildes(2), "h5: the controller resynchronised\n");
		state = Uninit;
		txseq = 0;
		txack = 0;
		send(0, 0, Tlink, Msyncresp);
		return;
	}
	if(same(p, Msyncresp)){
		if(state == Uninit)
			state = Init;
		return;
	}
	if(len p >= 2 && int p[0] == 16r03 && int p[1] == 16rfc){
		send(0, 0, Tlink, Mconfresp);
		return;
	}
	if(len p >= 2 && int p[0] == 16r04 && int p[1] == 16r7b){
		if(state == Init){
			state = Active;
			txseq = 0;
			txack = 0;
		}
		return;
	}
}

same(a, b: array of byte): int
{
	if(len a < len b)
		return 0;
	for(i := 0; i < len b; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}
