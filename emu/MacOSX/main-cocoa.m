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
