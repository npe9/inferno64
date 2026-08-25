implement Join;

# A structural Limbo translation of Plan 9's real join(1) -
# sys/src/cmd/join.c in the 9front tree, 368 lines - replacing an
# earlier version of this file that was a *workalike* reverse-engineered
# against macOS/BSD join(1), the wrong oracle (see doc/plan9-port.md's
# CORRECTION section). Every deviation from the C source is listed here;
# where the C is buggy or invokes undefined behaviour, that is preserved
# or explicitly called out below, not silently "fixed".
#
# The single biggest structural fact about this file: Plan 9's join does
# NOT load both inputs into memory and merge two arrays (which is what
# the old workalike did, and what a POSIX join implementation typically
# does). It drives the match loop off ONE file (whichever is seekable -
# checked with a real seek probe, matching the C's ftell()>=0 test) and
# handles a run of duplicate keys on the OTHER file by *rewinding* it
# with a real seek back to a bookmarked byte offset and re-reading the
# run for each new record on the driving side - seek1()/seek2() below,
# mirror images of each other exactly as in the source. This is not
# equivalent to a buffered merge in the general case: `join - -` (both
# inputs from standard input, neither seekable) is a hard, documented
# *error* in the real join ("neither file is randomly accessible"), not
# something a buffered version would even notice. Translating the seek
# algorithm as written was necessary to preserve that, not optional.
#
# Because the algorithm is seek-based, the in-process test seam here
# (runfiles below) takes two real file paths, not two strings the way
# every other p9/cmd tool's runstring(text) seam does - there is nothing
# to seek in an in-memory string, and bending the algorithm to fit a
# string-only seam would be exactly the "substitute an equivalent
# algorithm" mistake this rewrite exists to avoid.
#
# Translation idioms:
#   - The C represents each line's fields as a fixed array of Rune*
#     pointers into a per-file static line buffer (ppi[2][NFLD+1]),
#     manually walking UTF-32 runes with chartorune/runetochar because
#     C strings are just byte arrays. Limbo strings are already rune-
#     indexed sequences of Unicode code points - the same abstraction
#     Plan 9's Rune exists to bolt onto C - so field splitting and the
#     key comparison (comp(), C's runecmp()) below are direct rune-for-
#     rune translations with no chartorune/runetochar step needed at
#     all: Limbo is a *closer* match to what this C is doing than C's
#     own manual Rune juggling is.
#   - atoi() in C never errors on bad input - it parses leading digits
#     (with an optional sign) and silently stops at the first non-digit,
#     returning 0 if there were none. Every integer option argument here
#     (-1/-2/-j's field numbers, -o's comma-list field numbers) goes
#     through catoi() below, which replicates that exact leniency - not
#     the strict, fail()-on-garbage atoi() an earlier draft of this file
#     (and the old workalike) used elsewhere in this tree. Garbage in
#     gives silent nonsense out here, matching the real join, not an error.
#   - getoptarg()'s "attached-suffix-or-next-word" convention (-a1 and
#     -a 1 both work; the next word is rejected if it starts with '-')
#     is not getopt(3)'s convention and is translated directly as
#     getoptarg() below, consuming one argv word for the attached form
#     and two for the separate form - checked to match word-for-word,
#     since -j deliberately does NOT use this convention (its value is
#     always a separate following word; only the 1-vs-2 discriminator
#     can be attached, as -j1/-j2/-j).
#   - Unrecognised single-dash options are silently ignored (the C's
#     switch on the option letter has no default: case at all) - not
#     translated into an error, deliberately.
#   - Plan 9's -o has two independent argument forms, both real (this
#     is not a deprecated compat shim as BSD's manual frames its own
#     multi-word form): a comma-separated list (-o 0,1.2,2.2, or
#     attached as -o0,1.2,2.2), parsed character-by-character by
#     oparse(); and a legacy space-separated form (-o 1.2 2.3 ...),
#     parsed word-by-word directly in the option loop. Both are
#     translated, not just one.
#
# Three real, reproducible bugs in the C source, preserved rather than
# fixed (per doc/plan9-port.md's correction: translate what is there).
# All three were checked against a real Plan 9 join binary (this tree's
# local plan9port checkout), not just asserted from reading the code -
# an initial guess at what bug 1 does was wrong until checked this way.
#   1. oparse()'s comma-list parser advances its scan pointer assuming
#      a SINGLE-DIGIT field number after "1." or "2." - `atoi(s += 2)`
#      advances the pointer by exactly 2 (past "1."), then atoi's own
#      digit scan does NOT feed back into the pointer, so the following
#      `if(s[1]==',') s++` comma-skip check looks at the wrong position
#      for any field number with 2+ digits. This does NOT error, and
#      does NOT drop the intended field, as first guessed - it silently
#      inserts an EXTRA output column: the misaligned skip leaves the
#      second digit of the multi-digit number (e.g. the '0' of "10") to
#      be re-scanned as its own field spec on the next iteration, and a
#      bare '0' is a valid (join-key) selector. So "-o 1.10,2.2" produces
#      THREE output columns, not two: field 10 of file1, then the join
#      key (from the stray '0'), then field 2 of file2. Verified against
#      the real binary and reproduced exactly in jointest.b.
#   2. output()'s -o path has two distinct out-of-bounds reads for
#      degenerate -o specs that cannot happen from oparse()/the legacy
#      form's own normal output (both require a hand-built olist/olistf,
#      e.g. field number 0, i.e. "-o 1.0"): a negative array index
#      (ppi[F1][-1]), and - if a "0" (join-key) selector is used on a
#      row where the join field is out of range on BOTH sides - a read
#      of ppi[F0], where F0=3 but ppi only has 2 rows. Both are true
#      undefined behaviour in the original (memory-layout dependent, not
#      an algorithm), so there is nothing well-defined to translate;
#      output() below falls back to the -e replacement string in both
#      cases instead, and says so at the point it happens. "-o 1.0"
#      segfaults the real binary (confirmed: exit 139) - a live example
#      of why this one isn't a "preserve the behaviour" case.
#   3. input()'s field-pointer arrays point into a per-file line buffer
#      that is reused (overwritten from the start) on every call, not
#      cleared - so a field index at or beyond a SHORTER new line's own
#      field count does not reliably keep "the previous line's value"
#      (the plausible-sounding first guess) - it reads whatever the new,
#      shorter write happened to leave at that byte offset, which may be
#      a leftover fragment, a NUL the new write happened to land on, or
#      (confirmed: exit 139, segfault) memory outside the buffer entirely
#      if a still-EARLIER line's pointer for that index was never even
#      re-anchored by a subsequent shorter read. This is history-and-
#      memory-layout dependent in the original, not a well-defined rule,
#      so it is not reproduced bit-for-bit here: pp1/pp2 below simply
#      keep the last value actually written to each index, forever, once
#      written - a safe, well-defined stand-in for an unsafe case, not a
#      faithful replica of it. Only reachable by configuring -1/-2/-j
#      past some line's actual field count; ordinary use never hits it.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Join: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam - real files, not strings; see header
	# comment for why. args is the flag list only (no file operands -
	# path1/path2 are the two real files to join, taking the place of
	# argv's trailing file1/file2 words).
	runfiles:	fn(args: list of string, path1: string, path2: string): string;
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
	sys->fprint(stderr, "join: %s\n", msg);
	raise "fail:join";
}

