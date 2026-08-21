implement Meshview;

include "sys.m";
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "mesh.m";
include "string.m";
	str: String;
include "math.m";
	math: Math;
include "meshview.m";

init()
{
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(math == nil)
		math = load Math Math->PATH;
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

new(image: ref Draw->Image, font: ref Draw->Font): ref View
{
	init();
	return ref View(image, font, nil, 0.0, 1.0);
}

# 0xRRGGBBAA, the same packing win.display.color() already takes
# throughout this tree - unpack to interpolate, repack to store.
unpack(c: int): (int, int, int, int)
{
	return ((c>>24)&16rff, (c>>16)&16rff, (c>>8)&16rff, c&16rff);
}

pack(r, g, b, a: int): int
{
	return (r<<24)|(g<<16)|(b<<8)|a;
}

lerp(a, b: int, t: real): int
{
	return a + int(real(b-a)*t);
}

View.cmd(v: self ref View, command: string): string
{
	a := words(command);
	if(len a == 0)
		return nil;
	if(a[0] != "colour")
		return "unknown meshview command: " + a[0];
	if(len a < 5)
		return "usage: colour lo hi rgba0 rgba1 [rgba2 ...]";
	if(v.font == nil || v.font.display == nil)
		return "colour: no display";
	v.lo = real a[1];
	v.hi = real a[2];
	nstops := len a-3;
	stops := array[nstops] of int;
	for(i := 0; i < nstops; i++)
		stops[i] = int a[3+i];
	v.palette = array[256] of ref Draw->Image;
	for(i = 0; i < 256; i++){
		frac := real(i)/255.0*real(nstops-1);
		# int() rounds to nearest in this Limbo, not truncates - floor()
		# first or "seg" lands one segment high near each boundary and
		# t goes negative, corrupting the interpolation.
		seg := int math->floor(frac);
		if(seg >= nstops-1)
			seg = nstops-2;
		t := frac-real(seg);
		(r0,g0,b0,a0) := unpack(stops[seg]);
		(r1,g1,b1,a1) := unpack(stops[seg+1]);
		v.palette[i] = v.font.display.color(
			pack(lerp(r0,r1,t), lerp(g0,g1,t), lerp(b0,b1,t), lerp(a0,a1,t)));
	}
	return nil;
}

View.draw(v: self ref View, r: Draw->Rect, grid: ref Mesh->Grid, values: array of real)
{
	if(v.image == nil || v.palette == nil || grid == nil)
		return;
	nx := grid.nx;
	ny := grid.ny;
	cw := (r.dx()+nx-1)/nx;
	ch := (r.dy()+ny-1)/ny;
	span := v.hi-v.lo;
	if(span == 0.0)
		span = 1.0;
	for(y := 0; y < ny; y++)
		for(x := 0; x < nx; x++){
			frac := (values[y*nx+x]-v.lo)/span;
			idx := int math->floor(frac*255.0);
			if(idx < 0)
				idx = 0;
			if(idx > 255)
				idx = 255;
			x0 := r.min.x+x*r.dx()/nx;
			y0 := r.min.y+y*r.dy()/ny;
			v.image.draw(Rect((x0,y0),(x0+cw,y0+ch)), v.palette[idx], nil, Point(0,0));
		}
}
