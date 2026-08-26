/*
 * userprog - a library-OS program for the Osprey microkernel.
 *
 * It runs on top of the microkernel and reaches the kernel only through
 * the minimal system-call interface - write and exit.  Its file
 * operations are not the kernel's: they are a personality it links as a
 * library and calls in its own address space.  persopen and persread
 * below are that library in miniature - a name space of a couple of
 * files and the open and read over it.  The kernel knows none of it.
 * This is what the paper means by a library operating system: the OS
 * personality implemented as a library, run on top of the microkernel.
 *
 * As with initcode there is no separate loader: the whole image is
 * carried into the program's text, so it stays modest.
 */
#include <u.h>
#include <libc.h>

/* the personality's name space: files and their contents */
static char *pname[] = {
	"/dev/osversion",
	"/greeting",
};
static char *pdata[] = {
	"osprey-libos personality, version 1\n",
	"this file was served by a user-space personality library\n",
};

/* the personality's open: resolve a name to a handle */
static int
persopen(char *name)
{
	int i;

	for(i = 0; i < nelem(pname); i++)
		if(strcmp(name, pname[i]) == 0)
			return i;
	return -1;
}

/* the personality's read: the file's contents */
static long
persread(int fd, char *buf, long max)
{
	long n;

	if(fd < 0 || fd >= nelem(pdata))
		return -1;
	n = strlen(pdata[fd]);
	if(n > max)
		n = max;
	memmove(buf, pdata[fd], n);
	return n;
}

static void
puts(char *s)
{
	write(2, s, strlen(s));
}

void
startboot(char*, char**)
{
	char buf[256];
	int fd;
	long n;

	puts("osprey user: a program on the microkernel, opening a file through its personality library\n");
	fd = persopen("/dev/osversion");
	if(fd >= 0){
		n = persread(fd, buf, sizeof buf);
		if(n > 0)
			write(2, buf, n);
	}
	puts("osprey user: that file came from the library in user space, not from the kernel\n");

	/*
	 * And the microkernel's message ring.  This is how a library-OS
	 * program reaches what it does not hold: it maps its container's
	 * ring with segattach, puts a request in the ring in its own
	 * memory, calls the kernel once to carry it, and reads the reply
	 * back from the ring.  The request here is poll, a mechanism the
	 * kernel answers itself; a file request would be forwarded the same
	 * way to a file server.  submit and collect touch only mapped
	 * memory; only the service is a trap.
	 */
	{
		enum { Ospreymagic = 0x4f53505259ULL, ReqRead = 0, ReplyDone = 1 };
		typedef struct {
			uvlong	magic, id, size, msgsize;
			uvlong	requestqueue, replyqueue, outputqueue;
			uvlong	request, reply, output;
			uvlong	data, datalen, sem, nsem, selected;
			uvlong	pktbuf, npktbuf, pktbufsize;
			uvlong	page, npage, maxpage, pagesize;
			uvlong	txbuf, ntxbuf, txbufsize;
		} Omap;
		typedef struct { vlong message; uvlong size, put, get; } Queue;
		typedef struct { uvlong op, sequence, container, arg[5]; } Msg;
		uchar *ring;
		Omap *map;
		Queue *rq, *pq;
		Msg *reqm, *repm, m, rep;
		uvlong seq;

		ring = (uchar*)segattach(0, "osprey0", 0, 0);
		if(ring == (uchar*)-1)
			puts("osprey user: could not map the message ring\n");
		else if((map = (Omap*)ring)->magic != Ospreymagic)
			puts("osprey user: what segattach mapped is not a container ring\n");
		else {
			puts("osprey user: mapped its container's message ring with segattach\n");
			rq = (Queue*)(ring + map->requestqueue);
			pq = (Queue*)(ring + map->replyqueue);
			reqm = (Msg*)((uchar*)rq + rq->message);
			repm = (Msg*)((uchar*)pq + pq->message);

			memset(&m, 0, sizeof m);
			m.op = ReqRead;			/* a file op, forwarded to the server */
			seq = rq->put + 1;
			m.sequence = seq;
			m.container = map->id;
			reqm[rq->put % rq->size] = m;
			rq->put++;			/* publish: submit, no trap */

			{
				int tries;
				for(tries = 0; tries < 400 && pq->put == pq->get; tries++)
					sleep(1);	/* service until the server's reply lands */
			}

			if(pq->put != pq->get){
				rep = repm[pq->get % pq->size];
				pq->get++;		/* collect, no trap */
				if(rep.sequence == seq && (long)rep.arg[0] > 0){
					char fb[32];
					long fn, k;

					fn = (long)rep.arg[0];		/* the server's byte count */
					if(fn > (long)sizeof fb - 1)
						fn = sizeof fb - 1;
					for(k = 0; k < fn; k++)		/* bytes packed from arg[2] */
						fb[k] = ((char*)&rep.arg[2])[k];
					puts("osprey user: the personality library fetched a file over the ring from the server: ");
					write(2, fb, fn);
					puts("\n");
				} else
					puts("osprey user: a reply came back but carried no file\n");
			} else
				puts("osprey user: no reply came back on the ring\n");
		}
	}
	exits(nil);
}
