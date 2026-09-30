implement Lil;

#
# Little Limbo: an interpreted subset of the language, for boards with
# no room for a shell.
#
# WHY NOT A SHELL.  os/inferno/stm32f407 has 147456 bytes of RAM, and
# its own mkfile records what sh costs there: "loading /dis/sh.dis asks
# malloc for 73536 bytes for its Inst array alone".  XIP puts that array
# in flash, which is the only reason a shell runs at all -- but the
# shell's semantics are the expensive part and XIP does not help with
# those.  A command is a process and a redirection is an open, so
# driving a radio from the console forks twice per line, fragments the
# heap, and eventually cannot fork at all; then nothing drains the
# console queue and the kernel reaches "allocb: no memory".
#
# WHY NOT A SMALLER SHELL.  Because it would keep the thing that costs.
# What is wanted is a language: open a file once, hold it in a variable,
# write to it as often as you like.  No process per statement and no
# open per line.
#
#	ctl := sys->open("/dev/radio0/ctl", sys->OWRITE);
#	sys->fprint(ctl, "freq 915000000");
#	sys->fprint(ctl, "rate 9600");
#
# WHY LIMBO'S SYNTAX.  Because it is the syntax this tree already
# writes, so what is typed at the console and what is compiled into a
# .dis look alike.  A Forth would be smaller and a Tcl more uniform;
# both would be one more language to know for no gain.
#
# HOW IT STAYS SMALL.  Two decisions.
#
# There is no syntax tree.  A "while" remembers the source text of its
# condition and its body and re-scans them each time round.  That is
# slow, and it is the trade a Forth makes too: size over speed, on a
# machine where a human types the program one line at a time.
#
# WHAT IT DOES NOT HAVE, that a reader will look for.  No functions of
# one's own, no lists, no tuples, no declared types, no "for", no && or
# ||, no ~ or regular expressions, no globbing, no pipes, and no
# redirection -- the last three on purpose, since they are the shell
# semantics this exists to avoid.  No "else if" either: an else takes a
# block and not another if.
#
# There are three kinds of value -- int, string, and an open file --
# because holding a file descriptor across statements is the entire
# point.  No lists, no tuples, no ADTs, no modules.  A program that
# wants those should be compiled.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Lil: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

# what a value can be
Vnil, Vint, Vstr, Vfd: con iota;

Val: adt
{
	kind:	int;
	n:	big;
	s:	string;
	fd:	ref Sys->FD;
};

Var: adt
{
	name:	string;
	v:	Val;
};

vars: list of ref Var;
failed: string;			# non-nil once a statement has gone wrong
looplimit := 60000;		# ms a single while may run; see stmt()

# 0: no if is waiting for an else.  1: one ran its body.  2: one did not.
#
# This is what lets "else" begin a line of its own.  A line is read as
# complete once its brackets balance, so "if(x){ ... }" has already run
# by the time the next line arrives, and there is nothing to look ahead
# with.  Rather than make that a rule the typist has to remember,
# remember the if instead.
pendingelse := 0;

stdout, stderr: ref Sys->FD;

nilval(): Val
{
	return Val(Vnil, big 0, nil, nil);
}

intval(n: big): Val
{
	return Val(Vint, n, nil, nil);
}

strval(s: string): Val
{
	return Val(Vstr, big 0, s, nil);
}

fdval(fd: ref Sys->FD): Val
{
	return Val(Vfd, big 0, nil, fd);
}

# A value as text, which is what print wants and what a condition does
# not: only ints are truthy, so that "while(fd)" is a mistake rather
# than a loop.
text(v: Val): string
{
	case v.kind {
	Vint =>	return string v.n;
	Vstr =>	return v.s;
	Vfd =>	return "<fd>";
	}
	return "nil";
}

truth(v: Val): int
{
	if(v.kind == Vint)
		return v.n != big 0;
	if(v.kind == Vstr)
		return v.s != nil;
	return v.kind != Vnil;
}

getvar(name: string): (int, Val)
{
	for(l := vars; l != nil; l = tl l)
		if((hd l).name == name)
			return (1, (hd l).v);
	return (0, nilval());
}

