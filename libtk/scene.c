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
 * The box a scene's drawing lands in: the union of what its nodes mark.
 *
 * Conservative by construction, and the direction matters.  Damage that
 * is too LARGE only costs work; damage that is too SMALL drops pixels.
 * So a clip node is ignored rather than intersected - a clip can only
 * shrink what gets painted, so leaving it out can never make this too
 * small - and anything uncertain is taken wide.
 *
 * Nodes between a layer and its end draw into a SCRATCH surface, in that
 * surface's coordinates, so their rectangles mean nothing here; the
 * layer's dstr, where the scratch is blitted, is what marks the
 * destination.  Hence the depth count: inside a layer, only the nesting
 * is tracked.
 *
 * An empty rectangle means the scene marks nothing.
 */
Rectangle
tkscenebounds(TkScene *s)
{
	TkNode *n;
	Rectangle b, r;
	int any, depth;

	b = Rect(0, 0, 0, 0);
	any = 0;
	depth = 0;
	if(s == nil)
		return b;
	for(n = s->head; n != nil; n = n->next){
		if(n->type == TkNlayerend){
			if(depth > 0)
				depth--;
			continue;
		}
		if(n->type == TkNlayer){
			r = n->dstr;	/* where the scratch lands */
			depth++;
		}else if(depth > 0)
			continue;	/* scratch coordinates: not ours */
		else switch(n->type){
		default:
			continue;	/* group, clip, state: marks nothing */
		case TkNcolour:
		case TkNroundfill:
		case TkNcorners:
		case TkNborder:
		case TkNglyphs:
		case TkNtexture:
		case TkNpolyfill:
		case TkNspline:
			r = n->r;
			break;
		case TkNellipse:
		case TkNellipsefill:
			/*
			 * The one node whose r is not its box: r.min is the
			 * CENTRE and sp the two radii.  ellipse() strokes
			 * width+1 about the curve, so take it outward; a
			 * filled one has width 0 and loses nothing by it.
			 */
			r.min.x = n->r.min.x - n->sp.x - n->width - 1;
			r.min.y = n->r.min.y - n->sp.y - n->width - 1;
			r.max.x = n->r.min.x + n->sp.x + n->width + 2;
			r.max.y = n->r.min.y + n->sp.y + n->width + 2;
			break;
		}
		if(Dx(r) <= 0 || Dy(r) <= 0)
			continue;
		if(!any){
			b = r;
			any = 1;
		}else
			combinerect(&b, r);
	}
	return b;
}

/*
 * Nodes come in blocks.  A tree is built and thrown away every repaint,
 * so the allocator is the cost that would show first if each node were a
 * separate malloc.
 */
/*
 * The box a run of points occupies.  Used where a node's geometry lives
 * in pts rather than in r.
 */
static Rectangle
ptsbbox(Point *p, int np)
{
	Rectangle b;
	int i;

	b.min = p[0];
	b.max = p[0];
	for(i = 1; i < np; i++){
		if(p[i].x < b.min.x)
			b.min.x = p[i].x;
		if(p[i].y < b.min.y)
			b.min.y = p[i].y;
		if(p[i].x > b.max.x)
			b.max.x = p[i].x;
		if(p[i].y > b.max.y)
			b.max.y = p[i].y;
	}
	return b;
}

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

/*
 * A glyph node for the first n bytes of a string, which is what a
 * canvas text item draws: it holds one buffer and puts a line of it on
 * the page at a time.  The node owns its copy, as tkscenetext()'s does,
 * so the caller's buffer is not depended on.
 */
void
tkscenetextn(TkScene *s, Point p, char *text, int n, Font *f, ulong rgba)
{
	char *t;

	if(text == nil || n <= 0)
		return;
	t = malloc(n+1);
	if(t == nil)
		return;
	memmove(t, text, n);
	t[n] = '\0';
	tkscenetext(s, p, t, f, rgba);
	free(t);
}

