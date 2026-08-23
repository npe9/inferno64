implement Command;

#
# disrepl - type Dis instructions at a prompt and watch them run.
#
# Dis needs no interpreter written for it: emu already interprets and JITs it,
# asm(1) assembles it and disdump(1) disassembles it. What was missing was the
# loop and, much more awkwardly, somewhere for a program to keep its state
# between one typed line and the next.
#
# The approach here is to keep every line typed and re-run the whole session
# after each one. That has one real consequence and it is not hidden: a line
# with an effect outside the virtual machine happens again on every subsequent
# line. It buys correctness with no work in the VM at all - the frame, its type
# descriptor and the module's link section come from a wrapper that the Limbo
# compiler generated, so the garbage collector is told the truth about which
# words hold pointers without this program having to compute a descriptor.
#
# The wrapper below is verbatim limbo -S output, kept as text. Do not hand-edit
# the descriptors: regenerate it (the procedure is in REGENERATING, below) if
# the scratch layout ever needs to change, and update Scratch to match.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Sfile:	con "/tmp/disrepl.s";
Dfile:	con "/tmp/disrepl.dis";
Marker:	con "\tmovw\t$31337,80(fp)";
Limitms: con 3000;		# how long a typed program may run

#
# REGENERATING the wrapper
#
# Compile this, with N scratch variables, and take the assembly verbatim:
#
#	implement Skel;
#	include "sys.m";
#	include "draw.m";
#	Skel: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
#	init(nil: ref Draw->Context, nil: list of string)
#	{
#		sys := load Sys Sys->PATH;
#		s0 := 0; s1 := 0; ... ;
#		s0 = 31337;
#		sys->print("%d %d ...\en", s0, s1, ...);
#	}
#
#	limbo -S -I/module skel.b
#
# The "s0 = 31337" line becomes one instruction with a constant that appears
# nowhere else, which is what Marker finds and replaces. Keep the constant
# small enough to stay an immediate: a large one is placed in module data and
# the instruction then reads it from mp, which is harder to recognise and
# would move if anything else were added.
#
# The "#0" and "#10" program-counter comments limbo emits are dropped here.
# They are only comments, but they would be wrong the moment a line is
# inserted, and a wrong comment is worse than none.
#
wrapper(): list of string
{
	return
	"\tload\t0(mp),$0,152(fp)" ::
	"\tmovw\t$0,80(fp)" ::
	"\tmovw\t$0,96(fp)" ::
	"\tmovw\t$0,104(fp)" ::
	"\tmovw\t$0,112(fp)" ::
	"\tmovw\t$0,120(fp)" ::
	"\tmovw\t$0,128(fp)" ::
	"\tmovw\t$0,136(fp)" ::
	"\tmovw\t$0,144(fp)" ::
	Marker ::
	"\tframe\t$1,160(fp)" ::
	"\tmovp\t8(mp),64(160(fp))" ::
	"\tmovw\t80(fp),72(160(fp))" ::
	"\tmovw\t96(fp),80(160(fp))" ::
	"\tmovw\t104(fp),88(160(fp))" ::
	"\tmovw\t112(fp),96(160(fp))" ::
	"\tmovw\t120(fp),104(160(fp))" ::
	"\tmovw\t128(fp),112(160(fp))" ::
	"\tmovw\t136(fp),120(160(fp))" ::
	"\tmovw\t144(fp),128(160(fp))" ::
	"\tlea\t88(fp),32(160(fp))" ::
	"\tmcall\t160(fp),$0,152(fp)" ::
	"\tret\t" ::
	"\tentry\t0, 2" ::
	"\tdesc\t$0,24,\"e0\"" ::
	"\tdesc\t$1,136,\"0080\"" ::
	"\tdesc\t$2,168,\"00c010\"" ::
	"\tvar\t@mp,24" ::
	"\tstring\t@mp+0,\"$Sys\"" ::
	"\tstring\t@mp+8,\"%d %d %d %d %d %d %d %d\\n\"" ::
	"\tmodule\tDisrepl" ::
	"\tlink\t2,0,0x4244b354,\"init\"" ::
	"\tldts\t@ldt,1" ::
	"\tword\t@ldt+0,1" ::
	"\text\t@ldt+8,0xac849033,\"print\"" ::
	"\tsource\t\"disrepl\"" ::
	nil;
}

