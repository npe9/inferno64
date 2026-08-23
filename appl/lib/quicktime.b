implement QuickTime;

include "sys.m";

sys: Sys;

include "quicktime.m";

init()
{
	sys = load Sys Sys->PATH;
}

open(file: string): (ref QD, string)
{
	fd := sys->open(file, sys->OREAD);
	if(fd == nil)
		return (nil, "open failed");

	r := ref QD;
	r.fd = fd;
	r.buf = array[DEFBUF] of byte;

	(hdr, l) := r.atomhdr();
	if(hdr != "mdat")
		return (nil, "not a QuickTime movie file");

	#
	# We are expecting a unified file with .data then .rsrc
	#
	r.skipatom(l);

	return (r, nil);
}

QD.atomhdr(r: self ref QD): (string, int)
{
	b := array[8] of byte;

	if(r.readn(b, 8) != 8)
		return (nil, -1);

	return (string b[4:8], bedword(b, 0));
}

QD.skipatom(r: self ref QD, l: int): int
{
	return r.skip(l - AtomHDR);
}

QD.mvhd(q: self ref QD, l: int): string
{
	l -= AtomHDR;
	if(l != MvhdrSIZE)
		return "mvhd atom funny size";

	b := array[l] of byte;
	if(q.readn(b, l) != l)
		return "short read in mvhd";

	mvhdr := ref Mvhdr;

	mvhdr.version = bedword(b, 0);
	mvhdr.create = bedword(b, 4);
	mvhdr.modtime = bedword(b, 8);
	mvhdr.timescale = bedword(b, 12);
	mvhdr.duration = bedword(b, 16);
	mvhdr.rate = bedword(b, 20);
	mvhdr.vol = beword(b, 24);
	mvhdr.r1 = bedword(b, 26);
	mvhdr.r2 = bedword(b, 30);

	mvhdr.matrix = array[9] of int;
	for(i :=0; i<9; i++)
		mvhdr.matrix[i] = bedword(b, 34+i*4);

	mvhdr.r3 = beword(b, 70);
	mvhdr.r4 = bedword(b, 72);
	mvhdr.pvtime = bedword(b, 76);
	mvhdr.posttime = bedword(b, 80);
	mvhdr.seltime = bedword(b, 84);
	mvhdr.seldurat = bedword(b, 88);
	mvhdr.curtime = bedword(b, 92);
	mvhdr.nxttkid = bedword(b, 96);

	q.mvhdr = mvhdr;
	return nil;
}

QD.trak(q: self ref QD, l: int): string
{
	(tk, tkl) := q.atomhdr();
	if(tk != "tkhd")
		return "missing track header atom";

	l -= tkl;
	tkl -= AtomHDR;
	b := array[tkl] of byte;
	if(q.readn(b, tkl) != tkl)
		return "short read in tkhd";

	tkhdr := ref Tkhdr;

	tkhdr.version =	bedword(b, 0);
	tkhdr.creation = bedword(b, 4);
	tkhdr.modtime =	bedword(b, 8);
	tkhdr.trackid =	bedword(b, 12);
	tkhdr.timescale = bedword(b, 16);
	tkhdr.duration = bedword(b, 20);
	tkhdr.timeoff = bedword(b, 24);
	tkhdr.priority = bedword(b, 28);
	tkhdr.layer = beword(b, 32);
	tkhdr.altgrp = beword(b, 34);
	tkhdr.volume = beword(b, 36);

	tkhdr.matrix = array[9] of int;
	for(i := 0; i < 9; i++)
		tkhdr.matrix[i] = bedword(b, 38+i*4);

	tkhdr.width = bedword(b, 74);
	tkhdr.height = bedword(b, 78);

	(md, mdl) := q.atomhdr();
	if(md != "mdia")
		return "missing media atom";

	while(mdl != AtomHDR) {
		(atom, atoml) := q.atomhdr();
sys->print("\t%s %d\n", atom, atoml);
		q.skipatom(atoml);

		mdl -= atoml;
	}

	return nil;
}

