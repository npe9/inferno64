/*
 * The name space, from a program the library operating system loaded.
 *
 * bind(2), chdir(2) and unmount(2) were the personality's own until
 * now: a program it loaded could open a name but could not change what
 * a name meant.  A library operating system whose caller cannot bind is
 * not offering a name space, it is offering a fixed list of names, and
 * rio is what made that concrete - linked against this library with the
 * archive of system-call stubs left off, four of the eight things it
 * asks for are bind, mount, unmount and chdir.
 *
 * What this program does is the smallest thing that cannot pass by
 * accident.  It opens /boot/libcat by its whole name, so there is
 * something known to compare against.  Then it chdirs to /boot and
 * opens "libcat" with no slash in it, which can only resolve through
 * the working directory the chdir set.  Then it binds /boot onto /n and
 * opens /n/libcat, which can only resolve through the binding.  Then it
 * unmounts /n and opens /n/libcat again, which must now fail - an
 * unmount that did nothing would leave a test of bind alone passing.
 *
 * The name space it changes is the personality's, because there is one
 * of them: the program and the library share an address space and a
 * Pgrp both.  So it puts /n back the way it found it before it ends,
 * and says so, rather than leaving the library's own names altered by a
 * program that has finished.
 */
#include <u.h>
#include <libc.h>

extern int spawn(char *name, char **argv, int in, int out);

/*
 * The environment is files under /env, so putting a variable in it is a
 * create and a write and reading one is an open and a read.  libc has
 * getenv and putenv for this; they are written out here because what is
 * being tested is which Egrp the open lands in, and a wrapper of its own
 * makes that plain.
 */
static void
envset(char *name, char *val)
{
	char path[64];
	int fd;

	snprint(path, sizeof path, "/env/%s", name);
	fd = create(path, OWRITE, 0666);
	if(fd < 0){
		print("libns: cannot create %s: %r\n", path);
		return;
	}
	if(write(fd, val, strlen(val)) != strlen(val))
		print("libns: cannot write %s: %r\n", path);
	close(fd);
}

static char*
envget(char *name)
{
	static char buf[64];
	char path[64];
	int fd;
	long n;

	snprint(path, sizeof path, "/env/%s", name);
	buf[0] = 0;
	fd = open(path, OREAD);
	if(fd < 0)
		return "<not there>";
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n < 0)
		return "<unreadable>";
	buf[n] = 0;
	return buf;
}

static int
sizeof9(char *name)
{
	int fd;
	char buf[256];
	long n, tot;

	fd = open(name, OREAD);
	if(fd < 0)
		return -1;
	/*
	 * How much of it reads, not how long it is: the point is that the
	 * three names reach the same file, and reading a fixed amount off
	 * each is enough to say so without reading a megabyte three times.
	 */
	tot = 0;
	while((n = read(fd, buf, sizeof buf)) > 0){
		tot += n;
		if(tot >= 4096)
			break;
	}
	close(fd);
	if(n < 0)
		return -1;
	return (int)tot;
}

