#include "lib9.h"
#include "draw.h"
#include "tk.h"

struct TkCol
{
	ulong	rgba1;
	ulong	rgba3;	/* if mixed, otherwise DNotacolor */
	Image*	i;
	TkCol*	forw;
};

extern void	rptwakeup(void*, void*);
extern void*	rptproc(char*, int, void*, int (*)(void*), int (*)(void*,int), void (*)(void*));

typedef struct Cmd Cmd;
struct Cmd
{
	char*	name;
	char*	(*fn)(TkTop*, char*, char**);
};
static struct Cmd cmdmain[] =
{
	"bind",		tkbind,
	"button",	tkbutton,
	"canvas",	tkcanvas,
	"checkbutton",	tkcheckbutton,
	"choicebutton", tkchoicebutton,
	"cursor",	tkcursorcmd,
	"destroy",	tkdestroy,
	"entry",	tkentry,
	"focus",	tkfocus,
	"frame",	tkframe,
	"grab",		tkgrab,
	"grid",	tkgrid,
	"image",	tkimage,
	"label",	tklabel,
	"listbox",	tklistbox,
	"lower",	tklower,
	"menu",		tkmenu,
	"menubutton",	tkmenubutton,
	"pack",		tkpack,
	"panel",		tkpanel,
	"puts",		tkputs,
	"radiobutton",	tkradiobutton,
	"raise",	tkraise,
	"render",	tkrendercmd,
	"scale",	tkscale,
	"scrollbar",	tkscrollbar,
	"see",	tkseecmd,
	"send",		tksend,
	"style",	tkstylecmd,
	"text",		tktext,
	"update",	tkupdatecmd,
	"variable",	tkvariable,
	"winfo",	tkwinfo,
};

/*
 * The two spacing rows.  Classic is what was compiled in before the
 * register existed - label.h's Textpadx 3 / Textpady 0, Bitpad 0,
 * entry.c's Entrypad 0, textw.c's own Textpadx 2 / Textpady 0 - so a
 * classic toplevel measures every widget exactly as it always did, and
 * that is worth keeping true: these numbers reach every size computation
 * in the toolkit, and a change of one pixel here moves every layout in
 * every program.
 *
 * The flat row is roomier, and deliberately makes the two that used to
 * disagree agree.  A label and a text widget packed together now inset
 * their contents by the same amount, which is the thing the scattered
 * constants made impossible to arrange.
 */
TkSpace	tkspaces[] =
{
	/* labelpadx, labelpady, bitpadx, bitpady, entrypadx, entrypady, textpadx, textpady, scaleborder, corner */
	{ 14, 7, 5, 5, 8, 6, 7, 5, 1, 5 },	/* TkSflat - the default */
	{ 3, 0, 0, 0, 0, 0, 2, 0, 0, 0 },	/* TkSclassic */
};

/*
 * The default border width a widget asks for, given the one it would
 * have asked for before styles existed.
 *
 * The chrome's artwork already scales with the font, but the borders did
 * not, so a one-pixel line that reads as an edge at the tree's own font
 * is a hairline beside a 32-pixel one.  The classic style keeps the
 * literal number - every existing layout depends on it, since a border
 * is part of what a widget measures - and only a style that has opted
 * in gets a line that grows.  16 is the height the unscaled numbers were
 * chosen against, so a font that size still gets exactly them.
 */
/*
 * Is this widget's toplevel in the flat style?  Shared because scale(9)
 * and scrollbar(9) draw their own chrome instead of going through
 * tkdrawrelief(), so they each have to ask.
 */
/*
 * Which drawing path a flat border takes: straight to draw() as it has
 * done, or through a render-node tree.  Both must put down the same
 * pixels, and a switch is the only way to check that - the same
 * arrangement draw3d(2) uses, where a software provider and a device
 * provider are compared against each other rather than each being
 * trusted on its own.
 */
int tkviascene;

/*
 * The environment of whatever is visually BEHIND this widget, which is
 * what a rounded corner has to show.
 *
 * tk->master, not tk->parent.  `master' is the pack owner; `parent' is
 * set only for a window inside a canvas or a text widget, so for an
 * ordinary packed widget it is nil - and reading it gave the widget its
 * OWN background as the colour behind itself.  Invisible for as long as
 * every widget was the same colour as its container, which it was until
 * the flat style gave fields a surface of their own, and then a rounded
 * corner would have been filled in with the widget's own fill and not
 * rounded at all.
 */
TkEnv*
tkbehind(Tk *tk)
{
	if(tk == nil)
		return nil;
	if(tk->master != nil && tk->master->env != nil)
		return tk->master->env;
	if(tk->parent != nil && tk->parent->env != nil)
		return tk->parent->env;
	return tk->env;
}

int
tkstyleflat(Tk *tk)
{
	return tk != nil && tk->env != nil && tk->env->top != nil
		&& tk->env->top->style == TkSflat;
}

int
tkborderwidth(Tk *tk, int bd)
{
	int h, s;

	if(bd <= 0 || !tkspace(tk)->scaleborder)
		return bd;
	if(tk == nil || tk->env == nil || tk->env->font == nil)
		return bd;
	h = tk->env->font->height;
	s = (h + 8) / 16;
	if(s < 1)
		s = 1;
	return bd * s;
}

TkSpace*
tkspace(Tk *tk)
{
	if(tk == nil || tk->env == nil || tk->env->top == nil)
		return &tkspaces[TkSflat];
	if((uint)tk->env->top->style >= nelem(tkspaces))
		return &tkspaces[TkSflat];
	return &tkspaces[tk->env->top->style];
}

char*	tkfont;

/*
 * auto-repeating support
 * should perhaps be one rptproc per TkCtxt
 * This is not done for the moment as there isn't
 * a mechanism for terminating the rptproc
 */
static void *autorpt;
static int rptid;
static Tk *rptw;
static void *rptnote;
static void (*rptcb)(Tk*, void*, int);
static long rptto;
static int rptint;

/* blinking carets - should be per TkCtxt */
static void *blinkrpt;
static Tk *blinkw;
static void (*blinkcb)(Tk*, int);
static int blinkignore;
static int blinkon;


ulong
tkrgba(int r, int g, int b, int a)
{
	ulong p;

	if(r < 0)
		r = 0;
	else if(r > 255)
		r = 255;
	if(g < 0)
		g = 0;
	else if(g > 255)
		g = 255;
	if(b < 0)
		b = 0;
	else if(b > 255)
		b = 255;
	/*
	 * Cast, for the third time in this library and the one that matters
	 * most: every COMPUTED shade comes through here, so without it every
	 * bevel colour in the toolkit is a 64-bit value with its top half set
	 * - 0xffffffff959283ff for #959283.  colrs.c and xdata.c had the same
	 * fault in their RGB macros.
	 *
	 * It renders correctly anyway, because tkrgbavals() masks the red byte
	 * on the way back out.  What it breaks is the VALUE: tkcolor() caches
	 * by it and starts with `if(pix == DWhite) return d->white', a test a
	 * dirty value cannot satisfy, and the render nodes in scene.c carry
	 * these as the colour a backend would be handed.
	 */
	p = (((ulong)r&0xff)<<24)|(((ulong)g&0xff)<<16)|(((ulong)b&0xff)<<8)|0xffUL;
	if(a == 255)
		return p;
	return setalpha(p, a);
}

/* to be replaced */
static int
revalpha(int c, int a)
{
	if (a == 0)
		return 0;
	return (c & 0xff) * 255 / a;
}

void
tkrgbavals(ulong rgba, int *R, int *G, int *B, int *A)
{
	int a;

	a = rgba & 0xff;
	*A = a;
	/*
	 * The red byte is masked like the other two.  It was not, and on a
	 * 32-bit ulong that was harmless - the shift alone left exactly one
	 * byte.  Here ulong is 64 bits, so anything in the top half of the
	 * word comes through as well, and the RGB() macro in colrs.c put it
	 * there: R<<24 is computed as a signed int, so every colour with a
	 * red byte of 0x80 or more was sign-extended when it was widened.
	 *
	 * Red then arrived here as a negative number, rgb2hsv() computed a
	 * hue from it, and the shade came back out of a completely different
	 * sector of the colour wheel.  That is why every bevel drawn from a
	 * light background was TEAL: #F5F0D8 shaded to #00C0AB and #009080.
	 * Colours whose red byte was under 0x80 were unaffected, which is
	 * why the text and the selection accent always looked right.
	 */
	if (a != 0xff) {
		*R = revalpha((rgba>>24) & 0xFF, a);
		*G = revalpha((rgba>>16) & 0xFF, a);
		*B = revalpha((rgba >> 8) & 0xFF, a);
	} else {
		*R = ((rgba>>24) & 0xFF);
		*G = ((rgba>>16) & 0xFF);
		*B = ((rgba >> 8) & 0xFF);
	}
}

static int
tkcachecol(TkCtxt *c, Image *i, ulong one, ulong three)
{
	TkCol *cc;

	cc = malloc(sizeof(*cc));
	if(cc == nil)
		return 0;
	cc->rgba1 = one;
	cc->rgba3 = three;
	cc->i = i;
	cc->forw = c->chead;
	c->chead = cc;
	c->ncol++;
	/* we'll do LRU management at some point */
	if(c->ncol > TkColcachesize){
		static int warn;
		if(warn == 0){
			warn = 1;
			print("tk: %d colours cached\n", TkColcachesize);
		}
	}
	return 1;
}

