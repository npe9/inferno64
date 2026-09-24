#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"kernel.h"

typedef	struct Fid	Fid;
typedef	struct Export	Export;
typedef	struct Exq	Exq;

enum
{
	Nfidhash	= 32,
	MAXFDATA	= 8192,
	MAXRPCDEF		= IOHDRSZ+MAXFDATA,	/* initial/default */
	MAXRPCMAX	= IOHDRSZ+64*1024,	/* most every allowed */
	MSGHDRSZ	= BIT32SZ+BIT8SZ+BIT16SZ
};

struct Export
{
	Lock	l;
	Ref	r;
	int	nproc;		/* workers running on THIS connection */
	Exq*	work;
	Lock	fidlock;
	Fid*	fid[Nfidhash];
	Uqidtab	uqids;
	Chan*	io;
	Chan*	root;
	Pgrp*	pgrp;
	Egrp*	egrp;
	Fgrp*	fgrp;
	int	async;
	int	readonly;
	int	uid;
	int	gid;
	int	msize;
	char*	user;
};

struct Fid
{
	Fid*	next;
	Fid**	last;
	Chan*	chan;
	int	fid;
	int	ref;		/* fcalls using the fid; locked by Export.Lock */
	vlong	offset;	/* last offset used (within directory) */
	int	attached;	/* fid attached or cloned but not clunked */
	Uqid*	qid;	/* generated qid */
};

struct Exq
{
	Lock	l;
	int	busy;	/* fcall in progress */
	int	finished;	/* will do no more work on this request or flushes */
	Exq*	next;
	int	shut;		/* has been noted for shutdown */
	Exq*	flush;	/* queued flush requests */
	Exq*	flusht;	/* tail of flush queue */
	Export*	export;
	Proc*	slave;
	Fcall	in, out;
	uchar*	buf;
	int	bsize;
};

/*
 * No work queue: a worker per request, spawned by the connection that
 * read it.  See doc/exportfs-dispatch-plan.ms.  Bounds are explicit;
 * over the limit the reader serves the request itself, so backpressure
 * lands on the connection generating the load.
 */
enum
{
	/*
	 * Workers one connection may have at once.
	 *
	 * This is a CORRECTNESS bound today, not only a resource one.
	 * At 4 the redesign faulted on a nil dereference under load; at
	 * 1 it did not, which is how the fault was localised to two
	 * workers of the same connection running together -- something
	 * the old design never permitted, so nothing in Exfid, fs->fid[]
	 * or the reply path was ever required to tolerate it.  Raising
	 * it needs that audit first.
	 */
	Maxconnproc	= 4,
	Maxproc		= 64,
};

struct
{
	Lock	l;
	int	nproc;
}exq;

static int	exinline;	/* times the reader served a request itself */

/*
 * Writes that have STARTED and not finished.
 *
 * The timing below reports a slow write only once it returns, so at the
 * moment the server is wedged -- which is exactly when the state is
 * wanted -- the log is silent about the write that is causing it.  This
 * records the write before it begins and clears it after, so progwatch
 * can name what is stuck while it is still stuck, and say whether it is
 * a socket (one client's problem) or the pipe (every client's).
 */
struct Exwriting
{
	Lock	l;
	struct {
		int	used;
		int	pid;
		Proc*	p;		/* to interrupt it if it never finishes */
		int	killed;		/* already given up on */
		int	type;		/* R-message type */
		char	dev;		/* devtab dc: 'I' socket, '|' pipe */
		ulong	since;
	} w[32];
}exwriting;

/*
 * How long a reply may take to go out before the far end is declared
 * gone.
 *
 * The write has no timeout of its own: against a client that asked for
 * something and then stopped reading -- a board that rebooted, a test
 * that disconnects without waiting -- it blocks until the host kernel
 * gives up on the connection, which can be minutes.  Meanwhile it holds
 * a worker, and when the worker caps are full it is the connection's
 * READER that is blocked, so that connection is finished.
 *
 * Two minutes is deliberately generous.  A slow client is not a gone
 * client, and the board pulling a kernel over its 10Mb ethernet is the
 * slowest legitimate reader here by a wide margin: it reads
 * continuously, so no single reply of a few kilobytes waits anything
 * like this long.  Anything past two minutes is not slow, it is absent.
 */
enum { Exwritemax = 120*1000 };

static int
exwritestart(int type, int dc)
{
	int i;

	lock(&exwriting.l);
	for(i = 0; i < nelem(exwriting.w); i++)
		if(!exwriting.w[i].used){
			exwriting.w[i].used = 1;
			exwriting.w[i].pid = up->pid;
			exwriting.w[i].p = up;
			exwriting.w[i].killed = 0;
			exwriting.w[i].type = type;
			exwriting.w[i].dev = dc;
			exwriting.w[i].since = osmillisec();
			unlock(&exwriting.l);
			return i;
		}
	unlock(&exwriting.l);
	return -1;
}

static void
exwriteend(int i)
{
	if(i < 0)
		return;
	lock(&exwriting.l);
	exwriting.w[i].used = 0;
	unlock(&exwriting.l);
}

/*
 * Give up on a reply that is never going to be delivered.
 *
 * swiproc is what exshutdown already uses to pull a worker out of a
 * blocked operation, and exworker's error path was made to release the
 * concurrency slots and the Export reference however the call ends, so
 * a worker killed here unwinds the same way as one killed at shutdown.
 * The connection then tears down, which is the right answer: the client
 * stopped reading a long time ago.
 */
