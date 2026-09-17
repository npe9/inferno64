#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"ureg.h"
#include	"armv7m.h"
#include	"fpi.h"

/*
 * Double precision for a core that has not got any.
 *
 * A Cortex-M4's floating point extension is FPv4-SP: all 32 of the S
 * registers, and single precision arithmetic only.  utils/tc emits the
 * double precision instructions regardless -- utils/tl gives every F
 * register a D register -- so the Dis interpreter's real arithmetic and
 * everything in libmath is written in instructions the part will not
 * execute.  Reaching one raises a UsageFault with CFSR.UNDEFINSTR set.
 *
 * This decodes that instruction and does the arithmetic in software,
 * then returns to the instruction after it, so the same kernel binary
 * runs on a Cortex-M4 and on a Cortex-M7 that has the hardware.  That
 * property is why this is done here rather than by teaching utils/tc to
 * emit calls: one image, either core.  It is also much the slower of the
 * two arrangements -- a trap and a software operation for every double
 * -- which is a trade worth making for correctness first and revisiting
 * if a board ever needs the speed.
 *
 * The register file is reached with fpregsave and fpregrestore
 * (os/inferno/armv7m/l.s), which move all 32 S registers at once using
 * single precision transfers the part does have.  D0-D15 alias S0-S31 in
 * pairs, low word first, which is exactly the layout fpi.h's Double
 * wants, so a double operand is just &s[2*d].
 *
 * Nothing here uses floating point, which it must not: fpu.c turns
 * FPCCR.ASPEN and FPCCR.LSPEN off so an exception does not stack the
 * floating point registers, and a handler that used them would return
 * to the interrupted code with the file changed.  os/inferno/port/fpi.c
 * is integer throughout.
 *
 * Anything not decoded here returns 0 and the caller reports the fault
 * as before, printing the encoding and the pc, so an instruction this
 * does not yet know announces itself with an address to look up rather
 * than failing quietly.
 */

enum {
	Nsreg	= 32,		/* S0-S31; D0-D15 alias them in pairs */
	Ndreg	= 16,

	/* FPSCR condition flags, as VCMP leaves them and VMRS reads them */
	Fpn	= 1<<31,
	Fpz	= 1<<30,
	Fpc	= 1<<29,
	Fpv	= 1<<28,
};

int fpitrace = 1;	/* TEMPORARY: set from the console to trace conversions */

static void
getd(Internal *x, ulong *s, int d)
{
	fpid2i(x, &s[2*d]);
}

static void
putd(ulong *s, int d, Internal *x)
{
	fpii2d(&s[2*d], x);		/* fpii2d rounds for us */
}

/*
 * VFPExpandImm for a 64 bit value, from the architecture reference: the
 * eight bits are a sign, an exponent whose top bit is the complement of
 * the next and whose next eight repeat it, then two more exponent bits
 * and four fraction bits.  Only this small set of constants can be named
 * by a VMOV immediate; everything else arrives through a load.
 */
static void
expandimm(ulong *s, int d, int imm8)
{
	ulong hi;
	int sign, b6, exp;

	sign = (imm8>>7) & 1;
	b6 = (imm8>>6) & 1;
	exp = ((!b6)<<10) | ((b6? 0xff: 0)<<2) | ((imm8>>4) & 3);
	hi = ((ulong)sign<<31) | ((ulong)exp<<20) | ((ulong)(imm8 & 0xf)<<16);
	s[2*d] = 0;
	s[2*d+1] = hi;
}

extern int fpitrace;

static void
compare(ulong *s, int dd, int dm, int withzero)
{
	Internal x, y;
	ulong fpscr;
	int c;

	getd(&x, s, dd);
	if(withzero){
		memset(&y, 0, sizeof(y));
		SetZero(&y);
	}
	else
		getd(&y, s, dm);

	fpscr = fpscrget() & ~(Fpn|Fpz|Fpc|Fpv);
	if(IsNaN(&x) || IsNaN(&y))
		fpscr |= Fpc|Fpv;		/* unordered */
	else{
		c = fpicmp(&x, &y);
		if(c < 0)
			fpscr |= Fpn;
		else if(c == 0)
			fpscr |= Fpz|Fpc;
		else
			fpscr |= Fpc;
	}
	fpscrset(fpscr);
	if(fpitrace){
		print("cmp D%d=", dd); print("%.8lux", s[2*dd+1]);
		print(":%.8lux", s[2*dd]);
		if(withzero)
			print(" vs 0");
		else{
			print(" vs D%d=", dm); print("%.8lux", s[2*dm+1]);
			print(":%.8lux", s[2*dm]);
		}
		print(" fpscr=%.8lux\n", fpscr);
	}
}