static Image*
tkfindcol(TkCtxt *c, ulong one, ulong three)
{
	TkCol *cc, **l;

	for(l = &c->chead; (cc = *l) != nil; l = &cc->forw)
		if(cc->rgba1 == one && cc->rgba3 == three){
			/* move it up in the list */
			*l = cc->forw;
			cc->forw = c->chead;
			c->chead = cc;
			/* we assume it will be used right away and not stored */
			return cc->i;
		}
	return nil;
}

void
tkfreecolcache(TkCtxt *c)
{
	TkCol *cc;

	if(c == nil)
		return;
	while((cc = c->chead) != nil){
		c->chead = cc->forw;
		freeimage(cc->i);
		free(cc);
	}
	c->ctail = nil;
	c->ncol = 0;
}

Image*
tkcolormix(TkCtxt *c, ulong one, ulong three)
{
	Image *i;
	Display *d;

	i = tkfindcol(c, one, three);
	if(i != nil)
		return i;
	d = c->display;
	i = allocimagemix(d, one, three);
	if(i == nil)
		return d->black;
	if(!tkcachecol(c, i, one, three)){
		freeimage(i);
		return d->black;
	}
	return i;
}

Image*
tkcolor(TkCtxt *c, ulong pix)
{
	Image *i;
	Display *d;
	Rectangle r;

	d = c->display;
	if(pix == DWhite)
		return d->white;
	if(pix == DBlack)
		return d->black;
	i = tkfindcol(c, pix, DNotacolor);
	if(i != nil)
		return i;
	r.min = ZP;
	r.max.x = 1;
	r.max.y = 1;
	if ((pix & 0xff) == 0xff)
		i = allocimage(d, r, RGB24, 1, pix);
	else
		i = allocimage(d, r, RGBA32, 1, pix);
	if(i == nil)
		return d->black;
	if(!tkcachecol(c, i, pix, DNotacolor)) {
		freeimage(i);
		return d->black;
	}
	return i;
}

Image*
tkgradient(TkCtxt *c, Rectangle r, int dir, ulong pix0, ulong pix1)
{
	Display *d;
	Image *i;
	uchar *b, *p, *e;
	int c0[3], c1[3], delta[3], a, j, x, y, n, locked;
	Rectangle s;

	d = c->display;
	y = Dy(r);
	x = Dx(r);
	if(x <= 0 || y <= 0) {
		r = Rect(0, 0, 1, 1);
		x = y = 1;
	}
	/* TO DO: diagonal */
	s = r;
	if(dir == Tkhorizontal){
		n = x;
		r.max.y = r.min.y+1;
	}else{
		n = y;
		r.max.x = r.min.x+1;
	}
	b = mallocz(3*n, 0);
	if(b == nil)
		return nil;
	locked = lockdisplay(d);
	i = allocimage(d, r, RGB24, 1, DNofill);
	if(i == nil)
		goto Ret;
	tkrgbavals(pix0, &c0[2], &c0[1], &c0[0], &a);
	tkrgbavals(pix1, &c1[2], &c1[1], &c1[0], &a);
	for(j = 0; j < 3; j++){
		c0[j] <<= 12;
		c1[j] <<= 12;
		delta[j] = ((c1[j]-c0[j])+(1<<11))/n;
	}
	e = b+3*n;
	for(p = b; p < e; p += 3) {
		p[0] = c0[0]>>12;
		p[1] = c0[1]>>12;
		p[2] = c0[2]>>12;
		c0[0] += delta[0];
		c0[1] += delta[1];
		c0[2] += delta[2];
	}
	loadimage(i, r, b, 3*n);
	replclipr(i, 1, s);
Ret:
	if(locked)
		unlockdisplay(d);
	free(b);
	return i;
}

/*
 * XXX should be in libdraw?
 */
int
tkchanhastype(ulong c, int t)
{
	for(; c; c>>=8)
		if(TYPE(c) == t)
			return 1;
	return 0;
}

void
tksettransparent(Tk *tk, int transparent)
{
	if (transparent)
		tk->flag |= Tktransparent;
	else
		tk->flag &= ~Tktransparent;
}

int
tkhasalpha(TkEnv *e, int col)
{
	return (e->colors[col] & 0xff) != 0xff;
}

Image*
tkgc(TkEnv *e, int col)
{
	return tkcolor(e->top->ctxt, e->colors[col]);
}


/*
 * Todo: improve the fixed-point code
 * the 255 scale factor is used because RGB ranges 0-255
 */
static void
rgb2hsv(int r, int g, int b, int *h, int *s, int *v)
{
	int min, max, delta;

	max = r;
	if(g > max)
		max = g;
	if(b > max)
		max = b;
	min = r;
	if(g < min)
		min = g;
	if(b < min)
		min = b;
	*v = max;
	if (max != 0)
		*s = ((max - min)*255) / max;
	else
		*s = 0;

	if (*s == 0) {
		*h = 0;	/* undefined */
	} else {
		delta = max - min;
		if (r == max) 
			*h = (g - b)*255 / delta;
		else if (g == max)
			*h = (2*255) + ((b - r)*255) / delta;
		else if (b == max)
			*h = (4*255) + ((r - g)*255)/ delta;
		*h *= 60;
		if (*h < 0)
			*h += 360*255;
		*h /= 255;
	}
}

static void
hsv2rgb(int h, int s, int v, int *r, int *g, int *b)
{
	int	i;
	int	f,p,q,t;

	if (s == 0 && h == 0) {
		*r = *g = *b = v;	/* achromatic case */
	} else {
		if (h >= 360)
			h = 0;
		i = h / 60;
		h *= 255;
		h /= 60;

		f = h % 255;
		p = v * (255 - s);
		q = v * (255 - ((s * f)/255));
		t = v * (255- ((s * (255 - f))/255));
		p /= 255;
		q /= 255;
		t /= 255;
		switch (i) {
		case 0: *r = v; *g = t; *b = p; break;
		case 1: *r = q; *g = v; *b = p; break;
		case 2: *r = p; *g = v; *b = t; break;
		case 3: *r = p; *g = q; *b = v; break;
		case 4: *r = t; *g = p; *b = v; break;
		case 5: *r = v; *g = p; *b = q; break;
		}
	}
}

enum {
	MINDELTA	= 0x10,
	DELTA	= 0x30,
};

ulong
tkrgbashade(ulong rgba, int shade)
{
	int R, G, B, A, h, s, v, vl, vd;

	if (shade == TkSameshade)
		return rgba;

	tkrgbavals(rgba, &R, &G, &B, &A);
	h = s = v = 0;
	rgb2hsv(R, G, B, &h, &s, &v);

	if (v < MINDELTA) {
		vd = v+DELTA;
		vl = vd+DELTA;
	} else if (v > 255-MINDELTA) {
		vl = v-DELTA;
		vd = vl-DELTA;
	} else {
		vl = v+DELTA;
		vd = v-DELTA;
	}

	v = (shade == TkLightshade)?vl:vd;
	if (v < 0)
		v = 0;
	if (v > 255)
		v = 255;
	hsv2rgb(h, s, v, &R, &G, &B);

	return tkrgba(R, G, B, A);
}

Image*
tkgshade(TkEnv *e, int col, int shade)
{
	ulong rgba;

	if (col == TkCbackgnd || col == TkCselectbgnd || col == TkCactivebgnd)
		return tkgc(e, col+shade);
	rgba = tkrgbashade(e->colors[col], shade);
	return tkcolor(e->top->ctxt, rgba);
}

TkEnv*
tknewenv(TkTop *t)
{
	TkEnv *e;

	e = malloc(sizeof(TkEnv));
	if(e == nil)
		return nil;

	e->ref = 1;
	e->top = t;
	return e;
}

TkEnv*
tkdefaultenv(TkTop *t)
{
	int locked;
	TkEnv *env;
	Display *d;

	if(t->env != nil) {
		t->env->ref++;
		return t->env;
	}
	t->env = malloc(sizeof(TkEnv));
	if(t->env == nil)
		return nil;

	env = t->env;
	env->ref = 1;
	env->top = t;

	if(tkfont == nil)
		tkfont = "/fonts/pelm/unicode.8.font";

	d = t->display;
	env->font = font_open(d, tkfont);
	if(env->font == nil) {
		static int warn;
		if(warn == 0) {
			warn = 1;
			print("tk: font not found: %s\n", tkfont);
		}
		env->font = font_open(d, "*default*");
		if(env->font == nil) {
			free(t->env);
			t->env = nil;
			return nil;
		}
	}

	locked = lockdisplay(d);
	env->wzero = stringwidth(env->font, "0");
	if ( env->wzero <= 0 )
		env->wzero = env->font->height / 2;
	if(locked)
		unlockdisplay(d);

	tksetenvcolours(env, t != nil ? t->style : TkSflat);
	return env;
}

void
tkputenv(TkEnv *env)
{
	Display *d;
	int locked;

	if(env == nil)
		return;

	env->ref--;
	if(env->ref != 0)
		return;

	d = env->top->display;
	locked = lockdisplay(d);

	if(env->font != nil)
		font_close(env->font);

	if(locked)
		unlockdisplay(d);

	free(env);
}

TkEnv*
tkdupenv(TkEnv **env)
{
	Display *d;
	TkEnv *e, *ne;

	e = *env;
	if(e->ref == 1)
		return e;

	ne = malloc(sizeof(TkEnv));
	if(ne == nil)
		return nil;

	ne->ref = 1;
	ne->top = e->top;

	d = e->top->display;
	memmove(ne->colors, e->colors, sizeof(e->colors));
	ne->set = e->set;
	ne->font = font_open(d, e->font->name);
	ne->wzero = e->wzero;

	e->ref--;
	*env = ne;
	return ne;
}