static void
exwritewatch(void *a)
{
	int i;
	ulong now;
	Proc *p;

	USED(a);
	for(;;){
		osmillisleep(5000);
		now = osmillisec();
		lock(&exwriting.l);
		for(i = 0; i < nelem(exwriting.w); i++){
			if(!exwriting.w[i].used || exwriting.w[i].killed)
				continue;
			if(now - exwriting.w[i].since < Exwritemax)
				continue;
			p = exwriting.w[i].p;
			exwriting.w[i].killed = 1;
			print("exportfs: pid %d has been writing R%d to %s for "
				"%ldms; giving up on that connection\n",
				exwriting.w[i].pid, exwriting.w[i].type,
				exwriting.w[i].dev == '|'? "the pipe": "a socket",
				now - exwriting.w[i].since);
			unlock(&exwriting.l);
			swiproc(p, 0);
			lock(&exwriting.l);
		}
		unlock(&exwriting.l);
	}
}

/* called by progwatch: report writes that have been going for a while */
void
exwritingreport(void)
{
	int i, n;
	ulong now;

	now = osmillisec();
	n = 0;
	lock(&exwriting.l);
	for(i = 0; i < nelem(exwriting.w); i++)
		if(exwriting.w[i].used && now - exwriting.w[i].since >= 2000){
			print("exportfs: pid %d has been writing R%d to %s "
				"for %ldms -- the far end is not reading\n",
				exwriting.w[i].pid, exwriting.w[i].type,
				exwriting.w[i].dev == '|'? "the PIPE (this stops "
					"every client)": "a socket",
				now - exwriting.w[i].since);
			n++;
		}
	unlock(&exwriting.l);
	if(n == 0)
		print("exportfs: no write has been stuck for 2s\n");
}

static void	exshutdown(Export*);
static int	exflushed(Export*, Exq*);
static void	exdispatch(Exq*);
static void	exworker(void*);
static void	exworkerdone(Export*);
static void	exfreel(Export*, int);
#define exfree(fs)	exfreel(fs, __LINE__)
static void	exfreeq(Exq*);
static void	exportproc(void*);
static void	exreply(Exq*, char*);
static int	exisroot(Export*, Chan*);

static char*	Exversion(Export*, Fcall*, Fcall*);
static char*	Exauth(Export*, Fcall*, Fcall*);
static char*	Exattach(Export*, Fcall*, Fcall*);
static char*	Exclunk(Export*, Fcall*, Fcall*);
static char*	Excreate(Export*, Fcall*, Fcall*);
static char*	Exopen(Export*, Fcall*, Fcall*);
static char*	Exread(Export*, Fcall*, Fcall*);
static char*	Exremove(Export*, Fcall*, Fcall*);
static char*	Exstat(Export*, Fcall*, Fcall*);
static char*	Exwalk(Export*, Fcall*, Fcall*);
static char*	Exwrite(Export*, Fcall*, Fcall*);
static char*	Exwstat(Export*, Fcall*, Fcall*);

static char	*(*fcalls[Tmax])(Export*, Fcall*, Fcall*);

static char	Enofid[]   = "no such fid";
static char	Eseekdir[] = "can't seek on a directory";
static char	Eopen[]	= "walk of open fid";
static char	Emode[] = "open/create -- unknown mode";
static char	Edupfid[]	= "fid in use";
static char	Eaccess[] = "read/write -- not open in suitable mode";
static char	Ecount[] = "read/write -- count too big";
extern int	exdebug;

int
export(int fd, char *dir, int async)
{
	Chan *c, *dc;
	Pgrp *pg;
	Egrp *eg;
	Export *fs;

	/*
	 * Say why, on the way out.
	 *
	 * Both of these returned a bare -1, and styxlisten does not look
	 * at what sys->export returns.  So an export that failed here left
	 * a connection accepted, its Tversion unread, and its serving
	 * process quietly gone -- with nothing anywhere saying so.  From
	 * outside that is indistinguishable from a server that has stopped,
	 * and it was read as one for a long time.
	 */
	if(waserror()){
		print("export: fd %d is not usable: %s\n", fd, up->env->errstr);
		return -1;
	}
	c = fdtochan(up->env->fgrp, fd, ORDWR, 1, 1);
	poperror();

	if(waserror()){
		print("export: cannot walk to %s: %s\n", dir, up->env->errstr);
		cclose(c);
		return -1;
	}
	dc = namec(dir, Atodir, 0, 0);
	poperror();

	fs = malloc(sizeof(Export));
	if(fs == nil){
		cclose(c);
		cclose(dc);
		error(Enomem);
	}

	fs->r.ref = 1;
	pg = up->env->pgrp;
	fs->pgrp = pg;
	incref(&pg->r);
	eg = up->env->egrp;
	fs->egrp = eg;
	incref(&eg->r);
	fs->fgrp = newfgrp(nil);
	fs->uid = up->env->uid;
	fs->gid = up->env->gid;
	kstrdup(&fs->user, up->env->user);
	fs->root = dc;
	fs->io = c;
	uqidinit(&fs->uqids);
	fs->msize = 0;
	c->flag |= CMSG;
	fs->async = async;

	if(async){
		if(waserror())
			return -1;
		kproc("exportfs", exportproc, fs, 0);
		poperror();
	}else
		exportproc(fs);

	return 0;
}

