#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"kernel.h"		/* kopen, kread, kwrite, kclose, kbind, kseek */

/*
 * A command interpreter that is not a Dis program.
 *
 * WHY.  os/inferno/stm32f407 has 147456 bytes of RAM and this board's
 * own mkfile records what a shell costs on it: "loading /dis/sh.dis
 * asks malloc for 73536 bytes for its Inst array alone".  XIP puts that
 * array in flash and is the only reason a shell runs here at all -- but
 * the VM's working set, the modules sh loads, and above all a fork for
 * every command are still paid in RAM.  A session driving the radio
 * from the console kills this board in minutes: the heap fragments, a
 * fork fails, the shell dies, and nothing then drains the console queue
 * until the kernel reaches "allocb: no memory" and only the reset
 * button helps.
 *
 * So the cost is not the parser.  It is the VM, the module loads, and
 * the fork per command, and none of those is a language feature.
 *
 * WHAT IT IS.  One kernel process reading the console and calling the
 * kernel's own file layer.  Three properties, in the order they matter:
 *
 *	No malloc.  Every buffer below is static and the total is
 *	counted in one place, because on a board with this much RAM a
 *	claim of "a few kilobytes" that is really twelve is the whole
 *	problem again.
 *
 *	No fork.  "echo x >file" is an open, a write and a close in this
 *	process.  There is nothing to fail for want of a kernel stack.
 *
 *	A held-open file as the centre, not a convenience.  "open ctl
 *	/dev/radio0/ctl" then "put ctl ..." many times then "close ctl"
 *	is what tools/radio/board.py does over the serial line for
 *	exactly this reason, and doing it natively makes the fork cost
 *	structurally impossible rather than merely smaller.
 *
 * WHAT IT IS NOT.  Not a language worth arguing about.  The working set
 * on this board is bind, echo into a file, cat, and ls; strings and a
 * dozen variables cover it.  A Forth or a Tcl would be prettier and
 * would buy nothing, because the expensive thing was never the syntax.
 *
 * "dis" hands over to the Limbo world for when there is RAM to spare,
 * which is the point: Dis becomes something asked for rather than
 * something every boot pays for.
 */

enum
{
	Nline		= 256,		/* one command line */
	Narg		= 16,		/* words in it */
	Nvar		= 12,		/* named strings */
	Nvalue		= 48,		/* how long one may be */
	Nname		= 12,
	Nopen		= 4,		/* files held open across commands */
	Nbuf		= 256,		/* cat's read buffer */

	/*
	 * 256 + 64 + 12*60 + 4*16 + 256 = 1360 bytes, plus this
	 * process's kernel stack.  Counted here so that it stays true:
	 * every buffer in this file appears in this sum.
	 */
};

typedef struct Var Var;
struct Var
{
	char	name[Nname];
	char	val[Nvalue];
};

typedef struct Held Held;
struct Held
{
	char	name[Nname];
	int	fd;
};

static char	line[Nline];
static char	*arg[Narg];
static Var	var[Nvar];
static Held	held[Nopen];
static char	buf[Nbuf];
static int	minshdone;

static char*
getvar(char *name)
{
	int i;

	for(i = 0; i < Nvar; i++)
		if(var[i].name[0] && strcmp(var[i].name, name) == 0)
			return var[i].val;
	return nil;
}

static void
setvar(char *name, char *val)
{
	int i, free;

	free = -1;
	for(i = 0; i < Nvar; i++){
		if(var[i].name[0] == 0){
			if(free < 0)
				free = i;
			continue;
		}
		if(strcmp(var[i].name, name) == 0){
			if(val == nil)
				var[i].name[0] = 0;
			else
				kstrcpy(var[i].val, val, Nvalue);
			return;
		}
	}
	if(val == nil || free < 0)
		return;
	kstrcpy(var[free].name, name, Nname);
	kstrcpy(var[free].val, val, Nvalue);
}

/*
 * Split a line into words, expanding $name as it goes.
 *
 * In place, so a word points into the line buffer: nothing is copied
 * and nothing is allocated.  A $name whose value is longer than what
 * remains of the buffer is truncated rather than growing it, which is
 * the trade this file makes everywhere.
 */
