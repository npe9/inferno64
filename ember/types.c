#include "ember.h"
#include "mp.h"
#include "libsec.h"

/*
 * backend type model, sizing, gc descriptors, equivalence
 * classes, and md5 interface signatures.
 *
 * this is a careful port of the corresponding logic in
 * limbo/types.c; the signature and layout algorithms must match
 * limbo's exactly or ember modules cannot link against limbo
 * modules at runtime (libinterp/link.c compares the md5-folded
 * signatures, and the gc walks frames using the descriptor maps).
 */

char *kindname[Tend] =
{
	/* Tnone */	"no type",
	/* Tadt */	"adt",
	/* Tadtpick */	"adt",
	/* Tarray */	"array",
	/* Tbig */	"big",
	/* Tbyte */	"byte",
	/* Tchan */	"chan",
	/* Treal */	"real",
	/* Tfn */	"fn",
	/* Tint */	"int",
	/* Tlist */	"list",
	/* Tmodule */	"module",
	/* Tref */	"ref",
	/* Tstring */	"string",
	/* Ttuple */	"tuple",
	/* Texception */	"exception",
	/* Tfix */	"fixed point",
	/* Tpoly */	"polymorphic",

	/* Tainit */	"array initializers",
	/* Talt */	"alt channels",
	/* Tany */	"polymorphic type",
	/* Tarrow */	"->",
	/* Tcase */	"case int labels",
	/* Tcasel */	"case big labels",
	/* Tcasec */	"case string labels",
	/* Tdot */	".",
	/* Terror */	"type error",
	/* Tgoto */	"goto labels",
	/* Tid */	"id",
	/* Tiface */	"module interface",
	/* Texcept */	"exception handler table",
	/* Tinst */	"instantiated type",
};

Tattr tattr[Tend] =
{
	/*		 isptr	refable	conable	big	vis */
	/* Tnone */	{ 0,	0,	0,	0,	0, },
	/* Tadt */	{ 0,	1,	1,	1,	1, },
	/* Tadtpick */	{ 0,	1,	0,	1,	1, },
	/* Tarray */	{ 1,	0,	0,	0,	1, },
	/* Tbig */	{ 0,	0,	1,	1,	1, },
	/* Tbyte */	{ 0,	0,	1,	0,	1, },
	/* Tchan */	{ 1,	0,	0,	0,	1, },
	/* Treal */	{ 0,	0,	1,	1,	1, },
	/* Tfn */	{ 0,	1,	0,	0,	1, },
	/* Tint */	{ 0,	0,	1,	1,	1, },
	/* Tlist */	{ 1,	0,	0,	0,	1, },
	/* Tmodule */	{ 1,	0,	0,	0,	1, },
	/* Tref */	{ 1,	0,	0,	0,	1, },
	/* Tstring */	{ 1,	0,	1,	0,	1, },
	/* Ttuple */	{ 0,	1,	1,	1,	1, },
	/* Texception */	{ 0,	0,	0,	1,	1, },
	/* Tfix */	{ 0,	0,	1,	0,	1, },
	/* Tpoly */	{ 1,	0,	0,	0,	1, },

	/* Tainit */	{ 0,	0,	0,	1,	0, },
	/* Talt */	{ 0,	0,	0,	1,	0, },
	/* Tany */	{ 1,	0,	0,	0,	0, },
	/* Tarrow */	{ 0,	0,	0,	0,	1, },
	/* Tcase */	{ 0,	0,	0,	1,	0, },
	/* Tcasel */	{ 0,	0,	0,	1,	0, },
	/* Tcasec */	{ 0,	0,	0,	1,	0, },
	/* Tdot */	{ 0,	0,	0,	0,	1, },
	/* Terror */	{ 0,	1,	1,	0,	0, },
	/* Tgoto */	{ 0,	0,	0,	1,	0, },
	/* Tid */	{ 0,	0,	0,	0,	1, },
	/* Tiface */	{ 0,	0,	0,	1,	0, },
	/* Texcept */	{ 0,	0,	0,	1,	0, },
	/* Tinst */	{ 0,	1,	1,	1,	1, },
};

char *storename[Dend] =
{
	/* Dtype */	"type",
	/* Dfn */	"function",
	/* Dglobal */	"global",
	/* Darg */	"argument",
	/* Dlocal */	"local",
	/* Dconst */	"con",
	/* Dfield */	"field",
	/* Dtag */	"pick tag",
	/* Dimport */	"import",
	/* Dunbound */	"unbound",
	/* Dundef */	"undefined",
	/* Dwundef */	"undefined",
};

