implement Cb;

# A structural Limbo translation of Plan 9's real cb(1) - sys/src/cmd/cb/
# in the 9front tree: cb.c (1040 lines) + cb.h (172 lines, NOT a
# declarations-only header - it's a translation unit defining ~25
# mutable globals, the key[]/op[] recognition tables, and 6 statement
# macros) + cbtype.c (21 lines) + cbtype.h (26 lines) - 1259 real C
# lines total (the doc's own "1,061 combined" estimate silently
# dropped both .h files; corrected here, not left standing).
#
# Scoped by reading the actual source before committing to translate
# it (per this backlog's own standing discipline) - two real findings
# from that pass, not assumed from the line count:
#
#   1. plan9port's own copy of cb has DIVERGED from 9front's (tab vs
#      4-space indent on split continuation lines; the `::` case
#      entirely removed; ARGBEGIN bundling replaced with a loop that
#      silently drops a bundled second flag). This translation follows
#      9front's own cb.c, the actual translation target - plan9port's
#      real binary is NOT used as an oracle here for that reason (it
#      would fail on ordinary input for reasons that are its own
#      divergence, not this port's). Instead, following urlencode.b's
#      own precedent, cbtest.b builds 9front's ACTUAL cb.c fresh from
#      source via host clang against plan9port's prebuilt libs - a
#      faithful oracle with zero normalization needed, not a masked
#      comparison against a binary that behaves differently by design.
#
#   2. cbtype.c's own `_cbtype_[]` table is indexed `(_cbtype_+1)[c]`
#      for c in -1..127 (Beof==-1 deliberately selects the table's own
#      leading 0 entry, giving "no classification" for EOF). A byte
#      with the high bit set indexes past the table's real 129 entries
#      in the C - undefined behavior there (plan9port's own copy pads
#      the array to [257] as a tell that this is fragile). This port
#      defines that case rather than reproducing the C's UB: the table
#      is sized 257 (index c+1, valid for c in -1..255), and every
#      classification function additionally guards c<-1 to return 0.
#      All I/O is byte-, not rune-, oriented (getb/ungetb/putb, not
#      getc/ungetc/putc) so a UTF-8 continuation byte is classified (as
#      "not alnum/op/space/etc", correctly) rather than corrupted.
#
# unget(c)'s own C semantics were checked, not assumed, before
# deciding whether an extra pushback layer was needed on top of
# Bufio: `unget()` only honors its own explicit argument c while
# `inswitch` is true (writing it into the temp lookahead buffer);
# when `inswitch` is false it degrades to a bare `Bungetc(input)`,
# which discards its own argument entirely and just undoes the FD's
# last real read. Checked appl/lib/bufio.b directly: `Iobuf.ungetb()`
# does exactly `b.index--` - the identical single-level, argument-
# discarding "undo the last getb()" contract as Plan 9's own
# `Bungetc()`. Since the underlying primitives already match exactly,
# a literal 1:1 translation of `unget()`'s own conditional structure
# (using `input.ungetb()` in the non-inswitch branch, exactly as the C
# uses `Bungetc(input)`) reproduces whatever behavior the two call
# sites that pass a "wrong" argument (`unget('{')`, `unget('\n')`)
# actually have - correct or not - with no invented layer required.
#
# `main()`'s own file loop never resets ANY of cb.h's globals between
# multiple file arguments given on one command line (`cb a.c b.c`) -
# a real, if minor, latent bug in the source, preserved here exactly
# (init()'s own file loop below does not reset state between files
# either) and noted in BUGS. The in-process test seam run() is a
# different situation: like every repeated-call test seam in this
# backlog (pr.b's own Colw lesson), it must reset ALL state at the
# START of each call so independent test cases don't contaminate each
# other - resetstate() below exists for exactly that, and is NOT what
# `main()`'s own multi-file loop does.
#
# ARGBEGIN's own bundling behavior (`-jsl 80` == `-j -s -l 80`) is
# preserved via the same hand-rolled per-character parser convention
# ascii.b established, confirmed against the built-from-source oracle
# before finalizing (not assumed from EARGF's macro expansion, and
# NOT copied from plan9port's own diverged replacement, which silently
# drops flags in exactly this position).
#
# Dependencies are otherwise clean: no libregexp, no fork/exec, no
# file-tree walk - each file argument is an independent single pass
# through work(), streamed via Bufio exactly as the C streams via
# Biobuf.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Cb: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the flag+operand list with no
	# leading program name (matching ascii.b's own run() - cb.b uses
	# the same hand-rolled bundling parser ascii.b established, not
	# arg.m, so unlike rsa2ssh.b's own run() there is no dummy
	# program-name element to prepend here); input is one file's
	# worth of C source. Returns the reformatted output as raw bytes (cb's
	# own input/output is not guaranteed valid UTF-8 - a string literal
	# or comment can carry any byte). A fatal parse error (unbalanced
	# braces/brackets/quotes hitting real EOF) raises "fail:cb".
	run:	fn(argv: list of string, input: array of byte): array of byte;
};

stderr: ref FD;
fdout: ref FD;
capturing: int;
outbuf: list of byte;

# --- constants, verbatim from cb.h (renamed with a K/F suffix where
# the bare C name risks colliding with a Limbo reserved word or an
# unrelated identifier below - IF/ELSE/... aren't reserved here, but
# TYPE could be confused with the "type" keyword at a glance, so all
# seven get the same treatment for consistency). Numeric VALUES that
# are only ever compared among themselves are renumbered from 0 (iota)
# - never serialized, never bit-tested, so this is not observable.
# ALWAYS/NEVER/SOMETIMES ARE bitwise-tested (`blanks & ALWAYS`) and
# keep their literal C values (1/2/4) exactly. ---
IFK, ELSEK, CASEK, TYPEK, DOK, STRUCTK, OTHERK: con iota;

ALWAYSF: con 1;
NEVERF: con 2;
SOMETIMESF: con 4;

