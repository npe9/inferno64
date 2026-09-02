/*
 * An unmodified Plan 9 program.  It knows nothing of Osprey, the ring, or
 * a buddy: it opens a file and reads it with the ordinary Plan 9 library,
 * which traps in the Plan 9 system-call ABI.  On this microkernel those
 * traps - open, read, close - are not implemented; a buddy operating
 * system in a peer container answers them, and this program cannot tell.
 * Its writes go to the console through the kernel's own pwrite, so what it
 * prints appears directly; only the file operations cross to the buddy.
 */
#include <u.h>
#include <libc.h>

/*
 * Entry is startboot (init9's trampoline), since the host linker cannot
 * read libc's own _main; that is entry glue only.  What makes this a
 * legacy binary is the body: ordinary Plan 9 open/read/close/print.
 */
void
startboot(char *argv0, char **argv)
{
	int fd;
	char buf[512];
	long n;

	USED(argv0); USED(argv);
	print("legacy: an unmodified Plan 9 program; its file syscalls are served by a buddy\n");

	fd = open("/", OREAD);
	if(fd < 0){
		print("legacy: open(\"/\") failed\n");
		exits("open");
	}
	print("legacy: open(\"/\") returned fd %d\n", fd);

	n = read(fd, buf, sizeof buf);
	print("legacy: read(fd, buf, %d) returned %ld bytes, served by the buddy\n", (int)sizeof buf, n);

	close(fd);
	print("legacy: closed the fd; the buddy answered every trap\n");
	exits(nil);
}
