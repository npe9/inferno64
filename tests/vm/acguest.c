/*
 * #AC in a guest: a Linux program, run by the M2 guest (check-vm.sh),
 * that sets EFLAGS.AC -- Linux runs with CR0.AM set -- and stores 8
 * bytes to a 4-byte boundary.  The processor raises #AC at CPL 3; the
 * VMX and SVM backends leave the guest's exceptions to it (no #AC in
 * the exception bitmap or the intercepts), so the guest's Linux takes
 * it and sends SIGBUS, and the shell sees status 135.  Living through
 * the store means #AC was lost somewhere: it says so and exits 1.
 *
 * Built freestanding: x86_64-elf-gcc -static -nostdlib -ffreestanding
 * -mgeneral-regs-only.
 */

enum {
	SYS_write = 1, SYS_exit = 60,
};

static long
sys(long n, long a, long b, long c)
{
	long r;

	asm volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c)
		: "rcx", "r11", "memory");
	return r;
}

static void
put(const char *s)
{
	long n = 0;

	while (s[n])
		n++;
	sys(SYS_write, 1, (long)s, n);
}

static unsigned long buf[4];

void
_start(void)
{
	volatile unsigned long *aligned = &buf[1];
	volatile unsigned long *unaligned = (unsigned long *)((char *)&buf[1] + 4);

	asm volatile("pushfq; orq $0x40000, (%%rsp); popfq" ::: "memory", "cc");
	*aligned = 1;
	put("ACGUEST: aligned store with EFLAGS.AC set\n");
	*unaligned = 2;
	put("ACGUEST: FAIL misaligned store with EFLAGS.AC set took no #AC\n");
	sys(SYS_exit, 1, 0, 0);
}
