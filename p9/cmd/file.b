implement File;

# A structural Limbo translation of Plan 9's real file(1) -
# sys/src/cmd/file.c in the 9front tree, 1772 lines: guesses a file's
# type from its content, trying ~30 independent classifier functions
# in a fixed order and printing the first one that matches. See
# doc/plan9-port.md for the translation-not-workalike discipline.
#
# Unlike patch.c (one algorithm, no live oracle) or pr.c (coupled
# global state, no live oracle either), this file's own shape makes it
# tractable: ~30 largely-independent functions over a shared read-once
# buffer, each one a small, self-contained byte/string pattern check -
# closer to crc32.c repeated thirty times than to a single hard
# algorithm. Each classifier's correctness is independently verifiable
# too, the same way patch.c's was: a file whose first four bytes are
# \x89PNG *is* a PNG by this program's own table, checkable by
# constructing exactly those bytes, no reference binary needed.
#
# array of byte, not string, throughout - the opposite call from every
# translation before this one (patch.b included). file(1)'s whole job
# is sniffing raw bytes, and several of its own magic-byte tables
# contain values that are not valid UTF-8 on their own (0x1f 0x9d for
# `compress`, 0x89 'P' 'N' 'G' for PNG, the raw \xff-heavy Xilinx
# bitstream patterns) - round-tripping those through a Limbo string
# would corrup them (a Limbo string is a rune sequence; converting a
# string back to array of byte re-encodes each rune as UTF-8, which is
# NOT the identity function for a rune with value >= 0x80). Every
# multi-byte pattern with a byte >= 0x80 is built directly as bytes via
# bb() below, not as a string literal; only genuinely 7-bit-ASCII
# patterns use a plain string (where the two representations agree).
#
# chartorune()'s error-value convention differs between Plan 9 and
# Inferno, and file.c's own histogram loop depends on Plan 9's specific
# one - handled explicitly, not glossed over. Plan 9's chartorune(), on
# a malformed byte sequence, returns the RAW BYTE VALUE as the "rune"
# (landing it in the 0x80-0x9F "invalid runes" bucket the histogram
# classifies as Cbinary); Inferno's sys->byte2char(), confirmed by
# reading its native implementation in libinterp/runt.c, instead
# returns the literal constant Runeerror (0xFFFD) for the same case,
# which would silently misroute an invalid byte into the ">0xff: UTF
# extension" bucket instead. runehist() below uses sys->byte2char()
# for what it's reliable at (how many bytes this rune consumes, and
# whether the sequence is valid at all) but substitutes the raw byte
# value in place of Runeerror when it isn't, reproducing Plan 9's own
# convention rather than Inferno's.
#
# Two classifiers are not ported at all: isexec() and iscint(), which
# in the original call crackhdr()/objtype() from Plan 9's libmach to
# recognise native executables and compiler/assembler intermediate
# files. libmach is not absent from this tree - it exists at
# utils/libmach, built with the kencc toolchain - but it is host-native
# C with no Limbo/Dis binding, and porting an entire executable-header
# cracking library is a different, much larger undertaking than this
# file. Dropping them is a real, observable behaviour change, not a
# cosmetic one: isexec is 4th in the C's own dispatch order, so a
# native Plan 9 executable that would have been precisely identified
# here instead falls through every later classifier and typically ends
# up caught by ismung()'s entropy check or the final generic "binary"
# line. Said here and in BUGS, not silently absorbed.
#
# The dtype-based "is this actually a special device, not a real file"
# gate (`mbuf->type != 'M' && mbuf->type != '|'`) does not transfer:
# Plan 9's convention is that ordinary mounted/9P files report type
# 'M'; this emu's host-filesystem-backed files were checked directly
# (a throwaway probe stat()ing a real file) and report 'U' instead -
# porting the exact character check would misclassify every ordinary
# file here as "special" and skip analysis entirely. Adapted rather
# than preserved: the DMDIR check (directories) is kept as-is: anything
# else is read and classified normally, regardless of its dtype.
#
# A real, preserved bug found by testing the translation, not the
# source: dict[]'s binary search REQUIRES the table to be sorted, and
# it is not - "bio" sits at its own position (right after "extern"),
# but strcmp-order it belongs between "block" and "char", six entries
# earlier. Verified by simulating the exact search against the actual
# (unsorted) table order (see filetest.b, not just read off the
# source): the search silently fails to find "data", "dimension",
# "double", "extern", and "bio" even though all five are present in the
# table, because the broken ordering routes the search away from them.
# This means a real C source file's own `#include <bio.h>` line is not
# counted toward the "bio" (I2) word-frequency bucket isc() checks for
# includes-detection - the OTHER two isc() heuristics (a keyword-heavy
# declaration line, or a semicolon-and-equals-heavy assignment line)
# can still catch such a file, so this is a narrowing of one detection
# path, not a wholesale failure to recognise C source. Preserved as-is
# (a silent miscount, not a dangerous one) rather than sorted correctly,
# per this tree's "translate what's there" discipline - filetest.b has
# a case exercising exactly this.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

File: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: classifies one real file already on disk,
	# the same analysis typeone()/filetype() do, minus the CLI's padded
	# "name: " prefix (presentation, not classification). Returns the
	# one line of output the real binary would print for this file.
	run:	fn(mimeflag: int, path: string): string;
};

stderr: ref FD;
capturing: int;
outbuf: string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}


# choosestr: Limbo has no C-style ?: ternary - every `mime ? A : B` in
# the original is translated through this instead. ("pick" is itself a
# reserved word in this Limbo, confirmed by a standalone one-line
# probe - not a name to reach for here.)
choosestr(cond: int, a: string, b: string): string
{
	if(cond)
		return a;
	return b;
}

# class tags for the character/word histograms (cfreq[]/wfreq[]) -
# same numeric layout as the C's enum, since several classifiers index
# these arrays directly by these constants.
Cword, Fword, Aword, Alword, Lword, I1, I2, I3: con iota;
Clatin: con 128;
Cbinary: con 129;
Cnull: con 130;
Ceascii: con 131;
Cutf: con 132;

Fascii, Flatin, Futf, Fbinary, Feascii, Fnull: con iota;

OCTET: con "application/octet-stream";
PLAIN: con "text/plain";

BUFSZ: con 6001;

buf: array of byte;	# always BUFSZ long; only buf[0:nbuf] is live data
nbuf: int;
cfreq: array of int;	# size 140, indexed by rune value (<=0x7f) or
			# by Clatin/Cbinary/Cnull/Ceascii/Cutf above
wfreq: array of int;	# size 8, indexed by Cword..I3
guess: int;
mime: int;
fd: ref FD;
fname: string;
slash: int;		# byte index of fname's rightmost '/', or -1

mbuf: Sys->Dir;
havembuf: int;

Dictword: adt { word: string; class: int; };

# dict[]: word -> class, for wordfreq()'s binary search. Kept in the
# EXACT order the C source has it, including the "bio" misplacement -
# see header comment; this is a preserved bug, not a transcription slip.
dict := array[] of {
	Dictword("PATH", Lword),
	Dictword("TEXT", Aword),
	Dictword("adt", Alword),
	Dictword("aggr", Alword),
	Dictword("alef", Alword),
	Dictword("array", Lword),
	Dictword("block", Fword),
	Dictword("char", Cword),
	Dictword("common", Fword),
	Dictword("con", Lword),
	Dictword("data", Fword),
	Dictword("dimension", Fword),
	Dictword("double", Cword),
	Dictword("extern", Cword),
	Dictword("bio", I2),
	Dictword("float", Cword),
	Dictword("fn", Lword),
	Dictword("function", Fword),
	Dictword("h", I3),
	Dictword("implement", Lword),
	Dictword("import", Lword),
	Dictword("include", I1),
	Dictword("int", Cword),
	Dictword("integer", Fword),
	Dictword("iota", Lword),
	Dictword("libc", I2),
	Dictword("long", Cword),
	Dictword("module", Lword),
	Dictword("real", Fword),
	Dictword("ref", Lword),
	Dictword("register", Cword),
	Dictword("self", Lword),
	Dictword("short", Cword),
	Dictword("static", Cword),
	Dictword("stdio", I2),
	Dictword("struct", Cword),
	Dictword("subroutine", Fword),
	Dictword("u", I2),
	Dictword("void", Cword),
};

# language[]: Unicode ranges for script detection (print_utf()). mode
# tags: 0 Normal, 1 First (of a multi-range script), 2 Multi (a later
# range of one), 3 Shared (counted but never named on its own, e.g. CJK
# ideographs shared by Chinese/Japanese/Korean).
Lang: adt { mode: int; count: int; low: int; high: int; name: string; };
LMnormal, LMfirst, LMmulti, LMshared: con iota;
language: array of ref Lang;

