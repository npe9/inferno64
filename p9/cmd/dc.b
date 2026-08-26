implement Dc;

# A real, structural translation of dc(1) - Plan 9's own, from
# sys/src/cmd/dc.c (2298 lines, 9front; plan9port's copy is 2287,
# a 78-line diff that is entirely 9front-side robustness fixes -
# buffer-overflow guards, nil checks, one widened length() bound - not
# algorithm changes, confirmed by reading the diff before writing any
# Limbo, so plan9port's own real dc BINARY is a valid live oracle here,
# the same as pr's was). REPLACES the previous p9/cmd/dc.b wholesale,
# not extended from it - that file was a bounded 64-bit fixed-point
# workalike (Dnum{m:big; f:int}) reverse-engineered against the WRONG
# oracle (macOS's own /usr/bin/dc, not Plan 9's dc), per the standing
# "translate the real source, not a workalike" correction. Full scoping
# discussion: doc/plan9-port.md item 20.
#
# THE ORIGINAL'S OWN DATA MODEL, understood by reading before writing
# any Limbo: a dc number is a `Blk` - a growable byte buffer with FOUR
# cursors (rd/wt/beg/last) doing quadruple duty as (1) a base-100
# arbitrary-precision integer, digits stored LEAST SIGNIFICANT FIRST
# (buf[0] is the least significant base-100 digit), (2) a two's-
# complement-STYLE negative-number representation at that same radix
# (a leading -1 "digit" means "sign-extend with 99s from here up",
# exactly mirroring how two's complement sign-extends with 1-bits, just
# in base 100 instead of base 2 - chsign() below is a padded 100's-
# complement, not a sign bit), (3) a literal ASCII byte buffer for
# macro/string values (the `[...]` command and register contents used
# as pushed strings), and (4) - via a raw pointer-cast reinterpretation
# of the SAME struct as `Wblk` (four `Blk**` cursors instead of four
# `char*` ones) - a resizable array of Blk* for the `:`/`;` array-
# register commands. The LAST byte written into a "number" Blk is not
# a digit at all: it is dc's own decimal scale (how many actual decimal
# digits, not base-100 pairs, follow the point), popped off with
# `sunputc` before any arithmetic touches the digits themselves. This
# port keeps that same design almost verbatim (`Blk` below is an
# `array of int` plus `rd`/`wt` cursors, `beg` is always index 0 so it
# doesn't need its own field, `last` is just `len buf`) rather than
# redesigning the arithmetic around a "cleaner" representation - the
# entire file, including every genuinely tricky divide/sqrt/exponent
# routine, is written directly IN TERMS of this buffer's cursor
# operations, so translating the buffer faithfully and then porting
# each routine line-by-line on top of it is far lower-risk than
# reinventing the arithmetic from a description of what it should do.
# `int`, not `byte`, is used for buffer elements: digit values are
# 0..99 or the -1 sign-extension sentinel, and STRING/macro Blks store
# raw byte values up to 255 in that same field - both fit in `int`
# without the range worries a `byte`-typed buffer would raise.
#
# WHAT IS DELIBERATELY NOT REPRODUCED, and why each is safe to drop:
#
# - The original's own allocator (`salloc`/`morehd`/`hfree` free-list,
#   `release()` returning a Blk's header AND its backing bytes to that
#   free list) is pure C memory-management plumbing with zero
#   observable effect on any dc script's behavior - Limbo's GC makes
#   the whole mechanism unnecessary. `release()` below is kept as a
#   literal no-op function purely so every call site in this file still
#   reads line-for-line against the original (the same reasoning as
#   dropping tar.b's fixed buffers or file.b's freelist bookkeeping).
#
# - `:`/`;` (array registers) reinterpret a `Blk`'s raw bytes as a
#   `Wblk` (an array of `Blk*` slots) by literally casting the same
#   struct pointer to a different field layout, with `S`/`s` on a
#   register number >= ARRAYST padding extra `PTRSZ` bytes onto a plain
#   scalar value so it can LATER be reinterpreted the same way. That is
#   a raw memory-layout trick with no dc-script-observable meaning
#   beyond "this register holds indexable array elements" - reproduced
#   here as a genuine discriminated register kind instead (`RegVal`
#   below, `Scalar` vs `Arrv`, `array of ref Blk` for the latter),
#   which gives identical behavior for every well-formed dc script
#   (registers used consistently as either scalars or arrays) without
#   needing an actual pointer-overlay hack Limbo has no way to express
#   anyway. A script that deliberately mixes `s`/`:` on the SAME
#   register number does something genuinely undefined even in the
#   original C (the two commands make incompatible assumptions about
#   what is already stored there) - not chased further here, the same
#   as any other characterized-not-reproduced corner in this backlog.
#   The narrower version of the same mixing - `s`/`S` storing a plain
#   NUMBER into a register whose number is >= ARRAYST, i.e. one that
#   `:`/`;` could also address as an array - is handled safely rather
#   than faithfully here too: save()'s own `c >= ARRAYST` branch always
#   reads the popped value's `arrval` field (nil for an ordinary
#   number) and substitutes a fresh empty array when it's nil, rather
#   than storing the number's own digit bytes and letting a later `;`
#   reinterpret them as pointers the way the original's own pointer-
#   overlay trick would - the same crash class `t11crashsafety` (see
#   dctest.b) already documents for a different array-register misuse.
#

# - readc()'s own middle EOF-fallback branch (`if(readptr !=
#   &readptr[0]) {...}`) is DEAD CODE in the original, confirmed by
#   reading rather than assumed: `&readptr[0]` is `&(*(readptr+0))`,
#   which is just `readptr` itself, so the condition is `readptr !=
#   readptr` - always false. It is also unreachable for a second,
#   independent reason: whenever `readptr` is nonzero the FIRST `if` in
#   the loop already either returns a character or pops the exhausted
#   macro and retries from the top, so control only ever reaches the
#   `Bgetc(curfile)` call at all when `readptr` is already zero - the
#   dead branch's own guard could never fire even if its condition were
#   written correctly. Omitted here rather than translated as visible
#   dead code (the same treatment as pr.c's own unused deferred-error
#   list, a documented finding, not a silent drop).
#
# - No setjmp/longjmp anywhere in this file (unlike hoc.c, which needed
#   the flag-based redesign documented in inferno-rio-exception-frame-
#   bug) - every error path here is an ordinary `continue`/`return`
#   within a bounded, shallow call depth, so no Limbo exception is used
#   for control flow at all, avoiding that whole class of risk from the
#   start. The ONE place needing special handling is `exits(0)` (a
#   literal, immediate process termination - not a jump back to any
#   caller) called from three places: readc() hitting real EOF on the
#   real input stream with no pending macro left to fall back to, and
#   `q` popping the macro-execution stack down to its outermost level.
#   A plain `finished: int` flag (set at each of those three spots,
#   checked immediately after every readc() call and at the top of
#   commnds()'s own loop) reproduces this without any exception -
#   directly analogous to hoc.b's own `hadeerror`, and for the same
#   reason: it is arguably MORE faithful than an exception would be,
#   since `exits()` itself does not unwind any C stack frame either.
#
# - `dbg` (set whenever an unrecognized command-line flag is given) is
#   read NOWHERE else in the file - checked by grep, not assumed - a
#   confirmed dead flag. Any unrecognized flag is simply accepted and
#   ignored here too, matching the only OBSERVABLE behavior it has.
#
# - The `'Y'` debug command prints the allocator's own internal
#   counters (all/rel/headmor/nbytes/longest/active/maxsize/lall/...) -
#   entirely about the free-list allocator this port does not have.
#   Not part of dc's documented interface (no mnemonic meaning to a
#   script), so this port's own `'Y'` prints a DIFFERENT, shorter line
#   (alloc/release/copy/more call counts only - this port's own
#   salloc()/release()/copy()/more() call counters, not the original's
#   own field names or format) rather than reproducing the original's
#   three-line, dozen-field output whose fields are almost all about
#   an allocator this port does not have.
#
# Everything else - every arithmetic routine, the exact scale/rounding
# rules (confirmed against the real oracle BEFORE writing any Limbo,
# not assumed from reading the C: `2.5 1.25 *` truncates to 3.12, not
# 3.125, because multiply's natural scale is the SUM of operand scales,
# truncated toward zero once it exceeds max(k, both operand scales);
# `2.5 2^` prints 6.2, not 6.25, because exponentiation's own result
# scale is max(k, base's own scale), not scale*exponent, confirmed by
# tracing dcexp()/the `^` case by hand against the printed output
# before trusting it), the register/macro/array command set, and the
# fallback-to-stdin-after-a-file-argument behavior (confirmed directly:
# `dc file.dc` runs file.dc's commands, THEN keeps reading further
# commands from stdin rather than exiting) - is translated as literally
# as Limbo syntax allows, function by function, against this Blk model.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Dc: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching every other p9/cmd translation's
	# own convention: run the given command-line-style argument list
	# (at most one filename, exactly like the real dc) against stdin
	# text supplied separately (since dc always reads further commands
	# from stdin after any file argument runs out - see above), and
	# return whatever was written to stdout.
	run:	fn(argv: list of string, stdintext: string): string;
};

