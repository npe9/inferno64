implement Femesh;

include "sys.m";
include "string.m";
	str: String;
include "femesh.m";

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

# Splits "AxBxC" into ("A","B","C"); ("","","") if the shape is wrong.
splitx3(tok: string): (string, string, string)
{
	(a, rest) := str->splitl(tok, "x");
	if(rest == nil)
		return ("", "", "");
	(b, rest2) := str->splitl(rest[1:], "x");
	if(rest2 == nil)
		return ("", "", "");
	return (a, b, rest2[1:]);
}

parse(line: string): (ref Grid, string)
{
	init();
	a := words(line);
	if(len a < 2 || a[0] != "mesh")
		return (nil, "mesh: usage: mesh NXxNYxNZ [domain WxHxD]");
	(nxs, nys, nzs) := splitx3(a[1]);
	if(nxs == "")
		return (nil, "mesh: expected NXxNYxNZ, got " + a[1]);
	nx := int nxs;
	ny := int nys;
	nz := int nzs;
	if(nx < 1 || ny < 1 || nz < 1)
		return (nil, "mesh: NX, NY, and NZ must each be at least 1");
	dw := 1.0;
	dh := 1.0;
	dd := 1.0;
	for(i := 2; i+1 < len a; i += 2)
		case a[i] {
		"domain" =>
			(dws, dhs, dds) := splitx3(a[i+1]);
			if(dws == "")
				return (nil, "mesh: expected domain WxHxD, got " + a[i+1]);
			dw = real dws;
			dh = real dhs;
			dd = real dds;
		* =>
			return (nil, "mesh: unknown option " + a[i]);
		}
	return (ref Grid(nx, ny, nz, dw/real(nx), dh/real(ny), dd/real(nz)), nil);
}

nnodes(g: ref Grid): int
{
	return (g.nx+1)*(g.ny+1)*(g.nz+1);
}

nelem(g: ref Grid): int
{
	return g.nx*g.ny*g.nz;
}

nodeid(g: ref Grid, i, j, k: int): int
{
	return k*(g.ny+1)*(g.nx+1) + j*(g.nx+1) + i;
}

nodeijk(g: ref Grid, n: int): (int, int, int)
{
	planestride := (g.ny+1)*(g.nx+1);
	k := n/planestride;
	rem := n%planestride;
	j := rem/(g.nx+1);
	i := rem%(g.nx+1);
	return (i, j, k);
}

nodecoord(g: ref Grid, n: int): (real, real, real)
{
	(i, j, k) := nodeijk(g, n);
	return (real(i)*g.dx, real(j)*g.dy, real(k)*g.dz);
}

isboundary(g: ref Grid, n: int): int
{
	(i, j, k) := nodeijk(g, n);
	return i == 0 || i == g.nx || j == 0 || j == g.ny || k == 0 || k == g.nz;
}

elemnodes(g: ref Grid, e: int): array of int
{
	planestride := g.ny*g.nx;
	ek := e/planestride;
	rem := e%planestride;
	ej := rem/g.nx;
	ei := rem%g.nx;
	r := array[8] of int;
	r[0] = nodeid(g, ei,   ej,   ek);
	r[1] = nodeid(g, ei+1, ej,   ek);
	r[2] = nodeid(g, ei+1, ej+1, ek);
	r[3] = nodeid(g, ei,   ej+1, ek);
	r[4] = nodeid(g, ei,   ej,   ek+1);
	r[5] = nodeid(g, ei+1, ej,   ek+1);
	r[6] = nodeid(g, ei+1, ej+1, ek+1);
	r[7] = nodeid(g, ei,   ej+1, ek+1);
	return r;
}
