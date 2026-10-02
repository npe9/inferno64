/*
 * THESE FIELDS ARE 32 BITS WIDE ON DISK, and they were spelled "long".
 *
 * On a host whose long is 64 bits -- every 64-bit Unix, including the one
 * this is built on -- that made sizeof(Exec) 64 against an on-disk header
 * of 32, so libmach read every field one slot out: crackhdr reported
 * hdrsz 72 instead of 40, txtsz got the data size, datsz got the symbol
 * table size, and symsz got 0.  syminit then returned "no symbols" and
 * every tool built on libmach -- inm, acid, idb -- printed nothing and
 * exited 0 for EVERY Plan 9 executable, on every architecture.  Not just
 * arm64; arm64 is only where it was noticed, because nothing else here
 * had ever been asked to name an address in one.
 *
 * The union in libmach/executable.c already says so: its 64-bit view
 * declares "u32 ohdr[8]" for exactly these eight fields, so the layout
 * was understood and only this declaration disagreed.
 *
 * See the "Plan 9 long is 32 bits" hazard this tree records elsewhere.
 */
typedef	struct	Exec	Exec;
struct	Exec
{
	u32	magic;		/* magic number */
	u32	text;	 	/* size of text segment */
	u32	data;	 	/* size of initialized data */
	u32	bss;	  	/* size of uninitialized data */
	u32	syms;	 	/* size of symbol table */
	u32	entry;	 	/* entry point */
	u32	spsz;		/* size of pc/sp offset table */
	u32	pcsz;		/* size of pc/line number table */
};

#define HDR_MAGIC	0x00008000		/* header expansion */

#define	_MAGIC(f, b)	((f)|((((4*(b))+0)*(b))+7))
#define	A_MAGIC		_MAGIC(0, 8)		/* 68020 */
#define	I_MAGIC		_MAGIC(0, 11)		/* intel 386 */
#define	J_MAGIC		_MAGIC(0, 12)		/* intel 960 (retired) */
#define	K_MAGIC		_MAGIC(0, 13)		/* sparc */
#define	V_MAGIC		_MAGIC(0, 16)		/* mips 3000 BE */
#define	X_MAGIC		_MAGIC(0, 17)		/* att dsp 3210 (retired) */
#define	M_MAGIC		_MAGIC(0, 18)		/* mips 4000 BE */
#define	D_MAGIC		_MAGIC(0, 19)		/* amd 29000 (retired) */
#define	E_MAGIC		_MAGIC(0, 20)		/* arm */
#define	Q_MAGIC		_MAGIC(0, 21)		/* powerpc */
#define	N_MAGIC		_MAGIC(0, 22)		/* mips 4000 LE */
#define	L_MAGIC		_MAGIC(0, 23)		/* dec alpha (retired) */
#define	P_MAGIC		_MAGIC(0, 24)		/* mips 3000 LE */
#define	U_MAGIC		_MAGIC(0, 25)		/* sparc64 (retired) */
#define	S_MAGIC		_MAGIC(HDR_MAGIC, 26)	/* amd64 */
#define	T_MAGIC		_MAGIC(HDR_MAGIC, 27)	/* powerpc64 */
#define	R_MAGIC		_MAGIC(HDR_MAGIC, 28)	/* arm64 */
#define	Z_MAGIC		_MAGIC(0, 29)		/* riscv */
#define	Y_MAGIC		_MAGIC(0, 30)		/* riscv64 */

#define	MIN_MAGIC	8
#define	MAX_MAGIC	30			/* <= 90 */

#define	DYN_MAGIC	0x80000000		/* dlm */

typedef	struct	Sym	Sym;
struct	Sym
{
	vlong	value;
	uint	sig;
	char	type;
	char	*name;
};