usage()
{
	fail("usage: join [-1 x -2 y] [-o list] file1 file2");
}

# F1/F2/F0 keep the C's own numeric tags (0/1/3, with F0 deliberately
# non-contiguous - see bug 2 above) rather than renaming them, since
# olistf[] entries compare against these constants throughout.
F1: con 0;
F2: con 1;
F0: con 3;
NFLD: con 100;

j1, j2:		int;		# join field, 0-origin once parsing is done
a1, a2:		int;		# -a n (nonzero = print unmatched from file n)
sep1, sep2:	int;		# field-splitting separators (rune values)
sepstr:		string;		# output field separator (and, via -t, may be
				# more than sep1 alone if extra characters
				# were attached to -t's argument - see header)
nullstr:	string;		# -e replacement for a missing/empty field
olist:		array of int;	# -o output field list, 0-origin after the
				# decrement pass; size 2*NFLD
olistf:		array of int;	# which file (F1/F2/F0) each olist entry is from
no:		int;		# number of entries in olist/olistf in use
discard:	int;		# count of truncated lines, checked at the end

# pp1/pp2 mirror the C's ppi[F1]/ppi[F2]: field arrays that input() only
# overwrites up to the new line's own field count, leaving any index at
# or beyond that count untouched. This is a deliberate, safe stand-in for
# the C's genuinely memory-layout-dependent (and, confirmed, crash-prone)
# behaviour at that same index - see bug 3 in the header comment - not an
# attempt to reproduce it bit-for-bit. Initialised to "" rather than
# Limbo's nil default for strings for the same reason.
pp1, pp2:	array of string;