void
startboot(char *argv0, char **argv)
{
	int whole, bydot, bybind, after, held;
	char one[16];

	USED(argv0);
	USED(argv);

	whole = sizeof9("/boot/libcat");
	print("libns: /boot/libcat by its whole name reads %d bytes of it\n", whole);

	if(chdir("/boot") < 0)
		print("libns: chdir /boot failed: %r\n");
	bydot = sizeof9("libcat");
	print("libns: after chdir /boot, \"libcat\" with no slash in it reads %d\n", bydot);

	if(bind("/boot", "/n", MREPL) < 0)
		print("libns: bind /boot onto /n failed: %r\n");
	bybind = sizeof9("/n/libcat");
	print("libns: after bind /boot onto /n, /n/libcat reads %d\n", bybind);

	if(unmount(nil, "/n") < 0)
		print("libns: unmount /n failed: %r\n");
	after = sizeof9("/n/libcat");
	print("libns: after unmount /n, /n/libcat reads %d (a failure is -1, which is the point)\n",
		after);

	/*
	 * And put the library's own name space back.  #K on /n is what the
	 * personality bound there; a program that alters a name space it
	 * shares and walks away has left the library changed.
	 */
	if(bind("#K", "/n", MREPL) < 0)
		print("libns: could not put #K back on /n: %r\n");
	else
		print("libns: #K is back on /n, which is where the personality had it\n");

	/*
	 * Then take a name space of this program's own and do it again, to
	 * show the difference.  rfork(RFNAMEG) is a copy: everything that
	 * resolved a moment ago still resolves, and what is bound now is
	 * bound here and nowhere else.  The program cannot see the other
	 * side of that itself - it has only its own name space to look
	 * through - so it says what it did and the personality says what it
	 * still sees afterwards, and the two together are the claim.
	 */
	if(rfork(RFNAMEG) < 0)
		print("libns: rfork(RFNAMEG) failed: %r\n");
	else
		print("libns: rfork(RFNAMEG) gave me a name space of my own\n");
	print("libns: in it, /boot/libcat still reads %d, so it is a copy and not an empty one\n",
		sizeof9("/boot/libcat"));
	if(bind("/boot", "/n", MREPL) < 0)
		print("libns: private bind of /boot onto /n failed: %r\n");
	print("libns: in my own name space /n/libcat reads %d, and the personality should not see it\n",
		sizeof9("/n/libcat"));

	/*
	 * And the environment, which is the same question asked of a
	 * different group.  A variable put in the shared Egrp is the
	 * library's; one put in a group of this program's own is not, and
	 * the shell's next command is what shows the difference - the same
	 * two-halves shape the name space needed, because a program cannot
	 * see out of its own groups either.
	 */
	envset("libnsshared", "before");
	if(rfork(RFENVG) < 0)
		print("libns: rfork(RFENVG) failed: %r\n");
	else
		print("libns: rfork(RFENVG) gave me an environment of my own\n");
	print("libns: in it, libnsshared is \"%s\", so it is a copy and not an empty one\n",
		envget("libnsshared"));
	envset("libnsprivate", "after");
	print("libns: and libnsprivate is \"%s\" here, where the personality should not see it\n",
		envget("libnsprivate"));

	/*
	 * await(2), which is what libc's wait() is written on and rio's
	 * wait is written on that.  Two copies of one module are started -
	 * cat is relocatable, so two of it run at once - and waited for
	 * without naming either: await answers whichever ended, in the
	 * order they ended, and the line it answers is parsed here with
	 * tokenize, which is the same parser libc's wait() uses on it.
	 * Five fields or it is not an await line.
	 *
	 * Then a third wait, with nothing left of this program's own to end,
	 * which has to fail: a wait that answered anyway would be waiting
	 * for somebody else's program, and a wait that hung would be worse.
	 */
	{
		char *catav[3], line[256], *fld[5];
		int p1, p2, i, nf, n;

		/*
		 * Something small to read.  /env/libnsshared holds six bytes
		 * and the children inherit this program's groups, so they can
		 * see it; the first version of this handed cat the megabyte of
		 * /boot/libcat and the console write failed part way through,
		 * which was a bad argument and not a bad await - but it is why
		 * the file is named rather than left to be any file at all.
		 */
		catav[0] = "/boot/libcat";
		catav[1] = "/env/libnsshared";
		catav[2] = nil;
		/* -1 for each end: their console is the machine's, as this one's is */
		p1 = spawn("/boot/libcat", catav, -1, -1);
		p2 = spawn("/boot/libcat", catav, -1, -1);
		print("libns: started two of /boot/libcat, as %d and %d\n", p1, p2);
		for(i = 0; i < 2; i++){
			n = await(line, sizeof line - 1);
			if(n < 0){
				print("libns: await %d of 2 failed: %r\n", i+1);
				continue;
			}
			line[n] = 0;
			nf = tokenize(line, fld, 5);
			if(nf != 5){
				print("libns: await gave %d fields, not the 5 libc's wait parses\n", nf);
				continue;
			}
			print("libns: await says %s ended, status \"%s\", in %s %s %s ms\n",
				fld[0], fld[4], fld[1], fld[2], fld[3]);
		}
		if(await(line, sizeof line - 1) < 0)
			print("libns: a third await, with none of mine left, refused: %r\n");
		else
			print("libns: a third await answered, which would be somebody else's program\n");
	}

	/*
	 * And the descriptor table.  A spawned program's table is already
	 * its own - spawn built it - so what RFFDG separates is the program
	 * from itself after the call, which nothing outside can see.  What
	 * can be seen from inside is the difference between the two bits: a
	 * descriptor opened before the rfork still reads after RFFDG,
	 * because that is a copy, and does not after RFCFDG, because that
	 * is an empty table.  print does not go through a descriptor here -
	 * it is the console, the one trap a loaded program makes - so the
	 * program can still say what happened after emptying its own table.
	 */
	held = open("/boot/libcat", OREAD);
	if(held < 0)
		print("libns: cannot open /boot/libcat to hold: %r\n");
	if(rfork(RFFDG) < 0)
		print("libns: rfork(RFFDG) failed: %r\n");
	print("libns: after rfork(RFFDG) the descriptor I held reads %ld, because that is a copy\n",
		read(held, one, sizeof one));
	if(rfork(RFCFDG) < 0)
		print("libns: rfork(RFCFDG) failed: %r\n");
	print("libns: after rfork(RFCFDG) it reads %ld, because that is an empty table\n",
		read(held, one, sizeof one));

	/*
	 * And the bits that are not a group this personality has are refused
	 * rather than quietly granted.  RFPROC is the one that matters: a
	 * success that did nothing would leave a caller believing it had a
	 * second flow of control and running as one.
	 */
	if(rfork(RFPROC) < 0)
		print("libns: rfork(RFPROC) refused: %r\n");
	else
		print("libns: rfork(RFPROC) was granted, which this personality cannot mean\n");

	if(whole > 0 && bydot == whole && bybind == whole && after < 0)
		print("libns: the name space is the program's to change: "
			"three ways to one file, %d bytes off each, and the fourth refused\n", whole);
	else
		print("libns: that is not the name space I asked for: "
			"whole %d, by chdir %d, by bind %d, after unmount %d\n",
			whole, bydot, bybind, after);
	exits(nil);
}
