#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	<draw.h>
#include	<memdraw.h>
#include	<memlayer.h>
#include	<cursor.h>
//#include	"screen.h"

enum
{
	Qtopdir		= 0,
	Qnew,
	Q3rd,
	Q2nd,
	Qcolormap,
	Qctl,
	Qdata,
	Qrefresh
};

/*
 * Qid path is:
 *	 4 bits of file type (qids above)
 *	24 bits of mux slot number +1; 0 means not attached to client
 */
#define	QSHIFT	4	/* location in qid of client # */

#define	QID(q)		((((u32)(q).path)&0x0000000F)>>0)
#define	CLIENTPATH(q)	((((u32)q)&0x7FFFFFF0)>>QSHIFT)
#define	CLIENT(q)	CLIENTPATH((q).path)

#define	NHASH		(1<<5)
#define	HASHMASK	(NHASH-1)
#define	DRAWIOUNIT	(64*1024)

typedef struct Client Client;
typedef struct Draw Draw;
typedef struct DImage DImage;
typedef struct DScreen DScreen;
typedef struct CScreen CScreen;
typedef struct FChar FChar;
typedef struct Refresh Refresh;
typedef struct Refx Refx;
typedef struct DName DName;

u32 blanktime = 30;	/* in minutes; a half hour */

struct Draw
{
	/* Plain spinlock, not QLock: drawscreenrebind() is called directly
	 * from the native host's window-resize callback (win-cocoa.m's
	 * screenresize(), on the OS UI thread) rather than from an Inferno
	 * kproc, so the thread-local `up` QLock's blocked/queued path
	 * dereferences is nil there. That only crashed when this lock was
	 * actually contended - i.e. exactly when the interpreter thread
	 * was mid-critical-section here at the moment of a host resize -
	 * which is why it was an intermittent, resize-triggered fault
	 * ("dereference of nil" / "bad address" depending on scheduling)
	 * rather than a deterministic one. Every use of this lock already
	 * releases it before any blocking call (see the Qrefresh case
	 * below, which explicitly unlocks before Sleep()), so a spinlock
	 * costs nothing here and is safe from any thread.
	 */
	Lock	q;
	s32		clientid;
	s32		nclient;
	Client**	client;
	s32		nname;
	DName*	name;
	s32		vers;
	s32		softscreen;
	s32		blanked;	/* screen turned off */
	u32		blanktime;	/* time of last operation */
	u32		savemap[3*256];
};

struct Client
{
	Ref		r;
	DImage*		dimage[NHASH];
	CScreen*	cscreen;
	Refresh*	refresh;
	Rendez		refrend;
	uchar*		readdata;
	s32		nreaddata;
	s32		busy;
	s32		clientid;
	s32		slot;
	s32		refreshme;
	s32		infoid;
	s32	op;	/* compositing operator - SoverD by default */
	/* Optional draw3d protocol state (letters 3/M/w/u/z/g/G/h/j/k). */
	float		d3model[16];
	float		d3proj[16];
	float		d3mx, d3cx, d3my, d3cy;
	int		d3zenable;
	int		d3clipbehind;
	int		*d3zbuf;
	int		d3zw, d3zh;
	Rectangle	d3zr;
};

struct Refresh
{
	DImage*		dimage;
	Rectangle	r;
	Refresh*	next;
};

struct Refx
{
	Client*		client;
	DImage*		dimage;
};

struct DName
{
	char			*name;
	Client	*client;
	DImage*		dimage;
	s32			vers;
};

struct FChar
{
	s32		minx;	/* left edge of bits */
	s32		maxx;	/* right edge of bits */
	uchar		miny;	/* first non-zero scan-line */
	uchar		maxy;	/* last non-zero scan-line + 1 */
	schar		left;	/* offset of baseline */
	uchar		width;	/* width of baseline */
};

/*
 * Reference counts in DImages:
 *	one per open by original client
 *	one per screen image or fill
 * 	one per image derived from this one by name
 */
struct DImage
{
	s32		id;
	s32		ref;
	char		*name;
	s32		vers;
	Memimage*	image;
	s32		ascent;
	s32		nfchar;
	FChar*		fchar;
	DScreen*	dscreen;	/* 0 if not a window */
	DImage*	fromname;	/* image this one is derived from, by name */
	DImage*		next;
};

struct CScreen
{
	DScreen*	dscreen;
	CScreen*	next;
};

struct DScreen
{
	s32		id;
	s32		public;
	s32		ref;
	DImage	*dimage;
	DImage	*dfill;
	Memscreen*	screen;
	Client*		owner;
	DScreen*	next;
};

static	Draw		sdraw;
	Memimage	*screenimage;	/* accessed by some win-*.c */
static	Memdata	screendata;
static	Rectangle	flushrect;
static	int		waste;
static	DScreen*	dscreen;
extern	void	drawdisplayresize(Rectangle);
extern	void		flushmemscreen(Rectangle);
	void		drawmesg(Client*, void*, int);

/* Cocoa Metal (win-cocoa.m) assigns these; nil ⇒ software memline/memfillpoly. */
int	(*gpudrawline)(Memimage*, Point, Point, int, Memimage*, int, float, float);
int	(*gpudrawfillpoly)(Memimage*, Point*, float*, int, Memimage*, int, float);
/* GPU does model*proj+viewport itself; vx/vy/vz are raw model-space, post
 * near-clip. nil ⇒ not hooked (Cocoa always hooks it alongside gpudrawfillpoly)
 * or this call wasn't eligible (op/dst/src) - caller falls back to the
 * per-vertex d3project() + gpudrawfillpoly/memfillpoly path either way. */
int	(*gpudrawfillpoly3d)(Memimage*, float*, float*, float*, int, Memimage*, int,
	float, float*, float*, float, float, float, float);
