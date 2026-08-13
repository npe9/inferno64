implement Liveplot;

include "draw.m";
	draw: Draw;
	Image, Font, Point, Rect: import draw;
include "sys.m";
	sys: Sys;
include "liveplot.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
}

map(v, lo, hi: real, a, b: int): int
{
	if(hi == lo)
		return a;
	return a+int((v-lo)*real(b-a)/(hi-lo));
}

grid(im: ref Draw->Image, r: Draw->Rect,
		colour: ref Draw->Image, nx, ny: int)
{
	for(i := 1; i < nx; i++){
		x := r.min.x+i*r.dx()/nx;
		im.line((x,r.min.y),(x,r.max.y),0,0,0,colour,(0,0));
	}
	for(i = 1; i < ny; i++){
		y := r.min.y+i*r.dy()/ny;
		im.line((r.min.x,y),(r.max.x,y),0,0,0,colour,(0,0));
	}
}

series(im: ref Draw->Image, r: Draw->Rect, x, y: array of real,
		n: int, xlo, xhi, ylo, yhi: real, colour: ref Draw->Image)
{
	phase(im,r,x,y,n,xlo,xhi,ylo,yhi,colour);
}

phase(im: ref Draw->Image, r: Draw->Rect, x, y: array of real,
		n: int, xlo, xhi, ylo, yhi: real, colour: ref Draw->Image)
{
	if(n > len x)
		n = len x;
	if(n > len y)
		n = len y;
	for(i := 1; i < n; i++)
		im.line((map(x[i-1],xlo,xhi,r.min.x,r.max.x),
			map(y[i-1],ylo,yhi,r.max.y,r.min.y)),
			(map(x[i],xlo,xhi,r.min.x,r.max.x),
			map(y[i],ylo,yhi,r.max.y,r.min.y)),
			0,0,1,colour,(0,0));
}

slider(im: ref Draw->Image, font: ref Draw->Font,
		track, knob, text: ref Draw->Image, r: Draw->Rect,
		name: string, value, maximum: real)
{
	init();
	y := r.min.y+r.dy()/2;
	im.line((r.min.x,y),(r.max.x,y),0,0,2,track,(0,0));
	x := map(value,0.0,maximum,r.min.x,r.max.x);
	im.ellipse((x,y),4,4,0,knob,(0,0));
	im.text((r.min.x,r.max.y),text,(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

slidervalue(p: Draw->Point, r: Draw->Rect, maximum: real): real
{
	f := real(p.x-r.min.x)/real(r.dx());
	if(f < 0.02)
		f = 0.02;
	if(f > 0.98)
		f = 0.98;
	return f*maximum;
}
