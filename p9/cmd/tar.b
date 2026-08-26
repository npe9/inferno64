implement Tar;

# A structural Limbo translation of Plan 9's real tar(1) -
# sys/src/cmd/tar.c in the 9front tree, 1588 lines: reads and writes
# POSIX ustar archives, with GNU long-name and PAX extended-header
# support for interop with foreign archives. See doc/plan9-port.md for
# the translation-not-workalike discipline this follows, and
# doc/plan9-port.md's own entry for this file for the fuller derivation
# this comment summarises.
#
# THE ORACLE: better than most of this backlog. ustar is a format both
# ends of this port agree on independently of any Plan 9 binary, and a
# real tar/bsdtar exists on this host. tartest.b uses it both ways:
# archive with the host's tar, extract with this one, and vice versa -
# a live bidirectional oracle, not a hand-derived expectation.
#
# WHAT THE MISSING fork()/exec() REMOVES. Checked, not assumed: grep
# across module/*.m turns up no fork/exec/pipe-to-a-host-command
# primitive anywhere Limbo can reach - Dis processes are lightweight
# threads inside one module image, not new host processes, and there
# is no equivalent of Plan 9's push()/pushclose() piping stdin/stdout
# through gzip/bzip2/compress. So comps[], compmethod(), push(),
# pushclose(), Pushstate, and the -z keyletter's actual compression
# behaviour are all dropped, not ported - about 60 of the C's 1588
# lines. The real behaviour change, and the sharper half of it:
# extract()'s compmethod(usefile) call is UNCONDITIONAL, gated only on
# the archive's own filename suffix, not on any flag - so the original
# auto-decompresses "tar xf foo.tgz" with no -z at all. This port
# can't do that silently, so it refuses loudly instead: extract() on a
# recognisably-compressed archive name fails with a clear message
# rather than reading the compressed bytes as raw tar and failing an
# opaque checksum check three lines of output later. On create, -z is
# only ever invoked when actually asked for (docreate && docompress in
# the original too), so a "tar cf foo.tar.gz ..." with no -z still
# writes a plain (if misleadingly-named) tar file here, same as the
# real binary would.
#
# WHAT THE MISSING getwd() REMOVES. The original's addtoar()/
# addtreetoar() chdir() into each subdirectory during recursive
# descent (so shortf can stay a single bare component) and rely on
# getwd()+chdir(origdir) to recover the starting directory afterward.
# Sys has chdir but no getwd - once chdir'd, there is no general way to
# ask "where was I" and get back if a nested call didn't fully unwind.
# Rather than risk that, this translation never chdirs: addtoar()
# threads full relative paths throughout (both the archive-recorded
# name and the on-disk open path stay identical strings, concatenated
# with "/" at each recursion step) and addtreetoar() is folded directly
# into addtoar() rather than kept as a separate mzutual-recursion
# partner. Same archive contents, different internal mechanism.
#
# BLOCK BUFFERING, simplified. The original reads/writes Dblock Tblocks
# (a few kilobytes) per underlying read()/write() for throughput, via
# a getblk()/curblk/endblk/gothowmany/Refill machinery that manages a
# shared in-memory window across many logically-separate callers. This
# translation reads and writes exactly one Tblock (512 bytes) at a
# time - fewer moving parts, more syscalls, byte-for-byte identical
# archive contents. nblock/blkoff/nexthdr/the seekable-skip-ahead
# optimisation in the original's refill() are dropped along with it -
# they exist purely to make that buffering scheme fast, not to affect
# the format.
#
# TARGBEGIN, not ARGBEGIN - checked, not assumed to be the same as
# every other p9/cmd tool's option parsing. tar's own macro scans ONLY
# the first argv word for keyletters ("tar xvf archive" is one bundled
# word), and three of those letters (f, g, u) consume the *next whole
# argv word* as a value, Unix-tar-style, not attached the way -m is in
# file.b. A leading '-' on that first word is itself just another
# scanned character with its own case ('-': break - a no-op), so both
# "tar xvf ..." and "tar -xvf ..." parse identically. parseargs() below
# reproduces this exactly rather than reaching for a generic option
# parser.
#
# PAX headers and GNU long names: read in full before parsing, not
# incrementally. The original's parsepax() is the one function in this
# file with genuinely tricky control flow - a nested while/for with a
# goto nextblk landing mid-loop, carrying a length-prefix scan buffer
# across block boundaries because C's fixed on-stack buffers can't
# grow. Limbo's arrays can: getname() and parsepax() here both read
# every block the record needs into one contiguous array first (via a
# small grow-and-copy loop), then parse that buffer in a single
# straight-line pass with no cross-call state at all. Same attribute
# semantics (path=/linkpath=/uname=/gname=/atime=/mtime=/size=, same
# PAX record framing "LEN KEY=VALUE\n"), no goto-equivalent needed -
# the streaming constraint the original's structure works around
# simply doesn't apply here. Both PAX header kinds (LF_PAXHDR, a
# per-file header, and LF_PAXGLOBL, a global one carrying defaults for
# every file after it) go through this same parsepax() - but only the
# per-file kind is exercised by tartest.b's own T5; see BUGS.
#
# A REAL BUG IN THE SOURCE, found by reading it, not by testing it:
# parsehdr() sets both hdr->uid and hdr->gid from bp->uname - the
# second assignment (line 830 of the original) should read bp->gname,
# the field one line above it in the very same struct, and which
# mkhdr()/mkpaxhdr() both correctly write on the CREATE side. The
# result: every ustar archive's group field is silently replaced by
# its owner's *user* name on extract/list, for every archive this
# program has ever read. Preserved exactly here, not corrected - see
# BUGS, and see file.b's own dict[] bug for the precedent this tree
# follows on found-not-fixed defects. This one was caught by reading
# the header-parsing code side by side with the two header-writing
# functions that populate both fields correctly, not by any test
# failing - worth flagging the difference, since dict[] in file.c was
# the opposite (found by testing, not by reading).
#
# Symlinks/hardlinks/fifos on extract need NO adaptation at all: the
# original already just reports "can't make (sym)link"/"can't make
# fifo" and skips rather than creating one, on every target it runs
# on - Plan 9 has no on-disk symlink concept either. This is one of
# the few places nothing had to change.
#
# cleanname(): reused from this tree's own module/names.m
# (Names->cleanname), exactly the choice patch.b already made and
# documented for the same function - not reimplemented here either.
#
# array of byte throughout for the 512-byte header block itself (same
# choice as file.b, the opposite of every string-based translation in
# p9/cmd): tar headers are fixed-byte-offset binary records, not text.
# Field offsets below (F_NAME=0, F_MODE=100, ... F_CHKSUM=148,
# F_MAGIC=257 ...) were hand-derived from the real POSIX ustar struct
# layout in the source and cross-checked against file.b's own
# istar(), which independently arrived at chksum offset 148 and magic
# offset 257 while translating a completely different file - two
# independent derivations landing on the same numbers is the check.
#
# Cosmetic gap: -v's verbose listing renders permissions with a
# hand-written 9-character rwx approximation (modestr() below), not a
# port of the real %M dirmodefmt verb (which the original installs via
# fmtinstall and this tree's print formatting has no equivalent hook
# for) - no setuid/sticky/special-bit rendering. Only affects -v's
# cosmetic output column, not extraction or archive correctness.
#
# access(name, AEXIST) has no Sys equivalent; every existence check
# here is sys->stat(name) succeeding or not, which is what the
# original's own access(name, AEXIST) reduces to on this filesystem
# model anyway.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;
include "names.m";
	names: Names;