QD.readn(r: self ref QD, b: array of byte, l: int): int
{
	if(r.nbyte < l) {
		c := 0;
		if(r.nbyte != 0) {
			b[0:] = r.buf[r.ptr:];
			l -= r.nbyte;
			c += r.nbyte;
			b = b[r.nbyte:];
		}
		bsize := len r.buf;
		while(l != 0) {
			r.nbyte = sys->read(r.fd, r.buf, bsize);
			if(r.nbyte <= 0) {
				r.nbyte = 0;
				return -1;
			}
			n := l;
			if(n > bsize)
				n = bsize;

			r.ptr = 0;
			b[0:] = r.buf[0:n];
			b = b[n:];
			r.nbyte -= n;
			r.ptr += n;
			l -= n;
			c += n;
		}
		return c;
	}
	b[0:] = r.buf[r.ptr:r.ptr+l];
	r.nbyte -= l;
	r.ptr += l;
	return l;
}

QD.skip(r: self ref QD, size: int): int
{
	if(r.nbyte != 0) {
		n := size;
		if(n > r.nbyte)
			n = r.nbyte;
		r.ptr += n;
		r.nbyte -= n;
		size -= n;
		if(size == 0)
			return 0;
	}
	return int sys->seek(r.fd, big size, sys->SEEKRELA);
}

beword(b: array of byte, o: int): int
{
	return 	(int b[o] << 8) | int b[o+1];
}

bedword(b: array of byte, o: int): int
{
	return	(int b[o] << 24) |
		(int b[o+1] << 16) |
		(int b[o+2] << 8) |
		int b[o+3];
}

#
# Sample tables.
#
# The reader above is sequential and parses headers only. Sample tables need
# seeking: the tables are in moov while the samples they describe are in mdat,
# and the two are in no fixed order. So this walks the file by offset instead.
#
# What comes out is enough to drive a decoder: for each track, the codec, its
# setup data (the avcC payload for H.264, which a hardware decoder must be
# given before any sample), and every sample's offset, size, duration and
# whether it is a sync sample.
#

Atom: adt
{
	kind:	string;
	off:	big;	# of the atom's contents
	size:	big;	# of the contents, header excluded
};

# Atom header: 4-byte size then 4-byte type. size 1 means a 64-bit size
# follows the type; size 0 means "to end of file".
atomat(fd: ref Sys->FD, off, limit: big): (ref Atom, string)
{
	b := array[16] of byte;

	if(sys->seek(fd, off, Sys->SEEKSTART) != off)
		return (nil, "seek failed");
	if(sys->readn(fd, b, 8) != 8)
		return (nil, nil);		# clean end
	sz := big beu32(b, 0) & big 16rffffffff;	# masked: atoms can exceed 2^31
	kind := string b[4:8];
	hdr := big 8;
	if(sz == big 1){
		if(sys->readn(fd, b[8:], 8) != 8)
			return (nil, "truncated 64-bit atom size");
		sz = beu64(b, 8);
		hdr = big 16;
	}else if(sz == big 0)
		sz = limit - off;
	if(sz < hdr || off + sz > limit)
		return (nil, sys->sprint("atom %#q has a bad size", kind));
	a := ref Atom;
	a.kind = kind;
	a.off = off + hdr;
	a.size = sz - hdr;
	return (a, nil);
}

# Unsigned, and that is not a formality here: an int in this tree holds more
# than 32 bits, so 255<<24 does NOT wrap negative and this returns the true
# value even above 2^31. Printing one with %d is what misleads - %d shows the
# low 32 bits, so 16rffffff88 prints as -120 while arithmetic on it uses
# 4294967176. Where a signed field is wanted, use bes32.
beu32(b: array of byte, o: int): int
{
	return (int b[o]<<24) | (int b[o+1]<<16) | (int b[o+2]<<8) | int b[o+3];
}

