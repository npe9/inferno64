/*
 * AppKit requires the process main thread.  Real Inferno main runs on a
 * worker pthread; this file owns main() and [NSApp run].
 *
 * Queue Inferno start on the main queue before [NSApp run] so the run loop
 * is live before screeninit's dispatch_sync — avoids a startup deadlock.
 */
#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <stdio.h>

extern int	emumain(int, char**);

static int	emuargc;
static char	**emuargv;

static void*
emuthread(void *arg)
{
	(void)arg;
	emumain(emuargc, emuargv);
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSApp terminate:nil];
	});
	return NULL;
}

static void
startemu(void)
{
	pthread_t tid;
	pthread_attr_t attr;

	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	if(pthread_create(&tid, &attr, emuthread, NULL) != 0){
		fputs("emu: cannot start inferno thread\n", stderr);
		[NSApp terminate:nil];
	}
	pthread_attr_destroy(&attr);
}

int
main(int argc, char **argv)
{
	emuargc = argc;
	emuargv = argv;

	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

		/*
		 * Tell macOS this process must keep running.
		 *
		 * emu links Cocoa and creates an NSApplication even when it
		 * is serving Styx from a terminal with no window on screen.
		 * To macOS that is an app doing nothing visible in the
		 * background, and App Nap suspends it -- the whole task, not
		 * a thread of it.
		 *
		 * What that looks like from outside took a very long time to
		 * identify, because it looks like every kind of hang at once:
		 * connections accepted by the kernel and never taken off the
		 * listen queue (netstat -anL climbing 1/0/128, 2/0/128,
		 * 3/0/128), no reply to a Styx handshake for a minute or
		 * more, CPU time frozen to the hundredth of a second, SIGTERM
		 * ignored because the handler never runs, and then full
		 * recovery with no explanation.  A sample shows every thread
		 * parked in whatever it last called -- including watchdog
		 * kprocs sitting in a three-second nanosleep for three and a
		 * half minutes, which is the tell: no deadlock inside the
		 * process can stop an independent timer, only the OS
		 * declining to schedule the process can.
		 *
		 * Confirmed by lifting the policy on a frozen server with
		 * `taskpolicy -B -p <pid>`: it accepted its backlog and
		 * resumed printing immediately, then froze again when macOS
		 * re-applied it.
		 *
		 * AllowingIdleSystemSleep, deliberately: this says "do not
		 * nap me", not "keep the machine awake".  An emulator has no
		 * business holding somebody's laptop out of sleep.
		 */
		/*
		 * Held for the life of the process: the activity ends when
		 * this token is released, and this file is built with ARC,
		 * so a static strong reference is what keeps it.
		 */
		static id emuactivity;
		emuactivity = [[NSProcessInfo processInfo]
			beginActivityWithOptions:
				NSActivityUserInitiatedAllowingIdleSystemSleep
			reason:@"Inferno is an operating system; suspending it "
				@"stops its clocks and its network"];
		(void)emuactivity;

		/*
		 * Runs once the run loop is spinning inside [NSApp run],
		 * not before — so later dispatch_sync from Inferno is safe.
		 */
		dispatch_async(dispatch_get_main_queue(), ^{
			startemu();
		});

		[NSApp run];
	}
	return 0;
}