Tar: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam. argv here starts AT the keyletter word
	# itself (e.g. ("cf", "/tartest/out.tar", "/tartest/a")) - unlike
	# init(), which strips a leading program-name argv[0] via `tl argv`
	# before parseargs() ever sees it. Returns captured stdout (the
	# file-list/verbose-listing output the real binary would print) and
	# 1 on success. A hard failure (bad archive, can't open, ...) raises
	# "fail:tar" and propagates uncaught, exactly like patch.b's own
	# run() - the test file's own checkfail()-style wrapper is where
	# expected failures are caught, not here.
	run:	fn(argv: list of string): (string, int);
};

stdin, stdout, stderr: ref FD;
capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

warn(msg: string)
{
	sys->fprint(stderr, "tar: %s\n", msg);
}

fail(msg: string)
{
	warn(msg);
	raise "fail:tar";
}

usage()
{
	fail("usage: tar {crtx}[PRTfgikmpsuvz] [archive] [file1 file2...]");
}

Tblock:		con 512;
Namsiz:		con 100;
Maxpfx:		con 155;
Binsize:	con 16r80;
Binnegsz:	con 16rff;

# ustar header field offsets/lengths within one Tblock-sized block,
# hand-derived from the real struct layout and cross-checked against
# file.b's independently-derived istar() (chksum=148, magic=257).
F_NAME:		con 0;		F_NAME_LEN:	con 100;
F_MODE:		con 100;	F_MODE_LEN:	con 8;
F_UID:		con 108;	F_UID_LEN:	con 8;
F_GID:		con 116;	F_GID_LEN:	con 8;
F_SIZE:		con 124;	F_SIZE_LEN:	con 12;
F_MTIME:	con 136;	F_MTIME_LEN:	con 12;
F_CHKSUM:	con 148;	F_CHKSUM_LEN:	con 8;
F_LINKFLAG:	con 156;
F_LINKNAME:	con 157;	F_LINKNAME_LEN:	con 100;
F_MAGIC:	con 257;	F_MAGIC_LEN:	con 6;
F_VERSION:	con 263;	F_VERSION_LEN:	con 2;
F_UNAME:	con 265;	F_UNAME_LEN:	con 32;
F_GNAME:	con 297;	F_GNAME_LEN:	con 32;
F_DEVMAJOR:	con 329;	F_DEVMAJOR_LEN:	con 8;
F_DEVMINOR:	con 337;	F_DEVMINOR_LEN:	con 8;
F_PREFIX:	con 345;	F_PREFIX_LEN:	con 155;

# POSIX link flags
LF_PLAIN1:	con 0;
LF_PLAIN2:	con '0';
LF_LINK:	con '1';
LF_SYMLINK1:	con '2';
LF_SYMLINK2:	con 's';
LF_CHR:		con '3';
LF_BLK:		con '4';
LF_DIR:		con '5';
LF_FIFO:	con '6';
LF_CONTIG:	con '7';
LF_LONGNAME:	con 'L';
LF_LONGLINK:	con 'K';
LF_PAXHDR:	con 'x';
LF_PAXGLOBL:	con 'g';

