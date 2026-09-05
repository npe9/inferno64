/*
 * dirread and dirreadall: a directory, as an array of Dir.
 *
 * include/kern.h has declared both for as long as the header has
 * existed and nothing in this tree defined either, the same way
 * _runebsearch was declared and never defined: nothing here had ever
 * read a directory through the Plan 9 interface from a host program.
 * 9front's libdisk does, in the proto reader that says what goes into
 * a kernel's boot file system, and that is built for the build
 * machine.
 *
 * On Plan 9 the two differ in how much they return: dirread reads
 * what one read of the directory gives and leaves the rest, and
 * dirreadall keeps going to the end.  Here there is one function.
 * The POSIX directory reader has no notion of a partial read to stop
 * at, so a single call returns the whole directory and the caller's
 * descriptor is left at the end of it -- which is a truthful dirread
 * (it is entitled to return as many entries as it likes) and is
 * exactly dirreadall.  The loop every caller writes,
 *
 *	while((n = dirread(fd, &d)) > 0)
 *
 * takes one turn instead of several and then sees the 0 that ends
 * it, because the second call finds the descriptor already at the
 * end.
 */
/*
 * fcntl first, and Darwin's own namespace asked for by name: lib9.h
 * asks for a POSIX-only one, under which fdopendir and
 * AT_SYMLINK_NOFOLLOW are not declared.
 */
#define _DARWIN_C_SOURCE 1
#include <fcntl.h>
#include <dirent.h>

#include "lib9.h"
#include <sys/types.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>

static char nullstring[] = "";

typedef struct Ent Ent;
struct Ent {
	struct stat	st;
	char		*name;
};

/*
 * Room for one entry: the Dir itself, its name, and the user and
 * group names, which are looked up rather than left as numbers
 * because a proto file names them that way.
 */
static int
entrysize(struct stat *s, char *name)
{
	struct passwd *p;
	struct group *g;
	int n;

	n = sizeof(Dir) + strlen(name)+1;
	if((p = getpwuid(s->st_uid)) != nil)
		n += strlen(p->pw_name)+1;
	if((g = getgrgid(s->st_gid)) != nil)
		n += strlen(g->gr_name)+1;
	return n;
}

static char*
putstring(char **sp, char *v)
{
	char *r;

	r = *sp;
	strcpy(r, v);
	*sp = r + strlen(v)+1;
	return r;
}

static void
fill(Dir *d, struct stat *s, char *name, char **sp)
{
	struct passwd *p;
	struct group *g;

	d->name = putstring(sp, name);
	d->uid = d->gid = d->muid = nullstring;
	if((p = getpwuid(s->st_uid)) != nil)
		d->uid = putstring(sp, p->pw_name);
	if((g = getgrgid(s->st_gid)) != nil)
		d->gid = putstring(sp, g->gr_name);
	d->qid.type = S_ISDIR(s->st_mode)? QTDIR: QTFILE;
	d->qid.path = s->st_ino;
	d->qid.vers = s->st_mtime;
	d->mode = ((ulong)d->qid.type<<24) | (s->st_mode & 0777);
	if(S_ISDIR(s->st_mode))
		d->mode |= DMDIR;
	d->atime = s->st_atime;
	d->mtime = s->st_mtime;
	d->length = s->st_size;
	d->dev = s->st_dev;
	d->type = S_ISFIFO(s->st_mode)? '|': 'M';
}

long
dirread(int fd, Dir **dp)
{
	DIR *d;
	struct dirent *de;
	Ent *e;
	int copy, dd, i, n, na, size;
	char *s;
	Dir *v;

	*dp = nil;

	/*
	 * fdopendir takes the descriptor over and closedir closes it,
	 * and the caller still owns theirs, so it gets a copy.  The
	 * copy shares the file offset, which is what makes the second
	 * call return nothing: the descriptor is left where this call
	 * stopped reading, and this call reads to the end.
	 */
	if((copy = dup(fd)) < 0)
		return -1;
	if((d = fdopendir(copy)) == nil){
		close(copy);
		return -1;
	}
	dd = dirfd(d);

	/*
	 * Collect first, in one pass -- the directory can change
	 * underneath a second one -- then lay the whole answer into a
	 * single block, which is what the interface promises: one
	 * free frees the lot.
	 */
	e = nil;
	n = na = 0;
	size = 0;
	while((de = readdir(d)) != nil){
		if(strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;
		if(n == na){
			na = na? 2*na: 32;
			if((e = realloc(e, na*sizeof(Ent))) == nil){
				closedir(d);
				werrstr("out of memory");
				return -1;
			}
		}
		if(fstatat(dd, de->d_name, &e[n].st, AT_SYMLINK_NOFOLLOW) < 0)
			continue;
		if((e[n].name = strdup(de->d_name)) == nil){
			closedir(d);
			free(e);
			werrstr("out of memory");
			return -1;
		}
		size += entrysize(&e[n].st, e[n].name);
		n++;
	}
	closedir(d);
	if(n == 0){
		free(e);
		return 0;
	}

	if((v = malloc(size)) == nil){
		for(i = 0; i < n; i++)
			free(e[i].name);
		free(e);
		werrstr("out of memory");
		return -1;
	}
	s = (char*)v + n*sizeof(Dir);
	for(i = 0; i < n; i++){
		fill(&v[i], &e[i].st, e[i].name, &s);
		free(e[i].name);
	}
	free(e);
	*dp = v;
	return n;
}

long
dirreadall(int fd, Dir **dp)
{
	return dirread(fd, dp);
}
