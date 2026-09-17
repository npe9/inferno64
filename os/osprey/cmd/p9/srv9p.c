/*
 * The 9P server, compiled against the user headers so it can live in the
 * file-server container across the microkernel ring.  It is pure and
 * keeps no static state (the container is flat-loaded, no data segment):
 * the fid table is the caller's, and the file's contents are a string
 * literal, which lives in the text the loader does map.  It takes a
 * marshalled T-message and returns a marshalled R-message, so the same
 * logic serves whether called in one address space or reached over the
 * ring.  The served tree is the root directory and one file, "hello".
 */
#include <u.h>
#include <libc.h>
#include <fcall.h>
#include "srv9p.h"

enum { Qroot = 0, Msize = 8192 };

/*
 * The served tree: a root directory, a handful of files, and a directory
 * with a file in it.  Each entry is a name, a string literal (which
 * lives in the text the flat loader maps) and the qid path of the
 * directory holding it; a file's own qid path is its index+1, and Qroot
 * is 0.
 *
 * The subdirectory is not decoration.  Until it was here every name this
 * server held was one walk from the root, so a Twalk of more than one
 * name had never crossed the ring, and neither had a directory read of
 * anything but the root.  Both are ordinary 9P and neither was tested.
 */
static char *filename[] = {
	"hello",
	"motd",
	"readme",
	"scratch",		/* the one writable file; its bytes live in Srvstate */
	"sub",			/* a directory */
	"deep",			/* in it */
};
static char *filedata[] = {
	"hello from the 9P server, a container across the ring\n",
	"the microkernel routes 9P; the file server is a container of its own\n",
	"three files, listed by a program over a file descriptor\n",
	"",			/* scratch starts empty */
	nil,			/* a directory has no bytes */
	"one level down, reached by a walk of two names over the ring\n",
};
/* the qid path of the directory each is in: 0 is the root */
static int fileparent[] = { 0, 0, 0, 0, 0, 5 };
enum { Nfile = 6, Qscratch = 4, Qsub = 5 };

/* is this qid path a directory? */
static int
isdir(int which)
{
	return which == Qroot || (which > 0 && which <= Nfile && filedata[which-1] == nil);
}

static int
findfid(Fidtab *ft, ulong fid)
{
	int i;
	for(i = 0; i < Srv9pNfid; i++)
		if(ft->f[i].used && ft->f[i].fid == fid)
			return i;
	return -1;
}

static int
getfid(Fidtab *ft, ulong fid)
{
	int i;
	i = findfid(ft, fid);
	if(i >= 0)
		return i;
	for(i = 0; i < Srv9pNfid; i++)
		if(!ft->f[i].used){
			ft->f[i].used = 1;
			ft->f[i].fid = fid;
			ft->f[i].qid = Qroot;
			return i;
		}
	return -1;
}

static void
setqid(Qid *q, int which)
{
	q->path = which;
	q->vers = 0;
	q->type = isdir(which) ? QTDIR : QTFILE;
}

/* the qid path of a name in the directory whose path is `in`, or -1 */
static int
lookup(int in, char *name)
{
	int i;
	for(i = 0; i < Nfile; i++)
		if(fileparent[i] == in && strcmp(name, filename[i]) == 0)
			return i+1;		/* qid path = index+1 */
	return -1;
}

static void
mkdir(Dir *d, int which)
{
	memset(d, 0, sizeof *d);
	setqid(&d->qid, which);
	if(which == Qroot){
		d->name = "/";
		d->mode = DMDIR|0555;
		d->length = 0;
	} else {
		d->name = filename[which-1];
		if(isdir(which)){
			d->mode = DMDIR|0555;
			d->length = 0;
		} else {
			d->mode = which == Qscratch ? 0666 : 0444;
			d->length = which == Qscratch ? 0 : (vlong)strlen(filedata[which-1]);
		}
	}
	d->uid = d->gid = d->muid = "none";
	d->type = 'L';
	d->dev = 0;
}

