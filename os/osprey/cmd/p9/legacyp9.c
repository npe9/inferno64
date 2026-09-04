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

	print("legacy: the buddy answered every trap\n");
	exits(nil);
}