int	(*gpudrawplot)(Memimage*, Point, Memimage*, int, float);
int	(*gpudrawsprite)(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
int	(*gpudrawellipse)(Memimage*, Point, int, int, int, int, Memimage*, int, float);
void	(*gpudrawflush)(void);
void	(*gpudrawreadback)(void);
void	(*gpudrawzclear)(void);
void	(*gpudrawzenable)(int);
void	(*gpudrawdamage)(Rectangle);
int	(*gpudrawflushdamage)(Rectangle);
	void		drawuninstall(Client*, int);
	void		drawfreedimage(DImage*);
	Client*		drawclientofpath(ulong);
static int	drawclientop(Client*);

static	char Enodrawimage[] =	"unknown id for draw image";
static	char Enodrawscreen[] =	"unknown id for draw screen";
static	char Eshortdraw[] =	"short draw message";
static	char Eshortread[] =	"draw read too short";
static	char Eimageexists[] =	"image id in use";
static	char Escreenexists[] =	"screen id in use";
static	char Edrawmem[] =	"out of memory: image";
static	char Ereadoutside[] =	"readimage outside image";
static	char Ewriteoutside[] =	"writeimage outside image";
static	char Enotfont[] =	"image not a font";
static	char Eindex[] =		"character index out of range";
static	char Enoclient[] =	"no such draw client";
static	char Enameused[] =	"image name in use";
static	char Enoname[] =	"no image with that name";
static	char Eoldname[] =	"named image no longer valid";
static	char Enamed[] = 	"image already has name";
static	char Ewrongname[] = 	"wrong name for image";

static int
drawgen(Chan *c, char *name, Dirtab *tab, int x, int s, Dir *dp)
{
	int t;
	Qid q;
	ulong path;
	Client *cl;

	USED(name);
	USED(tab);
	USED(x);
	q.vers = 0;

	if(s == DEVDOTDOT){
		switch(QID(c->qid)){
		case Qtopdir:
		case Q2nd:
			mkqid(&q, Qtopdir, 0, QTDIR);
			devdir(c, q, "#i", 0, eve, 0500, dp);
			break;
		case Q3rd:
			cl = drawclientofpath(c->qid.path);
			if(cl == nil)
				strcpy(up->genbuf, "??");
			else
				sprint(up->genbuf, "%d", cl->clientid);
			mkqid(&q, Q2nd, 0, QTDIR);
			devdir(c, q, up->genbuf, 0, eve, 0500, dp);
			break;
		default:
			panic("drawwalk %llux", c->qid.path);
		}
		return 1;
	}

	/*
	 * Top level directory contains the name of the device.
	 */
	t = QID(c->qid);
	if(t == Qtopdir){
		switch(s){
		case 0:
			mkqid(&q, Q2nd, 0, QTDIR);
			devdir(c, q, "draw", 0, eve, 0555, dp);
			break;
		default:
			return -1;
		}
		return 1;
	}

	/*
	 * Second level contains "new" plus all the clients.
	 */
	if(t == Q2nd || t == Qnew){
		if(s == 0){
			mkqid(&q, Qnew, 0, QTFILE);
			devdir(c, q, "new", 0, eve, 0666, dp);
		}
		else if(s <= sdraw.nclient){
			cl = sdraw.client[s-1];
			if(cl == 0)
				return 0;
			sprint(up->genbuf, "%d", cl->clientid);
			mkqid(&q, (s<<QSHIFT)|Q3rd, 0, QTDIR);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		else
			return -1;
		return 1;
	}

	/*
	 * Third level.
	 */
	path = c->qid.path&~((1<<QSHIFT)-1);	/* slot component */
	q.vers = c->qid.vers;
	q.type = QTFILE;
	switch(s){
	case 0:
		q.path = path|Qcolormap;
		devdir(c, q, "colormap", 0, eve, 0600, dp);
		break;
	case 1:
		q.path = path|Qctl;
		devdir(c, q, "ctl", 0, eve, 0600, dp);
		break;
	case 2:
		q.path = path|Qdata;
		devdir(c, q, "data", 0, eve, 0600, dp);
		break;
	case 3:
		q.path = path|Qrefresh;
		devdir(c, q, "refresh", 0, eve, 0400, dp);
		break;
	default:
		return -1;
	}
	return 1;
}

static
int
drawrefactive(void *a)
{
	Client *c;

	c = a;
	return c->refreshme || c->refresh!=0;
}

static
void
drawrefreshscreen(DImage *l, Client *client)
{
	while(l != nil && l->dscreen == nil)
		l = l->fromname;
	if(l != nil && l->dscreen->owner != client)
		l->dscreen->owner->refreshme = 1;
}

static
void
drawrefresh(Memimage *l, Rectangle r, void *v)
{
	Refx *x;
	DImage *d;
	Client *c;
	Refresh *ref;

	USED(l);
	if(v == 0)
		return;
	x = v;
	c = x->client;
	d = x->dimage;
	for(ref=c->refresh; ref; ref=ref->next)
		if(ref->dimage == d){
			combinerect(&ref->r, r);
			return;
		}
	ref = malloc(sizeof(Refresh));
	if(ref){
		ref->dimage = d;
		ref->r = r;
		ref->next = c->refresh;
		c->refresh = ref;
	}
}

static void
addflush(Rectangle r)
{
	if(sdraw.softscreen==0 || !rectclip(&r, screenimage->r))
		return;
	if(gpudrawdamage)
		gpudrawdamage(r);

	/*
	 * Softscreen present is deferred until drawflush ('v' / Flushnow).
	 * Emitting mid-batch (old waste heuristic) presented half-composed
	 * frames during Flushoff line storms (Castle wireframe blink).
	 * Cocoa already coalesces presents; union the dirty rect only.
	 */
	if(flushrect.min.x >= flushrect.max.x){
		flushrect = r;
		waste = 0;
		return;
	}
	combinerect(&flushrect, r);
}

static
void
dstflush(Memimage *dst, Rectangle r)
{
	Memlayer *l;

	/* Drawing primitives clip to the destination, but their conservative
	 * bounding boxes can extend far beyond it (notably projected 3D lines).
	 * Keep those bounds from expanding softscreen damage outside the image. */
	if(!rectclip(&r, dst->clipr))
		return;
	if(dst == screenimage){
		if(gpudrawdamage)
			gpudrawdamage(r);
		combinerect(&flushrect, r);
		return;
	}
	l = dst->layer;
	if(l == nil)
		return;
	do{
		if(l->screen->image->data != screenimage->data)
			return;
		r = rectaddpt(r, l->delta);
		l = l->screen->image->layer;
	}while(l);
	addflush(r);
}

static
void
drawflush(void)
{
	if(gpudrawflush)
		gpudrawflush();
	if(flushrect.min.x < flushrect.max.x){
		if(gpudrawflushdamage == nil || !gpudrawflushdamage(flushrect))
			flushmemscreen(flushrect);
	}
	flushrect = Rect(10000, 10000, -10000, -10000);
}

static
int
drawcmp(char *a, char *b, int n)
{
	if(strlen(a) != n)
		return 1;
	return memcmp(a, b, n);
}

DName*
drawlookupname(int n, char *str)
{
	DName *name, *ename;

	name = sdraw.name;
	ename = &name[sdraw.nname];
	for(; name<ename; name++)
		if(drawcmp(name->name, str, n) == 0)
			return name;
	return 0;
}

int
drawgoodname(DImage *d)
{
	DName *n;

	/* if window, validate the screen's own images */
	if(d->dscreen)
		if(drawgoodname(d->dscreen->dimage) == 0
		|| drawgoodname(d->dscreen->dfill) == 0)
			return 0;
	if(d->name == nil)
		return 1;
	n = drawlookupname(strlen(d->name), d->name);
	if(n==nil || n->vers!=d->vers)
		return 0;
	return 1;
}

DImage*
drawlookup(Client *client, int id, int checkname)
{
	DImage *d;

	d = client->dimage[id&HASHMASK];
	while(d){
		if(d->id == id){
			if(checkname && !drawgoodname(d))
				error(Eoldname);
			return d;
		}
		d = d->next;
	}
	return 0;
}

DScreen*
drawlookupdscreen(int id)
{
	DScreen *s;

	s = dscreen;
	while(s){
		if(s->id == id)
			return s;
		s = s->next;
	}
	return 0;
}

DScreen*
drawlookupscreen(Client *client, int id, CScreen **cs)
{
	CScreen *s;

	s = client->cscreen;
	while(s){
		if(s->dscreen->id == id){
			*cs = s;
			return s->dscreen;
		}
		s = s->next;
	}
	error(Enodrawscreen);
	return 0;
}

Memimage*
drawinstall(Client *client, int id, Memimage *i, DScreen *dscreen)
{
	DImage *d;

	d = malloc(sizeof(DImage));
	if(d == 0)
		return 0;
	d->id = id;
	d->ref = 1;
	d->name = 0;
	d->vers = 0;
	d->image = i;
	d->nfchar = 0;
	d->fchar = 0;
	d->fromname = 0;
	d->dscreen = dscreen;
	d->next = client->dimage[id&HASHMASK];
	client->dimage[id&HASHMASK] = d;
	return i;
}

Memscreen*
drawinstallscreen(Client *client, DScreen *d, int id, DImage *dimage, DImage *dfill, int public)
{
	Memscreen *s;
	CScreen *c;

	c = malloc(sizeof(CScreen));
	if(dimage && dimage->image && dimage->image->chan == 0)
		panic("bad image %p in drawinstallscreen", dimage->image);

	if(c == 0)
		return 0;
	if(d == 0){
		d = malloc(sizeof(DScreen));
		if(d == 0){
			free(c);
			return 0;
		}
		s = malloc(sizeof(Memscreen));
		if(s == 0){
			free(c);
			free(d);
			return 0;
		}
		s->frontmost = 0;
		s->rearmost = 0;
		d->dimage = dimage;
		if(dimage){
			s->image = dimage->image;
			AINC(&dimage->ref);
		}
		d->dfill = dfill;
		if(dfill){
			s->fill = dfill->image;
			AINC(&dfill->ref);
		}
		d->ref = 0;
		d->id = id;
		d->screen = s;
		d->public = public;
		d->next = dscreen;
		d->owner = client;
		dscreen = d;
	}
	c->dscreen = d;
	AINC(&d->ref);
	c->next = client->cscreen;
	client->cscreen = c;
	return d->screen;
}

void
drawdelname(DName *name)
{
	int i;

	i = name-sdraw.name;
	memmove(name, name+1, (sdraw.nname-(i+1))*sizeof(DName));
	sdraw.nname--;
}

void
drawfreedscreen(DScreen *this)
{
	DScreen *ds, *next;
	int nr;

	nr = ADEC(&this->ref);
	if(nr < 0)
		print("negative ref in drawfreedscreen\n");
	if(nr > 0)
		return;
	ds = dscreen;
	if(ds == this){
		dscreen = this->next;
		goto Found;
	}
	while(next = ds->next){	/* assign = */
		if(next == this){
			ds->next = this->next;
			goto Found;
		}
		ds = next;
	}
	error(Enodrawimage);

    Found:
	if(this->dimage)
		drawfreedimage(this->dimage);
	if(this->dfill)
		drawfreedimage(this->dfill);
	free(this->screen);
	free(this);
}

void
drawfreedimage(DImage *dimage)
{
	int i;
	Memimage *l;
	DScreen *ds;
	int nr;

	nr = ADEC(&dimage->ref);
	if(nr < 0)
		print("negative ref in drawfreedimage\n");
	if(nr > 0)
		return;

	/* any names? */
	for(i=0; i<sdraw.nname; )
		if(sdraw.name[i].dimage == dimage)
			drawdelname(sdraw.name+i);
		else
			i++;
	if(dimage->fromname){	/* acquired by name; owned by someone else*/
		drawfreedimage(dimage->fromname);
		goto Return;
	}
	if(dimage->image == screenimage)	/* don't free the display */
		goto Return;
	ds = dimage->dscreen;
	if(ds){
		l = dimage->image;
		if(l->data == screenimage->data)
			dstflush(l->layer->screen->image, l->layer->screenr);
		if(l->layer->refreshfn == drawrefresh)	/* else true owner will clean up */
			free(l->layer->refreshptr);
		l->layer->refreshptr = nil;
		if(drawgoodname(dimage))
			memldelete(l);
		else
			memlfree(l);
		drawfreedscreen(ds);
	}else
		freememimage(dimage->image);
    Return:
	free(dimage->fchar);
	free(dimage);
}

void
drawuninstallscreen(Client *client, CScreen *this)
{
	CScreen *cs, *next;

	cs = client->cscreen;
	if(cs == this){
		client->cscreen = this->next;
		drawfreedscreen(this->dscreen);
		free(this);
		return;
	}
	while(next = cs->next){	/* assign = */
		if(next == this){
			cs->next = this->next;
			drawfreedscreen(this->dscreen);
			free(this);
			return;
		}
		cs = next;
	}
}

void
drawuninstall(Client *client, int id)
{
	DImage *d, *next;

	d = client->dimage[id&HASHMASK];
	if(d == 0)
		error(Enodrawimage);
	if(d->id == id){
		client->dimage[id&HASHMASK] = d->next;
		drawfreedimage(d);
		return;
	}
	while(next = d->next){	/* assign = */
		if(next->id == id){
			d->next = next->next;
			drawfreedimage(next);
			return;
		}
		d = next;
	}
	error(Enodrawimage);
}

void
drawaddname(Client *client, DImage *di, int n, char *str)
{
	DName *name, *ename, *new, *t;

	name = sdraw.name;
	ename = &name[sdraw.nname];
	for(; name<ename; name++)
		if(drawcmp(name->name, str, n) == 0)
			error(Enameused);
	t = smalloc((sdraw.nname+1)*sizeof(DName));
	memmove(t, sdraw.name, sdraw.nname*sizeof(DName));
	free(sdraw.name);
	sdraw.name = t;
	new = &sdraw.name[sdraw.nname++];
	new->name = smalloc(n+1);
	memmove(new->name, str, n);
	new->name[n] = 0;
	new->dimage = di;
	new->client = client;
	new->vers = ++sdraw.vers;
}

Client*
drawnewclient(void)
{
	Client *cl, **cp;
	int i;

	for(i=0; i<sdraw.nclient; i++){
		cl = sdraw.client[i];
		if(cl == 0)
			break;
	}
	if(i == sdraw.nclient){
		cp = malloc((sdraw.nclient+1)*sizeof(Client*));
		if(cp == 0)
			return 0;
		memmove(cp, sdraw.client, sdraw.nclient*sizeof(Client*));
		free(sdraw.client);
		sdraw.client = cp;
		sdraw.nclient++;
		cp[i] = 0;
	}
	cl = malloc(sizeof(Client));
	if(cl == 0)
		return 0;
	memset(cl, 0, sizeof(Client));
	cl->slot = i;
	cl->clientid = ++sdraw.clientid;
	cl->op = SoverD;
	/* Identity model/proj; viewport set by 'w'. */
	cl->d3model[0] = cl->d3model[5] = cl->d3model[10] = cl->d3model[15] = 1.0f;
	cl->d3proj[0] = cl->d3proj[5] = cl->d3proj[10] = cl->d3proj[15] = 1.0f;
	cl->d3clipbehind = 1;
	cl->d3zenable = 1;
	sdraw.client[i] = cl;
	return cl;
}

static int
drawclientop(Client *cl)
{
	int op;

	op = cl->op;
	cl->op = SoverD;
	return op;
}
	
int
drawhasclients(void)
{
	/*
	 * if draw has ever been used, we can't resize the frame buffer,
	 * even if all clients have exited (nclients is cumulative); it's too
	 * hard to make work.
	 */
	return sdraw.nclient != 0;
}

Client*
drawclientofpath(ulong path)
{
	Client *cl;
	int slot;

	slot = CLIENTPATH(path);
	if(slot == 0)
		return nil;
	cl = sdraw.client[slot-1];
	if(cl==0 || cl->clientid==0)
		return nil;
	return cl;
}


Client*
drawclient(Chan *c)
{
	Client *client;

	client = drawclientofpath(c->qid.path);
	if(client == nil)
		error(Enoclient);
	return client;
}

Memimage*
drawimage(Client *client, uchar *a)
{
	DImage *d;

	d = drawlookup(client, BG32INT(a), 1);
	if(d == nil){
		iprint("drawimage error\n");
		error(Enodrawimage);
	}
	return d->image;
}

void
drawrectangle(Rectangle *r, uchar *a)
{
	r->min.x = BG32INT(a+0*4);
	r->min.y = BG32INT(a+1*4);
	r->max.x = BG32INT(a+2*4);
	r->max.y = BG32INT(a+3*4);
	// iprint("drawrectangle %R\n", *r);
}

void
drawpoint(Point *p, uchar *a)
{
	p->x = BG32INT(a+0*4);
	p->y = BG32INT(a+1*4);
	// iprint("drawpoint %P\n", *p);
}

Point
drawchar(Memimage *dst, Point p, Memimage *src, Point *sp, DImage *font, int index, int op)
{
	FChar *fc;
	Rectangle r;
	Point sp1;

	fc = &font->fchar[index];
	r.min.x = p.x+fc->left;
	r.min.y = p.y-(font->ascent-fc->miny);
	r.max.x = r.min.x+(fc->maxx-fc->minx);
	r.max.y = r.min.y+(fc->maxy-fc->miny);
	sp1.x = sp->x+fc->left;
	sp1.y = sp->y+fc->miny;
	memdraw(dst, r, src, sp1, font->image, Pt(fc->minx, fc->miny), op);
	p.x += fc->width;
	sp->x += fc->width;
	return p;
}

static int
initscreenimage(void)
{
	int width, depth;
	ulong chan;
	Rectangle r;

	if(screenimage != nil)
		return 1;

	memimageinit();
	screendata.base = nil;
	screendata.bdata = (uchar*)attachscreen(&r, &chan, &depth, &width, &sdraw.softscreen);
	if(screendata.bdata == nil)
		return 0;
	screendata.ref = 1;

	screenimage = allocmemimaged(r, chan, &screendata);
	if(screenimage == nil){
		/* RSC: BUG: detach screen */
		return 0;
	}

	screenimage->width = width;
	screenimage->clipr = r;
	return 1;
}

void
deletescreenimage(void)
{
	lock(&sdraw.q);
	/* RSC: BUG: detach screen */
	if(screenimage)
		freememimage(screenimage);
	screenimage = nil;
	unlock(&sdraw.q);
}

/*
 * Layers copy width/zero from the screen image at alloc time.  When the
 * host softscreen is rebound to a new stride, every Memimage that shares
 * screendata must adopt the new words-per-line or draws address wrong pixels.
 */
static void
updatescreenstrides(void)
{
	DScreen *ds;
	Memimage *i;
	u32 w;
	s32 z;

	if(screenimage == nil)
		return;
	w = screenimage->width;
	z = screenimage->zero;
	for(ds = dscreen; ds != nil; ds = ds->next){
		if(ds->screen == nil)
			continue;
		i = ds->screen->image;
		if(i != nil && i->data == &screendata){
			i->width = w;
			i->zero = z;
		}
		for(i = ds->screen->frontmost; i != nil; ){
			Memimage *next;

			if(i->layer == nil)
				break;
			next = i->layer->rear;
			if(i->data == &screendata){
				i->width = w;
				i->zero = z;
			}
			i = next;
		}
	}
}

void
drawscreenrebind(Memimage *n)
{
	if(n == nil || screenimage == nil)
		return;
	lock(&sdraw.q);
	screendata.base = n->data->base;
	screendata.bdata = n->data->bdata;
	screenimage->data = &screendata;
	screenimage->r = n->r;
	screenimage->clipr = n->clipr;
	screenimage->width = n->width;
	screenimage->zero = n->zero;
	updatescreenstrides();
	unlock(&sdraw.q);
	drawdisplayresize(n->r);
	flushrect = n->r;
	drawflush();
}

void
drawscreenresize(Memimage *n)
{
	drawscreenrebind(n);
	if(n == nil)
		return;
	mouseresize(n->r.max.x - n->r.min.x, n->r.max.y - n->r.min.y);
}

Chan*
drawattach(char *spec)
{
	lock(&sdraw.q);
	if(!initscreenimage()){
		unlock(&sdraw.q);
		error("no frame buffer");
	}
	unlock(&sdraw.q);
	return devattach('i', spec);
}

static Walkqid*
drawwalk(Chan *c, Chan *nc, char **name, int nname)
{
	if(screendata.bdata == nil)
		error("no frame buffer");
	return devwalk(c, nc, name, nname, 0, 0, drawgen);
}

static int
drawstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, 0, 0, drawgen);
}