int storespace[Dend] =
{
	/* Dtype */	0,
	/* Dfn */	0,
	/* Dglobal */	1,
	/* Darg */	1,
	/* Dlocal */	1,
	/* Dconst */	0,
	/* Dfield */	1,
	/* Dtag */	0,
	/* Dimport */	0,
	/* Dunbound */	0,
	/* Dundef */	0,
	/* Dwundef */	0,
};

static	Teq	*eqclass[Tend];
static	int	eqrec;
static	int	eqset;

static	int	rtequal(Type*, Type*);
static	int	cleareqrec(Type*);
static	int	idequal(Decl*, Decl*, int, int*);
static	int	assumeteq(Type*, Type*);
static	int	rtsign(Type*, uchar*, int, int);
static	int	clearrec(Type*);
static	int	idsign(Decl*, int, uchar*, int, int);
static	int	idsign1(Decl*, int, uchar*, int, int);

void
typeinit(void)
{
	tbig = mktype(&nosrc, Tbig, nil, nil);
	tbig->size = IBY2LG;
	tbig->align = IBY2LG;
	tbig->ok = OKmask;

	tbyte = mktype(&nosrc, Tbyte, nil, nil);
	tbyte->size = 1;
	tbyte->align = 1;
	tbyte->ok = OKmask;

	tint = mktype(&nosrc, Tint, nil, nil);
	tint->size = IBY2WD;
	tint->align = IBY2WD;
	tint->ok = OKmask;

	treal = mktype(&nosrc, Treal, nil, nil);
	treal->size = IBY2LG;
	treal->align = IBY2LG;
	treal->ok = OKmask;

	tstring = mktype(&nosrc, Tstring, nil, nil);
	tstring->size = IBY2WD;
	tstring->align = IBY2WD;
	tstring->ok = OKmask;

	tany = mktype(&nosrc, Tany, nil, nil);
	tany->size = IBY2WD;
	tany->align = IBY2WD;
	tany->ok = OKmask;

	tnone = mktype(&nosrc, Tnone, nil, nil);
	tnone->size = 0;
	tnone->align = 1;
	tnone->ok = OKmask;

	terror = mktype(&nosrc, Terror, nil, nil);
	terror->size = 0;
	terror->align = 1;
	terror->ok = OKmask;

	tunknown = mktype(&nosrc, Terror, nil, nil);
	tunknown->size = 0;
	tunknown->align = 1;
	tunknown->ok = OKmask;

	descriptors = nil;
	memset(eqclass, 0, sizeof eqclass);
}

Type*
mktype(Src *src, int kind, Type *tof, Decl *ids)
{
	Type *t;

	t = allocmem(sizeof *t);
	memset(t, 0, sizeof *t);
	if(src != nil)
		t->src = *src;
	t->kind = kind;
	t->tof = tof;
	t->ids = ids;
	return t;
}

Type*
mktalt(Case *c)
{
	Type *t;

	t = mktype(&nosrc, Talt, nil, nil);
	t->cse = c;
	t->ok = OKmask;
	sizetype(t);
	return t;
}

Decl*
mkdecl(Src *src, int store, Type *t)
{
	Decl *d;

	d = allocmem(sizeof *d);
	memset(d, 0, sizeof *d);
	if(src != nil)
		d->src = *src;
	d->store = store;
	d->ty = t;
	d->nid = 1;
	return d;
}

Decl*
dupdecl(Decl *old)
{
	Decl *d;

	d = allocmem(sizeof *d);
	*d = *old;
	d->next = nil;
	return d;
}

Decl*
appdecls(Decl *d, Decl *dd)
{
	Decl *t;

	if(d == nil)
		return dd;
	for(t = d; t->next != nil; t = t->next)
		;
	t->next = dd;
	return d;
}

Decl*
revids(Decl *id)
{
	Decl *d, *next;

	d = nil;
	for(; id != nil; id = next){
		next = id->next;
		id->next = d;
		d = id;
	}
	return d;
}

/*
 * merge sort ids by name; must match limbo's namesort since
 * the order of module interface entries feeds the signature
 * and linkage sections
 */
static Decl*
namemerge(Decl *e, Decl *f)
{
	Decl rock, *d;

	d = &rock;
	while(e != nil && f != nil){
		if(strcmp(e->sym->name, f->sym->name) <= 0){
			d->next = e;
			e = e->next;
		}else{
			d->next = f;
			f = f->next;
		}
		d = d->next;
	}
	if(e != nil)
		d->next = e;
	else
		d->next = f;
	return rock.next;
}

static Decl*
recnamesort(Decl *d, int n)
{
	Decl *r, *dd;
	int i, m;

	if(n <= 1)
		return d;
	m = n / 2 - 1;
	dd = d;
	for(i = 0; i < m; i++)
		dd = dd->next;
	r = dd->next;
	dd->next = nil;
	return namemerge(recnamesort(d, n / 2),
			recnamesort(r, (n + 1) / 2));
}

