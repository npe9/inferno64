/*
 * Disassembler for arm64 JIT output.
 * Covers the instruction forms emitted by comp-arm64.c.
 */
#include <lib9.h>
#include <kernel.h>

static char *regname[] = {
	"x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
	"x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
	"x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
	"x24", "x25", "x26", "x27", "x28", "x29", "x30", "xzr",
};

static char *condname[] = {
	"eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc",
	"hi", "ls", "ge", "lt", "gt", "le", "al", "nv",
};

static char*
rn(int r)
{
	if(r < 0 || r > 31)
		return "?";
	return regname[r];
}

static void
fmtop(char *buf, int n, u32int w, uintptr addr)
{
	u32int op;
	int rd, rn_, rm, rt, rt2, imm, sh, cond;
	long off;

	rd = w & 0x1f;
	rn_ = (w >> 5) & 0x1f;
	rm = (w >> 16) & 0x1f;
	rt = rd;
	USED(addr);

	/* BRK */
	if((w & 0xFFE0001F) == 0xD4200000) {
		snprint(buf, n, "brk\t#%d", (w >> 5) & 0xFFFF);
		return;
	}
	/* NOP */
	if(w == 0xD503201F) {
		snprint(buf, n, "nop");
		return;
	}
	/* RET */
	if(w == 0xD65F03C0) {
		snprint(buf, n, "ret");
		return;
	}
	/* BR Xn */
	if((w & 0xFFFFFC1F) == 0xD61F0000) {
		snprint(buf, n, "br\t%s", rn(rn_));
		return;
	}
	/* BLR Xn */
	if((w & 0xFFFFFC1F) == 0xD63F0000) {
		snprint(buf, n, "blr\t%s", rn(rn_));
		return;
	}
	/* B imm26 */
	if((w & 0xFC000000) == 0x14000000) {
		off = (long)(w & 0x3FFFFFF);
		if(off & 0x2000000)
			off |= ~0x3FFFFFFL;
		snprint(buf, n, "b\t%ld", off);
		return;
	}
	/* BL imm26 */
	if((w & 0xFC000000) == 0x94000000) {
		off = (long)(w & 0x3FFFFFF);
		if(off & 0x2000000)
			off |= ~0x3FFFFFFL;
		snprint(buf, n, "bl\t%ld", off);
		return;
	}
	/* B.cond */
	if((w & 0xFF000010) == 0x54000000) {
		off = (long)((w >> 5) & 0x7FFFF);
		if(off & 0x40000)
			off |= ~0x7FFFFL;
		cond = w & 0xf;
		snprint(buf, n, "b.%s\t%ld", condname[cond], off);
		return;
	}
	/* CBZ / CBNZ (64-bit) */
	if((w & 0xFE000000) == 0xB4000000) {
		off = (long)((w >> 5) & 0x7FFFF);
		if(off & 0x40000)
			off |= ~0x7FFFFL;
		snprint(buf, n, "%s\t%s, %ld",
			(w & (1<<24)) ? "cbnz" : "cbz", rn(rt), off);
		return;
	}

	/* MOVZ / MOVK */
	if((w & 0xFF800000) == 0xD2800000 || (w & 0xFF800000) == 0xF2800000) {
		imm = (w >> 5) & 0xFFFF;
		sh = ((w >> 21) & 3) * 16;
		snprint(buf, n, "%s\t%s, #0x%x%s%d",
			((w >> 23) & 1) ? "movk" : "movz",
			rn(rd), imm, sh ? ", lsl #" : "", sh);
		return;
	}

	/* ADD/SUB/ADDS/SUBS immediate (64-bit) */
	op = (w >> 23) & 0x1FF;
	if((w & 0x1F000000) == 0x11000000 || (w & 0x1F000000) == 0x51000000) {
		imm = (w >> 10) & 0xFFF;
		sh = (w >> 22) & 3;
		if(sh == 1)
			imm <<= 12;
		if((w & 0xFF000000) == 0x91000000)
			snprint(buf, n, "add\t%s, %s, #%d", rn(rd), rn(rn_), imm);
		else if((w & 0xFF000000) == 0xD1000000)
			snprint(buf, n, "sub\t%s, %s, #%d", rn(rd), rn(rn_), imm);
		else if((w & 0xFF000000) == 0xB1000000)
			snprint(buf, n, "adds\t%s, %s, #%d", rn(rd), rn(rn_), imm);
		else if((w & 0xFF000000) == 0xF1000000) {
			if(rd == 31)
				snprint(buf, n, "cmp\t%s, #%d", rn(rn_), imm);
			else
				snprint(buf, n, "subs\t%s, %s, #%d", rn(rd), rn(rn_), imm);
		} else
			goto unknown;
		return;
	}

	/* ADD/SUB register (64-bit) */
	if((w & 0xFF200000) == 0x8B000000) {
		snprint(buf, n, "add\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		return;
	}
	if((w & 0xFF200000) == 0xCB000000) {
		if(rn_ == 31)
			snprint(buf, n, "neg\t%s, %s", rn(rd), rn(rm));
		else if(rd == 31)
			snprint(buf, n, "cmp\t%s, %s", rn(rn_), rn(rm));
		else
			snprint(buf, n, "sub\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		return;
	}
	/* SUBS register */
	if((w & 0xFF200000) == 0xEB000000) {
		if(rd == 31)
			snprint(buf, n, "cmp\t%s, %s", rn(rn_), rn(rm));
		else
			snprint(buf, n, "subs\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		return;
	}

	/* Logical ORR (MOV alias: ORR Xd, XZR, Xm) */
	if((w & 0xFF200000) == 0xAA000000) {
		if(rn_ == 31)
			snprint(buf, n, "mov\t%s, %s", rn(rd), rn(rm));
		else
			snprint(buf, n, "orr\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		return;
	}

	/* MADD / MUL (Ra=XZR) */
	if((w & 0xFF000000) == 0x9B000000) {
		rt2 = (w >> 10) & 0x1f;
		if(rt2 == 31)
			snprint(buf, n, "mul\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		else
			snprint(buf, n, "madd\t%s, %s, %s, %s", rn(rd), rn(rn_), rn(rm), rn(rt2));
		return;
	}

	/* SDIV */
	if((w & 0xFFE0FC00) == 0x9AC00C00) {
		snprint(buf, n, "sdiv\t%s, %s, %s", rn(rd), rn(rn_), rn(rm));
		return;
	}

	/* SXTW */
	if((w & 0xFFFFFC00) == 0x93407C00) {
		snprint(buf, n, "sxtw\t%s, w%d", rn(rd), rn_);
		return;
	}

	/* LDR/STR unsigned offset 64-bit */
	if((w & 0xFFC00000) == 0xF9400000) {
		imm = ((w >> 10) & 0xFFF) * 8;
		snprint(buf, n, "ldr\t%s, [%s, #%d]", rn(rt), rn(rn_), imm);
		return;
	}
	if((w & 0xFFC00000) == 0xF9000000) {
		imm = ((w >> 10) & 0xFFF) * 8;
		snprint(buf, n, "str\t%s, [%s, #%d]", rn(rt), rn(rn_), imm);
		return;
	}
	/* LDR/STR 32-bit */
	if((w & 0xFFC00000) == 0xB9400000) {
		imm = ((w >> 10) & 0xFFF) * 4;
		snprint(buf, n, "ldr\tw%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}
	if((w & 0xFFC00000) == 0xB9000000) {
		imm = ((w >> 10) & 0xFFF) * 4;
		snprint(buf, n, "str\tw%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}
	/* LDRSW */
	if((w & 0xFFC00000) == 0xB9800000) {
		imm = ((w >> 10) & 0xFFF) * 4;
		snprint(buf, n, "ldrsw\t%s, [%s, #%d]", rn(rt), rn(rn_), imm);
		return;
	}
	/* LDRB/STRB unsigned */
	if((w & 0xFFC00000) == 0x39400000) {
		imm = (w >> 10) & 0xFFF;
		snprint(buf, n, "ldrb\tw%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}
	if((w & 0xFFC00000) == 0x39000000) {
		imm = (w >> 10) & 0xFFF;
		snprint(buf, n, "strb\tw%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}
	/* LDRB register */
	if((w & 0xFFE0FC00) == 0x38606800) {
		snprint(buf, n, "ldrb\tw%d, [%s, %s]", rt, rn(rn_), rn(rm));
		return;
	}
	/* LDR 32-bit register LSL#2 */
	if((w & 0xFFE0FC00) == 0xB8607800) {
		snprint(buf, n, "ldr\tw%d, [%s, %s, lsl #2]", rt, rn(rn_), rn(rm));
		return;
	}

	/* LDUR/STUR 64 */
	if((w & 0xFFE00C00) == 0xF8400000) {
		imm = (w >> 12) & 0x1FF;
		if(imm & 0x100)
			imm |= ~0x1FF;
		snprint(buf, n, "ldur\t%s, [%s, #%d]", rn(rt), rn(rn_), imm);
		return;
	}
	if((w & 0xFFE00C00) == 0xF8000000) {
		imm = (w >> 12) & 0x1FF;
		if(imm & 0x100)
			imm |= ~0x1FF;
		snprint(buf, n, "stur\t%s, [%s, #%d]", rn(rt), rn(rn_), imm);
		return;
	}

	/* LDP/STP */
	if((w & 0xFFC00000) == 0xA9400000 || (w & 0xFFC00000) == 0xA9000000) {
		rt2 = (w >> 10) & 0x1f;
		imm = (int)((w >> 15) & 0x7F);
		if(imm & 0x40)
			imm |= ~0x7F;
		imm *= 8;
		snprint(buf, n, "%s\t%s, %s, [%s, #%d]",
			((w >> 22) & 1) ? "ldp" : "stp",
			rn(rt), rn(rt2), rn(rn_), imm);
		return;
	}

	/* FP: FADD/FSUB/FMUL/FDIV/FNEG/FCMP */
	if((w & 0xFFE0FC00) == 0x1E602800) {
		snprint(buf, n, "fadd\td%d, d%d, d%d", rd, rn_, rm);
		return;
	}
	if((w & 0xFFE0FC00) == 0x1E603800) {
		snprint(buf, n, "fsub\td%d, d%d, d%d", rd, rn_, rm);
		return;
	}
	if((w & 0xFFE0FC00) == 0x1E600800) {
		snprint(buf, n, "fmul\td%d, d%d, d%d", rd, rn_, rm);
		return;
	}
	if((w & 0xFFE0FC00) == 0x1E601800) {
		snprint(buf, n, "fdiv\td%d, d%d, d%d", rd, rn_, rm);
		return;
	}
	if((w & 0xFFFFFC00) == 0x1E614000) {
		snprint(buf, n, "fneg\td%d, d%d", rd, rn_);
		return;
	}
	if((w & 0xFFE0FC1F) == 0x1E602000) {
		snprint(buf, n, "fcmp\td%d, d%d", rn_, rm);
		return;
	}
	if((w & 0xFFFFFC1F) == 0x1E602008) {
		snprint(buf, n, "fcmp\td%d, #0.0", rn_);
		return;
	}
	if((w & 0xFFFFFC00) == 0x9E620000) {
		snprint(buf, n, "scvtf\td%d, %s", rd, rn(rn_));
		return;
	}
	if((w & 0xFFFFFC00) == 0x9E780000) {
		snprint(buf, n, "fcvtzs\t%s, d%d", rn(rd), rn_);
		return;
	}
	/* FLDR/FSTR double */
	if((w & 0xFFC00000) == 0xFD400000) {
		imm = ((w >> 10) & 0xFFF) * 8;
		snprint(buf, n, "ldr\td%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}
	if((w & 0xFFC00000) == 0xFD000000) {
		imm = ((w >> 10) & 0xFFF) * 8;
		snprint(buf, n, "str\td%d, [%s, #%d]", rt, rn(rn_), imm);
		return;
	}

unknown:
	USED(op);
	snprint(buf, n, ".word\t0x%.8ux", w);
}

void
das(u32int *x, int n)
{
	int i;
	char buf[128];

	for(i = 0; i < n; i++) {
		fmtop(buf, sizeof buf, x[i], (uintptr)&x[i]);
		print("  %.8p  %.8ux  %s\n", &x[i], x[i], buf);
	}
}
