/*
 * Record the order in which Dis execution actually happened.
 *
 * inputrec.c reproduces what a session was told; this is about what it then
 * did with it. Dis execution is serialised - exactly one process executes Dis
 * instructions at a time, see refstress(1) - so the schedule is a sequence of
 * discrete handoffs rather than an arbitrary interleaving, which is what makes
 * recording it tractable at all.
 *
 *	INFERNO_SCHED_RECORD=file	emu ...
 *
 * Deliberately record-only for now. Whether forcing the recorded order on a
 * later run is worth building is a question about how much two runs of the
 * same session actually differ, and that is measurable rather than arguable -
 * so measure it first. The recorder is independently useful either way: a
 * schedule is the one thing a fault report cannot reconstruct afterwards.
 *
 * Four sites are recorded, not one. The obvious place - vmachine's loop,
 * where a prog is taken off the head of the run queue - only says which prog
 * began a fresh quantum. It is not where the slot changes hands: acquire()
 * pushes its prog back at the *head* of the run queue and returns into the
 * middle of the xec() call it left, so a prog that makes a system call and
 * comes back resumes without passing through the loop at all. Recording only
 * the loop would therefore miss every interleaving caused by host calls,
 * which is most of them.
 *
 * schedrecord takes a "live" flag and will not follow a prog's module link
 * unless it is set. Only vmachine's loop sets it, because that is the one site
 * where the prog is about to execute and so is certainly alive.
 *
 * delprog() both releases the slot and takes it back while tearing a prog
 * down, and by then progexit() has run destroystack(), so the module link is
 * gone at *both* those sites and reading it faults. Nil checks do not help
 * against a pointer that is merely dead, which is why this is a flag rather
 * than a test: sh -c 'echo one; echo two' printed "one" and faulted in
 * delprog, and disabling the release hook alone did not fix it because
 * acquire is on the same teardown path.
 *
 * Every prog is given a quantum before it can ever release or acquire, so the
 * cache is always warm by the time a teardown event needs it.
 *
 * Identity is a pid and a hash of the module name, not a pid alone. Pids come
 * from a counter (newprog: n->pid = ++pidnum), so one extra or one missing
 * process shifts every later pid - and pid 7 then exists in both runs while
 * naming different programs. That corrupts a comparison silently. With the
 * name, it is a mismatch that can be reported, which is the same reason
 * styxreplay compares what a request asks for rather than its fid.
 */

#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"interp.h"

enum {
	Squantum = 'q',		/* vmachine gave a prog a fresh quantum */
	Sacquire = 'a',		/* a prog took the VM back after a host call */
	Srelease = 'r',		/* a prog gave up the VM to make a host call */
	Syield	 = 'y',		/* a prog handed the VM to a waiting proc */

	Hdrsz	= 12,		/* magic[8] cflag[4] */
	Recsz	= 9,		/* type[1] pid[4] namehash[4] */

	Nring	= 1<<16,
};

static char srmagic[8] = "infsched";

typedef struct Sevent Sevent;
struct Sevent {
	uchar	type;
	int	pid;
	ulong	hash;
};

/*
 * A lock here, unlike inputrec.c's ring: these events come from every
 * vmachine kproc, so there really are several producers. It is its own lock
 * and never isched.l, and it is held only across the append - never across
 * anything that can longjmp. dis.c's own comment records what happens
 * otherwise: a lock held around Dis execution deadlocked sh -c 'echo a; echo
 * b', because waserror()/nexterror() unwinding jumps to vmachine's recovery
 * block and skips the paired unlock.
 */
static struct {
	int	on;
	int	fd;
	Lock	l;
	Sevent	ring[Nring];
	int	wr;
	int	rd;
	int	lost;
	int	toldlost;
	Rendez	r;
} sr;

/*
 * pid -> module hash, filled in where the prog is known to be running, so a
 * teardown event can still be identified without following a dead link.
 * Direct-mapped and lossy on purpose: a stale entry costs a mismatch in a
 * comparison, and a fault costs the run.
 */
