#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "frame.h"

char*
tkframe(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkOptab tko[2];
	TkName *names;

	tk = tknewobj(t, TKframe, sizeof(Tk));
	if(tk == nil)
		return TkNomem;

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = nil;
	names = nil;

	e = tkparse(t, arg, tko, &names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));

	e = tkaddchild(t, tk, &names);

	tkfreename(names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;

	return tkvalue(ret, "%s", tk->name->name);
}

/*
 * Also used for windows, menus, separators
 */
void
tkfreeframe(Tk *tk)
{
	TkWin *tkw;

	if((tk->flag & Tkwindow) == 0)
		return;

	if(tk->type == TKmenu) {
		tkw = TKobj(TkWin, tk);
		free(tkw->postcmd);
		free(tkw->cascade);
		free(tkw->cbname);
	}

	tkunmap(tk);		/* XXX do this only if (tk->flag&Tkswept)==0 ?? */
}

char*
tkdrawframe(Tk *tk, Point orig)
{	
	int bw;
	Point p;
	Image *i;
	Tk *f;
	TkScene *framescene;
	Rectangle framebox;
	Point off;
	Rectangle r, slaver;		/* dribbling, whipping or just square? */

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	
	p.x = orig.x + tk->act.x + tk->borderwidth;
	p.y = orig.y + tk->act.y + tk->borderwidth;

	/*
	 * A frame is the first widget whose WHOLE appearance can be a scene,
	 * and that is why it is the one done first.  It draws straight into
	 * its parent's image with no temporary and no blit, and its fill and
	 * its border are adjacent with no content drawn between them - so the
	 * three nodes below are the entire widget, in paint order, and the
	 * border node needs no colour for what shows outside the corner.
	 *
	 * That argument to tksceneborder() exists only because every OTHER
	 * widget fills its whole rectangle, then draws text, then asks
	 * tkdrawrelief() for a border - by which point the corner is already
	 * wrong and the only thing that can be done is to paint it back.  A
	 * widget described entirely by nodes never has that problem, which
	 * is the point of describing one entirely by nodes.
	 *
	 * Behind tkviascene, so nothing in a running system takes this path
	 * until it has been compared against the other one.
	 */
	framescene = nil;
	if(tkviascene && tkstyleflat(tk) && tk->type == TKframe)
		framescene = tkscenenew();
	if(framescene != nil){
		ulong own, par;
		TkEnv *pe;

		/*
		 * The box tkdrawrelief() would be given: its origin is the
		 * widget's own position, NOT the content origin, and its size
		 * includes the border on both sides.  Computed here once and
		 * used for both nodes - the first attempt built it with
		 * rectaddpt(tkrect(tk,1), p), which adds the border offset a
		 * second time and drew the whole frame one border-width up and
		 * to the left.  1044 pixels, found by the byte comparison.
		 */
		framebox = Rect(orig.x + tk->act.x, orig.y + tk->act.y, 0, 0);
		framebox.max.x = framebox.min.x + tk->act.width + 2*tk->borderwidth;
		framebox.max.y = framebox.min.y + tk->act.height + 2*tk->borderwidth;
		own = tk->env->colors[TkCbackgnd];
		pe = tkbehind(tk);
		par = pe->colors[TkCbackgnd];
		/*
		 * Through a LAYER: the nodes below are rendered into a scratch
		 * and the result blitted back to where they would have gone.
		 *
		 * A frame has no need of one - it draws straight into its
		 * parent's image - which is exactly why it is the thing to
		 * prove the layer node on.  The result has to be identical to
		 * rendering the same nodes in place, so any error in the
		 * scratch's extent or the blit's offset shows up as a
		 * difference rather than as a widget that merely looks fine.
		 * Every widget that genuinely needs a layer uses tkitmp and
		 * draws with something other than nodes, so none of them could
		 * have told us whether this worked.
		 *
		 * Nodes inside are in layer-local coordinates, hence the
		 * translation by -framebox.min.
		 */
		off = Pt(-framebox.min.x, -framebox.min.y);
		tkscenelayer(framescene,
			Pt(framebox.max.x - framebox.min.x,
			   framebox.max.y - framebox.min.y),
			par, framebox, ZP);
		{
			Rectangle fr;

			fr = rectaddpt(tk->dirty, p);
			if(rectclip(&fr, framebox))
				tkscenecolour(framescene, rectaddpt(fr, off), par);
		}
		tksceneroundfill(framescene, rectaddpt(framebox, off),
			tkspace(tk)->corner, own);
	}else
		draw(i, rectaddpt(tk->dirty, p), tkgc(tk->env, TkCbackgnd), nil, ZP);

	/*
	 * doesn't matter about drawing TKseparator
	 * oblivious of dirty rect, as it never has any children to sully anyway
	 */
	if(tk->type == TKseparator) {
		r = rectaddpt(tkrect(tk, 1), p);
		r.min.x += 4;
		r.max.x -= 4;
		r.min.y += (Dy(r) - 2)/2;
		r.max.y = r.min.y+1;
		draw(i, r, tkgc(tk->env, TkCbackgnddark), nil, ZP);
		r.min.y += 1;
		r.max.y += 1;
		draw(i, r, tkgc(tk->env, TkCbackgndlght), nil, ZP);
		return nil;
	}

	/*
	 * make sure all the slaves inside the area we've just drawn
	 * refresh themselves properly.
	 */
	for(f = tk->slave; f; f = f->next) {
		bw = f->borderwidth;
		slaver.min.x = f->act.x;
		slaver.min.y = f->act.y;
		slaver.max.x = slaver.min.x + f->act.width + 2*bw;
		slaver.max.y = slaver.min.y + f->act.height + 2*bw;
		if (rectclip(&slaver, tk->dirty)) {
			f->flag |= Tkrefresh;
			slaver = rectsubpt(slaver, Pt(f->act.x + bw, f->act.y + bw));
			combinerect(&f->dirty, slaver);
		}
	}
	p.x -= tk->borderwidth;
	p.y -= tk->borderwidth;

	if(framescene != nil){
		if(!rectinrect(tk->dirty, tkrect(tk, 0)) && tk->relief != TKflat
		&& tk->borderwidth > 0)
			tksceneborder(framescene,
				rectaddpt(framebox, Pt(-framebox.min.x, -framebox.min.y)),
				tkspace(tk)->corner,
				tk->borderwidth,
				tk->env->colors[TkCbackgnd+TkDarkshade]);
		tkscenelayerend(framescene);
		tkscenerender(framescene, tk->env->top->ctxt, i);
		tkscenefree(framescene);
		return nil;
	}
	if (!rectinrect(tk->dirty, tkrect(tk, 0)))
		tkdrawrelief(i, tk, p, TkCbackgnd, tk->relief);
	return nil;
}

