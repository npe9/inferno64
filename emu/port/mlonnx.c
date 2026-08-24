/*
 * ml(3)'s backend: talk to mlsrv, which runs the model in a process of its
 * own.
 *
 * This file used to link onnxruntime directly, and that cannot be made to
 * work. emu aliases the libc allocators into the Inferno pool - malloc,
 * mallocz, free, realloc, calloc - and onnxruntime uses several the aliasing
 * does not cover: posix_memalign, aligned_alloc, malloc_size, and the
 * malloc_zone calls. So it allocated on one heap and freed on the other, and
 * the corruption surfaced later, inside Apple's neural library, as a jump to
 * a small address. One utterance per emu worked; the second did not, and
 * under wm often the first did not either.
 *
 * That was not fixable by tuning. Bigger pools did not help, nor did running
 * onnxruntime on one thread; the pool already aligns to 16. Wrapping the rest
 * of the surface is not possible - malloc_zone_* is not a wrappable interface
 * - and removing the aliasing does not link, because emu's own code needs the
 * wrap symbols.
 *
 * So the library lives where the aliasing is not. emu starts mlsrv with
 * oscmd(), the same way devcmd(3) starts any host command, and speaks a
 * length-delimited protocol to it over a pipe. emu links no part of
 * onnxruntime now, which is worth more than the bug it fixes: a device that
 * virtualizes a host capability should not share an address space with the
 * thing it virtualizes, and this is what ignoring that looks like.
 *
 * One server per model instance. Its lifetime is the instance's: closing the
 * pipe ends it, which is what mlsrv does when its read gives end of file.
 */

#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ml.h"
#include	<errno.h>

typedef struct Mlmodel Mlmodel;

struct Mlmodel {
	void*	proc;		/* oscmd handle, for killing it */
	int	fd[3];		/* to it, from it, its complaints */
	int	dead;
};

enum {
	Oopen	= 'o',
	Oinfo	= 'i',
	Oshape	= 's',
	Owrite	= 'w',
	Orun	= 'r',
	Oget	= 'g',
};

void*	mlort_open(unsigned char*, int, char*, char*, int);
void	mlort_close(void*);
int	mlort_info(void*, char*, int);
int	mlort_setinput(void*, char*, unsigned char*, int, char*, int);
int	mlort_run(void*, char*, int);
int	mlort_getoutput(void*, char*, unsigned char*, int, char*, int);
int	mlort_setshape(void*, char*, char**, int, char*, int);

static void
seterr(char *err, int nerr, char *s)
{
	if(err != nil && nerr > 0)
		snprint(err, nerr, "%s", s);
}

/*
 * Both of these retry on EINTR, and must. emu knocks a thread out of a
 * blocking host call by delivering SIGUSR1 to it - that is the whole purpose
 * of the signal, and os.c says so - so any read or write that blocks here will
 * sooner or later come back short with EINTR and nothing wrong.
 *
 * Not retrying looked exactly like a server that had crashed. Three utterances
 * in five failed at the run step, and only at the run step: the other
 * exchanges answer in microseconds, while a run blocks for about a second and
 * is the only one a signal has time to land in.
 */
static int
allwrite(int fd, void *b, int n)
{
	int put, r;

	for(put = 0; put < n; put += r){
		r = write(fd, (char*)b + put, n - put);
		if(r < 0 && errno == EINTR){
			r = 0;
			continue;
		}
		if(r <= 0)
			return -1;
	}
	return 0;
}

static int
allread(int fd, void *b, int n)
{
	int got, r;

	for(got = 0; got < n; got += r){
		r = read(fd, (char*)b + got, n - got);
		if(r < 0 && errno == EINTR){
			r = 0;
			continue;
		}
		if(r <= 0)
			return -1;
	}
	return 0;
}

/*
 * What the server had to say for itself. Its stderr is a pipe nothing else
 * reads, so when it dies the complaint is sitting there unread; without this
 * every death looks the same from here, which is to say it looks like nothing.
 *
 * Only called once the exchange has already failed, so the pipe is at end of
 * file and this does not block.
 */
