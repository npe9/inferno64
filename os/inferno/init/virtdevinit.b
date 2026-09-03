implement Init;

#
# virtdevinit: pc64devinit.b for the riscv64 virt board - a
# console-only init that reports what the PCI drivers shared with
# pc64 (NVMe, virtio 1.0, xHCI) found on this board's ECAM PCIe,
# runs usbd and reports the input events it delivers, then idles.
# Built with INIT=virtdevinit; the shipped init is virtinit.  See
# doc/inferno-ports.ms.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Screen, Rect, Point: import draw;
include "sh.m";
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
	for(l := "/dev/sdN0/data" :: "/dev/sdF0/data" :: "/dev/sdM0/data" :: nil; l != nil; l = tl l){
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
			if(err != nil || cfg == nil || cfg.ip == nil)
				sys->print("DEVTEST: %s DHCP-FAIL %s\n", ether, err);
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
		spawn usbd->init(nil, "usbd" :: nil);
		sys->sleep(6000);
		sys->print("DEVTEST: /dev/usb/ctl after usbd:\n%s", readfile("/dev/usb/ctl"));
		usbdiskcheck();
		spawn keyreport();
		spawn ptrreport();
	}

	gputest();

	sys->print("DEVTEST: done\n");
	for(;;)
		sys->sleep(10000);
}

gputest()
{
	# fill the screen so flushmemscreen drives virtio-gpu; a screendump
	# then shows the colour.  Three bands so the picture is unambiguous.
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("DEVTEST: GPU no draw module\n");
		return;
	}
	sys->bind("#i", "/dev", Sys->MAFTER);
	display := Display.allocate("/dev");
	if(display == nil){
		sys->print("DEVTEST: GPU Display.allocate: %r\n");
		return;
	}
	scr := display.image;
	red := display.color(Draw->Red);
	grn := display.color(Draw->Green);
	blu := display.color(Draw->Blue);
	r := scr.r;
	third := (r.max.y - r.min.y) / 3;
	scr.draw(Rect((r.min.x, r.min.y), (r.max.x, r.min.y+third)), red, nil, (0,0));
	scr.draw(Rect((r.min.x, r.min.y+third), (r.max.x, r.min.y+2*third)), grn, nil, (0,0));
	scr.draw(Rect((r.min.x, r.min.y+2*third), (r.max.x, r.max.y)), blu, nil, (0,0));
	scr.flush(Draw->Flushnow);
	sys->print("DEVTEST: GPU-DRAW-OK\n");
}

usbdiskcheck()
{
	# usbd exports a mounted USB stick as /chan/usbdiskN; mount its
	# FAT with dossrv and read the marker the host planted.
	if(sys->open("/chan/usbdisk0", Sys->OREAD) == nil){
		sys->print("DEVTEST: no /chan/usbdisk0 (no usb-storage attached)\n");
		return;
	}
	# /tmp is devroot's static read-only dir; mount a memfs there so
	# dossrv has a writable mount point (same as virtinit's tmpmount).
	memfs := load Command "/dis/memfs.dis";
	if(memfs != nil)
		memfs->init(nil, "memfs" :: "-m" :: "4194304" :: "/tmp" :: nil);
	sys->create("/tmp/usb", Sys->OREAD, Sys->DMDIR|8r755);
	spawn startfs2("/dis/dossrv.dis",
		"dossrv" :: "-f" :: "/chan/usbdisk0" :: "-m" :: "/tmp/usb" :: nil);
	sys->sleep(1500);
	fd := sys->open("/tmp/usb/marker.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("DEVTEST: USB-FS-FAIL open: %r\n");
		return;
	}
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n >= 9 && string buf[0:9] == "USB-FS-OK")
		sys->print("DEVTEST: USB-FS-OK (FAT on USB mass storage)\n");
	else
		sys->print("DEVTEST: USB-FS-FAIL content %d\n", n);
}

startfs2(path: string, args: list of string)
{
	cmd := load Command path;
	if(cmd == nil){
		sys->print("DEVTEST: USB-FS-FAIL load %s: %r\n", path);
		return;
	}
	cmd->init(nil, args);
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
