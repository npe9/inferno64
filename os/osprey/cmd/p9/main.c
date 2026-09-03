#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ring9p.h"
#include "p9file.h"

extern void p9init(void);
extern void exits(char*);
void p9server(char *arg);
void p9paircli(void);
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
	chandevreset();
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
	print("p9: name space up, root attached\n");
}

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
	p9setup();

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
	}

	/*
	 * A union directory read: list "/" itself, which by now is a union of
	 * the root device, the environment mounted onto it, and the 9P server
	 * mounted onto it.  One listing spans all three, the way a Plan 9
	 * union does - the root's boot and bin, the environment's variables,
	 * and the server's hello, motd, readme and scratch, together.
	 */
	{
		int dfd, nent = 0;
		long dn;
		uchar *p, *e;
		Dir dir;
		char names[256];
		int m;

		dfd = p9open("/", OREAD);
		print("p9: ls / (a union of the root device, the environment and the 9P mount):\n");
		while((dn = p9read(dfd, buf, sizeof buf)) > 0){
			p = buf;
			e = buf + dn;
			while(p < e){
				m = convM2D(p, (uint)(e - p), &dir, names);
				if(m <= 0)
					break;
				print("p9:   %s\n", dir.name);
				nent++;
				p += m;
			}
		}
		print("p9: the union listing spanned %d entries across three mounted members\n", nent);
		p9close(dfd);
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
	}
	poperror();
}

extern void p9serveloop(char *arg);	/* p9pairsrv.c: the ring service loop */
extern void p9linuxfile(void);		/* p9linuxfile.c: the legacy binary as /boot/linux */

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
		p9paircli();		/* the buddy's client: mount it and read its files */
		exits(nil);
	}
	USED(argv);
	p9main();
}
