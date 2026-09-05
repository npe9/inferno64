/*
 * cat - an ordinary Plan 9 program, its file system calls served by the
 * buddy over the ring.  It takes a real argument vector: startboot gets
 * argv0 and argv, and cat reads each named file and writes it to
 * descriptor 1.  It is the proof that exec carries arguments now and
 * that an arbitrary program - not the hand-written demonstration - runs
 * on the server personality: this program knows nothing of Osprey.
 */
#include <u.h>
#include <libc.h>

static void
catfd(int fd)
{
	char buf[512];
	long n;

	while((n = read(fd, buf, sizeof buf)) > 0)
		write(1, buf, n);
}

void
startboot(char *argv0, char **argv)
{
	int i, argc, fd;

	USED(argv0);
	/* count the argument vector startboot was handed */
	for(argc = 0; argv[argc] != nil; argc++)
		;
	print("cat: started with %d arguments; argv[0] = %s\n", argc, argv[0]);
	if(argc < 2){
		print("cat: no file named; usage: cat file...\n");
		exits("usage");
	}
	for(i = 1; i < argc; i++){
		print("cat: opening %s (argument %d), served by the buddy\n", argv[i], i);
		fd = open(argv[i], OREAD);
		if(fd < 0){
			print("cat: cannot open %s\n", argv[i]);
			continue;
		}
		/*
		 * dup the descriptor and read the file through the duplicate:
		 * the buddy holds the descriptor table, so dup(2) is answered
		 * there.  Proof the descriptor really duplicated: the copy
		 * reads the same file.
		 */
		{
			int df = dup(fd, -1);
			if(df >= 0){
				print("cat: dup'd descriptor %d to %d through the buddy; %s through the duplicate ->\n", fd, df, argv[i]);
				catfd(df);
				print("\ncat: <- end of %s through the duplicate\n", argv[i]);
				close(df);
			} else
				print("cat: dup of %d failed\n", fd);
		}
		close(fd);
	}
	exits(nil);
}
