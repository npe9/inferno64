implement Split;

# A structural Limbo translation of Plan 9's split(1) - 195 lines. Two
# real Plan 9 lineages diverge on this specific file (checked by
# diffing them directly, not assumed): 9front's sys/src/cmd/split.c
# primes its pattern-mode (-e) output with an extra, unconditional
# matchfile() call before reading any input, which plan9port's copy of
# the same file lacks entirely. Tried to confirm 9front's own resulting
# behaviour against a live binary (patched only the Resub field-naming
# difference and recompiled 9front's actual source against plan9port's
# headers) but linking failed - this machine's plan9port libraries are
# x86_64-only, an environment limit, not a source problem. Per an
# explicit go-ahead to use plan9port as the reference where 9front has
# a divergence that can't be verified directly, this translation is of
# plan9port's copy of split.c instead, which was fully verified against
# its own real binary (plan9port's local `split`, this tree's own
# oracle elsewhere in this session too) - not a guess either way.
#
# Consequence worth stating plainly: without that priming call, a line
# read in -e mode BEFORE the first pattern match is silently dropped -
# no output file is open yet to receive it, and nothing reports this.
# Confirmed directly against the real plan9port binary (a line before
# the first match appears in no output file at all), not assumed from
# reading the source. Reproduced here the same way plan9port's own C
# does: writes are simply skipped whenever no output file has been
# opened yet, rather than needing to model *why* an uninitialised
# static Biobuf in C doesn't produce a written line either.
#
# Other translation notes:
#   - `Resub`'s submatch array is Limbo's `Regex` module's own
#     `array of (int,int)` from execute()/executese() (module/regex.m)
#     - already an existing Inferno regex engine, not something built
#     for this translation. Index 0 is the whole match, index 1 is the
#     first parenthesized group - the same convention as Resub[0]/[1],
#     confirmed against this tree's own sed.b/grep.b usage. compile()'s
#     second argument is 1 (enable submatch/group tracking), matching
#     sed.b's own usage for the same reason (it needs \1 backreferences,
#     split needs group 1's captured text) - grep.b passes 0, since it
#     has no groups to track.
#   - Plan 9 C strings are byte arrays; `fold()`'s case-insensitive
#     lowering and the regex match positions it feeds are worked out by
#     hand with realloc'd static buffers there. Limbo strings are
#     already Unicode-aware and dynamically sized, so fold() here is a
#     plain per-rune lowering loop with no buffer-reuse machinery to
#     replicate - not a behaviour difference, just less code needed for
#     the same result. Positions returned by matching against a folded
#     string still index correctly into the *original* line (ASCII case
#     folding never changes length), matching the C's own reuse of
#     match[1] positions - computed against the folded text - to slice
#     the ORIGINAL match[1] range for a filename: `-i` really does
#     affect the resulting captured filename's case, not just matching.
#   - `openf()`'s error message says "grep", not "split" - a real,
#     preserved copy-paste typo in the original, not fixed here.
#   - The C's separate "tack whatever's left onto the last file" salvo
#     loop (for a final line with no trailing newline) has no equivalent
#     need here: `bufio`'s `Iobuf.gets()` already returns a final
#     partial line (without a terminator) at real EOF, which the same
#     write path already handles - nothing extra required.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "regex.m";
	regex: Regex;
	Re: import regex;

Split: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: run() is exactly init()'s post-argv0
	# argument-handling body. split's whole job is creating real output
	# files, so the test drives it with a real input file path as the
	# trailing operand (same "real files throughout" shape as join.b's
	# runfiles, for the same reason - there is no meaningful string-only
	# stand-in for "creates N files with these names and contents").
	run:	fn(args: list of string): int;
};

stdin, stderr: ref FD;

stem := "x";
suffix := "";
suffa := 'a';
suffb := 'a';
outfd: ref FD;
canopen := 1;

fail(msg: string)
{
	sys->fprint(stderr, "split: %s\n", msg);
	raise "fail:split";
}

usage()
{
	fail("usage: split [-n num] [-e exp] [-f stem] [-s suff] [-x] [-i] [file]");
}