static struct {
	int	pid;
	ulong	hash;
} hcache[1024];

static void
pbe32(uchar *p, ulong v)
{
	p[0] = v>>24;
	p[1] = v>>16;
	p[2] = v>>8;
	p[3] = v;
}

/*
 * The module a prog is executing, guarded at every step: this runs on the
 * scheduler's hot path and during teardown, where any of these can be nil.
 */
static ulong
proghash(Prog *p)
{
	ulong h;
	char *s;

	if(p == nil || p->R.M == nil || p->R.M->m == nil || p->R.M->m->name == nil)
		return 0;
	h = 2166136261UL;
	for(s = p->R.M->m->name; *s != '\0'; s++)
		h = (h ^ (uchar)*s) * 16777619UL;
	return h;
}

static int
srnotempty(void *v)
{
	USED(v);
	return sr.rd != sr.wr;
}

void
schedrecord(int type, Prog *p, int live)
{
	int w, pid;
	ulong hash;

	if(!sr.on)
		return;
	pid = p != nil? p->pid: 0;
	if(live){
		hash = proghash(p);
		if(pid != 0){
			hcache[pid & (nelem(hcache)-1)].pid = pid;
			hcache[pid & (nelem(hcache)-1)].hash = hash;
		}
	}else{
		/* the prog may be dying; its pid is still readable, its
		 * module link is not */
		hash = 0;
		if(pid != 0 && hcache[pid & (nelem(hcache)-1)].pid == pid)
			hash = hcache[pid & (nelem(hcache)-1)].hash;
	}
	lock(&sr.l);
	w = sr.wr + 1;
	if(w >= Nring)
		w = 0;
	if(w == sr.rd){
		sr.lost++;
		unlock(&sr.l);
		return;
	}
	sr.ring[sr.wr].type = type;
	sr.ring[sr.wr].pid = pid;
	sr.ring[sr.wr].hash = hash;
	sr.wr = w;
	unlock(&sr.l);
	Wakeup(&sr.r);
}

static void
schedrecproc(void *v)
{
	uchar buf[Recsz];
	Sevent e;

	USED(v);
	for(;;){
		Sleep(&sr.r, srnotempty, 0);
		if(sr.lost != 0 && !sr.toldlost){
			sr.toldlost = 1;
			print("schedrec: the event ring overflowed;"
				" this schedule is INCOMPLETE\n");
		}
		for(;;){
			lock(&sr.l);
			if(sr.rd == sr.wr){
				unlock(&sr.l);
				break;
			}
			e = sr.ring[sr.rd];
			if(++sr.rd >= Nring)
				sr.rd = 0;
			unlock(&sr.l);

			buf[0] = e.type;
			pbe32(buf+1, e.pid);
			pbe32(buf+5, e.hash);
			if(kwrite(sr.fd, buf, Recsz) != Recsz){
				print("schedrec: write failed, recording stops: %r\n");
				sr.on = 0;
				kclose(sr.fd);
				pexit("", 0);
			}
		}
	}
}

void
schedrecinit(void)
{
	uchar hdr[Hdrsz];
	char *path;

	path = getenv("INFERNO_SCHED_RECORD");
	if(path == nil || *path == '\0')
		return;
	sr.fd = kcreate(path, OWRITE, 0666);
	if(sr.fd < 0){
		print("schedrec: cannot create %s: %r\n", path);
		return;
	}
	memmove(hdr, srmagic, sizeof srmagic);
	/*
	 * The JIT and the interpreter reach system calls at different points,
	 * so a schedule recorded under one says nothing about the other.
	 * Recorded so that a comparison across the two can be refused rather
	 * than quietly reported as a difference in scheduling.
	 */
	pbe32(hdr+8, cflag);
	if(kwrite(sr.fd, hdr, Hdrsz) != Hdrsz){
		print("schedrec: cannot write the header of %s: %r\n", path);
		kclose(sr.fd);
		return;
	}
	sr.on = 1;
	kproc("schedrecord", schedrecproc, nil, KPDUPFDG|KPDUPPG|KPDUPENVG);
}
