implement Avdtp;

#
# AVDTP: the signalling under A2DP.
#
# It is a small request-response protocol on an L2CAP channel to PSM
# 25, and then a second channel to the same PSM which is the media
# itself.  What the signalling settles is which stream endpoint on the
# far side is going to be used and what it is configured to carry;
# after that the media channel is a pipe and AVDTP has nothing more to
# say until the stream is stopped.
#
# A message is a transaction label, a packet type, a message type, a
# signal identifier and a payload.  Only single-packet messages are
# sent here; a fragmented one that arrives is reassembled, because a
# capability list from a device with several codecs will not fit in a
# small MTU and it is the one message that routinely does not.
#
# What is not here is a codec.  A2DP is AVDTP plus SBC, and SBC is not
# implemented: this can find a sink, ask what it can do, configure it
# and open and start a stream, and what goes down the media channel is
# whatever the caller hands it.  Nothing here can turn sound into SBC
# or back, and that is said plainly rather than left to be discovered
# by hearing nothing.
#
# On 9front this is one C file: the same message reader.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;

#
# Message types, in the low two bits of the first byte.  The two
# rejections are the way round they look wrong: 1 is the general
# reject, which says the signal itself was not understood and carries
# no reason, and 3 is the response reject, which is the answer to a
# request that was understood and refused and carries the reason.
#
Mcommand:	con 0;
Mgeneral:	con 1;
Maccept:	con 2;
Mreject:	con 3;

# packet types, in bits 2 and 3
Psingle:	con 0;
Pstart:		con 1;
Pcontinue:	con 2;
Pend:		con 3;

Rtx:		con 10000;	# ms to wait for an answer

init(b: Bt): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	return nil;
}

start(fd: ref Sys->FD): ref Sess
{
	s := ref Sess;
	s.fd = fd;
	s.label = 0;
	return s;
}

#
# One command and its answer.  The transaction label is what pairs
# them, and it is checked: a device answering a label nobody asked
# about is answering something else, and taking it would be reading
# one question's answer as another's.
#
request(s: ref Sess, sig: int, p: array of byte): (array of byte, string)
{
	if(s == nil)
		return (nil, "no signalling channel");
	lab := s.label;
	s.label = (s.label + 1) & 16rf;
	m := array[2 + len p] of byte;
	m[0] = byte ((lab << 4) | (Psingle << 2) | Mcommand);
	m[1] = byte sig;
	if(len p > 0)
		m[2:] = p;
	if(sys->write(s.fd, m, len m) != len m)
		return (nil, sys->sprint("%r"));

	for(;;){
		(r, e) := message(s);
		if(e != nil)
			return (nil, e);
		if(len r < 2)
			continue;
		if((int r[0] >> 4) != lab)
			continue;	# an answer to something already given up on
		ty := int r[0] & 3;
		if(int r[1] != sig)
			continue;
		case ty {
		Maccept =>
			return (r[2:], nil);
		Mreject =>
			return (nil, rejected(sig, r[2:]));
		Mgeneral =>
			return (nil, "the device does not know that request");
		}
	}
}

