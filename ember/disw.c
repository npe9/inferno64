#include "ember.h"

/*
 * .dis object writer, ported from limbo/dis.c.  the operand
 * encoding (discon), section order, and linkage records must
 * match what libinterp/load.c parsemod expects.
 */

static	void	disbig(long, Long);
static	void	disbyte(long, int);
static	void	disbytes(long, void*, int);
static	void	disdatum(long, Node*);
static	void	disflush(int, long, long);
static	void	disint(long, long);
static	void	disreal(long, Real);
static	void	disstring(long, Sym*);

static	uchar	*cache;
static	int	ncached;
static	int	ndatum;
static	int	startoff;
static	int	lastoff;
static	int	lastkind;
static	int	lencache;

static void
dtocanon(double f, u32 v[])
{
	union { double d; u32 ul[2]; } a;

	a.d = 1.;
	if(a.ul[0]){
		a.d = f;
		v[0] = a.ul[0];
		v[1] = a.ul[1];
	}else{
		a.d = f;
		v[0] = a.ul[1];
		v[1] = a.ul[0];
	}
}

void
discon(long val)
{
	if(val >= -64 && val <= 63) {
		Bputc(bout, val & ~0x80);
		return;
	}
	if(val >= -8192 && val <= 8191) {
		Bputc(bout, ((val>>8) & ~0xC0) | 0x80);
		Bputc(bout, val);
		return;
	}
	if(val < 0 && ((val >> 29) & 0x7) != 7
	|| val > 0 && (val >> 29) != 0)
		fatal("overflow in constant 0x%lux", val);
	Bputc(bout, (val>>24) | 0xC0);
	Bputc(bout, val>>16);
	Bputc(bout, val>>8);
	Bputc(bout, val);
}

void
disword(long w)
{
	Bputc(bout, w >> 24);
	Bputc(bout, w >> 16);
	Bputc(bout, w >> 8);
	Bputc(bout, w);
}

void
disdata(int kind, long n)
{
	if(n < DMAX && n != 0)
		Bputc(bout, DBYTE(kind, n));
	else{
		Bputc(bout, DBYTE(kind, 0));
		discon(n);
	}
}

#define	NAMELEN	64

void
dismod(Decl *m)
{
	char name[8*NAMELEN];

	strncpy(name, m->sym->name, NAMELEN);
	name[NAMELEN-1] = '\0';
	Bwrite(bout, name, strlen(name)+1);
	for(m = m->ty->tof->ids; m != nil; m = m->next){
		switch(m->store){
		case Dglobal:
			discon(-1);
			discon(-1);
			disword(sign(m));
			Bprint(bout, ".mp");
			Bputc(bout, '\0');
			break;
		case Dfn:
			discon(m->pc->pc);
			discon(m->desc->id);
			disword(sign(m));
			if(m->dot->ty->kind == Tadt)
				Bprint(bout, "%s.", m->dot->sym->name);
			Bprint(bout, "%s", m->sym->name);
			Bputc(bout, '\0');
			break;
		default:
			fatal("unknown kind %d in dismod", m->store);
			break;
		}
	}
}

void
dispath(void)
{
	char name[8*NAMELEN];

	strncpy(name, infile, sizeof(name));
	name[sizeof(name)-1] = '\0';
	Bwrite(bout, name, strlen(name)+1);
}

void
disentry(Decl *e)
{
	if(e == nil){
		discon(-1);
		discon(-1);
		return;
	}
	discon(e->pc->pc);
	discon(e->desc->id);
}

void
disdesc(Desc *d)
{
	for(; d != nil; d = d->next){
		discon(d->id);
		discon(d->size);
		discon(d->nmap);
		Bwrite(bout, d->map, d->nmap);
	}
}

void
disvar(long size, Decl *d)
{
	USED(size);

	lastkind = -1;
	ncached = 0;
	ndatum = 0;

	for(; d != nil; d = d->next)
		if(d->store == Dglobal && d->init != nil)
			disdatum(d->offset, d->init);

	disflush(-1, -1, 0);

	Bputc(bout, 0);
}

