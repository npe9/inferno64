implement Init;

#
# pc64devinit: a console-only init that reports what the storage,
# USB and Ethernet drivers copied from 9front found, then idles.
# Built into ipc64dev from the pc64dev configuration; not the
# shipped init (that is disinit).  See doc/inferno-ports.ms.
#

include "sys.m";
	sys: Sys;
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Init: module
{
	init:	fn();
};

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "cannot open: " + sys->sprint("%r");
	buf := array[4096] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

init()
{
	sys = load Sys Sys->PATH;

	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#S", "/dev", Sys->MAFTER);
	sys->bind("#u", "/dev", Sys->MAFTER);
	sys->bind("#l1", "/net", Sys->MAFTER);
	sys->print("DEVTEST: start\n");

	# storage: every sd unit's ctl file
	fd := sys->open("/dev", Sys->OREAD);
	if(fd != nil){
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++){
				nm := d[i].name;
				if(len nm >= 3 && nm[0:2] == "sd" && d[i].mode & Sys->DMDIR)
					sys->print("DEVTEST: /dev/%s/ctl:\n%s", nm, readfile("/dev/" + nm + "/ctl"));
			}
		}
	}

	# storage: the first sector of the NVMe and virtio 1.0 disks,
	# which the host wrote a recognisable line into before boot
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: nil; l != nil; l = tl l){
		dfd := sys->open(hd l, Sys->OREAD);
		if(dfd == nil){
			sys->print("DEVTEST: %s: cannot open: %r\n", hd l);
			continue;
		}
		sec := array[512] of byte;
		n := sys->read(dfd, sec, len sec);
		e := 0;
		while(e < n && sec[e] != byte 0 && sec[e] != byte '\n')
			e++;
		sys->print("DEVTEST: %s sector 0 (%d bytes): %s\n", hd l, n, string sec[0:e]);
	}

	# usb: the controller and root hub list
	sys->print("DEVTEST: /dev/usb/ctl:\n%s", readfile("/dev/usb/ctl"));

	# ethernet: the virtio 1.0 interface's statistics
	sys->print("DEVTEST: /net/ether1/ifstats:\n%s", readfile("/net/ether1/ifstats"));

	# network: DHCP over the virtio 1.0 interface, ether1
	sys->bind("#I", "/net", Sys->MAFTER);
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil)
		sys->print("DEVTEST: DHCP-FAIL load: %r\n");
	else {
		dhcpclient->init();
		cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
		if(cfd == nil || sys->fprint(cfd, "bind ether /net/ether1") < 0)
			sys->print("DEVTEST: DHCP-FAIL ipifc: %r\n");
		else {
			cfg := Bootconf.new();
			lease: ref Lease;
			err: string;
			(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, "/net/ether1/addr", cfg, nil);
			if(err != nil || cfg == nil || cfg.ip == nil)
				sys->print("DEVTEST: DHCP-FAIL %s\n", err);
			else {
				if(lease != nil)
					lease.release();
				sys->print("DEVTEST: DHCP-OK over ether1 ip=%s gw=%s\n", cfg.ip, cfg.ipgw);
			}
		}
	}

	sys->print("DEVTEST: done\n");
	for(;;)
		sys->sleep(10000);
}
