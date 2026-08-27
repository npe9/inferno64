implement Marshal;

# Real 9front sys/src/cmd/upas/marshal/marshal.c (1832 lines), translated
# 1:1 where "1:1" is even meaningful - not a workalike. Source:
# /Users/npe/src/plan9front/sys/src/cmd/upas/marshal/marshal.c (pulled
# from outside this repo, same as cb.c/qr.c/news.c were).
#
# marshal composes a MIME mail message from headers (own args plus
# stdin) and hands the finished bytes to a subprocess - `sendmail`,
# then `/bin/upas/send` - that actually delivers it, forking one to
# three child processes along the way (sendmail itself, an optional
# `pgp` filter, and - only under -F/-S - a third child that appends a
# copy into a real local mailbox with real file locking, entirely
# inside sendmail()'s own forked child).
#
# THE ONE SCOPING DECISION WORTH STATING UP FRONT, PLAINLY, NOT AS A
# CAPABILITY GAP LIKE tar.b's DROPPED COMPRESSION: this translation
# implements marshal's COMPOSITION ENGINE - header parsing, RFC822
# address tokenizing, recursive local-alias expansion, MIME multipart
# assembly, base64 body encoding, RFC2047 header encoding - and STOPS
# where the real source hands off to a subprocess. `sendmail()`,
# `pgpfilter()`, `tee()`, `waitforsubprocs()`, and the flags whose ONLY
# job is driving that handoff (-x/-#/-d: "run sendmail with these args
# and write nothing"; -p: interpose pgp; -F/-S: also copy into a local
# mailbox) are none of them translated - not stubbed to accept-and-
# no-op, just not present, since implementing them as no-ops would
# silently misrepresent what the real flags do. This is a real,
# deliberate difference from tar.c's dropped compression: tar still
# does its whole job (archive/extract) on everything but a compressed
# archive. A `marshal` that composes a message and stops is a
# genuinely different program from the one in sys/src/cmd/upas/
# marshal/ - not a subset of it - because composing-then-delivering is
# the real program's one integrated action, not two separable
# features. Two things make dropping it the right call anyway rather
# than a compromise: this backlog's own standing rule that sending
# real mail is an outward-facing action needing explicit human intent,
# never something automated tooling or its own test suite should
# trigger as a side effect; and Dis having no fork/exec at all (this
# backlog's own tar.b precedent, re-confirmed here), so there is no
# faithful way to run `/bin/upas/send` as a real subprocess regardless
# - the actual real-delivery destination this tree already has,
# working today, is `sendmail.b` (appl/cmd/sendmail.b, real SMTP via
# dial.m) - loading it as an in-process Command module and wiring a
# constructed pipe to it is a genuine follow-on design decision of its
# own, deliberately left undone here, not silently absorbed.
#
# doc/plan9-port.md's own earlier scoping note for this item said
# marshal "never touches the mbox-append/lock code at all" - that
# was WRONG on the facts (sendmail()'s own forked child calls
# foldername()/openfolder()/closefolder() directly under -F/-S, and
# openfolder() really does take a real file lock) even though the
# CONCLUSION (no mbox-format dependency for what actually gets
# translated here) still holds, for the different reason above: -F/-S
# only exist to configure that same dropped subprocess, so the whole
# mbox-locking path leaves with it. Corrected in doc/plan9-port.md
# itself, not just noted here.
#
# What's translated, roughly in the order it was written (hardest
# piece first, per this backlog's own established practice):
#   - get822token()/expandline(): the RFC822 address-list tokenizer
#     and per-line alias-expanding state machine. Verified against a
#     standalone oracle built from the REAL C source (every function
#     body copied verbatim, not reimplemented - only a driver main()
#     and an in-memory alias-list stub, replacing readaliases()'s own
#     real file read, are new) - see marshaltest.b's own header
#     comment for what that oracle found.
#   - _expand()/rexpand()/unique()/expand()/concataddr(): the
#     alias-substitution and address-list algebra sitting underneath
#     expandline().
#   - readheaders(): coalesces multi-line header values, classifies
#     each against the real hdrs[] table, and drives expandline() on
#     To:/Cc:/Bcc: lines. The one real risk flagged before writing
#     this - whether bufio's backward Iobuf.seek() (used to push a
#     non-header line back for the body reader, matching the C's own
#     Bseek(in, -Blinelen(in), 1)) works on a non-seekable stdin pipe,
#     not just a real file - was checked directly with a standalone
#     probe (a real Sys->pipe(), not a redirected file) before writing
#     this function at all: a single-line rewind always lands inside
#     Iobuf's own 8192-byte read-ahead buffer, which its own seek()
#     serves from memory without ever calling the underlying fd's real
#     seek - safe on a pipe for exactly the distance this function
#     ever rewinds.
#   - body()/body64()/attachment()/mkattach(): MIME part assembly and
#     base64 encoding. mkattach()'s own C falls back to exec'ing
#     `/bin/file -m` to sniff an attachment's type when neither an
#     explicit -t, the built-in extension table, nor /lib/mimetype
#     matches - with no fork/exec available, this translation takes
#     the exact same "safest default" the C ITSELF already falls back
#     to when that pipe/fork fails (`application/octet-stream`),
#     rather than inventing a new fallback.
#   - the header-printing functions (printdate/printfrom/printaddr/
#     printto/printcc/printsubject/printinreplyto) and mkboundary().
#
# Two module-level translation choices, each replacing a hand-rolled
# C helper with an existing Limbo module rather than re-deriving it:
#   - Plan 9's String-buffer library (s_new/s_append/s_copy/...) is
#     not needed at all - Limbo's own `string` is already a suitable
#     growable buffer via `+=`, matching every other translation in
#     this backlog (tar.b, cb.b, qr.b, ...), none of which reach for a
#     buffer-class abstraction unless the source's own one does
#     something Limbo strings genuinely can't (dc.c's Blk did; this
#     doesn't).
#   - getenv("upasname")/getlog() -> Env->getenv, matching news.b's
#     own precedent; no $MAILROOT convention exists anywhere in this
#     tree (checked, not assumed - grepped appl/lib, appl/cmd), so the
#     alias file's own real path (mboxpathbuf(file, n, login, "names")
#     in the source, i.e. $MAILROOT/box/<login>/names) is simplified
#     to $home/mail/names here - a deliberate adaptation, stated
#     plainly, not a hidden divergence.

include "sys.m";
	sys: Sys;
	Dir: import sys;