f1, f2:		ref Iobuf;

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

# atoi(3) is lenient in C: leading optional '-', then digits, stopping
# silently at the first non-digit (0 if none were seen). Every numeric
# option argument in this file goes through this, not a strict parser -
# see header comment.
catoi(s: string): int
{
	i := 0;
	n := len s;
	neg := 0;
	if(i < n && s[i] == '-'){
		neg = 1;
		i++;
	}
	v := 0;
	while(i < n && isdigit(s[i])){
		v = v*10 + (s[i] - '0');
		i++;
	}
	if(neg)
		v = -v;
	return v;
}

resetstate()
{
	a1 = 0;
	a2 = 0;
	j1 = 1;
	j2 = 1;
	sep1 = ' ';
	sep2 = '\t';
	sepstr = " ";
	nullstr = "";
	no = 0;
	discard = 0;
	olist = array[2*NFLD] of { * => 0 };
	olistf = array[2*NFLD] of { * => 0 };
	pp1 = array[NFLD+1] of { * => "" };
	pp2 = array[NFLD+1] of { * => "" };
}

# getoptarg(w, rest): w is the current option word (e.g. "-a1" or "-a"),
# rest is everything after it. If w has characters attached past the
# two-letter option prefix, that suffix is the value and rest is
# untouched (1 word consumed overall by the caller); otherwise the value
# is the next word in rest, which must exist and must not itself look
# like an option (matching the C's `argc<=2 || argv[2][0]=='-'` check).
# Returns (value, wordsLeftAfterConsumingTheValue).
getoptarg(w: string, rest: list of string): (string, list of string)
{
	if(len w > 2)
		return (w[2:], rest);
	if(rest == nil)
		fail("incomplete option " + w);
	v := hd rest;
	if(len v > 0 && v[0] == '-')
		fail("incomplete option " + w);
	return (v, tl rest);
}

# oparse: the comma-separated -o list, translated character-by-character
# exactly as the C's own index walk (not word-by-word) - including bug 1
# from the header comment, which only shows up translating it this way.
oparse(s: string)
{
	n := len s;
	si := 0;
	no = 0;
	while(no < 2*NFLD && si < n){
		c := s[si];
		if(c == '0'){
			olistf[no] = F0;
			olist[no] = 0;
		} else if(c == '1' || c == '2'){
			if(si+2 < n && s[si+1] == '.' && isdigit(s[si+2])){
				if(c == '1')
					olistf[no] = F1;
				else
					olistf[no] = F2;
				si += 2;			# s += 2
				olist[no] = catoi(s[si:]);	# atoi(s) - doesn't itself move si
			} else
				fail("invalid -o list");
		} else
			fail("invalid -o list");
		if(si+1 < n && s[si+1] == ',')		# if(s[1]==',') s++;
			si++;
		si++;					# the for-loop's own s++
		no++;
	}
}

