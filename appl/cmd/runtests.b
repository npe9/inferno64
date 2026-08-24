implement Command;

#
# Run the tests and say which failed.
#
# There was no way to do that. The tests exist, they are listed in
# doc/hpc-plan.md, and each has a man page saying how to run it - but running
# them meant running each by hand and remembering which need a flag before they
# check anything at all rather than merely reporting. That is how clicktest's
# own synopsis came to disagree with clicktest for several weeks.
#
# Each test is loaded and run in this process. A test that raises is caught and
# counted rather than being allowed to end the run, which is the whole reason
# for doing it this way instead of from a shell: one test failing must not stop
# the others from being tried.
#
# The graphical ones are a separate list and are not run here. They need a
# display, they need wm underneath them, and some end the session deliberately -
# which would take this program with them. They are named so that what this
# does not cover is visible rather than merely absent.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "arg.m";
include "session.m";
	session: Session;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Test: adt {
	name:	string;
	args:	string;		# as typed, since a global initialiser cannot
				# build a list
	why:	string;		# what it checks, for the listing
};

# Run here. All of these work with no display and no window manager.
headless := array[] of {
	Test("sessiontest", nil,
		"session(2) decoding, compiling, and playing to the keyboard"),
	Test("styxtest", nil,
		"styxlog(1) reading a trace as the right paths, and styxreplay(1)"),
	Test("refstress", nil,
		"that exactly one process executes Dis at a time"),
};

# Run with -g, which needs a screen and so needs this to be started under
# wm(1). None is given -q: that would end the session and take this program
# with it.
graphical := array[] of {
	Test("nowmtest", nil,
		"that a draw context works with no window manager"),
	Test("line3test", nil,
		"the draw3d GPU line provider against the software one"),
	Test("keyuptest", nil,
		"that key releases are not inserted as text"),
	Test("wmtest", "-n 40",
		"window creation in bulk"),
	Test("wmtest", "-k",
		"that what was drawn into a window is still there"),
};

# Still not run by anything here, and why.
notrun := array[] of {
	Test("clicktest", "-e press -n 2",
		"a scripted click on a Tk widget; has to be driven, see -g"),
	Test("drawdecodetest", nil,
		"video decoding into a draw image; wants a clip to hand"),
	Test("gputest", nil,
		"gpu(3) against the software path; slow, and wants a GPU"),
	Test("fdstresstest", nil,
		"the scheduler; hangs on failure, so it needs a timeout around it"),
};

Capture: con "/runtests.out";

# the last thing a test said before it gave up
lastwords(): string
{
	fd := sys->open(Capture, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length == big 0)
		return nil;
	n := int d.length;
	if(n > 4096)
		n = 4096;
	sys->seek(fd, big (int d.length - n), Sys->SEEKSTART);
	buf := array[n] of byte;
	n = sys->read(fd, buf, n);
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	last := "";
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		# a bare verdict is not detail: the line before it says how
		# many of what went wrong, which is what a reader wants
		if(l == nil || l == "PASS" || l == "FAIL")
			continue;
		last = l;
	}
	if(last == "")
		return nil;
	return ": " + last;
}

