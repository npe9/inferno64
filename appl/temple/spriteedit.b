implement Spriteedit;

# TempleOS-style embedded sprite editor.  Sprite data lives in a textual block:
# .SPRITE name width height
# -16776961 . 862388223 ...
# ...
# .ENDSPRITE
# Pixels and mesh materials are Inferno r8g8b8a8 values; '.' is transparent.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Spriteedit: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Ncol: con 16;
Defw: con 32;
Defh: con 32;
Top: con 42;
Margin: con 12;
Paletteh: con 62;

win: ref Window;
font: ref Font;
col: array of ref Image;
pix: array of int;
sw, sh, cell: int;
inkrgba := int 16rFF0000FF;
down := 0;
path := "/tmp/sprite.txt";
name := "sprite";
prefix, suffix: string;
status := "new sprite";
palval: array of int;
cachev: array of int;
cachei: array of ref Image;
ncache := 0;
meshmode := 0;
vx, vy, vz: array of int;
fa, fb, fc, fcol: array of int;
nv, nf: int;
selected := -1;
pick0 := -1; pick1 := -1; pick2 := -1;
plane := 0;	# 0 XY, 1 XZ, 2 ZY
lastx, lasty: int;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	if(argv != nil)
		argv = tl argv;
	if(argv != nil){
		path = hd argv;
		argv = tl argv;
	}
	if(argv != nil)
		name = hd argv;

	win = wmclient->window(ctxt, "TempleOS Sprite Editor", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	vals := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF,
		int 16r55FFFFFF, int 16rFF5555FF, int 16rFF55FFFF,
		Draw->Yellow, Draw->White
	};
	palval = vals;
	col = array[Ncol] of ref Image;
	for(i := 0; i < Ncol; i++)
		col[i] = d.color(vals[i]);
	cachev = array[128] of int;
	cachei = array[128] of ref Image;
	new_sprite(Defw, Defh);
	load_sprite();
	win.reshape(Rect((0, 0), (640, 520)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		pointer(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' => exit;
		's' or 'S' => save(); redraw();
		'l' or 'L' => load_sprite(); redraw();
		'n' or 'N' => clear_current(); redraw();
		'\t' => if(meshmode){ plane = (plane+1)%3; redraw(); }
		' ' => if(meshmode){ remember_vertex(); redraw(); }
		't' or 'T' => if(meshmode){ add_face(); redraw(); }
		'v' or 'V' => if(meshmode){ add_vertex(); redraw(); }
		'x' or 'X' => inkrgba &= ~255; status = "transparent ink"; redraw();
		'r' => adjust(0, -16); redraw();
		'R' => adjust(0, 16); redraw();
		'g' => adjust(1, -16); redraw();
		'G' => adjust(1, 16); redraw();
		'b' => adjust(2, -16); redraw();
		'B' => adjust(2, 16); redraw();
		}
	}
}

new_sprite(w, h: int)
{
	if(w < 1) w = 1;
	if(h < 1) h = 1;
	if(w > 128) w = 128;
	if(h > 128) h = 128;
	sw = w;
	sh = h;
	pix = array[sw*sh] of { * => 0 };
}

redraw()
{
	if(meshmode){
		redraw_mesh();
		return;
	}
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, col[7], nil, Point(0, 0));
	availw := w-2*Margin;
	availh := h-Top-Paletteh-Margin;
	cell = availw/sw;
	if(availh/sh < cell) cell = availh/sh;
	if(cell < 2) cell = 2;
	if(cell > 24) cell = 24;
	gx := o.x+Margin;
	gy := o.y+Top;
	for(y := 0; y < sh; y++)
		for(x := 0; x < sw; x++){
			r := Rect((gx+x*cell, gy+y*cell),
				(gx+(x+1)*cell, gy+(y+1)*cell));
			c := pix[y*sw+x];
			if((c&255) == 0)
				checker(img, r, x, y);
			else
				img.draw(r, colour(c), nil, Point(0, 0));
			if(cell >= 6){
				img.line(r.min, Point(r.max.x-1, r.min.y), 0, 0, 0, col[8], Point(0, 0));
				img.line(r.min, Point(r.min.x, r.max.y-1), 0, 0, 0, col[8], Point(0, 0));
			}
		}
	py := gy+sh*cell+5;
	draw_sliders(img, o.x+Margin, py, w-2*Margin);
	if(font != nil){
		img.text(Point(o.x+Margin, o.y+5), col[0], Point(0, 0), font,
			sys->sprint("%s  %s  %dx%d", path, name, sw, sh));
		img.text(Point(o.x+Margin, o.y+21), col[0], Point(0, 0), font,
			"paint:LMB erase:RMB/X RGB sliders or r/R g/G b/B save:S reload:L clear:N");
		img.text(Point(o.x+w-245, py+17), col[0], Point(0, 0), font,
			sys->sprint("RGBA %8.8ux", inkrgba));
		img.text(Point(o.x+Margin, py+46), col[0], Point(0, 0), font, status);
	}
	img.flush(Draw->Flushnow);
}

