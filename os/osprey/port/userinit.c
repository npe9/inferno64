#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"tos.h"
#include	"../port/error.h"

/*
 * The initcode array contains the binary text of the first
 * user process. Its job is to invoke the exec system call
 * for /boot/boot.
 * Initcode does not link with standard plan9 libc _main()
 * trampoline due to size constrains. Instead it is linked
 * with a small machine specific trampoline init9.s that
 * only sets the base address register and passes arguments
 * to startboot() (see port/initcode.c).
 */
#include	"initcode.i"
#include	"userprog.i"
#include	"p9prog.i"

extern int ospreymicro;
extern void ospreymicroboot(void);
extern int ospreyuser;
extern int ospreyp9;
extern int ospreyp9pair;
extern int ospreyp9buddy;
extern int ospreyp9linux;
extern void touserat(char*);
extern int ospreyuserprep(void);
extern int ospreyframebuffer(void);

static void
smark(char *s)
{
	/*
	 * kdebugmark is a locked raw COM1 write: it shares the console lock
	 * with the user tasks' writes so the marker does not interleave with
	 * them (which was splicing a byte out of a string a check greps for),
	 * and it does not call kdebugsetup, so it leaves pc64's interrupt-
	 * driven console alone.
	 */
	kdebugmark(s, strlen(s));
}

/*
 * Load the userprog image into up's text and stack segments.  The
 * program has no data segment - its strings live on the stack, as
 * initcode's do - so its whole image is text, loaded a page at a time.
 * Shared by proc0 (the first user task) and any further user task the
 * microkernel spawns, so each gets the same image in its own address
 * space.
 */
void
ospreyloadprog(void)
{
	KMap *k;
	Page *pg;
	ulong npg, i, off, cnt;

	npg = (sizeof(userprog) + BY2PG - 1) / BY2PG;
	up->seg[SSEG] = newseg(SG_STACK | SG_NOEXEC, USTKTOP-USTKSIZE, USTKSIZE / BY2PG);
	up->seg[TSEG] = newseg(SG_TEXT | SG_RONLY, UTZERO, npg);
	up->seg[TSEG]->flushme = 1;
	for(i = 0; i < npg; i++){
		off = i * BY2PG;
		cnt = sizeof(userprog) - off;
		if(cnt > BY2PG)
			cnt = BY2PG;
		pg = newpage(UTZERO + off, nil);
		k = kmap(pg);
		memmove((uchar*)VA(k), userprog + off, cnt);
		if(cnt < BY2PG)
			memset((uchar*)VA(k) + cnt, 0, BY2PG - cnt);
		kunmap(k);
		segpage(up->seg[TSEG], pg);
	}
}

/*
 * Load a real a.out program (the Plan 9 personality library, p9prog.i)
 * into text, data and bss segments.  Unlike ospreyloadprog's flat load,
 * this parses the exec header and lays out the segments the way the
 * linker and sysproc's exec do, eager-mapping every page (xup64 has no
 * demand paging).  The entry is init9's _main at UTZERO+0x28, which
 * touser jumps to.
 */
static void
ospreyfillseg(Segment *s, uvlong va, ulong npg, uchar *src, ulong srclen)
{
	KMap *k;
	Page *pg;
	ulong i, off, cnt;

	for(i = 0; i < npg; i++){
		off = i*BY2PG;
		cnt = off < srclen ? srclen - off : 0;
		if(cnt > BY2PG)
			cnt = BY2PG;
		pg = newpage(va + off, nil);
		k = kmap(pg);
		if(cnt)
			memmove((uchar*)VA(k), src + off, cnt);
		if(cnt < BY2PG)
			memset((uchar*)VA(k) + cnt, 0, BY2PG - cnt);
		kunmap(k);
		segpage(s, pg);
	}
}