static void
exportinit(void)
{
	lock(&exq.l);
	if(fcalls[Tversion] != nil) {
		unlock(&exq.l);
		return;
	}
	fcalls[Tversion] = Exversion;
	fcalls[Tauth] = Exauth;
	fcalls[Tattach] = Exattach;
	fcalls[Twalk] = Exwalk;
	fcalls[Topen] = Exopen;
	fcalls[Tcreate] = Excreate;
	fcalls[Tread] = Exread;
	fcalls[Twrite] = Exwrite;
	fcalls[Tclunk] = Exclunk;
	fcalls[Tremove] = Exremove;
	fcalls[Tstat] = Exstat;
	fcalls[Twstat] = Exwstat;
	unlock(&exq.l);
	kproc("exwritewatch", exwritewatch, nil, 0);
}

static int
exisroot(Export *fs, Chan *c)
{
	return eqchan(fs->root, c, 1);
}

static int
exreadn(Chan *c, void *buf, int n)
{
	int nr, t;

	if(waserror())
		return -1;
	for(nr = 0; nr < n;){
		t = devtab[c->type]->read(c, (char*)buf+nr, n-nr, 0);
		if(t <= 0)
			break;
		nr += t;
	}
	poperror();
	return nr;
}

static int
exreadmsg(Chan *c, void *a, uint n)
{
	int m, len;
	uchar *buf;

	buf = a;
	m = exreadn(c, buf, BIT32SZ);
	if(m < BIT32SZ){
		if(m < 0)
			return -1;
		return 0;
	}
	len = GBIT32(buf);
	if(len <= BIT32SZ || len > n){
		kwerrstr("bad length in Styx message header");
		return -1;
	}
	len -= BIT32SZ;
	m = exreadn(c, buf+BIT32SZ, len);
	if(m < len){
		if(m < 0)
			return -1;
		return 0;
	}
	return BIT32SZ+m;
}

static void
exportproc(void *a)
{
	Exq *q;
	int async, msize;
	int n, type, spawned;
	Export *fs = a;

	exportinit();

	for(;;){

		msize = fs->msize;
		if(msize == 0)
			msize = MAXRPCDEF;
		for(n=0;; n++){	/* we don't use smalloc, to avoid memset */
			q = mallocz(sizeof(*q)+msize, 0);
			if(q != nil || n > 6000)
				break;
			if(n%600 == 0)
				print("exportproc %d: waiting for memory (%d) for request\n", up->pid, msize);
			osenter();
			osmillisleep(100);
			osleave();
		}
		if(q == nil){
			kwerrstr("out of memory: read request");
			n = -1;
			break;
		}
		memset(q, 0, sizeof(*q));
		q->buf = (uchar*)q + sizeof(*q);
		q->bsize = msize;

		n = exreadmsg(fs->io, q->buf, msize);	/* TO DO: avoid copy */
		if(n <= 0)
			break;
		if(convM2S(q->buf, n, &q->in) != n){
			kwerrstr("bad T-message");
			n = -1;
			break;
		}
		type = q->in.type;
		if(type < Tversion || type >= Tmax || type&1 || type == Terror){
			kwerrstr("invalid T-message type %d", type);
			n = -1;
			break;
		}

		if(exdebug)
			print("export %d <- %F\n", up->pid, &q->in);

		q->out.type = type+1;
		q->out.tag = q->in.tag;

		q->export = fs;
		incref(&fs->r);

		if(fs->readonly){
			switch(type){
			case Topen:
				if((q->in.mode & (ORCLOSE|OTRUNC|3)) == OREAD)
					break;
				/* FALL THROUGH */
			case Tcreate:
			case Twrite:
			case Tremove:
			case Twstat:
				q->out.type = Rerror;
				q->out.ename = "file system read only";
				exreply(q, "exportproc");
				exfreeq(q);
				continue;
			}
		}

		if(q->in.type == Tflush){
			if(exflushed(fs, q)){
				/* not yet started or not found (flush arrived after reply); we reply */
				if(exdebug)
					print("export: flush %d\n", q->in.oldtag);
				exreply(q, "exportproc");
				exfreeq(q);
			}
			continue;
		}

		/*
		 * On fs->work BEFORE this loop can read another message.
		 *
		 * A Tflush is only answerable if the request it names can be
		 * found, and the only place that is guaranteed is here, on
		 * the one process that reads this connection.  Registering in
		 * the worker instead left a window in which a flush for a
		 * request already handed out saw an empty list, and answering
		 * Rflush for a request that is still running is the one thing
		 * the protocol forbids -- the client frees the tag, reuses
		 * it, and then the real reply arrives against somebody else's
		 * request:
		 *
		 *	-> T116 tag 1     the read
		 *	-> T108 tag 2     flush it
		 *	<- R109 tag 2     Rflush: "that reply will never come"
		 *	-> T104 tag 1     tag reused, correctly
		 *	<- R117 tag 1     the read's reply, after all
		 *	mnt: mismatch ... T104 R117
		 *
		 * Which desynchronises the session for good; and styxlisten
		 * gives every client a mount of the SAME pipe, so one client
		 * doing this stops the server for all of them.
		 */
		lock(&fs->l);
		q->next = fs->work;
		fs->work = q;
		unlock(&fs->l);

		spawned = 0;
		lock(&exq.l);
		lock(&fs->l);
		if(fs->nproc < Maxconnproc && exq.nproc < Maxproc){
			fs->nproc++;
			exq.nproc++;
			spawned = 1;
		}
		unlock(&fs->l);
		unlock(&exq.l);
		if(spawned){
			incref(&fs->r);		/* the worker holds one */
			kproc("exwork", exworker, q, 0);
		}else{
			/*
			 * At the cap, so the READER serves this one itself.
			 *
			 * Which means the reader is inside exreply, and
			 * exreply writes the answer to the connection.  A
			 * client that asked for something and then stopped
			 * reading -- a board that rebooted, a test that
			 * disconnects without waiting -- fills the socket's
			 * send buffer, and that write blocks with no timeout.
			 * The reader is then not reading, so this connection
			 * is finished; and because styxlisten gives every
			 * client a mount of the same pipe, the same thing
			 * happening on the pipe's export stops every client
			 * at once.
			 *
			 * Say when it happens, so the next wedge can be
			 * matched against it instead of guessed at.
			 */
			if(exinline++ % 16 == 0)
				print("exportfs: at worker cap (%d/%d on this "
					"connection, %d/%d total), reader is "
					"serving T%d inline (%d times)\n",
					fs->nproc, Maxconnproc,
					exq.nproc, Maxproc,
					q->in.type, exinline);
			exdispatch(q);
		}
	}

	if(exdebug){
		if(n < 0)
			print("exportproc %d shut down: %s\n", up->pid, up->env->errstr);
		else
			print("exportproc %d shut down\n", up->pid);
	}

	free(q);
	exshutdown(fs);
	async = fs->async;
	exfree(fs);

	if(async)
		pexit("mount shut down", 0);
}

