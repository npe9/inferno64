implement Procbench;

#
# What a Dis process and a channel actually cost, so that "one process
# per entity" can be a decision rather than a preference.
#
# doc/games-plan.md proposes a game whose swarm is one Dis process an
# entity, communicating over channels and multiplexed with alt, on the
# grounds that this is the obvious Inferno reading of "many small
# independent things at once".  That reading may be wrong: execution
# here is serialised, not parallel - see the note in doc/hpc-plan.md -
# so N processes and their channel traffic may cost strictly more than a
# loop over an array and buy nothing but shape.  This measures it.
#
# Three things are timed, all doing the SAME arithmetic per entity per
# frame, so the difference is the machinery and not the work:
#
#	loop	one process, a loop over an array
#	procs	one process an entity, woken and waited for each frame
#	pool	one process an entity, all replying on one channel
#
# and separately the cost of a bare channel round trip and of a spawn.
#
# Say which execution mode a number came from: emu runs the interpreter
# unless asked otherwise, and the on-the-fly compiler is different code.
# This prints it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

Procbench: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Entity: adt {
	x, y:	real;
	vx, vy:	real;
};

# The work one entity does in one frame.  Deliberately small and
# deliberately real: a position, a velocity, gravity, and a bounce off
# two walls, which is what the things in these games actually do.
step(e: ref Entity)
{
	e.vy += 0.42;
	e.x += e.vx;
	e.y += e.vy;
	if(e.x < 0.0 || e.x > 256.0)
		e.vx = -e.vx;
	if(e.y > 240.0){
		e.y = 240.0;
		e.vy = -e.vy * 0.8;
	}
}

# Did two arrangements end up in the same place?  Exactly the same
# place: the arithmetic is deterministic and identical, so anything but
# equality is a bug in one of them.
same(a, b: array of ref Entity): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i].x != b[i].x || a[i].y != b[i].y
		|| a[i].vx != b[i].vx || a[i].vy != b[i].vy)
			return 0;
	return 1;
}

mkents(n: int): array of ref Entity
{
	a := array[n] of ref Entity;
	for(i := 0; i < n; i++)
		a[i] = ref Entity(real (i % 256), real (i % 240), 1.0 + real (i%3), 0.0);
	return a;
}

# --- one process, a loop ---
byloop(ents: array of ref Entity, frames: int): int
{
	t0 := sys->millisec();
	for(f := 0; f < frames; f++)
		for(i := 0; i < len ents; i++)
			step(ents[i]);
	return sys->millisec() - t0;
}

# --- one process an entity, each woken and waited for in turn ---
entproc(e: ref Entity, go: chan of int, done: chan of int)
{
	for(;;){
		if(<-go == 0)
			return;
		step(e);
		done <-= 1;
	}
}

byprocs(ents: array of ref Entity, frames: int): int
{
	n := len ents;
	go := array[n] of chan of int;
	done := chan of int;
	for(i := 0; i < n; i++){
		go[i] = chan of int;
		spawn entproc(ents[i], go[i], done);
	}
	t0 := sys->millisec();
	for(f := 0; f < frames; f++){
		for(i = 0; i < n; i++)
			go[i] <-= 1;
		for(i = 0; i < n; i++)
			<-done;
	}
	ms := sys->millisec() - t0;
	for(i = 0; i < n; i++)
		go[i] <-= 0;
	return ms;
}

# --- one process an entity, all sharing one wake-up channel ---
#
# This is the arrangement a game would actually want, because alt cannot
# be written over an array of channels: the entities take from one
# channel and reply on one channel.
poolproc(e: ref Entity, go: chan of int, done: chan of int)
{
	for(;;){
		if(<-go == 0)
			return;
		step(e);
		done <-= 1;
	}
}

bypool(ents: array of ref Entity, frames: int): int
{
	n := len ents;
	go := chan of int;
	done := chan of int;
	for(i := 0; i < n; i++)
		spawn poolproc(ents[i], go, done);
	t0 := sys->millisec();
	for(f := 0; f < frames; f++){
		for(i = 0; i < n; i++)
			go <-= 1;
		for(i = 0; i < n; i++)
			<-done;
	}
	ms := sys->millisec() - t0;
	for(i = 0; i < n; i++)
		go <-= 0;
	return ms;
}