checker(img: ref Image, r: Rect, x, y: int)
{
	c := col[15];
	if((x+y)&1) c = col[7];
	img.draw(r, c, nil, Point(0, 0));
}

border(img: ref Image, r: Rect, c: ref Image)
{
	img.line(r.min, Point(r.max.x-1, r.min.y), 0, 0, 1, c, Point(0, 0));
	img.line(Point(r.max.x-1, r.min.y), Point(r.max.x-1, r.max.y-1), 0, 0, 1, c, Point(0, 0));
	img.line(Point(r.max.x-1, r.max.y-1), Point(r.min.x, r.max.y-1), 0, 0, 1, c, Point(0, 0));
	img.line(Point(r.min.x, r.max.y-1), r.min, 0, 0, 1, c, Point(0, 0));
}

colour(v: int): ref Image
{
	for(i := 0; i < ncache; i++)
		if(cachev[i] == v) return cachei[i];
	c := win.display.color(v);
	if(ncache < len cachev){ cachev[ncache]=v; cachei[ncache++]=c; }
	return c;
}

component(which: int): int
{
	case which {
	0 => return (inkrgba>>24)&255;
	1 => return (inkrgba>>16)&255;
	* => return (inkrgba>>8)&255;
	}
}

setcomp(which, v: int)
{
	if(v<0)v=0; if(v>255)v=255;
	case which {
	0 => inkrgba=(inkrgba&int 16r00FFFFFF)|(v<<24);
	1 => inkrgba=(inkrgba&int 16rFF00FFFF)|(v<<16);
	* => inkrgba=(inkrgba&int 16rFFFF00FF)|(v<<8);
	}
	inkrgba |= 255;
	if(meshmode && selected >= 0)
		for(i := 0; i < nf; i++)
			if(fa[i]==selected || fb[i]==selected || fc[i]==selected)
				fcol[i]=inkrgba;
}

adjust(which, d: int) { setcomp(which, component(which)+d); }

draw_sliders(img: ref Image, x, y, w: int)
{
	barw := w-250;
	if(barw < 64) barw=64;
	for(k := 0; k < 3; k++){
		for(i := 0; i < barw; i+=4){
			v := i*255/barw;
			r:=component(0);g:=component(1);b:=component(2);
			case k {
			0 => r=v;
			1 => g=v;
			* => b=v;
			}
			c := (r<<24)|(g<<16)|(b<<8)|255;
			img.draw(Rect((x+i,y+k*14),(x+i+4,y+k*14+11)),colour(c),nil,Point(0,0));
		}
		mark := x+component(k)*barw/255;
		img.line(Point(mark,y+k*14),Point(mark,y+k*14+11),0,0,1,col[15],Point(0,0));
	}
	img.draw(Rect((x+barw+12,y),(x+barw+52,y+40)),colour(inkrgba),nil,Point(0,0));
}

pointer(p: ref Draw->Pointer)
{
	if(meshmode){
		mesh_pointer(p);
		return;
	}
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	gx := o.x+Margin;
	gy := o.y+Top;
	py := gy+sh*cell+8;
	x := p.xy.x-o.x;
	y := p.xy.y-o.y;
	if((p.buttons & 1) && y >= py-o.y && y < py-o.y+42){
		band := (y-(py-o.y))/14;
		v := (x-Margin)*255/(img.r.dx()-2*Margin-250);
		if(v < 0) v=0; if(v > 255) v=255;
		if(band >= 0 && band < 3){ setcomp(band,v); redraw(); }
		return;
	}
	if(!(p.buttons & (1|4))){
		down = 0;
		return;
	}
	px := (p.xy.x-gx)/cell;
	qy := (p.xy.y-gy)/cell;
	if(px < 0 || px >= sw || qy < 0 || qy >= sh)
		return;
	v := inkrgba;
	if(p.buttons & 4) v = 0;
	if(pix[qy*sw+px] != v){
		pix[qy*sw+px] = v;
		status = "modified";
		redraw();
	}
	down = 1;
}