YES: con 1;
NO: con 0;

KEYWORDF: con 1;
DATADEFF: con 2;
SINITF: con 3;

CLEVEL: con 200;
IFLEVEL: con 100;
DOLEVEL: con 100;
OPLENGTH: con 100;
LINE: con 2048;
TABLENG: con 8;
MAXTABSDEFAULT: con 8;
LINELENGDEFAULT: con 2048;
TEMP: con 20480;

Beof: con -1;

# --- key[] - verbatim from cb.h, as parallel arrays (Limbo has no
# adt-literal array initializer the way C has an initializer list of
# structs; a parallel-array is the established idiom in this backlog
# for this shape of table, e.g. ascii.b's own str[]/ncoltab[]). ---
keyname := array[] of {
	"switch", "do", "while", "if", "for", "else", "case", "default",
	"char", "int", "short", "long", "unsigned", "float", "double",
	"struct", "union", "enum", "extern", "register", "static", "typedef",
};
keypunc := array[] of {
	' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ',
	'\t', '\t', '\t', '\t', '\t', '\t', '\t',
	' ', ' ', ' ',
	' ', ' ', ' ', ' ',
};
keytype := array[] of {
	OTHERK, DOK, OTHERK, IFK, OTHERK, ELSEK, CASEK, CASEK,
	TYPEK, TYPEK, TYPEK, TYPEK, TYPEK, TYPEK, TYPEK,
	STRUCTK, STRUCTK, STRUCTK,
	TYPEK, TYPEK, TYPEK, TYPEK,
};

# --- op[] - verbatim from cb.h, same parallel-array treatment. ---
opname := array[] of {
	"+=", "-=", "*=", "/=", "%=", ">>=", "<<=", "&=", "^=", "|=",
	">>", "<<", "<=", ">=", "==", "!=", "=", "&&", "||",
	"++", "--", "->",
	"<", ">", "+", "/", "%", "^", "|", "!", "~", "*", "&", "-",
	"?", ":",
};
opblanks := array[] of {
	ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF,
	ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF,
	NEVERF, NEVERF, NEVERF,
	ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, ALWAYSF, NEVERF, NEVERF, SOMETIMESF, SOMETIMESF, SOMETIMESF,
	ALWAYSF, ALWAYSF,
};
opsetop := array[] of {
	YES, YES, YES, YES, YES, YES, YES, YES, YES, YES,
	YES, YES, YES, YES, YES, YES, YES, YES, YES,
	NO, NO, NO,
	YES, YES, YES, YES, YES, YES, YES, YES, YES, YES, YES, YES,
	YES, YES,
};

# --- _cbtype_[] - verbatim from cbtype.c, sized 257 (not the C's own
# 129) so a high-bit byte lands on a defined zero entry instead of an
# out-of-range access - see this file's own header comment. Index is
# c+1, matching the C's own (_cbtype_+1)[c] exactly for c in -1..127;
# entries 128..255 (c in 127..254, i.e. bytes with the high bit set)
# are the padding, all zero. ---
_U: con 16r01;
_L: con 16r02;
_N: con 16r04;
_S: con 16r08;
_P: con 16r10;
_C: con 16r20;
_X: con 16r40;
_O: con 16r80;

cbtype := array[] of {
	byte 0,
	byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C,
	byte _C, byte (_C|_S), byte (_C|_S), byte (_C|_S), byte (_C|_S), byte (_C|_S), byte _C, byte _C,
	byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C,
	byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C, byte _C,
	byte _S, byte (_P|_O), byte _P, byte _P, byte _P, byte (_P|_O), byte (_P|_O), byte _P,
	byte _P, byte _P, byte (_P|_O), byte (_P|_O), byte _P, byte (_P|_O), byte _P, byte (_P|_O),
	byte _N, byte _N, byte _N, byte _N, byte _N, byte _N, byte _N, byte _N,
	byte _N, byte _N, byte _P, byte _P, byte (_P|_O), byte (_P|_O), byte (_P|_O), byte _P,
	byte _P, byte (_U|_X), byte (_U|_X), byte (_U|_X), byte (_U|_X), byte (_U|_X), byte (_U|_X), byte _U,
	byte _U, byte _U, byte _U, byte _U, byte _U, byte _U, byte _U, byte _U,
	byte _U, byte _U, byte _U, byte _U, byte _U, byte _U, byte _U, byte _U,
	byte _U, byte _U, byte _U, byte _P, byte _P, byte _P, byte (_P|_O), byte (_P|_L),
	byte _P, byte (_L|_X), byte (_L|_X), byte (_L|_X), byte (_L|_X), byte (_L|_X), byte (_L|_X), byte _L,
	byte _L, byte _L, byte _L, byte _L, byte _L, byte _L, byte _L, byte _L,
	byte _L, byte _L, byte _L, byte _L, byte _L, byte _L, byte _L, byte _L,
	byte _L, byte _L, byte _L, byte _P, byte (_P|_O), byte _P, byte _P, byte _C,
};	# 129 real entries; the rest (up to 257) default-initialize to byte 0

ctype(c: int): int
{
	if(c < -1 || c+1 >= len cbtype)
		return 0;
	return int cbtype[c+1];
}
isop(c: int): int { return (ctype(c) & _O) != 0; }
isalpha(c: int): int { return (ctype(c) & (_U|_L)) != 0; }
isdigit(c: int): int { return (ctype(c) & _N) != 0; }
isspace(c: int): int { return (ctype(c) & _S) != 0; }
ispunct(c: int): int { return (ctype(c) & _P) != 0; }
isalnum(c: int): int { return (ctype(c) & (_U|_L|_N)) != 0; }

# --- cb.h's own mutable globals ---
Indent: adt {
	tabs:	int;
	pdepth:	int;
	iflev:	int;
	ifc:	array of int;		# sized IFLEVEL
	spdepth: array of int;		# sized IFLEVEL
};
ind: array of ref Indent;	# sized CLEVEL
clevidx: int;

