implement Radiocal;

#
# The per-radio calibration file, read once for everybody who needs it.
#
# This is the parser that was measured on the stm32f407 -- lifted out of
# radiocfg(1) rather than rewritten, so that the thing in the library is
# the thing that was checked against attrdb(2) on both boards and against
# two negative controls under emu.  See module/radiocal.m for why it is
# not attrdb(2), and doc/radio-plan.ms item 8 for why the file exists.
#
# WHY A LIBRARY AND NOT A SECOND COPY.  radiocfg(1) applies the
# calibration at a prompt; an init applies it on a board that runs no
# shell, which is what this board needs because at NPROC 5 a shell and #a
# will not both fit.  Two callers, one format, and a format deserves one
# reader: the alternative is two sets of bugs in a parser whose whole job
# is to decide what numbers a radio is configured with.
#

include "sys.m";
	sys: Sys;
include "radiocal.m";

init()
{
	sys = load Sys Sys->PATH;
}

boarduid(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	# one line, and nothing after it
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == ' ' || s[i] == '\t')
			return s[0:i];
	return s;
}


# The attrdb(6) subset this board can afford, in one pass.
#
# Returns the values of the wanted attributes for the entry whose "uid"
# is ours, and a count of pairs it could not parse -- which is reported,
# not swallowed.
lookup(path, uid: string, want: array of string): (array of string, int, string)
{
	got := array[len want] of string;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (got, 0, sys->sprint("open %s: %r", path));

	buf := array[512] of byte;
	carry := "";
	inentry := 0;		# this entry is ours
	started := 0;		# we have seen our entry
	bad := 0;
	eof := 0;
	for(;;){
		if(!eof){
			n := sys->read(fd, buf, len buf);
			if(n <= 0)
				eof = 1;
			else
				carry += string buf[0:n];
		}
		i := 0;
		for(;;){
			nl := -1;
			for(j := i; j < len carry; j++)
				if(carry[j] == '\n'){
					nl = j;
					break;
				}
			if(nl < 0)
				break;
			line := carry[i:nl];
			i = nl + 1;
			(inentry, started, bad) =
				feed(line, uid, want, got, inentry,
					started, bad);
		}
		carry = carry[i:];
		if(eof){
			if(len carry > 0)
				(inentry, started, bad) =
					feed(carry, uid, want, got,
						inentry, started, bad);
			break;
		}
	}
	if(!started)
		return (got, bad, "noentry");
	return (got, bad, nil);
}

# One line of it.  An entry begins in column one; an indented line
# continues the one before.
feed(line, uid: string, want: array of string, got: array of string,
	inentry, started, bad: int): (int, int, int)
{
	# a comment is the rest of the line, wherever it starts
	for(h := 0; h < len line; h++)
		if(line[h] == '#'){
			line = line[0:h];
			break;
		}
	indented := len line > 0 && (line[0] == ' ' || line[0] == '\t');
	# trim
	a := 0;
	while(a < len line && (line[a] == ' ' || line[a] == '\t'))
		a++;
	z := len line;
	while(z > a && (line[z-1] == ' ' || line[z-1] == '\t'))
		z--;
	line = line[a:z];
	if(len line == 0)
		return (inentry, started, bad);

	if(!indented){
		# A new entry, so stop collecting whatever the last one
		# was: nothing belongs to us again until a uid= says so.
		# This was written as an if/else whose arms both assigned
		# zero, which reads as a bug and was one line of thinking
		# out loud left in the file.
		inentry = 0;
	}
	# every pair on the line
	for(p := 0; p < len line;){
		while(p < len line && (line[p] == ' ' || line[p] == '\t'))
			p++;
		q := p;
		while(q < len line && line[q] != ' ' && line[q] != '\t')
			q++;
		if(q == p)
			break;
		pair := line[p:q];
		p = q;
		eq := -1;
		for(k := 0; k < len pair; k++)
			if(pair[k] == '='){
				eq = k;
				break;
			}
		if(eq <= 0){
			# not attr=value: say so rather than skip it
			sys->fprint(sys->fildes(2), "radiocal: %q is not an "
				+ "attribute=value pair\n", pair);
			bad++;
			continue;
		}
		attr := pair[0:eq];
		val := pair[eq+1:];
		if(!indented && attr == "uid"){
			if(val == uid){
				inentry = 1;
				started = 1;
			}
			continue;
		}
		if(attr == "uid" && indented && val == uid){
			inentry = 1;
			started = 1;
			continue;
		}
		if(!inentry)
			continue;
		for(w := 0; w < len want; w++)
			if(want[w] == attr)
				got[w] = val;
	}
	return (inentry, started, bad);
}

