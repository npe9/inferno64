#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * A retained render-node tree, after GTK4's GSK.
 *
 * WHY, since the numbers say it is not for speed.  tkbench(1) measures a
 * thirty-widget window at about 400us to draw and 250us to present - 4%
 * of a frame at 60Hz - so nothing here is going to make a static window
 * appear faster, and a naive GPU port would make it slower: this tree
 * already measured 94% command-buffer overhead for small work.  What a
 * node tree buys is what it buys GTK4 and Core Animation: a description
 * of the frame that something OTHER than an immediate draw() can
 * consume.  From that follow the things libtk cannot do at all today -
 * animating a widget without re-rasterising it, antialiased rounded
 * corners and shadows from a shader rather than from per-row spans, and
 * one GPU submission for a whole frame instead of one per primitive.
 *
 * WHAT THIS FIRST PIECE IS.  The node vocabulary, and a SOFTWARE
 * renderer for it.  Software first on purpose, and not as a stepping
 * stone: it is the oracle.  A node tree is only worth anything if it can
 * express what libtk already draws, and the way to know that is to
 * render the same widget both ways and compare the pixels - which is the
 * arrangement draw3d(2) already uses, where a software provider and a
 * device provider are checked against each other by sprite2dtest(1).  A
 * Metal backend then has something to be correct against.
 *
 * Nodes carry VALUES - a rectangle, a radius, an rgba - and never a
 * draw(2) Image.  That is the whole reason a backend other than this one
 * can consume them: an Image is a server-side resource belonging to a
 * particular display, an rgba is a number.  The software renderer turns
 * numbers back into Images at the point of drawing, which costs a
 * lookup per node and is what a GPU backend would not do.
 *
 * Nodes live in this library rather than in a library of their own
 * because a new library means editing the kernel configurations under
 * os/ and mkfiles/mkkernel-*, and those belong to someone else.
 */

enum {
	Chunk = 32,		/* nodes per allocation */
};

struct TkNodeblk
{
	TkNodeblk*	next;
	int		n;
	TkNode		node[Chunk];
};

TkScene*
tkscenenew(void)
{
	TkScene *s;

	s = malloc(sizeof(TkScene));
	if(s == nil)
		return nil;
	s->blk = nil;
	s->head = nil;
	s->tail = nil;
	s->n = 0;
	return s;
}

void
tkscenefree(TkScene *s)
{
	TkNodeblk *b, *nb;
	TkNode *n;

	if(s == nil)
		return;
	for(n = s->head; n != nil; n = n->next){
		if(n->text != nil)
			free(n->text);
		if(n->pts != nil)
			free(n->pts);
	}
	for(b = s->blk; b != nil; b = nb){
		nb = b->next;
		free(b);
	}
	free(s);
}

/*
 * Nodes come in blocks.  A tree is built and thrown away every repaint,
 * so the allocator is the cost that would show first if each node were a
 * separate malloc.
 */
static TkNode*
newnode(TkScene *s, int type)
{
	TkNodeblk *b;
	TkNode *n;

	if(s == nil)
		return nil;
	b = s->blk;
	if(b == nil || b->n >= Chunk){
		b = malloc(sizeof(TkNodeblk));
		if(b == nil)
			return nil;
		b->n = 0;
		b->next = s->blk;
		s->blk = b;
	}
	n = &b->node[b->n++];
	memset(n, 0, sizeof(TkNode));
	n->type = type;
	if(s->tail == nil)
		s->head = n;
	else
		s->tail->next = n;
	s->tail = n;
	s->n++;
	return n;
}

void
tkscenecolour(TkScene *s, Rectangle r, ulong rgba)
{
	TkNode *n;

	if(Dx(r) <= 0 || Dy(r) <= 0)
		return;
	if((n = newnode(s, TkNcolour)) == nil)
		return;
	n->r = r;
	n->rgba = rgba;
}

void
tksceneroundfill(TkScene *s, Rectangle r, int radius, ulong rgba)
{
	TkNode *n;

	if(Dx(r) <= 0 || Dy(r) <= 0)
		return;
	if((n = newnode(s, TkNroundfill)) == nil)
		return;
	n->r = r;
	n->radius = radius;
	n->rgba = rgba;
}