static int
minshtok(char *s, char **av, int max)
{
	char *v, name[Nname];
	int n, i, c;

	n = 0;
	while(*s && n < max){
		while(*s == ' ' || *s == '\t')
			s++;
		if(*s == 0)
			break;
		if(*s == '$'){
			s++;
			for(i = 0; i < Nname-1 && *s && *s != ' ' && *s != '\t'; i++)
				name[i] = *s++;
			name[i] = 0;
			v = getvar(name);
			av[n++] = v != nil? v: "";
			continue;
		}
		/*
		 * Quotes are stripped, because a path is the commonest
		 * argument here and "#W" is the commonest path.  Nothing
		 * in this interpreter treats # specially, so the quotes
		 * a Dis shell needs are noise -- but people type what
		 * they are used to, and "bind -a '#W' /dev" arriving as
		 * a path called 'quote hash W quote' fails in a way that
		 * looks like the bind, not like the quoting.
		 */
		if(*s == '\'' || *s == '"'){
			c = *s++;
			av[n++] = s;
			while(*s && *s != c)
				s++;
			if(*s)
				*s++ = 0;
			continue;
		}
		av[n++] = s;
		while(*s && *s != ' ' && *s != '\t')
			s++;
		if(*s)
			*s++ = 0;
	}
	return n;
}

static int
holdslot(char *name)
{
	int i;

	for(i = 0; i < Nopen; i++)
		if(held[i].name[0] && strcmp(held[i].name, name) == 0)
			return i;
	return -1;
}

static void
say(char *s)
{
	kwrite(1, s, strlen(s));
}

/*
 * Write one string to a path, opening and closing around it.
 *
 * This is the whole of redirection and it is four lines, because the
 * process doing it is the process that read the command.  A shell pays
 * two forks here.
 */
static int
writefile(char *path, char *s, int append)
{
	int fd, r;

	fd = kopen(path, append? OWRITE: OWRITE|OTRUNC);
	if(fd < 0)
		return -1;
	if(append)
		kseek(fd, 0, 2);
	r = kwrite(fd, s, strlen(s));
	kclose(fd);
	return r;
}

static int
catfile(char *path)
{
	int fd, n;

	fd = kopen(path, OREAD);
	if(fd < 0)
		return -1;
	while((n = kread(fd, buf, sizeof buf)) > 0)
		kwrite(1, buf, n);
	kclose(fd);
	return 0;
}

/*
 * One command, already split.  Called inside a waserror() by the loop
 * below: a kernel process that faults takes the kernel with it, and
 * this board's fault handler has itself faulted on a bad stack pointer
 * before now, so every path that touches a Chan is wrapped.
 */