usage()
{
	fprint(sys->fildes(2), "usage: runtests [-g] [-l] [-v] [-r resultfile]\n");
	raise "fail:usage";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		print("runtests: load: %r\n");
		raise "fail:load";
	}
	# 'list' is a Limbo keyword
	listonly := 0;
	verbose := 0;
	gui := 0;
	result := "/runtests.result";
	arg->init(argv);
	arg->setusage("runtests [-g] [-l] [-v] [-r resultfile]");
	while((o := arg->opt()) != 0)
		case o {
		'l' =>	listonly++;	# say what would run, and run nothing
		'v' =>	verbose++;	# let each test's own output through
		'r' =>	result = arg->earg();
		'g' =>	gui++;		# also the ones that need a screen
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		usage();

	if(listonly){
		print("run here:\n");
		for(i := 0; i < len headless; i++)
			print("    %-16s %s\n", headless[i].name, headless[i].why);
		print("needs a screen, run by hand:\n");
		for(i = 0; i < len graphical; i++)
			print("    %-16s %s\n", graphical[i].name + " " + graphical[i].args,
				graphical[i].why);
		return;
	}

	tests := headless;
	if(gui){
		if(ctxt == nil){
			fprint(sys->fildes(2),
				"runtests: -g needs a window context; run it under wm\n");
			raise "fail:context";
		}
		tests = graphical;
	}
	failed := 0;
	for(i := 0; i < len tests; i++){
		t := tests[i];
		# the arguments are part of the name here: the same test twice
		# with different flags is two different checks, and a listing
		# that says "wmtest" twice says nothing about which failed
		label := t.name;
		if(t.args != nil)
			label += " " + t.args;
		if(!verbose)
			print("%-20s ", label);
		e := run(t, ctxt, verbose);
		if(e == nil){
			if(!verbose)
				print("ok\n");
			else
				print("%-20s ok\n", label);
			continue;
		}
		if(!verbose)
			print("FAIL %s\n", e);
		else
			print("%-20s FAIL %s\n", label, e);
		failed++;
	}

	# The summary also goes to a file, because emu does not carry a Dis
	# program's exit status out to whatever started it: a run with a failing
	# test exits 0 exactly like a clean one. Anything deciding automatically
	# has to read this.
	verdict := sprint("%d of %d ran clean\n", len tests - failed, len tests);
	if(failed)
		verdict += "FAIL\n";
	else
		verdict += "PASS\n";
	rfd := sys->create(result, Sys->OWRITE, 8r666);
	if(rfd != nil)
		fprint(rfd, "%s", verdict);

	print("\n%d of %d ran clean.\n", len tests - failed, len tests);
	rest := graphical;
	what := "need a screen, so run runtests -g under wm";
	if(gui){
		rest = notrun;
		what = "are not run by this at all";
	}
	print("These %s: ", what);
	for(i = 0; i < len rest; i++){
		if(i)
			print(", ");
		print("%s", rest[i].name);
		if(rest[i].args != nil)
			print(" %s", rest[i].args);
	}
	print(".\n");
	sys->remove(Capture);
	if(failed)
		raise "fail:test";
}

#
# Load a test and run it. Its exceptions are caught, because one test failing
# must not stop the rest from being tried - which is the point of running them
# from a program rather than a shell script.
#
# the arguments of a test, as a list
args(s: string): list of string
{
	(nil, l) := sys->tokenize(s, " \t");
	return l;
}

run(t: Test, ctxt: ref Draw->Context, verbose: int): string
{
	m := load Command "/dis/" + t.name + ".dis";
	if(m == nil)
		return sprint("cannot load /dis/%s.dis: %r", t.name);

	# A test says a great deal on the way past. Without -v that goes to a
	# file rather than to the terminal - and to a file rather than to
	# /dev/null, because when a test does fail its own last words are the
	# only detail there is. The exception itself cannot be turned into a
	# string: Limbo gives the variable in an exception clause a type of its
	# own, so what it said is not available here.
	saved := -1;
	saved2 := -1;
	if(!verbose){
		ofd := sys->create(Capture, Sys->OWRITE, 8r666);
		if(ofd != nil){
			# both, because a test's verdict may go to either and its
			# complaints usually go to the second
			saved = sys->dup(1, -1);
			saved2 = sys->dup(2, -1);
			sys->dup(ofd.fd, 1);
			sys->dup(ofd.fd, 2);
		}
	}
	err: string;
	{
		m->init(ctxt, t.name :: args(t.args));
	}exception{
	"fail:*" =>
		err = "reported failure";
	* =>
		err = "raised an exception";
	}
	if(saved >= 0){
		sys->dup(saved, 1);
		sys->dup(saved2, 2);
	}
	if(err != nil && !verbose)
		err += lastwords();
	return err;
}