void
ospreyloadaout(uchar *prog)
{
	struct Exec { long magic, text, data, bss, syms, entry, spsz, pcsz; } *h;
	ulong magic, hdrsz, textsz, datasz, bsssz, tseg;
	uvlong textend, adata, abss, ebss;

	h = (struct Exec*)prog;
	magic = beswal(h->magic);
	textsz = beswal(h->text);
	datasz = beswal(h->data);
	bsssz = beswal(h->bss);
	hdrsz = (magic & 0x8000) ? sizeof(struct Exec)+8 : sizeof(struct Exec);
	tseg = hdrsz + textsz;
	textend = UTZERO + tseg;
	adata = (textend + BY2PG-1) & ~(uvlong)(BY2PG-1);
	abss = (adata + datasz + BY2PG-1) & ~(uvlong)(BY2PG-1);
	ebss = (adata + datasz + bsssz + BY2PG-1) & ~(uvlong)(BY2PG-1);

	up->seg[SSEG] = newseg(SG_STACK | SG_NOEXEC, USTKTOP-USTKSIZE, USTKSIZE/BY2PG);

	up->seg[TSEG] = newseg(SG_TEXT | SG_RONLY, UTZERO, PGROUND(tseg)>>PGSHIFT);
	up->seg[TSEG]->flushme = 1;
	ospreyfillseg(up->seg[TSEG], UTZERO, PGROUND(tseg)>>PGSHIFT, prog, tseg);

	up->seg[DSEG] = newseg(SG_DATA, adata, PGROUND(datasz)>>PGSHIFT);
	ospreyfillseg(up->seg[DSEG], adata, PGROUND(datasz)>>PGSHIFT, prog+tseg, datasz);

	up->seg[BSEG] = newseg(SG_BSS, abss, (ebss-abss)>>PGSHIFT);
	ospreyfillseg(up->seg[BSEG], abss, (ebss-abss)>>PGSHIFT, nil, 0);
}

void
ospreyloadp9(void)
{
	ospreyloadaout(p9prog);		/* the Plan 9 personality library */
}

/*
 * The entry of the legacy program the buddy laid out; touserat (l.s)
 * reads it, since an ELF binary enters at e_entry, not the a.out
 * convention's fixed offset.
 */
uintptr	ospreyuserentry;

/* 1 TB: above any static image, below the stack.  Not an enum: those are int here. */
#define Linuxmmapbase	0x10000000000ull
enum {
	Lenomem		= 12,
	Leinval		= 22,
	Mapanon		= 0x20,
	Mapfixed	= 0x10,
	Lebadf		= 9,
	Sigsegv		= 11,
	SAsiginfo	= 4,
	SArestorer	= 0x04000000,
};

/*
 * Exec a legacy binary through the buddy.  The kernel holds no copy of
 * it: it is a file in the buddy's file system, the buddy reads its
 * headers and answers with the entry, the loadable segments and what
 * kind of binary it is, and the kernel makes each segment empty - text
 * or data by the segment's execute flag - with a stack below USTKTOP
 * and a heap for brk a page above the image.  Every page of text and
 * data is then a fault the buddy answers (ospreybuddyfault in
 * devosprey.c): the paper's buddy interposes on page faults as well as
 * system calls.  An ELF is a Linux process and marks itself so; a Plan
 * 9 a.out is laid out by the buddy as three pieces the same way and is
 * entered the Plan 9 way by the caller.  Returns the kind - 0 an ELF,
 * 1 an a.out - or -1 when the buddy did not lay it out.
 */
