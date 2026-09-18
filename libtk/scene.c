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
		if(n->fontname != nil)
			free(n->fontname);
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
 * A run of text at a point, in a NAMED font.
 *
 * The node used to carry the Font* itself, which was the one place a
 * node held a display-side resource rather than a value, and it is the
 * reason a tree could not outlive the call that built it: a Font
 * belongs to a display and can be closed under a tree that points at
 * it.  A name is a value.  The renderer resolves it with font_open(),
 * which is how the toolkit opens every font it uses anyway - including
 * "*default*", which libtk asks for by that name in utils.c.
 *
 * What this does NOT yet do is lay the run out into positioned glyphs.
 * That is the other half of the same job, and it is what a backend
 * needs, since it cannot call string() at all; but it changes what the
 * pixels are made of, so it is a step of its own and this one is not
 * pretending to have taken it.
 *
 * The string is copied for the same reason the name is.
 */
/*
 * An image, named by the file it came from.  mask says whether it is
 * painted THROUGH - a one-bit icon in the foreground colour, which is
 * how the chrome's artwork is drawn - or drawn as it stands.
 */
void
tkscenetexture(TkScene *s, Rectangle r, char *path, int mask, ulong rgba)
{
	TkNode *n;

	if(path == nil || *path == '\0' || Dx(r) <= 0 || Dy(r) <= 0)
		return;
	if((n = newnode(s, TkNtexture)) == nil)
		return;
	n->r = r;
	n->rgba = rgba;
	n->width = mask != 0;
	n->fontname = strdup(path);
	if(n->fontname == nil)
		n->type = TkNgroup;	/* a node that draws nothing */
}

void
tkscenetext(TkScene *s, Point p, char *text, Font *f, ulong rgba)
{
	TkNode *n;

	if(text == nil || *text == '\0' || f == nil || f->name == nil)
		return;
	if((n = newnode(s, TkNglyphs)) == nil)
		return;
	n->r.min = p;
	n->r.max = p;
	n->rgba = rgba;
	n->text = strdup(text);
	n->fontname = strdup(f->name);
	if(n->text == nil || n->fontname == nil)
		n->type = TkNgroup;	/* a node that draws nothing */
}

/*
 * Name to Font, for the renderer.
 *
 * Small and never emptied: a window uses a handful of faces and each is
 * opened once for the life of the process, which is what the toolkit
 * already does with the fonts in a TkEnv.  A miss that cannot be opened
 * draws nothing, which is visible, rather than falling back to another
 * face, which would not be.
 */
/*
 * The image a texture node names, opened once and kept.  The same
 * arrangement as scenefont() below and for the same reasons: the
 * renderer must not hold a resource on a node's behalf, an image is
 * cheap to keep and expensive to reopen per repaint, and a toolkit has
 * a handful of them.  Never emptied, like the font cache.
 */
static Image*
scenetexture(TkCtxt *c, char *path)
{
	static struct {
		char*	path;
		Image*	img;
	} cache[16];
	int i;
	Image *m;

	if(path == nil || c == nil || c->display == nil)
		return nil;
	for(i = 0; i < nelem(cache); i++){
		if(cache[i].path == nil)
			break;
		if(strcmp(cache[i].path, path) == 0)
			return cache[i].img;
	}
	m = display_open(c->display, path);
	if(m == nil || i >= nelem(cache))
		return m;
	cache[i].path = strdup(path);
	if(cache[i].path == nil)
		return m;
	cache[i].img = m;
	return m;
}

