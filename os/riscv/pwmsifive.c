/*
 * SiFive PWM0 (sifive,pwm0) — FU540 / QEMU sifive_u.
 * Programmable compare; optional IRQ via board Uart-style plicenable.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

#ifndef PWM0
#define PWM0	0
#endif

typedef struct Pwm Pwm;
struct Pwm {
	u32	*regs;
	int	irq0;
};

static Pwm pwm0;

void
pwminit(void)
{
	if(PWM0 == 0)
		return;
	pwm0.regs = (u32*)(uintptr)PWM0;
	pwm0.irq0 = Pwm0IRQ;
	/* ~1kHz-ish scale for LED/demo; QEMU clock differs from silicon. */
	pwm0.regs[SpwCfg/4] = 0;
	pwm0.regs[SpwCmp0/4] = 0x8000;
	pwm0.regs[(SpwCmp0+4)/4] = 0;
	pwm0.regs[(SpwCmp0+8)/4] = 0;
	pwm0.regs[(SpwCmp0+12)/4] = 0;
	pwm0.regs[SpwCfg/4] = SpwEnalways | SpwZeroCmp | (8<<0);	/* scale */
}

void
pwmset(int cmp, u32 duty)
{
	if(pwm0.regs == nil || cmp < 0 || cmp > 3)
		return;
	pwm0.regs[(SpwCmp0 + 4*cmp)/4] = duty;
}

u32
pwmcount(void)
{
	if(pwm0.regs == nil)
		return 0;
	return pwm0.regs[SpwCount/4];
}
