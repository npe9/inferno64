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
# The dispatch shape matches sh-tk(1) exactly, not a "cmd" sub-verb of
# its own: "plot <id> <text...>" hands text straight to Plotter.cmd()
# with no keyword in between, the same way "tk <id> <text...>" hands
# text straight to tk->cmd() - only "new"/"del" (handle lifecycle) and
# "draw"/"rows"/"value"/"invert" (this module's own additions, not
# part of plot(2)'s string vocabulary at all) are special-cased first
# words, laid over that generic forward exactly the way sh-tk(1)'s own
# "window"/"winctl"/"onscreen"/"namechan"/"del" are laid over ITS
# generic forward. Every verb this module does NOT special-case
# (table/colour/view/content/split/axis/line/scale/clear, a table's
# own append, and anything plot(2) adds later) is plot(2)'s own graph
# command language, forwarded verbatim and unrecognized by this file -
# the same discipline dynsys(2)'s own sh module and danby-aerobraking(1)
# itself already hold to. A forwarded command's own failure is
# reported as a soft $status (sh-tk(1)'s own convention for a bad raw
# tk command) rather than aborting the script - only handle/usage
# errors (a bad id, a missing argument) raise.
Handle: adt {
	id:	int;
	top:	ref Tk->Toplevel;
	buffer:	ref Draw->Image;
	font:	ref Draw->Font;
	graph:	ref Plotter;
	chans:	list of (string, chan of string);
	want:	Point;		# the size "plot new" was asked for
	shown:	int;
};

# The window a handle owns is a real Tk toplevel, so a script can put
# real widgets in it: "plot <id> tk <text...>" is the same generic
# forward to tk->cmd() that sh-tk(1)'s own "tk <winid> <text...>" is,
# aimed at this handle's window instead of one sh-tk(1) opened.  That
# matters because a Shellbuiltin module cannot reach another one's
# tables - sh-tk(1)'s window and channel tables are private to it - so a
# plot cannot be drawn into a window sh-tk(1) opened, and the way to have
# controls around a plot is to put them in the plot's own window.
#
# With "namechan" and "recv" alongside it, that is enough for the whole
# shape: Tk owns the buttons, scales and layout, plot(2) owns the pixels
# of the graph, and the script is the model.  See sh-plot(1)'s own
# EXAMPLE, which is a working predator/prey lab in about eighty lines of
# sh(1).

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
#   plot $id table history t altitude speed
#   plot $id content margin 10 10 10 10
#   plot $id view diagnostics content
#   plot $id draw
#   plot del $id
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if(tl argv == nil)
		ctxt.fail("usage", "usage: plot (new|del|<id> args...)");
	argv = tl argv;
	w := (hd argv).word;
	if(w == "new"){
		remark(ctxt, string newhandle(ctxt, tl argv));
		return nil;
	}
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
		ctxt.fail("usage", "usage: plot <id> (draw|graph-command...)");
	case (hd rest).word {
	"draw" =>
		show(ctxt, h);
		h.graph.draw();
		h.buffer.flush(Draw->Flushnow);
		tkcmd(ctxt, h.top, ".f.p dirty");
		tkcmd(ctxt, h.top, "update");
		return nil;
	"tk" =>
		if(tl rest == nil)
			ctxt.fail("usage", "usage: plot <id> tk command...");
		# a raw forwarded tk command's own failure is a soft $status,
		# the same as sh-tk(1)'s own builtin_tk
		e := tk->cmd(h.top, concat(tl rest));
		if(len e > 0 && e[0] == '!'){
			remark(ctxt, e);
			return e;
		}
		return nil;
	"namechan" =>
		if(len tl rest != 1 && len tl rest != 2)
			ctxt.fail("usage", "usage: plot <id> namechan name [tkname]");
		nm := (hd tl rest).word;
		tkname := nm;
		if(len tl rest == 2)
			tkname = (hd tl tl rest).word;
		c := getchan(h, nm);
		if(c == nil){
			# buffered: tk drops a message it cannot queue, and a
			# scale reports every step of a drag
			c = chan[64] of string;
			h.chans = (nm, c) :: h.chans;
		}
		tk->namechan(h.top, c, tkname);
		return nil;
	"winctl" =>
		if(tl rest == nil)
			ctxt.fail("usage", "usage: plot <id> winctl message");
		tkclient->wmctl(h.top, concat(tl rest));
		return nil;
	"fit" =>
		show(ctxt, h);
		fit(ctxt, h);
		return nil;
	}
	# the generic case: whatever follows the handle id is plot(2)'s own
	# graph command language, unrecognized by this file - forwarded
	# straight to Plotter.cmd(), its own error (if any) reported as a
	# soft $status, the same as sh-tk(1) does for a bad raw tk command.
	err := h.graph.cmd(concat(rest));
	if(err != nil)
		remark(ctxt, err);
	return err;
}

