implement Tkrender;

#
# Rasterise a decoded libtk render-node tree with draw(2) and nothing
# else.  See module/tkrender.m for why.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	# NOT `draw': this module exports a function of that name, and
	# limbo reports the clash as a type mismatch on the exported
	# declaration rather than as a shadowed name.
	drawmod: Draw;
	Display, Image, Rect, Point, Font: import drawmod;
include "tknode.m";
	tknode: Tknode;
	Node: import tknode;
include "tkrender.m";

disp: ref Display;

# Faces and bitmaps are named by FILE in a node -- which is what lets a
# tree outlive the repaint that built it -- so they are opened on demand
# and kept, because a glyph run per character would otherwise reopen the
# same face hundreds of times.
fonts: list of (string, ref Font);
imgs: list of (string, ref Image);

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	drawmod = load Draw Draw->PATH;
	tknode = load Tknode Tknode->PATH;
	if(tknode != nil)
		tknode->init();
	disp = d;
	fonts = nil;
	imgs = nil;
}

#
# The one piece of libtk's geometry that is not in a node: how far in
# from the edge the curve is on a given row.  Integer, exact, and
# identical to libtk/scene.c's tkinset() line for line -- a backend has
# to reproduce this or a rounded corner comes out square, and that it
# can be reproduced at all is part of what makes the vocabulary
# sufficient.
#
inset(radius, y: int): int
{
	r2 := radius*radius;
	dy := radius - y;
	for(x := 0; x < radius; x++){
		dx := radius - x;
		if(dx*dx + dy*dy <= r2)
			return x;
	}
	return radius;
}

clamprad(r: Rect, radius: int): int
{
	if(radius*2 > r.dx())
		radius = r.dx()/2;
	if(radius*2 > r.dy())
		radius = r.dy()/2;
	if(radius < 0)
		radius = 0;
	return radius;
}

colour(rgba: int): ref Image
{
	if(disp == nil)
		return nil;
	return disp.color(rgba);
}

getfont(name: string): ref Font
{
	for(l := fonts; l != nil; l = tl l){
		(n, f) := hd l;
		if(n == name)
			return f;
	}
	f := Font.open(disp, name);
	fonts = (name, f) :: fonts;
	return f;
}

getimg(path: string): ref Image
{
	for(l := imgs; l != nil; l = tl l){
		(n, i) := hd l;
		if(n == path)
			return i;
	}
	i := disp.open(path);
	imgs = (path, i) :: imgs;
	return i;
}

rect(minx, miny, maxx, maxy: int): Rect
{
	return Rect((minx, miny), (maxx, maxy));
}

#
# r filled, corners rounded by radius.  libtk/scene.c
# renderroundfill(): the middle band in one draw, then the top and
# bottom rows one at a time with the row's cut taken off each end.
#
roundfill(dst: ref Image, n: ref Node)
{
	col := colour(n.rgba);
	if(col == nil)
		return;
	rad := clamprad(n.r, n.radius);
	h := n.r.dy();
	if(rad <= 0){
		dst.draw(n.r, col, nil, (0, 0));
		return;
	}
	dst.draw(rect(n.r.min.x, n.r.min.y+rad, n.r.max.x, n.r.max.y-rad),
		col, nil, (0, 0));
	for(y := 0; y < rad; y++){
		cut := inset(rad, y);
		dst.draw(rect(n.r.min.x+cut, n.r.min.y+y,
			n.r.max.x-cut, n.r.min.y+y+1), col, nil, (0, 0));
		dst.draw(rect(n.r.min.x+cut, n.r.min.y+h-1-y,
			n.r.max.x-cut, n.r.min.y+h-y), col, nil, (0, 0));
	}
}

# Just the four corner cutaways, in the colour behind the widget.
corners(dst: ref Image, n: ref Node)
{
	out := colour(n.rgba);
	if(out == nil)
		return;
	o := n.r.min;
	w := n.r.dx();
	h := n.r.dy();
	rad := clamprad(n.r, n.radius);
	for(y := 0; y < rad; y++){
		cut := inset(rad, y);
		if(cut <= 0)
			continue;
		dst.draw(rect(o.x, o.y+y, o.x+cut, o.y+y+1), out, nil, (0, 0));
		dst.draw(rect(o.x+w-cut, o.y+y, o.x+w, o.y+y+1), out, nil, (0, 0));
		dst.draw(rect(o.x, o.y+h-1-y, o.x+cut, o.y+h-y), out, nil, (0, 0));
		dst.draw(rect(o.x+w-cut, o.y+h-1-y, o.x+w, o.y+h-y), out, nil, (0, 0));
	}
}