#
# One whole message, reassembled if it arrived in pieces.  A start
# packet says how many packets are coming; the rest carry one byte of
# header each and are joined on to it.
#
message(s: ref Sess): (array of byte, string)
{
	b := array[1024] of byte;
	n := sys->read(s.fd, b, len b);
	if(n < 0)
		return (nil, sys->sprint("%r"));
	if(n < 2)
		return (nil, "a signalling message of " + string n + " bytes");
	pt := (int b[0] >> 2) & 3;
	if(pt == Psingle)
		return (b[0:n], nil);
	if(pt != Pstart)
		return (nil, "a continuation of a message that never started");
	if(n < 3)
		return (nil, "a start packet with no signal in it");
	#
	# a start packet is label, packet count, signal, and then the
	# payload; what is rebuilt is the single packet it would have
	# been
	#
	hdr := array[2] of byte;
	hdr[0] = byte ((int b[0] & 16rf0) | (Psingle << 2) | (int b[0] & 3));
	hdr[1] = b[2];
	acc := b[3:n];
	for(;;){
		n = sys->read(s.fd, b, len b);
		if(n < 0)
			return (nil, sys->sprint("%r"));
		if(n < 1)
			return (nil, "a continuation of no bytes");
		pt = (int b[0] >> 2) & 3;
		na := array[len acc + n - 1] of byte;
		na[0:] = acc;
		na[len acc:] = b[1:n];
		acc = na;
		if(pt == Pend)
			break;
		if(pt != Pcontinue)
			return (nil, "a message that neither continues nor ends");
	}
	r := array[2 + len acc] of byte;
	r[0:] = hdr;
	r[2:] = acc;
	return (r, nil);
}

#
# A rejection carries the signal's own error code, and for the
# configuration signals the capability category that was refused
# before it.  Saying which is what tells a caller what to ask for
# instead.
#
rejected(sig: int, p: array of byte): string
{
	if(sig == Ssetconfig || sig == Sreconfigure){
		if(len p < 2)
			return "the device refused the configuration";
		return sys->sprint("the device refused %s: %s",
			capname(int p[0]), errname(int p[1]));
	}
	if(len p < 1)
		return "the device refused the request";
	return "the device refused the request: " + errname(int p[0]);
}

errname(e: int): string
{
	case e {
	16r01 =>	return "a bad header format";
	16r11 =>	return "a bad length";
	16r12 =>	return "a bad endpoint";
	16r13 =>	return "a bad media type";
	16r17 =>	return "a bad state";
	16r18 =>	return "a bad service category";
	16r19 =>	return "a bad payload format";
	16r1a =>	return "an unsupported configuration";
	16r22 =>	return "the endpoint is in use";
	16r31 =>	return "the endpoint is not configured";
	}
	return sys->sprint("error %#2.2ux", e);
}

capname(c: int): string
{
	case c {
	Cmediatransport =>	return "media transport";
	Creporting =>		return "reporting";
	Crecovery =>		return "recovery";
	Ccontent =>		return "content protection";
	Cheader =>		return "header compression";
	Cmultiplexing =>	return "multiplexing";
	Cmediacodec =>		return "the codec";
	Cdelayreport =>		return "delay reporting";
	}
	return sys->sprint("category %#2.2ux", c);
}

#
# Every stream endpoint the device has.  Two bytes each: the
# identifier and whether it is in use, then the media type and
# whether it is a source or a sink.
#
discover(s: ref Sess): (list of ref Sep, string)
{
	(r, e) := request(s, Sdiscover, nil);
	if(e != nil)
		return (nil, e);
	l: list of ref Sep;
	for(i := 0; i + 2 <= len r; i += 2){
		p := ref Sep;
		p.seid = int r[i] >> 2;
		p.inuse = (int r[i] & 2) != 0;
		p.media = int r[i+1] >> 4;
		p.sink = (int r[i+1] & 8) != 0;
		p.caps = nil;
		l = p :: l;
	}
	rl: list of ref Sep;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return (rl, nil);
}

#
# What one endpoint can do.  A capability is a category, a length and
# that many bytes; the codec one is the interesting one and its bytes
# are the codec's own business, which is why they are handed back
# rather than interpreted here.
#
capabilities(s: ref Sess, seid: int): (list of ref Cap, string)
{
	p := array[1] of byte;
	p[0] = byte (seid << 2);
	(r, e) := request(s, Sgetcaps, p);
	if(e != nil)
		return (nil, e);
	l: list of ref Cap;
	for(i := 0; i + 2 <= len r; ){
		c := ref Cap;
		c.cat = int r[i];
		n := int r[i+1];
		if(i + 2 + n > len r)
			break;
		c.info = r[i+2:i+2+n];
		l = c :: l;
		i += 2 + n;
	}
	rl: list of ref Cap;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return (rl, nil);
}

