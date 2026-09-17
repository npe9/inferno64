/*
 * p9kbd.c - the i8042 controller (keyboard and mouse), driven from user
 * space above the microkernel.
 *
 * One driver owns the whole i8042, the way the talk's argument wants: the
 * controller is a single stateful device with one output buffer, and its
 * status port's aux bit says whether a byte came from the keyboard or the
 * mouse, so splitting it between two drivers would split that one buffer.
 * This driver reads every byte off port 0x60 with its own inb and routes
 * by the aux bit - a keyboard scancode, or a byte of a three-byte PS/2
 * mouse packet.
 *
 * The kernel does only the privileged parts.  It grants this process the
 * i8042 ports (ReqIoport, a per-process TSS I/O-permission bitmap), and
 * it routes the two interrupts - IRQ1 keyboard, IRQ12 aux - to the
 * process as bare notifications (ReqKbdnotify, ReqMousenotify).  Neither
 * kernel handler reads the byte; each only gives a container semaphore.
 * The two use DIFFERENT semaphores: one semaphore shared between two
 * interrupt sources loses wakeups (the give/select accounting desyncs
 * when the count and the buffer state come from two IRQs), so the
 * keyboard has its own arm and the mouse its own.  Either wakes this one
 * driver, which drains and routes both.  No scancode or mouse byte passes
 * through the kernel.
 *
 * The one-time controller setup (the command-byte handshakes that turn
 * the keyboard and aux interrupts on, enable the aux device and its
 * reporting, and drain the buffer) is done inside those two xcalls, in
 * this CPL3 kproc now (i8042enable below): the handshakes spin on the
 * status port, once thought to reopen the standing pc64 interrupt-path
 * bug, which item 15 ran fifty-two boots of the reproduction against and
 * found gone.  The whole i8042 - its one-time enable and its scancode
 * reads both - is the driver's, in user space; the kernel only routes
 * the interrupt as a notification.
 *
 * It runs as a cooperative kproc, sharing the one microkernel process the
 * personality is, and that process's port grant.  A kproc cannot block in
 * select - only the server loop can - so a notification wakes the server
 * loop (through the container semaphore), the loop calls p9kbdnotify() to
 * ready this kproc, and this kproc drains the controller.  The i8042
 * interrupts are edge-triggered, so between the notification and the
 * drain no edge is lost or repeated: the next edge waits for the drain.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

enum {
	Kbddata		= 0x60,
	Kbdstat		= 0x64,
	Kbdready	= 0x01,		/* status: output buffer full */
	Auxdata		= 0x20,		/* status: the byte is from the aux (mouse) port */
	Kbdsem		= 3,		/* the block device has 1, the clock 2 */
	Mousesem	= 4,
	ReqIoport	= 20,
	ReqKbdnotify	= 21,
	ReqMousenotify	= 22,
};

extern int  ospreyinb(int);
extern void ospreyoutb(int, int);

/*
 * The i8042 command-byte handshake, at CPL3, with this driver's own
 * port I/O - the enable the kernel used to do (item 7b's seam), moved
 * here now that item 15 showed a long CPL3 spin taking interrupts
 * corrupts nothing.  The spins on the status port are bounded so a
 * wedged controller cannot hang the driver.  The kernel has already
 * armed the notification handler and masked its own; the interrupt is
 * not enabled in the controller until the writes below set the command
 * bits, so no keypress or mouse packet fires before the driver is ready.
 */
static void
i8042wait_ibe(void)		/* wait for the input buffer to empty before a write */
{
	int i;
	for(i = 0; i < 100000 && (ospreyinb(Kbdstat) & 0x02); i++)
		;
}
static void
i8042wait_obf(void)		/* wait for the output buffer to fill before a read */
{
	int i;
	for(i = 0; i < 100000 && !(ospreyinb(Kbdstat) & Kbdready); i++)
		;
}
static void
i8042cmd_u(int cmd)
{
	i8042wait_ibe();
	ospreyoutb(Kbdstat, cmd);
}
static void
i8042wdata_u(int data)
{
	i8042wait_ibe();
	ospreyoutb(Kbddata, data);
}
static int
i8042rdata_u(void)
{
	i8042wait_obf();
	return ospreyinb(Kbddata) & 0xff;
}