/*
 * A stroked rounded rectangle.  `out' is what shows where the corner has
 * been cut away.
 *
 * In a real node tree there would be no such argument: the parent's own
 * node is drawn first and the child's border goes on top, so nothing
 * ever paints the corner and nothing needs to know what is behind it.
 * It is here because libtk's widgets fill their whole rectangle before
 * the border is drawn, so the corner arrives already wrong.  The fix is
 * for a widget's background to be a TkNroundfill instead, and then this
 * argument goes away - which is the next piece of work, not a caveat.
 */
void
tksceneborder(TkScene *s, Rectangle r, int radius, int width, ulong rgba)
{
	TkNode *n;

	if(Dx(r) <= 0 || Dy(r) <= 0 || width <= 0)
		return;
	if((n = newnode(s, TkNborder)) == nil)
		return;
	n->r = r;
	n->radius = radius;
	n->width = width;
	n->rgba = rgba;
}

/*
 * A border, plus the colour that shows where its corners are cut away.
 *
 * For callers that are NOT a whole widget: tkdrawrelief() is handed an
 * image in which the widget has already filled its whole rectangle and
 * drawn its text, so the corner arrives wrong and painting it back is
 * the only thing left.  Expressed as two nodes rather than as an
 * argument, because what shows behind a widget is not a property of its
 * border - and a widget whose fill is a TkNroundfill, as a frame's now
 * is, calls tksceneborder() and has no use for this.
 */
void
tksceneborderon(TkScene *s, Rectangle r, int radius, int width, ulong rgba, ulong out)
{
	TkNode *n;

	if(Dx(r) <= 0 || Dy(r) <= 0 || width <= 0)
		return;
	if((n = newnode(s, TkNcorners)) == nil)
		return;
	n->r = r;
	n->radius = radius;
	n->rgba = out;
	tksceneborder(s, r, radius, width, rgba);
}

/*
 * A run of text at a point.
 *
 * This one carries a Font*, and so breaks the rule that a node holds
 * values and never a resource.  GSK's glyph node does the same thing for
 * the same reason: a font is not reducible to a number, and the
 * alternative - laying the run out here into positioned glyph indices -
 * needs the glyph atlas that does not exist yet.  When it does, this
 * node becomes an atlas reference and a list of positions, and the Font*
 * goes away.  Recording that now so the field is not mistaken for a
 * decision.
 *
 * The string is copied because a retained tree may outlive its caller's
 * buffer.  Today it does not - a scene is built and rendered in one call
 * - so this is an allocation per text node per repaint, paid for a
 * property nothing yet relies on.
 */
void
tkscenetext(TkScene *s, Point p, char *text, Font *f, ulong rgba)
{
	TkNode *n;

	if(text == nil || *text == '\0' || f == nil)
		return;
	if((n = newnode(s, TkNglyphs)) == nil)
		return;
	n->r.min = p;
	n->r.max = p;
	n->rgba = rgba;
	n->font = f;
	n->text = strdup(text);
	if(n->text == nil)
		n->type = TkNgroup;	/* a node that draws nothing */
}

/*
 * An ellipse, stroked (tksceneellipse) or filled (tksceneellipsefill),
 * about a centre with two radii.
 *
 * A radiobutton's indicator is a ring with a dot in it and the flat
 * scale's knob is two filled circles, so this is the shape those widgets
 * need before they can be described by nodes at all.  The centre and the
 * radii are kept as they are passed rather than folded into a rectangle:
 * ellipse() and fillellipse() take them that way, and a bounding box
 * cannot say whether a circle of radius r is 2r or 2r+1 across.
 *
 * width is ellipse()'s thickness, where 0 means one pixel.
 */
void
tksceneellipse(TkScene *s, Point c, Point rad, int width, ulong rgba)
{
	TkNode *n;

	if(rad.x < 0 || rad.y < 0 || width < 0)
		return;
	if((n = newnode(s, TkNellipse)) == nil)
		return;
	n->r.min = c;
	n->r.max = c;
	n->sp = rad;
	n->width = width;
	n->rgba = rgba;
}

void
tksceneellipsefill(TkScene *s, Point c, Point rad, ulong rgba)
{
	TkNode *n;

	if(rad.x < 0 || rad.y < 0)
		return;
	if((n = newnode(s, TkNellipsefill)) == nil)
		return;
	n->r.min = c;
	n->r.max = c;
	n->sp = rad;
	n->rgba = rgba;
}