static Chan*
drawopen(Chan *c, int omode)
{
	Client *cl;

	if(c->qid.type & QTDIR)
		return devopen(c, omode, 0, 0, drawgen);

	lock(&sdraw.q);
	if(waserror()){
		unlock(&sdraw.q);
		nexterror();
	}

	if(QID(c->qid) == Qnew){
		cl = drawnewclient();
		if(cl == 0)
			error(Enodev);
		c->qid.path = Qctl|((cl->slot+1)<<QSHIFT);
	}

	switch(QID(c->qid)){
	case Qnew:
		break;

	case Qctl:
		cl = drawclient(c);
		if(cl->busy)
			error(Einuse);
		cl->busy = 1;
		flushrect = Rect(10000, 10000, -10000, -10000);
		drawinstall(cl, 0, screenimage, 0);
		incref(&cl->r);
		break;
	case Qcolormap:
	case Qdata:
	case Qrefresh:
		cl = drawclient(c);
		incref(&cl->r);
		break;
	}
	unlock(&sdraw.q);
	poperror();
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = DRAWIOUNIT;
	return c;
}

static void
drawclose(Chan *c)
{
	int i;
	DImage *d, **dp;
	Client *cl;
	Refresh *r;

	if(QID(c->qid) < Qcolormap)	/* Qtopdir, Qnew, Q3rd, Q2nd have no client */
		return;
	lock(&sdraw.q);
	if(waserror()){
		unlock(&sdraw.q);
		nexterror();
	}

	cl = drawclient(c);
	if(QID(c->qid) == Qctl)
		cl->busy = 0;
	if((c->flag&COPEN) && (decref(&cl->r)==0)){
		while(r = cl->refresh){	/* assign = */
			cl->refresh = r->next;
			free(r);
		}
		/* free names */
		for(i=0; i<sdraw.nname; )
			if(sdraw.name[i].client == cl)
				drawdelname(sdraw.name+i);
			else
				i++;
		while(cl->cscreen)
			drawuninstallscreen(cl, cl->cscreen);
		/* all screens are freed, so now we can free images */
		dp = cl->dimage;
		for(i=0; i<NHASH; i++){
			while((d = *dp) != nil){
				*dp = d->next;
				drawfreedimage(d);
			}
			dp++;
		}
		sdraw.client[cl->slot] = 0;
		drawflush();	/* to erase visible, now dead windows */
		free(cl->d3zbuf);
		free(cl);
	}
	unlock(&sdraw.q);
	poperror();
}

long
drawread(Chan *c, void *a, long n, vlong off)
{
	int index, m;
	ulong red, green, blue;
	Client *cl;
	uchar *p;
	Refresh *r;
	DImage *di;
	Memimage *i;
	ulong offset = off;
	char buf[16];

	USED(offset);
	SET(red);
	SET(green);
	SET(blue);
	SET(m);
	SET(index);
	USED(red);
	USED(green);
	USED(blue);
	USED(m);
	USED(index);
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, drawgen);
	cl = drawclient(c);
	lock(&sdraw.q);
	if(waserror()){
		unlock(&sdraw.q);
		nexterror();
	}
	switch(QID(c->qid)){
	case Qctl:
		if(n < 12*12)
			error(Eshortread);
		if(cl->infoid < 0)
			error(Enodrawimage);
		if(cl->infoid == 0){
			i = screenimage;
			if(i == nil)
				error(Enodrawimage);
		}else{
			di = drawlookup(cl, cl->infoid, 1);
			if(di == nil)
				error(Enodrawimage);
			i = di->image;
		}
		n = sprint(a, "%11d %11d %11s %11d %11d %11d %11d %11d %11d %11d %11d %11d ",
			cl->clientid, cl->infoid, chantostr(buf, i->chan), (i->flags&Frepl)==Frepl,
			i->r.min.x, i->r.min.y, i->r.max.x, i->r.max.y,
			i->clipr.min.x, i->clipr.min.y, i->clipr.max.x, i->clipr.max.y);
		cl->infoid = -1;
		break;

	case Qcolormap:
#ifdef COLORMAP
		p = malloc(4*12*256+1);
		if(p == 0)
			error(Enomem);
		m = 0;
		for(index = 0; index < 256; index++){
			getcolor(index, &red, &green, &blue);
			m += sprint((char*)p+m, "%11d %11lud %11lud %11lud\n", index, red>>24, green>>24, blue>>24);
		}
		n = readstr(offset, a, n, (char*)p);
		free(p);
#else
		n = 0;
#endif
		break;

	case Qdata:
		if(cl->readdata == nil)
			error("no draw data");
		if(n < cl->nreaddata)
			error(Eshortread);
		n = cl->nreaddata;
		memmove(a, cl->readdata, cl->nreaddata);
		free(cl->readdata);
		cl->readdata = nil;
		break;

	case Qrefresh:
		if(n < 5*4)
			error(Ebadarg);
		for(;;){
			if(cl->refreshme || cl->refresh)
				break;
			unlock(&sdraw.q);
			if(waserror()){
				lock(&sdraw.q);	/* restore lock for waserror() above */
				nexterror();
			}
			Sleep(&cl->refrend, drawrefactive, cl);
			poperror();
			lock(&sdraw.q);
		}
		p = a;
		while(cl->refresh && n>=5*4){
			r = cl->refresh;
			BP32INT(p+0*4, r->dimage->id);
			BP32INT(p+1*4, r->r.min.x);
			BP32INT(p+2*4, r->r.min.y);
			BP32INT(p+3*4, r->r.max.x);
			BP32INT(p+4*4, r->r.max.y);
			cl->refresh = r->next;
			free(r);
			p += 5*4;
			n -= 5*4;
		}
		cl->refreshme = 0;
		n = p-(uchar*)a;
	}
	unlock(&sdraw.q);
	poperror();
	return n;
}

void
drawwakeall(void)
{
	Client *cl;
	int i;

	for(i=0; i<sdraw.nclient; i++){
		cl = sdraw.client[i];
		if(cl && (cl->refreshme || cl->refresh))
			Wakeup(&cl->refrend);
	}
}

static long
drawwrite(Chan *c, void *a, long n, vlong off)
{
	char buf[128], *fields[4], *q;
	Client *cl;
	int i, m, red, green, blue, x;
	ulong offset = off;

	USED(offset);
	SET(red);
	SET(green);
	SET(blue);
	SET(m);
	SET(i);
	SET(x);
	SET(q);
	SET(fields);
	SET(buf);
	USED(red);
	USED(green);
	USED(blue);
	USED(m);
	USED(i);
	USED(x);
	USED(q);
	USED(fields);
	USED(buf);
	if(c->qid.type & QTDIR)
		error(Eisdir);
	cl = drawclient(c);
	lock(&sdraw.q);
	if(waserror()){
		drawwakeall();
		unlock(&sdraw.q);
		nexterror();
	}
	switch(QID(c->qid)){
	case Qctl:
		if(n != 4)
			error("unknown draw control request");
		cl->infoid = BG32INT((uchar*)a);
		break;

	case Qcolormap:
#ifdef COLORMAP
		m = n;
		n = 0;
		while(m > 0){
			x = m;
			if(x > sizeof(buf)-1)
				x = sizeof(buf)-1;
			q = memccpy(buf, a, '\n', x);
			if(q == 0)
				break;
			i = q-buf;
			n += i;
			a = (char*)a + i;
			m -= i;
			*q = 0;
			if(tokenize(buf, fields, nelem(fields)) != 4)
				error(Ebadarg);
			i = strtoul(fields[0], 0, 0);
			red = strtoul(fields[1], 0, 0);
			green = strtoul(fields[2], 0, 0);
			blue = strtoul(fields[3], &q, 0);
			if(fields[3] == q)
				error(Ebadarg);
			if(red>255 || green>255 || blue>255 || i<0 || i>255)
				error(Ebadarg);
			red |= red<<8;
			red |= red<<16;
			green |= green<<8;
			green |= green<<16;
			blue |= blue<<8;
			blue |= blue<<16;
			setcolor(i, red, green, blue);
		}
#else
		n = 0;
#endif
		break;

	case Qdata:
		drawmesg(cl, a, n);
		drawwakeall();
		break;

	default:
		error(Ebadusefd);
	}
	unlock(&sdraw.q);
	poperror();
	return n;
}

uchar*
drawcoord(uchar *p, uchar *maxp, s32 oldx, s32 *newx)
{
	int b, x;

	if(p >= maxp)
		error(Eshortdraw);
	b = *p++;
	x = b & 0x7F;
	if(b & 0x80){
		if(p+1 >= maxp)
			error(Eshortdraw);
		x |= *p++ << 7;
		x |= *p++ << 15;
		if(x & (1<<22))
			x |= ~0<<23;
	}else{
		if(b & 0x40)
			x |= ~0<<7;
		x += oldx;
	}
	*newx = x;
	return p;
}

