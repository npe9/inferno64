/*
 * p9input.c - a loop that services this container's interrupt
 * notifications, for a personality whose main flow is a script.
 *
 * The i8042 driver (p9kbd.c) registers IRQ1 and IRQ12 as notifications
 * on two of this container's semaphores and then blocks waiting to be
 * told one fired.  What tells it is a select over those semaphores, and
 * on the personality that serves a peer over a ring that select is
 * p9pairsrv.c's serve1, which arms them beside the clock and the ring.
 *
 * This personality has no such loop: its main flow is a sequence of
 * demonstrations that ends.  So /dev/kbd and /dev/mouse were files with
 * a driver behind them that never woke, and a window system reading
 * them waited for ever - rio's screen appeared only because rio flushes
 * once itself after painting the background, and every draw after that
 * waits for an event.
 *
 * This is the smallest thing that is a loop: for as long as it is asked
 * for, select over the two semaphores, hand each notification to the
 * driver, and let the cooperative scheduler run.  It is not a server -
 * it answers no ring and forwards no call - and it is not the clock:
 * the tick has its own arm elsewhere and is not taken here, so a
 * personality that wants both will want serve1's shape rather than
 * this.
 *
 * The arms go in this container's own data area, which is why the slice
 * has to be mapped, which is why the kernel had to be able to say which
 * slot is this container's (ReqWhoami).  Mapping every slot the kernel
 * allows and guessing which is one's own is not knowing.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ospreydata.h"

extern long	ospreyxcall(int, uvlong*, long);
extern int	dup(int, int);		/* the DUP number, reused as select */
extern void	p9kbdnotify(void);	/* p9kbd.c: ready the driver kproc */
extern void	p9kbdstart(void);	/* p9kbd.c: the user-space i8042 driver */
extern void	runkprocs(void);	/* p9sched.c */
extern vlong	p9nsec(void);		/* devtime.c */

enum {
	ReqWhoami	= 38,	/* devosprey.c's xcall op: which slot is mine */
	OSdown		= 4,	/* the select op that takes a semaphore */
	Kbdsem		= 3,	/* as p9kbd.c registers them */
	Mousesem	= 4,
	Armoff		= Odarm,
	Nslot		= 16,
	Ospreymagic	= 0x4f53505259ULL,	/* as p9pairsrv.c has it */
};

typedef struct Arm Arm;
struct Arm { uvlong op, obj, buf; };

typedef struct Omap Omap;
struct Omap {
	uvlong	magic, id, size, msgsize;
	uvlong	requestqueue, replyqueue, outputqueue;
	uvlong	request, reply, output;
	uvlong	data, datalen, sem, nsem, selected;
};

/* select over arms this container wrote: the DUP number, reused */
static int
oselect(int armoff, int narms)
{
	return dup(narms, armoff);
}

/*
 * This container's own slice, mapped once.  The kernel says which slot
 * it is; the name is that slot's, which is how every slice here is
 * named.
 */
static uchar*
ownslice(void)
{
	static uchar *base;
	static int tried;
	uvlong a[2];
	char nm[16];
	int slot, i, d, started, div;
	Omap *m;

	if(tried)
		return base;
	tried = 1;
	a[0] = 0;
	if(ospreyxcall(ReqWhoami, a, 1) < 0){
		print("p9 input: the kernel would not say which slot is mine\n");
		return nil;
	}
	slot = (int)a[0];
	if(slot < 0 || slot >= Nslot){
		print("p9 input: the kernel says my slot is %d, which is not one\n", slot);
		return nil;
	}
	i = 0;
	nm[i++]='o'; nm[i++]='s'; nm[i++]='p'; nm[i++]='r'; nm[i++]='e'; nm[i++]='y';
	if(slot == 0)
		nm[i++]='0';
	else {
		started = 0;
		for(div = 1000000000; div > 0; div /= 10){
			d = (slot/div)%10;
			if(d != 0 || started){ nm[i++]='0'+d; started = 1; }
		}
	}
	nm[i] = 0;
	base = (uchar*)segattach(0, nm, 0, 0);
	if(base == (uchar*)-1){
		print("p9 input: slot %d is mine and %s did not map\n", slot, nm);
		base = nil;
		return nil;
	}
	m = (Omap*)base;
	if(m->magic != Ospreymagic){
		print("p9 input: %s carries no ring map\n", nm);
		base = nil;
		return nil;
	}
	print("p9 input: my own slice is slot %d (%s), container %llud; "
		"its arms are where a select of mine is read from\n", slot, nm, m->id);
	return base;
}

/*
 * Service this container's input notifications for ms milliseconds.
 * Answers the number of notifications handed to the driver.
 */
int
p9inputloop(long ms)
{
	uchar *base;
	Omap *map;
	Arm *arm;
	static int started;
	vlong end;
	int n, got;

	base = ownslice();
	if(base == nil){
		print("p9 input: no slice of my own, so no select: sleeping instead\n");
		tsleep(&up->sleep, return0, nil, ms);
		return -1;
	}
	map = (Omap*)base;
	arm = (Arm*)(base + map->data + Armoff);
	/*
	 * And the driver, started here and not at setup.  Its own comment
	 * says why the ordering matters: the kernel enables each device's
	 * interrupt and unmasks the line last, so nothing fires until the
	 * driver's kproc is blocked waiting.  Started during setup, before
	 * there was any loop for a notification to be serviced by, it broke
	 * the configurations where it already worked - kbd, rio and riowin,
	 * three checks - and making the start idempotent did not help,
	 * which is what said the trouble was when rather than who.
	 *
	 * Here there is a loop, about to run.
	 */
	if(!started){
		started = 1;
		p9kbdstart();
	}
	end = p9nsec() + (vlong)ms * 1000000LL;
	got = 0;
	while(p9nsec() < end){
		arm[0].op = OSdown;	/* the keyboard's IRQ1 notification */
		arm[0].obj = Kbdsem;
		arm[0].buf = 0;
		arm[1].op = OSdown;	/* the mouse's IRQ12, its own semaphore */
		arm[1].obj = Mousesem;
		arm[1].buf = 0;
		n = oselect(Armoff, 2);
		if(n == 0 || n == 1){
			p9kbdnotify();	/* ready the driver kproc; it does the inb */
			got++;
		}
		runkprocs();		/* and let it, and everything else, run */
	}
	print("p9 input: serviced %d interrupt notifications in %ld ms\n", got, ms);
	return got;
}