#
# Configure a stream: which endpoint of theirs, which of ours, and the
# capabilities it is to run with.  Media transport is always in the
# list because a stream that does not carry media is not a stream.
#
setconfig(s: ref Sess, acp, int0: int, caps: list of ref Cap): string
{
	body := array[0] of byte;
	for(l := caps; l != nil; l = tl l){
		c := hd l;
		one := array[2 + len c.info] of byte;
		one[0] = byte c.cat;
		one[1] = byte len c.info;
		if(len c.info > 0)
			one[2:] = c.info;
		nb := array[len body + len one] of byte;
		nb[0:] = body;
		nb[len body:] = one;
		body = nb;
	}
	p := array[2 + len body] of byte;
	p[0] = byte (acp << 2);
	p[1] = byte (int0 << 2);
	p[2:] = body;
	(nil, e) := request(s, Ssetconfig, p);
	return e;
}

#
# and the three that move a stream along.  Each is the endpoint
# identifier and nothing else, which is why they are one function.
#
open(s: ref Sess, seid: int): string
{
	return simple(s, Sopen, seid);
}

startstream(s: ref Sess, seid: int): string
{
	return simple(s, Sstart, seid);
}

close(s: ref Sess, seid: int): string
{
	return simple(s, Sclose, seid);
}

suspend(s: ref Sess, seid: int): string
{
	return simple(s, Ssuspend, seid);
}

simple(s: ref Sess, sig, seid: int): string
{
	p := array[1] of byte;
	p[0] = byte (seid << 2);
	(nil, e) := request(s, sig, p);
	return e;
}

#
# Choosing an SBC configuration out of what a sink says it can do.
#
# An SBC capability is four bytes: the sampling frequencies and
# channel modes it will take, the block lengths, subbands and
# allocation methods, and the smallest and largest bitpool.  Each of
# the first three is a set of bits and a configuration is one bit out
# of each set -- so this is not negotiation in the sense of meeting in
# the middle, it is picking one of the things the sink already said it
# would do.
#
# What is picked is the best of what is offered: the highest sampling
# frequency, joint stereo if it will, the longest blocks, eight
# subbands and loudness allocation, which is what every A2DP source
# picks and for the same reason -- they are the settings that sound
# best at a given bitpool.
#
sbcchoose(c: ref Cap): (ref Cap, string, string)
{
	if(c == nil || c.cat != Cmediacodec)
		return (nil, nil, "not a codec capability");
	if(len c.info < 6)
		return (nil, nil, "a codec capability of " + string len c.info + " bytes");
	if(int c.info[0] != Maudio)
		return (nil, nil, "not an audio codec");
	if(int c.info[1] != Vsbc)
		return (nil, nil, sys->sprint("codec %#2.2ux, which is not SBC", int c.info[1]));
	freqs := int c.info[2] >> 4;
	modes := int c.info[2] & 16rf;
	blocks := int c.info[3] >> 4;
	subs := (int c.info[3] >> 2) & 3;
	alloc := int c.info[3] & 3;
	lo := int c.info[4];
	hi := int c.info[5];

	(fbit, fname) := pick4(freqs, array[] of {"16000", "32000", "44100", "48000"});
	(mbit, mname) := pick4(modes, array[] of {"mono", "dual", "stereo", "joint"});
	(bbit, bname) := pick4(blocks, array[] of {"4", "8", "12", "16"});
	(sbit, sname) := pick2(subs, array[] of {"4", "8"});
	(abit, aname) := pick2(alloc, array[] of {"snr", "loudness"});
	if(fbit == 0 || mbit == 0 || bbit == 0 || sbit == 0 || abit == 0)
		return (nil, nil, "the sink offered no usable configuration");
	if(lo < 2 || hi > 250 || lo > hi)
		return (nil, nil, sys->sprint("a bitpool range of %d to %d", lo, hi));

	r := ref Cap;
	r.cat = Cmediacodec;
	r.info = array[6] of byte;
	r.info[0] = byte Maudio;
	r.info[1] = byte Vsbc;
	r.info[2] = byte ((fbit << 4) | mbit);
	r.info[3] = byte ((bbit << 4) | (sbit << 2) | abit);
	r.info[4] = byte lo;
	r.info[5] = byte hi;
	return (r, sys->sprint("sbc %s %s blocks %s subbands %s %s bitpool %d-%d",
		fname, mname, bname, sname, aname, lo, hi), nil);
}