beu64(b: array of byte, o: int): big
{
	# Both halves masked: beu32 is signed, so an unmasked high word would
	# sign-extend and an unmasked low word would corrupt the result.
	return ((big beu32(b, o) & big 16rffffffff) << 32) |
		(big beu32(b, o+4) & big 16rffffffff);
}

# A 32-bit field that is genuinely signed. Sign extension has to be explicit
# because beu32 does not wrap: ctts version 1 offsets are signed by the
# specification, and version 0 offsets are nominally unsigned but real files
# carry negative values there anyway - this tree's own test movie, written by
# the platform's encoder, has a version 0 ctts holding -120 and -60.
bes32(b: array of byte, o: int): int
{
	v := big beu32(b, o) & big 16rffffffff;
	if(v >= big 16r80000000)
		v -= big 16r100000000;
	return int v;
}

beu16(b: array of byte, o: int): int
{
	return (int b[o]<<8) | int b[o+1];
}

readat(fd: ref Sys->FD, off: big, n: int): array of byte
{
	if(n <= 0 || n > 64*1024*1024)
		return nil;
	if(sys->seek(fd, off, Sys->SEEKSTART) != off)
		return nil;
	b := array[n] of byte;
	if(sys->readn(fd, b, n) != n)
		return nil;
	return b;
}

# Children of a container atom, in order.
children(fd: ref Sys->FD, a: ref Atom): list of ref Atom
{
	l: list of ref Atom;
	end := a.off + a.size;
	for(off := a.off; off < end;){
		(c, err) := atomat(fd, off, end);
		if(c == nil || err != nil)
			break;
		l = c :: l;
		off = c.off + c.size;
	}
	return rev(l);
}

