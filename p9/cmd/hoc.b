implement Command;

# hoc(1) - a thin dispatcher, not the translation itself. hoc6's own
# 1950-line Limbo port (parser, evaluator, symbol table, and the
# compile()/eval()/setvar()/getvar()/symbol()/reset() library entry
# points a caller like appl/danby uses directly, bypassing the
# argv/stdin-driven REPL below entirely) now lives at appl/lib/hoc.b,
# module/hoc.m - a real, ordinary Inferno library, not scoped to this
# p9/ tree, since appl/danby (real userspace) needs to include/load it
# without the `bind -a /p9/dis /dis` this tree's own commands are
# otherwise kept behind (see doc/plan9-port.md, "Rule: Limbo-native,
# in a separate bindable tree" - that rule is about a COMMAND shadowing
# a real userspace tool in $dis; a library shadows nothing, and living
# in appl/lib is what lets real userspace depend on it at all).
#
# This file exists only so `hoc` still runs as a real Plan 9 workalike
# command from inside this p9/ tree's own bound namespace, exactly as
# before the move - it loads the real implementation and forwards
# init()'s own argv straight through, matching every other thin
# dispatcher in this tree (e.g. appl/danby/basketball.b calling into
# appl/temple/trajectory.b).

include "sys.m";
	sys: Sys;
include "hoc.m";
	hoc: Hoc;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	hoc = load Hoc Hoc->PATH;
	if(hoc == nil){
		sys->fprint(sys->fildes(2), "hoc: cannot load %s: %r\n", Hoc->PATH);
		raise "fail:load";
	}
	hoc->init(ctxt, argv);
}
