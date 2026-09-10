implement Titlebar;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "env.m";
include "titlebar.m";
include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	plumbready: int;

# Soft Plan9 Paper: inactive cool slate #8A9098, active accent #3D6A9A,
# titlebar buttons use soft chrome #D4D0C4 so bitmaps stay readable.
title_cfg := array[] of {
	"frame .Wm_t -bg #8A9098 -borderwidth 1",
	"label .Wm_t.title -anchor w -bg #8A9098 -fg white",
	"button .Wm_t.e -bitmap exit.bit -command {send wm_title exit} -takefocus 0 -bg #D4D0C4 -fg #2A2A22",
	"pack .Wm_t.e -side right",
	"bind .Wm_t <Button-1> {send wm_title move %X %Y}",
	"bind .Wm_t <Double-Button-1> {send wm_title lower .}",
	"bind .Wm_t <Motion-Button-1> {}",
	"bind .Wm_t <Motion> {}",
	"bind .Wm_t.title <Button-1> {send wm_title move %X %Y}",
	"bind .Wm_t.title <Double-Button-1> {send wm_title lower .}",
	"bind .Wm_t.title <Motion-Button-1> {}",
	"bind .Wm_t.title <Motion> {}",
	"bind . <FocusIn> {.Wm_t configure -bg #3D6A9A;"+
		".Wm_t.title configure -bg #3D6A9A -fg white;update}",
	"bind . <FocusOut> {.Wm_t configure -bg #8A9098;"+
		".Wm_t.title configure -bg #8A9098 -fg white;update}",
};

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	plumbready = 0;
}

new(top: ref Tk->Toplevel, buts: int): chan of string
{
	ctl := chan of string;
	tk->namechan(top, ctl, "wm_title");

	if(buts & Plain)
		return ctl;

	for(i := 0; i < len title_cfg; i++)
		cmd(top, title_cfg[i]);

	if(buts & OK)
		cmd(top, "button .Wm_t.ok -bitmap ok.bit"+
			" -command {send wm_title ok} -takefocus 0 -bg #D4D0C4 -fg #2A2A22; pack .Wm_t.ok -side right");

	if(buts & Hide)
		cmd(top, "button .Wm_t.top -bitmap task.bit"+
			" -command {send wm_title task} -takefocus 0 -bg #D4D0C4 -fg #2A2A22; pack .Wm_t.top -side right");

	if(buts & Resize)
		cmd(top, "button .Wm_t.m -bitmap maxf.bit"+
			" -command {send wm_title size} -takefocus 0 -bg #D4D0C4 -fg #2A2A22; pack .Wm_t.m -side right");

	# Always offer a help (?) button on decorated windows.
	cmd(top, "button .Wm_t.h -bitmap help.bit"+
		" -command {send wm_title help} -takefocus 0 -bg #D4D0C4 -fg #2A2A22; pack .Wm_t.h -side right");

	# Pencil: find this program's Limbo source and send it to the editor.
	cmd(top, "button .Wm_t.d -bitmap @/icons/charon/edit.bit"+
		" -command {send wm_title source} -takefocus 0 -bg #D4D0C4 -fg #2A2A22; pack .Wm_t.d -side right");

	# pack the title last so it gets clipped first
	cmd(top, "pack .Wm_t.title -side left");
	cmd(top, "pack .Wm_t -fill x");

	scalechrome(top);

	return ctl;
}

# Which button carries which piece of artwork.  A configuration that does
# not have one of these simply has no such widget.
chromebuts := array[] of {
	(".Wm_t.e",	"exit.bit"),
	(".Wm_t.ok",	"ok.bit"),
	(".Wm_t.top",	"task.bit"),
	(".Wm_t.m",	"maxf.bit"),
	(".Wm_t.h",	"help.bit"),
	(".Wm_t.d",	"/icons/charon/edit.bit"),
};