Decl*
namesort(Decl *d)
{
	Decl *dd;
	int n;

	n = 0;
	for(dd = d; dd != nil; dd = dd->next)
		n++;
	return recnamesort(d, n);
}

long
align(long off, int a)
{
	if(a == 0)
		fatal("align 0");
	while(off % a)
		off++;
	return off;
}

long
idoffsets(Decl *id, long offset, int al)
{
	int a;

	for(; id != nil; id = id->next){
		if(storespace[id->store]){
			if(id->store == Dlocal && id->link != nil){
				id->offset = id->link->offset;
				continue;
			}
			a = id->ty->align;
			if(a == 0)
				a = 1;
			offset = align(offset, a);
			id->offset = offset;
			offset += id->ty->size;
		}
	}
	return align(offset, al);
}

long
idindices(Decl *id)
{
	int i;

	i = 0;
	for(; id != nil; id = id->next){
		if(storespace[id->store])
			id->offset = i++;
	}
	return i;
}

void
sizetype(Type *t)
{
	Decl *id, *tg;
	Szal szal;
	long sz, al, a;

	if(t == nil)
		return;
	if((t->ok & OKsized) == OKsized)
		return;
	t->ok |= OKsized;
	switch(t->kind){
	default:
		fatal("sizetype: unknown type kind %d", t->kind);
		break;
	case Terror:
	case Tnone:
	case Tbyte:
	case Tint:
	case Tbig:
	case Tstring:
	case Tany:
	case Treal:
		fatal("%T should have a size", t);
		break;
	case Tref:
	case Tchan:
	case Tarray:
	case Tlist:
	case Tmodule:
	case Tfix:
	case Tpoly:
		t->size = t->align = IBY2WD;
		break;
	case Ttuple:
	case Tadt:
	case Texception:
		if(t->tags == nil){
			szal = sizeids(t->ids, 0);
			t->size = align(szal.size, szal.align);
			t->align = szal.align;
			return;
		}
		szal = sizeids(t->ids, IBY2WD);
		sz = szal.size;
		al = szal.align;
		if(al < IBY2WD)
			al = IBY2WD;
		for(tg = t->tags; tg != nil; tg = tg->next){
			if((tg->ty->ok & OKsized) == OKsized)
				continue;
			tg->ty->ok |= OKsized;
			szal = sizeids(tg->ty->ids, sz);
			a = szal.align;
			if(a < al)
				a = al;
			tg->ty->size = align(szal.size, a);
			tg->ty->align = a;
		}
		break;
	case Tfn:
		t->size = 0;
		t->align = 1;
		break;
	case Tainit:
		t->size = 0;
		t->align = 1;
		break;
	case Talt:
		t->size = t->cse->nlab * 2*IBY2WD + 2*IBY2WD;
		t->align = IBY2WD;
		break;
	case Tcase:
	case Tcasec:
		t->size = t->cse->nlab * 3*IBY2WD + 2*IBY2WD;
		t->align = IBY2WD;
		break;
	case Tcasel:
		t->size = t->cse->nlab * 6*IBY2WD + 3*IBY2WD;
		t->align = IBY2LG;
		break;
	case Tgoto:
		t->size = t->cse->nlab * IBY2WD + IBY2WD;
		if(t->cse->iwild != nil)
			t->size += IBY2WD;
		t->align = IBY2WD;
		break;
	case Tiface:
		sz = IBY2WD;
		for(id = t->ids; id != nil; id = id->next){
			sz = align(sz, IBY2WD) + IBY2WD;
			sz += id->sym->len + 1;
			if(id->dot->ty->kind == Tadt)
				sz += id->dot->sym->len + 1;
		}
		t->size = sz;
		t->align = IBY2WD;
		break;
	case Texcept:
		t->size = 0;
		t->align = IBY2WD;
		break;
	}
}

Szal
sizeids(Decl *id, long off)
{
	Szal szal;
	int a, al;

	al = 1;
	for(; id != nil; id = id->next){
		if(storespace[id->store]){
			sizetype(id->ty);
			a = id->ty->align;
			if(a == 0)
				a = 1;
			if(a > al)
				al = a;
			off = align(off, a);
			id->offset = off;
			off += id->ty->size;
		}
	}
	szal.size = off;
	szal.align = al;
	return szal;
}

/*
 * gc descriptors: a bit per word, high bit of each byte maps
 * the first word.  identical to limbo's descmap.
 */
Desc*
gendesc(Decl *d, long size, Decl *decls)
{
	USED(d);
	return usedesc(mkdesc(size, decls));
}