strict, join, opflag, keyflag: int;
paren, split, folded, dolevel: int;
dotabs, docurly, dopdepth: array of int;	# sized DOLEVEL
structlev, question: int;

strbuf: array of byte;		# C's string[LINE]
p: int;				# write cursor into strbuf
lastlook: int;			# index into strbuf, -1 = C's NULL

temp: array of byte;		# C's temp[TEMP]
tp: int;
err: int;
lastplace: int;
tptr: int;
maxleng, maxtabs, count: int;
next: int;			# 0 = C's '\0' sentinel (no pending byte)
inswitch: int;
lbegin: int;
lineno: int;

input: ref Iobuf;

resetstate()
{
	ind = array[CLEVEL] of ref Indent;
	for(i := 0; i < CLEVEL; i++){
		ind[i] = ref Indent;
		ind[i].tabs = 0;
		ind[i].pdepth = 0;
		ind[i].iflev = 0;
		ind[i].ifc = array[IFLEVEL] of int;
		ind[i].spdepth = array[IFLEVEL] of int;
	}
	clevidx = 0;

	strict = 0;
	join = 0;
	opflag = 1;
	keyflag = 0;
	paren = 0;
	split = 0;
	folded = 0;
	dolevel = 0;
	dotabs = array[DOLEVEL] of int;
	docurly = array[DOLEVEL] of int;
	dopdepth = array[DOLEVEL] of int;
	structlev = 0;
	question = 0;

	strbuf = array[LINE] of byte;
	p = 0;
	lastlook = -1;

	temp = array[TEMP] of byte;
	tp = 0;
	err = 0;
	lastplace = 0;
	tptr = 0;
	maxleng = LINELENGDEFAULT;
	maxtabs = MAXTABSDEFAULT;
	count = 0;
	next = 0;
	inswitch = 0;
	lbegin = 1;
	lineno = 0;
}

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
}

warn(s: string)
{
	if(stderr == nil)
		stderr = sys->fildes(2);
	sys->fprint(stderr, "%s", s);
}

fail(msg: string)
{
	warn("cb: "+msg+"\n");
	raise "fail:cb";
}

cberror(s: string)
{
	warn(sys->sprint("saw EOF while looking for %s\n", s));
	raise "fail:cb";
}

# --- output: emit()/emitbyte() route to a real fd (CLI) or an
# in-memory byte accumulator (test seam) - same convention ascii.b
# established, since cb's own output can carry arbitrary bytes (a
# string literal or comment need not be valid UTF-8). ---
emit(b: array of byte)
{
	if(capturing){
		for(i := 0; i < len b; i++)
			outbuf = b[i] :: outbuf;
	} else
		sys->write(fdout, b, len b);
}
emits(s: string)
{
	emit(array of byte s);
}
emitbyte(c: int)
{
	if(capturing)
		outbuf = byte c :: outbuf;
	else
		sys->write(fdout, array[1] of {byte c}, 1);
}

# --- getch/unget: see this file's own header comment for why this is
# a literal, unmodified translation of the C's own conditional
# structure, with no extra pushback layer. ---
getch(): int
{
	if(inswitch){
		if(next != 0){
			c := next;
			next = 0;
			return c;
		}
		if(tptr <= lastplace){
			if(temp[tptr] != byte 0)
				return int temp[tptr++];
			else {
				tptr++;
				if(tptr <= lastplace)
					return int temp[tptr++];
			}
		}
		inswitch = 0;
		lastplace = 0;
		tptr = 0;
	}
	return input.getb();
}

unget(c: int)
{
	if(inswitch){
		if(tptr != 0){
			tptr--;
			temp[tptr] = byte c;
		} else
			next = c;
	} else
		input.ungetb();
}

eatspace()
{
	cc := getch();
	while(cc == ' ' || cc == '\t')
		cc = getch();
	unget(cc);
}
eatallsp()
{
	cc := getch();
	while(cc == ' ' || cc == '\t' || cc == '\n')
		cc = getch();
	unget(cc);
}

puttmp(c: int, keepc: int): int
{
	if(tp < TEMP-120){
		temp[tp] = byte c;
		tp++;
	} else {
		if(keepc != 0){
			if(tp >= TEMP-1){
				warn("can't look past huge comment - quiting\n");
				raise "fail:cb";
			}
			temp[tp] = byte c;
			tp++;
		} else if(err == 0){
			err++;
			warn("truncating long comment\n");
		}
	}
	return c;
}

# getnext: see this file's own header comment - a goto-free
# restructuring of the C's own goto graph (outer restart loop =
# "space:", the comment scan = "cont:"/"star:"), not a behavior
# change. Returns an index into temp (C's own char* return).
getnext(must: int): int
{
	prect := 0;
	nlct := 0;

	if(tptr > lastplace){
		tptr = 0;
		lastplace = 0;
		err = 0;
		inswitch = 0;
	}
	tp = lastplace;
	if(inswitch != 0 && tptr <= lastplace){
		tc := int temp[lastplace];
		if(isalnum(tc) || ispunct(tc) || isop(tc))
			return lastplace;
	}

	c := 0;
	beg := 0;
	for(;;){
		c = input.getb();
		while(isspace(c)){
			puttmp(c, 1);
			c = input.getb();
		}
		beg = tp;
		puttmp(c, 1);
		gotdone := 0;
		if(c == '/'){
			cs := puttmp(input.getb(), 1);
			if(cs == '*'){
				commentopen := 1;
				while(commentopen != 0){
					for(;;){
						c = input.getb();
						if(c == '*')
							break;
						puttmp(c, 0);
						if(must == 0 && c == '\n'){
							nlct++;
							if(nlct > 2){
								gotdone = 1;
								break;
							}
						}
					}
					if(gotdone != 0)
						break;
					puttmp(c, 1);
					starloop := 1;
					while(starloop != 0){
						c = input.getb();
						cs2 := puttmp(c, 1);
						if(cs2 == '/'){
							beg = tp;
							c = input.getb();
							puttmp(c, 1);
							commentopen = 0;
							starloop = 0;
						} else if(c == '*')
							;	# goto star: loop again
						else
							starloop = 0;	# goto cont
					}
				}
				if(gotdone != 0)
					break;
			} else {
				break;
			}
		}
		if(isspace(c))
			continue;
		if(c == '#' && tp > 1 && int temp[tp-2] == '\n'){
			prect++;
			if(prect > 2)
				break;
			for(;;){
				c = input.getb();
				cc := puttmp(c, 1);
				if(cc == '\n')
					break;
				if(c == '\\')
					puttmp(input.getb(), 1);
			}
			continue;
		}
		if(isalnum(c)){
			for(;;){
				c = input.getb();
				if(!isalnum(c))
					break;
				puttmp(c, 1);
			}
			input.ungetb();
		}
		break;
	}
	puttmp(0, 1);
	lastplace = tp - 1;
	inswitch = 1;
	return beg;
}

