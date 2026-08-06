	.text

	.globl _setfcr
_setfcr:
	subq $32, %rsp
	xorb $0x3f, %al
	movq %rax, (%rsp)
	fwait
	fldcw (%rsp)
	addq $32, %rsp
	ret

	.globl _getfcr
_getfcr:
	subq $32, %rsp
	fwait
	fstcw (%rsp)
	movw (%rsp), %ax
	andq $0xffffff, %rax
	xorb $0x3f, %al
	addq $32, %rsp
	ret

	.globl _getfsr
_getfsr:
	subq $32, %rsp
	fwait
	fstsw (%rsp)
	movw (%rsp), %ax
	andq $0xffffff, %rax
	addq $32, %rsp
	ret

	.globl _setfsr
_setfsr:
	fclex
	ret