# A ref and not a value, so that assigning to a variable that exists
# writes through it.  Holding them by value meant rebuilding the whole
# list on every assignment, which is an allocation per iteration of
# every loop, on the board whose mkfile records what fragmentation
# costs here.
setvar(name: string, v: Val)
{
	for(l := vars; l != nil; l = tl l)
		if((hd l).name == name){
			(hd l).v = v;
			return;
		}
	vars = ref Var(name, v) :: vars;
}

fail(s: string)
{
	if(failed == nil)
		failed = s;
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isalpha(c: int): int
{
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

# Skip whitespace and comments from p, returning the new position.
skip(s: string, p: int): int
{
	while(p < len s){
		if(isspace(s[p])){
			p++;
			continue;
		}
		if(s[p] == '#'){
			while(p < len s && s[p] != '\n')
				p++;
			continue;
		}
		break;
	}
	return p;
}

# The position just past a bracketed run starting at p, which must be
# on the opening bracket.  Counts nesting and ignores brackets inside
# strings, because "}" in a message should not end a block.
matching(s: string, p: int, open: int, close: int): int
{
	depth := 0;
	while(p < len s){
		c := s[p];
		if(c == '"'){
			p++;
			while(p < len s && s[p] != '"'){
				if(s[p] == '\\' && p+1 < len s)
					p++;
				p++;
			}
			p++;
			continue;
		}
		if(c == open)
			depth++;
		else if(c == close){
			depth--;
			if(depth == 0)
				return p+1;
		}
		p++;
	}
	return -1;
}

# an identifier at p, or nil
word(s: string, p: int): (string, int)
{
	if(p >= len s || !isalpha(s[p]))
		return (nil, p);
	q := p;
	while(q < len s && (isalpha(s[q]) || isdigit(s[q])))
		q++;
	return (s[p:q], q);
}

# Does the text at p start with this operator?  Longest first, so that
# "==" is not read as "=" twice.
has(s: string, p: int, op: string): int
{
	if(p + len op > len s)
		return 0;
	return s[p:p+len op] == op;
}

primary(s: string, p: int): (Val, int)
{
	p = skip(s, p);
	if(p >= len s){
		fail("expression ended early");
		return (nilval(), p);
	}
	c := s[p];
	if(c == '('){
		q := matching(s, p, '(', ')');
		if(q < 0){
			fail("unclosed (");
			return (nilval(), len s);
		}
		(v, nil) := expr(s[p+1:q-1], 0);
		return (v, q);
	}
	if(c == '"'){
		q := p+1;
		out := "";
		while(q < len s && s[q] != '"'){
			if(s[q] == '\\' && q+1 < len s){
				q++;
				case s[q] {
				'n' =>	out[len out] = '\n';
				't' =>	out[len out] = '\t';
				* =>	out[len out] = s[q];
				}
			}else
				out[len out] = s[q];
			q++;
		}
		return (strval(out), q+1);
	}
	# Unary minus.  The radio work is full of negative numbers that are
	# arguments and not subtractions -- csthr -104, rssioffset -90 -- and
	# without this they can only be written as strings.
	if(c == '-'){
		(v, q) := primary(s, p+1);
		if(v.kind != Vint){
			fail("minus wants a number");
			return (nilval(), q);
		}
		return (intval(-v.n), q);
	}
	if(isdigit(c)){
		q := p;
		# Hex, because every register and sync word on this bench is
		# written that way.  Both spellings: 0x for what the data
		# sheet and the host tools use, 16r for what Limbo uses.
		base := big 10;
		if(c == '0' && p+1 < len s && (s[p+1] == 'x' || s[p+1] == 'X')){
			base = big 16;
			q = p+2;
		}else if(c == '1' && has(s, p, "16r")){
			base = big 16;
			q = p+3;
		}
		n := big 0;
		digits := 0;
		while(q < len s){
			d := -1;
			if(isdigit(s[q]))
				d = s[q] - '0';
			else if(base == big 16 && s[q] >= 'a' && s[q] <= 'f')
				d = s[q] - 'a' + 10;
			else if(base == big 16 && s[q] >= 'A' && s[q] <= 'F')
				d = s[q] - 'A' + 10;
			if(d < 0 || big d >= base)
				break;
			n = n*base + big d;
			digits++;
			q++;
		}
		if(digits == 0){
			fail("a number with no digits at: " + s[p:]);
			return (nilval(), len s);
		}
		return (intval(n), q);
	}
	(w, q) := word(s, p);
	if(w == nil){
		fail("cannot read an expression at: " + s[p:]);
		return (nilval(), len s);
	}
	# a call?
	r := skip(s, q);
	if(r < len s && s[r] == '('){
		e := matching(s, r, '(', ')');
		if(e < 0){
			fail("unclosed ( in call to " + w);
			return (nilval(), len s);
		}
		return (call(w, s[r+1:e-1]), e);
	}
	(ok, v) := getvar(w);
	if(!ok){
		fail(w + " is not set");
		return (nilval(), q);
	}
	return (v, q);
}

# Binary operators, lowest precedence level first.  Two levels is
# enough for what a console program compares and adds; anything wanting
# more should be compiled.
expr(s: string, lvl: int): (Val, int)
{
	if(lvl == 0){
		(l, p) := expr(s, 1);
		for(;;){
			p = skip(s, p);
			op := "";
			if(has(s, p, "==")) op = "==";
			else if(has(s, p, "!=")) op = "!=";
			else if(has(s, p, "<=")) op = "<=";
			else if(has(s, p, ">=")) op = ">=";
			else if(has(s, p, "<")) op = "<";
			else if(has(s, p, ">")) op = ">";
			if(op == nil)
				return (l, p);
			(r, q) := expr(s[p+len op:], 1);
			p = p + len op + q;
			l = compare(op, l, r);
		}
	}
	(l, p) := primary(s, 0);
	for(;;){
		p = skip(s, p);
		if(p >= len s)
			return (l, p);
		c := s[p];
		if(c != '+' && c != '-' && c != '*' && c != '/')
			return (l, p);
		if(has(s, p, "+") && p+1 < len s && s[p+1] == '+')
			return (l, p);
		(r, q) := primary(s, p+1);
		p = q;
		l = arith(c, l, r);
	}
}

arith(op: int, a: Val, b: Val): Val
{
	if(op == '+' && (a.kind == Vstr || b.kind == Vstr))
		return strval(text(a) + text(b));
	if(a.kind != Vint || b.kind != Vint){
		fail("arithmetic wants numbers");
		return nilval();
	}
	case op {
	'+' =>	return intval(a.n + b.n);
	'-' =>	return intval(a.n - b.n);
	'*' =>	return intval(a.n * b.n);
	'/' =>
		if(b.n == big 0){
			fail("divide by zero");
			return nilval();
		}
		return intval(a.n / b.n);
	}
	return nilval();
}

compare(op: string, a: Val, b: Val): Val
{
	r := 0;
	if(a.kind == Vstr || b.kind == Vstr){
		x := text(a);
		y := text(b);
		case op {
		"==" =>	r = x == y;
		"!=" =>	r = x != y;
		"<" =>	r = x < y;
		">" =>	r = x > y;
		"<=" =>	r = x <= y;
		">=" =>	r = x >= y;
		}
	}else{
		case op {
		"==" =>	r = a.n == b.n;
		"!=" =>	r = a.n != b.n;
		"<" =>	r = a.n < b.n;
		">" =>	r = a.n > b.n;
		"<=" =>	r = a.n <= b.n;
		">=" =>	r = a.n >= b.n;
		}
	}
	return intval(big r);
}

# Split an argument list on commas that are not inside brackets or
# strings, and evaluate each.
argv(s: string): array of Val
{
	n := 0;
	parts := array[8] of string;
	p := 0;
	start := 0;
	depth := 0;
	while(p < len s){
		c := s[p];
		if(c == '"'){
			p++;
			while(p < len s && s[p] != '"'){
				if(s[p] == '\\' && p+1 < len s)
					p++;
				p++;
			}
		}else if(c == '(' )
			depth++;
		else if(c == ')')
			depth--;
		else if(c == ',' && depth == 0){
			if(n >= len parts){
				fail("more than " + string len parts +
					" arguments to one call");
				return array[0] of Val;
			}
			parts[n++] = s[start:p];
			start = p+1;
		}
		p++;
	}
	if(skip(s, start) < len s){
		if(n >= len parts){
			fail("more than " + string len parts +
				" arguments to one call");
			return array[0] of Val;
		}
		parts[n++] = s[start:];
	}
	a := array[n] of Val;
	for(i := 0; i < n; i++){
		(v, nil) := expr(parts[i], 0);
		a[i] = v;
	}
	return a;
}

# The builtins.  These are the whole point: each one does in a
# statement what a shell would do with a process and an open.
call(name: string, args: string): Val
{
	a := argv(args);

	# An argument that failed must not still be passed.  Without this,
	# "write(ctl, read(f, 8))" whose read failed went on to write the
	# string "nil" to the ctl file -- an argument nobody typed, reaching
	# a transmitter.  The failure is already recorded; do nothing more.
	if(failed != nil)
		return nilval();

	case name {
	"print" =>
		out := "";
		for(i := 0; i < len a; i++)
			out += text(a[i]);
		out[len out] = '\n';
		b := array of byte out;
		sys->write(stdout, b, len b);
		return nilval();
	"open" =>
		if(len a < 1){
			fail("open wants a path");
			return nilval();
		}
		mode := Sys->OREAD;
		if(len a > 1 && text(a[1]) == "w")
			mode = Sys->OWRITE;
		else if(len a > 1 && text(a[1]) == "rw")
			mode = Sys->ORDWR;
		fd := sys->open(text(a[0]), mode);
		if(fd == nil){
			fail("cannot open " + text(a[0]));
			return nilval();
		}
		return fdval(fd);
	"create" =>
		if(len a < 1){
			fail("create wants a path");
			return nilval();
		}
		fd := sys->create(text(a[0]), Sys->OWRITE, 8r666);
		if(fd == nil){
			fail("cannot create " + text(a[0]));
			return nilval();
		}
		return fdval(fd);
	"write" =>
		if(len a < 2 || a[0].kind != Vfd){
			fail("write wants an open file and a string");
			return nilval();
		}
		out := "";
		for(i := 1; i < len a; i++)
			out += text(a[i]);
		b := array of byte out;
		return intval(big sys->write(a[0].fd, b, len b));
	"read" =>
		# One read of at most n bytes, which is what a device file
		# wants: readall blocks until end of file and a ctl or a
		# packet file need never give one.  A short read is a whole
		# answer here, because a Styx read boundary is a message
		# boundary.
		if(len a < 1 || a[0].kind != Vfd){
			fail("read wants an open file");
			return nilval();
		}
		max := 256;
		if(len a > 1 && a[1].kind == Vint)
			max = int a[1].n;
		if(max <= 0 || max > 8192){
			fail("read wants a count between 1 and 8192");
			return nilval();
		}
		buf := array[max] of byte;
		m := sys->read(a[0].fd, buf, len buf);
		if(m < 0){
			fail(sys->sprint("read: %r"));
			return nilval();
		}
		return strval(string buf[0:m]);
	"dir" =>
		# The names in a directory, printed as they are read, and the
		# count returned.
		#
		# This does NOT use sys->dirread, and that is the whole point.
		# dirread converts the entire directory into an array of
		# Sys->Dir in one allocation, with four Limbo strings per
		# entry, and this board cannot afford it: /dev is 2817 bytes
		# of stat data over about 45 entries, and converting it
		# exhausted the 30000 bytes free at a prompt before a single
		# name had been printed.  That is why ls(1) fails here too --
		# "ls /dis" gives out of memory and "ls /dev" after it kills
		# the shell outright -- and it is not ls's code that is too
		# big, which is 6324 bytes of flash.
		#
		# So the stat entries are read raw and the name taken out of
		# each.  A read on a directory returns whole entries only, so
		# a chunk boundary never splits one, and the cost is one
		# buffer for the whole call however large the directory is.
		# Measured: three reads of /dev returned 228, 234 and 230
		# bytes and moved the heap by 256.
		#
		# The layout is libkern/convM2D.c's, and the offsets are its:
		# size[2] type[2] dev[4] qid.type[1] qid.vers[4] qid.path[8]
		# mode[4] atime[4] mtime[4] length[8], then name[s] -- a
		# 16-bit count and that many bytes.  So qid.type is at 8, the
		# name's count at 41 and its text at 43, and the entry is
		# 2+size bytes long.  Little-endian, as GBIT16 is.
		if(len a < 1){
			fail("dir wants a path");
			return nilval();
		}
		fd := sys->open(text(a[0]), Sys->OREAD);
		if(fd == nil){
			fail("cannot open " + text(a[0]));
			return nilval();
		}
		# Larger than any entry Styx can produce -- 49 fixed bytes, a
		# 255-byte name and three 255-byte user names is 1073 -- so a
		# read can never come back short for want of room, which would
		# look exactly like the end of the directory and silently cut
		# the listing off.
		buf := array[1280] of byte;
		count := 0;
		for(;;){
			m := sys->read(fd, buf, len buf);
			if(m < 0){
				fail(sys->sprint("dir: %r"));
				return intval(big count);
			}
			if(m == 0)
				break;
			i := 0;
			while(i + 43 <= m){
				sz := 2 + (int buf[i] | (int buf[i+1] << 8));
				if(sz < 43 || i + sz > m){
					fail("dir: a stat entry of " +
						string sz + " bytes in " +
						string m + " read");
					return intval(big count);
				}
				nl := int buf[i+41] | (int buf[i+42] << 8);
				if(43 + nl > sz){
					fail("dir: a name longer than its entry");
					return intval(big count);
				}
				line := string buf[i+43:i+43+nl];
				if(int buf[i+8] & Sys->QTDIR)
					line += "/";
				line[len line] = '\n';
				b := array of byte line;
				sys->write(stdout, b, len b);
				count++;
				i += sz;
			}
		}
		return intval(big count);
	"timelimit" =>
		# How long a single while may run.  0 removes the bound,
		# which on this board means a loop that does not end can
		# only be left by resetting it.
		if(len a > 0 && a[0].kind == Vint)
			looplimit = int a[0].n;
		return intval(big looplimit);
	"readall" =>
		if(len a < 1 || a[0].kind != Vfd){
			fail("readall wants an open file");
			return nilval();
		}
		out := "";
		buf := array[256] of byte;
		for(;;){
			m := sys->read(a[0].fd, buf, len buf);
			if(m <= 0)
				break;
			out += string buf[0:m];
		}
		return strval(out);
	"slurp" =>
		# open, read it all, close: the one place a whole-file
		# read is worth a helper, because "cat" was most of what
		# the shell was used for here.
		if(len a < 1){
			fail("slurp wants a path");
			return nilval();
		}
		fd := sys->open(text(a[0]), Sys->OREAD);
		if(fd == nil){
			fail("cannot open " + text(a[0]));
			return nilval();
		}
		out := "";
		buf := array[256] of byte;
		for(;;){
			m := sys->read(fd, buf, len buf);
			if(m <= 0)
				break;
			out += string buf[0:m];
		}
		return strval(out);
	"bind" =>
		if(len a < 2){
			fail("bind wants two paths");
			return nilval();
		}
		flags := Sys->MREPL;
		if(len a > 2){
			f := text(a[2]);
			if(f == "a")
				flags = Sys->MAFTER;
			else if(f == "b")
				flags = Sys->MBEFORE;
			else if(f == "c")
				flags = Sys->MREPL|Sys->MCREATE;
		}
		return intval(big sys->bind(text(a[0]), text(a[1]), flags));
	"sleep" =>
		if(len a > 0)
			sys->sleep(int a[0].n);
		return nilval();
	"millisec" =>
		return intval(big sys->millisec());
	"len" =>
		if(len a > 0)
			return intval(big len text(a[0]));
		return intval(big 0);
	}
	fail(name + " is not a builtin");
	return nilval();
}

# One statement.  Returns the position just past it.
stmt(s: string, p: int): int
{
	p = skip(s, p);
	if(p >= len s)
		return p;

	# Take the flag now and clear it: every statement but an if or an
	# else ends the chance to say else, and an else consumes it.
	waiting := pendingelse;
	pendingelse = 0;

	if(has(s, p, "else")){
		(nil, eq) := word(s, p);
		if(waiting == 0){
			fail("else without a preceding if");
			return len s;
		}
		b := skip(s, eq);
		if(b >= len s || s[b] != '{'){
			fail("else wants {");
			return len s;
		}
		be := matching(s, b, '{', '}');
		if(be < 0){
			fail("unclosed { after else");
			return len s;
		}
		if(waiting == 2)
			run(s[b+1:be-1]);
		return be;
	}

	if(s[p] == '{'){
		q := matching(s, p, '{', '}');
		if(q < 0){
			fail("unclosed {");
			return len s;
		}
		run(s[p+1:q-1]);
		return q;
	}

	(w, q) := word(s, p);

	if(w == "while"){
		r := skip(s, q);
		if(r >= len s || s[r] != '('){
			fail("while wants (");
			return len s;
		}
		ce := matching(s, r, '(', ')');
		if(ce < 0){
			fail("unclosed ( after while");
			return len s;
		}
		b := skip(s, ce);
		if(b >= len s || s[b] != '{'){
			fail("while wants {");
			return len s;
		}
		be := matching(s, b, '{', '}');
		if(be < 0){
			fail("unclosed { after while");
			return len s;
		}
		cond := s[r+1:ce-1];
		body := s[b+1:be-1];
		# Re-scanned every time round rather than compiled: this
		# is where the interpreter buys its size back.
		#
		# Bounded by time and not by a count of iterations, because
		# a count is not a timeout: what matters is how long the
		# console goes undrained, not how many times round it got.
		# This board's devcons has no interrupt character -- nothing
		# in kbdputc() turns a keystroke into a note -- so a loop
		# that does not end can only be left by resetting the board,
		# and a mistyped condition should not cost a power cycle.
		#
		# It says so when it trips, rather than quietly returning a
		# half-done loop, and timelimit() raises or removes it for a
		# monitor that is meant to run.
		deadline := big 0;
		if(looplimit > 0)
			deadline = big sys->millisec() + big looplimit;
		for(;;){
			(v, nil) := expr(cond, 0);
			if(failed != nil || !truth(v))
				break;
			run(body);
			if(failed != nil)
				break;
			if(deadline != big 0 && big sys->millisec() > deadline){
				fail("while ran for " + string looplimit +
					"ms and was stopped; this console has no " +
					"interrupt character.  timelimit(ms) raises " +
					"the bound, timelimit(0) removes it");
				break;
			}
		}
		return be;
	}

	if(w == "if"){
		r := skip(s, q);
		if(r >= len s || s[r] != '('){
			fail("if wants (");
			return len s;
		}
		ce := matching(s, r, '(', ')');
		if(ce < 0){
			fail("unclosed ( after if");
			return len s;
		}
		b := skip(s, ce);
		if(b >= len s || s[b] != '{'){
			fail("if wants {");
			return len s;
		}
		be := matching(s, b, '{', '}');
		if(be < 0){
			fail("unclosed { after if");
			return len s;
		}
		(v, nil) := expr(s[r+1:ce-1], 0);
		took := 0;
		if(failed == nil && truth(v)){
			run(s[b+1:be-1]);
			took = 1;
		}
		# else?
		e := skip(s, be);
		(ew, eq) := word(s, e);
		if(ew == "else"){
			eb := skip(s, eq);
			if(eb < len s && s[eb] == '{'){
				ebe := matching(s, eb, '{', '}');
				if(ebe < 0){
					fail("unclosed { after else");
					return len s;
				}
				if(!took && failed == nil)
					run(s[eb+1:ebe-1]);
				return ebe;
			}
		}
		# No else here, so one may still arrive on the next line.
		if(took)
			pendingelse = 1;
		else
			pendingelse = 2;
		return be;
	}

	# close(name).  A statement and not a builtin, because Limbo shuts
	# a file when the last reference to it goes and the reference that
	# matters is the one in the variable table -- which call() cannot
	# reach, since it is handed values and not names.  Written as a
	# builtin it returned success and closed nothing.
	if(w == "close"){
		r := skip(s, q);
		if(r >= len s || s[r] != '('){
			fail("close wants (");
			return len s;
		}
		e := matching(s, r, '(', ')');
		if(e < 0){
			fail("unclosed ( after close");
			return len s;
		}
		(cn, cq) := word(s, skip(s, r+1));
		if(cn == nil || skip(s, cq) != e-1){
			fail("close wants the name of a variable");
			return len s;
		}
		(ok, v) := getvar(cn);
		if(!ok){
			fail(cn + " is not set");
			return len s;
		}
		if(v.kind != Vfd){
			fail(cn + " is not an open file");
			return len s;
		}
		setvar(cn, nilval());
		return e;
	}

	# assignment?  "name := expr" or "name = expr"
	if(w != nil){
		r := skip(s, q);
		if(has(s, r, ":=") || (has(s, r, "=") && !has(s, r, "=="))){
			skiplen := 1;
			decl := 0;
			if(has(s, r, ":=")){
				skiplen = 2;
				decl = 1;
			}
			# ":=" introduces a name and "=" requires one that
			# exists, as in the language this is a subset of.  The
			# point is not purity: a mistyped name on the left of
			# "=" otherwise makes a new variable and the write
			# goes nowhere, silently, which is the whole class of
			# bug a console session cannot see.
			if(!decl){
				(known, nil) := getvar(w);
				if(!known){
					fail(w + " is not set; use := to " +
						"introduce it");
					return len s;
				}
			}
			(v, n) := expr(s[r+skiplen:], 0);
			if(failed != nil)
				return len s;
			setvar(w, v);
			return r + skiplen + n;
		}
	}

	# Otherwise an expression, evaluated for its effect.
	#
	# The slice is load-bearing and was got wrong first: expr's second
	# argument is a precedence level, not a position, and both are int,
	# so "expr(s, p)" compiled without complaint and re-parsed from the
	# start of the line.  "print(\"a\"); print(\"b\")" printed a twice
	# and b never, because the second statement began at p > 0, took the
	# level-1 path, evaluated the first statement again, and came back
	# with a position behind where it started -- which the guard below
	# then read as "no progress" and threw the rest of the line away.
	#
	# It matters more than a wrong answer.  The statement that runs
	# twice here is "write(ctl, ...)", and the file it writes to tunes a
	# transmitter.
	(nil, np) := expr(s[p:], 0);
	if(np <= 0)
		return len s;		# no progress: stop rather than spin
	return p + np;
}

# A sequence of statements separated by ";" or newlines.
run(s: string)
{
	p := 0;
	while(p < len s && failed == nil){
		p = stmt(s, p);
		p = skip(s, p);
		while(p < len s && (s[p] == ';' || s[p] == '\n')){
			p++;
			p = skip(s, p);
		}
	}
}

# Is what has been typed so far a complete statement?  A line ending
# inside braces or parens is continued, which is what makes a while
# loop typable at a console.
complete(s: string): int
{
	depth := 0;
	p := 0;
	while(p < len s){
		c := s[p];
		if(c == '"'){
			p++;
			while(p < len s && s[p] != '"'){
				if(s[p] == '\\' && p+1 < len s)
					p++;
				p++;
			}
		}else if(c == '#'){
			while(p < len s && s[p] != '\n')
				p++;
		}else if(c == '{' || c == '(')
			depth++;
		else if(c == '}' || c == ')')
			depth--;
		p++;
	}
	return depth <= 0;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	# Everything there is, in two lines, because the man page is not on
	# the board and this is the only help there will be.
	say("lil: little Limbo.  x := e; x = e; if(e){} else {}; while(e){}\n");
	say("  print open create read readall slurp write close dir bind\n");
	say("  sleep millisec len timelimit\n");

	buf := array[256] of byte;
	pending := "";
	for(;;){
		if(pending == nil)
			say("; ");
		else
			say("  ");
		n := sys->read(sys->fildes(0), buf, len buf);
		if(n <= 0)
			break;
		pending += string buf[0:n];
		if(!complete(pending))
			continue;
		failed = nil;
		run(pending);
		if(failed != nil)
			say("lil: " + failed + "\n");
		pending = "";
	}
}

say(s: string)
{
	b := array of byte s;
	sys->write(stdout, b, len b);
}
