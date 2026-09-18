#include "lib9.h"
#include "draw.h"
#include "tk.h"
#include "label.h"

extern void tkannouncechange(Tk*);	/* ebind.c, for voice(3) */

#define	O(t, e)		((long)(&((t*)0)->e))

/* Widget Commands (+ means implemented)
	+cget
	+configure
	+invoke
	+select
	+deselect
	+toggle
 */

enum {
	/* other constants */
	InvokePause	= 200,	/* delay showing button in down state when invoked */
};

TkOption tkbutopts[] =
{
	"text",		OPTtext,	O(TkLabel, text),	nil,
	"label",	OPTtext,	O(TkLabel, text),	nil,
	"underline",	OPTdist,	O(TkLabel, ul),		nil,
	"justify",	OPTstab,	O(TkLabel, justify),	tkjustify,
	"anchor",	OPTflag,	O(TkLabel, anchor),	tkanchor,
	"command",	OPTtext,	O(TkLabel, command),	nil,
	"bitmap",	OPTbmap,	O(TkLabel, bitmap),	nil,
	"image",	OPTimag,	O(TkLabel, img),	nil,
	nil
};

TkOption tkcbopts[] =
{
	"variable",	OPTtext,	O(TkLabel, variable),	nil,
	"indicatoron",	OPTstab,	O(TkLabel, indicator),	tkbool,
	"onvalue",	OPTtext,	O(TkLabel, value),	nil,
	"offvalue",	OPTtext,	O(TkLabel, offvalue), nil,
	nil,
};

TkOption tkradopts[] =
{
	"variable",	OPTtext,	O(TkLabel, variable),	nil,
	"value",	OPTtext,	O(TkLabel, value), nil,
	"indicatoron",	OPTstab,	O(TkLabel, indicator),	tkbool,
	nil,
};

static
TkEbind bb[] =
{
	{TkEnter,	"%W configure -state active"},
	{TkLeave,	"%W configure -state normal"},
	{TkButton1P,	"%W tkButton1P"},
	{TkButton1R,	"%W tkButton1R %x %y"},
	{TkMotion|TkButton1P, 	"" },
	{TkKey,	"%W tkButtonKey 0x%K"},
};

static
TkEbind cb[] = 
{
	{TkEnter,		"%W configure -state active"},
	{TkLeave,		"%W configure -state normal"},
	{TkButton1P,		"%W invoke"},
	{TkMotion|TkButton1P, 	"" },
	{TkKey,	"%W tkButtonKey 0x%K"},
};


static char	tkselbut[] = "selectedButton";

static char*	newbutton(TkTop*, int, char*, char**);
static int	istransparent(Tk*);
static void tkvarchanged(Tk*, char*, char*);

char*
tkbutton(TkTop *t, char *arg, char **ret)
{
	return newbutton(t, TKbutton, arg, ret);
}

char*
tkcheckbutton(TkTop *t, char *arg, char **ret)
{
	return newbutton(t, TKcheckbutton, arg, ret);
}

char*
tkradiobutton(TkTop *t, char *arg, char **ret)
{
	return newbutton(t, TKradiobutton, arg, ret);
}

static char*
newbutton(TkTop *t, int btype, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkLabel *tkl;
	TkName *names;
	TkOptab tko[4];
	TkVar *v;

	tk = tkmkbutton(t, btype);
	if(tk == nil)
		return TkNomem;

	tkl = TKobj(TkLabel, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tkl;
	tko[1].optab = tkbutopts;
	switch(btype){
	case TKcheckbutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkcbopts;
		break;
	case TKradiobutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkradopts;
		break;
	default:
		tk->relief = TKraised;
		tk->borderwidth = tkborderwidth(tk, 1);
		tko[2].ptr = nil;
		break;
	}
	tko[3].ptr = nil;

	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}

	tksettransparent(tk, istransparent(tk));
	tksizebutton(tk);

	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;

	if (btype == TKradiobutton &&
			tkl->variable != nil &&
			strcmp(tkl->variable, tkselbut) == 0 &&
			tkl->value == nil &&
			tk->name != nil)
		tkl->value = strdup(tk->name->name);

	if (tkl->variable != nil) {
		v = tkmkvar(t, tkl->variable, 0);
		if (v == nil){
			if(btype == TKcheckbutton){
				e = tksetvar(t, tkl->variable, tkl->offvalue ? tkl->offvalue : "0");
				if (e != nil)
					goto err;
			}
		} else if(v->type != TkVstring){
			e = TkNotvt;
			goto err;
		} else
			tkvarchanged(tk, tkl->variable, v->value);
	}

	return tkvalue(ret, "%s", tk->name->name);

err:
	tkfreeobj(tk);
	return e;
}