buildlanguage(): array of ref Lang
{
	return array[] of {

	ref Lang(LMnormal, 0, 16r0100, 16r01FF, "Extended Latin"),
	ref Lang(LMnormal, 0, 16r0370, 16r03FF, "Greek"),
	ref Lang(LMnormal, 0, 16r0400, 16r04FF, "Cyrillic"),
	ref Lang(LMnormal, 0, 16r0530, 16r058F, "Armenian"),
	ref Lang(LMnormal, 0, 16r0590, 16r05FF, "Hebrew"),
	ref Lang(LMnormal, 0, 16r0600, 16r06FF, "Arabic"),
	ref Lang(LMnormal, 0, 16r0900, 16r097F, "Devanagari"),
	ref Lang(LMnormal, 0, 16r0980, 16r09FF, "Bengali"),
	ref Lang(LMnormal, 0, 16r0A00, 16r0A7F, "Gurmukhi"),
	ref Lang(LMnormal, 0, 16r0A80, 16r0AFF, "Gujarati"),
	ref Lang(LMnormal, 0, 16r0B00, 16r0B7F, "Oriya"),
	ref Lang(LMnormal, 0, 16r0B80, 16r0BFF, "Tamil"),
	ref Lang(LMnormal, 0, 16r0C00, 16r0C7F, "Telugu"),
	ref Lang(LMnormal, 0, 16r0C80, 16r0CFF, "Kannada"),
	ref Lang(LMnormal, 0, 16r0D00, 16r0D7F, "Malayalam"),
	ref Lang(LMnormal, 0, 16r0E00, 16r0E7F, "Thai"),
	ref Lang(LMnormal, 0, 16r0E80, 16r0EFF, "Lao"),
	ref Lang(LMnormal, 0, 16r1000, 16r105F, "Tibetan"),
	ref Lang(LMnormal, 0, 16r10A0, 16r10FF, "Georgian"),
	ref Lang(LMnormal, 0, 16r3040, 16r30FF, "Japanese"),
	ref Lang(LMnormal, 0, 16r3100, 16r312F, "Chinese"),
	ref Lang(LMfirst,  0, 16r3130, 16r318F, "Korean"),
	ref Lang(LMmulti,  0, 16r3400, 16r3D2F, "Korean"),
	ref Lang(LMshared, 0, 16r4e00, 16r9fff, "CJK"),
	};
}

resetstate()
{
	buf = array[BUFSZ] of byte;
	nbuf = 0;
	cfreq = array[140] of {* => 0};
	wfreq = array[8] of {* => 0};
	guess = Fascii;
	havembuf = 0;
	language = buildlanguage();
	mime = 0;
	fname = nil;
	slash = -1;
}

# bb: build an exact array of byte from raw int byte-values, for magic
# patterns containing a byte >= 0x80 - see header comment for why a
# plain string literal cannot represent these.
bb(vals: array of int): array of byte
{
	r := array[len vals] of byte;
	for(i := 0; i < len vals; i++)
		r[i] = byte vals[i];
	return r;
}

# matchat: does b, starting at byte offset off, match pat exactly?
matchat(b: array of byte, off: int, pat: array of byte): int
{
	if(off < 0 || off+len pat > len b)
		return 0;
	for(i := 0; i < len pat; i++)
		if(b[off+i] != pat[i])
			return 0;
	return 1;
}

matchstr(b: array of byte, off: int, s: string): int
{
	return matchat(b, off, array of byte s);
}

isdigit(c: int): int { return c >= '0' && c <= '9'; }
isupperc(c: int): int { return c >= 'A' && c <= 'Z'; }
islowerc(c: int): int { return c >= 'a' && c <= 'z'; }
isalphac(c: int): int { return isupperc(c) || islowerc(c); }
tolowerc(c: int): int { if(isupperc(c)) return c+32; return c; }
isspacec(c: int): int { return c==' '||c=='\t'||c=='\n'||c=='\v'||c=='\f'||c=='\r'; }
isprintc(c: int): int { return c >= 16r20 && c < 16r7f; }

le32(b: array of byte, off: int): int
{
	return (int b[off]&16rff) | ((int b[off+1]&16rff)<<8) |
		((int b[off+2]&16rff)<<16) | ((int b[off+3]&16rff)<<24);
}

cistrncmp(a: string, off: int, blen: int): int
{
	# case-insensitive compare of a (ASCII pattern) against buf starting
	# at byte offset off, for blen bytes - a's own length.
	if(off < 0 || off+blen > nbuf)
		return -1;
	for(i := 0; i < blen; i++){
		ca := tolowerc(int a[i]);
		cb := tolowerc(int buf[off+i]&16rff);
		if(ca != cb)
			return ca-cb;
	}
	return 0;
}

fail(msg: string)
{
	sys->fprint(stderr, "file: %s\n", msg);
	raise "fail:file";
}

# utfconv: strip/report a byte-order mark, re-encoding UTF-16 to UTF-8
# in place (surrogate pairs are not handled - neither is the original -
# so this is only exact on the Basic Multilingual Plane, same limit as
# the C). Adjusts nbuf when it rewrites buf.
utfconv()
{
	if(nbuf < 4)
		return;
	if(matchat(buf, 0, bb(array[] of {16r00,16r00,16rFE,16rFF}))){
		if(!mime) emit("utf-32be ");
		return;
	}
	if(matchat(buf, 0, bb(array[] of {16rFE,16rFF,16r00,16r00}))){
		if(!mime) emit("utf-32le ");
		return;
	}
	if(matchat(buf, 0, bb(array[] of {16rEF,16rBB,16rBF}))){
		for(i := 3; i < nbuf; i++)
			buf[i-3] = buf[i];
		nbuf -= 3;
		return;
	}
	if(matchat(buf, 0, bb(array[] of {16rFE,16rFF}))){
		if(!mime) emit("utf-16be ");
		n := nbuf-2;
		rb := array[n] of byte;
		for(j := 0; j < n; j++)
			rb[j] = buf[j+2];
		p := 0;
		k := 0;
		while(k+2 <= n && p < BUFSZ-Sys->UTFmax-1){
			r := (int rb[k+1]&16rff) | ((int rb[k]&16rff)<<8);
			p += sys->char2byte(r, buf, p);
			k += 2;
		}
		nbuf = p;
		return;
	}
	if(matchat(buf, 0, bb(array[] of {16rFF,16rFE}))){
		if(!mime) emit("utf-16le ");
		n := nbuf-2;
		rb := array[n] of byte;
		for(j := 0; j < n; j++)
			rb[j] = buf[j+2];
		p := 0;
		k := 0;
		while(k+2 <= n && p < BUFSZ-Sys->UTFmax-1){
			r := (int rb[k]&16rff) | ((int rb[k+1]&16rff)<<8);
			p += sys->char2byte(r, buf, p);
			k += 2;
		}
		nbuf = p;
		return;
	}
}

bump_utf_count(r: int)
{
	high := len language;
	low := 0;
	while(low < high){
		mid := (low+high)/2;
		if(r >= language[mid].low){
			if(r <= language[mid].high){
				language[mid].count++;
				return;
			}
			low = mid+1;
		} else
			high = mid;
	}
}

utf_count(): int
{
	count := 0;
	for(i := 0; i < len language; i++)
		if(language[i].count > 0)
			if(language[i].mode == LMnormal || language[i].mode == LMfirst)
				count++;
	return count;
}

chkascii(): int
{
	for(lc := 'a'; lc < 'z'; lc++)
		if(cfreq[lc] != 0)
			return 1;
	for(uc := 'A'; uc < 'Z'; uc++)
		if(cfreq[uc] != 0)
			return 1;
	return 0;
}

find_first(name: string): int
{
	for(i := 0; i < len language; i++)
		if(language[i].mode == LMfirst && language[i].name == name)
			return i;
	return -1;
}

print_utf()
{
	if(mime){
		emit(PLAIN+"\n");
		return;
	}
	printed := 0;
	if(chkascii()){
		printed = 1;
		emit("Ascii");
	}
	for(i := 0; i < len language; i++){
		if(language[i].count == 0)
			continue;
		case language[i].mode {
		LMmulti =>
			j := find_first(language[i].name);
			if(j < 0 || language[j].count > 0)
				continue;
			# fall through to name it, same as the C's fallthrough
			if(printed)
				emit(" & ");
			else
				printed = 1;
			emit(language[i].name);
		LMnormal or LMfirst =>
			if(printed)
				emit(" & ");
			else
				printed = 1;
			emit(language[i].name);
		* =>
			;
		}
	}
	if(!printed)
		emit("UTF");
	emit(" text\n");
}

