/*
 * The library operating system as a program's libc.
 *
 * An ordinary Plan 9 program calls open, read, write and close, and on
 * Plan 9 those are system calls.  Here they are not: the file system is
 * a library in the program's own address space, and this is what makes
 * the program's own libc call it.  Each of these definitions comes
 * before libc.a on the link line, so the linker takes this one and never
 * pulls libc's system-call stub for it - the program's source is
 * unchanged and does not know.
 *
 * What is still a trap is what the personality does not hold: the
 * machine's console (descriptors 0, 1 and 2, through the microkernel's
 * pwrite) and nothing else.  Even exit is not a trap: a program that
 * ends returns to the personality that loaded it, which goes on running.
 *
 * The heap is the program's own, a fixed arena in its bss.  brk on this
 * address space is the personality's business - its segments are laid
 * out around this program, not below it - so a loaded program does not
 * ask the kernel for memory, it brings its own.
 */
#include <u.h>
#include <libc.h>
#include <tos.h>
#include "p9lib.h"

P9lib *p9lib;

/*
 * The console, and the only trap in this file: see p9cons.s.
 */
extern long p9conswrite(int fd, void *buf, long n, vlong off);

/*
 * The top of stack a loaded program does not have.
 *
 * libc's allocator keys its pool on _tos->pid: plock stores it and
 * punlock compares it, so that a pool cannot be unlocked by a process
 * other than the one that locked it.  _tos is set up by libc's own
 * _main out of the page the kernel leaves at the top of the stack, and
 * a program loaded here is entered at p9start rather than at _main and
 * shares the personality's address space, so it has none: _tos was nil
 * and the first malloc read address 0x40, which is where pid sits in a
 * Tos.  A graphics program mallocs before it draws anything, so the
 * fault was the first thing that happened.
 *
 * This is that Tos.  One program is one flow of control here - spawn
 * gives a program a kproc of its own, not a second thread inside one -
 * so the number only has to be the program's own and stay the same
 * while it runs.
 */
static Tos p9tos;

/*
 * And the privates, for the same reason and found the same way.
 *
 * privalloc(2) hands out one word of a per-process block and returns nil
 * when there are none, and libc's callers do not check: nsec(2), which
 * is a read of /dev/bintime and not a system call, keeps its descriptor
 * in a private and stores through whatever it got.  _privates is set up
 * by libc's own _main out of the top of stack a loaded program does not
 * have, so it was nil and the store was to address 0 - the same fault
 * the missing Tos gave, at a different offset.
 *
 * init9tos.c, which does this for the programs the buddy loads, puts the
 * block on the caller's frame because rfork(RFPROC|RFMEM) shares the bss
 * and a private has to be per process.  Here it is the same: the block
 * is p9start's own, and p9start is the frame the whole program runs
 * inside.
 */
extern void **_privates;
extern int _nprivates;
enum { Nprivates = 16 };

extern void startboot(char *argv0, char **argv);

/*
 * p9start must be the first thing in this file: it is the first thing in
 * the linked program's text, and that is how the loader recovers the
 * address the program was linked at (p9exec.c).  Everything else, the
 * descriptor table below included, comes after it.
 */
static void fdinit(int *std);
static void **fdpriv;		/* this flow's descriptor table, or nil for the program's */
static int fdof(int fd);
static int fdnew(int pfd);

