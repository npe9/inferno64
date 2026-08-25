implement Join;

# A Limbo-native workalike for a bounded subset of join(1) - relational
# join of two sorted text files - see doc/plan9-port.md's "Rule: Limbo-
# native, in a separate bindable tree". A classic sorted merge-join: two
# pointers advance through the (already-sorted, not re-sorted here -
# same as the real oracle) input files, one output line per matching
# pair of records, duplicate keys on either side producing the full
# cross product (checked against the oracle, not assumed - `a 1`/`a 2`
# in file1 crossed with `a X`/`a Y` in file2 gives all four combinations,
# not just the first).
#
# The host oracle here is macOS/BSD join(1) (POSIX-conformant, per its
# own man page) - every behavioral rule below was checked with targeted
# probes before writing any of this, the same discipline as awk/dc/m4/bc:
# the default field separator is a run of spaces/tabs (leading whitespace
# skipped, multiple separators collapsed to one), but the default output
# separator is always a single space regardless; -o's missing/out-of-
# range field references print as empty (or the -e replacement) rather
# than erroring; a record whose own key field is out of range compares
# as an empty-string key rather than crashing, and still appears under
# -a/-v with that field printed empty; -v suppresses the default matched
# output entirely (not just adding unpaired lines, as -a does).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";

Join: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: args is the flag list only (no file
	# operands - the two inputs are passed directly as strings,
	# extending awk.b's runstring(prog, input) to two inputs).
	runstring:	fn(args: list of string, in1: string, in2: string): string;
};

stdin, stdout, stderr: ref FD;

Rec: adt
{
	fields:	array of string;
};

# --- field splitting ---

# default: a run of spaces/tabs is one separator, leading whitespace
# is skipped entirely (checked against the oracle, not assumed).
splitws(line: string): array of string
{
	out: list of string;
	i := 0;
	n := len line;
	while(i < n){
		while(i < n && (line[i] == ' ' || line[i] == '\t'))
			i++;
		if(i >= n)
			break;
		start := i;
		while(i < n && line[i] != ' ' && line[i] != '\t')
			i++;
		out = line[start:i] :: out;
	}
	return revtoarray(out);
}

# -t char: split strictly on that byte, no collapsing - every
# occurrence is significant, matching the real join's -t semantics.
splitchar(line: string, sep: int): array of string
{
	out: list of string;
	start := 0;
	i := 0;
	n := len line;
	for(; i < n; i++){
		if(line[i] == sep){
			out = line[start:i] :: out;
			start = i+1;
		}
	}
	out = line[start:n] :: out;
	return revtoarray(out);
}

revtoarray(l: list of string): array of string
{
	n := 0;
	for(x := l; x != nil; x = tl x)
		n++;
	a := array[n] of string;
	i := n-1;
	for(; l != nil; l = tl l){
		a[i] = hd l;
		i--;
	}
	return a;
}

# a field index outside a record's actual field count reads as the
# empty string (checked: this is how the oracle handles both a
# missing -o field reference and an out-of-range join-key field,
# rather than raising an error) - 0-based index in.
field(r: Rec, idx: int): string
{
	if(idx < 0 || idx >= len r.fields)
		return "";
	return r.fields[idx];
}

fail(msg: string)
{
	sys->fprint(stderr, "join: %s\n", msg);
	raise "fail:join";
}

# --- options ---

Outsel: adt
{
	filenum:	int;	# 0 for the join field itself, else 1 or 2
	fieldidx:	int;	# 0-based; unused when filenum == 0
};

key1, key2:	int;	# 0-based join-field index for file1/file2
avmode1, avmode2: int;	# 0 none, 1 -a, 2 -v
estr:		string;	# -e replacement for an empty output field
outsep:		string;	# output field separator (single space by default)
usesep:		int;	# 1 if -t was given (splitchar), else splitws
sepchar:	int;
outsel:		list of Outsel;	# nil means "default format", not "-o with no fields"
haveoutsel:	int;

resetopts()
{
	key1 = 0;
	key2 = 0;
	avmode1 = 0;
	avmode2 = 0;
	estr = "";
	outsep = " ";
	usesep = 0;
	sepchar = 0;
	outsel = nil;
	haveoutsel = 0;
}

# parses one -o argument's comma-separated list ("0,1.2,2.2") and
# appends to outsel, preserving order across repeated -o options.
#
# outsel's invariant is "reverse of the intended final field order,
# across every -o seen so far" - so parsing this string's tokens in
# their own left-to-right order and prepending each directly onto
# outsel keeps that invariant across repeated -o calls. (An earlier
# version reversed twice - once here, once again in oselpair/oselsolo
# - which cancelled out to backwards output; caught by comparing
# `-o 0,1.2,2.2` against the host, not by inspection.)
parseosel(s: string)
{
	start := 0;
	n := len s;
	i := 0;
	for(; i <= n; i++){
		if(i == n || s[i] == ','){
			tok := s[start:i];
			outsel = parseoneosel(tok) :: outsel;
			start = i+1;
		}
	}
}

