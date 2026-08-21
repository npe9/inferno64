implement Thinkertoy;

# Nelson's Dream Machines chapter on Thinkertoys/decision-creativity
# systems: a computer display that helps you envision complex
# alternatives, rather than forcing you to hold the whole branching
# structure in your head. This is a plain branching-alternatives tree
# editor - each node is a decision, option, or consequence; children are
# its alternatives or outcomes - direct manipulation: drag any node
# wherever you want it, the connector lines just follow. A new node gets
# a sensible default position near where it was added from, not dropped
# at some fixed origin, but nothing here fights a drag by silently
# resetting position - only the explicit "Auto Layout" button recomputes
# the whole tree's positions from scratch (each subtree's width is the
# sum of its children's widths, a node centred over its own children),
# for when manual placement has gotten messy and a clean reset is
# wanted. Persisted as a plain tab-indented outline (one line per node -
# tab count = depth, then the label and its saved x,y position, tab-
# separated) - readable and editable outside this program too, matching
# how everything else in this tree favours plain text; a manually
# arranged layout survives a save/reload exactly as left, an older
# position-less file gets one fresh Auto Layout on load instead of
# piling every node at the origin.
#
# usage: dreammachines/thinkertoy [file]

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

Thinkertoy: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;

BOXW: con 120;
BOXH: con 40;
XGAP: con 24;
YGAP: con 50;
MARGIN: con 20;

SELFILL: con "#fff2a8";
PLAINFILL: con "white";

Node: adt {
	label: string;
	children: list of ref Node;
	parent: cyclic ref Node;
	x, y, w, h: int;	# computed by layout(); (x,y) is the box's top-left
};

root: ref Node;
selected: ref Node;
dragging: ref Node;
dragdx, dragdy: int;
savepath := "/lib/thinkertoy/tree.tt";

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
	if(argv != nil)
		savepath = hd argv;

	(r, haspos, err) := load_(savepath);
	needlayout := 1;
	if(r != nil){
		root = r;
		needlayout = haspos == 0;
	}else
		root = ref Node("start", nil, nil, 0, 0, 0, 0);
	selected = root;

	tkclient->init();
	buts := Tkclient->Resize | Tkclient->Hide;
	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Thinkertoy", buts);
	cmdc := chan of string;
	mousec := chan of string;
	tk->namechan(window, cmdc, "cmd");
	tk->namechan(window, mousec, "mouse");
	for(tc := 0; tc < len tkconfig; tc++)
		tkcmd(window, tkconfig[tc]);
	if((e := tkcmd(window, "variable lasterror")) != nil){
		sys->fprint(sys->fildes(2), "thinkertoy: tk initialization failed: %s\n", e);
		raise "fail:tk";
	}
	fittoscreen(window);
	tkcmd(window, "update");

	if(err != nil)
		setstatus("new tree (" + err + ")");
	if(needlayout)
		relayout();
	else
		redraw();

	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or
	s = <-window.wreq or
	s = <-winctl =>
		werr := tkclient->wmctl(window, s);
		if(werr == nil && s[0] == '!')
			redraw();
	s := <-cmdc =>
		docmd(s);
	s := <-mousec =>
		domouse(s);
	}
}

tkconfig := array[] of {
	"frame .tool",
	"label .tool.status -text {click a node to select it} -anchor w",
	"entry .tool.label -bg white -width 20",
	"button .tool.child -text {Add Child} -command {send cmd child}",
	"button .tool.sibling -text {Add Sibling} -command {send cmd sibling}",
	"button .tool.rename -text Rename -command {send cmd rename}",
	"button .tool.delete -text Delete -command {send cmd delete}",
	"button .tool.relayout -text {Auto Layout} -command {send cmd relayout}",
	"button .tool.save -text Save -command {send cmd save}",
	"pack .tool.status -side left -expand 1 -fill x",
	"pack .tool.label .tool.child .tool.sibling .tool.rename .tool.delete .tool.relayout .tool.save -side left",

	"frame .view",
	"canvas .view.c -bg white -yscrollcommand {.view.yscroll set} -xscrollcommand {.view.xscroll set}",
	"scrollbar .view.yscroll -orient vertical -command {.view.c yview}",
	"scrollbar .view.xscroll -orient horizontal -command {.view.c xview}",
	"pack .view.yscroll -side left -fill y",
	"pack .view.xscroll -side bottom -fill x",
	"pack .view.c -expand 1 -fill both",

	# Direct manipulation: press selects (and remembers the click offset
	# into the node, so dragging doesn't snap the node to the pointer),
	# motion-while-down moves it live, release just stops. Same
	# press/motion/release-suffixed event names pinboard.b's canvas
	# dragging already uses in this tree.
	"bind .view.c <ButtonPress-1>   {send mouse press %x %y}",
	"bind .view.c <Motion-Button-1> {send mouse drag %x %y}",
	"bind .view.c <ButtonRelease-1> {send mouse release %x %y}",
	"bind .tool.label <Key-\n> {send cmd rename}",

	"pack .tool -fill x",
	"pack .view -expand 1 -fill both",
	"pack propagate . 0",
	". configure -width 820 -height 520",
};