static void
command(int n, char **av)
{
	int i, fd, append;
	char *redir;

	if(n == 0)
		return;

	/* trailing ">file" or ">>file" applies to echo and cat */
	redir = nil;
	append = 0;
	if(n >= 2 && av[n-1][0] == '>'){
		redir = av[n-1] + 1;
		if(*redir == '>'){
			append = 1;
			redir++;
		}
		n--;
	}else if(n >= 3 && strcmp(av[n-2], ">") == 0){
		redir = av[n-1];
		n -= 2;
	}else if(n >= 3 && strcmp(av[n-2], ">>") == 0){
		redir = av[n-1];
		append = 1;
		n -= 2;
	}

	if(strcmp(av[0], "echo") == 0){
		line[0] = 0;		/* reuse: the words are elsewhere now */
		for(i = 1; i < n; i++){
			if(i > 1)
				strcat(buf, " ");
			else
				buf[0] = 0;
			strcat(buf, av[i]);
		}
		if(n == 1)
			buf[0] = 0;
		strcat(buf, "\n");
		if(redir != nil){
			if(writefile(redir, buf, append) < 0)
				say("minsh: cannot write there\n");
		}else
			say(buf);
		return;
	}
	if(strcmp(av[0], "cat") == 0 && n == 2){
		if(catfile(av[1]) < 0)
			say("minsh: cannot read that\n");
		return;
	}
	if(strcmp(av[0], "bind") == 0 && n >= 3){
		/*
		 * The flags a Dis shell's bind takes, because the
		 * commands people already have written down use them:
		 * -a after, -b before, -c create, and nothing is
		 * replace.  Ignoring them and always replacing was the
		 * other half of why "bind -a '#W' /dev" did not work.
		 */
		fd = MREPL;
		for(i = 1; i < n-2; i++){
			if(strcmp(av[i], "-a") == 0)
				fd = (fd & ~MORDER) | MAFTER;
			else if(strcmp(av[i], "-b") == 0)
				fd = (fd & ~MORDER) | MBEFORE;
			else if(strcmp(av[i], "-c") == 0)
				fd |= MCREATE;
		}
		if(kbind(av[n-2], av[n-1], fd) < 0)
			say("minsh: bind failed\n");
		return;
	}
	if(strcmp(av[0], "open") == 0 && n == 3){
		i = holdslot(av[1]);
		if(i < 0)
			for(i = 0; i < Nopen; i++)
				if(held[i].name[0] == 0)
					break;
		if(i >= Nopen){
			say("minsh: no free slot\n");
			return;
		}
		fd = kopen(av[2], OWRITE);
		if(fd < 0){
			say("minsh: cannot open that\n");
			return;
		}
		if(held[i].name[0])
			kclose(held[i].fd);
		kstrcpy(held[i].name, av[1], Nname);
		held[i].fd = fd;
		return;
	}
	if(strcmp(av[0], "put") == 0 && n >= 3){
		i = holdslot(av[1]);
		if(i < 0){
			say("minsh: nothing open by that name\n");
			return;
		}
		buf[0] = 0;
		for(i = 2; i < n; i++){
			if(i > 2)
				strcat(buf, " ");
			strcat(buf, av[i]);
		}
		strcat(buf, "\n");
		i = holdslot(av[1]);
		if(kwrite(held[i].fd, buf, strlen(buf)) < 0)
			say("minsh: write refused\n");
		return;
	}
	if(strcmp(av[0], "close") == 0 && n == 2){
		i = holdslot(av[1]);
		if(i < 0)
			return;
		kclose(held[i].fd);
		held[i].name[0] = 0;
		return;
	}
	if(strcmp(av[0], "set") == 0 && n >= 2){
		setvar(av[1], n >= 3? av[2]: nil);
		return;
	}
	if(strcmp(av[0], "vars") == 0){
		for(i = 0; i < Nvar; i++)
			if(var[i].name[0]){
				say(var[i].name);
				say("=");
				say(var[i].val);
				say("\n");
			}
		return;
	}
	if(strcmp(av[0], "held") == 0){
		for(i = 0; i < Nopen; i++)
			if(held[i].name[0]){
				say(held[i].name);
				say("\n");
			}
		return;
	}
	if(strcmp(av[0], "dis") == 0){
		/*
		 * Hand over to Limbo, which is what this exists to make
		 * optional rather than automatic.  It does not come
		 * back; everything above stops here.
		 */
		say("minsh: starting Dis\n");
		minshdone = 1;
		return;
	}
	if(strcmp(av[0], "help") == 0){
		say("echo cat bind open put close set vars held dis help\n");
		say("redirect with >file or >>file\n");
		return;
	}
	say("minsh: ?\n");
}

static void
minshproc(void*)
{
	int n, i;
	char c;

	if(kopen("#c/cons", OREAD) != 0){
		print("minsh: cannot open the console\n");
		pexit("", 0);
	}
	kopen("#c/cons", OWRITE);
	kopen("#c/cons", OWRITE);

	say("minsh; type help\n");
	while(!minshdone){
		say("> ");
		n = 0;
		for(;;){
			if(kread(0, &c, 1) != 1)
				continue;
			if(c == '\r' || c == '\n')
				break;
			if(n < Nline-1)
				line[n++] = c;
		}
		line[n] = 0;
		if(n == 0)
			continue;
		i = minshtok(line, arg, Narg);
		if(waserror()){
			say("minsh: ");
			say(up->env->errstr);
			say("\n");
			continue;
		}
		command(i, arg);
		poperror();
	}
	pexit("", 0);
}

/*
 * Run in the caller's context and never come back, which is what
 * disinit() does and for the same reason: the first process is the one
 * userinit() gave a namespace, and kopen() needs one.  A kproc'd
 * process starts without it, which is why the first attempt printed
 * nothing at all -- not a fault, just a process with no root to open
 * "#c/cons" against.
 */
void
minshinit(void)
{
	minshproc(nil);
}