# wordfreq: extract byte-level [A-Za-z]+ runs and look each up in
# dict[] via the SAME binary search as the C, over the SAME (partly
# unsorted - see header comment) table order.
wordfreq()
{
	p := 0;
	while(p < nbuf){
		while(p < nbuf && !isalphac(int buf[p]&16rff))
			p++;
		if(p >= nbuf)
			return;
		start := p;
		while(p < nbuf && isalphac(int buf[p]&16rff))
			p++;
		word := string buf[start:p];
		low := 0;
		high := len dict;
		while(low < high){
			mid := (low+high)/2;
			r := 0;
			if(dict[mid].word < word)
				r = -1;
			else if(dict[mid].word > word)
				r = 1;
			if(r == 0){
				wfreq[dict[mid].class]++;
				break;
			}
			if(r < 0)
				low = mid+1;
			else
				high = mid;
		}
	}
}

# runehist: the character-frequency histogram at the heart of gross
# classification (Fascii/Flatin/Futf/Fbinary/Feascii/Fnull) and of
# isc()/islimbo()/isas()/isenglish() afterwards. See header comment for
# why byte2char()'s invalid-sequence value is substituted with the raw
# byte, matching Plan 9's own chartorune() convention rather than
# Inferno's Runeerror.
runehist()
{
	p := 0;
	while(p < nbuf){
		(r, w, ok) := sys->byte2char(buf, p);
		if(w == 0)
			break;		# truncated trailing sequence: stop, as
					# the C's fullrune()-guarded loop does
		if(!ok)
			r = int buf[p] & 16rff;
		f := 0;
		if(r == 0)
			f = Cnull;
		else if(r <= 16r7f){
			if(!isprintc(r) && !isspacec(r))
				f = Ceascii;
			else
				f = r;
		} else if(r == 16r80){
			bump_utf_count(r);
			f = Cutf;
		} else if(r < 16rA0)
			f = Cbinary;
		else if(r <= 16rff)
			f = Clatin;
		else {
			bump_utf_count(r);
			f = Cutf;
		}
		cfreq[f]++;
		p += w;
	}
}

# filetype: main()/typeone()'s shared body once a real fd is in hand -
# stat, read once, classify. fname/slash must already be set by the
# caller (isp9font() reads them).
filetype(f: ref FD)
{
	fd = f;
	(ok, d) := sys->fstat(fd);
	if(ok == -1){
		sys->fprint(stderr, "file: cannot stat: %r\n");
		return;
	}
	mbuf = d;
	havembuf = 1;
	if(mbuf.mode & Sys->DMDIR){
		emit(choosestr(mime, OCTET, "directory")+"\n");
		return;
	}
	# the C gates here on mbuf->type being a Plan 9 mounted-file/pipe
	# channel type ('M'/'|') and calls anything else "special" without
	# reading it - does not transfer to this emu's own dtype
	# convention (a real host-backed file here reports 'U', not 'M' -
	# checked directly, not assumed); see header comment. Only
	# directories (handled above) are special-cased here.

	buf = array[BUFSZ] of byte;
	n := sys->readn(fd, buf, len buf - 1);
	if(n < 0){
		sys->fprint(stderr, "file: cannot read: %r\n");
		return;
	}
	if(n == 0){
		emit(choosestr(mime, PLAIN, "empty file")+"\n");
		return;
	}
	nbuf = n;

	utfconv();

	cfreq = array[140] of {* => 0};
	for(i := 0; i < len language; i++)
		language[i].count = 0;
	runehist();

	if(cfreq[Cbinary] != 0)
		guess = Fbinary;
	else if(cfreq[Cutf] != 0)
		guess = Futf;
	else if(cfreq[Clatin] != 0)
		guess = Flatin;
	else if(cfreq[Ceascii] != 0)
		guess = Feascii;
	else if(cfreq[Cnull] != 0)
		guess = Fbinary;
	else
		guess = Fascii;

	wfreq = array[8] of {* => 0};
	if(guess == Fascii || guess == Flatin || guess == Futf)
		wordfreq();

	# dispatch, in the C's own call[] order - Limbo has no first-class
	# function-pointer array (bufio.m's own BufioFill callback is a
	# whole separate loadable module, not a bare fn value - not
	# appropriate for thirty small same-file functions), so this is a
	# flat sequence rather than a loop over a table; the ORDER is what
	# matters and is preserved exactly. isexec/iscint are skipped -
	# see header comment.
	if(long0())		return;
	if(istring())		return;
	if(iself())		return;
	if(isexecscript())	return;
	if(iff())		return;
	if(longoff())		return;
	if(isoffstr())		return;
	if(isudiff())		return;
	if(isrfc822())		return;
	if(ismbox())		return;
	if(istar())		return;
	if(ishtml())		return;
	if(islimbo())		return;
	if(isc())		return;
	if(isas())		return;
	if(isp9font())		return;
	if(isp9bit())		return;
	if(isrtf())		return;
	if(ismsdos())		return;
	if(isicocur())		return;
	if(isface())		return;
	if(istga())		return;
	if(isoggvorbis())	return;
	if(isoggopus())		return;
	if(ismp4())		return;
	if(ismp3())		return;
	if(ismung())		return;
	if(isenglish())		return;

	if(nbuf < 100 && !mime)
		emit("short ");
	if(guess == Fascii)
		emit(choosestr(mime, PLAIN, "Ascii")+"\n");
	else if(guess == Feascii)
		emit(choosestr(mime, PLAIN, "extended ascii")+"\n");
	else if(guess == Flatin)
		emit(choosestr(mime, PLAIN, "latin ascii")+"\n");
	else if(guess == Futf && utf_count() < 4)
		print_utf();
	else
		emit(choosestr(mime, OCTET, "binary")+"\n");
}

Filemagic: adt { x: int; mask: int; desc: string; mimet: string; };

# integers here must be as seen on a little-endian machine when read
# from a file - direct translation of the C's own comment and table.
long0tab := array[] of {
	Filemagic(int 16rF16DF16D, int 16rFFFFFFFF, "pac1 audio file", OCTET),
	Filemagic(16r31636170, int 16rFFFFFFFF, "pac3 audio file", OCTET),
	Filemagic(16r32630070, int 16rFFFF00FF, "pac4 audio file", OCTET),
	Filemagic(int 16rBA010000, int 16rFFFFFFFF, "mpeg system stream", OCTET),
	Filemagic(16r43614c66, int 16rFFFFFFFF, "FLAC audio file", "audio/flac"),
	Filemagic(16r30800CC0, int 16rFFFFFFFF, "inferno .dis executable", OCTET),
	Filemagic(16r04034B50, int 16rFFFFFFFF, "zip archive", "application/zip"),
	Filemagic(8r070707, 16rFFFF, "cpio archive", "application/x-cpio"),
	Filemagic(16r2F7, 16rFFFF, "tex dvi", "application/dvi"),
	Filemagic(16rfaff, 16rfeff, "mp3 audio", "audio/mpeg"),
	Filemagic(16rf0ff, 16rf6ff, "aac audio", "audio/aac"),
	Filemagic(int 16rcefaedfe, int 16rFFFFFFFF, "32-bit power Mach-O executable", OCTET),
	Filemagic(int 16rcffaedfe, int 16rFFFFFFFF, "64-bit power Mach-O executable", OCTET),
	Filemagic(int 16rfeedface, int 16rFFFFFFFF, "386 Mach-O executable", OCTET),
	Filemagic(int 16rfeedfacf, int 16rFFFFFFFF, "amd64 Mach-O executable", OCTET),
	Filemagic(int 16rbebafeca, int 16rFFFFFFFF, "Mach-O universal executable", OCTET),
	Filemagic(int 16rad4e5cd1, int 16rFFFFFFFF, "venti arena", OCTET),
	Filemagic(int 16r2bb19a52, int 16rFFFFFFFF, "paq archive", OCTET),
	Filemagic(int 16r1a53454e, int 16rFFFFFFFF, "NES ROM", OCTET),
	Filemagic(int 16ra1b2c3d4, int 16rFFFFFFFF, "pcap file", "application/vnd.tcpdump.pcap"),
	Filemagic(int 16rd4c3b2a1, int 16rFFFFFFFF, "pcap file", "application/vnd.tcpdump.pcap"),
	Filemagic(int 16ra1b23c4d, int 16rFFFFFFFF, "pcap file", "application/vnd.tcpdump.pcap"),
	Filemagic(int 16r4d3cb2a1, int 16rFFFFFFFF, "pcap file", "application/vnd.tcpdump.pcap"),
};

filemagic(tab: array of Filemagic, x: int): int
{
	for(i := 0; i < len tab; i++)
		if((x & tab[i].mask) == tab[i].x){
			emit(choosestr(mime, tab[i].mimet, tab[i].desc)+"\n");
			return 1;
		}
	return 0;
}

long0(): int
{
	if(nbuf < 4)
		return 0;
	return filemagic(long0tab, le32(buf, 0));
}

Fileoffmag: adt { off: int; x: int; mask: int; desc: string; mimet: string; };