badexp()
{
	fail("bad regular expression");
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

catoi(s: string): int
{
	v := 0;
	i := 0;
	n := len s;
	neg := 0;
	if(i < n && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	while(i < n && isdigit(s[i])){
		v = v*10 + (s[i] - '0');
		i++;
	}
	if(neg)
		v = -v;
	return v;
}

getoptarg(w: string, rest: list of string): (string, list of string)
{
	if(len w > 2)
		return (w[2:], rest);
	if(rest == nil)
		usage();
	return (hd rest, tl rest);
}

resetstate()
{
	stem = "x";
	suffix = "";
	suffa = 'a';
	suffb = 'a';
	outfd = nil;
	canopen = 1;
}

openf(name: string)
{
	fd := sys->create(name, Sys->OWRITE, 8r666);
	if(fd == nil){
		# "grep", not "split" - see header comment.
		sys->fprint(stderr, "grep: can't create %s: %r\n", name);
		raise "fail:create";
	}
	outfd = fd;
}

nextfile(): int
{
	if(suffa > 'z'){
		if(canopen)
			sys->fprint(stderr, "split: file %szz not split\n", stem);
		canopen = 0;
	} else {
		name := stem + sys->sprint("%c%c", suffa, suffb);
		suffb++;
		if(suffb > 'z'){
			suffb = 'a';
			suffa++;
		}
		openf(name);
	}
	return canopen;
}

matchfile(havecap: int, capstart: int, capend: int, matchtext: string): int
{
	if(havecap){
		name := matchtext[capstart:capend] + suffix;
		openf(name);
		return 1;
	}
	return nextfile();
}

fold(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		out[len out] = c;
	}
	return out;
}

writeline(line: string)
{
	# silently dropped if no output file is open yet - see header
	# comment (plan9port's own confirmed behaviour in -e mode).
	if(outfd != nil){
		buf := array of byte line;
		sys->write(outfd, buf, len buf);
	}
}

run(args: list of string): int
{
	# defensive loads: run() is also the test seam's entry point,
	# called without going through init() first (same convention as
	# join.b's runfiles()/crc32.b's runstring()).
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(stdin == nil)
		stdin = sys->fildes(0);
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(regex == nil)
		regex = load Regex Regex->PATH;
	if(bufio == nil || regex == nil)
		fail("cannot load a required module");

	resetstate();
	n := 1000;
	pattern := "";
	havepattern := 0;
	xflag := 0;
	iflag := 0;

	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		case w[1] {
		'l' or 'n' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			n = catoi(v);
		'e' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			pattern = v;
			havepattern = 1;
		'f' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			stem = v;
		's' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			suffix = v;
		'x' =>
			l = tl l;
			xflag = 1;
		'i' =>
			l = tl l;
			iflag = 1;
		* =>
			usage();
		}
	}

	nfiles := 0;
	for(x := l; x != nil; x = tl x)
		nfiles++;
	if(nfiles > 1)
		usage();

	iob: ref Iobuf;
	if(nfiles == 1){
		iob = bufio->open(hd l, Bufio->OREAD);
		if(iob == nil)
			fail("can't open " + hd l);
	} else
		iob = bufio->fopen(stdin, Bufio->OREAD);

	if(havepattern){
		patsrc := pattern;
		if(iflag)
			patsrc = fold(pattern);
		(re, err) := regex->compile(patsrc, 1);
		if(re == nil)
			badexp();
		for(;;){
			line := iob.gets('\n');
			if(line == nil)
				break;
			if(len line > 0 && line[len line - 1] == '\n')
				line = line[0:len line - 1];
			matchtext := line;
			if(iflag)
				matchtext = fold(line);
			m := regex->executese(re, matchtext, (0, len matchtext), 1, 1);
			skip := 0;
			if(m != nil){
				havecap := 0;
				capstart := 0;
				capend := 0;
				if(len m > 1){
					(cs, ce) := m[1];
					if(cs >= 0){
						havecap = 1;
						capstart = cs;
						capend = ce;
					}
				}
				newfile := matchfile(havecap, capstart, capend, matchtext);
				if(newfile != 0 && xflag)
					skip = 1;
			}
			if(!skip)
				writeline(line + "\n");
		}
	} else {
		linecnt := n;
		for(;;){
			line := iob.gets('\n');
			if(line == nil)
				break;
			linecnt++;
			if(linecnt > n){
				nextfile();
				linecnt = 1;
			}
			writeline(line);
		}
	}
	return 0;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	regex = load Regex Regex->PATH;
	if(bufio == nil || regex == nil){
		sys->fprint(stderr, "split: cannot load a required module\n");
		raise "fail:module";
	}
	run(tl argv);
}