load_sprite()
{
	{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		prefix = suffix = nil;
		status = "new file";
		return;
	}
	b := array[1024*1024] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		raise "read";
	s := string b[0:n];
	key := ".SPRITE "+name+" ";
	a := find(s, key, 0);
	if(a < 0){
		key = ".MESH "+name+" ";
		a = find(s, key, 0);
		if(a >= 0){
			parse_mesh(s, a);
			status = "loaded mesh";
			return;
		}
		prefix = s;
		if(len prefix && prefix[len prefix-1] != '\n') prefix += "\n";
		suffix = nil;
		status = "object not found; new block";
		return;
	}
	eol := find(s, "\n", a);
	end := find(s, ".ENDSPRITE", eol+1);
	if(eol < 0 || end < 0)
		raise "bad sprite block";
	endline := find(s, "\n", end);
	if(endline < 0) endline = len s; else endline++;
	prefix = s[0:a];
	suffix = s[endline:];
	(nil, hdr) := sys->tokenize(s[a:eol], " \t\r");
	if(len hdr != 4 && len hdr != 5)
		raise "bad sprite header";
	w := int hd tl tl hdr;
	h := int hd tl tl tl hdr;
	new_sprite(w, h);
	(nil, rows) := sys->tokenize(s[eol+1:end], "\n");
	y := 0;
	newfmt := len hdr == 5;
	for(; rows != nil && y < sh; rows = tl rows){
		row := hd rows;
		if(newfmt){
			(nil, cells) := sys->tokenize(row, " \t\r");
			for(x := 0; x < sw && cells != nil; x++){
				v := hd cells; cells=tl cells;
				if(v == ".") pix[y*sw+x]=0; else pix[y*sw+x]=int v;
			}
		}else
			for(x := 0; x < sw && x < len row; x++){
				v := hex(row[x]);
				if(v < 0) pix[y*sw+x]=0; else pix[y*sw+x]=palval[v];
			}
		y++;
	}
	status = "loaded";
	} exception e {
	"*" => status = "load: "+e;
	}
}

save()
{
	if(meshmode){
		save_mesh();
		return;
	}
	{
	s := prefix+sys->sprint(".SPRITE %s %d %d r8g8b8a8\n", name, sw, sh);
	for(y := 0; y < sh; y++){
		for(x := 0; x < sw; x++){
			v := pix[y*sw+x];
			if(x) s += " ";
			if((v&255)==0) s += "."; else s += sys->sprint("%d",v);
		}
		s += "\n";
	}
	s += ".ENDSPRITE\n"+suffix;
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil)
		raise "create";
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		raise "write";
	status = "saved";
	} exception e {
	"*" => status = "save: "+e;
	}
}

parse_mesh(s: string, a: int)
{
	eol := find(s, "\n", a);
	end := find(s, ".ENDMESH", eol+1);
	if(eol < 0 || end < 0)
		raise "bad mesh block";
	endline := find(s, "\n", end);
	if(endline < 0) endline = len s; else endline++;
	prefix = s[0:a];
	suffix = s[endline:];
	(nil, hdr) := sys->tokenize(s[a:eol], " \t\r");
	if(len hdr != 4)
		raise "bad mesh header";
	nv = int hd tl tl hdr;
	nf = int hd tl tl tl hdr;
	if(nv < 0 || nv > 4096 || nf < 0 || nf > 8192)
		raise "mesh too large";
	vx = array[nv] of int;
	vy = array[nv] of int;
	vz = array[nv] of int;
	fa = array[nf] of int;
	fb = array[nf] of int;
	fc = array[nf] of int;
	fcol = array[nf] of int;
	(nil, lines) := sys->tokenize(s[eol+1:end], "\n");
	vi := fi := 0;
	for(; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil) continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t; vx[vi] = int hd t;
			t = tl t; vy[vi] = int hd t;
			t = tl t; vz[vi++] = int hd t;
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t; fcol[fi] = int hd t;
			if(fcol[fi] >= 0 && fcol[fi] < 16) fcol[fi] = palval[fcol[fi]];
			t = tl t; fa[fi] = int hd t;
			t = tl t; fb[fi] = int hd t;
			t = tl t; fc[fi++] = int hd t;
		}
	}
	if(vi != nv || fi != nf)
		raise "truncated mesh";
	meshmode = 1;
	selected = -1;
	pick0 = pick1 = pick2 = -1;
}

