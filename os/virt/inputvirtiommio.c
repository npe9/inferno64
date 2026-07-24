/*
 * Virtio-mmio input (QEMU virtio-tablet/mouse/keyboard).  TypInput=18.
 * Probes every MMIO slot; maps EV_ABS/EV_REL/buttons → mousetrack,
 * and other EV_KEY → /dev/keyboard (gkbdq).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

typedef struct Vring Vring;
typedef struct Vdesc Vdesc;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;
typedef struct Ctlr Ctlr;
typedef struct Inevent Inevent;

enum {
	TypInput	= 18,

	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeatureok	= 8,
	Sfailed		= 0x80,

	Magic		= 0x00,
	Version		= 0x04,
	DeviceId	= 0x08,
	DevFeatures	= 0x10,
	DevFeaturesSel	= 0x14,
	DrvFeatures	= 0x20,
	DrvFeaturesSel	= 0x24,
	GuestPageSize	= 0x28,
	QueueSel	= 0x30,
	QueueNumMax	= 0x34,
	QueueNum	= 0x38,
	QueueAlign	= 0x3c,
	QueuePfn	= 0x40,
	QueueReady	= 0x44,
	QueueNotify	= 0x50,
	InterruptStatus	= 0x60,
	InterruptAck	= 0x64,
	Status		= 0x70,
	QueueDescLow	= 0x80,
	QueueDescHigh	= 0x84,
	QueueAvailLow	= 0x90,
	QueueAvailHigh	= 0x94,
	QueueUsedLow	= 0xa0,
	QueueUsedHigh	= 0xa4,

	VirtMagic	= 0x74726976,

	Dnext		= 1,
	Dwrite		= 2,

	VringSize	= 4,
	VdescSize	= 16,
	VusedSize	= 8,
	VBY2PG		= 4096,
#define VPGROUND(s)	ROUND(s, VBY2PG)

	Qevent		= 0,
	/* Qstatus = 1 unused */

	EV_SYN		= 0,
	EV_KEY		= 1,
	EV_REL		= 2,
	EV_ABS		= 3,

	SYN_REPORT	= 0,
	ABS_X		= 0,
	ABS_Y		= 1,
	REL_X		= 0,
	REL_Y		= 1,
	BTN_LEFT	= 0x110,
	BTN_RIGHT	= 0x111,
	BTN_MIDDLE	= 0x112,

	/* Linux input keycodes (subset) */
	KEY_ESC		= 1,
	KEY_1		= 2,
	KEY_0		= 11,
	KEY_MINUS	= 12,
	KEY_EQUAL	= 13,
	KEY_BACKSPACE	= 14,
	KEY_TAB		= 15,
	KEY_Q		= 16,
	KEY_P		= 25,
	KEY_LEFTBRACE	= 26,
	KEY_RIGHTBRACE	= 27,
	KEY_ENTER	= 28,
	KEY_LEFTCTRL	= 29,
	KEY_A		= 30,
	KEY_L		= 38,
	KEY_SEMICOLON	= 39,
	KEY_APOSTROPHE	= 40,
	KEY_GRAVE	= 41,
	KEY_LEFTSHIFT	= 42,
	KEY_BACKSLASH	= 43,
	KEY_Z		= 44,
	KEY_M		= 50,
	KEY_COMMA	= 51,
	KEY_DOT		= 52,
	KEY_SLASH	= 53,
	KEY_RIGHTSHIFT	= 54,
	KEY_LEFTALT	= 56,
	KEY_SPACE	= 57,
	KEY_CAPSLOCK	= 58,
	KEY_RIGHTALT	= 100,
	KEY_RIGHTCTRL	= 97,
	KEY_UP		= 103,
	KEY_LEFT	= 105,
	KEY_RIGHT	= 106,
	KEY_DOWN	= 108,
	KEY_DELETE	= 111,

	AbsMax		= 32767,
	ScrX		= 640,
	ScrY		= 480,
	/*
	 * Bounce (and QMP floods) can produce ABS+SYN bursts faster than
	 * a starved kproc drains.  64 was too small and a bad used.id
	 * recycle permanently killed the tablet.  256 + reclaim recovers.
	 */
	Nbuf		= 256,
	Nctlr		= 4,
};

struct Vring
{
	u16int	flags;
	u16int	idx;
};

struct Vdesc
{
	u64int	addr;
	u32int	len;
	u16int	flags;
	u16int	next;
};

struct Vused
{
	u32int	id;
	u32int	len;
};

struct Inevent
{
	u16int	type;
	u16int	code;
	s32int	value;
};

struct Vqueue
{
	int	qsize;
	int	qmask;
	u16int	lastused;
	Vdesc	*desc;
	Vring	*avail;
	u16int	*availent;
	u16int	*availevent;
	Vring	*used;
	Vused	*usedent;
	u16int	*usedevent;
	Inevent	*ev;
};