void
p9start(P9lib *lib, char **argv, int *std)
{
	static char *noargv[] = { "prog", nil };
	void *privates[Nprivates];
	int i;

	p9tos.pid = 1;			/* before anything mallocs: see p9tos above */
	_tos = &p9tos;
	for(i = 0; i < Nprivates; i++)
		privates[i] = nil;
	_privates = privates;
	_nprivates = Nprivates;
	fdinit(std);
	p9lib = lib;
	if(lib == nil || lib->version != P9libversion){
		/* nothing to call: say so on the console, which is the kernel's */
		char *m = "p9crt: the library handed me a table I do not know\n";
		p9conswrite(2, m, strlen(m), -1LL);
		return;
	}
	if(argv == nil || argv[0] == nil)
		argv = noargv;
	startboot(argv[0], argv);
	lib->exits(nil);
}
/*
 * The program's own descriptor table.
 *
 * The personality's descriptors are its own small integers and it hands
 * out whatever is free, which may be 0, 1 or 2 - and for a program those
 * three are the console, which the personality does not hold.  Without a
 * table of its own a program that opened a file and got 1 would write
 * its output into that file, or into the console, by luck rather than by
 * meaning.  So the program keeps a table, the way the buddy keeps one
 * for the legacy binary it serves: every file the program opens is
 * numbered from three up and stands for a descriptor of the
 * personality's.
 *
 * 0, 1 and 2 are what the loader handed the program in std: a
 * descriptor of the personality's when it was started with one - a pipe
 * from a shell, say - and the machine's console when it was not, which
 * is what a program the personality runs itself gets.
 */
enum {
	Nfd	= 32,
	Fdfree	= -1,
	Fdcons	= -2,
	Nfdtab	= 8,		/* flows that may have a table of their own */
};

/*
 * The program's own table, shared by every flow of control it has -
 * which is what rfork without RFFDG means, and what a second flow made
 * by proccreate gets.
 *
 * A flow that rforks RFFDG or RFCFDG gets one of its own, and that is
 * not a nicety.  This numbering is the program's, not the
 * personality's, so one array for the whole program meant a close in
 * one flow freed the number in every flow - and rio's winshell begins
 * by closing the server end of the pipe its file server is reading,
 * which is safe on Plan 9 precisely because it rforked first.  Here it
 * took the number out from under rio's own file server, which then read
 * end of file on its own channel and shut the window system down.  The
 * personality-side table was already per-flow by then; this is the
 * program-side half of the same thing.
 *
 * The word that says which table is a privalloc(2) word, which is the
 * one mechanism here for something a flow has of its own: the
 * personality swaps its contents at every switch.  Nil means the
 * program's, so a flow that never rforked, and one made after this one
 * did, both share - which is right.
 */
static int fdmap[Nfd];
static int fdpool[Nfdtab][Nfd];
static int fdpoolused[Nfdtab];

static int*
fdtab(void)
{
	if(fdpriv != nil && *fdpriv != nil)
		return (int*)*fdpriv;
	return fdmap;
}

static void
fdtabfree(int *t)
{
	int i;

	for(i = 0; i < Nfdtab; i++)
		if(fdpool[i] == t)
			fdpoolused[i] = 0;
}

/* a table for a flow that is about to have one of its own */
static int*
fdtabnew(void)
{
	int i;

	for(i = 0; i < Nfdtab; i++)
		if(!fdpoolused[i]){
			fdpoolused[i] = 1;
			return fdpool[i];
		}
	return nil;
}

static void
fdinit(int *std)
{
	int i;

	for(i = 0; i < Nfd; i++)
		fdmap[i] = Fdfree;
	for(i = 0; i < 3; i++)
		fdmap[i] = (std == nil || std[i] < 0) ? Fdcons : std[i];
}

/* the personality's descriptor a program's number stands for, or Fdfree */
static int
fdof(int fd)
{
	if(fd < 0 || fd >= Nfd)
		return Fdfree;
	return fdtab()[fd];
}

/* a program number for a personality descriptor just opened */
static int
fdnew(int pfd)
{
	int *t;
	int i;

	if(pfd < 0)
		return -1;
	/*
	 * The lowest free number, which is what open(2) answers and
	 * includes 0, 1 and 2 once a program has closed them.  This
	 * started at 3, to keep the standard descriptors out of the way,
	 * and that is not what a Plan 9 program expects: rio's winshell
	 * closes 0 and opens /dev/cons expecting the window to become its
	 * standard input, closes 1 and opens it again for output, and does
	 * not look at what number it got.  Starting at 3 handed it 3 and 4
	 * and left 0 and 1 as the machine's console, so the shell rio then
	 * started read and wrote the console instead of the window.
	 */
	t = fdtab();
	for(i = 0; i < Nfd; i++)
		if(t[i] == Fdfree){
			t[i] = pfd;
			return i;
		}
	p9lib->close(pfd);
	return -1;
}