void
disldt(long size, Decl *ds)
{
	int m;
	Decl *d, *id;
	Sym *s;
	Node *n;

	USED(size);

	m = 0;
	for(d = ds; d != nil; d = d->next)
		if(d->store == Dglobal && d->init != nil)
			m++;
	discon(m);
	for(d = ds; d != nil; d = d->next){
		if(d->store == Dglobal && d->init != nil){
			n = d->init;
			if(n->ty->kind != Tiface)
				fatal("disldt: not Tiface");
			discon(n->val);
			for(id = n->decl->ty->ids; id != nil; id = id->next){
				disword(sign(id));
				if(id->dot->ty->kind == Tadt){
					s = id->dot->sym;
					Bprint(bout, "%s", s->name);
					Bputc(bout, '.');
				}
				s = id->sym;
				Bprint(bout, "%s", s->name);
				Bputc(bout, 0);
			}
		}
	}
	discon(0);
}

static void
disdatum(long offset, Node *n)
{
	Decl *id;
	Sym *s;

	switch(n->ty->kind){
	case Tbyte:
		disbyte(offset, n->val);
		break;
	case Tint:
		disint(offset, n->val);
		break;
	case Tbig:
		disbig(offset, n->val);
		break;
	case Tstring:
		disstring(offset, n->decl->sym);
		break;
	case Treal:
		disreal(offset, n->rval);
		break;
	case Tadt:
	case Tadtpick:
	case Ttuple:
		id = n->ty->ids;
		for(n = n->left; n != nil; n = n->right){
			disdatum(offset + id->offset, n->left);
			id = id->next;
		}
		break;
	case Tany:
		break;
	case Tiface:
		disint(offset, n->val);
		offset += IBY2WD;
		for(id = n->decl->ty->ids; id != nil; id = id->next){
			offset = align(offset, IBY2WD);
			disint(offset, sign(id));
			offset += IBY2WD;

			if(id->dot->ty->kind == Tadt){
				s = id->dot->sym;
				disbytes(offset, s->name, s->len);
				offset += s->len;
				disbyte(offset, '.');
				offset++;
			}
			s = id->sym;
			disbytes(offset, s->name, s->len);
			offset += s->len;
			disbyte(offset, 0);
			offset++;
		}
		break;
	default:
		fatal("can't dis global type %T", n->ty);
		break;
	}
}

static void
disbyte(long off, int v)
{
	disflush(DEFB, off, 1);
	cache[ncached++] = v;
	ndatum++;
}

static void
disbytes(long off, void *v, int n)
{
	disflush(DEFB, off, n);
	memmove(&cache[ncached], v, n);
	ncached += n;
	ndatum += n;
}

static void
disint(long off, long v)
{
	disflush(DEFW, off, IBY2WD);
	cache[ncached++] = v >> 24;
	cache[ncached++] = v >> 16;
	cache[ncached++] = v >> 8;
	cache[ncached++] = v;
	ndatum++;
}

static void
disbig(long off, Long v)
{
	u32 iv;

	disflush(DEFL, off, IBY2LG);
	iv = v >> 32;
	cache[ncached++] = iv >> 24;
	cache[ncached++] = iv >> 16;
	cache[ncached++] = iv >> 8;
	cache[ncached++] = iv;
	iv = v;
	cache[ncached++] = iv >> 24;
	cache[ncached++] = iv >> 16;
	cache[ncached++] = iv >> 8;
	cache[ncached++] = iv;
	ndatum++;
}

static void
disreal(long off, Real v)
{
	u32 bv[2];
	u32 iv;

	disflush(DEFF, off, IBY2LG);
	dtocanon(v, bv);
	iv = bv[0];
	cache[ncached++] = iv >> 24;
	cache[ncached++] = iv >> 16;
	cache[ncached++] = iv >> 8;
	cache[ncached++] = iv;
	iv = bv[1];
	cache[ncached++] = iv >> 24;
	cache[ncached++] = iv >> 16;
	cache[ncached++] = iv >> 8;
	cache[ncached++] = iv;
	ndatum++;
}

static void
disstring(long offset, Sym *sym)
{
	disflush(-1, -1, 0);
	disdata(DEFS, sym->len);
	discon(offset);
	Bwrite(bout, sym->name, sym->len);
}

