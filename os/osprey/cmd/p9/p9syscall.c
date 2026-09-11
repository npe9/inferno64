/*
 * The system calls of a program that was not built for this personality.
 *
 * Every other program here is linked against p9crt.c and calls the
 * library operating system as a library: open and read are function
 * calls in the one address space, through the table in p9lib.h, and the
 * program makes no system call at all.  That is the arrangement the
 * whole thing is for, and it has one thing wrong with it - the program
 * has to be built for it.  A library per program is not an operating
 * system.
 *
 * An ordinary Plan 9 binary is built against libc, whose file calls are
 * the generated system-call stubs, and it traps.  Under it is a
 * microkernel that answers five calls and has no name space: the trap
 * for open(2) is answered "osprey user: unimplemented syscall 14" and
 * the program dies without knowing why.
 *
 * So the personality asks the kernel for those traps (ReqSyscallup) and
 * this file is what they arrive at.  The kernel copies the frame the
 * call was made on to the stack and re-enters the task here, with the
 * call's number, its arguments where the caller left them, and that
 * frame; p9syscallup does the work with the name space it already has -
 * the same libopen and libpread that serve a program linked against the
 * table - and hands the frame back with a value in it.  The program's
 * libc sees an ordinary system-call return.
 *
 * What tells this program's traps from the personality's own is where
 * they were made: the kernel routes a call only if the instruction that
 * made it is inside the image the program was laid in.  The
 * personality's own flows - the input loop, the draw server, rio's four
 * - go on calling the microkernel while this runs, and they are linked
 * a gigabyte higher.
 *
 * The descriptors are the program's own small integers and not the
 * personality's: fdmap below is the table an operating system keeps for
 * a process, and 0, 1 and 2 in it are opens of /dev/cons in the
 * personality's name space, which is where a Plan 9 program's standard
 * descriptors come from anyway.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"sys.h"

extern int	libopen(char*, int);
extern int	libcreate(char*, int, ulong);
extern long	libread(int, void*, long);
extern long	libwrite(int, void*, long);
extern long	libpread(int, void*, long, vlong);
extern long	libpwrite(int, void*, long, vlong);
extern void	libclose(int);
extern vlong	libseek(int, vlong, int);
extern int	libdup(int);
extern int	libfd2path(int, char*, int);
extern int	libstat(char*, uchar*, int);
extern int	libfstat(int, uchar*, int);
extern int	libbind(char*, char*, int);
extern int	libmount(int, char*, int, char*);
extern int	libunmount(char*, char*);
extern int	libchdir(char*);
extern int	libpipe(int[2]);
extern int	libsleep(long);
extern int	liberrstr(char*, uint);
extern int	p9forkns(int);
extern int	p9waitany(char*, int);
extern void	p9anyexits(char*);
extern long	ospreyxcall(int, uvlong*, long);

enum {
	ReqSyscallup	= 39,	/* devosprey.c: this task serves its own program's calls */
	ReqSyscallret	= 40,	/* and this one is answered */
	ReqFaultup	= 41,	/* and this is where a fault in it goes */
	ReqNote		= 25,	/* post the caller a note - refused below, and why */
	Nfd		= 64,	/* descriptors the legacy program may hold */
};

static int fdmap[Nfd];		/* the program's fd -> the personality's, or -1 */
static int fdready;

static void
fdstart(int *std)
{
	int i;

	for(i = 0; i < Nfd; i++)
		fdmap[i] = -1;
	/*
	 * 0, 1 and 2.  A Plan 9 program is started with them open and this
	 * one is no different.
	 *
	 * A program a shell started is given the shell's own: that is what
	 * makes a command in a pipeline write to the next one rather than
	 * to the machine's console, and the descriptors are already in this
	 * flow's own table, put there by givefds before the flow started.
	 *
	 * Where there is none - the personality running a program itself,
	 * or a shell whose own descriptor is the machine's console and so
	 * is -1 - the program is given /dev/cons, which is what the console
	 * is in this name space.  A program with no descriptor at all is
	 * not a Plan 9 program: the first thing this one did with three of
	 * them missing was print, which failed, and it ended with the
	 * descriptor error as its status before it had said anything.
	 * 2 is a dup of 1 and not a second open, so that closing one does
	 * not take the other.
	 */
	fdmap[0] = std != nil && std[0] >= 0 ? std[0] : libopen("/dev/cons", OREAD);
	fdmap[1] = std != nil && std[1] >= 0 ? std[1] : libopen("/dev/cons", OWRITE);
	if(std != nil && std[2] >= 0)
		fdmap[2] = std[2];
	else
		fdmap[2] = fdmap[1] >= 0 ? libdup(fdmap[1]) : -1;
	fdready = 1;
}

