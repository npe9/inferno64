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

/* the same in octal, for a mode */
static char *
onum(char *p, long v)
{
	char t[24];
	int i = 0;
	if(v < 0){ *p++ = '-'; v = -v; }
	do { t[i++] = '0' + (v & 7); v >>= 3; } while(v);
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
/*
 * Does a system call give back every register the Linux ABI says it
 * will?  rbx alone is checked below, across every call this program
 * makes; this checks twelve, across a hundred calls of one kind.
 *
 * It is worth having on this kernel in particular.  syscallentry and
 * forkret in os/osprey/pc64/l.s are not 9front's - they were written to
 * carry the Plan 9 and the Linux ABI at once, so they store every
 * register into the Ureg and restore every one, and the Linux branch of
 * syscall() in trap.c does more still: it takes the number from rax and
 * copies rdi, rsi, rdx, r10, r8 and r9 into the argument block itself.
 * That branch is reached by no other test.
 *
 * Three registers cannot be checked and the ABI says why: rax carries
 * the number in and the result out, and rcx and r11 are where SYSCALL
 * puts the return ip and flags and what SYSRET consumes.  Everything
 * else is preserved, argument registers included - so rdi, rsi and rdx
 * are checked against the argument values they were given rather than
 * against invented ones, which is the same question asked of the same
 * three registers.
 *
 * The call is write(2, rsp, 0): no bytes, no effect, and answered, since
 * say() below is the same call with a length.  The loop is written out
 * rather than built from the sys3 wrapper because a wrapper is a call,
 * and the compiler is free to use any of these registers across a call -
 * the sentinels would be destroyed by the calling convention rather than
 * by anything this is looking for.
 *
 *	long linuxregtorture(long n, unsigned long *badp)
 *
 * Answers 0 with the number of calls made stored through badp, or the
 * register's index 1..12 with the value it came back as.
 */
__asm__(
".globl linuxregtorture\n"
"linuxregtorture:\n"
"	pushq	%rbx\n"
"	pushq	%rbp\n"
"	pushq	%r12\n"
"	pushq	%r13\n"
"	pushq	%r14\n"
"	pushq	%r15\n"
"	subq	$32, %rsp\n"
"	movq	%rdi, 0(%rsp)\n"	/* n, as System V passed it */
"	movq	%rsi, 8(%rsp)\n"	/* badp */
"	movq	$0, 16(%rsp)\n"		/* how many calls have been made */
"	movq	%rsp, 24(%rsp)\n"	/* an address the zero-length write can name */
"	movq	$0x31111111, %rbx\n"
"	movq	$0x32222222, %rbp\n"
"	movq	$0x33333333, %r12\n"
"	movq	$0x34444444, %r13\n"
"	movq	$0x35555555, %r14\n"
"	movq	$0x36666666, %r15\n"
"	movq	$0x37777777, %r10\n"
"	movq	$0x38888888, %r8\n"
"	movq	$0x39999999, %r9\n"
"	movq	$2, %rdi\n"		/* fd */
"	movq	24(%rsp), %rsi\n"	/* buf */
"	movq	$0, %rdx\n"		/* no bytes */
"1:\n"
"	movq	$1, %rax\n"		/* SYS_write */
"	syscall\n"
"	cmpq	$0x31111111, %rbx\n"
"	jne	11f\n"
"	cmpq	$0x32222222, %rbp\n"
"	jne	12f\n"
"	cmpq	$0x33333333, %r12\n"
"	jne	13f\n"
"	cmpq	$0x34444444, %r13\n"
"	jne	14f\n"
"	cmpq	$0x35555555, %r14\n"
"	jne	15f\n"
"	cmpq	$0x36666666, %r15\n"
"	jne	16f\n"
"	cmpq	$0x37777777, %r10\n"
"	jne	17f\n"
"	cmpq	$0x38888888, %r8\n"
"	jne	18f\n"
"	cmpq	$0x39999999, %r9\n"
"	jne	19f\n"
"	cmpq	$2, %rdi\n"
"	jne	20f\n"
"	cmpq	24(%rsp), %rsi\n"
"	jne	21f\n"
"	cmpq	$0, %rdx\n"
"	jne	22f\n"
"	movq	16(%rsp), %rcx\n"
"	addq	$1, %rcx\n"
"	movq	%rcx, 16(%rsp)\n"
"	cmpq	0(%rsp), %rcx\n"
"	jne	1b\n"
	/* every one survived: tell the caller how many calls were made */
"	movq	16(%rsp), %rcx\n"
"	movq	8(%rsp), %rdx\n"
"	movq	%rcx, (%rdx)\n"
"	movq	$0, %rax\n"
"	jmp	98f\n"
"11:\n	movq %rbx, %rcx\n	movq $1, %rax\n	jmp 99f\n"
"12:\n	movq %rbp, %rcx\n	movq $2, %rax\n	jmp 99f\n"
"13:\n	movq %r12, %rcx\n	movq $3, %rax\n	jmp 99f\n"
"14:\n	movq %r13, %rcx\n	movq $4, %rax\n	jmp 99f\n"
"15:\n	movq %r14, %rcx\n	movq $5, %rax\n	jmp 99f\n"
"16:\n	movq %r15, %rcx\n	movq $6, %rax\n	jmp 99f\n"
"17:\n	movq %r10, %rcx\n	movq $7, %rax\n	jmp 99f\n"
"18:\n	movq %r8, %rcx\n	movq $8, %rax\n	jmp 99f\n"
"19:\n	movq %r9, %rcx\n	movq $9, %rax\n	jmp 99f\n"
"20:\n	movq %rdi, %rcx\n	movq $10, %rax\n	jmp 99f\n"
"21:\n	movq %rsi, %rcx\n	movq $11, %rax\n	jmp 99f\n"
"22:\n	movq %rdx, %rcx\n	movq $12, %rax\n"
"99:\n"
"	movq	8(%rsp), %rdx\n"
"	movq	%rcx, (%rdx)\n"
"98:\n"
"	addq	$32, %rsp\n"
"	popq	%r15\n"
"	popq	%r14\n"
"	popq	%r13\n"
"	popq	%r12\n"
"	popq	%rbp\n"
"	popq	%rbx\n"
"	ret\n");
extern long linuxregtorture(long n, unsigned long *badp);

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
		/*
		 * A real file, through the calls a Linux program built
		 * against a libc actually makes.  open(2) compiles to
		 * openat(AT_FDCWD, ...) in both glibc and musl, and a program
		 * finds its way about a file with lseek and fstat.  The file
		 * is the buddy's own store, which holds 46 bytes.
		 */
		enum { Atfdcwd = -100 };
		static char st[144];		/* struct stat, x86-64 */
		long ffd, m, sz, mode;

		ffd = sys6(257, Atfdcwd, (long)"/n/hello", 0, 0, 0, 0);
		p = cat(line, "linux: openat(AT_FDCWD, \"/n/hello\") returned fd ");
		p = num(p, ffd); *p++ = '\n'; *p = 0;
		say(line);

		m = sys3(0, ffd, (long)buf, sizeof buf);
		buf[m > 0 && m <= (long)sizeof buf - 1 ? m : 0] = 0;
		p = cat(line, "linux: read ");
		p = num(p, m); p = cat(p, " bytes of it: \"");
		p = cat(p, buf);
		p = cat(p, "\"\n"); *p = 0;
		say(line);

		r = sys3(8, ffd, 6, 0);		/* lseek(ffd, 6, SEEK_SET) */
		m = sys3(0, ffd, (long)buf, 16);
		buf[m > 0 && m <= 16 ? m : 0] = 0;
		p = cat(line, "linux: lseek to 6 returned ");
		p = num(p, r); p = cat(p, " and the 16 bytes there are \"");
		p = cat(p, buf); p = cat(p, "\"\n"); *p = 0;
		say(line);

		r = sys3(5, ffd, (long)st, 0);	/* fstat(ffd, st) */
		sz = *(long*)(st + 48);		/* st_size */
		mode = *(int*)(st + 24);	/* st_mode */
		p = cat(line, "linux: fstat returned ");
		p = num(p, r); p = cat(p, ", st_size ");
		p = num(p, sz); p = cat(p, ", st_mode 0");
		p = onum(p, mode); *p++ = '\n'; *p = 0;
		say(line);

		sys3(3, ffd, 0, 0);

		for(m = 0; m < 144; m++)
			st[m] = 0;
		r = sys3(4, (long)"/n", (long)st, 0);	/* stat("/n", st) */
		mode = *(int*)(st + 24);
		p = cat(line, "linux: stat(\"/n\") returned ");
		p = num(p, r); p = cat(p, " and st_mode 0");
		p = onum(p, mode);
		p = cat(p, ", which has the directory bit\n"); *p = 0;
		say(line);
	}

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

	{
		/*
		 * Twelve registers across a hundred calls.  The count
		 * printed is the one the loop counted, not the one it was
		 * asked for, and the check requires them to agree: a loop
		 * that misread its argument still finishes with every
		 * register intact, so the registers alone say nothing
		 * about how many calls were made.
		 */
		enum { Ncall = 100 };
		unsigned long bad = 0;
		long r = linuxregtorture(Ncall, &bad);

		if(r == 0){
			p = cat(line, "linux: twelve registers survived ");
			p = num(p, (long)bad);
			p = cat(p, " of 100 system calls, the Linux ABI's own set less rax, rcx and r11\n");
			*p = 0;
		} else {
			p = cat(line, "linux: register ");
			p = num(p, r);
			p = cat(p, " came back as ");
			p = hex(p, bad);
			p = cat(p, " across a system call\n");
			*p = 0;
		}
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