Tk*
tknewobj(TkTop *t, int type, int n)
{
	Tk *tk;

	tk = malloc(n);
	if(tk == 0)
		return 0;

	tk->type = type;		/* Defaults */
	tk->flag = Tktop;
	tk->relief = TKflat;
	tk->env = tkdefaultenv(t);
	if(tk->env == nil) {
		free(tk);
		return nil;
	}

	return tk;
}

void
tkfreebind(TkAction *a)
{
	TkAction *next;

	while(a != nil) {
		next = a->link;
		if((a->type & 0xff) == TkDynamic)
			free(a->arg);
		free(a);
		a = next;
	}
}

void
tkfreename(TkName *f)
{
	TkName *n;

	while(f != nil) {
		n = f->link;
		free(f);
		f = n;
	}
}

void
tkfreeobj(Tk *tk)
{
	TkCtxt *c;

	c = tk->env->top->ctxt;
	if(c != nil) {
		if(c->tkkeygrab == tk)
			c->tkkeygrab = nil;
		if(c->mgrab == tk)
			tksetmgrab(tk->env->top, nil);
		if(c->mfocus == tk)
			c->mfocus = nil;
		if(c->entered == tk)
			c->entered = nil;
	}

	if (tk == rptw) {
		/* cancel the autorepeat without notifying the widget */
		rptid++;
		rptw = nil;
	}
	if (tk == blinkw)
		blinkw = nil;
	tkextnfreeobj(tk);
	tkmethod[tk->type]->free(tk);
	tkputenv(tk->env);
	tkfreebind(tk->binds);
	if(tk->name != nil)
		free(tk->name);
	free(tk);
}

char*
tkaddchild(TkTop *t, Tk *tk, TkName **names)
{
	TkName *n;
	Tk *f, **l;
	int found, len;
	char *s, *ep;

	n = *names;
	if(n == nil || n->name[0] != '.'){
		if(n != nil)
			tkerr(t, n->name);
		return TkBadwp;
	}

	if (n->name[1] == '\0')
		return TkDupli;

	/*
	 * check that the name is well-formed.
	 * ep will point to end of parent component of the name.
	 */
	ep = nil;
	for (s = n->name + 1; *s; s++) {
		if (*s == '.'){
			tkerr(t, n->name);
			return TkBadwp;
		}
		for (; *s && *s != '.'; s++)
			;
		if (*s == '\0')
			break;
		ep = s;
	}
	if (ep == s - 1){
		tkerr(t, n->name);
		return TkBadwp;
	}
	if (ep == nil)
		ep = n->name + 1;
	len = ep - n->name;

	found = 0;
	l = &t->root;
	for(f = *l; f; f = f->siblings) {
		if (f->name != nil) {
			if (strcmp(n->name, f->name->name) == 0)
				return TkDupli;
			if (!found &&
					strncmp(n->name, f->name->name, len) == 0 &&
					f->name->name[len] == '\0')
				found = 1;
		}
		l = &f->siblings;
	}
	if (0) {		/* don't enable this until a reasonably major release... if ever */
		/*
		 * parent widget must already exist
		 */
		if (!found){
			tkerr(t, n->name);
			return TkBadwp;
		}
	}
	*l = tk;
	tk->name = n;
	*names = n->link;

	return nil;
}

Tk*
tklook(TkTop *t, char *wp, int parent)
{
	Tk *f;
	char *p, *q;

	if(wp == nil)
		return nil;

	if(parent) {
		p = strdup(wp);
		if(p == nil)
			return nil;
		q = strrchr(p, '.');
		if(q == nil)
			abort();
		if(q == p) {
			free(p);
			return t->root;
		}
		*q = '\0';	
	} else
		p = wp;

	for(f = t->root; f; f = f->siblings)
		if ((f->name != nil) && (strcmp(f->name->name, p) == 0))
			break;

	if(f != nil && (f->flag & Tkdestroy))
		f = nil;

	if (parent)
		free(p);
	return f;
}

/*
 * A selection band is a fill and four edges - light along the top and the
 * left, dark along the bottom and the right.  The geometry lives here
 * once, and both the draw() path and the node path walk what it returns,
 * so the two cannot come to describe different bands.  It was five
 * open-coded draw()s accumulating into one rectangle, and the order
 * below is theirs.  Keeping it costs nothing, and the order turns out
 * not to matter anyway: all four edges lie OUTSIDE the fill, and where
 * two of them overlap - the corner squares - they are the same colour,
 * so nothing here paints over anything of a different shade.
 */
int
tkselrects(Rectangle r, int sbw, Rectangle *rr, int *ci)
{
	ci[0] = TkCselectbgnd;
	rr[0] = r;

	ci[1] = TkCselectbgndlght;			/* top */
	rr[1] = Rect(r.min.x-sbw, r.min.y-sbw, r.max.x, r.min.y);

	ci[2] = TkCselectbgndlght;			/* left */
	rr[2] = Rect(r.min.x-sbw, r.min.y-sbw, r.min.x, r.max.y+sbw);

	ci[3] = TkCselectbgnddark;			/* bottom */
	rr[3] = Rect(r.min.x, r.max.y, r.max.x+sbw, r.max.y+sbw);

	ci[4] = TkCselectbgnddark;			/* right */
	rr[4] = Rect(r.max.x, r.min.y-sbw, r.max.x+sbw, r.max.y+sbw);

	return 5;
}

void
tktextsdraw(Image *img, Rectangle r, TkEnv *e, int sbw)
{
	Rectangle rr[5];
	int ci[5], k, n;

	n = tkselrects(r, sbw, rr, ci);
	for(k = 0; k < n; k++)
		draw(img, rr[k], tkgc(e, ci[k]), nil, ZP);
}

void
tkscenetextsel(TkScene *s, Rectangle r, TkEnv *e, int sbw)
{
	Rectangle rr[5];
	int ci[5], k, n;

	n = tkselrects(r, sbw, rr, ci);
	for(k = 0; k < n; k++)
		tkscenecolour(s, rr[k], e->colors[ci[k]]);
}

void
tkbox(Image *i, Rectangle r, int bd, Image *fill)
{
	if (bd > 0) {
		draw(i, Rect(r.min.x, r.min.y, r.max.x, r.min.y+bd), fill, nil, ZP);
		draw(i, Rect(r.min.x, r.min.y+bd, r.min.x+bd, r.max.y-bd), fill, nil, ZP);
		draw(i, Rect(r.min.x, r.max.y-bd, r.max.x, r.max.y), fill, nil, ZP);
		draw(i, Rect(r.max.x-bd, r.min.y+bd, r.max.x, r.max.y), fill, nil, ZP);
	}
}

/*
 * The classic two-tone bevel, into an image or into a scene.  Written
 * once and branched at the draw, the way drawstring() is: the shape is
 * a staircase, eight rectangles for a border width of two, and two
 * copies of that arithmetic would drift apart the first time either
 * was touched.
 */
static void
bevel(Image *i, TkScene *sc, Point o, int w, int h, int bw, Image *top,
	Image *bottom, ulong toprgba, ulong botrgba)
{
	Rectangle r;
	int x, border;

	border = 2 * bw;

	r.min = o;
	r.max.x = r.min.x + w + border;
	r.max.y = r.min.y + bw;
	if(sc != nil)
		tkscenecolour(sc, r, toprgba);
	else
		draw(i, r, top, nil, ZP);

	r.max.x = r.min.x + bw;
	r.max.y = r.min.y + h + border;
	if(sc != nil)
		tkscenecolour(sc, r, toprgba);
	else
		draw(i, r, top, nil, ZP);

	r.max.x = o.x + w + border;
	r.max.y = o.y + h + border;
	r.min.x = o.x + bw;
	r.min.y = r.max.y - bw;
	for(x = 0; x < bw; x++) {
		if(sc != nil)
			tkscenecolour(sc, r, botrgba);
		else
			draw(i, r, bottom, nil, ZP);
		r.min.x--;
		r.min.y++;
	}
	r.min.x = o.x + bw + w;
	r.min.y = o.y + bw;
	for(x = bw; x >= 0; x--) {
		if(sc != nil)
			tkscenecolour(sc, r, botrgba);
		else
			draw(i, r, bottom, nil, ZP);
		r.min.x++;
		r.min.y--;
	}
}

void
tkbevel(Image *i, Point o, int w, int h, int bw, Image *top, Image *bottom)
{
	bevel(i, nil, o, w, h, bw, top, bottom, 0, 0);
}

void
tkbevelnodes(TkScene *sc, Point o, int w, int h, int bw, ulong top, ulong bottom)
{
	bevel(nil, sc, o, w, h, bw, nil, nil, top, bottom);
}

/*
 * draw a relief border.
 * color is an index into tk->env->colors and assumes
 * light and dark versions following immediately after
 * that index
 */
/*
 * A rounded rectangle, stroked.
 *
 * The first version of this only ERASED the corners - painted them back
 * to the parent's background and stopped - which on a one-pixel outline
 * leaves four disconnected line segments and no curve at all.  A rounded
 * rectangle needs the border to FOLLOW the arc, so the corner rows both
 * erase what is outside the curve and draw the border pixel on it.
 *
 * The erase uses the PARENT's background, not the widget's own: the
 * point is to let whatever is behind the widget show through where the
 * corner has been cut away.
 *
 * No sqrt.  The radius is a handful of pixels, so the arc position on
 * each row is found by walking out from the edge until the pixel falls
 * inside the circle - exact at these sizes, and it keeps the maths
 * library out of every kernel that links libtk.
 */