# --- output layer ---
doOUT()
{
	outs(ind[clevidx].tabs);
	emitbyte('\n');
	opflag = 1;
	lbegin = 1;
	count = 0;
}
doOUTK()
{
	doOUT();
	keyflag = 0;
}
BUMP()
{
	ind[clevidx].tabs++;
	ind[clevidx].pdepth++;
}
UNBUMP()
{
	ind[clevidx].tabs -= ind[clevidx].pdepth;
	ind[clevidx].pdepth = 0;
}

ptabs(n: int)
{
	num: int;
	if(n > maxtabs){
		if(!folded){
			emits("/* code folded from here */\n");
			folded = 1;
		}
		num = n - maxtabs;
	} else {
		num = n;
		if(folded){
			folded = 0;
			emits("/* unfolding */\n");
		}
	}
	for(i := 0; i < num; i++)
		emitbyte('\t');
}

outs(n: int)
{
	if(p > 0){
		if(lbegin){
			ptabs(n);
			lbegin = 0;
			if(split == 1){
				split = 0;
				if(ind[clevidx].tabs > 0)
					emits("\t");
			}
		}
		emit(strbuf[0:p]);
		lastlook = -1;
		p = 0;
	} else {
		if(lbegin != 0){
			lbegin = 0;
			split = 0;
		}
	}
}

putch(c: int, ok: int)
{
	if(p < LINE-1){
		if(count+TABLENG*ind[clevidx].tabs >= maxleng && ok != 0 && !folded){
			if(c != ' '){
				strbuf[p] = byte c;
				p++;
			}
			doOUT();
			split = 1;
			cc := getch();
			if(cc != '\n')
				unget(cc);
		} else {
			strbuf[p] = byte c;
			p++;
			count++;
		}
	} else {
		outs(ind[clevidx].tabs);
		strbuf[p] = byte c;
		p++;
		count = 0;
	}
}

putspace(ch: int, ok: int)
{
	if(p == 0)
		putch(ch, ok);
	else if(int strbuf[p-1] != ch)
		putch(ch, ok);
}

copy(s: string)
{
	for(i := 0; i < len s; i++)
		putch(s[i], NO);
}

clearif(ci: int)
{
	for(i := 0; i < IFLEVEL-1; i++)
		ind[ci].ifc[i] = 0;
}

# --- keyword/operator recognition ---
# lookup: the C's own `lookup(char *first, char *last)` takes raw
# pointers that can address EITHER of two different buffers depending
# on the call site - `string`/`p`/`lastlook` at some sites, `temp`/
# `getnext()`'s own return value at others (case '}'/';'  and
# checkif()/gottype() all pass a `pt` that came from getnext(), an
# index into temp, not string). Limbo has no buffer-agnostic pointer
# to match that with, so the buffer is an explicit parameter here -
# lookupbuf(strbuf,...) at the string-buffer call sites, lookupbuf
# (temp,...) at the temp-buffer ones. A real bug from missing this the
# first time: every temp-buffer call site silently got strbuf's
# (usually unrelated) contents instead, so an "else"/"case" keyword
# sitting in the lookahead buffer was never recognized there - found
# by diffing against a real built-from-source oracle on ordinary
# if/else input, not by re-reading.
lookupbuf(buf: array of byte, first: int, last: int): int
{
	if(first == last || first == -1)
		return -1;
	cptr := first;
	while(cptr < last && (int buf[cptr] == ' ' || int buf[cptr] == '\t'))
		cptr++;
	if(cptr >= last)
		return -1;
	for(i := 0; i < len keyname; i++){
		ck := keyname[i];
		k := cptr;
		j := 0;
		while(j < len ck && int buf[k] == ck[j]){
			k++;
			j++;
		}
		if(j == len ck && (k == last || (k < last && !isalnum(int buf[k])))){
			opflag = 1;
			lastlook = -1;
			return i;
		}
	}
	return -1;
}
lookupstr(first: int, last: int): int { return lookupbuf(strbuf, first, last); }
lookuptemp(first: int, last: int): int { return lookupbuf(temp, first, last); }

keep(oi: int)
{
	blanks := opblanks[oi];
	ok: int;
	if(blanks == NEVERF)
		ok = NO;
	else
		ok = YES;
	precond := strict != 0 &&
		((blanks & ALWAYSF) != 0 ||
		 (opflag == 0 && (blanks & SOMETIMESF) != 0 && ind[clevidx].tabs != 0));
	if(precond)
		putspace(' ', YES);
	nm := opname[oi];
	for(si := 0; si < len nm; si++){
		if(si == len nm - 1)
			putch(nm[si], ok);
		else
			putch(nm[si], NO);
	}
	if(precond)
		putch(' ', YES);
}

