/*
 * RISC-V 64 (RV64GC) JIT for Dis — Linux hosted only (gcc).
 * KenC/native uses the stub in comp-riscv64.c.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#include <sys/mman.h>
#include <unistd.h>

#ifndef MAP_ANON
#define MAP_ANON	0x1000
#endif
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

extern int segflush(void*, ulong);

#define	RESCHED	1

enum
{
	RA0	= 10,
	RA1	= 11,
	RA2	= 12,
	RA3	= 13,
	RTA	= 14,
	RCON	= 15,
	RSAVE	= 21,
	RREG	= 18,
	RFP	= 19,
	RMP	= 20,
	RZERO	= 0,
	RRA	= 1,
	RSP	= 2,

	FA0	= 0,
	FA1	= 1,
	FA2	= 2,

	EQ	= 0,
	NE	= 1,
	CS	= 2,
	CC	= 3,
	MI	= 4,
	PL	= 5,
	VS	= 6,
	VC	= 7,
	HI	= 8,
	LS	= 9,
	GE	= 10,
	LT	= 11,
	GT	= 12,
	LE	= 13,
	AL	= 14,

	HS	= CS,
	LO	= CC,

	Lea	= 100,
	Ldw,
	Stw,
	Ldb,
	Stb,
	Ldw32,
	Stw32,
	Ldw32s,
	Ldh,
	Sth,

	SRCOP	= (1<<0),
	DSTOP	= (1<<1),
	WRTPC	= (1<<2),
	TCHECK	= (1<<3),
	NEWPC	= (1<<4),
	DBRAN	= (1<<5),
	THREOP	= (1<<6),

	MacFRP	= 0,
	MacRET,
	MacCASE,
	MacCOLR,
	MacMCAL,
	MacFRAM,
	MacMFRA,
	MacRELQ,
	MacBNDS,
	NMACRO
};

#define RTYPE(funct7, rs2, rs1, funct3, rd, opc) \
	*code++ = (((funct7)&0x7f)<<25)|(((rs2)&0x1f)<<20)|(((rs1)&0x1f)<<15)|(((funct3)&7)<<12)|(((rd)&0x1f)<<7)|((opc)&0x7f)
#define ITYPE(imm, rs1, funct3, rd, opc) \
	*code++ = ((((imm)&0xfff)<<20)|(((rs1)&0x1f)<<15)|(((funct3)&7)<<12)|(((rd)&0x1f)<<7)|((opc)&0x7f))
#define STYPE(imm, rs2, rs1, funct3, opc) do { \
	int _i = (imm); \
	*code++ = ((((_i)>>5)&0x7f)<<25)|(((rs2)&0x1f)<<20)|(((rs1)&0x1f)<<15)|(((funct3)&7)<<12)|(((_i)&0x1f)<<7)|((opc)&0x7f); \
} while(0)
#define UTYPE(imm20, rd, opc) \
	*code++ = ((((imm20)&0xfffff)<<12)|(((rd)&0x1f)<<7)|((opc)&0x7f))

#define ADD_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 0, Rd, 0x33)
#define SUB_REG(Rd, Rn, Rm)	RTYPE(0x20, Rm, Rn, 0, Rd, 0x33)
#define AND_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 7, Rd, 0x33)
#define ORR_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 6, Rd, 0x33)
#define EOR_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 4, Rd, 0x33)
#define MUL_REG(Rd, Rn, Rm)	RTYPE(0x01, Rm, Rn, 0, Rd, 0x33)
#define SDIV_REG(Rd, Rn, Rm)	RTYPE(0x01, Rm, Rn, 4, Rd, 0x33)
#define REM_REG(Rd, Rn, Rm)	RTYPE(0x01, Rm, Rn, 6, Rd, 0x33)
#define LSLV_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 1, Rd, 0x33)
#define LSRV_REG(Rd, Rn, Rm)	RTYPE(0x00, Rm, Rn, 5, Rd, 0x33)
#define ASRV_REG(Rd, Rn, Rm)	RTYPE(0x20, Rm, Rn, 5, Rd, 0x33)

#define ADDI(Rd, Rn, imm12)	ITYPE(imm12, Rn, 0, Rd, 0x13)
#define SLLI(Rd, Rn, sh)	ITYPE((sh)&0x3f, Rn, 1, Rd, 0x13)
#define SRLI(Rd, Rn, sh)	ITYPE((sh)&0x3f, Rn, 5, Rd, 0x13)
#define ADDIW(Rd, Rn, imm12)	ITYPE(imm12, Rn, 0, Rd, 0x1B)
#define LUI(Rd, imm20)		UTYPE(imm20, Rd, 0x37)

#define LD(Rd, Rn, imm12)	ITYPE(imm12, Rn, 3, Rd, 0x03)
#define LW(Rd, Rn, imm12)	ITYPE(imm12, Rn, 2, Rd, 0x03)
#define LWU(Rd, Rn, imm12)	ITYPE(imm12, Rn, 6, Rd, 0x03)
#define LH(Rd, Rn, imm12)	ITYPE(imm12, Rn, 1, Rd, 0x03)
#define LB(Rd, Rn, imm12)	ITYPE(imm12, Rn, 0, Rd, 0x03)
#define SD(Rs, Rn, imm12)	STYPE(imm12, Rs, Rn, 3, 0x23)
#define SW(Rs, Rn, imm12)	STYPE(imm12, Rs, Rn, 2, 0x23)
#define SB(Rs, Rn, imm12)	STYPE(imm12, Rs, Rn, 0, 0x23)

#define FLD(Fd, Rn, imm12)	ITYPE(imm12, Rn, 3, Fd, 0x07)
#define FSD(Fs, Rn, imm12)	STYPE(imm12, Fs, Rn, 3, 0x27)
#define FADD_D(Fd, Fn, Fm)	RTYPE(0x01, Fm, Fn, 0, Fd, 0x53)
#define FSUB_D(Fd, Fn, Fm)	RTYPE(0x05, Fm, Fn, 0, Fd, 0x53)
#define FMUL_D(Fd, Fn, Fm)	RTYPE(0x09, Fm, Fn, 0, Fd, 0x53)
#define FDIV_D(Fd, Fn, Fm)	RTYPE(0x0D, Fm, Fn, 0, Fd, 0x53)
#define FEQ_D(Rd, Fn, Fm)	RTYPE(0x51, Fm, Fn, 2, Rd, 0x53)
#define FLT_D(Rd, Fn, Fm)	RTYPE(0x51, Fm, Fn, 1, Rd, 0x53)
#define FLE_D(Rd, Fn, Fm)	RTYPE(0x51, Fm, Fn, 0, Rd, 0x53)
#define FCVT_D_L(Fd, Rn)	RTYPE(0x69, 2, Rn, 0, Fd, 0x53)	/* int64→double, RNE */
#define FCVT_L_D(Rd, Fn)	RTYPE(0x61, 3, Fn, 1, Rd, 0x53)	/* double→int64, RTZ */
#define FMV_D_X(Fd, Rn)		RTYPE(0x79, 0, Rn, 0, Fd, 0x53)
#define FSGNJN_D(Fd, Fn, Fm)	RTYPE(0x11, Fm, Fn, 1, Fd, 0x53)
#define FNEG_D(Fd, Fn)		FSGNJN_D(Fd, Fn, Fn)

#define JALR(Rd, Rn, imm12)	ITYPE(imm12, Rn, 0, Rd, 0x67)
#define BR_REG(Rn)		JALR(RZERO, Rn, 0)
#define BLR_REG(Rn)		JALR(RRA, Rn, 0)
#define RET_X30()		JALR(RZERO, RRA, 0)
#define NOP_INSN()		ADDI(RZERO, RZERO, 0)

#define MOV_REG(Rd, Rm)		ADDI(Rd, Rm, 0)
#define NEG_REG(Rd, Rm)		SUB_REG(Rd, RZERO, Rm)
#define SXTW(Rd, Rn)		ADDIW(Rd, Rn, 0)

/* ADDI immediates are signed 12-bit; spill via con() when out of range. */
#define ADD_IMM(Rd, Rn, imm12)	do { \
	long _ai = (long)(imm12); \
	if(_ai > -2048 && _ai < 2048) \
		ADDI(Rd, Rn, _ai); \
	else { \
		con((uvlong)_ai, ((Rd) == RCON) ? RTA : RCON); \
		ADD_REG(Rd, Rn, ((Rd) == RCON) ? RTA : RCON); \
	} \
} while(0)
#define SUB_IMM(Rd, Rn, imm12)	ADD_IMM(Rd, Rn, -(imm12))
#define LDR_UOFF(Rt, Rn, scaled)	LD(Rt, Rn, (scaled)*8)
#define STR_UOFF(Rt, Rn, scaled)	SD(Rt, Rn, (scaled)*8)
#define LDR32_UOFF(Rt, Rn, scaled)	LWU(Rt, Rn, (scaled)*4)
#define STR32_UOFF(Rt, Rn, scaled)	SW(Rt, Rn, (scaled)*4)
#define LDRSW_UOFF(Rt, Rn, scaled)	LW(Rt, Rn, (scaled)*4)
#define LDRB_UOFF(Rt, Rn, off)		LB(Rt, Rn, off)
#define STRB_UOFF(Rt, Rn, off)		SB(Rt, Rn, off)
#define LDRH_UOFF(Rt, Rn, scaled)	LH(Rt, Rn, (scaled)*2)
#define LDUR(Rt, Rn, simm9)		LD(Rt, Rn, simm9)
#define STUR(Rt, Rn, simm9)		SD(Rt, Rn, simm9)
#define LDUR32(Rt, Rn, simm9)		LWU(Rt, Rn, simm9)
#define STUR32(Rt, Rn, simm9)		SW(Rt, Rn, simm9)
#define LDURSW(Rt, Rn, simm9)		LW(Rt, Rn, simm9)
#define LDURB(Rt, Rn, simm9)		LB(Rt, Rn, simm9)
#define STURB(Rt, Rn, simm9)		SB(Rt, Rn, simm9)
#define LDURH(Rt, Rn, simm9)		LH(Rt, Rn, simm9)
#define FLDR_UOFF(Ft, Rn, scaled)	FLD(Ft, Rn, (scaled)*8)
#define FSTR_UOFF(Ft, Rn, scaled)	FSD(Ft, Rn, (scaled)*8)
#define FLDUR(Ft, Rn, simm9)		FLD(Ft, Rn, simm9)
#define FSTUR(Ft, Rn, simm9)		FSD(Ft, Rn, simm9)
#define SCVTF_DX(Fd, Rn)		FCVT_D_L(Fd, Rn)
#define FCVTZS_XD(Rd, Fn)		FCVT_L_D(Rd, Fn)
#define MSUB_REG(Rd, Rn, Rm, Ra) do { \
	MUL_REG(RCON, Rn, Rm); \
	SUB_REG(Rd, Ra, RCON); \
} while(0)

