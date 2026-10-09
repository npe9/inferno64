implement Tknode;

#
# Decode libtk's `render tree' serialisation.  See module/tknode.m for
# the wire form and for why it exists.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Rect, Point: import draw;
include "tknode.m";

names := array[Nodetypes] of {
	"group",
	"colour",
	"roundfill",
	"border",
	"corners",
	"layer",
	"layerend",
	"texture",
	"glyphs",
	"linear",
	"shadow",
	"clip",
	"transform",
	"opacity",
	"ellipse",
	"ellipsefill",
	"polyfill",
	"spline",
	"clipend",
	"transformend",
	"opacityend",
};

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
}

Node.name(n: self ref Node): string
{
	return typename(n.ntype);
}

typename(t: int): string
{
	if(t < 0 || t >= len names)
		return "unknown";
	return names[t];
}

typeof(name: string): int
{
	for(i := 0; i < len names; i++)
		if(names[i] == name)
			return i;
	return -1;
}

#
# One escaped, quoted field.  Returns the string, the index just past
# the closing quote, and an error.  A field that is not quoted, or that
# runs off the end of the line, is an error rather than a guess: this
# runs on a tree another process produced and a silent recovery here
# would show up as wrong geometry somewhere else.
#
unquote(l: string, i: int): (string, int, string)
{
	if(i >= len l || l[i] != '"')
		return (nil, i, "field is not quoted");
	s := "";
	for(i++; i < len l; i++){
		case l[i] {
		'"' =>
			return (s, i+1, nil);
		'\\' =>
			if(i+1 >= len l)
				return (nil, i, "escape at end of line");
			case l[i+1] {
			'n' =>	s[len s] = '\n';
			't' =>	s[len s] = '\t';
			* =>	s[len s] = l[i+1];
			}
			i++;
		* =>
			s[len s] = l[i];
		}
	}
	return (nil, i, "unterminated string");
}

#
# The fixed integer fields, in the order libtk writes them.  Named here
# rather than counted at the use site so that adding a field is one
# edit in two files instead of an off-by-one nobody sees until a
# polygon's points are read out of the width.
#
Nfixed: con 14;	# r(4) dstr(4) sp(2) rgba radius width npts

decodeline(l: string): (ref Node, string)
{
	# The numbers end at the first quote; the two strings follow it.
	q := -1;
	for(i := 0; i < len l; i++)
		if(l[i] == '"'){
			q = i;
			break;
		}
	if(q < 0)
		return (nil, "no quoted field");
	(nt, toks) := sys->tokenize(l[0:q], " \t");
	if(nt < 1 + Nfixed)
		return (nil, sys->sprint("%d fields, want at least %d",
			nt, 1 + Nfixed));
	n := ref Node;
	n.ntype = typeof(hd toks);
	toks = tl toks;
	f := array[nt-1] of int;
	for(i = 0; i < nt-1; i++){
		f[i] = int hd toks;
		toks = tl toks;
	}
	n.r = Rect((f[0], f[1]), (f[2], f[3]));
	n.dstr = Rect((f[4], f[5]), (f[6], f[7]));
	n.sp = (f[8], f[9]);
	n.rgba = f[10];
	n.radius = f[11];
	n.width = f[12];
	npts := f[13];
	if(npts < 0 || Nfixed + 2*npts != nt-1)
		return (nil, sys->sprint("npts %d but %d numbers after it",
			npts, nt-1-Nfixed));
	n.pts = array[npts] of Point;
	for(i = 0; i < npts; i++)
		n.pts[i] = (f[Nfixed + 2*i], f[Nfixed + 2*i + 1]);
	err: string;
	(n.fontname, q, err) = unquote(l, q);
	if(err != nil)
		return (nil, "fontname: " + err);
	# One space between the two strings, which libtk always writes.
	while(q < len l && (l[q] == ' ' || l[q] == '\t'))
		q++;
	(n.text, q, err) = unquote(l, q);
	if(err != nil)
		return (nil, "text: " + err);
	return (n, nil);
}

decode(dump: string): (array of ref Node, string)
{
	if(sys == nil)
		init();
	nodes: list of ref Node;
	nn := 0;
	err: string;
	i := 0;
	while(i < len dump){
		e := i;
		while(e < len dump && dump[e] != '\n')
			e++;
		if(e > i){
			(n, le) := decodeline(dump[i:e]);
			if(le != nil){
				err = sys->sprint("line %d: %s", nn+1, le);
				break;
			}
			nodes = n :: nodes;
			nn++;
		}
		i = e + 1;
	}
	a := array[nn] of ref Node;
	# nodes is reversed; the tree's order is paint order and a
	# consumer that drew it backwards would be wrong in a way a count
	# does not show.
	for(j := nn-1; j >= 0; j--){
		a[j] = hd nodes;
		nodes = tl nodes;
	}
	return (a, err);
}
