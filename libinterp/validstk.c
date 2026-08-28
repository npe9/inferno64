#include "lib9.h"
#include "isa.h"
#include "interp.h"

static int depth;

void
memchk(void *p, Type *t)
{
	Heap *h;
	int i, j;
	ulong *v, **base;

	if(depth > 100)
		return;
	depth++;
	base = p;
	for(i = 0; i < t->np; i++) {
		for(j = 0; j < 8; j++) {
			if(t->map[i] & (1<<(7-j))) {
				v = base[(i*8)+j];
				if(v != H) {
					h = D2H(v);
					hmsize(h);
					if(h->ref <= 0) {
						extern void panic(char*, ...);

						/* same abort()-hangs-on-pc64 fix as unload()/badptrslot(); unreachable right now (memchk() has no caller in this tree), fixed for completeness. pc64-only, temporary. See doc/inferno-ports.ms. */
						panic("memchk: h->ref <= 0, h %#p", h);
					}
					if(h->t != nil)
						memchk(v, h->t);
				}
			}
		}
	}
	depth--;
}

void
validstk(void)
{
	Type *t;
	Frame *f;
	uchar *fp;

	fp = R.FP;
	while(fp != nil) {
		f = (Frame*)fp;
		t = f->t;
		if(t == nil)
			t = SEXTYPE(f)->reg.TR;

		memchk(f, t);
		fp = f->fp;
	}
}
