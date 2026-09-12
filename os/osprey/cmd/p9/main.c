#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ring9p.h"
#include "p9file.h"
#include "p9lib.h"		/* the bases a relocatable module can be laid at */

extern void p9init(void);
extern void exits(char*);
extern void p9clientnet(void);		/* p9ip.c: the client container's own stack, over the ring wire */
void p9server(char *arg);
void p9paircli(void);
extern void memimageinit(void);	/* libmemdraw: the shared masks a draw reads */
int p9riodemo;		/* *riodemo= in plan9.ini: also exec rio and leave it running */
int p9legacydemo;	/* *legacydemo= in plan9.ini: also run the unmodified Plan 9 binary, which ends the task */
int p9legacyserve = 1;	/* and whether to serve its system calls: *legacycontrol= runs it without, which is the control */
void p9server(char *arg);
void p9setup(void);

/*
 * Bring up a Plan 9 name space as user code and walk it: attach the root
 * device, open "/" and read it, then prove the name space is a name
 * space and not one device - mount a second device (the environment) and
 * resolve a name with no '#' in it across the mount table into it.  All
 * of attach, walk, open, read, cmount and the union walk run through
 * chan.c and real devices, in a user process on the microkernel.
 */
/*
 * Bring up the name space every role shares: attach the root device, and
 * give the process the environment and file-descriptor groups the devices
 * and the fd layer need.
 */
void
p9setup(void)
{
	p9init();
	/*
	 * How much a pipe holds before its writer waits for its reader.
	 * Nothing set this, so it was zero: every write filled the queue by
	 * definition and the writer slept until the far end drained it, which
	 * worked but is not what a pipe is.  This is the size Plan 9 uses.
	 */
	conf.pipeqsize = 32*1024;
	print("p9: a pipe holds %lud bytes before its writer waits for its reader\n", conf.pipeqsize);
	chandevreset();
	/*
	 * How much room there is between the top of the region loaded
	 * programs live in and the address this personality starts at.
	 *
	 * This used to read the other way round - the end of this image
	 * against the first program's base - because the personality was
	 * below the programs and grew up towards them, and when it reached
	 * them the machine died at touser with nothing printed.  It is
	 * above them now, at P9selfbase, so that an ordinary Plan 9 binary
	 * can have UTZERO; the quantity that can close is the one below.
	 * Left as it was it said MY OWN IMAGE ENDS AT ... WHICH IS PAST ...
	 * at every boot, in capitals, and was right about the arithmetic
	 * and wrong about what it meant.
	 */
	{
		extern char end[];
		uvlong e = (uvlong)(uintptr)end;
		uvlong me = (uvlong)(uintptr)p9setup;
		uvlong progtop = (uvlong)P9relocbase +
			(uvlong)Nrelocslot * (uvlong)P9relocslot;

		/*
		 * Where this program actually is, against where p9lib.h says
		 * it is.  The two are set in different files - build.sh's -T
		 * and P9selfbase - and nothing but this would notice them
		 * drifting apart: the loader refuses a program that would
		 * land on the personality, and it works that out from
		 * P9selfbase, so a stale P9selfbase would let a program be
		 * laid on top of this one and the machine would die with
		 * nothing to say.  p9setup is a text address, so it is at or
		 * above the base and not far above it.
		 */
		if(me < (uvlong)P9selfbase || me - (uvlong)P9selfbase > 64*1024*1024)
			print("p9: I AM LINKED AT %#llux BUT p9lib.h SAYS %#llux: "
				"build.sh's -T and P9selfbase disagree, and the loader's "
				"check on where a program may go is reading the wrong "
				"address\n", me, (uvlong)P9selfbase);
		else
			print("p9: I am at %#llux, the base p9lib.h names (%#llux) plus "
				"%llud bytes of my own text\n",
				me, (uvlong)P9selfbase, me - (uvlong)P9selfbase);

		if(progtop > (uvlong)P9selfbase)
			print("p9: THE PROGRAM REGION ENDS AT %#llux, WHICH IS PAST %#llux, "
				"WHERE I AM: a program laid in the top slots would be laid "
				"on me, and the map in p9lib.h has outgrown the gap\n",
				progtop, (uvlong)P9selfbase);
		else
			print("p9: programs live below %#llux, %llud bytes below me, and "
				"my own image is %llud bytes of text, data and bss\n",
				progtop, (uvlong)P9selfbase - progtop, e - (uvlong)P9selfbase);
	}
	up->pgrp = newpgrp();
	up->egrp = smalloc(sizeof(Egrp));
	up->egrp->ref = 1;
	up->fgrp = smalloc(sizeof(Fgrp));
	up->fgrp->ref = 1;
	up->slash = namec("#/", Atodir, 0, 0);
	pathclose(up->slash->path);
	up->slash->path = newpath("/");
	up->dot = cclone(up->slash);
	chandevinit();
	quotefmtinstall();		/* %q, which namelenerror() names files with */
	/*
	 * The time device onto /dev, so that a program's nsec(2) - which is
	 * a read of /dev/bintime and not a system call - finds the file.
	 * The name space a legacy program runs in is this one, so the file
	 * has to be here for the buddy to answer an open of it.
	 */
	if(!waserror()){
		p9bind("#T", "/dev", MAFTER);
		poperror();
		print("p9: #T bound onto /dev; nsec(2) reads /dev/bintime, the kernel's clock\n");
	} else
		print("p9: could not bind #T onto /dev: %s\n", up->errstr);
	/*
	 * The environment onto /env, where a program's getenv(2) and
	 * putenv(2) look for it: both are opens of /env/<name>, not system
	 * calls, so the device has to be under that name in the name space
	 * a container's calls are resolved in.  rio puts the name of the
	 * pipe it posted in /srv there, under wsys, which is how a command
	 * in a window finds the window system that started it.
	 */
	if(!waserror()){
		p9bind("#e", "/env", MREPL|MCREATE);
		poperror();
		print("p9: #e bound onto /env; getenv(2) and putenv(2) are opens of /env/<name>\n");
	} else
		print("p9: could not bind #e onto /env: %s\n", up->errstr);
	/*
	 * The input device onto /dev, so that a program's /dev/kbd and
	 * /dev/mouse are the keyboard and mouse this personality's own
	 * user-space i8042 driver is reading.  rio wants both, and both
	 * are files here rather than a segment because on this
	 * configuration the microkernel hands the controller to this
	 * container as two interrupt notifications, not as the polled
	 * rings the full personality exposes - see devinput.c.
	 */
	if(!waserror()){
		p9bind("#m", "/dev", MAFTER);
		poperror();
		print("p9: #m bound onto /dev; /dev/kbd and /dev/mouse are the i8042 driver's, in user space\n");
	} else
		print("p9: could not bind #m onto /dev: %s\n", up->errstr);
	/*
	 * And the draw device onto /dev beside them, so a program's
	 * /dev/draw is this personality's own.  It is the kernel's
	 * devdraw.c, compiled into this program (devdrawp9.c) rather than
	 * run as a server in a container of its own: on this personality a
	 * draw is a call in the drawing program's own address space, which
	 * is the whole of what the library-operating-system track is for.
	 * memimageinit is memdraw's - the shared masks every draw reads -
	 * and the device never calls it, so it is called here.
	 */
	if(!waserror()){
		memimageinit();
		p9bind("#i", "/dev", MAFTER);
		poperror();
		print("p9: #i bound onto /dev; /dev/draw is the kernel's draw device, compiled into this personality\n");
	} else
		print("p9: could not bind #i onto /dev: %s\n", up->errstr);
	/*
	 * And /boot onto /bin, because rio does not ask what the shell is
	 * called: winshell execs "/bin/rc", the name written into rio.
	 * What answers to it here is /boot/sh, this personality's own small
	 * shell, registered under that name as well - the same bytes under
	 * two names, not a copy.  It is not rc and does not pretend to be:
	 * one command a line, words at blanks, stages at |, no quoting and
	 * no variables.  What it is is a shell a window can run.
	 */
	if(!waserror()){
		p9bind("/boot", "/bin", MREPL);
		poperror();
		print("p9: /boot bound onto /bin; /bin/rc is /boot/sh, which is the shell rio's windows get\n");
	} else
		print("p9: could not bind /boot onto /bin: %s\n", up->errstr);
	/*
	 * And the dup device onto /fd.  libthread's procexec - which is how
	 * rio starts the command in a window - opens /fd/<n> to get a second
	 * channel on a pipe it just made, and without the device that open
	 * fails and no exec is ever attempted.  See devdup.c.
	 */
	if(!waserror()){
		p9bind("#d", "/fd", MREPL);
		poperror();
		print("p9: #d bound onto /fd; /fd/<n> is the calling container's descriptor n\n");
	} else
		print("p9: could not bind #d onto /fd: %s\n", up->errstr);
	/*
	 * And the note tree onto /proc, for the same reason: postnote(2) is
	 * a write to /proc/n/note, not a system call, so the file has to be
	 * in the name space a legacy program runs in.
	 */
	if(!waserror()){
		p9bind("#p", "/proc", MAFTER);
		poperror();
		print("p9: #p bound onto /proc; postnote(2) writes /proc/n/note, and the kernel posts it\n");
	} else
		print("p9: could not bind #p onto /proc: %s\n", up->errstr);
	/*
	 * And the service registry onto /srv.  The personality reaches it
	 * as #s and never needed the name, but a program does: lib9p's
	 * postsrv creates /srv/<name> and hands the pipe to whatever opens
	 * it, which is how a server started in one container is reachable
	 * from another.  Without the bind the create landed on the root
	 * device, which refuses it, and the draw server's postmountsrv
	 * failed with Eperm.  MCREATE, because a mount point without it is
	 * not a place a file may be made, which is the next thing the same
	 * create said: Enocreate.
	 */
	if(!waserror()){
		p9bind("#s", "/srv", MREPL|MCREATE);
		poperror();
		print("p9: #s bound onto /srv; a server posts its pipe there by name and another container mounts it\n");
	} else
		print("p9: could not bind #s onto /srv: %s\n", up->errstr);
	print("p9: name space up, root attached\n");
}

