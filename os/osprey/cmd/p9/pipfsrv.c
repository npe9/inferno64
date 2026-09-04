#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * Pi-p spoken about this personality's files: the session protocol of
 * pip(5) - sessions that outlive their connection, grouped transactions,
 * named attributes, versions committed on close, leases - served here
 * over the name space, as p9srv.c serves 9P over it.  The kernel speaks
 * pi-p about containers (devosprey.c); this is the same protocol about
 * files, which is what the talk says every file is reached through.
 *
 * A fid names a file opened in this name space.  Its attributes are
 * "*" (that list), "data" (the bytes), "version", "length" and "name".
 * A write to "data" makes the version the fid is making, which nobody
 * else can see - a read through this fid gets it, a read through any
 * other gets what is committed - and closing the fid commits it as a
 * whole, by writing the file anew, which on the log-structured store is
 * exactly one new record; a fid whose file has been committed over since
 * it was opened is refused, and what it wrote is thrown away.  The root
 * fid's "*" is the root directory's names.  Leases are counted in the
 * server task's clock ticks, ten milliseconds each.  Streams need a
 * wire and tickets need a key; neither is here.
 */
enum {
	PipTsession = 100, PipRsession, PipTopen, PipRopen, PipTread, PipRread,
	PipTwrite, PipRwrite, PipTclose, PipRclose, PipTlease, PipRlease,
	PipRerror, PipTstream, PipRstream, PipTauth, PipRauth,

	Pipheader = 7,
	Nsess	= 4,
	Nfid	= 8,
	Namelen	= 128,
	Datalen	= 4096,
	Fidlease = 3000,		/* ms */
	Sesslease = 30000,
	Tickms	= 10,
};

typedef struct Fid Fid;
struct Fid {
	int	used;
	ulong	fid;
	char	name[Namelen];
	Chan	*c;			/* open for reading, or nil for the root */
	uvlong	base;			/* the version it began from */
	uchar	*draft;			/* the version it is making, or nil */
	long	draftlen;
	uvlong	lease;			/* good until this tick, in ms */
};
typedef struct Sess Sess;
struct Sess {
	int	used;
	uvlong	sid;
	uvlong	lease;
	Fid	fids[Nfid];
};

static Sess sess[Nsess];
static uvlong nextsid = 0x5ec0de;
static uvlong nowms;			/* ticks * Tickms */

/*
 * A stream: an attribute of a fid sent at a rate, unasked, on the wire
 * the group that set it up came over.  There is no wire under a group
 * that came over the ring (a reply is the answer to a request), so a
 * Tstream there is refused as it always was; a group served for the
 * wire (pipfs_servewire) may set one up, and the wire's own task emits
 * what is due (pipfs_stream).
 */
typedef struct Stream Stream;
struct Stream {
	int	used;
	Sess	*s;
	uvlong	sid;
	ulong	fid;
	int	tag;
	ulong	period;			/* ms */
	long	left;			/* frames still to send, or -1 for no end */
	uvlong	due;			/* ms */
	char	attr[Namelen];
};
enum { Nstream = 4 };
static Stream streams[Nstream];
static int onwire;			/* the group being served came over a wire */

/* the replies of the group being served */
static uchar *rbuf;
static long rmax, rn;
static int overflow;

void
pipfs_tick(void)
{
	nowms += Tickms;
}

static uvlong
pget(uchar *p, int n)
{
	uvlong v;
	int i;

	v = 0;
	for(i = n-1; i >= 0; i--)
		v = (v<<8) | p[i];
	return v;
}

static void
pput(uchar *p, int n, uvlong v)
{
	int i;

	for(i = 0; i < n; i++){
		p[i] = v;
		v >>= 8;
	}
}

static uchar*
reply(int type, int tag, long n)
{
	uchar *r;

	if(overflow || rn + Pipheader + n > rmax){
		overflow = 1;
		return nil;
	}
	r = rbuf + rn;
	pput(r, 4, Pipheader + n);
	r[4] = type;
	pput(r+5, 2, tag);
	rn += Pipheader + n;
	return r + Pipheader;
}

static void
rerror(int tag, char *e)
{
	uchar *r;
	long n;

	n = strlen(e);
	if((r = reply(PipRerror, tag, 2 + n)) == nil)
		return;
	pput(r, 2, n);
	memmove(r+2, e, n);
}