gotop(c: int)
{
	optmp := array[OPLENGTH] of byte;
	oplen := 0;
	optmp[oplen++] = byte c;
	cc := getch();
	while(isop(cc)){
		optmp[oplen++] = byte cc;
		cc = getch();
	}
	if(strict == 0)
		unget(cc);
	else if(cc != ' ')
		unget(cc);

	b := 0;
	i := 0;
	while(i < len opname){
		a := opname[i];
		k := b;
		j := 0;
		while(j < len a && k < oplen && int optmp[k] == a[j]){
			k++;
			j++;
		}
		if(j == len a){
			keep(i);
			opflag = opsetop[i];
			if(k != oplen){
				b = k;
				i = 0;
				continue;
			} else
				break;
		} else
			i++;
	}
}

# --- brace/indent-level bookkeeping ---
gotif()
{
	outs(ind[clevidx].tabs);
	ind[clevidx].iflev++;
	if(ind[clevidx].iflev >= IFLEVEL-1){
		warn(sys->sprint("too many levels of if %d\n", ind[clevidx].iflev));
		ind[clevidx].iflev = IFLEVEL-1;
	}
	ind[clevidx].ifc[ind[clevidx].iflev] = ind[clevidx].tabs;
	ind[clevidx].spdepth[ind[clevidx].iflev] = ind[clevidx].pdepth;
}
gotelse()
{
	ind[clevidx].tabs = ind[clevidx].ifc[ind[clevidx].iflev];
	ind[clevidx].pdepth = ind[clevidx].spdepth[ind[clevidx].iflev];
	ind[clevidx].iflev--;
	if(ind[clevidx].iflev < 0)
		ind[clevidx].iflev = 0;
}
checkif(pt: int): int
{
	lidx := lookuptemp(pt, lastplace+1);
	if(lidx != -1){
		if(keytype[lidx] == IFK){
			if(strict != 0)
				putch(' ', YES);
			copy(keyname[lidx]);
			temp[pt] = byte 0;
			lastplace = pt;
			if(strict != 0){
				putch(keypunc[lidx], NO);
				eatallsp();
			}
			ind[clevidx].tabs = ind[clevidx].ifc[ind[clevidx].iflev];
			ind[clevidx].pdepth = ind[clevidx].spdepth[ind[clevidx].iflev];
			keyflag = KEYWORDF;
			return 1;
		}
	}
	return 0;
}
gotdo()
{
	dolevel++;
	if(dolevel >= DOLEVEL-1){
		warn(sys->sprint("too many levels of do %d\n", dolevel));
		dolevel = DOLEVEL-1;
	}
	dotabs[dolevel] = ind[clevidx].tabs;
	docurly[dolevel] = YES;
}
resetdo()
{
	if(docurly[dolevel] == NO)
		ind[clevidx].pdepth = dopdepth[dolevel];
	dolevel--;
	if(dolevel < 0)
		dolevel = 0;
}
gottype(lidxin: int)
{
	lidx := lidxin;
	for(;;){
		pt := getnext(1);
		tlidx := lookuptemp(pt, lastplace+1);
		if(tlidx != -1){
			putch(' ', YES);
			copy(keyname[tlidx]);
			temp[pt] = byte 0;
			lastplace = pt;
			if(keytype[tlidx] == STRUCTK){
				putch(keypunc[tlidx], YES);
				gotstruct();
				break;
			}
			lidx = tlidx;
		} else {
			putch(keypunc[lidx], NO);
			c := getch();
			while(c == ' ' || c == '\t')
				c = getch();
			unget(c);
			break;
		}
	}
}
gotstruct()
{
	c := getch();
	while(c == ' ' || c == '\t'){
		if(strict == 0)
			putch(c, NO);
		c = getch();
	}
	if(c == '{'){
		structlev++;
		unget(c);
		return;
	}
	if(isalpha(c)){
		putch(c, NO);
		c = getch();
		while(isalnum(c)){
			putch(c, NO);
			c = getch();
		}
	}
	unget(c);
	pt := getnext(1);
	if(int temp[pt] == '{')
		structlev++;
	if(strict != 0){
		eatallsp();
		putch(' ', NO);
	}
}

# --- comments ---
comment(ok: int): int
{
	hitnl := 0;
	for(;;){
		ch := getch();
		if(ch == Beof)
			break;
		putch(ch, NO);
		if(ch == '*'){
			for(;;){
				ch = getch();
				if(ch == '/'){
					putch(ch, NO);
					return hitnl;
				}
				putch(ch, NO);
				if(ch != '*')
					break;
			}
		}
		if(ch == '\n'){
			if(ok != 0 && hitnl == 0)
				outs(ind[clevidx].tabs);
			else
				outs(0);
			lbegin = 1;
			count = 0;
			hitnl = 1;
		}
	}
	return hitnl;
}
cppcomment(ok: int): int
{
	hitnl := 0;
	for(;;){
		ch := getch();
		if(ch == Beof)
			break;
		if(ch == '\n'){
			if(ok != 0 && hitnl == 0)
				outs(ind[clevidx].tabs);
			else
				outs(0);
			lbegin = 1;
			count = 0;
			hitnl = 1;
			break;
		}
		putch(ch, NO);
	}
	return hitnl;
}

getnl(): int
{
	gotcmt := 0;
	savp := p;
	ch := getch();
	while(ch == '\t' || ch == ' '){
		putch(ch, NO);
		ch = getch();
	}
	if(ch == '/'){
		ch = getch();
		if(ch == '*'){
			putch('/', NO);
			putch('*', NO);
			comment(NO);
			ch = getch();
			gotcmt = 1;
		} else if(ch == '/'){
			putch('/', NO);
			putch('/', NO);
			cppcomment(NO);
			ch = getch();
			gotcmt = 1;
		} else {
			if(inswitch){
				lastplace++;
				temp[lastplace] = byte ch;
			} else {
				inswitch = 1;
				temp[lastplace] = byte ch;
			}
			unget('/');
			return 0;
		}
	}
	if(ch == '\n'){
		if(gotcmt == 0)
			p = savp;
		return 1;
	}
	unget(ch);
	return 0;
}