static Font*
scenefont(TkCtxt *c, char *name)
{
	static struct {
		char*	name;
		Font*	font;
	} cache[16];
	int i;
	Font *f;

	if(name == nil || c == nil || c->display == nil)
		return nil;
	for(i = 0; i < nelem(cache); i++){
		if(cache[i].name == nil)
			break;
		if(strcmp(cache[i].name, name) == 0)
			return cache[i].font;
	}
	f = font_open(c->display, name);
	if(f == nil || i >= nelem(cache))
		return f;
	cache[i].name = strdup(name);
	if(cache[i].name == nil)
		return f;
	cache[i].font = f;
	return f;
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
 * Composite a layer, in its own shape: the shared blit in utils.c,
 * which the direct path also ends in.
 */
static void
blitshaped(Image *dst, TkNode *n, Image *src)
{
	tkshapedblit(dst, n->dstr, src, n->sp, n->radius);
}

/*
 * A stroked B-spline through np points, with the same end style at both
 * ends.
 *
 * A checkbutton's tick is the one of these in the flat style.  The
 * points are copied for the reason a polygon's are: a node is a value.
 */
void
tkscenespline(TkScene *s, Point *p, int np, int end, int width, ulong rgba)
{
	TkNode *n;

	if(p == nil || np < 2)
		return;
	if((n = newnode(s, TkNspline)) == nil)
		return;
	n->rgba = rgba;
	n->width = width;
	n->radius = end;
	n->pts = malloc(np*sizeof(Point));
	if(n->pts == nil){
		n->type = TkNgroup;
		return;
	}
	memmove(n->pts, p, np*sizeof(Point));
	n->npts = np;
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
	int	nodes;		/* nodes in them: what sizes a submission */
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
	walk.nodes += s->n;
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
 * How many trees the last repaint rendered, how many widgets went into
 * them, and how many nodes those held - the last being what sizes a
 * submission, since a backend that submits per tree pays for the
 * submission whatever the tree holds.  Only tkofftest(1) reads these: a walk that batches
 * nothing and a walk that batches everything draw the same pixels, so
 * the identity check cannot tell them apart and something else has to.
 */
void
tkwalkcount(int *runs, int *widgets, int *nodes)
{
	if(runs != nil)
		*runs = walk.runs;
	if(widgets != nil)
		*widgets = walk.widgets;
	if(nodes != nil)
		*nodes = walk.nodes;
}

void
tkwalkreset(void)
{
	walk.runs = 0;
	walk.widgets = 0;
	walk.nodes = 0;
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
	tkscenelayerround(s, size, fill, dstr, sp, 0);
}

/*
 * A layer with ROUNDED CORNERS: the composite takes the shape, so the
 * four corners of the destination are left as they were.
 *
 * This is what a widget with a rounded border actually is, and the
 * reason it is on the composite rather than on the fill.  A fill of the
 * right shape is not enough: a listbox draws a selection band the full
 * width of itself, and an entry its selection, AFTER the fill - so with
 * a shaped fill and a square composite the corner shows the band.  That
 * was 12 pixels, and it is what sent the first attempt at this back.
 *
 * The alternative, which is what the direct path does and what
 * TkNcorners described, is to paint the corners back with the parent's
 * colour once the widget is drawn.  That works and is a mend: it needs
 * to know what is behind a widget in order to draw the widget.  Shaping
 * the composite needs to know nothing, which is the difference between
 * describing a frame and reproducing one.
 */
void
tkscenelayerround(TkScene *s, Point size, ulong fill, Rectangle dstr, Point sp,
	int radius)
{
	TkNode *n;

	if((n = newnode(s, TkNlayer)) == nil)
		return;
	n->r.min = ZP;
	n->r.max = size;
	n->rgba = fill;
	n->dstr = dstr;
	n->sp = sp;
	n->radius = radius;
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
/*
 * Where the curve is, at one row of a corner, and the radius a
 * rectangle can actually carry.  Not static: the shaped blit in utils.c
 * is the other half of the same shape and must not have its own copy of
 * this arithmetic.
 */
int
tkinset(int radius, int y)
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

int
tkclamprad(Rectangle r, int radius)
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
	rad = tkclamprad(n->r, n->radius);
	w = Dx(n->r);
	h = Dy(n->r);
	if(rad <= 0){
		draw(dst, n->r, col, nil, ZP);
		return;
	}
	draw(dst, Rect(n->r.min.x, n->r.min.y+rad, n->r.max.x, n->r.max.y-rad),
		col, nil, ZP);
	for(y = 0; y < rad; y++){
		cut = tkinset(rad, y);
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
	rad = tkclamprad(n->r, n->radius);
	for(y = 0; y < rad; y++){
		cut = tkinset(rad, y);
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
	int rad, bd, y, cut, w, h, in0, in1, l0, r0;
	Point o;

	col = tkcolor(c, n->rgba);
	if(col == nil)
		return;
	o = n->r.min;
	w = Dx(n->r);
	h = Dy(n->r);
	bd = n->width;
	rad = tkclamprad(n->r, n->radius);

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
		/* clamped to the shape, as tkroundbox() is: see there */
		cut = tkinset(rad, y);
		in0 = o.x+cut;
		in1 = o.x+w-cut;
		if(in1 < in0)
			in1 = in0;
		l0 = in0+bd;
		if(l0 > in1)
			l0 = in1;
		r0 = in1-bd;
		if(r0 < in0)
			r0 = in0;
		draw(dst, Rect(in0, o.y+y, l0, o.y+y+1), col, nil, ZP);
		draw(dst, Rect(r0, o.y+y, in1, o.y+y+1), col, nil, ZP);
		draw(dst, Rect(in0, o.y+h-1-y, l0, o.y+h-y), col, nil, ZP);
		draw(dst, Rect(r0, o.y+h-1-y, in1, o.y+h-y), col, nil, ZP);
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
	Image *col, *target, *saved, *t, *img;
	Font *fnt;
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
			blitshaped(saved, open, target);
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
			fnt = scenefont(c, n->fontname);
			if(col != nil && fnt != nil)
				string(target, n->r.min, col, ZP, fnt, n->text);
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
		case TkNtexture:
			img = scenetexture(c, n->fontname);
			if(img == nil)
				break;
			/*
			 * ZP for the source point, not img->r.min, because
			 * ZP is what the widget passed and the two have to
			 * be the same call.  A colour image showed the
			 * difference at once - 604800 bytes - where every
			 * mask under /icons/tk had hidden it by starting at
			 * the origin.
			 */
			if(n->width){
				col = tkcolor(c, n->rgba);
				if(col != nil)
					draw(target, n->r, col, img, ZP);
			}else
				draw(target, n->r, img, nil, ZP);
			break;
		case TkNpolyfill:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				fillpoly(target, n->pts, n->npts, ~0, col,
					n->pts[0]);
			break;
		case TkNspline:
			col = tkcolor(c, n->rgba);
			if(col != nil)
				bezspline(target, n->pts, n->npts, n->radius,
					n->radius, n->width, col, ZP);
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