# A rounded rectangle, stroked, width wide.
border(dst: ref Image, n: ref Node)
{
	col := colour(n.rgba);
	if(col == nil)
		return;
	o := n.r.min;
	w := n.r.dx();
	h := n.r.dy();
	bd := n.width;
	rad := clamprad(n.r, n.radius);

	if(w > 2*rad){
		dst.draw(rect(o.x+rad, o.y, o.x+w-rad, o.y+bd), col, nil, (0, 0));
		dst.draw(rect(o.x+rad, o.y+h-bd, o.x+w-rad, o.y+h), col, nil, (0, 0));
	}
	if(h > 2*rad){
		dst.draw(rect(o.x, o.y+rad, o.x+bd, o.y+h-rad), col, nil, (0, 0));
		dst.draw(rect(o.x+w-bd, o.y+rad, o.x+w, o.y+h-rad), col, nil, (0, 0));
	}
	if(rad <= 0)
		return;
	for(y := 0; y < rad; y++){
		cut := inset(rad, y);
		in0 := o.x+cut;
		in1 := o.x+w-cut;
		if(in1 < in0)
			in1 = in0;
		l0 := in0+bd;
		if(l0 > in1)
			l0 = in1;
		r0 := in1-bd;
		if(r0 < in0)
			r0 = in0;
		dst.draw(rect(in0, o.y+y, l0, o.y+y+1), col, nil, (0, 0));
		dst.draw(rect(r0, o.y+y, in1, o.y+y+1), col, nil, (0, 0));
		dst.draw(rect(in0, o.y+h-1-y, l0, o.y+h-y), col, nil, (0, 0));
		dst.draw(rect(r0, o.y+h-1-y, in1, o.y+h-y), col, nil, (0, 0));
	}
}

#
# Integer scale about an origin, for a Ttransform span.  num/den with
# rounding and no floating point, because that is what libtk does and
# the two have to agree to the pixel.
#
scaleval(v, num, den: int): int
{
	if(v >= 0)
		return (v*num + den/2)/den;
	return -(((-v)*num + den/2)/den);
}

scalept(p, o: Point, num, den: int): Point
{
	return (o.x + scaleval(p.x - o.x, num, den),
		o.y + scaleval(p.y - o.y, num, den));
}

scalerect(r: Rect, o: Point, num, den: int): Rect
{
	return Rect(scalept(r.min, o, num, den), scalept(r.max, o, num, den));
}

#
# A node scaled.  PER TYPE, because the fields mean different things:
# an ellipse's r.min is its centre and sp its two radii, a spline's sp
# is two PACKED end styles and not geometry at all, and a layer's three
# rectangles are an extent, a destination and a source point.  Treating
# sp as a point everywhere turns a canvas arrow (25329922) into a
# coordinate.
#
scalenode(n: ref Node, o: Point, num, den: int): ref Node
{
	d := ref *n;
	case n.ntype {
	Tknode->Tellipse or Tknode->Tellipsefill =>
		d.r.min = scalept(n.r.min, o, num, den);
		d.r.max = d.r.min;
		d.sp = (scaleval(n.sp.x, num, den), scaleval(n.sp.y, num, den));
		d.width = scaleval(n.width, num, den);
	Tknode->Tspline =>
		d.width = scaleval(n.width, num, den);
		d.r = scalerect(n.r, o, num, den);
		d.pts = scalepts(n.pts, o, num, den);
	Tknode->Tpolyfill =>
		d.r = scalerect(n.r, o, num, den);
		d.pts = scalepts(n.pts, o, num, den);
	Tknode->Tlayer =>
		d.r = scalerect(n.r, o, num, den);
		d.dstr = scalerect(n.dstr, o, num, den);
		d.sp = scalept(n.sp, o, num, den);
	* =>
		d.r = scalerect(n.r, o, num, den);
		d.radius = scaleval(n.radius, num, den);
		d.width = scaleval(n.width, num, den);
	}
	return d;
}

