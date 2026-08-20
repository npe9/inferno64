implement WmHyperdoc;

# A work-alike of Ted Nelson's "Parallel Textface"/hypertext browser (see
# _Computer Lib/Dream Machines_, 1974): two scrollable text panels side by
# side, with a strip between them drawing visible connector lines for
# "collateral structures" - Nelson's named links between spans of two
# documents, independent of either document's own sequence (what his 1965
# paper called "zippered lists"). Selecting a span in each pane and hitting
# Link records a bidirectional link; clicking a linked (highlighted) span
# scrolls the other pane to bring its partner span into view - a simplified
# form of Nelson's "derivative motion". A link whose partner is currently
# scrolled out of view is drawn as a broken arrow pointing toward the edge
# it's off past, matching the convention described in the book.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "wmclient.m";
	wmclient: Wmclient;

WmHyperdoc: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;

LINKDIR: con "/lib/hyperdoc";
LINKSTORE: con "/lib/hyperdoc/links";
CW: con 40;			# width of the connector strip, in pixels
LINKBG: con "#fff2a8";		# highlight for a linked span
LINKLINE: con "#b93a1c";	# connector line colour

curleft, curright: string;	# paths currently loaded in .left.t / .right.t

Viewlink: adt {
	lidx1, lidx2: string;	# tk text indices in .left.t, at creation time
	ridx1, ridx2: string;	# tk text indices in .right.t
	label: string;
	tag: string;		# tk tag name, e.g. "L3"
};

viewlinks: list of ref Viewlink;
ntags := 0;

tkconfig := array[] of {
	"frame .tool",
	"label .tool.status -text {select a span in each pane, then Link} -anchor w",
	"entry .tool.label -bg white -width 20",
	"button .tool.link -text Link -command {send mklink go}",
	"pack .tool.status -side left -expand 1 -fill x",
	"pack .tool.label .tool.link -side left",

	"frame .left",
	"text .left.t -state disabled -bd 0 -width 0 -height 0 -bg white -wrap word"+
		" -yscrollcommand {send redraw l ; .left.yscroll set}",
	"scrollbar .left.yscroll -orient vertical -command {.left.t yview}",
	"pack .left.yscroll -side left -fill y",
	"pack .left.t -expand 1 -fill both",

	"canvas .mid -width " + string CW + " -bg white -highlightthickness 0 -bd 0",

	"frame .right",
	"text .right.t -state disabled -bd 0 -width 0 -height 0 -bg white -wrap word"+
		" -yscrollcommand {send redraw r ; .right.yscroll set}",
	"scrollbar .right.yscroll -orient vertical -command {.right.t yview}",
	"pack .right.yscroll -side left -fill y",
	"pack .right.t -expand 1 -fill both",

	"bind .left.t <Button-1> +{grab set .left.t}",
	"bind .left.t <ButtonRelease-1> +{grab release .left.t}",
	"bind .right.t <Button-1> +{grab set .right.t}",
	"bind .right.t <ButtonRelease-1> +{grab release .right.t}",
	"bind .tool.label <Key-\n> {send mklink go}",

	"pack .tool -fill x",
	"pack .left -side left -expand 1 -fill both",
	"pack .mid -side left -fill y",
	"pack .right -side left -expand 1 -fill both",
	"pack propagate . 0",
	". configure -width 760 -height 480",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->NEWPGRP, nil);

	draw = load Draw Draw->PATH;
	if(draw == nil)
		loaderr("Draw");
	tk = load Tk Tk->PATH;
	if(tk == nil)
		loaderr(Tk->PATH);
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		loaderr(Tkclient->PATH);
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		loaderr(Wmclient->PATH);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	argv = tl argv;
	curleft = "/man/1/intro";
	curright = "/man/1/sh";
	if(argv != nil && tl argv != nil){
		curleft = hd argv;
		curright = hd tl argv;
	}

	tkclient->init();
	buts := Tkclient->Resize | Tkclient->Hide;
	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Hyperdoc", buts);
	redrawc := chan of string;
	mklink := chan of string;
	follow := chan of string;
	tk->namechan(window, redrawc, "redraw");
	tk->namechan(window, mklink, "mklink");
	tk->namechan(window, follow, "follow");
	for(tc := 0; tc < len tkconfig; tc++)
		tkcmd(window, tkconfig[tc]);
	if((err := tkcmd(window, "variable lasterror")) != nil){
		sys->fprint(sys->fildes(2), "hyperdoc: tk initialization failed: %s\n", err);
		raise "fail:tk";
	}
	fittoscreen(window);
	tkcmd(window, "update");

	loadpane(".left.t", curleft);
	loadpane(".right.t", curright);

	if((serr := ensurestore()) != nil)
		setstatus(serr);

	viewlinks = loadlinks();
	for(l := viewlinks; l != nil; l = tl l)
		tagviewlink(hd l);

	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd"::"ptr"::nil);
	redraw();

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or
	s = <-window.wreq or
	s = <-winctl =>
		e := tkclient->wmctl(window, s);
		if(e == nil && s[0] == '!')
			redraw();
	nil := <-redrawc =>
		redraw();
	nil := <-mklink =>
		domklink();
	s := <-follow =>
		dofollow(s);
	}
}

