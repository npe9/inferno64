implement Commonancestor;

# TempleOS Demo/Graphics/CommonAncestor.HC — a binary search tree, drawn.
#
#	TreeNew: for (i=0;i<N;i++) { tmpn->n=RandU16%N;
#	           if (i==N-1) n1=tmpn->n; else if (i==N-2) n2=tmpn->n;
#	           TreeAdd(&root,tmpn); Sleep(50); }
#	TreeCommonAncestorFind(root):
#	  if (root && root->n!=n1 && root->n!=n2) {
#	    common_ancestor=root->n;
#	    if (n1<root->n && n2<root->n) ...left
#	    else if (n1>root->n && n2>root->n) ...right
#	  }
#
# Thirty-two random keys inserted one every fifty milliseconds so the tree
# grows while you watch, duplicates dropped.  The last two inserted are
# the pair whose common ancestor is wanted, marked red; the ancestor is
# green, or yellow if it is one of the pair.
#
# The search is four lines and needs no parent pointers and no second
# pass: descend from the root, and the first node the two keys fall on
# opposite sides of — or that is one of them — is their lowest common
# ancestor, because a search tree has already sorted them.
#
# ShowTree is an in-order walk that hands an x cursor down the recursion,
# so each node lands one column right of everything in its left subtree.
# That is why the drawing never overlaps and needs no width calculation.
#
# The original closes with a warning that TempleOS stacks do not grow, so
# recursion is dangerous there.  Here it is not, but the walk is written
# the same way.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;

Commonancestor: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

N: con 32;
X_SPACING: con 16;
Y_SPACING: con 45;
ARROW_SPACING: con 3;
FH: con 8;

Node: adt {
	left, right: cyclic ref Node;
	n: int;
};

win: ref Window;
font: ref Font;
white, black, blue, red, green, yellow: ref Image;
root: ref Node;
n1, n2, ancestor: int;
inserted := 0;
treex: int;
scrollx := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS CommonAncestor", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	red = d.color(grpal->value(Grpalette->RED));
	green = d.color(grpal->value(Grpalette->GREEN));
	yellow = d.color(grpal->value(Grpalette->YELLOW));

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 50);		# the original's Sleep(50) per insert
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case k {
		Keyboard->Left =>	scrollx -= 32;
		Keyboard->Right =>	scrollx += 32;
		* =>			exit;
		}
		redraw();
	<-ticks =>
		if(inserted < N){
			add(rn(N));
			inserted++;
			if(inserted == N-1)
				n1 = lastadded;
			else if(inserted == N)
				n2 = lastadded;
			if(inserted == N)
				findancestor();
			redraw();
		}
	}
}

lastadded: int;

add(v: int)
{
	lastadded = v;
	root = insert(root, v);
}

# TreeAdd: duplicates are dropped
insert(t: ref Node, v: int): ref Node
{
	if(t == nil)
		return ref Node(nil, nil, v);
	if(v == t.n)
		return t;
	if(v < t.n)
		t.left = insert(t.left, v);
	else
		t.right = insert(t.right, v);
	return t;
}

# TreeCommonAncestorFind, verbatim: descend while both keys are on the
# same side; stop at the first node they part at, or that is one of them.
findancestor()
{
	t := root;
	ancestor = 0;
	while(t != nil && t.n != n1 && t.n != n2){
		ancestor = t.n;
		if(n1 < t.n && n2 < t.n)
			t = t.left;
		else if(n1 > t.n && n2 > t.n)
			t = t.right;
		else
			break;
	}
	if(t != nil && (t.n == n1 || t.n == n2))
		ancestor = t.n;
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	img.text(o, black, Point(0, 0), font,
		"left/right scroll; any other key exits");
	treex = 0;
	show(img, o, root, 20);
	if(inserted >= N)
		img.text(Point(o.x, img.r.max.y - font.height), black, Point(0, 0),
			font, sys->sprint("n1=%d n2=%d, common ancestor %d",
				n1, n2, ancestor));
	img.flush(Draw->Flushnow);
}

# ShowTree: an in-order walk carrying one x cursor down the recursion, so
# a node sits one column right of its whole left subtree.
show(img: ref Image, o: Point, t: ref Node, y: int): int
{
	if(t == nil)
		return 0;
	nodex := 0;
	if(t.left != nil){
		cx := show(img, o, t.left, y + Y_SPACING);
		arrow(img, o, treex, y, cx + ARROW_SPACING, y + Y_SPACING - ARROW_SPACING);
	}
	col := blue;
	if(t.n == n1 || t.n == n2){
		col = red;
		if(t.n == ancestor)
			col = yellow;
	}else if(t.n == ancestor && inserted >= N)
		col = green;
	nodex = treex;
	img.text(Point(o.x + nodex - scrollx, o.y + y), col, Point(0, 0), font,
		sys->sprint("%d", t.n));
	treex += X_SPACING;
	if(t.right != nil){
		cx := show(img, o, t.right, y + Y_SPACING);
		arrow(img, o, nodex, y, cx - ARROW_SPACING, y + Y_SPACING - ARROW_SPACING);
	}
	return nodex;
}

arrow(img: ref Image, o: Point, x1, y1, x2, y2: int)
{
	img.line(Point(o.x+x1-scrollx, o.y+y1+FH), Point(o.x+x2-scrollx, o.y+y2),
		Draw->Endsquare, Draw->Endarrow, 0, blue, Point(0, 0));
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