islink(lf: int): int
{
	return lf == LF_LINK || lf == LF_SYMLINK1 || lf == LF_SYMLINK2;
}

None, Toc, Xtract, Replace: con iota;

Hdr: adt
{
	name:	string;
	uid:	string;
	gid:	string;
	mode:	int;
	size:	big;
	mtime:	int;
	atime:	int;
};

nullhdr(): ref Hdr
{
	h := ref Hdr;
	h.name = nil;
	h.uid = nil;
	h.gid = nil;
	h.mode = -1;
	h.mtime = -1;
	h.atime = -1;
	h.size = big -1;
	return h;
}

verb, docreate, aruid, argid, relative, settime, verbose,
	docompress, keepexisting, ignerrs, resync, posix: int;
usefile, arname: string;
lastcantcreate: string;
globlhdr: ref Hdr;

resetstate()
{
	verb = None;
	docreate = 0;
	aruid = 0;
	argid = 0;
	relative = 1;
	settime = 0;
	verbose = 0;
	docompress = 0;
	keepexisting = 0;
	ignerrs = 0;
	resync = 0;
	posix = 1;
	usefile = nil;
	arname = "archive";
	lastcantcreate = nil;
	globlhdr = nullhdr();
}

# block I/O - see header comment: one Tblock at a time, no batching.

readblk(ar: ref FD): array of byte
{
	bp := array[Tblock] of byte;
	got := 0;
	while(got < Tblock){
		tmp := array[Tblock-got] of byte;
		n := sys->read(ar, tmp, Tblock-got);
		if(n < 0){
			if(ignerrs){
				warn("ignoring error reading "+arname);
				return array[Tblock] of {* => byte 0};
			}
			fail("read error on archive "+arname);
		}
		if(n == 0)
			break;
		bp[got:] = tmp[0:n];
		got += n;
	}
	if(got == 0)
		return nil;
	if(got != Tblock)
		fail("partial block read from archive "+arname);
	return bp;
}

writeblk(ar: ref FD, bp: array of byte)
{
	n := sys->write(ar, bp, len bp);
	if(n != len bp)
		fail("error writing "+arname);
}

writen(fd: ref FD, name: string, bp: array of byte, n: int)
{
	if(n <= 0)
		return;
	w := sys->write(fd, bp[0:n], n);
	if(w != n)
		fail("error writing "+name);
}

zeroblk(): array of byte
{
	return array[Tblock] of {* => byte 0};
}

# field accessors

blkputstr(bp: array of byte, off: int, s: string)
{
	bp[off:] = array of byte s;
}

strnlenb(bp: array of byte, off, n: int): int
{
	# Plan 9's own strnlen(): if the field is completely full with no
	# terminating NUL, its length is the whole field.
	if(bp[off+n-1] != byte 0)
		return n;
	i := 0;
	while(i < n && bp[off+i] != byte 0)
		i++;
	return i;
}

fieldstr(bp: array of byte, off, n: int): string
{
	return string bp[off:off+strnlenb(bp, off, n)];
}

matchat(bp: array of byte, off: int, pat: array of byte): int
{
	if(off < 0 || off+len pat > len bp)
		return 0;
	for(mi := 0; mi < len pat; mi++)
		if(bp[off+mi] != pat[mi])
			return 0;
	return 1;
}

# quiet octal field parse: skip leading whitespace, take the leading
# octal-digit run, 0 if none - matches strtoul(field, nil, 8) called
# directly with no diagnostic, as isdir()/parsehdr() do in the original.
octq(bp: array of byte, off, n: int): big
{
	i := 0;
	while(i < n && (bp[off+i] == byte ' ' || bp[off+i] == byte '\t' || bp[off+i] == byte '\n'))
		i++;
	j := i;
	while(j < n && bp[off+j] >= byte '0' && bp[off+j] <= byte '7')
		j++;
	if(j == i)
		return big 0;
	(v, nil) := str->tobig(string bp[off+i:off+j], 8);
	return v;
}

# noisy octal field parse - matches hdrotoull(): skip leading space/NUL
# only, diagnose an empty or non-numeric field, used for size/checksum.
octfield(bp: array of byte, off, n: int, errval: big, name, field: string): big
{
	i := 0;
	while(i < n && (bp[off+i] == byte ' ' || bp[off+i] == byte 0))
		i++;
	if(i < n && bp[off+i] >= byte '0' && bp[off+i] <= byte '7')
		return octq(bp, off+i, n-i);
	if(i >= n)
		warn(name+": empty "+field+" in header");
	else
		warn(name+": non-numeric "+field+" in header");
	return errval;
}

putbe(bp: array of byte, off: int, v: big, n: int)
{
	for(pbi := n-1; pbi >= 0; pbi--){
		bp[off+pbi] = byte (int (v & big 255));
		v = v >> 8;
	}
}