static void
i8042enable(void)
{
	int c, i;

	/* drain any stale bytes the buffer holds */
	for(i = 0; i < 100000 && (ospreyinb(Kbdstat) & Kbdready); i++)
		ospreyinb(Kbddata);
	/* the keyboard: read the command byte, set the keyboard-interrupt bit, write it back */
	i8042cmd_u(0x20);
	c = i8042rdata_u();
	c |= 0x01;			/* keyboard interrupt enable (IRQ1) */
	i8042cmd_u(0x60);
	i8042wdata_u(c);
	/* the aux (mouse): enable the port, set the aux-interrupt and clock bits, tell it to report */
	i8042cmd_u(0xA8);		/* enable the aux port */
	i8042cmd_u(0x20);
	c = i8042rdata_u();
	c |= 0x02;			/* aux interrupt enable (IRQ12) */
	c &= ~0x20;			/* aux clock enable (0 = enabled) */
	i8042cmd_u(0x60);
	i8042wdata_u(c);
	i8042cmd_u(0xD4);		/* route the next byte to the aux port */
	i8042wdata_u(0xF4);		/* tell the mouse to report movement */
	i8042rdata_u();			/* eat its ACK (0xFA) */
	/* drain the echoes */
	for(i = 0; i < 100000 && (ospreyinb(Kbdstat) & Kbdready); i++)
		ospreyinb(Kbddata);
}
extern long ospreyxcall(int op, uvlong *args, long n);

static Rendez kbdr;
/*
 * The US set-1 keymap, and the shift and control state a scancode
 * stream carries.  The driver reads scancodes; /dev/kbd is runes, so
 * the translation belongs on this side of the queue - devinput.c holds
 * runes and knows nothing about a keyboard.  The tables are kbd.c's,
 * the full personality's user-level driver, unchanged: one keymap for
 * the machine, whichever driver is reading the controller.
 */
static Rune unshift[128] = {
[0x01] 0x1b,
[0x02] '1',[0x03] '2',[0x04] '3',[0x05] '4',[0x06] '5',[0x07] '6',
[0x08] '7',[0x09] '8',[0x0a] '9',[0x0b] '0',[0x0c] '-',[0x0d] '=',
[0x0e] '\b',[0x0f] '\t',
[0x10] 'q',[0x11] 'w',[0x12] 'e',[0x13] 'r',[0x14] 't',[0x15] 'y',
[0x16] 'u',[0x17] 'i',[0x18] 'o',[0x19] 'p',[0x1a] '[',[0x1b] ']',
[0x1c] '\n',
[0x1e] 'a',[0x1f] 's',[0x20] 'd',[0x21] 'f',[0x22] 'g',[0x23] 'h',
[0x24] 'j',[0x25] 'k',[0x26] 'l',[0x27] ';',[0x28] '\'',[0x29] '`',
[0x2b] '\\',
[0x2c] 'z',[0x2d] 'x',[0x2e] 'c',[0x2f] 'v',[0x30] 'b',[0x31] 'n',
[0x32] 'm',[0x33] ',',[0x34] '.',[0x35] '/',
[0x39] ' ',
};
static Rune shifted[128] = {
[0x01] 0x1b,
[0x02] '!',[0x03] '@',[0x04] '#',[0x05] '$',[0x06] '%',[0x07] '^',
[0x08] '&',[0x09] '*',[0x0a] '(',[0x0b] ')',[0x0c] '_',[0x0d] '+',
[0x0e] '\b',[0x0f] '\t',
[0x10] 'Q',[0x11] 'W',[0x12] 'E',[0x13] 'R',[0x14] 'T',[0x15] 'Y',
[0x16] 'U',[0x17] 'I',[0x18] 'O',[0x19] 'P',[0x1a] '{',[0x1b] '}',
[0x1c] '\n',
[0x1e] 'A',[0x1f] 'S',[0x20] 'D',[0x21] 'F',[0x22] 'G',[0x23] 'H',
[0x24] 'J',[0x25] 'K',[0x26] 'L',[0x27] ':',[0x28] '"',[0x29] '~',
[0x2b] '|',
[0x2c] 'Z',[0x2d] 'X',[0x2e] 'C',[0x2f] 'V',[0x30] 'B',[0x31] 'N',
[0x32] 'M',[0x33] '<',[0x34] '>',[0x35] '?',
[0x39] ' ',
};

static int kbdshift, kbdctl, kbdesc;

extern void inputkey(Rune);
extern void inputmouse(int, int, int);

