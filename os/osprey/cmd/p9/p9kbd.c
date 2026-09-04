/*
 * p9kbd.c - the i8042 keyboard's scancode read path, in user space above
 * the microkernel.
 *
 * The exokernel split for a legacy port device.  The kernel does the two
 * privileged things: it grants this process the i8042 ports (0x60 data,
 * 0x64 status) by clearing their bits in the process's own TSS
 * I/O-permission bitmap (ReqIoport), and it routes IRQ1 to the process as
 * a bare notification on a container semaphore (ReqKbdnotify).  When a key
 * is pressed the kernel's IRQ1 handler does not read the scancode - it
 * only gives the semaphore.  This driver, woken through that semaphore,
 * reads the scancode itself, at CPL3, with its own inb off port 0x60.  No
 * scancode passes through the kernel.
 *
 * The one-time controller enable (the i8042 command-byte handshake that
 * turns the keyboard interrupt on and drains the buffer) is done inside
 * ReqKbdnotify, in the kernel under splhi, not here: that handshake spins
 * on the status port, and a spin that long at CPL3 in a cooperative kproc
 * is long enough for a clock or device interrupt to land while this kproc
 * is the running context, which this microkernel's interrupt path
 * corrupts (the standing pc64 heisenbug - a user driver taking a legacy
 * IRQ from CPL3 reproduces it reliably).  The scancode reads below are a
 * couple of inb instructions each - the same short CPL3 bursts every
 * other personality kproc makes - so the data path stays in user space
 * without reopening that window.
 *
 * It runs as one of the personality's cooperative kprocs, sharing the one
 * microkernel process the whole personality is, and thus that process's
 * port grant.  A kproc cannot block in select - only the server loop can -
 * so the kernel's notification wakes the server loop (through the
 * container semaphore), the server loop calls p9kbdnotify() to ready this
 * kproc, and this kproc drains the controller.  IRQ1 is edge-triggered,
 * so between the notification and the drain no edge is lost or repeated:
 * the next edge waits for the drain.
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
	ReqIoport	= 20,
	ReqKbdnotify	= 21,
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
 * Called from the server loop when the IRQ1 notification semaphore fires.
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
	int st, sc;
	uvlong a[2];

	/* own the i8042 ports at CPL3 - for the scancode reads below */
	a[0] = Kbddata;
	a[1] = Kbdstat;
	ospreyxcall(ReqIoport, a, 2);

	/*
	 * Register the IRQ1 notification.  The kernel side (under splhi)
	 * enables the keyboard interrupt in the controller, drains the
	 * buffer, and unmasks IRQ1 last, so nothing fires until this kproc
	 * has reached the select below at CPL0.
	 */
	a[0] = Kbdsem;
	ospreyxcall(ReqKbdnotify, a, 1);
	print("p9 kbd: user-space i8042 driver up; IRQ1 is a notification, "
		"scancodes read by inb\n");

	for(;;){
		kbdpending = 0;
		ksleep(&kbdr, kbdcond, nil);
		/*
		 * The kernel only signalled.  We read the controller: drain
		 * every byte the output buffer holds, discarding aux (mouse)
		 * bytes, and report each keyboard scancode - read, here, in
		 * user space, off port 0x60 by this process's own inb.
		 */
		while((st = ospreyinb(Kbdstat)) & Kbdready){
			if(st & Auxdata){
				ospreyinb(Kbddata);	/* a mouse byte: not ours */
				continue;
			}
			sc = ospreyinb(Kbddata) & 0xff;
			print("p9 kbd: scancode %#ux read from port 0x60 in user "
				"space%s\n", sc, (sc & 0x80) ? " (release)" : "");
		}
	}
}

void
p9kbdstart(void)
{
	kproc("p9kbd", kbdproc, nil);
}