Desc*
mkdesc(long size, Decl *d)
{
	uchar *pmap;
	long len, n;

	len = (size+8*IBY2WD-1) / (8*IBY2WD);
	pmap = allocmem(len);
	memset(pmap, 0, len);
	n = descmap(d, pmap, 0);
	if(n >= 0)
		n = n / (8*IBY2WD) + 1;
	else
		n = 0;
	if(n > len)
		fatal("wrote off end of decl map: %ld %ld", n, len);
	return enterdesc(pmap, size, n);
}

Desc*
mktdesc(Type *t)
{
	Desc *d;
	uchar *pmap;
	long len, n;

	if(t->decl == nil){
		t->decl = mkdecl(&t->src, Dtype, t);
		t->decl->sym = enter("_mktdesc_", 0);
	}
	if(t->decl->desc != nil)
		return t->decl->desc;
	len = (t->size+8*IBY2WD-1) / (8*IBY2WD);
	pmap = allocmem(len);
	memset(pmap, 0, len);
	n = tdescmap(t, pmap, 0);
	if(n >= 0)
		n = n / (8*IBY2WD) + 1;
	else
		n = 0;
	if(n > len)
		fatal("wrote off end of type map for %T: %ld %ld", t, n, len);
	d = enterdesc(pmap, t->size, n);
	t->decl->desc = d;
	return d;
}

Desc*
enterdesc(uchar *map, long size, long nmap)
{
	Desc *d, *last;
	int c;

	last = nil;
	for(d = descriptors; d != nil; d = d->next){
		if(d->size > size || d->size == size && d->nmap > nmap)
			break;
		if(d->size == size && d->nmap == nmap){
			c = memcmp(d->map, map, nmap);
			if(c == 0){
				free(map);
				return d;
			}
			if(c > 0)
				break;
		}
		last = d;
	}
	d = allocmem(sizeof *d);
	d->id = -1;
	d->used = 0;
	d->map = map;
	d->size = size;
	d->nmap = nmap;
	if(last == nil){
		d->next = descriptors;
		descriptors = d;
	}else{
		d->next = last->next;
		last->next = d;
	}
	return d;
}

Desc*
usedesc(Desc *d)
{
	d->used = 1;
	return d;
}

long
descmap(Decl *decls, uchar *map, long start)
{
	Decl *d;
	long last, m;

	last = -1;
	for(d = decls; d != nil; d = d->next){
		if(d->store == Dtype && d->ty->kind == Tmodule
		|| d->store == Dfn
		|| d->store == Dconst)
			continue;
		if(d->store == Dlocal && d->link != nil)
			continue;
		m = tdescmap(d->ty, map, d->offset + start);
		if(m >= 0)
			last = m;
	}
	return last;
}

long
tdescmap(Type *t, uchar *map, long offset)
{
	Label *lab;
	long i, e, m;
	int bit;

	if(t == nil)
		return -1;

	m = -1;
	if(t->kind == Talt){
		lab = t->cse->labs;
		e = t->cse->nlab;
		offset += IBY2WD * 2;
		for(i = 0; i < e; i++){
			if(lab[i].isptr){
				bit = offset / IBY2WD % 8;
				map[offset / (8*IBY2WD)] |= 1 << (7 - bit);
				m = offset;
			}
			offset += 2*IBY2WD;
		}
		return m;
	}
	if(t->kind == Tcasec){
		e = t->cse->nlab;
		offset += IBY2WD;
		for(i = 0; i < e; i++){
			bit = offset / IBY2WD % 8;
			map[offset / (8*IBY2WD)] |= 1 << (7 - bit);
			offset += IBY2WD;
			bit = offset / IBY2WD % 8;
			map[offset / (8*IBY2WD)] |= 1 << (7 - bit);
			m = offset;
			offset += 2*IBY2WD;
		}
		return m;
	}

	if(tattr[t->kind].isptr){
		bit = offset / IBY2WD % 8;
		map[offset / (8*IBY2WD)] |= 1 << (7 - bit);
		return offset;
	}
	if(t->kind == Tadtpick)
		t = t->tof;
	if(t->kind == Ttuple || t->kind == Tadt || t->kind == Texception){
		if(t->rec != 0)
			fatal("illegal cyclic type %T in tdescmap", t);
		t->rec = 1;
		offset = descmap(t->ids, map, offset);
		t->rec = 0;
		return offset;
	}

	return -1;
}

/*
 * equivalence classes: adts, tuples, and modules are put in
 * structural classes; the class identity feeds both signature
 * recursion markers and type equality
 */