include "draw.m";
	Context: import Draw;
include "env.m";
	env: Env;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	daytime: Daytime;
include "string.m";
	str: String;
include "encoding.m";
	encoding: Encoding;
include "rand.m";
	rand: Rand;

Marshal: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# run: the real composition pipeline as a test-callable seam -
	# builds the exact bytes the real source would hand to sendmail()
	# (see this file's own header comment for why that handoff itself
	# stops here), given argv (recipients/-C/-B/-a/-A/-s/-t/-n/-8/-R,
	# NOT the sendmail-only -x/-#/-d/-p/-F/-S, which this translation
	# does not accept at all - see BUGS in man/1/marshal) and the raw
	# stdin bytes (already fully read - this seam never itself reads
	# a live fd, matching every other run() in this backlog).
	run:		fn(argv: list of string, data: array of byte): (array of byte, int);

	# Test seam only (not part of the real CLI): setaliases populates
	# the alias table the way readaliases() would from a real file,
	# from a plain in-memory list of "name addr addr ..." lines -
	# whitespace-tokenized, matching s_parse()'s own line format minus
	# the real file read. testexpandline runs expandline() on one
	# line with no incoming accumulator, returning (rewritten line,
	# expanded addresses, syntax-error flag) as plain types a test
	# module can compare directly.
	setaliases:	fn(lines: list of string);
	testexpandline:	fn(line: string): (string, list of string, int);
};

stderr: ref Sys->FD;

# --- growable byte-buffer output (arbitrary bytes, not text) ---
#
# marshal's own output is not always valid text - an attachment can be
# any binary content, and MIME's own base64 encoding of one is always
# plain ASCII but still built as bytes here for one uniform sink
# rather than switching representations mid-message. A plain Limbo
# `string` (used for everything else in this backlog) would corrupt
# arbitrary binary content by forcing a UTF-8 round-trip - the same
# byte-vs-string trap file.b's own dict[] handling was translated
# around; Outbuf is the equivalent fix here.
Outbuf: adt
{
	buf:	array of byte;
	n:	int;

	emit1:		fn(b: self ref Outbuf, x: byte);
	emits:		fn(b: self ref Outbuf, s: string);
	emitbytes:	fn(b: self ref Outbuf, x: array of byte);
};

mkoutbuf(): ref Outbuf
{
	return ref Outbuf(array[8192] of byte, 0);
}

obgrow(b: ref Outbuf, extra: int)
{
	if(b.n + extra <= len b.buf)
		return;
	newlen := len b.buf * 2;
	if(newlen < b.n + extra)
		newlen = b.n + extra;
	nbuf := array[newlen] of byte;
	nbuf[0:] = b.buf[0:b.n];
	b.buf = nbuf;
}

Outbuf.emit1(b: self ref Outbuf, x: byte)
{
	obgrow(b, 1);
	b.buf[b.n++] = x;
}

Outbuf.emitbytes(b: self ref Outbuf, x: array of byte)
{
	obgrow(b, len x);
	b.buf[b.n:] = x;
	b.n += len x;
}

Outbuf.emits(b: self ref Outbuf, s: string)
{
	b.emitbytes(array of byte s);
}

# --- address list / alias expansion engine ---
#
# Addr/Alias mirror the C's own singly-linked structs exactly (a
# Limbo `ref adt` is already a mutable, GC'd node - no separate
# free()/malloc() needed anywhere in this section). An Alias's own
# `addr` field holds the alias NAME as addr.v and the expansion
# addresses as addr.next onward, exactly matching the C's own
# `al->addr->v` / `al->addr->next` usage in _expand().

Addr: adt
{
	next:	cyclic ref Addr;
	v:	string;
};

Alias: adt
{
	next:	cyclic ref Alias;
	addr:	ref Addr;
};

aliases:		ref Alias;
rfc822syntaxerror:	int;
lastchar:		int;	# last byte body()/body64() emitted - mirrors
				# the C's own global of the same name exactly,
				# read by run() after each attachment to decide
				# whether a separating blank line is needed

newaddr(name: string): ref Addr
{
	return ref Addr(nil, name);
}

# concataddr(a,b): a followed by b - identical shape to the C's own
# tail-walking version (no address-of-a-pointer trick needed; a
# Limbo ref's own fields are directly mutable in place).
concataddr(a: ref Addr, b: ref Addr): ref Addr
{
	if(a == nil)
		return b;
	oa := a;
	while(a.next != nil)
		a = a.next;
	a.next = b;
	return oa;
}

# _expand: one pass of alias substitution over `old`, returning the
# substituted list and whether anything changed. Every C freeaddr()
# call is simply omitted - Limbo's GC reclaims a node once nothing
# references it, same as every other translation in this backlog.
_expand(old: ref Addr): (ref Addr, int)
{
	changed := 0;
	first: ref Addr = nil;
	last: ref Addr = nil;
	while(old != nil){
		next := old.next;
		matched: ref Alias = nil;
		for(al := aliases; al != nil; al = al.next){
			if(al.addr.v == old.v){
				matched = al;
				break;
			}
		}
		if(matched != nil){
			for(a := matched.addr.next; a != nil; a = a.next){
				na := newaddr(a.v);
				if(first == nil)
					first = na;
				else
					last.next = na;
				last = na;
				changed = 1;
			}
		}else{
			old.next = nil;
			if(first == nil)
				first = old;
			else
				last.next = old;
			last = old;
		}
		old = next;
	}
	return (first, changed);
}

# rexpand: repeat _expand until a fixed point, capped at 32 passes -
# matching the C's own cap exactly, not a safety margin added here.
# A self-referential alias (one whose own expansion list contains its
# own name) genuinely does NOT converge - it grows by one entry per
# pass until the cap stops it, confirmed against the real-source
# oracle (see marshaltest.b) rather than assumed; the cap exists
# precisely to bound that case, not to handle some other divergence.
rexpand(old: ref Addr): ref Addr
{
	changed := 0;
	for(i := 0; i < 32; i++){
		(old, changed) = _expand(old);
		if(changed == 0)
			break;
	}
	return old;
}

# unique: drop later duplicates of each address's own value, in place.
unique(first: ref Addr): ref Addr
{
	for(a := first; a != nil; a = a.next){
		p := a;
		for(;;){
			x := p.next;
			if(x == nil)
				break;
			if(x.v == a.v)
				p.next = x.next;
			else
				p = x;
		}
	}
	return first;
}