static void
printmesg(char *fmt, uchar *a, int plsprnt)
{
	char buf[256];
	char *p, *q;
	int s;

	if(1|| plsprnt==0){
		SET(s); SET(q); SET(p);
		USED(fmt); USED(a); USED(buf); USED(p); USED(q); USED(s);
		return;
	}
	q = buf;
	*q++ = *a++;
	for(p=fmt; *p; p++){
		switch(*p){
		case 'l':
			q += sprint(q, " %ld", (long)BG32INT(a));
			a += 4;
			break;
		case 'L':
			q += sprint(q, " %.8lux", (ulong)BG32INT(a));
			a += 4;
			break;
		case 'R':
			q += sprint(q, " [%d %d %d %d]", BG32INT(a), BG32INT(a+4), BG32INT(a+8), BG32INT(a+12));
			a += 16;
			break;
		case 'P':
			q += sprint(q, " [%d %d]", BG32INT(a), BG32INT(a+4));
			a += 8;
			break;
		case 'b':
			q += sprint(q, " %d", *a++);
			break;
		case 's':
			q += sprint(q, " %d", BG16INT(a));
			a += 2;
			break;
		case 'S':
			q += sprint(q, " %.4ux", BG16INT(a));
			a += 2;
			break;
		}
	}
	*q++ = '\n';
	*q = 0;
	iprint("%.*s", (int)(q-buf), buf);
}

/*
 * draw3d protocol helpers (software raster into Memimage; Metal when hooked).
 * Floats are IEEE754 binary32, little-endian (same endianness as BG32INT).
 * Soft z uses Limbo draw3d/polyfill plane scale (ZSCALE = 1<<20).
 */
enum {
	D3ZSCALE	= 1<<20,
	D3LIMIT		= 1<<11,
	D3CapMatrix	= 1<<0,
	D3CapFill	= 1<<1,
	D3CapLine	= 1<<2,
	D3CapPlot	= 1<<3,
	D3CapSprite	= 1<<4,
	D3CapEllipse	= 1<<5,
	D3CapGPU	= 1<<6,
	D3CapReadback	= 1<<7,
	D3CapNearClip	= 1<<8,
	D3CapDepthOrder	= 1<<9
};

static float
bgfloat(uchar *p)
{
	u32 u;
	float f;

	u = (u32)BG32INT(p);
	memmove(&f, &u, sizeof f);
	return f;
}

static void
d3loadmat(float *m, uchar *a)
{
	int i;

	for(i = 0; i < 16; i++)
		m[i] = bgfloat(a + i*4);
}

static void
d3mulpoint(float *m, float x, float y, float z, float *ox, float *oy, float *oz)
{
	float x1, y1, z1, w;

	x1 = x*m[0] + y*m[1] + z*m[2] + m[3];
	y1 = x*m[4] + y*m[5] + z*m[6] + m[7];
	z1 = x*m[8] + y*m[9] + z*m[10] + m[11];
	w  = x*m[12] + y*m[13] + z*m[14] + m[15];
	if(w != 0.0f && w != 1.0f){
		x1 /= w;
		y1 /= w;
		z1 /= w;
	}
	*ox = x1;
	*oy = y1;
	*oz = z1;
}

/* Model then proj (matches Limbo draw3d project); returns 0 if clipped. */
static int
d3project(Client *cl, float x, float y, float z, Point *sp, float *eyez)
{
	float ex, ey, ez, cx, cy, cz;

	d3mulpoint(cl->d3model, x, y, z, &ex, &ey, &ez);
	*eyez = ez;
	if(cl->d3clipbehind && ez >= 0.0f)
		return 0;
	d3mulpoint(cl->d3proj, ex, ey, ez, &cx, &cy, &cz);
	sp->x = (int)(cl->d3mx * cx + cl->d3cx);
	sp->y = (int)(cl->d3my * cy + cl->d3cy);
	return 1;
}

/* Clip a segment in eye space instead of dropping it when it crosses z=0. */
static int
d3projectline(Client *cl, float ax, float ay, float az, float bx, float by, float bz,
	Point *pa, Point *pb, float *eza, float *ezb)
{
	float aex, aey, aez, bex, bey, bez, cx, cy, cz, t;
	float const nearz = -1.0e-4f;

	d3mulpoint(cl->d3model, ax, ay, az, &aex, &aey, &aez);
	d3mulpoint(cl->d3model, bx, by, bz, &bex, &bey, &bez);
	if(cl->d3clipbehind){
		if(aez >= nearz && bez >= nearz)
			return 0;
		if(aez >= nearz){
			t = (nearz - bez) / (aez - bez);
			aex = bex + t*(aex-bex);
			aey = bey + t*(aey-bey);
			aez = nearz;
		}else if(bez >= nearz){
			t = (nearz - aez) / (bez - aez);
			bex = aex + t*(bex-aex);
			bey = aey + t*(bey-aey);
			bez = nearz;
		}
	}
	d3mulpoint(cl->d3proj, aex, aey, aez, &cx, &cy, &cz);
	pa->x = (int)(cl->d3mx * cx + cl->d3cx);
	pa->y = (int)(cl->d3my * cy + cl->d3cy);
	d3mulpoint(cl->d3proj, bex, bey, bez, &cx, &cy, &cz);
	pb->x = (int)(cl->d3mx * cx + cl->d3cx);
	pb->y = (int)(cl->d3my * cy + cl->d3cy);
	*eza = aez;
	*ezb = bez;
	return 1;
}

/* Sutherland-Hodgman clip against the eye plane used by clipbehind. */
static int
d3clipnear(Client *cl, float *ix, float *iy, float *iz, int n,
	float *ox, float *oy, float *oz)
{
	float sx, sy, sz, ex, ey, ez, qx, qy, sez, eez, t;
	float const nearz = -1.0e-4f;
	int i, m, sin, ein;

	if(!cl->d3clipbehind){
		for(i = 0; i < n; i++){
			ox[i] = ix[i];
			oy[i] = iy[i];
			oz[i] = iz[i];
		}
		return n;
	}
	m = 0;
	sx = ix[n-1]; sy = iy[n-1]; sz = iz[n-1];
	d3mulpoint(cl->d3model, sx, sy, sz, &qx, &qy, &sez);
	sin = sez < nearz;
	for(i = 0; i < n; i++){
		ex = ix[i]; ey = iy[i]; ez = iz[i];
		d3mulpoint(cl->d3model, ex, ey, ez, &qx, &qy, &eez);
		ein = eez < nearz;
		if(sin != ein){
			t = (nearz - sez) / (eez - sez);
			ox[m] = sx + t*(ex-sx);
			oy[m] = sy + t*(ey-sy);
			oz[m++] = sz + t*(ez-sz);
		}
		if(ein){
			ox[m] = ex;
			oy[m] = ey;
			oz[m++] = ez;
		}
		sx = ex; sy = ey; sz = ez; sez = eez; sin = ein;
	}
	return m;
}

static void
d3clearz(Client *cl, Memimage *dst)
{
	int n, i;
	Rectangle r;

	if(dst == nil)
		return;
	r = dst->clipr;
	n = Dx(r) * Dy(r);
	if(n <= 0)
		return;
	if(cl->d3zbuf == nil || cl->d3zw != Dx(r) || cl->d3zh != Dy(r)
	|| !eqrect(cl->d3zr, r)){
		free(cl->d3zbuf);
		cl->d3zbuf = malloc(sizeof(int) * n);
		if(cl->d3zbuf == nil)
			error(Edrawmem);
		cl->d3zw = Dx(r);
		cl->d3zh = Dy(r);
		cl->d3zr = r;
	}
	/* ∞ depth: farther than any projected eye z (more positive = farther). */
	for(i = 0; i < n; i++)
		cl->d3zbuf[i] = 0x7fffffff;
}

/* True iff cl->d3model is the identity matrix. */
static int
d3modelisident(Client *cl)
{
	int i, j;

	for(i = 0; i < 4; i++)
		for(j = 0; j < 4; j++)
			if(cl->d3model[i*4+j] != (i == j ? 1.0f : 0.0f))
				return 0;
	return 1;
}

/*
 * Limbo draw3d fillpoly3 plane in screen space (same formulae as draw3d.b).
 * vx,vy,vz are verts in the same space as the face normal - this formula
 * maps that space to screen coordinates through the viewport scale alone,
 * with no model or projection transform in between, so it's only valid
 * when cl->d3model is identity (the caller must check d3modelisident()
 * first) - a real model matrix (rotation/translation) needs the general,
 * slower d3planefromeyez() below instead, which derives the plane from
 * already-projected screen points + eye z rather than assuming vx/vy/vz
 * map to the screen directly.
 */
static int
d3planecoeffs(Client *cl, float nx, float ny, float nz,
	float *vx, float *vy, float *vz, int n,
	int *pdx, int *pdy, int *pdc)
{
	float d, cz, a, b, dd, α, β, γ, δ;
	int i;

	if(n < 3 || nz == 0.0f)
		return 0;
	d = 0.0f;
	for(i = 0; i < n; i++)
		d += nx*vx[i] + ny*vy[i] + nz*vz[i];
	d /= (float)n;
	α = cl->d3mx;
	β = cl->d3cx;
	γ = cl->d3my;
	δ = cl->d3cy;
	if(α == 0.0f || γ == 0.0f)
		return 0;
	cz = nz;
	if(cz > -1e-6f && cz < 1e-6f)
		return 0;
	a = -nx / (cz * α);
	b = -ny / (cz * γ);
	dd = d / cz - β * a - δ * b;
	if(a <= -(float)D3LIMIT || a >= (float)D3LIMIT
	|| b <= -(float)D3LIMIT || b >= (float)D3LIMIT
	|| dd <= -(float)D3LIMIT || dd >= (float)D3LIMIT)
		return 0;
	*pdx = (int)(a * (float)D3ZSCALE);
	*pdy = (int)(b * (float)D3ZSCALE);
	*pdc = (int)(dd * (float)D3ZSCALE);
	return 1;
}

/* Plane through three screen points with eye-z → fixed-point coeffs. */
static int
d3planefromeyez(Point *pp, float *ez, int n, int *pdx, int *pdy, int *pdc)
{
	float x0, y0, z0, x1, y1, z1, x2, y2, z2;
	float e1x, e1y, e1z, e2x, e2y, e2z, nx, ny, nz, inv;
	float a, b, dd;

	if(n < 3)
		return 0;
	x0 = (float)pp[0].x; y0 = (float)pp[0].y; z0 = -ez[0];
	x1 = (float)pp[1].x; y1 = (float)pp[1].y; z1 = -ez[1];
	x2 = (float)pp[2].x; y2 = (float)pp[2].y; z2 = -ez[2];
	e1x = x1 - x0; e1y = y1 - y0; e1z = z1 - z0;
	e2x = x2 - x0; e2y = y2 - y0; e2z = z2 - z0;
	nx = e1y*e2z - e1z*e2y;
	ny = e1z*e2x - e1x*e2z;
	nz = e1x*e2y - e1y*e2x;
	if(nz > -1e-6f && nz < 1e-6f)
		return 0;
	/* z = a*x + b*y + dd  (eye z on the plane) */
	inv = 1.0f / nz;
	a = -nx * inv;
	b = -ny * inv;
	dd = (nx*x0 + ny*y0 + nz*z0) * inv;
	if(a <= -(float)D3LIMIT || a >= (float)D3LIMIT
	|| b <= -(float)D3LIMIT || b >= (float)D3LIMIT
	|| dd <= -(float)D3LIMIT || dd >= (float)D3LIMIT)
		return 0;
	*pdx = (int)(a * (float)D3ZSCALE);
	*pdy = (int)(b * (float)D3ZSCALE);
	*pdc = (int)(dd * (float)D3ZSCALE);
	return 1;
}