#define LDP(Rt1, Rt2, Rn, simm7) do { \
	LD(Rt1, Rn, (simm7)*8); \
	LD(Rt2, Rn, (simm7)*8 + 8); \
} while(0)
#define STP(Rt1, Rt2, Rn, simm7) do { \
	SD(Rt1, Rn, (simm7)*8); \
	SD(Rt2, Rn, (simm7)*8 + 8); \
} while(0)

#define RELPC(pc)		((ulong)(base + (pc)))
#define IA(s, o)		(base + s[o])
#define XZR	RZERO

static	u32int*	code;
static	u32int*	base;
static	ulong*	patch;
static	ulong	codeoff;
static	int	pass;
static	Module*	mod;
static	uchar*	tinit;
static	ulong*	litpool;
static	ulong*	litlimit;
static	int	nlit;
static	ulong	macro[NMACRO];
	void	(*comvec)(void);
static	int	cmp_rs1, cmp_rs2;
static	int	cmp_kind;
static	int	cmp_fa, cmp_fb;
static	u32int	*last_branch;

static	void	macfrp(void);
static	void	macret(void);
static	void	maccase(void);
static	void	maccolr(void);
static	void	macmcal(void);
static	void	macfram(void);
static	void	macmfra(void);
static	void	macrelq(void);
static	void	macbounds(void);
static	void	movmem(Inst*);
static	void	mid(Inst*, int, int);
static	void	mem(int, long, int, int);
static	void	memfl(int, long, int, int);
static	void	bcondbra(int, int);
static	void	bradis(int);
static	void	bramac(int);
static	void	blmac(int);
static	void	urk(char*);
static	void	FMOV_D_HALF(int);
static	void	con(uvlong, int);
extern	void	das(u32int*, int);

#define T(r)	*((void**)(R.r))

static struct
{
	int	idx;
	void	(*gen)(void);
	char*	name;
} mactab[] =
{
	{ MacFRP,	macfrp,		"FRP" },
	{ MacRET,	macret,		"RET" },
	{ MacCASE,	maccase,	"CASE" },
	{ MacCOLR,	maccolr,	"COLR" },
	{ MacMCAL,	macmcal,	"MCAL" },
	{ MacFRAM,	macfram,	"FRAM" },
	{ MacMFRA,	macmfra,	"MFRA" },
	{ MacRELQ,	macrelq,	"RELQ" },
	{ MacBNDS,	macbounds,	"BNDS" },
};

static void
enc_btype(int imm, int rs2, int rs1, int funct3)
{
	int i;

	i = imm;
	*code++ = (((i>>12)&1)<<31)|(((i>>5)&0x3f)<<25)|((rs2&0x1f)<<20)|
		((rs1&0x1f)<<15)|((funct3&7)<<12)|(((i>>1)&0xf)<<8)|
		(((i>>11)&1)<<7)|0x63;
}

static void
enc_jtype(int imm, int rd)
{
	int i;

	i = imm;
	*code++ = (((i>>20)&1)<<31)|(((i>>1)&0x3ff)<<21)|(((i>>11)&1)<<20)|
		(((i>>12)&0xff)<<12)|((rd&0x1f)<<7)|0x6f;
}

static void
patch_btype(u32int *ptr, long byteoff)
{
	int i;

	i = (int)byteoff;
	if(i < -4096 || i > 4094 || (i & 1))
		urk("patch_btype range");
	*ptr = ((*ptr) & 0x01fff07f) |
		(((i>>12)&1)<<31)|(((i>>5)&0x3f)<<25)|
		(((i>>1)&0xf)<<8)|(((i>>11)&1)<<7);
}

static void
patch_jtype(u32int *ptr, long byteoff)
{
	int i;

	i = (int)byteoff;
	if(i < -1048576 || i > 1048574 || (i & 1))
		urk("patch_jtype range");
	*ptr = ((*ptr) & 0x00000fff) |
		(((i>>20)&1)<<31)|(((i>>1)&0x3ff)<<21)|(((i>>11)&1)<<20)|
		(((i>>12)&0xff)<<12);
}

#define PATCH_BCOND(ptr)	do { \
	u32int *_p = (ptr); \
	if(((*_p) & 0x7f) != 0x63) \
		_p = last_branch;	/* FP compares precede the B */ \
	patch_btype(_p, (long)((uchar*)code - (uchar*)_p)); \
} while(0)
#define PATCH_B(ptr)		do { \
	u32int *_p = (ptr); \
	if(((*_p) & 0x7f) == 0x6f) \
		patch_jtype(_p, (long)((uchar*)code - (uchar*)_p)); \
	else \
		patch_btype(_p, (long)((uchar*)code - (uchar*)_p)); \
} while(0)

#define CMP_REG(Rn, Rm)		do { cmp_rs1 = (Rn); cmp_rs2 = (Rm); cmp_kind = 0; } while(0)
#define CMP_IMM(Rn, imm12)	do { \
	if((imm12) == 0) { cmp_rs1 = (Rn); cmp_rs2 = RZERO; } \
	else { ADDI(RCON, RZERO, (imm12)); cmp_rs1 = (Rn); cmp_rs2 = RCON; } \
	cmp_kind = 0; \
} while(0)
#define CMP_IMM32(Rn, imm12)	CMP_IMM(Rn, imm12)
#define CMN_IMM(Rn, imm12)	do { \
	ADDI(RCON, (Rn), (imm12)); \
	cmp_rs1 = RCON; cmp_rs2 = RZERO; cmp_kind = 0; \
} while(0)
#define SUBS_IMM(Rd, Rn, imm12)	do { \
	ADDI(Rd, Rn, -(imm12)); \
	cmp_rs1 = Rd; cmp_rs2 = RZERO; cmp_kind = 0; \
} while(0)
#define SUBS_IMM32(Rd, Rn, imm12)	SUBS_IMM(Rd, Rn, imm12)
#define SUBS_REG(Rd, Rn, Rm)	do { \
	SUB_REG(Rd, Rn, Rm); \
	cmp_rs1 = Rd; cmp_rs2 = RZERO; cmp_kind = 0; \
} while(0)
#define ADDS_IMM(Rd, Rn, imm12)	do { \
	ADDI(Rd, Rn, imm12); \
	cmp_rs1 = Rd; cmp_rs2 = RZERO; cmp_kind = 0; \
} while(0)

#define FCMP_D(Fn, Fm)		do { cmp_fa = (Fn); cmp_fb = (Fm); cmp_kind = 1; } while(0)
#define FCMP_D_ZERO(Fn)		do { cmp_fa = (Fn); cmp_kind = 2; } while(0)

static void
emit_bcond(int cond, long byteoff)
{
	int rs1, rs2, f3;

	if(cmp_kind == 1) {
		switch(cond) {
		case EQ: FEQ_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case NE: FEQ_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		case LT: case MI: FLT_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case GE: case PL: FLT_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		case LE: FLE_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case GT: FLE_D(RCON, cmp_fa, cmp_fb); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		default: urk("fcmp cond");
		}
		cmp_kind = 0;
	} else if(cmp_kind == 2) {
		FMV_D_X(FA2, RZERO);
		switch(cond) {
		case EQ: FEQ_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case NE: FEQ_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		case LT: case MI: FLT_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case GE: case PL: FLT_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		case LE: FLE_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = NE; break;
		case GT: FLE_D(RCON, cmp_fa, FA2); cmp_rs1 = RCON; cmp_rs2 = RZERO; cond = EQ; break;
		default: urk("fcmp0 cond");
		}
		cmp_kind = 0;
	}

	rs1 = cmp_rs1;
	rs2 = cmp_rs2;
	switch(cond) {
	case EQ: f3 = 0; break;
	case NE: f3 = 1; break;
	case LT: case MI: f3 = 4; break;
	case GE: case PL: f3 = 5; break;
	case GT: f3 = 4; rs1 = cmp_rs2; rs2 = cmp_rs1; break;
	case LE: f3 = 5; rs1 = cmp_rs2; rs2 = cmp_rs1; break;
	case LO: f3 = 6; break;	/* CC */
	case HS: f3 = 7; break;	/* CS */
	case HI: f3 = 6; rs1 = cmp_rs2; rs2 = cmp_rs1; break;
	case LS: f3 = 7; rs1 = cmp_rs2; rs2 = cmp_rs1; break;
	default: urk("emit_bcond"); return;
	}
	last_branch = code;
	enc_btype((int)byteoff, rs2, rs1, f3);
}

#define BCOND(cond, imm19)	emit_bcond((cond), (long)(imm19) * 4)

static void
CBZ_X(int rt, int imm19)
{
	cmp_rs1 = rt;
	cmp_rs2 = RZERO;
	cmp_kind = 0;
	emit_bcond(EQ, (long)imm19 * 4);
}

static void
CBNZ_X(int rt, int imm19)
{
	cmp_rs1 = rt;
	cmp_rs2 = RZERO;
	cmp_kind = 0;
	emit_bcond(NE, (long)imm19 * 4);
}


static void
rdestroy(void)
{
	destroy(R.s);
}

static void
rmcall(void)
{
	Frame *f;
	Prog *p;

	if((void*)R.dt == H)
		error(exModule);

	f = (Frame*)R.FP;
	if(f == H)
		error(exModule);

	f->mr = nil;
	((void(*)(Frame*))R.dt)(f);
	R.SP = (uchar*)f;
	R.FP = f->fp;
	if(f->t == nil)
		unextend(f);
	else
		freeptrs(f, f->t);
	p = currun();
	if(p->kill != nil)
		error(p->kill);
}

static void
rmfram(void)
{
	Type *t;
	Frame *f;
	uchar *nsp;

	if(R.d == H)
		error(exModule);
	t = (Type*)R.s;
	if(t == H)
		error(exModule);
	nsp = R.SP + t->size;
	if(nsp >= R.TS) {
		R.s = t;
		extend();
		T(d) = R.s;
		return;
	}
	f = (Frame*)R.SP;
	R.SP = nsp;
	f->t = t;
	f->mr = nil;
	initmem(t, f);
	T(d) = f;
}