longofftab := array[] of {
	Fileoffmag(256*1024, int 16re7a5e4a9, int 16rFFFFFFFF, "venti arenas partition", OCTET),
	Fileoffmag(256*1024, int 16rc75e5cd1, int 16rFFFFFFFF, "venti index section", OCTET),
	Fileoffmag(128*1024, int 16r89ae7637, int 16rFFFFFFFF, "fossil write buffer", OCTET),
	Fileoffmag(4, 16r31647542, int 16rFFFFFFFF, "OS X finder properties", OCTET),
	Fileoffmag(16r100, int 16r41474553, int 16rFFFFFFFF, "SEGA ROM", OCTET),
	Fileoffmag(16r1fc, int 16rAA550000, int 16rFFFF0000, "bootable disk image", OCTET),
};

longoff(): int
{
	tmp := array[4] of byte;
	for(i := 0; i < len longofftab; i++){
		t := longofftab[i];
		if(sys->seek(fd, big t.off, Sys->SEEKSTART) < big 0)
			continue;
		if(sys->readn(fd, tmp, len tmp) != len tmp)
			continue;
		x := le32(tmp, 0);
		if((x & t.mask) == t.x){
			emit(choosestr(mime, t.mimet, t.desc)+"\n");
			return 1;
		}
	}
	return 0;
}

# Strent: an initial-bytes classifier. length -1 means "use the key's
# own byte length" (the C's file_string[] uses -1 for a handful of
# entries where the literal's own strlen() is the intended length,
# rather than a shorter explicit prefix). Every key with a byte >=
# 0x80, an embedded NUL, or a control character is built via bb() -
# see header comment - rather than as a Limbo string literal.
Strent: adt { key: array of byte; desc: string; length: int; mimet: string; };

file_string := array[] of {
	Strent(array[] of {byte 16r1f, byte 16r9d}, "compressed", 2, "application/x-compress"),
	Strent(array[] of {byte 16r1f, byte 16r8b}, "gzip compressed", 2, "application/x-gzip"),
	Strent(array[] of {byte 66, byte 90, byte 104}, "bzip2 compressed", 3, "application/x-bzip2"),
	Strent(array[] of {byte '!', byte '<', byte 'a', byte 'r', byte 'c', byte 'h', byte '>', byte 10, byte '_', byte '_', byte '.', byte 'S', byte 'Y', byte 'M', byte 'D', byte 'E'},
		"archive random library", 16, OCTET),
	Strent(array[] of {byte '!', byte '<', byte 'a', byte 'r', byte 'c', byte 'h', byte '>', byte 10}, "archive", 8, OCTET),
	Strent(array[] of {byte 48, byte 55, byte 48, byte 55, byte 48, byte 55}, "cpio archive - ascii header", 6, OCTET),
	Strent(array[] of {byte 'Q', byte 'F', byte 'I', byte 16rfb}, "QCOW disk image", 4, OCTET),
	Strent(array[] of {byte 37, byte 33}, "postscript", 2, "application/postscript"),
	Strent(array[] of {byte 4, byte '%', byte '!'}, "postscript", 3, "application/postscript"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32, byte 112, byte 111, byte 115, byte 116}, "troff output for post", 8, "application/troff"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32, byte 76, byte 97, byte 116, byte 105, byte 110, byte 49}, "troff output for Latin1", 10, "application/troff"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32, byte 117, byte 116, byte 102}, "troff output for UTF", 7, "application/troff"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32, byte 50, byte 48, byte 50}, "troff output for 202", 7, "application/troff"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32, byte 97, byte 112, byte 115}, "troff output for aps", 7, "application/troff"),
	Strent(array[] of {byte 120, byte 32, byte 84, byte 32}, "troff output", 4, "application/troff"),
	Strent(array[] of {byte 71, byte 73, byte 70}, "GIF image", 3, "image/gif"),
	Strent(array[] of {byte 0, byte 'P', byte 'C', byte ' ', byte 'R', byte 'e', byte 's', byte 'e', byte 'a', byte 'r', byte 'c', byte 'h', byte ',', byte ' ', byte 'I', byte 'n', byte 'c', byte 0},
		"ghostscript fax file", 18, "application/ghostscript"),
	Strent(array[] of {byte 37, byte 80, byte 68, byte 70}, "PDF", 4, "application/pdf"),
	Strent(array[] of {byte 60, byte 33, byte 68, byte 79, byte 67, byte 84, byte 89, byte 80, byte 69}, "HTML file", 9, "text/html"),
	Strent(array[] of {byte 60, byte 33, byte 100, byte 111, byte 99, byte 116, byte 121, byte 112, byte 101}, "HTML file", 9, "text/html"),
	Strent(array[] of {byte 60, byte 33, byte 45, byte 45}, "XML file", 4, "text/xml"),
	Strent(array[] of {byte 60, byte 104, byte 116, byte 109, byte 108, byte 62}, "HTML file", 6, "text/html"),
	Strent(array[] of {byte 60, byte 72, byte 84, byte 77, byte 76, byte 62}, "HTML file", 6, "text/html"),
	Strent(array[] of {byte 60, byte 63, byte 120, byte 109, byte 108}, "HTML file", 5, "text/html"),
	Strent(array[] of {byte 'I', byte 'I', byte 16r2a, byte 0}, "tiff", 4, "image/tiff"),
	Strent(array[] of {byte 'M', byte 'M', byte 0, byte 16r2a}, "tiff", 4, "image/tiff"),
	Strent(array[] of {byte 16rff, byte 16rd8, byte 16rff, byte 16re0}, "jpeg", 4, "image/jpeg"),
	Strent(array[] of {byte 16rff, byte 16rd8, byte 16rff, byte 16re1}, "jpeg", 4, "image/jpeg"),
	Strent(array[] of {byte 16rff, byte 16rd8, byte 16rff, byte 16rdb}, "jpeg", 4, "image/jpeg"),
	Strent(array[] of {byte 16rff, byte 16rd8}, "jpeg", 2, "image/jpeg"),
	Strent(array[] of {byte 66, byte 77}, "bmp", 2, "image/bmp"),
	Strent(array[] of {byte 16rD0, byte 16rCF, byte 16r11, byte 16rE0, byte 16rA1, byte 16rB1, byte 16r1A, byte 16rE1},
		"microsoft office document", 8, "application/doc"),
	Strent(array[] of {byte 60, byte 77, byte 97, byte 107, byte 101, byte 114, byte 70, byte 105, byte 108, byte 101, byte 32}, "FrameMaker file", 11, "application/framemaker"),
	Strent(array[] of {byte 16r1b, byte 'E', byte 16r1b}, "HP PCL printer data", 3, OCTET),
	Strent(array[] of {byte 16r1b, byte '&'}, "HP PCL printer data", 2, OCTET),
	Strent(array[] of {byte 16r1b, byte '%', byte '-', byte '1', byte '2', byte '3', byte '4', byte '5', byte 'X'}, "HPJCL file", 9, "application/hpjcl"),
	Strent(array[] of {byte 16r1b, byte 'L', byte 'u', byte 'a'}, "Lua bytecode", 4, OCTET),
	Strent(array[] of {byte 73, byte 68, byte 51}, "mp3 audio with id3", 3, "audio/mpeg"),
	Strent(array[] of {byte 46, byte 115, byte 110, byte 100}, "sun audio", 4, "audio/basic"),
	Strent(array[] of {byte 16r89, byte 'P', byte 'N', byte 'G'}, "PNG image", 4, "image/png"),
	Strent(array[] of {byte 'P', byte '1', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte 'P', byte '2', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte 'P', byte '3', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte 'P', byte '4', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte 'P', byte '5', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte 'P', byte '6', byte 10}, "ppm", 3, "image/ppm"),
	Strent(array[] of {byte '/', byte '*', byte ' ', byte 'X', byte 'P', byte 'M', byte ' ', byte '*', byte '/', byte 10}, "xbm", 10, "image/xbm"),
	Strent(array[] of {byte 46, byte 72, byte 84, byte 77, byte 76, byte 32}, "troff -ms input", 6, "text/troff"),
	Strent(array[] of {byte 46, byte 76, byte 80}, "troff -ms input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 78, byte 68}, "troff -ms input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 80, byte 80}, "troff -ms input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 84, byte 76}, "troff -ms input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 84, byte 82}, "troff -ms input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 84, byte 72}, "manual page", 3, "text/troff"),
	Strent(array[] of {byte 16r2e, byte 16r5c, byte 16r22}, "troff input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 100, byte 101}, "troff input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 105, byte 102}, "troff input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 110, byte 114}, "troff input", 3, "text/troff"),
	Strent(array[] of {byte 46, byte 116, byte 114}, "troff input", 3, "text/troff"),
	Strent(array[] of {byte 118, byte 97, byte 99, byte 58}, "venti score", 4, PLAIN),
	Strent(array[] of {byte 45, byte 45, byte 45, byte 45, byte 45, byte 66, byte 69, byte 71, byte 73, byte 78, byte 32, byte 67, byte 69, byte 82, byte 84, byte 73, byte 70, byte 73, byte 67, byte 65, byte 84, byte 69, byte 45, byte 45, byte 45, byte 45, byte 45, byte 10}, "pem certificate", -1, PLAIN),
	Strent(array[] of {byte 45, byte 45, byte 45, byte 45, byte 45, byte 66, byte 69, byte 71, byte 73, byte 78, byte 32, byte 84, byte 82, byte 85, byte 83, byte 84, byte 69, byte 68, byte 32, byte 67, byte 69, byte 82, byte 84, byte 73, byte 70, byte 73, byte 67, byte 65, byte 84, byte 69, byte 45, byte 45, byte 45, byte 45, byte 45, byte 10}, "pem trusted certificate", -1, PLAIN),
	Strent(array[] of {byte 45, byte 45, byte 45, byte 45, byte 45, byte 66, byte 69, byte 71, byte 73, byte 78, byte 32, byte 88, byte 53, byte 48, byte 57, byte 32, byte 67, byte 69, byte 82, byte 84, byte 73, byte 70, byte 73, byte 67, byte 65, byte 84, byte 69, byte 45, byte 45, byte 45, byte 45, byte 45, byte 10}, "pem x.509 certificate", -1, PLAIN),
	Strent(array[] of {byte 115, byte 117, byte 98, byte 106, byte 101, byte 99, byte 116, byte 61, byte 47, byte 67, byte 61}, "pem certificate with header", -1, PLAIN),
	Strent(array[] of {byte 112, byte 114, byte 111, byte 99, byte 101, byte 115, byte 115, byte 32, byte 115, byte 110, byte 97, byte 112, byte 115, byte 104, byte 111, byte 116, byte 32}, "process snapshot", -1, "application/snapfs"),
	Strent(array[] of {byte 100, byte 56, byte 58, byte 97, byte 110, byte 110, byte 111, byte 117, byte 110, byte 99, byte 101}, "torrent file", 11, "application/x-bittorrent"),
	Strent(array[] of {byte 91, byte 112, byte 108, byte 97, byte 121, byte 108, byte 105, byte 115, byte 116, byte 93}, "playlist", 10, "application/x-scpls"),
	Strent(array[] of {byte 35, byte 69, byte 88, byte 84, byte 77, byte 51, byte 85}, "playlist", 7, "audio/x-mpegurl"),
	Strent(array[] of {byte 66, byte 69, byte 71, byte 73, byte 78, byte 58, byte 86, byte 67, byte 65, byte 82, byte 68, byte 13, byte 10}, "vCard", 13, "text/directory;profile=vcard"),
	Strent(array[] of {byte 66, byte 69, byte 71, byte 73, byte 78, byte 58, byte 86, byte 67, byte 65, byte 82, byte 68, byte 10}, "vCard", 12, "text/directory;profile=vcard"),
	Strent(array[] of {byte 65, byte 84, byte 38, byte 84}, "DjVu document", 4, "image/vnd.djvu"),
	Strent(array[] of {byte 69, byte 120, byte 116, byte 101, byte 110, byte 100, byte 101, byte 100, byte 32, byte 109, byte 111, byte 100, byte 117, byte 108, byte 101, byte 58, byte 32}, "XM audio", 17, "audio/xm"),
	Strent(array[] of {byte 77, byte 84, byte 104, byte 100}, "midi audio", 4, "audio/midi"),
	Strent(array[] of {byte 'M', byte 'U', byte 'S', byte 16r1a}, "mus audio", 4, "audio/mus"),
	Strent(array[] of {byte 'C', byte 'r', byte 'e', byte 'a', byte 't', byte 'i', byte 'v', byte 'e', byte ' ', byte 'V', byte 'o', byte 'i', byte 'c', byte 'e', byte ' ', byte 'F', byte 'i', byte 'l', byte 'e', byte 16r1a},
		"voc audio", 20, "audio/x-voc"),
	Strent(array[] of {byte 'p', byte 'r', byte 16r0f}, "Plan 9 profile data", 3, OCTET),
	Strent(array[] of {byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16r00, byte 16r00, byte 16r00, byte 16rbb, byte 16r11, byte 16r22, byte 16r00, byte 16r44, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16raa, byte 16r99, byte 16r55, byte 16r66},
		"Xilinx bitstream (not byteswappped)", 52, OCTET),
	Strent(array[] of {byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rbb, byte 16r00, byte 16r00, byte 16r00, byte 16r44, byte 16r00, byte 16r22, byte 16r11, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16rff, byte 16r66, byte 16r55, byte 16r99, byte 16raa},
		"Xilinx bitstream (byteswappped)", 52, OCTET),
};