void
tkscenetext(TkScene *s, Point p, char *text, Font *f, ulong rgba)
{
	TkNode *n;

	/*
	 * A face with no name cannot be described, so the run is dropped -
	 * and a caller that chose this arm over drawing then draws nothing
	 * at all, which is a blank line rather than a wrong one.  That is
	 * survivable only because it cannot happen here: a Font comes from
	 * buildfont(), which fails outright if it cannot strdup the name,
	 * or from mkfont(), which names it `<synthetic>' and has no caller
	 * in this tree.  Giving mkfont() one means giving this a way to
	 * tell its caller it emitted nothing.
	 */
	if(text == nil || *text == '\0' || f == nil || f->name == nil)
		return;
	if((n = newnode(s, TkNglyphs)) == nil)
		return;
	/*
	 * The box the run occupies, not just its origin.  A node has to
	 * describe its own extent, because the whole point of the tree is
	 * that it outlives the repaint that built it and can be handed to
	 * something else to draw: a backend that cannot see where a glyph
	 * run lands can neither place it nor cull it.  r.max used to equal
	 * r.min, so a walk that unioned node rectangles missed every
	 * glyph.  string() takes r.min as the upper left and the renderer
	 * still passes exactly that, so this adds information and moves no
	 * pixel.
	 */
	n->r.min = p;
	n->r.max.x = p.x + stringwidth(f, text);
	n->r.max.y = p.y + f->height;
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
tkscenespline(TkScene *s, Point *p, int np, int end0, int end1, int width,
	ulong rgba)
{
	TkNode *n;

	if(p == nil || np < 2)
		return;
	if((n = newnode(s, TkNspline)) == nil)
		return;
	n->rgba = rgba;
	n->width = width;
	/*
	 * The ends go in sp, which is two ints, and NOT in radius, which
	 * is a short.  An end style is a packed value - an arrow encodes
	 * three numbers in it - and a canvas line's arrow came to
	 * 25329922, which a short makes -32510.  The checkbutton tick that
	 * was the only caller asks for Enddisc, which fits, so nothing
	 * showed it until a line did: 36624 bytes.
	 *
	 * Two of them rather than one, because bezspline() takes two and
	 * a canvas line can have an arrow at one end only.
	 */
	n->sp.x = end0;
	n->sp.y = end1;
	n->pts = malloc(np*sizeof(Point));
	if(n->pts == nil){
		n->type = TkNgroup;
		return;
	}
	memmove(n->pts, p, np*sizeof(Point));
	n->npts = np;
	/*
	 * A B-spline stays inside the convex hull of its control points,
	 * so the hull's box bounds the curve; the ends do not, because an
	 * arrowhead sticks out past the last point.  memlinebbox() is the
	 * tree's own answer to exactly that question - it insets by the
	 * radius plus the larger of the two end sizes - so the bound is
	 * the union of it over consecutive control points rather than
	 * arrow arithmetic rewritten here.  Declared locally: no libtk
	 * source includes memdraw.h, and every link that has libtk has
	 * libmemdraw.
	 */
	{
		extern Rectangle memlinebbox(Point, Point, int, int, int);
		Rectangle b;
		int i;

		b = memlinebbox(n->pts[0], n->pts[1], end0,
			np == 2 ? end1 : 0, width);
		for(i = 1; i < np-1; i++)
			combinerect(&b, memlinebbox(n->pts[i], n->pts[i+1],
				0, i == np-2 ? end1 : 0, width));
		n->r = b;
	}
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
 * first.
 *
 * The grid clipping in windw.c used to flush too - twice, once each
 * side - because its replclipr() would have been put back by the time
 * the nodes were rendered.  It carries a TkNclip instead now, which is
 * what a clip being a property of a SPAN rather than of a repaint
 * means, and the run runs straight through a grid.
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
enum {
	Maxclip = 8,	/* a text in a grid in a text ... */
};

typedef struct Walk Walk;
struct Walk {
	TkScene*	scene;
	TkCtxt*		ctxt;
	Image*		dst;
	/*
	 * The clip belongs to the WALK, not to the tree.
	 *
	 * A tree is rendered and FREED when the walk flushes, so a clip
	 * emitted into one is gone the moment anything inside the span it
	 * covers paints into the window - a text widget's embedded window,
	 * a menu's separator - while the span itself is still open.  The
	 * walk remembers what is open, re-emits it into whatever tree comes
	 * next, and closes it in that one.  Nobody holding a TkScene* could
	 * do that, and holding one across a flush is a use-after-free: a
	 * menu with a separator in it faulted on a pointer built out of its
	 * own item text.
	 *
	 * Innermost last, each already intersected with the one outside it,
	 * so what is emitted is always a single rectangle - which is what
	 * the renderer supports, and it is enough, since a clip that nests
	 * is just a smaller clip.
	 *
	 * NOTHING NESTS TODAY: a widget closes its clip before it returns,
	 * and a descent into another window gets a Walk of its own.  The
	 * stack is kept rather than reduced to one rectangle so that a
	 * caller which does nest is right rather than silently wrong, but
	 * it is unexercised, and `lost' - the overflow arm - is reachable
	 * only past eight of them.
	 */
	Rectangle	clip[Maxclip];
	int		nclip;
	int		lost;		/* opens past Maxclip, to keep the balance */
	int		clipon;		/* this tree has one open */
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
	Rectangle bounds;	/* union of what those trees marked */
	int	anybounds;	/* whether bounds means anything yet */
	int	drawnodes;	/* nodes that mark pixels */
	int	undesc;		/* ...of those, how many describe no extent */
	int	drew[TKwidgets];	/* times each type's draw ran */
	int	joined[TKwidgets];	/* ...of those, times it joined a tree */
} walk;

/*
 * Does this node type mark pixels, and does its r mean its box?
 *
 * Both halves matter.  A group or a clip marks nothing, so an empty r is
 * right for it.  An ellipse marks pixels but its r.min is the CENTRE and
 * sp the radii - documented in tk.h, and the one node whose r is not a
 * box - so it is excluded here rather than counted as undescribed.
 */
static int
nodehasbox(int type)
{
	switch(type){
	case TkNcolour:
	case TkNroundfill:
	case TkNcorners:
	case TkNborder:
	case TkNglyphs:
	case TkNtexture:
	case TkNpolyfill:
	case TkNspline:
		return 1;
	}
	return 0;
}

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
	w->nclip = 0;
	w->lost = 0;
	w->clipon = 0;
}

/*
 * Make this tree's open clip say what the walk says.  Called wherever
 * either could have changed: a clip opened or closed, or a fresh tree
 * begun after a flush.
 */
static void
clipsync(Walk *w)
{
	if(w->scene == nil)
		return;
	if(w->clipon){
		tksceneclipend(w->scene);
		w->clipon = 0;
	}
	if(w->nclip > 0){
		tksceneclip(w->scene, w->clip[w->nclip-1]);
		w->clipon = 1;
	}
}

/*
 * Narrow the clip for everything drawn until the matching
 * tkwalkclipend(), across flushes and whatever trees they leave behind.
 * In window coordinates.
 */
void
tkwalkclip(Rectangle r)
{
	Walk *w;

	if(walk.depth == 0)
		return;
	w = &walk.s[walk.depth-1];
	if(w->nclip >= Maxclip){
		w->lost++;	/* so the close below still balances */
		return;
	}
	if(w->nclip > 0 && !rectclip(&r, w->clip[w->nclip-1]))
		r.max = r.min;
	w->clip[w->nclip++] = r;
	/*
	 * tkwalkscene() emits the clip itself when it has to make the
	 * tree, so only sync when it did not - otherwise every open costs
	 * a clipend and a second clip that say nothing.
	 */
	if(tkwalkscene(w->ctxt, w->dst) != nil && !w->clipon)
		clipsync(w);
}

void
tkwalkclipend(void)
{
	Walk *w;

	if(walk.depth == 0)
		return;
	w = &walk.s[walk.depth-1];
	if(w->lost > 0){
		w->lost--;
		return;
	}
	if(w->nclip == 0)
		return;
	w->nclip--;
	clipsync(w);
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
	w->clipon = 0;			/* the tree holding it is going */
	walk.nodes += s->n;
	/*
	 * Two extra walks of the node list per tree, on the path every
	 * repaint takes, for figures nothing in this tree consumes yet.
	 * That deserved a number rather than an argument.  tkbench -n,
	 * interleaved because the rig drifts: the node path's per-widget
	 * slope moved a few tenths of a percent, and the DIRECT path -
	 * which none of this can touch - moved by the same amount over the
	 * same runs, so the shift is drift and not this.  A compare per
	 * node against a render that draws per node is the expected
	 * answer; it is recorded here because the question is obvious, and
	 * because the alternative was a flag to make it opt-in, which
	 * would cost more in complexity than this costs in time.
	 */
	{	/* before the tree is freed */
		Rectangle b;
		TkNode *n;

		for(n = s->head; n != nil; n = n->next)
			if(nodehasbox(n->type)){
				walk.drawnodes++;
				if(Dx(n->r) <= 0 || Dy(n->r) <= 0)
					walk.undesc++;
			}
		b = tkscenebounds(s);
		if(Dx(b) > 0 && Dy(b) > 0){
			if(!walk.anybounds){
				walk.bounds = b;
				walk.anybounds = 1;
			}else
				combinerect(&walk.bounds, b);
		}
	}
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
			if(w->scene == nil){
				w->scene = tkscenenew();
				w->clipon = 0;
			}
			if(w->scene != nil){
				/*
				 * A tree begun after a flush starts inside
				 * whatever clip is still open, which is the
				 * whole point of the walk owning it.
				 */
				if(!w->clipon && w->nclip > 0)
					clipsync(w);
				walk.widgets++;
			}
			return w->scene;
		}
	}
	return tkscenenew();
}

