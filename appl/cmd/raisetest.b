implement Raisetest;

# Diagnostic for an open bug, not a smoke test: does a Limbo raise from
# inside a spawned Prog reach its own immediately-surrounding exception
# handler?  Under hosted emu it does -- this exact bytecode prints
# "received caught" and exits cleanly.  On a native os/inferno kernel
# (confirmed on riscv64/virt and pc64) it does not: the marker right
# before the raise prints, and the whole VM goes silent forever, never
# reaching the handler one call frame up.  A second shape (raise/catch
# in the SAME, non-spawned Prog) fails differently there -- a hard
# "panic: exception" from os/inferno/virt/trap.c instead of silence --
# so this is not spawn-boundary-specific; no native raise/catch shape
# tried so far has worked.  Traced as far as os/inferno/port/dis.c's
# vmachine()/handler()/propex() (byte-identical to emu/port/dis.c's
# equivalents) without finding the difference; genuinely open past
# there.  Same shape as appl/cmd/dossrv.b's init()/os/inferno/init/
# virtinit.b's startfs(), which is what surfaced this.  See
# doc/inferno-ports.ms.

include "sys.m";
	sys: Sys;
include "draw.m";

Raisetest: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

victim()
{
	sys->fprint(sys->fildes(2), "raisetest: victim about to raise\n");
	raise "fail:test";
}

spawned(c: chan of string)
{
	{
		victim();
	} exception e {
	"*" =>
		sys->fprint(sys->fildes(2), "raisetest: spawned caught %s\n", e);
		c <-= "caught";
		exit;
	}
	c <-= "no-exception";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->fprint(sys->fildes(2), "raisetest: init start\n");
	c := chan of string;
	spawn spawned(c);
	r := <-c;
	sys->fprint(sys->fildes(2), "raisetest: received %s\n", r);
}