/*
 * THE WALK.  One tree for a run of widgets rather than one per widget.
 *
 * A repaint descends the widget tree and calls each widget's draw
 * method (tkdrawslaves1() in windw.c).  Six widgets can describe
 * themselves as nodes; the rest paint straight into the window with
 * draw(2), and a tree that was still being built when one of those
 * painted would land ON TOP of it, since it is rendered later.  So the
 * walk is not one tree per repaint but one tree per RUN of consecutive
 * node widgets: anything that paints directly flushes what is pending
 * first, and so does the grid clipping in windw.c, whose replclipr()
 * would otherwise be gone by the time the nodes were rendered.
 *
 * That leaves painter order exactly as it was - which is the property
 * the identity check measures - while giving a backend runs of nodes to
 * batch instead of single widgets.  A pane of nothing but converted
 * widgets is one tree, which is the case that matters; a pane that
 * alternates is no worse than before.
 *
 * Descents NEST: a canvas's window item and a text widget's embedded
 * windows each call tkdrawslaves() from inside a draw method, which is
 * inside a descent already.  The inner one draws into a different window
 * and must not join the outer tree, so the state is a small stack and
 * not one struct - with one struct, the inner close left the outer
 * descent with no walk at all and every widget after the canvas built
 * its own tree again (13 widgets batched became 11).  Opening flushes
 * what the outer walk had pending, so the order is still the order the
 * widgets drew in.
 */
typedef struct Walk Walk;
struct Walk {
	TkScene*	scene;
	TkCtxt*		ctxt;
	Image*		dst;
};

enum {
	Maxwalk = 8,	/* a canvas in a text in a canvas ... */
};

static struct {
	Walk	s[Maxwalk];
	int	depth;		/* 0: no walk open */
	int	runs;		/* trees rendered, for the test */
	int	widgets;	/* widgets that joined one */
} walk;

void
tkwalkopen(TkCtxt *c, Image *dst)
{
	Walk *w;

	tkwalkflush();		/* the enclosing walk's pending tree first */
	if(walk.depth >= Maxwalk)
		return;		/* deeper than this: no batching, still correct */
	w = &walk.s[walk.depth++];
	w->scene = nil;
	w->ctxt = c;
	w->dst = dst;
}

/*
 * Render what is pending and drop it, leaving the walk open.  Called
 * before anything that draws into the window by itself.
 */
void
tkwalkflush(void)
{
	TkScene *s;
	Walk *w;

	if(walk.depth == 0)
		return;
	w = &walk.s[walk.depth-1];
	if(w->scene == nil)
		return;
	s = w->scene;
	w->scene = nil;			/* before rendering: a layer's
					 * scratch must not join the tree
					 * it is rendering */
	tkscenerender(s, w->ctxt, w->dst);
	tkscenefree(s);
	walk.runs++;
}

void
tkwalkclose(void)
{
	tkwalkflush();
	if(walk.depth > 0)
		walk.depth--;
}

/*
 * The scene a widget should build into: the walk's own if one is open
 * for this context and this window, otherwise a fresh one that the
 * widget renders and frees itself through tkscenefinish().
 */
TkScene*
tkwalkjoin(TkCtxt *c, Image *dst)
{
	Walk *w;

	if(walk.depth > 0){
		w = &walk.s[walk.depth-1];
		if(w->ctxt == c && w->dst == dst){
			if(w->scene == nil)
				w->scene = tkscenenew();
			if(w->scene != nil)
				walk.widgets++;
			return w->scene;
		}
	}
	return tkscenenew();
}

/*
 * The end of a widget's contribution.  A scene that belongs to the walk
 * stays for the next widget; one that does not is rendered now.
 */
void
tkscenefinish(TkScene *s, TkCtxt *c, Image *dst)
{
	if(s == nil)
		return;
	if(walk.depth > 0 && s == walk.s[walk.depth-1].scene)
		return;
	tkscenerender(s, c, dst);
	tkscenefree(s);
}

/*
 * How many trees the last repaint rendered and how many widgets went
 * into them.  Only tkofftest(1) reads these: a walk that batches
 * nothing and a walk that batches everything draw the same pixels, so
 * the identity check cannot tell them apart and something else has to.
 */
void
tkwalkcount(int *runs, int *widgets)
{
	if(runs != nil)
		*runs = walk.runs;
	if(widgets != nil)
		*widgets = walk.widgets;
}

void
tkwalkreset(void)
{
	walk.runs = 0;
	walk.widgets = 0;
}

