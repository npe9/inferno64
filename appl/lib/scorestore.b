implement Scorestore;

include "sys.m";
	sys: Sys;

include "scorestore.m";

scorepath(name: string): string
{
	# Score names are deliberately flat: callers cannot escape the score dir.
	for(i := 0; i < len name; i++)
		if(name[i] == '/' || name[i] == '\\' || name[i] == 0)
			return nil;
	if(name == nil)
		return nil;
	return "/lib/scores/" + name;
}

readscore(name: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	path := scorepath(name);
	if(path == nil)
		return nil;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

writescore(name, value: string): int
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	path := scorepath(name);
	if(path == nil)
		return -1;
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil)
		return -1;
	b := array of byte value;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

validnumber(s: string, allowdot: int): int
{
	seen := 0;
	dot := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= '0' && c <= '9'){
			seen = 1;
			continue;
		}
		if(allowdot && c == '.' && !dot){
			dot = 1;
			continue;
		}
		if((c == ' ' || c == '\t' || c == '\n' || c == '\r') && seen)
			return 1;
		return 0;
	}
	return seen;
}

loadint(name: string, dflt: int): int
{
	s := readscore(name);
	if(s == nil || !validnumber(s, 0))
		return dflt;
	v := int s;
	if(v < 0)
		return dflt;
	return v;
}

loadreal(name: string, dflt: real): real
{
	s := readscore(name);
	if(s == nil || !validnumber(s, 1))
		return dflt;
	v := real s;
	if(v < 0.0)
		return dflt;
	return v;
}

saveint(name: string, value: int): int
{
	if(value < 0)
		return -1;
	if(sys == nil)
		sys = load Sys Sys->PATH;
	return writescore(name, sys->sprint("%d\n", value));
}

savereal(name: string, value: real): int
{
	if(value < 0.0)
		return -1;
	if(sys == nil)
		sys = load Sys Sys->PATH;
	return writescore(name, sys->sprint("%5.4f\n", value));
}
