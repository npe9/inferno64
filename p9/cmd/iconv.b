implement Iconv;

# A structural Limbo translation of Plan 9's iconv(1) -
# sys/src/cmd/iconv.c in the 9front tree, 102 lines - converts an image
# between pixel-channel formats (not text-encoding conversion, despite
# the name it shares with the better-known Unix iconv).
#
# Unlike every other translation in this tree so far, the actual image
# codec work here was never something to port: Inferno's Draw module
# (module/draw.m) already wraps Plan 9's own real libdraw/libmemdraw C
# functions directly - checked in libinterp/draw.c, not assumed:
# Chans.mk() calls strtochan(), Chans.text() calls chantostr(),
# Chans.depth() calls chantodepth(), and Display.readimage/writeimage/
# newimage/Image.draw/readpixels are the same shapes as
# readmemimage/writememimage/allocmemimage/memimagedraw/unloadmemimage.
# So this translation is mostly wiring those together in the same order
# the C does, not reimplementing an image format.
#
# The one piece with no direct Draw-module equivalent is
# writeuncompressed()'s hand-rolled "-u" output format (a plain text
# header line, five space-padded fields, followed by raw per-scanline
# pixel bytes - distinct from writeimage()'s own, possibly-compressed,
# wire format). bytesperline() below is a direct translation of this
# tree's own libdraw/bytesperline.c (the exact function Draw's own
# internals already use for the same calculation) - not reinvented,
# and kept in its non-obvious rect.min.x<0 case exactly as written
# there, not simplified to the common-case `(width*depth+7)/8` formula,
# since that only agrees with the real one when min.x happens to be 0.
#
# `-c chanstr`'s failure mode (a bad channel descriptor string) is
# Chans.mk()'s `.desc` coming back 0 - checked directly against
# libinterp/draw.c's Chans_mk, which just stores strtochan()'s raw
# return value with no separate error signal, matching the C's own
# `if(tochan==0) sysfatal(...)` check exactly.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	draw: Draw;
	Context, Display, Image, Chans, Point, Rect: import draw;

Iconv: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: same "real files throughout" shape as
	# join.b/split.b - iconv's whole job is real image files, there is
	# no meaningful string-only stand-in for that. display is passed in
	# (rather than allocated fresh) so a test can share one headless
	# Display across many calls instead of paying allocate() each time.
	run:	fn(display: ref Display, args: list of string, inpath: string, outpath: string): int;
};

stdin, stdout, stderr: ref FD;

fail(msg: string)
{
	sys->fprint(stderr, "iconv: %s\n", msg);
	raise "fail:iconv";
}

usage()
{
	fail("usage: iconv [-u] [-c chanstr] [file]");
}

getoptarg(w: string, rest: list of string): (string, list of string)
{
	if(len w > 2)
		return (w[2:], rest);
	if(rest == nil)
		usage();
	return (hd rest, tl rest);
}

# a direct translation of this tree's own libdraw/bytesperline.c
# (bytesperline(), not wordsperline()) - see header comment for why
# the r.min.x<0 branch is kept rather than simplified away.
bytesperline(r: Rect, d: int): int
{
	if(r.min.x >= 0)
		return (r.max.x*d + 7)/8 - (r.min.x*d)/8;
	t := (-r.min.x*d + 7)/8;
	return t + (r.max.x*d + 7)/8;
}

writeuncompressed(fd: ref FD, m: ref Image)
{
	chanstr := m.chans.text();
	if(chanstr == nil)
		fail("can't convert channel descriptor");
	hdr := sys->sprint("%11s %11d %11d %11d %11d ",
		chanstr, m.r.min.x, m.r.min.y, m.r.max.x, m.r.max.y);
	hbuf := array of byte hdr;
	sys->write(fd, hbuf, len hbuf);

	bpl := bytesperline(m.r, m.depth);
	buf := array[bpl] of byte;
	for(y := m.r.min.y; y < m.r.max.y; y++){
		rowr := Rect(Point(m.r.min.x, y), Point(m.r.max.x, y+1));
		j := m.readpixels(rowr, buf);
		if(j != bpl)
			fail("image unload failed");
		if(sys->write(fd, buf, bpl) != bpl)
			fail("write failed");
	}
}

# run(): the shared body behind both init() and the test seam - parses
# options, reads the input image, converts it, writes the result. Takes
# real file descriptors for input/output rather than deciding stdin/
# stdout itself, so the test seam can point both at real files.
convert(display: ref Display, args: list of string, infd: ref FD, outfd: ref FD): int
{
	tostr := "";
	havetostr := 0;
	uncompressed := 0;

	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		case w[1] {
		'c' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			tostr = v;
			havetostr = 1;
		'u' =>
			l = tl l;
			uncompressed = 1;
		* =>
			usage();
		}
	}

	nfiles := 0;
	for(x := l; x != nil; x = tl x)
		nfiles++;
	if(nfiles > 1)
		usage();

	m: ref Image;
	if(nfiles == 1){
		m = display.open(hd l);
		if(m == nil)
			fail("can't read " + hd l);
	} else {
		m = display.readimage(infd);
		if(m == nil)
			fail("can't read image");
	}

	tochan: Chans;
	if(havetostr){
		tochan = Chans.mk(tostr);
		if(tochan.desc == 0)
			fail("bad channel descriptor '" + tostr + "'");
	} else
		tochan = m.chans;

	n := display.newimage(m.r, tochan, 0, Draw->Nofill);
	if(n == nil)
		fail("can't allocate new image");

	n.draw(n.r, m, nil, m.r.min);

	if(uncompressed)
		writeuncompressed(outfd, n);
	else if(display.writeimage(outfd, n) < 0)
		fail("write failed");
	return 0;
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	draw = load Draw Draw->PATH;

	display: ref Display;
	if(ctxt == nil)
		display = Display.allocate(nil);
	else
		display = ctxt.display;
	if(display == nil)
		fail("can't open display");

	convert(display, tl argv, stdin, stdout);
}

run(display: ref Display, args: list of string, inpath: string, outpath: string): int
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(draw == nil)
		draw = load Draw Draw->PATH;

	infd := sys->open(inpath, Sys->OREAD);
	if(infd == nil)
		fail("run: cannot open " + inpath);
	outfd := sys->create(outpath, Sys->OWRITE, 8r666);
	if(outfd == nil)
		fail("run: cannot create " + outpath);
	return convert(display, args, infd, outfd);
}
