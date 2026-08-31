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
 * The served tree: a root directory and a handful of files, each a name
 * and a string literal (which lives in the text the flat loader maps).
 * A file's qid path is its index+1 into this table; Qroot is 0.
 */
static char *filename[] = {
	"hello",
	"motd",
	"readme",
};
static char *filedata[] = {
	"hello from the 9P server, a container across the ring\n",
	"the microkernel routes 9P; the file server is a container of its own\n",
	"three files, listed by a program over a file descriptor\n",
};
enum { Nfile = 3 };

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
	q->type = which == Qroot ? QTDIR : QTFILE;
}

/* index of a name in the root directory, or -1 */
static int
lookup(char *name)
{
	int i;
	for(i = 0; i < Nfile; i++)
		if(strcmp(name, filename[i]) == 0)
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
		d->mode = 0444;
		d->length = (vlong)strlen(filedata[which-1]);
	}
	d->uid = d->gid = d->muid = "none";
	d->type = 'L';
	d->dev = 0;
}

long
srv9p(Fidtab *ft, uchar *msg, long n, uchar *rbuf, long rmax)
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

	case Tversion:
		r.msize = t.msize < Msize ? t.msize : Msize;
		r.version = "9P2000";
		break;

	case Tauth:
		r.type = Rerror; r.ename = "no authentication required"; break;

	case Tattach:
		f = getfid(ft, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "no fids"; break; }
		ft->f[f].qid = Qroot;
		setqid(&r.qid, Qroot);
		break;

	case Twalk:
		f = findfid(ft, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		r.nwqid = 0;
		nf = ft->f[f].qid;
		for(i = 0; i < t.nwname; i++){
			int q;
			if(nf == Qroot && (q = lookup(t.wname[i])) > 0)
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
			int g = getfid(ft, t.newfid);
			if(g < 0){ r.type = Rerror; r.ename = "no fids"; break; }
			ft->f[g].qid = nf;
		}
		break;

	case Topen:
		f = findfid(ft, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		setqid(&r.qid, ft->f[f].qid);
		r.iounit = 0;
		break;

	case Tread:
		f = findfid(ft, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		cnt = t.count;
		if(ft->f[f].qid != Qroot){
			char *content = filedata[ft->f[f].qid - 1];
			long len = strlen(content);
			long off = t.offset;
			if(off >= len) off = len;
			if(cnt > len - off) cnt = len - off;
			r.data = content + off;
			r.count = cnt;
		} else {
			/* directory: marshal every entry, return the slice at offset */
			long total = 0, off = t.offset;
			int k;
			for(k = 0; k < Nfile; k++){
				mkdir(&d, k+1);
				total += convD2M(&d, dirbuf + total, sizeof dirbuf - total);
			}
			if(off > total) off = total;
			if(cnt > total - off) cnt = total - off;
			r.data = (char*)(dirbuf + off);
			r.count = cnt;
		}
		break;

	case Tclunk:
		f = findfid(ft, t.fid);
		if(f >= 0) ft->f[f].used = 0;
		break;

	case Tstat:
		f = findfid(ft, t.fid);
		if(f < 0){ r.type = Rerror; r.ename = "unknown fid"; break; }
		mkdir(&d, ft->f[f].qid);
		r.nstat = convD2M(&d, statbuf, sizeof statbuf);
		r.stat = statbuf;
		break;
	}
	return convS2M(&r, rbuf, rmax);
}
