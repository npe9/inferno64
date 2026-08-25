implement M4;

# A Limbo-native workalike for a bounded subset of m4(1), the macro
# processor - see doc/plan9-port.md's "Rule: Limbo-native, in a separate
# bindable tree". Covers define/undefine, $0-$9/$# substitution, ifdef,
# ifelse (including the chained-triplet form), include, dnl, the default
# `...' quoting (nested, one level stripped), and default #-to-end-of-
# line comments (passed through verbatim, not expanded - a real default
# behaviour this session did not expect and only found by getting a
# real oracle error, "end of file in argument list", from a test program
# that had an unquoted # in it). No divert, no changequote/changecom, no
# syscmd/esyscmd, no builtins beyond the six above - see p9/man/1/m4's
# BUGS.
#
# Every rule below - argument collection strips leading whitespace after
# `(`/`,` but keeps trailing whitespace before `,`/`)`; `name` bare vs
# `name()` differ ($# is 0 vs 1, though $1 is "" either way); quoting
# protects a macro body from premature expansion of macro-shaped text
# inside it - was checked against the host's own m4 with targeted probes
# before writing any of this, the same discipline as p9/cmd/dc.b.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";

M4: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching awk.b/dc.b's runstring.
	runstring:	fn(prog: string): string;
};

stdin, stdout, stderr: ref FD;

Macro: adt
{
	name:	string;
	body:	string;
};

macros:		list of ref Macro;
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
	sys->fprint(stderr, "m4: %s\n", msg);
	raise "fail:m4";
}