/*
 * The file calls, into the personality.  Nothing here traps.
 */
/*
 * A descriptor named in a path.
 *
 * /fd/<n> is the calling process's descriptor n, and n here is this
 * program's number rather than the personality's: p9crt.c keeps the
 * table, so it owns what that path means for this program just as it
 * owns what the number means in a call.  Without this, a path built
 * from a number the program holds names some other descriptor of the
 * personality's, or none - which is how libthread's procexec failed.
 * It makes a pipe, opens
 *	/fd/<the write end>
 * to get a close-on-exec copy, and that open answered Enonexist.
 *
 * Only the plain forms are translated, and only when the number really
 * is one of this program's: anything else is passed through untouched,
 * because /fd is a directory with other things in it and this is a
 * translation, not a takeover.
 */
static char*
fdpath(char *name, char *buf, int nbuf)
{
	char *p, *e;
	int n, pfd;

	if(strncmp(name, "/fd/", 4) == 0)
		p = name + 4;
	else if(strncmp(name, "#d/", 3) == 0)
		p = name + 3;
	else
		return name;
	if(*p < '0' || *p > '9')
		return name;
	n = 0;
	for(e = p; *e >= '0' && *e <= '9'; e++)
		n = n*10 + (*e - '0');
	if(*e != 0)
		return name;			/* something below it, not a descriptor */
	pfd = fdof(n);
	if(pfd < 0)
		return name;			/* the console, or not open: let it fail as it would */
	snprint(buf, nbuf, "%.*s%d", (int)(p - name), name, pfd);
	return buf;
}

int
open(char *name, int mode)
{
	char buf[64];

	return fdnew(p9lib->open(fdpath(name, buf, sizeof buf), mode));
}

int
create(char *name, int mode, ulong perm)
{
	return fdnew(p9lib->create(name, mode, perm));
}

long
read(int fd, void *buf, long n)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return 0;		/* end of file on the console: nothing types here */
	if(pfd == Fdfree)
		return -1;
	return p9lib->read(pfd, buf, n);
}

/*
 * write: the console is the machine's, not the personality's, so 0, 1
 * and 2 go to the microkernel through the one call it offers for it and
 * everything else goes to the file system beside us.
 */
long
write(int fd, void *buf, long n)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return p9conswrite(fd, buf, n, -1LL);
	if(pfd == Fdfree)
		return -1;
	return p9lib->write(pfd, buf, n);
}

/*
 * pread and pwrite: the same two calls with the offset given rather than
 * the descriptor's own.  They were libc's system-call stubs before, and
 * a program that reached one of those did not get an error - it trapped
 * into a microkernel that does not answer the Plan 9 table, and the
 * fault was the end of it.  libdraw reaches pread: namedimage writes an
 * 'n' message to the draw device's data file and then reads the answer
 * out of its control file at offset 0, and there is no libdraw without
 * that read.
 *
 * The console is a write and nothing else, so a pread of it is the end
 * of file a read of it is, and a pwrite of it ignores the offset the way
 * the console does.
 */
long
pread(int fd, void *buf, long n, vlong off)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return 0;		/* end of file: nothing types here */
	if(pfd == Fdfree)
		return -1;
	return p9lib->pread(pfd, buf, n, off);
}

long
pwrite(int fd, void *buf, long n, vlong off)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdcons)
		return p9conswrite(fd, buf, n, -1LL);
	if(pfd == Fdfree)
		return -1;
	return p9lib->pwrite(pfd, buf, n, off);
}

