/*
 * A KVM client with no library: runs a small guest through /dev/kvm
 * and reports what it saw.  It is the second check of the VMX that the
 * patched QEMU's TCG implements (scripts/qemu-patches/0006), with
 * Linux's kvm_intel as the hypervisor rather than this kernel's vmx.c
 * (scripts/check-qemu-vmx.sh); it is not part of Inferno.
 *
 * The guest is real-mode code at 0x1000, which under kvm_intel runs
 * with unrestricted guest and EPT: it writes "Hi" to port 0xe9, sums
 * a table it was given in memory and writes the sum where the host
 * reads it, makes 1000 more port exits, and halts.
 *
 * Built freestanding: x86_64-elf-gcc -static -nostdlib -ffreestanding
 * -mgeneral-regs-only.
 */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long u64;

enum {
	SYS_write = 1, SYS_open = 2, SYS_mmap = 9, SYS_ioctl = 16, SYS_exit = 60,
	O_RDWR = 2,
	PROT_RW = 3, MAP_SHARED = 1, MAP_PRIVATE = 2, MAP_ANON = 0x20,

	KVM_GET_API_VERSION = 0xae00,
	KVM_CREATE_VM = 0xae01,
	KVM_GET_VCPU_MMAP_SIZE = 0xae04,
	KVM_CREATE_VCPU = 0xae41,
	KVM_SET_USER_MEMORY_REGION = 0x4020ae46,
	KVM_RUN = 0xae80,
	KVM_GET_REGS = 0x8090ae81,
	KVM_SET_REGS = 0x4090ae82,
	KVM_GET_SREGS = 0x8138ae83,
	KVM_SET_SREGS = 0x4138ae84,

	KVM_EXIT_IO = 2, KVM_EXIT_HLT = 5,
};

struct region {
	u32 slot, flags;
	u64 gpa, size, uaddr;
};

struct regs {
	u64 rax, rbx, rcx, rdx, rsi, rdi, rsp, rbp;
	u64 r8, r9, r10, r11, r12, r13, r14, r15;
	u64 rip, rflags;
};

struct seg {
	u64 base;
	u32 limit;
	u16 selector;
	u8 type, present, dpl, db, s, l, g, avl, unusable, pad;
};

struct sregs {
	struct seg cs, ds, es, fs, gs, ss, tr, ldt;
	u8 dt[32];
	u64 cr0, cr2, cr3, cr4, cr8, efer, apic_base;
	u64 intr[4];
};

static long
sys(long n, long a, long b, long c, long d, long e, long f)
{
	long r;
	register long r10 asm("r10") = d;
	register long r8 asm("r8") = e;
	register long r9 asm("r9") = f;

	asm volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c),
		"r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
	return r;
}

static void
put(const char *s)
{
	long n = 0;

	while (s[n])
		n++;
	sys(SYS_write, 1, (long)s, n, 0, 0, 0);
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
	put("KVMTEST: FAIL ");
	put(what);
	put(" ");
	putnum(-r);
	put("\n");
	sys(SYS_exit, 1, 0, 0, 0, 0, 0);
}

/*
 * The guest, 16-bit real mode, at 0x1000:
 *	mov al,'H'; out 0xe9,al; mov al,'i'; out 0xe9,al
 *	xor ax,ax; mov si,0x2000; mov cx,16
 * l:	add ax,[si]; add si,2; loop l
 *	mov [0x3000],ax
 *	mov cx,1000
 * m:	out 0xe8,al; loop m
 *	hlt
 */
static const u8 code[] = {
	0xb0, 'H', 0xe6, 0xe9, 0xb0, 'i', 0xe6, 0xe9,
	0x31, 0xc0, 0xbe, 0x00, 0x20, 0xb9, 0x10, 0x00,
	0x03, 0x04, 0x83, 0xc6, 0x02, 0xe2, 0xf9,
	0xa3, 0x00, 0x30,
	0xb9, 0xe8, 0x03,
	0xe6, 0xe8, 0xe2, 0xfc,
	0xf4,
};