/*
 * One listing of "/", through a buffer of the caller's size, printing
 * each entry's name and length and handing back the length the entry
 * named "hello" carried.  It is a function because the same listing is
 * run three times below: once before anything is bound over an entry of
 * it, once after, and once through a buffer too small to hold the
 * entry the fixup grew - which is the rock's case.
 */
static int
lsunion(char *what, uchar *buf, long bufn, vlong *hellolen, int quiet)
{
	int dfd, nent, m;
	long dn;
	uchar *p, *e;
	Dir dir;
	char names[256];

	*hellolen = -1;
	nent = 0;
	dfd = p9open("/", OREAD);
	if(!quiet)
		print("p9: ls / (%s):\n", what);
	while((dn = p9read(dfd, buf, bufn)) > 0){
		p = buf;
		e = buf + dn;
		while(p < e){
			m = convM2D(p, (uint)(e - p), &dir, names);
			if(m <= 0)
				break;
			if(!quiet)
				print("p9:   %s %lld (%d bytes of entry)\n",
					dir.name, (vlong)dir.length, m);
			if(strcmp(dir.name, "hello") == 0)
				*hellolen = dir.length;
			nent++;
			p += m;
		}
	}
	p9close(dfd);
	return nent;
}

extern void p9execfile(void);	/* p9exec.c: the second program, as /boot/prog2 */
extern int p9exec(char *name, char **argv);	/* p9exec.c: read it through the name space and run it */

