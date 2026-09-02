/* An unmodified Linux x86-64 program: raw syscalls, no libc.  It opens a
 * file and reads it (Linux sys_open=2, sys_read=0), writes what it got
 * (sys_write=1), and exits (sys_exit=60) - the Linux system-call ABI,
 * number in rax, args in rdi/rsi/rdx, rcx and r11 clobbered, every
 * other register preserved.  It knows nothing of Osprey. */
static long
sys3(long n, long a, long b, long c)
{
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c)
		: "rcx", "r11", "memory");
	return r;
}

static long
slen(const char *s)
{
	long n = 0;
	while(s[n]) n++;
	return n;
}

static void
say(const char *s)
{
	sys3(1, 2, (long)s, slen(s));		/* write(2, s) */
}

/* append a decimal, no libc */
static char*
num(char *p, long v)
{
	char t[24];
	int i = 0;
	if(v < 0){ *p++ = '-'; v = -v; }
	do { t[i++] = '0' + v%10; v /= 10; } while(v);
	while(i) *p++ = t[--i];
	return p;
}

/*
 * The process entry, as a real Linux nolibc program writes it: the
 * kernel enters _start with rsp 16-byte aligned and argc at rsp, which
 * is not a C function's frame (a C function expects rsp == 8 mod 16, as
 * left by a call), so a C _start faults on its first aligned SSE store,
 * on Linux as much as here.  Align and call the C body.
 */
__asm__(".globl _start\n_start:\n\txorl %ebp,%ebp\n\tmovq %rsp,%rdi\n\tandq $-16,%rsp\n\tcall lmain\n\thlt\n");

void
lmain(void)
{
	static char buf[512];
	char line[128], *p;
	long fd, n, r;
	/* a callee-saved register the ABI must return intact across syscall */
	register long keep __asm__("rbx") = 0x5a5a1234;

	say("linux: an unmodified Linux binary; its file syscalls served by a buddy\n");
	fd = sys3(2, (long)"/", 0, 0);		/* open("/", O_RDONLY) */
	p = line; p = (char*)__builtin_memcpy(p, "linux: open(\"/\") returned fd ", 29) + 29;
	p = num(p, fd); *p++ = '\n'; *p = 0;
	say(line);

	n = sys3(0, fd, (long)buf, sizeof buf);	/* read(fd, buf, 512) */
	p = line; p = (char*)__builtin_memcpy(p, "linux: read(fd, buf, 512) returned ", 35) + 35;
	p = num(p, n); p = (char*)__builtin_memcpy(p, " bytes, served by the buddy\n", 28) + 28; *p = 0;
	say(line);

	r = sys3(3, fd, 0, 0);			/* close(fd) */
	p = line; p = (char*)__builtin_memcpy(p, "linux: close returned ", 22) + 22;
	p = num(p, r); *p++ = '\n'; *p = 0;
	say(line);

	__asm__ volatile("" : "+r"(keep));
	if(keep == 0x5a5a1234)
		say("linux: rbx preserved across every syscall; the buddy answered every trap\n");
	else
		say("linux: rbx CLOBBERED across syscall\n");
	sys3(60, 0, 0, 0);			/* exit(0) */
	for(;;);
}