# the legacy space-separated -o form: "1.N", "2.N", or a word starting
# with '0' (only the first character is checked - "0anything" matches,
# unlike oparse's comma form, where a stray character after a bare '0'
# is a parse error - a real, separate discrepancy between the two forms,
# both preserved rather than unified).
legacyoselmatch(w: string): (int, int, int)
{
	if(len w >= 2 && w[0] == '1' && w[1] == '.')
		return (1, F1, catoi(w[2:]));
	if(len w >= 2 && w[0] == '2' && w[1] == '.')
		return (1, F2, catoi(w[2:]));
	if(len w >= 1 && w[0] == '0')
		return (1, F0, 0);
	return (0, 0, 0);
}

# parseopts walks the option words exactly as the C's while/switch does,
# consuming the same number of argv words per option (see getoptarg's
# comment and the -j case below, which deliberately does not use
# getoptarg's convention). Returns the leftover (non-option) words, in
# order - the file operands, for init() to check and use.
parseopts(args: list of string): list of string
{
	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;			# not an option word, or a bare "-"
		c := w[1];
		case c {
		'-' =>
			l = tl l;		# "--": stop scanning, rest are files
			return l;
		'a' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			if(len v > 0 && v[0] == '1')
				a1++;
			else if(len v > 0 && v[0] == '2')
				a2++;
			else
				fail("incomplete option -a");
		'e' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			nullstr = v;
		't' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			sepstr = v;
			if(len v > 0)
				sep1 = v[0];
			else
				sep1 = 0;
			sep2 = sep1;
		'o' =>
			rest := tl l;
			attached := len w > 2;
			hascomma := 0;
			if(!attached && rest != nil){
				h := hd rest;
				for(k := 0; k < len h; k++)
					if(h[k] == ',')
						hascomma = 1;
			}
			if(attached || hascomma){
				(v, rest2) := getoptarg(w, rest);
				oparse(v);
				l = rest2;
			} else {
				l = rest;
				no = 0;
				while(no < 2*NFLD && l != nil){
					(ok, fnum, fval) := legacyoselmatch(hd l);
					if(!ok)
						break;
					olistf[no] = fnum;
					olist[no] = fval;
					no++;
					l = tl l;
				}
			}
		'j' =>
			rest := tl l;
			if(rest == nil)
				l = tl l;	# "if(argc<=2) break;" - stop, consume just "-j..."
			else {
				val := catoi(hd rest);
				if(len w > 2 && w[2] == '1')
					j1 = val;
				else if(len w > 2 && w[2] == '2')
					j2 = val;
				else {
					j1 = val;
					j2 = val;
				}
				l = tl rest;
			}
		'1' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			j1 = catoi(v);
		'2' =>
			(v, rest) := getoptarg(w, tl l);
			l = rest;
			j2 = catoi(v);
		* =>
			l = tl l;		# unrecognised option: silently ignored
		}
	}
	return l;
}

# input(): read one line from f1 or f2 and split it into fields, exactly
# as the C's input() does - persistent field arrays (see pp1/pp2's
# comment), the "strip multiple default separators, but not a custom
# -t separator" rule (`if(sep1==' ')`, true only when -t was never
# given), and the NFLD-1 field cap with its end-of-line/truncation
# bookkeeping (discard).
input(fnum: int): int
{
	iob: ref Iobuf;
	pp: array of string;
	if(fnum == F1){
		iob = f1;
		pp = pp1;
	} else {
		iob = f2;
		pp = pp2;
	}
	line := iob.gets('\n');
	if(line == nil)
		return 0;
	n := len line;
	bp := 0;
	i := 0;
	c := 0;
	do {
		i++;
		if(sep1 == ' ')				# strip multiples
			while(bp < n && (line[bp] == sep1 || line[bp] == sep2))
				bp++;
		start := bp;
		while(bp < n && line[bp] != sep1 && line[bp] != sep2 && line[bp] != '\n')
			bp++;
		if(i-1 < NFLD)
			pp[i-1] = line[start:bp];	# record beginning..end
		if(bp < n)
			c = line[bp];
		else
			c = 0;				# ran off the end: C's '\0'
		bp++;					# skip past the separator
	} while(c != '\n' && c != 0 && i < NFLD-1);
	if(c != '\n')
		discard++;
	return i;
}

