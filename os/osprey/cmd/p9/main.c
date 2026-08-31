#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ring9p.h"
#include "p9file.h"

extern void p9init(void);
extern void exits(char*);

/*
 * Bring up a Plan 9 name space as user code and walk it: attach the root
 * device, open "/" and read it, then prove the name space is a name
 * space and not one device - mount a second device (the environment) and
 * resolve a name with no '#' in it across the mount table into it.  All
 * of attach, walk, open, read, cmount and the union walk run through
 * chan.c and real devices, in a user process on the microkernel.
 */
void
p9main(void)
{
	Chan *c, *ec, *tc, *mc;
	uchar buf[2048];
	long n;
	int mnttype;

	p9init();
	if(waserror()){
		print("p9: error: %s\n", up->errstr);
		exits("error");
	}
	chandevreset();
	up->pgrp = newpgrp();
	up->slash = namec("#/", Atodir, 0, 0);
	pathclose(up->slash->path);
	up->slash->path = newpath("/");
	up->dot = cclone(up->slash);
	chandevinit();
	print("p9: name space up, root attached\n");

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
	up->egrp = smalloc(sizeof(Egrp));
	up->egrp->ref = 1;
	up->fgrp = smalloc(sizeof(Fgrp));
	up->fgrp->ref = 1;

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

	poperror();
	exits(nil);
}

void
startboot(char *argv0, char **argv)
{
	USED(argv0); USED(argv);
	p9main();
}