istring(): int
{
	for(i := 0; i < len file_string; i++){
		e := file_string[i];
		l := e.length;
		if(l == -1)
			l = len e.key;
		if(nbuf >= l && matchat(buf, 0, e.key[0:l])){
			emit(choosestr(mime, e.mimet, e.desc)+"\n");
			return 1;
		}
	}
	if(matchat(buf, 0, array of byte "TYPE=")){	# td
		ti := 5;
		while(ti < nbuf && buf[ti] != byte '\n')
			ti++;
		if(mime)
			emit(OCTET+"\n");
		else
			emit(string buf[5:ti] + " picture\n");
		return 1;
	}
	return 0;
}

Offstrent: adt { off: int; key: array of byte; desc: string; mimet: string; };

offstrs := array[] of {
	Offstrent(32*1024, array[] of {byte 1, byte 'C', byte 'D', byte '0', byte '0', byte '1', byte 1}, "ISO9660 CD image", "application/x-iso9660-image"),
	Offstrent(32*4, array[] of {byte 'D', byte 'I', byte 'C', byte 'M'}, "DICOM medical imaging data", "application/dicom"),
	Offstrent(1080, array[] of {byte 'M', byte '.', byte 'K', byte '.'}, "Amiga module", "audio/mod"),
};

isoffstr(): int
{
	tmp := array[256] of byte;
	for(i := 0; i < len offstrs; i++){
		e := offstrs[i];
		n := len e.key;
		if(sys->seek(fd, big e.off, Sys->SEEKSTART) < big 0)
			continue;
		if(sys->readn(fd, tmp, n) != n)
			continue;
		if(matchat(tmp, 0, e.key)){
			emit(choosestr(mime, e.mimet, e.desc)+"\n");
			return 1;
		}
	}
	return 0;
}

# strstr/strchr over the byte buffer, used by several classifiers below.
bstrstr(b: array of byte, off: int, s: string): int
{
	pat := array of byte s;
	n := len b;
	pn := len pat;
	for(i := off; i+pn <= n; i++)
		if(matchat(b, i, pat))
			return i;
	return -1;
}

bindexof(b: array of byte, off: int, c: int): int
{
	for(i := off; i < len b; i++)
		if(int b[i] == c)
			return i;
	return -1;
}

iff(): int
{
	if(matchstr(buf, 0, "FORM") && matchstr(buf, 8, "AIFF")){
		emit(choosestr(mime, "audio/x-aiff", "aiff audio")+"\n");
		return 1;
	}
	if(matchstr(buf, 0, "RIFF")){
		if(matchstr(buf, 8, "WAVE"))
			emit(choosestr(mime, "audio/wave", "wave audio")+"\n");
		else if(matchstr(buf, 8, "AVI "))
			emit(choosestr(mime, "video/avi", "avi video")+"\n");
		else if(matchstr(buf, 8, "WEBP"))
			emit(choosestr(mime, "image/webp", "webp image")+"\n");
		else
			emit(choosestr(mime, OCTET, "riff file")+"\n");
		return 1;
	}
	return 0;
}

isudiff(): int
{
	p := bstrstr(buf, 0, "diff");
	if(p < 0) return 0;
	p = bindexof(buf, p, '\n');
	if(p < 0) return 0;
	p++;
	if(!matchstr(buf, p, "--- ")) return 0;
	p = bindexof(buf, p, '\n');
	if(p < 0) return 0;
	p++;
	if(!matchstr(buf, p, "+++ ")) return 0;
	p = bindexof(buf, p, '\n');
	if(p < 0) return 0;
	p++;
	if(!matchstr(buf, p, "@@ ")) return 0;
	emit(choosestr(mime, "text/plain", "unified diff output")+"\n");
	return 1;
}

rfc822_string := array[] of {
	"from:", "date:", "to:", "subject:", "received:", "reply to:", "sender:",
};

isrfc822(): int
{
	count := 0;
	p := 0;
	first := 1;
	while(p < nbuf){
		q := bindexof(buf, p, '\n');
		if(q < 0)
			break;
		if(first && matchstr(buf, p, "From ") && bstrstr(buf, p, " remote from ") >= 0 && bstrstr(buf, p, " remote from ") < q){
			count++;
			p = q+1;
			first = 0;
			continue;
		}
		first = 0;
		if(int buf[p] != '\t' && int buf[p] != ' '){
			r := bindexof(buf, p, ':');
			if(r < 0 || r > q)
				break;
			for(i := 0; i < len rfc822_string; i++){
				w := rfc822_string[i];
				if(p+len w <= q+1 && cistrncmp(w, p, len w) == 0){
					count++;
					break;
				}
			}
		}
		p = q+1;
	}
	if(count >= 3){
		emit(choosestr(mime, "message/rfc822", "email file")+"\n");
		return 1;
	}
	return 0;
}