static void
fidfree(Fid *f)
{
	if(f->c != nil)
		cclose(f->c);
	if(f->draft != nil)
		free(f->draft);
	memset(f, 0, sizeof *f);
}

static void
expire(void)
{
	Sess *s;
	Fid *f;

	for(s = sess; s < &sess[Nsess]; s++){
		if(!s->used)
			continue;
		if(s->lease < nowms){
			for(f = s->fids; f < &s->fids[Nfid]; f++)
				if(f->used)
					fidfree(f);
			s->used = 0;
			continue;
		}
		for(f = s->fids; f < &s->fids[Nfid]; f++)
			if(f->used && f->lease < nowms)
				fidfree(f);
	}
}

static Sess*
sessfind(uvlong sid)
{
	Sess *s;

	for(s = sess; s < &sess[Nsess]; s++)
		if(s->used && s->sid == sid)
			return s;
	return nil;
}

static Fid*
fidfind(Sess *s, ulong fid)
{
	Fid *f;

	for(f = s->fids; f < &s->fids[Nfid]; f++)
		if(f->used && f->fid == fid)
			return f;
	return nil;
}

/* the file's committed version now: its qid's version, read afresh */
static uvlong
fileversion(char *name)
{
	Chan *c;
	uvlong v;

	c = namec(name, Aaccess, 0, 0);
	v = c->qid.vers;
	cclose(c);
	return v;
}

/* commit the draft: the file written anew, one new version */
static uvlong
commit(Fid *f)
{
	Chan *c;

	if(fileversion(f->name) != f->base)
		error("what it was written against has changed");
	c = namec(f->name, Aopen, OWRITE|OTRUNC, 0);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	devtab[c->type]->write(c, f->draft, f->draftlen, 0);
	poperror();
	cclose(c);			/* the store commits on close */
	return fileversion(f->name);
}

/*
 * An attribute of a fid, answered as an Rread carrying the given tag:
 * for a Tread, and for a stream, which is an Rread that arrives with the
 * Tstream's tag and nobody asked for.
 */
static void
readattr(Fid *f, char *attr, long cnt, int tag)
{
	uchar *r;
	uvlong v;
	long k;

	{
		uchar *b;
		long n;

		b = smalloc(Datalen);
		if(waserror()){
			free(b);
			rerror(tag, up->errstr);
			return;
		}
		if(f->c == nil){
			/* the root: its names, from a directory read */
			Chan *dc;
			uchar dbuf[2048], *p, *e;
			Dir d;
			char names[256];
			int mm;

			if(strcmp(attr, "*") != 0)
				error("no such attribute");
			dc = namec("/", Aopen, OREAD, 0);
			n = devtab[dc->type]->read(dc, dbuf, sizeof dbuf, 0);
			cclose(dc);
			k = 0;
			for(p = dbuf, e = dbuf + n; p < e; p += mm){
				mm = convM2D(p, (uint)(e - p), &d, names);
				if(mm <= 0)
					break;
				k += snprint((char*)b+k, Datalen-k, k == 0 ? "%s" : " %s", d.name);
			}
			n = k;
			v = 0;
		} else if(strcmp(attr, "*") == 0){
			n = snprint((char*)b, Datalen, "* data version length name latest");
			v = f->draft != nil ? f->base + 1 : f->base;
		} else if(strcmp(attr, "data") == 0){
			if(f->draft != nil){
				n = f->draftlen;
				memmove(b, f->draft, n);
				v = f->base + 1;
			} else {
				n = devtab[f->c->type]->read(f->c, b, Datalen, 0);
				v = f->base;
			}
		} else if(strcmp(attr, "version") == 0){
			v = f->draft != nil ? f->base + 1 : f->base;
			n = snprint((char*)b, Datalen, "%llud", v);
		} else if(strcmp(attr, "length") == 0){
			if(f->draft != nil)
				n = snprint((char*)b, Datalen, "%ld", f->draftlen);
			else {
				uchar *t = smalloc(Datalen);
				long tn = devtab[f->c->type]->read(f->c, t, Datalen, 0);
				free(t);
				n = snprint((char*)b, Datalen, "%ld", tn);
			}
			v = f->draft != nil ? f->base + 1 : f->base;
		} else if(strcmp(attr, "name") == 0){
			n = snprint((char*)b, Datalen, "%s", f->name);
			v = f->base;
		} else if(strcmp(attr, "latest") == 0){
			/* the file's committed version now, not this fid's: what a
			 * replica watches, since a fid's version is fixed at its open */
			v = fileversion(f->name);
			n = snprint((char*)b, Datalen, "%llud", v);
		} else
			error("no such attribute");
		if(cnt >= 0 && n > cnt)
			n = cnt;
		if((r = reply(PipRread, tag, 8+2+n)) != nil){
			pput(r, 8, v);
			pput(r+8, 2, n);
			memmove(r+10, b, n);
		}
		poperror();
		free(b);
	}
}