static void
fdstop(void)
{
	int i;

	for(i = 0; i < Nfd; i++)
		if(fdmap[i] >= 0){
			int j;

			/* a number the program dup'd onto two of its own is one
			 * descriptor of the personality's and is closed once */
			for(j = 0; j < i; j++)
				if(fdmap[j] == fdmap[i])
					break;
			if(j == i)
				libclose(fdmap[i]);
			fdmap[i] = -1;
		}
	fdready = 0;
}

/* the personality's descriptor behind one of the program's, or -1 */
static int
fdof(int fd)
{
	if(fd < 0 || fd >= Nfd)
		return -1;
	return fdmap[fd];
}

/* the lowest free number, which is what a Plan 9 open answers with */
static int
fdnew(int pfd)
{
	int i;

	if(pfd < 0)
		return -1;
	for(i = 0; i < Nfd; i++)
		if(fdmap[i] < 0){
			fdmap[i] = pfd;
			return i;
		}
	libclose(pfd);
	snprint(up->errstr, ERRMAX, "no free file descriptors");
	return -1;
}

static void
fdfree(int fd)
{
	if(fd >= 0 && fd < Nfd)
		fdmap[fd] = -1;
}

/*
 * The heap.  A legacy program's malloc grows its break with brk(2), and
 * the break is an address in the region this personality laid it in.
 * There is no page fault to grow here - the region is attached whole -
 * so the call is a bounds check and a record of where the program thinks
 * its break is.
 */
static uvlong heapbase, heaptop, heapbrk;

/*
 * Where the program is, which is also what the kernel is told so that it
 * can tell the program's traps from the personality's.
 */
void
p9syscallprog(uvlong base, uvlong end, int *std)
{
	uvlong a[4];
	extern void p9syscallup(ulong, uintptr, uintptr);
	extern void p9faultup(char*);

	/*
	 * One at a time.  The kernel keeps one image range and one
	 * outstanding call, and the descriptor table below is one table, so
	 * a second legacy program started while one is running would be
	 * served as though it were the first.  It is refused by name
	 * instead, which a caller can act on; lifting the limit is
	 * per-flow state on both sides of the trap and is not done.
	 */
	if(fdready){
		print("p9 syscall: a legacy program is already being served; "
			"%#llux cannot be served as well\n", base);
		return;
	}
	heapbase = base;
	heaptop = end;
	heapbrk = 0;
	fdstart(std);
	a[0] = (uvlong)(uintptr)p9syscallup;
	a[1] = base;
	a[2] = end;
	if(ospreyxcall(ReqSyscallup, a, 3) < 0)
		print("p9 syscall: the kernel would not let me serve my program's system calls\n");
	a[0] = (uvlong)(uintptr)p9faultup;
	a[1] = a[2] = 0;
	if(ospreyxcall(ReqFaultup, a, 1) < 0)
		print("p9 syscall: the kernel would not let me catch my program's faults\n");
}

/*
 * And give the service back, which is what the personality does the
 * moment its legacy program has returned.  Nothing routes afterwards.
 */
void
p9syscallnoprog(void)
{
	uvlong a[4];

	a[0] = a[1] = a[2] = a[3] = 0;
	ospreyxcall(ReqSyscallup, a, 3);
	ospreyxcall(ReqFaultup, a, 1);
	fdstop();
}

/*
 * Hand the frame back with the call's value in it.  This does not
 * return: the kernel puts the frame the call arrived on back, and the
 * program goes on from the instruction after its trap.
 */
static void
answer(uintptr frame, uintptr val)
{
	uvlong a[2];

	a[0] = (uvlong)frame;
	a[1] = (uvlong)val;
	ospreyxcall(ReqSyscallret, a, 2);
	/*
	 * Only reached if the kernel refused the frame, which it prints.
	 * There is nowhere to return to - the frame this runs on was made
	 * by the kernel and its return address is zero - so end the
	 * program the way its own exits would.
	 */
	print("p9 syscall: the kernel would not put my program's frame back; ending it\n");
	p9anyexits("syscall");
}

/*
 * A call this personality does not serve yet.  It is named in the log
 * and answered -1 with a reason the program can read with errstr(2),
 * which is what a Plan 9 program does with a call that fails.
 */
static uintptr
unserved(ulong scallnr)
{
	static ulong said[64];
	static int nsaid;
	int i;

	for(i = 0; i < nsaid; i++)
		if(said[i] == scallnr)
			break;
	if(i == nsaid && nsaid < nelem(said)){
		said[nsaid++] = scallnr;
		print("p9 syscall: my program asked for system call %uld, which I do not serve yet\n",
			scallnr);
	}
	snprint(up->errstr, ERRMAX, "system call %uld is not served by this personality", scallnr);
	return (uintptr)-1;
}