static void
urk(char *s)
{
	USED(s);
	error(exCompile);
}

static void
bounds(void)
{
	error(exBounds);
}

static void
lui_addiw(int rd, u32int val)
{
	int lo12, hi20;

	lo12 = val & 0xfff;
	hi20 = (val >> 12) & 0xfffff;
	if(lo12 & 0x800) {
		hi20 = (hi20 + 1) & 0xfffff;
		lo12 -= 0x1000;
	}
	LUI(rd, hi20);
	ADDIW(rd, rd, lo12 & 0xfff);
}

static void
con(uvlong val, int rd)
{
	int tmp;
	u32int lo, hi;

	/*
	 * Always 8 instructions. Build lo32 zero-extended and hi32<<32
	 * separately — ADDIW sign-extends, so shifting a sign-extended
	 * "high" half first (the old sequence) corrupts addresses with
	 * bits 32..63 set (common under qemu-user).
	 */
	tmp = (rd == RCON) ? RTA : RCON;
	lo = (u32int)val;
	hi = (u32int)(val >> 32);
	lui_addiw(rd, lo);
	SLLI(rd, rd, 32);
	SRLI(rd, rd, 32);		/* zero-extend lo32 */
	lui_addiw(tmp, hi);
	SLLI(tmp, tmp, 32);
	ADD_REG(rd, rd, tmp);
}

static void
FMOV_D_HALF(int fd)
{
	con(0x3FE0000000000000ULL, RCON);
	FMV_D_X(fd, RCON);
}

static void
jalr_abs(uvlong dest, int link)
{
	con(dest, RTA);
	JALR(link, RTA, 0);
}

static void
bradis(int dispc)
{
	if(pass == 0) {
		jalr_abs(0, RZERO);
		return;
	}
	jalr_abs(RELPC(patch[dispc]), RZERO);
}

static void
bramac(int macidx)
{
	if(pass == 0) {
		jalr_abs(0, RZERO);
		return;
	}
	jalr_abs(RELPC(macro[macidx]), RZERO);
}

static void
blmac(int macidx)
{
	if(pass == 0) {
		jalr_abs(0, RRA);
		return;
	}
	jalr_abs(RELPC(macro[macidx]), RRA);
}

static void
bcondbra(int cond, int macidx)
{
	u32int *skip;

	emit_bcond(cond ^ 1, 0);
	skip = last_branch;
	if(pass == 0)
		jalr_abs(0, RZERO);
	else
		jalr_abs(RELPC(macro[macidx]), RZERO);
	PATCH_BCOND(skip);
}

static void
bconddis(int cond, int dispc)
{
	u32int *skip;

	emit_bcond(cond ^ 1, 0);
	skip = last_branch;
	if(pass == 0)
		jalr_abs(0, RZERO);
	else
		jalr_abs(RELPC(patch[dispc]), RZERO);
	PATCH_BCOND(skip);
}

static void
mem(int inst, long off, int rbase, int r)
{
	if(inst == Lea) {
		if(off == 0)
			MOV_REG(r, rbase);
		else if(off > -2048 && off < 2048)
			ADDI(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(r, rbase, RCON);
		}
		return;
	}

	switch(inst) {
	case Ldw:
		if(off > -2048 && off < 2048)
			LD(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			LD(r, RCON, 0);
		}
		break;
	case Stw:
		if(off > -2048 && off < 2048)
			SD(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			SD(r, RCON, 0);
		}
		break;
	case Ldb:
		if(off > -2048 && off < 2048)
			LB(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			LB(r, RCON, 0);
		}
		break;
	case Stb:
		if(off > -2048 && off < 2048)
			SB(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			SB(r, RCON, 0);
		}
		break;
	case Ldw32:
		if(off > -2048 && off < 2048)
			LWU(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			LWU(r, RCON, 0);
		}
		break;
	case Ldw32s:
		if(off > -2048 && off < 2048)
			LW(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			LW(r, RCON, 0);
		}
		break;
	case Stw32:
		if(off > -2048 && off < 2048)
			SW(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			SW(r, RCON, 0);
		}
		break;
	case Ldh:
		if(off > -2048 && off < 2048)
			LH(r, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			LH(r, RCON, 0);
		}
		break;
	}
}

static void
memfl(int inst, long off, int rbase, int fr)
{
	switch(inst) {
	case Ldw:
		if(off > -2048 && off < 2048)
			FLD(fr, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			FLD(fr, RCON, 0);
		}
		break;
	case Stw:
		if(off > -2048 && off < 2048)
			FSD(fr, rbase, off);
		else {
			con((uvlong)(ulong)off, RCON);
			ADD_REG(RCON, rbase, RCON);
			FSD(fr, RCON, 0);
		}
		break;
	}
}

/*
 * opx — decode Dis addressing mode and perform load/store.
 */
