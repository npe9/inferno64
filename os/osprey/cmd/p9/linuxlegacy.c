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
sys6(long n, long a, long b, long c, long d, long e, long f)
{
	long r;
	register long r10 __asm__("r10") = d;
	register long r8 __asm__("r8") = e;
	register long r9 __asm__("r9") = f;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c),
		"r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
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

/* append a string, no libc */
static char*
cat(char *p, const char *s)
{
	while(*s)
		*p++ = *s++;
	*p = 0;
	return p;
}

/* append a hex number */
static char*
hex(char *p, unsigned long v)
{
	static const char hx[] = "0123456789abcdef";
	int sh, started = 0;
	*p++ = '0'; *p++ = 'x';
	for(sh = 60; sh >= 0; sh -= 4){
		int d = (v >> sh) & 15;
		if(d || started || sh == 0){ *p++ = hx[d]; started = 1; }
	}
	*p = 0;
	return p;
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
 * The SIGSEGV handler and its restorer, as a libc supplies them: the
 * handler maps the page the fault named, so the retried store goes
 * through; the restorer is what the handler returns into, and it asks
 * the kernel to put the interrupted frame back (rt_sigreturn, 15).
 */
static volatile int segvs;

static void
onsegv(int sig, void *info, void *uc)
{
	unsigned long addr = *(unsigned long*)((char*)info + 16);	/* si_addr */
	char l[96], *q;

	(void)uc;
	segvs++;
	sys6(9, addr & ~4095UL, 4096, 3, 0x32, -1, 0);	/* mmap(page, rw, PRIVATE|ANON|FIXED) */
	q = cat(l, "linux: SIGSEGV ");
	q = num(q, sig);
	q = cat(q, " at ");
	q = hex(q, addr);
	q = cat(q, " delivered; the handler mapped the page\n");
	sys3(1, 2, (long)l, slen(l));
}

__asm__(".globl restore_rt\nrestore_rt:\n\tmovl $15,%eax\n\tsyscall\n\thlt\n");
extern void restore_rt(void);

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
	p = cat(line, "linux: read(fd, buf, 512) returned ");
	p = num(p, n); p = cat(p, " bytes, served by the buddy\n"); *p = 0;
	say(line);

	r = sys3(3, fd, 0, 0);			/* close(fd) */
	p = cat(line, "linux: close returned ");
	p = num(p, r); *p++ = '\n'; *p = 0;
	say(line);

	{
		/* the heap: brk, then memory that must be zero and must hold a write */
		long b0, b1, i, sum;
		volatile char *h;
		b0 = sys3(12, 0, 0, 0);			/* brk(0) */
		b1 = sys3(12, b0 + 65536, 0, 0);	/* brk(b0 + 64K) */
		p = cat(line, "linux: brk grew the heap by ");
		p = num(p, b1 - b0);
		p = cat(p, " bytes");
		if(b1 == b0 + 65536){
			h = (volatile char*)b0;
			sum = 0;
			for(i = 0; i < 65536; i += 4096)
				sum += h[i];			/* fresh pages read as zero */
			for(i = 0; i < 65536; i += 4096)
				h[i] = (char)(i >> 12) + 1;
			for(i = 0; i < 65536; i += 4096)
				sum += h[i] != (char)((i >> 12) + 1);
			p = cat(p, sum == 0 ? ", zero-filled and holding what was written" : ", WRONG contents");
		}
		p = cat(p, "\n");
		say(line);
	}
	{
		/* an anonymous mapping: mmap(0, 2 pages, rw, private|anon, -1, 0), use it, munmap it */
		long m, u;
		volatile char *q;
		m = sys6(9, 0, 8192, 3, 0x22, -1, 0);
		p = cat(line, "linux: mmap gave an anonymous mapping at ");
		if(m > 0){
			q = (volatile char*)m;
			q[0] = 7; q[8191] = 9;
			p = hex(p, m);
			p = cat(p, (q[0] == 7 && q[8191] == 9) ? "" : " WRONG");
			u = sys3(11, m, 8192, 0);	/* after the last touch: it is gone */
			p = cat(p, ", written at both ends, munmap returned ");
			p = num(p, u);
		} else {
			p = cat(p, "error ");
			p = num(p, m);
		}
		p = cat(p, "\n");
		say(line);
	}

	{
		/* stdin is the buddy's console: end of file; stdout goes to the console */
		long n0;
		n0 = sys3(0, 0, (long)buf, 16);
		p = cat(line, "linux: read(0) on stdin returned ");
		p = num(p, n0);
		p = cat(p, " (end of file at the buddy's console)\n");
		sys3(1, 1, (long)line, slen(line));		/* write(1): stdout */
	}
	{
		/* a file mapping: the buddy reads the pages from the file */
		long ffd, m;
		volatile unsigned char *q;
		ffd = sys3(2, (long)"/boot/linux", 0, 0);
		m = sys6(9, 0, 4096, 1, 2, ffd, 0);		/* mmap(0, 4K, PROT_READ, MAP_PRIVATE, fd, 0) */
		p = cat(line, "linux: file mapping of /boot/linux at ");
		if(m > 0){
			q = (volatile unsigned char*)m;
			p = hex(p, m);
			p = cat(p, (q[0] == 0x7f && q[1] == 'E' && q[2] == 'L' && q[3] == 'F') ? ", first bytes are its ELF magic" : ", WRONG bytes");
			sys3(11, m, 4096, 0);
		} else {
			p = cat(p, "error ");
			p = num(p, m);
		}
		p = cat(p, "\n");
		say(line);
		sys3(3, ffd, 0, 0);
	}
	{
		/* a fault the buddy declines: SIGSEGV to a handler that mends it, then the store goes through */
		struct { void (*handler)(int, void*, void*); unsigned long flags; void (*restorer)(void); unsigned long mask; } sa;
		volatile int *bad = (volatile int*)0x20000000000L;
		sa.handler = onsegv;
		sa.flags = 0x04000000 | 4;			/* SA_RESTORER | SA_SIGINFO */
		sa.restorer = restore_rt;
		sa.mask = 0;
		sys6(13, 11, (long)&sa, 0, 8, 0, 0);		/* rt_sigaction(SIGSEGV, &sa, 0, 8) */
		*bad = 42;					/* faults: the handler maps the page */
		p = cat(line, "linux: the faulting store went through after the handler returned: ");
		p = num(p, *bad);
		p = cat(p, segvs == 1 ? ", one SIGSEGV\n" : ", WRONG count\n");
		say(line);
	}

	__asm__ volatile("" : "+r"(keep));
	if(keep == 0x5a5a1234)
		say("linux: rbx preserved across every syscall; the buddy answered every trap\n");
	else
		say("linux: rbx CLOBBERED across syscall\n");
	sys3(60, 0, 0, 0);			/* exit(0) */
	for(;;);
}