/* fold one scancode into the shift state, and queue a rune if it makes one */
static void
kbdrune(int sc)
{
	Rune r;

	if(sc == 0xe0){			/* extended prefix: the next code is not ours */
		kbdesc = 1;
		return;
	}
	if(kbdesc){
		kbdesc = 0;
		return;
	}
	if(sc & 0x80){			/* a break code: only the modifiers matter */
		sc &= 0x7f;
		if(sc == 0x2a || sc == 0x36)
			kbdshift = 0;
		else if(sc == 0x1d)
			kbdctl = 0;
		return;
	}
	if(sc == 0x2a || sc == 0x36){
		kbdshift = 1;
		return;
	}
	if(sc == 0x1d){
		kbdctl = 1;
		return;
	}
	if(sc >= 128)
		return;
	r = kbdshift ? shifted[sc] : unshift[sc];
	if(r == 0)
		return;
	if(kbdctl && r < 0x80){		/* control folds a letter to ^X */
		if(r >= 'a' && r <= 'z')
			r &= 0x1f;
		else if(r >= '@' && r <= '_')
			r &= 0x1f;
	}
	inputkey(r);
}

static int kbdpending;

static int
kbdcond(void *)
{
	return kbdpending;
}

/*
 * Called from the server loop when either notification semaphore fires.
 * It runs in the loop's context, so it only readies the driver kproc; the
 * loop then runs the ready kprocs and the driver does the real read.
 */
void
p9kbdnotify(void)
{
	kbdpending = 1;
	wakeup(&kbdr);
}

static void
kbdproc(void *)
{
	int st, c, mn;
	uchar mpkt[3];
	uvlong a[2];

	/* own the i8042 ports at CPL3 - for the reads below */
	a[0] = Kbddata;
	a[1] = Kbdstat;
	ospreyxcall(ReqIoport, a, 2);

	/*
	 * Register both interrupts as notifications, each on its own
	 * semaphore.  The kernel side (buffer masked while it programs the
	 * controller) enables each device's interrupt and unmasks the line
	 * last, so nothing fires until this kproc is blocked in select.
	 */
	a[0] = Kbdsem;
	ospreyxcall(ReqKbdnotify, a, 1);
	a[0] = Mousesem;
	ospreyxcall(ReqMousenotify, a, 1);
	/*
	 * The handshake at CPL3, this driver's own: the kernel has armed
	 * the notification handlers and masked its own; now the driver
	 * enables the keyboard and aux interrupts in the controller.  The
	 * whole i8042 - its enable and its data both - is the driver's now.
	 */
	i8042enable();
	print("p9 i8042: user-space driver up; the driver did the controller handshake at CPL3 "
		"(the whole i8042 is its own now); IRQ1/IRQ12 are notifications, "
		"scancodes and mouse packets read by inb\n");

	mn = 0;
	for(;;){
		kbdpending = 0;
		ksleep(&kbdr, kbdcond, nil);
		/*
		 * The kernel only signalled.  We read the controller: drain
		 * every byte the output buffer holds and route each by the aux
		 * bit - a keyboard scancode, or a byte of a PS/2 mouse packet -
		 * read, here, in user space, off port 0x60 by this process's
		 * own inb.
		 */
		while((st = ospreyinb(Kbdstat)) & Kbdready){
			c = ospreyinb(Kbddata) & 0xff;
			if(st & Auxdata){
				/* a three-byte PS/2 packet: flags, dx, dy */
				if(mn == 0 && !(c & 0x08))
					continue;	/* byte0 bit3 is always 1: resync */
				mpkt[mn++] = (uchar)c;
				if(mn >= 3){
					int b, dx, dy;
					b = mpkt[0];
					dx = mpkt[1]; if(b & 0x10) dx -= 256;
					dy = mpkt[2]; if(b & 0x20) dy -= 256;
					print("p9 mouse: dx=%d dy=%d buttons=%s%s%s "
						"read from port 0x60 in user space\n",
						dx, dy, (b&1)?"L":"-", (b&4)?"M":"-",
						(b&2)?"R":"-");
					inputmouse(dx, dy, b);	/* and on to /dev/mouse */
					mn = 0;
				}
				continue;
			}
			print("p9 kbd: scancode %#ux read from port 0x60 in user "
				"space%s\n", c, (c & 0x80) ? " (release)" : "");
			kbdrune(c);		/* and on to /dev/kbd */
		}
	}
}

void
p9kbdstart(void)
{
	kproc("p9kbd", kbdproc, nil);
}
