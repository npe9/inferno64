/*
 * dirread/dirreadall against a directory this program makes itself,
 * so the answers do not depend on anything in the tree.  It builds a
 * directory with three files and a subdirectory, reads it back, and
 * checks that the names, the sizes, the directory bit and the count
 * are what it put there -- and that a second dirread on the same
 * descriptor returns 0, which is what ends every caller's loop.
 *
 * mk dirreadtest, in this directory.
 */
#include "lib9.h"
#include <sys/stat.h>

static int errors;

static void
check(int ok, char *what)
{
	if(!ok){
		fprint(2, "dirreadtest: %s\n", what);
		errors++;
	}
}

static void
mkfile(char *dir, char *name, int len)
{
	char path[512], buf[512];
	int fd, i;

	snprint(path, sizeof path, "%s/%s", dir, name);
	if((fd = create(path, OWRITE, 0666)) < 0)
		sysfatal("create %s: %r", path);
	for(i = 0; i < len; i++)
		buf[i] = 'a' + i%26;
	if(len > 0 && write(fd, buf, len) != len)
		sysfatal("write %s: %r", path);
	close(fd);
}

void
main(void)
{
	char dir[64], sub[128];
	Dir *d;
	long n;
	int fd, i, seen;

	snprint(dir, sizeof dir, "/tmp/dirreadtest.%d", getpid());
	if(mkdir(dir, 0777) < 0)
		sysfatal("mkdir %s: %r", dir);
	mkfile(dir, "alpha", 5);
	mkfile(dir, "beta", 40);
	mkfile(dir, "gamma", 0);
	snprint(sub, sizeof sub, "%s/delta", dir);
	if(mkdir(sub, 0777) < 0)
		sysfatal("mkdir %s: %r", sub);

	if((fd = open(dir, OREAD)) < 0)
		sysfatal("open %s: %r", dir);

	n = dirreadall(fd, &d);
	check(n == 4, "dirreadall did not return four entries");

	seen = 0;
	for(i = 0; i < n; i++){
		if(strcmp(d[i].name, "alpha") == 0){
			seen |= 1;
			check(d[i].length == 5, "alpha is not five bytes");
			check((d[i].mode & DMDIR) == 0, "alpha is a directory");
			check(d[i].qid.type == QTFILE, "alpha's qid is not a file");
		}else if(strcmp(d[i].name, "beta") == 0){
			seen |= 2;
			check(d[i].length == 40, "beta is not forty bytes");
		}else if(strcmp(d[i].name, "gamma") == 0){
			seen |= 4;
			check(d[i].length == 0, "gamma is not empty");
		}else if(strcmp(d[i].name, "delta") == 0){
			seen |= 8;
			check((d[i].mode & DMDIR) != 0, "delta is not a directory");
			check(d[i].qid.type == QTDIR, "delta's qid is not a directory");
		}else
			check(0, "an entry this test did not create");
		check(d[i].uid != nil && d[i].gid != nil, "no owner or group");
	}
	check(seen == 15, "not all four entries came back");
	free(d);

	/*
	 * The second read ends the caller's loop.  Every caller is
	 * written as "while((n = dirread(fd, &d)) > 0)" and this is
	 * the 0 that stops it.
	 */
	n = dirread(fd, &d);
	check(n == 0, "a second dirread did not return end of directory");
	free(d);
	close(fd);

	/* and again from a fresh descriptor, which starts over */
	if((fd = open(dir, OREAD)) < 0)
		sysfatal("reopen %s: %r", dir);
	n = dirread(fd, &d);
	check(n == 4, "a fresh descriptor did not see four entries");
	free(d);
	close(fd);

	mkfile(dir, "alpha", 0);	/* truncate so remove works everywhere */
	remove(sub);
	snprint(sub, sizeof sub, "%s/alpha", dir); remove(sub);
	snprint(sub, sizeof sub, "%s/beta", dir); remove(sub);
	snprint(sub, sizeof sub, "%s/gamma", dir); remove(sub);
	remove(dir);

	if(errors){
		fprint(2, "dirreadtest: %d failures\n", errors);
		exits("errors");
	}
	print("dirread OK\n");
	exits(nil);
}
