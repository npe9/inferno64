#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "kernel.h"
#include "raise.h"

static int
ematch(char *pat, char *exp)
{
	int l;

	if(strcmp(pat, exp) == 0)
		return 1;

	l = strlen(pat);
	if(l == 0)
		return 0;
	if(pat[l-1] == '*') {
		if(l == 1)
			return 1;
		if(strncmp(pat, exp, l-1) == 0)
			return 1;
	}
	return 0;
}

static void
setstr(String *s, char *p)
{
	if(s == H)
		return;
	if(s->len < 0 || s->max < 4)
		return;
	kstrcpy(s->Sascii, p, s->max);	/* TO DO: we are assuming they aren't runes */
	s->len = strlen(s->Sascii);
}

static String *exstr;

void
excinit(void)
{
	exstr = newstring(ERRMAX);
	poolimmutable(D2H(exstr));
}

static String*
newestring(char *estr)
{
	String *s;

	if(waserror()){
		setstr(exstr, estr);
		/*
		 * AINC, not ->ref++.  These are Dis heap counts and two
		 * executors reach them at once now; interp.h says so where
		 * AINC is defined.  A lost update here frees a string or an
		 * exception value that is still referred to.  Same fix as
		 * dis.c's newprog() and schedmod().
		 */
		AINC(&D2H(exstr)->ref);
		return exstr;
	}
	s = c2string(estr, strlen(estr));
	poperror();
	return s;
}

#define NOPC	0xffffffff

#define FRTYPE(f)	((f)->t == nil ? SEXTYPE(f)->reg.TR : (f)->t)

/*
 * clear up an uncalled frame
 */
static void
freeframe(uchar *fp, int setsp)
{
	Frame *f;

	f = (Frame*)fp;
	if(f->t == nil)
		unextend(f);
	else if(f->t->np)
		freeptrs(f, f->t);
	if(setsp)
		R.SP = fp;
}

ulong handlerbroke, handlerbroketold;	/* INSTRUMENTATION - temporary */