void
teqclass(Type *t)
{
	Decl *id, *tg;
	Teq *teq;

	if(t == nil || (t->ok & OKclass) == OKclass)
		return;
	t->ok |= OKclass;
	switch(t->kind){
	default:
		return;
	case Tref:
	case Tchan:
	case Tarray:
	case Tlist:
		teqclass(t->tof);
		return;
	case Tadt:
	case Tadtpick:
	case Ttuple:
	case Texception:
		for(id = t->ids; id != nil; id = id->next)
			teqclass(id->ty);
		for(tg = t->tags; tg != nil; tg = tg->next)
			teqclass(tg->ty);
		break;
	case Tmodule:
		if(t->tof == nil)
			t->tof = mkiface(t->decl);
		for(id = t->ids; id != nil; id = id->next)
			teqclass(id->ty);
		break;
	case Tfn:
		for(id = t->ids; id != nil; id = id->next)
			teqclass(id->ty);
		teqclass(t->tof);
		return;
	}

	if((t->ok & OKsized) != OKsized)
		fatal("eqclass type not sized: %T", t);

	for(teq = eqclass[t->kind]; teq != nil; teq = teq->eq){
		if(t->size == teq->ty->size && tequal(t, teq->ty)){
			t->eq = teq;
			if(t->kind == Tmodule)
				joiniface(t, t->eq->ty->tof);
			return;
		}
	}

	t->eq = allocmem(sizeof(Teq));
	t->eq->id = 0;
	t->eq->ty = t;
	t->eq->eq = eqclass[t->kind];
	eqclass[t->kind] = t->eq;
}

int
tequal(Type *t1, Type *t2)
{
	int ok;

	eqrec = 0;
	eqset = 0;
	ok = rtequal(t1, t2);
	cleareqrec(t1);
	cleareqrec(t2);
	eqset = 0;
	return ok;
}

static int
rtequal(Type *t1, Type *t2)
{
	if(t1 == t2)
		return 1;

	if(t1 == nil || t2 == nil)
		return 0;
	if(t1->kind == Terror || t2->kind == Terror)
		return 1;

	if(t1->kind != t2->kind)
		return 0;

	if(t1->eq != nil && t2->eq != nil)
		return t1->eq == t2->eq;

	t1->rec |= TReq;
	t2->rec |= TReq;
	switch(t1->kind){
	default:
		fatal("unknown type %T v %T in rtequal", t1, t2);
	case Tnone:
	case Tbig:
	case Tbyte:
	case Treal:
	case Tint:
	case Tstring:
		fatal("bogus value type %T vs %T in rtequal", t1, t2);
		return 1;
	case Tref:
	case Tlist:
	case Tarray:
	case Tchan:
		if(t1->kind != Tref && assumeteq(t1, t2))
			return 1;
		return rtequal(t1->tof, t2->tof);
	case Tfn:
		if(t1->varargs != t2->varargs)
			return 0;
		if(!idequal(t1->ids, t2->ids, 0, storespace))
			return 0;
		return rtequal(t1->tof, t2->tof);
	case Ttuple:
	case Texception:
		if(t1->kind != t2->kind)
			return 0;
		if(assumeteq(t1, t2))
			return 1;
		return idequal(t1->ids, t2->ids, 0, storespace);
	case Tadt:
	case Tadtpick:
	case Tmodule:
		if(assumeteq(t1, t2))
			return 1;
		if(t1->kind == Tmodule)
			return idequal(t1->tof->ids, t2->tof->ids, 1, nil);
		if(t1->kind == Tadtpick && !rtequal(t1->decl->dot->ty, t2->decl->dot->ty))
			return 0;
		if(!idequal(t1->tags, t2->tags, 1, nil))
			return 0;
		return idequal(t1->ids, t2->ids, 1, storespace);
	}
}

static int
assumeteq(Type *t1, Type *t2)
{
	Type *r1, *r2;

	if(t1->teq == nil && t2->teq == nil){
		eqrec++;
		eqset += 2;
		t1->teq = t2->teq = t1;
	}else{
		if(t1->teq == nil){
			r1 = t1;
			t1 = t2;
			t2 = r1;
		}
		for(r1 = t1->teq; r1 != r1->teq; r1 = r1->teq)
			;
		for(r2 = t2->teq; r2 != nil && r2 != r2->teq; r2 = r2->teq)
			;
		if(r1 == r2)
			return 1;
		if(r2 == nil)
			eqset++;
		t2->teq = t1;
		for(; t2 != r1; t2 = r2){
			r2 = t2->teq;
			t2->teq = r1;
		}
	}
	return 0;
}

static int
idequal(Decl *id1, Decl *id2, int usenames, int *storeok)
{
	if(id1 == id2)
		return 1;

	for(; id1 != nil; id1 = id1->next){
		if(storeok != nil && !storeok[id1->store])
			continue;
		while(id2 != nil && storeok != nil && !storeok[id2->store])
			id2 = id2->next;
		if(id2 == nil
		|| usenames && id1->sym != id2->sym
		|| id1->store != id2->store
		|| id1->implicit != id2->implicit
		|| id1->cyc != id2->cyc
		|| (id1->dot == nil) != (id2->dot == nil)
		|| id1->dot != nil && id2->dot != nil && id1->dot->ty->kind != id2->dot->ty->kind
		|| !rtequal(id1->ty, id2->ty))
			return 0;
		id2 = id2->next;
	}
	while(id2 != nil && storeok != nil && !storeok[id2->store])
		id2 = id2->next;
	return id1 == nil && id2 == nil;
}

