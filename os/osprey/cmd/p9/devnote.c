#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ospreydata.h"

/*
 * The note tree: /proc/<n>/note and /proc/<n>/notepg, which is what
 * postnote(2) writes.
 *
 * postnote is not a system call.  libc opens /proc/n/note (one process)
 * or /proc/n/notepg (its group) and writes the note's text there, so on
 * this personality it is a file, and the personality is where a legacy
 * program's name space lives.  What the write cannot do is post the
 * note: the processes are the kernel's.  So the write turns into one
 * request to the kernel (ReqPostnote), which decides whether the
 * container asking may note the container named.
 *
 * The n in the path is a container's identity, which is what a legacy
 * program has for a pid: rfork(2) returns it and await(2) reports it.
 * Any number walks - the directory does not list, because this
 * personality does not hold the kernel's table of containers and would
 * have to invent one.  A walk that names a container nobody may note is
 * not refused here; the write is, by the kernel, which is where the
 * question belongs.
 */

enum {
	Qdir = 0,
	Qpid,			/* /proc/<n> */
	Qnote,
	Qnotepg,
	Qstatus,
	Qargs,			/* /proc/<n>/args: what the flow was started with */
	ReqPostnote = 37,	/* devosprey.c's xcall op */
};

extern long ospreyxcall(int, uvlong*, long);
extern long p9argsof(int schedpid, char *buf, long nbuf);	/* p9proc.c */
extern long p9setargs(int schedpid, char *buf, long n);
extern uvlong p9servingcontainer(void);	/* p9buddy.c: whose call this process is answering */
extern uchar *p9srvdata(void);		/* this personality's own data area */

/*
 * The qid carries the container in its top bits and the file in its
 * bottom two, so a walk needs no table of open processes.
 */
#define QPATH(pid, f)	(((uvlong)(pid) << 3) | (f))
#define QPID(path)	((uvlong)(path) >> 3)
#define QFILE(path)	((ulong)(path) & 7)

static Chan*
noteattach(char *spec)
{
	Chan *c;

	c = devattach('p', spec);
	c->qid.path = QPATH(0, Qdir);
	c->qid.type = QTDIR;
	return c;
}

/*
 * The decimal in the path, parsed here rather than through strtoull:
 * the number is a container identity and it has to survive exactly, and
 * a wrong answer is silent - the note would be asked for container 0,
 * which is not a container, and the refusal would look like an
 * authority refusal rather than a parse.
 */
static int
numeric(char *s, uvlong *vp)
{
	uvlong v;

	if(*s == 0)
		return 0;
	v = 0;
	for(; *s != 0; s++){
		if(*s < '0' || *s > '9')
			return 0;
		v = v*10 + (*s - '0');
	}
	*vp = v;
	return 1;
}

static Walkqid*
notewalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;
	Chan *tc;
	uvlong pid;
	int i, f;

	if(nc == nil)
		nc = devclone(c);
	wq = smalloc(sizeof(Walkqid) + (nname ? nname - 1 : 0)*sizeof(Qid));
	if(waserror()){
		free(wq);
		nexterror();
	}
	tc = nc;
	tc->qid = c->qid;
	tc->type = c->type;
	tc->dev = c->dev;
	for(i = 0; i < nname; i++){
		if(strcmp(name[i], "..") == 0){
			tc->qid.path = QPATH(0, Qdir);
			tc->qid.type = QTDIR;
			wq->qid[i] = tc->qid;
			continue;
		}
		switch(QFILE(tc->qid.path)){
		case Qdir:
			if(!numeric(name[i], &pid))
				goto Nope;
			tc->qid.path = QPATH(pid, Qpid);
			tc->qid.type = QTDIR;
			break;
		case Qpid:
			if(strcmp(name[i], "note") == 0)
				f = Qnote;
			else if(strcmp(name[i], "notepg") == 0)
				f = Qnotepg;
			else if(strcmp(name[i], "status") == 0)
				f = Qstatus;
			else if(strcmp(name[i], "args") == 0)
				f = Qargs;
			else
				goto Nope;
			tc->qid.path = QPATH(QPID(tc->qid.path), f);
			tc->qid.type = QTFILE;
			break;
		default:
			goto Nope;
		}
		wq->qid[i] = tc->qid;
	}
	poperror();
	wq->nqid = nname;
	wq->clone = tc;
	return wq;
Nope:
	poperror();
	wq->nqid = i;
	if(i == 0){
		free(wq);
		if(nc != c)
			cclose(nc);
		error(Enonexist);
	}
	wq->clone = nil;
	if(nc != c)
		cclose(nc);
	return wq;
}

static int
notestat(Chan *c, uchar *dp, int n)
{
	Dir d;
	char name[32];
	ulong f;

	f = QFILE(c->qid.path);
	switch(f){
	case Qdir:
		strcpy(name, "proc");
		break;
	case Qpid:
		snprint(name, sizeof name, "%llud", QPID(c->qid.path));
		break;
	case Qnote:
		strcpy(name, "note");
		break;
	case Qstatus:
		strcpy(name, "status");
		break;
	case Qargs:
		strcpy(name, "args");
		break;
	default:
		strcpy(name, "notepg");
		break;
	}
	/*
	 * The owner is what this file is mostly here for.  libc's
	 * getuser(2) stats /proc/<pid>/status and takes the uid out of the
	 * stat message; without the file it answers "none", and rio's file
	 * server then refuses its own window's attach - the attach says
	 * "osprey", which is who the personality runs as, and rio compares
	 * the two.  "mount failed: permission denied", and no window.
	 */
	devdir(c, c->qid, name, 0, eve,
		f == Qdir || f == Qpid ? DMDIR|0555
		: f == Qstatus ? 0444 : f == Qargs ? 0666 : 0222, &d);
	return convD2M(&d, dp, n);
}

