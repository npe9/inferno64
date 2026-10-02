implement Init;

#
# pc64devinit: a console-only init that reports what the storage,
# USB and Ethernet drivers copied from 9front found, then idles.
# Built into ipc64dev from the pc64dev configuration; not the
# shipped init (that is disinit).  See doc/inferno-ports.ms.
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

msixcycle()
{
	# "config switch off spec N" runs the controller's disable(),
	# which for sdnvme releases both of its MSI-X vectors -- masking
	# each and turning the capability off behind the last -- and then
	# frees the SDev.  sdnvme has no probe() function, so devsd cannot
	# put it back afterwards; what this checks is that the release
	# happens and that the device really goes away.
	cfd := sys->open("#S/sdctl", Sys->OWRITE);
	if(cfd == nil){
		sys->print("DEVTEST: MSIX-DETACH: no #S/sdctl: %r\n");
		return;
	}
	off := array of byte "config switch off spec N";
	if(sys->write(cfd, off, len off) < 0){
		sys->print("DEVTEST: MSIX-DETACH-FAIL switch off: %r\n");
		return;
	}
	cfd = nil;
	if(sys->open("/dev/sdN0/data", Sys->OREAD) != nil){
		sys->print("DEVTEST: MSIX-DETACH-FAIL /dev/sdN0/data still opens\n");
		return;
	}
	sys->print("DEVTEST: MSIX-DETACH-OK sdN gone after switch off\n");

	# recorded rather than checked: devsd's "switch on" needs an
	# SDifc probe(), and sdnvme's is nil, so this always fails.
	cfd = sys->open("#S/sdctl", Sys->OWRITE);
	if(cfd != nil){
		on := array of byte "config switch on spec N type nvme";
		if(sys->write(cfd, on, len on) < 0)
			sys->print("DEVTEST: MSIX-REATTACH not available: %r\n");
		else
			sys->print("DEVTEST: MSIX-REATTACH accepted\n");
	}
}

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
	sys->bind("#l0", "/net", Sys->MAFTER);
	sys->bind("#l1", "/net", Sys->MAFTER);
	sys->bind("#l2", "/net", Sys->MAFTER);
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
	# sdC0 and sdD0 are the legacy IDE channels, which is what a Xen
	# HVM domain's device model and QEMU's i440fx machine present.
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: "/dev/sdM0/data" ::
		"/dev/sdC0/data" :: "/dev/sdD0/data" :: nil; l != nil; l = tl l){
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

	# MSI-X detach and re-attach: "config switch off spec N" runs the
	# controller's disable(), which for sdnvme releases both of its
	# MSI-X vectors and turns the capability off behind the last one;
	# switching it back on re-enables them.  Reading the sector again
	# is what says the second enable actually programmed the table.
	msixcycle();

	# audio: the codec's status, then a second of silence written to it
	sys->bind("#A", "/dev", Sys->MAFTER);
	sys->print("DEVTEST: /dev/audiostat:\n%s", readfile("/dev/audiostat"));
	sys->print("DEVTEST: /dev/volume:\n%s", readfile("/dev/volume"));
	afd := sys->open("/dev/audio", Sys->OWRITE);
	if(afd == nil)
		sys->print("DEVTEST: /dev/audio: cannot open: %r\n");
	else {
		silence := array[44100*4] of { * => byte 0 };
		nw := sys->write(afd, silence, len silence);
		if(nw < 0)
			sys->print("DEVTEST: /dev/audio write: %r\n");
		else
			sys->print("DEVTEST: /dev/audio: wrote %d bytes of silence\n", nw);
		afd = nil;
	}

	# usb: the controller and root hub list
	sys->print("DEVTEST: /dev/usb/ctl:\n%s", readfile("/dev/usb/ctl"));

	# ethernet: the virtio 1.0 interface's statistics
	sys->print("DEVTEST: /net/ether1/ifstats:\n%s", readfile("/net/ether1/ifstats"));

	# network: DHCP over every Ethernet interface in turn, so each
	# driver's transmit and receive paths are exercised, not just the
	# first one's
	sys->bind("#I", "/net", Sys->MAFTER);
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil)
		sys->print("DEVTEST: DHCP-FAIL load: %r\n");
	else {
		dhcpclient->init();
		for(i := 0; i < 3; i++){
			ether := sys->sprint("/net/ether%d", i);
			if(sys->open(ether + "/addr", Sys->OREAD) == nil)
				continue;
			cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
			if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0){
				sys->print("DEVTEST: %s DHCP-FAIL ipifc: %r\n", ether);
				continue;
			}
			cfg := Bootconf.new();
			lease: ref Lease;
			err: string;
			(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, ether + "/addr", cfg, nil);
			if(err != nil || cfg == nil || cfg.ip == nil){
				sys->print("DEVTEST: %s DHCP-FAIL %s\n", ether, err);
				# what the driver saw, so a failure can be told
				# apart: nothing sent, sent and nothing back, or
				# received and dropped
				sys->print("DEVTEST: %s/stats:\n%s", ether, readfile(ether + "/stats"));
				sys->print("DEVTEST: %s/ifstats:\n%s", ether, readfile(ether + "/ifstats"));
			}
			else {
				if(lease != nil)
					lease.release();
				sys->print("DEVTEST: %s DHCP-OK ip=%s gw=%s\n", ether, cfg.ip, cfg.ipgw);
				# one lease per boot: a second dhcp on the same
				# stack fails with "address in use", so a boot
				# tests the first interface that answers; boot
				# once per NIC to test each driver
				break;
			}
			cfd = nil;
		}
	}

	# usb: start usbd and let it enumerate what hangs off the root hubs;
	# then report every key and pointer event the drivers deliver, so
	# a QEMU monitor can inject some and this log shows them arriving
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#m", "/dev", Sys->MAFTER);
	usbd := load Command "/dis/usb/usbd.dis";
	if(usbd == nil)
		sys->print("DEVTEST: usbd: %r\n");
	else {
		spawn usbd->init(nil, "usbd" :: "-d" :: nil);
		sys->sleep(6000);
		sys->print("DEVTEST: reading /dev/usb/ctl after usbd\n");
		sys->print("DEVTEST: /dev/usb/ctl after usbd:\n%s", readfile("/dev/usb/ctl"));
		spawn keyreport();
		spawn ptrreport();
	}

	sys->print("DEVTEST: done\n");
	for(;;)
		sys->sleep(10000);
}

keyreport()
{
	fd := sys->open("/dev/keyboard", Sys->OREAD);
	if(fd == nil){
		sys->print("DEVTEST: /dev/keyboard: %r\n");
		return;
	}
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		sys->print("DEVTEST: key %q\n", string buf[0:n]);
	}
}

ptrreport()
{
	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil){
		sys->print("DEVTEST: /dev/pointer: %r\n");
		return;
	}
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		sys->print("DEVTEST: pointer %s\n", string buf[0:n]);
	}
}