int
handler(char *estr)
{
	Prog *p;
	Modlink *m, *mr;
	int str, ne;
	uintptr pc, newpc;
	intptr eoff;
	uchar *fp, **eadr;
	Frame *f;
	Type *t, *zt;
	Handler *h;
	Except *e;
	void *v;

	p = currun();
	if(*estr == 0 || p == nil)
		return 0;
	str = p->exval == H || D2H(p->exval)->t == &Tstring;
	m = R.M;
	if(m->compiled)
		pc = (uintptr)R.PC-(uintptr)m->prog;
	else
		pc = R.PC-m->prog;
	pc--;
	fp = R.FP;
	while(fp != nil){		/* look for a handler */
		if((h = m->m->htab) != nil){
			for( ; h->etab != nil; h++){
				if(pc < h->pc1 || pc >= h->pc2)
					continue;
				eoff = h->eoff;
				zt = h->t;
				for(e = h->etab, ne = h->ne; e->s != nil; e++, ne--){
					if(ematch(e->s, estr) && (str && ne <= 0 || !str && ne > 0)){
						newpc = e->pc;
						goto found;
					}
				}
				newpc = e->pc;
				if(newpc != NOPC)
					goto found;
			}
		}
		if(!str && fp != R.FP){		/* becomes a string exception in immediate caller */
			v = p->exval;
			p->exval = *(String**)v;
			AINC(&D2H(p->exval)->ref);	/* see setexc() above */
			destroy(v);
			str = 1;
			continue;
		}
		f = (Frame*)fp;
		if(f->mr != nil)
			m = f->mr;
		if(m->compiled)
			pc = (uintptr)f->lr-(uintptr)m->prog;
		else
			pc = f->lr-m->prog;
		pc--;
		fp = f->fp;
	}
	destroy(p->exval);
	p->exval = H;
	return 0;
found:
	{
		int n, i;
		char name[3*KNAMELEN];

		pc = modstatus(&R, name, sizeof(name));
		n = 10+1+strlen(name)+1+strlen(estr)+1;
		p->exstr = realloc(p->exstr, n);
		if(p->exstr != nil){
			/* KenC LP64: one homogeneous arg per snprint */
			i = snprint(p->exstr, n, "%zud ", pc);
			i += snprint(p->exstr+i, n-i, "%s ", name);
			snprint(p->exstr+i, n-i, "%s", estr);
		}
	}

	/*
	 * there may be an uncalled frame at the top of the stack
	 */
	f = (Frame*)R.FP;
	t = FRTYPE(f);
	/*
	 * INSTRUMENTATION - temporary.  Which of these sets R.SP?
	 *
	 * The first passes setsp as 0 and leaves R.SP alone; the second
	 * passes 1.  If neither runs, and the unwind loop below does not
	 * run either because R.FP is already the handler frame, then
	 * nothing here touches R.SP and the snapshot taken at the end
	 * carries whatever it had.  rootset() then walks tos.fu..SP over
	 * range that is not frames, which is the fault this is chasing.
	 *
	 * 1 = first branch (no setsp), 2 = second (setsp), 3 = neither.
	 * 0x10 is or'd in when the unwind loop ran, which also sets SP.
	 */
	if(R.FP < R.EX || R.FP >= R.TS){
		p->spsrc = 1;
		freeframe(R.EX+OA(Stkext, reg.tos.fr), 0);
	}
	else if(R.FP+t->size < R.SP){
		p->spsrc = 2;
		freeframe(R.FP+t->size, 1);
	}
	else
		p->spsrc = 3;

	m = R.M;
	while(R.FP != fp){
		p->spsrc |= 0x10;	/* INSTRUMENTATION: the loop set SP */
		f = (Frame*)R.FP;
		R.PC = f->lr;
		R.FP = f->fp;
		R.SP = (uchar*)f;
		mr = f->mr;
		if(f->t == nil)
			unextend(f);
		else if(f->t->np)
			freeptrs(f, f->t);
		if(mr != nil){
			m = mr;
			destroy(R.M);
			R.M = m;
			R.MP = m->MP;
		}
	}
	if(zt != nil){
		freeptrs(fp, zt);
		initmem(zt, fp);
	}
	eadr = (uchar**)(fp+eoff);
	destroy(*eadr);
	*eadr = H;
	if(p->exval == H)
		*eadr = (uchar*)newestring(estr);	/* might fail */
	else{
		AINC(&D2H(p->exval)->ref);	/* see setexc() above */
		*eadr = p->exval;
	}
	if(m->compiled)
		R.PC = (Inst*)((uintptr)m->prog+newpc);
	else
		R.PC = m->prog+newpc;
	{	/* INSTRUMENTATION - temporary */
		Stkext *sx;
		uchar *cf;
		int n, ok;

		/*
		 * Does the stack this handler leaves behind still have a
		 * frame chain that reaches the bottom of its newest extent?
		 * This is the one place a Prog's whole register file is
		 * rewritten while it is not running, and the branch above
		 * that passes setsp as 0 leaves R.SP alone -- which
		 * doc/multicore-plan.ms has had flagged as a suspect since
		 * before there was anything to test it with.
		 */
		ok = 1;
		if(R.EX != nil && R.FP != nil && R.SP != nil){
			sx = (Stkext*)R.EX;
			ok = 0;
			for(cf = R.FP, n = 0; n < 4096; n++){
				if(cf == sx->reg.tos.fu){
					ok = 1;
					break;
				}
				if(cf < sx->reg.tos.fu || cf >= R.SP)
					break;
				cf = ((Frame*)cf)->fp;
				if(cf == nil){
					ok = 1;
					break;
				}
			}
			if(R.FP >= R.SP)
				ok = 0;
		}
		if(!ok){
			handlerbroke++;
			if(handlerbroketold++ < 6)
				print("handler: prog %d leaves FP %#p SP %#p"
					" EX %#p with a chain that stops short,"
					" spsrc %#x\n",
					p->pid, R.FP, R.SP, R.EX, p->spsrc);
		}
	}
	memmove(&p->reg, &R, sizeof(R));
	REGSYNCED();
	p->regsrc = 3;		/* INSTRUMENTATION: propex() */
	p->syncn = p->wmtracen;
	p->kill = nil;
	destroy(p->exval);
	p->exval = H;
	return 1;
}
