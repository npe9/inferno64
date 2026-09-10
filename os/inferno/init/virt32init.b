implement Init;

#
# Console bring-up for os/inferno/virt32 (riscv32).  Copied from
# armv7minit.b: same shape (serial console, no storage, no network,
# no display), and needed for more than a shape match.
#
# virt32's own board config said INIT=virtinit, the same name
# riscv64/virt already uses.  os/inferno/init/ is shared across every
# board; virtinit.b/.dis already existed on disk, built for virt
# (riscv64, DISWORD=8), and `mk`'s dependency check only compares
# timestamps against virtinit.b -- it has no way to know a same-named
# .dis needs rebuilding for a different word size.  virt32 silently
# loaded that word-size-mismatched .dis (its own Type descriptors
# decoded with tsz/tnp scaled for 8-byte words), corrupting the very
# first module it read: libinterp's own heap-tracking code caught
# pointer-tagged words getting overwritten with plain non-pointer
# integers, and newmp() then crashed dereferencing one of those
# integers as a pointer.  Found live via QEMU/lldb, traced back
# through mkroot's own /osinit.dis -> os/inferno/init/$INIT.dis
# resolution.  virtinit.b's own module list (draw/tk/tkclient/wmsrv)
# wouldn't have worked on this board's device list either way, so a
# genuinely separate init, not a rebuild of the shared one, is the
# fix -- both the word-size collision and the missing-module problem
# at once.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Init: module
{
	init:	fn();
};

Shell: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Command: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init()
{
	shell: Shell;

	sys = load Sys Sys->PATH;
	sys->print("virt32 init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	netcheck();

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: there is no host /lib/sh/profile to read
	sys->print("VIRT32-INIT-OK\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}

#
# The network, over the virtio-mmio NIC this board links as of the same
# round.  Deliberately the same shape as virtinit.b's own ipcheck(): a
# DHCP exchange and then a ping to the gateway DHCP hands back.  A full
# DISCOVER/OFFER/REQUEST/ACK needs the NIC to transmit, to receive and
# to take its PLIC interrupt, so DHCP-OK is proof the driver works and
# not just that it probed; the ping then proves the ip stack above it
# on a 32-bit Dis word, which is the part this board is here to test.
#
netcheck()
{
	cfd: ref Sys->FD;
	cfg: ref Bootconf;
	lease: ref Lease;
	c := chan of string;
	s: string;
	e: string;

	sys->bind("#l", "/net", Sys->MREPL);
	sys->bind("#I", "/net", Sys->MAFTER);

	(ok, nil) := sys->stat("/net/ether0/addr");
	if(ok < 0){
		sys->print("ETHER32-NONE no /net/ether0\n");
		return;
	}
	sys->print("ETHER32-OK\n");

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("DHCP32-FAIL load: %r\n");
		return;
	}
	dhcpclient->init();

	cfd = sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("IP32-FAIL clone: %r\n");
		return;
	}
	if(sys->fprint(cfd, "bind ether /net/ether0") < 0){
		sys->print("IP32-FAIL bind: %r\n");
		return;
	}

	cfg = Bootconf.new();
	(cfg, lease, e) = dhcpclient->dhcp("/net", cfd, "/net/ether0/addr", cfg, nil);
	if(e != nil || cfg == nil || cfg.ip == nil){
		if(e == nil)
			e = "no address";
		sys->print("DHCP32-FAIL %s\n", e);
		return;
	}
	# Stop the renewer: it can removecfg out from under the ping.
	if(lease != nil)
		lease.release();
	dhcpclient->applycfg("/net", cfd, cfg);
	sys->print("ip=%s ipmask=%s ipgw=%s iplease=%d\n",
		cfg.ip, cfg.ipmask, cfg.ipgw, cfg.lease);
	sys->print("DHCP32-OK\n");
	cfd = nil;

	# Let NOW pass sendarp's one-second rate limit before the ping.
	sys->sleep(1500);

	gw := cfg.ipgw;
	if(gw == nil)
		gw = "10.0.2.2";
	spawn pingfs(c, "/dis/ip/ping.dis",
		"ping" :: "-n" :: "3" :: "-i" :: "200" :: "-q" :: gw :: nil);
	# 20s, not the 10s riscv64/virt's own ipcheck() uses.  This board
	# has no 64-bit registers: every vlong the ip stack touches is a
	# call into libkern's vlrt, so the same work takes longer here,
	# and at 10s the ping missed its deadline about one boot in ten
	# with the echoes and replies all on the wire.
	tp := chan of int;
	spawn iptimer(tp, 20000);
	alt {
	s = <-c =>
		if(s != nil){
			sys->print("IP32-FAIL ping\n");
			return;
		}
	<-tp =>
		sys->print("IP32-FAIL ping timeout\n");
		return;
	}
	sys->print("IP32-OK\n");
}

pingfs(c: chan of string, file: string, args: list of string)
{
	fs := load Command file;
	if(fs == nil){
		sys->print("can't load %s: %r\n", file);
		c <-= "load failed";
		return;
	}
	{
		fs->init(nil, args);
	} exception {
	"*" =>
		c <-= "failed";
		exit;
	}
	c <-= nil;
}

# A deadline re-checked against millisec() rather than slept out in one
# go, and stepped at 50ms rather than 0: the same watchdog virtinit.b
# uses, and for the same reason -- a sleep(0) spinner starves the very
# thing it is timing.
iptimer(t: chan of int, ms: int)
{
	t0: int;

	t0 = sys->millisec();
	while(sys->millisec() - t0 < ms)
		sys->sleep(50);
	t <-= 1;
}