void
p9main(void)
{
	Chan *c, *ec, *tc, *mc;
	uchar buf[2048];
	long n;
	int mnttype;

	if(waserror()){
		print("p9: error: %s\n", up->errstr);
		exits("error");
	}
	p9execfile();		/* the second program, a file in this personality's own file system */
	p9setup();

	/*
	 * The handler installed above has to still be there now.  It was
	 * not: p9setup calls p9init, which set up->nerrlab = 0, and a count
	 * cleared is a handler thrown away - so everything below this line
	 * ran with nothing to catch anything, and an error raised anywhere
	 * in it longjmped to errlab[-1], whatever lay in memory before the
	 * array.  From the outside that is "fault at user pc 0xffffffff",
	 * which says neither what the error was nor where it came from; it
	 * took a file server departing mid-demonstration to show it at all.
	 * So say the depth, and prove the unwinding while at it: an error
	 * raised under a handler of its own is caught there and leaves the
	 * depth where it found it.
	 */
	{
		int depth, caught;

		depth = up->nerrlab;
		caught = 0;
		if(!waserror()){
			error("a deliberate error, to prove the unwinding");
			poperror();
		} else
			caught = 1;
		print("p9: the handler installed before setup is still in scope after it, %d deep; "
			"a deliberate error was caught %s, said \"%s\", and left the depth at %d\n",
			depth, caught ? "by the handler put over it" : "by nothing at all",
			up->errstr, up->nerrlab);
	}

	c = namec("/", Aopen, OREAD, 0);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: opened / and read %ld bytes of directory through the name space\n", n);
	cclose(c);

	/*
	 * A second device, mounted, and a name resolved across the mount
	 * table.  Give the process an environment group, create a file in
	 * the environment device by writing a value to it, mount that device
	 * onto the root, then open "/greeting" - a name with no device in it,
	 * which the union walk must carry from the root into the environment
	 * device - and read the value back.
	 */
	c = namec("#e/greeting", Acreate, OWRITE, 0666);
	devtab[c->type]->write(c, "hello osprey", 12, 0);
	cclose(c);
	print("p9: wrote a value into the environment device\n");

	ec = namec("#e", Atodir, 0, 0);
	cmount(ec, up->slash, MAFTER, "");
	cclose(ec);
	print("p9: mounted the environment device into the name space at /\n");

	c = namec("/greeting", Aopen, OREAD, 0);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: resolved /greeting through the mount table and read \"%.*s\"\n", (int)n, (char*)buf);
	cclose(c);

	/*
	 * A real 9P mount, over the microkernel ring.  The name space names
	 * files a server holds in a container of its own: open the transport
	 * (#L, which carries 9P across the ring - the marshalling and the
	 * mount client devmnt are the kernel's own, and the server is another
	 * user program, srv9p, in the delegated file-server container),
	 * attach the mount device to it (Tversion and Tattach travel the
	 * ring), and mount the server's root.  Then open "/hello", which
	 * devmnt walks and reads over 9P into the server; the channel is
	 * served by the mount device (#M), not the transport, and the bytes -
	 * held only in the server binary - come back across the ring.
	 */
	tc = namec("#L", Aopen, ORDWR, 0);
	mc = mntattach(tc, nil, "", 0);
	cclose(tc);
	cmount(mc, up->slash, MAFTER, "");
	cclose(mc);
	print("p9: attached and mounted a 9P server over the microkernel ring\n");

	mnttype = devno('M', 0);
	c = namec("/hello", Aopen, OREAD, 0);
	{
		/*
		 * What the mount agreed it may carry, against what the ring
		 * can actually hold.  devmnt sets a channel's iounit to the
		 * negotiated message size less 9P's header allowance, so this
		 * is the largest read the client will ask for in one message,
		 * and the R-message that answers it has to fit the reply
		 * region of the server's data area.  The server was told it
		 * had 8192 bytes of a 2048-byte region and advertised 8192 to
		 * match; nothing it serves could make a message that long, so
		 * nothing had gone wrong, and a file of three kilobytes would
		 * have run the answer into the ticket window past the region.
		 * It advertises what it has now, and the two numbers are
		 * printed together so they cannot drift apart unnoticed.
		 */
		extern long ring9p_replyroom(void);

		print("p9: the ring mount carries %lud bytes at a time, in a message region of %ld\n",
			c->iounit, ring9p_replyroom());
	}
	print("p9: /hello resolved across #M, served by device type=%d (mnt=%d)\n",
		c->type, mnttype);
	n = devtab[c->type]->read(c, buf, sizeof buf, 0);
	print("p9: read from the 9P server over the mount: \"%.*s\"\n", (int)n, (char*)buf);
	cclose(c);

	/*
	 * The file-descriptor layer: a program reaches the name space by
	 * small integers, not by holding Chans.  Open "/hello" - the file the
	 * 9P server holds across the ring - by name, read it by descriptor,
	 * and close the descriptor, all through the fd table (Fgrp) the way a
	 * Plan 9 program does.  The same fd layer names a local file too, so
	 * open "/greeting" from the environment device by descriptor as well.
	 */
	{
		int fd;
		long fn;

		fd = p9open("/hello", OREAD);
		fn = p9read(fd, buf, sizeof buf - 1);
		if(fn < 0) fn = 0;
		buf[fn] = 0;
		print("p9: fd %d read \"%.*s\" from /hello over the ring\n", fd, (int)fn, (char*)buf);
		p9close(fd);

		fd = p9open("/greeting", OREAD);
		fn = p9read(fd, buf, sizeof buf - 1);
		if(fn < 0) fn = 0;
		buf[fn] = 0;
		print("p9: fd %d read \"%.*s\" from /greeting through the name space\n", fd, (int)fn, (char*)buf);
		p9close(fd);
	}

	/*
	 * ls over 9P: list the file server's own directory, by descriptor,
	 * across the ring.  Attach a fresh channel to the server, open its
	 * root directory (a Topen over the ring), and read it - the server
	 * returns 9P stat entries for the files it holds, which we unpack the
	 * way a program listing a directory does.
	 */
	{
		Chan *ltc, *lrc;
		int dfd;
		long dn;
		uchar *p, *e;
		Dir dir;
		char names[256];
		int m;

		ltc = namec("#L", Aopen, ORDWR, 0);
		lrc = mntattach(ltc, nil, "", 0);
		cclose(ltc);
		lrc = devtab[lrc->type]->open(lrc, OREAD);	/* Topen the root */
		dfd = newfd(lrc, OREAD);
		print("p9: ls the 9P server's directory over the ring:\n");
		while((dn = p9read(dfd, buf, sizeof buf)) > 0){
			p = buf;
			e = buf + dn;
			while(p < e){
				m = convM2D(p, (uint)(e - p), &dir, names);
				if(m <= 0)
					break;
				print("p9:   %s (%lld bytes)\n", dir.name, (vlong)dir.length);
				p += m;
			}
		}
		p9close(dfd);
	}

	/*
	 * Read-write file I/O over 9P: the server holds one writable file,
	 * "scratch".  Open it for writing across the ring, write a line, then
	 * open it again and read it back - the bytes make a full round trip to
	 * the file-server container and home, by descriptor.
	 */
	{
		int wfd, rfd;
		long wn, rn;
		char *msg = "a program on the personality wrote this over 9P\n";

		wfd = p9open("/scratch", OWRITE);
		wn = p9write(wfd, msg, strlen(msg));
		print("p9: wrote %ld bytes to /scratch over the ring\n", wn);
		p9close(wfd);

		rfd = p9open("/scratch", OREAD);
		rn = p9read(rfd, buf, sizeof buf - 1);
		if(rn < 0) rn = 0;
		buf[rn] = 0;
		print("p9: read /scratch back over the ring: \"%.*s\"\n", (int)rn, (char*)buf);

		/*
		 * And a file larger than the ring carries in one message.
		 * Everything above fits a single exchange - the files are
		 * tens of bytes and the store was 512 - so the transport had
		 * never been asked to carry a file in pieces, which is what
		 * it does for anything of any size.  Write 4096 bytes of a
		 * pattern no run of zeroes or repeats could imitate, read
		 * them back into a fresh buffer, and compare every one.  The
		 * write and the read are both loops because that is what a
		 * program does with a descriptor: each call carries what the
		 * mount's message size allows and returns how much it took.
		 */
		{
			enum { Big = 4096 };
			static uchar out[Big], in[Big];
			long k, off, m, nbad;
			int bfd;

			for(k = 0; k < Big; k++)
				out[k] = (uchar)(k*7 + (k>>8)*13 + 1);
			bfd = p9open("/scratch", OWRITE);
			for(off = 0; off < Big; off += m){
				m = p9write(bfd, out + off, Big - off);
				if(m <= 0)
					break;
			}
			p9close(bfd);
			print("p9: wrote %ld bytes of %d to /scratch, in messages of at most %lud\n",
				off, Big, c->iounit);
			bfd = p9open("/scratch", OREAD);
			for(k = 0; k < Big; k += m){
				m = p9read(bfd, in + k, Big - k);
				if(m <= 0)
					break;
			}
			p9close(bfd);
			nbad = 0;
			for(m = 0; m < k && m < Big; m++)
				if(in[m] != out[m])
					nbad++;
			print("p9: read %ld bytes back, %ld of them wrong: a file larger than "
				"one message crosses the ring in pieces\n", k, nbad + (Big - k));
		}
		p9close(rfd);
	}

	/*
	 * The personality as a 9P server.  Where all of the above made it a
	 * client of a server elsewhere, p9srv answers 9P about this name
	 * space itself.  Mount the personality's own export (#X) and read its
	 * root directory back over 9P - a loopback that proves the server
	 * serves the real name space, the reciprocal of mounting a buddy's.
	 */
	{
		Chan *xtc, *xrc;
		int xfd;
		long xn;
		uchar *p, *e;
		Dir dir;
		char names[256];
		int m;

		xtc = namec("#X", Aopen, ORDWR, 0);
		xrc = mntattach(xtc, nil, "", 0);
		cclose(xtc);
		xrc = devtab[xrc->type]->open(xrc, OREAD);
		xfd = newfd(xrc, OREAD);
		int nent = 0;
		print("p9: mounted the personality's own name space over 9P (exportfs loopback); its root:\n");
		while((xn = p9read(xfd, buf, sizeof buf)) > 0){
			p = buf;
			e = buf + xn;
			while(p < e){
				m = convM2D(p, (uint)(e - p), &dir, names);
				if(m <= 0)
					break;
				print("p9:   %s\n", dir.name);
				nent++;
				p += m;
			}
		}
		print("p9: exportfs served %d entries from the personality's own root over 9P\n", nent);
		p9close(xfd);
	}

	/*
	 * seek and stat by descriptor.  Stat "/hello" over the 9P mount for
	 * its length, then seek past the first word and read the rest - random
	 * access and metadata, the operations a program needs beyond a plain
	 * sequential read.
	 */
	{
		int fd;
		long rn;
		Dir d;
		uchar sbuf[256];

		fd = p9open("/hello", OREAD);
		if(p9stat(fd, &d, sbuf, sizeof sbuf) == 0)
			print("p9: stat /hello: name %s, length %lld\n", d.name, (vlong)d.length);
		p9seek(fd, 6, 0);		/* past "hello " */
		rn = p9read(fd, buf, sizeof buf - 1);
		if(rn < 0) rn = 0;
		buf[rn] = 0;
		print("p9: after seek to 6, read \"%.*s\"\n", (int)rn, (char*)buf);
		p9close(fd);
	}

	/*
	 * bind and create - the last of the name-space operations rio needs.
	 * Create a file in the environment device by name, bind that device
	 * onto /mnt, and read the file back through the bound path: the create
	 * makes a new file, the bind rearranges the name space, and the read
	 * proves a name resolves across the binding.
	 */
	{
		int fd;
		long rn;
		char *val = "reached through a bind\n";

		fd = p9create("#e/bound", OWRITE, 0666);
		p9write(fd, val, strlen(val));
		p9close(fd);
		print("p9: created #e/bound and wrote a value\n");

		p9bind("#e", "/mnt", MREPL);
		print("p9: bound the environment device onto /mnt\n");

		fd = p9open("/mnt/bound", OREAD);
		rn = p9read(fd, buf, sizeof buf - 1);
		if(rn < 0) rn = 0;
		buf[rn] = 0;
		print("p9: read /mnt/bound across the binding: \"%.*s\"\n", (int)rn, (char*)buf);
		p9close(fd);

		/*
		 * And put /mnt back, which this did not do and had to.  The
		 * name space here is the one every program the personality
		 * loads is given, and the root device keeps /mnt/temp and
		 * /mnt/wsys in it for exactly the program that wants them:
		 * rio binds the pipe device onto /mnt/temp in cexecpipe.  An
		 * MREPL of the environment device over /mnt hid both, and
		 * what rio said about it was "can't create file system
		 * server: Enonexist: '/mnt/temp'" - the demonstration above
		 * had taken the mount point out from under a program that had
		 * not run yet.
		 */
		p9unmount(nil, "/mnt");
		print("p9: unbound the environment device from /mnt, "
			"which the root device keeps temp and wsys in\n");
	}

	/*
	 * A union directory read: list "/" itself, which by now is a union of
	 * the root device, the environment mounted onto it, and the 9P server
	 * mounted onto it.  One listing spans all three, the way a Plan 9
	 * union does - the root's boot and bin, the environment's variables,
	 * and the server's hello, motd, readme and scratch, together.
	 */
	{
		int nent, nbound, ncross, nafter, nsweep, nrocked, firstrock, i;
		vlong hl, hlbound, hlcross, hlafter, hlsweep;
		uchar small[512];

		nent = lsunion("a union of the root device, the environment "
			"and the 9P mount", buf, sizeof buf, &hl, 0);
		print("p9: the union listing spanned %d entries across three mounted members\n", nent);
		print("p9: and \"hello\" in it is %lld bytes, which is the 9P server's own\n", hl);

		/*
		 * Now make one entry of that listing a mount point and list it
		 * again.  /motd is bound over /hello: the name "hello" still
		 * resolves, but it reaches motd, and a listing that still said
		 * 54 bytes would be describing a file the name no longer
		 * reaches.  The listing above is the control - the same
		 * program, the same buffer, the same entry, taken before the
		 * bind - so if the fixup did nothing the two lengths would be
		 * equal.  Both files are the 9P server's, so the entry is
		 * rewritten where it stands: same name, same size, other file.
		 */
		p9bind("/motd", "/hello", MREPL);
		print("p9: bound /motd over /hello, so one entry of that listing is a mount point\n");
		nbound = lsunion("the same union, with /motd bound over /hello",
			buf, sizeof buf, &hlbound, 0);
		print("p9: the entry is still named \"hello\" and is now %lld bytes, "
			"which is motd's, across %d entries\n", hlbound, nbound);

		/*
		 * And across devices, which is the case the rock is for.  The
		 * environment device's files belong to eve, whose name is six
		 * characters, and the 9P server's belong to "none", which is
		 * four; a stat carries the owner three times, so the entry
		 * that replaces this one is six bytes longer than the one it
		 * replaces.  A rewritten entry that no longer fits the
		 * caller's buffer is what the rock holds.
		 */
		p9unmount(nil, "/hello");
		p9bind("/greeting", "/hello", MREPL);
		print("p9: and bound /greeting, which the environment device serves, over /hello\n");
		ncross = lsunion("the union with an entry of one device bound over "
			"an entry of another", buf, sizeof buf, &hlcross, 0);
		print("p9: with the environment's file over it the entry is %lld bytes "
			"across %d entries, and the entry itself grew from 66 bytes to 72\n",
			hlcross, ncross);

		/*
		 * Now read that listing through every buffer size from 75
		 * bytes - the largest single entry, below which a member
		 * cannot return anything - to 320, one byte at a time.  Every
		 * one of them has to give the same twenty entries and the same
		 * rewritten length: a buffer boundary is not allowed to lose
		 * an entry or cut one in half.  The sizes where the grown
		 * entry no longer fits are the rock's, and they are counted.
		 */
		nsweep = 0;
		nrocked = 0;
		firstrock = 0;
		for(i = 75; i <= 320; i++){
			long before = p9rockcount();
			int n2 = lsunion(nil, small, i, &hlsweep, 1);
			if(n2 != nent || hlsweep != hlcross){
				print("p9: a %d-byte buffer gave %d entries and %lld bytes, "
					"not %d and %lld\n", i, n2, hlsweep, nent, hlcross);
				break;
			}
			nsweep++;
			if(p9rockcount() > before){
				nrocked++;
				if(firstrock == 0)
					firstrock = i;
			}
		}
		print("p9: the same listing through every buffer size from 75 to 320 bytes: "
			"%d of them gave the same %d entries with \"hello\" at %lld bytes, "
			"and at %d of those sizes the grown entry did not fit and went to the "
			"channel's rock, the first at %d bytes; %ld entries were carried in "
			"the rock altogether\n",
			nsweep, nent, hlcross, nrocked, firstrock, p9rockcount());

		/*
		 * Put it back.  Later demonstrations here and programs the
		 * personality loads read /hello for the 9P server's own bytes.
		 */
		p9unmount(nil, "/hello");
		nafter = lsunion("the union with the bind undone", buf, sizeof buf, &hlafter, 0);
		print("p9: with the bind undone \"hello\" is %lld bytes again, across %d entries\n",
			hlafter, nafter);
	}

	/*
	 * A pipe: the name space carries not only files but a channel two
	 * ends of a program talk through.  Attach a pipe, walk to its two
	 * ends, write one and read the other - the bytes cross through the
	 * queue the pipe device holds, in the personality's own memory.
	 */
	{
		Chan *pd, *w, *r;
		char *nm[1];
		long n;

		pd = namec("#|", Atodir, 0, 0);
		w = cclone(pd);
		nm[0] = "data";
		walk(&w, nm, 1, 1, nil);
		w = devtab[w->type]->open(w, OWRITE);
		r = cclone(pd);
		nm[0] = "data1";
		walk(&r, nm, 1, 1, nil);
		r = devtab[r->type]->open(r, OREAD);
		cclose(pd);

		devtab[w->type]->write(w, "sent through a pipe", 19, 0);
		n = devtab[r->type]->read(r, buf, sizeof buf - 1, 0);
		if(n < 0) n = 0;
		buf[n] = 0;
		print("p9: wrote one end of a pipe, read the other: \"%.*s\"\n", (int)n, (char*)buf);
		cclose(w);
		cclose(r);
	}

	/*
	 * And a write that is refused leaves the descriptor's offset where it
	 * found it.
	 *
	 * The write path advances the channel's offset before it calls the
	 * device and winds it back by what the device did not take, which is
	 * 9front's order and not the older one: a second writer on the same
	 * channel must not be handed an offset the first is about to use.  A
	 * write that fails outright takes none of it, so the offset has to
	 * come back whole - and if it did not, nothing would go wrong until
	 * some later write to the same channel landed in the wrong place,
	 * which is the kind of drift that is never noticed.
	 *
	 * A pipe whose reader has gone is the write that fails.  Seek cannot
	 * be used to look at the offset - a pipe is a stream and refuses one
	 * - so the channel is asked directly.
	 */
	{
		int pfd[2], refused;
		vlong before, after;
		char reason[ERRMAX];

		if(waserror())
			print("p9: the refused-write check could not run: %s\n", up->errstr);
		else {
			p9pipe(pfd);
			p9close(pfd[0]);		/* the reader is gone */
			before = p9fdoffset(pfd[1]);
			refused = 0;
			reason[0] = 0;
			if(waserror()){
				refused = 1;
				kstrcpy(reason, up->errstr, sizeof reason);
			} else {
				p9write(pfd[1], "sent through a pipe", 19);
				poperror();
			}
			after = p9fdoffset(pfd[1]);
			print("p9: a write of 19 bytes into a pipe with no reader was %s (%s); the write end's offset was %lld before and %lld after\n",
				refused ? "refused" : "taken", reason, before, after);
			p9close(pfd[1]);
			poperror();
		}
	}

	/*
	 * Service publication: post a channel to /srv by name, the way a
	 * Plan 9 server announces itself, then look it up and mount it.  Post
	 * the personality's own exportfs (#X) to /srv/export, reopen it by
	 * name, mount it, and read the served root - proving a service named
	 * in /srv can be found and mounted, which is how name spaces compose.
	 */
	{
		Chan *tc, *sc, *rc, *xr;
		int tfd, xfd, nent;
		long dn;
		char fdstr[16];
		uchar *p, *e;
		Dir dir;
		char names[256];
		int m;

		tc = namec("#X", Aopen, ORDWR, 0);
		tfd = newfd(tc, ORDWR);
		sc = namec("#s/export", Acreate, OWRITE, 0666);
		snprint(fdstr, sizeof fdstr, "%d", tfd);
		devtab[sc->type]->write(sc, fdstr, strlen(fdstr), 0);
		cclose(sc);
		print("p9: posted the personality's exportfs to /srv/export\n");

		rc = namec("#s/export", Aopen, ORDWR, 0);
		xr = mntattach(rc, nil, "", 0);
		cclose(rc);
		xr = devtab[xr->type]->open(xr, OREAD);
		xfd = newfd(xr, OREAD);
		nent = 0;
		while((dn = p9read(xfd, buf, sizeof buf)) > 0){
			p = buf; e = buf + dn;
			while(p < e){
				m = convM2D(p, (uint)(e - p), &dir, names);
				if(m <= 0) break;
				nent++;
				p += m;
			}
		}
		print("p9: looked up /srv/export, mounted it, read %d entries from the served root\n", nent);
		p9close(xfd);
	}

	/*
	 * dup: a second descriptor onto the same open channel, sharing its
	 * offset - what a shell uses to redirect.  Open "/hello", read the
	 * first word through one descriptor, dup it, and read the rest
	 * through the duplicate, which continues where the first left off.
	 */
	{
		int fd, fd2;
		long a, b;

		fd = p9open("/hello", OREAD);
		a = p9read(fd, buf, 5);			/* "hello" */
		buf[a < 0 ? 0 : a] = 0;
		fd2 = p9dup(fd);
		b = p9read(fd2, buf, sizeof buf - 1);	/* the rest, via the dup */
		buf[b < 0 ? 0 : b] = 0;
		print("p9: dup - first read %ld bytes on fd %d, the rest on its dup fd %d: \"%.*s\"\n",
			a, fd, fd2, (int)b, (char*)buf);
		p9close(fd);
		p9close(fd2);
	}

	/*
	 * And a second program, run by this one: the personality reads
	 * /boot/prog2 through the name space it built, lays it in its own
	 * address space and calls it, handing it the table of its own entry
	 * points.  The program opens and reads a file by calling this
	 * personality - an ordinary call, no trap and no ring - and creates
	 * one of its own, which is read back here afterwards: proof that the
	 * name space under it is this one and that it is still here.
	 */
	p9exec("/boot/prog2", nil);
	{
		int fd;
		long m;

		fd = p9open("/fromprog2", OREAD);
		if(fd < 0)
			fd = p9open("#e/fromprog2", OREAD);
		if(fd >= 0){
			m = p9read(fd, buf, sizeof buf - 1);
			buf[m < 0 ? 0 : m] = 0;
			print("p9: read what the second program wrote, through the same name space: \"%s\"\n", (char*)buf);
			p9close(fd);
		} else
			print("p9: the second program left nothing to read\n");
	}

	/*
	 * And a real command: /boot/libcat is catp9.c, the same source as
	 * the cat that runs under the buddy on the server personality, with
	 * no line changed.  What differs is the link - against p9crt.c,
	 * which is this personality standing in for libc's system calls -
	 * so its open, read, close, dup, fd2path and sbrk are calls into
	 * the file system in its own address space, not traps.  One program,
	 * two arrangements: a process boundary there, none here.
	 */
	{
		char *catargv[3];

		catargv[0] = "/boot/libcat";
		catargv[1] = "/hello";
		catargv[2] = nil;
		p9exec("/boot/libcat", catargv);
	}

	/*
	 * And a program that draws.  /boot/libdraw is an ordinary Plan 9
	 * graphics program - initdraw, allocimage, draw, flushimage, out of
	 * the real libdraw built from source - and the /dev/draw its
	 * libdraw opens is the kernel's own devdraw.c, compiled into this
	 * personality rather than run as a server in a container of its
	 * own.  So the draw protocol crosses no boundary at all: the
	 * program writes it into a file whose device is code in the same
	 * address space, which draws on the firmware frame buffer the
	 * microkernel exposed as a segment.  The one thing any of it asks a
	 * kernel for is the address space.
	 *
	 * What it paints is stated in the program and in the check before
	 * either was run: the screen 0x112233 and the rectangle
	 * (200,150)-(600,450) 0xCC7722.
	 */
	{
		char *dargv[2];

		dargv[0] = "/boot/libdraw";
		dargv[1] = nil;
		p9exec("/boot/libdraw", dargv);
	}

	/*
	 * And a threaded program.  /boot/libthread is an ordinary Plan 9
	 * libthread program - threadmain, threadcreate, chancreate, send
	 * and recv - on the real libthread, built from source with no line
	 * changed.  What is this personality's own is threadmain9.c, the
	 * four functions 9front keeps in libthread/main.c because they are
	 * the system a port has to supply.
	 *
	 * It is worth saying what this program does not need.  Its link
	 * leaves out the prebuilt libc.a - the archive of generated
	 * system-call stubs - altogether, and resolves: every call it and
	 * its libc make is either the personality's, through the table, or
	 * code in its own image.  A threaded program on this personality
	 * makes one system call, and it is the console.
	 *
	 * Threads of one proc, for now: a second proc would be a second
	 * flow of control inside the program, and libthread keeps the
	 * running Proc in a privalloc(2) word, which one word cannot answer
	 * differently to two flows unless the personality swaps it at the
	 * switch.  proccreate refuses by name until it does.
	 */
	{
		char *targv[2];

		targv[0] = "/boot/libthread";
		targv[1] = nil;
		p9exec("/boot/libthread", targv);
	}

	/*
	 * And two of the same program running at once, which is what all
	 * of this was for.
	 *
	 * The shell is told, a few lines above, that it cannot run two of
	 * an image at the same time, and the check confirms the refusal:
	 * a program with a fixed base IS its address, and the two would be
	 * one image sharing one data segment, one descriptor table and one
	 * heap.  /boot/reloc has no address, so spawn takes a free slot for
	 * each copy and gives it back when the copy ends (p9proc.c).  Two
	 * spawns, two slots, both alive at once, and each reads its own
	 * pointers - which are different addresses in the two copies.
	 *
	 * That is the shape rio needs.  It is not rio: nothing here has
	 * built the shell's programs as modules, and the slots are four.
	 */
	{
		char *rargv[2];
		int a, b;
		char sa[64], sb[64];
		extern int p9spawn(char*, char**, int*);
		extern int p9waitpid(int, char*, int);
		int std[3];

		rargv[0] = "/boot/reloc";
		rargv[1] = nil;
		std[0] = std[1] = std[2] = -1;
		a = p9spawn("/boot/reloc", rargv, std);
		b = p9spawn("/boot/reloc", rargv, std);
		if(a < 0 || b < 0)
			print("p9: could not start two of /boot/reloc at once (%d, %d)\n", a, b);
		else {
			p9waitpid(a, sa, sizeof sa);
			p9waitpid(b, sb, sizeof sb);
			print("p9: two of /boot/reloc ran at once, as %d and %d, each in a slot of its own\n",
				a, b);
		}
	}

	/*
	 * And the same module twice, at two addresses.
	 *
	 * Every other program here is laid at the address it was linked
	 * for, which is why p9lib.h has one base per program and why the
	 * shell is told it cannot run two of an image at once.
	 * /boot/reloc has no address of its own: 6l -u linked it at 0 and
	 * gave it a table of every absolute address in it, and the loader
	 * corrects them as it lays it down (p9execreloc).  So it goes down
	 * twice, at two bases, and both copies run.
	 *
	 * The program is built to notice a correction that did not happen:
	 * it is a table of pointers to functions and a table of pointers to
	 * strings, both in its data, and it prints arithmetic over both.  A
	 * pointer nobody fixed is a wrong number or a fault, not a subtly
	 * different string.
	 */
	{
		char *rargv[2];
		extern int p9execreloc(char*, char**, uvlong);
		extern uvlong p9relocaddr(int);

		rargv[0] = "/boot/reloc";
		rargv[1] = nil;
		p9execreloc("/boot/reloc", rargv, p9relocaddr(0));
		p9execreloc("/boot/reloc", rargv, p9relocaddr(1));
	}

	/*
	 * And a shell, with processes under it.  The personality now starts
	 * a program on a flow of control of its own - a kproc with a
	 * descriptor table of its own - so a program can start other
	 * programs and wait for them, which is what a shell is (p9proc.c).
	 * The script's second line is a pipeline, so cat's bytes reach wc
	 * through a pipe of this personality's, in this one address space,
	 * with no process boundary anywhere and no trap but the console.
	 *
	 * The shell is not shp9.c, the server personality's shell, and the
	 * reason is written down in shlib.c: fork and exec are not things a
	 * library operating system can offer its caller.  The commands are
	 * the same source on both, which is the claim that was earned.
	 */
	{
		char *shargv[3];
		/*
		 * The last three lines are the halves of the same claim.
		 *
		 * cat is a relocatable module now, so "cat | cat" is two of
		 * one image running at once, each in a slot the loader took
		 * for it - which is what the fourth line was written to be
		 * refused for, back when cat was its address.  wc is a module
		 * too, so the fifth line is three of them alive at once in
		 * three slots, with /hello going the length of it and being
		 * counted at the far end.  The sixth is five stages, and the
		 * shell is a module as well and holds a slot of its own while
		 * they run: six modules at once, which is every slot there
		 * is.  A number of slots nothing ever reaches would say
		 * nothing about them.
		 *
		 * The seventh changes the name space rather than reading
		 * through it: bind, chdir and unmount were the personality's
		 * own until now, and a library operating system whose caller
		 * cannot bind is offering a list of names and not a name
		 * space.  It ends by taking a name space of its own with
		 * rfork(RFNAMEG) and binding /boot onto /n in it, and the
		 * eighth line is how that is checked: cat is asked for
		 * /n/libcat afterwards, in the shell's name space, and must
		 * not find it.  A private bind that was not private would
		 * leave that file there.  The ninth asks the same of the
		 * environment: /env/libnsshared was set before libns took an
		 * Egrp of its own and must be readable, /env/libnsprivate was
		 * set after and must not be.
		 *
		 * gen still is its address, so "gen | gen" is refused, and
		 * refused by name; and the first gen, writing into a pipe
		 * whose reader never arrived, ends with the reason as its
		 * status.  Both of those were cat's job before and neither
		 * is lost.
		 */
		char *script =
			"/boot/libcat /hello\n"
			"/boot/libcat /hello | /boot/libwc\n"
			"/boot/libgen 200000 | /boot/libwc\n"
			"/boot/libcat /hello | /boot/libcat\n"
			"/boot/libcat /hello | /boot/libcat | /boot/libwc\n"
			"/boot/libcat /hello | /boot/libcat | /boot/libcat | /boot/libcat | /boot/libwc\n"
			"/boot/libns\n"
			"/boot/libcat /n/libcat\n"
			"/boot/libcat /env/libnsshared /env/libnsprivate\n"
			"/boot/libgen 100 | /boot/libgen 100\n";
		/*
		 * And one more line when the machine was asked for it: a
		 * command that is an ordinary Plan 9 binary rather than a
		 * program linked against the table.  The shell does not know
		 * the difference - it spawns a name - and the difference is
		 * the personality's: it recognises one of its own ordinary
		 * binaries and enters it with an argument vector, having asked
		 * the kernel for the traps its libc will make.
		 *
		 * It is behind the same switch as the rest of the legacy
		 * demonstration because the boot every other check is written
		 * against should be the boot they were written against.
		 */
		char *legacyline = "/boot/cat /hello\n";
		int fd;

		fd = p9create("#e/script", OWRITE, 0666);
		if(fd < 0)
			print("p9: cannot write the script for the shell\n");
		else {
			p9write(fd, script, strlen(script));
			if(p9legacydemo)
				p9write(fd, legacyline, strlen(legacyline));
			p9close(fd);
			print("p9: wrote a script of ten lines, five of them pipelines\n");
			shargv[0] = "/boot/libsh";
			shargv[1] = "#e/script";
			shargv[2] = nil;
			p9exec("/boot/libsh", shargv);
		}
	}

	/*
	 * And once more, after the shell has ended: p9exec takes a slot for
	 * a module and gives it back, and the giving back had nothing to
	 * show it while the shell was the last module to run.  /boot/reloc
	 * goes down through p9exec this time rather than p9execreloc, with
	 * no address named, and the slot it is given is the one the shell
	 * held - which is only free because p9exec freed it.
	 */
	{
		char *rargv[2];

		rargv[0] = "/boot/reloc";
		rargv[1] = nil;
		print("p9: the shell has ended; loading a module through exec again, "
			"to see the slot it held given back\n");
		p9exec("/boot/reloc", rargv);
	}

	/*
	 * And rio.  This is the program Phase 3.2 is named for: the real
	 * 9front rio, from the source in 9front/src/cmd/rio, linked against
	 * this personality and against nothing else - the prebuilt archive
	 * of generated system-call stubs is left off its link line, so every
	 * call it makes is either the personality's through the table or
	 * code in its own image.
	 *
	 * What happens when it runs is the report, not the claim.  It is
	 * started here so that the failure, if it fails, is a thing on a
	 * booted machine with a message rather than a guess.
	 */
	{
		char *rioargv[4];

		/*
		 * Plain, with no window asked for.
		 *
		 * -k asks rio for a window at startup without a mouse click:
		 * it allocates one over the bottom third of the screen and
		 * creates it.  That was tried and it is not a window that
		 * stands.  rio's new() hands the window to winshell, which
		 * rforks (answered), mounts its own wsys (answered), opens
		 * /dev/cons twice (answered), renames itself by writing
		 * /proc/<n>/args (answered, once this personality served that
		 * file) and then execs /bin/rc - which threadmain9.c refuses,
		 * because a library operating system has no exec.  new()
		 * gets the failure back on its pid channel, rio takes the
		 * window down again and aborts its file server.  The window
		 * exists for as long as the exec takes to fail.
		 *
		 * exec is answered now - _schedexec spawns, and
		 * /boot/libthread's procexec starts cat through it - and rio
		 * still has no window: with -k its winshell gets further and
		 * the window's own 9P channel is closed under it before
		 * procexec is reached, which is the next thing to find.  rio
		 * runs plain here, because a window that is taken down again
		 * is not a window and the boot should not claim one.
		 */
		rioargv[0] = "/boot/rio";
		rioargv[1] = "-k";
		rioargv[2] = "/boot/libgen 20000";
		rioargv[3] = nil;
		/*
		 * What a window system finds here, said before it runs.  rio
		 * opens these in this order and each is a different part of
		 * the personality: /dev/draw is the kernel's devdraw compiled
		 * in, /dev/mouse and /dev/kbd are the i8042 driver's if this
		 * configuration has one, /dev/cons is the machine's console
		 * and /dev/snarf is nobody's.  A program that blocks on one of
		 * them blocks with nothing to say, so the name space is asked
		 * first and the answer is in the log whatever happens after.
		 */
		{
			static char *want[] = {
				"/dev/draw", "/dev/mouse", "/dev/kbd",
				"/dev/cons", "/dev/snarf", "/dev/winname", nil
			};
			int i, f;

			for(i = 0; want[i] != nil; i++){
				/*
				 * p9open is the personality's own open and it
				 * raises rather than answering -1, which is what
				 * every other caller here already knew and this
				 * one did not: without a handler of its own the
				 * raise unwound out of p9main, and what came back
				 * was a wild jump with the half-built message
				 * ("'/dev/snarf'") still on the stack.  A probe
				 * whose whole purpose is to ask about names that
				 * may not be there has to catch.
				 */
				if(waserror()){
					print("p9: rio will want %s: not there (%s)\n",
						want[i], up->errstr);
					continue;
				}
				f = p9open(want[i], OREAD);
				poperror();
				print("p9: rio will want %s: it opens\n", want[i]);
				p9close(f);
			}
		}
		/*
		 * rio is started on a flow of its own rather than run to
		 * completion, because rio does not complete: it paints its
		 * screen and waits for a mouse click, and nothing here
		 * clicks.  p9exec would block for ever and the boot would end
		 * by the harness giving up, which is a poor way to end and a
		 * worse thing to photograph - the screendump was taken at the
		 * watchdog noticing the spin, and that is a timing artifact
		 * rather than something the machine says, so it failed under
		 * load.
		 *
		 * So: spawn it, give it a fixed few seconds of the clock, say
		 * so, and let the task end.  The screendump is taken at that
		 * sentence, which the personality prints and which does not
		 * move.
		 */
		extern int p9spawn(char*, char**, int*);
		extern int libsleep(long ms);
		int riopid;
		int std[3];
		extern int p9inputloop(long ms);

		std[0] = std[1] = std[2] = -1;
		/*
		 * Before rio, the question the whole arrangement turns on: an
		 * ordinary Plan 9 binary, linked against libc and the
		 * generated system-call stubs and against no personality at
		 * all.  Everything else here is linked against p9crt.c, which
		 * is a library per program; this one traps, and what answers
		 * the traps is what says whether this is a library operating
		 * system or a set of libraries.
		 */
		if(p9legacydemo){
			extern int p9execlegacy(char*, char**);
			char *lav[3];

			lav[0] = "/boot/legacy";
			lav[1] = nil;
			p9execlegacy("/boot/legacy", lav);
			/*
			 * And the same question asked of a program that is not
			 * a demonstration of anything: /boot/cat is catp9.c,
			 * the same source as /boot/libcat, built the ordinary
			 * Plan 9 way - libc, the generated stubs, an argument
			 * vector, a heap grown with sbrk.  /boot/libcat is that
			 * source linked against p9crt.c, which is a library per
			 * program; this is the program itself.  If the second
			 * reads the same file as the first, then p9crt.c is the
			 * special case here and not the rule.
			 */
			lav[0] = "/boot/cat";
			lav[1] = "/hello";
			lav[2] = nil;
			p9execlegacy("/boot/cat", lav);
			/*
			 * And the other half of the fault path.  /boot/legacy
			 * registers a note handler and catches its own fault,
			 * which is what a Plan 9 program does; this one has no
			 * handler, which is what most programs are, and there
			 * is nobody in it to give the note to.  On this
			 * configuration a note nothing handles is a panic, so
			 * the personality takes the flow of control back
			 * instead - and the proof that it did is that the boot
			 * goes on to the window system below.
			 */
			lav[0] = "/boot/faulty";
			lav[1] = nil;
			p9execlegacy("/boot/faulty", lav);
		}
		print("p9: /bin/rc is /boot/libsh, this tree's own small shell, and not rc: "
			"rio asks for rc by name and there is none here\n");
		print("p9: starting /boot/rio, the real 9front rio, linked against this personality\n");
		riopid = p9spawn("/boot/rio", rioargv, std);
		if(riopid < 0)
			print("p9: /boot/rio: cannot start it\n");
		else {
			/*
			 * Six seconds of the clock, spent servicing this
			 * container's interrupt notifications rather than
			 * sleeping through them: that is what turns the i8042
			 * driver's IRQ1 and IRQ12 into bytes on /dev/kbd and
			 * /dev/mouse, and what lets rio be typed at and
			 * clicked.  A sleep would leave the driver blocked on
			 * a semaphore nobody downs.
			 */
			p9inputloop(15000);
			print("p9: /boot/rio has had its time, a screen of its own "
				"and a window with a program's output in it\n");
		}
	}

	poperror();
	exits(nil);
}