static void
disflush(int kind, long off, long size)
{
	if(kind != lastkind || off != lastoff){
		if(lastkind != -1 && ncached){
			disdata(lastkind, ndatum);
			discon(startoff);
			Bwrite(bout, cache, ncached);
		}
		startoff = off;
		lastkind = kind;
		ncached = 0;
		ndatum = 0;
	}
	lastoff = off + size;
	while(kind >= 0 && ncached + size >= lencache){
		lencache = ncached+1024;
		cache = reallocmem(cache, lencache);
	}
}

static int dismode[Aend] = {
	/* Aimm */	AIMM,
	/* Amp */	AMP,
	/* Ampind */	AMP|AIND,
	/* Afp */	AFP,
	/* Afpind */	AFP|AIND,
	/* Apc */	AIMM,
	/* Adesc */	AIMM,
	/* Aoff */	AIMM,
	/* Anoff */	AIMM,
	/* Aerr */	AXXX,
	/* Anone */	AXXX,
	/* Aldt */	AIMM,
};

static int disregmode[Aend] = {
	/* Aimm */	AXIMM,
	/* Amp */	AXINM,
	/* Ampind */	AXNON,
	/* Afp */	AXINF,
	/* Afpind */	AXNON,
	/* Apc */	AXIMM,
	/* Adesc */	AXIMM,
	/* Aoff */	AXIMM,
	/* Anoff */	AXIMM,
	/* Aerr */	AXNON,
	/* Anone */	AXNON,
	/* Aldt */	AXIMM,
};

enum
{
	MAXCON	= 4,
	MAXADDR	= 2*MAXCON,
	MAXINST	= 3*MAXADDR+2,
	NIBUF	= 1024
};

static	uchar	*ibuf;
static	int	nibuf;

static	void	disaddr(int, Addr*);
static	void	disbcon(long);

void
disinst(Inst *in)
{
	ibuf = allocmem(NIBUF);
	nibuf = 0;
	for(; in != nil; in = in->next){
		if(in->op == INOOP)
			continue;
		if(nibuf >= NIBUF-MAXINST){
			Bwrite(bout, ibuf, nibuf);
			nibuf = 0;
		}
		ibuf[nibuf++] = in->op;
		ibuf[nibuf++] = SRC(dismode[in->sm]) | DST(dismode[in->dm]) | disregmode[in->mm];
		if(in->mm != Anone)
			disaddr(in->mm, &in->m);
		if(in->sm != Anone)
			disaddr(in->sm, &in->s);
		if(in->dm != Anone)
			disaddr(in->dm, &in->d);
	}
	if(nibuf > 0)
		Bwrite(bout, ibuf, nibuf);
	free(ibuf);
	ibuf = nil;
}

static void
disaddr(int m, Addr *a)
{
	long val;

	val = 0;
	switch(m){
	case Anone:
	case Aerr:
	default:
		break;
	case Aimm:
	case Apc:
	case Adesc:
		val = a->offset;
		break;
	case Aoff:
		val = a->decl->iface->offset;
		break;
	case Anoff:
		val = -(a->decl->iface->offset+1);
		break;
	case Afp:
	case Amp:
	case Aldt:
		val = a->reg;
		break;
	case Afpind:
	case Ampind:
		disbcon(a->reg);
		val = a->offset;
		break;
	}
	disbcon(val);
}

static void
disbcon(long val)
{
	if(val >= -64 && val <= 63){
		ibuf[nibuf++] = val & ~0x80;
		return;
	}
	if(val >= -8192 && val <= 8191){
		ibuf[nibuf++] = val>>8 & ~0xC0 | 0x80;
		ibuf[nibuf++] = val;
		return;
	}
	if(val < 0 && ((val >> 29) & 7) != 7
	|| val > 0 && (val >> 29) != 0)
		fatal("overflow in constant 16r%lux", val);
	ibuf[nibuf++] = val>>24 | 0xC0;
	ibuf[nibuf++] = val>>16;
	ibuf[nibuf++] = val>>8;
	ibuf[nibuf++] = val;
}