int
ospreyexecbuddy(char *name)
{
	Ospreybuddyseg segs[8];
	uvlong entry, segva, segend, top;
	int n, i, seg, npg, kind;

	n = ospreybuddyexec(name, &entry, segs, nelem(segs), &kind);
	if(n < 0)
		return -1;
	up->oslinux = kind == 0;	/* an ELF is a Linux process; an a.out a Plan 9 one */
	up->buddyimage = 1;		/* either way its pages are the buddy's */
	ospreyuserentry = entry;
	up->seg[SSEG] = newseg(SG_STACK | SG_NOEXEC, USTKTOP-USTKSIZE, USTKSIZE/BY2PG);
	seg = TSEG;
	top = 0;
	for(i = 0; i < n && seg < NSEG; i++){
		segva = segs[i].va & ~(uvlong)(BY2PG-1);
		segend = (segs[i].va + segs[i].memsz + BY2PG-1) & ~(uvlong)(BY2PG-1);
		if(segva < top)
			segva = top;	/* two headers in one page: the first owns it */
		if(segva >= segend)
			continue;
		npg = (segend - segva) / BY2PG;
		up->seg[seg] = newseg((segs[i].flags & 1) ? SG_TEXT : SG_DATA, segva, npg);
		if(segs[i].flags & 1)
			up->seg[seg]->flushme = 1;
		top = segend;
		seg++;
	}
	/*
	 * The heap brk grows, a page above the image, in a slot of its
	 * own; the kernel zero-fills it on demand (SG_BSS), which is the
	 * address-space service and not the buddy's file.
	 */
	up->linuxheap = -1;
	if(seg < NSEG){
		up->seg[seg] = newseg(SG_BSS, top, 1);
		up->linuxheap = seg;
		up->linuxbrk = top;
		seg++;
	}
	up->linuxmmapnext = Linuxmmapbase;
	print("osprey buddy: %s laid out by the buddy: entry %#llux, %d segments, no page mapped yet\n",
		name, entry, n);
	return kind;
}


/*
 * The Linux address-space calls, answered by the kernel: they ask for
 * memory, which is the microkernel's own service, not a file the buddy
 * holds.  brk moves the heap segment's top (Linux returns the new break
 * on success and the old one on failure); mmap of anonymous private
 * memory makes a demand-zero segment at the next free address above
 * Linuxmmapbase (a hint is honoured only as a hint, and a file mapping
 * is refused); munmap detaches the segment mmap made at exactly that
 * address.  Errors are the negative errno Linux uses.
 */

uintptr
ospreylinuxbrk(uintptr addr)
{
	if(up->linuxheap < 0)
		return (uintptr)-Lenomem;
	if(addr == 0)
		return up->linuxbrk;
	if(waserror())
		return up->linuxbrk;		/* unchanged: the old break */
	ibrk(addr, up->linuxheap);
	poperror();
	up->linuxbrk = addr;
	return addr;
}

uintptr
ospreylinuxmmap(uintptr addr, uintptr len, int prot, int flags, int fd, vlong off)
{
	uintptr va;
	int sno;

	int m;

	USED(prot);
	if(len == 0)
		return (uintptr)-Leinval;
	if(flags & Mapanon){
		if(fd != -1)
			return (uintptr)-Leinval;
	} else {
		/*
		 * A file mapping: its pages come from the buddy, read from
		 * the file at the offset, which is the image's page path
		 * with an offset.  Private: a page is the process's own copy.
		 */
		if(fd < 0 || (off & (BY2PG-1)) != 0)
			return (uintptr)-Leinval;
		for(m = 0; m < nelem(up->linuxmap); m++)
			if(up->linuxmap[m].len == 0)
				break;
		if(m == nelem(up->linuxmap))
			return (uintptr)-Lenomem;
	}
	len = PGROUND(len);
	if(flags & Mapfixed){
		if(addr == 0 || (addr & (BY2PG-1)) != 0 || isoverlap(addr, len) != nil)
			return (uintptr)-Leinval;	/* over something: not replaced here */
		va = addr;
	} else
		va = addr != 0 && (addr & (BY2PG-1)) == 0 && isoverlap(addr, len) == nil && addr + len < USTKTOP-USTKSIZE ?
			addr : up->linuxmmapnext;
	while(isoverlap(va, len) != nil)
		va += len;
	if(va + len >= USTKTOP-USTKSIZE)
		return (uintptr)-Lenomem;
	for(sno = 0; sno < NSEG; sno++)
		if(up->seg[sno] == nil && sno != ESEG)
			break;
	if(sno == NSEG)
		return (uintptr)-Lenomem;
	if(waserror())
		return (uintptr)-Lenomem;
	/* a file mapping is a data segment the buddy pages; anonymous memory the kernel zero-fills */
	up->seg[sno] = newseg((flags & Mapanon) ? SG_BSS : SG_DATA, va, len/BY2PG);
	poperror();
	if((flags & Mapanon) == 0){
		up->linuxmap[m].va = va;
		up->linuxmap[m].len = len;
		up->linuxmap[m].fd = fd;
		up->linuxmap[m].off = off;
	}
	if(va == up->linuxmmapnext)
		up->linuxmmapnext = va + len;
	print("osprey user: mmap %lud bytes %s at %#llux\n", (ulong)len, (flags & Mapanon) ? "anonymous" : "of a file", (uvlong)va);
	return va;
}