/*
 * The buddy's client: mount the peer personality's exported name space
 * over the ring and read its root - two library operating systems, one
 * naming the other's files by 9P, the kernel only routing.
 */
void
p9paircli(void)
{
	Chan *tc, *rc, *root;
	uchar buf[2048];
	int fd, nent, m;
	long dn;
	uchar *p, *e;
	Dir dir;
	char names[256];

	if(waserror()){
		print("p9: pair-client error: %s\n", up->errstr);
		exits("error");
	}
	p9setup();
	print("p9: pair-client: mounting the server personality over the ring\n");
	tc = namec("#L", Aopen, ORDWR, 0);
	rc = mntattach(tc, nil, "", 0);
	cclose(tc);
	root = cclone(rc);		/* an unopened root to walk from, below */
	rc = devtab[rc->type]->open(rc, OREAD);
	fd = newfd(rc, OREAD);
	nent = 0;
	while((dn = p9read(fd, buf, sizeof buf)) > 0){
		p = buf;
		e = buf + dn;
		while(p < e){
			m = convM2D(p, (uint)(e - p), &dir, names);
			if(m <= 0)
				break;
			nent++;
			p += m;
		}
	}
	print("p9: pair-client: read %d entries from the server personality's exported root over the ring\n", nent);
	/*
	 * The file system on the disk, over 9P: the server personality
	 * mounted its log-structured store at /n, so /n/hello is a file on
	 * the block device, read here across the ring; then written, which
	 * commits a new version to the disk when the fid is clunked, and
	 * read again.
	 */
	if(!waserror()){
		char text[256];
		char *names[2];
		Chan *hc;
		long ln;

		/*
		 * Walked from the mounted root itself, not by path: this
		 * personality's own root device has an empty /n of its own
		 * that a path would find first.
		 */
		names[0] = "n";
		names[1] = "hello";
		hc = cclone(root);
		if(walk(&hc, names, 2, 1, nil) < 0)
			error("no /n/hello at the server");
		hc = devtab[hc->type]->open(hc, OREAD);
		ln = devtab[hc->type]->read(hc, text, sizeof text - 1, 0);
		if(ln < 0) ln = 0;
		text[ln] = 0;
		cclose(hc);
		print("p9: pair-client: read /n/hello from the disk over 9P: \"%s\"\n", text);

		hc = cclone(root);
		walk(&hc, names, 2, 1, nil);
		hc = devtab[hc->type]->open(hc, OWRITE|OTRUNC);
		devtab[hc->type]->write(hc, "written by the client over 9P, a new version on the disk", 56, 0);
		cclose(hc);		/* the clunk commits it, over there, to the disk */
		/*
		 * The same file over pi-p, which is what the talk says a file
		 * is reached through: one group - a session, an open, a read
		 * of the attribute list, a read of the data, a write, a close
		 * that commits - in one round trip over the ring, answered by
		 * the server personality's pi-p (pipfsrv.c) about its files;
		 * then a second group that resumes the session and reads what
		 * the first committed.
		 */
		{
			extern long ringpip_xfer(uchar*, long, uchar*, long);
			extern long pip_tsession(uchar*, int, uvlong);
			extern long pip_topen(uchar*, int, ulong, ulong, int, char*);
			extern long pip_tread(uchar*, int, ulong, long, char*);
			extern long pip_twrite(uchar*, int, ulong, char*, char*, long);
			extern long pip_tclose(uchar*, int, ulong);
			extern int pip_next(uchar*, long, long*, int*, int*, uchar**, long*);
			extern uvlong pip_num(uchar*, int);
			uchar tg[512], rg[2048], *body;
			long tn, rn, off, blen;
			int type, tag, nrep;
			uvlong sid, vers;
			char show[160];

			tn = 0;
			tn += pip_tsession(tg+tn, 1, 0);
			{
				extern char *pip_ticket(void);
				extern long pip_tauth(uchar*, int, char*);
				char *tk = pip_ticket();

				if(tk != nil)
					tn += pip_tauth(tg+tn, 99, tk);	/* who I am, first: the file is the personality's */
			}
			tn += pip_topen(tg+tn, 2, 0, 1, 0, "/n/hello");
			tn += pip_tread(tg+tn, 3, 1, 64, "*");
			tn += pip_tread(tg+tn, 4, 1, 256, "data");
			tn += pip_twrite(tg+tn, 5, 1, "data", "written over pi-p in one group; the close commits it", 52);
			tn += pip_tclose(tg+tn, 6, 1);
			rn = ringpip_xfer(tg, tn, rg, sizeof rg);
			sid = 0;
			vers = 0;
			nrep = 0;
			for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); nrep++){
				switch(type){
				case 101:	/* Rsession */
					sid = pip_num(body, 8);
					break;
				case 103:	/* Ropen: qid version lease */
					print("p9: pair-client: pi-p open /n/hello: version %llud, lease %llud ms\n", pip_num(body+8, 8), pip_num(body+16, 8));
					break;
				case 105:	/* Rread: version data */
					snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
					print("p9: pair-client: pi-p read %s (version %llud): \"%s\"\n", tag == 3 ? "*" : "data", pip_num(body, 8), show);
					break;
				case 107:	/* Rwrite */
					print("p9: pair-client: pi-p write makes version %llud, nobody else's until the close\n", pip_num(body, 8));
					break;
				case 109:	/* Rclose */
					vers = pip_num(body, 8);
					print("p9: pair-client: pi-p close committed version %llud\n", vers);
					break;
				case 112:	/* Rerror */
					snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
					print("p9: pair-client: pi-p error on tag %d: %s\n", tag, show);
					break;
				}
			}
			print("p9: pair-client: pi-p group of 7, the first saying who I am, answered with %d replies in one round trip, session %llux\n", nrep, sid);
			/* come back to the session and read what was committed */
			tn = 0;
			tn += pip_tsession(tg+tn, 7, sid);
			tn += pip_topen(tg+tn, 8, 0, 2, 0, "/n/hello");
			tn += pip_tread(tg+tn, 9, 2, 256, "data");
			tn += pip_tread(tg+tn, 10, 2, 32, "version");
			tn += pip_tclose(tg+tn, 11, 2);
			rn = ringpip_xfer(tg, tn, rg, sizeof rg);
			for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); ){
				if(type == 105 && tag == 9){
					snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
					print("p9: pair-client: pi-p resumed session %llux, read data (version %llud): \"%s\"\n", sid, pip_num(body, 8), show);
				} else if(type == 112){
					snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
					print("p9: pair-client: pi-p error on tag %d: %s\n", tag, show);
				}
			}
		}
		/*
		 * And forty more versions, each a record of two sectors: more
		 * than a small log holds, so the store must reclaim as it goes.
		 */
		{
			int v;
			char vt[128];

			for(v = 0; v < 40; v++){
				hc = cclone(root);
				walk(&hc, names, 2, 1, nil);
				hc = devtab[hc->type]->open(hc, OWRITE|OTRUNC);
				ln = snprint(vt, sizeof vt, "version %d of forty written by the client to fill the log and make reclamation run", v+3);
				devtab[hc->type]->write(hc, vt, ln, 0);
				cclose(hc);
			}
			print("p9: pair-client: wrote forty more versions of /n/hello over 9P\n");
		}

		hc = cclone(root);
		walk(&hc, names, 2, 1, nil);
		hc = devtab[hc->type]->open(hc, OREAD);
		ln = devtab[hc->type]->read(hc, text, sizeof text - 1, 0);
		if(ln < 0) ln = 0;
		text[ln] = 0;
		cclose(hc);
		print("p9: pair-client: wrote /n/hello over 9P and read it back: \"%s\"\n", text);

			/*
			 * Create a new file on the server over 9P, write it, read it
			 * back, and remove it - create and remove that p9srv.c now
			 * answers, in the server's own name space, the round trip
			 * carried on the ring.
			 */
			names[0] = "n";
			if(!waserror()){
				hc = cclone(root);
				if(walk(&hc, names, 1, 1, nil) < 0)
					error("no /n at the server");
				hc = devtab[hc->type]->create(hc, "clientmade", ORDWR, 0666);
				devtab[hc->type]->write(hc, "made by the client over 9P", 26, 0);
				cclose(hc);			/* the clunk commits it on the disk */
				poperror();
				print("p9: pair-client: created /n/clientmade over 9P\n");
			} else
				print("p9: pair-client: create /n/clientmade over 9P: %s\n", up->errstr);

			/*
			 * The shell's script, on the server's disk: the shell is a
			 * legacy binary, so the file its calls reach is the buddy's,
			 * and the buddy's /n is this store.  Written here over 9P
			 * the same way /n/hello is.
			 */
			names[0] = "n";
			if(!waserror()){
				static char scr[] =
					"# a script the shell runs on the server personality\n"
					"/boot/cat /n/hello\n"
					"/boot/cat /n/hello | /boot/cat\n";

				hc = cclone(root);
				if(walk(&hc, names, 1, 1, nil) < 0)
					error("no /n at the server");
				hc = devtab[hc->type]->create(hc, "script", ORDWR, 0666);
				devtab[hc->type]->write(hc, scr, sizeof scr - 1, 0);
				cclose(hc);
				poperror();
				print("p9: pair-client: wrote /n/script over 9P, two lines, the second a pipeline\n");
			} else
				print("p9: pair-client: create /n/script over 9P: %s\n", up->errstr);

			names[0] = "n"; names[1] = "clientmade";
			if(!waserror()){
				hc = cclone(root);
				if(walk(&hc, names, 2, 1, nil) < 0)
					error("no /n/clientmade");
				hc = devtab[hc->type]->open(hc, OREAD);
				ln = devtab[hc->type]->read(hc, text, sizeof text - 1, 0);
				if(ln < 0) ln = 0;
				text[ln] = 0;
				cclose(hc);
				poperror();
				print("p9: pair-client: read /n/clientmade back over 9P: \"%s\"\n", text);
			} else
				print("p9: pair-client: read /n/clientmade over 9P: %s\n", up->errstr);

			names[0] = "n"; names[1] = "clientmade";
			hc = cclone(root);
			if(walk(&hc, names, 2, 1, nil) < 0)
				cclose(hc);
			else if(!waserror()){
				devtab[hc->type]->remove(hc);	/* Tremove; consumes the fid */
				poperror();
				print("p9: pair-client: removed /n/clientmade over 9P\n");
			} else
				print("p9: pair-client: remove /n/clientmade over 9P refused: %s\n", up->errstr);
			poperror();
	} else
		print("p9: pair-client: /n/hello: %s\n", up->errstr);
	cclose(root);
	p9close(fd);
	/*
	 * Start a program: the Linux binary that lives in the server
	 * personality's file system, in a container of its own that the
	 * server lays out, pages and answers for, and wait for it to exit.
	 * A container that is not the boot's, started at run time by a
	 * request, and a wait that is answered by somebody.
	 */
	{
		extern long ring_exec(char*);
		extern long ring_wait(long*);
		long id, st;

		char *progs[] = { "/boot/linux", "/boot/legacy" };
		int i;

		for(i = 0; i < 2; i++){
			id = ring_exec(progs[i]);
			print("p9: pair-client: exec %s started container %ld\n", progs[i], id);
			if(id < 0)
				continue;
			if(ring_wait(&st) == 0)
				print("p9: pair-client: wait: container %ld exited with status %ld\n", id, st);
			else
				print("p9: pair-client: wait: no answer\n");
		}
		/*
		 * An arbitrary program with an argument vector: /boot/cat is an
		 * ordinary Plan 9 binary that opens the file it is given and
		 * writes its bytes, its file calls served by the buddy.  Exec it
		 * with a real argument - the file to read - and its output, the
		 * file's contents, comes back to the console.  This is exec
		 * carrying arguments, and a program that is not the hand-written
		 * demonstration, on the server personality.
		 */
		{
			extern long ring_execv(char**);
			char *catargv[3];

			catargv[0] = "/boot/cat";
			catargv[1] = "/n/hello";
			catargv[2] = nil;
			id = ring_execv(catargv);
			print("p9: pair-client: exec /boot/cat /n/hello with an argument vector started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/cat (container %ld) exited with status %ld - it read /n/hello through the buddy and wrote it out\n", id, st);
		}
		/*
		 * exec(2) in place: /boot/exec replaces itself twenty times over
		 * in the one container this starts, keeping the descriptor it
		 * opened before the first exec, and is refused an exec of a name
		 * that is not there without dying of it.  This is the exec a
		 * shell makes after it forks, as against the ring request just
		 * above, which starts a program in a container of its own.
		 */
		{
			extern long ring_execv(char**);
			char *exargv[2];

			exargv[0] = "/boot/exec";
			exargv[1] = nil;
			id = ring_execv(exargv);
			print("p9: pair-client: exec /boot/exec started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/exec (container %ld) exited with status %ld - it exec'd itself in place twenty times\n", id, st);
		}
		/*
		 * A shell.  /boot/sh is an ordinary Plan 9 program that reads a
		 * script and, for each line, forks a process for each stage,
		 * makes a pipe between them, execs each child in place and
		 * waits for it - fork, exec, pipe and wait, all four answered
		 * by a peer container over the ring.  The script's second line
		 * is a pipeline, so the bytes of /n/hello cross a pipe from one
		 * legacy process to another.
		 */
		{
			extern long ring_execv(char**);
			char *shargv[3];

			shargv[0] = "/boot/sh";
			shargv[1] = "/n/script";
			shargv[2] = nil;
			id = ring_execv(shargv);
			print("p9: pair-client: exec /boot/sh /n/script started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/sh (container %ld) exited with status %ld - it ran a script with a pipeline in it\n", id, st);
		}
		/*
		 * And a program this tree did not write: /boot/kbdsrv is
		 * os/osprey/cmd/draw/kbd.c linked against the 9front
		 * libraries built from source in 9front/src - libthread and
		 * lib9p above the source-built libc, three segments and a
		 * hundred kilobytes of image, where every legacy program
		 * before it was a few tens.  It takes an argument, asks the
		 * kernel for the keyboard ring as a segment and serves
		 * /dev/kbd from it.  What this settles is that a binary of
		 * that shape lays out, is entered through init9main.c and
		 * runs its libc on the server personality.
		 */
		{
			extern long ring_execv(char**);
			char *kargv[3];

			kargv[0] = "/boot/kbdsrv";
			kargv[1] = "-m/dev";
			kargv[2] = nil;
			id = ring_execv(kargv);
			print("p9: pair-client: exec /boot/kbdsrv started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/kbdsrv (container %ld) exited with status %ld\n", id, st);
		}
		/*
		 * The negative control for the error path, and the reason
		 * kbd.c names its segment rather than fixing it: the same
		 * binary asked for a segment this kernel does not have.  The
		 * call fails in the kernel, which the buddy never saw, so
		 * errstr(2) must be answered here and exits(2) must carry the
		 * reason out as the container's status.  Both were broken
		 * once and neither would be noticed again without a call that
		 * still fails.
		 */
		{
			extern long ring_execv(char**);
			char *nargv[3];

			nargv[0] = "/boot/kbdsrv";
			nargv[1] = "-snosuchring";
			nargv[2] = nil;
			id = ring_execv(nargv);
			print("p9: pair-client: exec /boot/kbdsrv -snosuchring started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/kbdsrv -snosuchring (container %ld) exited with status %ld\n", id, st);
		}
		/*
		 * And the draw server, which is the one of the four that can
		 * do its work here: it wants the frame buffer, which this
		 * kernel exposes as a segment, and nothing else - its cursor
		 * gives up quietly when there is no mouse ring.  It is also
		 * the first program in this tree to reach the allocator of
		 * the source-built libc: memimageinit and the memdraw layer
		 * are malloc and pool.
		 */
		{
			extern long ring_execv(char**);
			char *dargv[3];

			dargv[0] = "/boot/drawsrv";
			dargv[1] = "-m/dev";
			dargv[2] = nil;
			id = ring_execv(dargv);
			print("p9: pair-client: exec /boot/drawsrv started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/drawsrv (container %ld) exited with status %ld\n", id, st);
		}
		/*
		 * And the same binary again as nothing but a client, in a
		 * container of its own.  The mount the server made lives in
		 * the name space of the process that made it, and that
		 * process has gone; this one finds the server the way rio
		 * will, by the name postmountsrv posted in /srv, and mounts
		 * it for itself.
		 */
		{
			extern long ring_execv(char**);
			char *cargv[4];

			cargv[0] = "/boot/drawsrv";
			cargv[1] = "-c";
			cargv[2] = nil;		/* /dev is the default mount point */
			cargv[3] = nil;
			id = ring_execv(cargv);
			print("p9: pair-client: exec /boot/drawsrv -c started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/drawsrv -c (container %ld) exited with status %ld\n", id, st);
		}
		/*
		 * And rio.  It is 9front's own window system, 6407 lines this
		 * tree now builds itself, and nothing about it was written or
		 * changed for this machine.  It is started through the same
		 * draw binary with -x: that container mounts /srv/draw at
		 * /dev and execs rio in place, so rio opens /dev/draw and
		 * finds the screen where a window system expects it.  It is
		 * not waited for - a window system does not exit - so what it
		 * did is read off the screen afterwards.
		 */
		if(p9riodemo){
			extern long ring_execv(char**);
			char *rargv[3];

			rargv[0] = "/boot/drawsrv";
			rargv[1] = "-x/boot/rio";
			rargv[2] = nil;
			id = ring_execv(rargv);
			print("p9: pair-client: exec /boot/rio started container %ld\n", id);
		}
		/*
		 * And what is on the screen now.  A container of its own,
		 * which draws nothing: it maps the frame buffer the kernel
		 * exposes and reads it.
		 */
		if(p9riodemo){
			extern long ring_execv(char**);
			char *pargv[3];

			/*
			 * The waiting is the probe's, in its own container.
			 * The client cannot wait: this personality's
			 * cooperative scheduler has no idle - if every proc
			 * of it is in a timed sleep, nothing advances the
			 * clock that would wake them, and sched() panics
			 * with "no runnable proc (deadlock), tick 0".  A
			 * tsleep here to let rio paint did exactly that.
			 * sleep(2) in a container is the kernel's, and the
			 * kernel has a clock.
			 */
			pargv[0] = "/boot/drawsrv";
			pargv[1] = "-P6000";
			pargv[2] = nil;
			id = ring_execv(pargv);
			print("p9: pair-client: exec /boot/drawsrv -P started container %ld\n", id);
			if(id >= 0 && ring_wait(&st) == 0)
				print("p9: pair-client: wait: /boot/drawsrv -P (container %ld) exited with status %ld\n", id, st);
		}
	}
	/*
	 * The device-carried medium: put a network frame on the ring to the
	 * server container, where it is injected into the stack at that end.
	 * This is the osprey medium with its two ends in two containers, in
	 * the direction the request ring runs; the frame crosses the ring the
	 * kernel only routes, the way the plan's second machine would send it.
	 */
	{
		extern long ring9p_frame(uchar*, long, uchar*, long);
		uchar frame[28], back[64];
		long fn;
		ulong sum;
		int i;

		/*
		 * A real IPv4 packet, not filler: an ICMP echo request from
		 * 10.0.0.1 to 10.0.0.2, the address the server injects a ring
		 * frame into.  The osprey medium is a raw-IP medium (no MAC), so
		 * this is a whole frame.  The server's stack, if it accepts it,
		 * answers with an echo reply to 10.0.0.1 - which its other stack
		 * owns, so the reply terminates there and does not loop.
		 */
		for(i = 0; i < (int)sizeof frame; i++)
			frame[i] = 0;
		frame[0] = 0x45;			/* IPv4, header 20 bytes */
		frame[3] = sizeof frame;		/* total length */
		frame[8] = 64;				/* ttl */
		frame[9] = 1;				/* protocol ICMP */
		frame[12] = 10; frame[15] = 1;		/* src 10.0.0.1 */
		frame[16] = 10; frame[19] = 2;		/* dst 10.0.0.2 */
		sum = 0;				/* IP header checksum over frame[0..19] */
		for(i = 0; i < 20; i += 2)
			sum += (frame[i] << 8) | frame[i+1];
		while(sum >> 16)
			sum = (sum & 0xffff) + (sum >> 16);
		sum = ~sum & 0xffff;
		frame[10] = sum >> 8; frame[11] = sum;
		frame[20] = 8;				/* ICMP echo request */
		frame[25] = 1;				/* id */
		frame[27] = 1;				/* sequence */
		sum = 0;				/* ICMP checksum over frame[20..27] */
		for(i = 20; i < (int)sizeof frame; i += 2)
			sum += (frame[i] << 8) | frame[i+1];
		while(sum >> 16)
			sum = (sum & 0xffff) + (sum >> 16);
		sum = ~sum & 0xffff;
		frame[22] = sum >> 8; frame[23] = sum;

		fn = ring9p_frame(frame, sizeof frame, back, sizeof back);
		if(fn >= 0)
			print("p9: pair-client: sent an ICMP echo request (10.0.0.1->10.0.0.2) to the server container over the ring - the device-carried medium\n");
		else
			print("p9: pair-client: frame over the ring failed (%ld)\n", fn);
	}
	/*
	 * What a request costs, between two personalities: a thousand empty
	 * frame polls, each a request this container puts on the ring, the
	 * kernel carries to the server container, the server's loop takes
	 * by select and answers, and the kernel routes home - measured by
	 * the cycle counter, which the kernel's status line gives the rate
	 * of.  The talk's number is 270 ns for a send, a receive and a
	 * context switch; this is the microkernel's equivalent, two whole
	 * processes switched, under QEMU.
	 */
	{
		extern void ospreycycles(uvlong*);
		extern long ring9p_frame(uchar*, long, uchar*, long);
		uvlong t0, t1;
		uchar back[64];
		int i;

		ospreycycles(&t0);
		for(i = 0; i < 1000; i++)
			ring9p_frame(nil, 0, back, sizeof back);
		ospreycycles(&t1);
		print("p9: pair-client: 1000 requests put on the ring and answered by the server personality in %llud cycles: %llud cycles each\n",
			t1 - t0, (t1 - t0) / 1000);
	}
	/*
	 * And the same wire carrying a whole stack's traffic, not a frame
	 * built by hand: this container brings up the real Plan 9 IP stack
	 * of its own, with an interface whose wire is the ring, and its
	 * tcp.c talks to the server container's tcp.c across it.
	 */
	p9clientnet();
	poperror();
}

