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
extern void touserv(char*, char*);
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
	return ospreyexecbuddy1(name, 0);
}

/*
 * The same, with replace saying the caller already has an address space
 * that this image is to take the place of - exec(2) in place, as against
 * the fresh process the exec request starts.  The old segments go only
 * after the buddy has laid the new binary out, so a name it will not lay
 * out leaves the caller running on the image it had.
 */
int
ospreyexecbuddy1(char *name, int replace)
{
	Ospreybuddyseg segs[8];
	uvlong entry, segva, segend, top;
	int n, i, seg, npg, kind;

	n = ospreybuddyexec(name, &entry, segs, nelem(segs), &kind);
	if(n < 0)
		return -1;
	if(replace){
		/*
		 * Now, and not before: the new image is known, so the old
		 * address space can go.  Every segment, the stack included -
		 * exec keeps no memory, and what a process holds across it is
		 * its descriptors, which are the buddy's and untouched.  A note
		 * handler is code in the text that is going, so it goes too;
		 * the mapped-file records are of an address space that no
		 * longer exists.
		 */
		qlock(&up->seglock);
		for(i = 0; i < NSEG; i++)
			if(up->seg[i] != nil){
				putseg(up->seg[i]);
				up->seg[i] = nil;
			}
		qunlock(&up->seglock);
		flushmmu();
		for(i = 0; i < nelem(up->linuxmap); i++)
			up->linuxmap[i].len = 0;
		up->notify = nil;
		up->notified = 0;
		up->nnote = 0;
		up->notepending = 0;
		up->lastnote = nil;
	}
	up->oslinux = kind == 0;	/* an ELF is a Linux process; an a.out a Plan 9 one */
	up->buddyimage = 1;		/* either way its pages are the buddy's */
	if(!replace)
		up->buddyredir = 0;	/* a program the exec request started: 0, 1 and 2 are the console the buddy gives it.  An exec in place keeps them, as it keeps the descriptors */
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

/*
 * Plan 9's brk_(addr) for a legacy program the buddy loaded: heap
 * growth, which is the microkernel's own address-space service and not
 * the buddy's file.  It moves the top of the same heap segment
 * ospreyexecbuddy made a page above the image, and returns 0 or -1 the
 * way brk_(2) does rather than the address Linux's brk returns.
 *
 * The clamp below the base is not a refusal but the truth about the
 * layout: the a.out's own bss runs from the linker's `end` up to the
 * page boundary that the heap segment begins at, and those pages are
 * already mapped - the buddy supplies them as zeros (the third piece it
 * lays out has filesz 0).  libc's first sbrk asks for `end` plus a few
 * bytes, which is inside that span, so nothing has to move and the call
 * succeeds having moved nothing.  Only an ask past the image's end
 * reaches ibrk and really grows the segment.
 */
long
ospreybuddybrk(uintptr addr)
{
	Segment *s;

	if(up->linuxheap < 0 || (s = up->seg[up->linuxheap]) == nil)
		return -1;
	if(addr == 0)
		return 0;
	if(addr <= s->base){
		up->linuxbrk = addr;
		return 0;		/* still inside the image's own bss */
	}
	if(waserror())
		return -1;
	ibrk(addr, up->linuxheap);
	poperror();
	up->linuxbrk = addr;
	return 0;
}

/*
 * A region of the caller's address space it may write a program into and
 * then run: the one thing a library operating system has to ask a kernel
 * for when it loads a program itself.  Demand-zero, so nothing is
 * carried until it is touched; writable, because the loader writes the
 * program in; and executable, because the program then runs there -
 * which is what flushme means to fault(), the same mark exec puts on a
 * text segment.  A real text segment would not do: SG_TEXT is mapped
 * read-only and pages from an image, and this memory has no file behind
 * it, only the loader's copy.
 *
 * Reached by segattach with the name "code", so the microkernel's
 * address-space service keeps the one call it had rather than growing
 * another number.
 */
uintptr
ospreysegcode(uintptr va, ulong len)
{
	Segment *s;
	int sno;

	if(va == 0 || (va & (BY2PG-1)) != 0 || len == 0)
		return (uintptr)-1;
	len = PGROUND(len);
	if(va + len >= USTKTOP-USTKSIZE || isoverlap(va, len) != nil)
		return (uintptr)-1;
	for(sno = 0; sno < NSEG; sno++)
		if(up->seg[sno] == nil && sno != ESEG)
			break;
	if(sno == NSEG)
		return (uintptr)-1;
	if(waserror())
		return (uintptr)-1;
	s = newseg(SG_BSS, va, len/BY2PG);
	poperror();
	if(s == nil)
		return (uintptr)-1;
	s->flushme = 1;			/* code is fetched from it: fault() maps it executable */
	up->seg[sno] = s;
	print("osprey user: %lud bytes of address space at %#llux for a program the caller loads itself\n", (ulong)len, (uvlong)va);
	return va;
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

			/*
			 * Through the console task like every other write, in
			 * pieces a kernel buffer holds.  This once went to the bare
			 * port a byte at a time, past the task, and was the last
			 * writer that could cut the task's lines in two.
			 */
			if(!waserror()){
				extern void ospreyconsolewrite(char*, int);
				char kb[256];
				long m;

				validaddr((uintptr)b, ln, 0);
				for(i = 0; i < ln; i += m){
					m = ln - i < (long)sizeof kb ? ln - i : (long)sizeof kb;
					memmove(kb, b + i, m);
					ospreyconsolewrite(kb, m);
				}
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
/*
 * Lay a nil-terminated argument vector on the user stack the way the
 * entry (init9's _main) expects: the strings just below the Tos, then a
 * pointer array below them - argv[0]..argv[argc-1] and a nil - and enter
 * with the stack pointer at that array, which the 6c amd64 convention
 * leaves in the first argument register.  The kernel argv[] are kernel
 * pointers; their bytes are copied up and the array holds user addresses.
 */
static void
ospreyenteruservec(char **argv, int argc)
{
	uintptr strtop, sp;
	uintptr *uargv;
	int i, n;

	up->kp = 0;
	up->noswap = 0;
	up->privatemem = 0;
	procpriority(up, PriNormal, 0);
	procsetup(up);
	flushmmu();

	/* the strings, packed just below the Tos, growing down */
	strtop = USTKTOP - sizeof(Tos) - 16;
	sp = strtop;
	{
		uintptr straddr[1 + 32];		/* the user address of each string */

		if(argc > 32)
			argc = 32;
		for(i = argc - 1; i >= 0; i--){
			n = strlen(argv[i]) + 1;
			sp -= n;
			memmove((void*)sp, argv[i], n);
			straddr[i] = sp;
		}
		/*
		 * The pointer array, 16-aligned, below the strings:
		 * argv[0]..argv[argc-1], the nil that ends the vector, and
		 * one word past the nil holding the address of the Tos.
		 *
		 * That last word is this kernel's own, and it is here because
		 * a program entered this way never runs libc's _main.  On
		 * Plan 9 the kernel leaves the Tos in AX and main9.s stores
		 * it in _tos; here AX carries the argument vector instead, so
		 * the pointer has to travel somewhere, and the end of the
		 * vector is the one place the entry can find it without a
		 * second convention.  init9.c reads it.  Without a Tos, libc
		 * faults the first time a program asks the time: nsec(2)
		 * reads /dev/bintime and keeps its descriptor in a private,
		 * and the private it keeps is indexed by _tos->pid.
		 */
		sp &= ~(uintptr)15;
		sp -= (uintptr)(argc + 2) * sizeof(uintptr);
		sp &= ~(uintptr)15;
		uargv = (uintptr*)sp;
		for(i = 0; i < argc; i++)
			uargv[i] = straddr[i];
		uargv[argc] = 0;
		uargv[argc+1] = USTKTOP - sizeof(Tos);
	}

	/*
	 * And fill it.  Only what a program actually reads is set: the pid,
	 * which libc's getpid(2) and its per-process privates use, and the
	 * cycle frequency, which is 0 when the machine has no counter and
	 * is read as "do not use cycles" rather than as a rate.
	 */
	{
		Tos *tos = (Tos*)(USTKTOP - sizeof(Tos));

		memset(tos, 0, sizeof *tos);
		tos->pid = up->osprey != nil ? ospreyprocid(up) : up->pid;
		tos->cyclefreq = m->cyclefreq;
	}

	splhi();
	fpukexit(nil);
	/*
	 * The argument register holds the vector; the stack starts two
	 * words below it, which is where the entry spills that register
	 * (see touserv in pc64/l.s).  Without the gap the spill lands on
	 * argv[1].
	 */
	touserv((char*)sp, (char*)(sp - 2*sizeof(uintptr)));
}

void
ospreyenteruser(char *arg0)
{
	char *argv[2];

	argv[0] = arg0;
	argv[1] = nil;
	ospreyenteruservec(argv, 1);
}

/*
 * The same, from a packed argument buffer the exec request carried:
 * argv[0]\0 argv[1]\0 ... \0, a double nul ending it.
 */
void
ospreyenteruserargs(char *packed)
{
	char *argv[32];
	int argc;

	argc = 0;
	while(*packed != 0 && argc < 32){
		argv[argc++] = packed;
		packed += strlen(packed) + 1;
	}
	if(argc == 0){
		argv[argc++] = "";
	}
	ospreyenteruservec(argv, argc);
}

/*
 * exec(2) in place, for a legacy process the buddy loaded.  The exec
 * request (devosprey.c) starts a program in a container of its own; this
 * is the other exec, the one a program makes for itself - what a shell
 * does after it forks, and what the personality could not offer before.
 *
 * It is in two parts, and the order between them is the whole of it.
 * First everything that can fail, while the process is still whole: the
 * name and the argument vector are copied out of the address space that
 * is about to go (they live in it, and ospreyenteruservec reads them
 * after the mapping has changed, so kernel copies are not tidiness but
 * necessity), and the buddy is asked to lay the new binary out.  Either
 * can refuse, and a refusal returns -1 to a process that goes on running
 * - the buddy commits nothing of its image record until the new binary
 * has parsed.  Only then the second part, which cannot fail into
 * anything the caller could survive: the old segments go, the new ones
 * are made, and the process enters the new program.  It does not return.
 */
int
ospreyexecself(char *uname, char **uargv)
{
	char name[128], packed[512];
	char *p;
	int i, n, np;

	validaddr((uintptr)uname, 1, 0);
	for(n = 0; n < (int)sizeof name - 1; n++){
		validaddr((uintptr)&uname[n], 1, 0);
		if((name[n] = uname[n]) == 0)
			break;
	}
	name[n] = 0;
	np = 0;
	if(uargv != nil)
		for(i = 0; i < 32; i++){
			validaddr((uintptr)&uargv[i], sizeof(char*), 0);
			if((p = uargv[i]) == nil)
				break;
			while(np < (int)sizeof packed - 2){
				validaddr((uintptr)p, 1, 0);
				if((packed[np] = *p++) == 0)
					break;
				np++;
			}
			packed[np++] = 0;
		}
	if(np == 0){			/* no vector at all: the program's own name is argv[0] */
		for(i = 0; i <= n; i++)
			packed[np++] = name[i];
	}
	packed[np] = 0;			/* the double nul ospreyenteruserargs ends on */

	if(ospreyexecbuddy1(name, 1) < 0){
		/* named, because the caller returns -1 to a library that
		 * usually turns it into "exec failed" and nothing else */
		print("osprey exec: container %llud could not exec %s\n",
			up->osprey != nil ? ospreyid(up->osprey) : 0, name);
		return -1;
	}
	kstrdup(&up->text, name);
	/*
	 * The system call's own bookkeeping, which the entry below walks out
	 * of rather than returning through.  insyscall and the error label
	 * dosyscall pushed would otherwise be left standing, and the label
	 * is the one that bites quietly: it is not an error the first time
	 * or the tenth, it is an overflow after enough execs, which is why
	 * the check execs twenty times over.
	 */
	up->insyscall = 0;
	up->nerrlab = 0;
	if(up->oslinux)
		ospreyenteruserat();	/* an ELF: at its entry, the Linux way */
	ospreyenteruserargs(packed);	/* an a.out: the Plan 9 way, with its vector */
	return -1;			/* neither returns */
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
		/*
		 * The alarm kproc, which the full personality starts in
		 * init0 and this path never did.  alarm(2) posts a note when
		 * a process's time comes, and the posting is this kproc's:
		 * without it procalarm records the deadline and nothing ever
		 * reads it, so a legacy program that sets an alarm waits for
		 * a note that cannot arrive.  checkalarms, on the clock tick,
		 * is what wakes it.
		 */
		kproc("alarm", alarmkproc, 0);
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
			 *
			 * A machine starts a window system because it was
			 * configured to, and this one is no different: with
			 * *riodemo= in plan9.ini the client also execs rio and
			 * leaves it running, and without it the machine is the
			 * machine every check that is not about rio was written
			 * against.  A window system is a standing load - three
			 * readers blocked on files, a draw server answering
			 * them - and the two-machine checks, which run two of
			 * these at once and carry processes between them, are
			 * not the place to put one.
			 */
			ospreyenteruser(getconf("*riodemo") != nil ? "c rio" : "c");
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