# --- the main per-character dispatch loop ---
work()
{
	for(;;){
		c := getch();
		if(c == Beof)
			break;
		case c {
		'{' =>
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				if(keytype[lptr] == ELSEK)
					gotelse();
				else if(keytype[lptr] == DOK)
					gotdo();
				else if(keytype[lptr] == STRUCTK)
					structlev++;
			}
			clevidx++;
			if(clevidx >= CLEVEL-1){
				warn("too many levels of curly brackets\n");
				clevidx = CLEVEL-1;
			}
			ind[clevidx].pdepth = 0;
			ind[clevidx].tabs = ind[clevidx-1].tabs;
			clearif(clevidx);
			if(strict != 0 && ind[clevidx].tabs > 0)
				putspace(' ', NO);
			putch(c, NO);
			getnl();
			if(keyflag == DATADEFF)
				doOUT();
			else
				doOUTK();
			ind[clevidx].tabs++;
			pt := getnext(0);
			if(int temp[pt] == '{'){
				cc := getch();
				while(cc != '{'){
					if(cc == Beof)
						cberror("{");
					cc = getch();
				}
				putch(cc, NO);
				if(strict != 0){
					putch(' ', NO);
					eatspace();
				}
				keyflag = SINITF;
			}
			continue;
		'}' =>
			pt := getnext(0);
			if(int temp[pt] == ','){
				if(strict != 0){
					putspace(' ', NO);
					eatspace();
				}
				putch(c, NO);
				putch(int temp[pt], NO);
				temp[pt] = byte 0;
				ct := getnl();
				pt = getnext(0);
				if(int temp[pt] == '{'){
					doOUT();
					cc := getch();
					while(cc != '{'){
						if(cc == Beof)
							cberror("}");
						cc = getch();
					}
					putch(cc, NO);
					if(strict != 0){
						putch(' ', NO);
						eatspace();
					}
					getnext(0);
					continue;
				} else if(strict != 0 || ct != 0)
					doOUT();
				continue;
			} else if(keyflag == SINITF && int temp[pt] == '}'){
				if(strict != 0)
					putspace(' ', NO);
				putch(c, NO);
				getnl();
				doOUT();
				keyflag = DATADEFF;
				temp[pt] = byte 0;
				pt = getnext(0);
			}
			outs(ind[clevidx].tabs);
			clevidx--;
			if(clevidx < 0)
				clevidx = 0;
			ptabs(ind[clevidx].tabs);
			putch(c, NO);
			lbegin = 0;
			lptr := lookuptemp(pt, lastplace+1);
			cend := int temp[pt];
			if(cend == ';' || cend == ','){
				putch(cend, NO);
				temp[pt] = byte 0;
				lastplace = pt;
			}
			ct := getnl();
			if((dolevel != 0 && ind[clevidx].tabs <= dotabs[dolevel]) || structlev != 0 ||
			   (lptr != -1 && keytype[lptr] == ELSEK && ind[clevidx].pdepth == 0)){
				if(cend == ';')
					doOUTK();
				else if(strict != 0 || (lptr != -1 && keytype[lptr] == ELSEK && ct == 0)){
					putspace(' ', NO);
					eatspace();
				} else if(lptr != -1 && keytype[lptr] == ELSEK)
					doOUTK();
				if(structlev != 0){
					structlev--;
					keyflag = DATADEFF;
				}
			} else {
				doOUTK();
				if(strict != 0 && ind[clevidx].tabs == 0){
					cc := getch();
					if(cc != '\n'){
						emitbyte('\n');
						emitbyte('\n');
						unget(cc);
					} else {
						lineno++;
						emitbyte('\n');
						cc = getch();
						if(cc != '\n')
							unget(cc);
						else
							lineno++;
						emitbyte('\n');
					}
				}
			}
			if(lptr != -1 && keytype[lptr] == ELSEK && ind[clevidx].pdepth != 0)
				UNBUMP();
			if(lptr == -1 || keytype[lptr] != ELSEK){
				ind[clevidx].iflev = 0;
				if(dolevel != 0 && docurly[dolevel] == NO && ind[clevidx].tabs == dotabs[dolevel]+1)
					ind[clevidx].tabs--;
				else if(ind[clevidx].pdepth != 0)
					UNBUMP();
			}
			continue;
		'(' =>
			paren++;
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				if(!(keytype[lptr] == TYPEK || keytype[lptr] == STRUCTK))
					keyflag = KEYWORDF;
				if(strict != 0){
					putspace(keypunc[lptr], NO);
					opflag = 1;
				}
				putch(c, NO);
				if(keytype[lptr] == IFK)
					gotif();
			} else {
				putch(c, NO);
				lastlook = p;
				opflag = 1;
			}
			continue;
		')' =>
			paren--;
			if(paren < 0)
				paren = 0;
			putch(c, NO);
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				if(keytype[lptr] == TYPEK || keytype[lptr] == STRUCTK)
					opflag = 1;
			} else if(keyflag == DATADEFF)
				opflag = 1;
			else
				opflag = 0;
			outs(ind[clevidx].tabs);
			pt := getnext(1);
			ct := getnl();
			if(ct == 1 && strict == 0){
				if(dolevel != 0 && ind[clevidx].tabs <= dotabs[dolevel])
					resetdo();
				if(ind[clevidx].tabs > 0 && (paren != 0 || keyflag == 0)){
					if(join != 0){
						eatspace();
						putch(' ', YES);
						continue;
					} else {
						doOUT();
						split = 1;
						continue;
					}
				} else if(ind[clevidx].tabs > 0 && int temp[pt] != '{')
					BUMP();
				doOUTK();
			} else if(strict != 0){
				if(ind[clevidx].tabs == 0){
					tc := int temp[pt];
					if(tc != ';' && tc != ',' && tc != '(' && tc != '[')
						doOUTK();
				} else {
					if(keyflag == KEYWORDF && paren == 0){
						if(dolevel != 0 && ind[clevidx].tabs <= dotabs[dolevel]){
							resetdo();
							eatspace();
							continue;
						}
						if(int temp[pt] != '{'){
							BUMP();
							doOUTK();
						} else {
							temp[pt] = byte 0;
							eatspace();
							unget('{');
						}
					} else if(ct != 0){
						if(paren != 0){
							if(join != 0)
								eatspace();
							else {
								split = 1;
								doOUT();
							}
						} else
							doOUTK();
					}
				}
			} else if(dolevel != 0 && ind[clevidx].tabs <= dotabs[dolevel])
				resetdo();
			continue;
		' ' or '\t' =>
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				if(!(keytype[lptr] == TYPEK || keytype[lptr] == STRUCTK))
					keyflag = KEYWORDF;
				else if(paren == 0)
					keyflag = DATADEFF;
				if(strict != 0){
					if(keytype[lptr] != ELSEK){
						if(keytype[lptr] == TYPEK){
							if(paren != 0)
								putch(' ', YES);
						} else
							putch(keypunc[lptr], NO);
						eatspace();
					}
				} else
					putch(c, YES);
				if(keytype[lptr] == CASEK){
					outs(ind[clevidx].tabs-1);
					continue;
				} else if(keytype[lptr] == ELSEK){
					pt := getnext(1);
					eatspace();
					cc := getch();
					if(cc == '\n' && strict == 0)
						unget(cc);
					else {
						unget(cc);
						if(checkif(pt))
							continue;
					}
					gotelse();
					if(strict != 0)
						unget(c);
					if(getnl() == 1 && strict == 0){
						doOUTK();
						if(int temp[pt] != '{')
							BUMP();
					} else if(strict != 0){
						if(int temp[pt] != '{'){
							doOUTK();
							BUMP();
						}
					}
					continue;
				} else if(keytype[lptr] == IFK){
					gotif();
					continue;
				} else if(keytype[lptr] == DOK){
					gotdo();
					pt := getnext(1);
					if(int temp[pt] != '{'){
						eatallsp();
						doOUTK();
						docurly[dolevel] = NO;
						dopdepth[dolevel] = ind[clevidx].pdepth;
						ind[clevidx].pdepth = 0;
						ind[clevidx].tabs++;
					}
					continue;
				} else if(keytype[lptr] == TYPEK){
					if(paren != 0)
						continue;
					if(strict == 0)
						continue;
					gottype(lptr);
					continue;
				} else if(keytype[lptr] == STRUCTK){
					gotstruct();
					continue;
				}
			} else if(lbegin == 0 || p > 0){
				if(strict != 0)
					putch(c, NO);
				else
					putch(c, YES);
			}
			continue;
		';' =>
			putch(c, NO);
			if(paren != 0){
				if(strict != 0){
					putch(' ', YES);
					eatspace();
				}
				opflag = 1;
				continue;
			}
			outs(ind[clevidx].tabs);
			pt := getnext(0);
			lptr := lookuptemp(pt, lastplace+1);
			if(lptr == -1 || keytype[lptr] != ELSEK){
				ind[clevidx].iflev = 0;
				if(ind[clevidx].pdepth != 0)
					UNBUMP();
				if(dolevel != 0 && docurly[dolevel] == NO && ind[clevidx].tabs <= dotabs[dolevel]+1)
					ind[clevidx].tabs--;
			}
			getnl();
			doOUTK();
			continue;
		'\n' =>
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				pt := getnext(1);
				if(keytype[lptr] == ELSEK){
					if(strict != 0)
						if(checkif(pt))
							continue;
					gotelse();
					doOUTK();
					if(int temp[pt] != '{')
						BUMP();
				} else if(keytype[lptr] == DOK){
					doOUTK();
					gotdo();
					if(int temp[pt] != '{'){
						docurly[dolevel] = NO;
						dopdepth[dolevel] = ind[clevidx].pdepth;
						ind[clevidx].pdepth = 0;
						ind[clevidx].tabs++;
					}
				} else {
					doOUTK();
					if(keytype[lptr] == STRUCTK)
						gotstruct();
				}
			} else if(p == 0)
				emitbyte('\n');
			else {
				if(ind[clevidx].tabs > 0 && (paren != 0 || keyflag == 0)){
					if(join != 0){
						putch(' ', YES);
						eatspace();
						continue;
					} else {
						doOUT();
						split = 1;
						continue;
					}
				} else if(keyflag == KEYWORDF){
					doOUTK();
					continue;
				}
				doOUT();
			}
			continue;
		'"' or '\'' =>
			putch(c, NO);
			cc := getch();
			while(cc != c){
				if(cc == Beof)
					cberror("\" or '");
				putch(cc, NO);
				if(cc == '\\')
					putch(getch(), NO);
				if(cc == '\n'){
					outs(ind[clevidx].tabs);
					lbegin = 1;
					count = 0;
				}
				cc = getch();
			}
			putch(cc, NO);
			opflag = 0;
			if(getnl() == 1)
				unget('\n');
			continue;
		'\\' =>
			putch(c, NO);
			putch(getch(), NO);
			continue;
		'?' =>
			question = 1;
			gotop(c);
			continue;
		':' =>
			cc := getch();
			if(cc == ':'){
				putch(c, NO);
				putch(cc, NO);
				continue;
			}
			unget(cc);
			if(question == 1){
				question = 0;
				gotop(c);
				continue;
			}
			putch(c, NO);
			if(structlev != 0)
				continue;
			lptr := lookupstr(lastlook, p);
			if(lptr != -1){
				if(keytype[lptr] == CASEK)
					outs(ind[clevidx].tabs - 1);
			} else {
				lbegin = 0;
				outs(ind[clevidx].tabs);
			}
			getnl();
			doOUTK();
			continue;
		'/' =>
			cc := getch();
			if(cc == '/'){
				putch(c, NO);
				putch(cc, NO);
				cppcomment(YES);
				doOUT();
				lastlook = -1;
				continue;
			} else if(cc != '*'){
				unget(cc);
				gotop(c);
				continue;
			}
			putch(c, NO);
			putch(cc, NO);
			ccval := comment(YES);
			if(getnl() == 1){
				if(ccval == 0)
					doOUT();
				else {
					outs(0);
					emitbyte('\n');
					lbegin = 1;
					count = 0;
				}
				lastlook = -1;
			}
			continue;
		'[' =>
			putch(c, NO);
			ct := 0;
			cc := getch();
			while(cc != ']' || ct > 0){
				if(cc == Beof)
					cberror("]");
				putch(cc, NO);
				if(cc == '[')
					ct++;
				if(cc == ']')
					ct--;
				cc = getch();
			}
			putch(cc, NO);
			continue;
		'#' =>
			putch(c, NO);
			cc := getch();
			while(cc != '\n'){
				if(cc == Beof)
					cberror("newline");
				if(cc == '\\'){
					putch(cc, NO);
					cc = getch();
				}
				putch(cc, NO);
				cc = getch();
			}
			putch(cc, NO);
			lbegin = 0;
			outs(ind[clevidx].tabs);
			lbegin = 1;
			count = 0;
			continue;
		* =>
			if(c == ','){
				opflag = 1;
				putch(c, YES);
				if(strict != 0){
					cc := getch();
					if(cc != ' ')
						unget(cc);
					if(cc != '\n')
						putch(' ', YES);
				}
			} else if(isop(c))
				gotop(c);
			else {
				if(isalnum(c) && lastlook == -1)
					lastlook = p;
				if(isdigit(c)){
					putch(c, NO);
					cc := input.getb();
					while(isdigit(cc) || cc == '.'){
						putch(cc, NO);
						cc = input.getb();
					}
					if(cc == 'e'){
						putch(cc, NO);
						cc = input.getb();
						putch(cc, NO);
						cc = input.getb();
						while(isdigit(cc)){
							putch(cc, NO);
							cc = input.getb();
						}
					}
					input.ungetb();
				} else
					putch(c, NO);
				if(keyflag != DATADEFF)
					opflag = 0;
			}
		}
	}
}

