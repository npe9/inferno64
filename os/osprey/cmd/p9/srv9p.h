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

long	srv9p(Fidtab *ft, uchar *msg, long n, uchar *rbuf, long rmax);
