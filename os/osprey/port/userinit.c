#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
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
	while(*s != 0)
		outb(0x3f8, *s++);
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
		{
			ulong npg, i, off, cnt;

			npg = (sizeof(userprog) + BY2PG - 1) / BY2PG;
			up->seg[SSEG] = newseg(SG_STACK | SG_NOEXEC, USTKTOP-USTKSIZE, USTKSIZE / BY2PG);
			up->seg[TSEG] = newseg(SG_TEXT | SG_RONLY, UTZERO, npg);
			up->seg[TSEG]->flushme = 1;
			/*
			 * The program has no data segment - its strings live on
			 * the stack, as initcode's do - so its whole image is
			 * text, loaded a page at a time.  This carries a bigger
			 * program than initcode: an application and the
			 * personality library it links.
			 */
			for(i = 0; i < npg; i++){
				off = i * BY2PG;
				cnt = sizeof(userprog) - off;
				if(cnt > BY2PG)
					cnt = BY2PG;
				p = newpage(UTZERO + off, nil);
				k = kmap(p);
				memmove((uchar*)VA(k), userprog + off, cnt);
				if(cnt < BY2PG)
					memset((uchar*)VA(k) + cnt, 0, BY2PG - cnt);
				kunmap(k);
				segpage(up->seg[TSEG], p);
			}
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