/*
 * A Linux process's system call, whatever configuration it runs in: the
 * number in up->s.args is la[0..5] as syscall() (trap.c) laid them out.
 * write to the console and exit are answered here, so are the
 * address-space calls above, and everything else goes to the buddy
 * through ospreybuddyforward, which maps the file calls it knows and
 * refuses the rest.  The result goes to the process's ax.
 */
extern long ospreybuddyforward(ulong, uintptr*);
uintptr ospreylinuxmunmap(uintptr, uintptr);

int
ospreylinuxsyscall(ulong scallnr, uintptr *retp)
{
	uvlong *la = (uvlong*)up->s.args;

	switch(scallnr){
	case 1:				/* write */
		if(la[0] == 1 || la[0] == 2){
			char *b = (char*)la[1];
			long ln = (long)la[2], i;

			if(!waserror()){
				validaddr((uintptr)b, ln, 0);
				for(i = 0; i < ln; i++)
					kdebugputc(b[i]);
				poperror();
			}
			*retp = (uintptr)ln;
			return 0;
		}
		break;
	case 60: case 231:		/* exit, exit_group */
		ospreyexits((long)la[0]);
		*retp = 0;
		return 0;
	case 12:			/* brk */
		*retp = ospreylinuxbrk((uintptr)la[0]);
		return 0;
	case 9:				/* mmap */
		*retp = ospreylinuxmmap((uintptr)la[0], (uintptr)la[1], (int)la[2], (int)la[3], (int)la[4], (vlong)la[5]);
		return 0;
	case 11:			/* munmap */
		*retp = ospreylinuxmunmap((uintptr)la[0], (uintptr)la[1]);
		return 0;
	case 13:			/* rt_sigaction(sig, act, oldact, sigsetsize) */
		/*
		 * Only SIGSEGV is delivered, since the only signal this
		 * kernel has to deliver is a fault the buddy declined; the
		 * rest are accepted and forgotten.  The kernel's own struct:
		 * handler, flags, restorer, mask.  The restorer is required -
		 * there is no trampoline of the kernel's on the stack - and a
		 * libc always supplies one.
		 */
		if(la[0] == Sigsegv && la[1] != 0){
			uvlong *act = (uvlong*)la[1];

			if(!waserror()){
				validaddr((uintptr)act, 4*sizeof(uvlong), 0);
				if((act[1] & SArestorer) == 0 || act[2] == 0){
					poperror();
					*retp = (uintptr)-Leinval;
					return 0;
				}
				up->linuxsighandler = (uintptr)act[0];
				up->linuxsigrestorer = (uintptr)act[2];
				poperror();
			}
		}
		*retp = 0;
		return 0;
	case 14:			/* rt_sigprocmask: no mask is kept */
		*retp = 0;
		return 0;
	case 15:			/* rt_sigreturn: back to the frame the signal interrupted */
		ospreylinuxsigreturn();
		return 0;		/* ax is whatever the frame had */
	}
	*retp = (uintptr)ospreybuddyforward(scallnr, (uintptr*)up->s.args);
	return 0;
}

