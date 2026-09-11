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
/* set by the note handler when alarm(2)'s note arrives */
static volatile int galarm;

/*
 * Who this process is, for the note handler to say.  A fork copies it,
 * so each process of the demonstration names itself and a note posted
 * to a whole group can be told apart in the log.
 */
static char *gwho = "legacy";

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
	if(strncmp(msg, "alarm", 5) == 0){
		/* alarm(2)'s note: the kernel's clock, not a fault and not the buddy's */
		galarm = 1;
		print("legacy: my note handler got the alarm note I asked for: \"%s\"; noted(NCONT)\n", msg);
		noted(NCONT);
	}
	if(strncmp(msg, "interrupt", 9) == 0){
		/* postnote(2)'s note, from the process that started this one */
		print("%s: my note handler got the note posted to it: \"%s\"; exiting on it\n", gwho, msg);
		exits("interrupted");
	}
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
static char *gheap;		/* a buffer on the heap, for the RFMEM sharing check */

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
			rerrstr(ebuf, sizeof ebuf);
			print("legacy: remove of /n/p9test refused: \"%s\"\n", ebuf);
		}
		/*
		 * And a call that must fail, for the error itself: errstr
		 * crosses the buddy or it does not, and a call that succeeds
		 * says nothing about that.  The store used to refuse every
		 * remove and this was that refusal; now that it takes one,
		 * removing a name that is not there is the refusal.
		 */
		if(remove("/n/nosuchfile") < 0){
			char ebuf[ERRMAX];
			rerrstr(ebuf, sizeof ebuf);	/* the real reason, over the buddy's errstr */
			print("legacy: remove refused, errstr from the buddy: \"%s\"\n", ebuf);
		} else
			print("legacy: remove of a name that is not there was not refused\n");
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
				/*
				 * And take it off again.  unmount(nil, "/mnt")
				 * is Plan 9's "everything mounted there": the
				 * name space is this container's own, so what
				 * goes is this container's mount and no other's,
				 * and the proof is that the file reachable a
				 * moment ago is not reachable now.
				 */
				if(unmount(nil, "/mnt") < 0)
					print("legacy: unmount /mnt failed\n");
				else if(open("/mnt/n/hello", OREAD) >= 0)
					print("legacy: BUG: /mnt/n/hello still readable after unmount\n");
				else
					print("legacy: unmounted /mnt; /mnt/n/hello is no longer reachable, which is what unmount means\n");
			}
			close(fd);
		}
	}

	print("legacy: the buddy answered every trap\n");

	/*
	 * The four calls beyond the file traps, which rio's libc uses and
	 * this program had never asked for.  Two of them are the buddy's,
	 * because a working directory is a name-space thing; two are the
	 * kernel's, because a clock and a place to block are not files.
	 */
	{
		vlong t0, t1;
		int rfd, i;

		/*
		 * chdir(2): the buddy's, and the container's own.  After it, a
		 * relative name resolves against /n here and against whatever
		 * directory another container chose there - which is why the
		 * buddy keeps a working directory per container rather than
		 * setting its worker's.
		 */
		if(chdir("/n") < 0)
			print("legacy: chdir /n failed\n");
		else if((rfd = open("hello", OREAD)) < 0)
			print("legacy: chdir'd to /n but the relative name hello did not open\n");
		else {
			n = read(rfd, buf, sizeof buf - 1);
			if(n < 0)
				n = 0;
			buf[n] = 0;
			close(rfd);
			print("legacy: chdir'd to /n and opened the relative name hello, which reads: \"%s\"\n", buf);
		}

		/*
		 * And the working directory is the container's, not the
		 * buddy's worker's.  A fork inherits it - the child opens the
		 * same relative name and gets the same file - and then the
		 * child chdirs somewhere else of its own, which must not move
		 * the parent: the two run their calls on the same four shared
		 * workers, so if the directory were the worker's the second
		 * open here would resolve wherever the child last went.
		 */
		{
			int pid, cfd;
			char abuf[128];

			pid = rfork(RFPROC);
			if(pid == 0){
				cfd = open("hello", OREAD);
				if(cfd < 0)
					print("legacy: BUG: the forked child did not inherit the working directory - hello did not open\n");
				else {
					close(cfd);
					print("legacy: the forked child inherited the working directory: it opened the relative name hello too\n");
				}
				if(chdir("/") < 0)
					print("legacy: the forked child could not chdir to /\n");
				else if((cfd = open("n/hello", OREAD)) < 0)
					print("legacy: BUG: the child chdir'd to / but n/hello did not open\n");
				else {
					close(cfd);
					print("legacy: and the child chdir'd to / on its own, where the relative name is n/hello\n");
				}
				_exits(nil);
			}
			if(pid > 0){
				if((n = await(abuf, sizeof abuf - 1)) > 0)
					abuf[n] = 0;
				if((cfd = open("hello", OREAD)) < 0)
					print("legacy: BUG: my working directory moved when my child chdir'd - hello no longer opens\n");
				else {
					close(cfd);
					print("legacy: and my own working directory did not move when my child chdir'd: hello still opens here\n");
				}
			}
		}

		/*
		 * nsec(2): the machine's clock, answered in the kernel.  Two
		 * readings around a sleep, so that what is shown is the clock
		 * running and not a constant.
		 */
		t0 = nsec();
		sleep(50);
		t1 = nsec();
		if(t1 > t0)
			print("legacy: nsec() ran forward %lld milliseconds over a 50 millisecond sleep\n", (t1 - t0)/1000000);
		else
			print("legacy: BUG: nsec() did not run forward (%lld then %lld)\n", t0, t1);

		/*
		 * alarm(2): ask the kernel for a note in 150 milliseconds and
		 * wait for it.  The note is delivered to the handler, which
		 * continues with noted(NCONT), and the flag it set is what this
		 * sees.  The wait is a bounded number of short sleeps rather
		 * than one long one, so a lost note ends the wait rather than
		 * hanging the boot.
		 */
		notify(nhandler);
		galarm = 0;
		alarm(150);
		for(i = 0; i < 40 && !galarm; i++)
			sleep(20);
		alarm(0);
		if(galarm)
			print("legacy: alarm(150) delivered its note and I woke to it\n");
		else
			print("legacy: BUG: alarm(150) never delivered a note\n");

		/*
		 * rendezvous(2): the one call of the four that needs two
		 * processes in one address space.  A thread is forked with
		 * RFMEM and meets this one on a tag, each handing the other a
		 * word; libthread's proccreate is this, and rio's six
		 * proccreate calls are why it is here.
		 */
		{
			int tid;
			void *got;

			/*
			 * And the part of "one address space" that the bss
			 * check further down does not reach: the heap.  A
			 * buffer this process allocated before the fork -
			 * memory sbrk grew, not memory the program was loaded
			 * with - is written by the thread and read back here.
			 * The allocator of a program that forks this way keeps
			 * its arena there, so if that memory were copied
			 * rather than shared, two processes would each be
			 * allocating out of what they both believed was
			 * theirs.
			 */
			if(gheap == nil)
				gheap = malloc(64);
			if(gheap != nil)
				strcpy(gheap, "written by the parent");
			tid = rfork(RFPROC|RFMEM);
			if(tid < 0)
				print("legacy: rfork(RFPROC|RFMEM) for the rendezvous failed\n");
			else if(tid == 0){
				if(gheap != nil)
					strcpy(gheap, "written by the thread, in the address space they share");
				rendezvous((void*)0x9001, (void*)0x1234);
				_exits(nil);
			} else {
				char abuf[128];

				got = rendezvous((void*)0x9001, (void*)0x5678);
				if(got == (void*)0x1234)
					print("legacy: rendezvous on tag 0x9001 met my thread and took the word it left: %#p\n", got);
				else
					print("legacy: BUG: rendezvous returned %#p, not the word my thread left\n", got);
				if((n = await(abuf, sizeof abuf - 1)) > 0){
					abuf[n] = 0;
					print("legacy: reaped the thread I rendezvoused with\n");
				}
				if(gheap != nil){
					if(strcmp(gheap, "written by the thread, in the address space they share") == 0)
						print("legacy: and the heap is shared too: what my thread wrote into a buffer malloc gave me reads back here as \"%s\"\n", gheap);
					else
						print("legacy: BUG: the heap buffer still reads \"%s\" - sbrk memory is not shared across RFMEM\n", gheap);
				}
			}
		}
	}

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
	 * postnote(2): the last of the calls rio's libc uses that this
	 * personality did not answer, and it is not a system call - libc
	 * opens /proc/<pid>/note and writes the note's text.  So it is a
	 * file, served here by the personality that holds this program's
	 * name space, and the write turns into one request to the kernel,
	 * which holds the processes.  This is what a window system does to
	 * the command in a window when the delete key is struck.
	 */
	{
		int pid, n2, k;
		char abuf[128];

		pid = rfork(RFPROC);
		if(pid == 0){
			/*
			 * The child: a note handler of its own, then it waits
			 * to be interrupted.  The handler is nhandler, which
			 * this program registers below - registered here too,
			 * since a fork's child inherits the handler only if
			 * the parent had one already, and this one is first.
			 */
			gwho = "legacy child";
			notify(nhandler);
			for(k = 0; k < 200; k++)
				sleep(20);
			print("legacy: BUG: the child was never interrupted\n");
			_exits(nil);
		}
		if(pid < 0)
			print("legacy: rfork(RFPROC) for the note test failed\n");
		else {
			sleep(100);		/* let it reach its handler-registered wait */
			if(postnote(PNPROC, pid, "interrupt") < 0){
				char eb[ERRMAX];

				eb[0] = 0;
				errstr(eb, sizeof eb);
				print("legacy: BUG: postnote to my own child %d was refused: %s\n", pid, eb);
			}
			else
				print("legacy: posted the note \"interrupt\" to the child I started, container %d, by writing /proc/%d/note\n", pid, pid);
			/*
			 * And a container this one did not start: the client,
			 * container 1, which is not a child of this one.  The
			 * kernel refuses it - a container may interrupt what it
			 * started and nothing else.
			 */
			if(postnote(PNPROC, 1, "interrupt") < 0)
				print("legacy: and posting a note to container 1, which I did not start, was refused - authority for a note is having started it\n");
			else
				print("legacy: BUG: I was allowed to note a container I did not start\n");
			if((n2 = await(abuf, sizeof abuf - 1)) > 0){
				abuf[n2] = 0;
				print("legacy: reaped the child I interrupted; its wait message: \"%s\"\n", abuf);
			} else
				print("legacy: await() after the note returned nothing\n");
		}

		/*
		 * And the group form, which is the one rio uses: a note to a
		 * container and to everything that container started.  The
		 * child here starts one of its own first, so the walk has
		 * something to find - a window's command with something under
		 * it, which is the shape a window system interrupts.
		 */
		pid = rfork(RFPROC);
		if(pid == 0){
			int gk;

			gwho = "legacy child";
			notify(nhandler);
			gk = rfork(RFPROC);
			if(gk == 0){
				gwho = "legacy grandchild";
				notify(nhandler);
				for(k = 0; k < 200; k++)
					sleep(20);
				print("legacy: BUG: the grandchild was never interrupted\n");
				_exits(nil);
			}
			for(k = 0; k < 200; k++)
				sleep(20);
			print("legacy: BUG: the child of the group was never interrupted\n");
			_exits(nil);
		}
		if(pid < 0)
			print("legacy: rfork(RFPROC) for the group note test failed\n");
		else {
			sleep(300);	/* let the child fork its own and both reach their handlers */
			if(postnote(PNGROUP, pid, "interrupt the group") < 0)
				print("legacy: BUG: postnote to the group of container %d was refused\n", pid);
			else
				print("legacy: posted the note \"interrupt the group\" to container %d and everything it started, by writing /proc/%d/notepg\n", pid, pid);
			if((n2 = await(abuf, sizeof abuf - 1)) > 0){
				abuf[n2] = 0;
				print("legacy: reaped the group's head; its wait message: \"%s\"\n", abuf);
			} else
				print("legacy: await() after the group note returned nothing\n");
		}
	}

	/*
	 * The identity a process has for itself.  getpid(2) on Plan 9 is a
	 * read of one word of the Tos the kernel filled, and a threaded
	 * program keeps the number it read there and posts notes to it
	 * when it shuts down - libthread's threadexitsall does exactly
	 * that, which is what rio does at the end.  So the number read
	 * there has to be the same kind of number a note is addressed by,
	 * which is a container's identity: the one rfork gave the parent
	 * and the one /proc/<n>/note takes.  The child reads its own and
	 * writes it up a pipe; the parent compares it with the id rfork
	 * handed back and then posts a note to the child's own number.  If
	 * the two are different kinds of number the note goes to something
	 * else, or to nothing.
	 */
	{
		int pid, k, n2, selfpid, pfd[2];
		char pbuf[32], abuf[128];

		if(pipe(pfd) < 0)
			print("legacy: pipe() for the self-pid test failed\n");
		else {
			pid = rfork(RFPROC);
			if(pid == 0){
				gwho = "legacy self-pid child";
				notify(nhandler);
				n2 = snprint(pbuf, sizeof pbuf, "%d", getpid());
				write(pfd[1], pbuf, n2);
				for(k = 0; k < 200; k++)
					sleep(20);
				print("legacy: BUG: the self-pid child was never interrupted\n");
				_exits(nil);
			}
			if(pid < 0)
				print("legacy: rfork(RFPROC) for the self-pid test failed\n");
			else {
				selfpid = -1;
				/*
				 * Bounded.  Without RFFDG the child shares
				 * this descriptor table, so the pipe's write
				 * end is open here too and a child that never
				 * reached its write would leave this read
				 * waiting on a writer that is this process.
				 * The alarm note interrupts the read and
				 * nhandler continues from it, so a failure
				 * here prints a BUG instead of stopping the
				 * program and every criterion after it.
				 */
				alarm(5000);
				n2 = read(pfd[0], pbuf, sizeof pbuf - 1);
				alarm(0);
				if(n2 > 0){
					pbuf[n2] = 0;
					selfpid = atoi(pbuf);
				}
				print("legacy: the child I started is id %d to me, and getpid() reads %d to it\n",
					pid, selfpid);
				if(selfpid != pid)
					print("legacy: BUG: a process's own pid and the id its parent was given are different numbers\n");
				if(postnote(PNPROC, selfpid, "interrupt") < 0){
					char eb[ERRMAX];

					eb[0] = 0;
					errstr(eb, sizeof eb);
					print("legacy: BUG: the note to %d, the number the child read for itself, was refused: %s\n",
						selfpid, eb);
				} else
					print("legacy: posted a note to %d, the number the child read for itself with getpid(), and it is the same number rfork gave me\n",
						selfpid);
				if((n2 = await(abuf, sizeof abuf - 1)) > 0){
					abuf[n2] = 0;
					print("legacy: reaped the child I noted by its own pid; its wait message: \"%s\"\n", abuf);
				} else
					print("legacy: await() after the self-pid note returned nothing\n");
			}
			close(pfd[0]);
			close(pfd[1]);
		}
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
			if(getpid() == moved)
				print("legacy: and getpid() reads %d after the move too - the pid a program reads for itself followed it into the new container\n", moved);
			else
				print("legacy: BUG: after the move getpid() reads %d but I am container %d\n", getpid(), moved);
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