static int
cleareqrec(Type *t)
{
	Decl *id;
	int n;

	n = 0;
	for(; t != nil && (t->rec & TReq) == TReq; t = t->tof){
		t->rec &= ~TReq;
		if(t->teq != nil){
			t->teq = nil;
			n++;
		}
		if(t->kind == Tadtpick)
			n += cleareqrec(t->decl->dot->ty);
		if(t->kind == Tmodule)
			t = t->tof;
		for(id = t->ids; id != nil; id = id->next)
			n += cleareqrec(id->ty);
		for(id = t->tags; id != nil; id = id->next)
			n += cleareqrec(id->ty);
	}
	return n;
}

/*
 * module interface construction: collect the external linkage
 * decls (functions, and one flattened adt for the globals) into
 * a name-sorted list, exactly as limbo's mkiface does
 */
Type*
mkiface(Decl *m)
{
	Decl *iface, *last, *globals, *glast, *id, *d;
	Type *t;
	char buf[StrSize];

	iface = last = allocmem(sizeof(Decl));
	memset(iface, 0, sizeof(Decl));
	globals = glast = mkdecl(&m->src, Dglobal, mktype(&m->src, Tadt, nil, nil));
	for(id = m->ty->ids; id != nil; id = id->next){
		switch(id->store){
		case Dglobal:
			glast = glast->next = dupdecl(id);
			id->iface = globals;
			glast->iface = id;
			break;
		case Dfn:
			id->iface = last = last->next = dupdecl(id);
			last->iface = id;
			break;
		case Dtype:
			if(id->ty->kind != Tadt)
				break;
			for(d = id->ty->ids; d != nil; d = d->next){
				if(d->store == Dfn){
					d->iface = last = last->next = dupdecl(d);
					last->iface = d;
				}
			}
			break;
		}
	}
	last->next = nil;
	iface = namesort(iface->next);

	if(globals->next != nil){
		glast->next = nil;
		globals->ty->ids = namesort(globals->next);
		globals->ty->decl = globals;
		globals->sym = enter(".mp", 0);
		globals->dot = m;
		globals->next = iface;
		iface = globals;
	}

	t = mktype(&m->src, Tiface, nil, iface);
	seprint(buf, buf+sizeof(buf), ".m.%s", m->sym->name);
	id = enter(buf, 0)->decl;
	if(id == nil){
		id = mkdecl(&m->src, Dglobal, t);
		id->sym = enter(buf, 0);
		id->sym->decl = id;
	}
	t->decl = id;
	id->ty = t;

	/*
	 * dummy node so the interface is initialized
	 */
	id->init = mkn(Onothing, nil, nil);
	id->init->ty = t;
	id->init->decl = id;
	return t;
}

void
joiniface(Type *mt, Type *t)
{
	Decl *id, *d, *iface, *globals;

	iface = t->ids;
	globals = iface;
	if(iface != nil && iface->store == Dglobal)
		iface = iface->next;
	for(id = mt->tof->ids; id != nil; id = id->next){
		switch(id->store){
		case Dglobal:
			for(d = id->ty->ids; d != nil; d = d->next)
				d->iface->iface = globals;
			break;
		case Dfn:
			id->iface->iface = iface;
			iface = iface->next;
			break;
		default:
			fatal("unknown store %d in joiniface", id->store);
			break;
		}
	}
	if(iface != nil)
		fatal("join iface not matched");
	mt->tof = t;
}

/*
 * create type signatures
 * sign the same information used for testing type equality
 */
u32
sign(Decl *d)
{
	Type *t;
	uchar *sig, md5sig[MD5dlen];
	char buf[StrSize];
	int i, sigend, sigalloc, v;

	t = d->ty;
	if(t->sig != 0)
		return t->sig;

	sig = 0;
	sigend = -1;
	sigalloc = 1024;
	while(sigend < 0 || sigend >= sigalloc){
		sigalloc *= 2;
		sig = reallocmem(sig, sigalloc);
		eqrec = 0;
		sigend = rtsign(t, sig, sigalloc, 0);
		v = clearrec(t);
		if(v != eqrec)
			fatal("recid not balanced in sign: %d %d", v, eqrec);
		eqrec = 0;
	}
	sig[sigend] = '\0';

	if(signdump != nil){
		seprint(buf, buf+sizeof(buf), "%s", d->sym->name);
		if(strcmp(buf, signdump) == 0)
			print("sign %s len %d\n%s\n", d->sym->name, sigend, (char*)sig);
	}

	md5(sig, sigend, md5sig, nil);
	for(i = 0; i < MD5dlen; i += 4)
		t->sig ^= md5sig[i+0] | (md5sig[i+1]<<8) | (md5sig[i+2]<<16) | (md5sig[i+3]<<24);
	free(sig);
	return t->sig;
}

