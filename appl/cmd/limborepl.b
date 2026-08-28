implement Command;

#
# limborepl - type Limbo source at a prompt and watch it run.
#
# See doc/limbo-repl-plan.md for the design this follows. In one sentence:
# disrepl(1) already solved "keep a running program's state across lines
# typed one at a time" one compiler stage down, at raw Dis assembly - this
# is the identical architecture one stage up, at Limbo source, reusing
# /dis/limbo.dis (an ordinary Inferno command, not a stub - appl/cmd/limbo/
# limbo.b, 3107 lines) exactly the way disrepl reuses /dis/asm.dis.
#
# The one genuinely new problem disrepl never had to solve: Limbo source
# has real grammar, and a typed line has to land in one of three different
# places in the generated module - classify() below (via isdecl()) tags
# each line as a module-scope declaration (an adt, a bare module
# variable, or a one-line function definition), an ordinary statement
# that belongs inside init()'s own body, or a bare expression whose
# value should auto-print (see this comment's next paragraph). Getting
# this classification wrong is the actual risk in this file, not the
# process-management machinery below, which is disrepl's own, unchanged
# in spirit.
#
# Redeclaration: Limbo forbids `x := ...` twice in one scope. This REPL
# does not try to detect or rewrite that - type `x = ...` yourself after
# the first `x := ...`, exactly as you would if this were all one
# function body, which after assembly it is. See help() and man/1/
# limborepl's own BUGS for why this was chosen over silently rewriting
# the user's input (doc/limbo-repl-plan.md's own option (b) over (a)).
#
# A typed line with no trailing ';' or '}' auto-prints its own value,
# TempleOS/HolyC-console style, instead of needing an explicit print()
# call - this is the one thing that changed the whole file's design:
# a line typed that way used to be simply a compile error (Limbo
# requires a statement to end in ';'; only a control construct like
# if/for/while/a bare block gets away with ending in '}' instead), so
# the convention claims syntax that was previously dead rather than
# reinterpreting anything that used to work. classify() below tags such
# a line Expr; exprline() rewrites it in place, as one line, no
# temporary and no block:
#	sys->print("%s\n", string (EXPR));
# using Limbo's own built-in cast of an arithmetic value (byte/int/big/
# real) or string to string (doc/limbo/limbo.ms, "Casts to strings") -
# confirmed live against the real compiler, including that the cast is
# genuinely typechecked (a list, array, adt, ... fails to compile with
# the language's own "cannot make a string from ..." diagnostic, not a
# silently wrong answer) and that it is legal directly as a call
# argument, so there is nothing for a temporary variable to buy - an
# earlier version introduced one anyway (plus a { } to scope it),
# purely out of habit from languages where a cast isn't already this
# composable; source-level ahead-of-time compilation, which is what
# this whole file already does, does not need it. A value that cast
# can't handle needs an explicit print() call and a trailing ';',
# exactly as before this file's redesign - see help() and man/1/
# limborepl's own BUGS for what is and isn't covered.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Sfile:	con "/tmp/limborepl.b";
Dfile:	con "/tmp/limborepl.dis";
Limitms: con 3000;		# how long a typed program may run

# The fixed shape of the module every session compiles into. DECLS and
# STMTS below are not literal text in this file - they are the markers
# assembly() looks for and replaces with the accumulated lines, in the
# order they were typed. sys is loaded once, before any typed statement
# runs, so ordinary use (sys->print(...)) needs no load of its own.
header := array[] of {
	"implement Limborepl;",
	"",
	"include \"sys.m\";",
	"\tsys: Sys;",
	"include \"draw.m\";",
	"",
	"Limborepl: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };",
	"",
	"DECLS",
	"",
	"init(ctxt: ref Draw->Context, argv: list of string)",
	"{",
	"\tsys = load Sys Sys->PATH;",
	"STMTS",
	"}",
};

Decl: con 0;	# module-scope declaration - isdecl() said so
Stmt: con 1;	# an ordinary statement, ending in ';' or '}'
Expr: con 2;	# a bare expression - auto-print its value

# One typed line, tagged with where it was classified to go. History is
# most-recent-first, exactly like disrepl's own `session` - .drop needs
# to remove the last thing typed regardless of which bucket it landed
# in, so one combined list is simpler than two independently-ordered
# ones.
Entry: adt
{
	kind:	int;
	line:	string;
};

history: list of ref Entry;	# most recent first
broken := 0;			# the program does not currently compile
ctxt: ref Draw->Context;

lines: chan of string;
pending: list of string;
readerpid := -1;

reader(in: ref Iobuf, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		l := in.gets('\n');
		lines <-= l;
		if(l == nil)
			break;
	}
}

