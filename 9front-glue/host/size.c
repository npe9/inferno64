/*
 * size -- what a Plan 9 a.out holds, for a build machine that is not
 * Plan 9.
 *
 * cwfs and a few other mkfiles run "size $target" after linking, and
 * on this machine the name reaches the Xcode size, which reads Mach-O
 * and nothing else.  9front's own size is a 9front binary and cannot
 * run here; it works through libmach, which is more of 9front than
 * this build has any reason to bring across for eight numbers.
 *
 * What it reads is the header at the front of the file: eight
 * big-endian 32-bit words, and on the machines whose magic has
 * HDR_MAGIC in it a 64-bit entry point after them, which this does
 * not need.  a.out.h beside this tree's own loaders is where the
 * magic numbers are; that is the same file the loaders write them
 * from.  The three sizes are printed the way 9front's size prints
 * them, which is also the way the loader reports them when it writes
 * the file, so the two can be read against each other.
 */
#include <u.h>
#include <libc.h>
#include <a.out.h>

static long magics[] = {
	A_MAGIC, I_MAGIC, J_MAGIC, K_MAGIC, V_MAGIC, X_MAGIC, M_MAGIC,
	D_MAGIC, E_MAGIC, Q_MAGIC, N_MAGIC, L_MAGIC, P_MAGIC, U_MAGIC,
	S_MAGIC, T_MAGIC, R_MAGIC, Z_MAGIC, Y_MAGIC,
};

static long
beswal(uchar *p)
{
	return ((long)p[0]<<24) | ((long)p[1]<<16) | ((long)p[2]<<8) | p[3];
}

static int
size(char *file)
{
	int fd, i, ok;
	uchar hdr[8*4];
	long magic, text, data, bss;

	if((fd = open(file, OREAD)) < 0){
		fprint(2, "size: %s: %r\n", file);
		return 1;
	}
	if(readn(fd, hdr, sizeof hdr) != sizeof hdr){
		fprint(2, "size: %s not an a.out\n", file);
		close(fd);
		return 1;
	}
	close(fd);

	magic = beswal(hdr);
	ok = 0;
	for(i = 0; i < nelem(magics); i++)
		if(magic == magics[i] || magic == (magics[i]|DYN_MAGIC))
			ok = 1;
	if(!ok){
		fprint(2, "size: %s not an a.out\n", file);
		return 1;
	}
	text = beswal(hdr+4);
	data = beswal(hdr+8);
	bss = beswal(hdr+12);
	print("%ldt + %ldd + %ldb = %ld\t%s\n", text, data, bss,
		text+data+bss, file);
	return 0;
}

void
main(int argc, char *argv[])
{
	char *err;
	int i;

	ARGBEGIN{
	default:
		fprint(2, "usage: size [a.out ...]\n");
		exits("usage");
	}ARGEND

	err = 0;
	if(argc == 0)
		err = size("6.out") ? "error" : 0;
	for(i = 0; i < argc; i++)
		if(size(argv[i]))
			err = "error";
	exits(err);
}