static void
opx(int mode, Adr *a, int mi, int r, int li)
{
	int ir, rta;

	switch(mode) {
	default:
		urk("opx");
	case AFP:
		mem(mi, a->ind, RFP, r);
		return;
	case AMP:
		mem(mi, a->ind, RMP, r);
		return;
	case AIMM:
		con(a->imm, r);
		if(mi == Lea) {
			mem(Stw, li, RREG, r);
			mem(Lea, li, RREG, r);
		}
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	rta = RTA;
	if(mi == Lea)
		rta = r;
	mem(Ldw, a->i.f, ir, rta);
	mem(mi, a->i.s, rta, r);
}

static void
opwld(Inst *i, int op, int r)
{
	opx(USRC(i->add), &i->s, op, r, O(REG, st));
}

static void
opwst(Inst *i, int op, int r)
{
	opx(UDST(i->add), &i->d, op, r, O(REG, dt));
}

/*
 * Float operand decode.
 */
static void
opfl(Adr *a, int am, int mi, int fr)
{
	int ir;

	switch(am) {
	default:
		urk("opfl");
	case AFP:
		memfl(mi, a->ind, RFP, fr);
		return;
	case AMP:
		memfl(mi, a->ind, RMP, fr);
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	mem(Ldw, a->i.f, ir, RTA);
	memfl(mi, a->i.s, RTA, fr);
}

static void
opflld(Inst *i, int mi, int fr)
{
	opfl(&i->s, USRC(i->add), mi, fr);
}

static void
opflst(Inst *i, int mi, int fr)
{
	opfl(&i->d, UDST(i->add), mi, fr);
}

/*
 * mid — decode middle operand.
 */
static void
mid(Inst *i, int mi, int r)
{
	int ir;

	switch(i->add & ARM) {
	default:
		opwst(i, mi, r);
		return;
	case AXIMM:
		if(mi == Lea)
			urk("mid/lea");
		con((short)i->reg, r);
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	mem(mi, i->reg, ir, r);
}

static void
midfl(Inst *i, int mi, int fr)
{
	int ir;

	switch(i->add & ARM) {
	default:
		opflst(i, mi, fr);
		return;
	case AXIMM:
		urk("midfl/imm");
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	memfl(mi, i->reg, ir, fr);
}

/*
 * literal — store value in literal pool and put its address in R.roff.
 */
static void
literal(uvlong imm, int roff)
{
	nlit++;
	con((uvlong)litpool, RTA);
	mem(Stw, roff, RREG, RTA);
	if(pass == 0)
		return;
	if(litpool >= litlimit) {
		print("JIT: literal pool overflow (nlit=%d)\n", nlit);
		urk("literal pool overflow");
	}
	*litpool = imm;
	litpool++;
}

/*
 * schedcheck — decrement IC at backward branches; reschedule if expired.
 */
static void
schedcheck(Inst *i)
{
	u32int *skip;

	if(!RESCHED || i->d.ins > i)
		return;

	mem(Ldw32, O(REG, IC), RREG, RA0);
	SUBS_IMM32(RA0, RA0, 1);
	mem(Stw32, O(REG, IC), RREG, RA0);
	skip = code;
	BCOND(GT, 0);		/* IC > 0: continue */

	/* IC <= 0: reschedule.
	 * BL sets LR = address of next instruction (the comparison code).
	 * MacRELQ saves LR as R.PC so re-entry resumes at the comparison,
	 * not past the branch — matching AMD64's call/pop approach.
	 */
	mem(Stw, O(REG, FP), RREG, RFP);
	blmac(MacRELQ);

	PATCH_BCOND(skip);
}

/*
 * punt — fall back to C interpreter for an instruction.
 */
static void
punt(Inst *i, int m, void (*fn)(void))
{
	ulong pc;

	if(m & SRCOP) {
		if(UXSRC(i->add) == SRC(AIMM))
			literal(i->s.imm, O(REG, s));
		else {
			opwld(i, Lea, RA0);
			mem(Stw, O(REG, s), RREG, RA0);
		}
	}

	if(m & DSTOP) {
		opwst(i, Lea, RA0);
		mem(Stw, O(REG, d), RREG, RA0);
	}
	if(m & WRTPC) {
		con(RELPC(patch[i - mod->prog + 1]), RA0);
		mem(Stw, O(REG, PC), RREG, RA0);
	}
	if(m & DBRAN) {
		pc = patch[i->d.ins - mod->prog];
		literal(RELPC(pc), O(REG, d));
	}

	switch(i->add & ARM) {
	case AXNON:
		/* R.m = R.d (matches dec[] behaviour regardless of THREOP) */
		mem(Ldw, O(REG, d), RREG, RA0);
		mem(Stw, O(REG, m), RREG, RA0);
		break;
	case AXIMM:
		literal((short)i->reg, O(REG, m));
		break;
	case AXINF:
		mem(Lea, i->reg, RFP, RA2);
		mem(Stw, O(REG, m), RREG, RA2);
		break;
	case AXINM:
		mem(Lea, i->reg, RMP, RA2);
		mem(Stw, O(REG, m), RREG, RA2);
		break;
	}

	mem(Stw, O(REG, FP), RREG, RFP);
	con((uvlong)fn, RTA);
	BLR_REG(RTA);

	con((uvlong)&R, RREG);

	if(m & TCHECK) {
		mem(Ldw, O(REG, t), RREG, RA0);
		CBZ_X(RA0, 3);
		mem(Ldw, O(REG, xpc), RREG, RTA);
		BR_REG(RTA);
	}

	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);

	if(m & NEWPC) {
		mem(Ldw, O(REG, PC), RREG, RTA);
		BR_REG(RTA);
	}
}

/*
 * Branch helpers.
 */
static int
swapbraop(int b)
{
	switch(b) {
	case GE:	return LE;
	case LE:	return GE;
	case GT:	return LT;
	case LT:	return GT;
	}
	return b;
}

static void
cbra(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	opwld(i, Ldw, RA0);
	mid(i, Ldw, RA1);
	CMP_REG(RA0, RA1);
	bconddis(r, i->d.ins - mod->prog);
}

static void
cbrab(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	opwld(i, Ldb, RA0);
	mid(i, Ldb, RA1);
	CMP_REG(RA0, RA1);
	bconddis(r, i->d.ins - mod->prog);
}

static void
cbral(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	opwld(i, Ldw, RA0);
	mid(i, Ldw, RA1);
	CMP_REG(RA0, RA1);
	bconddis(r, i->d.ins - mod->prog);
}

static void
cbraf(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	opflld(i, Ldw, FA0);
	midfl(i, Ldw, FA1);
	FCMP_D(FA0, FA1);
	bconddis(r, i->d.ins - mod->prog);
}

/*
 * comcase — binary search case statement.
 */
static void
comcase(Inst *i, int w)
{
	int l;
	WORD *t, *e;

	if(w != 0) {
		opwld(i, Ldw, RA1);
		opwst(i, Lea, RA3);
		bramac(MacCASE);
	}

	t = (WORD*)(mod->origmp + i->d.ind + IBY2WD);
	l = t[-1];

	if(pass == 0) {
		if(l >= 0)
			t[-1] = -l - 1;
		return;
	}
	if(l >= 0)
		return;
	t[-1] = -l - 1;
	e = t + t[-1] * 3;
	while(t < e) {
		t[2] = RELPC(patch[t[2]]);
		t += 3;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
comcasel(Inst *i)
{
	int l;
	WORD *t, *e;

	t = (WORD*)(mod->origmp + i->d.ind + 2*IBY2WD);
	l = t[-2];
	if(pass == 0) {
		if(l >= 0)
			t[-2] = -l - 1;
		return;
	}
	if(l >= 0)
		return;
	t[-2] = -l - 1;
	e = t + t[-2] * 6;
	while(t < e) {
		t[4] = RELPC(patch[t[4]]);
		t += 6;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
comgoto(Inst *i)
{
	WORD *t, *e;

	opwld(i, Ldw, RA1);		/* index */
	opwst(i, Lea, RA0);		/* table base */
	/* each entry is IBY2WD bytes; compute RA0 + RA1 * IBY2WD */
	con(IBY2WD, RCON);
	MUL_REG(RA1, RA1, RCON);
	ADD_REG(RA0, RA0, RA1);
	LDR_UOFF(RTA, RA0, 0);
	BR_REG(RTA);

	if(pass == 0)
		return;

	t = (WORD*)(mod->origmp + i->d.ind);
	e = t + t[-1];
	t[-1] = 0;
	while(t < e) {
		t[0] = RELPC(patch[t[0]]);
		t++;
	}
}

/*
 * commframe — inline module frame allocation.
 */
static void
commframe(Inst *i)
{
	u32int *mlnil, *punt_lab;

	opwld(i, Ldw, RA0);
	CMN_IMM(RA0, 1);
	mlnil = code;
	BCOND(EQ, 0);

	if((i->add & ARM) == AXIMM) {
		mem(Ldw, OA(Modlink, links) + i->reg * sizeof(Modl) + O(Modl, frame),
			RA0, RA3);
	} else {
		mid(i, Ldw, RA1);
		con(sizeof(Modl), RCON);
		MUL_REG(RA1, RA1, RCON);
		ADD_IMM(RA1, RA1, OA(Modlink, links) + O(Modl, frame));
		ADD_REG(RA1, RA0, RA1);
		LDR_UOFF(RA3, RA1, 0);
	}

	mem(Ldw, O(Type, initialize), RA3, RA1);
	punt_lab = code;
	CBNZ_X(RA1, 0);	/* initialize != 0: jump to MacFRAM path */

	opwst(i, Lea, RA0);

	/*
	 * MacMFRA is reached by BR (not BL).  Put the resume PC in RRA
	 * so macmfra can save/restore it around rmfram and RET there —
	 * same convention as arm32 (RLINK).
	 */
	PATCH_BCOND(mlnil);
	con(RELPC(patch[i - mod->prog + 1]), RRA);
	bramac(MacMFRA);

	PATCH_BCOND(punt_lab);
	blmac(MacFRAM);
	opwst(i, Stw, RA2);
}

/*
 * commcall — inline module call.
 */
static void
commcall(Inst *i)
{
	u32int *mlnil, *join;

	opwld(i, Ldw, RA2);
	con(RELPC(patch[i - mod->prog + 1]), RA0);
	mem(Stw, O(Frame, lr), RA2, RA0);
	mem(Stw, O(Frame, fp), RA2, RFP);
	mem(Ldw, O(REG, M), RREG, RA3);
	mem(Stw, O(Frame, mr), RA2, RA3);
	opwst(i, Ldw, RA3);
	CMN_IMM(RA3, 1);
	mlnil = code;
	BCOND(EQ, 0);
	if((i->add & ARM) == AXIMM) {
		mem(Ldw, OA(Modlink, links) + i->reg * sizeof(Modl) + O(Modl, u.pc),
			RA3, RA0);
	} else {
		mid(i, Ldw, RA1);
		con(sizeof(Modl), RCON);
		MUL_REG(RA1, RA1, RCON);
		ADD_IMM(RA1, RA1, OA(Modlink, links) + O(Modl, u.pc));
		ADD_REG(RA1, RA3, RA1);
		LDR_UOFF(RA0, RA1, 0);
	}
	join = code;
	enc_jtype((int)((0) * 4), RZERO);
	PATCH_BCOND(mlnil);
	con((uvlong)(uintptr)H, RA0);	/* force MacMCAL punt path */
	PATCH_B(join);
	blmac(MacMCAL);
}

/*
 * movmem — block memory copy for MOVM instruction.
 */
static void
movmem(Inst *i)
{
	u32int *cp;

	/* source address already in RA1 */
	if((i->add & ARM) != AXIMM) {
		mid(i, Ldw, RA3);
		CMP_IMM(RA3, 0);
		cp = code;
		BCOND(LE, 0);
		opwst(i, Lea, RA2);
		/* byte-by-byte loop */
		LDRB_UOFF(RA0, RA1, 0);
		STRB_UOFF(RA0, RA2, 0);
		ADD_IMM(RA1, RA1, 1);
		ADD_IMM(RA2, RA2, 1);
		SUB_IMM(RA3, RA3, 1);
		CBNZ_X(RA3, -5);
		PATCH_BCOND(cp);
		return;
	}
	switch(i->reg) {
	case 0:
		break;
	case 8:
		opwst(i, Lea, RA2);
		LDR_UOFF(RA0, RA1, 0);
		STR_UOFF(RA0, RA2, 0);
		break;
	case 16:
		opwst(i, Lea, RA2);
		LDP(RA0, RA3, RA1, 0);
		STP(RA0, RA3, RA2, 0);
		break;
	default:
		if((i->reg & 7) == 0) {
			con(i->reg >> 3, RA3);
			opwst(i, Lea, RA2);
			LDR_UOFF(RA0, RA1, 0);
			STR_UOFF(RA0, RA2, 0);
			ADD_IMM(RA1, RA1, 8);
			ADD_IMM(RA2, RA2, 8);
			SUB_IMM(RA3, RA3, 1);
			CBNZ_X(RA3, -5);
		} else {
			con(i->reg, RA3);
			opwst(i, Lea, RA2);
			LDRB_UOFF(RA0, RA1, 0);
			STRB_UOFF(RA0, RA2, 0);
			ADD_IMM(RA1, RA1, 1);
			ADD_IMM(RA2, RA2, 1);
			SUB_IMM(RA3, RA3, 1);
			CBNZ_X(RA3, -5);
		}
		break;
	}
}

/*
 * comp — compile one Dis instruction to RV64.
 */
static void
comp(Inst *i)
{
	int r;

#if 0 /* PUNT_ALL: punt data ops to C, keep control flow inline */
	switch(i->op) {
	/*
	 * Control flow — must stay inline because they use compiled addresses
	 */
	case IJMP:
		if(RESCHED)
			schedcheck(i);
		bradis(i->d.ins - mod->prog);
		return;
	case ICALL:
		opwld(i, Ldw, RA0);
		con(RELPC(patch[i - mod->prog + 1]), RA1);
		mem(Stw, O(Frame, lr), RA0, RA1);
		mem(Stw, O(Frame, fp), RA0, RFP);
		MOV_REG(RFP, RA0);
		bradis(i->d.ins - mod->prog);
		return;
	case IRET:
		mem(Ldw, O(Frame, t), RFP, RA1);
		bramac(MacRET);
		return;
	case IFRAME:
		if(UXSRC(i->add) != SRC(AIMM)) {
			punt(i, SRCOP|DSTOP, optab[i->op]);
			return;
		}
		tinit[i->s.imm] = 1;
		con((uvlong)mod->type[i->s.imm], RA3);
		blmac(MacFRAM);
		opwst(i, Stw, RA2);
		return;
	case ICASE:
		comcase(i, 1);
		return;
	case ICASEC:
		comcase(i, 0);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		return;
	case ICASEL:
		comcasel(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		return;
	case IGOTO:
		comgoto(i);
		return;
	case IMOVPC:
		con(RELPC(patch[i->s.imm]), RA0);
		opwst(i, Stw, RA0);
		return;

	/*
	 * Branches — must stay inline because JMP(d) in the C handlers
	 * dereferences R.d as a pointer, which doesn't work when R.d
	 * holds a compiled code address.
	 */
	case IBEQW: cbra(i, EQ); return;
	case IBNEW: cbra(i, NE); return;
	case IBLTW: cbra(i, LT); return;
	case IBLEW: cbra(i, LE); return;
	case IBGTW: cbra(i, GT); return;
	case IBGEW: cbra(i, GE); return;
	case IBEQB: cbrab(i, EQ); return;
	case IBNEB: cbrab(i, NE); return;
	case IBLTB: cbrab(i, LT); return;
	case IBLEB: cbrab(i, LE); return;
	case IBGTB: cbrab(i, GT); return;
	case IBGEB: cbrab(i, GE); return;
	case IBEQL: cbral(i, EQ); return;
	case IBNEL: cbral(i, NE); return;
	case IBLTL: cbral(i, LT); return;
	case IBLEL: cbral(i, LE); return;
	case IBGTL: cbral(i, GT); return;
	case IBGEL: cbral(i, GE); return;
	case IBEQF: cbraf(i, EQ); return;
	case IBNEF: cbraf(i, NE); return;
	case IBLTF: cbraf(i, MI); return;
	case IBLEF: cbraf(i, LS); return;
	case IBGTF: cbraf(i, GT); return;
	case IBGEF: cbraf(i, GE); return;

	/*
	 * Everything else — punt to C interpreter
	 */
	default:
		break;
	}
	{
		int flags = SRCOP|DSTOP;
		switch(i->op) {
		case IMCALL:
			flags = SRCOP|DSTOP|THREOP|WRTPC|NEWPC;
			break;
		case ISEND: case IRECV: case IALT:
			flags = SRCOP|DSTOP|TCHECK|WRTPC;
			break;
		case INBALT:
			flags = SRCOP|DSTOP|TCHECK|WRTPC;
			break;
		case ISPAWN:
			flags = SRCOP|DBRAN;
			break;
		case IMSPAWN:
			flags = SRCOP|DSTOP;
			break;
		case IBNEC: case IBLTC: case IBLEC: case IBGTC: case IBGEC: case IBEQC:
			flags = SRCOP|DBRAN|WRTPC|NEWPC;
			break;
		case IMFRAME:
			flags = SRCOP|DSTOP|THREOP;
			break;
		case INEWCM: case INEWCMP:
			flags = SRCOP|DSTOP|THREOP;
			break;
		case INEWCB: case INEWCW: case INEWCF: case INEWCP: case INEWCL:
			flags = DSTOP|THREOP;
			break;
		case IEXIT:
			flags = 0;
			break;
		case IRAISE:
			flags = SRCOP|WRTPC;
			break;
		case ISELF:
			flags = DSTOP;
			break;
		case IMULX: case IDIVX: case ICVTXX:
		case IMULX0: case IDIVX0: case ICVTXX0:
		case IMULX1: case IDIVX1: case ICVTXX1:
		case ICVTFX: case ICVTXF:
		case IEXPW: case IEXPL: case IEXPF:
		case IMNEWZ: case IADDC:
			flags = SRCOP|DSTOP|THREOP;
			break;
		}
		punt(i, flags, optab[i->op]);
		return;
	}
#endif

	switch(i->op) {
	default:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;

	case IMCALL:
		if((i->add & ARM) == AXIMM)
			commcall(i);
		else
			punt(i, SRCOP|DSTOP|THREOP|WRTPC|NEWPC, optab[i->op]);
		break;
	case ISEND:
	case IRECV:
	case IALT:
		punt(i, SRCOP|DSTOP|TCHECK|WRTPC, optab[i->op]);
		break;
	case ISPAWN:
		punt(i, SRCOP|DBRAN, optab[i->op]);
		break;
	case IBNEC:
	case IBEQC:
	case IBLTC:
	case IBLEC:
	case IBGTC:
	case IBGEC:
		punt(i, SRCOP|DBRAN|NEWPC|WRTPC, optab[i->op]);
		break;
	case ICASEC:
		comcase(i, 0);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case ICASEL:
		comcasel(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case IADDC:
	case IMNEWZ:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ILOAD:
	case INEWA:
	case INEWAZ:
	case INEW:
	case INEWZ:
	case ISLICEA:
	case ISLICELA:
	case ICONSB:
	case ICONSW:
	case ICONSL:
	case ICONSF:
	case ICONSM:
	case ICONSMP:
	case ICONSP:
	case IMOVMP:
	case IHEADMP:
	case IINSC:
	case ICVTAC:
	case ICVTCW:
	case ICVTWC:
	case ICVTLC:
	case ICVTCL:
	case ICVTFC:
	case ICVTCF:
	case ICVTRF:
	case ICVTFR:
	case ICVTWS:
	case ICVTSW:
	case IMSPAWN:
	case ICVTCA:
	case ISLICEC:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case INBALT:
		punt(i, SRCOP|DSTOP|TCHECK|WRTPC, optab[i->op]);
		break;
	case INEWCM:
	case INEWCMP:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case IMFRAME:
		if((i->add & ARM) == AXIMM)
			commframe(i);
		else
			punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case INEWCB:
	case INEWCW:
	case INEWCF:
	case INEWCP:
	case INEWCL:
		punt(i, DSTOP|THREOP, optab[i->op]);
		break;
	case IEXIT:
		punt(i, 0, optab[i->op]);
		break;
	case IRAISE:
		punt(i, SRCOP|WRTPC|NEWPC, optab[i->op]);
		break;
	case IMULX:
	case IDIVX:
	case ICVTXX:
	case IMULX0:
	case IDIVX0:
	case ICVTXX0:
	case IMULX1:
	case IDIVX1:
	case ICVTXX1:
	case ICVTFX:
	case ICVTXF:
	case IEXPW:
	case IEXPL:
	case IEXPF:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ISELF:
		punt(i, DSTOP, optab[i->op]);
		break;
	case ITCMP:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;

	/* ---- Inline case/goto ---- */
	case ICASE:
		comcase(i, 1);
		break;
	case IGOTO:
		comgoto(i);
		break;

	/* ---- Data Movement ---- */
	case IMOVW:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVB:
		opwld(i, Ldb, RA0);
		opwst(i, Stb, RA0);
		break;
	case IMOVL:
	case IMOVF:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILEA:
		opwld(i, Lea, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVPC:
		/* native PC, not Dis address (see patch[] / RELPC) */
		con(RELPC(patch[i->s.imm]), RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Arithmetic (word) ---- */
	case IADDW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ADD_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISUBW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SUB_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMULW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		MUL_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IDIVW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		SDIV_REG(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;
	case IMODW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		SDIV_REG(RA2, RA0, RA1);
		MSUB_REG(RA0, RA1, RA2, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Arithmetic (byte) ---- */
	case IADDB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		ADD_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case ISUBB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		SUB_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case IMULB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		MUL_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case IDIVB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		SDIV_REG(RA0, RA0, RA1);
		opwst(i, Stb, RA0);
		break;
	case IMODB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		SDIV_REG(RA2, RA0, RA1);
		MSUB_REG(RA0, RA1, RA2, RA0);
		opwst(i, Stb, RA0);
		break;

	/* ---- Arithmetic (long = word on 64-bit) ---- */
	case IADDL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ADD_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISUBL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SUB_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMULL:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		MUL_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IDIVL:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		SDIV_REG(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;
	case IMODL:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		SDIV_REG(RA2, RA0, RA1);
		MSUB_REG(RA0, RA1, RA2, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Logic (word) ---- */
	case IANDW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		AND_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IORW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ORR_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IXORW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		EOR_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Logic (byte) ---- */
	case IANDB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		AND_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case IORB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		ORR_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case IXORB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		EOR_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;

	/* ---- Logic (long = word on 64-bit) ---- */
	case IANDL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		AND_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IORL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ORR_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IXORL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		EOR_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Shifts (word) ---- */
	case ISHLW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		LSLV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISHRW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ASRV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILSRW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		LSRV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Shifts (byte) ---- */
	case ISHLB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		LSLV_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case ISHRB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		ASRV_REG(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;

	/* ---- Shifts (long) ---- */
	case ISHLL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		LSLV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISHRL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ASRV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILSRL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		LSRV_REG(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Float arithmetic ---- */
	case IADDF:
		opflld(i, Ldw, FA0);
		midfl(i, Ldw, FA1);
		FADD_D(FA1, FA1, FA0);
		opflst(i, Stw, FA1);
		break;
	case ISUBF:
		opflld(i, Ldw, FA0);
		midfl(i, Ldw, FA1);
		FSUB_D(FA1, FA1, FA0);
		opflst(i, Stw, FA1);
		break;
	case IMULF:
		opflld(i, Ldw, FA0);
		midfl(i, Ldw, FA1);
		FMUL_D(FA1, FA1, FA0);
		opflst(i, Stw, FA1);
		break;
	case IDIVF:
		opflld(i, Ldw, FA0);
		midfl(i, Ldw, FA1);
		FDIV_D(FA1, FA1, FA0);
		opflst(i, Stw, FA1);
		break;
	case INEGF:
		opflld(i, Ldw, FA0);
		FNEG_D(FA0, FA0);
		opflst(i, Stw, FA0);
		break;

	/* ---- Conversions ---- */
	case ICVTBW:
		opwld(i, Ldb, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTWB:
		opwld(i, Ldw, RA0);
		opwst(i, Stb, RA0);
		break;
	case ICVTWL:
	case ICVTLW:
		/* WORD and LONG are both 64-bit on this port */
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTWF:
		opwld(i, Ldw, RA0);
		SCVTF_DX(FA0, RA0);
		opflst(i, Stw, FA0);
		break;
	case ICVTFW: {
		/* Match interpreter: W(d) = f < 0 ? f - 0.5 : f + 0.5 */
		u32int *brpatch;
		opflld(i, Ldw, FA0);
		FMOV_D_HALF(FA1);           /* FA1 = 0.5 */
		FCMP_D_ZERO(FA0);           /* compare FA0 with 0.0 */
		brpatch = code;
		BCOND(GE, 0);               /* if FA0 >= 0.0, skip to add */
		FSUB_D(FA0, FA0, FA1);      /* FA0 = FA0 - 0.5 (negative) */
		{
			u32int *brskip = code;
			enc_jtype((int)((0) * 4), RZERO);
			PATCH_BCOND(brpatch);   /* patch: GE lands here */
			FADD_D(FA0, FA0, FA1);  /* FA0 = FA0 + 0.5 (positive) */
			PATCH_B(brskip);
		}
		FCVTZS_XD(RA0, FA0);
		opwst(i, Stw, RA0);
		break;
	}
	case ICVTLF:
		opwld(i, Ldw, RA0);
		SCVTF_DX(FA0, RA0);
		opflst(i, Stw, FA0);
		break;
	case ICVTFL: {
		/* Match interpreter: V(d) = f < 0 ? f - 0.5 : f + 0.5 */
		u32int *brpatch;
		opflld(i, Ldw, FA0);
		FMOV_D_HALF(FA1);           /* FA1 = 0.5 */
		FCMP_D_ZERO(FA0);           /* compare FA0 with 0.0 */
		brpatch = code;
		BCOND(GE, 0);               /* if FA0 >= 0.0, skip to add */
		FSUB_D(FA0, FA0, FA1);      /* FA0 = FA0 - 0.5 (negative) */
		{
			u32int *brskip = code;
			enc_jtype((int)((0) * 4), RZERO);
			PATCH_BCOND(brpatch);   /* patch: GE lands here */
			FADD_D(FA0, FA0, FA1);  /* FA0 = FA0 + 0.5 (positive) */
			PATCH_B(brskip);
		}
		FCVTZS_XD(RA0, FA0);
		opwst(i, Stw, RA0);
		break;
	}

	/* ---- Branches (word) ---- */
	case IBEQW:	cbra(i, EQ);	break;
	case IBNEW:	cbra(i, NE);	break;
	case IBLTW:	cbra(i, LT);	break;
	case IBLEW:	cbra(i, LE);	break;
	case IBGTW:	cbra(i, GT);	break;
	case IBGEW:	cbra(i, GE);	break;

	/* ---- Branches (byte) ---- */
	case IBEQB:	cbrab(i, EQ);	break;
	case IBNEB:	cbrab(i, NE);	break;
	case IBLTB:	cbrab(i, LT);	break;
	case IBLEB:	cbrab(i, LE);	break;
	case IBGTB:	cbrab(i, GT);	break;
	case IBGEB:	cbrab(i, GE);	break;

	/* ---- Branches (long = word on 64-bit) ---- */
	case IBEQL:	cbral(i, EQ);	break;
	case IBNEL:	cbral(i, NE);	break;
	case IBLTL:	cbral(i, LT);	break;
	case IBLEL:	cbral(i, LE);	break;
	case IBGTL:	cbral(i, GT);	break;
	case IBGEL:	cbral(i, GE);	break;

	/* ---- Branches (float) ---- */
	case IBEQF:	cbraf(i, EQ);	break;
	case IBNEF:	cbraf(i, NE);	break;
	case IBLTF:	cbraf(i, MI);	break;
	case IBLEF:	cbraf(i, LS);	break;
	case IBGTF:	cbraf(i, GT);	break;
	case IBGEF:	cbraf(i, GE);	break;

	/* ---- Control Flow ---- */
	case IJMP:
		if(RESCHED)
			schedcheck(i);
		bradis(i->d.ins - mod->prog);
		break;
	case ICALL:
		opwld(i, Ldw, RA0);
		con(RELPC(patch[i - mod->prog + 1]), RA1);
		mem(Stw, O(Frame, lr), RA0, RA1);
		mem(Stw, O(Frame, fp), RA0, RFP);
		MOV_REG(RFP, RA0);
		bradis(i->d.ins - mod->prog);
		break;
	case IRET:
		mem(Ldw, O(Frame, t), RFP, RA1);
		bramac(MacRET);
		break;
	case IFRAME:
		if(UXSRC(i->add) != SRC(AIMM)) {
			punt(i, SRCOP|DSTOP, optab[i->op]);
			break;
		}
		tinit[i->s.imm] = 1;
		con((uvlong)mod->type[i->s.imm], RA3);
		blmac(MacFRAM);
		opwst(i, Stw, RA2);
		break;

	/* ---- Array Indexing ---- */
	case IINDW:
	case IINDF:
	case IINDL:
	case IINDB:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		if(bflag)
			mem(Ldw, O(Array, len), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		r = 0;
		switch(i->op) {
		case IINDL:
		case IINDF:
		case IINDW:
			r = 3;
			break;
		}
		if(UXDST(i->add) == DST(AIMM)) {
			if(bflag) {
				con((uvlong)i->d.imm, RCON);
				CMP_REG(RA2, RCON);
				bcondbra(LS, MacBNDS);
			}
			{
				long off = (r > 0) ? ((long)i->d.imm << r) : i->d.imm;
				if(off >= 0 && off < 4096)
					ADD_IMM(RA0, RA0, off);
				else {
					con(off, RCON);
					ADD_REG(RA0, RA0, RCON);
				}
			}
		} else {
			opwst(i, Ldw, RA1);
			if(bflag) {
				CMP_REG(RA2, RA1);
				bcondbra(LS, MacBNDS);
			}
			if(r > 0) {
				con(r, RCON);
				LSLV_REG(RA1, RA1, RCON);
			}
			ADD_REG(RA0, RA0, RA1);
		}
		mid(i, Stw, RA0);
		break;
	case IINDX:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		opwst(i, Ldw, RA1);
		if(bflag) {
			mem(Ldw, O(Array, len), RA0, RA2);
			CMP_REG(RA2, RA1);
			bcondbra(LS, MacBNDS);
		}
		mem(Ldw, O(Array, t), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		mem(Ldw32, O(Type, size), RA2, RA2);
		MUL_REG(RA1, RA1, RA2);
		ADD_REG(RA0, RA0, RA1);
		mid(i, Stw, RA0);
		break;
	case IINDC: {
		u32int *ascii, *done;

		opwld(i, Ldw, RA1);
		CMN_IMM(RA1, 1);
		bcondbra(EQ, MacBNDS);
		mid(i, Ldw, RA2);
		mem(Ldw32s, O(String, len), RA1, RA0);
		if(bflag) {
			MOV_REG(RA3, RA0);
			CMP_IMM(RA3, 0);
			{
				u32int *sk = code;
				BCOND(GE, 0);
				NEG_REG(RA3, RA3);
				PATCH_BCOND(sk);
			}
			CMP_REG(RA3, RA2);
			bcondbra(LS, MacBNDS);
		}
		ADD_IMM(RA1, RA1, O(String, data));
		CMP_IMM(RA0, 0);
		ascii = code;
		BCOND(GE, 0);
		if(sizeof(Rune) == 4)
			do { SLLI(RCON, RA2, 2); ADD_REG(RCON, RA1, RCON); LWU(RA3, RCON, 0); } while(0);
		else
			*code++ = (0x78607800 | (RA2<<16) | (RA1<<5) | RA3);
		done = code;
		enc_jtype((int)((0) * 4), RZERO);
		PATCH_BCOND(ascii);
		do { ADD_REG(RCON, RA1, RA2); LB(RA3, RCON, 0); } while(0);
		PATCH_B(done);
		opwst(i, Stw, RA3);
		break;
	}

	/* ---- Pointer Move ---- */
	case ITAIL:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		mem(Ldw, O(List, tail), RA0, RA1);
		goto movp;
	case IMOVP:
		opwld(i, Ldw, RA1);
		goto movp;
	case IHEADP:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		mem(Ldw, OA(List, data), RA0, RA1);
	movp:
		CMN_IMM(RA1, 1);
		{
			u32int *skip_colr = code;
			BCOND(EQ, 0);
			blmac(MacCOLR);
			PATCH_BCOND(skip_colr);
		}
		opwst(i, Lea, RA2);
		mem(Ldw, 0, RA2, RA0);
		mem(Stw, 0, RA2, RA1);
		blmac(MacFRP);
		break;

	/* ---- Head (scalar from list) ---- */
	case IHEADW:
	case IHEADL:
	case IHEADF:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		mem(Ldw, OA(List, data), RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case IHEADB:
		opwld(i, Ldw, RA0);
		CMN_IMM(RA0, 1);
		bcondbra(EQ, MacBNDS);
		mem(Ldb, OA(List, data), RA0, RA0);
		opwst(i, Stb, RA0);
		break;

	/* ---- Memory Move ---- */
	case IHEADM:
		opwld(i, Ldw, RA1);
		CMN_IMM(RA1, 1);
		bcondbra(EQ, MacBNDS);
		ADD_IMM(RA1, RA1, OA(List, data));
		movmem(i);
		break;
	case IMOVM:
		opwld(i, Lea, RA1);
		movmem(i);
		break;

	/* ---- Length ---- */
	case ILENA:
		opwld(i, Ldw, RA1);
		MOV_REG(RA0, XZR);
		CMN_IMM(RA1, 1);
		{
			u32int *skip = code;
			BCOND(EQ, 0);
			mem(Ldw, O(Array, len), RA1, RA0);
			PATCH_BCOND(skip);
		}
		opwst(i, Stw, RA0);
		break;
	case ILENC:
		opwld(i, Ldw, RA1);
		MOV_REG(RA0, XZR);
		CMN_IMM(RA1, 1);
		{
			u32int *skip = code;
			BCOND(EQ, 0);
			mem(Ldw32s, O(String, len), RA1, RA0);
			/* if len < 0, negate (Rune vs byte) */
			CMP_IMM(RA0, 0);
			{
				u32int *skip2 = code;
				BCOND(GE, 0);
				NEG_REG(RA0, RA0);
				PATCH_BCOND(skip2);
			}
			PATCH_BCOND(skip);
		}
		opwst(i, Stw, RA0);
		break;
	case ILENL:
		MOV_REG(RA0, XZR);
		opwld(i, Ldw, RA1);
		{
			u32int *loop, *done;
			loop = code;
			CMN_IMM(RA1, 1);
			done = code;
			BCOND(EQ, 0);
			mem(Ldw, O(List, tail), RA1, RA1);
			ADD_IMM(RA0, RA0, 1);
			{
				long off = (long)(loop - code);
				enc_jtype((int)((off) * 4), RZERO);
			}
			PATCH_BCOND(done);
		}
		opwst(i, Stw, RA0);
		break;

	case INOP:
		break;
	}
}


/*
 * preamble — comvec entry/exit trampoline (allocated once).
 */
static void
preamble(void)
{
	ulong sz;
	u32int *start, *xpc_loc, *epilogue;

	if(comvec)
		return;

	sz = 128 * sizeof(u32int);
	comvec = mmap(0, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(comvec == MAP_FAILED) {
		comvec = nil;
		error(exNomem);
	}

	code = (u32int*)comvec;
	start = code;

	ADDI(RSP, RSP, -48);
	SD(RRA, RSP, 40);
	SD(RREG, RSP, 32);
	SD(RFP, RSP, 24);
	SD(RMP, RSP, 16);
	SD(RSAVE, RSP, 8);

	con((uvlong)&R, RREG);

	xpc_loc = code;
	con(0ULL, RTA);
	mem(Stw, O(REG, xpc), RREG, RTA);

	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(REG, PC), RREG, RTA);
	BR_REG(RTA);

	epilogue = code;
	LD(RSAVE, RSP, 8);
	LD(RMP, RSP, 16);
	LD(RFP, RSP, 24);
	LD(RREG, RSP, 32);
	LD(RRA, RSP, 40);
	ADDI(RSP, RSP, 48);
	RET_X30();

	{
		u32int *save = code;
		code = xpc_loc;
		con((uvlong)epilogue, RTA);
		code = save;
	}

	segflush(start, sz);

	if(cflag > 3) {
		int k;
		print("preamble at %.8p (%ld words):\n", start, (long)(code - start));
		for(k = 0; k < code - start; k++)
			print("  %.8p  %.8ux\n", &start[k], start[k]);
	}
}


/*
 * Macro implementations.
 */
static void
macfrp(void)
{
	u32int *nilcheck, *destroy, *done;

	/* destroy the pointer in RA0; match arm32: leave ref==1 in memory
	 * for rdestroy(), which does its own --h->ref. */
	CMN_IMM(RA0, 1);
	nilcheck = code;
	BCOND(EQ, 0);			/* H → return */

	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA0, RA2);
	SUBS_IMM(RA2, RA2, 1);
	destroy = code;
	BCOND(EQ, 0);			/* was last ref → destroy */
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA0, RA2);
	done = code;
	enc_jtype((int)((0) * 4), RZERO);			/* → return */

	PATCH_BCOND(destroy);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, s), RREG, RA0);
	mem(Stw, O(REG, st), RREG, RRA);
	con((uvlong)rdestroy, RTA);
	BLR_REG(RTA);
	con((uvlong)&R, RREG);
	mem(Ldw, O(REG, st), RREG, RRA);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);

	PATCH_BCOND(nilcheck);
	PATCH_B(done);
	RET_X30();
}

static void
maccolr(void)
{
	u32int *done;

	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA1, RA0);
	ADD_IMM(RA0, RA0, 1);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA1, RA0);

	mem(Ldw32, O(Heap, color) - sizeof(Heap), RA1, RA0);
	con((uvlong)&mutator, RA2);
	mem(Ldw32, 0, RA2, RA2);
	CMP_REG(RA0, RA2);
	done = code;
	BCOND(EQ, 0);

	con(propagator, RA2);
	mem(Stw32, O(Heap, color) - sizeof(Heap), RA1, RA2);
	con((uvlong)&nprop, RA2);
	con(1, RA0);
	mem(Stw32, 0, RA2, RA0);

	PATCH_BCOND(done);
	RET_X30();
}

static void
macret(void)
{
	u32int *notypelab, *nodestroylab, *nofplab, *nomrlab, *noreflab;
	u32int *linterp;
	Inst dummy;

	CBZ_X(RA1, 0);
	notypelab = code - 1;

	mem(Ldw, O(Type, destroy), RA1, RA0);
	CBZ_X(RA0, 0);
	nodestroylab = code - 1;

	mem(Ldw, O(Frame, fp), RFP, RA2);
	CBZ_X(RA2, 0);
	nofplab = code - 1;

	mem(Ldw, O(Frame, mr), RFP, RA3);
	CBZ_X(RA3, 0);
	nomrlab = code - 1;

	mem(Ldw, O(REG, M), RREG, RA2);
	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA2, RA3);
	SUB_IMM(RA3, RA3, 1);
	CBZ_X(RA3, 0);
	noreflab = code - 1;
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA2, RA3);

	mem(Ldw, O(Frame, mr), RFP, RA1);
	mem(Stw, O(REG, M), RREG, RA1);
	mem(Ldw, O(Modlink, MP), RA1, RMP);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw32, O(Modlink, compiled), RA1, RA3);
	CBZ_X(RA3, 0);
	linterp = code - 1;

	/* Compiled: call destroy, jump to lr */
	BLR_REG(RA0);
	mem(Stw, O(REG, SP), RREG, RFP);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	mem(Ldw, O(Frame, fp), RFP, RFP);
	mem(Stw, O(REG, FP), RREG, RFP);
	BR_REG(RA1);

	/* Not compiled: return to interpreter */
	PATCH_BCOND(linterp);
	BLR_REG(RA0);
	mem(Stw, O(REG, SP), RREG, RFP);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	mem(Ldw, O(Frame, fp), RFP, RFP);
	mem(Stw, O(REG, PC), RREG, RA1);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	BR_REG(RTA);

	/* Punt fallback */
	PATCH_BCOND(notypelab);
	PATCH_BCOND(nodestroylab);
	PATCH_BCOND(nofplab);
	PATCH_BCOND(nomrlab);
	PATCH_BCOND(noreflab);
	dummy.add = AXNON;
	punt(&dummy, TCHECK|NEWPC, optab[IRET]);
}

static void
maccase(void)
{
	u32int *out, *notlt, *notfound;

	mem(Ldw, 0, RA3, RA2);		/* count */
	MOV_REG(RSAVE, RA3);		/* save initial table in X6 */

	u32int *loop = code;
	CMP_IMM(RA2, 0);
	out = code;
	BCOND(LE, 0);

	con(1, RTA);
	LSRV_REG(RA0, RA2, RTA);	/* n2 = n >> 1 */
	con(3 * IBY2WD, RTA);
	MUL_REG(RCON, RA0, RTA);
	ADD_REG(RCON, RA3, RCON);	/* pivot = table + n2*3*IBY2WD */

	mem(Ldw, IBY2WD, RCON, RTA);
	CMP_REG(RA1, RTA);
	notlt = code;
	BCOND(GE, 0);
	MOV_REG(RA2, RA0);		/* n = n2 */
	{
		long off = (long)(loop - code);
		enc_jtype((int)((off) * 4), RZERO);
	}

	PATCH_BCOND(notlt);
	mem(Ldw, 2 * IBY2WD, RCON, RTA);
	CMP_REG(RA1, RTA);
	notfound = code;
	BCOND(GE, 0);
	mem(Ldw, 3 * IBY2WD, RCON, RTA);
	BR_REG(RTA);			/* found! */

	PATCH_BCOND(notfound);
	ADD_IMM(RA3, RCON, 3 * IBY2WD);
	ADD_IMM(RA0, RA0, 1);
	SUB_REG(RA2, RA2, RA0);
	{
		long off = (long)(loop - code);
		enc_jtype((int)((off) * 4), RZERO);
	}

	/* Default */
	PATCH_BCOND(out);
	mem(Ldw, 0, RSAVE, RA2);
	con(3 * IBY2WD, RTA);
	MUL_REG(RA2, RA2, RTA);
	ADD_REG(RSAVE, RSAVE, RA2);
	mem(Ldw, IBY2WD, RSAVE, RTA);
	BR_REG(RTA);
}

static void
macmcal(void)
{
	u32int *notnil, *hasprog;

	CMN_IMM(RA0, 1);
	notnil = code;
	BCOND(NE, 0);

	/* RA0 == H: punt to rmcall */
	mem(Stw, O(REG, st), RREG, RRA);
	mem(Stw, O(REG, FP), RREG, RA2);
	mem(Stw, O(REG, dt), RREG, RA0);
	con((uvlong)rmcall, RTA);
	BLR_REG(RTA);
	con((uvlong)&R, RREG);
	mem(Ldw, O(REG, st), RREG, RRA);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET_X30();

	PATCH_BCOND(notnil);
	mem(Ldw, O(Modlink, prog), RA3, RA1);
	CBNZ_X(RA1, 0);
	hasprog = code - 1;

	/* prog == nil: same punt */
	mem(Stw, O(REG, st), RREG, RRA);
	mem(Stw, O(REG, FP), RREG, RA2);
	mem(Stw, O(REG, dt), RREG, RA0);
	con((uvlong)rmcall, RTA);
	BLR_REG(RTA);
	con((uvlong)&R, RREG);
	mem(Ldw, O(REG, st), RREG, RRA);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET_X30();

	PATCH_BCOND(hasprog);
	MOV_REG(RFP, RA2);
	mem(Stw, O(REG, M), RREG, RA3);
	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA3, RA1);
	ADD_IMM(RA1, RA1, 1);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA3, RA1);
	mem(Ldw, O(Modlink, MP), RA3, RMP);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw32, O(Modlink, compiled), RA3, RA1);
	CBNZ_X(RA1, 5);	/* skip 4 insns (Stw FP, Stw PC, Ldw xpc, BR xpc) to compiled path */
	/* Not compiled */
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, PC), RREG, RA0);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	BR_REG(RTA);
	/* Compiled */
	BR_REG(RA0);
}

static void
macfram(void)
{
	u32int *expand;

	mem(Ldw, O(REG, SP), RREG, RA0);
	mem(Ldw32, O(Type, size), RA3, RA1);
	ADD_REG(RA0, RA0, RA1);
	mem(Ldw, O(REG, TS), RREG, RA1);
	CMP_REG(RA0, RA1);
	expand = code;
	BCOND(HS, 0);

	mem(Ldw, O(REG, SP), RREG, RA2);
	mem(Stw, O(REG, SP), RREG, RA0);
	mem(Stw, O(Frame, t), RA2, RA3);
	MOV_REG(RA0, XZR);
	mem(Stw, O(Frame, mr), RA2, RA0);
	/* Save RA2 (frame ptr) and LR before calling initialize */
	mem(Stw, O(REG, dt), RREG, RA2);
	mem(Stw, O(REG, st), RREG, RRA);
	mem(Ldw, O(Type, initialize), RA3, RTA);
	BLR_REG(RTA);
	mem(Ldw, O(REG, st), RREG, RRA);
	mem(Ldw, O(REG, dt), RREG, RA2);
	RET_X30();

	PATCH_BCOND(expand);
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, st), RREG, RRA);
	con((uvlong)extend, RTA);
	BLR_REG(RTA);
	con((uvlong)&R, RREG);
	mem(Ldw, O(REG, st), RREG, RRA);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, s), RREG, RA2);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET_X30();
}

static void
macmfra(void)
{
	/* RRA holds resume PC (set by commframe before bramac). */
	mem(Stw, O(REG, st), RREG, RRA);
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, d), RREG, RA0);
	mem(Stw, O(REG, FP), RREG, RFP);
	con((uvlong)rmfram, RTA);
	BLR_REG(RTA);
	con((uvlong)&R, RREG);
	mem(Ldw, O(REG, st), RREG, RRA);	/* restore resume PC */
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET_X30();
}