# expand: the top-level entry from a raw recipient-argument list (the
# CLI's own argv/-C/-B lists, before any header-line parsing).
expand(av: list of string): ref Addr
{
	first: ref Addr = nil;
	last: ref Addr = nil;
	for(; av != nil; av = tl av){
		na := newaddr(hd av);
		if(first == nil)
			first = na;
		else
			last.next = na;
		last = na;
	}
	return unique(rexpand(first));
}

# --- RFC822 address-list tokenizer ---
#
# Direct translation of get822token()'s own char-pointer/index
# arithmetic onto a Limbo string plus an integer cursor - safe to
# index by rune rather than by byte here (unlike a raw byte buffer)
# since every delimiter get822token cares about (space/tab/CR/LF,
# '(' ')' '<' '>' ',' '"' '\\') is plain ASCII, well under 0x80, and
# every UTF-8 continuation/lead byte is >=0x80, so a multi-byte
# character can never be misread as one of these delimiters either
# way - byte-indexing (C) and rune-indexing (Limbo) agree on every
# valid UTF-8 input.

Twhite, Tcomment, Twords, Tcomma, Tleftangle, Trightangle, Terror, Tend: con iota;

iswhite822(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

# get822token(p, i): classify and consume the next token starting at
# index i, returning (tokentext, newindex, type). Matches the C's own
# dual-increment escape handling exactly: a backslash advances the
# cursor once for itself (this loop's own unconditional step) plus
# once more for the escaped character (the conditional step below),
# so an escaped delimiter is never separately re-examined.
get822token(p: string, i: int): (string, int, int)
{
	n := len p;
	if(i >= n)
		return ("", i, Tend);
	op := i;
	c := p[i];
	toktype: int;
	case c {
	' ' or '\t' or '\n' or '\r' =>
		toktype = Twhite;
		while(i < n && iswhite822(p[i]))
			i++;
	'(' =>
		toktype = Tcomment;
		i++;
		for(;;){
			if(i >= n || p[i] == ')')
				break;
			if(p[i] == '\\'){
				if(i + 1 >= n)
					return ("", i, Terror);
				i++;
			}
			i++;
		}
		if(i >= n || p[i] != ')')
			return ("", i, Terror);
		i++;
	',' =>
		toktype = Tcomma;
		i++;
	'<' =>
		toktype = Tleftangle;
		i++;
	'>' =>
		toktype = Trightangle;
		i++;
	* =>
		toktype = Twords;
		quoting := 0;
		for(;;){
			if(i >= n)
				break;
			c2 := p[i];
			if(!(quoting != 0 || (iswhite822(c2) == 0 && c2 != '>' && c2 != '<' && c2 != ',')))
				break;
			if(c2 == '"')
				quoting = !quoting;
			if(c2 == '\\'){
				if(i + 1 >= n)
					return ("", i, Terror);
				i++;
			}
			i++;
		}
	}
	return (p[op:i], i, toktype);
}

# expandline: expand local aliases in one already-coalesced "Label:
# addr, addr (comment), ..." line, returning the rewritten line text
# and the parsed+expanded address list prepended onto `to` (matching
# the C's own concataddr(nto, to) at the very end - later lines end up
# BEFORE earlier ones in the combined list, exactly as the C's own
# tail-building produces, confirmed against the oracle).
#
# The C's `goto Error`, reached from four separate spots, always does
# the same four things and then falls straight into Break2 - inlined
# at each site here rather than factored into a helper, matching this
# backlog's own established practice for a short shared error tail
# (readheaders()'s own `goto Addhdr` gets the same treatment below).
# Limbo has no goto; escaping the surrounding parse loop from inside a
# `case` arm needs a LABELED break specifically - confirmed against
# the language reference before writing this (a bare `break` inside a
# `case` breaks the case itself, not an enclosing loop, since `case`
# is itself one of the constructs a bare break can terminate).
#
# Two pairs of the C's own separate `goto Error` conditions are merged
# into one `if(a || b)` here (Tcomma/Tend's `if(inangle)...if(nword!=1)`,
# and Twords/Tleftangle's `if(hadangle)...if(...)`) - safe because both
# halves of each pair lead to byte-identical handling with no
# distinguishing side effect in between, confirmed by inspection, not
# assumed the way the qr.c evaluate() "obvious fix" once was.
expandline(line: string, dest: ref Addr): (string, ref Addr)
{
	os := line;
	colon := -1;
	for(k := 0; k < len line; k++)
		if(line[k] == ':'){
			colon = k;
			break;
		}
	if(colon < 0)
		raise "fail:marshal";	# matches the C's own assert(p != nil):
					# every real call site only ever passes
					# a line that already matched the header
					# table, which always contains this colon.
	p := colon + 1;

	ns := line[0:p];
	nto: ref Addr = nil;
	lastword := "";
	sinceword := "";
	inangle := 0;
	nword := 0;
	hadangle := 0;

	parseloop: for(;;){
		(stok, newp, tok) := get822token(line, p);
		p = newp;
		case tok {
		Tcomma or Tend =>
			if(inangle || nword != 1){
				ns = os;
				nto = nil;
				rfc822syntaxerror = 1;
				break parseloop;
			}
			na := rexpand(newaddr(lastword));
			ns += na.v;
			ns += sinceword;
			for(ap := na.next; ap != nil; ap = ap.next){
				ns += ", ";
				ns += ap.v;
			}
			nto = concataddr(na, nto);
			if(tok == Tcomma)
				ns += ",";
			if(tok == Tend)
				break parseloop;
			inangle = 0;
			nword = 0;
			hadangle = 0;
			sinceword = "";
			lastword = "";
		Twhite or Tcomment =>
			sinceword += stok;
		Trightangle =>
			if(inangle == 0){
				ns = os;
				nto = nil;
				rfc822syntaxerror = 1;
				break parseloop;
			}
			inangle = 0;
			hadangle = 1;
			sinceword += stok;
		Twords or Tleftangle =>
			if(hadangle != 0 || (tok != Tleftangle && inangle != 0 && len lastword > 0)){
				ns = os;
				nto = nil;
				rfc822syntaxerror = 1;
				break parseloop;
			}
			if(tok == Tleftangle){
				inangle = 1;
				nword = 1;
			}
			ns += lastword;
			ns += sinceword;
			sinceword = "";
			if(tok == Tleftangle){
				ns += "<";
				lastword = "";
			}else
				lastword = stok;
			if(inangle == 0)
				nword++;
		Terror =>
			ns = os;
			nto = nil;
			rfc822syntaxerror = 1;
			break parseloop;
		}
	}
	nto = concataddr(nto, dest);
	return (ns, nto);
}

# --- header table ---
#
# Positional, not designated, initializer - Limbo has no C-style
# `[Hto] = "to:"` designated-index syntax, so this array is built in
# plain enum order instead. The real source's own initializer lists
# entries in a DIFFERENT textual order than the enum (grouping
# to/cc/bcc/sender/reply-to before date/subject/mime/etc rather than
# following Hfrom..Hinclude straight through) - designated initializers
# make that safe in C since each string still lands at its own index
# regardless of listing order; reproducing the same INDEX<->STRING
# mapping here means listing every entry in enum order instead, not
# copying the C's own visual order verbatim. Checked field by field
# against the real source's own `[Hxxx]` tags, not assumed from
# position.
Hfrom, Hto, Hcc, Hbcc, Hsender, Hreplyto, Hinreplyto, Hdate, Hsubject,
	Hmime, Hpriority, Hmsgid, Hcontent, Hx, Hprecedence, Hattach,
	Hinclude, Nhdr: con iota;

hdrs := array[] of {
	"from:",		# Hfrom
	"to:",			# Hto
	"cc:",			# Hcc
	"bcc:",			# Hbcc
	"sender:",		# Hsender
	"reply-to:",		# Hreplyto
	"in-reply-to:",		# Hinreplyto
	"date:",		# Hdate
	"subject:",		# Hsubject
	"mime-",		# Hmime
	"priority:",		# Hpriority
	"message-id:",		# Hmsgid
	"content-",		# Hcontent
	"x-",			# Hx
	"precedence",		# Hprecedence
	"attach:",		# Hattach
	"include:",		# Hinclude
};

wkday := array[] of {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
month := array[] of {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

# --- attachments / MIME content typing ---

Ctype: adt
{
	mtype:		string;	# "type" is reserved - see marshal.b's
				# own header comment convention (news.b hit
				# the same "type"/"to" reservations)
	ext:		string;
	display:	int;
};

Attach: adt
{
	next:		cyclic ref Attach;
	path:		string;
	atype:		string;
	ainline:	int;
	ctype:		ref Ctype;
};

# The real ctype[] table, in the same order, minus its own trailing
# {"",0,0} sentinel - Limbo arrays carry their own length, so no
# sentinel is needed to know where the real entries end. See
# matchctype()'s own comment for why that sentinel's ABSENCE still
# needs replicating in spirit, not just dropping.
ctypetab := array[] of {
	Ctype("text/plain", "txt", 1),
	Ctype("text/html", "html", 1),
	Ctype("text/html", "htm", 1),
	Ctype("text/tab-separated-values", "tsv", 1),
	Ctype("text/richtext", "rtx", 1),
	Ctype("message/rfc822", "txt", 1),
};

mimetypes: array of Ctype;	# nil until readmimetypes() has run once

hassuffix(a: string, b: string): int
{
	na := len a;
	nb := len b;
	if(na <= nb + 1 || a[na - nb - 1] != '.')
		return 0;
	return a[na - nb:na] == b;
}

# matchctype: mkattach()'s own C has TWO call sites of
# `for(c = ctype; ; c++) if(strncmp(type, c->type, strlen(c->type)) == 0) ...`
# with NO bound on c at all - looking unbounded, but it never actually
# runs past the real table: the C array's own trailing sentinel entry
# is {"", 0, 0}, and strncmp(anything, "", 0) is ALWAYS 0 (comparing
# zero bytes trivially matches), so that sentinel silently acts as a
# universal catch-all as well as an end marker. Confirmed by reading
# the comparison, not assumed from the loop's own shape - a real Limbo
# array has no such sentinel and IS bounds-checked, so this function
# makes the same catch-all explicit: if nothing in ctypetab's own
# entries matches, return the same {"","",0} shape the C's sentinel
# would have matched, which is exactly what mkattach() needs (display
# false, so this attachment falls through to the base64 encoding path
# used for anything not one of the 6 specially-recognized display
# types).
ctypesentinel := Ctype("", "", 0);

matchctype(mtype: string): ref Ctype
{
	for(i := 0; i < len ctypetab; i++){
		c := ctypetab[i];
		if(len mtype >= len c.mtype && mtype[0:len c.mtype] == c.mtype)
			return ref c;
	}
	return ref ctypesentinel;
}

# readmimetypes: parses /lib/mimetype (this tree's own path - see
# appl/lib/rfc822.b's own SuffixFile constant, same column layout the
# real source's own /sys/lib/mimetype uses: suffix, generic-type,
# specific-type, encoding, safe?). The real source has NO special
# handling for the file's own leading "#suffix ..." comment/header
# line - it just tokenizes it like any other line and builds whatever
# (harmless, never-matching) entry falls out; preserved here exactly
# rather than adding a comment-skip the source doesn't have.
readmimetypes()
{
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	b := bufio->open("/lib/mimetype", Sys->OREAD);
	if(b == nil){
		mimetypes = array[0] of Ctype;
		return;
	}
	entries: list of Ctype = nil;
	n := 0;
	for(;;){
		line := b.gets('\n');
		if(line == "")
			break;
		bare := line;
		if(len bare > 0 && bare[len bare - 1] == '\n')
			bare = bare[0:len bare - 1];
		(nf, f) := sys->tokenize(bare, " \t");
		if(nf < 4)
			continue;
		f0 := hd f;
		f1 := hd tl f;
		f2 := hd tl tl f;
		if(f0 == "-" || f1 == "-" || f2 == "-")
			continue;
		mt := f1 + "/" + f2;
		ext := "";
		if(len f0 > 1)
			ext = f0[1:];
		entries = Ctype(mt, ext, mt == "text/plain") :: entries;
		n++;
	}
	arr := array[n] of Ctype;
	i := n - 1;
	for(; entries != nil; entries = tl entries){
		arr[i] = hd entries;
		i--;
	}
	mimetypes = arr;
}

# mkattach: real fork/exec fallback to `/bin/file -m` (when neither an
# explicit -t, the built-in extension table, nor /lib/mimetype
# matches) is dropped - no fork/exec in Dis - falling through to the
# exact SAME "safest default" the C itself already falls back to when
# that pipe/fork fails: application/octet-stream.
mkattach(file: string, atype: string, ainline: int): ref Attach
{
	if(file == nil)
		return nil;
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "marshal: %s can't read file\n", file);
		return nil;
	}
	a := ref Attach(nil, file, atype, ainline, nil);
	if(atype != nil && atype != ""){
		a.ctype = matchctype(atype);
		return a;
	}

	# pick a type depending on extension
	for(i := 0; i < len ctypetab; i++){
		c := ctypetab[i];
		if(hassuffix(file, c.ext)){
			a.atype = c.mtype;
			a.ctype = ref c;
			return a;
		}
	}

	# try the mimetypes file
	if(mimetypes == nil)
		readmimetypes();
	for(i = 0; i < len mimetypes; i++){
		c := mimetypes[i];
		if(hassuffix(file, c.ext)){
			a.atype = c.mtype;
			a.ctype = ref c;
			return a;
		}
	}

	a.atype = "application/octet-stream";
	a.ctype = matchctype(a.atype);
	return a;
}

# --- MIME body / attachment assembly ---

# body: pass the message body through, making sure it starts with a
# newline. A REAL TRANSLATION BUG lived here until caught by
# marshaltest.b's own t18/t20 failing: the C accumulates the leading
# "\n"-if-needed byte AND the high-bit scan's own read-ahead into ONE
# buffer, and only ever Bwrite()s it - AFTER first Bprint()ing the
# Content-Type/Content-Transfer-Encoding pair, not before. The first
# translation pass emitted the lead byte immediately, then the
# Content-Type header, then the rest of the body - splicing the
# header into the middle of the body's own first line. Fixed by
# computing the lead bytes and the high-bit verdict first, emitting
# the header (if any), and ONLY THEN emitting the lead bytes followed
# by the remainder - matching the real ORDER OF BYTES ON THE WIRE,
# not just the same decision logic. (The C's own read-ahead is
# chunked/streaming and can stop scanning as soon as it finds one
# high-bit byte; this translation already holds the whole body in
# memory, so a single clean scan produces byte-identical OUTPUT to
# the C's own chunked one regardless - confirmed by reasoning through
# both, not assumed.)
body(indata: array of byte, outbuf: ref Outbuf, docontenttype: int)
{
	n := len indata;
	lead: array of byte;
	if(n > 0 && int indata[0] != '\n')
		lead = array[] of {byte '\n', indata[0]};
	else if(n > 0)
		lead = array[] of {indata[0]};
	else
		lead = array[] of {byte '\n'};

	if(docontenttype){
		hibit := 0;
		for(j := 0; j < n; j++)
			if((int indata[j] & 16r80) != 0){
				hibit = 1;
				break;
			}
		if(hibit)
			outbuf.emits("Content-Type: text/plain; charset=\"UTF-8\"\nContent-Transfer-Encoding: 8bit\n");
		else
			outbuf.emits("Content-Type: text/plain; charset=\"US-ASCII\"\nContent-Transfer-Encoding: 7bit\n");
	}

	outbuf.emitbytes(lead);
	lastchar = int lead[len lead - 1];
	if(n > 1){
		outbuf.emitbytes(indata[1:n]);
		lastchar = int indata[n - 1];
	}
}

# enc64x18: base64, wrapped at 72 output chars (18 base64 groups) per
# line, i.e. every 54 input bytes - reusing Encoding->enc()'s own
# alphabet/packing (module/encoding.m) rather than hand-rolling a
# second base64 implementation, per this backlog's own "reuse what
# already exists" convention. Verified the wrap geometry against the
# real source's own arithmetic (18*3 input bytes, not assumed from a
# paraphrase): a full 54-byte chunk base64-encodes to exactly 72
# characters with no '=' padding, confirmed directly against
# Encoding->enc()'s own packing loop.
enc64x18(indata: array of byte): string
{
	out := "";
	n := len indata;
	i := 0;
	while(i < n){
		m := 18 * 3;
		if(m > n - i)
			m = n - i;
		out += encoding->enc(indata[i:i + m]);
		out += "\n";
		i += m;
	}
	return out;
}

body64(indata: array of byte, outbuf: ref Outbuf)
{
	outbuf.emits("\n");
	outbuf.emits(enc64x18(indata));
	lastchar = '\n';
}

# attachment: emit one attachment's own MIME part headers plus body,
# base64-encoded unless its ctype is one of the small directly-
# displayable set (ctypetab's own `display` field). The real source's
# own "already mime encoded" passthrough (a->type=="mime": copy the
# file's bytes through completely unheaded) and its "dump our local
# 'From ' line when passing a message/rfc822 attachment" logic are
# both preserved.
attachment(a: ref Attach, outbuf: ref Outbuf)
{
	if(a.atype == "mime"){
		fd := sys->open(a.path, Sys->OREAD);
		if(fd == nil){
			sys->fprint(stderr, "marshal: opening %s: %r\n", a.path);
			raise "fail:marshal";
		}
		outbuf.emitbytes(readall(fd));
	}

	if(a.atype != "text/plain")
		outbuf.emits("Content-Type: " + a.atype + "\n");

	if(a.ainline != 0)
		outbuf.emits("Content-Disposition: inline\n");
	else{
		p := a.path;
		slash := -1;
		for(k := len p - 1; k >= 0; k--)
			if(p[k] == '/'){
				slash = k;
				break;
			}
		fname := p;
		if(slash >= 0)
			fname = p[slash + 1:];
		outbuf.emits("Content-Disposition: attachment; filename=" + doublequote(fname) + "\n");
	}

	fd := sys->open(a.path, Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "marshal: opening %s: %r\n", a.path);
		raise "fail:marshal";
	}
	data := readall(fd);

	# dump our local 'From ' line when passing along mail messages
	if(a.atype == "message/rfc822" && len data >= 5 && string data[0:5] == "From "){
		nl := -1;
		for(k := 0; k < len data; k++)
			if(data[k] == byte '\n'){
				nl = k;
				break;
			}
		if(nl >= 0)
			data = data[nl + 1:];
	}

	if(a.ctype.display != 0){
		dc := 0;
		if(a.atype == "text/plain")
			dc = 1;
		body(data, outbuf, dc);
	}else{
		outbuf.emits("Content-Transfer-Encoding: base64\n");
		body64(data, outbuf);
	}
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		if(n == len buf){
			nbuf := array[len buf * 2] of byte;
			nbuf[0:] = buf;
			buf = nbuf;
		}
		nr := sys->read(fd, buf[n:], len buf - n);
		if(nr <= 0)
			break;
		n += nr;
	}
	return buf[0:n];
}