int
fpiemu(Ureg *ur)
{
	ushort hw1, hw2;
	ulong s[Nsreg];
	int dd, dn, dm, sel;
	Internal x, y, r;

	hw1 = ((ushort*)ur->pc)[0];
	hw2 = ((ushort*)ur->pc)[1];
	if((hw1 & 0xff00) != 0xee00)		/* not VFP data processing */
		return 0;
	if(((hw2>>8) & 0xf) != 0xb)		/* cp11 is double precision */
		return 0;

	/*
	 * Double register numbers are D:Vd, N:Vn and M:Vm.  They are only
	 * meaningful for the operands that really are doubles: the
	 * conversions between a double and an integer have a single
	 * register on the integer side, numbered Vd:D or Vm:M the other way
	 * round, and those cases work it out for themselves.  So the range
	 * check belongs with each operand's use, not here -- an earlier
	 * version checked it here and would have refused a legitimate
	 * VCVT whose integer register was S31.
	 */
	dd = (((hw1>>6) & 1)<<4) | ((hw2>>12) & 0xf);
	dn = (((hw2>>7) & 1)<<4) | (hw1 & 0xf);
	dm = (((hw2>>5) & 1)<<4) | (hw2 & 0xf);

	fpregsave(s);

	/*
	 * Bits 7, 5 and 4 of the first halfword pick the operation; bit 6
	 * is Vd's high bit and has to come out of the comparison.
	 */
	switch(hw1 & 0x00b0){
	case 0x0020:				/* VMUL.F64 */
		if(hw2 & 0x0040)		/* VNMUL, not yet */
			goto unhandled;
		if(dd >= Ndreg || dn >= Ndreg || dm >= Ndreg)
			goto unhandled;
		getd(&x, s, dn);
		getd(&y, s, dm);
		fpimul(&x, &y, &r);
		putd(s, dd, &r);
		break;

	case 0x0030:				/* VADD.F64, VSUB.F64 */
		if(dd >= Ndreg || dn >= Ndreg || dm >= Ndreg)
			goto unhandled;
		getd(&x, s, dn);
		getd(&y, s, dm);
		if(hw2 & 0x0040)		/* subtract: add the negation */
			y.s ^= 1;
		/*
		 * fpiadd and fpisub are not signed addition and signed
		 * subtraction; they are the like-sign and unlike-sign
		 * halves of one addition, and the caller dispatches.  The
		 * same idiom as os/inferno/pc/fpi387.c.
		 */
		(x.s == y.s? fpiadd: fpisub)(&x, &y, &r);
		putd(s, dd, &r);
		if(fpitrace){
			print("%s ", (hw2 & 0x0040)? "sub": "add");
			print("D%d=", dd); print("%.8lux", s[2*dd+1]);
			print(":%.8lux\n", s[2*dd]);
		}
		break;

	case 0x0080:				/* VDIV.F64 */
		if(hw2 & 0x0040)
			goto unhandled;
		if(dd >= Ndreg || dn >= Ndreg || dm >= Ndreg)
			goto unhandled;
		/*
		 * fpidiv(x, y, i) computes i = y/x -- the divisor is the
		 * first argument -- and it consumes both, so both are
		 * copies taken here.
		 */
		getd(&x, s, dm);
		getd(&y, s, dn);
		fpidiv(&x, &y, &r);
		putd(s, dd, &r);
		break;

	case 0x00b0:
		/* opc2 in the first halfword's low nibble, opc3 in hw2<7:6> */
		sel = ((hw1 & 0xf)<<2) | ((hw2>>6) & 3);
		switch(sel){
		case (0<<2)|0: case (1<<2)|0:	/* VMOV.F64 Dd, #imm */
		case (2<<2)|0: case (3<<2)|0:
		case (4<<2)|0: case (5<<2)|0:
		case (6<<2)|0: case (7<<2)|0:
		case (8<<2)|0: case (9<<2)|0:
		case (10<<2)|0: case (11<<2)|0:
		case (12<<2)|0: case (13<<2)|0:
		case (14<<2)|0: case (15<<2)|0:
			if(dd >= Ndreg)
				goto unhandled;
			expandimm(s, dd, ((hw1 & 0xf)<<4) | (hw2 & 0xf));
			break;

		case (0<<2)|1:			/* VMOV.F64 Dd, Dm */
			if(dd >= Ndreg || dm >= Ndreg)
				goto unhandled;
			s[2*dd] = s[2*dm];
			s[2*dd+1] = s[2*dm+1];
			break;

		case (0<<2)|3:			/* VABS.F64 */
			if(dd >= Ndreg || dm >= Ndreg)
				goto unhandled;
			s[2*dd] = s[2*dm];
			s[2*dd+1] = s[2*dm+1] & ~0x80000000;
			break;

		case (1<<2)|1:			/* VNEG.F64 */
			if(dd >= Ndreg || dm >= Ndreg)
				goto unhandled;
			s[2*dd] = s[2*dm];
			s[2*dd+1] = s[2*dm+1] ^ 0x80000000;
			break;

		case (7<<2)|3:			/* VCVT.F32.F64 Sd, Dm */
			/*
			 * Only this direction reaches here: the other one,
			 * single to double, is encoded with cp10 and so is
			 * not a double-precision instruction at all.  The
			 * destination is a single register, Vd:D rather than
			 * D:Vd.
			 */
			if(dm >= Ndreg)
				goto unhandled;
			getd(&x, s, dm);
			fpii2s(&s[(((hw2>>12) & 0xf)<<1) | ((hw1>>6) & 1)], &x);
			break;

		case (8<<2)|1:			/* VCVT.F64.U32 Dd, Sm */
		case (8<<2)|3:			/* VCVT.F64.S32 Dd, Sm */
			/*
			 * The integer is in a single register, so it is
			 * indexed Vm:M.  Unsigned is only taken when the
			 * value also reads as a non-negative signed one --
			 * fpiw2i is the only integer conversion here and it
			 * is signed -- and announces itself otherwise rather
			 * than being quietly wrong.
			 */
			sel = ((hw2 & 0xf)<<1) | ((hw2>>5) & 1);
			if((hw2 & 0x0080) == 0 && (s[sel] & 0x80000000) != 0)
				goto unhandled;
			if(dd >= Ndreg)
				goto unhandled;
			fpiw2i(&x, &s[sel]);
			putd(s, dd, &x);
			if(fpitrace){
				print("i2d S%d=", sel); print("%.8lux", s[sel]);
				print(" -> D%d=", dd); print("%.8lux", s[2*dd+1]);
				print(":%.8lux\n", s[2*dd]);
			}
			break;

		case (12<<2)|1: case (12<<2)|3:	/* VCVT.U32.F64 Sd, Dm */
		case (13<<2)|1: case (13<<2)|3:	/* VCVT.S32.F64 Sd, Dm */
			if(dm >= Ndreg)
				goto unhandled;
			getd(&x, s, dm);
			if((hw1 & 0xf) == 12 && x.s != 0)
				goto unhandled;		/* negative to unsigned */
			sel = (((hw2>>12) & 0xf)<<1) | ((hw1>>6) & 1);
			fpii2w((Word*)&s[sel], &x);
			if(fpitrace){
				print("d2i D%d=", dm); print("%.8lux", s[2*dm+1]);
				print(":%.8lux", s[2*dm]);
				print(" -> S%d=", sel); print("%.8lux\n", s[sel]);
			}
			break;

		case (4<<2)|1:			/* VCMP.F64 Dd, Dm */
		case (4<<2)|3:			/* VCMPE.F64 Dd, Dm */
			if(dd >= Ndreg || dm >= Ndreg)
				goto unhandled;
			compare(s, dd, dm, 0);
			break;

		case (5<<2)|1:			/* VCMP.F64 Dd, #0.0 */
		case (5<<2)|3:			/* VCMPE.F64 Dd, #0.0 */
			if(dd >= Ndreg)
				goto unhandled;
			compare(s, dd, dm, 1);
			break;

		default:
			goto unhandled;
		}
		break;

	default:
		goto unhandled;
	}

	if(fpitrace){
		print("emu %.4ux ", hw1); print("%.4ux", hw2);
		print(" d%d", dd); print(" n%d", dn); print(" m%d", dm);
		print(" -> ");
		if(dd < Ndreg){
			print("%.8lux", s[2*dd+1]); print(":%.8lux", s[2*dd]);
		}
		print("\n");
	}
	fpregrestore(s);
	if(fpitrace){
		ulong chk[Nsreg];
		int k;

		fpregsave(chk);
		for(k = 0; k < Nsreg; k++)
			if(chk[k] != s[k]){
				print("RESTORE-LOST S%d wrote ", k);
				print("%.8lux", s[k]);
				print(" read %.8lux\n", chk[k]);
			}
	}
	ur->pc += 4;
	return 1;

unhandled:
	print("fpiemu: no rule for ");
	print("%.4ux ", hw1);
	print("%.4ux", hw2);
	print(" at pc ");
	print("%.8lux\n", (ulong)ur->pc);
	return 0;
}