# --- tree structure helpers ---

appendchild(l: list of ref Node, n: ref Node): list of ref Node
{
	if(l == nil)
		return n :: nil;
	return hd l :: appendchild(tl l, n);
}

filterout(l: list of ref Node, c: ref Node): list of ref Node
{
	if(l == nil)
		return nil;
	if(hd l == c)
		return filterout(tl l, c);
	return hd l :: filterout(tl l, c);
}

nchildren(l: list of ref Node): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

# --- layout: each subtree's width is the sum of its children's widths
# (a leaf is one box wide), a parent centred over its own children's span -
# adding or removing a branch anywhere just reflows everything else. ---

subtreewidth(n: ref Node): int
{
	if(n.children == nil)
		return BOXW;
	w := 0;
	for(c := n.children; c != nil; c = tl c)
		w += subtreewidth(hd c);
	w += (nchildren(n.children)-1)*XGAP;
	return w;
}

layout(n: ref Node, xleft, depth: int)
{
	n.y = depth*(BOXH+YGAP);
	n.w = BOXW;
	n.h = BOXH;
	if(n.children == nil){
		n.x = xleft;
		return;
	}
	cx := xleft;
	firstcx := -1;
	lastcx := -1;
	for(c := n.children; c != nil; c = tl c){
		child := hd c;
		cw := subtreewidth(child);
		layout(child, cx, depth+1);
		if(firstcx < 0)
			firstcx = child.x;
		lastcx = child.x;
		cx += cw+XGAP;
	}
	n.x = (firstcx+lastcx)/2;
}

nodeat(n: ref Node, x, y: int): ref Node
{
	if(x >= n.x && x < n.x+n.w && y >= n.y && y < n.y+n.h)
		return n;
	for(c := n.children; c != nil; c = tl c){
		found := nodeat(hd c, x, y);
		if(found != nil)
			return found;
	}
	return nil;
}

# Bounding box of the whole tree as actually positioned right now - not
# assumed to start at (MARGIN,0), since a drag can move a node anywhere,
# including up/left of wherever the tree originally started.
treebounds(n: ref Node): (int, int, int, int)
{
	x0 := n.x;
	y0 := n.y;
	x1 := n.x+n.w;
	y1 := n.y+n.h;
	for(c := n.children; c != nil; c = tl c){
		(cx0, cy0, cx1, cy1) := treebounds(hd c);
		if(cx0 < x0) x0 = cx0;
		if(cy0 < y0) y0 = cy0;
		if(cx1 > x1) x1 = cx1;
		if(cy1 > y1) y1 = cy1;
	}
	return (x0, y0, x1, y1);
}

# --- drawing ---

drawnode(n: ref Node)
{
	fill := PLAINFILL;
	if(n == selected)
		fill = SELFILL;
	tkcmd(window, sys->sprint(".view.c create rectangle %d %d %d %d -fill %s -outline black -width 2",
		n.x, n.y, n.x+n.w, n.y+n.h, fill));
	tkcmd(window, sys->sprint(".view.c create text %d %d -width %d -justify center -text ",
		n.x+n.w/2, n.y+n.h/2, n.w-8) + tk->quote(n.label));
	for(c := n.children; c != nil; c = tl c){
		child := hd c;
		tkcmd(window, sys->sprint(".view.c create line %d %d %d %d -fill gray -width 2",
			n.x+n.w/2, n.y+n.h, child.x+child.w/2, child.y));
		drawnode(child);
	}
}

# Recomputes every node's position from scratch (the "Auto Layout"
# button, and the initial layout for a brand new or position-less tree).
# Nothing else calls this - see the file's own header comment for why an
# add/delete/drag deliberately doesn't.
relayout()
{
	layout(root, MARGIN, 0);
	redraw();
}

# Draws the tree at whatever positions its nodes currently hold - never
# recomputes them. Safe to call after a drag, a selection change, or a
# rename without disturbing manual placement.
redraw()
{
	tkcmd(window, ".view.c delete all");
	drawnode(root);
	(x0, y0, x1, y1) := treebounds(root);
	tkcmd(window, sys->sprint(".view.c configure -scrollregion {%d %d %d %d}",
		x0-MARGIN, y0-MARGIN, x1+MARGIN, y1+MARGIN));
}

# --- interaction ---

domouse(s: string)
{
	(nil, toks) := sys->tokenize(s, " ");
	if(toks == nil || tl toks == nil || tl tl toks == nil)
		return;
	verb := hd toks;
	wx := int hd tl toks;
	wy := int hd tl tl toks;
	cx := int tkcmd(window, sys->sprint(".view.c canvasx %d", wx));
	cy := int tkcmd(window, sys->sprint(".view.c canvasy %d", wy));
	case verb {
	"press" =>
		n := nodeat(root, cx, cy);
		if(n == nil)
			return;
		selected = n;
		dragging = n;
		dragdx = cx-n.x;
		dragdy = cy-n.y;
		setstatus("selected: " + n.label);
		tkcmd(window, ".tool.label delete 0 end");
		tkcmd(window, ".tool.label insert 0 " + tk->quote(n.label));
		redraw();
	"drag" =>
		if(dragging == nil)
			return;
		dragging.x = cx-dragdx;
		dragging.y = cy-dragdy;
		redraw();
	"release" =>
		dragging = nil;
	}
}