extern void p9serveloop(char *arg);	/* p9pairsrv.c: the ring service loop */
extern void p9linuxfile(void);		/* p9linuxfile.c: the legacy binary as /boot/linux */
extern void p9ipup(void);

/*
 * The buddy server: bring up this personality's name space, then answer
 * 9P about it for whoever delegates to this container over the ring.
 */
/*
 * The file system on the disk: mount the log-structured store (#l, on
 * the block device the kernel exposed and blkvirtio.c drives) at /n of
 * this personality's name space, where the client reaches it over 9P,
 * and make sure it holds a file.  On a fresh disk that file is created
 * here as version 1; on a disk that has been through this before it is
 * found, with whatever version was last committed to it.  Called from
 * the serve loop once the device is up; without a device there is
 * nothing to mount and nothing is said.
 */
void
p9lfsmount(void)
{
	extern int blkready(void);
	Chan *lc, *nc;
	char buf[256];
	int fd;
	long n;

	if(!blkready())
		return;
	if(waserror()){
		print("lfs: mount failed: %s\n", up->errstr);
		return;
	}
	lc = namec("#l", Atodir, 0, 0);
	nc = namec("/n", Atodir, 0, 0);
	cmount(lc, nc, MREPL|MCREATE, "");
	cclose(lc);
	cclose(nc);
	poperror();
	print("lfs: mounted at /n of the server personality's name space\n");
	fd = -1;
	if(!waserror()){		/* a fresh disk has no such file: open raises, and it is made below */
		fd = p9open("/n/hello", OREAD);
		n = p9read(fd, buf, sizeof buf - 1);
		if(n < 0)
			n = 0;
		buf[n] = 0;
		print("lfs: found /n/hello on the disk: \"%s\"\n", buf);
		p9close(fd);
		poperror();
	}
	if(fd < 0){
		if(waserror()){
			print("lfs: create /n/hello: %s\n", up->errstr);
			return;
		}
		fd = p9create("/n/hello", OWRITE, 0666);
		p9write(fd, "hello from the log-structured store, version 1", 46);
		p9close(fd);
		poperror();
		print("lfs: created /n/hello, version 1\n");
	}
}

