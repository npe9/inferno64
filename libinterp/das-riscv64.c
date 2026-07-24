/*
 * Disassembler for riscv64 JIT output.
 * Covers the instruction forms emitted by comp-riscv64.c.
 */
#include <lib9.h>
#include <kernel.h>

static char *xname[] = {
	"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
	"s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
	"a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
	"s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

static char *fname[] = {
	"fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
	"fs0", "fs1", "fs2", "fs3", "fs4", "fs5", "fs6", "fs7",
	"fs8", "fs9", "fs10", "fs11", "ft0", "ft1", "ft2", "ft3",
	"ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11",
};

static char*
xn(int r)
{
	if(r < 0 || r > 31)
		return "?";
	return xname[r];
}

static char*
fn(int r)
{
	if(r < 0 || r > 31)
		return "?";
	return fname[r];
}

static int
imm12(u32int w)
{
	int i;

	i = (int)(w >> 20);
	return i << 20 >> 20;
}

static int
imm12s(u32int w)
{
	int i;

	i = (((int)(w >> 25) & 0x7f) << 5) | ((w >> 7) & 0x1f);
	return i << 20 >> 20;
}

static long
bimm(u32int w)
{
	long i;

	i = ((w >> 31) & 1) << 12;
	i |= ((w >> 7) & 1) << 11;
	i |= ((w >> 25) & 0x3f) << 5;
	i |= ((w >> 8) & 0xf) << 1;
	if(i & 0x1000)
		i |= ~0x1fffL;
	return i;
}

static long
jimm(u32int w)
{
	long i;

	i = ((w >> 31) & 1) << 20;
	i |= ((w >> 12) & 0xff) << 12;
	i |= ((w >> 20) & 1) << 11;
	i |= ((w >> 21) & 0x3ff) << 1;
	if(i & 0x100000)
		i |= ~0x1fffffL;
	return i;
}

static void
fmtop(char *buf, int n, u32int w)
{
	int opc, rd, rs1, rs2, f3, f7, imm;
	long off;

	opc = w & 0x7f;
	rd = (w >> 7) & 0x1f;
	f3 = (w >> 12) & 7;
	rs1 = (w >> 15) & 0x1f;
	rs2 = (w >> 20) & 0x1f;
	f7 = (w >> 25) & 0x7f;

	if(w == 0x00000013) {
		snprint(buf, n, "nop");
		return;
	}
	if(w == 0x00100073) {
		snprint(buf, n, "ebreak");
		return;
	}
	if(w == 0x00008067) {
		snprint(buf, n, "ret");
		return;
	}

	switch(opc) {
	case 0x37:	/* LUI */
		snprint(buf, n, "lui\t%s, %#ux", xn(rd), (w >> 12) & 0xfffff);
		return;
	case 0x17:	/* AUIPC */
		snprint(buf, n, "auipc\t%s, %#ux", xn(rd), (w >> 12) & 0xfffff);
		return;
	case 0x6f:	/* JAL */
		snprint(buf, n, "jal\t%s, %ld", xn(rd), jimm(w));
		return;
	case 0x67:	/* JALR */
		snprint(buf, n, "jalr\t%s, %d(%s)", xn(rd), imm12(w), xn(rs1));
		return;
	case 0x63:	/* BRANCH */
		off = bimm(w);
		switch(f3) {
		case 0: snprint(buf, n, "beq\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		case 1: snprint(buf, n, "bne\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		case 4: snprint(buf, n, "blt\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		case 5: snprint(buf, n, "bge\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		case 6: snprint(buf, n, "bltu\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		case 7: snprint(buf, n, "bgeu\t%s, %s, %ld", xn(rs1), xn(rs2), off); return;
		}
		break;
	case 0x03:	/* LOAD */
		imm = imm12(w);
		switch(f3) {
		case 0: snprint(buf, n, "lb\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 1: snprint(buf, n, "lh\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 2: snprint(buf, n, "lw\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 3: snprint(buf, n, "ld\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 4: snprint(buf, n, "lbu\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 5: snprint(buf, n, "lhu\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		case 6: snprint(buf, n, "lwu\t%s, %d(%s)", xn(rd), imm, xn(rs1)); return;
		}
		break;
	case 0x23:	/* STORE */
		imm = imm12s(w);
		switch(f3) {
		case 0: snprint(buf, n, "sb\t%s, %d(%s)", xn(rs2), imm, xn(rs1)); return;
		case 1: snprint(buf, n, "sh\t%s, %d(%s)", xn(rs2), imm, xn(rs1)); return;
		case 2: snprint(buf, n, "sw\t%s, %d(%s)", xn(rs2), imm, xn(rs1)); return;
		case 3: snprint(buf, n, "sd\t%s, %d(%s)", xn(rs2), imm, xn(rs1)); return;
		}
		break;
	case 0x13:	/* OP-IMM */
		imm = imm12(w);
		switch(f3) {
		case 0: snprint(buf, n, "addi\t%s, %s, %d", xn(rd), xn(rs1), imm); return;
		case 1: snprint(buf, n, "slli\t%s, %s, %d", xn(rd), xn(rs1), rs2); return;
		case 4: snprint(buf, n, "xori\t%s, %s, %d", xn(rd), xn(rs1), imm); return;
		case 5:
			if(f7 & 0x20)
				snprint(buf, n, "srai\t%s, %s, %d", xn(rd), xn(rs1), rs2);
			else
				snprint(buf, n, "srli\t%s, %s, %d", xn(rd), xn(rs1), rs2);
			return;
		case 6: snprint(buf, n, "ori\t%s, %s, %d", xn(rd), xn(rs1), imm); return;
		case 7: snprint(buf, n, "andi\t%s, %s, %d", xn(rd), xn(rs1), imm); return;
		}
		break;
	case 0x1B:	/* OP-IMM-32 */
		imm = imm12(w);
		if(f3 == 0) {
			snprint(buf, n, "addiw\t%s, %s, %d", xn(rd), xn(rs1), imm);
			return;
		}
		break;
	case 0x33:	/* OP */
		if(f7 == 0x01) {
			switch(f3) {
			case 0: snprint(buf, n, "mul\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
			case 4: snprint(buf, n, "div\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
			case 6: snprint(buf, n, "rem\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
			}
		}
		switch(f3) {
		case 0:
			snprint(buf, n, "%s\t%s, %s, %s",
				f7 == 0x20 ? "sub" : "add", xn(rd), xn(rs1), xn(rs2));
			return;
		case 1: snprint(buf, n, "sll\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		case 2: snprint(buf, n, "slt\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		case 3: snprint(buf, n, "sltu\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		case 4: snprint(buf, n, "xor\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		case 5:
			snprint(buf, n, "%s\t%s, %s, %s",
				f7 == 0x20 ? "sra" : "srl", xn(rd), xn(rs1), xn(rs2));
			return;
		case 6: snprint(buf, n, "or\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		case 7: snprint(buf, n, "and\t%s, %s, %s", xn(rd), xn(rs1), xn(rs2)); return;
		}
		break;
	case 0x07:	/* LOAD-FP */
		if(f3 == 3) {
			snprint(buf, n, "fld\t%s, %d(%s)", fn(rd), imm12(w), xn(rs1));
			return;
		}
		break;
	case 0x27:	/* STORE-FP */
		if(f3 == 3) {
			snprint(buf, n, "fsd\t%s, %d(%s)", fn(rs2), imm12s(w), xn(rs1));
			return;
		}
		break;
	case 0x53:	/* OP-FP */
		switch(f7) {
		case 0x01: snprint(buf, n, "fadd.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2)); return;
		case 0x05: snprint(buf, n, "fsub.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2)); return;
		case 0x09: snprint(buf, n, "fmul.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2)); return;
		case 0x0D: snprint(buf, n, "fdiv.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2)); return;
		case 0x11:
			if(f3 == 1)
				snprint(buf, n, "fsgnjn.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2));
			else
				snprint(buf, n, "fsgnj.d\t%s, %s, %s", fn(rd), fn(rs1), fn(rs2));
			return;
		case 0x51:
			if(f3 == 2)
				snprint(buf, n, "feq.d\t%s, %s, %s", xn(rd), fn(rs1), fn(rs2));
			else if(f3 == 1)
				snprint(buf, n, "flt.d\t%s, %s, %s", xn(rd), fn(rs1), fn(rs2));
			else
				snprint(buf, n, "fle.d\t%s, %s, %s", xn(rd), fn(rs1), fn(rs2));
			return;
		case 0x61:
			snprint(buf, n, "fcvt.l.d\t%s, %s", xn(rd), fn(rs1));
			return;
		case 0x69:
			snprint(buf, n, "fcvt.d.l\t%s, %s", fn(rd), xn(rs1));
			return;
		case 0x71:
			snprint(buf, n, "fmv.x.d\t%s, %s", xn(rd), fn(rs1));
			return;
		case 0x79:
			snprint(buf, n, "fmv.d.x\t%s, %s", fn(rd), xn(rs1));
			return;
		}
		break;
	}
	snprint(buf, n, ".word\t%#.8ux", w);
}

void
das(u32int *x, int n)
{
	char buf[128];
	int i;

	for(i = 0; i < n; i++) {
		fmtop(buf, sizeof buf, x[i]);
		print("\t%.8p %.8ux %s\n", &x[i], x[i], buf);
	}
}