static void
serve1(Sess **sp, uchar *m, long sz)
{
	Sess *s;
	Fid *f;
	uchar *r;
	char name[Namelen], attr[Namelen], val[Namelen];
	uvlong sid, v;
	long k, alen, cnt, dlen;
	ulong fid, nfid;
	int type, tag, how;

	type = m[4];
	tag = pget(m+5, 2);
	s = *sp;
	if(type == PipTsession){
		sid = sz >= Pipheader + 8 ? pget(m+Pipheader, 8) : 0;
		expire();
		if(sid != 0){
			if((s = sessfind(sid)) == nil){
				rerror(tag, "no such session");
				return;
			}
		} else {
			for(s = sess; s < &sess[Nsess] && s->used; s++)
				;
			if(s == &sess[Nsess]){
				rerror(tag, "no free sessions");
				return;
			}
			memset(s, 0, sizeof *s);
			s->used = 1;
			s->sid = ++nextsid;
		}
		s->lease = nowms + Sesslease;
		*sp = s;
		if((r = reply(PipRsession, tag, 8)) != nil)
			pput(r, 8, s->sid);
		return;
	}
	if(s == nil){
		rerror(tag, "no session");
		return;
	}
	switch(type){
	case PipTopen:
		if(sz < Pipheader + 4+4+1+2)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		nfid = pget(m+Pipheader+4, 4);
		how = m[Pipheader+8];
		k = Pipheader + 9;
		alen = pget(m+k, 2);
		k += 2;
		if(k + alen > sz || alen >= Namelen)
			goto Bad;
		memmove(name, m+k, alen);
		name[alen] = 0;
		USED(fid);
		if(fidfind(s, nfid) != nil){
			rerror(tag, "fid in use");
			break;
		}
		for(f = s->fids; f < &s->fids[Nfid] && f->used; f++)
			;
		if(f == &s->fids[Nfid]){
			rerror(tag, "no free fids");
			break;
		}
		memset(f, 0, sizeof *f);
		if(alen == 0 || strcmp(name, "/") == 0){
			strcpy(f->name, "/");
			f->c = nil;
			f->base = 0;
		} else {
			if(waserror()){
				rerror(tag, up->errstr);
				break;
			}
			f->c = namec(name, Aopen, OREAD, 0);
			poperror();
			strcpy(f->name, name);
			f->base = f->c->qid.vers;
		}
		f->used = 1;
		f->fid = nfid;
		f->lease = nowms + Fidlease;
		USED(how);
		if((r = reply(PipRopen, tag, 24)) != nil){
			pput(r, 8, f->c == nil ? 0 : f->c->qid.path);
			pput(r+8, 8, f->base);
			pput(r+16, 8, Fidlease);
		}
		break;

	case PipTread:
		if(sz < Pipheader + 4+4+2)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		cnt = pget(m+Pipheader+4, 4);
		k = Pipheader + 8;
		alen = pget(m+k, 2);
		k += 2;
		if(k + alen > sz || alen >= Namelen)
			goto Bad;
		memmove(attr, m+k, alen);
		attr[alen] = 0;
		if((f = fidfind(s, fid)) == nil){
			rerror(tag, "fid not open");
			break;
		}
		readattr(f, attr, cnt, tag);
		f->lease = nowms + Fidlease;
		break;

	case PipTwrite:
		if(sz < Pipheader + 4+2)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		k = Pipheader + 4;
		alen = pget(m+k, 2);
		k += 2;
		if(k + alen > sz || alen >= Namelen)
			goto Bad;
		memmove(attr, m+k, alen);
		attr[alen] = 0;
		k += alen;
		if(k + 2 > sz)
			goto Bad;
		dlen = pget(m+k, 2);
		k += 2;
		if(k + dlen > sz || dlen > Datalen)
			goto Bad;
		if((f = fidfind(s, fid)) == nil || f->c == nil){
			rerror(tag, "fid not open");
			break;
		}
		if(strcmp(attr, "data") != 0){
			rerror(tag, "attribute is not writable");
			break;
		}
		if(f->draft == nil)
			f->draft = smalloc(Datalen);
		memmove(f->draft, m+k, dlen);
		f->draftlen = dlen;
		f->lease = nowms + Fidlease;
		if((r = reply(PipRwrite, tag, 8)) != nil)
			pput(r, 8, f->base + 1);
		break;

	case PipTclose:
		if(sz < Pipheader + 4)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		if((f = fidfind(s, fid)) == nil){
			rerror(tag, "no such fid");
			break;
		}
		v = 0;
		if(f->draft != nil){
			if(waserror()){
				fidfree(f);
				rerror(tag, up->errstr);
				break;
			}
			v = commit(f);
			poperror();
		}
		fidfree(f);
		if((r = reply(PipRclose, tag, 8)) != nil)
			pput(r, 8, v);
		break;

	case PipTlease:
		if(sz < Pipheader + 4)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		if((f = fidfind(s, fid)) == nil){
			rerror(tag, "no such fid");
			break;
		}
		f->lease = nowms + Fidlease;
		s->lease = nowms + Sesslease;
		if((r = reply(PipRlease, tag, 8)) != nil)
			pput(r, 8, Fidlease);
		break;

	case PipTstream:
		if(sz < Pipheader + 4+4+4+2)
			goto Bad;
		fid = pget(m+Pipheader, 4);
		{
			ulong period, count;
			Stream *st, *slot;

			period = pget(m+Pipheader+4, 4);
			count = pget(m+Pipheader+8, 4);
			k = Pipheader + 12;
			alen = pget(m+k, 2);
			k += 2;
			if(k + alen > sz || alen >= Namelen)
				goto Bad;
			memmove(attr, m+k, alen);
			attr[alen] = 0;
			if((f = fidfind(s, fid)) == nil){
				rerror(tag, "fid not open");
				break;
			}
			/* one stream to a fid: a second says what the first said */
			slot = nil;
			for(st = streams; st < &streams[Nstream]; st++)
				if(st->used && st->s == s && st->sid == s->sid && st->fid == fid)
					slot = st;
			if(period == 0){
				if(slot != nil)
					slot->used = 0;
				if((r = reply(PipRstream, tag, 8)) != nil)
					pput(r, 8, 0);
				break;
			}
			if(!onwire){
				rerror(tag, "no wire to stream on");
				break;
			}
			if(slot == nil)
				for(st = streams; st < &streams[Nstream]; st++)
					if(!st->used){
						slot = st;
						break;
					}
			if(slot == nil){
				rerror(tag, "no room for another stream");
				break;
			}
			memset(slot, 0, sizeof *slot);
			slot->used = 1;
			slot->s = s;
			slot->sid = s->sid;
			slot->fid = fid;
			slot->tag = tag;
			slot->period = period;
			slot->left = count == 0 ? -1 : (long)count;
			slot->due = nowms + period;
			strncpy(slot->attr, attr, Namelen-1);
			if((r = reply(PipRstream, tag, 8)) != nil)
				pput(r, 8, period);
		}
		break;
	case PipTauth:
		rerror(tag, "no key here to check a ticket against");
		break;
	default:
	Bad:
		rerror(tag, "bad message");
		break;
	}
	USED(val);
}