# --- entry points ---
dowork(argv: list of string): (int, string)
{
	strict = 0;
	join = 0;
	maxleng = LINELENGDEFAULT;
	maxtabs = MAXTABSDEFAULT;

	rest := argv;
	while(rest != nil){
		w := hd rest;
		if(len w < 2 || w[0] != '-')
			break;
		rest = tl rest;
		i := 1;
		while(i < len w){
			ch := w[i];
			i++;
			case ch {
			'j' =>
				join = 1;
			's' =>
				strict = 1;
			'l' =>
				v: string;
				if(i < len w){
					v = w[i:];
					i = len w;
				} else if(rest != nil){
					v = hd rest;
					rest = tl rest;
				} else
					return (-1, "usage: cb [-sj] [-l width]");
				n := 0;
				for(j := 0; j < len v; j++){
					if(v[j] < '0' || v[j] > '9')
						return (-1, "usage: cb [-sj] [-l width]");
					n = n*10 + (v[j]-'0');
				}
				maxleng = n;
				maxtabs = maxleng/TABLENG - 2;
				maxleng -= (maxleng+5)/10;
			* =>
				return (-1, "usage: cb [-sj] [-l width]");
			}
		}
	}
	if(rest != nil)
		return (-1, "usage: cb [-sj] [-l width]");
	work();
	return (0, "");
}