stdout, stderr: ref FD;

# --- the Blk buffer: a growable array of int with two cursors ---
#
# `beg` is always index 0 (never given its own field); `last` is
# always `len buf` (also never given its own field) - both are
# implicit rather than tracked, since this port never needs a Blk
# whose content doesn't start at its own backing array's index 0.
# Every function below is a direct translation of the C macro or
# function of the same name (see the header comment above for which
# pieces of the ORIGINAL Blk design - the allocator, the Wblk
# reinterpretation - are deliberately not reproduced).

Blk: adt
{
	buf:	array of int;
	rd:	int;
	wt:	int;
	arrval:	array of ref Blk;	# nil except for the marker Blk pushp2arr()
					# uses to carry an array-register value
					# back onto the calculator stack - see
					# pushp2arr()'s own comment. Every
					# ordinary number/string Blk leaves
					# this nil.
};

# --- allocator (see header comment: free-list machinery dropped,
# Limbo's GC makes it unnecessary; call counts kept only for 'Y') ---

allcnt, relcnt, copycnt, morecnt: int;

salloc(size: int): ref Blk
{
	allcnt++;
	return ref Blk(array[size] of int, 0, 0, nil);
}

# copy(hptr,size): a NEW block of the given capacity, holding hptr's
# current content (up to length(hptr)) at the front, zero-padded to
# `size` - Limbo's `array[n] of int` already zero-initializes, so the
# explicit C zero-padding loop needs no equivalent here.
copy(p: ref Blk, size: int): ref Blk
{
	copycnt++;
	sz := p.wt;
	nb := array[size] of int;
	n := sz;
	if(n > size)
		n = size;
	nb[0:] = p.buf[0:n];
	return ref Blk(nb, 0, sz, nil);
}

# more(hptr): the growable-block doubling used by sputc/salterc when
# they run off the end of the current backing array.
more(p: ref Blk)
{
	morecnt++;
	newsize := len p.buf * 2;
	if(newsize == 0)
		newsize = 2;
	nb := array[newsize] of int;
	nb[0:] = p.buf;
	p.buf = nb;
}

# seekc(hptr,n): reposition rd at offset n, growing the backing array
# to exactly n if it isn't big enough yet (the `:`/`;` array-index
# reposition uses this; here it also backs plain array-register growth
# via RegVal's own `arr` field, see below, rather than this exact
# byte-buffer form - kept for the Wblk-adjacent uses that still apply
# to a plain Blk, e.g. none remain after the RegVal redesign, but kept
# for structural fidelity against the original's own seekc call sites
# that operate on ordinary numeric Blks, e.g. none currently do, so
# this exists chiefly for readability parity with the source).
seekc(p: ref Blk, n: int)
{
	if(n > len p.buf){
		nb := array[n] of int;
		m := len p.buf;
		nb[0:] = p.buf[0:m];
		p.buf = nb;
		p.rd = p.wt = n;
		return;
	}
	p.rd = n;
	if(n > p.wt)
		p.wt = n;
}

release(p: ref Blk)
{
	relcnt++;
}

# --- Blk cursor primitives (direct translations of dc.c's own macros) ---

length(p: ref Blk): int
{
	return p.wt;
}

rewind(p: ref Blk)
{
	p.rd = 0;
}

bcreate(p: ref Blk)
{
	p.rd = p.wt = 0;
}

fsfile(p: ref Blk)
{
	p.rd = p.wt;
}

btruncate(p: ref Blk)
{
	p.wt = p.rd;
}

sfeof(p: ref Blk): int
{
	if(p.rd == p.wt)
		return 1;
	return 0;
}

sfbeg(p: ref Blk): int
{
	if(p.rd == 0)
		return 1;
	return 0;
}

sungetc(p: ref Blk, c: int)
{
	p.rd--;
	p.buf[p.rd] = c;
}

sgetc(p: ref Blk): int
{
	if(p.rd == p.wt)
		return -1;
	c := p.buf[p.rd];
	p.rd++;
	return c;
}

skipc(p: ref Blk)
{
	if(p.rd < p.wt)
		p.rd++;
}

slookc(p: ref Blk): int
{
	if(p.rd == p.wt)
		return -1;
	return p.buf[p.rd];
}

sbackc(p: ref Blk): int
{
	if(p.rd == 0)
		return -1;
	p.rd--;
	return p.buf[p.rd];
}

backc(p: ref Blk)
{
	if(p.rd > 0)
		p.rd--;
}

sputc(p: ref Blk, c: int)
{
	if(p.wt == len p.buf)
		more(p);
	p.buf[p.wt] = c;
	p.wt++;
}

salterc(p: ref Blk, c: int)
{
	if(p.rd == len p.buf)
		more(p);
	p.buf[p.rd] = c;
	p.rd++;
	if(p.rd > p.wt)
		p.wt = p.rd;
}

sunputc(p: ref Blk): int
{
	p.wt--;
	p.rd = p.wt;
	return p.buf[p.wt];
}

sclobber(p: ref Blk): int
{
	p.wt--;
	p.rd = p.wt;
	return p.buf[p.wt];
}

bzero(p: ref Blk)
{
	for(i := 0; i < len p.buf; i++)
		p.buf[i] = 0;
}

# --- global calculator state (kept as file-scope globals, matching
# the original's own global-heavy style directly rather than
# threading it through parameters) ---

arg1, arg2: ref Blk;
savk: int;
scalptr, basptr, tenptr, inbas: ref Blk;
sqtemp, chptr, strptr, divxyz: ref Blk;

STKSZ: con 100;
stack: array of ref Blk;
stkptr: int;			# index of the top element, 0 = empty (matches stkptr==&stack[0])

stkerr: int;
lastchar: int;

RDSKSZ: con 100;
readstk: array of ref Blk;
readptr: int;

rem: ref Blk;
k: int;
irem: ref Blk;
skd, skr: int;
neg: int;

obase: int;
logo, logten: int;
fw, fw1, ll: int;
outdit: ref fn(p: ref Blk, flg: int);
count: int;

finished: int;			# see header comment: stands in for exits(0)

curfile: ref Iobuf;
stdinbuf: ref Iobuf;
fsave: ref Iobuf;