static void
tkroundbox(Image *i, Tk *tk, Point o, int w, int h, int bd, Image *col)
{
	TkEnv *pe;
	Image *bg;
	int rad, x, y, dx, dy, cut, r2, in0, in1, l0, r0;

	rad = tkspace(tk)->corner;
	if(rad*2 > w)
		rad = w/2;
	if(rad*2 > h)
		rad = h/2;
	if(rad < 0)
		rad = 0;

	/* the straight runs, stopping short of the corners */
	if(w > 2*rad) {
		draw(i, Rect(o.x+rad, o.y, o.x+w-rad, o.y+bd), col, nil, ZP);
		draw(i, Rect(o.x+rad, o.y+h-bd, o.x+w-rad, o.y+h), col, nil, ZP);
	}
	if(h > 2*rad) {
		draw(i, Rect(o.x, o.y+rad, o.x+bd, o.y+h-rad), col, nil, ZP);
		draw(i, Rect(o.x+w-bd, o.y+rad, o.x+w, o.y+h-rad), col, nil, ZP);
	}
	if(rad <= 0)
		return;

	pe = tkbehind(tk);
	bg = tkgc(pe, TkCbackgnd);

	r2 = rad*rad;
	for(y = 0; y < rad; y++){
		dy = rad - y;
		cut = 0;
		for(x = 0; x < rad; x++){
			dx = rad - x;
			if(dx*dx + dy*dy <= r2)
				break;
			cut++;
		}
		/* outside the curve: let the parent through */
		if(bg != nil && cut > 0){
			draw(i, Rect(o.x, o.y+y, o.x+cut, o.y+y+1), bg, nil, ZP);
			draw(i, Rect(o.x+w-cut, o.y+y, o.x+w, o.y+y+1), bg, nil, ZP);
			draw(i, Rect(o.x, o.y+h-1-y, o.x+cut, o.y+h-y), bg, nil, ZP);
			draw(i, Rect(o.x+w-cut, o.y+h-1-y, o.x+w, o.y+h-y), bg, nil, ZP);
		}
		/*
		 * On the curve: the border itself, clamped to the span the
		 * cut above left behind.  Unclamped it draws OUTSIDE the
		 * outline it has just cut away, which is invisible until a
		 * widget is narrower than twice its own corner - an 8-pixel
		 * entry, a thin scrollbar - and then the widget has two
		 * pixels of border sticking out of a row that is otherwise
		 * not the widget at all.
		 */
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
		draw(i, Rect(in0, o.y+y, l0, o.y+y+1), col, nil, ZP);
		draw(i, Rect(r0, o.y+y, in1, o.y+y+1), col, nil, ZP);
		draw(i, Rect(in0, o.y+h-1-y, l0, o.y+h-y), col, nil, ZP);
		draw(i, Rect(r0, o.y+h-1-y, in1, o.y+h-y), col, nil, ZP);
	}
}

/*
 * The nodes a flat border is made of, appended to a scene the caller
 * owns.
 *
 * Separated from tkdrawrelief() so that a widget building its own scene
 * can put its border in the same tree as the rest of itself, rather than
 * having tkdrawrelief() build and render a tree of its own into an image
 * halfway through - which is right when the border is all there is and
 * wrong once the widget is a layer.
 */
/*
 * Blit a widget into its own rounded shape: the middle band, then each
 * corner row span by span.
 *
 * Both paths end in this.  A widget draws itself square into a scratch
 * and the SHAPE is applied when the result is copied out, so the corners
 * of the destination are left exactly as they were - which is what is
 * behind the widget, whatever that is.
 *
 * The alternative, which is what this tree did until now, is to paint
 * the corners with the parent's flat background once the widget is
 * drawn.  That is right only while the thing behind a widget is that
 * flat colour: a bordered entry over a red canvas item had its corners
 * painted page-grey over the red, and the byte comparison found it as
 * soon as the two paths stopped agreeing about which was correct.
 */
void
tkshapedblit(Image *dst, Rectangle d, Image *src, Point sp, int radius)
{
	int rad, y, cut, h;

	rad = tkclamprad(d, radius);
	if(rad <= 0){
		draw(dst, d, src, nil, sp);
		return;
	}
	h = Dy(d);
	draw(dst, Rect(d.min.x, d.min.y+rad, d.max.x, d.max.y-rad), src, nil,
		addpt(sp, Pt(0, rad)));
	for(y = 0; y < rad; y++){
		cut = tkinset(rad, y);
		draw(dst, Rect(d.min.x+cut, d.min.y+y, d.max.x-cut, d.min.y+y+1),
			src, nil, addpt(sp, Pt(cut, y)));
		draw(dst, Rect(d.min.x+cut, d.min.y+h-1-y, d.max.x-cut, d.min.y+h-y),
			src, nil, addpt(sp, Pt(cut, h-1-y)));
	}
}

/*
 * The corner radius a widget's LAYER should take, which is the radius
 * its border will be drawn with, or none when no border is drawn.
 *
 * The two have to agree, because they describe one widget: a border
 * that is not drawn leaves square corners, and a layer composited round
 * under it would round a widget the direct path leaves square.  So this
 * repeats tkreliefnodes' own early return rather than guessing at it.
 */
int
tkscenecorner(Tk *tk, int rlf)
{
	if(tk->borderwidth <= 0 || rlf == TKflat)
		return 0;
	return tkspace(tk)->corner;
}

static void
relief(TkScene *sc, Tk *tk, Point o, int color, int rlf, int mend)
{
	TkEnv *e, *pe;
	ulong brgba;
	Rectangle r;
	int w, h, bd;

	if(sc == nil || tk->borderwidth == 0 || rlf == TKflat)
		return;
	e = tk->env;
	w = tk->act.width;
	h = tk->act.height;
	bd = tk->borderwidth;
	/*
	 * The same two-way choice the direct path makes: only the three
	 * background colours have a precomputed dark shade in the table
	 * beside them; anything else has to be computed.
	 */
	if(color == TkCbackgnd || color == TkCselectbgnd || color == TkCactivebgnd)
		brgba = e->colors[color+TkDarkshade];
	else
		brgba = tkrgbashade(e->colors[color], TkDarkshade);
	r = Rect(o.x, o.y, o.x + w + 2*bd, o.y + h + 2*bd);
	if(mend){
		pe = tkbehind(tk);
		tksceneborderon(sc, r, tkspace(tk)->corner, bd, brgba,
			pe->colors[TkCbackgnd]);
	}else
		tksceneborder(sc, r, tkspace(tk)->corner, bd, brgba);
}

void
tkreliefnodes(TkScene *sc, Tk *tk, Point o, int color, int rlf)
{
	relief(sc, tk, o, color, rlf, 0);
}

/*
 * The same border, plus the parent's colour painted back where the
 * corner is cut away.
 *
 * For a widget that draws IN PLACE and is not described entirely by
 * nodes - a text(9) is the one there is - because such a widget's
 * background is its parent's and its own content can reach the corner
 * pixel the curve cuts.  tkroundbox() has always done this in the
 * drawing path; a plain border node does not, which made `render
 * scene' change what a border meant for exactly those widgets.  It
 * showed as ONE pixel, at the top right of a text widget whose tag had
 * a background reaching the edge.
 */
void
tkreliefnodeson(TkScene *sc, Tk *tk, Point o, int color, int rlf)
{
	relief(sc, tk, o, color, rlf, 1);
}

void
tkdrawrelief(Image *i, Tk *tk, Point o, int color, int rlf)
{
	TkEnv *e;
	Image *l, *d, *t;
	int h, w, bd, bd1, bd2;

	if(tk->borderwidth == 0)
		return;

	h = tk->act.height;
	w = tk->act.width;

	e = tk->env;
	if (color == TkCbackgnd || color == TkCselectbgnd || color == TkCactivebgnd) {
		l = tkgc(e, color+TkLightshade);
		d = tkgc(e, color+TkDarkshade);
	} else {
		l = tkgshade(e, color, TkLightshade);
		d = tkgshade(e, color, TkDarkshade);
	}
	bd = tk->borderwidth;
	if(rlf < 0)
		rlf = TKraised;

	/*
	 * One restrained outline instead of a two-tone chisel.  Every state
	 * that a relief is asked to show also changes the FILL behind it -
	 * a pressed button is drawn in activebgnd, an indicator-less
	 * checkbutton in select - so collapsing raised and sunken here
	 * loses no information a person could act on, which is why the flat
	 * style can be one line rather than a second set of shapes.
	 */
	if(tk->env->top != nil && tk->env->top->style == TkSflat) {
		if(rlf == TKflat)
			return;
		if(tkviascene){
			TkScene *sc;

			sc = tkscenenew();
			if(sc != nil){
				/*
				 * MENDING, because the line below it does:
				 * tkroundbox() lets the parent through where
				 * the curve cuts, and this is the same call
				 * with the same job.  Without that, turning
				 * on `render scene' changed what a border did
				 * to a widget that draws in place.
				 */
				tkreliefnodeson(sc, tk, o, color, rlf);
				tkscenerender(sc, e->top->ctxt, i);
				tkscenefree(sc);
				return;
			}
			/* no memory for a tree: draw it directly rather than not */
		}
		tkroundbox(i, tk, o, w + 2*bd, h + 2*bd, bd, d);
		return;
	}

	switch(rlf) {	case TKflat:
		break;
	case TKsunken:
		tkbevel(i, o, w, h, bd, d, l);
		break;	
	case TKraised:
		tkbevel(i, o, w, h, bd, l, d);
		break;	
	case TKgroove:
		t = d;
		d = l;
		l = t;
		/* fall through */
	case TKridge:
		bd1 = bd/2;
		bd2 = bd - bd1;
		if(bd1 > 0)
			tkbevel(i, o, w + 2*bd2, h + 2*bd2, bd1, l, d);
		o.x += bd1;
		o.y += bd1;
		tkbevel(i, o, w, h, bd2, d, l);
		break;
	}
}