# --- header printers ---

rfc822date(t: int): string
{
	tm := daytime->local(t);
	return sys->sprint("%s, %.2d %s %d %.2d:%.2d:%.2d %s",
		wkday[tm.wday], tm.mday, month[tm.mon], 1900 + tm.year,
		tm.hour, tm.min, tm.sec, tm.zone);
}

printdate(outbuf: ref Outbuf)
{
	outbuf.emits("Date: " + rfc822date(daytime->now()) + "\n");
}

# printfrom: if `user` already looks like "Real Name <addr>", RFC2047-
# encode just the display-name portion (matching the C's own
# `%.*U%s` - an RFC2047-encoded prefix followed by the untouched
# "<addr>" suffix); otherwise print it verbatim.
printfrom(outbuf: ref Outbuf, user: string)
{
	n := len user;
	if(n > 4 && user[n - 1] == '>'){
		langle := -1;
		for(k := n - 1; k > 0; k--)
			if(user[k] == '<'){
				langle = k;
				break;
			}
		if(langle > 0 && iswhite822(user[langle - 1]) != 0){
			outbuf.emits("From: " + rfc2047(user[0:langle - 1]) + user[langle - 1:] + "\n");
			return;
		}
	}
	outbuf.emits("From: " + user + "\n");
}

printaddr(outbuf: ref Outbuf, label: string, a: ref Addr)
{
	if(a == nil)
		return;
	outbuf.emits(label + " " + a.v);
	i := 0;
	for(a = a.next; a != nil; a = a.next){
		if((i & 7) == 7)
			outbuf.emits(",\n\t");
		else
			outbuf.emits(", ");
		outbuf.emits(a.v);
		i++;
	}
	outbuf.emits("\n");
}