run(argv: list of string, input0: array of byte): array of byte
{
	loadmods();
	resetstate();
	input = bufio->aopen(input0);
	outbuf = nil;
	capturing = 1;
	(ok, msg) := dowork(argv);
	capturing = 0;
	if(ok < 0)
		fail(msg);

	n := len outbuf;
	r := array[n] of byte;
	i := n;
	for(l := outbuf; l != nil; l = tl l)
		r[--i] = hd l;
	return r;
}

init(ctxt: ref Context, argv: list of string)
{
	loadmods();
	stderr = sys->fildes(2);
	fdout = sys->fildes(1);
	capturing = 0;

	# parse flags (same hand-rolled bundling parser as run(), but
	# operating on the real argv, and needing the real file list
	# afterward - separated from dowork() so the file-opening loop
	# below can see the operand list too).
	resetstate();
	if(argv != nil)
		argv = tl argv;
	rest := argv;
	while(rest != nil){
		w := hd rest;
		if(len w < 2 || w[0] != '-')
			break;
		rest = tl rest;
		i := 1;
		while(i < len w){
			ch := w[i];
			i++;
			case ch {
			'j' =>
				join = 1;
			's' =>
				strict = 1;
			'l' =>
				v: string;
				if(i < len w){
					v = w[i:];
					i = len w;
				} else if(rest != nil){
					v = hd rest;
					rest = tl rest;
				} else
					fail("usage: cb [-sj] [-l width]");
				n := 0;
				for(j := 0; j < len v; j++){
					if(v[j] < '0' || v[j] > '9')
						fail("usage: cb [-sj] [-l width]");
					n = n*10 + (v[j]-'0');
				}
				maxleng = n;
				maxtabs = maxleng/TABLENG - 2;
				maxleng -= (maxleng+5)/10;
			* =>
				fail("usage: cb [-sj] [-l width]");
			}
		}
	}

	# main()'s own file loop never resets cb.h's globals between
	# files given on one command line - preserved exactly, see this
	# file's own header comment.
	if(rest == nil){
		input = bufio->fopen(sys->fildes(0), Bufio->OREAD);
		work();
	} else {
		for(l := rest; l != nil; l = tl l){
			fname := hd l;
			fd := sys->open(fname, Sys->OREAD);
			if(fd == nil)
				fail("can't open input file "+fname);
			input = bufio->fopen(fd, Bufio->OREAD);
			work();
		}
	}
}
