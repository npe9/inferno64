/*
 * A shell for the library operating system.
 *
 * The server personality's shell (shp9.c) forks and execs: it runs on a
 * legacy binary's container, and fork and exec are what its kernel and
 * its buddy give it.  This one cannot be that source, and the reason is
 * the arrangement, not an omission.  A library operating system is one
 * address space; rfork(RFPROC) would have to split this program's own C
 * stack, which no library can do for its caller, and exec would have to
 * lay a new binary over the personality that is running the shell.  So
 * this shell starts programs instead of forking into them: spawn is the
 * fused fork-and-exec the library offers (p9lib.h), and the shell was
 * only ever using fork and exec together anyway.
 *
 * The claim earned in 3.2a - one program, two arrangements - is a claim
 * about commands, and it still holds: cat is the same source on both
 * personalities.  It is not a claim about shells, and this file says so
 * rather than pretending.
 *
 * What it understands is a script: one command a line, words separated
 * by blanks, stages separated by |, # to end of line a comment.  That is
 * what shp9.c understands too, so the same script runs on both.
 */
#include <u.h>
#include <libc.h>

extern int spawn(char *name, char **argv, int in, int out);
extern int awaitpid(int pid, char *status, int nstatus);

enum {
	/*
	 * Five, so that a pipeline can hold every relocation slot the
	 * personality has at once: the shell is a module too and keeps one
	 * for as long as its script runs, so five stages beside it is six.
	 * A number that is never reached proves nothing about the slots.
	 */
	Nstage	= 5,		/* stages in a pipeline */
	Narg	= 8,		/* words in a stage */
	Nline	= 512,
	Nscript	= 8192,
};

/* split s on any of the separators, in place; returns the count */
static int
split(char *s, char **out, int max, char sep)
{
	int n;

	n = 0;
	for(;;){
		while(*s == ' ' || *s == '\t')
			s++;
		if(*s == 0)
			break;
		if(n >= max)
			return -1;
		out[n++] = s;
		while(*s != 0 && *s != sep)
			s++;
		if(*s == 0)
			break;
		*s++ = 0;
	}
	/* trim trailing blanks off each piece */
	for(max = 0; max < n; max++){
		char *e;

		e = out[max] + strlen(out[max]);
		while(e > out[max] && (e[-1] == ' ' || e[-1] == '\t'))
			*--e = 0;
	}
	return n;
}

static void
runline(char *line)
{
	char *stage[Nstage];
	char *av[Nstage][Narg+1];
	int pid[Nstage];
	char status[64];
	int ns, na, i, in, out, p[2], npid;

	ns = split(line, stage, Nstage, '|');
	if(ns <= 0){
		if(ns < 0)
			print("libsh: too many stages in a pipeline\n");
		return;
	}
	for(i = 0; i < ns; i++){
		na = split(stage[i], av[i], Narg, ' ');
		if(na <= 0){
			print("libsh: an empty stage in a pipeline\n");
			return;
		}
		av[i][na] = nil;
	}

	/*
	 * The ends of the pipeline are the shell's own 0 and 1, not the
	 * machine's console.  That distinction did not exist while the only
	 * shell was the one the personality starts, whose 0 and 1 are the
	 * console anyway - but a shell rio starts in a window has the
	 * window there, and a command it runs should write to the window.
	 * Handing -1 wrote to the console instead, which is the machine's
	 * and not the window's.
	 *
	 * mine says which of these numbers the shell must not close: its
	 * own two, as against a pipe end it made and has to close for the
	 * far end ever to see end of file.
	 */
	in = 0;
	npid = 0;
	for(i = 0; i < ns; i++){
		out = i < ns-1 ? -1 : 1;
		p[0] = p[1] = -1;
		if(i < ns-1){
			if(pipe(p) < 0){
				print("libsh: no pipe\n");
				break;
			}
			out = p[1];
		}
		pid[i] = spawn(av[i][0], av[i], in, out);
		/*
		 * The shell's own ends go now.  The child was given its own
		 * copies when it was started, so closing here does not take
		 * them away - and not closing here is what would stop the far
		 * end of the pipe from ever seeing end of file.  The shell's
		 * own 0 and 1 are not ends it made and stay open.
		 */
		if(in > 1)
			close(in);
		if(out > 1)
			close(out);
		in = i < ns-1 ? p[0] : 0;
		if(pid[i] < 0){
			print("libsh: %s: cannot start it\n", av[i][0]);
			break;
		}
		npid++;
	}
	if(in > 1)
		close(in);
	for(i = 0; i < npid; i++){
		status[0] = 0;
		if(awaitpid(pid[i], status, sizeof status) < 0)
			print("libsh: no such program to wait for\n");
		else
			print("libsh: %s ended, status \"%s\"\n", av[i][0], status);
	}
}

