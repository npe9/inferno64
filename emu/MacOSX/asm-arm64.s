/*
 * MacOSX arm64 assembly helpers for emu
 */

	.text
	.align	2

/*
 * void FPsave(void *p)
 * Save FPSR and FPCR into FPU.env[16] (see MacOSX/arm64/include/emu.h).
 */
	.globl	_FPsave
_FPsave:
	mrs	x1, fpsr
	mrs	x2, fpcr
	str	x1, [x0]
	str	x2, [x0, #8]
	ret

/*
 * void FPrestore(void *p)
 */
	.globl	_FPrestore
_FPrestore:
	ldr	x1, [x0]
	ldr	x2, [x0, #8]
	msr	fpsr, x1
	msr	fpcr, x2
	ret

	.globl	__tas
__tas:
	mov	w1, #1
1:
	ldaxr	w2, [x0]
	cbnz	w2, 2f
	stlxr	w3, w1, [x0]
	cbnz	w3, 1b
2:
	mov	w0, w2
	ret
