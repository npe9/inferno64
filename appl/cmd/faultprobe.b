implement Command;

#
# Fault on purpose, so that a harness can be calibrated.
#
# A test that watches for failures is only as good as its ability to see one,
# and in this tree that is not obvious: wm(1) intercepts Limbo's print into its
# own Log window, so a great deal that a program says while wm is running never
# reaches whatever started it. A run that reports no faults may mean there were
# none, or may mean the watcher was reading the wrong stream, and those are not
# distinguishable from the log.
#
# So: run this under whatever harness is in question and see whether the
# harness notices. If it does not, the harness cannot be trusted to notice a
# real one either.
#
#	faultprobe		# dereference nil
#	faultprobe -b		# index past the end of an array
#	faultprobe -e		# raise an exception nobody handles
#
# All three are broken in the sense progexit() means: emu prints
# "[module] Broken: pid N ..." through C, not through Limbo, so the question
# being answered is whether that line arrives.
#
include "sys.m";
	sys: Sys;
	print: import sys;
include "draw.m";
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

T: adt {
	x: int;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		print("faultprobe: load: %r\n");
		raise "fail:load";
	}
	how := 'n';
	arg->init(argv);
	arg->setusage("faultprobe [-b] [-e]");
	while((o := arg->opt()) != 0)
		case o {
		'b' =>	how = 'b';
		'e' =>	how = 'e';
		* =>	arg->usage();
		}

	print("faultprobe: about to fault\n");
	case how {
	'b' =>
		a := array[2] of int;
		i := 5;
		a[i] = 1;			# index past the end
		print("faultprobe: still here, which is wrong: %d\n", a[0]);
	'e' =>
		raise "faultprobe: an exception nobody handles";
	* =>
		t: ref T;
		t.x = 1;			# dereference nil
		print("faultprobe: still here, which is wrong: %d\n", t.x);
	}
}
