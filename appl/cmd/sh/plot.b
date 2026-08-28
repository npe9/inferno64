implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "plot.m";
	plot: Plot;
	Plotter: import plot;

# A loadable sh(1) module giving shell scripts direct access to
# plot(2)'s own graph command language. Plot(2) itself is display-
# agnostic - Plotter.new() just takes an image and a font, and draws
# into whatever image it's handed - so the one thing this file adds
# beyond forwarding to Plotter.cmd()/rows()/value()/invert() is a
# window to draw INTO: a handle here is a small Toplevel (opened the
# same way danby-aerobraking(1) opens its own - a "panel" widget, an
# offscreen buffer image bound to it via tk->putimage, a Plotter over
# that buffer) plus the Plotter itself. This is real, independent work
# from sh-tk(1)'s own window handles (that module's own window table
# is private to it, unreachable from here - Shellbuiltin exposes no
# such thing across modules), not a small mirror of that file.
#
# Every verb this module does NOT list below (table/colour/view/
# content/split/axis/line/scale/clear, and anything plot(2) adds
# later) is plot(2)'s own graph command language, forwarded verbatim
# via "draw $id cmd ..." - this file never recognizes any of it, the
# same discipline dynsys(2)'s own sh module and danby-aerobraking(1)
# itself already hold to.
Handle: adt {
	id:	int;
	top:	ref Tk->Toplevel;
	buffer:	ref Draw->Image;
	font:	ref Draw->Font;
	graph:	ref Plotter;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if(myself == nil)
		ctxt.fail("bad module", sys->sprint("plot: cannot load self: %r"));
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		ctxt.fail("bad module", sys->sprint("plot: cannot load %s: %r", Tk->PATH));
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		ctxt.fail("bad module", sys->sprint("plot: cannot load %s: %r", Tkclient->PATH));
	tkclient->init();
	plot = load Plot Plot->PATH;
	if(plot == nil)
		ctxt.fail("bad module", sys->sprint("plot: cannot load %s: %r", Plot->PATH));
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("plot", myself);
	ctxt.addsbuiltin("plot", myself);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

getself(): Shellbuiltin
{
	return myself;
}

# usage:
#   id := ${plot new WxH [title]}
#   plot $id cmd table history t altitude speed
#   plot $id cmd content margin 10 10 10 10
#   plot $id cmd view diagnostics content
#   plot $id draw
#   plot del $id
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if(tl argv == nil)
		ctxt.fail("usage", "usage: plot (new|del|<id> args...)");
	argv = tl argv;
	w := (hd argv).word;
	if(w == "del"){
		for(argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if(!isnum(w))
		ctxt.fail("usage", "usage: plot (new|del|<id> args...)");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: plot <id> (cmd|draw) args...");
	case (hd rest).word {
	"cmd" =>
		a := tl rest;
		if(a == nil)
			ctxt.fail("usage", "usage: plot <id> cmd graph-command...");
		err := h.graph.cmd(concat(a));
		if(err != nil)
			ctxt.fail("plot", "plot: " + err);
	"draw" =>
		h.graph.draw();
		h.buffer.flush(Draw->Flushnow);
		tkcmd(ctxt, h.top, ".f.p dirty");
		tkcmd(ctxt, h.top, "update");
	* =>
		ctxt.fail("usage", "plot: unknown command " + (hd rest).word);
	}
	return nil;
}

# usage:
#   ${plot new WxH [title]}
#   ${plot $id rows name}
#   ${plot $id value name row column}
#   ${plot $id invert view x y}
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if((hd argv).word != "plot")
		return nil;
	argv = tl argv;
	if(argv == nil)
		ctxt.fail("usage", "usage: plot new WxH [title]");
	w := (hd argv).word;
	if(w == "new")
		return ref Listnode(nil, string newhandle(ctxt, tl argv)) :: nil;
	if(!isnum(w))
		ctxt.fail("usage", "usage: plot new WxH [title] | plot <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: plot <id> (rows|value|invert) args...");
	case (hd rest).word {
	"rows" =>
		a := tl rest;
		if(len a != 1)
			ctxt.fail("usage", "usage: plot <id> rows name");
		return ref Listnode(nil, string h.graph.rows((hd a).word)) :: nil;
	"value" =>
		a := tl rest;
		if(len a != 3)
			ctxt.fail("usage", "usage: plot <id> value name row column");
		(v, err) := h.graph.value((hd a).word, int (hd tl a).word, (hd tl tl a).word);
		if(err != nil)
			ctxt.fail("plot", "plot: " + err);
		return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
	"invert" =>
		a := tl rest;
		if(len a != 3)
			ctxt.fail("usage", "usage: plot <id> invert view x y");
		(x, y, err) := h.graph.invert((hd a).word,
			Point(int (hd tl a).word, int (hd tl tl a).word));
		if(err != nil)
			ctxt.fail("plot", "plot: " + err);
		return ref Listnode(nil, sys->sprint("%g", x)) ::
			ref Listnode(nil, sys->sprint("%g", y)) :: nil;
	}
	return nil;
}

# WxH, an optional title, then opens a real Toplevel exactly the way
# danby-aerobraking(1) does (a single "panel" widget, packed to fill,
# an offscreen buffer image the same size bound to it via
# tk->putimage) and creates a Plotter over the buffer - nothing in
# plot(2) itself changes; this is only the window this module needs to
# have anything visible to draw plot(2)'s own commands into.
newhandle(ctxt: ref Context, argv: list of ref Listnode): int
{
	if(argv == nil)
		ctxt.fail("usage", "usage: plot new WxH [title]");
	(w, herr) := wxh((hd argv).word);
	if(herr != nil)
		ctxt.fail("usage", "plot: " + herr);
	title := "plot";
	if(tl argv != nil)
		title = word(hd tl argv);

	# an interactive sh(1) hosted inside a window (wm, say) already
	# has its own drawcontext, the same one sh-tk(1)'s own "tk window"
	# requires and refuses to substitute for; a bare top-level
	# "sh script" invocation has none, so this falls back to a fresh
	# one, the same way danby-aerobraking(1)'s own init() does for the
	# identical ambiguity (a command that might be run standalone or
	# might be handed a context by whatever launched it).
	dc := ctxt.drawcontext;
	if(dc == nil)
		dc = tkclient->makedrawcontext();
	(top, nil) := tkclient->toplevel(dc, "", title, Tkclient->Appl);
	# "panel" must live inside its own frame, not packed directly under
	# root "." - the same structure danby-aerobraking(1)'s own setup
	# uses ("frame .f" before "panel .f.p"); packing a panel straight
	# under "." fails.
	tkcmd(ctxt, top, "frame .f");
	tkcmd(ctxt, top, sys->sprint("panel .f.p -bd 2 -relief flat -width %d -height %d", w.x, w.y));
	tkcmd(ctxt, top, "pack .f.p -fill both -expand 1");
	tkcmd(ctxt, top, "pack .f -fill both -expand 1");
	tkcmd(ctxt, top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);
	if(top.image == nil)
		ctxt.fail("plot", "plot: onscreen left nil image");

	buffer := top.display.newimage(Rect((0, 0), (w.x, w.y)), top.image.chans, 0, Draw->White);
	if(buffer == nil)
		ctxt.fail("plot", "plot: cannot allocate drawing buffer");
	err := tk->putimage(top, ".f.p", buffer, nil);
	if(len err > 0 && err[0] == '!')
		ctxt.fail("plot", "plot: putimage: " + err);
	font := Font.open(top.display, "/fonts/lucida/unicode.8.font");

	h := ref Handle(nexthandle++, top, buffer, font, plot->new(buffer, font));
	addhandle(h);
	return h.id;
}

# "WxH" -> (Point(w,h), nil), or (Point, an error) - the same NxN
# convention sh-pde(1)/sh-mesh(1) already use for a mesh size.
wxh(s: string): (Point, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == 'x')
			return (Point(int s[0:i], int s[i+1:len s]), nil);
	return (Point(0, 0), "bad size " + s + ", want WxH");
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if(h == nil)
		ctxt.fail("bad id", "plot: unknown handle " + w);
	return h;
}