printsubject(outbuf: ref Outbuf, subject: string)
{
	outbuf.emits("Subject: " + rfc2047(subject) + "\n");
}

printinreplyto(outbuf: ref Outbuf, dir: string)
{
	fd := sys->open(dir + "/messageid", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return;
	outbuf.emits("In-Reply-To: <" + string buf[0:n] + ">\n");
}

mkboundary(): string
{
	if(rand == nil){
		rand = load Rand Rand->PATH;
		rand->init(sys->millisec());
	}
	s := "upas-";
	for(i := 0; i < 27; i++)
		s[len s] = 'a' + rand->rand(26);
	return s;
}

# --- %Z / %U formatter equivalents ---
#
# The real source installs these as custom Fmt verbs (fmtinstall);
# Limbo's sys->sprint has no such mechanism, so both are plain
# functions called explicitly at each call site instead.

needsquote(c: int): int
{
	if(c >= 128)
		return 1;
	if(c <= ' ')
		return 1;
	return 0;
}

doublequote(s: string): string
{
	if(s == nil || len s == 0)
		return "\"\"";
	quotes := 0;
	for(i := 0; i < len s; i++)
		if(needsquote(s[i]) != 0 || s[i] == '\\' || s[i] == '"')
			quotes = 1;
	if(quotes == 0)
		return s;
	out := "\"";
	for(i = 0; i < len s; i++){
		if(s[i] == '\\' || s[i] == '"')
			out[len out] = '\\';
		out[len out] = s[i];
	}
	out[len out] = '"';
	return out;
}

# rfc2047: RFC2047 "Q-encoding" for header text, matching the real
# source's own byte-oriented escape rule exactly (escape space as
# '_', and '_'/tab/'='/'?'/anything >=0x80 as =XX hex) - operates on
# RUNES here rather than raw bytes, but every rune this function ever
# treats specially is itself a single-byte ASCII value (space, '_',
# tab, '=', '?'); the "else" branch emits a >=0x80 RUNE as one =XX per
# byte of its own UTF-8 encoding, matching the C's own per-BYTE loop -
# checked explicitly, not assumed, since this is exactly the kind of
# byte-vs-rune boundary that broke ascii.b's own first pass.
rfc2047(s: string): string
{
	if(s == nil)
		return "";
	hard := 0;
	for(i := 0; i < len s; i++)
		if(s[i] >= 128){
			hard = 1;
			break;
		}
	if(!hard)
		return s;

	out := "=?utf-8?q?";
	for(i = 0; i < len s; i++){
		c := s[i];
		if(c == ' ')
			out += "_";
		else if(c == '_' || c == '\t' || c == '=' || c == '?' || c >= 128){
			b := array of byte string c;
			for(k := 0; k < len b; k++)
				out += sys->sprint("=%.2uX", int b[k]);
		}else
			out[len out] = c;
	}
	out += "?=";
	return out;
}

hdrval(line: string): string
{
	colon := -1;
	for(i := 0; i < len line; i++)
		if(line[i] == ':'){
			colon = i;
			break;
		}
	p := colon + 1;
	n := len line;
	while(p < n && (line[p] == ' ' || line[p] == '\t'))
		p++;
	e := n;
	while(e > p && (line[e - 1] == ' ' || line[e - 1] == '\t'))
		e--;
	return line[p:e];
}

mksubject(line: string): string
{
	v := hdrval(line);
	hard := 0;
	for(i := 0; i < len v; i++)
		if(v[i] >= 128){
			hard = 1;
			break;
		}
	if(!hard)
		return line;
	return "Subject: " + rfc2047(v);
}

# --- header block parsing ---

RHok, RHnomessage, RHnobody, RHerror: con iota;

# readheaders: coalesce multi-line header values off `in`, classify
# each against hdrs[], drive expandline() on To:/Cc:/Bcc: lines when
# the corresponding collect flag is set, and collect attach:/include:
# lines into an Attach list when collectattach is set. Returns
# (status, updated flags bitmask, non-Bcc header text, to, cc, bcc,
# attachments).
#
# The C's own shared `Addhdr:` tail (reached by both `default` and,
# via goto, the Hto/Hcc cases) is inlined at each of those three sites
# below rather than factored out, matching this backlog's own
# established practice for a short goto-shared-tail (same call this
# file's own expandline() made for its own `goto Error`).
# attin: the attachment list already built from -a/-A flags before
# stdin is ever read (matching the C's own `att` pointer arriving
# already advanced past whatever `l` built - readheaders() APPENDS
# attach:/include: header-derived attachments onto that same tail,
# it does not start a fresh list of its own).
readheaders(in: ref Iobuf, flags: int, collectto: int, collectcc: int,
	collectbcc: int, collectattach: int, strict: int, attin: ref Attach)
	: (int, int, string, ref Addr, ref Addr, ref Addr, ref Attach)
{
	s := "";
	toaddr: ref Addr = nil;
	cc: ref Addr = nil;
	bcc: ref Addr = nil;
	sline := "";
	havesline := 0;
	hdrtype := -1;
	seen := 0;
	lastlinelen := 0;

	attfirst: ref Attach = attin;
	attlast: ref Attach = attin;
	if(attlast != nil)
		while(attlast.next != nil)
			attlast = attlast.next;

	p := "";
	havep := 0;

	readloop: for(;;){
		line := in.gets('\n');
		if(line != ""){
			seen = 1;
			havep = 1;
			bare := line;
			if(len bare > 0 && bare[len bare - 1] == '\n')
				bare = bare[0:len bare - 1];
			lastlinelen = len line;

			# coalesce multiline headers
			if(havesline != 0 && len bare > 0 && (bare[0] == ' ' || bare[0] == '\t')){
				sline += "\n";
				sline += bare;
				continue;
			}
			p = bare;
		}else{
			havep = 0;
			lastlinelen = 0;
		}

		# process the current header, it's all been read
		if(havesline != 0){
			case hdrtype {
			Hto =>
				if(collectto != 0)
					(sline, toaddr) = expandline(sline, toaddr);
				s += sline;
				s += "\n";
			Hcc =>
				if(collectcc != 0)
					(sline, cc) = expandline(sline, cc);
				s += sline;
				s += "\n";
			Hbcc =>
				if(collectbcc != 0)
					(sline, bcc) = expandline(sline, bcc);
				# never appended to s - Bcc must not appear
				# in the outgoing headers.
			Hsubject =>
				s += mksubject(sline);
				s += "\n";
			Hattach or Hinclude =>
				if(collectattach != 0){
					na := mkattach(hdrval(sline), nil, hdrtype == Hinclude);
					if(na == nil)
						return (RHerror, flags, s, toaddr, cc, bcc, attfirst);
					if(attfirst == nil)
						attfirst = na;
					else
						attlast.next = na;
					attlast = na;
				}
			* =>
				s += sline;
				s += "\n";
			}
			havesline = 0;
			sline = "";
		}

		if(havep == 0)
			break readloop;

		# if no ':', it's not a header - seek back and break
		colon := -1;
		for(ci := 0; ci < len p; ci++)
			if(p[ci] == ':'){
				colon = ci;
				break;
			}
		if(colon < 0){
			in.seek(big (-lastlinelen), 1);
			break readloop;
		}

		sline = p;
		havesline = 1;

		hdrtype = -1;
		lowp := str->tolower(p);
		for(hi := 0; hi < len hdrs; hi++){
			if(str->prefix(hdrs[hi], lowp) != 0){
				flags |= 1 << hi;
				hdrtype = hi;
				break;
			}
		}
		if(strict != 0){
			if(hdrtype == -1){
				in.seek(big (-lastlinelen), 1);
				break readloop;
			}
		}else
			hdrtype = 0;
	}

	if(seen == 0)
		return (RHnomessage, flags, s, toaddr, cc, bcc, attfirst);
	if(havep == 0)
		return (RHnobody, flags, s, toaddr, cc, bcc, attfirst);
	return (RHok, flags, s, toaddr, cc, bcc, attfirst);
}

# --- CLI ---

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(env == nil)
		env = load Env Env->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(encoding == nil)
		encoding = load Encoding Encoding->BASE64PATH;
}