# --- register/symbol table ---
#
# ARRAYST (221) and MAXIND (2048) match the original exactly: register
# numbers are 0..255 (`getstk()&0377`, extended past a single raw byte
# via `<N>` bracket syntax); array element indices are 0..MAXIND-1,
# read from a POPPED calculator value, not from getstk() - two
# independent numeric spaces, exactly as in the source.

ARRAYST: con 221;
MAXIND: con 2048;
LASTFUN: con 8r26;		# octal 026 in the source = 22 decimal = 'a'..'v'
TBLSZ: con 256;

RegVal: adt
{
	pick {
	Scalar =>
		blk:	ref Blk;
	Arrv =>
		arr:	array of ref Blk;	# grown on demand, see arrset() below
	}
};

Sym: adt
{
	next:	cyclic ref Sym;
	val:	ref RegVal;
};

stable: array of ref Sym;

# --- init ---

resetstate()
{
	stack = array[STKSZ] of ref Blk;
	stkptr = 0;
	stkerr = 0;
	readstk = array[RDSKSZ] of ref Blk;
	readptr = 0;
	stable = array[TBLSZ] of ref Sym;
	k = 0;
	obase = 10;
	logten = log2(10);
	ll = 70;
	fw = 1;
	fw1 = 0;
	scalptr = salloc(1);
	sputc(scalptr, 0);
	basptr = salloc(1);
	sputc(basptr, 10);
	tenptr = salloc(1);
	sputc(tenptr, 10);
	inbas = salloc(1);
	sputc(inbas, 10);
	sqtemp = salloc(1);
	sputc(sqtemp, 2);
	chptr = salloc(0);
	strptr = salloc(0);
	divxyz = salloc(0);
	outdit = bigot;
	logo = 0;
	finished = 0;
	lastchar = 0;
	neg = 0;
	rem = nil;
	irem = nil;
	allcnt = relcnt = copycnt = morecnt = 0;
	capturing = 0;
	outbuf = "";
}

# --- output, matching every other p9/cmd translation's own in-process
# test seam convention ---

capturing: int;
outbuf: string;

