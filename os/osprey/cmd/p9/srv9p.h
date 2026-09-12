/*
 * The 9P server, split so its state lives in the caller's frame: the
 * server container is flat-loaded (text only, no data segment), so the
 * fid table cannot be a static - it is a Fidtab the caller keeps on its
 * stack and hands to each call.  srv9p takes a marshalled T-message and
 * writes the marshalled R-message, returning its length.
 */
enum { Srv9pNfid = 64 };
typedef struct Fid9p Fid9p;
struct Fid9p { ulong fid; int qid; int used; };
typedef struct Fidtab Fidtab;
struct Fidtab { Fid9p f[Srv9pNfid]; };

/*
 * All the server's mutable state, kept in the caller's frame because the
 * container is flat-loaded: the fid table, and the one writable file's
 * contents and length.
 */
/*
 * The one writable file's size.  This was 512 - smaller than the ring
 * carries in one message - so no read or write of it ever needed more
 * than one exchange, and the transport's behaviour on a file larger than
 * a message was untested.  4096 is several messages' worth.  Srvstate
 * lives in the server container's stack frame, because that container is
 * flat-loaded and has no data segment, so this is stack: that stack is
 * the ordinary USTKSIZE segment, 16 MiB and demand-paged
 * (ospreyloadprog), and ten kilobytes of frame is nothing against it.
 */
enum { Srv9pScratch = 4096 };
typedef struct Srvstate Srvstate;
struct Srvstate {
	Fidtab	fids;
	char	scratch[Srv9pScratch];
	long	scratchlen;
};

long	srv9p(Srvstate *st, uchar *msg, long n, uchar *rbuf, long rmax);
