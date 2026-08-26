implement Pr;

# A structural Limbo translation of Plan 9's real pr(1) -
# sys/src/cmd/pr.c in the 9front tree, 666 lines. Previously read and
# left BLOCKED (see doc/plan9-port.md's earlier entry): no working
# 9front build on this machine, and plan9port ships a same-named
# src/cmd/pr.c that looked like it might be another split.c-class
# divergence. Checked directly this time, not assumed: diffing the two
# sources finds only `NFILES 20` vs `10`, three `Blethal()` calls
# 9front has and plan9port doesn't (a Plan-9-only bio "this fd dies on
# exec" marker, portability noise, not algorithm), and two `#define
# err pr_err`/`#define getdate prgetdate` collision-avoidance macros
# plan9port adds for its shared libc. None of that touches the actual
# formatting/pagination algorithm - plan9port's pr binary runs the same
# algorithm as 9front's, so it is a genuine, faithful oracle here, not
# a workaround.
#
# THE ORACLE MECHANISM: this emu provides a real host-command-
# execution device, #C (see man/3/cmd, emu/port/devcmd.c) - checked
# directly, not assumed, after the user pointed it out. It runs a host
# process in the HOST's own filesystem namespace (not Inferno's), with
# its stdin/stdout/stderr reachable through synthetic files under
# /cmd/n/. prtest.b uses this to run plan9port's real pr binary on
# identical input and byte-diff its output against this translation's
# own - a stronger check than any hand-derived expectation, and used
# throughout development, not just as a final pass. (This corrects
# tar.b's own header comment, which said flatly "no fork/exec anywhere
# Limbo can reach" - true at the Sys-module level, checked by grep, but
# too broad: the capability exists via #C. It stayed unused there
# because #C runs in the host's namespace, which is awkward for
# piping an Inferno-side archive stream through a host compressor -
# not because the mechanism doesn't exist.)
#
# STRUCTURE, checked before writing anything: findopt() gates the
# multi-column Buffer/Colpts machinery on `Ncols != 1 && Multi == 0`.
# So there are three distinct execution shapes sharing one get()/put()
# core: `pr file` (Ncols==1, no Buffer, get() reads straight from the
# one open file's own one-rune lookahead); `pr -m a b` (Multi=='m' or
# 'a', no Buffer, one column per real open Fil); `pr -2 file` (the full
# page-buffering machinery: nexbuf() reads a whole page's worth of
# runes into one flat buffer up front, Colpts slices it into per-column
# ranges, get() reads column-interleaved from that buffer, balance()
# re-slices the last page's ranges evenly if -b/-n asked for it).
# Translated and verified against the oracle in that order - simplest
# shape first, since it validates get()/put()/putspace()/putpage(),
# which is most of this file's coupled state, before the pointer-
# arithmetic-heavy Buffer/Colpts machinery is even reached.
#
# Colpts[i].c_ptr/c_ptr0 are raw Rune* into one flat C array in the
# original, with a column's END defined as *the next column's START*
# (`p->c_ptr >= (p+1)->c_ptr0`) - Colpts is sized Ncols+1 precisely so
# Colpts[Ncols] is a valid sentinel one past the last real column.
# Translated as `array of ref Colp` (int indices into a shared `array
# of int Buffer`, not string/array slices, which would copy - Colp
# must be `ref` since get()/nexbuf()/balance() all mutate a column's
# ptr/lno through aliases of the same entry) with integer indices
# standing in for the raw pointers, same aliasing, no unsafe pointer
# arithmetic needed since Limbo bounds-checks array indices anyway.
#
# A REAL BUG IN THE SOURCE, found by reading it and CONFIRMED against
# the oracle, not just reasoned about: findopt()'s `case 'n':` falls
# through into `case 'b':` with no `continue` in between (every other
# case ends with one) - so `-n` (line numbering) unconditionally also
# sets `Balance = 1`, as an apparent copy-paste/missing-continue
# mistake. Confirmed empirically: `pr -3 -l15` on a 20-line file
# leaves its last page ragged (one item per line, unbalanced), but
# `pr -n -3 -l15` on the same file balances that same last page across
# all 3 columns, with no -b given at all. Limbo's `case` has no
# fallthrough, so this is reproduced explicitly (`Balance = 1;`
# duplicated at the end of the 'n' arm) rather than silently "fixed"
# by omission, per this tree's translate-what's-there discipline (see
# file.c's dict[] bug, tar.c's uname/gname bug for the precedent).
#
# A SECOND, VESTIGIAL finding, found by reading, not by testing: the
# `err`/`Lasterr`/`Err` linked-list "deferred error message" mechanism
# the header comment above the real mustopen() describes ("defer
# message about failure to open file to prevent messing up alignment
# of page with tear perforations") is never actually populated
# anywhere in the file - grepped for every assignment to `Lasterr`/
# `e_nextp`, found none. `mustopen()`'s own failure path prints
# directly via `cerror()` at the point of failure, not deferred at
# all; `errprint()` in practice only flushes output and walks an
# always-empty list. Translated as what it actually does (a flush,
# nothing else), not as a deferred-error mechanism that was never
# wired up.
#
# getdate()'s C builds the page-header date/time by reusing ctime()'s
# fixed-width 26-byte buffer at hand-picked offsets (HEAD's own
# `date+4`/`date+24`) to pull "Mmm dd hh:mm" and "yyyy" out of it
# without a proper date-formatting call. Inferno's Daytime module hands
# back a structured Tm (year/mon/mday/hour/min already split out, see
# module/daytime.m) - this translation formats those fields directly
# with a small month-name table rather than reimplementing ctime()'s
# fixed-width string layout just to slice it apart again; same
# displayed content, no offset-slicing needed. Daytime->text()'s own
# format ("Sat Jan  1 13:00:00 GMT 2000") was checked and rejected for
# this specifically because it inserts a variable-length zone name
# before the year, breaking any fixed-offset slice.
#
# Bio's own output buffering (`Binit(&bout, 1, OWRITE)`, the various
# `Bflush(&bout)` calls) has no equivalent here: every "flush point" in
# the original existed to manage that buffer's own timing, not to
# affect what's printed - dropped as a no-op simplification, replaced
# by the same emit()/capturing/outbuf convention every other p9/cmd
# translation in this tree uses for its in-process test seam.
#
# Post-review fixes (advisor caught both, neither found by the 13
# original cases): Colw was declared mid-file with no reset in
# resetstate() - harmless for a single run() but a latent test-
# isolation bug once run() is called repeatedly in one process (this
# is exactly what prtest.b does), since findopt()'s own "bad option"
# fail() path returns before Colw is (re)assigned. Moved up with the
# other globals and reset explicitly, same as peekc already was.
# Separately, get()'s Etabn/peekc input-tab-expansion branch - the
# trickiest state in this file, since peekc holds a *count* rather
# than a flag - had never been exercised by any case with a real tab
# in it; T13/T14 in prtest.b now do, one explicitly (-e4) and one via
# findopt()'s own implicit Etabn=DEFTAB-when-multicolumn rule. Also
# checked, not just assumed: plan9port's own pr on a bad option writes
# the same single stray '\n' to stdout that fail()'s boutc('\n') does
# here, confirmed by running it directly - so that trailing-newline
# behavior is faithful too, not an oversight.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
	Tm: import daytime;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Pr: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the real command line minus the
	# program name (matching every other p9/cmd translation's `tl
	# argv`). Returns captured stdout and 1 on success; a hard failure
	# raises "fail:pr" and propagates uncaught, same convention as
	# patch.b/tar.b's own run().
	run:	fn(argv: list of string): (string, int);
};