rev(l: list of ref Atom): list of ref Atom
{
	r: list of ref Atom;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

find(l: list of ref Atom, kind: string): ref Atom
{
	for(; l != nil; l = tl l)
		if((hd l).kind == kind)
			return hd l;
	return nil;
}

tracks(file: string): (array of ref Track, string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", file));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sys->sprint("stat %s: %r", file));
	limit := d.length;

	# Top level: find moov, wherever it is. Some writers put it after the
	# media data, some before, and ftyp is usually first.
	moov: ref Atom;
	for(off := big 0; off < limit;){
		(a, err) := atomat(fd, off, limit);
		if(err != nil)
			return (nil, err);
		if(a == nil)
			break;
		if(a.kind == "moov"){
			moov = a;
			break;
		}
		off = a.off + a.size;
	}
	if(moov == nil)
		return (nil, "no moov atom: not a QuickTime or MP4 file");

	ts: list of ref Track;
	for(kids := children(fd, moov); kids != nil; kids = tl kids){
		if((hd kids).kind != "trak")
			continue;
		(t, err) := onetrack(fd, hd kids);
		if(err != nil)
			return (nil, err);
		if(t != nil)
			ts = t :: ts;
	}
	if(ts == nil)
		return (nil, "no tracks");

	n := len ts;
	a := array[n] of ref Track;
	for(i := n-1; ts != nil; ts = tl ts)
		a[i--] = hd ts;
	return (a, nil);
}

onetrack(fd: ref Sys->FD, trak: ref Atom): (ref Track, string)
{
	t := ref Track;
	t.timescale = 1;

	kids := children(fd, trak);
	tkhd := find(kids, "tkhd");
	if(tkhd != nil){
		b := readat(fd, tkhd.off, int tkhd.size);
		# version(1) flags(3) then times; the id and the fixed-point
		# width/height sit at different offsets in v0 and v1.
		if(b != nil && len b >= 84){
			v := int b[0];
			if(v == 0 && len b >= 84){
				t.id = beu32(b, 12);
				t.width = beu32(b, 76) >> 16;
				t.height = beu32(b, 80) >> 16;
			}else if(len b >= 96){
				t.id = beu32(b, 20);
				t.width = beu32(b, 88) >> 16;
				t.height = beu32(b, 92) >> 16;
			}
		}
	}

	mdia := find(kids, "mdia");
	if(mdia == nil)
		return (nil, nil);		# not a media track: skip it
	mkids := children(fd, mdia);

	mdhd := find(mkids, "mdhd");
	if(mdhd != nil){
		b := readat(fd, mdhd.off, int mdhd.size);
		if(b != nil && len b >= 20){
			if(int b[0] == 0)
				t.timescale = beu32(b, 12);
			else if(len b >= 28)
				t.timescale = beu32(b, 20);
		}
	}
	if(t.timescale <= 0)
		t.timescale = 1;

	hdlr := find(mkids, "hdlr");
	if(hdlr != nil){
		b := readat(fd, hdlr.off, int hdlr.size);
		if(b != nil && len b >= 12)
			t.kind = string b[8:12];
	}

	minf := find(mkids, "minf");
	if(minf == nil)
		return (nil, nil);
	stbl := find(children(fd, minf), "stbl");
	if(stbl == nil)
		return (nil, nil);
	skids := children(fd, stbl);

	err := sampledesc(fd, skids, t);
	if(err != nil)
		return (nil, err);
	err = buildsamples(fd, skids, t);
	if(err != nil)
		return (nil, err);
	return (t, nil);
}

# stsd: the codec and its setup data. For avc1 the setup is the avcC box
# nested inside the sample entry, after a fixed 78-byte visual header.
sampledesc(fd: ref Sys->FD, skids: list of ref Atom, t: ref Track): string
{
	stsd := find(skids, "stsd");
	if(stsd == nil)
		return nil;
	b := readat(fd, stsd.off, int stsd.size);
	if(b == nil || len b < 16)
		return nil;
	nent := beu32(b, 4);
	if(nent < 1)
		return nil;
	esz := beu32(b, 8);
	if(esz < 8 || 8+esz > len b)
		return nil;
	t.codec = string b[12:16];

	# Walk the boxes nested inside the sample entry for the setup box.
	# A SampleEntry is 8 bytes of box header, 6 reserved and a 2-byte data
	# reference index; a VisualSampleEntry adds 70 more (pre_defined,
	# width/height, resolutions, frame count, the 32-byte compressor name,
	# depth). So nested boxes begin 86 bytes into the entry, and the entry
	# itself begins 8 bytes into stsd's contents.
	o := 8 + 86;
	while(o + 8 <= 8 + esz){
		bsz := beu32(b, o);
		kind := string b[o+4:o+8];
		if(bsz < 8 || o + bsz > 8 + esz)
			break;
		if(kind == "avcC" || kind == "hvcC" || kind == "esds"){
			t.extra = b[o+8:o+bsz];
			break;
		}
		o += bsz;
	}
	return nil;
}

# Combine stsc (samples per chunk), stco/co64 (chunk offsets), stsz (sizes),
# stts (durations) and stss (sync samples) into a flat list.
buildsamples(fd: ref Sys->FD, skids: list of ref Atom, t: ref Track): string
{
	stsz := find(skids, "stsz");
	stsc := find(skids, "stsc");
	stco := find(skids, "stco");
	co64 := find(skids, "co64");
	if(stco == nil)
		stco = co64;
	if(stsz == nil || stsc == nil || stco == nil)
		return nil;			# no samples: leave the track empty

	zb := readat(fd, stsz.off, int stsz.size);
	cb := readat(fd, stsc.off, int stsc.size);
	ob := readat(fd, stco.off, int stco.size);
	if(zb == nil || cb == nil || ob == nil)
		return "unreadable sample table";
	if(len zb < 12 || len cb < 8 || len ob < 8)
		return "short sample table";

	uniform := beu32(zb, 4);
	nsamp := beu32(zb, 8);
	if(nsamp <= 0)
		return nil;
	if(uniform == 0 && len zb < 12 + nsamp*4)
		return "short sample size table";

	nchunk := beu32(ob, 4);
	wide := co64 != nil && stco == co64;
	need := 8 + nchunk * 4;
	if(wide)
		need = 8 + nchunk * 8;
	if(nchunk <= 0 || len ob < need)
		return "short chunk offset table";

	nsc := beu32(cb, 4);
	if(nsc <= 0 || len cb < 8 + nsc*12)
		return "short sample-to-chunk table";

	samples := array[nsamp] of Sample;
	si := 0;
	for(c := 0; c < nchunk && si < nsamp; c++){
		# How many samples in this chunk: the last stsc run whose
		# first_chunk is at or before this one. Chunk numbers are
		# 1-based in the file.
		per := 0;
		for(k := 0; k < nsc; k++){
			first := beu32(cb, 8 + k*12);
			if(first <= c+1)
				per = beu32(cb, 8 + k*12 + 4);
			else
				break;
		}
		if(per <= 0)
			continue;
		coff: big;
		if(wide)
			coff = beu64(ob, 8 + c*8);
		else
			coff = big beu32(ob, 8 + c*4) & big 16rffffffff;
		for(j := 0; j < per && si < nsamp; j++){
			sz := uniform;
			if(uniform == 0)
				sz = beu32(zb, 12 + si*4);
			samples[si].off = coff;
			samples[si].size = sz;
			coff += big sz;
			si++;
		}
	}
	if(si < nsamp)
		samples = samples[0:si];

	durations(fd, skids, samples);
	compoffsets(fd, skids, samples);
	syncs(fd, skids, samples);
	t.samples = samples;
	return nil;
}

durations(fd: ref Sys->FD, skids: list of ref Atom, s: array of Sample)
{
	stts := find(skids, "stts");
	if(stts == nil)
		return;
	b := readat(fd, stts.off, int stts.size);
	if(b == nil || len b < 8)
		return;
	n := beu32(b, 4);
	if(len b < 8 + n*8)
		return;
	si := 0;
	for(k := 0; k < n && si < len s; k++){
		cnt := beu32(b, 8 + k*8);
		delta := beu32(b, 8 + k*8 + 4);
		for(j := 0; j < cnt && si < len s; j++)
			s[si++].delta = delta;
	}
}

# ctts gives each sample's composition offset, present when the stream codes
# frames out of display order. Without it a caller decoding in file order gets
# the pictures in decode order, which for a stream with B-frames is not the
# order they are meant to be shown in.
compoffsets(fd: ref Sys->FD, skids: list of ref Atom, s: array of Sample)
{
	ctts := find(skids, "ctts");
	if(ctts == nil)
		return;			# no reordering: coff stays 0
	b := readat(fd, ctts.off, int ctts.size);
	if(b == nil || len b < 8)
		return;
	n := beu32(b, 4);
	if(len b < 8 + n*8)
		return;
	si := 0;
	for(k := 0; k < n && si < len s; k++){
		cnt := beu32(b, 8 + k*8);
		off := bes32(b, 8 + k*8 + 4);
		for(j := 0; j < cnt && si < len s; j++)
			s[si++].coff = off;
	}
}

# stss lists the sync samples; when it is absent every sample is a sync
# sample, which is what an all-keyframe codec produces.
syncs(fd: ref Sys->FD, skids: list of ref Atom, s: array of Sample)
{
	stss := find(skids, "stss");
	if(stss == nil){
		for(i := 0; i < len s; i++)
			s[i].sync = 1;
		return;
	}
	b := readat(fd, stss.off, int stss.size);
	if(b == nil || len b < 8)
		return;
	n := beu32(b, 4);
	if(len b < 8 + n*4)
		return;
	for(k := 0; k < n; k++){
		i := beu32(b, 8 + k*4) - 1;	# 1-based in the file
		if(i >= 0 && i < len s)
			s[i].sync = 1;
	}
}