void
p9server(char *arg)
{
	if(waserror()){
		print("p9: buddy-server error: %s\n", up->errstr);
		exits("error");
	}
	p9linuxfile();		/* the legacy Linux binary, a file in this file system */
	p9setup();
	p9ipup();
	print("p9: server personality: name space up, answering 9P over the ring\n");
	p9serveloop(arg);
	poperror();
}

void
startboot(char *argv0, char **argv)
{
	if(argv0 != nil && argv0[0] == 's'){
		p9server(argv0);	/* the buddy: a 9P server of this name space over the ring */
		exits(nil);
	}
	if(argv0 != nil && argv0[0] == 'c'){
		/* "c rio": the kernel was configured to start a window system */
		p9riodemo = strstr(argv0, "rio") != nil;
		p9paircli();		/* the buddy's client: mount it and read its files */
		exits(nil);
	}
	/*
	 * "legacy": run the unmodified Plan 9 binary as well.  It is asked
	 * for rather than always done, because what it does to the machine
	 * is end it - its exits is a real system call, made by real libc,
	 * and this personality has nothing between it and the kernel that
	 * would catch it - so the boot that carries it is not the boot the
	 * rest of the checks are written against.
	 */
	p9legacydemo = argv != nil && argv[1] != nil
		&& strncmp(argv[1], "legacy", 6) == 0;
	p9legacyserve = p9legacydemo && strcmp(argv[1], "legacy") == 0;
	print("p9: entered as \"%s\" with %s\n", argv0 == nil ? "" : argv0,
		argv == nil ? "no vector" :
		argv[1] == nil ? "one word" : argv[1]);
	p9main();
}
