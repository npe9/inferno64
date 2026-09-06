/*
 * wc, for the library operating system: the far end of a pipeline.
 *
 * It reads its standard input to end of file and says how much there
 * was.  On the library-OS personality its read is a call into the file
 * system in its own address space, and its standard input is a pipe of
 * the personality's that the shell handed it; the count it prints goes
 * to the machine's console, which is the one thing still a trap.
 *
 * It is here because a pipeline needs two different programs: a program
 * is at the address it was linked for and nothing relocates it, so two
 * of one program would be the one image (p9lib.h).  Two of these run at
 * once with cat.
 */
#include <u.h>
#include <libc.h>

void
startboot(char *argv0, char **argv)
{
	char buf[4096];
	long n, lines, words, bytes;
	int i, inword;

	USED(argv0);
	USED(argv);
	lines = words = bytes = 0;
	inword = 0;
	while((n = read(0, buf, sizeof buf)) > 0){
		bytes += n;
		for(i = 0; i < n; i++){
			if(buf[i] == '\n')
				lines++;
			if(buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\n'){
				inword = 0;
			} else if(!inword){
				inword = 1;
				words++;
			}
		}
	}
	if(n < 0){
		print("libwc: the read failed\n");
		exits("read");
	}
	print("libwc: %ld lines %ld words %ld bytes off the pipe, read as a call into the personality\n",
		lines, words, bytes);
	exits(nil);
}
