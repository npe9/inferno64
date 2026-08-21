implement Mesh;

include "sys.m";
include "string.m";
	str: String;
include "mesh.m";

init()
{
	if(str == nil)
		str = load String String->PATH;
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

# Splits "AxB" into ("A","B"); ("","") if there's no 'x'.
splitx(tok: string): (string, string)
{
	(before, after) := str->splitl(tok, "x");
	if(after == nil)
		return ("", "");
	return (before, after[1:]);
}

parse(line: string): (ref Grid, string)
{
	init();
	a := words(line);
	if(len a < 2 || a[0] != "mesh")
		return (nil, "mesh: usage: mesh NXxNY [domain WxH] [bc clamp|periodic|zero]");
	(nxs, nys) := splitx(a[1]);
	if(nxs == "")
		return (nil, "mesh: expected NXxNY, got " + a[1]);
	nx := int nxs;
	ny := int nys;
	if(nx < 2 || ny < 2)
		return (nil, "mesh: NX and NY must each be at least 2");
	dw := 1.0;
	dh := 1.0;
	bc := CLAMP;
	for(i := 2; i+1 < len a; i += 2)
		case a[i] {
		"domain" =>
			(dws, dhs) := splitx(a[i+1]);
			if(dws == "")
				return (nil, "mesh: expected domain WxH, got " + a[i+1]);
			dw = real dws;
			dh = real dhs;
		"bc" =>
			case a[i+1] {
			"clamp" => bc = CLAMP;
			"periodic" => bc = PERIODIC;
			"zero" => bc = ZERO;
			* => return (nil, "mesh: bc must be clamp, periodic, or zero, got " + a[i+1]);
			}
		* =>
			return (nil, "mesh: unknown option " + a[i]);
		}
	return (ref Grid(nx, ny, dw/real(nx), dh/real(ny), bc), nil);
}