remark(ctxt: ref Context, s: string)
{
	if(ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

# usage:
#   ${plot new WxH [title]}
#   ${plot $id rows name}
#   ${plot $id value name row column}
#   ${plot $id invert view x y}
#   ${plot $id graph-command...}
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
		ctxt.fail("usage", "usage: plot <id> (rows|value|invert|graph-command...)");
	case (hd rest).word {
	"recv" =>
		# pump this window's own keyboard and pointer events while
		# waiting, the way sh-tk(1)'s own ${recv $wid} does: nothing
		# else is servicing them, so without this a binding never
		# fires and a click never reaches a widget
		a := tl rest;
		if(len a > 2)
			ctxt.fail("usage", "usage: plot <id> recv [name [ms]]");
		c: chan of string;
		if(a != nil){
			c = getchan(h, (hd a).word);
			if(c == nil)
				ctxt.fail("bad chan", "plot: no channel "+(hd a).word+
					" on handle "+w);
		}
		# with a timeout, an empty result means nothing happened - so a
		# script can run its own clock in the same loop that reads its
		# own events, which is otherwise the one thing this shape
		# cannot do
		show(ctxt, h);
		tc: chan of int;
		if(len a == 2){
			tc = chan[1] of int;
			spawn timeout(int (hd tl a).word, tc);
		}
		for(;;) alt {
		key := <-h.top.ctxt.kbd =>
			tk->keyboard(h.top, key);
		pt := <-h.top.ctxt.ptr =>
			tk->pointer(h.top, *pt);
		<-tc =>
			return nil;
		v := <-h.top.ctxt.ctl or
		v = <-h.top.wreq or
		v = <-c =>
			return ref Listnode(nil, v) :: nil;
		}
	"tk" =>
		if(tl rest == nil)
			ctxt.fail("usage", "usage: plot <id> tk command...");
		return ref Listnode(nil, tk->cmd(h.top, concat(tl rest))) :: nil;
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
		# a point outside the view is a normal answer to a click, not
		# an error: a script binds one canvas and gets every click in
		# it, including the ones that land in another view's margin.
		# Only a view that does not exist is worth failing over.
		if(err != nil){
			if(len err >= 12 && err[0:12] == "outside view")
				return nil;
			ctxt.fail("plot", "plot: " + err);
		}
		return ref Listnode(nil, sys->sprint("%g", x)) ::
			ref Listnode(nil, sys->sprint("%g", y)) :: nil;
	}
	# same generic forward as the builtin form, matching sh-tk(1)'s own
	# sbuiltin_tk default case - even in substitution form, a raw
	# forwarded command just yields whatever plot(2) itself returned.
	return ref Listnode(nil, h.graph.cmd(concat(rest))) :: nil;
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
	font := Font.open(top.display, "/fonts/lucida/unicode.8.font");

	# The buffer is allocated now, from the display rather than from the
	# window's own image, because every "content"/"split"/"view" command
	# measures the image it is drawing into and a script sets those up
	# before it ever asks for anything to appear.
	chans := top.display.image.chans;
	buffer := top.display.newimage(Rect((0,0),(w.x,w.y)), chans, 0, Draw->White);
	if(buffer == nil)
		ctxt.fail("plot", "plot: cannot allocate drawing buffer");

	# NOT onscreen yet.  A widget created after the window is on screen
	# never receives a pointer event - measured: a scale added after
	# tkclient->onscreen() reports nothing at all when clicked, while
	# the panel created before it reports every click - so a script that
	# wants controls around its plot has to be able to add them first.
	# show() below does it, lazily, at the first thing that needs a
	# window: a script that never adds a widget never notices.
	h := ref Handle(nexthandle++, top, buffer, font, plot->new(buffer, font), nil, w, 0);
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
	# NOT tkclient->wmctl(h.top, "exit") - wmctl's own "exit" case calls
	# exit directly (see appl/lib/tkclient.b), killing this whole
	# process's group; danby-aerobraking(1) can use it safely only
	# because it calls sys->pctl(Sys->NEWPGRP, nil) first, putting
	# itself in a fresh group of its own. This module has no such
	# group of its own to sacrifice - it's a handle inside whatever
	# process is running the calling sh(1) script - so "del" just
	# forgets the handle and leaves the window orphaned on screen, the
	# same trade-off sh-tk(1)'s own "tk del" already makes for exactly
	# this reason.
	slot := hashslot(id);
	nhl: list of ref Handle;
	for(hl := handles[slot]; hl != nil; hl = tl hl)
		if((hd hl).id != id)
			nhl = hd hl :: nhl;
	handles[slot] = nhl;
}

# buffered by one, so this always gets to send and exit even when the
# alt it was made for took another branch first
timeout(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

# Put the window on screen, once, and give the panel an image of the
# size Tk actually gave it.  Everything that needs a visible window calls
# this first.
show(ctxt: ref Context, h: ref Handle)
{
	if(h.shown)
		return;
	h.shown = 1;
	tkcmd(ctxt, h.top, "update");
	tkclient->startinput(h.top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(h.top, nil);
	if(h.top.image == nil)
		ctxt.fail("plot", "plot: onscreen left nil image");
	fit(ctxt, h);
}

getchan(h: ref Handle, name: string): chan of string
{
	for(cl := h.chans; cl != nil; cl = tl cl){
		(n, c) := hd cl;
		if(n == name)
			return c;
	}
	return nil;
}

# The buffer was allocated at the size "plot new" was given.  Once a
# script has packed its own widgets around the panel, or the user has
# resized the window, that is no longer the panel's size - tk->rect()
# says what is, and this reallocates to match.  A plot that is never
# given widgets and never resized never needs it.
fit(ctxt: ref Context, h: ref Handle)
{
	r := tk->rect(h.top, ".f.p", 0);
	(w, hgt) := (r.dx(), r.dy());
	if(w <= 0 || hgt <= 0)
		(w, hgt) = (h.want.x, h.want.y);
	if(h.top.image == nil)
		return;
	if(h.buffer != nil && h.buffer.r.dx() == w && h.buffer.r.dy() == hgt)
		return;
	b := h.top.display.newimage(Rect((0,0),(w,hgt)), h.top.image.chans,
		0, Draw->White);
	if(b == nil)
		ctxt.fail("plot", "plot: cannot allocate drawing buffer");
	h.buffer = b;
	h.graph.image = b;
	e := tk->putimage(h.top, ".f.p", b, nil);
	if(len e > 0 && e[0] == '!')
		ctxt.fail("plot", "plot: putimage: " + e);
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