#
# The best bit set in a field, and its name.
#
# In every one of these fields the best value is the lowest bit, which
# is the opposite of what it looks like: the frequencies run 16000,
# 32000, 44100, 48000 from the top bit down, and so do the block
# lengths, and joint stereo and loudness are the bottom bit of theirs.
# So this walks up from the bottom.
#
# Getting it the other way round is not a crash: it picks 16000 mono
# four blocks four subbands, which is the worst of everything the sink
# offered, and the stream still opens and still plays.  Which is why
# the bench asserts what was chosen and not only that something was.
#
pick4(v: int, names: array of string): (int, string)
{
	for(i := 0; i < 4; i++)
		if(v & (1 << i))
			return (1 << i, names[3-i]);
	return (0, nil);
}

pick2(v: int, names: array of string): (int, string)
{
	for(i := 0; i < 2; i++)
		if(v & (1 << i))
			return (1 << i, names[1-i]);
	return (0, nil);
}

#
# One media packet.  The header is RTP's: version 2, no padding, no
# extension, one contributing source of zero, the payload type, a
# sequence number, a timestamp and a synchronisation source.  What
# goes after it is the codec's, and there is no codec here.
#
media(seq, stamp, ssrc, pt: int, payload: array of byte): array of byte
{
	p := array[12 + len payload] of byte;
	#
	# RTP is big endian, so the numbers go in by hand: bt's put16
	# and put32 are the other way round and would be wrong here.
	#
	p[0] = byte 16r80;		# version 2
	p[1] = byte (pt & 16r7f);
	p[2] = byte (seq >> 8);
	p[3] = byte seq;
	p[4] = byte (stamp >> 24);
	p[5] = byte (stamp >> 16);
	p[6] = byte (stamp >> 8);
	p[7] = byte stamp;
	p[8] = byte (ssrc >> 24);
	p[9] = byte (ssrc >> 16);
	p[10] = byte (ssrc >> 8);
	p[11] = byte ssrc;
	if(len payload > 0)
		p[12:] = payload;
	return p;
}

