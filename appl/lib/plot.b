implement Plot;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "math.m";
	math: Math;
include "string.m";
	str: String;
include "plot.m";

Line, Pointmark, Vector: con iota;

new(image: ref Image, font: ref Font): ref Plotter
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		draw = load Draw Draw->PATH;
		math = load Math Math->PATH;
		str = load String String->PATH;
	}
	return ref Plotter(image, font, nil, nil, nil, nil);
}

run(p: ref Plotter): chan of ref Plotmsg
{
	commands := chan of ref Plotmsg;
	spawn commandproc(p,commands);
	return commands;
}

commandproc(p: ref Plotter, commands: chan of ref Plotmsg)
{
	for(;;){
		message := <-commands;
		if(message == nil)
			continue;
		error := p.cmd(message.command);
		if(message.reply != nil)
			message.reply <-= error;
	}
}

newtable(columns: array of string, capacity: int): ref Table
{
	if(capacity < 1)
		capacity = 1;
	cols := array[len columns] of array of real;
	for(i := 0; i < len cols; i++)
		cols[i] = array[capacity] of real;
	return ref Table(columns, cols, capacity, 0, 0);
}

tableappend(t: ref Table, values: array of real)
{
	i := 0;
	if(t.n < t.capacity){
		i = (t.head+t.n)%t.capacity;
		t.n++;
	}else{
		i = t.head;
		t.head = (t.head+1)%t.capacity;
	}
	for(j := 0; j < len t.cols; j++)
		if(j < len values)
			t.cols[j][i] = values[j];
}

tableclear(t: ref Table)
{
	t.head = 0;
	t.n = 0;
}

tableget(t: ref Table, row, col: int): real
{
	if(row < 0 || row >= t.n || col < 0 || col >= len t.cols)
		return 0.0;
	return t.cols[col][(t.head+row)%t.capacity];
}

tablecolumn(t: ref Table, name: string): int
{
	for(i := 0; i < len t.names; i++)
		if(t.names[i] == name)
			return i;
	return -1;
}

Scale.map(s: self ref Scale, value: real): int
{
	if(s.hi == s.lo)
		return s.plo;
	# Draw's line rasterizer receives fixed-point coordinates before applying
	# clipr.  Bound mapped data here so an unstable live model cannot overflow
	# that conversion or flood the console with rasterizer diagnostics.
	if(value != value)
		value = s.lo;
	if(value < s.lo)
		value = s.lo;
	if(value > s.hi)
		value = s.hi;
	return s.plo+int((value-s.lo)*real(s.phi-s.plo)/(s.hi-s.lo));
}

Scale.invert(s: self ref Scale, pixel: int): real
{
	if(s.phi == s.plo)
		return s.lo;
	return s.lo+real(pixel-s.plo)*(s.hi-s.lo)/real(s.phi-s.plo);
}

bind(p: ref Plotter, name: string, t: ref Table)
{
	for(l := p.tables; l != nil; l = tl l)
		if((hd l).name == name){
			(hd l).table = t;
			return;
		}
	p.tables = ref Namedtable(name, t) :: p.tables;
}

setcolour(p: ref Plotter, name: string, image: ref Image)
{
	for(l := p.colours; l != nil; l = tl l)
		if((hd l).name == name){
			(hd l).image = image;
			return;
		}
	p.colours = ref Namedimage(name, image) :: p.colours;
}

Plotter.rows(p: self ref Plotter, name: string): int
{
	t := findtable(p,name);
	if(t == nil)
		return 0;
	return t.n;
}

Plotter.value(p: self ref Plotter, name: string, row: int,
		column: string): (real, string)
{
	t := findtable(p,name);
	if(t == nil)
		return (0.0,"value: no such table " + name);
	c := tablecolumn(t,column);
	if(c < 0)
		return (0.0,"value: no such column " + column);
	if(row < 0 || row >= t.n)
		return (0.0,"value: row out of range");
	return (tableget(t,row,c),nil);
}