ismbox(): int
{
	q := bindexof(buf, 0, '\n');
	if(q < 0)
		return 0;
	if(matchstr(buf, 0, "From ")){
		rem := bstrstr(buf, 0, " remote from ");
		if(rem < 0 || rem >= q){
			emit(choosestr(mime, "application/mbox", "mail box")+"\n");
			return 1;
		}
	}
	return 0;
}

# tar header layout, ustar/POSIX - see p1003.2b. Shared conceptually
# with tar.c's own copy (this file inlines it, the same way the C
# source does - "from tar.c" in the original's own comment).
NAMSIZ: con 100;
TBLOCK: con 512;

tarchecksum(hp: array of byte): int
{
	s := 0;
	for(i := 0; i < TBLOCK; i++){
		if(i >= 148 && i < 156)
			s += ' ';	# chksum field itself reads as spaces 
		else
			s += int hp[i] & 16rff;
	}
	return s;
}

octalfield(hp: array of byte, off: int, flen: int): int
{
	i := off;
	end := off+flen;
	while(i < end && (int hp[i]==' ' || int hp[i]=='\t'))
		i++;
	v := 0;
	while(i < end && int hp[i] >= '0' && int hp[i] <= '7'){
		v = v*8 + (int hp[i]-'0');
		i++;
	}
	return v;
}

istar(): int
{
	if(sys->seek(fd, big 0, Sys->SEEKSTART) < big 0)
		return 0;
	tblock := array[TBLOCK] of byte;
	if(sys->readn(fd, tblock, TBLOCK) != TBLOCK)
		return 0;
	chksum := octalfield(tblock, 148, 8);	# hdr->chksum offset/size 
	if(int tblock[0] != 0 && tarchecksum(tblock) == chksum){
		if(matchat(tblock, 257, array of byte "ustar") && tblock[262] == byte 0)	# strcmp(hdr->magic,"ustar")==0: needs the NUL too 
			emit(choosestr(mime, "application/x-ustar", "posix tar archive")+"\n");
		else
			emit(choosestr(mime, "application/x-tar", "tar archive")+"\n");
		return 1;
	}
	return 0;
}

html_string := array[] of {
	"blockquote",
	"!DOCTYPE", "![CDATA[", "basefont", "frameset", "noframes", "textarea",
	"caption",
	"button", "center", "iframe", "object", "option", "script",
	"select", "strong",
	"blink", "embed", "frame", "input", "label", "param", "small",
	"style", "table", "tbody", "tfoot", "thead", "title",
	"?xml", "body", "code", "font", "form", "head", "html",
	"link", "menu", "meta", "span",
	"!--", "big", "dir", "div", "img", "pre", "sub", "sup",
	"br", "dd", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5",
	"h6", "hr", "li", "ol", "td", "th", "tr", "tt", "ul",
	"a", "b", "i", "p", "q", "u",
};

htmlfollower(c: int): int
{
	return c=='\t' || c=='\r' || c=='\n' || c==' ' || c=='/' || c=='>';
}

ishtml(): int
{
	count := 0;
	p := 0;
	for(;;){
		while(p < nbuf && int buf[p] != '<')
			p++;
		p++;
		if(p >= nbuf)
			break;
		if(int buf[p] == '/')
			p++;
		if(p >= nbuf)
			break;
		for(i := 0; i < len html_string; i++){
			w := html_string[i];
			n := len w;
			if(p+n > nbuf)
				continue;
			if(cistrncmp(w, p, n) == 0){
				p += n;
				if(p < nbuf && htmlfollower(int buf[p])){
					count++;
					if(count > 2){
						emit(choosestr(mime, "text/html", "HTML file")+"\n");
						return 1;
					}
				}
				break;
			}
		}
	}
	return 0;
}

# isc/islimbo/isas: word-frequency heuristics over wfreq[] (populated
# by wordfreq(), see its own header note on the preserved dict[] bug).
isc(): int
{
	n := wfreq[I1];
	yes := 0;
	if(n >= 2 && wfreq[I2] >= n && wfreq[I3] >= n && cfreq['.'] >= n)
		yes = 1;
	else if(n >= 1 && wfreq[Alword] >= n && wfreq[I3] >= n && cfreq['.'] >= n)
		yes = 1;
	else if(wfreq[Cword] >= 5 && cfreq[';'] >= 5)
		yes = 1;
	else if(cfreq[';'] >= 10 && cfreq['='] >= 10 && wfreq[Cword] >= 1)
		yes = 1;
	if(!yes)
		return 0;
	if(mime){
		emit(PLAIN+"\n");
		return 1;
	}
	if(wfreq[Alword] > 0)
		emit("alef program\n");
	else
		emit("c program\n");
	return 1;
}

islimbo(): int
{
	if(wfreq[Lword] < 4)
		return 0;
	emit(choosestr(mime, PLAIN, "limbo program")+"\n");
	return 1;
}

isas(): int
{
	if(wfreq[Aword] < 2)
		return 0;
	emit(choosestr(mime, PLAIN, "as program")+"\n");
	return 1;
}

isenglish(): int
{
	if(guess != Fascii && guess != Feascii)
		return 0;
	badpun := 0;
	punct := 0;
	for(p := 0; p < nbuf-1; p++){
		c := int buf[p];
		if(c=='.'||c==','||c==')'||c=='%'||c==';'||c==':'||c=='?'){
			punct++;
			nc := int buf[p+1];
			if(nc != ' ' && nc != '\n')
				badpun++;
		}
	}
	if(badpun*5 > punct)
		return 0;
	if(cfreq['>']+cfreq['<']+cfreq['/'] > cfreq['e'])
		return 0;
	if(2*cfreq[';'] > cfreq['e'])
		return 0;

	vow := 0;
	vowels := "AEIOU";
	for(vi := 0; vi < len vowels; vi++){
		vow += cfreq[vowels[vi]];
		vow += cfreq[tolowerc(vowels[vi])];
	}
	comm := 0;
	common := "ETAION";
	for(ci := 0; ci < len common; ci++){
		comm += cfreq[common[ci]];
		comm += cfreq[tolowerc(common[ci])];
	}
	rare := 0;
	rares := "VJKQXZ";
	for(ri := 0; ri < len rares; ri++){
		rare += cfreq[rares[ri]];
		rare += cfreq[tolowerc(rares[ri])];
	}
	if(vow*5 >= nbuf-cfreq[' '] && comm >= 10*rare){
		emit(choosestr(mime, PLAIN, "English text")+"\n");
		return 1;
	}
	return 0;
}

isexecscript(): int
{
	if(!matchstr(buf, 0, "#!"))
		return 0;
	n := nbuf-2;
	if(n > 128) n = 128;
	tmp := buf[2:2+n];
	end := len tmp;
	nl := -1;
	for(ni := 0; ni < end; ni++)
		if(int tmp[ni] == '\n'){ nl = ni; break; }
	if(nl >= 0) end = nl;
	for(si := 0; si < end; si++)
		if(int tmp[si]==' ' || int tmp[si]=='\t'){ end = si; break; }
	last := 0;
	for(li := 0; li < end; li++)
		if(int tmp[li] == '/')
			last = li+1;
	p := string tmp[last:end];
	case p {
	"rc" =>		emit(choosestr(mime, PLAIN, "rc executable file")+"\n");
	"sh" =>		emit(choosestr(mime, "application/x-sh", "sh executable file")+"\n");
	"bash" =>	emit(choosestr(mime, "application/x-sh", "bash executable file")+"\n");
	"awk" =>	emit(choosestr(mime, PLAIN, "awk executable file")+"\n");
	"sed" =>	emit(choosestr(mime, PLAIN, "sed executable file")+"\n");
	"perl" =>	emit(choosestr(mime, PLAIN, "perl executable file")+"\n");
	* =>		emit(choosestr(mime, PLAIN, "unknown executable file")+"\n");
	}
	return 1;
}

# isp9bit/isp9font: Plan 9's own bitmap image and subfont formats -
# five (or three) whitespace-delimited 12-byte decimal fields at the
# start of the file. p9bitnum/depthof translate the C's in-place
# temporary-NUL-then-strtol trick as bounded-offset parses over buf
# directly, since array of byte here isn't NUL-terminated the way a C
# buffer is.
P9BITLEN: con 12;