/*
 * And where a fault in the program arrives.  The kernel bends the frame
 * here rather than panicking (userinit.c says why), and this does not
 * return: the program is over, and the jump goes back to the frame
 * p9execlegacy left, which is the library operating system carrying on
 * after a program of its own has died.  That is what a kernel does with
 * a process; the difference is that this one shares an address space
 * with what it is catching, and so can only say the program is over -
 * it cannot claim the program did no damage on its way out.
 */
void
p9faultup(char *msg)
{
	print("p9 syscall: my program faulted: %s.  It ends there; I go on.\n",
		msg == nil ? "" : msg);
	p9syscallnoprog();
	p9anyexits("fault");
}

void
p9syscallup(ulong scallnr, uintptr aargs, uintptr frame)
{
	va_list list;
	uintptr ret;
	char *name, *buf, *status, *old, *spec;
	uchar *edir;
	vlong off, *offp;
	long len;
	int fd, mode, t, p[2], flag, afd;
	ulong perm;

	list = (va_list)aargs;
	ret = (uintptr)-1;
	switch(scallnr){
	case OPEN:
		name = va_arg(list, char*);
		mode = va_arg(list, int);
		ret = (uintptr)fdnew(libopen(name, mode));
		break;
	case CREATE:
		name = va_arg(list, char*);
		mode = va_arg(list, int);
		perm = va_arg(list, ulong);
		ret = (uintptr)fdnew(libcreate(name, mode, perm));
		break;
	case CLOSE:
		fd = va_arg(list, int);
		if((t = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		libclose(t);
		fdfree(fd);
		ret = 0;
		break;
	case PREAD:
	case PWRITE:
		fd = va_arg(list, int);
		buf = va_arg(list, char*);
		len = va_arg(list, long);
		off = va_arg(list, vlong);
		if((t = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		/*
		 * ~0 is libc's "wherever the descriptor is", which is read(2)
		 * and write(2); anything else is the offset pread(2) names.
		 */
		if(scallnr == PREAD)
			ret = (uintptr)(off == ~0ULL ? libread(t, buf, len)
					: libpread(t, buf, len, off));
		else
			ret = (uintptr)(off == ~0ULL ? libwrite(t, buf, len)
					: libpwrite(t, buf, len, off));
		break;
	case SEEK:
		offp = va_arg(list, vlong*);
		fd = va_arg(list, int);
		off = va_arg(list, vlong);
		t = va_arg(list, int);
		if((fd = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		*offp = libseek(fd, off, t);
		ret = *offp < 0 ? (uintptr)-1 : 0;
		break;
	case DUP:
		fd = va_arg(list, int);
		t = va_arg(list, int);
		if((fd = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		if(t == -1)
			ret = (uintptr)fdnew(libdup(fd));
		else {
			/* onto a number of the program's choosing */
			if(t < 0 || t >= Nfd){
				snprint(up->errstr, ERRMAX, "fd out of range");
				break;
			}
			if(fdmap[t] >= 0)
				libclose(fdmap[t]);
			fdmap[t] = libdup(fd);
			ret = fdmap[t] < 0 ? (uintptr)-1 : (uintptr)t;
		}
		break;
	case FD2PATH:
		fd = va_arg(list, int);
		buf = va_arg(list, char*);
		len = va_arg(list, int);
		if((fd = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		/*
		 * The library answers with the byte count and the system call
		 * with 0, which is the shape p9crt's own fd2path converts
		 * between too.  Without the conversion cat said "fd2path of 4
		 * failed" about a call that had worked.
		 */
		ret = libfd2path(fd, buf, (int)len) > 0 ? 0 : (uintptr)-1;
		break;
	case STAT:
		name = va_arg(list, char*);
		edir = va_arg(list, uchar*);
		len = va_arg(list, int);
		ret = (uintptr)libstat(name, edir, (int)len);
		break;
	case FSTAT:
		fd = va_arg(list, int);
		edir = va_arg(list, uchar*);
		len = va_arg(list, int);
		if((fd = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		ret = (uintptr)libfstat(fd, edir, (int)len);
		break;
	case PIPE:
		{
			int *up9 = va_arg(list, int*);
			if(libpipe(p) < 0)
				break;
			up9[0] = fdnew(p[0]);
			up9[1] = fdnew(p[1]);
			ret = up9[0] < 0 || up9[1] < 0 ? (uintptr)-1 : 0;
		}
		break;
	case BIND:
		name = va_arg(list, char*);
		old = va_arg(list, char*);
		flag = va_arg(list, int);
		ret = (uintptr)libbind(name, old, flag);
		break;
	case MOUNT:
		fd = va_arg(list, int);
		afd = va_arg(list, int);
		old = va_arg(list, char*);
		flag = va_arg(list, int);
		spec = va_arg(list, char*);
		USED(afd);
		if((fd = fdof(fd)) < 0){
			snprint(up->errstr, ERRMAX, "fd out of range or not open");
			break;
		}
		ret = (uintptr)libmount(fd, old, flag, spec);
		break;
	case UNMOUNT:
		name = va_arg(list, char*);
		old = va_arg(list, char*);
		ret = (uintptr)libunmount(name, old);
		break;
	case CHDIR:
		name = va_arg(list, char*);
		ret = (uintptr)libchdir(name);
		break;
	case RFORK:
		/*
		 * Only the name-space bits, as the table's forkns is: a flow
		 * of control cannot be split by a library (p9lib.h says why),
		 * and RFPROC asks for exactly that.  p9forkns names what it
		 * refuses.
		 */
		flag = va_arg(list, int);
		ret = (uintptr)p9forkns(flag);
		break;
	case SLEEP:
		len = va_arg(list, long);
		ret = (uintptr)libsleep(len);
		break;
	case ERRSTR:
		buf = va_arg(list, char*);
		len = va_arg(list, int);
		ret = (uintptr)liberrstr(buf, (uint)len);
		break;
	case BRK_:
		/*
		 * The break.  The program's image and the room above it are
		 * one region this personality attached, so this is a bounds
		 * check: inside it the memory is already there, past it there
		 * is none and the program's malloc is told so.
		 */
		{
			uvlong want = (uvlong)va_arg(list, uintptr);

			if(want < heapbase || want > heaptop){
				snprint(up->errstr, ERRMAX,
					"no room: the break %#llux is outside the %llud bytes at %#llux this program was laid in",
					want, heaptop - heapbase, heapbase);
				break;
			}
			heapbrk = want;
			ret = 0;
		}
		break;
	case AWAIT:
		/*
		 * For what this flow started.  A legacy program that started
		 * nothing gets what a Plan 9 program gets: -1 and "no living
		 * processes", because it started nothing.
		 */
		buf = va_arg(list, char*);
		len = va_arg(list, int);
		ret = (uintptr)p9waitany(buf, (int)len);
		break;
	case NOTIFY:
		/*
		 * The truth, which is what p9crt answers a program linked
		 * against the table: this personality posts no notes to a
		 * program it loaded, so a handler would never be called and
		 * accepting one would be a promise it does not keep.  nil -
		 * "I want no handler" - is answered yes, because that is
		 * true.
		 */
		if(va_arg(list, void*) == nil)
			ret = 0;
		else
			snprint(up->errstr, ERRMAX, "notify: this personality posts no notes to the program it loaded, so a handler would never be called");
		break;
	case 60:
		/*
		 * Not a Plan 9 system call at all: the number above the table
		 * is Osprey's own request (devosprey.c), and a program making
		 * one is asking the microkernel and not this name space.  So
		 * it is passed on - the same call, from the personality's own
		 * text, where the kernel does not route it back.
		 *
		 * Except the two that are this arrangement's own: a program
		 * that could register a system-call handler or hand back a
		 * frame could take the personality's own traps.
		 */
		{
			int op = va_arg(list, int);
			uvlong *ub = va_arg(list, uvlong*);
			long n = va_arg(list, long);

			if(op == ReqSyscallup || op == ReqSyscallret || op == ReqFaultup){
				snprint(up->errstr, ERRMAX,
					"request %d is the personality's own; a program it loaded may not make it", op);
				break;
			}
			/*
			 * And one that would stop the machine rather than fail.
			 * ReqNote posts a note to the container, and the
			 * container is this personality: a note arriving in a
			 * configuration whose donotify is a panic ends the boot,
			 * and it would arrive wherever the personality happened
			 * to be rather than in the program that asked for it.
			 * The program is told no, which is what it can act on.
			 */
			if(op == ReqNote){
				snprint(up->errstr, ERRMAX,
					"a note posted to this container would arrive in the personality, which has no handler for one");
				break;
			}
			ret = (uintptr)ospreyxcall(op, ub, n);
		}
		break;
	case EXITS:
		/*
		 * And the call that makes the demonstration possible at all.
		 * exits(2) from an ordinary binary is a system call, and on
		 * this microkernel it idles the machine - the personality
		 * that started the program would never run again.  Here it is
		 * the library's exits: it returns to p9execlegacy, which is
		 * where the program was called from.  Nothing below runs.
		 */
		status = va_arg(list, char*);
		print("p9 syscall: my program's exits(\"%s\") comes back to me, not to the kernel\n",
			status == nil ? "" : status);
		p9syscallnoprog();
		p9anyexits(status);
		break;
	default:
		ret = unserved(scallnr);
		break;
	}
	answer(frame, ret);
}
