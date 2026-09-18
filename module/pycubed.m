#
# The PyCubed beep-sat mission logic, ported from Python.
#
# The Python it comes from is one object, cubesat, that every task
# reaches into for both state and hardware, and a cooperative scheduler
# (lib/tasko) that exists because CircuitPython has one thread.  Inferno
# has processes and channels, so the scheduler is not ported, and the
# shared object becomes a server: one process owns the state and answers
# requests on a channel, so a task that dies does not take the state
# with it.  See doc/pycubed-plan.ms phase 4.
#

Sat: module
{
	PATH:	con "/dis/pycubed/sat.dis";

	# What the satellite knows about itself.  In the Python this is
	# fields on cubesat, some of them backed by non-volatile memory.
	State: adt {
		vbatt:		int;	# millivolts
		vlowbatt:	int;	# millivolts, the low-power threshold
		boottime:	int;	# seconds, from sys->millisec at start
		cboot:		int;	# NVM: boot count
		cstateerr:	int;	# NVM: state-machine errors
		cgsresp:	int;	# NVM: ground-station responses
		flowbatt:	int;	# NVM flag: low battery seen
		flowbtout:	int;	# NVM flag: low-battery timeout taken
		fcritical:	int;	# NVM flag: critical
		powermode:	string;	# "normal" or "minimum"
	};

	# A request to the state server.  Get returns the whole State,
	# which is cheap and saves a request kind per field; the rest are
	# the mutations the tasks actually make.
	Get, Bump, Setflag, Setpower, Setvbatt: con iota;

	Req: adt {
		kind:	int;
		name:	string;	# which counter or flag
		val:	int;
		reply:	chan of ref State;
	};

	init:		fn();
	server:		fn(req: chan of ref Req);
	flagname:	fn(s: ref State, name: string): int;
};