static int
exflushed(Export *fs, Exq *fq)
{
	Exq *q, **last;
	ulong pid;

	/* no unstarted work: there is no queue */
	USED(last);

	/* tricky case: in progress */
	lock(&fs->l);
	for(q = fs->work; q != nil; q = q->next)
		if(q->in.tag == fq->in.oldtag){
			pid = 0;
			lock(&q->l);
			if(q->finished){
				/*
				 * Slave replied and emptied its flush queue, so
				 * we can Rflush now -- and we must let go of
				 * fs->l on the way out.
				 *
				 * This path returned holding it.  fs->l is a
				 * spinlock, so a Tflush naming a request that
				 * had just finished wedged the export for good:
				 * every later exslave and exportproc spins on
				 * fs->l, the connection's first message is
				 * never read, and the process sits at 0% CPU
				 * with nothing queued for the VM -- which is
				 * why the scheduler's own stall detector stays
				 * silent for it.  Found by a parallel run on
				 * the multicore branch, where reverting this
				 * one line accounted for the whole measured
				 * difference between surviving 10 abrupt
				 * disconnects and surviving 2000.
				 */
				unlock(&q->l);
				unlock(&fs->l);
				return 1;
			}
			/* append to slave's flush queue */
			fq->next = nil;
			if(q->flush != nil)
				q->flusht->next = fq;
			else
				q->flush = fq;
			q->flusht = fq;
			if(q->busy){
				pid = q->slave->pid;
				swiproc(q->slave, 0);
			}
			unlock(&q->l);
			unlock(&fs->l);
			if(exdebug && pid)
				print("export: swiproc %ld to flush %d\n", pid, fq->in.oldtag);
			return 0;
		}
	unlock(&fs->l);

	/* not found */
	return 1;
}

static void
exfreeq(Exq *q)
{
	Exq *fq;

	while((fq = q->flush) != nil){
		q->flush = fq->next;
		exfree(fq->export);
		free(fq);
	}
	exfree(q->export);
	free(q);
}

static void
exshutdown(Export *fs)
{
	Exq *q, **last;

	/* no unstarted work to discard */
	USED(last);

	/* tell workers to abandon work in progress */
	lock(&fs->l);
	while((q = fs->work) != nil){
		fs->work = q->next;
		lock(&q->l);
		q->shut = 1;
		swiproc(q->slave, 0);	/* whether busy or not */
		unlock(&q->l);
	}
	unlock(&fs->l);
}

static void
exfreefids(Export *fs)
{
	Fid *f, *n;
	int i;

	for(i = 0; i < Nfidhash; i++){
		for(f = fs->fid[i]; f != nil; f = n){
			n = f->next;
			f->attached = 0;
			if(f->ref == 0) {
				if(f->chan != nil)
					cclose(f->chan);
				freeuqid(&fs->uqids, f->qid);
				free(f);
			} else
				print("exfreefids: busy fid\n");
		}
	}
}

static void
exfreel(Export *fs, int line)
{
	if(exdebug)
		print("export p/s %d free %p ref %ld\n", up->pid, fs, fs->r.ref);
	/*
	 * Name the site of the decref that is one too many.
	 *
	 * "panic: decref" says only that some Ref went below zero, which
	 * in a file with three references per request and four callers
	 * is not a lead.  Checking here costs one compare and prints the
	 * LINE that over-released, which is the whole diagnosis.
	 */
	if(fs->r.ref <= 0)
		panic("exfree from line %d: Export %p ref already %ld",
			line, fs, fs->r.ref);
	if(decref(&fs->r) != 0)
		return;
	closepgrp(fs->pgrp);
	closeegrp(fs->egrp);
	closefgrp(fs->fgrp);
	cclose(fs->root);
	cclose(fs->io);
	exfreefids(fs);
	free(fs->user);
	free(fs);
}

/*
 * Serve one request, then return.  Called on a worker spawned for this
 * message, or on the connection's own reader when at the bound.
 */
