implement Crc32;

# A structural Limbo translation of Plan 9's real crc32(1) -
# sys/src/cmd/crc32.c in the 9front tree, 99 lines. Every deviation from
# the C source is listed here.
#
#   - The C's u32int (32-bit unsigned) arithmetic, including a right
#     shift that must be logical (zero-fill), not arithmetic - is
#     translated as Limbo `big`, not `int`. Limbo's own right-shift on
#     `int` sign-extends (doc/limbo/limbo.ms: "fill bits are a copy of
#     the sign for the int case"), which would corrupt this algorithm
#     the moment the top bit of a CRC value is set; Limbo has no logical-
#     shift operator for a signed type to fall back on either. Kept as a
#     `big` masked to 32 bits (`mask32`) after every operation that could
#     exceed it, every value here is always non-negative (fits in 32 of
#     `big`'s 64 bits) - and shifting a non-negative value right, in any
#     two's-complement representation, never needs to fill with 1s in
#     the first place, so `big`'s arithmetic ">>" is exactly the logical
#     shift this algorithm needs, with no separate operator required.
#   - `ARGBEGIN`/`EARGF` (Plan 9 libc's own option-parsing macros, not
#     getopt) use the same attached-suffix-or-next-word convention as
#     join.b's getoptarg() - ported as the same style of helper here,
#     since it's the same convention, not coincidentally similar code.
#   - `strtol(s, 0, 0)` (base-0: auto-detects "0x"/"0X" as hex, a
#     leading "0" as octal, otherwise decimal) is translated as
#     parsenum() below, matching that auto-detection for the realistic
#     option-argument values this program deals with (CRC constants are
#     conventionally written in hex). This is not a bug-for-bug port of
#     strtol's own edge cases (leading whitespace, overflow, an explicit
#     sign) - unlike join.b's atoi() leniency, there is no known real
#     divergence in ordinary use worth preserving here.
#   - `exits(error)`: a failure opening or reading any one file does not
#     stop the others from being processed - the C defers the failure
#     signal to the very end, after all files (successful or not) have
#     already been handled - the same "process everything, report at the
#     end" shape as join.b's `discard` bookkeeping. Translated as raising
#     the failure only after every file has been attempted, not as soon
#     as the first one fails.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Crc32: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: args is the flag list only, input is what
	# would otherwise be read from standard input (the argc==0 path -
	# the only path exercised without real files; see BUGS in
	# crc32test's man page for what this doesn't cover).
	runstring:	fn(args: list of string, input: string): string;
};

stdin, stderr: ref FD;
capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

fail(msg: string)
{
	sys->fprint(stderr, "crc32: %s\n", msg);
	raise "fail:crc32";
}

mask32: con big 16rFFFFFFFF;

table:	array of big;
xorval:	big;
initval: big;
poly:	big;

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