/*
 * Is the walk open for this target?
 *
 * A widget asks before deciding to describe itself as nodes, so that
 * the decision and the emission cannot disagree - tkwalkjoin() makes a
 * standalone tree when the walk is not open for the target, which a
 * widget that emits piecemeal has nowhere to render.
 */
int
tkwalkhas(TkCtxt *c, Image *dst)
{
	Walk *w;

	if(walk.depth == 0)
		return 0;
	w = &walk.s[walk.depth-1];
	return w->ctxt == c && w->dst == dst;
}

/*
 * The walk's current tree, for a widget that emits in more than one
 * place and must not hold the pointer between them.  Nil if the walk is
 * not open for this target.  Counts nothing: tkwalkjoin() is what says
 * a widget joined, and is called once.
 */
TkScene*
tkwalkscene(TkCtxt *c, Image *dst)
{
	Walk *w;

	if(!tkwalkhas(c, dst))
		return nil;
	w = &walk.s[walk.depth-1];
	if(w->scene == nil){
		w->scene = tkscenenew();
		w->clipon = 0;
	}
	if(w->scene != nil && !w->clipon && w->nclip > 0)
		clipsync(w);
	return w->scene;
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

/*
 * The union of what the trees counted above marked, in the destination's
 * coordinates.  Answers 0 and an empty rectangle if they marked nothing.
 */
/*
 * How many nodes that mark pixels described the box they mark, and how
 * many did not.  A node that cannot say where it lands is one a backend
 * can neither place nor cull, which is the whole contract the tree is
 * for, so the second number should be zero.
 */
void
tkwalknodebox(int *drawn, int *undesc)
{
	if(drawn != nil)
		*drawn = walk.drawnodes;
	if(undesc != nil)
		*undesc = walk.undesc;
}

int
tkwalkbounds(Rectangle *r)
{
	if(r != nil){
		if(walk.anybounds)
			*r = walk.bounds;
		else
			*r = Rect(0, 0, 0, 0);
	}
	return walk.anybounds;
}

/*
 * Per widget TYPE, how many times its draw method ran and how many of
 * those joined a tree.  This answers item 1.1 of
 * doc/scene-graph-plan.ms: a retained tree is only possible over a
 * subtree no DIRECT painter enters, so what is wanted is not a ratio
 * but the list of types that paint without joining.
 *
 * A RATIO WOULD BE THE WRONG SHAPE.  "n% of widgets are node-capable"
 * averages over a population whose members behave differently, which is
 * the error doc/raspi3b-draw-plan.ms made three times over bytes per
 * line.  The table is the output.
 *
 * TWO THINGS IT CANNOT TELL YOU, so read it as a candidate list:
 *
 *	A type with drew > 0 and joined == 0 either paints DIRECTLY or
 *	paints nothing at all.  An empty frame is indistinguishable here
 *	from a separator drawing its own line; only reading the widget
 *	separates them.
 *
 *	A parent whose own draw method draws sub-widgets -- menus.c and
 *	textw.c both do -- is credited with their joins, because the
 *	attribution brackets one draw call and cannot see inside it.  So
 *	joined > 0 does not prove the type itself emits.
 */
void
tkwalknote(int type, int joined)
{
	if(type < 0 || type >= TKwidgets)
		return;
	walk.drew[type]++;
	if(joined)
		walk.joined[type]++;
}

void
tkwalktypes(int type, int *drew, int *joined)
{
	if(type < 0 || type >= TKwidgets)
		return;
	if(drew != nil)
		*drew = walk.drew[type];
	if(joined != nil)
		*joined = walk.joined[type];
}

void
tkwalkreset(void)
{
	int i;

	for(i = 0; i < TKwidgets; i++){
		walk.drew[i] = 0;
		walk.joined[i] = 0;
	}
	walk.runs = 0;
	walk.widgets = 0;
	walk.nodes = 0;
	walk.anybounds = 0;
	walk.bounds = Rect(0, 0, 0, 0);
	walk.drawnodes = 0;
	walk.undesc = 0;
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
	n->r = ptsbbox(n->pts, np);	/* fillpoly stays inside the points */
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

/*
 * Narrow the clipping rectangle for the nodes up to the matching
 * tksceneclipend().  Bracketed rather than carried on each node,
 * because a clip is a property of a SPAN - the text widget sets one
 * around every line it draws and puts the window's own back afterwards
 * - and because a glyph run cannot be clipped by trimming a rectangle:
 * the clip has to reach the raster.
 *
 * In WINDOW coordinates, which is what replclipr() wants and what the
 * widget already computed.  A clip OPENED inside a layer would be in
 * the wrong coordinates - the target is a scratch - so the renderer
 * refuses that, as it refuses a nested clip.
 *
 * A layer inside a clip is the ordinary case and needs nothing: the
 * nodes go into the scratch unclipped, and the composite is drawn into
 * the window, which is where the narrowed clipping rectangle is.  So
 * the clip reaches a layered child through the blit rather than
 * through the drawing, which is exactly how the direct path works -
 * every widget that asks tkitmp() for a scratch is clipped the same
 * way.  Measured rather than assumed: the pane's grid holds a scale,
 * which takes a layer and is three times wider than the frame it is
 * gridded into, and a clip node that does not narrow lets it out to
 * (622,1834) from a frame that ends at 474.
 */
void
tksceneclip(TkScene *s, Rectangle r)
{
	TkNode *n;

	if((n = newnode(s, TkNclip)) == nil)
		return;
	n->r = r;
}

void
tksceneclipend(TkScene *s)
{
	newnode(s, TkNclipend);
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
	Image *col, *target, *saved, *t, *img, *clipped;
	Rectangle oclipr, clipr;
	Font *fnt;
	int drawn;

	if(s == nil || c == nil || dst == nil)
		return 0;
	drawn = 0;
	target = dst;
	saved = nil;
	open = nil;
	clipped = nil;
	oclipr = dst->clipr;
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
		case TkNclip:
			if(saved != nil || clipped)
				continue;	/* not inside a layer, and no nesting */
			oclipr = target->clipr;
			clipr = n->r;
			if(!rectclip(&clipr, oclipr))
				clipr.max = clipr.min;
			replclipr(target, target->repl, clipr);
			clipped = target;
			drawn++;
			continue;
		case TkNclipend:
			if(clipped == nil)
				continue;
			replclipr(clipped, clipped->repl, oclipr);
			clipped = nil;
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
				bezspline(target, n->pts, n->npts, n->sp.x,
					n->sp.y, n->width, col, ZP);
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
	/*
	 * A tree that ends inside its clip leaves the window narrowed for
	 * whatever draws next, which would be a fault nothing in the
	 * picture points at.  Put it back.
	 */
	if(clipped != nil)
		replclipr(clipped, clipped->repl, oclipr);
	return drawn;
}
