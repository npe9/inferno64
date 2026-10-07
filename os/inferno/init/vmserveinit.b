implement Init;
#
# The hypervisor host as a Styx server (doc/genesize-plan.ms, phase 10):
# #H, #Q and #$ bound into /dev, a DHCP lease on the first Ethernet that
# answers, ndb/cs for the announcement, and the whole namespace exported
# on tcp!*!5640.  A machine that mounts it makes, configures, starts,
# stops and inspects virtual machines here with ordinary file
# operations -- there is no other control protocol.
#
# No authentication (-A): this is the bench's.  A real host answers
# with its keyring, as every other Inferno service does.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->bind("#Q", "/dev", Sys->MAFTER);
	sys->bind("#$", "/dev", Sys->MAFTER);
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#I", "/net", Sys->MAFTER);
	for(i := 0; i < 3; i++)
		sys->bind(sys->sprint("#l%d", i), "/net", Sys->MAFTER);
	sys->print("VMSERVE: start\n");

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("VMSERVE: FAIL dhcpclient: %r\n");
		return;
	}
	dhcpclient->init();
	up := 0;
	for(i = 0; i < 3 && !up; i++){
		ether := sys->sprint("/net/ether%d", i);
		if(sys->open(ether + "/addr", Sys->OREAD) == nil)
			continue;
		cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
		if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0)
			continue;
		(cfg, nil, err) := dhcpclient->dhcp("/net", cfd, ether + "/addr", Bootconf.new(), nil);
		if(err == nil && cfg != nil && cfg.ip != nil){
			sys->print("VMSERVE: %s %s\n", ether, cfg.ip);
			up = 1;
		}
	}
	if(!up){
		sys->print("VMSERVE: FAIL no network\n");
		return;
	}
	sh := load Command "/dis/sh.dis";
	if(sh == nil){
		sys->print("VMSERVE: FAIL sh: %r\n");
		return;
	}
	# the shell does not return once the listener runs, so beside it
	spawn sh->init(nil, "sh" :: "-c" :: "ndb/cs; styxlisten -A 'tcp!*!5640' export /; echo VMSERVE: listening" :: nil);
	# the interface's transmit checksum offload at work, if its driver
	# counts it (ether82598's "txck"): the frames whose TCP or UDP
	# checksum the hardware put in
	for(;;){
		sys->sleep(30*1000);
		fd := sys->open("/net/ether0/ifstats", Sys->OREAD);
		if(fd == nil)
			continue;
		buf := array[4096] of byte;
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			continue;
		(nil, l) := sys->tokenize(string buf[0:n], "\n");
		for(; l != nil; l = tl l)
			if(len hd l > 5 && (hd l)[0:5] == "txck ")
				sys->print("VMSERVE: ether0 %s\n", hd l);
	}
}