# comp(), the C's runecmp() on ppi[F1][j1]/ppi[F2][j2] - a direct rune-
# by-rune comparison, which is exactly what Limbo's string ordering
# already is (see header comment).
cmp(): int
{
	a := pp1[j1];
	b := pp2[j2];
	if(a == b)
		return 0;
	if(a < b)
		return -1;
	return 1;
}

# output(): default case reconstructs the matched/unmatched record from
# on1 (file1's field count for this call, 0 if file1 has no record here)
# and on2 likewise; the -o case walks olist/olistf. See header comment
# for the two out-of-bounds cases in the original this deliberately does
# not reproduce.
output(on1: int, on2: int)
{
	if(no <= 0){
		if(on1 != 0)
			emit(pp1[j1]);
		else
			emit(pp2[j2]);
		for(i1 := 0; i1 < on1; i1++){
			if(i1 != j1){
				emit(sepstr);
				emit(pp1[i1]);
			}
		}
		for(i2 := 0; i2 < on2; i2++){
			if(i2 != j2){
				emit(sepstr);
				emit(pp2[i2]);
			}
		}
		emit("\n");
	} else {
		for(io := 0; io < no; io++){
			temp: string;
			if(olistf[io] == F0 && on1 > j1)
				temp = pp1[j1];
			else if(olistf[io] == F0 && on2 > j2)
				temp = pp2[j2];
			else if(olistf[io] == F0){
				# both sides lack the join field here: the C
				# falls through to ppi[F0][olist[i]] - out of
				# bounds (F0==3, only 2 rows exist) - see bug 2.
				temp = nullstr;
			} else if(olist[io] < 0 || olist[io] > NFLD){
				# a "-o 1.0"/"-o 2.0" (field 0) style spec -
				# decrements to -1 - out of bounds the other
				# direction; see bug 2.
				temp = nullstr;
			} else {
				if(olistf[io] == F1)
					temp = pp1[olist[io]];
				else
					temp = pp2[olist[io]];
				if(olistf[io] == F1 && on1 <= olist[io] ||
				   olistf[io] == F2 && on2 <= olist[io] ||
				   temp == "")
					temp = nullstr;
			}
			emit(temp);
			if(io == no-1)
				emit("\n");
			else
				emit(sepstr);
		}
	}
}

# seek2/seek1: mirror images, driving the match off whichever file is
# NOT the one being rewound. Bookmarks (bot2/top2, bot1/top1) are byte
# offsets via Iobuf.offset()/seek() - the direct analogue of the C's
# ftell()/fseek(...,0), since bufio's offset() accounts for buffered-
# but-unconsumed data the same way ftell does after fgets().
seek2()
{
	n1, n2: int;
	top2 := big 0;
	bot2 := f2.offset();
	n1 = input(F1);
	n2 = input(F2);
	while((n1 > 0 && n2 > 0) || ((a1 != 0 || a2 != 0) && n1+n2 > 0)){
		if((n1 > 0 && n2 > 0 && cmp() > 0) || n1 == 0){
			if(a2 != 0)
				output(0, n2);
			bot2 = f2.offset();
			n2 = input(F2);
		} else if((n1 > 0 && n2 > 0 && cmp() < 0) || n2 == 0){
			if(a1 != 0)
				output(n1, 0);
			n1 = input(F1);
		} else {
			while(n2 > 0 && cmp() == 0){
				output(n1, n2);
				top2 = f2.offset();
				n2 = input(F2);
			}
			f2.seek(bot2, Sys->SEEKSTART);
			n2 = input(F2);
			n1 = input(F1);
			for(;;){
				if(n1 > 0 && n2 > 0 && cmp() == 0){
					output(n1, n2);
					n2 = input(F2);
				} else if((n1 > 0 && n2 > 0 && cmp() < 0) || n2 == 0){
					f2.seek(bot2, Sys->SEEKSTART);
					n2 = input(F2);
					n1 = input(F1);
				} else {
					f2.seek(top2, Sys->SEEKSTART);
					bot2 = top2;
					n2 = input(F2);
					break;
				}
			}
		}
	}
}

