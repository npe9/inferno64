implement Urlencode;

# A structural Limbo translation of Plan 9's real urlencode(1) -
# sys/src/cmd/urlencode.c in the 9front tree, 103 lines. One of the
# "residual" real Plan 9 commands flagged in doc/plan9-port.md's item
# 21 - real, self-contained, zero-subsystem-dependency, no existing
# equivalent or name collision anywhere in this tree.
#
# No plan9port copy of this file exists (checked, not assumed - only
# 9front carries it), and no prebuilt binary for it exists on this
# host either, unlike every other file in this backlog with a live
# oracle. Rather than translate unverified (the hoc.b/split.c
# allowance, used only when no reference at all is available), this
# file's own real oracle was BUILT from the actual 9front source:
# `9c`/`9l` (plan9port's own compiler/linker wrappers, `-arch x86_64`
# to match this plan9port checkout's prebuilt libc/libbio, which are
# themselves x86_64-only) compile urlencode.c directly against
# plan9port's real `libc`/`bio`, producing a genuine working binary of
# the actual translated source - not a stand-in, not a different
# implementation. urlencodetest.b drives that binary through the same
# #C mechanism as every other oracle in this backlog. This is a new
# precedent for this backlog, worth remembering: a file with no
# prebuilt binary anywhere is not automatically "unverifiable" if the
# host has a C toolchain that can build the ACTUAL source directly.
#
# Uses `array of byte` throughout, not `string`, for both input and
# output - the same file.b/iconv.b precedent: this is a byte-
# transparent filter (arbitrary binary input percent-encodes to pure
# ASCII, but DECODING can reconstruct any byte 0-255, including ones
# that are not valid standalone UTF-8), so a `string` round-trip could
# corrupt exactly the high-byte values this command exists to encode/
# decode faithfully. `getb`/`putb`/`ungetb` (bufio's own byte-level
# primitives), not `getc`/`putc` (which decode/encode UTF-8 runes).
#
# One real behavioral subtlety, preserved exactly rather than
# simplified: a decode failure on the SECOND hex digit of a `%XY`
# sequence (`x2 < 0`) ungets the SECOND digit character and emits BOTH
# the literal `%` AND the (valid) first digit character `c1` verbatim,
# then reprocesses the ungotten second character on the next loop
# iteration - `%3z` decodes to the two literal characters `%3`
# followed by whatever `z` decodes to on its own (nothing special,
# just itself, since `z` isn't `%` or `+`). A failure on the FIRST hex
# digit is simpler: only `%` itself is emitted literally, and the
# first-digit character is ungotten to be reprocessed on its own.
#
# A REAL TRANSLATION BUG, found by testing against the built oracle
# (not by re-reading): both encode()'s and decode()'s multi-byte
# emissions (`%` + two hex digits; `%` + one literal digit character)
# came out with the bytes in REVERSE order the first time this was
# written - "100% done!" encoded to "10052%+done!" instead of
# "100%25+done!". `out` here is a `list of byte` built by prepending
# (`out = byte c :: out`) and reversed once, in bulk, by bytesof() at
# the very end - a single prepend per loop iteration is therefore
# already in correct final order (the list's own reversal-by-
# prepending exactly cancels bytesof()'s own final reversal), but
# pushing SEVERAL bytes for one iteration needs them pushed in the
# SAME order they should finally appear in, not reversed - easy to get
# backwards by treating "prepend" as meaning "reverse my push order"
# when it doesn't, once a single final bulk reversal is already in the
# picture. Confirmed with a genuine negative control (reverting just
# encode()'s push order reproduced exactly the four encode-dependent
# test failures while every decode-only case kept passing, isolating
# the bug to that one block before restoring the fix).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Urlencode: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the flag+operand list (a bare
	# filename operand is NOT supported here, matching the scope of
	# what's actually tested - see urlencodetest.b's own man page
	# BUGS), input is the byte stream that would otherwise come from
	# stdin (or the named file).
	run:	fn(argv: list of string, input: array of byte): array of byte;
};

