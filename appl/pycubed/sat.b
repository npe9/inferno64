implement Sat;

#
# The satellite state, as a server.
#
# lib/pycubed.py keeps this as attributes on one object that every task
# reads and writes directly, with a lock (lib/tasko's managed resource)
# around the parts that matter.  Here one process owns it and answers on
# a channel, which is the same guarantee without the lock: requests are
# serialised because there is one server, and a task that fails does not
# leave the state half-written.
#
# The counters and flags marked NVM in pycubed.m are the ones the Python
# keeps in non-volatile memory through lib/bitflags.py, so that a reboot
# does not lose the boot count or the fact that the battery went low.
# Nothing here writes them to NVM: that is the microcontroller's flash,
# and it wants the driver phase 2 of the plan describes.  They are kept
# in memory and the boundary is named here rather than hidden.
#

include "sys.m";
	sys: Sys;
include "pycubed.m";

init()
{
	sys = load Sys Sys->PATH;
}

flagname(s: ref State, name: string): int
{
	case name {
	"lowbatt" =>	return s.flowbatt;
	"lowbtout" =>	return s.flowbtout;
	"critical" =>	return s.fcritical;
	}
	return 0;
}

setflag(s: ref State, name: string, v: int)
{
	case name {
	"lowbatt" =>	s.flowbatt = v;
	"lowbtout" =>	s.flowbtout = v;
	"critical" =>	s.fcritical = v;
	}
}

bump(s: ref State, name: string, by: int)
{
	case name {
	"boot" =>	s.cboot += by;
	"stateerr" =>	s.cstateerr += by;
	"gsresp" =>	s.cgsresp += by;
	}
}

# A copy, so a task holding the reply cannot reach into the server's own
# state after the fact.
copy(s: ref State): ref State
{
	n := ref State;
	*n = *s;
	return n;
}

server(req: chan of ref Req)
{
	s := ref State(
		4000,		# vbatt, mV: the stand-in driver's starting value
		3600,		# vlowbatt, mV: lib/pycubed.py's 3.6V threshold
		0,		# boottime, filled in below
		1,		# cboot: this boot
		0, 0,		# cstateerr, cgsresp
		0, 0, 0,	# flowbatt, flowbtout, fcritical
		"normal"
	);
	s.boottime = sys->millisec()/1000;

	for(;;){
		r := <-req;
		case r.kind {
		Get =>		;
		Bump =>		bump(s, r.name, r.val);
		Setflag =>	setflag(s, r.name, r.val);
		Setpower =>	s.powermode = r.name;
		Setvbatt =>	s.vbatt = r.val;
		}
		r.reply <-= copy(s);
	}
}