docmd(s: string)
{
	case s {
	"child" =>
		if(selected == nil){
			setstatus("select a node first");
			return;
		}
		label := entrytext();
		if(label == "")
			label = "new";
		# Default position only - stack new children in a row below
		# their parent, offset by however many already exist so they
		# don't land on top of each other. Everything else on screen,
		# manually placed or not, keeps its position untouched.
		nb4 := nchildren(selected.children);
		n := ref Node(label, nil, selected,
			selected.x + nb4*(BOXW+XGAP), selected.y+BOXH+YGAP, BOXW, BOXH);
		selected.children = appendchild(selected.children, n);
		selected = n;
		setstatus("added child: " + label);
		redraw();
	"sibling" =>
		if(selected == nil || selected.parent == nil){
			setstatus("root has no siblings - select another node");
			return;
		}
		label := entrytext();
		if(label == "")
			label = "new";
		p := selected.parent;
		n := ref Node(label, nil, p, selected.x+BOXW+XGAP, selected.y, BOXW, BOXH);
		p.children = appendchild(p.children, n);
		selected = n;
		setstatus("added sibling: " + label);
		redraw();
	"rename" =>
		if(selected == nil){
			setstatus("select a node first");
			return;
		}
		label := entrytext();
		if(label == ""){
			setstatus("type a new label first");
			return;
		}
		selected.label = label;
		setstatus("renamed to: " + label);
		redraw();
	"delete" =>
		if(selected == nil || selected.parent == nil){
			setstatus("can't delete the root");
			return;
		}
		p := selected.parent;
		p.children = filterout(p.children, selected);
		selected = p;
		setstatus("deleted");
		redraw();
	"relayout" =>
		setstatus("auto-arranged the whole tree");
		relayout();
	"save" =>
		if((err := save(savepath)) != nil)
			setstatus("save failed: " + err);
		else
			setstatus("saved to " + savepath);
	}
}

entrytext(): string
{
	return tkcmd(window, ".tool.label get");
}

setstatus(s: string)
{
	tkcmd(window, ".tool.status configure -text " + tk->quote(s));
}

# --- persistence: a plain tab-indented outline, one line per node ---

save(path: string): string
{
	ensuredir(path);
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	savenode(fd, root, 0);
	return nil;
}

savenode(fd: ref Sys->FD, n: ref Node, depth: int)
{
	indent := "";
	for(i := 0; i < depth; i++)
		indent += "\t";
	sys->fprint(fd, "%s%s\t%d\t%d\n", indent, n.label, n.x, n.y);
	for(c := n.children; c != nil; c = tl c)
		savenode(fd, hd c, depth+1);
}

ensuredir(path: string)
{
	i := len path-1;
	while(i > 0 && path[i] != '/')
		i--;
	if(i <= 0)
		return;
	dir := path[0:i];
	(ok, nil) := sys->stat(dir);
	if(ok < 0)
		sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
}

load_(path: string): (ref Node, int, string)
{
	(text, err) := readfile(path);
	if(err != nil)
		return (nil, 0, err);
	(nil, lines) := sys->tokenize(text, "\n");
	rootnode: ref Node;
	stack: list of (int, ref Node);
	allpositioned := 1;
	for(l := lines; l != nil; l = tl l){
		line := hd l;
		if(line == "")
			continue;
		depth := 0;
		i := 0;
		while(i < len line && line[i] == '\t'){
			depth++;
			i++;
		}
		rest := line[i:];
		(nf, ftoks) := sys->tokenize(rest, "\t");
		label: string;
		nx := 0;
		ny := 0;
		if(nf >= 3){
			label = hd ftoks;
			nx = int hd tl ftoks;
			ny = int hd tl tl ftoks;
		} else {
			label = rest;
			allpositioned = 0;
		}
		n := ref Node(label, nil, nil, nx, ny, BOXW, BOXH);
		if(depth == 0){
			rootnode = n;
			stack = (0, n) :: nil;
		} else {
			parent: ref Node;
			for(sp := stack; sp != nil; sp = tl sp){
				(d, nd) := hd sp;
				if(d == depth-1){
					parent = nd;
					break;
				}
			}
			if(parent == nil && rootnode != nil)
				parent = rootnode;
			if(parent == nil)
				continue;
			n.parent = parent;
			parent.children = appendchild(parent.children, n);
			stack = (depth, n) :: stack;
		}
	}
	if(rootnode == nil)
		return (nil, 0, "empty file");
	return (rootnode, allpositioned, nil);
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