/* Frame commands */

static char*
tkframecget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = nil;
	if(tk->flag & Tkwindow){
		tko[1].ptr = TKobj(TkWin, tk);
		tko[1].optab = tktop;
		tko[2].ptr = nil;
	}

	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
tkframeconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	Point oldp;
	TkOptab tko[3];
	TkWin *tkw;

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = nil;
	tkw = nil;
	if(tk->flag & Tkwindow) {
		tkw = TKobj(TkWin, tk);
		tko[1].ptr = tkw;
		tko[1].optab = tktop;
		tko[2].ptr = nil;
		oldp = tkw->act;
	}

	if(*arg == '\0')
		return tkconflist(tko, val);

	if(tkw != nil){
		/*
		 * see whether only -x or -y is being configured,
		 * in which case just move the window; don't redraw
		 * everything
		 */
		e = tkparse(tk->env->top, arg, &tko[1], nil);
		if(e == nil){
			if(!eqpt(oldp, tkw->req))
				tkmovewin(tk, tkw->req);
			return nil;
		}
	}

	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));
	tk->req.x = tk->act.x;
	tk->req.y = tk->act.y;
	tkgeomchg(tk, &g, bd);
	if(tkw != nil && !eqpt(oldp, tkw->act))
		tkmovewin(tk, tkw->req);

	tk->dirty = tkrect(tk, 1);

	return e;
}

static char*
tkframesuspend(Tk *tk, char *arg, char **val)
{
	USED(arg);
	USED(val);
	if((tk->flag & Tkwindow) == 0)
		return TkNotwm;
	tk->flag |= Tksuspended;
	return nil;
}

static char*
tkframemap(Tk *tk, char *arg, char **val)
{
	USED(arg);
	USED(val);
	if(tk->flag & Tkwindow)
		return tkmap(tk);
	return TkNotwm;
}

static char*
tkframeunmap(Tk *tk, char *arg, char **val)
{
	USED(arg);
	USED(val);
	if(tk->flag & Tkwindow) {
		tkunmap(tk);
		return nil;
	}
	return TkNotwm;
}

static void
tkframefocusorder(Tk *tk)
{
	int i, n;
	Tk *sub;
	TkWinfo *inf;

	n = 0;
	for (sub = tk->slave; sub != nil; sub = sub->next)
		n++;

	if (n == 0)
		return;

	inf = malloc(sizeof(*inf) * n);
	if (inf == nil)
		return;
	i = 0;
	for (sub = tk->slave; sub != nil; sub = sub->next) {
		inf[i].w = sub;
		inf[i].r = rectaddpt(tkrect(sub, 1), Pt(sub->act.x, sub->act.y));
		i++;
	}
	tksortfocusorder(inf, n);
	for (i = 0; i < n; i++)
		tkappendfocusorder(inf[i].w);
	free(inf);
}

static
TkCmdtab tkframecmd[] =
{
	"cget",			tkframecget,
	"configure",		tkframeconf,
	"map",			tkframemap,
	"unmap",		tkframeunmap,
	"suspend",		tkframesuspend,
	nil
};

TkMethod framemethod = {
	"frame",
	tkframecmd,
	tkfreeframe,
	tkdrawframe,
	nil,
	nil,
	tkframefocusorder
};