stdin, stderr: ref FD;
capturing:	int;
outbuf:		string;

boutstr(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

boutc(c: int)
{
	boutstr(sys->sprint("%c", c));
}

warn(msg: string)
{
	sys->fprint(stderr, "pr: %s", msg);
}

fail(msg: string)
{
	warn(msg);
	boutc('\n');
	raise "fail:pr";
}

ISPRINT(c: int): int
{
	return c >= ' ';
}

ESC:		con 16r1b;
LENGTH:		con 66;
LINEWDEF:	con 72;
NUMWDEF:	con 5;
MARGINDEF:	con 10;
DEFTAB:		con 8;
NFILES:		con 20;
EMPTYMSG:	con " -- empty file";

Fil: adt
{
	iob:	ref Iobuf;
	name:	string;
	nextc:	int;
};

Colp: adt
{
	ptr:	int;	# index into Buffer
	ptr0:	int;	# index into Buffer - this column's own start
	lno:	int;
};

# global state - names kept identical to the original's own globals
# wherever no Limbo reserved-word collision applies, so this reads
# side by side with pr.c directly.
Balance, Dblspace, Etabn, Formfeed, Fpage, Inpos, Itabn,
	Lcolpos, Len, Line, Linew, Margin, Ncols, Nfiles,
	Nspace, Numw, Offset, Outpos, Padodd, Page, Pcolpos, Plength,
	Sepc, Lnumb, error, Cc: int;
Multi:		int;	# 0, 'a', or 'm'
Etabc, Itabc, Nsepc: int;
Head:		string;
Files:		array of ref Fil;
Buffer:		array of int;
Colpts:		array of ref Colp;
Colw:		int;	# per-column width, set by findopt() - kept with
			# the other globals and reset alongside them since
			# run() calls findopt()/mainpr() repeatedly in one
			# process (prtest.b's 13 cases); findopt()'s own
			# "bad option" fail() path returns before Colw would
			# be (re)assigned, so a stale value could otherwise
			# leak into the next run() if that path is ever
			# exercised in the same process.

resetstate()
{
	Balance = 0;
	Dblspace = 1;
	Etabc = '\t';
	Etabn = 0;
	Formfeed = 0;
	Fpage = 1;
	Head = nil;
	Inpos = 0;
	Itabc = '\t';
	Itabn = 0;
	Lcolpos = 0;
	Len = LENGTH;
	Line = 0;
	Linew = 0;
	Lnumb = 0;
	Margin = MARGINDEF;
	Multi = 0;
	Ncols = 1;
	Nfiles = 0;
	Nsepc = '\t';
	Nspace = 0;
	Numw = 0;
	Offset = 0;
	Outpos = 0;
	Padodd = 0;
	Page = 0;
	Pcolpos = 0;
	Plength = 0;
	Sepc = 0;
	error = 0;
	Cc = 0;
	Files = array[NFILES] of ref Fil;
	for(fsi := 0; fsi < NFILES; fsi++)
		Files[fsi] = ref Fil(nil, nil, 0);
	Buffer = nil;
	Colpts = nil;
	Colw = 0;
	peekc = 0;
}

isdigitc(c: int): int
{
	return c >= '0' && c <= '9';
}

tolowerc(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c + ('a' - 'A');
	return c;
}

# atoix: scans a decimal-digit run starting right after `pos`, returns
# (value, newpos) where newpos is the LAST digit consumed (pos
# unchanged if there were no digits) - matches the original's own
# *++*p-then-(*p)-- convention exactly, just as (string, index) rather
# than raw pointer arithmetic.
atoix(word: string, pos: int): (int, int)
{
	n := 0;
	p := pos;
	while(p+1 < len word && isdigitc(word[p+1])){
		p++;
		n = 10*n + (word[p] - '0');
	}
	return (n, p);
}

# intopt: TABS-style optional-char-then-optional-digit-run parse for
# -e/-i/-n. Returns (optchar-or-0, value-or-minus1, newpos).
intopt(word: string, pos: int): (int, int, int)
{
	optchar := 0;
	p := pos;
	if(p+1 < len word && !isdigitc(word[p+1])){
		optchar = word[p+1];
		p++;
	}
	(n, p2) := atoix(word, p);
	if(n == 0)
		n = -1;
	return (optchar, n, p2);
}

# findopt: the original's own option scanner, walking one argv word's
# characters at a time (so "-3n" really does set Ncols=3 then line
# numbering in one word, confirmed against the oracle) - not a
# generic bundled-flags parser. Returns the remaining file arguments,
# in original order.
findopt(rawargs: list of string): list of string
{
	rfiles: list of string = nil;
	args := rawargs;
	while(args != nil){
		word := hd args;
		args = tl args;
		if(len word == 0 || (word[0] != '-' && word[0] != '+')){
			rfiles = word :: rfiles;
			continue;
		}
		if(word[0] == '-' && len word == 1){
			# a bare "-": a filename (stdin marker), not an option -
			# matches the original's own `case '-': if(*++*argv=='\0')
			# break;` falling out of the option scanner entirely.
			rfiles = word :: rfiles;
			continue;
		}
		pos := 1;
		c := word[pos];
		for(;;){
			if(isdigitc(c)){
				(n, newpos) := atoix(word, pos-1);
				Ncols = n;
				pos = newpos;
			} else {
				lc := tolowerc(c);
				case lc {
				'+' =>
					(n, newpos) := atoix(word, pos);
					if(n < 1)
						n = 1;
					Fpage = n;
					pos = newpos;
				'd' =>
					Dblspace = 2;
				'e' =>
					(oc, n, newpos) := intopt(word, pos);
					if(oc != 0)
						Etabc = oc;
					if(n <= 0)
						n = DEFTAB;
					Etabn = n;
					pos = newpos;
				'f' =>
					Formfeed++;
				'h' =>
					if(args != nil){
						Head = hd args;
						args = tl args;
					}
				'i' =>
					(oc, n, newpos) := intopt(word, pos);
					if(oc != 0)
						Itabc = oc;
					if(n <= 0)
						n = DEFTAB;
					Itabn = n;
					pos = newpos;
				'l' =>
					(n, newpos) := atoix(word, pos);
					Len = n;
					pos = newpos;
				'a' or 'm' =>
					Multi = lc;
				'o' =>
					(n, newpos) := atoix(word, pos);
					Offset = n;
					pos = newpos;
				's' =>
					if(pos+1 < len word){
						Sepc = word[pos+1];
						pos++;
					} else
						Sepc = '\t';
				't' =>
					Margin = 0;
				'w' =>
					(n, newpos) := atoix(word, pos);
					Linew = n;
					pos = newpos;
				'n' =>
					Lnumb++;
					(oc, n, newpos) := intopt(word, pos);
					if(oc != 0)
						Nsepc = oc;
					Numw = n;
					if(Numw <= 0)
						Numw = NUMWDEF;
					pos = newpos;
					# preserved bug: the original's own case 'n' falls
					# through into case 'b' with no `continue` between
					# them - see this file's header comment.
					Balance = 1;
				'b' =>
					Balance = 1;
				'p' =>
					Padodd = 1;
				* =>
					fail("bad option");
				}
			}
			pos++;
			if(pos >= len word)
				break;
			c = word[pos];
		}
	}

	# rfiles was consed in reverse - restore argv order
	files: list of string = nil;
	for(; rfiles != nil; rfiles = tl rfiles)
		files = hd rfiles :: files;

	if(Len == 0)
		Len = LENGTH;
	if(Len <= Margin)
		Margin = 0;
	Plength = Len - Margin/2;
	if(Multi == 'm')
		Ncols = len files;
	case Ncols {
	0 =>
		Ncols = 1;
	1 =>
		;
	* =>
		if(Etabn == 0)
			Etabn = DEFTAB;
	}
	if(Linew == 0){
		if(Ncols != 1 && Sepc == 0)
			Linew = LINEWDEF;
		else
			Linew = 512;
	}
	if(Lnumb){
		if(Multi == 'm')
			Linew -= Numw;
		else
			Linew -= Numw*Ncols;
	}
	Colw = (Linew - Ncols + 1)/Ncols;
	if(Colw < 1)
		fail("width too small");
	if(Ncols != 1 && Multi == 0){
		buflen := (Plength/Dblspace + 1) * (Linew+1);
		Buffer = array[buflen] of int;
		Colpts = array[Ncols+1] of ref Colp;
		for(cpi := 0; cpi <= Ncols; cpi++)
			Colpts[cpi] = ref Colp(0, 0, 0);
	}
	return files;
}

# mustopen: opens a file (or, for name=="", stdin), pre-reads its
# first rune to detect an empty file. Returns nil (and records the
# error, printed immediately - see header comment on the vestigial
# deferred-error mechanism) on failure, matching the original's own
# 0-on-failure convention.
mustopen(name: string, f: ref Fil): int
{
	if(name == nil){
		f.name = nil;
		f.iob = bufio->fopen(stdin, Bufio->OREAD);
	} else {
		f.name = name;
		f.iob = bufio->open(name, Bufio->OREAD);
		if(f.iob == nil){
			warn("can't open "+name+"\n");
			error = 1;
			return 0;
		}
	}
	f.nextc = f.iob.getc();
	if(f.nextc == Bufio->EOF && Multi != 'm'){
		warn(f.name+EMPTYMSG+"\n");
		error = 1;
		return 0;
	}
	return 1;
}

# getdate: the file's own mtime if exactly one real file was named,
# else "now" - see header comment on why this formats Daytime's own
# Tm fields directly rather than reproducing ctime()'s fixed-offset
# string layout.
monthname := array[] of {"Jan","Feb","Mar","Apr","May","Jun",
	"Jul","Aug","Sep","Oct","Nov","Dec"};

fmtdate(tm: ref Tm): (string, string)
{
	return (sys->sprint("%s %2d %2.2d:%2.2d", monthname[tm.mon], tm.mday, tm.hour, tm.min),
		sys->sprint("%4d", tm.year+1900));
}

getdate(): (string, string)
{
	secs: int;
	if(Nfiles > 1 || Files[0].name == nil)
		secs = daytime->now();
	else {
		(sok, d) := sys->stat(Files[0].name);
		if(sok < 0)
			secs = 0;
		else
			secs = d.mtime;
	}
	return fmtdate(daytime->local(secs));
}

# nexbuf: fills Buffer with one whole page's worth of runes, sliced
# per-column via Colpts - the multi-column path's own page-at-a-time
# lookahead. Buffer holds -1 (Bufio->EOF) as its own end-of-input
# sentinel, same as the original's raw Rune* buffer did.
nexbuf()
{
	s := 0;	# index into Buffer
	pi := 0;	# index into Colpts
	bline := 0;
	for(;;){
		Colpts[pi].ptr0 = s;
		Colpts[pi].ptr = s;
		if(pi == Ncols)
			return;
		Colpts[pi].lno = Lnumb + bline;
		pi++;
		# bline only increments once a line is FULLY read (right after
		# the '\n' break below) - matching the original's own for-
		# loop update-expression (`bline++`), which likewise only runs
		# after a normal iteration completes, never after the EOF
		# path's early `return`. An earlier draft incremented bline up
		# front instead, off by one whenever EOF landed mid-attempt -
		# found via balance()'s line numbering going visibly wrong
		# under -n, not by re-reading this loop a second time.
		for(j := (Len - Margin)/Dblspace; j > 0; j--){
			Inpos = 0;
			for(;;){
				c := Files[0].iob.getc();
				if(c == Bufio->EOF){
					Buffer[s] = -1;
					for(; pi <= Ncols; pi++){
						Colpts[pi].ptr0 = s;
						Colpts[pi].ptr = s;
					}
					if(Balance)
						balance(bline);
					return;
				}
				if(ISPRINT(c))
					Inpos++;
				if(Inpos <= Colw || c == '\n'){
					Buffer[s] = c;
					s++;
					if(s >= len Buffer)
						fail("page-buffer overflow");
				}
				if(c == '\n')
					break;
				if(c == '\b'){
					if(Inpos == 0)
						s--;
					if(Inpos > 0)
						Inpos--;
				} else if(c == ESC){
					if(Inpos > 0)
						Inpos--;
				}
			}
			bline++;
		}
	}
}

# balance: re-slices the last page's Colpts evenly across all columns
# - only reached when nexbuf() hits EOF partway through a page and
# Balance is set (by -b, or by the preserved -n fallthrough bug).
balance(bline0: int)
{
	s := 0;
	pi := 0;
	colno := 0;
	bline := bline0;
	c := bline % Ncols;
	l := (bline + Ncols - 1)/Ncols;
	bline = 0;
	do{
		for(j := 0; j < l; j++){
			while(Buffer[s] != '\n')
				s++;
			s++;	# advance past the '\n' itself, matching the
				# original's own `while(*s++ != '\n')` post-
				# increment - Limbo has no post-increment operator,
				# so this is spelled out as its own statement.
		}
		pi++;
		bline += l;
		Colpts[pi].lno = Lnumb + bline;
		Colpts[pi].ptr0 = s;
		Colpts[pi].ptr = s;
		colno++;
		if(colno == c)
			l--;
	} while(colno < Ncols - 1);
}

# get: the shared character-source for both the streaming (no Buffer)
# and page-buffered (Buffer set) paths, plus tab expansion and the
# Inpos (line-position) bookkeeping put() depends on.
peekc: int;

get(colno: int): int
{
	c: int;
	if(peekc){
		peekc = 0;
		c = Etabc;
	} else if(Buffer != nil){
		p := Colpts[colno];
		p1 := Colpts[colno+1];
		if(p.ptr >= p1.ptr0)
			c = -1;
		else {
			c = Buffer[p.ptr];
			if(c != -1)
				p.ptr++;
		}
	} else {
		fi := colno;
		if(Multi == 'a')
			fi = 0;
		q := Files[fi];
		c = q.nextc;
		if(c == Bufio->EOF){
			c = -1;
			qi := Nfiles - 1;
			while(qi >= 0 && Files[qi].nextc == Bufio->EOF)
				qi--;
			if(qi >= 0)
				c = '\n';
		} else
			q.nextc = q.iob.getc();
	}
	if(Etabn != 0 && c == Etabc){
		Inpos++;
		peekc = Inpos % Etabn;
		c = ' ';
	} else if(ISPRINT(c))
		Inpos++;
	else case c {
	'\b' or ESC =>
		if(Inpos > 0)
			Inpos--;
	'\f' =>
		if(Ncols == 1)
			;
		else {
			c = '\n';
			Inpos = 0;
		}
	'\n' or '\r' =>
		Inpos = 0;
	}
	Cc = c;
	return c;
}

put(c: int)
{
	move: int;
	case c {
	' ' =>
		Nspace++;
		Lcolpos++;
		return;
	'\b' =>
		if(Lcolpos == 0)
			return;
		if(Nspace > 0){
			Nspace--;
			Lcolpos--;
			return;
		}
		if(Lcolpos > Pcolpos){
			Lcolpos--;
			return;
		}
		move = -1;
	ESC =>
		move = -1;
	'\n' =>
		Line++;
		Pcolpos = 0;
		Lcolpos = 0;
		Nspace = 0;
		Outpos = 0;
	'\r' or '\f' =>
		Pcolpos = 0;
		Lcolpos = 0;
		Nspace = 0;
		Outpos = 0;
	* =>
		move = 0;
		if(ISPRINT(c))
			move = 1;
	}
	if(Page < Fpage)
		return;
	if(Lcolpos > 0 || move > 0)
		Lcolpos += move;
	if(Lcolpos <= Colw){
		putspace();
		boutc(c);
		Pcolpos = Lcolpos;
		Outpos += move;
	}
}

putspace()
{
	while(Nspace > 0){
		nc := 1;
		if(Itabn > 0 && Nspace > 1 && Itabn - Outpos%Itabn <= Nspace){
			nc = Itabn - Outpos%Itabn;
			boutc(Itabc);
		} else
			boutstr(" ");
		Outpos += nc;
		Nspace -= nc;
	}
}

# putpage: one page, row by row, column by column. Translated as two
# nested loops matching the original's two `for` loops - the outer
# one's own update-expression (`get(0)`, run after every row) is
# reproduced explicitly at the bottom of the outer loop body rather
# than folded into a for-statement's update clause, since several
# `break`s/`return`s inside need to skip it, same as the original's
# `break` skipping a for-loop's own update expression. The three
# combined break conditions after the per-column char loop
# (`C==-1 || ++colno==Ncols || C=='\n' && get(colno)==-1`) are unpacked
# into explicit sequential statements preserving C's own short-circuit
# order: colno is only ever incremented when C!=-1 (matching `||`
# short-circuiting past `++colno` once the first clause is true), and
# the third clause's own get(colno) call uses colno already
# incremented by the second clause's side effect. The post-loop check
# is genuinely `colno == 0`, not `colno == Ncols` - it asks whether
# the row hit end-of-input before printing anything at all (a wholly
# empty page), not whether every column filled; a row that runs out
# partway through (colno>0, ragged last page) falls through to the
# ordinary end-of-row padding instead. Traced by hand, then confirmed
# against the oracle on input whose columns end at different lines.
putpage()
{
	Line = Margin/2;
	for(;;){
		Nspace = Offset;
		colno := 0;
		Outpos = 0;
		while(Cc != '\f'){
			if(Lnumb && Cc != -1 && (colno == 0 || Multi == 'a')){
				if(Page >= Fpage){
					putspace();
					lnum := Lnumb;
					if(Buffer != nil){
						lnum = Colpts[colno].lno;
						Colpts[colno].lno++;
					}
					boutstr(sys->sprint("%*d", Numw, lnum));
					Outpos += Numw;
					put(Nsepc);
				}
				Lnumb++;
			}
			Lcolpos = 0;
			Pcolpos = 0;
			while(Cc != '\n' && Cc != '\f' && Cc != -1){
				put(Cc);
				get(colno);
			}
			brk := 0;
			if(Cc == -1)
				brk = 1;
			else {
				colno++;
				if(colno == Ncols)
					brk = 1;
				else if(Cc == '\n' && get(colno) == -1)
					brk = 1;
			}
			if(brk)
				break;
			if(Sepc != 0)
				put(Sepc);
			else {
				Nspace += Colw - Lcolpos + 1;
				if(Nspace < 1)
					Nspace = 1;
			}
		}
		if(Cc == -1 && colno == 0){
			if(Margin != 0)
				break;
			return;
		}
		if(Cc == '\f')
			break;
		put('\n');
		if(Dblspace == 2 && Line < Plength)
			put('\n');
		if(Line >= Plength)
			break;
		get(0);
	}
	if(Formfeed)
		put('\f');
	else
		while(Line < Len)
			put('\n');
}

# pr: drives one file (Multi != 'm') or the whole already-opened merge
# set (Multi == 'm', name is ignored - see mainpr()'s own header
# comment on the real, easy-to-miss way merge mode reaches this
# function at all). Structured as an explicit for(;;) with the
# original's own `putpage()` for-loop update-expression reproduced at
# the two points that reach it (the Margin==0 early continue, and the
# normal fall-through) - see putpage()'s own header comment for why.
pr(name: string): int
{
	if(Multi != 'm' && mustopen(name, Files[0]) == 0)
		return 0;
	if(Buffer != nil)
		Files[0].iob.ungetc();
	if(Lnumb)
		Lnumb = 1;

	havedate := 0;
	date, datey: string;
	havehead := 0;
	head: string;
	Page = 0;
	for(;;){
		if(Cc == -1)
			break;
		if(Buffer != nil)
			nexbuf();
		Inpos = 0;
		if(get(0) == -1)
			break;
		Page++;
		if(Page >= Fpage){
			if(Margin == 0){
				putpage();
				continue;
			}
			if(!havedate){
				(date, datey) = getdate();
				havedate = 1;
			}
			if(!havehead){
				if(Head != nil)
					head = Head;
				else if(Nfiles < 2)
					head = Files[0].name;
				else
					head = nil;
				havehead = 1;
			}
			boutstr("\n\n");
			Nspace = Offset;
			putspace();
			boutstr(sys->sprint("%s %s  %s Page %d\n\n\n", date, datey, head, Page));
		}
		putpage();
	}
	if(Padodd && (Page&1) == 1){
		Line = 0;
		if(Formfeed)
			put('\f');
		else
			while(Line < Len)
				put('\n');
	}
	Cc = 0;
	return 1;
}

# mainpr: the original's own main(), minus argument parsing (findopt(),
# called separately by init()/run() before this). A real, easy-to-miss
# feature of the original, found only by tracing nfdone's two totally
# different meanings side by side: in -m (merge) mode, this loop only
# OPENS each file (mustopen() into successive Files[] slots) - it never
# calls pr() per file at all. pr() only ever gets invoked for the whole
# merge set via the SAME `pr(nil)` fallback call every other mode uses
# for "no files named, read stdin" - reached here because nfdone is
# only incremented on an OPEN FAILURE in merge mode (the original's own
# "/* suppress printing */" comment), so it stays 0 (falling through to
# pr(nil)) exactly when every merge file opened cleanly, and pr(nil)'s
# own body takes the Multi=='m' fast path around mustopen() entirely
# and prints straight from the already-opened Files[] array. The
# consequence, preserved exactly: if even one file in a merge set fails
# to open, nfdone becomes nonzero and printing is suppressed for the
# WHOLE merge operation, not just the one bad file.
mainpr(files: list of string)
{
	nfdone := 0;
	if(Multi == 'm'){
		for(fl := files; fl != nil; fl = tl fl){
			if(Nfiles >= NFILES - 1)
				fail("too many files");
			ok := mustopen(hd fl, Files[Nfiles]);
			Nfiles++;
			if(ok == 0)
				nfdone++;
		}
	} else {
		for(fl := files; fl != nil; fl = tl fl){
			if(pr(hd fl))
				Files[0].iob.close();
			nfdone++;
		}
	}
	if(nfdone == 0)
		pr(nil);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
	bufio = load Bufio Bufio->PATH;
	if(str == nil || daytime == nil || bufio == nil){
		sys->fprint(stderr, "pr: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();
	files := findopt(tl argv);
	mainpr(files);
	if(error)
		raise "fail:pr";
}

run(argv: list of string): (string, int)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(stdin == nil)
		stdin = sys->fildes(0);
	if(stderr == nil)
		stderr = sys->fildes(2);

	resetstate();
	outbuf = "";
	capturing = 1;
	files := findopt(argv);
	mainpr(files);
	capturing = 0;
	return (outbuf, !error);
}
