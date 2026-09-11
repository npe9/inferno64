implement Cloudinit;

#
# Bring a cloud instance's network up, and make the metadata service
# reachable.
#
# The shipped pc64 kernel configured no networking at all: it reaches a
# shell with an ether device present, /net/iproute empty and no address
# on any interface, so nothing can be dialled.  On a rented machine that
# is most of the point of the machine.
#
# Three steps, none of which a shell can do.  "#I" has to be bound into
# /net before there is an IP stack at all.  /net/ipifc/clone allocates
# an interface and the binding only lasts while that file descriptor
# stays open, so the fd must be held by the process that configures it.
# And the provider's metadata service lives on a link-local address --
# 169.254.169.254 on both Compute Engine and EC2 -- which no DHCP lease
# covers, so it needs an explicit host route through the lease's
# gateway.  Without that route cloudfs(4) mounts, lists its files and
# fails every read with "no route", which is exactly what it did on the
# first instance this was tried on.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Cloudinit: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

MDADDR: con "169.254.169.254";

#
# Routes, each bound to the interface by name.
#
# /net/iproute's "add" takes an optional fifth field naming an
# interface, and a route carrying one is used as it stands:
# routefindipifc() returns r->ifc without asking whether the gateway is
# reachable.  A route without one has to find its interface, and
# findipifc() will only match an interface whose subnet contains the
# gateway -- so on a network that hands out a /32 with the gateway
# outside it, every gateway route is unusable and the machine can reach
# nothing.  That is Compute Engine: 10.128.0.25/32 with gateway
# 10.128.0.1, which is exactly how Linux's client is expected to behave
# too, installing a link-scope route to the gateway before a default
# route through it.
#
# findipifcstr() takes either an interface number or an address on it,
# so this names the interface by the address the lease just gave us.
#
routes(ip: string, gw: string, mdaddr: string, verbose: int)
{
	rfd := sys->open("/net/iproute", Sys->OWRITE);
	if(rfd == nil){
		sys->print("cloudinit: /net/iproute: %r\n");
		return;
	}
	# the gateway itself, reachable directly on this interface
	add(rfd, gw, "255.255.255.255", gw, ip, verbose);
	# everything else through it
	add(rfd, "0.0.0.0", "0.0.0.0", gw, ip, verbose);
	# and the metadata service, which no lease covers
	if(mdaddr != nil)
		add(rfd, mdaddr, "255.255.255.255", gw, ip, verbose);
}

add(rfd: ref Sys->FD, targ, mask, gw, ifc: string, verbose: int)
{
	if(sys->fprint(rfd, "add %s %s %s %s", targ, mask, gw, ifc) < 0)
		sys->print("cloudinit: route %s: %r\n", targ);
	else if(verbose)
		sys->print("cloudinit: route %s %s via %s on %s\n", targ, mask, gw, ifc);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	verbose := 0;
	mdaddr := MDADDR;
	nifc := 3;

	arg->init(argv);
	arg->setusage("cloudinit [-v] [-m metadataip] [-n nifc]");
	while((o := arg->opt()) != 0)
		case o {
		'v' =>	verbose = 1;
		'm' =>	mdaddr = arg->earg();
		'n' =>	nifc = int arg->earg();
		* =>	arg->usage();
		}

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->fprint(sys->fildes(2), "cloudinit: cannot load %s: %r\n",
			Dhcpclient->PATH);
		return;
	}
	dhcpclient->init();
	sys->bind("#I", "/net", Sys->MAFTER);

	for(i := 0; i < nifc; i++){
		ether := sys->sprint("/net/ether%d", i);
		if(sys->open(ether + "/addr", Sys->OREAD) == nil)
			continue;
		cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
		if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0){
			if(verbose)
				sys->print("cloudinit: %s: ipifc: %r\n", ether);
			continue;
		}
		(cfg, nil, err) := dhcpclient->dhcp("/net", cfd, ether + "/addr",
			Bootconf.new(), nil);
		if(err != nil || cfg == nil || cfg.ip == nil){
			if(verbose)
				sys->print("cloudinit: %s: dhcp: %s\n", ether, err);
			continue;
		}
		#
		# The lease is deliberately not released.  The dev
		# configuration's DEVTEST releases it because it is testing
		# the exchange and wants the next boot to repeat it; an
		# instance that means to keep its address must not.
		#
		sys->print("cloudinit: %s ip %s gw %s\n", ether, cfg.ip, cfg.ipgw);
		if(cfg.ipgw != nil)
			routes(cfg.ip, cfg.ipgw, mdaddr, verbose);
		return;
	}
	sys->fprint(sys->fildes(2), "cloudinit: no interface took a lease\n");
}