clear_current()
{
	if(!meshmode){
		new_sprite(sw, sh);
		status = "cleared";
		return;
	}
	nv = nf = 0;
	vx = vy = vz = array[0] of int;
	fa = fb = fc = fcol = array[0] of int;
	selected = pick0 = pick1 = pick2 = -1;
	status = "cleared mesh";
}

add_vertex()
{
	nx := array[nv+1] of int; ny := array[nv+1] of int; nz := array[nv+1] of int;
	for(i := 0; i < nv; i++){ nx[i]=vx[i]; ny[i]=vy[i]; nz[i]=vz[i]; }
	vx=nx; vy=ny; vz=nz; selected=nv; nv++;
	status = "added vertex";
}

remember_vertex()
{
	if(selected < 0) return;
	pick0=pick1; pick1=pick2; pick2=selected;
	status=sys->sprint("face vertices %d %d %d",pick0,pick1,pick2);
}

add_face()
{
	if(pick0 < 0 || pick1 < 0 || pick2 < 0){ status="select three vertices with Space"; return; }
	na:=array[nf+1] of int; nb:=array[nf+1] of int; nc:=array[nf+1] of int; ncol:=array[nf+1] of int;
	for(i:=0;i<nf;i++){na[i]=fa[i];nb[i]=fb[i];nc[i]=fc[i];ncol[i]=fcol[i];}
	na[nf]=pick0;nb[nf]=pick1;nc[nf]=pick2;ncol[nf]=inkrgba;
	fa=na;fb=nb;fc=nc;fcol=ncol;nf++;
	status="added triangle";
}

save_mesh()
{
	{
		s := prefix+sys->sprint(".MESH %s %d %d\n", name, nv, nf);
		for(i := 0; i < nv; i++)
			s += sys->sprint("v %d %d %d\n", vx[i], vy[i], vz[i]);
		for(i = 0; i < nf; i++)
			s += sys->sprint("f %d %d %d %d\n", fcol[i], fa[i], fb[i], fc[i]);
		s += ".ENDMESH\n"+suffix;
		fd := sys->create(path, Sys->OWRITE, 8r664);
		if(fd == nil) raise "create";
		b := array of byte s;
		if(sys->write(fd, b, len b) != len b) raise "write";
		status = "saved mesh";
	} exception e {
	"*" => status = "save: "+e;
	}
}

ortho(i, cx, cy: int, scale: real): Point
{
	case plane {
	0 => return Point(cx+int(real vx[i]*scale), cy-int(real vy[i]*scale));
	1 => return Point(cx+int(real vx[i]*scale), cy-int(real vz[i]*scale));
	* => return Point(cx+int(real vz[i]*scale), cy-int(real vy[i]*scale));
	}
}

preview(i, cx, cy: int, scale: real): Point
{
	# Fixed isometric preview; the editing pane remains exact and orthographic.
	x := real vx[i]; y := real vy[i]; z := real vz[i];
	return Point(cx+int((0.78*x-0.62*z)*scale),
		cy-int((y+0.35*x+0.44*z)*scale));
}

meshscale(w, h: int): real
{
	m := 1;
	for(i := 0; i < nv; i++){
		if(abs(vx[i]) > m) m = abs(vx[i]);
		if(abs(vy[i]) > m) m = abs(vy[i]);
		if(abs(vz[i]) > m) m = abs(vz[i]);
	}
	s := real (h/2-36)/real m;
	if(real(w/4-18)/real m < s) s = real(w/4-18)/real m;
	return s;
}