Tk*
tkmkbutton(TkTop *t, int btype)
{
	Tk *tk;
	TkLabel *tkl;
	char *e;

	tk = tknewobj(t, btype, sizeof(Tk)+sizeof(TkLabel));
	if (tk == nil)
		return nil;

	e = nil;
	tk->relief = TKraised;
	tk->borderwidth = 0;
	tk->highlightwidth = 1;
	tk->flag |= Tktakefocus;
	tkl = TKobj(TkLabel, tk);
	tkl->ul = -1;
	tkl->justify = Tkleft;

	switch (btype) {
	case TKbutton:
		e = tkbindings(t, tk, bb, nelem(bb));
		break;
	case TKcheckbutton:
		e = tkbindings(t, tk, cb, nelem(cb));
		break;
	case TKradiobutton:
		tkl->variable = strdup(tkselbut);
		e = tkbindings(t, tk, cb, nelem(cb));
		break;
	}

	if (e != nil) {
		print("tkmkbutton internal error: %s\n", e);
		tkfreeobj(tk);
		return nil;
	}
	return tk;
}

/*
 * draw TKbutton, TKcheckbutton, TKradiobutton
 */
char*
tkdrawbutton(Tk *tk, Point orig)
{
 	TkEnv *e;
	TkLabel *tkl;
	Rectangle r, s, mainr, focusr;
	int dx, dy, h;
	Point p, u, v, pp[4];
	Image *i, *dst, *cd, *cl, *ct, *img;
	int relief, bgnd, fgnd;
	TkScene *bsc;

	e = tk->env;

	dst = tkimageof(tk);
	if(dst == nil)
		return nil;

	v.x = tk->act.width + 2*tk->borderwidth;
	v.y = tk->act.height + 2*tk->borderwidth;

	r.min = ZP;
	r.max = v;
	focusr = insetrect(r, tk->borderwidth);
	mainr = insetrect(focusr, tk->highlightwidth);
	relief = tk->relief;

	tkl = TKobj(TkLabel, tk);

	fgnd = TkCforegnd;
	bgnd = TkCbackgnd;
	/*
	 * A push button is a FILLED control sitting on the page, not an
	 * outline drawn on it.  That is what every current system does -
	 * macOS puts a white control on a grey page, Windows and GNOME a
	 * filled grey one - and it is the difference between a button and a
	 * rectangle with a label in it.
	 *
	 * Only the push buttons.  A checkbutton or radiobutton with its
	 * indicator is a LABEL beside a control, so it belongs on the page;
	 * filling it would put a slab behind every line of a list of
	 * options.
	 */
	if (tkstyleflat(tk) && (tk->type == TKbutton || tk->type == TKmenubutton))
		bgnd = TkCfield;
	if (tk->flag & Tkdisabled)
		fgnd = TkCdisablefgnd;
	else if ((tk->type == TKcheckbutton || tk->type == TKradiobutton) && tkl->indicator == BoolF && tkl->check) {
		bgnd = TkCselect;
		/*
		 * Light text on the accent, and this is a contrast defect
		 * rather than a preference.  The foreground here is the
		 * near-black ink, which against #3D6A9A measures 2.80:1 -
		 * WCAG AA asks 4.5:1 for body text.  The field colour gives
		 * 5.63:1.
		 *
		 * It reaches further than the chip it was found on: a
		 * tknotebook(2) tab is an indicator-less radiobutton, so
		 * every chosen tab had the same 2.80:1.
		 *
		 * Left alone under classic, deliberately.  The same defect is
		 * there - it is the same two colours - but classic is the
		 * look this toolkit has always had, kept for compatibility
		 * and asserted unchanged by tkofftest(1); changing it would
		 * be changing the thing it exists to preserve.
		 */
		if (tkstyleflat(tk))
			fgnd = TkCfield;
	}
	else if (tk->flag & Tkactive) {
		fgnd = TkCactivefgnd;
		bgnd = TkCactivebgnd;
	}

	/*
	 * The whole widget as one layer, when it is the simple case: a plain
	 * button with text and no image, a run that reduces to one string(),
	 * and the flat style.  Everything else keeps the scratch-and-blit it
	 * has always used, because the indicator a checkbutton draws and the
	 * bitmap path have no nodes yet.
	 *
	 * Nothing is translated: a button already draws its interior in
	 * coordinates relative to its own top-left, which is exactly what a
	 * layer wants.  The blit at the end becomes the layer's own
	 * composite, so the destination has to be known here rather than
	 * there - it is only tk->act plus orig, which is available either
	 * way.
	 */
	bsc = nil;
	if(tkviascene && tkstyleflat(tk)
	&& (tk->type == TKbutton
		|| ((tk->type == TKradiobutton || tk->type == TKcheckbutton)
			&& tkl->indicator != BoolF))
	&& tkl->img == nil && tkl->bitmap == nil && tkl->text != nil)
		bsc = tkwalkjoin(e->top->ctxt, dst);
	if(bsc != nil){
		Rectangle dr;

		dr = rectaddpt(r, Pt(tk->act.x + orig.x, tk->act.y + orig.y));
		tkscenelayerround(bsc, r.max, e->colors[bgnd], dr, ZP,
			tkscenecorner(tk, relief));
		if(tk->flag & Tkactive)
			tkscenecolour(bsc, r, e->colors[bgnd]);
		i = nil;
	}else{
		i = tkitmp(e, r.max, bgnd);
		if(i == nil)
			return nil;

		if(tk->flag & Tkactive)
			draw(i, r, tkgc(e, bgnd), nil, ZP);
	}

	p = mainr.min;
	h = tkl->h - 2 * tk->highlightwidth;

	dx = tk->act.width - tkl->w - tk->ipad.x;
	dy = tk->act.height - tkl->h - tk->ipad.y;
	if((tkl->anchor & (Tknorth|Tksouth)) == 0)
		p.y += dy/2;
	else if(tkl->anchor & Tksouth)
		p.y += dy;

	if((tkl->anchor & (Tkeast|Tkwest)) == 0)
		p.x += dx/2;
	else if(tkl->anchor & Tkeast)
		p.x += dx;

	switch(tk->type) {
	case TKcheckbutton:
		if(tkl->indicator == BoolF) {
			relief = tkl->check? TKsunken: TKraised;
			break;
		}
		u.x = p.x + ButtonBorder;
		u.y = p.y + ButtonBorder + (h - CheckSpace) / 2;

		cl = tkgc(e, bgnd+TkLightshade);
		cd = tkgc(e, bgnd+TkDarkshade);
		/*
		 * A box that is EMPTY when off and FILLED in the accent when
		 * on, rather than a sunken well with a mark in it.  The tick
		 * below is drawn either way; on the filled box it lands in the
		 * foreground colour against the accent, which is the contrast
		 * a filled checkbox relies on.
		 */
		if(tkstyleflat(tk)) {
			Rectangle cb;

			cb = Rect(u.x, u.y, u.x+CheckButton, u.y+CheckButton);
			if(bsc != nil){
				/* the box: filled when on, a stroke when off */
				if(tkl->check)
					tkscenecolour(bsc, cb,
						e->colors[TkChighlightfgnd]);
				else
					tksceneborder(bsc, cb, 0, CheckButtonBW,
						e->colors[TkCdisablefgnd]);
			}else if(tkl->check)
				draw(i, cb, tkgc(e, TkChighlightfgnd), nil, ZP);
			else
				tkbox(i, cb, CheckButtonBW, tkgc(e, TkCdisablefgnd));
		} else
			tkbevel(i, u, CheckButton, CheckButton, CheckButtonBW, cd, cl);
		if(tkl->check) {
			u.x += CheckButtonBW+1;
			u.y += CheckButtonBW+1;
			pp[0] = u;
			pp[0].y += CheckButton/2-1;
			pp[1] = pp[0];
			pp[1].x += 2;
			pp[1].y += 2;
			pp[2] = u;
			pp[2].x += CheckButton/4;
			pp[2].y += CheckButton-2;
			pp[3] = u;
			pp[3].x += CheckButton-2;
			pp[3].y++;
			/*
			 * On the filled box the tick has to be the LIGHT
			 * colour: drawn in the foreground it is near-black on
			 * the accent, which is the one combination a filled
			 * checkbox must not use.
			 */
			if(bsc != nil)
				tkscenespline(bsc, pp, 4, Enddisc, 1,
					e->colors[tkstyleflat(tk) ?
						TkCbackgnd : TkCforegnd]);
			else
				bezspline(i, pp, 4, Enddisc, Enddisc, 1,
					tkgc(e, tkstyleflat(tk) ? TkCbackgnd : TkCforegnd), ZP);
		}
		break;
	case TKradiobutton:
		if(tkl->indicator == BoolF) {
			relief = tkl->check? TKsunken: TKraised;
			break;
		}
		u.x = p.x + ButtonBorder;
		u.y = p.y + ButtonBorder + (h - CheckSpace) / 2;
		v = Pt(u.x+CheckButton/2,u.y+CheckButton/2);
		if(tkstyleflat(tk)) {
			/*
			 * A ring, filled when chosen.  This is the one shape
			 * in the flat style that is not a rectangle, which is
			 * why the node vocabulary had to grow an ellipse
			 * before a radiobutton could be described by it.
			 */
			if(bsc != nil){
				tksceneellipse(bsc, v,
					Pt(CheckButton/2, CheckButton/2),
					CheckButtonBW, e->colors[tkl->check ?
					TkChighlightfgnd : TkCdisablefgnd]);
				if(tkl->check)
					tksceneellipsefill(bsc, v,
						Pt(CheckButton/2-3, CheckButton/2-3),
						e->colors[TkChighlightfgnd]);
				break;
			}
			ellipse(i, v, CheckButton/2, CheckButton/2, CheckButtonBW,
				tkgc(e, tkl->check ? TkChighlightfgnd : TkCdisablefgnd), ZP);
			if(tkl->check)
				fillellipse(i, v, CheckButton/2-3, CheckButton/2-3,
					tkgc(e, TkChighlightfgnd), ZP);
		} else {
			ellipse(i, v, CheckButton/2, CheckButton/2, CheckButtonBW-1, tkgc(e, bgnd+TkDarkshade), ZP);
			if(tkl->check)
				fillellipse(i, v, CheckButton/2-2, CheckButton/2-2, tkgc(e, TkCforegnd), ZP);	/* could be TkCselect */
		}
		break;
	case TKbutton:
		if ((tk->flag & (Tkactivated|Tkactive)) == (Tkactivated|Tkactive))
			relief = TKsunken;
		break;
	}

	p.x += tk->ipad.x/2;
	p.y += tk->ipad.y/2;
	u = ZP;
	if(tk->type == TKbutton && relief == TKsunken) {
		u.x++;
		u.y++;
	}
	if((tk->type == TKcheckbutton || tk->type == TKradiobutton) && tkl->indicator != BoolF)
		u.x += CheckSpace;

	img = nil;
	if (tkl->img != nil && tkl->img->img != nil)
		img = tkl->img->img;
	else if (tkl->bitmap != nil)
		img = tkl->bitmap;
	if (img != nil) {
		s.min.x = p.x + tkspace(tk)->bitpadx;
		s.min.y = p.y + tkspace(tk)->bitpady;
		s.max.x = s.min.x + Dx(img->r);
		s.max.y = s.min.y + Dy(img->r);
		s = rectaddpt(s, u);
		if(tkchanhastype(img->chan, CGrey))
			draw(i, s, tkgc(e, fgnd), img, ZP);
		else
			draw(i, s, img, nil, ZP);
	} else if(tkl->text != nil) {
		u.x += tkspace(tk)->labelpadx;
		u.y += tkspace(tk)->labelpady;
		ct = tkgc(e, fgnd);
		
		p.y += (h - tkl->textheight) / 2;
		if(bsc != nil)
			tkscenestring(bsc, tk, addpt(u, p), tkl->text,
				tkl->ul, e->colors[fgnd], tkl->justify);
		else
			tkdrawstring(tk, i, addpt(u, p), tkl->text, tkl->ul, ct,
				tkl->justify);
	}

	/*
	 * Which control has the keyboard, shown.
	 *
	 * These two lines were commented out here and are live and identical
	 * in label.c, and entry.c does the same thing a line further down.
	 * So a label and a text field showed their focus and a button did
	 * not - and a button is what a person tabs between. Nothing was
	 * saved by leaving it out: tk->highlightwidth is already 1 for these
	 * widgets and mainr is already inset by it, so the ring has had its
	 * pixel reserved all along and the space was simply left blank.
	 */
	if(bsc != nil){
		/* a focus ring is a square stroke: the same node, radius 0 */
		if(tkhaskeyfocus(tk))
			tksceneborder(bsc, focusr, 0, tk->highlightwidth,
				e->colors[TkChighlightfgnd]);
		tkreliefnodes(bsc, tk, ZP, bgnd, relief);
		tkscenelayerend(bsc);
		tkscenefinish(bsc, e->top->ctxt, dst);
		return nil;
	}

	if(tkhaskeyfocus(tk))
		tkbox(i, focusr, tk->highlightwidth, tkgc(e, TkChighlightfgnd));
	tkdrawrelief(i, tk, ZP, bgnd, relief);

	p.x = tk->act.x + orig.x;
	p.y = tk->act.y + orig.y;
	r = rectaddpt(r, p);
	tkshapedblit(dst, r, i, ZP, tkscenecorner(tk, relief));

	return nil;
}