# checksum: modifies bp's own chksum field to spaces while summing,
# then restores it - important for the "tar r" re-checksum-on-read case.
chksum(bp: array of byte): int
{
	old := bp[F_CHKSUM:F_CHKSUM+F_CHKSUM_LEN];
	for(ci := 0; ci < F_CHKSUM_LEN; ci++)
		bp[F_CHKSUM+ci] = byte ' ';
	sum := 0;
	for(ci2 := 0; ci2 < Tblock; ci2++)
		sum += int bp[ci2];
	for(ci3 := 0; ci3 < F_CHKSUM_LEN; ci3++)
		bp[F_CHKSUM+ci3] = old[ci3];
	return sum;
}

isustar(bp: array of byte): int
{
	return matchat(bp, F_MAGIC, array of byte "ustar") && bp[F_MAGIC+5] == byte 0;
}

parsename(bp: array of byte): string
{
	namlen := strnlenb(bp, F_NAME, F_NAME_LEN);
	if(bp[F_PREFIX] == byte 0 || !isustar(bp))
		return string bp[F_NAME:F_NAME+namlen];
	pfxlen := strnlenb(bp, F_PREFIX, F_PREFIX_LEN);
	if(pfxlen == 0)
		return string bp[F_NAME:F_NAME+namlen];
	return string bp[F_PREFIX:F_PREFIX+pfxlen] + "/" + string bp[F_NAME:F_NAME+namlen];
}

isdir(bp: array of byte, name: string): int
{
	if(bp[F_LINKFLAG] == byte LF_DIR)
		return 1;
	if(len name > 0 && name[len name-1] == '/')
		return 1;
	m := octq(bp, F_MODE, F_MODE_LEN);
	return (int m & 8r170000) == 8r040000;
}

eotar(bp: array of byte): int
{
	return len parsename(bp) == 0;
}

hdrsize(bp: array of byte): big
{
	b0 := int bp[F_SIZE];
	if(b0 == Binnegsz){
		warn(parsename(bp)+": negative length, which is insane");
		return big 0;
	}
	if(b0 == Binsize){
		v := big 0;
		for(hi := 0; hi < 8; hi++)
			v = (v<<8) | big int bp[F_SIZE+3+hi];
		return v;
	}
	return octfield(bp, F_SIZE, F_SIZE_LEN, big 0, parsename(bp), "size");
}

arsize(bp: array of byte, fname: string): big
{
	if(isdir(bp, fname) || islink(int bp[F_LINKFLAG]))
		return big 0;
	return hdrsize(bp);
}

parsecksum(bp: array of byte): big
{
	return octfield(bp, F_CHKSUM, F_CHKSUM_LEN, big -1, parsename(bp), "checksum");
}

readhdrblk(ar: ref FD): array of byte
{
	bp := readblk(ar);
	if(bp == nil)
		fail("unexpected EOF instead of archive header in "+arname);
	if(eotar(bp))
		return nil;
	hdrcksum := parsecksum(bp);
	if(hdrcksum == big -1 || big chksum(bp) != hdrcksum){
		if(!resync)
			fail(sys->sprint("bad archive header checksum in %s: name %s...; expected %.6bo got %.6o",
				arname, parsename(bp), hdrcksum, chksum(bp)));
		warn("skipping past archive header with bad checksum in "+arname+"...");
		do{
			bp = readblk(ar);
			if(bp == nil)
				fail("unexpected EOF looking for archive header in "+arname);
			hdrcksum = parsecksum(bp);
		} while(hdrcksum == big -1 || big chksum(bp) != hdrcksum);
		warn("found "+parsename(bp));
	}
	return bp;
}

# GNU long name: read every block the record needs up front (Limbo
# arrays grow; the original streams because C's can't), then trim at
# the first NUL - see header comment.
getname(ar: ref FD, bp: array of byte, hdr: ref Hdr): int
{
	if(int bp[F_LINKFLAG] != LF_LONGNAME){
		if(hdr.name == nil)
			hdr.name = parsename(bp);
		return 0;
	}
	nblks := int ((hdrsize(bp)+big (Tblock-1)) / big Tblock);
	raw := array[0] of byte;
	for(gi := 0; gi < nblks; gi++){
		b := readblk(ar);
		if(b == nil)
			fail("unexpected EOF on archive reading from "+arname);
		nr := len raw;
		grown := array[nr+Tblock] of byte;
		grown[0:] = raw;
		grown[nr:] = b;
		raw = grown;
	}
	gj := 0;
	while(gj < len raw && raw[gj] != byte 0)
		gj++;
	hdr.name = string raw[0:gj];
	return 1;
}

matchattr(kvp: string, k: string): string
{
	if(len kvp >= len k && kvp[0:len k] == k)
		return kvp[len k:];
	return nil;
}

