implement Ascii;

# A structural Limbo translation of Plan 9's real ascii(1) -
# sys/src/cmd/ascii.c in the 9front tree, 181 lines. One of the
# "residual" real Plan 9 commands flagged in doc/plan9-port.md's item
# 21 - a real, self-contained, zero-subsystem-dependency candidate,
# checked (not assumed) to have no existing equivalent or name
# collision anywhere in this tree.
#
# Diffed against plan9port's own copy before translating (the usual
# first check for this backlog): identical except ONE table entry -
# 9front labels character 0x0c (form feed) "ff ", plan9port labels it
# "np " (new page) - a vocabulary choice, not a behavior difference
# either way. This translates 9front's own label, matching the
# repository's stated primary target; plan9port's real `ascii` binary
# (used as the live oracle here, since it IS installed on this host,
# unlike 9front's) will therefore print "np " on that one row where
# this port prints "ff " - a confirmed, understood, one-row divergence
# from the ORACLE, not from 9front's own source, which is what's
# actually being translated. asciitest.b's own oracle comparison skips
# exactly that one row rather than papering over it with a tolerance
# rule.
#
# Two real, deliberately-preserved quirks, confirmed against the
# oracle rather than assumed from reading the C:
#   - `ascii -8n` (no-text-conversion, all 256 chars) prints two-digit
#     hex/octal/decimal codes for EVERY character 0-255 with NO
#     separator between entries other than the fixed column width -
#     this is putn()'s own recursive digit-printer, `ncol` wide,
#     zero-padded; translated as printn() below with the exact same
#     recursion-then-print-least-significant-digit-last shape (Limbo
#     has no pre-decrement to mirror C's own recursive call ordering
#     with, but the recursion itself does the same job).
#   - `ascii text` on a plain non-numeric argument treats each BYTE of
#     the argument as a thing to print with putnum() (the "numeric"
#     path is default OFF unless isnum() finds every character of the
#     first argument is a valid digit in the current base) - `ascii
#     hello` prints one numeric code per letter of "hello", not an
#     error; `ascii -c 68` (forcing text=2, i.e. "treat argument as a
#     numeric CODE, print its name") prints the name for code 68
#     decimal in the CURRENT input base (16 by default, so "68" is
#     read as hex 0x68 = 104 = 'h').
#
# ARGBEGIN's own bundled-flag convention (`-8x` is the same as `-8 -x`)
# is preserved - confirmed directly against the real binary before
# writing this loop, not assumed from the C's own ARGBEGIN macro
# expansion. `-b` is the one flag taking a value (EARGF's own
# attached-suffix-or-next-word convention, same idiom as crc32.b's/
# join.b's own getoptarg(), inlined here per-character since `-b`
# can appear bundled after other boolean flags too, e.g. `-nb16`).
#
# Two real translation bugs, both caught by advisor review before this
# file's first commit (every test case at that point stayed under
# code 128, so neither one showed up in the suite until t7/t8 below
# were added specifically to catch them):
#   - puttext()'s -t/strip path used to do
#     `emit(sys->sprint("%c", n))`, which for n>127 emits the UTF-8
#     ENCODING of rune n (2 bytes), not the one raw byte n the
#     original's own Bputc(&bin, n) writes. Fixed by emitbyte(), which
#     writes the byte directly. Confirmed against the oracle:
#     `ascii -t ff` must print one raw 0xff byte, not 0xc3 0xbf.
#   - putnum() used to index its argument by RUNE (`s[i]`), not by
#     byte - a multi-byte UTF-8 argument produced one code per rune
#     instead of one per byte, the same rune/byte confusion
#     urlencode.b's own header comment warns about. Fixed by
#     `array of byte s`, which re-encodes the string back to the exact
#     bytes argv originally carried, and iterating that. Confirmed
#     against the oracle: `ascii -8n 'é'` must print two codes
#     (c3 a9), not one (e9).
# Once both were fixed, capturing needed a real output-accumulation
# rewrite from `string outbuf` to `list of byte outbuf` (see emit()/
# emitbyte() below) - and that rewrite introduced, then caught via its
# own negative control, a THIRD bug: emit() reversed bytes within each
# call before pushing, which double-reverses against run()'s own bulk
# reversal at the end (every table label came out spelled backwards,
# "nul" as "lun", until the fix - push in forward order per call, same
# rule urlencode.b's encode()/decode() bug established).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Ascii: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the flag+operand list exactly as
	# init() would see it (minus argv[0]). Returns captured stdout as
	# raw bytes (see the header comment's note on -t/putnum needing
	# byte-, not rune-, level output). A usage error raises
	# "fail:ascii" the same way the original's own usage()/exits
	# ("usage") would abort the process.
	run:	fn(argv: list of string): array of byte;
};

stderr, fdout: ref FD;
capturing: int;
outbuf: list of byte;