struct Ctlr
{
	int	vers;
	int	irq;
	uintptr	regs;
	Vqueue	*eq;
	Rendez	*r;	/* pointer: KenC LP64 embeds Lock/Rendez poorly */
	int	x;
	int	y;
	int	b;
	int	pend;
};

static Ctlr	*inputctlr[Nctlr];
static int	ninput;
static int	shift;
static int	ctrl;
static int	caps;

extern Queue*	gkbdq;

static u32int
csr32r(Ctlr *c, int r)
{
	return *(volatile u32int*)(c->regs + r);
}

static void
csr32w(Ctlr *c, int r, u32int v)
{
	*(volatile u32int*)(c->regs + r) = v;
}

static void
csr64w(Ctlr *c, int r, u64int v)
{
	csr32w(c, r, (u32int)v);
	csr32w(c, r+4, (u32int)(v>>32));
}

static ulong
queuesize(ulong size)
{
	return VPGROUND(VdescSize*size + sizeof(u16int)*(3+size))
		+ VPGROUND(sizeof(u16int)*3 + VusedSize*size)
		+ VPGROUND(sizeof(Inevent)*size);
}

static Vqueue*
mkvqueue(int size)
{
	Vqueue *q;
	uchar *p;

	q = mallocz(sizeof(*q), 1);
	if(q == nil)
		return nil;
	p = mallocalign(queuesize(size), VBY2PG, 0, 0);
	if(p == nil){
		free(q);
		return nil;
	}
	q->desc = (void*)p;
	p += VdescSize*size;
	q->avail = (void*)p;
	p += VringSize;
	q->availent = (void*)p;
	p += sizeof(u16int)*size;
	q->availevent = (void*)p;
	p += sizeof(u16int);
	p = (uchar*)VPGROUND((uintptr)p);
	q->used = (void*)p;
	p += VringSize;
	q->usedent = (void*)p;
	p += VusedSize*size;
	q->usedevent = (void*)p;
	p += sizeof(u16int);
	p = (uchar*)VPGROUND((uintptr)p);
	q->ev = (Inevent*)p;
	q->qsize = size;
	q->qmask = size - 1;
	q->lastused = 0;
	return q;
}

static int
vqsetup(Ctlr *c, Vqueue *q, int qi)
{
	u64int pa;
	int i;

	csr32w(c, QueueSel, qi);
	if(c->vers >= 2){
		csr32w(c, QueueNum, q->qsize);
		csr64w(c, QueueDescLow, PADDR(q->desc));
		csr64w(c, QueueAvailLow, PADDR(q->avail));
		csr64w(c, QueueUsedLow, PADDR(q->used));
		coherence();
		csr32w(c, QueueReady, 1);
		if(csr32r(c, QueueReady) != 1)
			return -1;
	}else{
		csr32w(c, GuestPageSize, BY2PG);
		csr32w(c, QueueNum, q->qsize);
		csr32w(c, QueueAlign, BY2PG);
		pa = PADDR(q->desc);
		if(pa & (BY2PG-1))
			return -1;
		coherence();
		csr32w(c, QueuePfn, (u32int)(pa/BY2PG));
	}

	/* Fill eventq with device-writable buffers. */
	for(i = 0; i < q->qsize; i++){
		q->desc[i].addr = PADDR(&q->ev[i]);
		q->desc[i].len = sizeof(Inevent);
		q->desc[i].flags = Dwrite;
		q->desc[i].next = 0;
		q->availent[i] = i;
	}
	coherence();
	q->avail->idx = q->qsize;
	coherence();
	csr32w(c, QueueNotify, qi);
	return 0;
}

static int
scale(int v, int max)
{
	if(v < 0)
		v = 0;
	if(v > AbsMax)
		v = AbsMax;
	return (v * max) / AbsMax;
}

static void
apply(Ctlr *c)
{
	if(!c->pend)
		return;
	c->pend = 0;
	if(c->x < 0)
		c->x = 0;
	if(c->x >= ScrX)
		c->x = ScrX - 1;
	if(c->y < 0)
		c->y = 0;
	if(c->y >= ScrY)
		c->y = ScrY - 1;
	mousetrack(c->b, c->x, c->y, 0);
}

/* US QWERTY: unshifted / shifted printable for KEY_1..KEY_SLASH subset. */
static char unshiftmap[128] = {
	[KEY_1] '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=',
	[KEY_Q] 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']',
	[KEY_A] 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'',
	[KEY_GRAVE] '`',
	[KEY_BACKSLASH] '\\',
	[KEY_Z] 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
	[KEY_SPACE] ' ',
};
static char shiftmap[128] = {
	[KEY_1] '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+',
	[KEY_Q] 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}',
	[KEY_A] 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"',
	[KEY_GRAVE] '~',
	[KEY_BACKSLASH] '|',
	[KEY_Z] 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
	[KEY_SPACE] ' ',
};

