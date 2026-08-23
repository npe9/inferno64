/*
 * The floating-point control and status word, which on RISC-V is the
 * fcsr control register: bits 7..5 the rounding mode, bits 4..0 the
 * accrued exception flags.  An assembly function because the compiler
 * has no word for reading a control register, as with the atomics
 * beside this file.
 *
 * There are no trap enables to set here: RISC-V raises no floating
 * point exceptions, it only accumulates flags.  setfcr therefore keeps
 * the rounding mode and drops the rest, which is what the hardware can
 * honour.
 */

#define RARG	R8
#define FCSR	0x003

TEXT	getfcr(SB), 1, $-4		/* ulong getfcr(void) */
	MOV	CSR(FCSR), RARG
	AND	$0xe0, RARG		/* the rounding mode */
	RET

TEXT	setfcr(SB), 1, $-4		/* void setfcr(ulong) */
	AND	$0xe0, RARG
	MOV	RARG, CSR(FCSR)
	RET

TEXT	getfsr(SB), 1, $-4		/* ulong getfsr(void) */
	MOV	CSR(FCSR), RARG
	AND	$0x1f, RARG		/* the accrued flags */
	RET

TEXT	setfsr(SB), 1, $-4		/* void setfsr(ulong) */
	AND	$0x1f, RARG
	MOV	RARG, CSR(FCSR)
	RET