# PAX extended header: same "read it all first, then parse in one
# straight pass" simplification as getname() - see header comment.
parsepax(ar: ref FD, bp: array of byte, hdr: ref Hdr, paxtype: int): int
{
	if(!isustar(bp) || int bp[F_LINKFLAG] != paxtype)
		return 0;
	nblks := int ((hdrsize(bp)+big (Tblock-1)) / big Tblock);
	raw := array[0] of byte;
	for(pi := 0; pi < nblks; pi++){
		b := readblk(ar);
		if(b == nil)
			fail("unexpected EOF on archive reading attr for "+parsename(bp)+" from "+arname);
		nr := len raw;
		grown := array[nr+Tblock] of byte;
		grown[0:] = raw;
		grown[nr:] = b;
		raw = grown;
	}

	p := 0;
	n := len raw;
	while(p < n && raw[p] != byte 0){
		lstart := p;
		while(p < n && raw[p] >= byte '0' && raw[p] <= byte '9')
			p++;
		if(p >= n)
			fail("oversize length prefix in pax header");
		if(raw[p] != byte ' ')
			fail(sys->sprint("invalid delimiter in pax header: %c", int raw[p]));
		lenstr := string raw[lstart:p];
		p++;
		(reclen, nil) := str->toint(lenstr, 10);
		vlen := reclen - len lenstr - 1;
		if(vlen <= 0)
			fail("invalid attribute length in pax header ("+lenstr+")");
		if(p+vlen > n)
			fail("truncated pax attribute");
		kvp := string raw[p:p+vlen-1];
		p += vlen;

		val := matchattr(kvp, "path=");
		if(val != nil)
			hdr.name = val;
		else{
			val = matchattr(kvp, "linkpath=");
			if(val != nil)
				hdr.name = val;
			else{
				val = matchattr(kvp, "uname=");
				if(val != nil)
					hdr.uid = val;
				else{
					val = matchattr(kvp, "gname=");
					if(val != nil)
						hdr.gid = val;
					else{
						val = matchattr(kvp, "atime=");
						if(val != nil)
							hdr.atime = int octq(array of byte val, 0, len val);
						else{
							val = matchattr(kvp, "mtime=");
							if(val != nil)
								hdr.mtime = int octq(array of byte val, 0, len val);
							else{
								val = matchattr(kvp, "size=");
								if(val != nil)
									(hdr.size, nil) = str->tobig(val, 10);
								else if(matchattr(kvp, "comment=") == nil && matchattr(kvp, "ctime=") == nil)
									warn("pax attribute not supported: "+kvp);
							}
						}
					}
				}
			}
		}
	}
	return 1;
}

# parsehdr: preserves the original's real uname/gname bug - see header
# comment. hdr->gid is supposed to come from bp's group-name field but
# the original copies the owner-name field into it instead, and this
# translation keeps that exactly, not corrected.
parsehdr(hdr: ref Hdr, bp: array of byte)
{
	ustar := isustar(bp);
	if(hdr.mode == -1)
		hdr.mode = int (octq(bp, F_MODE, F_MODE_LEN) & big 8r777);
	if(hdr.mode == -1)
		hdr.mode = globlhdr.mode;
	if(isdir(bp, hdr.name))
		hdr.mode |= Sys->DMDIR;
	if(hdr.mtime == -1)
		hdr.mtime = int octq(bp, F_MTIME, F_MTIME_LEN);
	if(hdr.mtime == -1)
		hdr.mtime = globlhdr.mtime;
	if(hdr.size == big -1)
		hdr.size = arsize(bp, hdr.name);
	if(ustar && hdr.uid == nil)
		hdr.uid = fieldstr(bp, F_UNAME, F_UNAME_LEN);
	if(hdr.uid == nil)
		hdr.uid = globlhdr.uid;
	if(ustar && hdr.gid == nil)
		hdr.gid = fieldstr(bp, F_UNAME, F_UNAME_LEN);	# bug preserved: should be F_GNAME
	if(hdr.gid == nil)
		hdr.gid = globlhdr.gid;
}

readhdr(ar: ref FD): (array of byte, ref Hdr)
{
	hdr := nullhdr();
	for(;;){
		bp := readhdrblk(ar);
		if(bp == nil)
			return (nil, hdr);
		if(parsepax(ar, bp, hdr, LF_PAXHDR))
			continue;
		if(parsepax(ar, bp, globlhdr, LF_PAXGLOBL))
			continue;
		if(getname(ar, bp, hdr))
			continue;
		parsehdr(hdr, bp);
		return (bp, hdr);
	}
}

# member selection (extract/list): prefix-of-a-cleaned-name match
# against the argument list, same semantics as the original, reusing
# names->cleanname() rather than a hand-rolled path canonicaliser -
# same choice patch.b already made and documented.

prefix(name: string, pfx: string): int
{
	clpfx := names->cleanname(pfx);
	pl := len clpfx;
	if(len name < pl)
		return 0;
	if(name[0:pl] != clpfx)
		return 0;
	return len name == pl || name[pl] == '/';
}

match(name: string, argv: list of string): int
{
	if(argv == nil)
		return 1;
	clname := names->cleanname(name);
	for(; argv != nil; argv = tl argv)
		if(prefix(clname, hd argv))
			return 1;
	return 0;
}

# extraction side

lastcantcreatereset()
{
	lastcantcreate = nil;
}

cantcreate(s: string, mode: int)
{
	if(mode & Sys->DMDIR){
		if(lastcantcreate != nil){
			if(s == lastcantcreate)
				return;
			ll := len lastcantcreate;
			if(len s >= ll && s[0:ll] == lastcantcreate && s[ll] == '/')
				return;
		}
		lastcantcreate = s;
	}
	warn("can't create "+s);
}