void
tksizebutton(Tk *tk)
{
	int w, h;
	TkLabel *tkl;
	
	tkl = TKobj(TkLabel, tk);
	if(tkl->anchor == 0)	
		tkl->anchor = Tkcenter;

	tksizelabel(tk);	/* text, bitmap or image, and highlight */
	w = tkl->w;
	h = tkl->h;

	if((tk->type == TKcheckbutton || tk->type == TKradiobutton) && tkl->indicator != BoolF) {
		w += CheckSpace;
		if(h < CheckSpace)
			h = CheckSpace;
	}
	tkl->w = w;
	tkl->h = h;
	if((tk->flag & Tksetwidth) == 0)
		tk->req.width = w;
	if((tk->flag & Tksetheight) == 0)
		tk->req.height = h;
}

int
tkbuttonmargin(Tk *tk)
{
	TkLabel *tkl;
	tkl = TKobj(TkLabel, tk);

	switch (tk->type) {
	case TKbutton:
		if (tkl->img != nil || tkl->bitmap != nil)
			return 0;
		return tkspace(tk)->labelpadx+tk->highlightwidth;
	case TKcheckbutton:
	case TKradiobutton:
		return CheckButton + 2*CheckButtonBW + 2*ButtonBorder;
	}
	return tklabelmargin(tk);
}