/*
 * stat and fstat: the raw stat message, which is what libc's dirstat and
 * dirfstat parse into a Dir.  A program that asks how long a file is
 * asks this way.
 */
int
stat(char *name, uchar *edir, int nedir)
{
	return p9lib->stat(name, edir, nedir);
}

int
fstat(int fd, uchar *edir, int nedir)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd < 0)
		return -1;
	return p9lib->fstat(pfd, edir, nedir);
}

/*
 * The name space, bind(2), mount(2), unmount(2) and chdir(2).  A
 * program on this personality shares the library's name space rather
 * than having one of its own, so what it binds the library sees; that
 * is written down in p9lib.h and is not hidden from the caller.
 *
 * mount takes one of the program's own descriptors and hands the
 * personality the descriptor it stands for, the way every other call
 * that takes an fd here does.
 */
int
bind(char *name, char *old, int flag)
{
	return p9lib->bind(name, old, flag);
}

int
mount(int fd, int afd, char *old, int flag, char *spec)
{
	int pfd;

	/*
	 * afd is authentication, which this personality has nothing behind:
	 * a caller that asks for it is told no rather than quietly mounted
	 * without it.
	 */
	if(afd >= 0)
		return -1;
	pfd = fdof(fd);
	if(pfd < 0)
		return -1;
	return p9lib->mount(pfd, old, flag, spec);
}

int
unmount(char *name, char *old)
{
	return p9lib->unmount(name, old);
}

int
chdir(char *name)
{
	return p9lib->chdir(name);
}

/*
 * notify(2), for the one thing it can honestly mean here.
 *
 * notify(nil) says "no note handler", and there is none: nothing on
 * this personality posts a note to a loaded program.  A loaded program
 * is a kproc of a cooperative scheduler that the microkernel does not
 * know about, the note tree in devnote.c is the buddy's and is about
 * the kernel's own containers, and a program's flow of control is never
 * interrupted between one instruction and the next.  So nil is answered
 * truthfully and is not a bit that does nothing: it asks for no handler
 * and gets none.
 *
 * A handler is refused, by name.  Recording one that nothing would ever
 * call is exactly the failure this table has been refusing all along -
 * a caller would write a handler, be told it was installed, and find
 * out otherwise only when a note it was counting on went nowhere.  rio
 * calls notify(nil) in winshell and that is what it gets; a rio that
 * wanted a handler would be told no rather than misled.
 */
int
notify(void (*f)(void*, char*))
{
	char e[ERRMAX];

	if(f == nil)
		return 0;
	/*
	 * The reason goes where %r reads it.  errstr(2) here is an
	 * exchange, as it is on Plan 9 - it hands back what was there and
	 * installs what it was given - so writing the reason is a call to
	 * the same entry a program reads one with.
	 */
	snprint(e, sizeof e, "notify: this personality posts no notes to a "
		"loaded program, so a handler would never be called");
	errstr(e, sizeof e);
	return -1;
}

/*
 * await(2), which is what libc's wait() is written on and rio's wait is
 * written on that.  The kernel's await hands back one line that
 * tokenize splits into five fields - the pid, three times and the exit
 * status - and the status is quoted because it may hold blanks.
 *
 * The three times are 0.  This personality does not account processor
 * time to a loaded program: every flow of control is a kproc of one
 * cooperative scheduler and nothing charges the clock to one of them.
 * Reporting zeroes is the honest answer to a question nothing here
 * measures, and it is said rather than left to be inferred from a
 * number that looked plausible.
 */
static int
quoted(char *p, char *e, char *s)
{
	char *b;

	b = p;
	if(p < e)
		*p++ = '\'';
	for(; *s != 0; s++){
		if(*s == '\''){		/* a quote inside is doubled */
			if(p < e)
				*p++ = '\'';
		}
		if(p < e)
			*p++ = *s;
	}
	if(p < e)
		*p++ = '\'';
	return (int)(p - b);
}