# The frame offsets the wrapper leaves free, in the order they are printed.
# These are not contiguous and cannot be guessed: 88(fp) is the argument area
# the print builds in, 152(fp) holds a pointer to the Sys module, and anything
# from 160(fp) up is the frame of the call itself. Writing to those breaks the
# program in ways that have nothing to do with what was typed, so the safe
# offsets are listed rather than described as a range.
Scratch: con "80 96 104 112 120 128 136 144";

session: list of string;		# typed instructions, most recent first
broken := 0;			# the program does not currently assemble
ctxt: ref Draw->Context;

# All input arrives on one channel, from one reader process. That is what lets
# the prompt and the interrupt be the same source: while a program runs the
# main loop is sitting in an alt on this channel, and when it is not, it is
# reading from it for the next command. Two readers on one file descriptor
# would race for lines.
#
# A nil on the channel is end of input.
lines: chan of string;
pending: list of string;	# arrived during a run, not yet acted on

readerpid := -1;

# The reader runs until it is killed. It has to be killed rather than left to
# finish, because emu keeps running while any process is alive: a reader
# blocked on a read that will never complete keeps the whole session up after
# the prompt has gone away, which looks exactly like a hang.
reader(in: ref Iobuf, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		l := in.gets('\n');
		lines <-= l;
		if(l == nil)
			break;
	}
}

# gets() returns the line with its newline still on it, and leading space is
# not meaningful at this prompt. Trimming in one place because doing it in two
# and forgetting one is exactly what made "!" fail to match while a program was
# running.
trim(l: string): string
{
	l = str->drop(l, " \t");
	while(len l > 0 && (l[len l-1] == ' ' || l[len l-1] == '\t' || l[len l-1] == '\n'))
		l = l[0:len l-1];
	return l;
}

# Next command, from what arrived during a run before anything new.
nextline(): string
{
	if(pending != nil){
		l := hd pending;
		pending = tl pending;
		return l;
	}
	return <-lines;
}

usage()
{
	fprint(sys->fildes(2), "usage: disrepl\n");
	raise "fail:usage";
}

help()
{
	print("Type Dis instructions; each is added to the program and the whole\n");
	print("program is run again. Scratch words, printed after every run:\n");
	print("\n");
	sc := Scratch;
	for(i := 0; i < 8; i++){
		(f, rest) := str->splitl(sc, " ");
		sc = str->drop(rest, " ");
		print("    s%d is %s(fp)\n", i, f);
	}
	print("\n");
	print("    .list     show the program so far\n");
	print("    .drop     remove the last instruction\n");
	print("    .clear    start again\n");
	print("    .asm      show the assembly that would be run\n");
	print("    .dump     disassemble the module that was built\n");
	print("    .help     this\n");
	print("    .quit     leave\n");
	print("    !         stop a program that is still running\n");
	print("\n");
	print("For example:  movw $6,80(fp)\n");
	print("              movw $7,96(fp)\n");
	print("              mulw 80(fp),96(fp),104(fp)      s2 becomes 42\n");
	print("\n");
	print("A branch target is a bare label name, not $name:\n");
	print("\n");
	print("              movw $5,96(fp)\n");
	print("              top: addw 80(fp),96(fp),80(fp)\n");
	print("              subw $1,96(fp),96(fp)\n");
	print("              bnew 96(fp),$0,top              s0 becomes 15\n");
	print("\n");
	print("Writing $top instead assembles - as the immediate 0 - and branches\n");
	print("to the first instruction, which loops forever. A program that runs\n");
	print("longer than %d seconds is stopped and the line is not kept.\n", Limitms/1000);
}

