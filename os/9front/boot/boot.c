#include <u.h>
#include <libc.h>

char bin[] = "/bin";
char root[] = "/root";

void
main(int, char *argv[])
{
	char buf[32];
	char *bootargv[2];

	USED(argv);
	bootargv[0] = "/bin/bootrc";
	bootargv[1] = nil;

	pwrite(2, "boot: start\n", 12, -1LL);
	/* setup the boot namespace */
	bind("/boot", bin, MAFTER);

	if(fork() == 0){
		execl("/bin/paqfs", "-qa", "-c", "8", "-m", root, "/boot/bootfs.paq", nil);
		goto Err;
	}
	if(await(buf, sizeof(buf)) < 0)
		goto Err;
	pwrite(2, "boot: paqfs done\n", 17, -1LL);

	bind(root, "/", MAFTER);

	buf[0] = '/';
	buf[1+read(open("/env/cputype", OREAD|OCEXEC), buf+1, sizeof buf - 6)] = '\0';
	strcat(buf, bin);
	bind(buf, bin, MAFTER);
	bind("/root/rc", "/rc", MREPL);
	bind("/rc/bin", bin, MAFTER);

	pwrite(2, "boot: bootrc\n", 13, -1LL);
	exec("/bin/bootrc", bootargv);
Err:
	errstr(buf, sizeof buf);
	pwrite(2, "boot: error\n", 12, -1LL);
	_exits(buf);
}