makedir(s: string): int
{
	(ok, nil) := sys->stat(s);
	if(ok != -1)
		return -1;
	fd := sys->create(s, Sys->OREAD, Sys->DMDIR | 8r777);
	if(fd != nil)
		return 0;
	cantcreate(s, Sys->DMDIR);
	return -1;
}

mkpdirs(path: string)
{
	n := len path;
	i := 1;
	while(i < n){
		while(i < n && path[i] != '/')
			i++;
		if(i >= n)
			break;
		dir := path[0:i];
		(ok, nil) := sys->stat(dir);
		if(ok == -1)
			makedir(dir);
		i++;
	}
}

openfname(bp: array of byte, fname0: string, mode: int): ref FD
{
	fname := names->cleanname(fname0);
	dir := (mode & Sys->DMDIR) != 0;
	lf := int bp[F_LINKFLAG];
	case lf {
	LF_LINK or LF_SYMLINK1 or LF_SYMLINK2 or LF_LONGLINK =>
		warn("can't make (sym)link "+fname);
		return nil;
	LF_FIFO =>
		warn("can't make fifo "+fname);
		return nil;
	}

	fd: ref FD = nil;
	doit := 1;
	if(keepexisting){
		(sok, nil) := sys->stat(fname);
		if(sok != -1)
			doit = 0;
	}
	if(doit){
		rw := Sys->OWRITE;
		if(dir)
			rw = Sys->OREAD;
		fd = sys->create(fname, rw, mode);
		if(fd == nil){
			mkpdirs(fname);
			fd = sys->create(fname, rw, mode);
		}
		if(fd == nil){
			exists := 0;
			if(dir){
				(sok2, nil) := sys->stat(fname);
				if(sok2 != -1)
					exists = 1;
			}
			if(!dir || !exists)
				cantcreate(fname, mode);
		}
		if(fd != nil && verbose)
			emit(fname+"\n");
	}
	return fd;
}

copyfromar(ar: ref FD, fd: ref FD, fname: string, blksleft: int, bytes0: big)
{
	bytes := bytes0;
	if(blksleft == 0 || bytes < big 0)
		bytes = big 0;
	for(cbi := 0; cbi < blksleft; cbi++){
		hb := readblk(ar);
		if(hb == nil)
			fail("unexpected EOF on archive extracting "+fname+" from "+arname);
		wrbytes := big Tblock;
		if(wrbytes > bytes)
			wrbytes = bytes;
		if(fd != nil)
			writen(fd, fname, hb, int wrbytes);
		bytes -= wrbytes;
	}
	if(bytes > big 0)
		warn(sys->sprint("%bd bytes uncopied at EOF on archive %s; %s not fully extracted", bytes, arname, fname));
}

modestr(mode: int): string
{
	# hand-written approximation of the original's real %M dirmodefmt
	# verb - see header comment.
	sb := array of byte "----------";
	if(mode & Sys->DMDIR)
		sb[0] = byte 'd';
	bits := array[] of {8r400, 8r200, 8r100, 8r040, 8r020, 8r010, 8r004, 8r002, 8r001};
	chars := array[] of {byte 'r', byte 'w', byte 'x', byte 'r', byte 'w', byte 'x', byte 'r', byte 'w', byte 'x'};
	for(mi := 0; mi < 9; mi++)
		if(mode & bits[mi])
			sb[1+mi] = chars[mi];
	return string sb;
}

wrmeta(fd: ref FD, hdr: ref Hdr)
{
	nd := Sys->nulldir;
	nd.mtime = hdr.mtime;
	nd.mode = hdr.mode;
	sys->fwstat(fd, nd);
	if(hdr.gid != nil){
		nd = Sys->nulldir;
		nd.gid = hdr.gid;
		sys->fwstat(fd, nd);
	}
	if(hdr.uid != nil){
		nd = Sys->nulldir;
		nd.uid = hdr.uid;
		sys->fwstat(fd, nd);
	}
}

extract1(ar: ref FD, bp: array of byte, hdr: ref Hdr)
{
	fd: ref FD = nil;
	bytes := hdr.size;
	blksleft := int ((bytes+big (Tblock-1))/big Tblock);
	lf := int bp[F_LINKFLAG];
	if(lf == LF_LINK || lf == LF_SYMLINK1 || lf == LF_SYMLINK2 || lf == LF_FIFO)
		blksleft = 0;

	path := hdr.name;
	if(relative && len path > 0 && path[0] == '/')
		path = "." + path;
	else if(relative && len path > 0 && path[0] == '#')
		path = "./" + path;

	if(verb == Xtract)
		fd = openfname(bp, path, hdr.mode);
	else if(verbose)
		emit(sys->sprint("%s %8bd %s\n", modestr(hdr.mode), bytes, path));
	else
		emit(path+"\n");

	copyfromar(ar, fd, path, blksleft, hdr.size);

	if(fd != nil && settime)
		wrmeta(fd, hdr);
}

skip(ar: ref FD, bp: array of byte, hdr: ref Hdr)
{
	blksleft := int ((arsize(bp, hdr.name)+big (Tblock-1))/big Tblock);
	for(ski := 0; ski < blksleft; ski++){
		hb := readblk(ar);
		if(hb == nil)
			fail("unexpected EOF on archive extracting "+hdr.name+" from "+arname);
	}
}