/* Convex point-in-polygon (draw3d faces are convex). */
static int
d3ptconvex(Point p, Point *v, int n)
{
	int i, s, c;
	Point a, b;

	s = 0;
	for(i = 0; i < n; i++){
		a = v[i];
		b = v[(i+1) % n];
		c = (b.x - a.x)*(p.y - a.y) - (b.y - a.y)*(p.x - a.x);
		if(c < 0){
			if(s > 0)
				return 0;
			s = -1;
		}else if(c > 0){
			if(s < 0)
				return 0;
			s = 1;
		}
	}
	return 1;
}

/*
 * Soft z-buffered fill matching Limbo polyfill semantics (closer = smaller z).
 * Falls back to memfillpoly when no z-buffer is allocated.
 */
static void
d3fillpolyz(Client *cl, Memimage *dst, Point *pp, int nw,
	Memimage *src, int op, int dc, int dx, int dy)
{
	Rectangle bbox, clip;
	Point p;
	int x, y, z, k, prevx;
	Memimage *ones;

	if(!cl->d3zenable || cl->d3zbuf == nil){
		memfillpoly(dst, pp, nw+1, ~0, src, pp[0], op);
		return;
	}
	bbox.min = bbox.max = pp[0];
	for(k = 1; k < nw; k++){
		if(pp[k].x < bbox.min.x) bbox.min.x = pp[k].x;
		if(pp[k].y < bbox.min.y) bbox.min.y = pp[k].y;
		if(pp[k].x > bbox.max.x) bbox.max.x = pp[k].x;
		if(pp[k].y > bbox.max.y) bbox.max.y = pp[k].y;
	}
	bbox.max.x++;
	bbox.max.y++;
	clip = dst->clipr;
	if(!rectclip(&bbox, clip) || !rectclip(&bbox, cl->d3zr))
		return;
	ones = memopaque;
	for(y = bbox.min.y; y < bbox.max.y; y++){
		prevx = 0x7fffffff;
		for(x = bbox.min.x; x < bbox.max.x; x++){
			p = Pt(x, y);
			if(!d3ptconvex(p, pp, nw)){
				if(prevx != 0x7fffffff){
					memdraw(dst, Rect(prevx, y, x, y+1),
						src, Pt(prevx, y), ones, Pt(prevx, y), op);
					prevx = 0x7fffffff;
				}
				continue;
			}
			z = dc + dx*x + dy*y;
			k = (y - cl->d3zr.min.y)*cl->d3zw + (x - cl->d3zr.min.x);
			if(k < 0 || k >= cl->d3zw*cl->d3zh)
				continue;
			if(z < cl->d3zbuf[k]){
				cl->d3zbuf[k] = z;
				if(prevx == 0x7fffffff)
					prevx = x;
			}else if(prevx != 0x7fffffff){
				memdraw(dst, Rect(prevx, y, x, y+1),
					src, Pt(prevx, y), ones, Pt(prevx, y), op);
				prevx = 0x7fffffff;
			}
		}
		if(prevx != 0x7fffffff)
			memdraw(dst, Rect(prevx, y, bbox.max.x, y+1),
				src, Pt(prevx, y), ones, Pt(prevx, y), op);
	}
}

/* Depth-tested software line/point fallback using the Metal plane-depth order. */
static void
d3linez(Client *cl, Memimage *dst, Point a, Point b, int thick,
	Memimage *src, int op, float eza, float ezb)
{
	Rectangle r;
	Point p;
	float vx, vy, len2, t, qx, qy, rad2, eyez;
	int x, y, k, z;

	if(!cl->d3zenable || cl->d3zbuf == nil){
		memline(dst, a, b, Endsquare, Endsquare, thick, src, a, op);
		return;
	}
	r = memlinebbox(a, b, Endsquare, Endsquare, thick);
	if(!rectclip(&r, dst->clipr) || !rectclip(&r, cl->d3zr))
		return;
	vx = b.x-a.x;
	vy = b.y-a.y;
	len2 = vx*vx + vy*vy;
	rad2 = ((float)thick + 0.5f)*((float)thick + 0.5f);
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			if(len2 <= 1.0e-6f)
				t = 0.0f;
			else{
				t = ((x-a.x)*vx + (y-a.y)*vy)/len2;
				if(t < 0.0f) t = 0.0f;
				if(t > 1.0f) t = 1.0f;
			}
			qx = (float)a.x + t*vx;
			qy = (float)a.y + t*vy;
			if((x-qx)*(x-qx) + (y-qy)*(y-qy) > rad2)
				continue;
			eyez = eza + t*(ezb-eza);
			z = (int)(-eyez*(float)D3ZSCALE);
			k = (y-cl->d3zr.min.y)*cl->d3zw + x-cl->d3zr.min.x;
			if(k < 0 || k >= cl->d3zw*cl->d3zh || z >= cl->d3zbuf[k])
				continue;
			cl->d3zbuf[k] = z;
			p = Pt(x, y);
			memdraw(dst, Rect(x, y, x+1, y+1), src, p, memopaque, p, op);
		}
}

static int
d3zpixel(Client *cl, Point p, float eyez)
{
	int k, z;

	if(!cl->d3zenable || cl->d3zbuf == nil)
		return 1;
	if(!ptinrect(p, cl->d3zr))
		return 0;
	k = (p.y-cl->d3zr.min.y)*cl->d3zw + p.x-cl->d3zr.min.x;
	if(k < 0 || k >= cl->d3zw*cl->d3zh)
		return 0;
	z = (int)(-eyez*(float)D3ZSCALE);
	if(z >= cl->d3zbuf[k])
		return 0;
	cl->d3zbuf[k] = z;
	return 1;
}

static int
d3maskset(Memimage *mask, Point p)
{
	uchar *q;

	if(mask == nil)
		return 1;
	q = byteaddr(mask, p);
	if(q == nil)
		return 0;
	if(mask->depth == 1)
		return (q[0] & 0x80) != 0;
	return q[0] != 0;
}

/* Rotated/scaled sprite fallback with constant billboard depth. */
static void
d3spritez(Client *cl, Memimage *dst, Point c, int sw, int sh, float eyez,
	Memimage *src, Memimage *mask, float degz, int op)
{
	Rectangle r;
	Point p, sp, mp;
	float rad, cs, sn, hx, hy, ex, ey, lx, ly;
	int x, y, iw, ih, mw, mh;

	iw = Dx(src->r); ih = Dy(src->r);
	if(iw < 1 || ih < 1 || sw < 1 || sh < 1)
		return;
	rad = degz*(float)M_PI/180.0f;
	cs = cosf(rad); sn = sinf(rad);
	hx = sw*0.5f; hy = sh*0.5f;
	ex = fabsf(cs)*hx + fabsf(sn)*hy;
	ey = fabsf(sn)*hx + fabsf(cs)*hy;
	r = Rect((int)floorf(c.x-ex), (int)floorf(c.y-ey),
		(int)ceilf(c.x+ex), (int)ceilf(c.y+ey));
	if(!rectclip(&r, dst->clipr))
		return;
	mw = mask != nil ? Dx(mask->r) : 0;
	mh = mask != nil ? Dy(mask->r) : 0;
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			/* Inverse screen rotation into the unrotated billboard. */
			lx = (x+0.5f-c.x)*cs + (y+0.5f-c.y)*sn;
			ly = -(x+0.5f-c.x)*sn + (y+0.5f-c.y)*cs;
			if(lx < -hx || lx >= hx || ly < -hy || ly >= hy)
				continue;
			sp = Pt(src->r.min.x + (int)((lx+hx)*iw/sw),
				src->r.min.y + (int)((ly+hy)*ih/sh));
			mp = ZP;
			if(mask != nil){
				mp = Pt(mask->r.min.x + (int)((lx+hx)*mw/sw),
					mask->r.min.y + (int)((ly+hy)*mh/sh));
				if(!d3maskset(mask, mp))
					continue;
			}
			p = Pt(x, y);
			if(!d3zpixel(cl, p, eyez))
				continue;
			memdraw(dst, Rect(x, y, x+1, y+1), src, sp,
				mask != nil ? mask : memopaque, mp, op);
		}
}

static void
d3ellipsez(Client *cl, Memimage *dst, Point c, int rx, int ry, int thick,
	int fill, Memimage *src, int op, float eyez)
{
	Rectangle r;
	Point p;
	float dx, dy, d, tol;
	int x, y;

	if(rx < 1 || ry < 1)
		return;
	tol = ((float)thick + 0.75f) / (float)(rx < ry ? rx : ry);
	r = Rect(c.x-rx-thick-1, c.y-ry-thick-1,
		c.x+rx+thick+2, c.y+ry+thick+2);
	if(!rectclip(&r, dst->clipr))
		return;
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			dx = (x+0.5f-c.x)/(float)rx;
			dy = (y+0.5f-c.y)/(float)ry;
			d = sqrtf(dx*dx + dy*dy);
			if((fill && d > 1.0f) || (!fill && (d < 1.0f-tol || d > 1.0f+tol)))
				continue;
			p = Pt(x, y);
			if(!d3zpixel(cl, p, eyez))
				continue;
			memdraw(dst, Rect(x, y, x+1, y+1), src, p, memopaque, p, op);
		}
}

/* Tint a solid 32-bit colour by lighting factor; *tmp owns any replacement. */
static Memimage*
d3applylit(Memimage *src, float lit, Memimage **tmp)
{
	u32 v, r, g, b, a;
	uchar *p;

	*tmp = nil;
	if(src == nil || (lit >= 0.999f && lit <= 1.001f))
		return src;
	if(!(src->flags & Frepl) || src->depth != 32)
		return src;
	p = byteaddr(src, src->r.min);
	if(p == nil)
		return src;
	v = (u32)p[0] | ((u32)p[1]<<8) | ((u32)p[2]<<16) | ((u32)p[3]<<24);
	r = v & 0xff;
	g = (v>>8) & 0xff;
	b = (v>>16) & 0xff;
	a = (v>>24) & 0xff;
	if(lit < 0.0f)
		lit = 0.0f;
	r = (u32)(r * lit);
	g = (u32)(g * lit);
	b = (u32)(b * lit);
	if(r > 255) r = 255;
	if(g > 255) g = 255;
	if(b > 255) b = 255;
	*tmp = allocmemimage(Rect(0, 0, 1, 1), src->chan);
	if(*tmp == nil)
		return src;
	(*tmp)->flags |= Frepl;
	(*tmp)->clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
	p = byteaddr(*tmp, (*tmp)->r.min);
	p[0] = (uchar)r;
	p[1] = (uchar)g;
	p[2] = (uchar)b;
	p[3] = (uchar)a;
	return *tmp;
}