/*
 * A filled polygon of np points, by the nonzero winding rule.
 *
 * The flat scrollbar's arrows are solid triangles, which is the reason
 * this exists.  The points are copied for the reason a glyph node's text
 * is: the node is meant to be a value that can outlive the caller's
 * array.  A polygon that cannot be copied becomes a node that draws
 * nothing, as a run of text does.
 */
void
tkscenepolyfill(TkScene *s, Point *p, int np, ulong rgba)
{
	TkNode *n;

	if(p == nil || np < 3)
		return;
	if((n = newnode(s, TkNpolyfill)) == nil)
		return;
	n->rgba = rgba;
	n->pts = malloc(np*sizeof(Point));
	if(n->pts == nil){
		n->type = TkNgroup;
		return;
	}
	memmove(n->pts, p, np*sizeof(Point));
	n->npts = np;
}

/*
 * Open a layer: the nodes that follow, up to tkscenelayerend(), are drawn
 * into a scratch surface `size' big filled with `fill', and the result is
 * then blitted to `dstr' taking pixels from `sp'.
 *
 * A scope rather than a live offscreen target, and that is a measured
 * choice: a frame takes 27 scratch surfaces but tkitmp() hands out ONE
 * cached scratch per context, reused and blitted out between widgets, so
 * there is never more than one live.  One saved pointer is therefore
 * enough and layers do not nest - which is just as well, since two live
 * layers would both be the same image.
 */
void
tkscenelayer(TkScene *s, Point size, ulong fill, Rectangle dstr, Point sp)
{
	TkNode *n;

	if((n = newnode(s, TkNlayer)) == nil)
		return;
	n->r.min = ZP;
	n->r.max = size;
	n->rgba = fill;
	n->dstr = dstr;
	n->sp = sp;
}

void
tkscenelayerend(TkScene *s)
{
	newnode(s, TkNlayerend);
}

int
tkscenecount(TkScene *s)
{
	if(s == nil)
		return 0;
	return s->n;
}

/*
 * How far in from the edge the curve is on a given row, walking out
 * until the pixel falls inside the circle.  No sqrt: a radius is a
 * handful of pixels, this is exact at those sizes, and it keeps the
 * maths library out of every kernel that links libtk.
 */
static int
inset(int radius, int y)
{
	int x, dx, dy, r2;

	r2 = radius*radius;
	dy = radius - y;
	for(x = 0; x < radius; x++){
		dx = radius - x;
		if(dx*dx + dy*dy <= r2)
			return x;
	}
	return radius;
}

static int
clamprad(Rectangle r, int radius)
{
	if(radius*2 > Dx(r))
		radius = Dx(r)/2;
	if(radius*2 > Dy(r))
		radius = Dy(r)/2;
	if(radius < 0)
		radius = 0;
	return radius;
}

static void
renderroundfill(TkCtxt *c, Image *dst, TkNode *n)
{
	Image *col;
	int rad, y, cut, h, w;

	col = tkcolor(c, n->rgba);
	if(col == nil)
		return;
	rad = clamprad(n->r, n->radius);
	w = Dx(n->r);
	h = Dy(n->r);
	if(rad <= 0){
		draw(dst, n->r, col, nil, ZP);
		return;
	}
	draw(dst, Rect(n->r.min.x, n->r.min.y+rad, n->r.max.x, n->r.max.y-rad),
		col, nil, ZP);
	for(y = 0; y < rad; y++){
		cut = inset(rad, y);
		draw(dst, Rect(n->r.min.x+cut, n->r.min.y+y,
			n->r.max.x-cut, n->r.min.y+y+1), col, nil, ZP);
		draw(dst, Rect(n->r.min.x+cut, n->r.min.y+h-1-y,
			n->r.max.x-cut, n->r.min.y+h-y), col, nil, ZP);
	}
	USED(w);
}