compsuffixes := array[] of {".tar.gz", ".tgz", ".tar.Z", ".tz", ".tar.bz", ".tbz", ".tar.bz2", ".tbz2"};

compsuffix(name: string): string
{
	if(name == nil)
		return nil;
	for(csi := 0; csi < len compsuffixes; csi++){
		sfx := compsuffixes[csi];
		if(len name > len sfx && name[len name-len sfx:] == sfx)
			return sfx;
	}
	return nil;
}

extract(files: list of string)
{
	ar: ref FD;
	if(usefile != nil){
		sfx := compsuffix(usefile);
		if(sfx != nil)
			fail("archive "+usefile+" looks compressed ("+sfx+"); this translation cannot decompress it (no fork/exec available) - see BUGS");
		ar = sys->open(usefile, Sys->OREAD);
	} else
		ar = stdin;
	if(ar == nil)
		fail("can't open archive "+arname);

	for(;;){
		(bp, hdr) := readhdr(ar);
		if(bp == nil)
			break;
		if(match(hdr.name, files))
			extract1(ar, bp, hdr);
		else
			skip(ar, bp, hdr);
	}
}

# creation side

putfullname(bp: array of byte, name: string): int
{
	n := len name;
	dir := isdir(bp, name);
	if(dir)
		n++;
	if(n > Namsiz){
		warn("name too long for tar header: "+name);
		return -1;
	}
	nm := name;
	if(dir)
		nm = name + "/";
	blkputstr(bp, F_NAME, nm);
	return 0;
}

mkhdr(bp: array of byte, dir: Sys->Dir, file: string): int
{
	blkputstr(bp, F_MODE, sys->sprint("%6o ", dir.mode & 8r777));
	blkputstr(bp, F_UID, sys->sprint("%6o ", aruid));
	blkputstr(bp, F_GID, sys->sprint("%6o ", argid));
	if(dir.length >= big 4294967296){
		bp[F_SIZE] = byte Binsize;
		putbe(bp, F_SIZE+3, dir.length, 8);
	} else
		blkputstr(bp, F_SIZE, sys->sprint("%11bo ", dir.length));
	blkputstr(bp, F_MTIME, sys->sprint("%11o ", dir.mtime));
	if(dir.mode & Sys->DMDIR)
		bp[F_LINKFLAG] = byte LF_DIR;
	else
		bp[F_LINKFLAG] = byte LF_PLAIN1;
	r := putfullname(bp, file);
	if(posix){
		blkputstr(bp, F_MAGIC, "ustar");
		blkputstr(bp, F_VERSION, "00");
		blkputstr(bp, F_UNAME, dir.uid);
		blkputstr(bp, F_GNAME, dir.gid);
	}
	blkputstr(bp, F_CHKSUM, sys->sprint("%6o", chksum(bp)));
	return r;
}

mkpaxhdr(ar: ref FD, dir: Sys->Dir, file: string): int
{
	if(!posix)
		return -1;
	kv := " path="+file+"\n";
	n := len kv + 1;
	nn := n;
	do{
		n = nn;
		nn = len string n + len kv;
	} while(n != nn);

	blk := zeroblk();
	blk[F_LINKFLAG] = byte LF_PAXHDR;
	blkputstr(blk, F_NAME, "pax/romana");
	blkputstr(blk, F_MODE, sys->sprint("%6o ", dir.mode & 8r777));
	blkputstr(blk, F_UID, sys->sprint("%6o ", aruid));
	blkputstr(blk, F_GID, sys->sprint("%6o ", argid));
	blkputstr(blk, F_SIZE, sys->sprint("%11o ", n));
	blkputstr(blk, F_MAGIC, "ustar");
	blkputstr(blk, F_VERSION, "00");
	blkputstr(blk, F_UNAME, dir.uid);
	blkputstr(blk, F_GNAME, dir.gid);
	blkputstr(blk, F_CHKSUM, sys->sprint("%6o", chksum(blk)));
	writeblk(ar, blk);

	content := array of byte (string n + kv);
	p := 0;
	while(p < len content){
		cb := zeroblk();
		m := len content - p;
		if(m > Tblock)
			m = Tblock;
		cb[0:] = content[p:p+m];
		writeblk(ar, cb);
		p += Tblock;
	}
	return 0;
}