loadpane(w, path: string)
{
	(text, err) := readfile(path);
	if(err != nil)
		text = "(cannot load " + path + ": " + err + ")";
	tkcmd(window, w + " delete 1.0 end");
	tkcmd(window, w + " insert 1.0 " + tk->quote(text));
}

ensurestore(): string
{
	(ok, nil) := sys->stat(LINKDIR);
	if(ok < 0){
		fd := sys->create(LINKDIR, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			return sys->sprint("cannot create %s: %r", LINKDIR);
	}
	(ok2, nil) := sys->stat(LINKSTORE);
	if(ok2 < 0){
		fd := sys->create(LINKSTORE, Sys->OWRITE, 8r666);
		if(fd == nil)
			return sys->sprint("cannot create %s: %r", LINKSTORE);
	}
	return nil;
}

# Every link is stored regardless of which document pair it names; only the
# ones touching the currently-loaded pair (in either order) are shown.
loadlinks(): list of ref Viewlink
{
	(text, err) := readfile(LINKSTORE);
	if(err != nil)
		text = "";
	vl: list of ref Viewlink;
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(line == "")
			continue;
		(nf, f) := sys->tokenize(line, "\t");
		if(nf != 7)
			continue;
		docA := hd f; f = tl f;
		aidx1 := hd f; f = tl f;
		aidx2 := hd f; f = tl f;
		docB := hd f; f = tl f;
		bidx1 := hd f; f = tl f;
		bidx2 := hd f; f = tl f;
		label := hd f;
		ntags++;
		tag := "L" + string ntags;
		if(docA == curleft && docB == curright)
			vl = ref Viewlink(aidx1, aidx2, bidx1, bidx2, label, tag) :: vl;
		else if(docA == curright && docB == curleft)
			vl = ref Viewlink(bidx1, bidx2, aidx1, aidx2, label, tag) :: vl;
	}
	return vl;
}

tagviewlink(v: ref Viewlink)
{
	tkcmd(window, ".left.t tag add " + v.tag + " " + v.lidx1 + " " + v.lidx2);
	tkcmd(window, ".left.t tag configure " + v.tag + " -background " + LINKBG + " -underline 1");
	tkcmd(window, ".left.t tag bind " + v.tag + " <Button-1> {send follow l:" + v.tag + "}");
	tkcmd(window, ".right.t tag add " + v.tag + " " + v.ridx1 + " " + v.ridx2);
	tkcmd(window, ".right.t tag configure " + v.tag + " -background " + LINKBG + " -underline 1");
	tkcmd(window, ".right.t tag bind " + v.tag + " <Button-1> {send follow r:" + v.tag + "}");
}

domklink()
{
	lsel := tkcmd(window, ".left.t tag ranges sel");
	rsel := tkcmd(window, ".right.t tag ranges sel");
	if(lsel == "" || rsel == ""){
		setstatus("select a span in each pane, then Link");
		return;
	}
	(nil, lt) := sys->tokenize(lsel, " ");
	(nil, rt) := sys->tokenize(rsel, " ");
	lidx1 := hd lt;
	lidx2 := hd tl lt;
	ridx1 := hd rt;
	ridx2 := hd tl rt;
	label := tkcmd(window, ".tool.label get");
	if(label == "")
		label = "link";
	label = sanitize(label);

	if((err := appendlink(curleft, lidx1, lidx2, curright, ridx1, ridx2, label)) != nil){
		setstatus(err);
		return;
	}
	ntags++;
	v := ref Viewlink(lidx1, lidx2, ridx1, ridx2, label, "L" + string ntags);
	viewlinks = v :: viewlinks;
	tagviewlink(v);
	tkcmd(window, ".tool.label delete 0 end");
	setstatus("linked: " + label);
	redraw();
}

dofollow(s: string)
{
	if(len s < 3)
		return;
	side := s[0];
	tag := s[2:];
	for(l := viewlinks; l != nil; l = tl l){
		v := hd l;
		if(v.tag != tag)
			continue;
		if(side == 'l'){
			tkcmd(window, ".right.t tag remove sel 1.0 end");
			tkcmd(window, ".right.t tag add sel " + v.ridx1 + " " + v.ridx2);
			tkcmd(window, ".right.t see " + v.ridx1);
		} else {
			tkcmd(window, ".left.t tag remove sel 1.0 end");
			tkcmd(window, ".left.t tag add sel " + v.lidx1 + " " + v.lidx2);
			tkcmd(window, ".left.t see " + v.lidx1);
		}
		setstatus(v.label);
		redraw();
		return;
	}
}