stderr: ref FD;

fail(msg: string)
{
	sys->fprint(stderr, "urlencode: %s\n", msg);
	raise "fail:urlencode";
}

usage()
{
	fail("usage: urlencode [ -d ] [ file ]");
}

hex := "0123456789abcdef";
Hex := "0123456789ABCDEF";

hexdigit(c: int): int
{
	for(i := 0; i < len Hex; i++)
		if(Hex[i] == c)
			return i;
	for(j := 0; j < len hex; j++)
		if(hex[j] == c)
			return j;
	return -1;
}

# issafe: the original's own `strchr("/$-_@.!*'(),", c)` set, plus
# alphanumerics - characters that pass through an ENCODE unchanged.
safeset := "/$-_@.!*'(),";

issafe(c: int): int
{
	if(c <= 0)
		return 0;
	for(i := 0; i < len safeset; i++)
		if(safeset[i] == c)
			return 1;
	if(c >= 'a' && c <= 'z')
		return 1;
	if(c >= 'A' && c <= 'Z')
		return 1;
	if(c >= '0' && c <= '9')
		return 1;
	return 0;
}

bytesof(l: list of byte): array of byte
{
	n := len l;
	a := array[n] of byte;
	i := n-1;
	for(; l != nil; l = tl l){
		a[i] = hd l;
		i--;
	}
	return a;
}

decode(bin: ref Iobuf): array of byte
{
	out: list of byte;
	for(;;){
		c := bin.getb();
		if(c < 0)
			break;
		if(c == '%'){
			c1 := bin.getb();
			if(c1 < 0)
				break;
			x1 := hexdigit(c1);
			if(x1 < 0){
				bin.ungetb();
				out = byte c :: out;
				continue;
			}
			c2 := bin.getb();
			if(c2 < 0)
				break;
			x2 := hexdigit(c2);
			if(x2 < 0){
				bin.ungetb();
				out = byte c :: out;
				out = byte c1 :: out;
				continue;
			}
			c = (x1<<4) | x2;
		} else if(c == '+')
			c = ' ';
		out = byte c :: out;
	}
	return bytesof(out);
}

encode(bin: ref Iobuf): array of byte
{
	out: list of byte;
	for(;;){
		c := bin.getb();
		if(c < 0)
			break;
		if(issafe(c))
			out = byte c :: out;
		else if(c == ' ')
			out = byte '+' :: out;
		else {
			out = byte '%' :: out;
			out = byte Hex[(c>>4)&16r0F] :: out;
			out = byte Hex[c&16r0F] :: out;
		}
	}
	return bytesof(out);
}

run(argv: list of string, input: array of byte): array of byte
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;

	dflag := 0;
	for(l := argv; l != nil; l = tl l){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			usage();
		if(w == "-d")
			dflag = 1;
		else
			usage();
	}

	bin := bufio->aopen(input);
	if(dflag)
		return decode(bin);
	return encode(bin);
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;

	dflag := 0;
	fname: string;
	for(l := tl argv; l != nil; l = tl l){
		w := hd l;
		if(w == "-d")
			dflag = 1;
		else if(len w > 0 && w[0] == '-')
			usage();
		else if(fname == nil)
			fname = w;
		else
			usage();
	}

	fd: ref FD;
	if(fname != nil){
		fd = sys->open(fname, Sys->OREAD);
		if(fd == nil){
			sys->fprint(stderr, "urlencode: %r\n");
			raise "fail:urlencode";
		}
	} else
		fd = sys->fildes(0);

	bin := bufio->fopen(fd, Bufio->OREAD);
	out: array of byte;
	if(dflag)
		out = decode(bin);
	else
		out = encode(bin);

	stdout := sys->fildes(1);
	sys->write(stdout, out, len out);
}