# addtoar: folds the original's addtreetoar() straight in - see header
# comment on why this never chdirs. file is the archive-recorded name,
# shortf the on-disk path; both stay identical here.
addtoar(ar: ref FD, file: string, shortf: string)
{
	fd := sys->open(shortf, Sys->OREAD);
	if(fd == nil){
		warn("can't open "+file);
		return;
	}
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		fail("can't fstat "+file);

	isdirfile := (dir.mode & Sys->DMDIR) != 0;
	hpath := file;
	extra := 0;
	if(isdirfile)
		extra = 1;
	if(len file + extra > Namsiz){
		if(mkpaxhdr(ar, dir, file) < 0){
			warn("name too long for tar header: "+file);
			return;
		}
		hpath = "PAXED";
	}
	blk := zeroblk();
	if(mkhdr(blk, dir, hpath) < 0)
		return;
	writeblk(ar, blk);

	if(isdirfile){
		(n, ents) := sys->dirread(fd);
		if(n < 0)
			warn("dirread "+file+": failed");
		for(ei := 0; ei < n; ei++)
			addtoar(ar, file+"/"+ents[ei].name, shortf+"/"+ents[ei].name);
	} else {
		blksleft := int ((dir.length+big (Tblock-1))/big Tblock);
		for(abi := 0; abi < blksleft; abi++){
			b := zeroblk();
			# readn, not read: read() alone may return short with more
			# data still available (a pipe, a slow fs), which would
			# shift the unread tail into the wrong block - readn loops
			# until the block is full or genuine EOF (man/2/sys-read:
			# "continues to read ... until nbytes have been read, or
			# read returns a non-positive count"), matching the
			# original's own ereadn(). b is already zeroed (zeroblk())
			# so a real short read at EOF (the file's last, partial
			# block) still pads correctly with no extra work, and an
			# ignerrs-suppressed error leaves the same zero fill the
			# original's cope() builds explicitly via memset(). Found
			# by an advisor review, not by a failing test - a genuine
			# negative control (temporarily reverting to plain read()
			# and archiving a 2000-byte/4-block file) did NOT reproduce
			# a failure: this host's regular-file reads never come back
			# short in practice, so the bug is real by the documented
			# read()/readn() contract and by matching ereadn(), not by
			# an observed corruption here.
			nr := sys->readn(fd, b, Tblock);
			if(nr < 0){
				if(!ignerrs)
					fail("read error reading "+file);
			}
			writeblk(ar, b);
		}
		if(verbose)
			emit(file+"\n");
	}
}

replace(files: list of string)
{
	ar: ref FD;
	if(usefile != nil && docreate)
		ar = sys->create(usefile, Sys->OWRITE, 8r666);
	else if(usefile != nil)
		ar = sys->open(usefile, Sys->ORDWR);
	else
		ar = stdout;
	if(ar == nil)
		fail("can't open archive "+arname);

	if(docreate && docompress)
		fail("compression (-z) is not supported by this translation (no fork/exec available)");

	if(usefile != nil && !docreate){
		# tar r: skip to the end of an existing archive
		for(;;){
			bp := readhdrblk(ar);
			if(bp == nil)
				break;
			blksleft := int ((hdrsize(bp)+big (Tblock-1))/big Tblock);
			for(rski := 0; rski < blksleft; rski++){
				hb := readblk(ar);
				if(hb == nil)
					fail("unexpected EOF on archive "+arname);
			}
		}
		# back up over the single zeroed end-of-archive block just
		# consumed, so new members overwrite it instead of following it.
		sys->seek(ar, big -Tblock, Sys->SEEKRELA);
	}

	for(; files != nil; files = tl files)
		addtoar(ar, hd files, hd files);

	writeblk(ar, zeroblk());
	writeblk(ar, zeroblk());

	# no explicit close(): Sys has none - same gap patch.b's own BUGS
	# already documents; the fd is released when its ref is collected.
}

# argument parsing: TARGBEGIN, not ARGBEGIN - see header comment.

parseargs(argv: list of string): list of string
{
	if(argv == nil)
		usage();
	kw := hd argv;
	rest := tl argv;
	errflg := 0;
	for(ki := 0; ki < len kw; ki++){
		c := kw[ki];
		case c {
		'c' =>
			docreate++;
			verb = Replace;
		'f' =>
			if(rest == nil)
				usage();
			usefile = hd rest;
			arname = usefile;
			rest = tl rest;
		'g' =>
			if(rest == nil)
				usage();
			(argid, nil) = str->toint(hd rest, 10);
			rest = tl rest;
		'i' =>
			ignerrs = 1;
		'k' =>
			keepexisting++;
		'm' =>
			settime = 0;
		'p' =>
			posix++;
		'P' =>
			posix = 0;
		'r' =>
			verb = Replace;
		'R' =>
			relative = 0;
		's' =>
			resync++;
		't' =>
			verb = Toc;
		'T' =>
			settime++;
		'u' =>
			if(rest == nil)
				usage();
			(aruid, nil) = str->toint(hd rest, 10);
			rest = tl rest;
		'v' =>
			verbose++;
		'x' =>
			verb = Xtract;
		'z' =>
			docompress++;
		'-' =>
			;
		* =>
			warn(sys->sprint("unknown letter %c", c));
			errflg = 1;
		}
	}
	if(errflg)
		usage();
	return rest;
}

dispatch(files: list of string)
{
	case verb {
	Toc or Xtract =>
		extract(files);
	Replace =>
		replace(files);
	* =>
		usage();
	}
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	str = load String String->PATH;
	names = load Names Names->PATH;
	if(str == nil || names == nil){
		sys->fprint(stderr, "tar: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();
	files := parseargs(tl argv);
	dispatch(files);
}

run(argv: list of string): (string, int)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(names == nil)
		names = load Names Names->PATH;
	if(stdin == nil)
		stdin = sys->fildes(0);
	if(stdout == nil)
		stdout = sys->fildes(1);
	if(stderr == nil)
		stderr = sys->fildes(2);

	resetstate();
	outbuf = "";
	capturing = 1;
	files := parseargs(argv);
	dispatch(files);
	capturing = 0;
	return (outbuf, 1);
}