# --- a bare channel round trip ---
echoproc(c: chan of int, r: chan of int)
{
	for(;;){
		v := <-c;
		if(v == 0)
			return;
		r <-= v;
	}
}

roundtrip(n: int): int
{
	c := chan of int;
	r := chan of int;
	spawn echoproc(c, r);
	t0 := sys->millisec();
	for(i := 0; i < n; i++){
		c <-= 1;
		<-r;
	}
	ms := sys->millisec() - t0;
	c <-= 0;
	return ms;
}

# --- making a process ---
nullproc(done: chan of int)
{
	done <-= 1;
}

spawncost(n: int): int
{
	done := chan of int;
	t0 := sys->millisec();
	for(i := 0; i < n; i++){
		spawn nullproc(done);
		<-done;
	}
	return sys->millisec() - t0;
}

execmode(): string
{
	fd := sys->open("/env/emuexec", Sys->OREAD);
	if(fd == nil)
		return "unknown";
	b := array[32] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "unknown";
	s := string b[0:n];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == 0))
		s = s[0:len s-1];
	case s {
	"compile" =>	return "compiled";
	"interp" =>	return "interpreted";
	}
	return "unknown";
}

# microseconds per entity per frame, as a string with two decimals
per(ms, frames, n: int): string
{
	if(frames <= 0 || n <= 0)
		return "-";
	us := real ms * 1000.0 / (real frames * real n);
	w := int (us * 100.0);
	return sys->sprint("%d.%.2d", w / 100, w % 100);
}

SIZES := array[] of {1, 4, 16, 64, 256};

# The clock here is sys->millisec(), so a measurement that takes two
# milliseconds is two significant figures of nothing.  Every measurement
# below is given the same amount of WORK - this many entity-steps - so
# each takes long enough to mean something whatever the entity count.
# The first run of this printed 0.00 for half the table.
STEPS:	con 4*1000*1000;

framesfor(n, budget: int): int
{
	f := budget / n;
	if(f < 50)
		f = 50;
	return f;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	budget := STEPS;
	if(arg != nil){
		arg->init(argv);
		arg->setusage("procbench [-n entity-steps]");
		while((o := arg->opt()) != 0)
			case o {
			'n' =>	budget = int arg->earg();
			* =>	arg->usage();
			}
	}
	if(budget < 1000)
		budget = 1000;

	sys->print("procbench: %s, %d entity-steps a measurement\n",
		execmode(), budget);

	nrt := 500000;
	rt := roundtrip(nrt);
	sys->print("\na channel round trip: %s us (%d of them, %d ms)\n",
		per(rt, 1, nrt), nrt, rt);
	nsp := 100000;
	sp := spawncost(nsp);
	sys->print("spawning a process:   %s us (%d of them, %d ms)\n\n",
		per(sp, 1, nsp), nsp, sp);

	sys->print("%8s %10s %10s %10s   %s\n", "entities", "loop", "procs", "pool",
		"procs/loop");
	bad := 0;
	for(i := 0; i < len SIZES; i++){
		n := SIZES[i];
		frames := framesfor(n, budget);
		# a fresh set each time, so one arrangement does not inherit
		# the state another left
		ea := mkents(n);
		eb := mkents(n);
		ec := mkents(n);
		a := byloop(ea, frames);
		b := byprocs(eb, frames);
		c := bypool(ec, frames);
		# The three must agree.  Without this a transcription error in
		# one of them would show up as a timing difference and not as
		# a wrong answer, and the whole table would be comparing two
		# arrangements doing different amounts of work.
		if(!same(ea, eb) || !same(ea, ec)){
			sys->print("MISMATCH at %d entities: the three did not agree\n", n);
			bad++;
		}
		ratio := "-";
		if(a > 0)
			ratio = sys->sprint("%d.%.1dx", (b*10/a)/10, (b*10/a)%10);
		sys->print("%8d %10s %10s %10s   %s\n", n,
			per(a, frames, n), per(b, frames, n), per(c, frames, n),
			ratio);
	}
	sys->print("\nus/e is microseconds per entity per frame.\n");
	if(bad){
		sys->print("%d of the sizes disagreed; the timings above mean nothing.\n",
			bad);
		raise "fail:mismatch";
	}
	sys->print("The three arrangements agreed at every size.\n");
}
