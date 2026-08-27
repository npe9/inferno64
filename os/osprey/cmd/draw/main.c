/*
 * main.c - the front end of the user-level /dev/draw server.
 *
 * The kernel's draw device, devdraw.c, is reused whole; this hands the
 * 9p requests a client makes - attach, walk, open, read, write - to that
 * device's own Chan-based entry points (drawdevtab), and turns its
 * kernel-style error() unwinding back into a 9p Rerror.  The device draws
 * onto the frame buffer the microkernel exposes (see attachscreen in
 * kshim.c).  Mounted at /dev, it makes /dev/draw, which rio opens.
 */
#include "kshim.h"
#include <auth.h>
#include <fcall.h>
#include <9p.h>

void
usage(void)
{
	fprint(2, "usage: draw [-m mtpt]\n");
	exits("usage");
}

extern Dev drawdevtab;
#define D (&drawdevtab)

static void
fsattach(Req *r)
{
	Chan *c;

	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	c = D->attach(r->ifcall.aname);
	poperror();
	r->fid->aux = c;
	r->fid->qid = c->qid;
	r->ofcall.qid = c->qid;
	respond(r, nil);
}

static char*
fsclone(Fid *old, Fid *new)
{
	Chan *oc, *nc;

	oc = old->aux;
	if(oc == nil)
		return nil;
	nc = mallocz(sizeof(Chan), 1);
	if(nc == nil)
		return "out of memory";
	*nc = *oc;
	new->aux = nc;
	return nil;
}

static char*
fswalk1(Fid *fid, char *name, Qid *qid)
{
	Chan *c;
	Walkqid *wq;
	char *e;

	c = fid->aux;
	e = nil;
	if(waserror()){
		e = up->errstr;
		return e;
	}
	wq = D->walk(c, c, &name, 1);
	poperror();
	if(wq == nil || wq->nqid < 1){
		free(wq);
		return "no such file";
	}
	free(wq);
	*qid = c->qid;
	fid->qid = c->qid;
	return nil;
}

static void
fsopen(Req *r)
{
	Chan *c;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	D->open(c, r->ifcall.mode);
	poperror();
	r->fid->qid = c->qid;
	r->ofcall.qid = c->qid;
	respond(r, nil);
}

static void
fsread(Req *r)
{
	Chan *c;
	long n;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	n = D->read(c, r->ofcall.data, r->ifcall.count, r->ifcall.offset);
	poperror();
	r->ofcall.count = n;
	respond(r, nil);
}

static void
fswrite(Req *r)
{
	Chan *c;
	long n;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	n = D->write(c, r->ifcall.data, r->ifcall.count, r->ifcall.offset);
	poperror();
	r->ofcall.count = n;
	respond(r, nil);
}

static void
fsdestroyfid(Fid *fid)
{
	Chan *c;

	c = fid->aux;
	if(c == nil)
		return;
	fid->aux = nil;
	if(!waserror()){
		if(c->flag & COPEN)
			D->close(c);
		poperror();
	}
	free(c);
}

static Srv drawsrv = {
	.attach = fsattach,
	.clone = fsclone,
	.walk1 = fswalk1,
	.open = fsopen,
	.read = fsread,
	.write = fswrite,
	.destroyfid = fsdestroyfid,
};

void
main(int argc, char **argv)
{
	char *mtpt;

	mtpt = "/dev";
	ARGBEGIN{
	case 'm':
		mtpt = EARGF(usage());
	}ARGEND;
	USED(argc, argv);

	D->reset();
	D->init();
	postmountsrv(&drawsrv, nil, mtpt, MBEFORE);
	exits(nil);
}