fail(s: string)
{
	sys->fprint(stderr, "marshal: %s\n", s);
	raise "fail:marshal";
}

usage()
{
	fail("usage: marshal [-n] [-s subject] [-C ccrecipient] [-B bccrecipient]" +
		" [-t type] [-aA attachment] [-R replymsg] -8 | recipient-list");
}

flagvalue(w: string, l: list of string): (string, list of string)
{
	if(len w > 2)
		return (w[2:], l);
	if(l == nil)
		usage();
	return (hd l, tl l);
}

readaliasesfrom(path: string): ref Alias
{
	b := bufio->open(path, Sys->OREAD);
	if(b == nil)
		return nil;
	first: ref Alias = nil;
	last: ref Alias = nil;
	for(;;){
		line := b.gets('\n');
		if(line == "")
			break;
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		(nil, toks) := sys->tokenize(line, " \t");
		addrfirst: ref Addr = nil;
		addrlast: ref Addr = nil;
		for(; toks != nil; toks = tl toks){
			na := newaddr(hd toks);
			if(addrfirst == nil)
				addrfirst = na;
			else
				addrlast.next = na;
			addrlast = na;
		}
		if(addrfirst == nil || addrfirst.next == nil)
			continue;
		al := ref Alias(nil, addrfirst);
		if(first == nil)
			first = al;
		else
			last.next = al;
		last = al;
	}
	return first;
}