#
# One SBC frame of silence for a configured capability.
#
# The frame is a four byte header -- syncword, the five fields packed
# into one byte, the bitpool, a CRC -- and then the scale factors and
# the sample bits, all of which are zero.  A frame of zeroes is a
# legal bitstream that decodes to silence; what has to be right is the
# header, the length, and the CRC over the header and the fields the
# spec says it covers.
#
# The length is the spec's own formula and depends on the channel
# mode, because joint stereo carries a join bit per subband that the
# other modes do not.  Getting it wrong makes a frame that a
# dissector, and a sink, will reject; there is no way to get it wrong
# quietly.
#
sbcsilence(c: ref Cap): (array of byte, string)
{
	if(c == nil || c.cat != Cmediacodec || len c.info < 6)
		return (nil, "not a codec capability");
	if(int c.info[0] != Maudio || int c.info[1] != Vsbc)
		return (nil, "not an SBC configuration");
	#
	# A configuration has one value in each field, unlike a
	# capability, which has every value the endpoint will take.  If
	# more than one bit is set here then what was passed is what a
	# sink offered rather than what was agreed with it.
	#
	freq := one4(int c.info[2] >> 4);
	mode := one4(int c.info[2] & 16rf);
	blks := one4(int c.info[3] >> 4);
	subs := one2((int c.info[3] >> 2) & 3);
	alloc := one2(int c.info[3] & 3);
	if(freq < 0 || mode < 0 || blks < 0 || subs < 0 || alloc < 0)
		return (nil, "not one value in each field: a capability and not a configuration");

	nsb := 4;
	if(subs == 1)
		nsb = 8;
	nbl := 4 + 4 * blks;			# 4, 8, 12 or 16
	nch := 2;
	if(mode == 0)				# mono
		nch = 1;
	bp := int c.info[5];			# the top of the agreed range
	if(bp < 2 || bp > 250)
		return (nil, sys->sprint("a bitpool of %d", bp));

	#
	# allocation_method is 0 for loudness and 1 for SNR, which is
	# the other way round from the order the capability bits are
	# in.  subbands is 0 for four and 1 for eight, which is the
	# same order.  This is the sort of thing that is wrong for a
	# long time without failing.
	#
	amethod := 1 - alloc;			# capability 0 is snr
	b1 := (freq << 6) | (blks << 4) | (mode << 2) | (amethod << 1) | subs;

	scale := 4 * nsb * nch / 8;		# whole bytes in every case
	abits: int;
	case mode {
	0 or 1 =>				# mono, dual
		abits = nbl * nch * bp;
	2 =>					# stereo
		abits = nbl * bp;
	* =>					# joint: a join bit per subband
		abits = nsb + nbl * bp;
	}
	n := 4 + scale + (abits + 7) / 8;

	f := array[n] of {* => byte 0};
	f[0] = byte 16r9c;			# the syncword
	f[1] = byte b1;
	f[2] = byte bp;

	#
	# The CRC covers the second and third bytes of the header and
	# then, without the syncword and without the CRC itself, the
	# join bits if this is joint stereo and every scale factor.
	# All of those are zero here, so what is left is to run the
	# right number of them through it.
	#
	k := 4 * nch * nsb;
	if(mode == 3)
		k += nsb;
	crc := 16r0f;
	crc = crcbyte(crc, b1);
	crc = crcbyte(crc, bp);
	for(i := 0; i < k; i++)
		crc = crcbit(crc, 0);
	f[3] = byte crc;
	return (f, nil);
}

#
# The samples per channel in one frame of that configuration: the
# blocks times the subbands.  -1 if the capability is not one.
#
sbcsamples(c: ref Cap): int
{
	if(c == nil || c.cat != Cmediacodec || len c.info < 6)
		return -1;
	if(int c.info[0] != Maudio || int c.info[1] != Vsbc)
		return -1;
	blks := one4(int c.info[3] >> 4);
	subs := one2((int c.info[3] >> 2) & 3);
	if(blks < 0 || subs < 0)
		return -1;
	nsb := 4;
	if(subs == 1)
		nsb = 8;
	return (4 + 4 * blks) * nsb;
}

#
# Which value a field holds, or -1 if it does not hold exactly one.
# The capability bits run the other way from the values they stand
# for: the top bit is the first value.
#
one4(v: int): int
{
	for(i := 0; i < 4; i++)
		if(v == (1 << i))
			return 3 - i;
	return -1;
}
one2(v: int): int
{
	for(i := 0; i < 2; i++)
		if(v == (1 << i))
			return 1 - i;
	return -1;
}

#
# SBC's CRC: eight bits, polynomial 0x1D, and it starts at 0x0F rather
# than at zero or at all ones.  It is taken a bit at a time because
# what it covers is not a whole number of bytes: joint stereo with
# four subbands covers thirty six bits.
#
crcbit(crc, bit: int): int
{
	t := ((crc >> 7) & 1) ^ bit;
	crc = (crc << 1) & 16rff;
	if(t)
		crc ^= 16r1d;
	return crc;
}
crcbyte(crc, b: int): int
{
	for(i := 7; i >= 0; i--)
		crc = crcbit(crc, (b >> i) & 1);
	return crc;
}
