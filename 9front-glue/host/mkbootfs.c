/*
 * mkbootfs -- lay the tree a proto file describes into a directory.
 *
 * This is the part of 9front's disk/mkfs that a kernel's boot file
 * system needs: read a proto, and for every entry in it make the
 * directory or copy the file into a staging tree, which mkpaqfs then
 * turns into the bootfs.paq the kernel links.
 *
 * disk/mkfs itself is not built here.  It is written against 9front's
 * Bio, which has a Biobufhdr this tree's Bio has not, and it carries
 * five file system kinds -- an archive writer, a kfs reamer, the
 * whole -a/-x/-s family -- none of which a boot file system wants.
 * What it does want is the proto reader, and that is 9front's own:
 * sys/src/libdisk/proto.c compiles for this machine unchanged and is
 * linked in beside this file, so the format is read by the code that
 * defines it rather than by a second implementation of it.
 *
 * usage: mkbootfs -d dir -s srcroot proto [proto...]
 *
 * -s is where the files come from, the way "disk/mkfs -s /" means the
 * running system's root; here it is the built tree, $ROOT/9front.
 *
 * A proto entry names a mode, a user and a group.  The mode is set;
 * the user and the group are not, because this is not Plan 9 and the
 * names in a 9front proto (sys, adm, none) mean nothing here.  What
 * the archive records for them is what mkpaqfs finds on the staging
 * tree, which is the person running the build.  paqfs serves a
 * read-only file system and a boot file system is read by the kernel
 * alone, so nothing consults them; this note is so that is a decision
 * rather than an oversight.
 */
#include <u.h>
#include <libc.h>
#include <bio.h>
#include <disk.h>

char *destroot;
char *srcroot = "/";
int nerr;

static void
warn(char *msg, void*)
{
	fprint(2, "mkbootfs: %s\n", msg);
	nerr++;
}

/*
 * Every component of the destination path, so a proto that names
 * /amd64/bin/auth/factotum works whether or not it named the
 * directories above it first.
 */
static void
mkdirs(char *path)
{
	char *p;

	for(p = path+1; *p != '\0'; p++){
		if(*p != '/')
			continue;
		*p = '\0';
		if(access(path, AEXIST) < 0 && mkdir(path, 0777) < 0 && access(path, AEXIST) < 0)
			fprint(2, "mkbootfs: mkdir %s: %r\n", path);
		*p = '/';
	}
}

static void
copyfile(char *dst, char *src, ulong mode)
{
	char buf[8192];
	int in, out;
	long n;

	if((in = open(src, OREAD)) < 0){
		fprint(2, "mkbootfs: open %s: %r\n", src);
		nerr++;
		return;
	}
	if((out = create(dst, OWRITE|OTRUNC, mode & 0777)) < 0){
		fprint(2, "mkbootfs: create %s: %r\n", dst);
		nerr++;
		close(in);
		return;
	}
	while((n = read(in, buf, sizeof buf)) > 0)
		if(write(out, buf, n) != n){
			fprint(2, "mkbootfs: write %s: %r\n", dst);
			nerr++;
			break;
		}
	if(n < 0){
		fprint(2, "mkbootfs: read %s: %r\n", src);
		nerr++;
	}
	close(in);
	close(out);
	chmod(dst, mode & 0777);
}

static void
enumerate(char *new, char *old, Dir *d, void*)
{
	char dst[2048];

	snprint(dst, sizeof dst, "%s%s", destroot, new);
	if(d->mode & DMDIR){
		mkdirs(dst);
		if(access(dst, AEXIST) < 0 && mkdir(dst, 0777) < 0 && access(dst, AEXIST) < 0){
			fprint(2, "mkbootfs: mkdir %s: %r\n", dst);
			nerr++;
		}
		return;
	}
	mkdirs(dst);
	copyfile(dst, old, d->mode);
}

static void
usage(void)
{
	fprint(2, "usage: mkbootfs -d dir [-s srcroot] proto...\n");
	exits("usage");
}

void
main(int argc, char **argv)
{
	int i;

	ARGBEGIN{
	case 'd':	destroot = EARGF(usage()); break;
	case 's':	srcroot = EARGF(usage()); break;
	default:	usage();
	}ARGEND

	if(destroot == nil || argc < 1)
		usage();

	if(access(destroot, AEXIST) < 0 && mkdir(destroot, 0777) < 0)
		sysfatal("mkdir %s: %r", destroot);

	for(i = 0; i < argc; i++)
		if(rdproto(argv[i], srcroot, enumerate, warn, nil) < 0)
			sysfatal("%s: %r", argv[i]);

	if(nerr)
		sysfatal("%d files did not arrive", nerr);
	exits(nil);
}