static void
exdispatch(Exq *q)
{
	Export *fs;
	Exq *t, *fq, **last;
	int nstat;
	char *err;
	Pgrp *opg;
	Egrp *oeg;
	Fgrp *ofg;

	/*
	 * Assertions, because this faulted on a nil and the plan
	 * (doc/emu-exportfs-nil-plan.ms, H2 and H3) says to check the
	 * pointers it assumes before assuming them.  Cheap, once per
	 * request, and each names exactly which assumption broke.
	 */
	if(q == nil)
		panic("exdispatch: nil q");
	if(q->export == nil)
		panic("exdispatch: nil q->export");
	if(q->buf == nil)
		panic("exdispatch: nil q->buf");
	if(up == nil || up->env == nil)
		panic("exdispatch: nil up->env");
	fs = q->export;
	if(fs->user == nil)
		panic("exdispatch: nil fs->user");

	notkilled();
	lock(&q->l);
	q->slave = up;
	q->busy = 1;
	unlock(&q->l);
	/*
	 * fs->work was joined by exportproc, not here.
	 *
	 * Doing it here is a race the flush protocol cannot survive: the
	 * reader spawns a worker and goes straight back for the next
	 * message, so a Tflush for the request just handed out arrives
	 * before the worker has put it on the list.  exflushed() then
	 * finds nothing, reports "not found", and the reader answers
	 * Rflush -- while the worker is still running and will answer
	 * the original too.  See exportproc.
	 */

	/*
	 * Borrow the connection's groups, and give them back on EVERY
	 * exit -- normal, error, or killed.
	 *
	 * These are installed by plain assignment with no reference
	 * taken, so whoever runs this must not still be holding them
	 * when it exits: pexit would close three groups it never
	 * referenced, exfree closes the same three when the Export goes,
	 * and the second close panics "decref" from closefgrp.
	 *
	 * The old exslave got away with never restoring because it was a
	 * dedicated process that looped for ever.  Both callers here are
	 * different: a worker exits after one request, and the INLINE
	 * caller is the connection's own reader, whose env must survive
	 * the call.  Restoring inside exdispatch, which is what did the
	 * borrowing, covers both without either caller having to know.
	 */
	opg = up->env->pgrp;
	oeg = up->env->egrp;
	ofg = up->env->fgrp;
	if(waserror()){
		up->env->pgrp = opg;
		up->env->egrp = oeg;
		up->env->fgrp = ofg;
		nexterror();
	}

	up->env->pgrp = fs->pgrp;
	up->env->egrp = fs->egrp;
	up->env->fgrp = fs->fgrp;
	up->env->uid = fs->uid;
	up->env->gid = fs->gid;
	kstrdup(&up->env->user, fs->user);

	if(exdebug > 1)
		print("exdispatch %d %F\n", up->pid, &q->in);

	if(waserror()){
		print("exdispatch %d err %s\n", up->pid, up->env->errstr);
		err = up->env->errstr;
	}else{
		if(q->in.type >= Tmax || !fcalls[q->in.type]){
			snprint(up->genbuf, sizeof(up->genbuf), "unknown message: %F", &q->in);
			err = up->genbuf;
		}else{
			switch(q->in.type){
			case Tread:
				q->out.data = (char*)q->buf + IOHDRSZ;
				break;
			case Tstat:
				/*
				 * Clamp: Fcall.nstat is a ushort.
				 *
				 * This was a plain assignment, and it is fine
				 * while msize is 8K.  Raise msize to 64K and
				 * bsize-(MSGHDRSZ+BIT16SZ) is 65551, which
				 * stored in sixteen bits is FIFTEEN.  The
				 * server then offers a fifteen-byte stat
				 * buffer, devtab's stat cannot fit a stat in
				 * it and returns BIT16SZ with the needed size
				 * patched in, and Exstat's "n <= BIT16SZ"
				 * turns that into Eshortstat -- which comes
				 * back to the client as
				 *
				 *	ls: /n/t/...: stat buffer too small
				 *
				 * and was read for a long time as ls or the
				 * client being at fault.  Neither: it is one
				 * unclamped narrowing conversion, invisible in
				 * the source, and it is the whole reason a
				 * bigger msize "did not work".
				 *
				 * A stat never approaches 64K anyway, so the
				 * clamp costs nothing.
				 */
				nstat = q->bsize-(MSGHDRSZ+BIT16SZ);
				if(nstat > 0xFFFF)
					nstat = 0xFFFF;
				q->out.stat = q->buf + MSGHDRSZ + BIT16SZ;
				q->out.nstat = nstat;
				break;
			}
			err = (*fcalls[q->in.type])(fs, &q->in, &q->out);
		}
		poperror();
	}

	lock(&q->l);
	notkilled();
	q->busy = 0;
	if(!q->shut){
		/*
		 * A flushed request gets NO reply of its own.
		 *
		 * This read "q->flush == nil || err == nil", so a request
		 * that had been flushed but happened to succeed was answered
		 * anyway, and then the Rflush was sent as well.  Two replies
		 * for one tag, and the client has already been told by the
		 * Rflush that the tag is free.  Whatever work was done is
		 * wasted either way; sending it is not a saving, it is a
		 * protocol violation that costs the whole session.
		 */
		if(q->flush == nil){
			unlock(&q->l);
			q->out.type = q->in.type+1;
			q->out.tag = q->in.tag;
			if(err){
				q->out.type = Rerror;
				q->out.ename = err;
			}
			exreply(q, "exdispatch");
			lock(&q->l);
		}
		while((fq = q->flush) != nil && !q->shut){
			q->flush = fq->next;
			unlock(&q->l);
			exreply(fq, "exdispatch");
			exfreeq(fq);
			lock(&q->l);
		}
	}
	q->finished = 1;
	unlock(&q->l);

	lock(&fs->l);
	for(last = &fs->work; (t = *last) != nil; last = &t->next)
		if(t == q){
			*last = q->next;
			break;
		}
	unlock(&fs->l);

	notkilled();
	poperror();
	up->env->pgrp = opg;
	up->env->egrp = oeg;
	up->env->fgrp = ofg;
	exfreeq(q);
}

