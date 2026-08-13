Liveplot: module
{
	PATH:	con "/dis/lib/liveplot.dis";

	map:	fn(v, lo, hi: real, a, b: int): int;
	grid:	fn(im: ref Draw->Image, r: Draw->Rect,
		colour: ref Draw->Image, nx, ny: int);
	series:	fn(im: ref Draw->Image, r: Draw->Rect,
		x, y: array of real, n: int,
		xlo, xhi, ylo, yhi: real, colour: ref Draw->Image);
	phase:	fn(im: ref Draw->Image, r: Draw->Rect,
		x, y: array of real, n: int,
		xlo, xhi, ylo, yhi: real, colour: ref Draw->Image);
	slider:	fn(im: ref Draw->Image, font: ref Draw->Font,
		track, knob, text: ref Draw->Image, r: Draw->Rect,
		name: string, value, maximum: real);
	slidervalue:	fn(p: Draw->Point, r: Draw->Rect, maximum: real): real;
};