trim(l: string): string
{
	l = str->drop(l, " \t");
	while(len l > 0 && (l[len l-1] == ' ' || l[len l-1] == '\t' || l[len l-1] == '\n'))
		l = l[0:len l-1];
	return l;
}

nextline(): string
{
	if(pending != nil){
		l := hd pending;
		pending = tl pending;
		return l;
	}
	return <-lines;
}

usage()
{
	fprint(sys->fildes(2), "usage: limborepl\n");
	raise "fail:usage";
}

help()
{
	print("Type a Limbo statement or declaration; each is added to the program\n");
	print("and the whole program is compiled and run again.\n");
	print("\n");
	print("Statements (most typing) go inside init()'s own body - sys is\n");
	print("already loaded, so sys->print(...) etc. work right away.\n");
	print("\n");
	print("Declarations go at module scope instead - anything of the shape\n");
	print("    Name: adt { ... };\n");
	print("    name: SomeType;\n");
	print("    square(x: int): int { return x*x; }\n");
	print("(a one-line function definition - this REPL takes one line per\n");
	print("entry, so a multi-line function body has to be written on one\n");
	print("line, semicolons and all).\n");
	print("\n");
	print("Limbo forbids declaring the same name with := twice in one scope.\n");
	print("This REPL does not rewrite what you type - if you already wrote\n");
	print("`x := 5;`, write `x = 6;` the next time, not another `:=`.\n");
	print("\n");
	print("A line ending in ';' or '}' runs as an ordinary statement, same\n");
	print("as always. A line that does NOT end that way is a bare\n");
	print("expression - its value is printed automatically, TempleOS/HolyC\n");
	print("console style, with no print() call of your own needed. This\n");
	print("works for byte, int, big, real, and string values (Limbo's own\n");
	print("string-cast); anything else (a list, array, adt, ...) needs an\n");
	print("explicit print() call and a trailing ';', same as before.\n");
	print("\n");
	print("    .list     show the program so far\n");
	print("    .drop     remove the last line\n");
	print("    .clear    start again\n");
	print("    .src      show the source that would be compiled\n");
	print("    .help     this\n");
	print("    .quit     leave\n");
	print("    !         stop a program that is still running\n");
	print("\n");
	print("For example:  x := 6;\n");
	print("              y := 7;\n");
	print("              x*y                                prints 42\n");
	print("\n");
	print("A program that runs longer than %d seconds is stopped and the\n", Limitms/1000);
	print("line just typed is not kept.\n");
}

# isdecl: the one genuinely new problem this file has that disrepl did
# not - see this file's own header comment. Deliberately rough, per
# doc/limbo-repl-plan.md's own "even a rough one" - three shapes are
# recognised, everything else is a statement:
#
#   1. `include "...";` - an extra module include.
#   2. `IDENT (, IDENT)*: <rest>` where <rest> does NOT start with a
#      loop/alt/pick/case keyword - a module-scope adt/module/plain-typed
#      variable declaration, including Limbo's own multi-name shape
#      (`x, y: int;`). The exclusion matters: `loop: for(;;){...}` is a
#      LABELED STATEMENT (this backlog's own marshal.b uses exactly
#      this shape for its own parseloop:), not a declaration, and the
#      two are told apart only by what follows the colon. The
#      comma-separated-names scan matters too: without it, `x, y: int;`
#      stops at the comma, never reaches a `:`, falls through as a
#      statement, and silently compiles anyway - `x, y: int;` is ALSO
#      legal Limbo inside a function body, just a local instead of the
#      module-scope global the user asked for. Confirmed as a real gap
#      via advisor review, not caught by any test before this fix.
#   3. `IDENT(...)  ...  { ... }` with the line's own brace count
#      balanced back to zero by its end - a one-line function
#      definition. The brace check is what tells this apart from an
#      ordinary function-call STATEMENT like `foo(1, 2, 3);`, which
#      starts the same way but has no brace at all.
isident(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') || c == '_';
}

isspace(c: int): int
{
	return c == ' ' || c == '\t';
}