/*
 * style ?flat|classic?
 *
 * Picks what a relief means for this toplevel, and reports what is in
 * force when asked with no argument.  It is deliberately a whole-window
 * setting rather than a per-widget option: the thing that makes a set of
 * widgets look like one set is that they agree, and an option each
 * widget could set differently is an option each program would set
 * differently.
 *
 * The old look stays reachable, which is the point of having the switch
 * at all - the existing chisel is coherent and somebody chose it.
 */
/*
 * render ?direct|scene?
 *
 * Reports or sets which path a flat border takes.  It is a whole-process
 * setting rather than per-toplevel because it exists to be compared
 * against itself, not to be configured: a program has no reason to want
 * one or the other, and a test has every reason to want both.
 */
char*
tkrendercmd(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char buf[Tkmaxitem];

	tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(buf[0] == '\0') {
		if(ret != nil)
			return tkvalue(ret, "%s", tkviascene ? "scene" : "direct");
		return nil;
	}
	/*
	 * `render count' answers how many trees the repaints since the last
	 * `render count' rendered, how many widgets went into them and how
	 * many nodes those held, and then starts counting again.  The last
	 * is what sizes a GPU backend: a submission per tree is worth
	 * having only if a tree carries enough nodes to pay for one.  Two repaints that batch differently
	 * draw the same pixels, so the identity check cannot see batching
	 * at all and this is what a test asks instead.
	 */
	/*
	 * `render types' answers, per widget type, how many times its draw
	 * method ran and how many of those joined a tree -- the table item
	 * 1.1 of doc/scene-graph-plan.ms needs.  Types printed with a join
	 * count of zero are the candidates for direct painting; see
	 * tkwalknote() for the two things this cannot distinguish.
	 */
	if(strcmp(buf, "types") == 0){
		/*
		 * NOT buf: it is Tkmaxitem, 128 bytes, and seventeen types
		 * need about 340.  Writing the table into it stopped after
		 * exactly eight entries -- the first eight in enum order --
		 * which read as "only eight types ever draw" and is instead
		 * the instrument running out of room.  And it broke out of
		 * the loop SILENTLY, so nothing in the output said so.
		 */
		char tbuf[32*TKwidgets], *q, *e;
		int i, drew, joined, cut;

		if(ret == nil)
			return nil;
		q = tbuf;
		e = tbuf + sizeof(tbuf);
		cut = 0;
		for(i = 0; i < TKwidgets; i++){
			tkwalktypes(i, &drew, &joined);
			if(drew == 0)
				continue;
			if(q + 32 >= e){
				cut = 1;	/* say so rather than stop quietly */
				break;
			}
			q += snprint(q, e - q, "%s %d %d ",
				tkmethod[i]->name, drew, joined);
		}
		if(cut)
			snprint(q, e - q, "TRUNCATED");
		tkwalkreset();
		return tkvalue(ret, "%s", tbuf);
	}
	if(strcmp(buf, "count") == 0){
		int runs, widgets, nodes;

		tkwalkcount(&runs, &widgets, &nodes);
		tkwalkreset();
		if(ret != nil)
			return tkvalue(ret, "%d %d %d", runs, widgets, nodes);
		return nil;
	}
	/*
	 * `render bounds' answers the union of what those same trees
	 * marked, as `minx miny maxx maxy', and resets with the counts.
	 * It exists because a described frame can say where it drew
	 * BEFORE anything looks at pixels, which is what lets a backend
	 * push only the part that changed.  An empty rectangle means the
	 * trees marked nothing.
	 */
	/*
	 * `render nodes' answers how many nodes that mark pixels went by
	 * and how many of those described no box, then resets with the
	 * counts.  The second number is the one that matters and it should
	 * be zero: a node whose extent is unknown is one a backend can
	 * neither place nor cull, and that is what the tree is FOR.  The
	 * scene-level union cannot see this - a detail node always sits
	 * inside its widget's background - so it is asked directly.
	 */
	if(strcmp(buf, "nodes") == 0){
		int drawn, undesc;

		tkwalknodebox(&drawn, &undesc);
		tkwalkreset();
		if(ret != nil)
			return tkvalue(ret, "%d %d", drawn, undesc);
		return nil;
	}
	if(strcmp(buf, "bounds") == 0){
		Rectangle b;

		tkwalkbounds(&b);
		tkwalkreset();
		if(ret != nil)
			return tkvalue(ret, "%d %d %d %d",
				b.min.x, b.min.y, b.max.x, b.max.y);
		return nil;
	}
	if(strcmp(buf, "scene") == 0)
		tkviascene = 1;
	else if(strcmp(buf, "direct") == 0)
		tkviascene = 0;
	else
		return TkBadvl;
	for(tk = t->root; tk != nil; tk = tk->siblings) {
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
	}
	return tkupdate(t);
}

char*
tkstylecmd(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char buf[Tkmaxitem];

	tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(buf[0] == '\0') {
		if(ret != nil)
			return tkvalue(ret, "%s",
				t->style == TkSflat ? "flat" : "classic");
		return nil;
	}
	if(strcmp(buf, "flat") == 0)
		t->style = TkSflat;
	else if(strcmp(buf, "classic") == 0)
		t->style = TkSclassic;
	else
		return TkBadvl;

	/*
	 * Only the BORDER of an existing widget changes here.  The spacings
	 * in tkspaces[] are read when a widget is configured, and a widget
	 * that changed size would push a new size request up to its master
	 * and on to the toplevel, which re-fits itself to its contents: one
	 * `style' command resized the whole window and moved every widget
	 * in it.  A window that jumps size because its borders were restyled
	 * is worse than one whose spacings only apply to what it builds
	 * afterwards, so a program sets the style before it builds its
	 * widgets - which is what the man page says and what style(9)'s
	 * BUGS records.
	 *
	 * Every widget's border is drawn from this, so every widget has to
	 * be told, not just the one the command was aimed at.  tkdirty()
	 * only PROPAGATES dirtiness to masters and to views under a
	 * transparent widget - it returns at once unless the widget's own
	 * dirty rectangle is already set - so the rectangle has to be set
	 * here first, exactly as tkbuttonselect() does.  Without that the
	 * style changed and almost nothing repainted.
	 */
	/*
	 * Colours CAN be re-applied to a window that already exists, unlike
	 * the spacings above: a colour does not feed back into layout, so
	 * nothing re-requests a size and the toplevel does not re-fit
	 * itself.  Widgets that have been given a colour of their own hold
	 * a cloned env and keep it, which is right - an explicit
	 * -background is not the style's to overrule.
	 */
	if(t->env != nil)
		tksetenvcolours(t->env, t->style);

	for(tk = t->root; tk != nil; tk = tk->siblings) {
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
	}
	return tkupdate(t);
}

Point
tkstringsize(Tk *tk, char *text)
{
	char *q;
	int locked;
	Display *d;
	Point p, t;

	if(text == nil) {
		p.x = 0;
		p.y = tk->env->font->height;
		return p;
	}

	d = tk->env->top->display;
	locked = lockdisplay(d);

	p = ZP;
	while(*text) {
		q = strchr(text, '\n');
		if(q != nil)
			*q = '\0';
		t = stringsize(tk->env->font, text);
		p.y += t.y;
		if(p.x < t.x)
			p.x = t.x;
		if(q == nil)
			break;
		text = q+1;
		*q = '\n';
	}
	if(locked)
		unlockdisplay(d);

	return p;	
}

static Rectangle
tkulallrect(Point o, Font *f, char *text)
{
	Rectangle r;

	r.max = stringsize(f, text);
	r.max = addpt(r.max, o);
	r.min.x = o.x;
	r.min.y = r.max.y - 1;
	return r;
}

static Rectangle
tkulrect(Point o, int ul, Font *f, char *text)
{
	char c, *v;
	Rectangle r;

	v = text+ul+1;
	c = *v;
	*v = '\0';
	r.max = stringsize(f, text);
	r.max = addpt(r.max, o);
	r.min = stringsize(f, v-1);
	*v = c;
	r.min.x = r.max.x - r.min.x;
	r.min.y = r.max.y - 1;
	r.max.y++;
	return r;
}

/*
 * A label's text, line by line, into an image or into a scene.
 *
 * One function for both because every number in it - where a line
 * starts once the justification has shifted it, where the underline
 * rule goes, how far down the next line is - is a number the two paths
 * have to agree about exactly.  Written twice they would agree until
 * somebody changed one, and the identity check would then report a
 * transcription slip as a renderer fault.  The same argument as
 * tkselrects() in the entry.
 *
 * Nothing here is new to the node vocabulary: a line is a TkNglyphs and
 * the underline is a filled rectangle, which is a TkNcolour.
 */