void
tkfreebutton(Tk *tk)
{
	tkfreelabel(tk);
}

static char*
tkbuttoncget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[4];
	TkLabel *tkl = TKobj(TkLabel, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tkl;
	tko[1].optab = tkbutopts;
	switch(tk->type){
	case TKcheckbutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkcbopts;
		break;
	case TKradiobutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkradopts;
		break;
	default:
		tko[2].ptr = nil;
		break;
	}
	tko[3].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
tkbuttonconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[4];
	TkVar *v;
	TkLabel *tkl = TKobj(TkLabel, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tkl;
	tko[1].optab = tkbutopts;
	switch(tk->type){
	case TKcheckbutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkcbopts;
		break;
	case TKradiobutton:
		tko[2].ptr = tkl;
		tko[2].optab = tkradopts;
		break;
	default:
		tko[2].ptr = nil;
		break;
	}
	tko[3].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);

	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	tksizebutton(tk);
	tkgeomchg(tk, &g, bd);

	tk->dirty = tkrect(tk, 1);
	tksettransparent(tk, istransparent(tk));
	/*
	 * XXX what happens if we're now disabled, but we were in
	 * active state before?
	 */
	if (tkl->variable != nil) {
		v = tkmkvar(tk->env->top, tkl->variable, 0);
		if (v != nil) {
			if (v->type != TkVstring) {
				e = TkNotvt;
				free(tkl->variable);
				tkl->variable = nil;
			}
			else
				tkvarchanged(tk, tkl->variable, v->value);
		}
	}
	return e;
}