ishex(c: int): int
{
	return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

hexval(c: int): int
{
	if(isdigit(c))
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

# strtol(s, 0, 0)'s base-0 auto-detection: "0x"/"0X" -> hex, a leading
# "0" (with more digits) -> octal, otherwise decimal. See header comment.
parsenum(s: string): big
{
	n := len s;
	i := 0;
	if(i < n && (s[i] == '+' || s[i] == '-'))
		i++;	# a leading sign is harmless to skip; these are CRC
			# constants, never meaningfully negative in practice
	base := 10;
	if(i+1 < n && s[i] == '0' && (s[i+1] == 'x' || s[i+1] == 'X')){
		base = 16;
		i += 2;
	} else if(i < n && s[i] == '0' && i+1 < n)
		base = 8;
	v := big 0;
	while(i < n){
		c := s[i];
		if(base == 16){
			if(!ishex(c))
				break;
			v = v*big 16 + big hexval(c);
		} else if(base == 8){
			if(!isdigit(c) || c > '7')
				break;
			v = v*big 8 + big (c - '0');
		} else {
			if(!isdigit(c))
				break;
			v = v*big 10 + big (c - '0');
		}
		i++;
	}
	return v & mask32;
}

# getoptarg: the same attached-suffix-or-next-word convention as
# join.b's helper of the same name (EARGF's own convention, not
# getopt(3)'s) - see header comment.
getoptarg(w: string, rest: list of string): (string, list of string)
{
	if(len w > 2)
		return (w[2:], rest);
	if(rest == nil)
		usage();
	return (hd rest, tl rest);
}

usage()
{
	fail("usage: crc32 [-x xorval] [-i initial] [-p poly] [file...]");
}

dotable()
{
	table = array[256] of big;
	for(n := 0; n < 256; n++){
		c := big n;
		for(k := 0; k < 8; k++){
			if((c & big 1) != big 0)
				c = (poly ^ (c >> 1)) & mask32;
			else
				c = c >> 1;
		}
		table[n] = c;
	}
}

calc(init: big, buf: array of byte, n: int): big
{
	c := init;
	for(i := 0; i < n; i++){
		idx := int((big buf[i] ^ c) & big 16rff);
		c = (table[idx] ^ (c >> 8)) & mask32;
	}
	return c;
}

# sum() reads a whole file (or, via the test seam, a string standing in
# for standard input) and prints its CRC - "%ux\n" alone for standard
# input, "%ux\tname\n" for a named file, matching the C's two print
# forms. Returns 1 on a read error (sets errmsg via the caller), 0 on
# success - the C's own `error = "read"` bookkeeping.
sumfd(fd: ref FD, name: string): int
{
	crc := (initval ^ xorval) & mask32;
	buf := array[8192] of byte;
	for(;;){
		nr := sys->read(fd, buf, len buf);
		if(nr < 0)
			return 1;
		if(nr == 0)
			break;
		crc = calc(crc, buf[0:nr], nr);
	}
	crc = (crc ^ xorval) & mask32;
	if(name == nil)
		emit(sys->sprint("%ux\n", int crc));
	else
		emit(sys->sprint("%ux\t%s\n", int crc, name));
	return 0;
}

sumstring(s: string, name: string): int
{
	crc := (initval ^ xorval) & mask32;
	buf := array of byte s;
	if(len buf > 0)
		crc = calc(crc, buf, len buf);
	crc = (crc ^ xorval) & mask32;
	if(name == nil)
		emit(sys->sprint("%ux\n", int crc));
	else
		emit(sys->sprint("%ux\t%s\n", int crc, name));
	return 0;
}

resetstate()
{
	xorval = mask32;	# C's `xor = -1` - all 32 bits set
	initval = big 0;
	poly = big 16redb88320;
}

# parseopts: -x/-i/-p, each via getoptarg (attached or next word); any
# other option is a usage error - unlike join.b, the C here DOES error
# on an unrecognised option (a real difference in convention between
# the two originals, not something to unify).
parseopts(args: list of string): list of string
{
	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		case w[1] {
		'x' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			xorval = parsenum(v);
		'i' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			initval = parsenum(v);
		'p' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			poly = parsenum(v);
		* =>
			usage();
		}
	}
	return l;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);

	resetstate();
	files := parseopts(tl argv);
	dotable();

	errmsg := "";
	if(files == nil){
		if(sumfd(stdin, nil) != 0){
			sys->fprint(stderr, "reading stdin: %r\n");
			errmsg = "read";
		}
	} else {
		for(l := files; l != nil; l = tl l){
			name := hd l;
			fd := sys->open(name, Sys->OREAD);
			if(fd == nil){
				sys->fprint(stderr, "crc32: can't open %s: %r\n", name);
				errmsg = "open";
				continue;
			}
			if(sumfd(fd, name) != 0){
				sys->fprint(stderr, "reading %s: %r\n", name);
				errmsg = "read";
			}
		}
	}
	if(errmsg != "")
		fail(errmsg);
}

runstring(args: list of string, input: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	resetstate();
	parseopts(args);	# args carries flags only, no file operands
	dotable();

	outbuf = "";
	capturing = 1;
	sumstring(input, nil);
	capturing = 0;
	return outbuf;
}
