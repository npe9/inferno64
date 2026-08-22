/*
 * #O - the Osprey resource containers, per-core EDF run queues and
 * asynchronous request rings, as an Inferno device.
 *
 * doc/osprey-plan.ms asks for request and reply rings reachable from
 * user processes and for a portable request dispatcher.  Exposing them
 * through Chan operations rather than through new system calls keeps the
 * contract the same for a native kernel and for a hosted adapter, and
 * lets the rings be driven and inspected from the shell.
 *
 * The policy layer holds no locks of its own, so every entry point here
 * is serialised by one qlock.
 */
#include	"u.h"
#include	"lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	"osprey.h"

enum {
	Qdir,
	Qctl,
	Qstatus,
	Qreply,

	Statuslen	= 8*1024,	/* every core and container line */
};

static Dirtab ospreydir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"ctl",		{Qctl},			0,	0664,
	"status",	{Qstatus},		0,	0444,
	"reply",	{Qreply},		0,	0444,
};

enum {
	CMreset,
	CMcreate,
	CMattach,
	CMdetach,
	CMexit,
	CMbalance,
	CMlimit,
	CMschedule,
	CMcharge,
	CMsubmit,
	CMservice,
	CMbind,
	CMunbind,
};

static Cmdtab ospreycmd[] = {
	CMreset,	"reset",	1,
	CMcreate,	"create",	5,
	CMattach,	"attach",	3,
	CMdetach,	"detach",	2,
	CMexit,		"exit",		2,
	CMbalance,	"balance",	1,
	CMlimit,	"limit",	5,
	CMschedule,	"schedule",	2,
	CMcharge,	"charge",	3,
	CMsubmit,	"submit",	0,
	CMservice,	"service",	0,
	CMbind,		"bind",		4,
	CMunbind,	"unbind",	3,
};

static QLock ospreylock;

static uvlong ospreyhz;

static uvlong
ospreynow(void)
{
	return fastticks(&ospreyhz);
}

static Ospreyproc*
ospreyproc(char *s)
{
	Ospreyproc *p;

	p = ospreylookup(strtoull(s, nil, 0));
	if(p == nil)
		error(Enonexist);
	return p;
}

static Chan*
ospreyattachdev(char *spec)
{
	return devattach('O', spec);
}

static Walkqid*
ospreywalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, ospreydir, nelem(ospreydir), devgen);
}

static int
ospreystat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, ospreydir, nelem(ospreydir), devgen);
}

static Chan*
ospreyopen(Chan *c, int omode)
{
	return devopen(c, omode, ospreydir, nelem(ospreydir), devgen);
}

static void
ospreyclose(Chan*)
{
}

static long
ospreyread(Chan *c, void *a, long n, vlong offset)
{
	char *buf, *s, *e;
	uvlong op, now, arg[Ospreynarg];
	Ospreyproc *p;
	long status;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, ospreydir, nelem(ospreydir), devgen);

	case Qstatus:
		buf = smalloc(Statuslen);
		if(waserror()){
			free(buf);
			nexterror();
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		now = ospreynow();	/* sets ospreyhz; read it after */
		ospreystatus(buf, Statuslen, now, ospreyhz);
		qunlock(&ospreylock);
		poperror();
		n = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return n;

	case Qreply:
		/*
		 * One line per reply, drained from every container's reply
		 * ring.  Reading is destructive and a ring has no stable
		 * offset, so only a read at the start of the file takes
		 * anything: a reader that asks for more would otherwise
		 * drain replies that arrived meanwhile and discard them.
		 */
		if(offset != 0)
			return 0;
		buf = smalloc(Statuslen);
		if(waserror()){
			free(buf);
			nexterror();
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		s = buf;
		e = buf + Statuslen;
		for(p = ospreynext(nil); p != nil; p = ospreynext(p))
			while(s < e - 1 && ospreycollect(p, &op, &status, arg) == 0)
				s = seprint(s, e, "%llud %s %s %llud %llud %llud\n",
					ospreyid(p), ospreyopname(op),
					ospreystatusname(status),
					arg[0], arg[1], arg[2]);
		*s = '\0';
		qunlock(&ospreylock);
		poperror();
		n = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return n;

	default:
		error(Egreg);
	}
}

static long
ospreywrite(Chan *c, void *a, long n, vlong)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	Ospreyproc *p;
	uvlong arg[Ospreynarg];
	int i, op;

	if((ulong)c->qid.path != Qctl)
		error(Eperm);

	cb = parsecmd(a, n);
	qlock(&ospreylock);
	if(waserror()){
		qunlock(&ospreylock);
		free(cb);
		nexterror();
	}
	ct = lookupcmd(cb, ospreycmd, nelem(ospreycmd));
	switch(ct->index){
	case CMreset:
		ospreyreset();
		break;

	case CMcreate:
		if(ospreycreate(strtoull(cb->f[1], nil, 0),
			strtoull(cb->f[2], nil, 0),
			strtoull(cb->f[3], nil, 0),
			strtoull(cb->f[4], nil, 0)) == nil)
			error(Enodev);
		break;

	case CMattach:
		p = ospreyproc(cb->f[1]);
		if(ospreyattach(p, strtoul(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMdetach:
		if(ospreydetach(ospreyproc(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMexit:
		if(ospreyexit(ospreyproc(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMbalance:
		ospreybalance(ospreynow());
		break;

	case CMschedule:
		ospreyschedule(strtoul(cb->f[1], nil, 0), ospreynow());
		break;

	case CMcharge:
		if(ospreycharge(strtoul(cb->f[1], nil, 0),
			strtoull(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMlimit:
		p = ospreyproc(cb->f[1]);
		if(ospreylimit(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0),
			strtoul(cb->f[4], nil, 0)) < 0)
			error(Ebadarg);
		break;

	case CMsubmit:
		if(cb->nf < 3 || cb->nf > 3 + Ospreynarg)
			error(Ecmdargs);
		p = ospreyproc(cb->f[1]);
		if((op = ospreyop(cb->f[2])) < 0)
			error(Ebadarg);
		for(i = 0; i < Ospreynarg; i++)
			arg[i] = 3 + i < cb->nf ?
				strtoull(cb->f[3+i], nil, 0) : 0;
		if(ospreysubmit(p, op, arg) < 0)
			error(Eio);
		break;

	case CMservice:
		if(cb->nf > 2)
			error(Ecmdargs);
		i = cb->nf == 2 ? atoi(cb->f[1]) : 1;
		while(i-- > 0)
			if(ospreyservice(ospreynow()) <= 0)
				break;
		break;

	case CMbind:
		p = ospreyproc(cb->f[1]);
		if(ospreybind(p, cb->f[2], cb->f[3]) < 0)
			error(Ebadarg);
		break;

	case CMunbind:
		p = ospreyproc(cb->f[1]);
		if(ospreyunbind(p, cb->f[2]) < 0)
			error(Enonexist);
		break;
	}
	qunlock(&ospreylock);
	poperror();
	free(cb);
	return n;
}

Dev ospreydevtab = {
	'O',
	"osprey",

	devreset,
	devinit,
	devshutdown,
	ospreyattachdev,
	ospreywalk,
	ospreystat,
	ospreyopen,
	devcreate,
	ospreyclose,
	ospreyread,
	devbread,
	ospreywrite,
	devbwrite,
	devremove,
	devwstat,
};