static void
keyevent(int code, int value)
{
	int ch, sh;

	if(gkbdq == nil)
		return;
	switch(code){
	case KEY_LEFTSHIFT:
	case KEY_RIGHTSHIFT:
		shift = value != 0;
		return;
	case KEY_LEFTCTRL:
	case KEY_RIGHTCTRL:
		ctrl = value != 0;
		return;
	case KEY_CAPSLOCK:
		if(value)
			caps ^= 1;
		return;
	case KEY_LEFTALT:
	case KEY_RIGHTALT:
		return;
	}
	if(value == 0)	/* key up */
		return;

	ch = 0;
	switch(code){
	case KEY_ENTER:
		ch = '\n';
		break;
	case KEY_BACKSPACE:
		ch = '\b';
		break;
	case KEY_TAB:
		ch = '\t';
		break;
	case KEY_ESC:
		ch = 0x1b;
		break;
	case KEY_DELETE:
		ch = 0x7f;
		break;
	default:
		if(code >= 0 && code < 128){
			sh = shift;
			if(caps && unshiftmap[code] >= 'a' && unshiftmap[code] <= 'z')
				sh ^= 1;
			ch = sh ? shiftmap[code] : unshiftmap[code];
		}
		break;
	}
	if(ch == 0)
		return;
	if(ctrl){
		if(ch >= 'a' && ch <= 'z')
			ch -= 'a' - 1;
		else if(ch >= 'A' && ch <= 'Z')
			ch -= 'A' - 1;
	}
	gkbdputc(gkbdq, ch);
}

static void
oneevent(Ctlr *c, Inevent *e)
{
	switch(e->type){
	case EV_ABS:
		if(e->code == ABS_X)
			c->x = scale(e->value, ScrX);
		else if(e->code == ABS_Y)
			c->y = scale(e->value, ScrY);
		c->pend = 1;
		break;
	case EV_REL:
		if(e->code == REL_X)
			c->x += e->value;
		else if(e->code == REL_Y)
			c->y += e->value;
		c->pend = 1;
		break;
	case EV_KEY:
		if(e->code == BTN_LEFT){
			if(e->value)
				c->b |= 1;
			else
				c->b &= ~1;
			c->pend = 1;
		}else if(e->code == BTN_MIDDLE){
			if(e->value)
				c->b |= 2;
			else
				c->b &= ~2;
			c->pend = 1;
		}else if(e->code == BTN_RIGHT){
			if(e->value)
				c->b |= 4;
			else
				c->b &= ~4;
			c->pend = 1;
		}else if(e->code < 0x100)
			keyevent(e->code, e->value);
		break;
	case EV_SYN:
		if(e->code == SYN_REPORT)
			apply(c);
		break;
	}
}

/*
 * Re-offer every descriptor after a corrupt used ring entry.
 * avail->idx := used->idx + qsize (all buffers free for the device).
 */
static void
vqreclaimall(Ctlr *c)
{
	Vqueue *q;
	int i, m;
	u16int base;

	q = c->eq;
	if(q == nil)
		return;
	m = q->qmask;
	coherence();
	base = q->used->idx;
	q->lastused = base;
	for(i = 0; i < q->qsize; i++){
		q->desc[i].addr = PADDR(&q->ev[i]);
		q->desc[i].len = sizeof(Inevent);
		q->desc[i].flags = Dwrite;
		q->desc[i].next = 0;
		q->availent[(base + i) & m] = i;
	}
	coherence();
	q->avail->idx = base + q->qsize;
	coherence();
	csr32w(c, QueueNotify, Qevent);
}

/* Drain used ring; must run in process context (mousetrack/gkbdputc). */
static void
vqdrain(Ctlr *c)
{
	Vqueue *q;
	int id, m, n;
	u16int idx;
	u32int len;

	q = c->eq;
	if(q == nil)
		return;
	m = q->qmask;
	n = 0;
	coherence();
	idx = q->used->idx;
	coherence();
	while(q->lastused != idx){
		id = q->usedent[q->lastused & m].id;
		len = q->usedent[q->lastused & m].len;
		coherence();
		/*
		 * Seeing a new used->idx before usedent[] is written
		 * (missing barrier) used to recycle a garbage id into
		 * avail — after that the tablet never moves again.
		 */
		if(id < 0 || id >= q->qsize || len < sizeof(Inevent)){
			/* KenC LP64: one int per print */
			print("virtinput: reclaim bad id=");
			print("%d", id);
			print(" len=");
			print("%lud", (ulong)len);
			print("\n");
			vqreclaimall(c);
			return;
		}
		oneevent(c, &q->ev[id]);
		q->availent[q->avail->idx & m] = id;
		coherence();
		q->avail->idx++;
		coherence();
		q->lastused++;
		n++;
	}
	if(n)
		csr32w(c, QueueNotify, Qevent);
}

