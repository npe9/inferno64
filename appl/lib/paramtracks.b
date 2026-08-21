implement Paramtracks;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "string.m";
	str: String;
include "paramtracks.m";

new(image: ref Image, font: ref Font): ref Tracks
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		draw = load Draw Draw->PATH;
		str = load String String->PATH;
	}
	return ref Tracks(image, font, array[0] of ref Track, 30, nil);
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

findcolour(t: ref Tracks, name: string): ref Image
{
	for(l := t.colours; l != nil; l = tl l){
		(n, img) := hd l;
		if(n == name)
			return img;
	}
	return nil;
}

setcolour(t: ref Tracks, name: string, img: ref Image)
{
	t.colours = (name, img) :: t.colours;
}

findtrack(t: ref Tracks, name: string): ref Track
{
	for(i := 0; i < len t.tracks; i++)
		if(t.tracks[i].name == name)
			return t.tracks[i];
	return nil;
}

append(t: ref Tracks, tr: ref Track)
{
	a := array[len t.tracks+1] of ref Track;
	a[0:] = t.tracks;
	a[len t.tracks] = tr;
	t.tracks = a;
}

Tracks.cmd(t: self ref Tracks, command: string): string
{
	# Like plot(2), accept a small command script: newlines separate
	# commands, empty lines are ignored.
	(nil, after) := str->splitl(command, "\n");
	if(after != nil){
		for(rest := command; rest != nil;){
			(line, tail) := str->splitl(rest, "\n");
			if(tail != nil)
				tail = tail[1:];
			if(str->fields(line) != nil){
				err := t.cmd(line);
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
	case a[0] {
	"colour" =>
		if(len a != 3)
			return "usage: colour name rgba";
		if(t.font == nil || t.font.display == nil)
			return "colour: no display";
		setcolour(t, a[1], t.font.display.color(int a[2]));
		return nil;
	"band" =>
		if(len a != 2)
			return "usage: band height";
		t.bandheight = int a[1];
		return nil;
	"track" =>
		if(len a < 4)
			return "usage: track name lo hi [colour name]";
		colour := "accent";
		if(len a >= 6 && a[4] == "colour")
			colour = a[5];
		tr := findtrack(t, a[1]);
		lo := real a[2];
		hi := real a[3];
		if(tr == nil){
			append(t, ref Track(a[1], lo, hi, lo, colour));
		}else{
			tr.lo = lo;
			tr.hi = hi;
			tr.colour = colour;
		}
		return nil;
	"set" =>
		if(len a != 3)
			return "usage: set name value";
		tr := findtrack(t, a[1]);
		if(tr == nil)
			return "set: no such track " + a[1];
		tr.value = real a[2];
		return nil;
	}
	return "unknown paramtracks command: " + a[0];
}

Tracks.value(t: self ref Tracks, name: string): real
{
	tr := findtrack(t, name);
	if(tr == nil)
		return 0.0;
	return tr.value;
}

Tracks.hit(t: self ref Tracks, p: Point, r: Rect): (string, real, int)
{
	n := len t.tracks;
	if(n == 0)
		return ("", 0.0, 0);
	bandtop := r.max.y - t.bandheight;
	if(p.y < bandtop)
		return ("", 0.0, 0);
	width := r.dx()/n;
	which := (p.x-r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(p.x-(r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	if(fraction > 0.99)
		fraction = 0.99;
	tr := t.tracks[which];
	tr.value = tr.lo + fraction*(tr.hi-tr.lo);
	return (tr.name, tr.value, 1);
}

Tracks.draw(t: self ref Tracks, r: Rect)
{
	n := len t.tracks;
	if(n == 0 || t.image == nil)
		return;
	grid := findcolour(t, "grid");
	foreground := findcolour(t, "foreground");
	if(grid == nil)
		grid = foreground;
	width := r.dx()/n;
	bandtop := r.max.y - t.bandheight;
	y := bandtop + t.bandheight*3/4;
	for(i := 0; i < n; i++){
		tr := t.tracks[i];
		left := r.min.x+i*width+8;
		right := left+width-16;
		accent := findcolour(t, tr.colour);
		if(accent == nil)
			accent = foreground;
		if(grid != nil)
			t.image.line((left,y), (right,y), 0, 0, 2, grid, Point(0,0));
		fraction := 0.0;
		if(tr.hi != tr.lo)
			fraction = (tr.value-tr.lo)/(tr.hi-tr.lo);
		x := left+int(fraction*real(right-left));
		if(accent != nil)
			t.image.ellipse((x,y), 4, 4, 0, accent, Point(0,0));
		if(t.font != nil && foreground != nil)
			t.image.text((left,bandtop+t.bandheight-14), foreground, Point(0,0),
				t.font, sys->sprint("%s %.3g", tr.name, tr.value));
	}
}
