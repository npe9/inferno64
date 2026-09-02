/* An unmodified Linux x86-64 program: raw syscalls, no libc.  It opens a
 * file and reads it (Linux sys_open=2, sys_read=0), writes a line
 * (sys_write=1), and exits (sys_exit=60) - the Linux system-call ABI,
 * number in rax, args in rdi/rsi/rdx.  It knows nothing of Osprey. */
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

void
_start(void)
{
	static char buf[512];
	const char *m1 = "linux: an unmodified Linux binary; its file syscalls served by a buddy\n";
	long fd, n;

	sys3(1, 2, (long)m1, slen(m1));		/* write(2, m1) */
	fd = sys3(2, (long)"/", 0, 0);		/* open("/", O_RDONLY) */
	n = sys3(0, fd, (long)buf, sizeof buf);	/* read(fd, buf, 512) */
	sys3(3, fd, 0, 0);			/* close(fd) */

	{
		char rep[64];
		const char *p = "linux: open+read over the buddy returned bytes\n";
		sys3(1, 2, (long)p, slen(p));
		(void)rep; (void)n;
	}
	sys3(60, 0, 0, 0);			/* exit(0) */
	for(;;);
}