/*
 * A worker spawned for exactly one request.  It holds a reference to
 * the Export for its lifetime, and puts its OWN process groups back
 * before exiting -- exdispatch borrows the connection's by plain
 * assignment without referencing them, which was survivable for a
 * slave that looped for ever and panics "decref" for a worker that
 * exits after one request.
 */
static void
exworker(void *a)
{
	Exq *q = a;
	Export *fs = q->export;

	/*
	 * exdispatch borrows and returns the groups itself now, so this
	 * only has to make sure the counts and the Export reference are
	 * released however the call ends.
	 *
	 * Restore on EVERY way out, including the error unwind.
	 *
	 * exdispatch borrows the connection's pgrp, egrp and fgrp by
	 * plain assignment and takes no reference on them.  A plain
	 * return put them back; an error() inside exdispatch -- from
	 * exreply writing a closed connection, or a swiproc from
	 * exshutdown killing this worker mid-request -- unwound STRAIGHT
	 * PAST the restore to the kproc trampoline, and pexit then
	 * closed three groups this process had never referenced.  The
	 * first one to reach zero took the next decref below it with
	 * "panic: decref", from a Ref that had nothing to do with the
	 * Export, which is why instrumenting exfree found nothing.
	 *
	 * The counts and the Export reference have to be released on
	 * both paths too, or a worker killed at shutdown leaks the
	 * connection for ever.
	 */
	if(waserror()){
		exworkerdone(fs);
		pexit("", 0);
	}
	exdispatch(q);
	poperror();
	exworkerdone(fs);
	pexit("", 0);
}

/* release what a worker holds: its concurrency slots and its Export */
static void
exworkerdone(Export *fs)
{
	lock(&fs->l);
	fs->nproc--;
	unlock(&fs->l);
	lock(&exq.l);
	exq.nproc--;
	unlock(&exq.l);
	exfree(fs);
}

static void
exreply(Exq *q, char *who)
{
	Export *fs;
	Fcall *r;
	int n, dt, slot;
	ulong t0;

	fs = q->export;
	r = &q->out;

	n = convS2M(r, q->buf, q->bsize);
	if(n == 0){
		r->type = Rerror;
		if(fs->msize == 0)
			r->ename = "Tversion not seen";
		else
			r->ename = "failed to convert R-message";
		n = convS2M(r, q->buf, q->bsize);
	}

	if(exdebug)
		print("%s %d -> %F\n", who, up->pid, r);

	/*
	 * Time it, and say so when it is slow.
	 *
	 * This write has no timeout.  Against a client that stopped
	 * reading it blocks until the kernel gives up on the connection,
	 * which can be minutes, and whoever is running it -- a worker, or
	 * the reader itself when the worker caps are full -- does nothing
	 * else meanwhile.  Every "the server has stopped" report in this
	 * tree so far has been something not saying what it was waiting
	 * for; this one says it.
	 */
	t0 = osmillisec();
	slot = exwritestart(r->type, devtab[fs->io->type]->dc);
	if(!waserror()){
		devtab[fs->io->type]->write(fs->io, q->buf, n, 0);
		poperror();
	}
	exwriteend(slot);
	dt = osmillisec() - t0;
	if(dt >= 2000)
		print("exportfs: %s %d: writing R%d took %dms "
			"(client is not reading)\n", who, up->pid, r->type, dt);
}

static int
exiounit(Export *fs, Chan *c)
{
	int iounit;

	iounit = fs->msize-IOHDRSZ;
	if(c->iounit != 0 && c->iounit < fs->msize)
		iounit = c->iounit;
	return iounit;
}

static Fid*
Exmkfid(Export *fs, ulong fid)
{
	ulong h;
	Fid *f, *nf;

	nf = malloc(sizeof(Fid));
	if(nf == nil)
		return nil;
	lock(&fs->fidlock);
	h = fid % Nfidhash;
	for(f = fs->fid[h]; f != nil; f = f->next){
		if(f->fid == fid){
			unlock(&fs->fidlock);
			free(nf);
			return nil;
		}
	}

	nf->next = fs->fid[h];
	if(nf->next != nil)
		nf->next->last = &nf->next;
	nf->last = &fs->fid[h];
	fs->fid[h] = nf;

	nf->fid = fid;
	nf->ref = 1;
	nf->attached = 1;
	nf->offset = 0;
	nf->chan = nil;
	nf->qid = nil;
	unlock(&fs->fidlock);
	return nf;
}

static Fid*
Exgetfid(Export *fs, ulong fid)
{
	Fid *f;
	ulong h;

	lock(&fs->fidlock);
	h = fid % Nfidhash;
	for(f = fs->fid[h]; f; f = f->next) {
		if(f->fid == fid){
			if(f->attached == 0)
				break;
			f->ref++;
			unlock(&fs->fidlock);
			return f;
		}
	}
	unlock(&fs->fidlock);
	return nil;
}

static void
Exputfid(Export *fs, Fid *f)
{
	Chan *c;

	lock(&fs->fidlock);
	f->ref--;
	if(f->ref == 0 && f->attached == 0){
		c = f->chan;
		f->chan = nil;
		*f->last = f->next;
		if(f->next != nil)
			f->next->last = f->last;
		unlock(&fs->fidlock);
		freeuqid(&fs->uqids, f->qid);
		free(f);
		if(c != nil)
			cclose(c);
		return;
	}
	unlock(&fs->fidlock);
}