uintptr
ospreylinuxmunmap(uintptr addr, uintptr len)
{
	Segment *s;
	int sno;

	for(sno = 0; sno < NSEG; sno++){
		s = up->seg[sno];
		if(s != nil && s->base == addr && s->top == addr + PGROUND(len) && sno != up->linuxheap && sno != SSEG)
			break;
	}
	if(sno == NSEG)
		return (uintptr)-Leinval;	/* only whole mappings mmap made */
	qlock(&up->seglock);
	up->seg[sno] = nil;
	qunlock(&up->seglock);
	putseg(s);
	flushmmu();
	for(sno = 0; sno < nelem(up->linuxmap); sno++)
		if(up->linuxmap[sno].va == addr)
			up->linuxmap[sno].len = 0;
	return 0;
}

/*
 * Enter a loaded ELF binary at its own entry (touserat), with a minimal
 * System V stack: argc zero and null argv, envp and auxv terminators, so
 * a program that peeks at them finds them empty.  The Linux system-call
 * convention (number in ax, arguments in registers) is read in syscall().
 */
void
ospreyenteruserat(void)
{
	uvlong *sp;

	up->kp = 0;
	up->noswap = 0;
	up->privatemem = 0;
	procpriority(up, PriNormal, 0);
	procsetup(up);
	flushmmu();

	sp = (uvlong*)(USTKTOP - 64);
	sp[0] = 0;		/* argc */
	sp[1] = 0;		/* argv terminator */
	sp[2] = 0;		/* envp terminator */
	sp[3] = 0;		/* auxv AT_NULL */

	splhi();
	fpukexit(nil);
	touserat((char*)sp);
}

/*
 * Become a user task: finish turning up into a user process and enter
 * user mode at the program's entry, with a stack carrying one argument.
 * This is the tail of init0 without the Plan 9 setup - no chandevinit,
 * no environment, no second alarm kproc - so a task spawned after proc0
 * enters user mode cleanly.  The stack is laid out as the entry expects:
 * the first word is the return slot the SYSRET entry does not use, the
 * second is argv[0] (a copy of arg0), the third the argv terminator, and
 * arg0's bytes sit above them.
 */
void
ospreyenteruser(char *arg0)
{
	char *sp;
	int n;

	up->kp = 0;
	up->noswap = 0;
	up->privatemem = 0;
	procpriority(up, PriNormal, 0);
	procsetup(up);
	flushmmu();

	/*
	 * The 6c amd64 convention passes the first argument in a register
	 * (RARG == BP), and touser leaves the sp pointer there, so the user
	 * entry reads argv0 == sp.  Put the argument string at sp itself, so
	 * the program's first parameter points straight at it.  The stack
	 * grows down from sp, so these bytes are above it and stay intact
	 * until the program reads them.
	 */
	sp = (char*)(USTKTOP - sizeof(Tos) - 64);
	n = strlen(arg0) + 1;
	memmove(sp, arg0, n);

	splhi();
	fpukexit(nil);
	touser(sp);
}

/*
 * The first process kernel process starts here.
 */
