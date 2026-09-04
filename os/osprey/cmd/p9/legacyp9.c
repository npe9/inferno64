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

		/*
		 * And mount: open the personality's own exportfs (#X), a 9P
		 * connection, mount it onto /mnt, and read a file through it - the
		 * mount is this container's own, in the name space it forked.
		 */
		fd = open("#X", ORDWR);
		if(fd < 0)
			print("legacy: could not open #X to mount\n");
		else {
			if(mount(fd, -1, "/mnt", MREPL, "") < 0)
				print("legacy: mount #X onto /mnt failed\n");
			else {
				int hfd = open("/mnt/n/hello", OREAD);
				if(hfd < 0)
					print("legacy: /mnt/n/hello not readable after the mount\n");
				else {
					n = read(hfd, buf, sizeof buf - 1);
					if(n < 0)
						n = 0;
					buf[n] = 0;
					close(hfd);
					print("legacy: mounted #X at /mnt and read /mnt/n/hello over 9P: \"%s\"\n", buf);
				}
			}
			close(fd);
		}
	}

	print("legacy: the buddy answered every trap\n");

	/*
	 * rfork(RFPROC): fork the process itself.  The buddy cannot do this -
	 * a container is the kernel's to make - so the kernel forks the
	 * container: a private address space (text shared, data and bss copied
	 * copy-on-write, its own stack), entered at this same point.  rfork
	 * returns 0 in the child and the child's id in the parent, so the two
	 * are separate flows of control.  The parent opens a file first; the
	 * child inherits the descriptor (the kernel has the buddy clone the
	 * container's descriptor table at the fork) and reads through it, which
	 * proves the fork carried the open files.  The child then exits; the
	 * parent goes on to the note test.
	 */
	{
		int ffd = open("/n/hello", OREAD);
		int pid = rfork(RFPROC);
		if(pid == 0){
			char cbuf[128];
			int hfd;
			long cn = ffd >= 0 ? read(ffd, cbuf, sizeof cbuf - 1) : -1;
			if(cn > 0){
				cbuf[cn] = 0;
				print("legacy: I am the forked child; rfork(RFPROC) returned 0 to me, and I read the inherited fd: \"%s\"\n", cbuf);
			} else
				print("legacy: I am the forked child, but could not read the inherited fd\n");
			/*
			 * And the name space: /hello is the parent's own bind (of /n
			 * into /), which exists only in the private name space the
			 * parent rforked.  Opening it proves the fork carried that name
			 * space too, not just the descriptors.
			 */
			hfd = open("/hello", OREAD);
			if(hfd >= 0){
				print("legacy: the forked child opened /hello, a name only in the parent's rforked name space - the fork carried the name space\n");
				close(hfd);
			} else
				print("legacy: the forked child could not see /hello - the name space did not cross\n");
			exits("forked child");
		} else if(pid < 0)
			print("legacy: rfork(RFPROC) failed\n");
		else {
			char abuf[128];
			int an;
			print("legacy: rfork(RFPROC) forked a child, id %d; I am the parent\n", pid);
			/*
			 * await(2) directly, not wait(): this minimal binary has no
			 * malloc, and await fills a buffer the caller gives it.  The
			 * message is the child's pid, its times, and its quoted exit
			 * status - the fork's other end, the parent reaping the child.
			 */
			an = await(abuf, sizeof abuf - 1);
			if(an >= 0){
				abuf[an] = 0;
				print("legacy: I awaited and reaped my forked child; its wait message: \"%s\"\n", abuf);
			} else
				print("legacy: await() returned nothing\n");
		}
		if(ffd >= 0)
			close(ffd);
	}

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