int
await(char *buf, int n)
{
	char status[ERRMAX], line[ERRMAX+64];
	char *p, *e;
	int pid, k;

	status[0] = 0;
	pid = p9lib->waitany(status, sizeof status);
	if(pid < 0)
		return -1;
	p = line;
	e = line + sizeof line;
	p += snprint(p, (int)(e - p), "%d 0 0 0 ", pid);
	p += quoted(p, e, status);
	k = (int)(p - line);
	if(k > n)
		k = n;
	memmove(buf, line, k);
	return k;
}

/*
 * rfork(2).  The name-space bits are answered and the rest are refused
 * by name: a program that asks for RFPROC here has asked the library to
 * split its caller's flow of control, which spawn and proccreate are
 * what there is for.  Refusing loudly is the point - a success that did
 * nothing would show up much later as a program sharing what it asked
 * not to share.
 */
int
rfork(int flags)
{
	int *nt, *ot;
	int i, r;

	/*
	 * The descriptor half is this program's to do, because this
	 * numbering is this program's.  The table is taken before the
	 * personality is asked, so that running out of tables refuses
	 * before anything has changed rather than after.
	 */
	nt = nil;
	if((flags & (RFFDG|RFCFDG)) != 0){
		char e[ERRMAX];

		/*
		 * The word that says which table this flow is using, claimed
		 * when a flow first asks for a table of its own and not
		 * before.  privalloc(2) hands out a word and never takes one
		 * back - the personality has a fixed block of them for the
		 * whole boot - so claiming one at every program's start spent
		 * them all on programs that never rfork, and the ones that
		 * did were refused.  That cost fifteen criteria and was found
		 * the same way everything else here was: by the boot.
		 */
		if(fdpriv == nil){
			fdpriv = p9lib->privalloc();
			if(fdpriv == nil){
				snprint(e, sizeof e,
					"rfork: the personality has no private word left "
					"for a descriptor table");
				errstr(e, sizeof e);
				return -1;
			}
			*fdpriv = nil;
		}
		if((nt = fdtabnew()) == nil){
			snprint(e, sizeof e, "rfork: all %d descriptor tables of mine are taken",
				Nfdtab);
			errstr(e, sizeof e);
			return -1;
		}
	}
	r = p9lib->forkns(flags);
	if(r < 0){
		if(nt != nil)
			fdtabfree(nt);
		return r;
	}
	if(nt != nil){
		ot = fdtab();
		for(i = 0; i < Nfd; i++){
			if((flags & RFFDG) != 0)
				nt[i] = ot[i];
			else
				/*
				 * RFCFDG empties the table, and the machine's
				 * console is not in it: Fdcons is not a
				 * descriptor of the personality's, it is the
				 * one trap a loaded program makes, and it is
				 * reachable whether or not the program has a
				 * descriptor table at all.  So it survives,
				 * and a program that empties its table can
				 * still say that it did - which on Plan 9 it
				 * could not, because there the console is a
				 * descriptor like any other.
				 */
				nt[i] = ot[i] == Fdcons ? Fdcons : Fdfree;
		}
		*fdpriv = nt;
	}
	return r;
}

/*
 * sleep(2), which libc's own lock calls while it spins.  On a
 * cooperative scheduler a spin that never yields is a machine that
 * stops, so this one is not optional even though nothing in a
 * single-threaded program contends.
 */
int
sleep(long ms)
{
	return p9lib->sleep(ms);
}

int
close(int fd)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdfree)
		return -1;
	if(pfd != Fdcons)
		p9lib->close(pfd);
	fdtab()[fd] = Fdfree;
	return 0;
}

vlong
seek(int fd, vlong off, int type)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd < 0)
		return -1;
	return p9lib->seek(pfd, off, type);
}