static void
proc0(void*)
{
	KMap *k;
	Page *p;

	spllo();
	smark("osprey: proc0\n");
	print("proc0: start\n");
	if(ospreyuser){
		/*
		 * A user program on the microkernel: set up its text and
		 * stack and enter user mode, with no Plan 9 name space.  This
		 * is the exokernel path a library-OS program runs on - the
		 * kernel gives it an address space and lets it run; what it
		 * calls for it reaches through the syscall interface, not
		 * through a name space the kernel set up.
		 */
		ospreyuserprep();
		ospreyframebuffer();
		if(ospreyp9linux){
			/*
			 * An unmodified Linux binary the buddy serves: mark this
			 * process Linux (its syscalls use the Linux ABI), have the
			 * buddy lay the ELF out from its own file system, and enter
			 * at its entry; its pages come from the buddy as it faults.
			 */
			if(ospreyexecbuddy("/boot/linux") < 0)
				panic("osprey buddy: the buddy did not lay out /boot/linux");
			ospreyenteruserat();
			panic("ospreyenteruserat returned");
		}
		if(ospreyp9buddy){
			/*
			 * An unmodified Plan 9 binary the buddy serves, laid out
			 * and paged by the buddy from its own file system like
			 * the Linux one, and entered the Plan 9 way.
			 */
			if(ospreyexecbuddy("/boot/legacy") != 1)
				panic("osprey buddy: the buddy did not lay out /boot/legacy");
			ospreyenteruser("/boot/legacy");
			panic("ospreyenteruser returned");
		}
		if(ospreyp9)
			ospreyloadp9();		/* the Plan 9 personality library */
		else
			ospreyloadprog();	/* the minimal microkernel task */
		if(ospreyp9pair){
			/*
			 * The paired personality: this task is the client, its
			 * buddy the server it delegates to.  Enter as the pair
			 * client, which mounts the buddy over the ring.
			 */
			ospreyenteruser("c");
			panic("ospreyenteruser returned");
		}
		up->kp = 0;
		up->noswap = 0;
		up->privatemem = 0;
		procpriority(up, PriNormal, 0);
		procsetup(up);
		flushmmu();
		smark("osprey: touser\n");
		init0();
		panic("init0 returned");
	}
	if(ospreymicro){
		/* the microkernel boot: an Osprey task, no Plan 9 personality */
		ospreymicroboot();
		panic("ospreymicroboot returned");
	}
	if(waserror())
		panic("proc0: %s", up->errstr);

	print("proc0: groups\n");
	up->pgrp = newpgrp();
	up->egrp = smalloc(sizeof(Egrp));
	up->egrp->ref = 1;
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();

	/*
	 * These are o.k. because rootinit is null.
	 * Then early kproc's will have a root and dot.
	 */
	print("proc0: root\n");
	up->slash = namec("#/", Atodir, 0, 0);
	pathclose(up->slash->path);
	up->slash->path = newpath("/");
	up->dot = cclone(up->slash);

	/*
	 * Setup Text and Stack segments for initcode.
	 */
	print("proc0: segments\n");
	up->seg[SSEG] = newseg(SG_STACK | SG_NOEXEC, USTKTOP-USTKSIZE, USTKSIZE / BY2PG);
	up->seg[TSEG] = newseg(SG_TEXT | SG_RONLY, UTZERO, 1);
	up->seg[TSEG]->flushme = 1;
	p = newpage(UTZERO, nil);
	k = kmap(p);
	memmove((uchar*)VA(k), initcode, sizeof(initcode));
	memset((uchar*)VA(k)+sizeof(initcode), 0, BY2PG-sizeof(initcode));
	kunmap(k);
	segpage(up->seg[TSEG], p);

	/*
	 * Become a user process.
	 */
	print("proc0: setup\n");
	up->kp = 0;
	up->noswap = 0;
	up->privatemem = 0;
	procpriority(up, PriNormal, 0);
	procsetup(up);

	flushmmu();

	poperror();

	/*
	 * init0():
	 *	call chandevinit()
	 *	setup environment variables
	 *	prepare the stack for initcode
	 *	switch to usermode to run initcode
	 */
	print("proc0: init0\n");
	smark("osprey: touser\n");
	init0();

	/* init0 will never return */
	panic("init0");
}

void
userinit(void)
{
	char *s;
	for(s = "osprey: userinit\n"; *s != 0; s++)
		outb(0x3f8, *s);
	up = nil;
	/*
	 * The host owner stays empty until the boot process picks one.
	 * Device permission entries (devsd's unit, ctl, raw and partition
	 * users, for one) are filled in from eve on first stat and only
	 * refreshed while they are still empty, so naming a placeholder
	 * here freezes device ownership to a user that nothing else knows
	 * and makes a later hostowner write lose access to the disk.
	 */
	kstrdup(&eve, "");
	kproc("*init*", proc0, nil);
}