isdecl(line: string): int
{
	if(len line >= 8 && line[0:8] == "include ")
		return 1;

	n := len line;
	i := 0;
	while(i < n && isident(line[i]))
		i++;
	# Skip over any further `, IDENT` names - Limbo allows declaring
	# several names at once against one trailing type (`x, y: int;`).
	while(i > 0){
		j := i;
		while(j < n && isspace(line[j]))
			j++;
		if(j >= n || line[j] != ',')
			break;
		j++;
		while(j < n && isspace(line[j]))
			j++;
		k := j;
		while(k < n && isident(line[k]))
			k++;
		if(k == j)
			break;	# a comma not followed by a name after all
		i = k;
	}
	if(i > 0 && i < n && line[i] == ':' && (i+1 >= n || line[i+1] != '=')){
		rest := str->drop(line[i+1:], " \t");
		if(str->prefix("for", rest) || str->prefix("while", rest) ||
		   str->prefix("case", rest) || str->prefix("alt", rest) ||
		   str->prefix("pick", rest) || str->prefix("do", rest))
			return 0;	# a labeled statement, not a declaration
		return 1;
	}

	if(i > 0 && i < n && line[i] == '('){
		depth := 0;
		hasbrace := 0;
		for(k := 0; k < n; k++)
			case line[k] {
			'{' =>
				depth++;
				hasbrace = 1;
			'}' =>
				depth--;
			}
		if(hasbrace != 0 && depth == 0)
			return 1;	# a one-line function definition
	}
	return 0;
}

# classify: the one genuinely new problem this file's redesign added.
# isdecl() (below) still says whether a line is a module-scope
# declaration; what's new is telling an ordinary statement apart from a
# bare expression whose value should auto-print, using the trailing
# ';'/'}' convention explained in this file's own header comment.
classify(line: string): int
{
	if(isdecl(line) != 0)
		return Decl;
	n := len line;
	if(n > 0 && (line[n-1] == ';' || line[n-1] == '}'))
		return Stmt;
	return Expr;
}

# Wrap a bare expression so it evaluates and prints its own value - see
# this file's own header comment for why this particular cast. The
# cast goes straight into the print() call as one line, no temporary
# to hold it and no block to scope one in - confirmed against the real
# compiler that string(EXPR) is legal directly as a call argument, so
# there is nothing here for a temporary to buy.
exprline(line: string): string
{
	return "\tsys->print(\"%s\\n\", string (" + line + "));";
}

# The session's declarations, oldest first.
decls(): list of string
{
	r: list of string;
	for(h := history; h != nil; h = tl h)
		if((hd h).kind == Decl)
			r = (hd h).line :: r;
	return r;
}

# The session's statements and auto-print expressions, oldest first,
# tab-indented (Limbo does not care about indentation, but it makes
# .src readable). An Expr entry contributes exprline()'s rewritten
# line, not the bare line the user typed - that line by itself is not
# something Limbo accepts as a statement (see the header comment).
stmts(): list of string
{
	r: list of string;
	for(h := history; h != nil; h = tl h){
		e := hd h;
		case e.kind {
		Stmt =>
			r = "\t" + e.line :: r;
		Expr =>
			r = exprline(e.line) :: r;
		}
	}
	return r;
}

joinlines(a: list of string, sep: string): string
{
	s := "";
	first := 1;
	for(; a != nil; a = tl a){
		if(!first)
			s += sep;
		s += hd a;
		first = 0;
	}
	return s;
}

