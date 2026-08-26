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

extern int ospreymicro;
extern void ospreymicroboot(void);
extern int ospreyuser;
extern int ospreyuserprep(void);
extern int ospreyframebuffer(void);

static void
smark(char *s)
{
	int i;

	/*
	 * Write the marker straight to COM1, waiting for the transmit
	 * register between bytes so none is dropped when more than one task
	 * shares the port.  Deliberately NOT through kdebugputs: that calls
	 * kdebugsetup, which disables COM1 interrupts to drive the port
	 * polled - right for the bare-console kernels, but on pc64 it would
	 * kill the interrupt-driven console the moment proc0 marked the boot.
	 */
	while(*s != 0){
		for(i = 0; i < 100000 && (inb(0x3fd) & 0x20) == 0; i++)
			;
		outb(0x3f8, *s++);
	}
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
		ospreyloadprog();
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