/* entered from the kernel with RSP 16-byte aligned, not as a call */
__attribute__((force_align_arg_pointer)) void
_start(void)
{
	long kvm, vm, vcpu, sz, r, i;
	u8 *mem, *run;
	struct region reg;
	struct regs rg;
	struct sregs sr;
	u16 *tab;
	u32 sum, nio = 0, nhi = 0;
	char hi[3] = { 0, 0, 0 };

	kvm = sys(SYS_open, (long)"/dev/kvm", O_RDWR, 0, 0, 0, 0);
	if (kvm < 0)
		fail("open /dev/kvm", kvm);
	r = sys(SYS_ioctl, kvm, KVM_GET_API_VERSION, 0, 0, 0, 0);
	if (r != 12)
		fail("api version", -r);
	vm = sys(SYS_ioctl, kvm, KVM_CREATE_VM, 0, 0, 0, 0);
	if (vm < 0)
		fail("create vm", vm);
	mem = (u8 *)sys(SYS_mmap, 0, 0x10000, PROT_RW, MAP_PRIVATE | MAP_ANON, -1, 0);
	if ((long)mem < 0)
		fail("mmap", (long)mem);
	for (i = 0; i < (long)sizeof code; i++)
		mem[0x1000 + i] = code[i];
	tab = (u16 *)(mem + 0x2000);
	sum = 0;
	for (i = 0; i < 16; i++) {
		tab[i] = 1000 + 37 * i;
		sum += tab[i];
	}
	reg = (struct region){ 0, 0, 0, 0x10000, (u64)mem };
	r = sys(SYS_ioctl, vm, KVM_SET_USER_MEMORY_REGION, (long)&reg, 0, 0, 0);
	if (r < 0)
		fail("set memory", r);
	vcpu = sys(SYS_ioctl, vm, KVM_CREATE_VCPU, 0, 0, 0, 0);
	if (vcpu < 0)
		fail("create vcpu", vcpu);
	sz = sys(SYS_ioctl, kvm, KVM_GET_VCPU_MMAP_SIZE, 0, 0, 0, 0);
	run = (u8 *)sys(SYS_mmap, 0, sz, PROT_RW, MAP_SHARED, vcpu, 0);
	if ((long)run < 0)
		fail("mmap vcpu", (long)run);
	r = sys(SYS_ioctl, vcpu, KVM_GET_SREGS, (long)&sr, 0, 0, 0);
	if (r < 0)
		fail("get sregs", r);
	sr.cs.base = 0;
	sr.cs.selector = 0;
	sr.ds.base = 0;
	sr.ds.selector = 0;
	r = sys(SYS_ioctl, vcpu, KVM_SET_SREGS, (long)&sr, 0, 0, 0);
	if (r < 0)
		fail("set sregs", r);
	for (i = 0; i < (long)(sizeof rg / 8); i++)
		((u64 *)&rg)[i] = 0;
	rg.rip = 0x1000;
	rg.rflags = 2;
	r = sys(SYS_ioctl, vcpu, KVM_SET_REGS, (long)&rg, 0, 0, 0);
	if (r < 0)
		fail("set regs", r);

	for (;;) {
		r = sys(SYS_ioctl, vcpu, KVM_RUN, 0, 0, 0, 0);
		if (r < 0)
			fail("run", r);
		switch (*(u32 *)(run + 8)) {
		case KVM_EXIT_IO: {
			u16 port = *(u16 *)(run + 34);
			u64 off = *(u64 *)(run + 40);

			if (port == 0xe9 && nhi < 2)
				hi[nhi++] = run[off];
			else if (port == 0xe8)
				nio++;
			break;
		}
		case KVM_EXIT_HLT:
			put("KVMTEST: guest said \"");
			put(hi);
			put("\", sum ");
			putnum(*(u16 *)(mem + 0x3000));
			put(" (want ");
			putnum(sum & 0xffff);
			put("), ");
			putnum(nio);
			put(" port exits, halted\n");
			if (hi[0] == 'H' && hi[1] == 'i' &&
			    *(u16 *)(mem + 0x3000) == (sum & 0xffff) && nio == 1000)
				put("KVMTEST: PASS\n");
			else
				put("KVMTEST: FAIL\n");
			sys(SYS_exit, 0, 0, 0, 0, 0, 0);
		default:
			put("KVMTEST: FAIL exit reason ");
			putnum(*(u32 *)(run + 8));
			put("\n");
			sys(SYS_exit, 1, 0, 0, 0, 0, 0);
		}
	}
}