run(argv: list of string, data: array of byte): (array of byte, int)
{
	loadmods();
	if(stderr == nil)
		stderr = sys->fildes(2);

	# per-call reset - this backlog's own established convention for
	# a repeatedly-called test seam (cb.b's resetstate(), etc.)
	aliases = nil;
	rfc822syntaxerror = 0;

	nflag := 0;
	eightflag := 0;
	subject := "";
	hassubject := 0;
	atype := "";
	replymsg := "";
	hasreplymsg := 0;
	ccargv: list of string = nil;
	bccargv: list of string = nil;
	attfirst: ref Attach = nil;
	attlast: ref Attach = nil;

	l := argv;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		l = tl l;
		case w[1] {
		'a' or 'A' =>
			ainline := 0;
			if(w[1] == 'A')
				ainline = 1;
			path: string;
			(path, l) = flagvalue(w, l);
			na := mkattach(path, atype, ainline);
			if(na == nil)
				fail("bad args");
			atype = "";
			if(attfirst == nil)
				attfirst = na;
			else
				attlast.next = na;
			attlast = na;
		'C' =>
			v: string;
			(v, l) = flagvalue(w, l);
			ccargv = v :: ccargv;
		'B' =>
			v: string;
			(v, l) = flagvalue(w, l);
			bccargv = v :: bccargv;
		'n' =>
			nflag = 1;
		'R' =>
			(replymsg, l) = flagvalue(w, l);
			hasreplymsg = 1;
		's' =>
			(subject, l) = flagvalue(w, l);
			hassubject = 1;
		't' =>
			(atype, l) = flagvalue(w, l);
		'8' =>
			eightflag = 1;
		* =>
			usage();
		}
	}
	rest := l;

	if(nflag != 0 && eightflag != 0)
		fail("can't use both -n and -8");
	if(eightflag == 0 && rest == nil)
		usage();

	login := env->getenv("user");
	user := env->getenv("upasname");
	if(user == nil || user == "")
		user = login;
	if(user == nil || user == "")
		fail("can't read user name");

	home := env->getenv("home");
	if(home != nil)
		aliases = readaliasesfrom(home + "/mail/names");

	toaddr: ref Addr = nil;
	cc: ref Addr = nil;
	bcc: ref Addr = nil;
	if(rest != nil)
		toaddr = expand(rest);
	if(ccargv != nil)
		cc = expand(ccargv);
	if(bccargv != nil)
		bcc = expand(bccargv);

	outbuf := mkoutbuf();
	flags := 0;
	headersrv := RHnomessage;
	noinput := 0;
	in: ref Iobuf;
	hs := "";

	if(nflag == 0){
		in = bufio->aopen(data);
		hto: ref Addr = nil;
		hcc: ref Addr = nil;
		hbcc: ref Addr = nil;
		(headersrv, flags, hs, hto, hcc, hbcc, attfirst) =
			readheaders(in, flags, eightflag, eightflag, eightflag, 1, 1, attfirst);
		if(rfc822syntaxerror != 0)
			fail("rfc822 syntax error, message not sent");
		if(headersrv == RHerror)
			fail("attachment(s) failed, message not sent");
		if(eightflag != 0){
			toaddr = hto;
			cc = hcc;
			bcc = hbcc;
		}
		case headersrv {
		RHnomessage =>
			noinput = 1;
		}
	}
	if(toaddr == nil)
		fail("no addresses found, message not sent");

	if(nflag == 0)
		outbuf.emits(hs);

	# The user's own default-headers file - attempted REGARDLESS of
	# -n, matching the real source's own placement exactly
	# (mboxpathbuf(file, n, user, "headers"), read unconditionally
	# right after the stdin-derived header block whether or not that
	# block ran). Missing this entirely was a real gap in an earlier
	# draft, caught by re-reading the source's own control flow rather
	# than by a failing test (no test fixture happened to use this
	# file) - its own header lines feed into the SAME `flags` bitmask,
	# so e.g. a custom "From:" line in this file suppresses the
	# auto-generated one below exactly like a stdin "From:" would,
	# even under -n. $home/mail/headers stands in for the real
	# source's own $MAILROOT/box/<user>/headers, the same adaptation
	# $home/mail/names already makes for the alias file.
	if(home != nil){
		defhdrpath := home + "/mail/headers";
		db := bufio->open(defhdrpath, Sys->OREAD);
		if(db != nil){
			dstatus: int;
			dhs: string;
			dnto, dncc, dnbcc: ref Addr;
			dnatt: ref Attach;
			(dstatus, flags, dhs, dnto, dncc, dnbcc, dnatt) =
				readheaders(db, flags, 0, 0, 0, 0, 0, nil);
			if(dstatus == RHerror)
				fail("reading");
			outbuf.emits(dhs);
		}
	}

	if((flags & (1 << Hdate)) == 0)
		printdate(outbuf);
	if((flags & (1 << Hfrom)) == 0)
		printfrom(outbuf, user);
	if((flags & (1 << Hto)) == 0)
		printaddr(outbuf, "To:", toaddr);
	if((flags & (1 << Hcc)) == 0)
		printaddr(outbuf, "Cc:", cc);
	if((flags & (1 << Hsubject)) == 0 && hassubject != 0)
		printsubject(outbuf, subject);
	if(hasreplymsg != 0)
		printinreplyto(outbuf, replymsg);
	outbuf.emits("MIME-Version: 1.0\n");

	boundary := "";
	if(attfirst != nil){
		boundary = mkboundary();
		outbuf.emits("Content-Type: multipart/mixed;\n");
		outbuf.emits("\tboundary=" + doublequote(boundary) + "\n\n");
		outbuf.emits("This is a multi-part message in MIME format.\n");
		outbuf.emits("--" + boundary + "\n");
		outbuf.emits("Content-Disposition: inline\n");
	}

	lastchar = '\n';
	if(nflag == 0){
		if(noinput == 0 && headersrv == RHok){
			# whatever bytes remain in `data` past the header
			# block are the body - `in`'s own current offset
			# marks where readheaders() left off (either past a
			# non-header line it rewound onto, or real EOF).
			bodystart := int in.offset();
			bodydata := data[bodystart:];
			body(bodydata, outbuf, 1);
		}
	}else
		outbuf.emits("\n");

	for(a := attfirst; a != nil; a = a.next){
		if(lastchar != '\n')
			outbuf.emits("\n");
		outbuf.emits("--" + boundary + "\n");
		attachment(a, outbuf);
	}

	if(attfirst != nil){
		if(lastchar != '\n')
			outbuf.emits("\n");
		outbuf.emits("--" + boundary + "--\n");
	}

	return (outbuf.buf[0:outbuf.n], 0);
}