hashslot(id: int): int
{
	return id % len handles;
}

addhandle(h: ref Handle)
{
	slot := hashslot(h.id);
	handles[slot] = h :: handles[slot];
}

gethandle(id: int): ref Handle
{
	for(hl := handles[hashslot(id)]; hl != nil; hl = tl hl)
		if((hd hl).id == id)
			return hd hl;
	return nil;
}

delhandle(id: int)
{
	h := gethandle(id);
	if(h != nil)
		tkclient->wmctl(h.top, "exit");
	slot := hashslot(id);
	nhl: list of ref Handle;
	for(hl := handles[slot]; hl != nil; hl = tl hl)
		if((hd hl).id != id)
			nhl = hd hl :: nhl;
	handles[slot] = nhl;
}

tkcmd(ctxt: ref Context, top: ref Tk->Toplevel, s: string)
{
	# tk->cmd()'s result is a plain Tcl-style return value on success
	# (many widget commands, "frame" among them, return their own new
	# widget's path - not an error), or an ERROR only when its first
	# byte is '!' - the same convention danby-aerobraking(1)'s own
	# tkcmd() and sh-tk(1)'s own builtin_tk() already check for.
	err := tk->cmd(top, s);
	if(len err > 0 && err[0] == '!')
		ctxt.fail("plot", "plot: tk: " + s + ": " + err);
}

isnum(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] > '9' || s[i] < '0')
			return 0;
	return 1;
}

word(n: ref Listnode): string
{
	if(n.word != nil)
		return n.word;
	if(n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}

concat(argv: list of ref Listnode): string
{
	if(argv == nil)
		return nil;
	s := word(hd argv);
	for(argv = tl argv; argv != nil; argv = tl argv)
		s += " " + word(hd argv);
	return s;
}
