implement Command;

#
# Tests draw(3)'s /dev/draw/N/video decode verb: hardware image decode
# straight into a draw image's pixels.
#
# Talks the draw protocol directly rather than going through the Draw module,
# because the verb names its destination by image id and libdraw does not
# expose ids to Limbo. That is the right interface for the device - the id is
# how every other draw message names an image - so the test uses it the way
# libdraw itself does.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "string.m";
	str: String;
include "draw.m";
	draw: Draw;
	Chans: import draw;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Jpg:	con "/lib/ebooks/oebtest/DrBill.jpg";
Mov:	con "/lib/movies/test.mov";
# 65 wide on purpose: 65*4 = 260 bytes per row, which is NOT the aligned
# stride Metal wants, so a texture-backed image has a different width from the
# natural one. That is exactly the case where getting Memimage.width or .zero
# wrong puts every row at the wrong offset, and a decoded photograph read back
# through the draw protocol would show it.
W:	con 65;
H:	con 65;
Id:	con 1;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

p32(b: array of byte, o: int, v: int)
{
	b[o]   = byte v;
	b[o+1] = byte (v>>8);
	b[o+2] = byte (v>>16);
	b[o+3] = byte (v>>24);
}

prect(b: array of byte, o, x0, y0, x1, y1: int)
{
	p32(b, o,    x0);
	p32(b, o+4,  y0);
	p32(b, o+8,  x1);
	p32(b, o+12, y1);
}

# 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] r[16] clipr[16] color[4]
allocimage(data: ref Sys->FD, id, cdesc: int): string
{
	m := array[1+4+4+1+4+1+16+16+4] of byte;
	m[0] = byte 'b';
	p32(m, 1, id);
	p32(m, 5, 0);			# no screen: an offscreen image
	m[9] = byte 0;			# refresh
	p32(m, 10, cdesc);
	m[14] = byte 0;			# not replicated
	prect(m, 15, 0, 0, W, H);
	prect(m, 31, 0, 0, W, H);
	p32(m, 47, 0);			# initial colour
	if(sys->write(data, m, len m) != len m)
		return sprint("alloc image: %r");
	return nil;
}

# 'r' id[4] r[16], then the pixels come back from the next read.
readpixels(data: ref Sys->FD, id: int): (array of byte, string)
{
	m := array[1+4+16] of byte;
	m[0] = byte 'r';
	p32(m, 1, id);
	prect(m, 5, 0, 0, W, H);
	if(sys->write(data, m, len m) != len m)
		return (nil, sprint("read request: %r"));
	want := W*H*4;
	buf := array[want] of byte;
	off := 0;
	while(off < want){
		n := sys->read(data, buf[off:], want - off);
		if(n <= 0)
			return (nil, sprint("read pixels at %d: %r", off));
		off += n;
	}
	return (buf, nil);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	draw = load Draw Draw->PATH;
	if(str == nil || draw == nil){
		print("drawdecodetest: load: %r\n");
		raise "fail:load";
	}

	# /dev/draw is not in a plain command's namespace - drawmux(1) binds it
	# for the window system. Bind it here for the same reason it does.
	if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
		print("drawdecodetest: bind #i: %r\n");
		raise "fail:no draw";
	}

	# Opening /dev/draw/new turns the fd into that new client's ctl file,
	# whose first field is the client number.
	ctl := sys->open("/dev/draw/new", Sys->ORDWR);
	if(ctl == nil){
		print("drawdecodetest: no /dev/draw: %r\n");
		raise "fail:no draw";
	}
	cbuf := array[12*12] of byte;
	n := sys->read(ctl, cbuf, len cbuf);
	if(n < 12){
		print("drawdecodetest: short ctl read: %r\n");
		raise "fail:ctl";
	}
	(cid, nil) := str->toint(str->drop(string cbuf[0:n], " "), 10);

	data := sys->open(sprint("/dev/draw/%d/data", cid), Sys->ORDWR);
	video := sys->open(sprint("/dev/draw/%d/video", cid), Sys->OWRITE);
	if(data == nil || video == nil){
		print("drawdecodetest: open client %d: %r\n", cid);
		raise "fail:open";
	}

	cd := Chans.mk("x8r8g8b8");
	if((e := allocimage(data, Id, cd.desc)) != nil){
		bad(e);
		raise "fail:test";
	}

	# Before: the image was allocated with colour 0, so every byte is 0.
	(before, e2) := readpixels(data, Id);
	if(e2 != nil){
		bad(e2);
		raise "fail:test";
	}
	nz := 0;
	for(i := 0; i < len before; i++)
		if(before[i] != byte 0)
			nz++;
	if(nz != 0)
		bad(sprint("image was not zero before decode: %d non-zero bytes", nz));

	cmd := array of byte sprint("decode %d %s", Id, Jpg);
	if(sys->write(video, cmd, len cmd) != len cmd){
		bad(sprint("decode: %r"));
		raise "fail:test";
	}

	(after, e3) := readpixels(data, Id);
	if(e3 != nil){
		bad(e3);
		raise "fail:test";
	}

	# A decoded photograph is neither blank nor uniform. Checking both
	# catches the two ways this fails quietly: nothing written at all, and
	# a solid fill from a decode that silently produced nothing.
	nz = 0;
	distinct := 0;
	seen := array[256] of { * => 0 };
	for(i = 0; i < len after; i++){
		if(after[i] != byte 0)
			nz++;
		if(seen[int after[i]] == 0){
			seen[int after[i]] = 1;
			distinct++;
		}
	}
	if(nz == 0)
		bad("nothing was written into the image");
	else if(distinct < 16)
		bad(sprint("only %d distinct byte values: decode produced a flat image", distinct));
	else
		print("  decoded %s into a %dx%d image: %d non-zero bytes, %d distinct values\n",
			Jpg, W, H, nz, distinct);

	movie(data, video);

	if(fail)
		raise "fail:test";
	print("PASS\n");
}

# The test movie is flat colour per frame: frame i is rgb(20+20i, 128,
# 220-20i). Flat blocks, so even lossy H.264 lands within a few counts of the
# intended value - which is what lets this assert a colour rather than merely
# "something was written".
movie(data, video: ref Sys->FD)
{
	for(f := 0; f < 3; f++){
		cmd := array of byte sprint("frame %d %d %s", Id, f, Mov);
		if(sys->write(video, cmd, len cmd) != len cmd){
			bad(sprint("frame %d: %r", f));
			return;
		}
		(px, e) := readpixels(data, Id);
		if(e != nil){
			bad(e);
			return;
		}
		# x8r8g8b8 is b,g,r,x in memory order; sample the middle pixel.
		o := ((H/2)*W + W/2) * 4;
		b := int px[o];
		g := int px[o+1];
		r := int px[o+2];
		wr := 20 + f*20;
		wb := 220 - f*20;
		if(abs(r-wr) > 12 || abs(g-128) > 12 || abs(b-wb) > 12)
			bad(sprint("frame %d: got rgb(%d,%d,%d) want about rgb(%d,128,%d)",
				f, r, g, b, wr, wb));
		else
			print("  frame %d: rgb(%d,%d,%d), expected about rgb(%d,128,%d)\n",
				f, r, g, b, wr, wb);
	}
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}