enum
{
	SIGSELF =	'S',
	SIGVARARGS =	'*',
	SIGCYC =	'y',
	SIGREC =	'@'
};

static int sigkind[Tend] =
{
	/* Tnone */	'n',
	/* Tadt */	'a',
	/* Tadtpick */	'p',
	/* Tarray */	'A',
	/* Tbig */	'B',
	/* Tbyte */	'b',
	/* Tchan */	'C',
	/* Treal */	'r',
	/* Tfn */	'f',
	/* Tint */	'i',
	/* Tlist */	'L',
	/* Tmodule */	'm',
	/* Tref */	'R',
	/* Tstring */	's',
	/* Ttuple */	't',
	/* Texception */	'e',
	/* Tfix */	'x',
	/* Tpoly */	'P',
};

static int
rtsign(Type *t, uchar *sig, int lensig, int spos)
{
	Decl *id, *tg;
	char name[32];
	int kind, lenname;

	if(t == nil)
		return spos;

	if(spos < 0 || spos + 8 >= lensig)
		return -1;

	if(t->eq != nil && t->eq->id){
		if(t->eq->id < 0 || t->eq->id > eqrec)
			fatal("sign rec %T %d %d", t, t->eq->id, eqrec);

		sig[spos++] = SIGREC;
		seprint(name, name+sizeof(name), "%d", t->eq->id);
		lenname = strlen(name);
		if(spos + lenname > lensig)
			return -1;
		strcpy((char*)&sig[spos], name);
		spos += lenname;
		return spos;
	}
	if(t->eq != nil){
		eqrec++;
		t->eq->id = eqrec;
	}

	kind = sigkind[t->kind];
	sig[spos++] = kind;
	if(kind == 0)
		fatal("no sigkind for %T", t);

	t->rec = 1;
	switch(t->kind){
	default:
		fatal("bogus type %T in rtsign", t);
		return -1;
	case Tnone:
	case Tbig:
	case Tbyte:
	case Treal:
	case Tint:
	case Tstring:
	case Tpoly:
		return spos;
	case Tref:
	case Tlist:
	case Tarray:
	case Tchan:
		return rtsign(t->tof, sig, lensig, spos);
	case Tfn:
		if(t->varargs != 0)
			sig[spos++] = SIGVARARGS;
		spos = idsign(t->ids, 0, sig, lensig, spos);
		return rtsign(t->tof, sig, lensig, spos);
	case Ttuple:
		return idsign(t->ids, 0, sig, lensig, spos);
	case Tadt:
		/*
		 * this is a little different than in rtequal,
		 * since we flatten the adt we used to represent the globals
		 */
		if(t->eq == nil){
			if(strcmp(t->decl->sym->name, ".mp") != 0)
				fatal("no t->eq field for %T", t);
			spos--;
			for(id = t->ids; id != nil; id = id->next){
				spos = idsign1(id, 1, sig, lensig, spos);
				if(spos < 0 || spos >= lensig)
					return -1;
				sig[spos++] = ';';
			}
			return spos;
		}
		spos = idsign(t->ids, 1, sig, lensig, spos);
		if(spos < 0 || t->tags == nil)
			return spos;

		/*
		 * convert closing ')' to a ',', then sign any tags
		 */
		sig[spos-1] = ',';
		for(tg = t->tags; tg != nil; tg = tg->next){
			lenname = tg->sym->len;
			if(spos + lenname + 2 >= lensig)
				return -1;
			strcpy((char*)&sig[spos], tg->sym->name);
			spos += lenname;
			sig[spos++] = '=';
			sig[spos++] = '>';

			spos = rtsign(tg->ty, sig, lensig, spos);
			if(spos < 0 || spos >= lensig)
				return -1;

			if(tg->next != nil)
				sig[spos++] = ',';
		}
		if(spos >= lensig)
			return -1;
		sig[spos++] = ')';
		return spos;
	case Tadtpick:
		spos = idsign(t->ids, 1, sig, lensig, spos);
		if(spos < 0)
			return spos;
		return rtsign(t->decl->dot->ty, sig, lensig, spos);
	case Tmodule:
		if(t->tof->linkall == 0)
			fatal("signing a narrowed module");

		if(spos >= lensig)
			return -1;
		sig[spos++] = '{';
		for(id = t->tof->ids; id != nil; id = id->next){
			if(id->tag)
				continue;
			if(strcmp(id->sym->name, ".mp") == 0){
				spos = rtsign(id->ty, sig, lensig, spos);
				if(spos < 0)
					return -1;
				continue;
			}
			spos = idsign1(id, 1, sig, lensig, spos);
			if(spos < 0 || spos >= lensig)
				return -1;
			sig[spos++] = ';';
		}
		if(spos >= lensig)
			return -1;
		sig[spos++] = '}';
		return spos;
	}
}