/*
 * dup(old, new): the personality's descriptor table allocates the lowest
 * free number, which is dup(old, -1); a dup onto a named descriptor is
 * not offered and is refused rather than quietly done wrong.
 */
int
dup(int oldfd, int newfd)
{
	int pfd;

	pfd = fdof(oldfd);
	if(pfd == Fdfree)
		return -1;
	if(newfd != -1)
		return -1;		/* a dup onto a named descriptor is not offered */
	if(pfd == Fdcons){
		int i;

		int *t = fdtab();

		for(i = 0; i < Nfd; i++)
			if(t[i] == Fdfree){
				t[i] = Fdcons;
				return i;
			}
		return -1;
	}
	return fdnew(p9lib->dup(pfd));
}

/*
 * fd2path(2) yields 0, not a count; the personality answers with the
 * number of bytes it wrote, which is what says the path fitted.
 */
int
fd2path(int fd, char *buf, int nbuf)
{
	int pfd;

	pfd = fdof(fd);
	if(pfd == Fdfree)
		return -1;
	if(pfd == Fdcons){
		if(nbuf < 10)
			return -1;
		strcpy(buf, "/dev/cons");
		return 0;
	}
	return p9lib->fd2path(pfd, buf, nbuf) > 0 ? 0 : -1;
}

/*
 * Processes, for a program that starts other programs.  A pipe is the
 * personality's, in the program's own numbering; spawn is given the
 * program's numbers for what the child's standard input and output are
 * to be and hands the personality its own; a program number that is the
 * console, or is not open, is -1 - the child gets the console for it.
 */
int
pipe(int fd[2])
{
	int p[2];

	if(p9lib->pipe(p) < 0)
		return -1;
	fd[0] = fdnew(p[0]);
	fd[1] = fdnew(p[1]);
	if(fd[0] < 0 || fd[1] < 0){
		/* fdnew closes what it could not find a number for, so what is
		 * still open here is only what it did place */
		if(fd[0] >= 0)
			close(fd[0]);
		if(fd[1] >= 0)
			close(fd[1]);
		return -1;
	}
	return 0;
}

/*
 * Start a program with three descriptors of this program's naming.  A
 * number that is the console, or is not open, is Fdcons or Fdfree: both
 * negative, and both mean the machine's console to the child.
 *
 * spawn is the two-descriptor form a shell wants for a pipeline, and is
 * this with the error descriptor left as the console.  spawn3 is what
 * libthread's procexec needs, because a program started in a window
 * reads and writes and complains to that window.
 */
int
spawn3(char *name, char **argv, int in, int out, int err)
{
	int std[3];

	std[0] = in < 0 || fdof(in) < 0 ? -1 : fdof(in);
	std[1] = out < 0 || fdof(out) < 0 ? -1 : fdof(out);
	std[2] = err < 0 || fdof(err) < 0 ? -1 : fdof(err);
	return p9lib->spawn(name, argv, std);
}

int
spawn(char *name, char **argv, int in, int out)
{
	return spawn3(name, argv, in, out, -1);
}

int
awaitpid(int pid, char *status, int nstatus)
{
	return p9lib->wait(pid, status, nstatus);
}

/*
 * errstr(2): the personality's, not the microkernel's.  libc's own is a
 * system call the microkernel does not answer, so without this a
 * program's %r was empty and every refusal the name space made came out
 * as "failed" with nothing after it.
 */
int
errstr(char *buf, uint nbuf)
{
	if(p9lib == nil || p9lib->errstr == nil){
		if(nbuf > 0)
			buf[0] = 0;
		return -1;
	}
	return p9lib->errstr(buf, nbuf);
}

/*
 * exits, and the handlers registered against it.
 *
 * _onexit is libc's own hook: atexit(2) sets it to its own list-walker
 * and libc's exits calls it.  It is defined here rather than taken from
 * libc's exits.c because taking it from there would drag in that file's
 * exits as well, and there would be two.  So this is libc's exits, with
 * the last line being the personality rather than the _exits trap: a
 * program that ends returns to the library that loaded it.
 *
 * initdraw registers a handler this way - it closes the display - so
 * without the hook the drawing program would leave its client open on
 * the way out.
 */
