implement Register;

#
# register: join (and leave) a registry(4).
#
# By default the registration lasts as long as this process: registry
# strikes the entry off when the file descriptor returned by its new
# file is closed, which happens when the process exits or is killed, or
# when a connection to a remote registry drops.  That is the join and
# leave the system database needs.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Register: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		error(sys->sprint("can't load %s: %r", Arg->PATH));

	regmnt := "/mnt/registry";
	persist := 0;
	remove := 0;
	arg->init(args);
	arg->setusage("ndb/register [-m regmnt] [-p] [-r] svcname [attr value]...");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	regmnt = arg->earg();
		'p' =>	persist = 1;
		'r' =>	remove = 1;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args == nil)
		arg->usage();
	arg = nil;

	svcname := hd args;
	args = tl args;
	if(remove){
		if(args != nil)
			error("-r takes only a service name");
		if(sys->remove(regmnt+"/"+svcname) < 0)
			error(sys->sprint("can't remove %s/%s: %r", regmnt, svcname));
		return;
	}

	s := sys->sprint("%q", svcname);
	for(; args != nil; args = tl args){
		if(tl args == nil)
			error("attributes must be given in pairs");
		s += sys->sprint(" %q %q", hd args, hd tl args);
		args = tl args;
	}
	if(persist)
		s += " persist 1";

	fd := sys->open(regmnt+"/new", Sys->OWRITE);
	if(fd == nil)
		error(sys->sprint("can't open %s/new: %r", regmnt));
	if(sys->fprint(fd, "%s", s) < 0)
		error(sys->sprint("can't register %s: %r", svcname));
	if(persist)
		return;

	#
	# hold the descriptor.  The entry lives exactly as long as this
	# process does.
	#
	sys->print("%s\n", svcname);
	for(;;)
		sys->sleep(60*1000);
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "register: %s\n", s);
	raise "fail:error";
}
