implement Init;

#
# Serial console bring-up for QEMU -M sifive_u, plus a DHCP check over
# the SoC's Cadence GEM ethernet to prove the NIC moves packets.
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

# DHCP over the GEM on QEMU user-net (SLIRP).  A full DHCP exchange
# (DISCOVER/OFFER/REQUEST/ACK) needs the NIC to both transmit and
# receive with working interrupts, so DHCP-OK proves the driver end to
# end, not just that it probed.
ipcheck()
{
	cfd: ref Sys->FD;
	cfg: ref Bootconf;
	lease: ref Lease;
	e: string;

	sys->bind("#l", "/net", Sys->MREPL);
	sys->bind("#I", "/net", Sys->MAFTER);

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("DHCP-FAIL load: %r\n");
		return;
	}
	dhcpclient->init();

	cfd = sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("IP-FAIL clone: %r\n");
		return;
	}
	if(sys->fprint(cfd, "bind ether /net/ether0") < 0){
		sys->print("IP-FAIL bind: %r\n");
		return;
	}

	cfg = Bootconf.new();
	(cfg, lease, e) = dhcpclient->dhcp("/net", cfd, "/net/ether0/addr", cfg, nil);
	if(e != nil || cfg == nil || cfg.ip == nil){
		if(e == nil)
			e = "no address";
		sys->print("DHCP-FAIL %s\n", e);
		return;
	}
	if(lease != nil)
		lease.release();
	dhcpclient->applycfg("/net", cfd, cfg);
	sys->print("ip=%s ipmask=%s ipgw=%s\n", cfg.ip, cfg.ipmask, cfg.ipgw);
	sys->print("DHCP-OK\n");
}

# Read blocks off the SD card exposed by devsd (#S) as /dev/sdM0/data,
# to prove the SD-over-SPI block device works through the file interface.
# Boot with -sd <image> whose block 0 and block 1 carry known markers.
sdcheck()
{
	fd := sys->open("/dev/sdM0/data", Sys->OREAD);
	if(fd == nil){
		sys->print("SD-NONE (no /dev/sdM0/data: %r)\n");
		return;
	}
	buf := array[512] of byte;
	if(sys->pread(fd, buf, len buf, big 0) != len buf){
		sys->print("SD-FAIL block0: %r\n");
		return;
	}
	sys->print("SD block0 %02x%02x%02x%02x\n",
		int buf[0], int buf[1], int buf[2], int buf[3]);
	if(sys->pread(fd, buf, len buf, big 512) != len buf){
		sys->print("SD-FAIL block1: %r\n");
		return;
	}
	sys->print("SD block1 %02x%02x%02x%02x\n",
		int buf[0], int buf[1], int buf[2], int buf[3]);
	sys->print("SD-OK\n");
}

init()
{
	shell: Shell;

	sys = load Sys Sys->PATH;
	sys->print("sifiveu init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	sys->print("SIFIVEU-OK\n");

	sys->bind("#S", "/dev", sys->MAFTER);
	sdcheck();

	ipcheck();

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){
		sys->print("init: load sh: %r\n");
		exit;
	}
	# -n: skip host /lib/sh/profile
	shell->init(nil, "sh" :: "-n" :: "-c" ::
		"load std; echo HELLO-FROM-SH; echo SIFIVEU-SH-OK" :: nil);
	sys->print("interactive sh (load std)\n");
	shell->init(nil, "sh" :: "-n" :: nil);
}