static int
idsign(Decl *id, int usenames, uchar *sig, int lensig, int spos)
{
	int first;

	if(spos >= lensig)
		return -1;
	sig[spos++] = '(';
	first = 1;
	for(; id != nil; id = id->next){
		if(id->store == Dlocal)
			fatal("local %s in idsign", id->sym->name);

		if(!storespace[id->store])
			continue;

		if(!first){
			if(spos >= lensig)
				return -1;
			sig[spos++] = ',';
		}

		spos = idsign1(id, usenames, sig, lensig, spos);
		if(spos < 0)
			return -1;
		first = 0;
	}
	if(spos >= lensig)
		return -1;
	sig[spos++] = ')';
	return spos;
}

static int
idsign1(Decl *id, int usenames, uchar *sig, int lensig, int spos)
{
	char *name;
	int lenname;

	if(usenames){
		name = id->sym->name;
		lenname = id->sym->len;
		if(spos + lenname + 1 >= lensig)
			return -1;
		strcpy((char*)&sig[spos], name);
		spos += lenname;
		sig[spos++] = ':';
	}

	if(spos + 2 >= lensig)
		return -1;

	if(id->implicit != 0)
		sig[spos++] = SIGSELF;

	if(id->cyc != 0)
		sig[spos++] = SIGCYC;

	return rtsign(id->ty, sig, lensig, spos);
}

static int
clearrec(Type *t)
{
	Decl *id;
	int n;

	n = 0;
	for(; t != nil && t->rec; t = t->tof){
		t->rec = 0;
		if(t->eq != nil && t->eq->id != 0){
			t->eq->id = 0;
			n++;
		}
		if(t->kind == Tmodule){
			for(id = t->tof->ids; id != nil; id = id->next)
				n += clearrec(id->ty);
			return n;
		}
		if(t->kind == Tadtpick)
			n += clearrec(t->decl->dot->ty);
		for(id = t->ids; id != nil; id = id->next)
			n += clearrec(id->ty);
		for(id = t->tags; id != nil; id = id->next)
			n += clearrec(id->ty);
	}
	return n;
}

/*
 * formatted printing of types and decls, for diagnostics
 */
static char*
tprint(char *p, char *e, Type *t)
{
	Decl *id;

	if(t == nil)
		return secpy(p, e, "nil");
	switch(t->kind){
	case Tref:
		p = secpy(p, e, "ref ");
		return tprint(p, e, t->tof);
	case Tarray:
		p = secpy(p, e, "array of ");
		return tprint(p, e, t->tof);
	case Tlist:
		p = secpy(p, e, "list of ");
		return tprint(p, e, t->tof);
	case Tchan:
		p = secpy(p, e, "chan of ");
		return tprint(p, e, t->tof);
	case Tadt:
	case Tmodule:
	case Tpoly:
		if(t->decl != nil && t->decl->sym != nil)
			return secpy(p, e, t->decl->sym->name);
		return secpy(p, e, kindname[t->kind]);
	case Ttuple:
		p = secpy(p, e, "(");
		for(id = t->ids; id != nil; id = id->next){
			p = tprint(p, e, id->ty);
			if(id->next != nil)
				p = secpy(p, e, ", ");
		}
		return secpy(p, e, ")");
	case Tfn:
		p = secpy(p, e, "fn(");
		for(id = t->ids; id != nil; id = id->next){
			p = tprint(p, e, id->ty);
			if(id->next != nil)
				p = secpy(p, e, ", ");
		}
		p = secpy(p, e, ")");
		if(t->tof != nil && t->tof->kind != Tnone){
			p = secpy(p, e, ": ");
			p = tprint(p, e, t->tof);
		}
		return p;
	default:
		return secpy(p, e, kindname[t->kind]);
	}
}

int
typeconv(Fmt *f)
{
	Type *t;
	char buf[1024];

	t = va_arg(f->args, Type*);
	tprint(buf, buf+sizeof(buf), t);
	return fmtstrcpy(f, buf);
}

int
declconv(Fmt *f)
{
	Decl *d;
	char buf[256];

	d = va_arg(f->args, Decl*);
	if(d == nil || d->sym == nil)
		seprint(buf, buf+sizeof(buf), "<nil>");
	else
		seprint(buf, buf+sizeof(buf), "%s %s", storename[d->store], d->sym->name);
	return fmtstrcpy(f, buf);
}