emits(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

outc(c: int)
{
	emits(sys->sprint("%c", c));
	count--;
	if(count == 0){
		emits("\\\n");
		count = ll;
	}
}

test2()
{
	count -= 2;
	if(count <= 0){
		emits("\\\n");
		count = ll;
	}
}

# --- stack ---

pushp(p: ref Blk)
{
	if(stkptr == STKSZ-1){
		emits("out of stack space\n");
		return;
	}
	stkerr = 0;
	stkptr++;
	stack[stkptr] = p;
}

pop(): ref Blk
{
	if(stkptr == 0){
		stkerr = 1;
		return nil;
	}
	p := stack[stkptr];
	stkptr--;
	return p;
}

# --- character-level input: readc()/unreadc(), the real-file/stdin
# layer, plus readstk[]/readptr, the macro-execution stack ---

readc(): int
{
	for(;;){
		if(readptr != 0 && readstk[readptr] != nil){
			if(!sfeof(readstk[readptr]))
				return lastchar = sgetc(readstk[readptr]);
			readstk[readptr] = nil;
			readptr--;
			continue;
		}
		lastchar = curfile.getc();
		if(lastchar != Bufio->EOF)
			return lastchar;
		# (the original's own middle EOF-fallback branch is dead code
		# here - see this file's header comment - omitted, not
		# translated)
		if(curfile != stdinbuf){
			curfile = stdinbuf;
			continue;
		}
		finished = 1;
		return 0;
	}
}

unreadc(c: int)
{
	if(readptr != 0 && readstk[readptr] != nil)
		sungetc(readstk[readptr], c);
	else
		curfile.ungetc();
}

# --- register table helpers ---

getstk(): int
{
	c := readc();
	if(finished)
		return 0;
	if(c != '<')
		return c;
	n := 0;
	for(;;){
		c = readc();
		if(finished)
			return 0;
		if(c == '>')
			break;
		n = n*10 + c - '0';
	}
	return n;
}

# arrset/arrget: grow-on-demand array-register element access,
# standing in for the original's Wblk-reinterpretation trick (see
# header comment) - identical OBSERVABLE behavior (out-of-range reads
# come back as a zero-scale zero value, same as the original's own
# "so uninitialized array elt prints as 0" comment) without needing an
# actual pointer-overlay hack.
arrget(a: array of ref Blk, i: int): ref Blk
{
	if(i < 0 || i >= len a || a[i] == nil)
		return nil;
	return a[i];
}

arrset(rv: ref RegVal, i: int, v: ref Blk): ref RegVal
{
	pick r := rv {
	Arrv =>
		if(i >= len r.arr){
			na := array[i+1] of ref Blk;
			na[0:] = r.arr;
			r.arr = na;
		}
		r.arr[i] = v;
		return rv;
	}
	na := array[i+1] of ref Blk;
	na[i] = v;
	return ref RegVal.Arrv(na);
}

# --- arithmetic ---

chsign(p: ref Blk)
{
	carry := 0;
	rewind(p);
	ct := 0;
	while(!sfeof(p)){
		ct = 100 - slookc(p) - carry;
		carry = 1;
		if(ct >= 100){
			ct -= 100;
			carry = 0;
		}
		salterc(p, ct);
	}
	if(carry != 0){
		sputc(p, -1);
		fsfile(p);
		backc(p);
		ct = sbackc(p);
		if(ct == 99){
			btruncate(p);
			sputc(p, -1);
		}
	} else {
		fsfile(p);
		ct = sbackc(p);
		if(ct == 0)
			btruncate(p);
	}
}

add(a1, a2: ref Blk): ref Blk
{
	size := length(a1);
	if(length(a2) > size)
		size = length(a2);
	p := salloc(size);
	rewind(a1);
	rewind(a2);
	carry := 0;
	while(--size >= 0){
		n1 := 0;
		if(!sfeof(a1))
			n1 = sgetc(a1);
		n2 := 0;
		if(!sfeof(a2))
			n2 = sgetc(a2);
		n := n1 + n2 + carry;
		if(n >= 100){
			carry = 1;
			n -= 100;
		} else if(n < 0){
			carry = -1;
			n += 100;
		} else
			carry = 0;
		sputc(p, n);
	}
	if(carry != 0)
		sputc(p, carry);
	fsfile(p);
	if(!sfbeg(p)){
		c := 0;
		while(!sfbeg(p) && (c = sbackc(p)) == 0)
			;
		if(c != 0)
			salterc(p, c);
		btruncate(p);
	}
	fsfile(p);
	if(!sfbeg(p) && sbackc(p) == -1){
		c := 0;
		for(;;){
			c = sbackc(p);
			if(c != 99)
				break;
			if(sfbeg(p))
				break;
		}
		skipc(p);
		salterc(p, -1);
		btruncate(p);
	}
	return p;
}

mult(p, q: ref Blk): ref Blk
{
	sign := 0;
	fsfile(p);
	mp := p;
	if(!sfbeg(p) && sbackc(p) < 0){
		mp = copy(p, length(p));
		chsign(mp);
		sign = ~sign;
	}
	fsfile(q);
	mq := q;
	if(!sfbeg(q) && sbackc(q) < 0){
		mq = copy(q, length(q));
		chsign(mq);
		sign = ~sign;
	}
	mr := salloc(length(mp)+length(mq));
	bzero(mr);
	rewind(mq);
	offset := 0;
	while(!sfeof(mq)){
		cq := sgetc(mq);
		rewind(mp);
		rewind(mr);
		mr.rd += offset;
		carry := 0;
		while(!sfeof(mp)){
			cp := sgetc(mp);
			mcr := 0;
			if(!sfeof(mr))
				mcr = slookc(mr);
			mt := cp*cq + carry + mcr;
			carry = mt/100;
			salterc(mr, mt%100);
		}
		offset++;
		if(carry != 0){
			mcr := 0;
			if(!sfeof(mr))
				mcr = slookc(mr);
			salterc(mr, mcr+carry);
		}
	}
	if(sign < 0)
		chsign(mr);
	return mr;
}

# add0(p,ct): p prefixed with ct zero base-100-DECIMAL-digits (ct
# counted in decimal digits, matching every other "n"/"sc" parameter in
# this file - odd counts need one extra ten's-place multiply at the
# end, since a base-100 digit holds two decimal digits at a time).
add0(p: ref Blk, ct: int): ref Blk
{
	q := salloc(length(p) + (ct+1)/2);
	while(ct > 1){
		sputc(q, 0);
		ct -= 2;
	}
	rewind(p);
	while(!sfeof(p))
		sputc(q, sgetc(p));
	if(ct == 1)
		return mult(tenptr, q);
	return q;
}

removc(p: ref Blk, n: int): ref Blk
{
	rewind(p);
	while(n > 1){
		skipc(p);
		n -= 2;
	}
	q := salloc(2);
	while(!sfeof(p))
		sputc(q, sgetc(p));
	if(n == 1){
		r := dcdiv(q, tenptr);
		q = r;
	}
	return q;
}

scalint(p: ref Blk): ref Blk
{
	n := sunputc(p);
	return removc(p, n);
}

# scale(p,n): p (an integer-valued Blk, no trailing scale byte yet)
# becomes a number scaled to n decimal digits - used by readin() for a
# literal like "3.14" (n=2).
scale(p: ref Blk, n: int): ref Blk
{
	t := add0(p, n);
	q := salloc(1);
	sputc(q, n);
	s := dcexp(inbas, q);
	q = dcdiv(t, s);
	sputc(q, n);
	return q;
}

removr(p: ref Blk, n: int): (ref Blk, ref Blk)
{
	fsfile(p);
	isneg := sbackc(p);
	if(isneg < 0)
		chsign(p);
	rewind(p);
	nn := (n+1)/2;
	q := salloc(nn);
	while(n > 1){
		sputc(q, sgetc(p));
		n -= 2;
	}
	r := salloc(2);
	while(!sfeof(p))
		sputc(r, sgetc(p));
	if(n == 1){
		s := dcdiv(r, tenptr);
		rm := rem;
		rewind(rm);
		if(!sfeof(rm))
			sputc(q, sgetc(rm));
		if(isneg < 0){
			chsign(s);
			chsign(q);
			return (s, q);
		}
		return (s, q);
	}
	if(isneg < 0){
		chsign(r);
		chsign(q);
		return (r, q);
	}
	return (r, q);
}

dcdiv(ddivd, ddivr: ref Blk): ref Blk
{
	dig := 0;
	under := 0;
	divcarry := 0;
	rem = nil;
	p := salloc(0);
	if(length(ddivr) == 0){
		pushp(ddivr);
		emits("divide by 0\n");
		return p;
	}
	divsign := 0;
	remsign := 0;
	first := 0;
	divr := ddivr;
	fsfile(divr);
	if(sbackc(divr) == -1){
		divr = copy(ddivr, length(ddivr));
		chsign(divr);
		divsign = ~divsign;
	}
	divd := copy(ddivd, length(ddivd));
	fsfile(divd);
	if(sfbeg(divd) == 0 && sbackc(divd) == -1){
		chsign(divd);
		divsign = ~divsign;
		remsign = ~remsign;
	}
	offset := length(divd) - length(divr);
	if(offset >= 0){
		seekc(p, offset+1);
		sputc(divd, 0);
		magic := 0;
		fsfile(divr);
		c := sbackc(divr);
		if(c < 10)
			magic++;
		c2 := 0;
		if(!sfbeg(divr))
			c2 = sbackc(divr);
		c = c*100 + c2;
		if(magic > 0){
			c3 := 0;
			if(!sfbeg(divr))
				c3 = sbackc(divr);
			c = (c*100 + c3)*2;
			c /= 25;
		}
		while(offset >= 0){
			first++;
			fsfile(divd);
			td := sbackc(divd) * 100;
			dd := 0;
			if(!sfbeg(divd))
				dd = sbackc(divd);
			td = (td + dd) * 100;
			dd = 0;
			if(!sfbeg(divd))
				dd = sbackc(divd);
			td = td + dd;
			cc := c;
			if(offset == 0)
				td++;
			else
				cc++;
			if(magic != 0)
				td <<= 3;
			dig = td/cc;
			under = 0;
			if(td%cc < 8 && dig > 0 && magic != 0){
				dig--;
				under = 1;
			}
			rewind(divr);
			rewind(divxyz);
			carry := 0;
			while(!sfeof(divr)){
				d := sgetc(divr)*dig + carry;
				carry = d/100;
				salterc(divxyz, d%100);
			}
			salterc(divxyz, carry);
			rewind(divxyz);
			seekc(divd, offset);
			carry = 0;
			while(!sfeof(divd)){
				d := slookc(divd);
				dv := 0;
				if(!sfeof(divxyz))
					dv = sgetc(divxyz);
				d = d - dv - carry;
				carry = 0;
				if(d < 0){
					d += 100;
					carry = 1;
				}
				salterc(divd, d);
			}
			divcarry = carry;
			backc(p);
			salterc(p, dig);
			backc(p);
			fsfile(divd);
			d := sbackc(divd);
			if(d != 0 && offset != 0){
				d = sbackc(divd) + 100;
				salterc(divd, d);
			}
			offset--;
			if(offset >= 0)
				divd.wt--;
		}
		if(under != 0){
			px := copy(divr, length(divr));
			chsign(px);
			ps := add(px, divd);
			fsfile(ps);
			if(length(ps) > 0 && sbackc(ps) < 0){
				# only adjust in really undershot
			} else {
				salterc(p, dig+1);
				divd = ps;
			}
		}
		if(divcarry != 0){
			salterc(p, dig-1);
			salterc(divd, -1);
			ps := add(divr, divd);
			divd = ps;
		}
		rewind(p);
		divcarry = 0;
		while(!sfeof(p)){
			d := slookc(p) + divcarry;
			divcarry = 0;
			if(d >= 100){
				d -= 100;
				divcarry = 1;
			}
			salterc(p, d);
		}
		if(divcarry != 0)
			salterc(p, divcarry);
		fsfile(p);
		while(!sfbeg(p)){
			if(sbackc(p) != 0)
				break;
			btruncate(p);
		}
		if(divsign < 0)
			chsign(p);
		fsfile(divd);
		while(!sfbeg(divd)){
			if(sbackc(divd) != 0)
				break;
			btruncate(divd);
		}
	}
	if(remsign < 0)
		chsign(divd);
	rem = divd;
	return p;
}

# dscale(): pops the divisor/dividend, sets arg1/arg2/savk for the
# following binop('/'). Returns 1 (and has already pushed a result) if
# the caller should NOT proceed to a division at all - either a
# divide-by-zero (an error message was printed) or a zero dividend (0
# was pushed directly, matching the original's own short-circuit).
dscale(): int
{
	dr := pop();
	if(stkerr != 0){
		emits("stack empty\n");
		return 1;
	}
	dd := pop();
	if(stkerr != 0){
		pushp(dr);
		emits("stack empty\n");
		return 1;
	}
	fsfile(dd);
	skd = sunputc(dd);
	fsfile(dr);
	skr = sunputc(dr);
	if(sfbeg(dr) == 1 || (sfbeg(dr) == 0 && sbackc(dr) == 0)){
		sputc(dr, skr);
		pushp(dr);
		emits("divide by 0\n");
		return 1;
	}
	if(sfbeg(dd) == 1 || (sfbeg(dd) == 0 && sbackc(dd) == 0)){
		sputc(dd, skd);
		pushp(dd);
		return 1;
	}
	c := k - skd + skr;
	r: ref Blk;
	if(c < 0){
		(r, irem) = removr(dd, -c);
	} else {
		r = add0(dd, c);
		irem = nil;
	}
	arg1 = r;
	arg2 = dr;
	savk = k;
	return 0;
}

dcsqrt(p: ref Blk): ref Blk
{
	n := length(p);
	fsfile(p);
	c := sbackc(p);
	if((n&1) != 1){
		c2 := 0;
		if(!sfbeg(p))
			c2 = sbackc(p);
		c = c*100 + c2;
	}
	n = (n+1)>>1;
	r := salloc(n);
	bzero(r);
	seekc(r, n);
	nn := 1;
	while((c -= nn) >= 0)
		nn += 2;
	c = (nn+1)>>1;
	fsfile(r);
	backc(r);
	if(c >= 100){
		c -= 100;
		salterc(r, c);
		sputc(r, 1);
	} else
		salterc(r, c);
	t, q, s: ref Blk;
	for(;;){
		q = dcdiv(p, r);
		s = add(q, r);
		q = dcdiv(s, sqtemp);
		s = copy(r, length(r));
		chsign(s);
		t = add(s, q);
		fsfile(t);
		nn = 0;
		if(!sfbeg(t))
			nn = sbackc(t);
		if(nn >= 0)
			break;
		r = q;
	}
	return r;
}

dcexp(base, ex: ref Blk): ref Blk
{
	r := salloc(1);
	sputc(r, 1);
	p := copy(base, length(base));
	e := copy(ex, length(ex));
	fsfile(e);
	temp := 0;
	if(!sfbeg(e)){
		c := sbackc(e);
		if(c < 0){
			temp++;
			chsign(e);
		}
		while(length(e) != 0){
			e1 := dcdiv(e, sqtemp);
			e = e1;
			n := length(rem);
			if(n != 0)
				r = mult(p, r);
			t := copy(p, length(p));
			p = mult(p, t);
		}
		if(temp != 0){
			bc := length(base);
			if(bc != 0){
				if(bc > 1)
					bcreate(r);
				else {
					rewind(base);
					bc = sgetc(base);
					bcreate(r);
					if(bc <= 1)
						sputc(r, bc);
				}
			}
		}
	}
	return r;
}

eqk(): int
{
	p := pop();
	if(stkerr != 0){
		emits("stack empty\n");
		return 1;
	}
	q := pop();
	if(stkerr != 0){
		pushp(p);
		emits("stack empty\n");
		return 1;
	}
	skp := sunputc(p);
	skq := sunputc(q);
	if(skp == skq){
		arg1 = p;
		arg2 = q;
		savk = skp;
		return 0;
	}
	if(skp < skq){
		savk = skq;
		p = add0(p, skq-skp);
	} else {
		savk = skp;
		q = add0(q, skp-skq);
	}
	arg1 = p;
	arg2 = q;
	return 0;
}

binop(c: int)
{
	r: ref Blk;
	case c {
	'+' =>	r = add(arg1, arg2);
	'*' =>	r = mult(arg1, arg2);
	'/' =>	r = dcdiv(arg1, arg2);
	}
	sputc(r, savk);
	pushp(r);
}

subt(): int
{
	arg1 = pop();
	if(stkerr != 0){
		emits("stack empty\n");
		return 1;
	}
	savk = sunputc(arg1);
	chsign(arg1);
	sputc(arg1, savk);
	pushp(arg1);
	if(eqk() != 0)
		return 1;
	binop('+');
	return 0;
}

# --- number parsing (readin(), shared by the top-level number token
# and by any macro text that types digits) ---

readin(): ref Blk
{
	dp := 0;
	dpct := 0;
	p := salloc(0);
	c := 0;
	for(;;){
		c = readc();
		if(finished)
			return p;
		if(c == '.'){
			if(dp != 0)
				break;
			dp++;
			continue;
		}
		if(c == '\\'){
			readc();
			continue;
		}
		if(c >= 'A' && c <= 'F')
			c = c - 'A' + 10;
		else if(c >= '0' && c <= '9')
			c -= '0';
		else
			break;
		if(dp != 0){
			if(dpct >= 99)
				continue;
			dpct++;
		}
		bcreate(chptr);
		if(c != 0)
			sputc(chptr, c);
		q := mult(p, inbas);
		p = add(chptr, q);
	}
	unreadc(c);
	if(dp == 0){
		sputc(p, 0);
		return p;
	}
	return scale(p, dpct);
}

# --- printing ---

getdec(p: ref Blk, sc: int): ref Blk
{
	rewind(p);
	if(length(p)*2 < sc)
		return copy(p, length(p));
	q := salloc(length(p));
	while(sc >= 1){
		sputc(q, sgetc(p));
		sc -= 2;
	}
	if(sc != 0){
		t := mult(q, tenptr);
		cc := length(q);
		s := salloc(cc);
		rewind(t);
		while(cc-- > 0)
			sputc(s, sgetc(t));
		sputc(s, 0);
		t = dcdiv(s, tenptr);
		return t;
	}
	return q;
}

tenot(p: ref Blk, sc: int)
{
	fsfile(p);
	f := 0;
	while(!sfbeg(p) && (p.rd-1)*2 >= sc){
		c := sbackc(p);
		if(c < 10 && f == 1)
			emits(sys->sprint("0%d", c));
		else
			emits(sys->sprint("%d", c));
		f = 1;
		test2();
	}
	if(sc == 0){
		emits("\n");
		return;
	}
	if(p.rd*2 > sc){
		c := sbackc(p);
		emits(sys->sprint("%d.", c/10));
		test2();
		outc(c%10 + '0');
		sc--;
	} else
		outc('.');
	while(sc > p.rd*2){
		outc('0');
		sc--;
	}
	while(sc > 1){
		c := sbackc(p);
		if(c < 10)
			emits(sys->sprint("0%d", c));
		else
			emits(sys->sprint("%d", c));
		sc -= 2;
		test2();
	}
	if(sc == 1)
		outc(sbackc(p)/10 + '0');
	emits("\n");
}

oneot(p: ref Blk, sc: int, ch: int)
{
	q := removc(p, sc);
	bcreate(strptr);
	sputc(strptr, -1);
	while(length(q) > 0){
		q = add(strptr, q);
		outc(ch);
	}
	emits("\n");
}

hexot(p: ref Blk, flg: int)
{
	rewind(p);
	if(sfeof(p) != 0){
		sputc(strptr, '0');
		return;
	}
	c := sgetc(p);
	if(c >= 16){
		emits("hex digit > 16");
		return;
	}
	if(c < 10)
		sputc(strptr, c+'0');
	else
		sputc(strptr, c-10+'a');
}

bigot(p: ref Blk, flg: int)
{
	t: ref Blk;
	l := 0;
	if(flg == 1)
		t = salloc(0);
	else {
		t = strptr;
		l = length(strptr) + fw - 1;
	}
	isneg := 0;
	if(length(p) != 0){
		fsfile(p);
		if(sbackc(p) < 0){
			isneg = 1;
			chsign(p);
		}
		while(length(p) != 0){
			q := dcdiv(p, tenptr);
			p = q;
			rm := rem;
			rewind(rm);
			if(sfeof(rm))
				sputc(t, '0');
			else
				sputc(t, sgetc(rm)+'0');
		}
	}
	if(flg == 1){
		l = fw1 - length(t);
		if(isneg != 0){
			l--;
			sputc(strptr, '-');
		}
		fsfile(t);
		while(l-- > 0)
			sputc(strptr, '0');
		while(!sfbeg(t))
			sputc(strptr, sbackc(t));
	} else {
		l -= length(strptr);
		while(l-- > 0)
			sputc(strptr, '0');
		if(isneg != 0){
			sclobber(strptr);
			sputc(strptr, '-');
		}
	}
	sputc(strptr, ' ');
}

dcprint(hptr: ref Blk)
{
	rewind(hptr);
	while(!sfeof(hptr)){
		if(sgetc(hptr) > 99){
			rewind(hptr);
			while(!sfeof(hptr))
				emits(sys->sprint("%c", sgetc(hptr)));
			emits("\n");
			return;
		}
	}
	fsfile(hptr);
	sc := sbackc(hptr);
	if(sfbeg(hptr) != 0){
		emits("0\n");
		return;
	}
	count = ll;
	p := copy(hptr, length(hptr));
	sclobber(p);
	fsfile(p);
	if(sbackc(p) < 0){
		chsign(p);
		outc('-');
	}
	if(obase == 0 || obase == -1){
		oneot(p, sc, 'd');
		return;
	}
	if(obase == 1){
		oneot(p, sc, '1');
		return;
	}
	if(obase == 10){
		tenot(p, sc);
		return;
	}
	# sleazy hack to scale top of stack - divide by 1 (matching the
	# original's own comment verbatim)
	pushp(p);
	sputc(p, sc);
	p = salloc(0);
	bcreate(p);
	sputc(p, 1);
	sputc(p, 0);
	pushp(p);
	if(dscale() != 0)
		return;
	p = dcdiv(arg1, arg2);
	sc = savk;

	bcreate(strptr);
	dig := logten*sc;
	dout := ((dig/10) + dig) / logo;
	dec := getdec(p, sc);
	p = removc(p, sc);
	while(length(p) != 0){
		q := dcdiv(p, basptr);
		p = q;
		outdit(rem, 0);
	}
	fsfile(strptr);
	while(!sfbeg(strptr))
		outc(sbackc(strptr));
	if(sc == 0){
		emits("\n");
		return;
	}
	bcreate(strptr);
	outc('.');
	ct := 0;
	do {
		q := mult(basptr, dec);
		dec = getdec(q, sc);
		p = removc(q, sc);
		outdit(p, 1);
		ct++;
	} while(ct < dout);
	rewind(strptr);
	while(!sfeof(strptr))
		outc(sgetc(strptr));
	emits("\n");
}

# --- registers, load/save/array element access ---

loadreg()
{
	c := getstk() & 16rFF;
	if(finished)
		return;
	sptr := stable[c];
	if(sptr != nil){
		rv := sptr.val;
		pick r := rv {
		Arrv =>
			q := array[len r.arr] of ref Blk;
			for(i := 0; i < len r.arr; i++)
				if(r.arr[i] != nil)
					q[i] = copy(r.arr[i], length(r.arr[i]));
			pushp2arr(q);
		Scalar =>
			pushp(copy(r.blk, length(r.blk)));
		}
	} else {
		q := salloc(1);
		if(c <= LASTFUN){
			emits(sys->sprint("function %c undefined\n", c+'a'-1));
			sputc(q, 'c');
			sputc(q, '0');
			sputc(q, ' ');
			sputc(q, '1');
			sputc(q, 'Q');
		} else
			sputc(q, 0);
		pushp(q);
	}
}

# pushp2arr: `l`/`L` on an array register push the array itself back
# onto the calculator stack the way the original's own `load()` does
# (`pushp(q)` where q is a Wblk cast back to a Blk*) - since this port
# keeps arrays as a distinct RegVal kind rather than a byte-
# reinterpreted Blk, "pushing an array" has no faithful scalar-stack
# representation. Solved by carrying the real array payload directly
# ON the marker Blk itself (its own `arrval` field, see Blk's own
# declaration above) rather than through a side-channel global - a
# global was tried FIRST and found broken: `commnds()`'s own `S`/`s`
# cases unconditionally clear that global to a fresh empty array
# immediately before calling save(), so by the time save() went to
# read it back, the real value it was meant to carry had already been
# stomped - `3 0:a 5 1:a La Sb 1;b p` silently stored an EMPTY array
# into b instead of a's real contents, with no error at all. Attaching
# the payload to the specific Blk that gets popped (rather than a
# global everyone shares) makes this correct instead of merely
# undocumented.
pushp2arr(q: array of ref Blk)
{
	m := salloc(0);
	bcreate(m);
	sputc(m, 0);
	m.arrval = q;
	pushp(m);
}

save(c: int, allownew: int)
{
	sptr := stable[c];
	if(c >= ARRAYST){
		p := pop();
		if(stkerr != 0){
			emits("stack empty\n");
			return;
		}
		a := p.arrval;
		if(a == nil)
			a = array[0] of ref Blk;
		nv := ref RegVal.Arrv(a);
		if(allownew || sptr == nil)
			stable[c] = ref Sym(sptr, nv);
		else
			sptr.val = nv;
		return;
	}
	p := pop();
	if(stkerr != 0){
		emits("stack empty\n");
		return;
	}
	nv := ref RegVal.Scalar(p);
	if(allownew || sptr == nil)
		stable[c] = ref Sym(sptr, nv);
	else
		sptr.val = nv;
}

# --- main command loop ---

log2(n: int): int
{
	if(n == 0)
		return 0;
	if(n < 0)
		return 31;
	i := 31;
	m := n;
	while((m <<= 1) > 0)
		i--;
	return i-1;
}

cond(c: int): int
{
	if(subt() != 0)
		return 1;
	p := pop();
	sclobber(p);
	if(length(p) == 0){
		if(c == '<' || c == '>' || c == 3){
			getstk();
			return 0;
		}
		loadreg();
		return 1;
	}
	if(c == '='){
		getstk();
		return 0;
	}
	if(c == 3){		# NE
		loadreg();
		return 1;
	}
	fsfile(p);
	cc := sbackc(p);
	if((cc < 0 && (c == '<' || c == 2)) || (cc > 0 && (c == '>' || c == 1))){
		getstk();
		return 0;
	}
	loadreg();
	return 1;
}

# command(): the `!` handler - '<'/'>'/'=' dispatch to cond() (register
# compare-and-execute); anything else is a shell command line, run via
# the #C host-command device (see man/3/cmd) since Inferno has no
# fork/exec of its own and, more to the point, no `/bin/rc` to run even
# if it did - a deliberate, documented substitution (running the
# HOST's own shell), the same class of choice as this backlog's other
# host-facing corners.
# ensurecmd()/runhostline(): the same #C host-command-execution pattern
# established in prtest.b/hoctest.b (see inferno-rio-cmd-device-oracle)
# - bind checked via stat before binding (idempotent across repeated
# calls, matching every other p9/cmd translation's own convention),
# wait opened BEFORE writing exec to ctl, data/stderr opened separately
# for read. The subprocess's own output is forwarded through emits()
# (real stdout when not capturing, appended to outbuf when a test is
# capturing) rather than discarded - the real dc's fork/exec inherits
# dc's own fds directly, so a `!ls` in an interactive session is
# expected to actually show `ls`'s output.
runhostline(line: string)
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return;
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return;
	convdir := "/cmd/"+string buf[0:n];
	waitfd := sys->open(convdir+"/wait", Sys->OREAD);
	if(sys->fprint(cfd, "exec sh -c %s", quotesh(line)) < 0)
		return;
	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);
	rb := array[8192] of byte;
	if(fromcmd != nil){
		m := sys->read(fromcmd, rb, len rb);
		if(m > 0)
			emits(string rb[0:m]);
	}
	if(errcmd != nil){
		m := sys->read(errcmd, rb, len rb);
		if(m > 0)
			emits(string rb[0:m]);
	}
	if(waitfd != nil){
		wb := array[512] of byte;
		sys->read(waitfd, wb, len wb);
	}
}