# header with DECLS/STMTS replaced by the accumulated lines, oldest
# first. An empty bucket leaves nothing where the marker was, same as
# disrepl leaving its own Marker instruction in place for an empty
# session - here there's nothing to preserve either way since a bare
# "DECLS"/"STMTS" line, once removed, is just a blank line.
source(): list of string
{
	out: list of string;
	d := decls();
	s := stmts();
	for(i := 0; i < len header; i++){
		h := header[i];
		if(h == "DECLS"){
			for(dl := d; dl != nil; dl = tl dl)
				out = hd dl :: out;
			continue;
		}
		if(h == "STMTS"){
			for(sl := s; sl != nil; sl = tl sl)
				out = hd sl :: out;
			continue;
		}
		out = h :: out;
	}
	r: list of string;
	for(l := out; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

writes(path: string, ls: list of string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sprint("create %s: %r", path);
	for(; ls != nil; ls = tl ls){
		s := hd ls + "\n";
		b := array of byte s;
		if(sys->write(fd, b, len b) != len b)
			return sprint("write %s: %r", path);
	}
	return nil;
}

runcmd(path: string, argv: list of string): string
{
	c := load Command path;
	if(c == nil)
		return sprint("load %s: %r", path);
	err: string;
	{
		c->init(ctxt, argv);
	} exception e {
	"*" =>
		err = e;
	}
	return err;
}

Killed:	con "did not finish";
Intr:	con "interrupted";

runner(c: Command, argv: list of string, pidc: chan of int, done: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	err: string;
	{
		c->init(ctxt, argv);
	} exception e {
	"*" =>
		err = e;
	}
	done <-= err;
}

ticker(ms: int, pidc: chan of int, c: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

# Identical in shape and reasoning to disrepl's own timedrun() - see its
# own comment in appl/cmd/disrepl.b for why each piece (buffered
# channels, the ticker as a backstop, "!" as the only available
# interrupt on this platform, queuing non-interrupt input that arrives
# mid-run) is there. Nothing about running compiled Limbo instead of
# raw Dis assembly changes any of it.
timedrun(path: string, argv: list of string): string
{
	c := load Command path;
	if(c == nil)
		return sprint("load %s: %r", path);
	pidc := chan[1] of int;
	done := chan[1] of string;
	spawn runner(c, argv, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	tpidc := chan[1] of int;
	spawn ticker(Limitms, tpidc, tc);
	tpid := <-tpidc;
	for(;;){
		alt {
		err := <-done =>
			kill(tpid);
			return err;
		l := <-lines =>
			if(l != nil && trim(l) == "!"){
				kill(pid);
				kill(tpid);
				return Intr;
			}
			pending = append(pending, l);
		<-tc =>
			kill(pid);
			return Killed;
		}
	}
}

append(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: append(tl l, s);
}

shutdown()
{
	if(readerpid >= 0)
		kill(readerpid);
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		fprint(fd, "kill");
}

# Compile the accumulated source with /dis/limbo.dis, run as an ordinary
# Command exactly as disrepl invokes /dis/asm.dis. A compile error's own
# diagnostic text is printed directly to stderr by the compiler itself
# (limbo.b's own yyerror()/lex.b fprint(stderr,...)), not captured here -
# the string this function returns is only the generic "fail:errors"
# tag it raises, matching disrepl's own asm-error handling exactly.
build(): string
{
	sys->remove(Dfile);
	if((e := writes(Sfile, source())) != nil)
		return e;
	if((e = runcmd("/dis/limbo.dis", "limbo" :: Sfile :: nil)) != nil)
		return "compiler: " + e;
	if(sys->stat(Dfile).t0 < 0)
		return sprint("the compiler produced no %s", Dfile);
	return nil;
}

run(): int
{
	e := build();
	broken = e != nil;
	if(e != nil){
		print("%s\n", e);
		return 0;
	}
	e = timedrun(Dfile, "limborepl" :: nil);
	if(e == Killed){
		print("stopped after %d seconds - it did not finish\n", Limitms/1000);
		return 0;
	}
	if(e == Intr){
		print("interrupted\n");
		return 0;
	}
	if(e != nil)
		print("%s\n", e);
	return 1;
}

init(c: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	if(bufio == nil || str == nil){
		print("limborepl: load: %r\n");
		raise "fail:load";
	}
	if(tl argv != nil)
		usage();
	ctxt = c;

	if(sys->stat("/dis/limbo.dis").t0 < 0){
		print("limborepl: /dis/limbo.dis is missing - mk it in appl/cmd/limbo\n");
		raise "fail:no tools";
	}

	if(sys->chdir("/tmp") < 0){
		print("limborepl: chdir /tmp: %r\n");
		raise "fail:no /tmp";
	}

	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(in == nil){
		print("limborepl: cannot read stdin: %r\n");
		raise "fail:stdin";
	}
	lines = chan of string;
	rp := chan of int;
	spawn reader(in, rp);
	readerpid = <-rp;

	print("limbo repl - .help for help, .quit to leave, ! to interrupt\n");
	for(;;){
		print("limbo> ");
		line := nextline();
		if(line == nil){
			print("\n");
			shutdown();
			return;
		}
		line = trim(line);
		if(line == nil)
			continue;

		case line {
		"!" =>
			print("(nothing running)\n");
		".quit" or ".q" =>
			shutdown();
			return;
		".help" or ".h" or "?" =>
			help();
		".list" or ".l" =>
			n := 0;
			r: list of string;
			for(h := history; h != nil; h = tl h)
				r = (hd h).line :: r;
			for(l := r; l != nil; l = tl l)
				print("%3d  %s\n", n++, hd l);
			if(n == 0)
				print("(nothing yet)\n");
		".drop" =>
			if(history == nil)
				print("(nothing to drop)\n");
			else{
				print("dropped: %s\n", (hd history).line);
				history = tl history;
				if(!run())
					print("the program no longer compiles - " +
						"drop more, or add what it needs\n");
			}
		".clear" =>
			history = nil;
			broken = 0;
			print("cleared\n");
		".src" =>
			for(l := source(); l != nil; l = tl l)
				print("%s\n", hd l);
		* =>
			if(len line > 0 && line[0] == '.'){
				print("no such command: %s (.help)\n", line);
				continue;
			}
			wasbroken := broken;
			history = ref Entry(classify(line), line) :: history;
			if(!run() && !wasbroken){
				history = tl history;
				print("not added\n");
			}
		}
	}
}