findmacro(name: string): ref Macro
{
	for(l := macros; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

setmacro(name: string, body: string)
{
	m := findmacro(name);
	if(m != nil){
		m.body = body;
		return;
	}
	macros = ref Macro(name, body) :: macros;
}

delmacro(name: string)
{
	r: list of ref Macro;
	for(l := macros; l != nil; l = tl l)
		if((hd l).name != name)
			r = hd l :: r;
	macros = r;
}

# define/undefine/ifdef/ifelse/include/dnl are always recognized as
# builtins and can't be redefined or undefined, unlike real m4 where
# they're just regular (if predefined) macros - a bounded-scope choice,
# not an oversight; see BUGS.
isbuiltin(name: string): int
{
	case name {
	"define" or "undefine" or "ifdef" or "ifelse" or "include" or "dnl" =>
		return 1;
	}
	return 0;
}

ismacro(name: string): int
{
	if(isbuiltin(name))
		return 1;
	return findmacro(name) != nil;
}

isnamestart(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

isnamechar(c: int): int
{
	return isnamestart(c) || (c >= '0' && c <= '9');
}

iswhite(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

argnth(args: list of string, n: int): string
{
	i := 0;
	for(l := args; l != nil; l = tl l){
		if(i == n)
			return hd l;
		i++;
	}
	return "";
}

nargs(args: list of string): int
{
	n := 0;
	for(l := args; l != nil; l = tl l)
		n++;
	return n;
}

revstrlist(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readfile(fname: string): string
{
	f := bufio->open(fname, Bufio->OREAD);
	if(f == nil)
		fail(sys->sprint("cannot open %s: %r", fname));
	out := "";
	for(;;){
		s := f.gets('\n');
		if(s == nil)
			break;
		out += s;
	}
	return out;
}

# substitute $0, $1.."$9", $# in a user macro's stored body template -
# this happens once, when the macro is invoked, never at define time.
substargs(body: string, name: string, args: list of string): string
{
	out := "";
	i := 0;
	n := len body;
	while(i < n){
		c := body[i];
		if(c == '$' && i+1 < n){
			d := body[i+1];
			if(d == '#'){
				out += string nargs(args);
				i += 2;
				continue;
			}
			if(d == '0'){
				out += name;
				i += 2;
				continue;
			}
			if(d >= '1' && d <= '9'){
				out += argnth(args, d - '1');
				i += 2;
				continue;
			}
		}
		out[len out] = c;
		i++;
	}
	return out;
}

doifelse(args: list of string): string
{
	n := nargs(args);
	i := 0;
	rest := args;
	while(n - i >= 3){
		a := argnth(rest, 0);
		b := argnth(rest, 1);
		t := argnth(rest, 2);
		if(a == b)
			return t;
		rest = tl tl tl rest;
		i += 3;
	}
	if(n - i == 1)
		return argnth(rest, 0);
	return "";
}

invoke(name: string, args: list of string): string
{
	case name {
	"define" =>
		setmacro(argnth(args, 0), argnth(args, 1));
		return "";
	"undefine" =>
		delmacro(argnth(args, 0));
		return "";
	"ifdef" =>
		nm := argnth(args, 0);
		if(findmacro(nm) != nil || isbuiltin(nm))
			return argnth(args, 1);
		return argnth(args, 2);
	"ifelse" =>
		return doifelse(args);
	"include" =>
		return readfile(argnth(args, 0));
	}
	m := findmacro(name);
	if(m == nil)
		fail("unknown macro " + name);
	return substargs(m.body, name, args);
}

# s[i] == '`'; returns the index just past the matching close quote,
# tracking nesting (an inner `...' pair keeps its own markers literally
# in the eventual output - only the outermost pair is stripped).
skipquoted(s: string, i: int): int
{
	depth := 1;
	i++;
	n := len s;
	while(i < n && depth > 0){
		if(s[i] == '`')
			depth++;
		else if(s[i] == '\'')
			depth--;
		i++;
	}
	if(depth != 0)
		fail("unterminated quote");
	return i;
}

expandeach(args: list of string): list of string
{
	r: list of string;
	for(l := args; l != nil; l = tl l)
		r = scanexpand(hd l) :: r;
	return revstrlist(r);
}

# s[i] == '('; collects the (possibly quoted, possibly nested-paren)
# argument list into raw substrings, split on top-level commas. Leading
# whitespace right after '(' or ',' is skipped; trailing whitespace
# before ',' or ')' is kept - checked against the host's m4, not assumed.
# `name()` always yields one (possibly empty) argument, never zero.
collectargs(s: string, i: int): (list of string, int)
{
	i++;
	n := len s;
	args: list of string;
	depth := 1;
	while(i < n && iswhite(s[i]))
		i++;
	start := i;
	while(i < n && depth > 0){
		c := s[i];
		if(c == '`'){
			i = skipquoted(s, i);
			continue;
		}
		if(c == '('){
			depth++;
			i++;
			continue;
		}
		if(c == ')'){
			depth--;
			if(depth == 0)
				break;
			i++;
			continue;
		}
		if(c == ',' && depth == 1){
			args = s[start:i] :: args;
			i++;
			while(i < n && iswhite(s[i]))
				i++;
			start = i;
			continue;
		}
		i++;
	}
	if(depth != 0)
		fail("unterminated argument list");
	args = s[start:i] :: args;
	i++;
	return (revstrlist(args), i);
}

# The whole engine: scan s, copying ordinary text through, stripping and
# passing quoted text through verbatim (no expansion inside), recognizing
# macro calls and replacing them with their (recursively rescanned)
# expansion, and handling # comments and dnl as their own special cases.
scanexpand(s: string): string
{
	out := "";
	i := 0;
	n := len s;
	while(i < n){
		c := s[i];
		if(c == '`'){
			j := skipquoted(s, i);
			out += s[i+1:j-1];
			i = j;
			continue;
		}
		if(c == '#'){
			start := i;
			while(i < n && s[i] != '\n')
				i++;
			out += s[start:i];
			continue;
		}
		if(isnamestart(c)){
			start := i;
			i++;
			while(i < n && isnamechar(s[i]))
				i++;
			name := s[start:i];
			if(name == "dnl"){
				while(i < n && s[i] != '\n')
					i++;
				if(i < n)
					i++;
				continue;
			}
			if(!ismacro(name)){
				out += name;
				continue;
			}
			args: list of string;
			if(i < n && s[i] == '('){
				(rawargs, ni) := collectargs(s, i);
				args = expandeach(rawargs);
				i = ni;
			}
			result := invoke(name, args);
			out += scanexpand(result);
			continue;
		}
		out[len out] = c;
		i++;
	}
	return out;
}

readall(f: ref Iobuf): string
{
	out := "";
	for(;;){
		s := f.gets('\n');
		if(s == nil)
			break;
		out += s;
	}
	return out;
}

usage()
{
	sys->fprint(stderr, "usage: m4 [-e script] [-f scriptfile] [file...]\n");
	raise "fail:usage";
}

resetstate()
{
	macros = nil;
}

runstring(prog: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	resetstate();
	outbuf = "";
	capturing = 1;
	out := scanexpand(prog);
	capturing = 0;
	return out;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	if(bufio == nil || arg == nil){
		sys->fprint(stderr, "m4: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();

	prog := "";
	haveprog := 0;

	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'e' =>
			prog += arg->earg();
			haveprog = 1;
		'f' =>
			fname := arg->earg();
			f := bufio->open(fname, Bufio->OREAD);
			if(f == nil){
				sys->fprint(stderr, "m4: cannot open %s: %r\n", fname);
				raise "fail:open";
			}
			prog += readall(f);
			haveprog = 1;
		* =>
			usage();
		}
	}
	rest := arg->argv();
	arg = nil;

	if(!haveprog){
		if(rest != nil){
			for(; rest != nil; rest = tl rest){
				f := bufio->open(hd rest, Bufio->OREAD);
				if(f == nil){
					sys->fprint(stderr, "m4: cannot open %s: %r\n", hd rest);
					raise "fail:open";
				}
				prog += readall(f);
			}
		} else
			prog = readall(bufio->fopen(stdin, Bufio->OREAD));
	}

	sys->print("%s", scanexpand(prog));
}