# The session, oldest first.
program(): list of string
{
	r: list of string;
	for(l := session; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Wrapper with the marker line replaced by the typed instructions. An empty
# session leaves the marker in place rather than removing it, so the program
# is always well formed - the marker is an ordinary instruction that happens
# to be recognisable.
assembly(): list of string
{
	out: list of string;
	body := program();
	for(w := wrapper(); w != nil; w = tl w){
		if(hd w == Marker && body != nil){
			for(b := body; b != nil; b = tl b)
				out = hd b :: out;
			continue;
		}
		out = hd w :: out;
	}
	r: list of string;
	for(l := out; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

writes(path: string, lines: list of string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sprint("create %s: %r", path);
	for(; lines != nil; lines = tl lines){
		s := hd lines + "\n";
		b := array of byte s;
		if(sys->write(fd, b, len b) != len b)
			return sprint("write %s: %r", path);
	}
	return nil;
}

# Load a command and call it, turning both a failed load and a raised
# exception into a string. An assembly error must not end the session: the
# whole point is to type something wrong and see what happens.
runcmd(path: string, argv: list of string): string
{
	c := load Command path;
	if(c == nil)
		return sprint("load %s: %r", path);
	err: string;
	{
		c->init(ctxt, argv);
	} exception e {
	"*" =>
		err = e;
	}
	return err;
}

Killed:	con "did not finish";
Intr:	con "interrupted";

runner(c: Command, argv: list of string, pidc: chan of int, done: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	err: string;
	{
		c->init(ctxt, argv);
	} exception e {
	"*" =>
		err = e;
	}
	done <-= err;
}

ticker(ms: int, pidc: chan of int, c: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

# The user's own program, run in its own process so it can be stopped.
#
# Three ways it ends, and all three are arms of one alt: it finishes, the user
# interrupts it, or it runs past the time limit.
#
# The interrupt matters because the obvious alternative does not exist here.
# On this platform emu wires SIGINT to cleanexit (emu/MacOSX/os.c), so typing
# the host's interrupt character kills the whole emulator, session and all -
# it cannot be used to stop one Dis program. So the interrupt is a line of
# input, "!", handled as a channel like everything else.
#
# The time limit is the backstop for when nobody is watching. Without one the
# first mistyped branch ends the session: "bnew 96(fp),$0,$top" assembles -
# $top is an immediate, not a label reference - and jumps to instruction zero,
# which re-runs the whole program forever. That is not hypothetical; it is what
# the first loop typed here did.
#
# Input that arrives while a program runs and is NOT the interrupt is queued,
# not acted on. That is what makes a piped session behave: its next command
# would otherwise arrive during the run and look like an interrupt.
timedrun(path: string, argv: list of string): string
{
	c := load Command path;
	if(c == nil)
		return sprint("load %s: %r", path);
	# Buffered, all of them, so that whichever of these processes loses the
	# race can still complete its send and exit. With unbuffered channels
	# the ticker for a program that finished early blocks on a send nobody
	# will ever receive, and one such process is left behind per line
	# typed. Nothing visible goes wrong until the session ends, at which
	# point emu waits for those processes and the whole thing appears to
	# hang.
	pidc := chan[1] of int;
	done := chan[1] of string;
	spawn runner(c, argv, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	tpidc := chan[1] of int;
	spawn ticker(Limitms, tpidc, tc);
	tpid := <-tpidc;
	for(;;){
		# Whichever arm wins, the other two processes are killed. A
		# ticker left to run out its sleep is not a leak but it does
		# delay the session's exit by the whole limit, which looks like
		# a hang for no reason.
		alt {
		err := <-done =>
			kill(tpid);
			return err;
		l := <-lines =>
			if(l != nil && trim(l) == "!"){
				kill(pid);
				kill(tpid);
				return Intr;
			}
			pending = append(pending, l);
		<-tc =>
			kill(pid);
			return Killed;
		}
	}
}

append(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: append(tl l, s);
}

shutdown()
{
	if(readerpid >= 0)
		kill(readerpid);
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		fprint(fd, "kill");
}

build(): string
{
	sys->remove(Dfile);
	if((e := writes(Sfile, assembly())) != nil)
		return e;
	if((e = runcmd("/dis/asm.dis", "asm" :: Sfile :: nil)) != nil)
		return "assembler: " + e;
	# asm names its output after the input file, in the current directory.
	if(sys->stat(Dfile).t0 < 0)
		return sprint("the assembler produced no %s", Dfile);
	return nil;
}

# Returns 1 if the program assembled and finished, whatever it did along the
# way.
#
# The distinction matters for what happens to the line just typed. A line that
# does not assemble is not Dis at all, so it is taken back out: leaving it in
# would make every later line fail with the same error, which is a bad way to
# treat a typo. A line that assembles and then raises is kept, because it is a
# real instruction doing a real thing, and the user may well have meant to see
# exactly that - but it will raise again on every subsequent run, so the
# warning says so and points at .drop.
run(): int
{
	e := build();
	broken = e != nil;
	if(e != nil){
		print("%s\n", e);
		return 0;
	}
	e = timedrun(Dfile, "disrepl" :: nil);
	if(e == Killed){
		print("stopped after %d seconds - it did not finish\n", Limitms/1000);
		return 0;
	}
	if(e == Intr){
		print("interrupted\n");
		return 0;
	}
	if(e != nil)
		print("%s\n", e);
	return 1;
}

init(c: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	if(bufio == nil || str == nil){
		print("disrepl: load: %r\n");
		raise "fail:load";
	}
	if(tl argv != nil)
		usage();
	ctxt = c;

	# These are loaded on every line, so say so once and by name rather
	# than reporting it as a failure to run the first instruction typed.
	for(t := "/dis/asm.dis" :: "/dis/disdump.dis" :: nil; t != nil; t = tl t)
		if(sys->stat(hd t).t0 < 0){
			print("disrepl: %s is missing - mk it in appl/cmd\n", hd t);
			raise "fail:no tools";
		}

	# asm writes its output beside the input, by name, in the working
	# directory - so the working directory has to be the one Dfile names.
	if(sys->chdir("/tmp") < 0){
		print("disrepl: chdir /tmp: %r\n");
		raise "fail:no /tmp";
	}

	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(in == nil){
		print("disrepl: cannot read stdin: %r\n");
		raise "fail:stdin";
	}
	lines = chan of string;
	rp := chan of int;
	spawn reader(in, rp);
	readerpid = <-rp;

	print("dis repl - .help for help, .quit to leave, ! to interrupt\n");
	for(;;){
		print("dis> ");
		line := nextline();
		if(line == nil){
			print("\n");
			shutdown();
			return;
		}
		line = trim(line);
		if(line == nil)
			continue;

		case line {
		"!" =>
			# Only meaningful while something is running.
			print("(nothing running)\n");
		".quit" or ".q" =>
			shutdown();
			return;
		".help" or ".h" or "?" =>
			help();
		".list" or ".l" =>
			n := 0;
			for(l := program(); l != nil; l = tl l)
				print("%3d  %s\n", n++, str->drop(hd l, "\t"));
			if(n == 0)
				print("(nothing yet)\n");
		".drop" =>
			if(session == nil)
				print("(nothing to drop)\n");
			else {
				print("dropped: %s\n", str->drop(hd session, "\t"));
				session = tl session;
				if(!run())
					print("the program no longer assembles - " +
						"drop more, or add what it needs\n");
			}
		".clear" =>
			session = nil;
			broken = 0;
			print("cleared\n");
		".asm" =>
			for(l := assembly(); l != nil; l = tl l)
				print("%s\n", hd l);
		".dump" =>
			de := build();
			if(de == nil)
				de = runcmd("/dis/disdump.dis",
					"disdump" :: Dfile :: nil);
			if(de != nil)
				print("%s\n", de);
		* =>
			if(len line > 0 && line[0] == '.'){
				print("no such command: %s (.help)\n", line);
				continue;
			}
			# Instructions are tab-indented, which is what the
			# assembler's grammar expects of a statement.
			# Only blame the new line if the program assembled
			# before it. Otherwise the breakage is something
			# already in the session - most easily arrived at by
			# dropping a label another line still branches to -
			# and taking the new line out would leave the user
			# unable to add the very line that fixes it.
			wasbroken := broken;
			session = "\t" + line :: session;
			if(!run() && !wasbroken){
				session = tl session;
				print("not added\n");
			}
		}
	}
}
