/*
 * Record and replay the input a session received.
 *
 * The point of interposing here rather than on the name space is that this is
 * below every bind. iostats(4) records Styx, which catches an enormous amount
 * because devices are files - but a program that binds #i reaches the device
 * directly and its input is never seen (see drawbind(1)). Input arrives
 * through mousetrack() and gkbdputc(), which every platform's window driver
 * calls and no Limbo program can get underneath, so recording there catches
 * the whole system: wm, its Tk clients, and anything they start.
 *
 * Deliberately port-only. Not one platform file changes, because the two
 * functions the platforms already call are the hooks. The Nt, Plan9, 9front
 * and X11 drivers get this without being edited or recompiled differently.
 *
 * What this reproduces is the input, not the execution. Dis scheduling is not
 * recorded, so a program racing two of its own processes can still diverge on
 * identical input. That is a real limit and is documented rather than implied
 * away.
 *
 *	INFERNO_INPUT_RECORD=/tmp/session.in	emu ...
 *	INFERNO_INPUT_REPLAY=/tmp/session.in	emu ...
 */

#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

enum {
	Rmouse	= 'm',		/* a=x b=y c=buttons */
	Rkey	= 'k',		/* a=rune */
	Rresize	= 'r',		/* a=w b=h */

	Hdrsz	= 16,		/* magic[8] xsize[4] ysize[4] */
	Recsz	= 17,		/* type[1] msec[4] a[4] b[4] c[4] */

	Nring	= 1024,		/* events held while the drain proc is not running */
};

static char magic[8] = "inferec1";

typedef struct Ievent Ievent;
struct Ievent {
	uchar	type;
	ulong	msec;		/* relative to the start of the session */
	int	a;
	int	b;
	int	c;
};

/*
 * One producer and one consumer, so no lock, exactly as ptrq in devpointer.c
 * does it: every event comes from the single host window-driver thread, and
 * only the drain kproc reads. Locking here would be locking on a thread that
 * has no Proc, which is why the shape is this one.
 *
 * That there is one producer is worth being able to check rather than trust.
 * Keys arrive only from the platform's driver. Resizes look like two paths -
 * win-cocoa.m calls mouseresize directly, and also reaches it through port
 * code as screenresize -> drawscreenresize -> mouseresize - but both are on
 * the host UI thread; drawscreenresize has exactly that one caller, and
 * devdraw.c's own comment says the same. Check that again before adding a
 * caller, and add a lock if it ever stops being true.
 */
static struct {
	int	on;
	int	fd;
	ulong	t0;
	Ievent	ring[Nring];
	int	wr;
	int	rd;
	int	lost;
	int	toldlost;
	Rendez	r;
} rec;

static struct {
	int	on;
} rep;

/*
 * Nullable, and registered by devpointer.c's init if that device is in the
 * build at all. A headless emu (emu-g) has no pointer device, so linking
 * against mousetrackt directly would make this file unbuildable there - which
 * is exactly what happened. The keyboard needs no such treatment because
 * devcons is in every configuration.
 */
void	(*inputmousehook)(int, int, int, ulong);
void	(*inputresizehook)(int, int);

static void
pbe32(uchar *p, ulong v)
{
	p[0] = v>>24;
	p[1] = v>>16;
	p[2] = v>>8;
	p[3] = v;
}

static ulong
gbe32(uchar *p)
{
	return ((ulong)p[0]<<24) | ((ulong)p[1]<<16) | ((ulong)p[2]<<8) | (ulong)p[3];
}

/*
 * True while a replay is driving the system, in which case real host input is
 * dropped. Letting it through would mean a stray movement of the actual mouse
 * silently corrupted the run, which is the sort of thing that shows up as an
 * unreproducible replay rather than as an error.
 */
int
inputreplaying(void)
{
	return rep.on;
}

static int
recnotempty(void *v)
{
	USED(v);
	return rec.rd != rec.wr;
}

void
inputrecord(int type, int a, int b, int c)
{
	int w;
	ulong now;

	if(!rec.on)
		return;
	now = osmillisec();
	w = rec.wr + 1;
	if(w >= Nring)
		w = 0;
	if(w == rec.rd){
		rec.lost++;		/* the drain proc says so */
		return;
	}
	rec.ring[rec.wr].type = type;
	rec.ring[rec.wr].msec = now - rec.t0;
	rec.ring[rec.wr].a = a;
	rec.ring[rec.wr].b = b;
	rec.ring[rec.wr].c = c;
	rec.wr = w;
	Wakeup(&rec.r);
}

static void
inputrecproc(void *v)
{
	uchar buf[Recsz];
	Ievent e;

	USED(v);
	for(;;){
		Sleep(&rec.r, recnotempty, 0);
		/*
		 * A dropped event makes a short trace that replays cleanly and
		 * looks right, which for a tool whose whole value is fidelity
		 * is the one failure that must not be silent.
		 */
		if(rec.lost != 0 && !rec.toldlost){
			rec.toldlost = 1;
			print("inputrec: the event ring overflowed;"
				" this recording is INCOMPLETE\n");
		}
		while(rec.rd != rec.wr){
			e = rec.ring[rec.rd];
			if(++rec.rd >= Nring)
				rec.rd = 0;
			buf[0] = e.type;
			pbe32(buf+1, e.msec);
			pbe32(buf+5, e.a);
			pbe32(buf+9, e.b);
			pbe32(buf+13, e.c);
			if(kwrite(rec.fd, buf, Recsz) != Recsz){
				print("inputrec: write failed, recording stops: %r\n");
				rec.on = 0;
				kclose(rec.fd);
				pexit("", 0);
			}
		}
	}
}