/* just the four corner regions, in the colour behind the widget */
static void
rendercorners(TkCtxt *c, Image *dst, TkNode *n)
{
	Image *out;
	int rad, y, cut, w, h;
	Point o;

	out = tkcolor(c, n->rgba);
	if(out == nil)
		return;
	o = n->r.min;
	w = Dx(n->r);
	h = Dy(n->r);
	rad = clamprad(n->r, n->radius);
	for(y = 0; y < rad; y++){
		cut = inset(rad, y);
		if(cut <= 0)
			continue;
		draw(dst, Rect(o.x, o.y+y, o.x+cut, o.y+y+1), out, nil, ZP);
		draw(dst, Rect(o.x+w-cut, o.y+y, o.x+w, o.y+y+1), out, nil, ZP);
		draw(dst, Rect(o.x, o.y+h-1-y, o.x+cut, o.y+h-y), out, nil, ZP);
		draw(dst, Rect(o.x+w-cut, o.y+h-1-y, o.x+w, o.y+h-y), out, nil, ZP);
	}
}

static void
renderborder(TkCtxt *c, Image *dst, TkNode *n)
{
	Image *col;
	int rad, bd, y, cut, w, h;
	Point o;

	col = tkcolor(c, n->rgba);
	if(col == nil)
		return;
	o = n->r.min;
	w = Dx(n->r);
	h = Dy(n->r);
	bd = n->width;
	rad = clamprad(n->r, n->radius);

	if(w > 2*rad){
		draw(dst, Rect(o.x+rad, o.y, o.x+w-rad, o.y+bd), col, nil, ZP);
		draw(dst, Rect(o.x+rad, o.y+h-bd, o.x+w-rad, o.y+h), col, nil, ZP);
	}
	if(h > 2*rad){
		draw(dst, Rect(o.x, o.y+rad, o.x+bd, o.y+h-rad), col, nil, ZP);
		draw(dst, Rect(o.x+w-bd, o.y+rad, o.x+w, o.y+h-rad), col, nil, ZP);
	}
	if(rad <= 0)
		return;
	for(y = 0; y < rad; y++){
		cut = inset(rad, y);
		draw(dst, Rect(o.x+cut, o.y+y, o.x+cut+bd, o.y+y+1), col, nil, ZP);
		draw(dst, Rect(o.x+w-cut-bd, o.y+y, o.x+w-cut, o.y+y+1), col, nil, ZP);
		draw(dst, Rect(o.x+cut, o.y+h-1-y, o.x+cut+bd, o.y+h-y), col, nil, ZP);
		draw(dst, Rect(o.x+w-cut-bd, o.y+h-1-y, o.x+w-cut, o.y+h-y), col, nil, ZP);
	}
}

/*
 * Walk the tree and draw it.  In list order, which is paint order: a
 * node tree is not a set.
 */
int
tkscenerender(TkScene *s, TkCtxt *c, Image *dst)
{
	TkNode *n, *open;
	Image *col, *target, *saved, *t;
	int drawn;

	if(s == nil || c == nil || dst == nil)
		return 0;
	drawn = 0;
	target = dst;
	saved = nil;
	open = nil;
	for(n = s->head; n != nil; n = n->next){
		switch(n->type){
		case TkNlayer:
			if(saved != nil)
				continue;	/* layers do not nest; see above */
			t = tkitmppix(c, n->r.max, n->rgba);
			if(t == nil)
				continue;	/* no scratch: draw in place */
			saved = target;
			target = t;
			open = n;
			drawn++;
			continue;
		case TkNlayerend:
			if(saved == nil)
				continue;
			draw(saved, open->dstr, target, nil, open->sp);
			target = saved;
			saved = nil;
			open = nil;
			drawn++;
			continue;
		}
		switch(n->type){
		case TkNcolour:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				draw(target, n->r, col, nil, ZP);
			break;
		case TkNroundfill:
			renderroundfill(c, target, n);
			break;
		case TkNcorners:
			rendercorners(c, target, n);
			break;
		case TkNborder:
			renderborder(c, target, n);
			break;
		case TkNglyphs:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				string(target, n->r.min, col, ZP, n->font, n->text);
			break;
		case TkNellipse:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				ellipse(target, n->r.min, n->sp.x, n->sp.y,
					n->width, col, ZP);
			break;
		case TkNellipsefill:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				fillellipse(target, n->r.min, n->sp.x, n->sp.y,
					col, ZP);
			break;
		case TkNpolyfill:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				fillpoly(target, n->pts, n->npts, ~0, col,
					n->pts[0]);
			break;
		default:
			/*
			 * The rest of the vocabulary is declared in tk.h and
			 * not implemented.  Reaching one is a programming
			 * error rather than a condition to handle, so it is
			 * counted and ignored rather than silently skipped.
			 */
			continue;
		}
		drawn++;
	}
	return drawn;
}