void
drawmesg(Client *client, void *av, int n)
{
	s32 c, op, repl, m, y, dstid, scrnid, ni, ci, j, nw, e0, e1, ox, oy, esize, oesize, doflush;
	uchar *u, *a, refresh;
	char *fmt;
	u32 value, chan;
	Rectangle r, clipr;
	Point p, q, *pp, sp;
	Memimage *i, *dst, *src, *mask;
	Memimage *l, **lp;
	Memscreen *scrn;
	DImage *font, *ll, *di, *ddst, *dsrc;
	DName *dn;
	DScreen *dscrn;
	FChar *fc;
	Refx *refx;
	CScreen *cs;
	Refreshfn reffn;

	a = av;
	m = 0;
	fmt = nil;
	if(waserror()){
		if(fmt) printmesg(fmt, a, 1);
	/*	iprint("error: %s\n", up->env->errstr);	*/
		nexterror();
	}
	while((n-=m) > 0){
		USED(fmt);
		a += m;
		/*
		 * Snapshot softscreen under queued Metal geom before 2D draws,
		 * so present can put sprites/HUD over the wireframe.  Keep draw3d
		 * letters from flushing mid-batch.
		 */
		switch(*a){
		case 'G':
		case 'g':
		case 'h':
		case 'j':
		case 'k':
		case 'q':
		case 'M':
		case 'w':
		case 'u':
		case 'z':
		case '3':
		case 'C':
			break;
		default:
			if(gpudrawflush)
				gpudrawflush();
			break;
		}
		switch(*a){
		default:
			error("bad draw command");
		/* new allocate: 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] R[4*4] clipR[4*4] rrggbbaa[4] */
		case 'b':
			printmesg(fmt="LLbLbRRL", a, 0);
			m = 1+4+4+1+4+1+4*4+4*4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			scrnid = BG32INT(a+5);
			refresh = a[9];
			chan = BG32INT(a+10);
			repl = a[14];
			drawrectangle(&r, a+15);
			drawrectangle(&clipr, a+31);
			value = BG32INT(a+47);
			if(drawlookup(client, dstid, 0))
				error(Eimageexists);
			if(scrnid){
				dscrn = drawlookupscreen(client, scrnid, &cs);
				scrn = dscrn->screen;
				if(repl || chan!=scrn->image->chan)
					error("image parameters incompatible with screen");
				reffn = nil;
				switch(refresh){
				case Refbackup:
					break;
				case Refnone:
					reffn = memlnorefresh;
					break;
				case Refmesg:
					reffn = drawrefresh;
					break;
				default:
					error("unknown refresh method");
				}
				l = memlalloc(scrn, r, reffn, 0, value);
				if(l == 0)
					error(Edrawmem);
				dstflush(l->layer->screen->image, l->layer->screenr);
				l->clipr = clipr;
				rectclip(&l->clipr, r);
				if(drawinstall(client, dstid, l, dscrn) == 0){
					memldelete(l);
					error(Edrawmem);
				}
				AINC(&dscrn->ref);
				if(reffn){
					refx = nil;
					if(reffn == drawrefresh){
						refx = malloc(sizeof(Refx));
						if(refx == 0){
							drawuninstall(client, dstid);
							error(Edrawmem);
						}
						refx->client = client;
						refx->dimage = drawlookup(client, dstid, 1);
					}
					memlsetrefresh(l, reffn, refx);
				}
				continue;
			}
			i = allocmemimage(r, chan);
			if(i == 0)
				error(Edrawmem);
			if(repl)
				i->flags |= Frepl;
			i->clipr = clipr;
			if(!repl)
				rectclip(&i->clipr, r);
			if(drawinstall(client, dstid, i, 0) == 0){
				freememimage(i);
				error(Edrawmem);
			}
			memfillcolor(i, value);
			continue;

		/* allocate screen: 'A' id[4] imageid[4] fillid[4] public[1] */
		case 'A':
			printmesg(fmt="LLLb", a, 1);
			m = 1+4+4+4+1;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(dstid == 0)
				error(Ebadarg);
			if(drawlookupdscreen(dstid))
				error(Escreenexists);
			ddst = drawlookup(client, BG32INT(a+5), 1);
			dsrc = drawlookup(client, BG32INT(a+9), 1);
			if(ddst==0 || dsrc==0)
				error(Enodrawimage);
			if(drawinstallscreen(client, 0, dstid, ddst, dsrc, a[13]) == 0)
				error(Edrawmem);
			continue;

		/* set repl and clip: 'c' dstid[4] repl[1] clipR[4*4] */
		case 'c':
			printmesg(fmt="LbR", a, 0);
			m = 1+4+1+4*4;
			if(n < m)
				error(Eshortdraw);
			ddst = drawlookup(client, BG32INT(a+1), 1);
			if(ddst == nil)
				error(Enodrawimage);
			if(ddst->name)
				error("cannot change repl/clipr of shared image");
			dst = ddst->image;
			if(a[5])
				dst->flags |= Frepl;
			drawrectangle(&dst->clipr, a+6);
			continue;

		/* draw: 'd' dstid[4] srcid[4] maskid[4] R[4*4] P[2*4] P[2*4] */
		case 'd':
			printmesg(fmt="LLLRPP", a, 0);
			m = 1+4+4+4+4*4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			mask = drawimage(client, a+9);
			drawrectangle(&r, a+13);
			drawpoint(&p, a+29);
			drawpoint(&q, a+37);
			op = drawclientop(client);
			memdraw(dst, r, src, p, mask, q, op);
			dstflush(dst, r);
			continue;

		/* toggle debugging: 'D' val[1] */
		case 'D':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			drawdebug = a[1];
			continue;

		/* ellipse: 'e' dstid[4] srcid[4] center[2*4] a[4] b[4] thick[4] sp[2*4] alpha[4] phi[4]*/
		case 'e':
		case 'E':
			printmesg(fmt="LLPlllPll", a, 0);
			m = 1+4+4+2*4+4+4+4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			drawpoint(&p, a+9);
			e0 = BG32INT(a+17);
			e1 = BG32INT(a+21);
			if(e0<0 || e1<0)
				error("invalid ellipse semidiameter");
			j = BG32INT(a+25);
			if(j < 0)
				error("negative ellipse thickness");
			drawpoint(&sp, a+29);
			c = j;
			if(*a == 'E')
				c = -1;
			ox = BG32INT(a+37);
			oy = BG32INT(a+41);
			op = drawclientop(client);
			/* high bit indicates arc angles are present */
			if(ox & (1<<31)){
				if((ox & (1<<30)) == 0)
					ox &= ~(1<<31);
				memarc(dst, p, e0, e1, c, src, sp, ox, oy, op);
			}else
				memellipse(dst, p, e0, e1, c, src, sp, op);
			dstflush(dst, Rect(p.x-e0-j, p.y-e1-j, p.x+e0+j+1, p.y+e1+j+1));
			continue;

		/* free: 'f' id[4] */
		case 'f':
			printmesg(fmt="L", a, 1);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			ll = drawlookup(client, BG32INT(a+1), 0);
			if(ll && ll->dscreen && ll->dscreen->owner != client)
				ll->dscreen->owner->refreshme = 1;
			drawuninstall(client, BG32INT(a+1));
			continue;

		/* free screen: 'F' id[4] */
		case 'F':
			printmesg(fmt="L", a, 1);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			drawlookupscreen(client, BG32INT(a+1), &cs);
			drawuninstallscreen(client, cs);
			continue;

		/* initialize font: 'i' fontid[4] nchars[4] ascent[1] */
		case 'i':
			printmesg(fmt="Llb", a, 1);
			m = 1+4+4+1;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			if(dstid == 0 || dst == screenimage)
				error("cannot use display as font");
			font = drawlookup(client, dstid, 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->image->layer)
				error("cannot use window as font");
			ni = BG32INT(a+5);
			if(ni<=0 || ni>4096)
				error("bad font size (4096 chars max)");
			free(font->fchar);	/* should we complain if non-zero? */
			font->fchar = malloc(ni*sizeof(FChar));
			if(font->fchar == 0)
				error(Enomem);
			memset(font->fchar, 0, ni*sizeof(FChar));
			font->nfchar = ni;
			font->ascent = a[9];
			continue;

		/* load character: 'l' fontid[4] srcid[4] index[2] R[4*4] P[2*4] left[1] width[1] */
		case 'l':
			printmesg(fmt="LLSRPbb", a, 0);
			m = 1+4+4+2+4*4+2*4+1+1;
			if(n < m)
				error(Eshortdraw);
			font = drawlookup(client, BG32INT(a+1), 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->nfchar == 0)
				error(Enotfont);
			src = drawimage(client, a+5);
			ci = BG16INT(a+9);
			if(ci >= font->nfchar)
				error(Eindex);
			drawrectangle(&r, a+11);
			drawpoint(&p, a+27);
			memdraw(font->image, r, src, p, memopaque, p, SoverD);
			fc = &font->fchar[ci];
			fc->minx = r.min.x;
			fc->maxx = r.max.x;
			fc->miny = r.min.y;
			fc->maxy = r.max.y;
			fc->left = a[35];
			fc->width = a[36];
			continue;

		/* draw line: 'L' dstid[4] p0[2*4] p1[2*4] end0[4] end1[4] radius[4] srcid[4] sp[2*4] */
		case 'L':
			printmesg(fmt="LPPlllLP", a, 0);
			m = 1+4+2*4+2*4+4+4+4+4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			drawpoint(&p, a+5);
			drawpoint(&q, a+13);
			e0 = BG32INT(a+21);
			e1 = BG32INT(a+25);
			j = BG32INT(a+29);
			if(j < 0)
				error("negative line width");
			src = drawimage(client, a+33);
			drawpoint(&sp, a+37);
			op = drawclientop(client);
			memline(dst, p, q, e0, e1, j, src, sp, op);
			/* avoid memlinebbox if possible */
			if(dst == screenimage || dst->layer!=nil){
				/* BUG: this is terribly inefficient: update maximal containing rect*/
				r = memlinebbox(p, q, e0, e1, j);
				dstflush(dst, insetrect(r, -(1+1+j)));
			}
			continue;

		/* create image mask: 'm' newid[4] id[4] */
/*
 *
		case 'm':
			printmesg("LL", a, 0);
			m = 4+4;
			if(n < m)
				error(Eshortdraw);
			break;
 *
 */

		/* attach to a named image: 'n' dstid[4] j[1] name[j] */
		case 'n':
			printmesg(fmt="Lz", a, 0);
			m = 1+4+1;
			if(n < m)
				error(Eshortdraw);
			j = a[5];
			if(j == 0)	/* give me a non-empty name please */
				error(Eshortdraw);
			m += j;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(drawlookup(client, dstid, 0))
				error(Eimageexists);
			dn = drawlookupname(j, (char*)a+6);
			if(dn == nil)
				error(Enoname);
			if(drawinstall(client, dstid, dn->dimage->image, 0) == 0)
				error(Edrawmem);
			di = drawlookup(client, dstid, 0);
			if(di == 0)
				error("draw: cannot happen");
			di->vers = dn->vers;
			di->name = smalloc(j+1);
			di->fromname = dn->dimage;
			AINC(&di->fromname->ref);
			memmove(di->name, a+6, j);
			di->name[j] = 0;
			client->infoid = dstid;
			continue;

		/* name an image: 'N' dstid[4] in[1] j[1] name[j] */
		case 'N':
			printmesg(fmt="Lbz", a, 0);
			m = 1+4+1+1;
			if(n < m)
				error(Eshortdraw);
			c = a[5];
			j = a[6];
			if(j == 0)	/* give me a non-empty name please */
				error(Eshortdraw);
			m += j;
			if(n < m)
				error(Eshortdraw);
			di = drawlookup(client, BG32INT(a+1), 0);
			if(di == 0)
				error(Enodrawimage);
			if(di->name)
				error(Enamed);
			if(c)
				drawaddname(client, di, j, (char*)a+7);
			else{
				dn = drawlookupname(j, (char*)a+7);
				if(dn == nil)
					error(Enoname);
				if(dn->dimage != di)
					error(Ewrongname);
				drawdelname(dn);
			}
			continue;

		/* position window: 'o' id[4] r.min [2*4] screenr.min [2*4] */
		case 'o':
			printmesg(fmt="LPP", a, 0);
			m = 1+4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			if(dst->layer){
				drawpoint(&p, a+5);
				drawpoint(&q, a+13);
				r = dst->layer->screenr;
				ni = memlorigin(dst, p, q);
				if(ni < 0)
					error("image origin failed");
				if(ni > 0){
					dstflush(dst->layer->screen->image, r);
					dstflush(dst->layer->screen->image, dst->layer->screenr);
					ll = drawlookup(client, BG32INT(a+1), 1);
					drawrefreshscreen(ll, client);
				}
			}
			continue;

		/* set compositing operator for next draw operation: 'O' op */
		case 'O':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			client->op = *(a+1);
			continue;

		/* filled polygon: 'P' dstid[4] n[2] wind[4] ignore[2*4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n] */
		/* polygon: 'p' dstid[4] n[2] end0[4] end1[4] radius[4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n] */
		case 'p':
		case 'P':
			printmesg(fmt="LslllLPP", a, 0);
			m = 1+4+2+4+4+4+4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			ni = BG16INT(a+5);
			if(ni < 0)
				error("negative count in polygon");
			e0 = BG32INT(a+7);
			e1 = BG32INT(a+11);
			j = 0;
			if(*a == 'p'){
				j = BG32INT(a+15);
				if(j < 0)
					error("negative polygon line width");
			}
			src = drawimage(client, a+19);
			drawpoint(&sp, a+23);
			drawpoint(&p, a+31);
			ni++;
			pp = malloc(ni*sizeof(Point));
			if(pp == nil)
				error(Enomem);
			doflush = 0;
			if(dst == screenimage || (dst->layer && dst->layer->screen->image->data == screenimage->data))
				doflush = 1;	/* simplify test in loop */
			ox = oy = 0;
			esize = 0;
			u = a+m;
			for(y=0; y<ni; y++){
				q = p;
				oesize = esize;
				u = drawcoord(u, a+n, ox, &p.x);
				u = drawcoord(u, a+n, oy, &p.y);
				ox = p.x;
				oy = p.y;
				if(doflush){
					esize = j;
					if(*a == 'p'){
						if(y == 0){
							c = memlineendsize(e0);
							if(c > esize)
								esize = c;
						}
						if(y == ni-1){
							c = memlineendsize(e1);
							if(c > esize)
								esize = c;
						}
					}
					if(*a=='P' && e0!=1 && e0 !=~0)
						r = dst->clipr;
					else if (y>0){
						r = Rect(q.x-oesize, q.y-oesize, q.x+oesize+1, q.y+oesize+1);
						combinerect(&r, Rect(p.x-esize, p.y-esize, p.x+esize+1, p.y+esize+1));
					}
					if (rectclip(&r, dst->clipr))		/* should perhaps be an arg to dstflush */
						dstflush(dst, r);
				}
				pp[y] = p;
			}
			if (y == 1)
				dstflush(dst, Rect(p.x-esize, p.y-esize, p.x+esize+1, p.y+esize+1));
			op = drawclientop(client);
			if(*a == 'p')
				mempoly(dst, pp, ni, e0, e1, j, src, sp, op);
			else
				memfillpoly(dst, pp, ni, e0, src, sp, op);
			free(pp);
			m = u-a;
			continue;

		/* read: 'r' id[4] R[4*4] */
		case 'r':
			printmesg(fmt="LR", a, 0);
			m = 1+4+4*4;
			if(n < m)
				error(Eshortdraw);
			i = drawimage(client, a+1);
			/* A read observes all preceding draw3d work, including GPU queues. */
			if(gpudrawreadback)
				gpudrawreadback();
			drawrectangle(&r, a+5);
			if(!rectinrect(r, i->r))
				error(Ereadoutside);
			c = bytesperline(r, i->depth);
			c *= Dy(r);
			free(client->readdata);
			client->readdata = mallocz(c, 0);
			if(client->readdata == nil)
				error("readimage malloc failed");
			client->nreaddata = memunload(i, r, client->readdata, c);
			if(client->nreaddata < 0){
				free(client->readdata);
				client->readdata = nil;
				error("bad readimage call");
			}
			continue;

		/* string: 's' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] ni*(index[2]) */
		/* stringbg: 'x' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] bgid[4] bgpt[2*4] ni*(index[2]) */
		case 's':
		case 'x':
			printmesg(fmt="LLLPRPs", a, 0);
			m = 1+4+4+4+2*4+4*4+2*4+2;
			if(*a == 'x')
				m += 4+2*4;
			if(n < m)
				error(Eshortdraw);

			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			font = drawlookup(client, BG32INT(a+9), 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->nfchar == 0)
				error(Enotfont);
			drawpoint(&p, a+13);
			drawrectangle(&r, a+21);
			drawpoint(&sp, a+37);
			ni = BG16INT(a+45);
			u = a+m;
			m += ni*2;
			if(n < m)
				error(Eshortdraw);
			clipr = dst->clipr;
			dst->clipr = r;
			op = drawclientop(client);
			if(*a == 'x'){
				/* paint background */
				l = drawimage(client, a+47);
				drawpoint(&q, a+51);
				r.min.x = p.x;
				r.min.y = p.y-font->ascent;
				r.max.x = p.x;
				r.max.y = r.min.y+Dy(font->image->r);
				j = ni;
				while(--j >= 0){
					ci = BG16INT(u);
					if(ci<0 || ci>=font->nfchar){
						dst->clipr = clipr;
						error(Eindex);
					}
					r.max.x += font->fchar[ci].width;
					u += 2;
				}
				memdraw(dst, r, l, q, memopaque, ZP, op);
				u -= 2*ni;
			}
			q = p;
			while(--ni >= 0){
				ci = BG16INT(u);
				if(ci<0 || ci>=font->nfchar){
					dst->clipr = clipr;
					error(Eindex);
				}
				q = drawchar(dst, q, src, &sp, font, ci, op);
				u += 2;
			}
			dst->clipr = clipr;
			p.y -= font->ascent;
			dstflush(dst, Rect(p.x, p.y, q.x, p.y+Dy(font->image->r)));
			continue;

		/* use public screen: 'S' id[4] chan[4] */
		case 'S':
			printmesg(fmt="Ll", a, 0);
			m = 1+4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(dstid == 0)
				error(Ebadarg);
			dscrn = drawlookupdscreen(dstid);
			if(dscrn==0 || (dscrn->public==0 && dscrn->owner!=client))
				error(Enodrawscreen);
			if(dscrn->screen->image->chan != BG32INT(a+5))
				error("inconsistent chan");
			if(drawinstallscreen(client, dscrn, 0, 0, 0, 0) == 0)
				error(Edrawmem);
			continue;

		/* top or bottom windows: 't' top[1] nw[2] n*id[4] */
		case 't':
			printmesg(fmt="bsL", a, 0);
			m = 1+1+2;
			if(n < m)
				error(Eshortdraw);
			nw = BG16INT(a+2);
			if(nw < 0)
				error(Ebadarg);
			if(nw == 0)
				continue;
			m += nw*4;
			if(n < m)
				error(Eshortdraw);
			lp = malloc(nw*sizeof(Memimage*));
			if(lp == 0)
				error(Enomem);
			if(waserror()){
				free(lp);
				nexterror();
			}
			for(j=0; j<nw; j++)
				lp[j] = drawimage(client, a+1+1+2+j*4);
			if(lp[0]->layer == 0)
				error("images are not windows");
			for(j=1; j<nw; j++)
				if(lp[j]->layer->screen != lp[0]->layer->screen)
					error("images not on same screen");
			if(a[1])
				memltofrontn(lp, nw);
			else
				memltorearn(lp, nw);
			if(lp[0]->layer->screen->image->data == screenimage->data)
				for(j=0; j<nw; j++)
					dstflush(lp[j]->layer->screen->image, lp[j]->layer->screenr);
			ll = drawlookup(client, BG32INT(a+1+1+2), 1);
			drawrefreshscreen(ll, client);
			poperror();
			free(lp);
			continue;

		/* visible: 'v' */
		case 'v':
			printmesg(fmt="", a, 0);
			m = 1;
			drawflush();
			continue;

		/*
		 * draw3d extension (optional; old clients never send these).
		 * '3'                 — capability probe (no body)
		 * 'C' dstid[4]        — write explicit capability bits to 32-bit image
		 * 'M' which[1] m[16*4] — load model(0)/proj(1) float32 LE matrix (row-major)
		 * 'w' mx cx my cy[4*4] — viewport: screen = (mx*ndc.x+cx, my*ndc.y+cy)
		 * 'u' flags[1]         — bit0 zenable, bit1 clipbehind
		 * 'z' dstid[4]         — clear (and size) software z-buffer for dst
		 * 'g' dstid srcid n[2] xyz... — fillpoly3 (compat; no normal/lit)
		 * 'k' dstid srcid n[2] nxyz lit xyz... — fillpoly3 with normal+lit
		 * 'G' dstid srcid thick a[3] b[3] — line3
		 * 'h' dstid srcid xyz[3] — plot3
		 * 'j' dstid img mask flags scale degz xyz [mat16] — sprite3 family
		 * 'q' dstid srcid flags thick xyz rx ry — circle/ellipse
		 * 'g'/'G'/'k'/'h'/'j'/'q' may be Metal-batched on Cocoa (depth + overlay).
		 */
		case '3':
			printmesg(fmt="", a, 0);
			m = 1;
			continue;

		case 'C':	/* explicit draw3d capabilities: C dstid[4] */
			printmesg(fmt="L", a, 0);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			i = drawimage(client, a+1);
			if(i->depth != 32 || Dx(i->r) < 1 || Dy(i->r) < 1)
				error(Ebadarg);
			value = D3CapMatrix | D3CapFill | D3CapLine | D3CapPlot
				| D3CapSprite | D3CapEllipse | D3CapNearClip | D3CapDepthOrder;
			if(gpudrawfillpoly != nil)
				value |= D3CapGPU;
			if(gpudrawreadback != nil)
				value |= D3CapReadback;
			u = byteaddr(i, i->r.min);
			u[0] = value;
			u[1] = value>>8;
			u[2] = value>>16;
			u[3] = value>>24;
			continue;

		case 'M':
			printmesg(fmt="b", a, 0);
			m = 1+1+16*4;
			if(n < m)
				error(Eshortdraw);
			if(a[1] == 0)
				d3loadmat(client->d3model, a+2);
			else if(a[1] == 1)
				d3loadmat(client->d3proj, a+2);
			else
				error(Ebadarg);
			continue;

		case 'w':
			printmesg(fmt="", a, 0);
			m = 1+4*4;
			if(n < m)
				error(Eshortdraw);
			client->d3mx = bgfloat(a+1);
			client->d3cx = bgfloat(a+5);
			client->d3my = bgfloat(a+9);
			client->d3cy = bgfloat(a+13);
			continue;

		case 'u':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			client->d3zenable = a[1] & 1;
			client->d3clipbehind = (a[1] & 2) != 0;
			if(gpudrawzenable)
				gpudrawzenable(client->d3zenable);
			continue;

		case 'z':
			printmesg(fmt="L", a, 0);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			d3clearz(client, dst);
			if(gpudrawzclear)
				gpudrawzclear();
			continue;

		case 'g':	/* fillpoly3 (compat) */
		case 'k':	/* fillpoly3 + normal + lit */
			printmesg(fmt="LLS", a, 0);
			m = 1+4+4+2;
			if(*a == 'k')
				m += 4*4;	/* nx ny nz lit */
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			nw = BG16INT(a+9);
			if(nw < 3 || nw > 1024)
				error(Ebadarg);
			{
				int hdr;
				float nx, ny, nz, lit;
				float *vx, *vy, *vz, *ix, *iy, *iz;
				Memimage *lsrc, *ltmp;
				int pdx, pdy, pdc, haveplane, gpudone;

				hdr = 11;
				nx = ny = 0.0f;
				nz = 1.0f;
				lit = 1.0f;
				ltmp = nil;
				lsrc = nil;
				if(*a == 'k'){
					nx = bgfloat(a+11);
					ny = bgfloat(a+15);
					nz = bgfloat(a+19);
					lit = bgfloat(a+23);
					hdr = 27;
				}
				m = hdr + nw * 3 * 4;
				if(n < m)
					error(Eshortdraw);
				pp = malloc(sizeof(Point) * (nw + 2));
				if(pp == nil)
					error(Edrawmem);
				if(waserror()){
					free(pp);
					nexterror();
				}
				vx = malloc(sizeof(float) * (nw + 1) * 6);
				if(vx == nil){
					poperror();
					free(pp);
					error(Edrawmem);
				}
				vy = vx + nw + 1;
				vz = vy + nw + 1;
				ix = vz + nw + 1;
				iy = ix + nw + 1;
				iz = iy + nw + 1;
				if(waserror()){
					free(vx);
					nexterror();
				}
				{
					float *ezs, ez;

					ezs = malloc(sizeof(float) * (nw + 1));
					if(ezs == nil){
						poperror();
						free(vx);
						poperror();
						free(pp);
						error(Edrawmem);
					}
					if(waserror()){
						free(ezs);
						nexterror();
					}
					for(j = 0; j < nw; j++){
						float fx, fy, fz;

						fx = bgfloat(a+hdr + j*12);
						fy = bgfloat(a+hdr + j*12 + 4);
						fz = bgfloat(a+hdr + j*12 + 8);
						ix[j] = fx;
						iy[j] = fy;
						iz[j] = fz;
					}
					nw = d3clipnear(client, ix, iy, iz, nw, vx, vy, vz);
					if(nw < 3){
						poperror();
						free(ezs);
						poperror();
						free(vx);
						poperror();
						free(pp);
						goto gdone;
					}
					op = drawclientop(client);
					/*
					 * GPU-T&L: hand the raw clipped world verts straight to
					 * Metal and let vgmain do model*proj+viewport - skips
					 * this whole function's per-vertex d3project() loop
					 * *and* the plane-fit below (d3planecoeffs/
					 * d3planefromeyez only exist because the old
					 * screen-space GPU/software paths interpolate depth
					 * linearly across the triangle; true hardware
					 * perspective-correct interpolation of a real eye-z
					 * needs no such approximation).
					 */
					if(gpudrawfillpoly3d != nil && gpudrawfillpoly3d(dst,
					    vx, vy, vz, nw, src, op, lit, client->d3model,
					    client->d3proj, client->d3mx, client->d3cx,
					    client->d3my, client->d3cy)){
						poperror();
						free(ezs);
						poperror();
						free(vx);
						poperror();
						free(pp);
						goto gdone;
					}
					for(j = 0; j < nw; j++){
						if(!d3project(client, vx[j], vy[j], vz[j], &pp[j], &ez)){
							poperror();
							free(ezs);
							poperror();
							free(vx);
							poperror();
							free(pp);
							goto gdone;
						}
						ezs[j] = ez;
					}
					pp[nw] = pp[0];
					haveplane = 0;
					pdx = pdy = pdc = 0;
					if(client->d3zenable){
						if(*a == 'k' && nz != 0.0f && d3modelisident(client))
							haveplane = d3planecoeffs(client, nx, ny, nz,
								vx, vy, vz, nw, &pdx, &pdy, &pdc);
						if(!haveplane)
							haveplane = d3planefromeyez(pp, ezs, nw,
								&pdx, &pdy, &pdc);
						/* Plane z → eye-like for Metal sort-only depth map. */
						if(haveplane){
							for(j = 0; j < nw; j++){
								float pz;

								pz = ((float)pdc + (float)pdx*(float)pp[j].x
									+ (float)pdy*(float)pp[j].y)
									/ (float)D3ZSCALE;
								/* Map plane z → eye-like: closer ⇒ more negative. */
								ezs[j] = -pz;
							}
						}
					}
					gpudone = 0;
					if(gpudrawfillpoly != nil)
						gpudone = gpudrawfillpoly(dst, pp, ezs, nw, src, op, lit);
					if(!gpudone){
						lsrc = d3applylit(src, lit, &ltmp);
						if(waserror()){
							if(ltmp)
								freememimage(ltmp);
							nexterror();
						}
						if(client->d3zenable && haveplane)
							d3fillpolyz(client, dst, pp, nw, lsrc, op, pdc, pdx, pdy);
						else
							memfillpoly(dst, pp, nw+1, ~0, lsrc, pp[0], op);
						poperror();
						if(ltmp)
							freememimage(ltmp);
					}
					poperror();
					free(ezs);
				}
				/* flush bbox of projected verts */
				r = dst->clipr;
				if(nw > 0){
					r.min = r.max = pp[0];
					for(j = 1; j < nw; j++){
						if(pp[j].x < r.min.x) r.min.x = pp[j].x;
						if(pp[j].y < r.min.y) r.min.y = pp[j].y;
						if(pp[j].x > r.max.x) r.max.x = pp[j].x;
						if(pp[j].y > r.max.y) r.max.y = pp[j].y;
					}
					r.max.x++;
					r.max.y++;
				}
				dstflush(dst, r);
				poperror();
				free(vx);
				poperror();
				free(pp);
			}
		gdone:
			continue;

		case 'G':	/* line3 */
			printmesg(fmt="LLl", a, 0);
			m = 1+4+4+4+6*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			j = BG32INT(a+9);	/* thick */
			if(j < 0)
				error("negative line width");
			{
				float ax, ay, az, bx, by, bz, eza, ezb;
				Point pa, pb;
				int gpudone;

				ax = bgfloat(a+13);
				ay = bgfloat(a+17);
				az = bgfloat(a+21);
				bx = bgfloat(a+25);
				by = bgfloat(a+29);
				bz = bgfloat(a+33);
				if(!d3projectline(client, ax, ay, az, bx, by, bz,
				    &pa, &pb, &eza, &ezb))
					continue;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawline != nil)
					gpudone = gpudrawline(dst, pa, pb, j, src, op, eza, ezb);
				if(!gpudone)
					d3linez(client, dst, pa, pb, j, src, op, eza, ezb);
				if(dst == screenimage || dst->layer != nil){
					r = memlinebbox(pa, pb, Endsquare, Endsquare, j);
					dstflush(dst, insetrect(r, -(1+1+j)));
				}
			}
			continue;

		case 'h':	/* plot3 */
			printmesg(fmt="LL", a, 0);
			m = 1+4+4+3*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			{
				float fx, fy, fz, ez;
				Point pa;
				int gpudone, zk;

				fx = bgfloat(a+9);
				fy = bgfloat(a+13);
				fz = bgfloat(a+17);
				if(!d3project(client, fx, fy, fz, &pa, &ez))
					continue;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawplot != nil)
					gpudone = gpudrawplot(dst, pa, src, op, ez);
				if(!gpudone){
					if(client->d3zenable && client->d3zbuf != nil
					&& ptinrect(pa, client->d3zr)){
						zk = (pa.y - client->d3zr.min.y)*client->d3zw
							+ (pa.x - client->d3zr.min.x);
						if(zk >= 0 && zk < client->d3zw*client->d3zh){
							int z;

							z = (int)((-ez) * (float)D3ZSCALE);
							if(z < client->d3zbuf[zk]){
								client->d3zbuf[zk] = z;
								memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
									src, ZP, memopaque, ZP, op);
							}
						}else
							memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
								src, ZP, memopaque, ZP, op);
					}else
						memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
							src, ZP, memopaque, ZP, op);
				}
				dstflush(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1));
			}
			continue;

		case 'j':	/* sprite3 family */
			printmesg(fmt="LLLb", a, 0);
			m = 1+4+4+4+1+4+4+3*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);	/* img */
			{
				u32 maskid;
				int flags, gpudone;
				float scale, degz, fx, fy, fz, ez, sc;
				Point sp;
				Memimage *mask;
				Rectangle dr;
				int iw, ih, sw, sh;
				float mat[16];
				float qx, qy, qz;
				DImage *dmask;

				maskid = BG32INT(a+9);
				flags = a[13];
				scale = bgfloat(a+14);
				degz = bgfloat(a+18);
				fx = bgfloat(a+22);
				fy = bgfloat(a+26);
				fz = bgfloat(a+30);
				mask = nil;
				if((flags & 1) && maskid != 0){
					dmask = drawlookup(client, (int)maskid, 1);
					if(dmask != nil)
						mask = dmask->image;
				}
				if(flags & 8){	/* sprite3mat: matrix then origin at p */
					m = 1+4+4+4+1+4+4+3*4+16*4;
					if(n < m)
						error(Eshortdraw);
					d3loadmat(mat, a+34);
					d3mulpoint(mat, 0, 0, 0, &qx, &qy, &qz);
					fx += qx;
					fy += qy;
					fz += qz;
				}
				if(!d3project(client, fx, fy, fz, &sp, &ez))
					continue;
				iw = Dx(src->r);
				ih = Dy(src->r);
				sc = 1.0f;
				if(scale > 0.0f && ez < 0.0f)
					sc = scale / (-ez);
				else if(ez < 0.0f)
					sc = 1.0f / (-ez);
				sw = (int)((float)iw * sc);
				sh = (int)((float)ih * sc);
				if(flags & 4)
					sh = (int)((float)sh * 0.85f);
				if(sw < 1) sw = 1;
				if(sh < 1) sh = 1;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawsprite != nil)
					gpudone = gpudrawsprite(dst, sp, sw, sh, ez, src, mask, degz, op);
				if(!gpudone){
					d3spritez(client, dst, sp, sw, sh, ez, src, mask, degz, op);
					dr = Rect(sp.x - sw, sp.y - sh, sp.x + sw + 1, sp.y + sh + 1);
					dstflush(dst, dr);
				}else
					dstflush(dst, Rect(sp.x - sw/2, sp.y - sh/2,
						sp.x - sw/2 + sw, sp.y - sh/2 + sh));
			}
			continue;

		case 'q':	/* circle/ellipse (immediate mode) */
			printmesg(fmt="LLb", a, 0);
			m = 1+4+4+1+4+3*4+4+4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			{
				int flags, thick, rx, ry, gpudone, fill;
				float fx, fy, fz, ez;
				Point pa;

				flags = a[9];
				thick = BG32INT(a+10);
				if(thick < 0)
					error("negative ellipse thickness");
				fx = bgfloat(a+14);
				fy = bgfloat(a+18);
				fz = bgfloat(a+22);
				rx = (int)bgfloat(a+26);
				ry = (int)bgfloat(a+30);
				if(rx < 0) rx = -rx;
				if(ry < 0) ry = -ry;
				if(!d3project(client, fx, fy, fz, &pa, &ez))
					continue;
				fill = flags & 1;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawellipse != nil)
					gpudone = gpudrawellipse(dst, pa, rx, ry, thick, fill, src, op, ez);
				if(!gpudone)
					d3ellipsez(client, dst, pa, rx, ry, thick, fill, src, op, ez);
				dstflush(dst, Rect(pa.x - rx - thick - 1, pa.y - ry - thick - 1,
					pa.x + rx + thick + 2, pa.y + ry + thick + 2));
			}
			continue;

		/* write: 'y' id[4] R[4*4] data[x*1] */
		/* write from compressed data: 'Y' id[4] R[4*4] data[x*1] */
		case 'y':
		case 'Y':
			printmesg(fmt="LR", a, 0);
		//	iprint("load %c\n", *a);
			m = 1+4+4*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			drawrectangle(&r, a+5);
			if(!rectinrect(r, dst->r))
				error(Ewriteoutside);
			y = memload(dst, r, a+m, n-m, *a=='Y');
			if(y < 0)
				error("bad writeimage call");
			dstflush(dst, r);
			m += y;
			continue;
		}
	}
	poperror();
}

int
drawlsetrefresh(ulong qidpath, int id, void *reffn, void *refx)
{
	DImage *d;
	Memimage *i;
	Client *client;

	client = drawclientofpath(qidpath);
	if(client == 0)
		return 0;
	d = drawlookup(client, id, 0);
	if(d == nil)
		return 0;
	i = d->image;
	if(i->layer == nil)
		return 0;
	return memlsetrefresh(i, reffn, refx);
}

void
drawqlock(void)
{
	lock(&sdraw.q);
}

void
drawqunlock(void)
{
	unlock(&sdraw.q);
}

void
interf(void)
{
	/* force it to load */
	drawreplxy(0, 0, 0);
}

Dev drawdevtab = {
	'i',
	"draw",

	devinit,
	drawattach,
	drawwalk,
	drawstat,
	drawopen,
	devcreate,
	drawclose,
	drawread,
	devbread,
	drawwrite,
	devbwrite,
	devremove,
	devwstat,
};