static void
srvwhy(Mlmodel *m, char *what, char *err, int nerr)
{
	char buf[512];
	int n;

	n = 0;
	if(m->fd[2] >= 0){
		n = read(m->fd[2], buf, sizeof(buf)-1);
		if(n < 0)
			n = 0;
	}
	buf[n] = '\0';
	while(n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r'))
		buf[--n] = '\0';
	if(n > 0)
		snprint(err, nerr, "%s: %s", what, buf);
	else
		seterr(err, nerr, what);
}

static void
put32(uchar *p, ulong v)
{
	p[0] = v>>24; p[1] = v>>16; p[2] = v>>8; p[3] = v;
}

static ulong
get32(uchar *p)
{
	return ((ulong)p[0]<<24) | ((ulong)p[1]<<16) | ((ulong)p[2]<<8) | p[3];
}

/*
 * One exchange. The reply's payload is returned in *rb when wanted, and the
 * caller frees it; an error reply becomes the error string instead.
 *
 * A server that has died takes the instance with it rather than being
 * restarted quietly: a model half loaded into a process that is gone is not
 * something to paper over.
 */
static int
rpc(Mlmodel *m, int op, void *a, int na, void *b, int nb, uchar **rb, int *nrb,
	char *err, int nerr)
{
	uchar hdr[5], *p;
	ulong n;

	if(m->dead){
		seterr(err, nerr, "the model server has gone");
		return -1;
	}
	hdr[0] = op;
	put32(hdr+1, na + nb);
	if(allwrite(m->fd[0], hdr, 5) < 0 ||
	   (na > 0 && allwrite(m->fd[0], a, na) < 0) ||
	   (nb > 0 && allwrite(m->fd[0], b, nb) < 0)){
		m->dead = 1;
		seterr(err, nerr, "cannot reach the model server");
		return -1;
	}
	if(allread(m->fd[1], hdr, 5) < 0){
		m->dead = 1;
		srvwhy(m, "the model server gave no answer", err, nerr);
		return -1;
	}
	n = get32(hdr+1);
	p = nil;
	if(n > 0){
		p = malloc(n + 1);
		if(p == nil){
			m->dead = 1;
			seterr(err, nerr, "out of memory");
			return -1;
		}
		if(allread(m->fd[1], p, n) < 0){
			free(p);
			m->dead = 1;
			seterr(err, nerr, "the model server stopped mid-answer");
			return -1;
		}
		p[n] = 0;
	}
	if(hdr[0] != 0){
		seterr(err, nerr, p != nil? (char*)p: "the model server said no");
		free(p);
		return -1;
	}
	if(rb != nil){
		*rb = p;
		*nrb = n;
	}else
		free(p);
	return 0;
}

void*
mlort_open(unsigned char *spec, int nspec, char *units, char *err, int nerr)
{
	Mlmodel *m;
	char *argv[2];
	char *u;

	if(spec == nil || nspec <= 0){
		seterr(err, nerr, "empty model");
		return nil;
	}
	m = malloc(sizeof(Mlmodel));
	if(m == nil){
		seterr(err, nerr, "out of memory");
		return nil;
	}
	memset(m, 0, sizeof(Mlmodel));

	/*
	 * Found on the host's path, as any other host command is, or named
	 * outright when it is somewhere else - which it will be for anyone who
	 * has not installed the tree's bin directory.
	 */
	argv[0] = getenv("INFERNO_MLSRV");
	if(argv[0] == nil || argv[0][0] == '\0')
		argv[0] = "mlsrv";
	argv[1] = nil;
	if(waserror()){
		free(m);
		seterr(err, nerr, "cannot start mlsrv: it must be on the host's path");
		return nil;
	}
	m->proc = oscmd(argv, 0, nil, m->fd);
	poperror();
	if(m->proc == nil){
		free(m);
		seterr(err, nerr, "cannot start mlsrv");
		return nil;
	}

	u = units != nil && *units != '\0'? units: "all";
	if(rpc(m, Oopen, u, strlen(u)+1, spec, nspec, nil, nil, err, nerr) < 0){
		mlort_close(m);
		return nil;
	}
	return m;
}

void
mlort_close(void *h)
{
	Mlmodel *m = h;

	if(m == nil)
		return;
	/* closing the pipe is how mlsrv is told to stop */
	if(m->fd[0] >= 0)
		close(m->fd[0]);
	if(m->fd[1] >= 0)
		close(m->fd[1]);
	if(m->fd[2] >= 0)
		close(m->fd[2]);
	if(m->proc != nil){
		oscmdkill(m->proc);
		oscmdfree(m->proc);
	}
	free(m);
}

int
mlort_info(void *h, char *buf, int nbuf)
{
	Mlmodel *m = h;
	uchar *p;
	int n;
	char err[ERRMAX];

	if(m == nil || buf == nil || nbuf <= 0)
		return -1;
	err[0] = '\0';
	if(rpc(m, Oinfo, nil, 0, nil, 0, &p, &n, err, sizeof(err)) < 0)
		return -1;
	if(n > nbuf-1)
		n = nbuf-1;
	memmove(buf, p, n);
	buf[n] = '\0';
	free(p);
	return n;
}

int
mlort_setshape(void *h, char *name, char **dims, int ndims, char *err, int nerr)
{
	Mlmodel *m = h;
	char buf[256];
	int i, o;

	if(m == nil)
		return -1;
	o = snprint(buf, sizeof buf, "%s", name != nil? name: "");
	o++;				/* the terminating nul is the separator */
	for(i = 0; i < ndims; i++)
		o += snprint(buf+o, sizeof buf - o, "%s%s", i? " ": "", dims[i]);
	return rpc(m, Oshape, buf, o+1, nil, 0, nil, nil, err, nerr);
}

int
mlort_setinput(void *h, char *name, unsigned char *b, int n, char *err, int nerr)
{
	Mlmodel *m = h;
	char nm[128];
	int o;

	if(m == nil)
		return -1;
	o = snprint(nm, sizeof nm, "%s", name != nil? name: "") + 1;
	return rpc(m, Owrite, nm, o, b, n, nil, nil, err, nerr);
}

int
mlort_run(void *h, char *err, int nerr)
{
	Mlmodel *m = h;

	if(m == nil)
		return -1;
	return rpc(m, Orun, nil, 0, nil, 0, nil, nil, err, nerr);
}

int
mlort_getoutput(void *h, char *name, unsigned char *b, int nbuf, char *err, int nerr)
{
	Mlmodel *m = h;
	char nm[128];
	uchar *p;
	int o, n;

	if(m == nil)
		return -1;
	o = snprint(nm, sizeof nm, "%s", name != nil? name: "") + 1;
	if(rpc(m, Oget, nm, o, nil, 0, &p, &n, err, nerr) < 0)
		return -1;
	/*
	 * devml.c asks how big the result is before it has anywhere to put it,
	 * so a nil buffer is a question rather than a too-small read. The
	 * answer is fetched either way, which costs one extra round trip per
	 * run and keeps the server free of any memory of what it last said.
	 */
	if(b == nil){
		free(p);
		return n;
	}
	if(n > nbuf){
		free(p);
		seterr(err, nerr, "the output does not fit the read");
		return -1;
	}
	memmove(b, p, n);
	free(p);
	return n;
}

/*
 * Installed at load time, because this file is only linked where the host has
 * something to talk to. Where it is not, mlhostbe stays nil and ml(3) uses the
 * software backend without anyone having to ask for it.
 */
static Mlbackend hostbe = {
	"host",
	mlort_open,
	mlort_close,
	mlort_info,
	mlort_setinput,
	mlort_run,
	mlort_getoutput,
	mlort_setshape,
};

__attribute__((constructor))
static void
mlhwinit(void)
{
	mlhostbe = &hostbe;
}