redraw_mesh()
{
	img := win.image;
	if(img == nil) return;
	o := img.r.min; w := img.r.dx(); h := img.r.dy();
	img.draw(img.r, col[7], nil, Point(0, 0));
	mid := o.x+w/2;
	img.line(Point(mid, o.y+Top), Point(mid, o.y+h-36), 0, 0, 0, col[8], Point(0,0));
	sc := meshscale(w, h);
	lc := o.x+w/4; rc := o.x+3*w/4; cy := o.y+(Top+h-36)/2;
	for(i := 0; i < nf; i++){
		if(fa[i] < 0 || fa[i] >= nv || fb[i] < 0 || fb[i] >= nv || fc[i] < 0 || fc[i] >= nv) continue;
		p := array[] of {preview(fa[i],rc,cy,sc), preview(fb[i],rc,cy,sc), preview(fc[i],rc,cy,sc)};
		fcimg := colour(fcol[i]);
		img.fillpoly(p, 0, fcimg, Point(0,0));
		a := ortho(fa[i],lc,cy,sc); b := ortho(fb[i],lc,cy,sc); c := ortho(fc[i],lc,cy,sc);
		img.line(a,b,0,0,0,fcimg,Point(0,0));
		img.line(b,c,0,0,0,fcimg,Point(0,0));
		img.line(c,a,0,0,0,fcimg,Point(0,0));
	}
	for(i = 0; i < nv; i++){
		p := ortho(i,lc,cy,sc); cc := col[15]; if(i == selected) cc = col[14];
		img.fillellipse(p, 3, 3, cc, Point(0,0));
	}
	draw_sliders(img,o.x+Margin,o.y+h-58,w-2*Margin);
	if(font != nil){
		planes := array[] of {"XY/front", "XZ/top", "ZY/side"};
		img.text(Point(o.x+Margin,o.y+5),col[0],Point(0,0),font,
			sys->sprint("%s  %s  mesh %dv/%df",path,name,nv,nf));
		img.text(Point(o.x+Margin,o.y+21),col[0],Point(0,0),font,
			planes[plane]+"  drag:LMB  mark:Space  triangle:T  vertex:V  plane:Tab  save:S");
		img.text(Point(o.x+Margin,o.y+h-20),col[0],Point(0,0),font,status);
	}
	img.flush(Draw->Flushnow);
}

mesh_pointer(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil) return;
	o := img.r.min; w := img.r.dx(); h := img.r.dy();
	if((p.buttons&1) && p.xy.y >= o.y+h-58){
		barw:=w-2*Margin-250; if(barw<64)barw=64;
		band:=(p.xy.y-(o.y+h-58))/14;
		v:=(p.xy.x-(o.x+Margin))*255/barw;
		if(v<0)v=0;if(v>255)v=255;
		if(band>=0 && band<3){setcomp(band,v);status="changed face colour";redraw_mesh();}
		return;
	}
	lc := o.x+w/4; cy := o.y+(Top+h-36)/2; sc := meshscale(w,h);
	if(!(p.buttons&1)){ down = 0; return; }
	if(p.xy.x >= o.x+w/2) return;
	if(!down){
		best := 1000000; selected = -1;
		for(i := 0; i < nv; i++){
			q := ortho(i,lc,cy,sc); dx := q.x-p.xy.x; dy := q.y-p.xy.y; d := dx*dx+dy*dy;
			if(d < best){ best=d; selected=i; }
		}
		if(best > 144) selected = -1;
		down=1; lastx=p.xy.x; lasty=p.xy.y; redraw_mesh(); return;
	}
	if(selected < 0 || sc == 0.0) return;
	dx := int(real(p.xy.x-lastx)/sc); dy := int(real(p.xy.y-lasty)/sc);
	case plane {
	0 => vx[selected] += dx; vy[selected] -= dy;
	1 => vx[selected] += dx; vz[selected] -= dy;
	* => vz[selected] += dx; vy[selected] -= dy;
	}
	lastx=p.xy.x; lasty=p.xy.y; status="modified mesh"; redraw_mesh();
}

abs(v: int): int { if(v < 0) return -v; return v; }

find(s, p: string, start: int): int
{
	if(len p == 0) return start;
	for(i := start; i+len p <= len s; i++)
		if(s[i:i+len p] == p)
			return i;
	return -1;
}

hex(c: int): int
{
	if(c == '.') return -1;
	if(c >= '0' && c <= '9') return c-'0';
	if(c >= 'a' && c <= 'f') return 10+c-'a';
	if(c >= 'A' && c <= 'F') return 10+c-'A';
	return -1;
}