static void
macrelq(void)
{
	/* Save LR (set by BL in schedcheck) as R.PC.
	 * On re-entry after reschedule, comvec jumps to R.PC,
	 * which is the comparison code — not past the branch.
	 */
	mem(Stw, O(REG, PC), RREG, RRA);	/* R.PC = LR (RRA) */
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	BR_REG(RTA);
}

static void
macbounds(void)
{
	con((uvlong)bounds, RTA);
	BLR_REG(RTA);
}

/*
 * comi / comd — type initializer and destroyer.
 */
void
comi(Type *t)
{
	int i, j, m, c;

	con((uvlong)H, RA0);
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i * 8 * (int)sizeof(WORD*);
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m)
				mem(Stw, j, RA2, RA0);
			j += sizeof(WORD*);
		}
	}
	RET_X30();
}

void
comd(Type *t)
{
	int i, j, m, c;
	uvlong macfrp_addr;

	/*
	 * Use absolute addressing (con + BLR) instead of relative BL
	 * for calling MacFRP.  typecom() allocates a separate mmap buffer
	 * which can be >128MB from the module's code buffer, exceeding
	 * the absolute JALR's range.
	 */
	macfrp_addr = (uvlong)IA(macro, MacFRP);

	mem(Stw, O(REG, dt), RREG, RRA);
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i * 8 * (int)sizeof(WORD*);
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m) {
				mem(Ldw, j, RFP, RA0);
				con(macfrp_addr, RTA);
				BLR_REG(RTA);
			}
			j += sizeof(WORD*);
		}
	}
	mem(Ldw, O(REG, dt), RREG, RRA);
	RET_X30();
}

