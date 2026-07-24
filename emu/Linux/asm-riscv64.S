	.file	"asm-Linux-riscv64.S"
	.text

/*
 * umult(ulong m1, ulong m2, ulong *hi)
 */
	.align	2
	.type	umult,@function
	.global	umult
umult:
	/* a0=m1, a1=m2, a2=hi — 32-bit style product in a0, high in *hi */
	mul	t0, a0, a1
	mulhu	t1, a0, a1
	sw	t1, 0(a2)
	mv	a0, t0
	ret

	.align	2
	.type	FPsave,@function
	.global	FPsave
FPsave:
	ret

	.align	2
	.type	FPrestore,@function
	.global	FPrestore
FPrestore:
	ret

	.align	2
	.type	_tas,@function
	.globl	_tas
_tas:
	mv	t0, a0
	li	t1, 1
1:
	lr.w	a0, (t0)
	sc.w	t2, t1, (t0)
	bnez	t2, 1b
	ret
