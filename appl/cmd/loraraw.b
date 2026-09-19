implement Loraraw;

#
# A RadioHead peer built by hand, on the raw packet device.
#
# lorachk(1) checks #L against itself, which cannot catch a header this
# tree agrees with and nobody else does.  This writes and reads the four
# bytes directly on /dev/radio0/data, from the specification rather than
# from os/inferno/radio/devlora.c:
#
#	to from id flags
#
# with 255 the broadcast address, 0x80 the acknowledge flag, 0x40 the
# retry flag, and "!" the payload of an acknowledgement -- RadioHead's
# RH_RF95 driver and lib/pycubed_rfm9x.py both.  If #L and this
# disagree about any of it, one of them is not speaking to a PyCubed.
#
#	loraraw hear n		print n frames, whatever they are
#	loraraw poke to from id flags text
#				one frame, exactly as given
#	loraraw ackpeer me n	take n frames for me and acknowledge each
#	loraraw deaf me n	take n frames for me and acknowledge none,
#				which is what makes the other end retry
#

include "sys.m";
	sys: Sys;
include "draw.m";

Loraraw: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Data:	con "/dev/radio0/data";
Hdrlen:	con 4;
Fack:	con 16r80;
Fretry:	con 16r40;

fd: ref Sys->FD;

Frame: adt {
	dst:	int;
	from:	int;
	id:	int;
	flags:	int;
	payload: string;
};

get(): ref Frame
{
	b := array[255] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0){
		sys->print("loraraw: read: %r\n");
		return nil;
	}
	if(n < Hdrlen){
		sys->print("loraraw: RUNT %d bytes\n", n);
		return nil;
	}
	return ref Frame(int b[0], int b[1], int b[2], int b[3],
		string b[Hdrlen:n]);
}

show(what: string, f: ref Frame)
{
	sys->print("%s to %d from %d id %d flags %#x payload %q\n",
		what, f.dst, f.from, f.id, f.flags, f.payload);
}

put(f: ref Frame): int
{
	p := array of byte f.payload;
	b := array[Hdrlen + len p] of byte;
	b[0] = byte f.dst;
	b[1] = byte f.from;
	b[2] = byte f.id;
	b[3] = byte f.flags;
	b[Hdrlen:] = p;
	n := sys->write(fd, b, len b);
	if(n != len b){
		sys->print("loraraw: write: %d %r\n", n);
		return -1;
	}
	return n;
}

hear(count: int)
{
	for(i := 0; i < count; i++){
		f := get();
		if(f == nil)
			continue;
		show("RAW", f);
	}
}

# Acknowledge what is addressed here, the way RadioHead does: the
# sender's address, the identifier it used, the ACK flag, and "!".
ackpeer(me, count: int)
{
	for(i := 0; i < count; i++){
		f := get();
		if(f == nil)
			continue;
		show("RAW", f);
		if(f.dst != me || (f.flags & Fack))
			continue;
		if(put(ref Frame(f.from, me, f.id, Fack, "!")) > 0)
			sys->print("RAWACK to %d id %d\n", f.from, f.id);
	}
}

# Take frames and say nothing.  The other end must retransmit with the
# same identifier and the retry flag set on every attempt after the
# first; anything else is not RadioHead.
deaf(me, count: int)
{
	firstid := -1;
	nretry := 0;
	ok := 1;
	for(i := 0; i < count; i++){
		f := get();
		if(f == nil)
			continue;
		show("RAW", f);
		if(f.dst != me)
			continue;
		if(firstid < 0){
			firstid = f.id;
			if(f.flags & Fretry){
				sys->print("RAWDEAF first attempt had retry set\n");
				ok = 0;
			}
		}else{
			if(f.id != firstid){
				sys->print("RAWDEAF id %d, wanted %d\n",
					f.id, firstid);
				ok = 0;
			}
			if((f.flags & Fretry) == 0){
				sys->print("RAWDEAF retransmission without retry flag\n");
				ok = 0;
			}else
				nretry++;
		}
	}
	sys->print("RAWDEAF id %d retries %d\n", firstid, nretry);
	if(ok && nretry > 0)
		sys->print("RAWDEAF-OK\n");
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->print("usage: loraraw hear|poke|ackpeer|deaf ...\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	fd = sys->open(Data, Sys->ORDWR);
	if(fd == nil){
		sys->print("loraraw: %s: %r\n", Data);
		return;
	}

	case mode {
	"hear" =>
		n := 1;
		if(argv != nil)
			n = int hd argv;
		hear(n);
	"poke" =>
		a := array[5] of string;
		for(i := 0; i < 5 && argv != nil; i++){
			a[i] = hd argv;
			argv = tl argv;
		}
		if(a[4] == nil){
			sys->print("usage: loraraw poke to from id flags text\n");
			return;
		}
		f := ref Frame(int a[0], int a[1], int a[2], int a[3], a[4]);
		if(put(f) > 0)
			show("RAWSENT", f);
	"ackpeer" =>
		if(argv == nil)
			return;
		me := int hd argv;
		n := 1;
		if(tl argv != nil)
			n = int hd tl argv;
		ackpeer(me, n);
	"deaf" =>
		if(argv == nil)
			return;
		me := int hd argv;
		n := 3;
		if(tl argv != nil)
			n = int hd tl argv;
		deaf(me, n);
	* =>
		sys->print("loraraw: %s?\n", mode);
	}
}