parseoneosel(tok: string): Outsel
{
	if(tok == "0")
		return Outsel(0, 0);
	dot := -1;
	for(i := 0; i < len tok; i++)
		if(tok[i] == '.')
			dot = i;
	if(dot < 0)
		fail("bad -o field " + tok);
	fnum := atoi(tok[0:dot]);
	fld := atoi(tok[dot+1:]);
	if(fnum != 1 && fnum != 2)
		fail("bad -o file number " + tok);
	return Outsel(fnum, fld-1);
}

atoi(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++){
		if(s[i] < '0' || s[i] > '9')
			fail("bad number " + s);
		v = v*10 + (s[i] - '0');
	}
	return v;
}

splitline(line: string): array of string
{
	if(usesep)
		return splitchar(line, sepchar);
	return splitws(line);
}

splitlines(text: string): list of string
{
	out: list of string;
	start := 0;
	n := len text;
	for(i := 0; i < n; i++){
		if(text[i] == '\n'){
			out = text[start:i] :: out;
			start = i+1;
		}
	}
	if(start < n)
		out = text[start:n] :: out;
	fwd: list of string;
	for(; out != nil; out = tl out)
		fwd = hd out :: fwd;
	return fwd;
}

readrecs(text: string): array of Rec
{
	lines := splitlines(text);
	n := 0;
	for(l1 := lines; l1 != nil; l1 = tl l1)
		n++;
	a := array[n] of Rec;
	i := 0;
	for(l2 := lines; l2 != nil; l2 = tl l2){
		a[i] = Rec(splitline(hd l2));
		i++;
	}
	return a;
}

emitfields(fs: list of string)
{
	first := 1;
	for(; fs != nil; fs = tl fs){
		if(!first)
			out += outsep;
		v := hd fs;
		if(v == "")
			v = estr;
		out += v;
		first = 0;
	}
	out += "\n";
}

# default output for a single unmatched record: its own key field,
# then its remaining fields in original order (this happens to
# reconstruct the original line exactly when the key is field 1).
defaultsolo(r: Rec, keyidx: int): list of string
{
	fs: list of string;
	n := len r.fields;
	for(i := n-1; i >= 0; i--)
		if(i != keyidx)
			fs = field(r, i) :: fs;
	return field(r, keyidx) :: fs;
}

defaultpair(r1: Rec, r2: Rec): list of string
{
	fs: list of string;
	n2 := len r2.fields;
	for(j := n2-1; j >= 0; j--)
		if(j != key2)
			fs = field(r2, j) :: fs;
	n1 := len r1.fields;
	for(i := n1-1; i >= 0; i--)
		if(i != key1)
			fs = field(r1, i) :: fs;
	return field(r1, key1) :: fs;
}

oselpair(r1: Rec, r2: Rec): list of string
{
	# outsel is stored reverse-of-intended-order (see parseosel) -
	# iterating it directly while prepending onto fs undoes exactly
	# that one reversal, with no second reversal needed.
	fs: list of string;
	for(l := outsel; l != nil; l = tl l){
		o := hd l;
		v: string;
		case o.filenum {
		0 => v = field(r1, key1);	# the join field's value
		1 => v = field(r1, o.fieldidx);
		2 => v = field(r2, o.fieldidx);
		}
		fs = v :: fs;
	}
	return fs;
}

# for an unpaired record from file1 (no file2 counterpart) or vice
# versa, -o references to the other file's fields read as empty,
# same as any other out-of-range field.
oselsolo(r: Rec, side: int): list of string
{
	fs: list of string;
	for(l := outsel; l != nil; l = tl l){
		o := hd l;
		v: string;
		case o.filenum {
		0 =>
			if(side == 1)
				v = field(r, key1);
			else
				v = field(r, key2);
		1 =>
			if(side == 1)
				v = field(r, o.fieldidx);
			else
				v = "";
		2 =>
			if(side == 2)
				v = field(r, o.fieldidx);
			else
				v = "";
		}
		fs = v :: fs;
	}
	return fs;
}

out:	string;