# emit/emitbyte both push onto outbuf (list prepend, so it accumulates
# in reverse of push order); run() does one bulk reversal at the very
# end to read it back out in the right order. Pushing WITHIN one
# emit(s) call must stay in forward order for this to work - the same
# byte-order lesson urlencode.b's encode()/decode() bug taught: with a
# single final bulk reversal already in play, an EXTRA per-call
# reversal double-reverses and comes out backwards (caught here by
# t1defaultdump before commit: every table label came out spelled
# backwards, "nul" as "lun").
emit(s: string)
{
	b := array of byte s;
	if(capturing){
		for(i := 0; i < len b; i++)
			outbuf = b[i] :: outbuf;
	} else
		sys->write(fdout, b, len b);
}

# emitbyte(n): write exactly the raw byte n (0-255), not the UTF-8
# encoding of rune n - what ascii.c's own Bputc(&bin, n) does, and what
# sys->sprint("%c", n) does NOT do once n exceeds 127 (it would emit
# the 2-byte UTF-8 encoding of that rune instead of one raw byte).
# Needed by puttext()'s -t/strip path; confirmed against the real
# oracle (`ascii -t ff` prints one raw 0xff byte, not 0xc3 0xbf).
emitbyte(n: int)
{
	if(capturing)
		outbuf = byte n :: outbuf;
	else
		sys->write(fdout, array[1] of {byte n}, 1);
}

fail(msg: string)
{
	sys->fprint(stderr, "ascii: %s\n", msg);
	raise "fail:ascii";
}

usage()
{
	fail("usage: ascii [-8cnt] [-dox | -b n] [text]");
}

MAXBASE: con 36;

# str[256]: verbatim from 9front's sys/src/cmd/ascii.c (see header
# comment for the one plan9port label difference, "ff " vs "np ").
str := array[] of {
	"nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel",
	"bs ", "ht ", "nl ", "vt ", "ff ", "cr ", "so ", "si ",
	"dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb",
	"can", "em ", "sub", "esc", "fs ", "gs ", "rs ", "us ",
	"sp ", " ! ", " \" ", " # ", " $ ", " % ", " & ", " ' ",
	" ( ", " ) ", " * ", " + ", " , ", " - ", " . ", " / ",
	" 0 ", " 1 ", " 2 ", " 3 ", " 4 ", " 5 ", " 6 ", " 7 ",
	" 8 ", " 9 ", " : ", " ; ", " < ", " = ", " > ", " ? ",
	" @ ", " A ", " B ", " C ", " D ", " E ", " F ", " G ",
	" H ", " I ", " J ", " K ", " L ", " M ", " N ", " O ",
	" P ", " Q ", " R ", " S ", " T ", " U ", " V ", " W ",
	" X ", " Y ", " Z ", " [ ", " \\ ", " ] ", " ^ ", " _ ",
	" ` ", " a ", " b ", " c ", " d ", " e ", " f ", " g ",
	" h ", " i ", " j ", " k ", " l ", " m ", " n ", " o ",
	" p ", " q ", " r ", " s ", " t ", " u ", " v ", " w ",
	" x ", " y ", " z ", " { ", " | ", " } ", " ~ ", "del",
	"x80", "x81", "x82", "x83", "x84", "x85", "x86", "x87",
	"x88", "x89", "x8a", "x8b", "x8c", "x8d", "x8e", "x8f",
	"x90", "x91", "x92", "x93", "x94", "x95", "x96", "x97",
	"x98", "x99", "x9a", "x9b", "x9c", "x9d", "x9e", "x9f",
	"xa0", " ¡ ", " ¢ ", " £ ", " ¤ ", " ¥ ", " ¦ ", " § ",
	" ¨ ", " © ", " ª ", " « ", " ¬ ", " ­ ", " ® ", " ¯ ",
	" ° ", " ± ", " ² ", " ³ ", " ´ ", " µ ", " ¶ ", " · ",
	" ¸ ", " ¹ ", " º ", " » ", " ¼ ", " ½ ", " ¾ ", " ¿ ",
	" À ", " Á ", " Â ", " Ã ", " Ä ", " Å ", " Æ ", " Ç ",
	" È ", " É ", " Ê ", " Ë ", " Ì ", " Í ", " Î ", " Ï ",
	" Ð ", " Ñ ", " Ò ", " Ó ", " Ô ", " Õ ", " Ö ", " × ",
	" Ø ", " Ù ", " Ú ", " Û ", " Ü ", " Ý ", " Þ ", " ß ",
	" à ", " á ", " â ", " ã ", " ä ", " å ", " æ ", " ç ",
	" è ", " é ", " ê ", " ë ", " ì ", " í ", " î ", " ï ",
	" ð ", " ñ ", " ò ", " ó ", " ô ", " õ ", " ö ", " ÷ ",
	" ø ", " ù ", " ú ", " û ", " ü ", " ý ", " þ ", " ÿ ",
};