p9bitnum(off: int): (int, int)
{
	if(off+P9BITLEN > len buf)
		return (0, 0);
	if(int buf[off+P9BITLEN-1] != ' ')
		return (0, 0);
	end := off+P9BITLEN-1;
	i := off;
	while(i < end && (int buf[i]==' ' || int buf[i]=='\t'))
		i++;
	neg := 0;
	if(i < end && (int buf[i]=='-' || int buf[i]=='+')){
		neg = int buf[i]=='-';
		i++;
	}
	digstart := i;
	v := 0;
	while(i < end && isdigit(int buf[i])){
		v = v*10 + (int buf[i]-'0');
		i++;
	}
	if(i == digstart || i != end)
		return (0, 0);
	if(neg) v = -v;
	return (v, 1);
}

autobasenum(off: int, end: int): int
{
	i := off;
	neg := 0;
	if(i < end && (int buf[i]=='-'||int buf[i]=='+')){
		neg = int buf[i]=='-';
		i++;
	}
	base := 10;
	if(i < end && int buf[i]=='0'){
		if(i+1 < end && (int buf[i+1]=='x'||int buf[i+1]=='X')){
			base = 16;
			i += 2;
		} else {
			base = 8;
			i++;
		}
	}
	v := 0;
	while(i < end){
		c := int buf[i];
		d := -1;
		if(c>='0'&&c<='9') d = c-'0';
		else if(c>='a'&&c<='f') d = c-'a'+10;
		else if(c>='A'&&c<='F') d = c-'A'+10;
		if(d < 0 || d >= base)
			break;
		v = v*base+d;
		i++;
	}
	if(neg) v = -v;
	return v;
}

depthof(off: int): (int, int)		# (depth, newformat) - -1 depth = fail
{
	end := off+12;
	if(end > len buf)
		return (-1, 0);
	i := off;
	while(i < end && int buf[i]==' ')
		i++;
	if(i == end)
		return (-1, 0);
	if(isdigit(int buf[i]))
		return (1 << autobasenum(i, end), 0);
	chans := "rgbkamx";
	d := 0;
	while(i < end && int buf[i] != ' '){
		c := int buf[i];
		found := 0;
		for(k := 0; k < len chans; k++)
			if(chans[k] == c){ found = 1; break; }
		if(!found)
			return (-1, 1);
		i++;
		if(i < end && isdigit(int buf[i])){
			start := i;
			while(i < end && isdigit(int buf[i]))
				i++;
			d += autobasenum(start, i);
		} else
			return (-1, 1);
	}
	if(d % 8 == 0 || (d != 0 && 8 % d == 0))
		return (d, 1);
	return (-1, 1);
}

p9subfont(off: int): int
{
	if(off+3*P9BITLEN > len buf)
		return 1;	# too big to have fit: assume subfont, as the C does 
	(n, ok1) := p9bitnum(off+0*P9BITLEN);
	if(!ok1) return 0;
	(h, ok2) := p9bitnum(off+1*P9BITLEN);
	if(!ok2) return 0;
	(a, ok3) := p9bitnum(off+2*P9BITLEN);
	if(!ok3) return 0;
	return n > 0 && h > 0 && a >= 0;
}

isp9bit(): int
{
	cmpr := 0;
	base := 0;
	if(matchstr(buf, 0, "compressed\n")){
		cmpr = 1;
		base = 11;
	}
	(dep, isnewfmt) := depthof(base+0*P9BITLEN);
	if(dep < 0)
		return 0;
	newlabel := choosestr(isnewfmt, "", "old ");
	(lox, ok1) := p9bitnum(base+1*P9BITLEN); if(!ok1) return 0;
	(loy, ok2) := p9bitnum(base+2*P9BITLEN); if(!ok2) return 0;
	(hix0, ok3) := p9bitnum(base+3*P9BITLEN); if(!ok3) return 0;
	(hiy0, ok4) := p9bitnum(base+4*P9BITLEN); if(!ok4) return 0;
	hix := hix0-lox;
	hiy := hiy0-loy;
	if(hix <= 0 || hiy <= 0)
		return 0;

	len_: int;
	if(dep < 8){
		px := 8/dep;
		len_ = (hix+px-1)/px;
	} else
		len_ = hix*dep/8;
	len_ *= hiy;
	len_ += 5*P9BITLEN;

	if(cmpr){
		emit(choosestr(mime, "image/p9bit\n",
			sys->sprint("Compressed %splan 9 image or subfont, depth %d, size %dx%d\n", newlabel, dep, hix, hiy)));
		return 1;
	}
	if(len_ != 0 && (mbuf.length == big 0 || mbuf.length == big len_ ||
	   mbuf.length > big len_ && mbuf.length < big (len_+P9BITLEN))){
		emit(choosestr(mime, "image/p9bit\n",
			sys->sprint("%splan 9 image, depth %d, size %dx%d\n", newlabel, dep, hix, hiy)));
		return 1;
	}
	if(p9subfont(len_) != 0){
		emit(choosestr(mime, "image/p9bit\n",
			sys->sprint("%ssubfont file, depth %d, size %dx%d\n", newlabel, dep, hix, hiy)));
		return 1;
	}
	return 0;
}

WHITESPACE(c: int): int { return c==' '||c=='\t'||c=='\n'; }

# getfontnum: extract one whitespace-delimited unsigned decimal at cp,
# returning (nextoffset, ok) - the C's own (cp,&rp) out-parameter pair.
getfontnum(cp: int): (int, int)
{
	while(cp < nbuf && WHITESPACE(int buf[cp]))
		cp++;
	if(cp >= nbuf || int buf[cp] < '0' || int buf[cp] > '9')
		return (cp, 0);
	i := cp;
	while(i < nbuf && isdigit(int buf[i]))
		i++;
	if(i >= nbuf || !WHITESPACE(int buf[i]))
		return (cp, 0);	# EOF right after the digits is a failure
				# too - a C NUL terminator isn't whitespace
				# either, so the original fails there too
	return (i, 1);
}

isp9font(): int
{
	(cp, ok1) := getfontnum(0);		# height 
	if(!ok1) return 0;
	(cp2, ok2) := getfontnum(cp);		# ascent 
	if(!ok2) return 0;
	cp = cp2;
	i := 0;
	for(;;){
		nl := bindexof(buf, cp, '\n');
		if(nl < 0)
			break;
		(a, oka) := getfontnum(cp);	# min 
		if(!oka) break;
		(b, okb) := getfontnum(a);	# max 
		if(!okb) return 0;
		(c, nil) := getfontnum(b);	# optional offset - ok ignored 
		cp = c;
		i++;
		while(cp < nbuf && WHITESPACE(int buf[cp]))
			cp++;
		pstart := cp;
		while(cp < nbuf && !WHITESPACE(int buf[cp]))
			cp++;
		# construct a candidate sibling path, if the entry's own name
		# isn't already absolute, using fname's own directory (slash)
		name := string buf[pstart:cp];
		path := name;
		if((len name == 0 || name[0] != '/') && slash >= 0)
			path = fname[0:slash+1] + name;
		(sok1, nil) := sys->stat(path);
		if(sok1 < 0){
			(sok2, nil) := sys->stat(path+".0");
			if(sok2 < 0)
				return 0;
		}
	}
	if(i != 0){
		emit(choosestr(mime, PLAIN, "font file")+"\n");
		return 1;
	}
	return 0;
}

isrtf(): int
{
	if(bstrstr(buf, 0, "\\rtf1") >= 0){
		emit(choosestr(mime, "application/rtf", "rich text format")+"\n");
		return 1;
	}
	return 0;
}

ismsdos(): int
{
	if(nbuf >= 2 && int buf[0]==16r4d && int buf[1]==16r5a){
		emit(choosestr(mime, "application/x-msdownload", "MSDOS executable")+"\n");
		return 1;
	}
	return 0;
}

isicocur(): int
{
	if(nbuf < 10)
		return 0;
	if(int buf[0]!=0 || int buf[1]!=0 || int buf[3]!=0 || int buf[9]!=0)
		return 0;
	if(int buf[4]==0 && int buf[5]==0)
		return 0;
	case int buf[2] {
	1 => emit(choosestr(mime, "image/x-icon", "Microsoft icon file")+"\n"); return 1;
	2 => emit(choosestr(mime, "image/x-icon", "Microsoft cursor file")+"\n"); return 1;
	}
	return 0;
}

istga(): int
{
	if(nbuf < 18)
		return 0;
	p := buf;
	if((int p[12]|int p[13]<<8) == 0) return 0;	# width 
	if((int p[14]|int p[15]<<8) == 0) return 0;	# height 
	bpp := int p[16];
	if(bpp!=8 && bpp!=15 && bpp!=16 && bpp!=24 && bpp!=32)
		return 0;
	if(((int p[2]|(1<<3)) & ~3) != (1<<3))
		return 0;
	if(int p[1] == 0){
		if((int p[2]&3) != 2 && (int p[2]&3) != 3)
			return 0;
		if((int p[5]|int p[6]<<8) != 0)
			return 0;
	} else if(int p[1] == 1){
		if((int p[2]&3) != 1 || int p[7] == 0)
			return 0;
		if((int p[5]|int p[6]<<8) == 0)
			return 0;
	} else
		return 0;
	emit(choosestr(mime, "image/tga", "targa image")+"\n");
	return 1;
}

