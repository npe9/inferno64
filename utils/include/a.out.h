typedef	struct	Exec	Exec;
/*
 * Every field here is a 32-bit big-endian word in the file: the
 * loaders write them with lput(), four bytes at a time.  They were
 * declared `long', which is 32 bits in a Plan 9 kernel and 64 on the
 * hosts these tools are built on, so on a 64-bit host the struct was
 * twice the width of the record it describes and every field after
 * `magic' read the wrong four bytes.  That is what made libmach report
 * symsz == 0 for every amd64 kernel -- it was reading the top half of
 * the 64-bit entry record where `syms' should be -- so inm printed
 * nothing and acid said "no symbol information".  See AGENTS.md on
 * `long' is 32 bits.
 */
struct	Exec
{
	int	magic;		/* magic number */
	int	text;	 	/* size of text segment */
	int	data;	 	/* size of initialized data */
	int	bss;	  	/* size of uninitialized data */
	int	syms;	 	/* size of symbol table */
	int	entry;	 	/* entry point */
	int	spsz;		/* size of pc/sp offset table */
	int	pcsz;		/* size of pc/line number table */
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