dojoin(a1: array of Rec, a2: array of Rec)
{
	emitmatch := !(avmode1 == 2 || avmode2 == 2);
	emitun1 := avmode1 == 1 || avmode1 == 2;
	emitun2 := avmode2 == 1 || avmode2 == 2;

	i := 0;
	j := 0;
	n1 := len a1;
	n2 := len a2;
	while(i < n1 && j < n2){
		k1 := field(a1[i], key1);
		k2 := field(a2[j], key2);
		if(k1 < k2){
			if(emitun1){
				if(haveoutsel)
					emitfields(oselsolo(a1[i], 1));
				else
					emitfields(defaultsolo(a1[i], key1));
			}
			i++;
			continue;
		}
		if(k1 > k2){
			if(emitun2){
				if(haveoutsel)
					emitfields(oselsolo(a2[j], 2));
				else
					emitfields(defaultsolo(a2[j], key2));
			}
			j++;
			continue;
		}
		# equal keys: gather the run on each side, cross them
		i2 := i;
		while(i2 < n1 && field(a1[i2], key1) == k1)
			i2++;
		j2 := j;
		while(j2 < n2 && field(a2[j2], key2) == k1)
			j2++;
		if(emitmatch){
			for(a := i; a < i2; a++){
				for(b := j; b < j2; b++){
					if(haveoutsel)
						emitfields(oselpair(a1[a], a2[b]));
					else
						emitfields(defaultpair(a1[a], a2[b]));
				}
			}
		}
		i = i2;
		j = j2;
	}
	if(emitun1){
		for(; i < n1; i++){
			if(haveoutsel)
				emitfields(oselsolo(a1[i], 1));
			else
				emitfields(defaultsolo(a1[i], key1));
		}
	}
	if(emitun2){
		for(; j < n2; j++){
			if(haveoutsel)
				emitfields(oselsolo(a2[j], 2));
			else
				emitfields(defaultsolo(a2[j], key2));
		}
	}
}

runstring(args: list of string, in1: string, in2: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	resetopts();
	parseopts(args);
	out = "";
	dojoin(readrecs(in1), readrecs(in2));
	return out;
}

parseopts(args: list of string)
{
	l := args;
	while(l != nil){
		a := hd l;
		l = tl l;
		case a {
		"-a" =>
			if(l == nil)
				fail("-a needs a file number");
			n := atoi(hd l);
			l = tl l;
			if(n == 1)
				avmode1 = 1;
			else if(n == 2)
				avmode2 = 1;
			else
				fail("-a file number must be 1 or 2");
		"-v" =>
			if(l == nil)
				fail("-v needs a file number");
			n := atoi(hd l);
			l = tl l;
			if(n == 1)
				avmode1 = 2;
			else if(n == 2)
				avmode2 = 2;
			else
				fail("-v file number must be 1 or 2");
		"-e" =>
			if(l == nil)
				fail("-e needs a string");
			estr = hd l;
			l = tl l;
		"-o" =>
			if(l == nil)
				fail("-o needs a field list");
			parseosel(hd l);
			haveoutsel = 1;
			l = tl l;
		"-t" =>
			if(l == nil)
				fail("-t needs a character");
			c := hd l;
			l = tl l;
			if(len c != 1)
				fail("-t needs exactly one character");
			usesep = 1;
			sepchar = c[0];
			outsep = c;
		"-1" =>
			if(l == nil)
				fail("-1 needs a field number");
			key1 = atoi(hd l) - 1;
			l = tl l;
		"-2" =>
			if(l == nil)
				fail("-2 needs a field number");
			key2 = atoi(hd l) - 1;
			l = tl l;
		* =>
			fail("unknown option " + a);
		}
	}
}

readall(f: ref Iobuf): string
{
	# named `text`, not `out` - `out` is this module's global output
	# accumulator (see emitfields()); shadowing it here compiled fine
	# but only by luck, since this function never touches the global.
	text := "";
	for(;;){
		s := f.gets('\n');
		if(s == nil)
			break;
		text += s;
	}
	return text;
}

usage()
{
	sys->fprint(stderr,
		"usage: join [-a n|-v n] [-e string] [-o list] [-t char] [-1 field] [-2 field] file1 file2\n");
	raise "fail:usage";
}

readfileorstdin(name: string): string
{
	if(name == "-")
		return readall(bufio->fopen(stdin, Bufio->OREAD));
	f := bufio->open(name, Bufio->OREAD);
	if(f == nil){
		sys->fprint(stderr, "join: cannot open %s: %r\n", name);
		raise "fail:open";
	}
	return readall(f);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(stderr, "join: cannot load Bufio\n");
		raise "fail:module";
	}

	resetopts();

	argv = tl argv;
	opts: list of string;
	files: list of string;
	l := argv;
	while(l != nil){
		a := hd l;
		case a {
		"-a" or "-v" or "-e" or "-o" or "-t" or "-1" or "-2" =>
			opts = a :: opts;
			l = tl l;
			if(l == nil)
				usage();
			opts = hd l :: opts;
			l = tl l;
		* =>
			files = a :: files;
			l = tl l;
		}
	}
	rf: list of string;
	for(; files != nil; files = tl files)
		rf = hd files :: rf;
	if(rf == nil || tl rf == nil || tl tl rf != nil)
		usage();
	f1name := hd rf;
	f2name := hd tl rf;

	ro: list of string;
	for(; opts != nil; opts = tl opts)
		ro = hd opts :: ro;
	parseopts(ro);

	in1 := readfileorstdin(f1name);
	in2 := readfileorstdin(f2name);
	out = "";
	dojoin(readrecs(in1), readrecs(in2));
	sys->print("%s", out);
}
