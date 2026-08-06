	.text

	.globl _umult
_umult:
	pushq %rbp
	movq %rdx, %rbp
	movq %rdi, %rax
	mulq %rsi
	movq %rdx, (%rbp)
	popq %rbp
	ret

	.globl _FPsave
_FPsave:
	fstenv (%rdi)
	ret

	.globl _FPrestore
_FPrestore:
	fldenv (%rdi)
	ret

	.globl __tas
__tas:
	movl $1, %eax
	xchgl %eax, (%rdi)
	ret
