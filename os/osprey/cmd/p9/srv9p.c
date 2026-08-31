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

enum { Qroot = 0, Qhello = 1, Msize = 8192 };

#define HELLO "hello from the 9P server, a container across the ring\n"

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

static void
mkdir(Dir *d, int which)
{
	memset(d, 0, sizeof *d);
	setqid(&d->qid, which);
	d->name = which == Qroot ? "/" : "hello";
	d->uid = d->gid = d->muid = "none";
	d->mode = which == Qroot ? (DMDIR|0555) : 0444;
	d->length = which == Qroot ? 0 : (vlong)(sizeof(HELLO)-1);
	d->type = 'L';
	d->dev = 0;
}

long
srv9p(Fidtab *ft, uchar *msg, long n, uchar *rbuf, long rmax)
{
	Fcall t, r;
	Dir d;
	uchar statbuf[256];
	char *hello = HELLO;
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
			if(nf == Qroot && strcmp(t.wname[i], "hello") == 0)
				nf = Qhello;
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
		if(ft->f[f].qid == Qhello){
			long len = sizeof(HELLO)-1;
			long off = t.offset;
			if(off >= len) off = len;
			if(cnt > len - off) cnt = len - off;
			r.data = hello + off;
			r.count = cnt;
		} else {
			if(t.offset != 0){
				r.count = 0; r.data = (char*)statbuf;
			} else {
				mkdir(&d, Qhello);
				r.count = convD2M(&d, statbuf, sizeof statbuf);
				r.data = (char*)statbuf;
			}
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