/*
 * Reads whole records. kread on a file returns what is there, but a short read
 * at the end of a truncated trace must not be replayed as a zeroed event.
 */
static int
readrec(int fd, uchar *buf, int n)
{
	int r, got;

	for(got = 0; got < n; got += r){
		r = kread(fd, buf+got, n-got);
		if(r <= 0)
			return got;
	}
	return got;
}

static void
inputrepproc(void *v)
{
	uchar hdr[Hdrsz], buf[Recsz];
	int fd, w, h, n, nev;
	ulong base, at, now;
	char *path;

	path = v;
	fd = kopen(path, OREAD);
	if(fd < 0){
		print("inputrec: cannot open %s for replay: %r\n", path);
		rep.on = 0;
		pexit("", 0);
	}
	if(readrec(fd, hdr, Hdrsz) != Hdrsz || memcmp(hdr, magic, sizeof magic) != 0){
		print("inputrec: %s is not an input recording\n", path);
		rep.on = 0;
		kclose(fd);
		pexit("", 0);
	}
	w = gbe32(hdr+8);
	h = gbe32(hdr+12);
	/*
	 * Pointer coordinates are absolute, so a replay into a differently
	 * sized window lands every click somewhere else. That diverges for a
	 * reason which has nothing to do with the recording, so say so here
	 * rather than let it look like the session simply behaved differently.
	 */
	if(w != Xsize || h != Ysize)
		print("inputrec: recorded at %dx%d but running at %dx%d;"
			" pointer positions will not line up\n", w, h, Xsize, Ysize);

	/*
	 * Times are relative to the start of the session, not to the first
	 * event, so the wait before the first one is reproduced too. That
	 * matters more than it sounds: anchoring on the first event injects it
	 * the instant emu boots, long before the session's programs are
	 * running, and the whole recording is then delivered into a queue and
	 * read out in one burst. The order survives that and the timing does
	 * not, which is a failure that looks like success.
	 */
	base = osmillisec();
	nev = 0;
	while(readrec(fd, buf, Recsz) == Recsz){
		at = base + gbe32(buf+1);
		now = osmillisec();
		if(at > now)
			osmillisleep(at - now);
		n = gbe32(buf+5);
		switch(buf[0]){
		case Rmouse:
			/*
			 * The recorded time is passed through, not restamped
			 * with osmillisec(). Consumers compare msec deltas -
			 * appl/acme/text.b treats two clicks under 500ms apart
			 * as a double click - so restamping turns a recorded
			 * double click into two single clicks whenever the
			 * injection drifts, and does it intermittently.
			 */
			if(inputmousehook != nil)
				inputmousehook(gbe32(buf+13), n, gbe32(buf+9), at);
			break;
		case Rkey:
			gkbdputc1(gkbdq, n);
			break;
		case Rresize:
			if(inputresizehook != nil)
				inputresizehook(n, gbe32(buf+9));
			break;
		}
		nev++;
	}
	kclose(fd);
	print("inputrec: %d events replayed from %s\n", nev, path);
	rep.on = 0;
	pexit("", 0);
}

void
inputrecinit(void)
{
	uchar hdr[Hdrsz];
	char *path;

	path = getenv("INFERNO_INPUT_REPLAY");
	if(path != nil && *path != '\0'){
		rep.on = 1;
		/*
		 * KPDUP*: a kproc otherwise starts with a fresh fd group and no
		 * name space, so it cannot see the descriptor opened here and
		 * cannot open the trace by name. The recorded file was created
		 * and its header written, then every event vanished, which
		 * looks exactly like "no input arrived".
		 */
		kproc("inputreplay", inputrepproc, path, KPDUPFDG|KPDUPPG|KPDUPENVG);
		return;		/* recording a replay would only copy the trace */
	}

	path = getenv("INFERNO_INPUT_RECORD");
	if(path == nil || *path == '\0')
		return;
	rec.fd = kcreate(path, OWRITE, 0666);
	if(rec.fd < 0){
		print("inputrec: cannot create %s: %r\n", path);
		return;
	}
	memmove(hdr, magic, sizeof magic);
	pbe32(hdr+8, Xsize);
	pbe32(hdr+12, Ysize);
	if(kwrite(rec.fd, hdr, Hdrsz) != Hdrsz){
		print("inputrec: cannot write the header of %s: %r\n", path);
		kclose(rec.fd);
		return;
	}
	rec.t0 = osmillisec();
	rec.on = 1;
	kproc("inputrecord", inputrecproc, nil, KPDUPFDG|KPDUPPG|KPDUPENVG);
}