static Chan*
exmount(Chan *c, Mhead **mp, int doname)
{
	struct {Chan *nc;} nc;
	Cname *oname;

	nc.nc = nil;
	if((c->flag & COPEN) == 0 && findmount(&nc.nc, mp, c->type, c->dev, c->qid)){
		if(waserror()){
			cclose(nc.nc);
			nexterror();
		}
		nc.nc = cunique(nc.nc);
		poperror();
		if(doname){
			oname = c->name;
			incref(&oname->r);
			cnameclose(nc.nc->name);
			nc.nc->name = oname;
		}
		return nc.nc;
	}
	incref(&c->r);
	return c;
}

static char*
Exversion(Export *fs, Fcall *t, Fcall *r)
{
	char *p;
	static char version[] = VERSION9P;
	int iounit;

	r->msize = t->msize;
	if(r->msize > MAXRPCMAX)
		r->msize = MAXRPCMAX;
	iounit = fs->io->iounit;
	if(iounit != 0 && iounit > 64 && iounit < r->msize)
		r->msize = iounit;
	if(r->msize < 64)
		return "message size too small";
	if(0)
		print("msgsize=%d\n", r->msize);
	if((p = strchr(t->version, '.')) != nil)
		*p = 0;
	if(strncmp(t->version, "9P", 2) ==0 && strcmp(version, t->version) <= 0){
		r->version = version;
		fs->msize = r->msize;
	}else
		r->version = "unknown";
	return nil;
}

static char*
Exauth(Export *fs, Fcall *t, Fcall *r)
{
	USED(fs);
	USED(t);
	USED(r);
	return "authentication not required";
}

static char*
Exattach(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;

	f = Exmkfid(fs, t->fid);
	if(f == nil)
		return Edupfid;
	if(waserror()){
		f->attached = 0;
		Exputfid(fs, f);
		return up->env->errstr;
	}
	f->chan = cclone(fs->root);
	f->qid = uqidalloc(&fs->uqids, f->chan);
	poperror();
	r->qid = mkuqid(f->chan, f->qid);
	Exputfid(fs, f);
	return nil;
}

static char*
Exclunk(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;

	USED(r);
	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	f->attached = 0;
	Exputfid(fs, f);
	return nil;
}

static int
safewalk(Chan **cp, char **names, int nnames, int nomount, int *nerror)
{
	int r;

	/* walk can raise error */
	if(waserror())
		return -1;
	r = walk(cp, names, nnames, nomount, nerror);
	poperror();
	return r;
}

static char*
Exwalk(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f, *nf;
	Chan *c;
	char *name;
	Uqid *qid;
	int i;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(f->chan->flag & COPEN){
		Exputfid(fs, f);
		return Eopen;
	}
	if(waserror())
		return up->env->errstr;
	c = cclone(f->chan);
	poperror();
	qid = f->qid;
	incref(&qid->r);
	r->nwqid = 0;
	if(t->nwname > 0){
		for(i=0; i<t->nwname; i++){
			name = t->wname[i];
			if(!exisroot(fs, c) || *name != '\0' && strcmp(name, "..") != 0){
				if(safewalk(&c, &name, 1, 0, nil) < 0){
					/* leave the original state on error */
					cclose(c);
					freeuqid(&fs->uqids, qid);
					Exputfid(fs, f);
					if(i == 0)
						return up->env->errstr;
					return nil;
				}
				freeuqid(&fs->uqids, qid);
				qid = uqidalloc(&fs->uqids, c);
			}
			r->wqid[r->nwqid++] = mkuqid(c, qid);
		}
	}

	if(t->newfid != t->fid){
		nf = Exmkfid(fs, t->newfid);
		if(nf == nil){
			cclose(c);
			freeuqid(&fs->uqids, qid);
			Exputfid(fs, f);
			return Edupfid;
		}
		nf->chan = c;
		nf->qid = qid;
		Exputfid(fs, nf);
	}else{
		cclose(f->chan);
		f->chan = c;
		freeuqid(&fs->uqids, f->qid);
		f->qid = qid;
	}
	Exputfid(fs, f);
	return nil;
}

static char*
Exopen(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;
	Uqid *qid;
	Mhead *m;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(f->chan->flag & COPEN){
		Exputfid(fs, f);
		return Emode;
	}
	m = nil;
	c = exmount(f->chan, &m, 1);
	if(waserror()){
		cclose(c);
		Exputfid(fs, f);
		return up->env->errstr;
	}

	/* only save the mount head if it's a multiple element union */
	if(m && m->mount && m->mount->next)
		c->umh = m;
	else
		putmhead(m);

	c = devtab[c->type]->open(c, t->mode);
	if(t->mode & ORCLOSE)
		c->flag |= CRCLOSE;

	qid = uqidalloc(&fs->uqids, c);
	poperror();
	freeuqid(&fs->uqids, f->qid);
	cclose(f->chan);
	f->chan = c;
	f->qid = qid;
	f->offset = 0;
	r->qid = mkuqid(c, f->qid);
	r->iounit = exiounit(fs, c);
	Exputfid(fs, f);
	return nil;
}

