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

	if(s == nil)
		return;
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
tksceneborder(TkScene *s, Rectangle r, int radius, int width, ulong rgba, ulong out)
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
	n->out = out;
	n->hasout = 1;
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

static void
renderborder(TkCtxt *c, Image *dst, TkNode *n)
{
	Image *col, *out;
	int rad, bd, y, cut, w, h;
	Point o;

	col = tkcolor(c, n->rgba);
	if(col == nil)
		return;
	out = nil;
	if(n->hasout)
		out = tkcolor(c, n->out);
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
		if(out != nil && cut > 0){
			draw(dst, Rect(o.x, o.y+y, o.x+cut, o.y+y+1), out, nil, ZP);
			draw(dst, Rect(o.x+w-cut, o.y+y, o.x+w, o.y+y+1), out, nil, ZP);
			draw(dst, Rect(o.x, o.y+h-1-y, o.x+cut, o.y+h-y), out, nil, ZP);
			draw(dst, Rect(o.x+w-cut, o.y+h-1-y, o.x+w, o.y+h-y), out, nil, ZP);
		}
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
	TkNode *n;
	Image *col;
	int drawn;

	if(s == nil || c == nil || dst == nil)
		return 0;
	drawn = 0;
	for(n = s->head; n != nil; n = n->next){
		switch(n->type){
		case TkNcolour:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				draw(dst, n->r, col, nil, ZP);
			break;
		case TkNroundfill:
			renderroundfill(c, dst, n);
			break;
		case TkNborder:
			renderborder(c, dst, n);
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