/*
 * A group: the messages in msg, one after another, answered in order
 * into rbuf.  A session is settled by the group's Tsession and lasts
 * for the group; a group without one is answered "no session".
 */
long
pipfs_serve(uchar *msg, long n, uchar *out, long outmax)
{
	Sess *s;
	long off, sz;

	rbuf = out;
	rmax = outmax;
	rn = 0;
	overflow = 0;
	s = nil;
	for(off = 0; off + Pipheader <= n; off += sz){
		sz = pget(msg+off, 4);
		if(sz < Pipheader || off + sz > n)
			break;
		serve1(&s, msg+off, sz);
	}
	if(overflow){
		rn = 0;
		overflow = 0;
		rerror(0, "the replies to that group do not fit");
	}
	return rn;
}

/*
 * The same group, come over a wire: what differs is that a Tstream in it
 * may be answered, since the wire's task will carry the frames.
 */
long
pipfs_servewire(uchar *msg, long n, uchar *out, long outmax)
{
	long k;

	onwire = 1;
	k = pipfs_serve(msg, n, out, outmax);
	onwire = 0;
	return k;
}

/*
 * What the streams owe now: for every stream whose period has come
 * round, an Rread of its attribute with the Tstream's tag, into out;
 * the count of bytes put there, 0 when nothing is due.  Called by the
 * wire's task at its own rate; the frames leave at the stream's.  A
 * stream ends when its count runs out, or when its session or its fid
 * has gone - a fid's lease running out stops it, as pip(5) says, since
 * the stream does not refresh the lease the way a Tread does.
 */
