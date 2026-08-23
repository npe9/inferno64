implement Shellbuiltin;

#
# Drive and describe a session from the shell.
#
# A recording made by INFERNO_INPUT_RECORD reproduces a session exactly and
# reads like nothing at all. `session script' turns it into shell:
#
#	session wait 7.240
#	session type 'echo hello'
#	session key Return
#	session wait 1.512
#	session type quitall
#	session key Return
#
# which is the same thing said in a way a person can read, edit, and run.
#
# That the script is shell is the whole design, not a convenience. Stopping a
# replay needs no protocol, because a script that has stopped is a shell that
# has not been given its next line - and the system underneath it is live the
# entire time, so you can use it and then carry on. `session pause' is exactly
# that: it waits for a line on the console while the machine goes on running.
#
# There are now two ways to replay a session and they are not the same
# mechanism. INFERNO_INPUT_REPLAY (emu(1)) feeds the recorded events back
# below every bind, which is faithful and cannot be interrupted. This feeds
# actions through /dev/keyboard and /dev/pointerin, which is approximate -
# it re-times everything and it cannot resize the window - and can be stopped
# anywhere. Use the first to reproduce, the second to demonstrate or to
# interact.
#
include "sys.m";
	sys: Sys;
	sprint, fprint: import sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "session.m";
	session: Session;
	Action: import session;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if(myself == nil)
		ctxt.fail("bad module", sprint("session: cannot load self: %r"));
	session = load Session Session->PATH;
	if(session == nil)
		ctxt.fail("bad module", sprint("session: cannot load %s: %r", Session->PATH));
	if((e := session->init()) != nil)
		ctxt.fail("bad module", "session: " + e);
	ctxt.addbuiltin("session", myself);
	return nil;
}

whatis(nil: ref Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

getself(): Shellbuiltin
{
	return myself;
}

runsbuiltin(nil: ref Context, nil: Sh, nil: list of ref Listnode): list of ref Listnode
{
	return nil;
}

# a script, back into the actions it names. Blank lines and comments are the
# ones this program wrote; anything else must parse or the script is wrong and
# saying so is more use than skipping it.
readscript(path: string): (array of ref Action, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("%s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sprint("stat %s: %r", path));
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return (nil, sprint("short read of %s", path));

	acts: list of ref Action;
	n := 0;
	for(i := 0; i < len buf; ){
		j := i;
		while(j < len buf && buf[j] != byte '\n')
			j++;
		line := string buf[i:j];
		i = j+1;
		w := tokens(line);
		if(w == nil || (hd w)[0] == '#')
			continue;
		if(hd w == "session")
			w = tl w;
		(a, err) := session->parse(w);
		if(err != nil)
			return (nil, sprint("%s: %s", line, err));
		acts = a :: acts;
		n++;
	}
	r := array[n] of ref Action;
	for(i = n-1; i >= 0; i--){
		r[i] = hd acts;
		acts = tl acts;
	}
	return (r, nil);
}

# words of a script line, honouring the single quotes this program writes
tokens(s: string): list of string
{
	r: list of string;
	i := 0;
	while(i < len s){
		while(i < len s && (s[i] == ' ' || s[i] == '\t'))
			i++;
		if(i >= len s)
			break;
		w := "";
		if(s[i] == '\''){
			i++;
			while(i < len s){
				if(s[i] == '\''){
					if(i+1 < len s && s[i+1] == '\''){
						w[len w] = '\'';
						i += 2;
						continue;
					}
					i++;
					break;
				}
				w[len w] = s[i];
				i++;
			}
		}else{
			while(i < len s && s[i] != ' ' && s[i] != '\t'){
				w[len w] = s[i];
				i++;
			}
		}
		r = w :: r;
	}
	q: list of string;
	for(; r != nil; r = tl r)
		q = hd r :: q;
	return q;
}

words(argv: list of ref Listnode): list of string
{
	w: list of string;
	for(; argv != nil; argv = tl argv)
		w = (hd argv).word :: w;
	r: list of string;
	for(; w != nil; w = tl w)
		r = hd w :: r;
	return r;
}

usage: con
"usage: session script recording          # print it as a script\n"+
"       session compile script recording  # and the other way\n"+
"       session play recording            # run it, honouring its waits\n"+
"       session type text | key name\n"+
"       session click x y [b] | doubleclick x y [b] | drag x0 y0 x1 y1 [b]\n"+
"       session move x y | wait seconds\n"+
"       session pause [seconds]     # stop here; the system stays live";

runbuiltin(ctxt: ref Context, nil: Sh, argv: list of ref Listnode, nil: int): string
{
	if((hd argv).word != "session")
		return nil;
	w := tl words(argv);
	if(w == nil)
		ctxt.fail("usage", usage);

	case hd w {
	"script" or "play" =>
		verb := hd w;
		if(len w != 2)
			ctxt.fail("usage", usage);
		(acts, err) := session->read(hd tl w);
		if(err != nil)
			ctxt.fail("session", "session: " + err);
		if(verb == "script"){
			sys->print("# %d actions, %d.%.3ds\n",
				len acts, session->span(acts)/1000, session->span(acts)%1000);
			for(i := 0; i < len acts; i++)
				sys->print("%s\n", acts[i].script());
			return nil;
		}
		for(i := 0; i < len acts; i++)
			if((e := acts[i].play()) != nil)
				fprint(sys->fildes(2), "session: %s\n", e);
		return nil;

	"compile" =>
		# The loop the other way round: a recording becomes a script,
		# the script is edited, and this makes it a recording again.
		# Recording what a script injects would be the obvious route
		# and is the wrong one - the events would arrive twice whenever
		# the replay re-ran the script that injected them.
		if(len w != 3)
			ctxt.fail("usage", usage);
		(sfd, rec) := (hd tl w, hd tl tl w);
		(acts, err) := readscript(sfd);
		if(err != nil)
			ctxt.fail("session", "session: " + err);
		if((e := session->write(acts, rec)) != nil)
			ctxt.fail("session", "session: " + e);
		return nil;

	"pause" =>
		# The point of the whole exercise: everything below this shell
		# is still running, so the machine can be used while this waits.
		#
		# With a number, wait that long instead of for a person. fd 0
		# here is #c/cons, not whatever the host redirected, so a script
		# run with nobody at the console waits at a bare pause for ever
		# - which is right for an interactive pause and useless for an
		# unattended one. A timed pause is a plain sleep rather than a
		# read raced against a timer, because the losing reader would
		# stay blocked on the console and a blocked process keeps emu
		# alive after everything else has finished.
		if(len w == 2){
			sys->print("session: pausing %s seconds\n", hd tl w);
			sys->sleep(int (real hd tl w * 1000.0));
			return nil;
		}
		if(len w != 1)
			ctxt.fail("usage", usage);
		sys->print("session: paused - use the system, then press return here\n");
		buf := array[256] of byte;
		for(;;){
			n := sys->read(sys->fildes(0), buf, len buf);
			if(n <= 0)
				break;		# end of input: carry on
			stop := 0;
			for(i := 0; i < n; i++)
				if(buf[i] == byte '\n')
					stop = 1;
			if(stop)
				break;
		}
		return nil;

	* =>
		(a, err) := session->parse(w);
		if(err != nil)
			ctxt.fail("usage", "session: " + err);
		if((e := a.play()) != nil)
			ctxt.fail("session", "session: " + e);
		return nil;
	}
}
