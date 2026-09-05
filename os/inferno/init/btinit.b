implement Init;

#
# btinit: the Bluetooth bench inside a native kernel.  It binds what
# the stack needs, decides how to reach a controller, and runs
# btbench(4), which does the rest through files.
#
# The transport comes from the kernel's own boot configuration --
#
#	-append 'console=0 bt=tcp!10.0.2.2!5555'
#
# -- and otherwise from what the board has: the second serial port if
# there is one, which is the H4 uart path a real UART-attached
# controller takes, and a network connection to the build host if
# there is not.  pc64 has two uarts and takes the first; the riscv64
# and arm64 virt boards have one and it is the console, so they take
# the second.  Nothing above the transport can tell the difference.
#
# Built into ipc64bt and ivirtbt from the pc64bt and virtbt
# configurations; neither is the shipped init.  See btfs(4) and
# doc/inferno-ports.ms.
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

Hostmodel:	con "tcp!10.0.2.2!5555";	# the bench host, over QEMU's user networking

init()
{
	sys = load Sys Sys->PATH;

	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#e", "/env", Sys->MAFTER);
	sys->bind("#t", "/dev", Sys->MAFTER);
	sys->bind("#l0", "/net", Sys->MAFTER);
	sys->bind("#I", "/net", Sys->MAFTER);
	sys->print("BT: start\n");

	spec := config("bt");
	if(spec == nil){
		if(sys->open("/dev/eia1", Sys->OREAD) != nil)
			spec = "/dev/eia1";
		else
			spec = Hostmodel;
	}
	sys->print("BT: controller %s\n", spec);

	# a controller across the network needs an address first
	if(len spec >= 4 && spec[0:4] == "tcp!" && !network()){
		sys->print("BT: no network, cannot reach the controller\n");
		idle();
	}

	bench := load Command "/dis/bt/btbench.dis";
	if(bench == nil)
		sys->print("BT: cannot load /dis/bt/btbench.dis: %r\n");
	else
		bench->init(nil, "btbench" :: spec :: nil);
	idle();
}

#
# a boot argument.  setconfenv() in os/inferno/pc/bootargs.c puts
# every configuration entry whose name does not begin with * into
# the environment device, so a name=value on the kernel command line
# arrives as a file in #e.  A board that has no such thing simply
# has no file, and the caller falls back to what the hardware is.
#
config(name: string): string
{
	fd := sys->open("/env/" + name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == 0))
		s = s[0:len s - 1];
	if(s == "")
		return nil;
	return s;
}

#
# a DHCP lease from QEMU's user networking, which is what makes the
# host reachable
#
network(): int
{
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("BT: dhcpclient: %r\n");
		return 0;
	}
	dhcpclient->init();
	for(i := 0; i < 3; i++){
		ether := sys->sprint("/net/ether%d", i);
		if(sys->open(ether + "/addr", Sys->OREAD) == nil)
			continue;
		cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
		if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0){
			sys->print("BT: %s ipifc: %r\n", ether);
			continue;
		}
		cfg := Bootconf.new();
		lease: ref Lease;
		err: string;
		(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, ether + "/addr", cfg, nil);
		if(err != nil || cfg == nil || cfg.ip == nil){
			sys->print("BT: %s dhcp: %s\n", ether, err);
			continue;
		}
		if(lease != nil)
			lease.release();
		sys->print("BT: %s ip %s gw %s\n", ether, cfg.ip, cfg.ipgw);
		return 1;
	}
	return 0;
}

idle()
{
	for(;;)
		sys->sleep(10000);
}
