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

/*
 * Heap growth, through libc's own sbrk and so through brk_(2): ask for
 * far more than the page the exec left above the image, so that the ask
 * really crosses the end of the binary and the kernel has to grow the
 * segment - a small ask would land inside the image's own bss and prove
 * nothing.  Write a pattern the length of it and read it back, so that
 * the memory is shown to be there and to be the process's own.
 */
static void
heap(void)
{
	enum { Nheap = 512*1024 };
	char *a, *b;
	long i;
	int bad;

	a = sbrk(Nheap);
	if(a == (char*)-1){
		print("cat: sbrk of %d bytes failed; no heap\n", Nheap);
		return;
	}
	for(i = 0; i < Nheap; i++)
		a[i] = (char)(i * 7 + 3);
	bad = 0;
	for(i = 0; i < Nheap; i++)
		if(a[i] != (char)(i * 7 + 3))
			bad++;
	b = sbrk(0);
	print("cat: sbrk grew the heap %d bytes at %p, now to %p; %d bytes written and read back, %d wrong\n",
		Nheap, a, b, Nheap, bad);
}

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
		/*
		 * No file named: read the standard input and write it out, as
		 * cat does.  This is the far end of a pipeline - the shell dups
		 * the pipe onto descriptor 0 before it execs this - and the byte
		 * count says what crossed.
		 */
		char buf[512];
		long n, tot;

		tot = 0;
		while((n = read(0, buf, sizeof buf)) > 0){
			write(1, buf, n);
			tot += n;
		}
		/*
		 * How the reading ended matters as much as how much was read: 0
		 * is the writer's end closing, which is what a pipeline means,
		 * and -1 would be the call giving up - the two are the same
		 * byte count and only this line tells them apart.
		 */
		print("\ncat: %ld bytes read from my standard input and written to my standard output; the read ended with %ld (0 is end of file, the writer gone)\n", tot, n);
		exits(nil);
	}
	heap();
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
				char path[128];

				print("cat: dup'd descriptor %d to %d through the buddy; %s through the duplicate ->\n", fd, df, argv[i]);
				/*
				 * fd2path of the duplicate: the buddy holds the
				 * descriptor table, so the path comes from the name
				 * space the container's own buddy resolved it in.
				 */
				if(fd2path(df, path, sizeof path) == 0)
					print("cat: descriptor %d is %s, by fd2path through the buddy\n", df, path);
				else
					print("cat: fd2path of %d failed\n", df);
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