#
# Grow the chrome's artwork with the font.
#
# The icons in /icons/tk are 16 pixels square, and libtk resolves a bare
# -bitmap name straight to that directory, so they are one fixed size
# while the bar around them follows the font.  Measured: at the tree's
# 8-pixel face the title is 15 pixels high and a button 20; at a face
# twice as tall the title is 30 and the button is still 20.
#
# Scale by a whole number and replicate pixels rather than resample -
# this is pixel art, and blurring it would look worse than leaving it
# small.  libtk draws -image and -bitmap through the same code, choosing
# between stencil and picture on the image's *channel* rather than on
# which option was used, so an 8-bit grey icon handed over as an image is
# still drawn in the button's own -fg and nothing changes but the size.
#
# At scale 1 - every configuration that exists today - this returns
# without touching anything.
#
scalechrome(top: ref Tk->Toplevel)
{
	if(top == nil || top.display == nil)
		return;
	fp := tk->cmd(top, ".Wm_t.title cget -font");
	if(len fp == 0 || fp[0] == '!')
		fp = tk->cmd(top, ". cget -font");
	if(len fp == 0 || fp[0] == '!')
		return;
	f := Font.open(top.display, fp);
	if(f == nil)
		return;
	n := (f.height + 8) / 16;
	if(n < 2)
		return;
	for(i := 0; i < len chromebuts; i++){
		(w, art) := chromebuts[i];
		if(tk->cmd(top, "winfo class " + w)[0] == '!')
			continue;
		if(len art > 0 && art[0] != '/')
			art = "/icons/tk/" + art;
		scaleicon(top, w, art, n);
	}
}

scaleicon(top: ref Tk->Toplevel, w, art: string, n: int)
{
	src := top.display.open(art);
	if(src == nil || src.depth != 8)
		return;			# one byte a pixel, which every icon here is
	sw := src.r.dx();
	sh := src.r.dy();
	if(sw <= 0 || sh <= 0)
		return;
	buf := array[sw*sh] of byte;
	if(src.readpixels(src.r, buf) != len buf)
		return;

	dw := sw*n;
	dh := sh*n;
	out := array[dw*dh] of byte;
	for(y := 0; y < dh; y++){
		row := (y/n)*sw;
		o := y*dw;
		for(x := 0; x < dw; x++)
			out[o+x] = buf[row + x/n];
	}
	dst := top.display.newimage(Rect((0,0),(dw,dh)), src.chans, 0, Draw->Nofill);
	if(dst == nil || dst.writepixels(dst.r, out) != len out)
		return;

	name := tk->cmd(top, "image create bitmap");
	if(len name == 0 || name[0] == '!')
		return;
	if(tk->putimage(top, name, dst, nil) != nil)
		return;
	cmd(top, w + " configure -image " + name);
}

title(top: ref Tk->Toplevel): string
{
	if(tk->cmd(top, "winfo class .Wm_t.title")[0] != '!')
		return cmd(top, ".Wm_t.title cget -text");
	return nil;
}
	
settitle(top: ref Tk->Toplevel, t: string): string
{
	s := title(top);
	tk->cmd(top, ".Wm_t.title configure -text '" + t);
	return s;
}

sendctl(top: ref Tk->Toplevel, c: string)
{
	cmd(top, "send wm_title " + c);
}

minsize(top: ref Tk->Toplevel): Point
{
	buts := array[] of {"e", "ok", "top", "m", "h", "d"};
	r := tk->rect(top, ".", Tk->Border);
	r.min.x = r.max.x;
	r.max.y = r.min.y;
	for(i := 0; i < len  buts; i++){
		br := tk->rect(top, ".Wm_t." + buts[i], Tk->Border);
		if(br.dx() > 0)
			r = r.combine(br);
	}
	r.max.x += tk->rect(top, ".Wm_t." + buts[0], Tk->Border).dx();
	sz := r.size();
	# The buttons are fixed-size bitmaps and the title is text, so the
	# bar is as tall as whichever is taller.  Measured from the buttons
	# alone this came out one pixel short of the bar at the 8-pixel font
	# and twelve short at a 32-pixel one, which is a window that may be
	# resized shorter than its own titlebar.
	bar := tk->rect(top, ".Wm_t", Tk->Border);
	if(bar.dy() > sz.y)
		sz.y = bar.dy();
	return sz;
}

exists(path: string): int
{
	if(path == nil)
		return 0;
	(ok, d) := sys->stat(path);
	return ok >= 0 && (d.mode & Sys->DMDIR) == 0;
}