# Ncol[base]: number of digits printed for that base - verbatim from
# the source (index 0/1 unused, since base 0/1 are never selected;
# index 2..36 give ceil(log_base(256))).
ncoltab := array[] of {
	0, 0, 7, 5, 4, 4, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};

dig := "0123456789abcdefghijklmnopqrstuvwxyz";

nchars, base, ncol, text, strip: int;

resetstate()
{
	nchars = 128;
	base = 16;
	ncol = ncoltab[base];
	text = 1;
	strip = 0;
}

parseint(s: string): int
{
	n := 0;
	i := 0;
	if(i >= len s)
		usage();
	for(; i < len s; i++){
		c := s[i];
		if(c < '0' || c > '9')
			usage();
		n = n*10 + (c - '0');
	}
	return n;
}

parseopts(args: list of string): list of string
{
	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		l = tl l;
		i := 1;
		while(i < len w){
			c := w[i];
			i++;
			case c {
			'8' =>
				nchars = 256;
			'x' =>
				base = 16;
			'o' =>
				base = 8;
			'd' =>
				base = 10;
			'b' =>
				v: string;
				if(i < len w){
					v = w[i:];
					i = len w;
				} else if(l != nil){
					v = hd l;
					l = tl l;
				} else {
					usage();
					v = "";	# unreached; usage() raises
				}
				base = parseint(v);
				if(base < 2 || base > MAXBASE)
					usage();
			'n' =>
				text = 0;
			't' =>
				strip = 1;
				text = 2;
			'c' =>
				text = 2;
			* =>
				usage();
			}
		}
	}
	return l;
}

# value(c, f): the digit value of c in the current base, or -1 if f is
# set and c isn't a valid digit; if f is NOT set, an invalid digit is
# a hard usage-style error (matching the original's own fprint+exits),
# not a -1 return the caller would otherwise have to check for.
value(c: int, f: int): int
{
	for(i := 0; i < base; i++)
		if(dig[i] == c)
			return i;
	if(f)
		return -1;
	fail(sys->sprint("bad input char %c", c));
	return 0;	# unreached
}

isnum(s: string): int
{
	for(i := 0; i < len s; i++)
		if(value(s[i], 1) == -1)
			return 0;
	return 1;
}

btoi(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++)
		n = n*base + value(s[i], 0);
	return n;
}

# printn(n, ndig): recursive least-significant-digit-last printer,
# zero-padded to ndig digits - matches the original's own putn()
# exactly (recurse on n/base first, THEN print n%base - the recursion
# is what makes the most significant digit come out first).
printn(n: int, ndig: int)
{
	if(ndig == 0)
		return;
	printn(n/base, ndig-1);
	emit(sys->sprint("%c", dig[n%base]));
}

put(i: int)
{
	emit("|");
	printn(i, ncol);
	emit(sys->sprint(" %s", str[i]));
}

puttext(s: string)
{
	n := btoi(s) & 16rFF;
	if(strip)
		emitbyte(n);
	else
		emit(str[n]+"\n");
}

# putnum(s): print one numeric code per BYTE of s, matching the
# original's own `*s++&0377` - byte-, not rune-, wise. s came from
# argv, which Limbo has already UTF-8-decoded into runes; `array of
# byte s` re-encodes back to the exact original bytes (e.g. argument
# "e"+combining-acute or a 2-byte UTF-8 "e" both round-trip to their
# real input bytes this way), matching what the C, which never
# re-encodes anything, sees directly. Confirmed against the oracle:
# `ascii -8n 'e-with-acute'` prints two codes (c3 a9), not one.
putnum(s: string)
{
	b := array of byte s;
	for(i := 0; i < len b; i++){
		printn(int b[i], ncol);
		emit("\n");
	}
}

dowork(argv: list of string)
{
	resetstate();
	rest := parseopts(argv);
	ncol = ncoltab[base];

	if(rest == nil){
		for(i := 0; i < nchars; i++){
			put(i);
			if((i&7) == 7)
				emit("|\n");
		}
	} else {
		t := text;
		if(t == 1)
			t = isnum(hd rest);
		for(l := rest; l != nil; l = tl l)
			if(t)
				puttext(hd l);
			else
				putnum(hd l);
	}
	emit("\n");
}

run(argv: list of string): array of byte
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	outbuf = nil;
	capturing = 1;
	dowork(argv);
	capturing = 0;

	n := len outbuf;
	r := array[n] of byte;
	i := n;
	for(l := outbuf; l != nil; l = tl l)
		r[--i] = hd l;
	return r;
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	fdout = sys->fildes(1);
	capturing = 0;
	if(argv != nil)
		argv = tl argv;	# drop argv[0]
	dowork(argv);
}