scalepts(p: array of Point, o: Point, num, den: int): array of Point
{
	if(p == nil)
		return nil;
	q := array[len p] of Point;
	for(i := 0; i < len p; i++)
		q[i] = scalept(p[i], o, num, den);
	return q;
}

#
# One node, into one target.  Returns 1 if it drew, 0 if this is a type
# it does not implement -- counted by the caller rather than ignored.
#
one(dst: ref Image, n: ref Node): int
{
	case n.ntype {
	Tknode->Tcolour =>
		col := colour(n.rgba);
		if(col != nil)
			dst.draw(n.r, col, nil, (0, 0));
	Tknode->Troundfill =>
		roundfill(dst, n);
	Tknode->Tcorners =>
		corners(dst, n);
	Tknode->Tborder =>
		border(dst, n);
	Tknode->Tglyphs =>
		col := colour(n.rgba);
		f := getfont(n.fontname);
		if(col != nil && f != nil)
			dst.text(n.r.min, col, (0, 0), f, n.text);
		else
			return 0;	# a face that will not open is not a draw
	Tknode->Tellipse =>
		col := colour(n.rgba);
		if(col != nil)
			dst.ellipse(n.r.min, n.sp.x, n.sp.y, n.width, col, (0, 0));
	Tknode->Tellipsefill =>
		col := colour(n.rgba);
		if(col != nil)
			dst.fillellipse(n.r.min, n.sp.x, n.sp.y, col, (0, 0));
	Tknode->Ttexture =>
		img := getimg(n.fontname);
		if(img == nil)
			return 0;
		if(n.width){
			# width 1 means the image is a MASK and rgba the
			# colour painted through it.
			col := colour(n.rgba);
			if(col != nil)
				dst.draw(n.r, col, img, (0, 0));
		}else
			dst.draw(n.r, img, nil, (0, 0));
	Tknode->Tpolyfill =>
		col := colour(n.rgba);
		if(col == nil || n.pts == nil || len n.pts == 0)
			return 0;
		dst.fillpoly(n.pts, ~0, col, n.pts[0]);
	Tknode->Tspline =>
		col := colour(n.rgba);
		if(col == nil || n.pts == nil || len n.pts == 0)
			return 0;
		# sp is the two END STYLES, first and last, not a point.
		dst.bezspline(n.pts, n.sp.x, n.sp.y, n.width, col, (0, 0));
	* =>
		return 0;
	}
	return 1;
}

