#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "mathi.h"

enum
{
	TOKI0,
	TOKI1,
	TOKI2,
	TOKI3,
	TOKSB,
	TOKFP
};
#include "tab.h"

typedef struct Addr	Addr;
struct Addr
{
	uchar	mode;
	Adr	a;
};

#pragma	varargck	type	"a"	Addr*

int	iconv(Fmt*);
int	aconv(Fmt*);

int
aconv(Fmt *f)
{
	Addr *a;
	char buf[64];

	a = va_arg(f->args, Addr*);
	if(a == nil)
		return fmtstrcpy(f, "AZ");
	switch(a->mode & AMASK) {
	case AFP:	sprint(buf, "%zd(fp)", a->a.ind);	break;
	case AMP:	sprint(buf, "%zd(mp)", a->a.ind);	break;
	case AIMM:	sprint(buf, "$%zd", a->a.imm);		break;
	case AIND|AFP:	sprint(buf, "%d(%d(fp))", a->a.i.s, a->a.i.f); break;
	case AIND|AMP:	sprint(buf, "%d(%d(mp))", a->a.i.s, a->a.i.f); break;
	}
	return fmtstrcpy(f, buf);
}

int
Dconv(Fmt *f)
{
	Inst *i;
	Addr s, d;
	char buf[128];
	static int init;

	if(init == 0) {
		/*
		 * There used to be an opnam[256] built here, mapping
		 * opcode to name.  keywds is already indexed by opcode
		 * -- the switch below reads keywds[i->op].terminal --
		 * so that loop was copying each name to the index it
		 * was already at, into 1024 bytes of bss that need not
		 * exist.  See the note in tab.h.
		 */
		fmtinstall('a', aconv);
		init = 1;
	}

	i = va_arg(f->args, Inst*);
	if(i == nil)
		return fmtstrcpy(f, "IZ");

	switch(keywds[i->op].terminal) {
	case TOKI0:
		sprint(buf, "%s", keywds[i->op].name);
		break;
	case TOKI1:
		d.a = i->d;
		d.mode = UDST(i->add);
		sprint(buf, "%s\t%a", keywds[i->op].name, &d);
		break;
	case TOKI3:
		d.a = i->d;
		d.mode = UDST(i->add);
		s.a = i->s;
		s.mode = USRC(i->add);
		switch(i->add&ARM) {
		default:
			sprint(buf, "%s\t%a, %a", keywds[i->op].name, &s, &d);
			break;
		case AXIMM:
			sprint(buf, "%s\t%a, $%d, %a", keywds[i->op].name, &s, i->reg, &d);
			break;
		case AXINF:
			sprint(buf, "%s\t%a, %d(fp), %a", keywds[i->op].name, &s, i->reg, &d);
			break;
		case AXINM:
			sprint(buf, "%s\t%a, %d(mp), %a", keywds[i->op].name, &s, i->reg, &d);
			break;
		}
		break;
	case TOKI2:
		d.a = i->d;
		d.mode = UDST(i->add);
		s.a = i->s;
		s.mode = USRC(i->add);
		sprint(buf, "%s\t%a, %a", keywds[i->op].name, &s, &d);
		break;
	}

	return fmtstrcpy(f, buf);
}