mappedsource(dis: string): string
{
	if(dis == nil)
		return nil;
	if(len dis < 5 || dis[0:5] != "/dis/")
		dis = "/dis/" + dis;
	rel := dis[5:];
	if(len rel > 4 && rel[len rel-4:] == ".dis")
		rel = rel[0:len rel-4];
	if(rel == nil)
		return nil;

	candidates := "/appl/" + rel + ".b" ::
		"/appl/cmd/" + rel + ".b" :: nil;
	stem := rel;
	for(i := len rel - 1; i >= 0; i--)
		if(rel[i] == '/'){
			stem = rel[i+1:];
			break;
		}
	if(stem == rel)
		candidates = "/appl/wm/" + stem + ".b" ::
			"/appl/lib/" + stem + ".b" ::
			"/appl/" + stem + "/" + stem + ".b" ::
			"/appl/cmd/" + stem + "/" + stem + ".b" :: candidates;
	for(; candidates != nil; candidates = tl candidates)
		if(exists(hd candidates))
			return hd candidates;
	return nil;
}

libraryframe(dis: string): int
{
	return dis == "/dis/lib/titlebar.dis" || dis == "/dis/lib/wmclient.dis" ||
		dis == "/dis/lib/tkclient.dis" || dis == "/dis/lib/wmlib.dis";
}

stacksource(): string
{
	fd := sys->open("/prog/"+string sys->pctl(0, nil)+"/stack", Sys->OREAD);
	if(fd == nil)
		return nil;
	a := array[8192] of byte;
	n := sys->read(fd, a, len a);
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string a[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nil, fields) := sys->tokenize(hd lines, " \t");
		if(len fields < 6)
			continue;
		dis := hd fields;
		for(; tl fields != nil; fields = tl fields)
			dis = hd tl fields;
		if(libraryframe(dis))
			continue;
		if((s := mappedsource(dis)) != nil)
			return s;
	}
	return nil;
}

sourcepath(dis: string): string
{
	env := load Env Env->PATH;
	if(env != nil){
		s := env->getenv("wmsource");
		if(exists(s))
			return s;
	}
	# The live stack is authoritative for wmclient applications launched
	# through scripts; their inherited $dis can name the wrapper or helper.
	if((s := stacksource()) != nil)
		return s;
	if(dis == nil && env != nil)
		dis = env->getenv("dis");
	return mappedsource(dis);
}

develop(dispath: string): string
{
	path := sourcepath(dispath);
	if(path == nil)
		return "cannot find source for " + dispath;
	# Keep the module resident.  Plumbmsg's file-I/O helper can still be
	# completing the write after Msg.send returns; a handler-local module
	# reference allowed it to be unloaded underneath that helper.
	if(plumbmsg == nil)
		plumbmsg = load Plumbmsg Plumbmsg->PATH;
	if(plumbmsg == nil)
		return sys->sprint("cannot load %s: %r", Plumbmsg->PATH);
	Msg, Attr: import plumbmsg;
	if(!plumbready){
		if(plumbmsg->init(1, nil, 0) < 0)
			return sys->sprint("cannot connect to plumber: %r");
		plumbready = 1;
	}
	env := load Env Env->PATH;
	args := "";
	if(env != nil)
		args = env->getenv("wmargs");
	dir := "/";
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/'){
			dir = path[0:i];
			break;
		}
	attrs := ref Attr("action", "develop") ::
		ref Attr("program", dispath) ::
		ref Attr("argv", args) ::
		ref Attr("pid", string sys->pctl(0, nil)) :: nil;
	# Put the complete launch description in the text payload.  The plumber
	# passes it as one ordinary startup argument, so Develop need not load the
	# asynchronous Plumbmsg module merely to decode its initial request.
	argfield := args;
	if(argfield == nil)
		argfield = "-";
	payload := path+"\n"+dispath+"\n"+argfield+"\n"+string sys->pctl(0, nil);
	msg := ref Msg("titlebar", nil, dir, "text",
		plumbmsg->attrs2string(attrs), array of byte payload);
	if(msg.send() < 0)
		return sys->sprint("cannot send source to plumber: %r");
	return nil;
}

cmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if (e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "wmclient: tk error %s on '%s'\n", e, s);
	return e;
}