seek1()
{
	n1, n2: int;
	top1 := big 0;
	bot1 := f1.offset();
	n1 = input(F1);
	n2 = input(F2);
	while((n1 > 0 && n2 > 0) || ((a1 != 0 || a2 != 0) && n1+n2 > 0)){
		if((n1 > 0 && n2 > 0 && cmp() > 0) || n1 == 0){
			if(a2 != 0)
				output(0, n2);
			n2 = input(F2);
		} else if((n1 > 0 && n2 > 0 && cmp() < 0) || n2 == 0){
			if(a1 != 0)
				output(n1, 0);
			bot1 = f1.offset();
			n1 = input(F1);
		} else {
			while(n2 > 0 && cmp() == 0){
				output(n1, n2);
				top1 = f1.offset();
				n1 = input(F1);
			}
			f1.seek(bot1, Sys->SEEKSTART);
			n2 = input(F2);
			n1 = input(F1);
			for(;;){
				if(n1 > 0 && n2 > 0 && cmp() == 0){
					output(n1, n2);
					n1 = input(F1);
				} else if((n1 > 0 && n2 > 0 && cmp() > 0) || n1 == 0){
					f1.seek(bot1, Sys->SEEKSTART);
					n2 = input(F2);
					n1 = input(F1);
				} else {
					f1.seek(top1, Sys->SEEKSTART);
					bot1 = top1;
					n1 = input(F1);
					break;
				}
			}
		}
	}
}

# parseandvalidate: option parsing plus the C's post-loop validation
# (the -o decrement-and-range-check pass, and j1/j2 >= 1), stopping
# short of the file-operand-count check, which only init() needs (the
# test seam takes its files separately - see header comment).
parseandvalidate(args: list of string): list of string
{
	resetstate();
	leftover := parseopts(args);
	for(i := 0; i < no; i++){
		old := olist[i];
		olist[i] = old - 1;
		if(old > NFLD)
			fail("field number too big in -o");
	}
	if(j1 < 1 || j2 < 1)
		fail("invalid field indices");
	j1--;
	j2--;
	return leftover;
}

# dojoin: given two already-open file descriptors, wraps them, probes
# seekability in the same order as the C (F2 first, then F1, else
# error), runs the matching algorithm, and checks discard - all of
# main()'s logic after the two files are open.
dojoin(fd1: ref FD, fd2: ref FD)
{
	seekable2 := sys->seek(fd2, big 0, Sys->SEEKRELA) >= big 0;
	seekable1 := 0;
	if(!seekable2)
		seekable1 = sys->seek(fd1, big 0, Sys->SEEKRELA) >= big 0;
	f1 = bufio->fopen(fd1, Bufio->OREAD);
	f2 = bufio->fopen(fd2, Bufio->OREAD);
	if(f1 == nil || f2 == nil)
		fail("cannot wrap input file");
	if(seekable2)
		seek2();
	else if(seekable1)
		seek1();
	else
		fail("neither file is randomly accessible");
	if(discard != 0)
		fail("some input line was truncated");
}

openreal(name: string): ref FD
{
	if(name == "-")
		return sys->fildes(0);
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		fail("can't open " + name);
	return fd;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(stderr, "join: cannot load Bufio\n");
		raise "fail:module";
	}

	leftover := parseandvalidate(tl argv);
	n := 0;
	for(l := leftover; l != nil; l = tl l)
		n++;
	if(n != 2)
		usage();
	f1name := hd leftover;
	f2name := hd tl leftover;

	fd1 := openreal(f1name);
	fd2 := openreal(f2name);
	dojoin(fd1, fd2);
}

runfiles(args: list of string, path1: string, path2: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	parseandvalidate(args);	# args carries flags only, no file operands
	outbuf = "";
	capturing = 1;
	fd1 := sys->open(path1, Sys->OREAD);
	fd2 := sys->open(path2, Sys->OREAD);
	if(fd1 == nil || fd2 == nil){
		capturing = 0;
		fail("runfiles: cannot open test file");
	}
	dojoin(fd1, fd2);
	capturing = 0;
	return outbuf;
}