static void
drawstring(Tk *tk, Image *i, TkScene *sc, Point o, char *text, int ul, Image *col, ulong rgba, int j)
{
	int n, l, maxl, sox;
	char *q, *txt;
	Rectangle r;
	TkEnv *e;

	e = tk->env;
	sox = maxl = 0;
	if(j != Tkleft){
		maxl = 0;
		txt = text;
		while(*txt){
			q = strchr(txt, '\n');
			if(q != nil)
				*q = '\0';
			l = stringwidth(e->font, txt);
			if(l > maxl)
				maxl = l;
			if(q == nil)
				break;
			txt = q+1;
			*q = '\n';
		}
		sox = o.x;
	}
	while(*text) {
		q = strchr(text, '\n');
		if(q != nil)
			*q = '\0';
		if(j != Tkleft){
			o.x = sox;
			l = stringwidth(e->font, text);
			if(j == Tkcenter)
				o.x += (maxl-l)/2;
			else
				o.x += maxl-l;
		}
		if(sc != nil)
			tkscenetext(sc, o, text, e->font, rgba);
		else
			string(i, o, col, o, e->font, text);
		if(ul >= 0) {
			n = strlen(text);
			r = Rect(0, 0, 0, 0);
			if(ul < n) {
				r = tkulrect(o, ul, e->font, text);
				ul = -1;
			} else if(ul == n) {
				r = tkulallrect(o, e->font, text);
				ul = -1;
			} else
				ul -= n;
			if(Dx(r) > 0 && Dy(r) > 0){
				if(sc != nil)
					tkscenecolour(sc, r, rgba);
				else
					draw(i, r, col, nil, ZP);
			}
		}
		o.y += e->font->height;
		if(q == nil)
			break;
		text = q+1;
		*q = '\n';
	}
}

void
tkdrawstring(Tk *tk, Image *i, Point o, char *text, int ul, Image *col, int j)
{
	drawstring(tk, i, nil, o, text, ul, col, 0, j);
}

void
tkscenestring(TkScene *sc, Tk *tk, Point o, char *text, int ul, ulong rgba, int j)
{
	drawstring(tk, nil, sc, o, text, ul, nil, rgba, j);
}

/* for debugging */
char*
tkname(Tk *tk)
{
	if(tk == nil)
		return "(nil)";
	if(tk->name == nil)
		return "(noname)";
	return tk->name->name;
}

Tk*
tkdeliver(Tk *tk, int event, void *data)
{
	Tk *dest;

	if(tk != nil && ((ulong)tk->type >= TKwidgets || (uintptr)tk->name < 4096 && tk->name != nil)){
		print("invalid Tk: type %d name %p\n", tk->type, tk->name);
		abort();
	}
//print("tkdeliver %v to %s\n", event, tkname(tk));
	if(tk == nil || ((tk->flag&Tkdestroy) && event != TkDestroy))
		return tk;
	if(event&(TkFocusin|TkFocusout) && (tk->flag&Tktakefocus))
		tk->dirty = tkrect(tk, 1);

	if (tkmethod[tk->type]->deliver != nil) {
		dest = tkmethod[tk->type]->deliver(tk, event, data);
		if (dest == nil)
			return tk;
		tkdirty(tk);
		return dest;
	}

	if((tk->flag & Tkdisabled) == 0)
		tksubdeliver(tk, tk->binds, event, data, 0);
	tkdirty(tk);
	return tk;
}

static int
nullop(char *fmt, ...)
{
	USED(fmt);
	return 0;
}

int
tksubdeliver(Tk *tk, TkAction *binds, int event, void *data, int extn)
{

	TkAction *a;
	int delivered, genkey, delivered2, iskey;
//int (*debug)(char *fmt, ...);

	if (!extn)
		return tkextndeliver(tk, binds, event, data);

//debug = (tk->name && !strcmp(tk->name->name, ".cd")) ? print : nullop;
//debug("subdeliver %v\n", event);

	if (event & TkTakefocus) {
		if (tk->flag & Tktakefocus)
			tksetkeyfocus(tk->env->top, tk, 0);
		return TkDdelivered;
	}

	delivered = TkDnone;
	genkey = 0;
	for(a = binds; a != nil; a = a->link) {
		if(event == a->event) {
//debug("  exact match on %v\n", a->event);
			tkcmdbind(tk, event, a->arg, data);
			delivered = TkDdelivered;
		} else if (a->event == TkKey && (a->type>>8)==TkAadd)
			genkey = 1;
	}
	if(delivered != TkDnone && !((event & TkKey) && genkey))
		return delivered;

	delivered2 = delivered;
	for(a = binds; a != nil; a = a->link) {
		/*
		 * only bind to non-specific key events; if a specific
		 * key event has already been delivered, only deliver event if
		 * the non-specific binding was added. (TkAadd)
		 */
		if (a->event & TkExtns)
			continue;
		iskey = (a->event & TkKey);
		if (iskey ^ (event & TkKey))
			continue;
		if(iskey && (TKKEY(a->event) != 0
					|| ((a->type>>8) != TkAadd && delivered != TkDnone)))
			continue;
		if(!iskey && (a->event & TkMotion) && (a->event&TkEpress) != 0)
			continue;
		if(!(event & TkDouble) && (a->event & TkDouble))
			continue;
		if((event & ~TkDouble) & a->event) {
//debug("  partial match on %v\n", a->event);
			tkcmdbind(tk, event, a->arg, data);
			delivered2 = TkDdelivered;
		}
	}
	return delivered2;
}

void
tkcancel(TkAction **l, int event)
{
	TkAction *a;

	for(a = *l; a; a = *l) {
		if(a->event == event) {
			*l = a->link;
			a->link = nil;
			tkfreebind(a);
			continue;
		}
		l = &a->link;
	}
}

static void
tkcancela(TkAction **l, int event, int type, char *arg)
{
	TkAction *a;

	for(a = *l; a; a = *l) {
		if(a->event == event && strcmp(a->arg, arg) == 0 && (a->type&0xff) == type){
			*l = a->link;
			a->link = nil;
			tkfreebind(a);
			continue;
		}
		l = &a->link;
	}
}

char*
tkaction(TkAction **l, int event, int type, char *arg, int how)
{
	TkAction *a;

	if(arg == nil)
		return nil;
	if(how == TkArepl)
		tkcancel(l, event);
	else if(how == TkAadd){
		for(a = *l; a; a = a->link)
			if(a->event == event && strcmp(a->arg, arg) == 0 && (a->type&0xff) == type){
				a->type = type + (how << 8);
				return nil;
			}
	}
	else if(how == TkAsub){
		tkcancela(l, event, type, arg);
		if(type == TkDynamic)	/* should always be the case */
			free(arg);
		return nil;
	}

	a = malloc(sizeof(TkAction));
	if(a == nil) {
		if(type == TkDynamic)
			free(arg);
		return TkNomem;
	}

	a->event = event;
	a->arg = arg;
	a->type = type + (how << 8);

	a->link = *l;
	*l = a;

	return nil;
}

char*
tkitem(char *buf, char *a)
{
	char *e;

	while(*a && (*a == ' ' || *a == '\t'))
		a++;

	e = buf + Tkmaxitem - 1;
	while(*a && *a != ' ' && *a != '\t' && buf < e)
		*buf++ = *a++;

	*buf = '\0';
	while(*a && (*a == ' ' || *a == '\t'))
		a++;
	return a;
}

/*
 * if tk is a subwindow or a descendent, return the subwindow;
 * return nil otherwise
 */
Tk*
tkfindsub(Tk *tk)
{
	for(; tk != nil; tk = tk->master){
		if(tk->parent != nil)
			return tk;	/* tk->parent is canvas or text */
	}
	return nil;
}

/*
 * Return absolute screen position of tk (just outside its top-left border).
 * When a widget is embedded in a text or canvas widget, we need to
 * use the text or canvas's relpos() function instead of act{x,y}, and we
 * need to folow up the parent pointer rather than the master one.
 */
Point
tkposn(Tk *tk)
{
	Tk *f, *last;
	Point g;

	last = tk;
	if(tk->parent != nil) {
		g = tkmethod[tk->parent->type]->relpos(tk);
		f = tk->parent;
	} else {
		g.x = tk->act.x;
		g.y = tk->act.y;
		f = tk->master;
	}
	while(f != nil) {
		g.x += f->borderwidth;
		g.y += f->borderwidth;
		last = f;
		if(f->parent != nil) {
			g = addpt(g, tkmethod[f->parent->type]->relpos(f));
			f = f->parent;
		} else {
			g.x += f->act.x;
			g.y += f->act.y;
			f = f->master;
		}
	}
	if (last->flag & Tkwindow)
		g = addpt(g, TKobj(TkWin, last)->req);
	return g;
}

/*
 * convert screen coords to local widget coords
 */
Point
tkscrn2local(Tk *tk, Point p)
{
	p = subpt(p, tkposn(tk));
	p.x -= tk->borderwidth;
	p.y -= tk->borderwidth;
	return p;
}

int
tkvisiblerect(Tk *tk, Rectangle *rr)
{
	Rectangle r;
	Point g;
	Tk *f, *last;
	g = Pt(tk->borderwidth, tk->borderwidth);
	last = tk;
	if(tk->parent != nil) {
		g = addpt(g, tkmethod[tk->parent->type]->relpos(tk));
		f = tk->parent;
	} else {
		g.x += tk->act.x;
		g.y += tk->act.y;
		f = tk->master;
	}
	if (f == nil) {
		*rr = tkrect(tk, 1);
		return 1;
	}
	r = rectaddpt(tkrect(tk, 1), g);
	while (f) {
		if (!rectclip(&r, tkrect(f, 0)))
			return 0;
		g.x = f->borderwidth;
		g.y = f->borderwidth;
		last = f;
		if (f->parent != nil) {
			g = addpt(g, tkmethod[f->parent->type]->relpos(f));
			f = f->parent;
		} else {
			g.x += f->act.x;
			g.y += f->act.y;
			f = f->master;
		}
		r = rectaddpt(r, g);
	}
	if (last->flag & Tkwindow)
		r = rectaddpt(r, TKobj(TkWin, last)->act);
	/*
	 * now we have the visible rectangle in screen coords;
	 * subtract actx+borderwidth and we've got it back in
	 * widget-local coords again
	 */
	r = rectsubpt(r, tkposn(tk));
	*rr = rectsubpt(r, Pt(tk->borderwidth, tk->borderwidth));
	return 1;
}

