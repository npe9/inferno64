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
	if(strncmp(msg, "osprey:", 7) == 0){
		/* not a fault: continue where the note interrupted */
		print("legacy: my note handler got a note that is not a fault: \"%s\"; noted(NCONT)\n", msg);
		noted(NCONT);
	}
	print("legacy: my note handler caught the fault: \"%s\"\n", msg);
	exits("note handled");
}

/* shared with a thread made by rfork(RFPROC|RFMEM): in the data segment, so both see it */
static volatile int gshared, gstop;

/* forty pages of the bss, each written before the crossing: pages that differ from the image, which is what a crossing carries */
enum { Ndirty = 40 };
static char dirty[Ndirty*4096];

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
	 * Move: ask the kernel to carry this process, running, into a
	 * container of its own - resume, not restart.  The call does not
	 * return to this container; it returns, with the new container's
	 * identity, to the same process in the new one, its stack and
	 * registers as they were.  A local variable and a descriptor opened
	 * before the move are read after it, which is what proves the state
	 * crossed rather than the program starting again.
	 */
	{
		extern long ospreyxcall(int, uvlong*, long);
		uvlong args[5];
		volatile int keep = 42;
		char mbuf[128];
		int mfd, moved;
		long mn;

		/*
		 * Before the move: ask the kernel to set the time of day.  A
		 * legacy container does not hold the console, so the kernel
		 * refuses - the authority is a capability, not everyone's.
		 */
		args[0] = 1000000000; args[1] = args[2] = args[3] = args[4] = 0;
		if((int)ospreyxcall(23, args, 1) < 0)		/* ReqSettime */
			print("legacy: the kernel refused to let me set the time of day - I do not hold the console\n");
		else
			print("legacy: BUG: the kernel let a legacy container set the time of day\n");

		mfd = open("/n/hello", OREAD);
		args[0] = args[1] = args[2] = args[3] = args[4] = 0;
		print("legacy: asking the kernel to move me, running, to a container of my own\n");
		moved = (int)ospreyxcall(24, args, 0);	/* ReqMove; only the moved process returns */
		if(moved > 0){
			mn = mfd >= 0 ? read(mfd, mbuf, sizeof mbuf - 1) : -1;
			if(mn < 0)
				mn = 0;
			mbuf[mn] = 0;
			print("legacy: I was moved: I am container %d now, my stack still holds %d, and the fd I opened before the move reads: \"%s\"\n",
				moved, keep, mbuf);
		} else
			print("legacy: the kernel would not move me (%d)\n", moved);
		if(mfd >= 0)
			close(mfd);
		/*
		 * And as a group: a thread sharing this address space, counting
		 * in shared memory, is carried along with the move - stopped,
		 * its registers and stack taken, resumed in a container of its
		 * own sharing the new one's memory - and goes on counting after
		 * it, which the parent sees.  Then it is stopped by a shared
		 * flag and reaped: the moved parent is still its parent.
		 */
		{
			int tid, n1, n2, i;
			char abuf[128];
			int an;

			gshared = 0;
			gstop = 0;
			tid = rfork(RFPROC|RFMEM);
			if(tid == 0){
				while(!gstop){
					gshared++;
					sleep(1);
				}
				exits("thread done");
			}
			for(i = 0; i < 20; i++)
				sleep(1);
			n1 = gshared;
			args[0] = 1;				/* with the group */
			args[1] = args[2] = args[3] = args[4] = 0;
			moved = (int)ospreyxcall(24, args, 1);
			for(i = 0; i < 20; i++)
				sleep(1);
			n2 = gshared;
			if(moved > 0 && n2 > n1)
				print("legacy: moved with my thread: I am container %d now; the thread had counted to %d before the move and to %d after it - it came along, still running in the shared memory\n", moved, n1, n2);
			else
				print("legacy: the group move did not carry the thread (moved %d, counted %d then %d)\n", moved, n1, n2);
			gstop = 1;
			an = await(abuf, sizeof abuf - 1);
			if(an >= 0){
				abuf[an] = 0;
				print("legacy: reaped my thread after the move; its wait message: \"%s\"\n", abuf);
			} else
				print("legacy: await() after the group move returned nothing\n");
		}
		/*
		 * And over the wire: ask the kernel to carry this process to
		 * the other machine.  If there is one, this line prints on its
		 * console - the same program, going on from this call with its
		 * stack as it was, on another kernel; if there is none, the
		 * kernel says so and the program stays.
		 */
		{
			int tid, n1, n2, i, an, hfd, sib, intact;
			char abuf[128], hbuf[128];
			long hn;

			/*
			 * What crosses with me: a descriptor opened before the
			 * crossing, read after it there; forty pages written
			 * here, which are the pages that differ from my image -
			 * the image itself the far buddy has; and a second
			 * process, forked now, that asks to cross at the same
			 * moment I do, alone.
			 */
			hfd = open("/n/hello", OREAD);
			for(i = 0; i < Ndirty; i++)
				dirty[i*4096 + 100] = 'a' + (i % 26);
			sib = rfork(RFPROC|RFFDG);
			if(sib == 0){
				for(i = 0; i < 20; i++)
					sleep(1);
				args[0] = 2;			/* to the wire, alone */
				args[1] = args[2] = args[3] = args[4] = 0;
				moved = (int)ospreyxcall(24, args, 1);
				if(moved > 0){
					hn = hfd >= 0 ? read(hfd, hbuf, sizeof hbuf - 1) : -1;
					if(hn < 0)
						hn = 0;
					hbuf[hn] = 0;
					intact = 0;
					for(i = 0; i < Ndirty; i++)
						if(dirty[i*4096 + 100] == 'a' + (i % 26))
							intact++;
					print("legacy: the second process crossed at the same time: I am container %d here, my %d dirty pages came with me (%d intact), and my descriptor opened before the crossing reads: \"%s\"\n",
						moved, Ndirty, intact, hbuf);
				} else
					print("legacy: the second process was not taken (%d)\n", moved);
				exits("second done");
			}
			gshared = 0;
			gstop = 0;
			tid = rfork(RFPROC|RFMEM);		/* a thread to go with me */
			if(tid == 0){
				/*
				 * Blocked for good, as far as a move that waits for
				 * user mode is concerned: a minute's sleep.  The
				 * move interrupts it - the sleep returns -1 - and
				 * the thread goes on counting where it lands.
				 */
				int longsleep = 1;

				while(!gstop){
					gshared++;
					if(longsleep){
						if(sleep(60*1000) < 0){
							longsleep = 0;
							print("legacy thread: my minute's sleep was interrupted for the move; I go on counting where I am\n");
						}
					} else
						sleep(1);
				}
				exits("thread done");
			}
			for(i = 0; i < 20; i++)
				sleep(1);
			n1 = gshared;
			args[0] = 3;				/* to the wire, with the group */
			args[1] = args[2] = args[3] = args[4] = 0;
			print("legacy: asking the kernel to carry me and my thread over the wire to the other machine\n");
			moved = (int)ospreyxcall(24, args, 1);
			for(i = 0; i < 20; i++)
				sleep(1);
			n2 = gshared;
			if(moved > 0 && n2 > n1){
				print("legacy: I was carried over the wire to the other machine with my thread: I am container %d here, my stack still holds %d, and the thread had counted to %d before the crossing and to %d after it - it came with me, still running in the shared memory\n", moved, keep, n1, n2);
				hn = hfd >= 0 ? read(hfd, hbuf, sizeof hbuf - 1) : -1;
				if(hn < 0)
					hn = 0;
				hbuf[hn] = 0;
				intact = 0;
				for(i = 0; i < Ndirty; i++)
					if(dirty[i*4096 + 100] == 'a' + (i % 26))
						intact++;
				print("legacy: and what I had came with me: my %d dirty pages (%d intact), and the descriptor I opened before the crossing reads here: \"%s\"\n",
					Ndirty, intact, hbuf);
				/*
				 * And my name space crossed: /hello is the bind of /n
				 * onto / I made in my private name space before the
				 * crossing, so if the bind came with me it names
				 * /n/hello here.  The far buddy rebuilt the name space
				 * and replayed the bind.
				 */
				{
					int bf = open("/hello", OREAD);
					char bbuf[128];
					long bn = bf >= 0 ? read(bf, bbuf, sizeof bbuf - 1) : -1;
					if(bn < 0)
						bn = 0;
					bbuf[bn] = 0;
					if(bf >= 0)
						close(bf);
					if(bf >= 0)
						print("legacy: and my name space came with me: /hello, the bind of /n onto / I made before the crossing, reads here: \"%s\"\n", bbuf);
					else
						print("legacy: BUG: /hello is not visible after the crossing - the name space did not come\n");
				}
			} else if(moved > 0)
				print("legacy: I was carried over the wire but my thread did not come with me (counted %d then %d)\n", n1, n2);
			else
				print("legacy: no other machine took me (%d); I stay\n", moved);
			gstop = 1;
			an = await(abuf, sizeof abuf - 1);
			if(an >= 0){
				abuf[an] = 0;
				print("legacy: reaped my thread after the crossing; its wait message: \"%s\"\n", abuf);
			} else
				print("legacy: await() after the crossing returned nothing\n");
		}
	}

	/*
	 * Register a note handler, then read a bad address on purpose.  The
	 * fault is declined and reaches this program as a note - and because
	 * a handler is registered, the note is delivered to it rather than
	 * killing the program outright; the handler catches its own fault.
	 */
	notify(nhandler);
	/*
	 * A note that is not a fault first: ask the kernel to post one.  It
	 * is delivered to the handler on the way back from the call, the
	 * handler returns with noted(NCONT), and this program resumes at
	 * the instruction after the call - the continuation a fault's note
	 * cannot show, since its address stays bad.
	 */
	{
		extern long ospreyxcall(int, uvlong*, long);
		uvlong args[5];
		volatile int after = 0;

		args[0] = args[1] = args[2] = args[3] = args[4] = 0;
		ospreyxcall(25, args, 0);		/* ReqNote */
		after = 7;
		print("legacy: resumed after the note - noted(NCONT) brought me back to the instruction after the call (%d)\n", after);
	}
	print("legacy: registered a note handler; now reading a bad address on purpose\n");
	{
		volatile int *bad = (volatile int*)0;
		int x = *bad;
		USED(x);
	}
	print("legacy: BUG: still running after the bad read - the note was not delivered\n");
	exits(nil);
}
