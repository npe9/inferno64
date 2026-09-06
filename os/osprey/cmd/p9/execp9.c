/*
 * exec - an ordinary Plan 9 program that replaces itself, over and over,
 * to show that exec(2) works for a legacy binary on the server
 * personality.  This is the exec a shell makes after it forks: the same
 * process, the same container, a new program in it - not the exec
 * request that starts a program in a container of its own.
 *
 * Three things are proven, and the first is the one that matters most.
 *
 * A bad name is a refusal, not a killing: the program execs a file that
 * is not there, is told -1, and goes on running.  The buddy holds the
 * image this process is paging from, so an exec that threw that away
 * before it knew the new binary parsed would leave a process that cannot
 * fault - which is what a shell's mistyped command would have done.
 *
 * A descriptor survives the exec: the file is opened before the first
 * exec and read through the same descriptor number in every image after
 * it.  The buddy holds the descriptor table, and exec does not touch it.
 *
 * And it is done twenty times over, because the way exec leaves the
 * kernel - out through touser rather than back through the system call -
 * leaks the call's error label unless the label is dropped, and one exec
 * cannot tell a leak from none.
 */
#include <u.h>
#include <libc.h>

enum { Ngen = 20 };

/*
 * Read the file through the descriptor opened before the first exec,
 * from the start each time.  Every generation reads; only the ones
 * worth seeing say so, since twenty of these on the console would
 * crowd out the rest of the boot.
 */
static void
readthrough(int fd, int gen, int say)
{
	char buf[64];
	long n;
	vlong off;

	off = seek(fd, 0, 0);
	if(off != 0)
		print("exec: generation %d: seek of descriptor %d to 0 answered %lld\n", gen, fd, off);
	n = read(fd, buf, sizeof buf - 1);
	if(n <= 0){
		print("exec: generation %d: the inherited descriptor %d read nothing\n", gen, fd);
		return;
	}
	buf[n] = 0;
	if(buf[n-1] == '\n')
		buf[n-1] = 0;
	if(say)
		print("exec: generation %d read through the inherited descriptor %d: %s\n", gen, fd, buf);
}

void
startboot(char *argv0, char **argv)
{
	int argc, fd, gen;
	char fs[16], gs[16];
	char *a[4];

	USED(argv0);
	for(argc = 0; argv[argc] != nil; argc++)
		;
	if(argc < 3){
		char *bad[2];

		print("exec: the first image, started with %d arguments\n", argc);
		fd = open("/n/hello", OREAD);
		if(fd < 0){
			print("exec: cannot open /n/hello\n");
			exits("open");
		}
		readthrough(fd, 0, 1);
		/*
		 * The negative control, first: a name the buddy cannot lay out.
		 * The exec must fail and this program must still be here to say
		 * so - and to go on paging from the image it is running on,
		 * which the read below shows.
		 */
		bad[0] = "notthere";
		bad[1] = nil;
		if(exec("/boot/notthere", bad) < 0)
			print("exec: exec of /boot/notthere was refused, as it should be, and I am still running\n");
		else
			print("exec: BUG: exec of /boot/notthere did not fail\n");
		readthrough(fd, 0, 1);
		gen = 1;
	} else {
		fd = atoi(argv[1]);
		gen = atoi(argv[2]);
		readthrough(fd, gen, gen == 1 || gen == Ngen);
		if(gen >= Ngen){
			print("exec: %d generations, each a whole exec of this binary in this same process, and the descriptor opened before the first is still open\n", Ngen);
			exits(nil);
		}
		gen++;
	}
	snprint(fs, sizeof fs, "%d", fd);
	snprint(gs, sizeof gs, "%d", gen);
	a[0] = "exec";
	a[1] = fs;
	a[2] = gs;
	a[3] = nil;
	exec("/boot/exec", a);
	print("exec: exec of /boot/exec failed at generation %d\n", gen);
	exits("exec");
}