Point
tkanchorpoint(Rectangle r, Point size, int anchor)
{
	int dx, dy;
	Point p;

	p = r.min;
	dx = Dx(r) - size.x;
	dy = Dy(r) - size.y;
	if((anchor & (Tknorth|Tksouth)) == 0)
		p.y += dy/2;
	else if(anchor & Tksouth)
		p.y += dy;

	if((anchor & (Tkeast|Tkwest)) == 0)
		p.x += dx/2;
	else if(anchor & Tkeast)
		p.x += dx;
	return p;
}
	
static char*
tkunits(char c, int *d, TkEnv *e)
{
	switch(c) {
	default:
		if(c >= '0' || c <= '9' || c == '.')
			break;
		return TkBadvl;
	case '\0':
		break;
	case 'c':		/* Centimeters */
		*d *= (Tkdpi*100)/254;
		break;
	case 'm':		/* Millimeters */
		*d *= (Tkdpi*10)/254;
		break;
	case 'i':		/* Inches */
		*d *= Tkdpi;
		break;
	case 'p':		/* Points */
		*d = (*d*Tkdpi)/72;
		break;
	case 'w':		/* Character width */
		if(e == nil)
			return TkBadvl;
		*d = *d * e->wzero;
		break;
	case 'h':		/* Character height */
		if(e == nil)
			return TkBadvl;
		*d = *d * e->font->height;
		break;
	}
	return nil;
}

int
TKF2I(int f)
{
	if (f >= 0)
		return (f + Tkfpscalar/2) / Tkfpscalar;
	return (f - Tkfpscalar/2) / Tkfpscalar;
}

/*
 * Parse a floating point number into a decimal fixed point representation
 */
char*
tkfrac(char **arg, s32 *f, TkEnv *env)
{
	int c, minus, i, fscale, seendigit;
	char *p, *e;

	seendigit = 0;

	p = *arg;
	p = tkskip(p, " \t");

	minus = 0;
	if(*p == '-') {
		minus = 1;
		p++;
	}
	i = 0;
	while(*p) {
		c = *p;
		if(c == '.')
			break;
		if(c < '0' || c > '9')
			break;
		i = i*10 + (c - '0');
		seendigit = 1;
		p++;
	}
	i *= Tkfpscalar;
	if(*p == '.')
		p++;
	fscale = Tkfpscalar;
	while(*p && *p >= '0' && *p <= '9') {
		fscale /= 10;
		i += fscale * (*p++ - '0');
		seendigit = 1;
	}

	if(minus)
		i = -i;

	if(!seendigit)
		return TkBadvl;
	e = tkunits(*p, &i, env);
	if (e != nil)
		return e;
	while (*p && *p != ' ' && *p != '\t')
		p++;
	*arg = p;
	*f = i;
	return nil;
}

char*
tkfracword(TkTop *t, char **arg, s32 *f, TkEnv *env)
{
	char *p;
	char buf[Tkminitem];

	*arg = tkword(t, *arg, buf, buf+sizeof(buf), nil);
	p = buf;
	return tkfrac(&p, f, env);
}

char*
tkfprint(char *v, int frac)
{
	int fscale;

	if(frac < 0) {
		*v++ = '-';
		frac = -frac;
	}
	v += sprint(v, "%d", frac/Tkfpscalar);
	frac = frac%Tkfpscalar;
	if(frac != 0)
		*v++ = '.';
	fscale = Tkfpscalar/10;
	while(frac) {
		*v++ = '0' + frac/fscale;
		frac %= fscale;
		fscale /= 10;
	}
	*v = '\0';
	return v;	
}

char*
tkvalue(char **val, char *fmt, ...)
{
	va_list arg;
	Fmt fmtx;

	if(val == nil)
		return nil;

	fmtstrinit(&fmtx);
	if(*val != nil)
		if(fmtprint(&fmtx, "%s", *val) < 0)
			return TkNomem;
	va_start(arg, fmt);
	fmtvprint(&fmtx, fmt, arg);
	va_end(arg);
	free(*val);
	*val = fmtstrflush(&fmtx);
	if(*val == nil)
		return TkNomem;
	return nil;
}

static char*
tkwidgetcmd(TkTop *t, Tk *tk, char *arg, char **val)
{
	TkMethod *cm;
	TkCmdtab *ct;
	int bot, top, new, r;
	char *e, *buf;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;

	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	if(val != nil)
		*val = nil;

	cm = tkmethod[tk->type];

	e = TkBadcm;
	bot = 0;
	top = cm->ncmd - 1;

	while(bot <= top) {
		new = (bot + top)/2;
		ct = &cm->cmd[new];
		r = strcmp(ct->name, buf);
		if(r == 0) {
			e = ct->fn(tk, arg, val);
			break;
		}
		if(r < 0)
			bot = new + 1;
		else
			top = new - 1;
	}
	free(buf);
	tkdirty(tk);
	return e;
}

Rectangle
tkrect(Tk *tk, int withborder)
{
	Rectangle r;
	int bd;

	bd = withborder? tk->borderwidth: 0;
	r.min.x = -bd;
	r.min.y = -bd;
	r.max.x = tk->act.width + bd;
	r.max.y = tk->act.height + bd;
	return r;
}

void
tkdirty(Tk *tk)
{
	Tk *sub;
	Point rel;
	Rectangle dirty;
	int isdirty, transparent;

	/*
	 * mark as dirty all views underneath a dirty transparent widget
	 *	down to the first opaque widget.
	 * inform parents about any dirtiness.

	 * XXX as Tksubsub never gets reset, testing against Tksubsub doesn't *exactly* test
	 * whether we're in a canvas/text widget, but merely
	 * whether it has ever been. Tksubsub should probably be reset on unpack.
	 */
	isdirty = Dx(tk->dirty) > 0;
	transparent = tk->flag & Tktransparent;
	sub = tk;
	while (isdirty && ((tk->flag&Tksubsub) || transparent)) {
		if (tk->master != nil) {
			if (transparent) {
				rel.x = tk->act.x + tk->borderwidth;
				rel.y = tk->act.y + tk->borderwidth;
				dirty = rectaddpt(sub->dirty, rel);
				sub = tk->master;
				combinerect(&sub->dirty, dirty);
				transparent = sub->flag & Tktransparent;
			}
			tk = tk->master;
		} else if (tk->parent != nil) {
			tkmethod[tk->parent->type]->dirtychild(sub);
			tk = sub = tk->parent;
			isdirty = Dx(sub->dirty) > 0;
			transparent = sub->flag & Tktransparent;
		} else
			break;
	}
}

static int
qcmdcmp(const void *a, const void *b)
{
	return strcmp(((TkCmdtab*)a)->name, ((TkCmdtab*)b)->name);
}

void
tksorttable(void)
{
	int i;
	TkMethod *c;
	TkCmdtab *cmd;

	for(i = 0; i < TKwidgets; i++) {
		c = tkmethod[i];
		if(c->cmd == nil)
			continue;

		for(cmd = c->cmd; cmd->name != nil; cmd++)
			;
		c->ncmd = cmd - c->cmd;

		qsort(c->cmd, c->ncmd, sizeof(TkCmdtab), qcmdcmp);
	}
}

static char*
tksinglecmd(TkTop *t, char *arg, char **val)
{
	Tk *tk;
	int bot, top, new;
	char *e, *buf;

	if(t->debug)
		print("tk: '%s'\n", arg);

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;

	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	switch(buf[0]) {
	case '\0':
		free(buf);
		return nil;
	case '.':
		tk = tklook(t, buf, 0);
		if(tk == nil){
			tkerr(t, buf);
			free(buf);
			return TkBadwp;
		}
		e = tkwidgetcmd(t, tk, arg, val);
		free(buf);
		return e;
	}

	bot = 0;
	top = nelem(cmdmain) - 1;
	e = TkBadcm;
	while(bot <= top) {
		int rc;
		new = (bot + top)/2;
		rc = strcmp(cmdmain[new].name, buf); 
		if(!rc) {
			e = cmdmain[new].fn(t, arg, val);
			break;
		}

		if(rc < 0) 
			bot = new + 1;
		else
			top = new - 1;
	}
	free(buf);
	return e;
}

static char*
tkmatch(int inc, int dec, char *p)
{
	int depth, esc, c;

	esc = 0;
	depth = 1;
	while(*p) {
		c = *p;
		if(esc == 0) {
			if(c == inc)
				depth++;
			if(c == dec)
				depth--;
			if(depth == 0)
				return p;
		}
		if(c == '\\' && esc == 0)
			esc = 1;
		else
			esc = 0;
		p++;
	}
	return nil;
}