static char*
Excreate(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	volatile struct {Chan *c;} c, dc;
	Cname *oname;
	Uqid *qid;
	Mhead *m;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(f->chan->flag & COPEN){
		Exputfid(fs, f);
		return Emode;
	}
	if(waserror()){
		Exputfid(fs, f);
		return up->env->errstr;
	}
	validname(t->name, 0);
	if(t->name[0] == '.' && (t->name[1] == '\0' || t->name[1] == '.' && t->name[2] == '\0'))
		error(Efilename);	/* underlying server should check, but stop it here */

	m = nil;
	c.c = exmount(f->chan, &m, 1);
	if(waserror()){
		cclose(c.c);
		if(m != nil)
			putmhead(m);
		nexterror();
	}
	if(m != nil){
		oname = c.c->name;
		incref(&oname->r);
		if(waserror()){
			cnameclose(oname);
			nexterror();
		}
		dc.c = createdir(c.c, m);
		if(waserror()){
			cclose(dc.c);
			nexterror();
		}
		c.c = cunique(dc.c);
		poperror();
		cnameclose(c.c->name);
		poperror();
		c.c->name = oname;
	}
	devtab[c.c->type]->create(c.c, t->name, t->mode, t->perm);
	c.c->name = addelem(c.c->name, t->name);
	if(t->mode & ORCLOSE)
		c.c->flag |= CRCLOSE;
	qid = uqidalloc(&fs->uqids, c.c);
	poperror();
	if(m != nil)
		putmhead(m);

	poperror();
	cclose(f->chan);
	f->chan = c.c;
	freeuqid(&fs->uqids, f->qid);
	f->qid = qid;
	r->qid = mkuqid(c.c, f->qid);
	r->iounit = exiounit(fs, c.c);
	Exputfid(fs, f);
	return nil;
}

static char*
Exread(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;
	Lock *cl;
	vlong off;
	int dir, n, seek;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;

	if(waserror()) {
		Exputfid(fs, f);
		return up->env->errstr;
	}
	c = f->chan;
	if((c->flag & COPEN) == 0)
		error(Emode);
	if(c->mode != OREAD && c->mode != ORDWR)
		error(Eaccess);
	if(t->count < 0 || t->count > fs->msize-IOHDRSZ)
		error(Ecount);
	if(t->offset < 0)
		error(Enegoff);
	dir = c->qid.type & QTDIR;
	if(dir && t->offset != f->offset){
		if(t->offset != 0)
			error(Eseekdir);
		f->offset = 0;
		c->uri = 0;
		c->dri = 0;
	}

	for(;;){
		n = t->count;
		seek = 0;
		off = t->offset;
		if(dir && f->offset != off){
			off = f->offset;
			n = t->offset - off;
			if(n > MAXFDATA)
				n = MAXFDATA;
			seek = 1;
		}
		if(dir && c->umh != nil){
			if(0)
				print("union read %d uri %d dri %d\n", seek, c->uri, c->dri);
			n = unionread(c, r->data, n);
		}
		else{
			cl = &c->l;
			lock(cl);
			c->offset = off;
			unlock(cl);
			n = devtab[c->type]->read(c, r->data, n, off);
			lock(cl);
			c->offset += n;
			unlock(cl);
		}
		f->offset = off + n;
		if(n == 0 || !seek)
			break;
	}
	r->count = n;

	poperror();
	Exputfid(fs, f);
	return nil;
}

static char*
Exwrite(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(waserror()){
		Exputfid(fs, f);
		return up->env->errstr;
	}
	c = f->chan;
	if((c->flag & COPEN) == 0)
		error(Emode);
	if(c->mode != OWRITE && c->mode != ORDWR)
		error(Eaccess);
	if(c->qid.type & QTDIR)
		error(Eisdir);
	if(t->count < 0 || t->count > fs->msize-IOHDRSZ)
		error(Ecount);
	if(t->offset < 0)
		error(Enegoff);
	r->count = devtab[c->type]->write(c, t->data, t->count, t->offset);
	poperror();
	Exputfid(fs, f);
	return nil;
}

static char*
Exstat(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;
	int n;

	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	c = exmount(f->chan, nil, 1);
	if(waserror()){
		cclose(c);
		Exputfid(fs, f);
		return up->env->errstr;
	}
	n = devtab[c->type]->stat(c, r->stat, r->nstat);
	if(n <= BIT16SZ)
		error(Eshortstat);
	r->nstat = n;
	poperror();
	/* TO DO: need to change qid */
	cclose(c);
	Exputfid(fs, f);
	return nil;
}

static char*
Exwstat(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;

	USED(r);
	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(waserror()){
		Exputfid(fs, f);
		return up->env->errstr;
	}
	validstat(t->stat, t->nstat);	/* check name */

	c = exmount(f->chan, nil, 0);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	devtab[c->type]->wstat(c, t->stat, t->nstat);
	poperror();

	cclose(c);
	poperror();
	Exputfid(fs, f);
	return nil;
}

static char*
Exremove(Export *fs, Fcall *t, Fcall *r)
{
	Fid *f;
	Chan *c;

	USED(r);
	f = Exgetfid(fs, t->fid);
	if(f == nil)
		return Enofid;
	if(waserror()){
		f->attached = 0;
		Exputfid(fs, f);
		return up->env->errstr;
	}
	c = exmount(f->chan, nil, 0);
	if(waserror()){
		c->type = 0;	/* see below */
		cclose(c);
		nexterror();
	}
	devtab[c->type]->remove(c);
	poperror();
	poperror();

	/*
	 * chan is already clunked by remove.
	 * however, we need to recover the chan,
	 * and follow sysremove's lead in making it point to root.
	 */
	c->type = 0;
	cclose(c);

	f->attached = 0;
	Exputfid(fs, f);
	return nil;
}