long
srv9p(Srvstate *st, uchar *msg, long n, uchar *rbuf, long rmax)
{
	Fcall t, r;
	Dir d;
	uchar statbuf[256];
	uchar dirbuf[512];
	int i, f, nf;
	long cnt;

	if(convM2S(msg, n, &t) == 0)
		return 0;
	r.tag = t.tag;
	r.type = t.type + 1;

	switch(t.type){
	default:
		r.type = Rerror; r.ename = "not supported"; break;

	case Twrite:
		f = findfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		if(st->fids.f[f].qid != Qscratch){ r.type = Rerror; r.ename = "read-only file"; break; }
		{
			long off = t.offset, k;
			long c = t.count;
			if(off < 0) off = 0;
			if(off + c > Srv9pScratch) c = Srv9pScratch - off;
			if(c < 0) c = 0;
			for(k = 0; k < c; k++)
				st->scratch[off+k] = t.data[k];
			if(off + c > st->scratchlen) st->scratchlen = off + c;
			r.count = c;
		}
		break;

	case Tversion:
		/*
		 * Advertise what can actually be returned.  The reply is
		 * marshalled into rbuf, which is rmax bytes of the client's
		 * data area, so a message size larger than that is a promise
		 * this server cannot keep: the client would ask for a read
		 * that fits its msize and the answer would run off the end of
		 * the region.  Msize is the ceiling this server would like;
		 * rmax is the one it has.  IOHDRSZ is 9P's own allowance for
		 * the header of a read or write, so the data a client may ask
		 * for is msize less that.
		 */
		r.msize = t.msize < Msize ? t.msize : Msize;
		if(rmax > 0 && r.msize > (ulong)rmax)
			r.msize = (ulong)rmax;
		r.version = "9P2000";
		break;

	case Tauth:
		r.type = Rerror; r.ename = "no authentication required"; break;

	case Tattach:
		f = getfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "no fids"; break; }
		st->fids.f[f].qid = Qroot;
		setqid(&r.qid, Qroot);
		break;

	case Twalk:
		f = findfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		r.nwqid = 0;
		nf = st->fids.f[f].qid;
		for(i = 0; i < t.nwname; i++){
			int q;
			if(!isdir(nf))
				break;			/* only a directory has names under it */
			if(strcmp(t.wname[i], "..") == 0)
				nf = nf == Qroot ? Qroot : fileparent[nf-1];
			else if((q = lookup(nf, t.wname[i])) > 0)
				nf = q;
			else
				break;
			setqid(&r.wqid[i], nf);
			r.nwqid++;
		}
		if(t.nwname != 0 && r.nwqid == 0){
			r.type = Rerror; r.ename = "file does not exist"; break;
		}
		if(r.nwqid == t.nwname){
			int g = getfid(&st->fids, t.newfid);
			if(g < 0){ r.type = Rerror; r.ename = "no fids"; break; }
			st->fids.f[g].qid = nf;
		}
		break;

	case Topen:
		f = findfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		setqid(&r.qid, st->fids.f[f].qid);
		r.iounit = 0;
		break;

	case Tread:
		f = findfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		cnt = t.count;
		/*
		 * And clamp here too, because a client that never sent a
		 * Tversion, or one that asks for more than it agreed, must
		 * still get an answer that fits the region rather than one
		 * that overruns it.  The clamp is the region less the
		 * R-message's own header (9 bytes: size, type, tag, count),
		 * with a little room rather than exactly that.
		 */
		if(rmax > IOHDRSZ && cnt > (long)(rmax - IOHDRSZ))
			cnt = rmax - IOHDRSZ;
		if(!isdir(st->fids.f[f].qid)){
			int q = st->fids.f[f].qid;
			char *content; long len, off = t.offset;
			if(q == Qscratch){ content = st->scratch; len = st->scratchlen; }
			else { content = filedata[q-1]; len = strlen(content); }
			if(off >= len) off = len;
			if(cnt > len - off) cnt = len - off;
			r.data = content + off;
			r.count = cnt;
		} else {
			/*
			 * A directory: marshal every entry, then return whole
			 * entries only.  This used to return the byte slice at
			 * the offset, which is wrong and only looked right
			 * because every reader here asked for more bytes than
			 * the whole directory: a smaller count cut the last
			 * entry in half, devmnt raised "invalid directory
			 * entry received from server" when the entries did not
			 * add up to the count, and unionread - which runs each
			 * member under waserror and moves on - dropped this
			 * whole member from the listing without a word.  9P
			 * has directory offsets land on entry boundaries, so
			 * an offset that does not is the error it is, and a
			 * count too small for one entry returns nothing, which
			 * is what the kernel's own devdirread does.
			 */
			long total = 0, off = t.offset, at, end, dl;
			int k, in = st->fids.f[f].qid;
			for(k = 0; k < Nfile; k++){
				if(fileparent[k] != in)
					continue;	/* in another directory */
				mkdir(&d, k+1);
				total += convD2M(&d, dirbuf + total, sizeof dirbuf - total);
			}
			at = 0;
			while(at < off && at < total)
				at += BIT16SZ + GBIT16(dirbuf + at);
			if(at != off){
				r.type = Rerror; r.ename = "bad offset in directory read"; break;
			}
			end = off;
			while(end < total){
				dl = BIT16SZ + GBIT16(dirbuf + end);
				if(end + dl > off + (long)cnt)
					break;
				end += dl;
			}
			r.data = (char*)(dirbuf + off);
			r.count = end - off;
		}
		break;

	case Tclunk:
		f = findfid(&st->fids, t.fid);
		if(f >= 0) st->fids.f[f].used = 0;
		break;

	case Tstat:
		f = findfid(&st->fids, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		mkdir(&d, st->fids.f[f].qid);
		r.nstat = convD2M(&d, statbuf, sizeof statbuf);
		r.stat = statbuf;
		break;
	}
	return convS2M(&r, rbuf, rmax);
}