static Chan*
noteopen(Chan *c, int omode)
{
	if(QFILE(c->qid.path) == Qargs){
		/* read to see what a flow is running, write to rename it */
		if(openmode(omode) != OREAD && openmode(omode) != OWRITE
		&& openmode(omode) != ORDWR)
			error(Eperm);
	} else if(QFILE(c->qid.path) == Qdir || QFILE(c->qid.path) == Qpid
	|| QFILE(c->qid.path) == Qstatus){
		if(openmode(omode) != OREAD)
			error(Eperm);
	} else if(openmode(omode) != OWRITE)
		error(Eperm);
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
noteclose(Chan*)
{
}

static long
noteread(Chan *c, void *a, long n, vlong off)
{
	char buf[256];
	int i, m;

	if(QFILE(c->qid.path) == Qstatus){
		/*
		 * The shape devproc(3) gives it: the program's name, the
		 * user, the state, then twelve numbers.  The name is "-"
		 * because this personality does not hold the kernel's table
		 * of containers and so does not know it; the user is what
		 * getuser(2) comes here for and is right.  The numbers are
		 * zero and are not accounting this personality keeps.
		 */
		m = snprint(buf, sizeof buf, "%-27s%-27s%-12s", "-", eve, "Running");
		for(i = 0; i < 12; i++)
			m += snprint(buf+m, sizeof buf - m, "%-11d ", 0);
		if(off >= m)
			return 0;
		if(n > m - off)
			n = m - off;
		memmove(a, buf + off, n);
		return n;
	}
	if(QFILE(c->qid.path) == Qargs){
		/*
		 * What the flow was started with, blank-separated, which is
		 * what devproc(3) puts here.  rio reads it to name a window
		 * after the command running in it, and the personality is
		 * where that is known: spawn copied the argument vector into
		 * the program's own slot, and a second flow of control made
		 * by proccreate carries the same one, because it is the same
		 * program running.
		 *
		 * A number that is not a flow of this personality's answers
		 * nothing rather than guessing.
		 */
		m = (int)p9argsof((int)QPID(c->qid.path), buf, sizeof buf);
		if(off >= m)
			return 0;
		if(n > m - off)
			n = m - off;
		memmove(a, buf + off, n);
		return n;
	}
	/*
	 * Nothing lists.  A directory here would have to be the kernel's
	 * table of containers, which this personality does not hold; the
	 * names work because a walk accepts any number, and inventing a
	 * listing to go with them would be a listing of nothing real.
	 */
	return 0;
}

static long
notewrite(Chan *c, void *a, long n, vlong)
{
	uvlong args[5], target, asking;
	uchar *d;
	long m;

	if(QFILE(c->qid.path) == Qargs){
		/*
		 * A program renaming itself.  rio writes the command a window
		 * is running here so the window has a name, which is what
		 * this file is for on Plan 9 - and it is a write the
		 * personality can answer truthfully, because the flow being
		 * renamed is one of its own.
		 */
		m = p9setargs((int)QPID(c->qid.path), a, n);
		if(m < 0)
			error(Enonexist);
		return m;
	}
	if(QFILE(c->qid.path) != Qnote && QFILE(c->qid.path) != Qnotepg)
		error(Eperm);
	target = QPID(c->qid.path);
	if((asking = p9servingcontainer()) == 0){
		print("p9: a note was written to /proc/%llud/note by nobody this personality is serving\n", target);
		error("no container asked for this note");
	}
	if((d = p9srvdata()) == nil)
		error("no data area to carry the note through");
	m = n;
	if(m > Odnotelen - 1)
		m = Odnotelen - 1;
	memmove(d + Odnote, a, m);
	d[Odnote + m] = 0;
	args[0] = target;
	args[1] = asking;
	args[2] = QFILE(c->qid.path) == Qnotepg;
	args[3] = args[4] = 0;
	/*
	 * Three words, which is all a request carries (Ospreynarg), and the
	 * count is not decoration: ospreyxcall copies exactly the number it
	 * is given and leaves the rest zero, and a count larger than three
	 * is refused outright with no word about why.  The note's text goes
	 * at Odnote instead of at an offset passed here, which is what frees
	 * the third word for the group flag.
	 */
	if(ospreyxcall(ReqPostnote, args, 3) < 0)
		error(Eperm);
	return n;
}

Dev notedevtab = {
	'p',
	"proc",

	devreset,
	devinit,
	devshutdown,
	noteattach,
	notewalk,
	notestat,
	noteopen,
	devcreate,
	noteclose,
	noteread,
	devbread,
	notewrite,
	devbwrite,
	devremove,
	devwstat,
};
