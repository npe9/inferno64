/*
 * An NVMe admin client with no library: asks a controller, through
 * Linux's /dev/nvme0 admin passthrough, what it says of the newer
 * features the patched QEMU's NVMe model has (scripts/qemu-patches/0008)
 * -- the host memory buffer and autonomous power state transitions --
 * after Linux's nvme driver has set them up.  It is the check of that
 * model against Linux (scripts/check-qemu-nvme.sh); it is not part of
 * Inferno.
 *
 *	identify	HMPRE, HMMIN, HMMINDS, HMMAXD, NPSS, APSTA
 *	hmb		whether the buffer is enabled, its size and descriptors
 *	apst		whether APST is on, and each state's transition
 *	idle		the power state the controller is found in after
 *			three idle seconds, and after a read
 *
 * Built freestanding: x86_64-elf-gcc -static -nostdlib -ffreestanding
 * -mgeneral-regs-only.
 */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long u64;

enum {
	SYS_read = 0, SYS_write = 1, SYS_open = 2, SYS_ioctl = 16,
	SYS_nanosleep = 35, SYS_exit = 60,
	O_RDONLY = 0, O_RDWR = 2, O_DIRECT = 0x4000,

	NVME_IOCTL_ADMIN_CMD = 0xc0484e41,
	ADM_IDENTIFY = 0x06,
	ADM_GET_FEATURES = 0x0a,
	FID_POWER = 0x02,
	FID_APST = 0x0c,
	FID_HMB = 0x0d,
};

struct admin {
	u8 opcode, flags;
	u16 rsvd1;
	u32 nsid, cdw2, cdw3;
	u64 metadata, addr;
	u32 metadata_len, data_len;
	u32 cdw10, cdw11, cdw12, cdw13, cdw14, cdw15;
	u32 timeout_ms, result;
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

static void
putnum(u64 v)
{
	char b[24];
	int i = 23;

	b[i] = 0;
	do {
		b[--i] = '0' + v % 10;
		v /= 10;
	} while (v);
	put(b + i);
}

static void
fail(const char *what, long r)
{
	put("NVMETEST: FAIL ");
	put(what);
	put(" ");
	putnum(r < 0 ? -r : r);
	put("\n");
	sys(SYS_exit, 1, 0, 0);
}

static void
zero(void *p, long n)
{
	u8 *b = p;

	while (n-- > 0)
		*b++ = 0;
}

static u32
le32(const u8 *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (u32)p[3] << 24;
}

static u64
le64(const u8 *p)
{
	return le32(p) | (u64)le32(p + 4) << 32;
}

static u8 buf[4096] __attribute__((aligned(4096)));

/* an admin command; the result dword, or the failure */
static u32
admin(long fd, u8 op, u32 cdw10, u32 len, const char *what)
{
	struct admin c;
	long r;

	zero(&c, sizeof c);
	zero(buf, sizeof buf);
	c.opcode = op;
	c.addr = (u64)buf;
	c.data_len = len;
	c.cdw10 = cdw10;
	r = sys(SYS_ioctl, fd, NVME_IOCTL_ADMIN_CMD, (long)&c);
	if (r != 0)
		fail(what, r);
	return c.result;
}

static void
nap(long s)
{
	long ts[2] = { s, 0 };

	sys(SYS_nanosleep, (long)ts, 0, 0);
}

void
_start(void)
{
	long fd, ns;
	u32 r, i, hsize, n;
	u8 npss, apsta;

	fd = sys(SYS_open, (long)"/dev/nvme0", O_RDWR, 0);
	if (fd < 0)
		fail("open /dev/nvme0", fd);

	admin(fd, ADM_IDENTIFY, 1, 4096, "identify");
	npss = buf[263];
	apsta = buf[265];
	put("NVMETEST: identify hmpre ");
	putnum(le32(buf + 272));
	put(" hmmin ");
	putnum(le32(buf + 276));
	put(" hmminds ");
	putnum(le32(buf + 332));
	put(" hmmaxd ");
	putnum(buf[336] | buf[337] << 8);
	put(" npss ");
	putnum(npss);
	put(" apsta ");
	putnum(apsta);
	put("\n");

	r = admin(fd, ADM_GET_FEATURES, FID_HMB, 4096, "get hmb");
	hsize = le32(buf);
	put("NVMETEST: hmb enabled ");
	putnum(r & 1);
	put(" hsize ");
	putnum(hsize);
	put(" pages descriptors ");
	putnum(le32(buf + 12));
	put("\n");

	r = admin(fd, ADM_GET_FEATURES, FID_APST, 256, "get apst");
	put("NVMETEST: apst enabled ");
	putnum(r & 1);
	put("\n");
	for (i = 0; i <= npss; i++) {
		u64 e = le64(buf + 8 * i);

		if ((e >> 8 & 0xffffff) == 0)
			continue;
		put("NVMETEST: apst ps");
		putnum(i);
		put(" -> ps");
		putnum(e >> 3 & 0x1f);
		put(" after ");
		putnum(e >> 8 & 0xffffff);
		put(" ms\n");
	}

	nap(3);
	r = admin(fd, ADM_GET_FEATURES, FID_POWER, 0, "get power");
	put("NVMETEST: idle 3s found in ps");
	putnum(r & 0x1f);
	put("\n");

	/* past the page cache, so that the read reaches the controller */
	ns = sys(SYS_open, (long)"/dev/nvme0n1", O_RDONLY | O_DIRECT, 0);
	if (ns < 0)
		fail("open /dev/nvme0n1", ns);
	n = sys(SYS_read, ns, (long)buf, 4096);
	if (n != 4096)
		fail("read nvme0n1", n);
	r = admin(fd, ADM_GET_FEATURES, FID_POWER, 0, "get power");
	put("NVMETEST: after a read found in ps");
	putnum(r & 0x1f);
	put("\n");
	put("NVMETEST: done\n");
	sys(SYS_exit, 0, 0, 0);
}
