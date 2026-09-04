/*
 * An unmodified Plan 9 program.  It knows nothing of Osprey, the ring, or
 * a buddy: it opens, creates, writes, reads, stats and removes files with
 * the ordinary Plan 9 library, which traps in the Plan 9 system-call ABI.
 * On this microkernel those traps are not implemented; a buddy operating
 * system in a peer container answers them, and this program cannot tell.
 * Its writes to the console go through the kernel's own pwrite, so what it
 * prints appears directly; a write to a file descriptor crosses to the
 * buddy like every other file operation.
 */
#include <u.h>
#include <libc.h>

/*
 * Entry is startboot (init9's trampoline), since the host linker cannot
 * read libc's own _main; that is entry glue only.  What makes this a
 * legacy binary is the body: ordinary Plan 9 open/create/write/read/
 * fstat/remove/close/print.
 */
/*
 * A note handler: the ordinary Plan 9 kind, registered with notify(2).
 * When the program faults, the microkernel delivers the note here (the
 * buddy is not involved - a note is the process's own), and it catches
 * its own fault and exits rather than being killed outright.
 */
static void
nhandler(void *ureg, char *msg)
{
	USED(ureg);
	print("legacy: my note handler caught the fault: \"%s\"\n", msg);
	exits("note handled");
}

void
startboot(char *argv0, char **argv)
{
	int fd;
	char buf[512];
	long n;
	static char text[] = "a file written and read back through the buddy";
	uchar statbuf[STATMAX];

	USED(argv0); USED(argv);
	print("legacy: an unmodified Plan 9 program; its file syscalls are served by a buddy\n");

	fd = open("/", OREAD);
	if(fd < 0){
		print("legacy: open(\"/\") failed\n");
		exits("open");
	}
	print("legacy: open(\"/\") returned fd %d\n", fd);
	n = read(fd, buf, sizeof buf);
	print("legacy: read(fd, buf, %d) returned %ld bytes, served by the buddy\n", (int)sizeof buf, n);
	close(fd);

	/*
	 * Create a file, write to it, and read it back - creation, the file
	 * write (which crosses to the buddy like every other file op), and a
	 * stat, all answered by the peer.  Needs a writable store; where
	 * there is none the program says so and carries on, as a real one would.
	 */
	fd = create("/n/p9test", ORDWR, 0666);
	if(fd < 0)
		print("legacy: no writable store here (create refused); skipping the file test\n");
	else {
		print("legacy: create(\"/n/p9test\") returned fd %d\n", fd);
		n = write(fd, text, sizeof text - 1);
		print("legacy: wrote %ld bytes to the new file, served by the buddy\n", n);
		close(fd);

		fd = open("/n/p9test", OREAD);
		if(fd >= 0){
			n = read(fd, buf, sizeof buf - 1);
			if(n < 0)
				n = 0;
			buf[n] = 0;
			print("legacy: read %ld bytes back from the file: \"%s\"\n", n, buf);
			n = fstat(fd, statbuf, sizeof statbuf);
			print("legacy: fstat(\"/n/p9test\") returned a %ld-byte stat message from the buddy\n", n);
			close(fd);
		}
		n = stat("/n/p9test", statbuf, sizeof statbuf);
		print("legacy: stat(\"/n/p9test\") by name returned a %ld-byte stat message from the buddy\n", n);

		if(remove("/n/p9test") == 0)
			print("legacy: removed /n/p9test through the buddy\n");
		else {
			char ebuf[ERRMAX];
			rerrstr(ebuf, sizeof ebuf);	/* the real reason, over the buddy's errstr */
			print("legacy: remove refused, errstr from the buddy: \"%s\"\n", ebuf);
		}
	}

	/* a pipe the buddy makes: write one end, read the other */
	{
		int p[2];
		char pb[64];
		static char msg[] = "through a pipe the buddy made";

		if(pipe(p) == 0){
			print("legacy: pipe() returned fds %d and %d from the buddy\n", p[0], p[1]);
			write(p[1], msg, sizeof msg - 1);
			n = read(p[0], pb, sizeof pb - 1);
			if(n < 0)
				n = 0;
			pb[n] = 0;
			print("legacy: wrote one pipe end and read %ld bytes from the other: \"%s\"\n", n, pb);
			close(p[0]);
			close(p[1]);
		} else
			print("legacy: pipe() failed\n");
	}

	/*
	 * A private name space: rfork it, then bind /n into / so /hello names
	 * /n/hello here.  The bind is this program's own - the buddy runs the
	 * call in the name space it forked for this container, not the shared
	 * one - so it does not change what any other program sees.
	 */
	if(rfork(RFNAMEG) < 0)
		print("legacy: rfork(RFNAMEG) failed\n");
	else if(bind("/n", "/", MAFTER) < 0)
		print("legacy: bind /n onto / in the private ns failed\n");
	else {
		fd = open("/hello", OREAD);
		if(fd < 0)
			print("legacy: /hello not visible after the bind\n");
		else {
			n = read(fd, buf, sizeof buf - 1);
			if(n < 0)
				n = 0;
			buf[n] = 0;
			close(fd);
			print("legacy: rforked a private ns and bound /n into /; /hello (= /n/hello) reads: \"%s\"\n", buf);
		}
	}

	print("legacy: the buddy answered every trap\n");

	/*
	 * Register a note handler, then read a bad address on purpose.  The
	 * fault is declined and reaches this program as a note - and because
	 * a handler is registered, the note is delivered to it rather than
	 * killing the program outright; the handler catches its own fault.
	 */
	notify(nhandler);
	print("legacy: registered a note handler; now reading a bad address on purpose\n");
	{
		volatile int *bad = (volatile int*)0;
		int x = *bad;
		USED(x);
	}
	print("legacy: BUG: still running after the bad read - the note was not delivered\n");
	exits(nil);
}