draw(dst: ref Image, nodes: array of ref Node): (int, int, string)
{
	if(disp == nil)
		return (0, 0, "tkrender: init() not called");
	if(dst == nil || nodes == nil)
		return (0, 0, "tkrender: nothing to draw into");

	drawn := 0;
	unsup := 0;

	#
	# THE SPANS.  A clip, a layer and an opacity each redirect drawing
	# into a surface and then put it back, and all three are done the
	# same way here for the same reason: draw(2) gives a Limbo program
	# no way to narrow an image's clipping rectangle -- Image.clipr is
	# a local copy and there is no replclipr -- so the only exact way
	# to clip is to draw into an image whose RECTANGLE is the clip,
	# where anything outside is dropped by draw() itself.
	#
	# That is also why they do not nest here, exactly as they do not
	# nest in libtk: one surface, one open span.
	#
	target := dst;
	surface: ref Image;
	open: ref Node;
	span := Tknode->Tgroup;		# no span open
	xf: ref Node;			# the open transform, or nil

	for(i := 0; i < len nodes; i++){
		nx := nodes[i];

		case nx.ntype {
		Tknode->Ttransform =>
			xf = nx;
			drawn++;
			continue;
		Tknode->Ttransformend =>
			xf = nil;
			drawn++;
			continue;
		Tknode->Tclip =>
			if(surface != nil)
				continue;	# no nesting, as in libtk
			r := nx.r;
			if(!rectclip(r, target.r))
				continue;
			surface = disp.newimage(r, target.chans, 0, Draw->Nofill);
			if(surface == nil)
				continue;
			surface.draw(r, target, nil, r.min);
			open = nx;
			span = Tknode->Tclip;
			target = surface;
			drawn++;
			continue;
		Tknode->Topacity =>
			if(surface != nil)
				continue;
			r := nx.r;
			if(!rectclip(r, target.r))
				continue;
			surface = disp.newimage(r, target.chans, 0, Draw->Nofill);
			if(surface == nil)
				continue;
			# starts as a COPY of the destination, so the
			# composite is the span over what was beneath it
			surface.draw(r, target, nil, r.min);
			open = nx;
			span = Tknode->Topacity;
			target = surface;
			drawn++;
			continue;
		Tknode->Tlayer =>
			if(surface != nil)
				continue;
			#
			# FILLED WITH THE NODE'S rgba, not left undefined.
			# r.max is the extent and rgba is what the scratch
			# starts as -- libtk's tkitmppix() takes both -- and
			# a layer exists precisely so a widget can draw over
			# a known background.  Started with Nofill first and
			# every fixture containing a layer differed, the
			# entry by 13332 bytes with no glyph in it at all,
			# which is what named the layer rather than the text.
			#
			# RGBA32 when there is alpha to carry, as tkitmppix
			# chooses, because the composite below goes through
			# the surface's own alpha.
			#
			lch := target.chans;
			if((nx.rgba & 16rff) != 16rff)
				lch = Draw->RGBA32;
			surface = disp.newimage(Rect((0,0), nx.r.max),
				lch, 0, nx.rgba);
			if(surface == nil)
				continue;
			open = nx;
			span = Tknode->Tlayer;
			target = surface;
			drawn++;
			continue;
		Tknode->Tclipend or Tknode->Topacityend or Tknode->Tlayerend =>
			if(surface == nil)
				continue;
			closespan(dst, surface, open, span);
			target = dst;
			surface = nil;
			open = nil;
			span = Tknode->Tgroup;
			drawn++;
			continue;
		}

		n := nx;
		if(xf != nil)
			n = scalenode(nx, xf.r.min, xf.sp.x, xf.sp.y);
		if(one(target, n))
			drawn++;
		else
			unsup++;
	}

	# A tree that ends inside a span: put it back rather than lose it,
	# which is what libtk's renderer does and for the same reason.
	if(surface != nil)
		closespan(dst, surface, open, span);

	return (drawn, unsup, nil);
}

closespan(dst, surface: ref Image, open: ref Node, span: int)
{
	if(open == nil)
		return;
	case span {
	Tknode->Tclip =>
		dst.draw(surface.r, surface, nil, surface.r.min);
	Tknode->Topacity =>
		# The alpha is the LOW BYTE of rgba. 255 must not go
		# through a mask: a mask with no alpha channel has its
		# GREY substituted for alpha, and an opaque black mask is
		# therefore a transparent one.
		a := open.rgba & 16rff;
		if(a == 16rff)
			dst.draw(open.r, surface, nil, open.r.min);
		else{
			m := colour(a);
			if(m != nil)
				dst.draw(open.r, surface, m, open.r.min);
		}
	Tknode->Tlayer =>
		#
		# SHAPED BY THE RADIUS, not a plain blit: libtk's
		# tkshapedblit() rounds the composite's corners the same
		# way roundfill rounds a fill, so that a layer under a
		# rounded border does not square the widget off.  A plain
		# draw() here leaves four opaque corners over a background
		# that should show through.
		#
		rad := clamprad(open.dstr, open.radius);
		if(rad <= 0){
			dst.draw(open.dstr, surface, nil, open.sp);
			return;
		}
		d := open.dstr;
		h := d.dy();
		dst.draw(rect(d.min.x, d.min.y+rad, d.max.x, d.max.y-rad),
			surface, nil, (open.sp.x, open.sp.y+rad));
		for(y := 0; y < rad; y++){
			cut := inset(rad, y);
			dst.draw(rect(d.min.x+cut, d.min.y+y,
				d.max.x-cut, d.min.y+y+1),
				surface, nil, (open.sp.x+cut, open.sp.y+y));
			dst.draw(rect(d.min.x+cut, d.min.y+h-1-y,
				d.max.x-cut, d.min.y+h-y),
				surface, nil, (open.sp.x+cut, open.sp.y+h-1-y));
		}
	}
}

# Rect.clip() hands back the intersection and whether any of it is left.
rectclip(r: Rect, b: Rect): int
{
	(vis, any) := r.clip(b);
	if(!any || vis.dx() <= 0 || vis.dy() <= 0)
		return 0;
	return 1;
}