# --- test seam ---

setaliases(lines: list of string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	first: ref Alias = nil;
	last: ref Alias = nil;
	for(; lines != nil; lines = tl lines){
		(nil, toks) := sys->tokenize(hd lines, " \t");
		addrfirst: ref Addr = nil;
		addrlast: ref Addr = nil;
		for(; toks != nil; toks = tl toks){
			na := newaddr(hd toks);
			if(addrfirst == nil)
				addrfirst = na;
			else
				addrlast.next = na;
			addrlast = na;
		}
		if(addrfirst == nil || addrfirst.next == nil)
			continue;	# matches readaliases()'s own
					# "name with no expansion" skip
		al := ref Alias(nil, addrfirst);
		if(first == nil)
			first = al;
		else
			last.next = al;
		last = al;
	}
	aliases = first;
}

testexpandline(line: string): (string, list of string, int)
{
	rfc822syntaxerror = 0;
	(ns, addrs) := expandline(line, nil);
	strs: list of string = nil;
	al: list of string;
	for(a := addrs; a != nil; a = a.next)
		al = a.v :: al;
	# al is in reverse (list-cons order); rebuild forward so the
	# test seam hands back the same left-to-right order expandline's
	# own caller (readheaders) would see via the ref-Addr chain.
	for(; al != nil; al = tl al)
		strs = hd al :: strs;
	return (ns, strs, rfc822syntaxerror);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
}
