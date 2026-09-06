/*
 * sh - a small shell, an ordinary Plan 9 program, running on the server
 * personality with every system call it makes answered by a peer
 * container over the ring.  It is the smallest program that needs all
 * four of the things a shell needs and the buddy had to grow: it forks,
 * it execs the forked child in place, it makes a pipe and puts one
 * child's output on it and another's input from it, and it waits for
 * each child and reads its exit status.
 *
 * The language is the least that can express that: one command a line,
 * words separated by blanks, stages separated by |, # to the end of the
 * line a comment, blank lines ignored.  No quoting, no variables, no
 * redirection to a file - a shell for the demonstration, not a shell to
 * live in, and it says so.
 */
#include <u.h>
#include <libc.h>

enum {
	Nstage	= 4,		/* stages in a pipeline */
	Nword	= 8,		/* words in a stage */
	Nline	= 512,
	Nscript	= 4096,
};

static char script[Nscript];

/*
 * Split a line into stages at |, and each stage into words at blanks,
 * in place.  Returns the number of stages; stage[i] is a nil-terminated
 * argument vector.
 */
static int
parse(char *line, char *stage[Nstage][Nword+1])
{
	char *p, *q;
	int ns, nw;

	ns = 0;
	p = line;
	while(ns < Nstage){
		if((q = strchr(p, '|')) != nil)
			*q = 0;
		nw = 0;
		while(nw < Nword){
			while(*p == ' ' || *p == '\t')
				p++;
			if(*p == 0)
				break;
			stage[ns][nw++] = p;
			while(*p != 0 && *p != ' ' && *p != '\t')
				p++;
			if(*p != 0)
				*p++ = 0;
		}
		stage[ns][nw] = nil;
		if(nw > 0)
			ns++;
		if(q == nil)
			break;
		p = q + 1;
	}
	return ns;
}

static void
runline(char *line)
{
	char *stage[Nstage][Nword+1];
	int ns, i, p[2], in, out, pid;
	char status[ERRMAX];

	ns = parse(line, stage);
	if(ns == 0)
		return;
	in = -1;
	for(i = 0; i < ns; i++){
		out = -1;
		if(i + 1 < ns){
			if(pipe(p) < 0){
				print("sh: no pipe\n");
				return;
			}
			out = p[1];
		}
		if(rfork(RFPROC) == 0){
			/*
			 * The child: its input is the previous stage's pipe and
			 * its output the next one's, each dup'd onto the standard
			 * descriptor the program will use without knowing.  The
			 * pipe's own numbers are closed after, so a stage that
			 * ends really ends and the reader sees end of file.
			 */
			if(in >= 0){
				dup(in, 0);
				close(in);
			}
			if(out >= 0){
				dup(out, 1);
				close(out);
				close(p[0]);
			}
			exec(stage[i][0], stage[i]);
			print("sh: cannot exec %s\n", stage[i][0]);
			exits("exec");
		}
		if(in >= 0)
			close(in);
		if(out >= 0){
			close(out);
			in = p[0];
		}
	}
	if(in >= 0)
		close(in);
	for(i = 0; i < ns; i++){
		pid = await(status, sizeof status - 1);
		if(pid > 0 && pid < (int)sizeof status)
			status[pid] = 0;	/* await answers a byte count, not a string */
		else
			status[0] = 0;
		if(pid < 0)
			print("sh: nothing to wait for\n");
		else
			print("sh: a stage of the pipeline ended: %s\n", status);
	}
}

void
startboot(char *argv0, char **argv)
{
	int argc, fd;
	long n, i, j;
	char line[Nline];

	USED(argv0);
	for(argc = 0; argv[argc] != nil; argc++)
		;
	if(argc < 2){
		print("sh: usage: sh script\n");
		exits("usage");
	}
	print("sh: reading the script %s, my file calls answered by the buddy\n", argv[1]);
	if((fd = open(argv[1], OREAD)) < 0){
		print("sh: cannot open %s\n", argv[1]);
		exits("open");
	}
	n = 0;
	while(n < (long)sizeof script - 1){
		i = read(fd, script + n, sizeof script - 1 - n);
		if(i <= 0)
			break;
		n += i;
	}
	close(fd);
	script[n] = 0;
	for(i = 0; i < n; ){
		for(j = i; j < n && script[j] != '\n'; j++)
			;
		if(j - i > 0 && j - i < (long)sizeof line){
			memmove(line, script + i, j - i);
			line[j - i] = 0;
			if(line[0] != '#'){
				print("sh: %s\n", line);
				runline(line);
			}
		}
		i = j + 1;
	}
	print("sh: the script is done\n");
	exits(nil);
}
