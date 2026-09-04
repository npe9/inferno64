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
 * the kernel, not in this CPL3 kproc: the handshakes spin on the status
 * port, and a spin that long at CPL3 in a cooperative kproc is a window
 * for a clock or device interrupt to land while this kproc is the running
 * context, which this microkernel's interrupt path corrupts (the standing
 * pc64 heisenbug).  The reads below are a couple of inb instructions each
 * - short CPL3 bursts - so the data path stays in user space without
 * reopening that window.
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
extern long ospreyxcall(int op, uvlong *args, long n);

static Rendez kbdr;
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
	print("p9 i8042: user-space driver up; IRQ1/IRQ12 are notifications, "
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
					mn = 0;
				}
				continue;
			}
			print("p9 kbd: scancode %#ux read from port 0x60 in user "
				"space%s\n", c, (c & 0x80) ? " (release)" : "");
		}
	}
}

void
p9kbdstart(void)
{
	kproc("p9kbd", kbdproc, nil);
}