word(a: array of string, i: int): string
{
	if(i < 0 || i >= len a)
		return nil;
	return a[i];
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

findview(p: ref Plotter, name: string): ref View
{
	for(l := p.views; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

findtable(p: ref Plotter, name: string): ref Table
{
	for(l := p.tables; l != nil; l = tl l)
		if((hd l).name == name)
			return (hd l).table;
	return nil;
}

findcolour(p: ref Plotter, name: string): ref Image
{
	for(l := p.colours; l != nil; l = tl l)
		if((hd l).name == name)
			return (hd l).image;
	return nil;
}

tablecmd(t: ref Table, name: string, a: array of string): string
{
	if(len a < 2)
		return "usage: " + name + " append value... | clear";
	case a[1] {
	"clear" =>
		if(len a != 2)
			return "usage: " + name + " clear";
		tableclear(t);
		return nil;
	"append" =>
		nvalues := len a-2;
		if(nvalues == 0 || nvalues%len t.names != 0)
			return sys->sprint("%s append: needs a multiple of %d values",
				name,len t.names);
		values := array[len t.names] of real;
		for(offset := 0; offset < nvalues; offset += len values){
			for(i := 0; i < len values; i++)
				values[i] = real a[offset+i+2];
			tableappend(t,values);
		}
		return nil;
	* =>
		return "usage: " + name + " append value... | clear";
	}
}

Plotter.cmd(p: self ref Plotter, command: string): string
{
	# Like Tk, accept a small command script as well as one command.  Newlines
	# separate commands; empty lines are ignored.
	(nil, after) := str->splitl(command,"\n");
	if(after != nil){
		for(rest := command; rest != nil;){
			(line, tail) := str->splitl(rest,"\n");
			if(tail != nil)
				tail = tail[1:];
			if(str->fields(line) != nil){
				err := p.cmd(line);
				if(err != nil)
					return err;
			}
			rest = tail;
		}
		return nil;
	}
	a := words(command);
	if(len a == 0)
		return nil;
	namedtable := findtable(p,a[0]);
	if(namedtable != nil)
		return tablecmd(namedtable,a[0],a);
	case a[0] {
	"colour" =>
		if(len a != 3)
			return "usage: colour name rgba";
		if(p.font == nil || p.font.display == nil)
			return "colour: no display";
		setcolour(p,a[1],p.font.display.color(int a[2]));
		return nil;
	"table" =>
		if(len a < 3)
			return "usage: table name column... [-capacity n]";
		capacity := 1024;
		ncols := len a-2;
		for(i := 2; i < len a; i++)
			if(a[i] == "-capacity"){
				if(i+1 >= len a)
					return "table: missing capacity";
				capacity = int a[i+1];
				ncols = i-2;
				break;
			}
		if(ncols < 1)
			return "table: no columns";
		columns := array[ncols] of string;
		for(i = 0; i < ncols; i++)
			columns[i] = a[i+2];
		bind(p,a[1],newtable(columns,capacity));
		return nil;
	"clear" =>
		p.views = nil;
		p.layers = nil;
		return nil;
	"view" =>
		if(len a != 6)
			return "usage: view name x0 y0 x1 y1";
		r := Rect((int a[2],int a[3]),(int a[4],int a[5]));
		v := findview(p,a[1]);
		if(v == nil){
			v = ref View(a[1],r,ref Scale(0.0,1.0,r.min.x,r.max.x),
				ref Scale(0.0,1.0,r.max.y,r.min.y),nil,nil,0,0);
			p.views = v :: p.views;
		}else
			v.r = r;
		return nil;
	"scale" =>
		if(len a < 5)
			return "usage: scale view x|y low high [reverse]";
		v := findview(p,a[1]);
		if(v == nil)
			return "scale: no such view " + a[1];
		reverse := len a > 5 && a[5] == "reverse";
		if(a[2] == "x"){
			v.x = ref Scale(real a[3],real a[4],v.r.min.x,v.r.max.x);
			if(reverse) (v.x.plo,v.x.phi) = (v.x.phi,v.x.plo);
		}else if(a[2] == "y"){
			v.y = ref Scale(real a[3],real a[4],v.r.min.y,v.r.max.y);
			if(reverse) (v.y.plo,v.y.phi) = (v.y.phi,v.y.plo);
		}else
			return "scale: axis must be x or y";
		return nil;
	"axis" =>
		if(len a < 4)
			return "usage: axis view x|y label [grid]";
		v := findview(p,a[1]);
		if(v == nil)
			return "axis: no such view " + a[1];
		grid := len a > 4 && a[4] == "grid";
		if(a[2] == "x") (v.xlabel,v.xgrid) = (a[3],grid);
		else if(a[2] == "y") (v.ylabel,v.ygrid) = (a[3],grid);
		else return "axis: axis must be x or y";
		return nil;
	"line" or "point" or "vector" =>
		if(len a < 8)
			return "usage: line|point|vector view table x column y column options";
		g := Line;
		if(a[0] == "point") g = Pointmark;
		if(a[0] == "vector") g = Vector;
		l := ref Layer(string g,a[1],a[2],nil,nil,nil,nil,"foreground",1,4);
		for(i := 3; i+1 < len a; i += 2)
			case a[i] {
			"x" => l.x = a[i+1];
			"y" => l.y = a[i+1];
			"dx" => l.dx = a[i+1];
			"dy" => l.dy = a[i+1];
			"colour" => l.colour = a[i+1];
			"width" => l.width = int a[i+1];
			"radius" => l.radius = int a[i+1];
			* => return a[0] + ": unknown option " + a[i];
			}
		p.layers = l :: p.layers;
		return nil;
	}
	return "unknown plot command: " + a[0];
}

nice(raw: real): real
{
	if(raw <= 0.0)
		return 1.0;
	p := math->pow(10.0,math->floor(math->log10(raw)));
	f := raw/p;
	if(f <= 1.0) return p;
	if(f <= 2.0) return 2.0*p;
	if(f <= 5.0) return 5.0*p;
	return 10.0*p;
}

drawaxes(p: ref Plotter, v: ref View)
{
	fg := findcolour(p,"foreground");
	grid := findcolour(p,"grid");
	if(fg == nil)
		return;
	if(grid == nil)
		grid = fg;
	p.image.line((v.r.min.x,v.r.max.y),(v.r.max.x,v.r.max.y),0,0,1,fg,(0,0));
	p.image.line((v.r.min.x,v.r.min.y),(v.r.min.x,v.r.max.y),0,0,1,fg,(0,0));
	xstep := nice((v.x.hi-v.x.lo)/5.0);
	for(xv := math->ceil(v.x.lo/xstep)*xstep; xv <= v.x.hi+xstep/10.0; xv += xstep){
		x := v.x.map(xv);
		if(v.xgrid) p.image.line((x,v.r.min.y),(x,v.r.max.y),0,0,0,grid,(0,0));
		p.image.text((x-12,v.r.max.y+13),fg,(0,0),p.font,sys->sprint("%.3g",xv));
	}
	ystep := nice((v.y.hi-v.y.lo)/5.0);
	for(yv := math->ceil(v.y.lo/ystep)*ystep; yv <= v.y.hi+ystep/10.0; yv += ystep){
		y := v.y.map(yv);
		if(v.ygrid) p.image.line((v.r.min.x,y),(v.r.max.x,y),0,0,0,grid,(0,0));
		p.image.text((v.r.min.x-34,y+4),fg,(0,0),p.font,sys->sprint("%.3g",yv));
	}
	p.image.text(((v.r.min.x+v.r.max.x-p.font.width(v.xlabel))/2,v.r.max.y+27),
		fg,(0,0),p.font,v.xlabel);
	p.image.text((v.r.min.x+5,v.r.min.y+12),
		fg,(0,0),p.font,v.ylabel);
}

Plotter.draw(p: self ref Plotter)
{
	for(vl := p.views; vl != nil; vl = tl vl)
		drawaxes(p,hd vl);
	ordered: list of ref Layer;
	for(ll := p.layers; ll != nil; ll = tl ll)
		ordered = hd ll :: ordered;
	for(ll = ordered; ll != nil; ll = tl ll){
		l := hd ll;
		v := findview(p,l.view);
		t := findtable(p,l.table);
		colour := findcolour(p,l.colour);
		if(v == nil || t == nil || colour == nil)
			continue;
		xc := tablecolumn(t,l.x);
		yc := tablecolumn(t,l.y);
		dxc := tablecolumn(t,l.dx);
		dyc := tablecolumn(t,l.dy);
		if(xc < 0 || yc < 0)
			continue;
		oldclip := p.image.clipr;
		p.image.clipr = v.r;
		g := int l.geometry;
		case g {
		Line =>
			for(i := 1; i < t.n; i++)
				p.image.line((v.x.map(tableget(t,i-1,xc)),v.y.map(tableget(t,i-1,yc))),
					(v.x.map(tableget(t,i,xc)),v.y.map(tableget(t,i,yc))),0,0,l.width,colour,(0,0));
		Pointmark =>
			for(i := 0; i < t.n; i++)
				p.image.ellipse((v.x.map(tableget(t,i,xc)),v.y.map(tableget(t,i,yc))),
					l.radius,l.radius,0,colour,(0,0));
		Vector =>
			if(dxc >= 0 && dyc >= 0)
				for(i := 0; i < t.n; i++){
					x := tableget(t,i,xc);
					y := tableget(t,i,yc);
					a := Point(v.x.map(x),v.y.map(y));
					b := Point(v.x.map(x+tableget(t,i,dxc)),v.y.map(y+tableget(t,i,dyc)));
					p.image.line(a,b,0,0,l.width,colour,(0,0));
					vx := real(b.x-a.x); vy := real(b.y-a.y);
					veclen := math->sqrt(vx*vx+vy*vy);
					if(veclen > 2.0){
						vx /= veclen; vy /= veclen;
						q1 := Point(b.x-int(4.0*vx-2.5*vy),b.y-int(4.0*vy+2.5*vx));
						q2 := Point(b.x-int(4.0*vx+2.5*vy),b.y-int(4.0*vy-2.5*vx));
						p.image.line(b,q1,0,0,l.width,colour,(0,0));
						p.image.line(b,q2,0,0,l.width,colour,(0,0));
					}
				}
		}
		p.image.clipr = oldclip;
	}
}

Plotter.invert(p: self ref Plotter, name: string, point: Point): (real, real, string)
{
	v := findview(p,name);
	if(v == nil)
		return (0.0,0.0,"no such view " + name);
	if(point.x < v.r.min.x || point.x >= v.r.max.x ||
			point.y < v.r.min.y || point.y >= v.r.max.y)
		return (0.0,0.0,"outside view " + name);
	return (v.x.invert(point.x),v.y.invert(point.y),nil);
}