long
pipfs_stream(uchar *out, long outmax)
{
	Stream *st;
	Fid *f;

	rbuf = out;
	rmax = outmax;
	rn = 0;
	overflow = 0;
	for(st = streams; st < &streams[Nstream]; st++){
		if(!st->used || st->due > nowms)
			continue;
		if(!st->s->used || st->s->sid != st->sid || (f = fidfind(st->s, st->fid)) == nil){
			st->used = 0;
			continue;
		}
		readattr(f, st->attr, -1, st->tag);
		st->due += st->period;
		if(st->left > 0 && --st->left == 0)
			st->used = 0;
	}
	if(overflow){
		rn = 0;
		overflow = 0;
	}
	return rn;
}

/*
 * Builders for a client, so that a group is put together in a few
 * lines, and a walker for its replies.  Each builder appends a message
 * at buf and returns its size.
 */
static long
tmsg(uchar *b, int type, int tag, long n)
{
	pput(b, 4, Pipheader + n);
	b[4] = type;
	pput(b+5, 2, tag);
	return Pipheader + n;
}

static long
pstr(uchar *b, char *s, long n)
{
	pput(b, 2, n);
	memmove(b+2, s, n);
	return 2 + n;
}

long
pip_tsession(uchar *b, int tag, uvlong sid)
{
	pput(b+Pipheader, 8, sid);
	return tmsg(b, PipTsession, tag, 8);
}

long
pip_topen(uchar *b, int tag, ulong fid, ulong nfid, int how, char *name)
{
	long n = strlen(name);

	pput(b+Pipheader, 4, fid);
	pput(b+Pipheader+4, 4, nfid);
	b[Pipheader+8] = how;
	pstr(b+Pipheader+9, name, n);
	return tmsg(b, PipTopen, tag, 9 + 2 + n);
}

long
pip_tread(uchar *b, int tag, ulong fid, long count, char *attr)
{
	long n = strlen(attr);

	pput(b+Pipheader, 4, fid);
	pput(b+Pipheader+4, 4, count);
	pstr(b+Pipheader+8, attr, n);
	return tmsg(b, PipTread, tag, 8 + 2 + n);
}

long
pip_twrite(uchar *b, int tag, ulong fid, char *attr, char *data, long dlen)
{
	long n = strlen(attr);

	pput(b+Pipheader, 4, fid);
	pstr(b+Pipheader+4, attr, n);
	pstr(b+Pipheader+4+2+n, data, dlen);
	return tmsg(b, PipTwrite, tag, 4 + 2 + n + 2 + dlen);
}

long
pip_tstream(uchar *b, int tag, ulong fid, ulong period, ulong count, char *attr)
{
	long n;

	n = tmsg(b, PipTstream, tag, 4+4+4+2+strlen(attr));
	pput(b+Pipheader, 4, fid);
	pput(b+Pipheader+4, 4, period);
	pput(b+Pipheader+8, 4, count);
	pstr(b+Pipheader+12, attr, strlen(attr));
	return n;
}

long
pip_tclose(uchar *b, int tag, ulong fid)
{
	pput(b+Pipheader, 4, fid);
	return tmsg(b, PipTclose, tag, 4);
}

/* the next reply in r[0..n): its type, tag, body and body length; 0 when there are no more */
int
pip_next(uchar *r, long n, long *off, int *type, int *tag, uchar **body, long *blen)
{
	long sz;

	if(*off + Pipheader > n)
		return 0;
	sz = pget(r + *off, 4);
	if(sz < Pipheader || *off + sz > n)
		return 0;
	*type = r[*off + 4];
	*tag = pget(r + *off + 5, 2);
	*body = r + *off + Pipheader;
	*blen = sz - Pipheader;
	*off += sz;
	return 1;
}

uvlong
pip_num(uchar *p, int n)
{
	return pget(p, n);
}