static int
istransparent(Tk *tk)
{
	TkEnv *e = tk->env;
	return (tkhasalpha(e, TkCbackgnd) || tkhasalpha(e, TkCselectbgnd) || tkhasalpha(e, TkCactivebgnd));
}

static void
tkvarchanged(Tk *tk, char *var, char *val)
{
	TkLabel *tkl;
	char *sval;

	tkl = TKobj(TkLabel, tk);
	if (tkl->variable != nil && strcmp(tkl->variable, var) == 0) {
		sval = tkl->value;
		if (sval == nil)
			sval = tk->type == TKcheckbutton ? "1" : "";
		tkl->check = (strcmp(val, sval) == 0);
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
	}
}

static char*
tkbutton1p(Tk *tk, char *arg, char **val)
{
	USED(arg);
	USED(val);
	if(tk->flag & Tkdisabled)
		return nil;
	tk->flag |= Tkactivated;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
tkbutton1r(Tk *tk, char *arg, char **val)
{
	char *e;
	Point p;
	Rectangle hitr;

	USED(arg);

	if(tk->flag & Tkdisabled)
		return nil;
	e = tkxyparse(tk, &arg, &p);
	if (e == nil) {
		hitr.min = ZP;
		hitr.max.x = tk->act.width + tk->borderwidth*2;
		hitr.max.y = tk->act.height + tk->borderwidth*2;
		if(ptinrect(p, hitr) && (tk->flag & Tkactivated))
			e = tkbuttoninvoke(tk, nil, val);
	}
	tk->flag &= ~Tkactivated;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return e;
}

static char*
tkbuttonkey(Tk *tk, char *arg, char **val)
{
	int key;

	if(tk->flag & Tkdisabled)
		return nil;

	key = strtol(arg, nil, 0);
	if (key == '\n' || key ==' ')
		return tkbuttoninvoke(tk, nil, val);
	return nil;
}

static char*
tkbuttontoggle(Tk *tk, char *arg, char **val)
{
	char *e;
	TkLabel *tkl = TKobj(TkLabel, tk);
	char *v;

	USED(arg);
	USED(val);
	if(tk->flag & Tkdisabled)
		return nil;
	tkl->check = !tkl->check;
	if (tkl->check)
		v = tkl->value ? tkl->value : "1";
	else
		v = tkl->offvalue ? tkl->offvalue : "0";
	e = tksetvar(tk->env->top, tkl->variable, v);
	tk->dirty = tkrect(tk, 0);
	return e;
}

static char*
buttoninvoke(Tk *tk, char **val)
{
	char *e = nil;
	TkTop *top;
	TkLabel *tkl = TKobj(TkLabel, tk);

	top = tk->env->top;
	if (tk->type == TKcheckbutton)
		e = tkbuttontoggle(tk, "", val);
	else if (tk->type == TKradiobutton)
		e = tksetvar(top, tkl->variable, tkl->value);
	if(e != nil)
		return e;
	if(tk->type == TKcheckbutton || tk->type == TKradiobutton)
		tkannouncechange(tk);	/* voice(3); see man 3 voice */
	if(tkl->command != nil)
		return tkexec(tk->env->top, tkl->command, val);
	return nil;
}

static void
cancelinvoke(Tk *tk, void *v, int cancelled)
{
	int unset;
	USED(cancelled);
	USED(v);

	/* if it was active before then leave it active unless cleared since */
	if (v)
		unset = 0;
	else
		unset = Tkactive;
	unset &= (tk->flag & Tkactive);
	unset |= Tkactivated;
	tk->flag &= ~unset;
	tksettransparent(tk, istransparent(tk));
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	tkupdate(tk->env->top);
}

char*
tkbuttoninvoke(Tk *tk, char *arg, char **val)
{
	char *e;
	USED(arg);

	if(tk->flag & Tkdisabled)
		return nil;
	e = buttoninvoke(tk, val);
	if (e == nil && tk->type == TKbutton && !(tk->flag & Tkactivated)) {
		tkrepeat(tk, cancelinvoke, (void*)(tk->flag&Tkactive), InvokePause, 0);
		tk->flag |= Tkactivated | Tkactive;
		tksettransparent(tk, istransparent(tk));
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
		tkupdate(tk->env->top);
	}
	return e;
}

static char*
tkbuttonselect(Tk *tk, char *arg, char **val)
{
	char *e, *v;
	TkLabel *tkl = TKobj(TkLabel, tk);

	USED(arg);
	USED(val);
	if (tk->type == TKradiobutton)
		v = tkl->value;
	else if (tk->type == TKcheckbutton) {
		v = tkl->value ? tkl->value : "1";
		tkl->check = 1;
		tk->dirty = tkrect(tk, 0);
	} else
		v = nil;
	e = tksetvar(tk->env->top, tkl->variable, v);
	if(e != nil)
		return e;
	return nil;
}

static char*
tkbuttondeselect(Tk *tk, char *arg, char **val)
{
	char *e, *v;
	TkLabel *tkl = TKobj(TkLabel, tk);

	USED(arg);
	USED(val);

	if (tk->type == TKcheckbutton) {
		v = tkl->offvalue ? tkl->offvalue : "0";
		tkl->check = 0;
		tk->dirty = tkrect(tk, 0);
	} else
		v = nil;

	e = tksetvar(tk->env->top, tkl->variable, v);
	if(e != nil)
		return e;
	return nil;
}

static
TkCmdtab tkbuttoncmd[] =
{
	"cget",			tkbuttoncget,
	"configure",		tkbuttonconf,
	"invoke",		tkbuttoninvoke,
	"tkButton1P",		tkbutton1p,
	"tkButton1R",		tkbutton1r,
	"tkButtonKey",		tkbuttonkey,
	nil
};

static
TkCmdtab tkchkbuttoncmd[] =
{
	"cget",			tkbuttoncget,
	"configure",		tkbuttonconf,
	"invoke",		tkbuttoninvoke,
	"select",		tkbuttonselect,
	"deselect",		tkbuttondeselect,
	"toggle",		tkbuttontoggle,
	"tkButtonKey",		tkbuttonkey,
	nil
};

static
TkCmdtab tkradbuttoncmd[] =
{
	"cget",			tkbuttoncget,
	"configure",		tkbuttonconf,
	"invoke",		tkbuttoninvoke,
	"select",		tkbuttonselect,
	"deselect",		tkbuttondeselect,
	"tkButtonKey",		tkbuttonkey,
	nil
};

TkMethod buttonmethod = {
	"button",
	tkbuttoncmd,
	tkfreebutton,
	tkdrawbutton,
	nil,
	tklabelgetimgs
};

TkMethod checkbuttonmethod = {
	"checkbutton",
	tkchkbuttoncmd,
	tkfreebutton,
	tkdrawbutton,
	nil,
	tklabelgetimgs,
	nil,
	nil,
	nil,
	nil,
	nil,
	nil,
	tkvarchanged
};

TkMethod radiobuttonmethod = {
	"radiobutton",
	tkradbuttoncmd,
	tkfreebutton,
	tkdrawbutton,
	nil,
	nil,
	nil,
	nil,
	nil,
	nil,
	nil,
	nil,
	tkvarchanged
};
