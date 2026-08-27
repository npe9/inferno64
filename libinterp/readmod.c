#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "kernel.h"
#include "dynld.h"
#undef DBG
#define DBG if(0) print

static int debug = 0;

Module*
readmod(char *path, Module *m, int sync)
{
	Dir *d;
	int fd, n, dynld;
	uchar *code;
	Module *ans;
	u32 length;

	if(path[0] == '$') {
		if(m == nil)
			kwerrstr("module not built-in");
		return m;
	}

	ans = nil;
	code = nil;
	length = 0;
	dynld = 0;

	/*
	 * Narrowing the landmark write further: readmod:before-parsemod
	 * (below) caught it, ruling parsemod() out entirely -- the write
	 * happens somewhere in this earlier stretch instead, which is
	 * exactly where release()/acquire() bracket real kernel syscalls
	 * (kopen/kdirfstat/kread/kclose).  pc64-only, temporary.  See
	 * doc/inferno-ports.ms.
	 */
	trackpoint = "readmod:before-release";
	checktracked();
	if(sync)
		release();
	trackpoint = "readmod:after-release";
	checktracked();

	d = nil;
	fd = kopen(path, OREAD);
	trackpoint = "readmod:after-kopen";
	checktracked();
	if(fd < 0){
		DBG("readmod path %s, fd < 0\n", path);
		goto done;
	}

	if((d = kdirfstat(fd)) == nil){
		DBG("readmod (d = kdirfstat(fd)) == nil for path %s\n", path);
		goto done;
	}
	trackpoint = "readmod:after-kdirfstat";
	checktracked();

	if(m != nil) {
		if(d->dev == m->dev && d->type == m->dtype &&
		   d->mtime == m->mtime &&
		   d->qid.type == m->qid.type && d->qid.path == m->qid.path && d->qid.vers == m->qid.vers) {
			DBG("readmod check failed for path %s\n", path);
			ans = m;
			goto done;
		}
	}

	if(d->length < 0 || d->length >= 8*1024*1024){
		kwerrstr("implausible length");
		goto done;
	}
	if((d->mode&0111) && dynldable(fd)){
		dynld = 1;
		goto done1;
	}
	length = d->length;
	code = mallocz(length, 0);
	if(code == nil)
		goto done;
	trackpoint = "readmod:after-mallocz";
	checktracked();

	n = kread(fd, code, length);
	trackpoint = "readmod:after-kread";
	checktracked();
	if(n != length) {
		DBG("readmod kread failed on path %s length %d, read n %d\n", path, length, n);
		/*
		 * Every other failure exit in this function sets an error
		 * string before falling through to done/done1 -- this one
		 * didn't, so a caller reading %r after a load that failed
		 * here (mntgen.b's badmodule() is exactly this pattern) saw
		 * an empty string instead of a reason.  A short, positive n
		 * is this function's own finding, with nothing upstream to
		 * have set a message for it, so it gets one here.  n<0 is a
		 * real kread error that should have left its own message in
		 * up->errstr via error() -- except boot logs against this
		 * exact call site have shown an empty %r on that path too
		 * (loading string.dis, not this one's styx.dis), so that
		 * assumption needs verifying, not trusting; not fixed here.
		 */
		if(n >= 0)
			kwerrstr("short read loading module: got %d of %d bytes", n, length);
		free(code);
		code = nil;
	}
done:
	if(fd >= 0)
		kclose(fd);
	trackpoint = "readmod:after-kclose";
	checktracked();
done1:
	if(sync)
		acquire();
	trackpoint = "readmod:after-acquire";
	checktracked();
	if(m != nil && ans == nil)
		unload(m);
	/*
	 * Narrowing the landmark write past "somewhere in readmod()":
	 * bracketing parsemod() specifically, the one call in this
	 * function that does any real interpretation of untrusted bytes.
	 * pc64-only, temporary.  See doc/inferno-ports.ms.
	 */
	trackpoint = "readmod:before-parsemod";
	checktracked();
	if(code != nil) {
		ans = parsemod(path, code, length, d);
		trackpoint = "readmod:after-parsemod";
		checktracked();
		free(code);
	}
	else if(dynld){
		kseek(fd, 0, 0);
		ans = newdyncode(fd, path, d);
		kclose(fd);
	}
	free(d);
	return ans;
}