static int
inhasroom(void *a)
{
	Ctlr *c;
	Vqueue *q;

	c = a;
	q = c->eq;
	if(q == nil)
		return 0;
	coherence();
	return q->lastused != q->used->idx;
}

static void
inputproc(void *arg)
{
	Ctlr *c;

	c = arg;
	for(;;){
		sleep(c->r, inhasroom, c);
		/* Drain until quiet so edge-triggered IRQs cannot strand events. */
		do
			vqdrain(c);
		while(inhasroom(c));
	}
}

static void
inputinterrupt(Ureg*, void *arg)
{
	Ctlr *c;

	c = arg;
	if(csr32r(c, InterruptStatus) & 1){
		csr32w(c, InterruptAck, 1);
		if(c->r != nil)
			wakeup(c->r);
	}
}

static Ctlr*
mmioprobe1(int slot)
{
	Ctlr *c;
	Vqueue *q;
	uintptr base;
	u32int magic, vers, id, feat1, n;

	base = VIRTIO0 + (uintptr)slot*VIRTIO_SIZE;
	magic = *(volatile u32int*)(base+Magic);
	if(magic != VirtMagic)
		return nil;
	vers = *(volatile u32int*)(base+Version);
	id = *(volatile u32int*)(base+DeviceId);
	if(id != TypInput)
		return nil;
	if(vers != 1 && vers != 2)
		return nil;
	c = mallocz(sizeof(*c), 1);
	if(c == nil)
		return nil;
	c->vers = vers;
	c->regs = base;
	c->irq = Virtio0IRQ + slot;
	c->x = ScrX/2;
	c->y = ScrY/2;

	csr32w(c, Status, 0);
	csr32w(c, Status, Sacknowledge|Sdriver);
	if(vers >= 2){
		csr32w(c, DevFeaturesSel, 1);
		feat1 = csr32r(c, DevFeatures);
		csr32w(c, DrvFeaturesSel, 0);
		csr32w(c, DrvFeatures, 0);
		csr32w(c, DrvFeaturesSel, 1);
		csr32w(c, DrvFeatures, feat1 & 1);
		csr32w(c, Status, Sacknowledge|Sdriver|Sfeatureok);
		if(!(csr32r(c, Status) & Sfeatureok)){
			csr32w(c, Status, Sfailed);
			free(c);
			return nil;
		}
	}else{
		csr32w(c, DrvFeaturesSel, 0);
		csr32w(c, DrvFeatures, 0);
	}

	csr32w(c, QueueSel, Qevent);
	n = csr32r(c, QueueNumMax);
	if(n == 0){
		csr32w(c, Status, Sfailed);
		free(c);
		return nil;
	}
	if(n > Nbuf)
		n = Nbuf;
	while(n & (n-1))
		n--;
	q = mkvqueue(n);
	if(q == nil){
		csr32w(c, Status, Sfailed);
		free(c);
		return nil;
	}
	c->eq = q;
	if(vqsetup(c, q, Qevent) < 0){
		csr32w(c, Status, Sfailed);
		free(q);
		free(c);
		return nil;
	}
	csr32w(c, Status, Sacknowledge|Sdriver|Sfeatureok|Sdriverok);
	c->r = mallocz(sizeof(Rendez), 1);
	if(c->r == nil){
		csr32w(c, Status, Sfailed);
		free(q);
		free(c);
		return nil;
	}
	print("virtiommio: input");
	print(" @ "); print("%lux", (ulong)c->regs);
	print(" irq "); print("%d", c->irq);
	print(" v"); print("%d", c->vers);
	print(" q "); print("%d", q->qsize);
	print("\n");
	return c;
}

void
inputvirtiommiolink(void)
{
	Ctlr *c;
	int slot;

	ninput = 0;
	for(slot = 0; slot < VIRTIO_NDEV && ninput < Nctlr; slot++){
		c = mmioprobe1(slot);
		if(c == nil)
			continue;
		inputctlr[ninput++] = c;
		intrenable(c->irq, 0, inputinterrupt, c, "virtinput");
	}
}

/* Start drain kprocs after sched is up (not from links()). */
void
inputvirtiommiostart(void)
{
	Ctlr *c;
	int i;
	char name[KNAMELEN];

	for(i = 0; i < ninput; i++){
		c = inputctlr[i];
		if(c == nil || c->r == nil)
			continue;
		snprint(name, sizeof name, "vinput%d", i);
		kproc(name, inputproc, c, 0);
	}
}
