implement Bnep;

#
# BNEP: ethernet frames over L2CAP.
#
# A BNEP link is a wire with exactly two ends, so most of an ethernet
# header is known before it arrives: a frame from the peer is from the
# peer and to us, and there is nothing to say.  That is what the
# compressed packet types are -- the same frame with the addresses
# that could have been worked out left out.
#
# The addresses are the two BD_ADDRs.  A Bluetooth link already has
# two six byte addresses on it, so PAN needs to invent none: the
# ethernet this serves is addressed by the same numbers the link is.
#
# What crosses the interface here is a whole ethernet frame either
# way, because that is what the thing above wants -- devip's ether
# medium reads and writes frames -- and putting the compression here
# rather than there is what keeps Bluetooth out of the IP stack.
#
# On 9front this is one C file with the same two functions.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;

Ehdr:	con 14;		# destination, source, type
Maxframe:	con 1600;	# an ethernet frame and the BNEP header on it

init(b: Bt): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	return nil;
}

#
# One packet out and one in.  The file underneath is btfs's, and it
# promises what BNEP needs: a write is one SDU and a read is the next
# SDU whole, so there is no framing to do here beyond BNEP's own.
#
put(l: ref Link, p: array of byte): string
{
	if(sys->write(l.fd, p, len p) != len p)
		return sys->sprint("%r");
	return nil;
}

get(fd: ref Sys->FD): (array of byte, string)
{
	b := array[Maxframe] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return (nil, sys->sprint("%r"));
	if(n == 0)
		return (nil, "the network went away");
	return (b[0:n], nil);
}

#
# The setup exchange.  A BNEP link is not usable until it has happened:
# what it settles is which of the two ends is the network access point
# and which is the user, and a peer that will not agree says so with a
# response code rather than by going quiet.
#
start(fd: ref Sys->FD, local, remote: array of byte,
	dst, src: string): (ref Link, string)
{
	if(fd == nil)
		return (nil, "no channel to the network service");
	d := bt->unhex(dst);
	s := bt->unhex(src);
	if(len d != len s || (len d != 2 && len d != 4 && len d != 16))
		return (nil, "the two service uuids must be the same size");

	p := array[3 + len d + len s] of byte;
	p[0] = byte Tcontrol;
	p[1] = byte Csetup;
	p[2] = byte len d;
	p[3:] = d;
	p[3+len d:] = s;
	l0 := ref Link(fd, local, remote);
	if((e := put(l0, p)) != nil)
		return (nil, e);

	#
	# The answer, and only the answer: a peer may send other
	# control messages -- a filter set, say -- before it gets to
	# this one, and they are not it.
	#
	for(;;){
		(r, re) := get(fd);
		if(re != nil)
			return (nil, re);
		if(len r < 2)
			continue;
		if((int r[0] & ~Text) != Tcontrol)
			continue;
		if(int r[1] != Csetupresp)
			continue;
		if(len r < 4)
			return (nil, "a setup response with no reason in it");
		code := (int r[2] << 8) | int r[3];
		if(code != 0)
			return (nil, setuperr(code));
		return (l0, nil);
	}
}

setuperr(code: int): string
{
	case code {
	1 =>	return "the peer does not know that size of service uuid";
	2 =>	return "the peer will not be that service";
	3 =>	return "this side may not be that service";
	4 =>	return "the peer refused the connection";
	}
	return sys->sprint("the peer refused the network: reason %#4.4ux", code);
}

#
# One ethernet frame out.  It goes as a general packet, with both
# addresses written down, because a frame from the thing above may be
# addressed to anything: a bridge on the other side of the access
# point, a multicast group, anything that is not the peer itself.
# Compressing it would be asserting something about the addresses that
# this layer does not know.
#
send(l: ref Link, f: array of byte): string
{
	if(l == nil)
		return "no network";
	if(len f < Ehdr)
		return "an ethernet frame of " + string len f + " bytes";
	p := array[1 + len f] of byte;
	p[0] = byte Tgeneral;
	p[1:] = f;
	return put(l, p);
}

#
# One frame in, with whatever the peer left out put back.  A
# compressed packet's addresses are the link's own: the source is the
# peer and the destination is this side, because a link has two ends
# and the frame came in on it.
#
recv(l: ref Link): (array of byte, string)
{
	if(l == nil)
		return (nil, "no network");
	for(;;){
		(p, e) := get(l.fd);
		if(e != nil)
			return (nil, e);
		if(len p < 1)
			continue;
		ty := int p[0] & ~Text;
		ext := (int p[0] & Text) != 0;
		o := 1;
		dst, src: array of byte;
		case ty {
		Tgeneral =>
			if(len p < 1 + 12)
				continue;
			dst = p[o:o+Bt->Baddrlen];
			src = p[o+Bt->Baddrlen:o+12];
			o += 12;
		Tcompressed =>
			dst = l.local;
			src = l.remote;
		Tsrconly =>
			if(len p < 1 + Bt->Baddrlen)
				continue;
			dst = l.local;
			src = p[o:o+Bt->Baddrlen];
			o += Bt->Baddrlen;
		Tdstonly =>
			if(len p < 1 + Bt->Baddrlen)
				continue;
			dst = p[o:o+Bt->Baddrlen];
			src = l.remote;
			o += Bt->Baddrlen;
		Tcontrol =>
			#
			# Not a frame.  A peer is entitled to send these
			# whenever it likes -- a filter it wants set, or
			# a message this side does not know -- and one
			# that is not understood is answered rather than
			# ignored, because a peer waiting for an answer
			# is a link that stops.
			#
			control(l, p[1:]);
			continue;
		* =>
			continue;
		}
		#
		# extension headers, which may be chained: each is a
		# type byte whose top bit says another follows, a length
		# byte, and that many bytes.  Nothing here acts on one;
		# stepping over them is what lets the frame behind them
		# through.
		#
		while(ext){
			if(o + 2 > len p)
				break;
			ext = (int p[o] & 16r80) != 0;
			n := int p[o+1];
			o += 2 + n;
		}
		if(o + 2 > len p)
			continue;
		#
		# and the frame, put back together: the two addresses,
		# the type, and the payload.  What the caller gets is
		# what would have been on a wire.
		#
		f := array[Ehdr + (len p - o - 2)] of byte;
		f[0:] = dst;
		f[Bt->Baddrlen:] = src;
		f[12:] = p[o:o+2];		# the ethernet type
		f[Ehdr:] = p[o+2:];
		return (f, nil);
	}
}

#
# A control message from the peer.  Filters are accepted and not
# applied: this side sends every frame it is given and hands up every
# frame it gets, so a filter it agreed to and ignored would be a lie.
# Saying the message is not understood is the truth and is what the
# specification provides for.
#
control(l: ref Link, p: array of byte)
{
	if(len p < 1)
		return;
	ty := int p[0];
	if(ty == Csetupresp || ty == Cnotunderstood)
		return;		# an answer, or an answer to an answer
	r := array[3] of byte;
	r[0] = byte Tcontrol;
	r[1] = byte Cnotunderstood;
	r[2] = byte ty;
	spawn later(l, r);
}

#
# from a process of its own: this runs in whoever is reading frames,
# and sending takes an ACL buffer that may not be there yet
#
later(l: ref Link, p: array of byte)
{
	put(l, p);
}
