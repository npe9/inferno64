/*
 * 7obj.c - identify and parse an aarch64 (7c/7l) object file
 *
 * Modeled on jobj.c (riscv64), but 7c/7l's own wire format differs
 * in two ways confirmed directly against utils/7c/swt.c's zwrite()/
 * zname() (the writer) and utils/7l/obj.c's ldobj()/zaddr() (the
 * reader, already exercised all session by every real 7l link):
 *
 *   - the opcode is a 2-byte little-endian word (bloc[0]|bloc[1]<<8),
 *     not jc's single byte -- ANAME/ASIGNAME still compare equal
 *     against a one-byte constant here only because both values fit
 *     under 256 and the high byte is always 0, but the record layout
 *     after the opcode still shifts by one extra byte throughout;
 *   - a TEXT/GLOBL-class record's reg byte carries two flag bits
 *     (0x80 NOSCHED, 0x40 "a from3 operand follows the from operand")
 *     that must be honored to stay byte-synchronized with the rest
 *     of the stream, and D_DCONST (a real 64-bit constant, needed
 *     since 7 is genuinely LP64) is an 8-byte payload jc has no
 *     equivalent of.
 */
#include <lib9.h>
#include <bio.h>
#include "mach.h"
#include "7c/7.out.h"
#include "obj.h"

typedef struct Addr	Addr;
struct Addr
{
	char	type;
	char	sym;
	char	name;
};
static Addr addr(Biobuf*);
static char type2char(int);
static void skip(Biobuf*, int);

int
_is7(char *s)
{
	return  s[0] == (ANAME&0xff) && s[1] == (ANAME>>8)	/* opcode, 2 bytes LE */
		&& s[2] == D_FILE				/* type */
		&& s[3] == 1					/* sym */
		&& s[4] == '<';					/* name of file */
}

int
_read7(Biobuf *bp, Prog *p)
{
	int as, aslo, ashi, n, flags;
	Addr a;

	aslo = Bgetc(bp);
	if(aslo < 0)
		return 0;
	ashi = Bgetc(bp);
	if(ashi < 0)
		return 0;
	as = aslo | (ashi<<8);
	p->kind = aNone;
	p->sig = 0;
	if(as == ANAME || as == ASIGNAME){
		if(as == ASIGNAME){
			Bread(bp, &p->sig, 4);
			p->sig = leswal(p->sig);
		}
		p->kind = aName;
		p->type = type2char(Bgetc(bp));		/* type */
		p->sym = Bgetc(bp);			/* sym */
		n = 0;
		for(;;) {
			as = Bgetc(bp);
			if(as < 0)
				return 0;
			n++;
			if(as == 0)
				break;
		}
		p->id = malloc(n);
		if(p->id == 0)
			return 0;
		Bseek(bp, -n, 1);
		if(Bread(bp, p->id, n) != n)
			return 0;
		return 1;
	}
	if(as == ATEXT)
		p->kind = aText;
	else if(as == AGLOBL)
		p->kind = aData;
	flags = Bgetc(bp);		/* reg, with NOSCHED/from3 flag bits */
	if(flags < 0)
		return 0;
	skip(bp, 4);			/* lineno(4) */
	a = addr(bp);
	if(flags & 0x40)
		addr(bp);		/* from3, when present */
	addr(bp);			/* to */
	if(a.type != D_OREG || a.name != D_STATIC && a.name != D_EXTERN)
		p->kind = aNone;
	p->sym = a.sym;
	return 1;
}

static Addr
addr(Biobuf *bp)
{
	Addr a;
	long off;

	a.type = Bgetc(bp);	/* a.type */
	skip(bp,1);		/* reg */
	a.sym = Bgetc(bp);	/* sym index */
	a.name = Bgetc(bp);	/* sym type */
	switch(a.type){
	default:
	case D_NONE: case D_REG: case D_SP: case D_FREG: case D_VREG: case D_COND:
		break;
	case D_OREG:
	case D_XPRE:
	case D_XPOST:
	case D_CONST:
	case D_BRANCH:
	case D_SHIFT:
	case D_EXTREG:
	case D_ROFF:
	case D_SPR:
		off = Bgetc(bp);
		off |= Bgetc(bp) << 8;
		off |= Bgetc(bp) << 16;
		off |= Bgetc(bp) << 24;
		if(off < 0)
			off = -off;
		if(a.sym && (a.name==D_PARAM || a.name==D_AUTO))
			_offset(a.sym, off);
		break;
	case D_DCONST:
		skip(bp, 8);
		break;
	case D_SCONST:
		skip(bp, NSNAME);
		break;
	case D_FCONST:
		skip(bp, 8);
		break;
	}
	return a;
}

static char
type2char(int t)
{
	switch(t){
	case D_EXTERN:		return 'U';
	case D_STATIC:		return 'b';
	case D_AUTO:		return 'a';
	case D_PARAM:		return 'p';
	default:		return UNKNOWN;
	}
}

static void
skip(Biobuf *bp, int n)
{
	while (n-- > 0)
		Bgetc(bp);
}