quotesh(s: string): string
{
	r := "'";
	for(i := 0; i < len s; i++)
		if(s[i] == '\'')
			r += "'\\''";
		else
			r[len r] = s[i];
	return r+"'";
}

command(): int
{
	c := readc();
	if(finished)
		return 0;
	case c {
	'<' =>	return cond('<');
	'>' =>	return cond('>');
	'=' =>	return cond('=');
	* =>
		line := "";
		line[len line] = c;
		for(;;){
			c = readc();
			if(finished || c == '\n')
				break;
			line[len line] = c;
		}
		runhostline(line);
		emits("!\n");
		return 0;
	}
}

# commnds(): the big switch. `error(p)`/`errorrt(p)` from the original
# translate directly to `continue`/`return` since every use is either
# already inside this loop or already inside a function whose own
# return value the caller checks - no exception, no cross-function
# unwinding needed anywhere in this file (see header comment).
commnds()
{
	for(;;){
		if(finished)
			return;
		c := readc();
		if(finished)
			return;
		if((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || c == '.'){
			unreadc(c);
			p := readin();
			if(finished)
				return;
			pushp(p);
			continue;
		}
		case c {
		' ' or '\t' or '\n' =>
			continue;
		'Y' =>
			emits(sys->sprint("alloc %d release %d copy %d more %d\n",
				allcnt, relcnt, copycnt, morecnt));
			continue;
		'_' =>
			p := readin();
			if(finished)
				return;
			sv := sunputc(p);
			chsign(p);
			sputc(p, sv);
			pushp(p);
			continue;
		'-' =>
			subt();
			continue;
		'+' =>
			if(eqk() != 0)
				continue;
			binop('+');
			continue;
		'*' =>
			arg1 = pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			arg2 = pop();
			if(stkerr != 0){
				pushp(arg1);
				emits("stack empty\n");
				continue;
			}
			sk1 := sunputc(arg1);
			sk2 := sunputc(arg2);
			sv := sk1+sk2;
			binop('*');
			p := pop();
			if(sv>k && sv>sk1 && sv>sk2){
				sclobber(p);
				sk := sk1;
				if(sk < sk2)
					sk = sk2;
				if(sk < k)
					sk = k;
				p = removc(p, sv-sk);
				sv = sk;
				sputc(p, sv);
			}
			pushp(p);
			continue;
		'/' =>
			if(dscale() != 0)
				continue;
			binop('/');
			continue;
		'%' =>
			if(dscale() != 0)
				continue;
			binop('/');
			p := pop();
			if(irem == nil){
				sputc(rem, skr+k);
				pushp(rem);
				continue;
			}
			p = add0(rem, skd-(skr+k));
			q := add(p, irem);
			sputc(q, skd);
			pushp(q);
			continue;
		'v' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			sv := sunputc(p);
			if(length(p) == 0){
				sputc(p, sv);
				pushp(p);
				continue;
			}
			if(sbackc(p) < 0){
				emits("sqrt of neg number\n");
				continue;
			}
			n := 0;
			if(k < sv)
				n = sv;
			else {
				n = k*2-sv;
				sv = k;
			}
			arg1 = add0(p, n);
			arg2 = dcsqrt(arg1);
			sputc(arg2, sv);
			pushp(arg2);
			continue;
		'^' =>
			neg = 0;
			arg1 = pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			if(sunputc(arg1) != 0){
				emits("exp not an integer\n");
				continue;
			}
			arg2 = pop();
			if(stkerr != 0){
				pushp(arg1);
				emits("stack empty\n");
				continue;
			}
			if(!sfbeg(arg1) && sbackc(arg1) < 0){
				neg++;
				chsign(arg1);
			}
			if(length(arg1) >= 5){
				emits("exp too big\n");
				continue;
			}
			sv := sunputc(arg2);
			p := dcexp(arg2, arg1);
			rewind(arg1);
			cc := sgetc(arg1);
			if(cc == -1)
				cc = 0;
			else if(!sfeof(arg1))
				cc = sgetc(arg1)*100 + cc;
			d := cc*sv;
			n := 0;
			if(k >= sv)
				n = k;
			else
				n = sv;
			if(n < d){
				q := removc(p, d-n);
				sputc(q, n);
				pushp(q);
			} else {
				sputc(p, d);
				pushp(p);
			}
			if(neg == 0)
				continue;
			p = pop();
			q := salloc(2);
			sputc(q, 1);
			sputc(q, 0);
			pushp(q);
			pushp(p);
			if(dscale() != 0)
				continue;
			binop('/');
			continue;
		'z' =>
			p := salloc(2);
			n := stkptr;
			if(n >= 100){
				sputc(p, n/100);
				n %= 100;
			}
			sputc(p, n);
			sputc(p, 0);
			pushp(p);
			continue;
		'Z' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			n := (length(p)-1)<<1;
			fsfile(p);
			backc(p);
			if(!sfbeg(p)){
				cc := sbackc(p);
				if(cc < 0){
					n -= 2;
					if(sfbeg(p))
						n++;
					else {
						cc = sbackc(p);
						if(cc == 0)
							n++;
						else if(cc > 90)
							n--;
					}
				} else if(cc < 10)
					n--;
			}
			q := salloc(1);
			if(n >= 100){
				sputc(q, n%100);
				n /= 100;
			}
			sputc(q, n);
			sputc(q, 0);
			pushp(q);
			continue;
		'i' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			inbas = scalint(p);
			continue;
		'I' =>
			p := copy(inbas, length(inbas)+1);
			sputc(p, 0);
			pushp(p);
			continue;
		'o' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			p = scalint(p);
			sign := 0;
			n := length(p);
			q := copy(p, n);
			fsfile(q);
			l := 0;
			cc := sbackc(q);
			l = cc;
			if(n != 1){
				if(cc < 0){
					sign = 1;
					chsign(q);
					n = length(q);
					fsfile(q);
					cc = sbackc(q);
					l = cc;
				}
				if(n != 1){
					while(!sfbeg(q))
						l = l*100+sbackc(q);
				}
			}
			logo = log2(l);
			obase = l;
			if(sign == 1)
				obase = -l;
			basptr = p;
			outdit = bigot;
			if(n == 1 && sign == 0 && cc <= 16){
				outdit = hexot;
				fw = 1;
				fw1 = 0;
				ll = 70;
				continue;
			}
			n = 0;
			if(sign == 1)
				n++;
			p = salloc(1);
			sputc(p, -1);
			t := add(p, q);
			n += length(t)*2;
			fsfile(t);
			if(sbackc(t) > 9)
				n++;
			fw = n;
			fw1 = n-1;
			ll = 70;
			if(fw >= ll)
				continue;
			ll = (70/fw)*fw;
			continue;
		'O' =>
			p := copy(basptr, length(basptr)+1);
			sputc(p, 0);
			pushp(p);
			continue;
		'[' =>
			n := 0;
			p := salloc(0);
			for(;;){
				c = readc();
				if(finished)
					return;
				if(c == ']'){
					if(n == 0)
						break;
					n--;
				}
				sputc(p, c);
				if(c == '[')
					n++;
			}
			pushp(p);
			continue;
		'k' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			p = scalint(p);
			if(length(p) > 1){
				emits("scale too big\n");
				continue;
			}
			rewind(p);
			k = 0;
			if(!sfeof(p))
				k = sgetc(p);
			scalptr = p;
			continue;
		'K' =>
			p := copy(scalptr, length(scalptr)+1);
			sputc(p, 0);
			pushp(p);
			continue;
		'X' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			fsfile(p);
			n := sbackc(p);
			p = salloc(2);
			sputc(p, n);
			sputc(p, 0);
			pushp(p);
			continue;
		'Q' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			if(length(p) > 2){
				emits("Q?\n");
				continue;
			}
			rewind(p);
			cc := sgetc(p);
			if(cc < 0){
				emits("neg Q\n");
				continue;
			}
			while(cc-- > 0){
				if(readptr == 0){
					emits("readstk?\n");
					break;
				}
				readptr--;
			}
			continue;
		'q' =>
			if(readptr <= 1){
				finished = 1;
				return;
			}
			readptr--;
			readptr--;
			continue;
		'f' =>
			if(stkptr == 0)
				emits("empty stack\n");
			else {
				for(ii := stkptr; ii > 0; ii--)
					dcprint(stack[ii]);
			}
			continue;
		'p' =>
			if(stkptr == 0)
				emits("empty stack\n");
			else
				dcprint(stack[stkptr]);
			continue;
		'P' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			# the original's own sputc(p,0) exists only to NUL-
			# terminate for its C "%s" Bprint call - the NUL itself
			# is never actually printed there, just a stopping point;
			# Limbo strings aren't NUL-terminated, so no equivalent
			# byte is appended (or read back) here at all.
			rewind(p);
			s := "";
			while(!sfeof(p))
				s[len s] = sgetc(p);
			emits(s);
			continue;
		'd' =>
			if(stkptr == 0){
				emits("empty stack\n");
				continue;
			}
			q := stack[stkptr];
			p := copy(q, length(q));
			pushp(p);
			continue;
		'c' =>
			while(stkerr == 0)
				pop();
			stkerr = 0;
			continue;
		'S' =>
			if(stkptr == 0){
				emits("save: args\n");
				continue;
			}
			cc := getstk() & 16rFF;
			if(finished)
				return;
			save(cc, 1);
			continue;
		's' =>
			if(stkptr == 0){
				emits("save:args\n");
				continue;
			}
			cc := getstk() & 16rFF;
			if(finished)
				return;
			save(cc, 0);
			continue;
		'l' =>
			loadreg();
			continue;
		'L' =>
			cc := getstk() & 16rFF;
			if(finished)
				return;
			sptr := stable[cc];
			if(sptr == nil){
				emits("L?\n");
				continue;
			}
			stable[cc] = sptr.next;
			pick r := sptr.val {
			Arrv =>
				# a SHALLOW copy (element Blks shared, not deep-
				# copied like loadreg()'s own Arrv branch below) -
				# faithful, not an oversight: `L` REMOVES this
				# register frame entirely, so nothing else can
				# still reference these element Blks afterward,
				# matching the original's own `L?` case which
				# pushes `sptr->val` directly with no copy at all
				# (only `load()`'s non-removing array path there
				# copies, for the same reason loadreg() does below).
				q := array[len r.arr] of ref Blk;
				q[0:] = r.arr;
				pushp2arr(q);
			Scalar =>
				pushp(r.blk);
			}
			continue;
		':' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			q := scalint(p);
			fsfile(q);
			cc := 0;
			if(!sfbeg(q)){
				cc = sbackc(q);
				if(cc < 0){
					emits("neg index\n");
					continue;
				}
			}
			if(length(q) > 2){
				emits("index too big\n");
				continue;
			}
			if(!sfbeg(q))
				cc = cc*100 + sbackc(q);
			if(cc >= MAXIND){
				emits("index too big\n");
				continue;
			}
			n := getstk() & 16rFF;
			if(finished)
				return;
			sptr := stable[n];
			s := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			nv: ref RegVal;
			if(sptr == nil)
				nv = ref RegVal.Arrv(array[0] of ref Blk);
			else
				nv = sptr.val;
			nv = arrset(nv, cc, s);
			if(sptr == nil)
				stable[n] = ref Sym(nil, nv);
			else
				sptr.val = nv;
			continue;
		';' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			q := scalint(p);
			fsfile(q);
			cc := 0;
			if(!sfbeg(q)){
				cc = sbackc(q);
				if(cc < 0){
					emits("neg index\n");
					continue;
				}
			}
			if(length(q) > 2){
				emits("index too big\n");
				continue;
			}
			if(!sfbeg(q))
				cc = cc*100 + sbackc(q);
			if(cc >= MAXIND){
				emits("index too big\n");
				continue;
			}
			n := getstk() & 16rFF;
			if(finished)
				return;
			sptr := stable[n];
			found := 0;
			if(sptr != nil){
				pick r := sptr.val {
				Arrv =>
					s := arrget(r.arr, cc);
					if(s != nil){
						pushp(copy(s, length(s)));
						found = 1;
					}
				}
			}
			if(!found){
				q2 := salloc(1);
				sputc(q2, 0);
				pushp(q2);
			}
			continue;
		'x' =>
			p := pop();
			if(stkerr != 0){
				emits("stack empty\n");
				continue;
			}
			pushmacro(p);
			continue;
		'?' =>
			readptr++;
			readstk[readptr] = nil;
			fsave = curfile;
			curfile = stdinbuf;
			c = readc();
			if(finished)
				return;
			while(c == '!'){
				command();
				if(finished)
					return;
				c = readc();
				if(finished)
					return;
			}
			p := salloc(0);
			sputc(p, c);
			for(;;){
				c = readc();
				if(finished)
					return;
				if(c == '\n')
					break;
				sputc(p, c);
				if(c == '\\'){
					c = readc();
					if(finished)
						return;
					sputc(p, c);
				}
			}
			curfile = fsave;
			readstk[readptr] = p;
			continue;
		'!' =>
			if(command() == 1){
				p := pop();
				if(stkerr != 0){
					emits("stack empty\n");
					continue;
				}
				pushmacro(p);
			}
			continue;
		'<' or '>' or '=' =>
			if(cond(c) == 1){
				p := pop();
				if(stkerr != 0){
					emits("stack empty\n");
					continue;
				}
				pushmacro(p);
			}
			continue;
		* =>
			emits(sys->sprint("%o is unimplemented\n", c));
		}
	}
}

# pushmacro(p): the `execute:` label shared by `x`, `!`, and `</>/=`.
# The C's own tail-call check (replace an already-exhausted top macro
# frame in place, instead of pushing a new one) avoids unbounded growth
# for a macro whose LAST action is to invoke another macro - kept
# verbatim since real dc scripts (recursive factorial-style macros)
# rely on it to not blow the nesting-depth check.
pushmacro(p: ref Blk)
{
	if(readptr != 0 && readstk[readptr] != nil){
		if(sfeof(readstk[readptr]))
			readstk[readptr] = nil;
		else {
			readptr++;
			if(readptr == RDSKSZ){
				emits("nesting depth\n");
				return;
			}
		}
	} else
		readptr++;
	readstk[readptr] = p;
	rewind(p);
}

# --- argument handling / test seam ---

run(argv: list of string, stdintext: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	resetstate();
	stdinbuf = bufio->sopen(stdintext);
	if(argv != nil){
		f := bufio->open(hd argv, Bufio->OREAD);
		if(f == nil){
			return sys->sprint("dc: can't open file %s\n", hd argv);
		}
		curfile = f;
	} else
		curfile = stdinbuf;
	capturing = 1;
	outbuf = "";
	commnds();
	capturing = 0;
	return outbuf;
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	resetstate();
	fname: string;
	argv = tl argv;	# drop argv[0] (the command name)
	for(l := argv; l != nil; l = tl l){
		a := hd l;
		if(len a > 0 && a[0] == '-')
			continue;	# unrecognized flag: accept, ignore (see header comment on `dbg`)
		fname = a;
		break;
	}
	stdinbuf = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(fname != nil){
		f := bufio->open(fname, Bufio->OREAD);
		if(f == nil){
			sys->fprint(stderr, "dc: can't open file %s\n", fname);
			return;
		}
		curfile = f;
	} else
		curfile = stdinbuf;
	commnds();
}