char*
tkexec(TkTop *t, char *arg, char **val)
{
	int cmdsz, n;
	char *p, *cmd, *e, *c;

	if(t->execdepth >= 0 && ++t->execdepth > 128)
		return TkDepth;

	cmd = nil;
	cmdsz = 0;

	p = arg;
	for(;;) {
		switch(*p++) {
		case '[':
			p = tkmatch('[', ']', p);
			if(p == nil){
				free(cmd);
				return TkSyntx;
			}
			break;
		case '{':
			p = tkmatch('{', '}', p);
			if(p == nil){
				free(cmd);
				return TkSyntx;
			}
			break;
		case ';':
			n = p - arg - 1;
			if(cmdsz < n)
				cmdsz = n;
			c = realloc(cmd, cmdsz+1);
			if(c == nil){
				free(cmd);
				return TkNomem;
			}
			cmd = c;
			memmove(cmd, arg, n);
			cmd[n] = '\0';
			e = tksinglecmd(t, cmd, nil);
			if(e != nil) {
				t->err = e;
				strncpy(t->errcmd, cmd, sizeof(t->errcmd));
				t->errcmd[sizeof(t->errcmd)-1] = '\0';
				free(cmd);
				return e;
			}
			arg = p;
			break;
		case '\0':
		case '\'':
			free(cmd);
			e = tksinglecmd(t, arg, val);
			if(e != nil) {
				t->err = e;
				strncpy(t->errcmd, arg, sizeof(t->errcmd));
				t->errcmd[sizeof(t->errcmd)-1] = '\0';
			}
			return e;
		}
	}
}

static struct {
	char *name;
	int mask;
} events[] = {
	"Button1P",	TkButton1P,
	"Button1R",	TkButton1R,
	"Button2P",	TkButton2P,
	"Button2R",	TkButton2R,
	"Button3P",	TkButton3P,
	"Button3R",	TkButton3R,
	"Button4P",	TkButton4P,
	"Button4R",	TkButton4R,
	"Button5P",	TkButton5P,
	"Button5R",	TkButton5R,
	"Button6P",	TkButton6P,
	"Button6R",	TkButton6R,
	"Extn1",		TkExtn1,
	"Extn2",		TkExtn2,
	"Takefocus",	TkTakefocus,
	"Destroy",		TkDestroy,
	"Enter",		TkEnter,
	"Leave",		TkLeave,
	"Motion",		TkMotion,
	"Map",		TkMap,
	"Unmap",		TkUnmap,
	"Key",		TkKey,
	"Focusin",		TkFocusin,
	"Focusout",	TkFocusout,
	"Configure",	TkConfigure,
	"Double",		TkDouble,
	0
};

int
tkeventfmt(Fmt *f)
{
	int k, i, d;
	int e;

	e = va_arg(f->args, int);

	if ((f->flags & FmtSharp) && e == TkMotion)
		return 0;
	fmtprint(f, "<");
	k = -1;
	if (e & TkKey) {
		k = e & 0xffff;
		e &= ~0xffff;
	}
	d = 0;
	for (i = 0; events[i].name; i++) {
		if (e & events[i].mask) {
			if (d++)
				fmtprint(f, "|");
			fmtprint(f, "%s", events[i].name);
		}
	}
	if (k != -1) {
		fmtprint(f, "[%c]", k);
	} else if (e == 0)
		fmtprint(f, "Noevent");
	fmtprint(f, ">");
	return 0;
}

void
tkerr(TkTop *t, char *e)
{
	if(t != nil && e != nil){
		strncpy(t->errx, e, sizeof(t->errx));
		t->errx[sizeof(t->errx)-1] = '\0';
	}
}

char*
tkerrstr(TkTop *t, char *e)
{
	char *s = malloc(strlen(e)+1+strlen(t->errx)+1);

	if(s == nil)
		return nil;
	strcpy(s, e);
	if(*e == '!'){
		strcat(s, " ");
		strcat(s, t->errx);
	}
	t->errx[0] = '\0';
	return s;
}

char*
tksetmgrab(TkTop *t, Tk *tk)
{
	Tk *omgrab;
	TkCtxt *c;
	c = t->ctxt;
	if (tk == nil) {
		omgrab = c->mgrab;
		c->mgrab = nil;
		/*
		 * don't enterleave if grab reset would cause no leave event
		 */
		if (!(omgrab != nil && (omgrab->flag & Tknograb) &&
				c->entered != nil && (c->entered->flag & Tknograb)))
			tkenterleave(t);
	} else {
		if (c->focused && c->mfocus != nil && c->mfocus->env->top != tk->env->top)
			return "!grab already taken on another toplevel";
		c->mgrab = tk;
		if (tk->flag & Tknograb) {
			if (c->focused) {
				c->focused = 0;
				c->mfocus = nil;
			}
		} else if (c->focused || c->mstate.b != 0) {
			c->focused = 1;
			c->mfocus = tk;
		}
//print("setmgrab(%s) focus now %s\n", tkname(tk), tkname(c->mfocus));
		tkenterleave(t);
	}
	return nil;
}

int
tkinsidepoly(Point *poly, int np, int winding, Point p)
{
	Point pi, pj;
	int i, j, hit;

	hit = 0;
	j = np - 1;
	for(i = 0; i < np; j = i++) {
		pi = poly[i];
		pj = poly[j];
		if((pi.y <= p.y && p.y < pj.y || pj.y <= p.y && p.y < pi.y) &&
				p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x) {
			if(winding == 1 || pi.y > p.y)
				hit++;
			else
				hit--;
		}
	}
	return (hit & winding) != 0;
}

int
tklinehit(Point *a, int np, int w, Point p)
{
	Point *b;
	int z, nx, ny, nrm;

	while(np-- > 1) {
		b = a+1;
		nx = a->y - b->y;
		ny = b->x - a->x;
		nrm = (nx < 0? -nx : nx) + (ny < 0? -ny : ny);
		if(nrm)
			z = (p.x-b->x)*nx/nrm + (p.y-b->y)*ny/nrm;
		else
			z = (p.x-b->x) + (p.y-b->y);
		if(z < 0)
			z = -z;
		if(z < w)
			return 1;
		a++;
	}
	return 0;
}

int
tkiswordchar(int c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c >= 0xA0;
}

int
tkhaskeyfocus(Tk *tk)
{
	if (tk == nil || tk->env->top->focused == 0)
		return 0;
	return tk == tk->env->top->ctxt->tkkeygrab;
}

static int
rptactive(void *v)
{
	intptr id = (intptr)v;
	if (id == rptid)
		return 1;
	return 0;
}

static int
ckrpt(void *v, int interval)
{
	intptr id = (intptr)v;
	if (id != rptid)
		return -1;
	if (interval < rptto)
		return 0;
	return 1;
}

static void
dorpt(void *v)
{
	intptr id = (intptr)v;

	if (id == rptid) {
		rptto = rptint;
		(*rptcb)(rptw, rptnote, 0);
		if (rptint <= 0) {
			rptid++;
			rptw = nil;
		}
	}
}

void
tkcancelrepeat(Tk *tk)
{
	if (tk == rptw) {
		rptid++;
		rptw = nil;
	}
}

void
tkrepeat(Tk *tk, void (*callback)(Tk*, void*, int), void *note, int pause, int interval)
{
	rptid++;
	if (tk != rptw && rptw != nil)
		/* existing callback being replaced- report to owner */
		(*rptcb)(rptw, rptnote, 1);
	rptw = tk;
	if (tk == nil || callback == nil)
		return;
	rptnote = note;
	rptcb = callback;
	rptto = pause;
	rptint = interval;
	if (!autorpt)
		autorpt = rptproc("autorepeat", TkRptclick, (void*)rptid, rptactive, ckrpt, dorpt);
	else
		rptwakeup((void*)rptid, autorpt);
}

static int
blinkactive(void *v)
{
	USED(v);
	return blinkw != nil;
}

static int
ckblink(void *v, int interval)
{
	USED(v);
	USED(interval);

	if (blinkw == nil)
		return -1;
	if (blinkignore) {
		blinkignore = 0;
		return 0;
	}
	return 1;
}

static void
doblink(void *v)
{
	USED(v);

	if (blinkw == nil)
		return;
	blinkcb(blinkw, blinkon++ & 1);
	tkupdate(blinkw->env->top);
}

void
tkblinkreset(Tk *tk)
{
	if (blinkw == tk) {
		blinkignore = 1;
		blinkon = 0;
	}
}

void
tkblink(Tk *tk, void (*callback)(Tk*, int))
{
	if (tk == nil || callback == nil) {
		blinkw = nil;
		return;
	}
	blinkw = tk;
	blinkcb = callback;
	if (!blinkrpt)
		blinkrpt = rptproc("blinker", TkBlinkinterval, nil, blinkactive, ckblink, doblink);
	else
		rptwakeup(nil, blinkrpt);
}

/*
 * debugging
 */
void
tkdump(Tk *tk)
{
	Tk *sl;

	if(tk == nil)
		return;
	if((uint)tk->type < TKwidgets)
		print("%s", tkmethod[tk->type]->name);
	else
		print("TYPE#%#ux", tk->type);
	if(tk->name == nil || (uintptr)tk->name < 512)
		print(" NAME %p", tk->name);
	else
		print(" %s", tkname(tk));
	print(" # tk %#p flag %#ux grid %#p", tk, tk->flag, tk->grid);
	if(tk->parent != nil)
		print(" parent [%#p %q]", tk->parent, tkname(tk->parent));
	if(tk->master != nil)
		print(" master [%#p %q]", tk->master, tkname(tk->master));
	if(tk->slave != nil){
		print(" slaves");
		for(sl = tk->slave; sl != nil; sl = sl->next)
			print(" [%#p %q]", sl, tkname(sl));
	}
	print("\n");
	if(tk->type != TKcanvas)
		return;
	tkcvsdump(tk);
}

void
tktopdump(Tk *tk)
{
	TkTop *top;
	Tk *sub;

	if(tk == nil || tk->env == nil){
		print("# %#p no top\n", tk);
		return;
	}
	top = tk->env->top;
	print("# env %#p top %#p\n", tk->env, top);
	if(top != nil){
		for(sub = top->root; sub != nil; sub = sub->siblings)
			tkdump(sub);
	}
}