appendlink(af, a1, a2, bf, b1, b2, label: string): string
{
	(text, err) := readfile(LINKSTORE);
	if(err != nil)
		text = "";
	rec := af + "\t" + a1 + "\t" + a2 + "\t" + bf + "\t" + b1 + "\t" + b2 + "\t" + label + "\n";
	return writefile(LINKSTORE, text + rec);
}

# Redraw every connector line in the strip between the two panes, based on
# each linked span's current on-screen position (or lack of one) in each
# text widget. A span currently scrolled out of view draws as a stub arrow
# pointing toward the edge it's off past, rather than a full line - Nelson's
# own convention for an off-screen link endpoint.
redraw()
{
	tkcmd(window, ".mid delete all");
	h := int tkcmd(window, ".mid cget -actheight");
	if(h <= 0)
		return;
	for(l := viewlinks; l != nil; l = tl l){
		v := hd l;
		(lvis, ly, labove) := spanpos(".left.t", v.lidx1);
		(rvis, ry, rabove) := spanpos(".right.t", v.ridx1);
		if(lvis && rvis)
			tkcmd(window, ".mid create line 0 " + string ly + " " + string CW + " " + string ry +
				" -fill " + LINKLINE + " -arrow last");
		else if(lvis && !rvis){
			ty := h - 4;
			if(rabove)
				ty = 4;
			tkcmd(window, ".mid create line 0 " + string ly + " " + string (CW/2) + " " + string ty +
				" -fill " + LINKLINE + " -arrow last");
		} else if(!lvis && rvis){
			ty := h - 4;
			if(labove)
				ty = 4;
			tkcmd(window, ".mid create line " + string CW + " " + string ry + " " + string (CW/2) + " " + string ty +
				" -fill " + LINKLINE + " -arrow last");
		}
		# neither endpoint visible: nothing to anchor a stub to, skip
	}
}

# Returns (visible, ycenter, above) for a span's on-screen position within
# widget w. When not currently visible, "above" says which edge of the
# viewable area it's off past (1 = scrolled above the top, 0 = below the
# bottom) so redraw() can point the stub arrow the right way.
spanpos(w, idx1: string): (int, int, int)
{
	bbox := tkcmd(window, w + " bbox " + idx1);
	if(bbox != ""){
		(nil, toks) := sys->tokenize(bbox, " ");
		y := int hd tl toks;
		ht := int hd tl tl tl toks;
		return (1, y + ht/2, 0);
	}
	cmp := tkcmd(window, w + " compare " + idx1 + " < @0,0");
	if(cmp == "1")
		return (0, 0, 1);
	return (0, 0, 0);
}

setstatus(s: string)
{
	tkcmd(window, ".tool.status configure -text " + tk->quote(s));
}

sanitize(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '\t' || s[i] == '\n')
			r += " ";
		else
			r += s[i:i+1];
	return r;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: " + path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a[0:n], nil);
}

writefile(path, text: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	a := array of byte text;
	if(sys->write(fd, a, len a) != len a)
		return sys->sprint("cannot write %s: %r", path);
	return nil;
}

loaderr(modname: string)
{
	sys->print("cannot load %s module: %r\n", modname);
	raise "fail:init";
}

fittoscreen(win: ref Tk->Toplevel)
{
	Point, Rect: import draw;
	if(win.image == nil || win.image.screen == nil)
		return;
	r := win.image.screen.image.r;
	scrsize := Point((r.max.x - r.min.x), (r.max.y - r.min.y));
	bd := int tkcmd(win, ". cget -bd");
	winsize := Point(int tkcmd(win, ". cget -actwidth") + bd * 2, int tkcmd(win, ". cget -actheight") + bd * 2);
	if(winsize.x > scrsize.x)
		tkcmd(win, ". configure -width " + string (scrsize.x - bd * 2));
	if(winsize.y > scrsize.y)
		tkcmd(win, ". configure -height " + string (scrsize.y - bd * 2));
	actr: Rect;
	actr.min = Point(int tkcmd(win, ". cget -actx"), int tkcmd(win, ". cget -acty"));
	actr.max = actr.min.add((int tkcmd(win, ". cget -actwidth") + bd*2,
				int tkcmd(win, ". cget -actheight") + bd*2));
	(dx, dy) := (actr.dx(), actr.dy());
	if(actr.max.x > r.max.x)
		(actr.min.x, actr.max.x) = (r.max.x - dx, r.max.x);
	if(actr.max.y > r.max.y)
		(actr.min.y, actr.max.y) = (r.max.y - dy, r.max.y);
	if(actr.min.x < r.min.x)
		(actr.min.x, actr.max.x) = (r.min.x, r.min.x + dx);
	if(actr.min.y < r.min.y)
		(actr.min.y, actr.max.y) = (r.min.y, r.min.y + dy);
	tkcmd(win, ". configure -x " + string actr.min.x + " -y " + string actr.min.y);
}

tkcmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->print("tk error %s on '%s'\n", e, s);
	return e;
}