/*
 * JIT code allocator: leading ulong holds total mmap length for freecode().
 */
static void*
jitalloc(ulong sz)
{
	ulong *hdr;
	ulong tot;

	tot = sz + sizeof(ulong);
	hdr = mmap(0, tot, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(hdr == MAP_FAILED)
		return nil;
	hdr[0] = tot;
	return hdr + 1;
}

void
freecode(void *p)
{
	ulong *hdr;

	if(p == nil)
		return;
	hdr = (ulong*)p - 1;
	munmap(hdr, hdr[0]);
}

static int
typecom(Type *t)
{
	int n;
	u32int *tmp, *start;
	ulong sz;

	if(t == nil || t->initialize != 0)
		return 1;

	tmp = mallocz(4096 * sizeof(u32int), 0);
	if(tmp == nil)
		error(exNomem);

	code = tmp;
	comi(t);
	n = code - tmp;
	code = tmp;
	comd(t);
	n += code - tmp;
	free(tmp);

	sz = n * sizeof(u32int);
	start = jitalloc(sz);
	if(start == nil)
		return 0;

	code = start;
	t->initialize = code;
	comi(t);
	t->destroy = code;
	comd(t);

	segflush(start, sz);

	if(cflag > 3)
		print("typ= %.8p %4d i %.8p d %.8p asm=%lud\n",
			t, t->size, t->initialize, t->destroy, sz);
	return 1;
}

static void
patchex(Module *m, ulong *p)
{
	Handler *h;
	Except *e;

	if((h = m->htab) == nil)
		return;
	for( ; h->etab != nil; h++) {
		h->pc1 = p[h->pc1] * sizeof(u32int);
		h->pc2 = p[h->pc2] * sizeof(u32int);
		for(e = h->etab; e->s != nil; e++)
			if(e->pc != (ulong)-1)
				e->pc = p[e->pc] * sizeof(u32int);
		if(e->pc != (ulong)-1)
			e->pc = p[e->pc] * sizeof(u32int);
	}
}

int
compile(Module *m, int size, Modlink *ml)
{
	Link *l;
	Modl *e;
	int i, n;
	u32int *s, *tmp = nil;

	/* JIT enabled */
	ulong codesize = 0;
	ulong tmpsize;

	base = nil;
	patch = mallocz((size + 1) * sizeof(*patch), 0);
	tinit = malloc(m->ntype * sizeof(*tinit));
	/* Size tmp buffer proportional to module: each Dis instruction can
	 * expand to many RV64 instructions (especially case statements).
	 * Use 64 RV64 instructions per Dis instruction as upper bound,
	 * with a minimum of 8192. */
	if(size > 0 && (ulong)size > ((ulong)-1) / 96) {
		/* overflow check */
		goto bad;
	}
	tmpsize = size * 96;
	if(tmpsize < 8192)
		tmpsize = 8192;
	tmp = malloc(tmpsize * sizeof(u32int));
	if(tinit == nil || patch == nil || tmp == nil)
		goto bad;

	preamble();

	mod = m;
	n = 0;
	pass = 0;
	nlit = 0;

	if(cflag > 3) {
		print("compile: entry=%.8p prog=%.8p idx=%ld size=%d\n",
			m->entry, m->prog, (long)(m->entry - m->prog), size);
		print("  &m->entry=%.8p &m->ext[0].u.pc=%.8p\n",
			&m->entry, &m->ext[0].u.pc);
	}

	for(i = 0; i < size; i++) {
		codeoff = n;
		code = tmp;
		comp(&m->prog[i]);
		if(code - tmp >= (int)tmpsize) {
			print("JIT: instruction %d overflow tmp buffer (%lud >= %lud)\n",
				i, (ulong)(code - tmp), tmpsize);
			goto bad;
		}
		patch[i] = n;
		n += code - tmp;
		/* Check for total size overflow before continuing */
		if(n > 16*1024*1024) {
			print("JIT: module too large for compilation (%d instructions)\n", n);
			goto bad;
		}
	}
	patch[size] = n;	/* sentinel: one past last Dis instruction */

	/* BRK trap: catch fall-through from last instruction into macros */
	n++;

	for(i = 0; i < nelem(mactab); i++) {
		codeoff = n;
		code = tmp;
		mactab[i].gen();
		macro[mactab[i].idx] = n;
		n += code - tmp;
	}

	/* Add 25% safety margin on literal pool for Phase 0/1 divergence */
	codesize = n * sizeof(u32int) + (nlit + nlit/4 + 16) * sizeof(ulong);

	/* Round up to page boundary + guard page for safety */
	{
		ulong pagesz = 4096;	/* Linux riscv64 */
		codesize = (codesize + pagesz - 1) & ~(pagesz - 1);
		codesize += pagesz;	/* extra guard page */
	}

	base = jitalloc(codesize);
	if(base == nil)
		goto bad;

	{
		static int ncompiled;
		ncompiled++;
		if(cflag > 3)
			print("[%d] dis=%5d riscv64=%5d mmap=%5lud base=%.8p end=%.8p lit=%.8p: %s\n",
				ncompiled, size, n, (ulong)codesize,
				(void*)base, (void*)(base + n), (void*)litpool, m->name);
	}

	pass = 1;
	nlit = 0;
	litpool = (ulong*)(base + n);
	litlimit = (ulong*)((uchar*)base + codesize);
	code = base;
	n = 0;
	codeoff = 0;

	for(i = 0; i < size; i++) {
		s = code;
		comp(&m->prog[i]);
		if(patch[i] != n) {
			print("%3d %D\n", i, &m->prog[i]);
			print("%lud != %d\n", patch[i], n);
			urk("phase error");
		}
		n += code - s;
		if(cflag > 4) {
			print("%3d %D\n", i, &m->prog[i]);
			das(s, code - s);
		}
	}

	/* BRK trap: catch fall-through from last instruction into macros */
	*code++ = 0x00100073;	/* EBREAK */
	n++;
	if(cflag > 4)
		print("TRAP:\n");

	for(i = 0; i < nelem(mactab); i++) {
		s = code;
		mactab[i].gen();
		if(macro[mactab[i].idx] != n) {
			print("mac phase err: %lud != %d\n", macro[mactab[i].idx], n);
			urk("phase error");
		}
		n += code - s;
		if(cflag > 4) {
			print("%s:\n", mactab[i].name);
			das(s, code - s);
		}
	}

	/*
	 * Generate type init/destroy stubs before rewriting any PCs so a
	 * typecom failure can still fall back to the interpreter.
	 */
	for(l = m->ext; l->name; l++) {
		if(typecom(l->frame) == 0)
			goto bad;
	}
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++, e++) {
			if(typecom(e->frame) == 0)
				goto bad;
		}
	}
	for(i = 0; i < m->ntype; i++) {
		if(tinit[i] != 0 && typecom(m->type[i]) == 0)
			goto bad;
	}

	if(cflag > 3)
		print("A: mod->entry=%.8p\n", mod->entry);
	for(l = m->ext; l->name; l++)
		l->u.pc = (Inst*)RELPC(patch[l->u.pc - m->prog]);
	if(cflag > 3)
		print("B: mod->entry=%.8p\n", mod->entry);
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++) {
			e->u.pc = (Inst*)RELPC(patch[e->u.pc - m->prog]);
			e++;
		}
	}
	if(cflag > 3)
		print("C: mod->entry=%.8p\n", mod->entry);
	if(cflag > 3)
		print("D: mod->entry=%.8p\n", mod->entry);

	patchex(m, patch);

	if(cflag > 3)
		print("E: mod->entry=%.8p\n", mod->entry);
	{
		long eidx = mod->entry - mod->prog;
		if(eidx < 0 || eidx >= size)
			eidx = 0;
		if(cflag > 3)
			print("setting entry: eidx=%ld RELPC=%.8p\n",
				eidx, (void*)RELPC(patch[eidx]));
		m->entry = (Inst*)RELPC(patch[eidx]);
	}
	m->pctab = patch;

	segflush(base, codesize);

	if(cflag > 3) {
		long eidx;
		print("code at %.8p: %.8ux %.8ux %.8ux %.8ux\n",
			base, base[0], base[1], base[2], base[3]);
		print("before entry: mod->entry=%.8p mod->prog=%.8p\n",
			mod->entry, mod->prog);
		eidx = mod->entry - mod->prog;
		print("entry idx=%ld patch[0]=%lud\n", eidx, patch[0]);
	}

	free(m->prog);
	m->prog = (Inst*)base;
	m->compiled = 1;
	free(tinit);
	free(tmp);
	return 1;
bad:
	if(base != nil)
		freecode(base);
	free(patch);
	free(tinit);
	free(tmp);
	return 0;
}