void (*_onexit)(void);

void
exits(char *status)
{
	if(_onexit != nil)
		(*_onexit)();
	_exits(status);
}

/*
 * And the primitive under it, which is what a flow of control that is
 * not the last one uses: end without running the handlers, because the
 * other flows of the program are still going and one of them will.
 */
void
_exits(char *status)
{
	p9lib->exits(status);
	for(;;)			/* the loader does not return here */
		;
}

/*
 * A call that is here so that a program which cannot reach it says so
 * instead of trapping.  It was libc's system-call stub, and a stub on
 * this personality is a trap into a microkernel that does not answer the
 * Plan 9 table: a program that reached one faulted, with nothing to say
 * why.
 *
 * noted(2) returns from a note handler.  The personality raises no
 * notes on a program it loaded, so no handler ever runs and nothing
 * returns from one.  It is linked because libthread's note.c also holds
 * _procsplhi and _procsplx, which its scheduler does call, and a file
 * is linked whole.
 *
 * Reaching it would mean something is true that this personality says is
 * not, so it says which and ends the program rather than answering: a
 * wrong answer here would be a program going quietly on as though it had
 * been sent a note.
 */
int
noted(int v)
{
	char *m = "p9crt: noted: a note was delivered to a loaded program, which does not happen here\n";

	USED(v);
	p9conswrite(2, m, strlen(m), -1LL);
	_exits("noted");
	return -1;
}

/*
 * The calls a program with more than one flow of control needs.
 *
 * privalloc(2) is one word of storage that is this flow's own.  libc's
 * own hands out a word of _privates, which is one array in the program's
 * image and so is shared by every flow it has; the personality's is a
 * word whose contents its scheduler swaps at the switch, which is what
 * per-process means when every process is a kproc of one address space.
 *
 * getpid(2) is this flow's number, for the same reason: libc's reads
 * _tos->pid, and the Tos is in the image and shared.
 *
 * rendezvous(2) is two flows meeting on a tag.  libc's qlock names it as
 * its default way to wait - and a libthread program replaces that before
 * it starts a thread - but libthread's own scheduler calls it to put a
 * proc with no ready thread to sleep and to wake it again (runthread and
 * _threadready, sched.c).  That is the caller that matters, and the
 * reason this is a call to the personality and not a refusal: without it
 * a program's second proc would be started and never woken.
 */
void**
privalloc(void)
{
	return p9lib->privalloc();
}

int
getpid(void)
{
	return p9lib->pid();
}

void*
rendezvous(void *tag, void *val)
{
	return p9lib->rendezvous(tag, val);
}

/*
 * A second flow of control inside this program, sharing its memory and
 * its descriptors.  This is not in libc, because there is no Plan 9 call
 * that means it: on Plan 9 it is rfork(RFPROC|RFMEM), which returns
 * twice and so cannot be a function a library provides - a library
 * cannot split its caller's C stack.  So it is named for what it does
 * and takes the function to start.
 */
int
p9proccreate(void (*f)(void*), void *arg)
{
	return p9lib->proccreate(f, arg);
}

/*
 * The program's own heap, in its own bss: enough for a command, and a
 * refusal rather than a wrong answer when it runs out.
 */
enum { Nheap = 1024*1024 };
static char heaparena[Nheap];
static long heapused;

void*
sbrk(uvlong n)
{
	char *p;

	if(heapused + (long)n > Nheap)
		return (void*)-1;
	p = heaparena + heapused;
	heapused += n;
	return p;
}

int
brk(void *p)
{
	long want;

	want = (char*)p - heaparena;
	if(want < 0 || want > Nheap)
		return -1;
	heapused = want;
	return 0;
}