ismp3(): int
{
	p := 0;
	e := nbuf-1;
	while(p < e){
		while(p < e && int buf[p] != 16rff)
			p++;
		if(p >= e)
			break;
		if((int buf[p+1] & 16rfe) == 16rfa){
			emit(choosestr(mime, "audio/mpeg", "mp3 audio")+"\n");
			return 1;
		}
		p++;
	}
	return 0;
}

ismp4(): int
{
	if(nbuf <= 12)
		return 0;
	if(!matchstr(buf, 4, "ftyp"))
		return 0;
	if(matchstr(buf, 8, "isom") || matchstr(buf, 8, "mp4")){
		emit(choosestr(mime, "video/mp4", "mp4 video")+"\n");
		return 1;
	}
	if(matchstr(buf, 8, "M4A ")){
		emit(choosestr(mime, "audio/m4a", "m4a audio")+"\n");
		return 1;
	}
	return 0;
}

isoggvorbis(): int
{
	if(!matchstr(buf, 0, "OggS"))
		return 0;
	if(!matchstr(buf, 29, "vorbis"))
		return 0;
	emit(choosestr(mime, "audio/ogg;codecs=vorbis", "Ogg Vorbis I profile")+"\n");
	return 1;
}

isoggopus(): int
{
	if(!matchstr(buf, 0, "OggS"))
		return 0;
	if(!matchstr(buf, 28, "OpusHead"))
		return 0;
	emit(choosestr(mime, "audio/ogg;codecs=opus", "Ogg Opus profile")+"\n");
	return 1;
}

ismung(): int
{
	if(nbuf < 64)
		return 0;
	bucket := array[8] of {* => 0};
	for(bi := nbuf-64; bi < nbuf; bi++)
		bucket[(int buf[bi]>>5)&7]++;
	cs := 0.0;
	for(ci := 0; ci < 8; ci++)
		cs += real ((bucket[ci]-8)*(bucket[ci]-8));
	cs /= 8.0;
	if(cs <= 24.322){
		if(int buf[0]==16r1f && int buf[1]==16r9d)
			emit(choosestr(mime, "application/x-compress", "compressed")+"\n");
		else if(int buf[0]==16r1f && int buf[1]==16r8b)
			emit(choosestr(mime, "application/x-gzip", "gzip compressed")+"\n");
		else if(int buf[0]=='B' && int buf[1]=='Z' && int buf[2]=='h')
			emit(choosestr(mime, "application/x-bzip2", "bzip2 compressed")+"\n");
		else if(int buf[0]==16r78 && int buf[1]==16r9c)
			emit(choosestr(mime, "application/x-deflate", "zlib compressed")+"\n");
		else
			emit(choosestr(mime, OCTET, "encrypted")+"\n");
		return 1;
	}
	return 0;
}

isface(): int
{
	ldepth := -1;
	p := 0;
	for(j := 0; j < 3; j++){
		for(i := 0; i < 3; i++){
			if(p+1 >= nbuf || int buf[p] != '0' || int buf[p+1] != 'x')
				return 0;
			l := 0;
			if(p+10 < nbuf && int buf[p+10] == ',')
				l = 2;
			else if(p+6 < nbuf && int buf[p+6] == ',')
				l = 1;
			else
				return 0;
			if(ldepth == -1)
				ldepth = l;
			if(l != ldepth)
				return 0;
			(nil, np) := hexscan(p);
			p = np;
			if(p >= nbuf || int buf[p] != ',')
				return 0;
			p++;
			while(p < nbuf && (int buf[p]==' '||int buf[p]=='\t'))
				p++;
		}
		if(p >= nbuf || int buf[p] != '\n')
			return 0;
		p++;
	}
	if(mime)
		emit("application/x-face\n");
	else
		emit(sys->sprint("face image depth %d\n", ldepth));
	return 1;
}

# hexscan: strtoul(p,&p,16) over buf - used only by isface() above.
hexscan(off: int): (int, int)
{
	v := 0;
	i := off;
	while(i < nbuf){
		c := int buf[i];
		d := -1;
		if(c>='0'&&c<='9') d=c-'0';
		else if(c>='a'&&c<='f') d=c-'a'+10;
		else if(c>='A'&&c<='F') d=c-'A'+10;
		if(d < 0)
			break;
		v = v*16+d;
		i++;
	}
	return (v, i);
}

iself(): int
{
	cpu := array[76] of string;
	cpu[1]="WE32100"; cpu[2]="SPARC"; cpu[3]="i386"; cpu[4]="M68000";
	cpu[5]="M88000"; cpu[6]="i486"; cpu[7]="i860"; cpu[8]="R3000";
	cpu[9]="S370"; cpu[10]="R4000"; cpu[15]="HP-PA"; cpu[18]="sparc v8+";
	cpu[19]="i960"; cpu[20]="PPC-32"; cpu[21]="PPC-64"; cpu[40]="ARM";
	cpu[41]="Alpha"; cpu[43]="sparc v9"; cpu[50]="IA-64"; cpu[62]="AMD64";
	cpu[75]="VAX";
	etype := array[5] of string;
	etype[1]="relocatable object"; etype[2]="executable";
	etype[3]="shared library"; etype[4]="core dump";

	if(!matchat(buf, 0, bb(array[] of {16r7f,'E','L','F'})))
		return 0;
	if(!mime){
		isdifend := 0;
		n := (int buf[19]<<8) | int buf[18];
		p := "unknown";
		t := "unknown";
		if(n > 0 && n < len cpu && cpu[n] != nil)
			p = cpu[n];
		else {
			isdifend = 1;
			n = (int buf[18]<<8) | int buf[19];
			if(n > 0 && n < len cpu && cpu[n] != nil)
				p = cpu[n];
		}
		if(isdifend)
			n = (int buf[16]<<8) | int buf[17];
		else
			n = (int buf[17]<<8) | int buf[16];
		if(n > 0 && n < len etype && etype[n] != nil)
			t = etype[n];
		emit(sys->sprint("%s ELF %s\n", p, t));
	} else
		emit("application/x-elf-executable\n");
	return 1;
}

# lastslash: fname's rightmost '/', or -1 - the C's own `slash` global,
# a raw pointer or nil; kept as an index here since Limbo strings don't
# support C's "pointer into this same string, or nil" idiom directly.
lastslash(s: string): int
{
	i := -1;
	for(k := 0; k < len s; k++)
		if(s[k] == '/')
			i = k;
	return i;
}

runeswidth(s: string): int
{
	return len s;	# Limbo strings are already rune-indexed 
}

# type: open one named file and classify it, with the CLI's own padded
# "name:   " prefix (nlen is the widest argument name's rune width, for
# column alignment across multiple file arguments - matches the C).
typeone(file: string, nlen: int)
{
	if(nlen > 0){
		slash = lastslash(file);
		i := runeswidth(file);
		pad := nlen-i+1;
		if(pad < 0) pad = 0;
		emit(file+":"+padding(pad));
	}
	fname = file;
	f := sys->open(file, Sys->OREAD);
	if(f == nil){
		sys->fprint(stderr, "cannot open: %r\n");
		return;
	}
	filetype(f);
}

padding(n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s += " ";
	return s;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	resetstate();

	args := tl argv;
	files: list of string = nil;
	tail := args;
	while(tail != nil){
		w := hd tail;
		if(len w >= 2 && w[0]=='-' && w[1]=='m')
			mime = 1;
		else if(len w >= 1 && w[0] == '-'){
			sys->fprint(stderr, "usage: file [-m] [file...]\n");
			raise "fail:usage";
		} else
			files = w :: files;
		tail = tl tail;
	}
	# files was consed in reverse - restore argv order
	rev: list of string = nil;
	for(l1 := files; l1 != nil; l1 = tl l1)
		rev = hd l1 :: rev;
	files = rev;

	maxlen := 0;
	if(mime == 0 || len files > 1)
		for(l2 := files; l2 != nil; l2 = tl l2)
			if(runeswidth(hd l2) > maxlen)
				maxlen = runeswidth(hd l2);

	if(files == nil){
		if(!mime)
			sys->print("stdin: ");
		filetype(sys->fildes(0));
	} else
		for(l3 := files; l3 != nil; l3 = tl l3)
			typeone(hd l3, maxlen);
}

run(mimeflag: int, path: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	resetstate();
	mime = mimeflag;
	fname = path;
	slash = lastslash(path);

	f := sys->open(path, Sys->OREAD);
	if(f == nil)
		fail("run: cannot open " + path);

	outbuf = "";
	capturing = 1;
	filetype(f);
	capturing = 0;
	return outbuf;
}