void
startboot(char *argv0, char **argv)
{
	static char script[Nscript];
	char line[Nline];
	char *p, *e, *nl;
	int fd;
	long n, got;

	USED(argv0);
	/*
	 * No arguments is a shell to type at.
	 *
	 * rio starts the shell in a window it sweeps with no arguments at
	 * all, so without this a new window ran a shell that printed a
	 * usage line and exited, and the window went with it.  A window
	 * system whose windows close as fast as they open is not one you
	 * can use.
	 *
	 * The reader is descriptor 0, which in a rio window is that
	 * window's own /dev/cons: rio assembles the line and hands it over
	 * when Enter is pressed, so this reads a line at a time and does
	 * not echo - the window has already drawn what was typed.
	 */
	if(argv == nil || argv[1] == nil){
		print("libsh: a shell to type at; one command a line, "
			"words at blanks, stages at |\n");
		for(;;){
			/*
			 * A prompt, because a window with nothing in it looks
			 * like a window with nothing running in it.  It goes
			 * out before every read, so it is there the moment the
			 * window is swept and again after every command.
			 */
			print("; ");
			n = read(0, line, sizeof line - 1);
			if(n <= 0)
				break;		/* end of file: the window is gone */
			line[n] = 0;
			nl = strchr(line, '\n');
			if(nl != nil)
				*nl = 0;
			nl = strchr(line, '#');
			if(nl != nil)
				*nl = 0;
			if(line[0] == 0)
				continue;
			runline(line);
		}
		print("libsh: end of input; this shell is done\n");
		exits(nil);
	}
	/*
	 * -c command, which is how rio starts a shell in a window: it runs
	 * /bin/rc with "-c" and one line to run.  The line is run and the
	 * shell ends, which is what -c means.
	 *
	 * The script path below is this shell's other way in, and the two
	 * do not overlap: a script is a file of lines and this is one line
	 * given outright.
	 */
	if(strcmp(argv[1], "-c") == 0){
		if(argv[2] == nil){
			print("libsh: -c wants a command\n");
			exits("usage");
		}
		strncpy(line, argv[2], sizeof line - 1);
		line[sizeof line - 1] = 0;
		print("libsh: -c %s\n", line);
		runline(line);
		print("libsh: the command is done\n");
		exits(nil);
	}
	if((fd = open(argv[1], OREAD)) < 0){
		print("libsh: cannot open %s\n", argv[1]);
		exits("open");
	}
	for(got = 0; got < Nscript-1; got += n){
		n = read(fd, script+got, Nscript-1-got);
		if(n <= 0)
			break;
	}
	script[got < 0 ? 0 : got] = 0;
	close(fd);
	print("libsh: %ld bytes of script, read by calling the personality beside me\n", got);

	p = script;
	e = script + strlen(script);
	while(p < e){
		nl = strchr(p, '\n');
		if(nl != nil)
			*nl = 0;
		strncpy(line, p, sizeof line - 1);
		line[sizeof line - 1] = 0;
		p = nl == nil ? e : nl+1;
		nl = strchr(line, '#');
		if(nl != nil)
			*nl = 0;
		if(line[0] == 0)
			continue;
		print("libsh: %s\n", line);
		runline(line);
	}
	print("libsh: the script is done, and the personality that started me is still here\n");
	exits(nil);
}
