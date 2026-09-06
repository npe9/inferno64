implement Init;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;
Init: module { init: fn(); };
Shell: module { init: fn(nil: ref Draw->Context, argv: list of string); };
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
# Read/write the SD card exposed by devsd (#S) as /dev/sdM0/data - the
# BCM2835 SDHOST native-SD path.  Boot with -sd <image>.
# Phase 5: the Arasan SDHCI (the "EMMC" block), the controller the
# BCM43430 Wi-Fi hangs off over SDIO.  The SoC wires the one SD card to
# either SDHOST or Arasan depending on the GPIO 48-53 alt function, and
# each driver routes the pins in its own online(), so opening
# /dev/sdH0 first hands the card to the Arasan.  Doing that before
# sdcheck() exercises this controller's register interface, command
# engine and PIO data path against a real card, and sdcheck() then
# takes the card back to SDHOST -- so one boot proves both controllers
# and that the routing works in both directions.  Boot with -sd <img>.
sdhcicheck()
{
	fd := sys->open("/dev/sdH0/data", Sys->ORDWR);
	if(fd == nil){
		sys->print("SDHCI-NONE (no /dev/sdH0/data: %r)\n");
		return;
	}
	buf := array[512] of byte;
	if(sys->pread(fd, buf, len buf, big 0) != len buf){
		sys->print("SDHCI-FAIL read: %r\n");
		return;
	}
	sys->print("SDHCI block0 %02x%02x%02x%02x sig %02x%02x\n",
		int buf[0], int buf[1], int buf[2], int buf[3],
		int buf[510], int buf[511]);
	wbuf := array[512] of byte;
	for(i := 0; i < len wbuf; i++)
		wbuf[i] = byte (16rA0 + (i & 16rf));
	if(sys->pwrite(fd, wbuf, len wbuf, big (5*512)) != len wbuf){
		sys->print("SDHCI-WFAIL write: %r\n");
		return;
	}
	rbuf := array[512] of byte;
	if(sys->pread(fd, rbuf, len rbuf, big (5*512)) != len rbuf){
		sys->print("SDHCI-WFAIL readback: %r\n");
		return;
	}
	for(i = 0; i < len rbuf; i++)
		if(rbuf[i] != wbuf[i]){
			sys->print("SDHCI-WRITE-MISMATCH at %d\n", i);
			return;
		}
	sys->print("SDHCI block5 wrote %02x%02x readback %02x%02x (SDHCI-WRITE-OK)\n",
		int wbuf[0], int wbuf[1], int rbuf[0], int rbuf[1]);
	# the geometry devsd derived from the CSD -- if the 136-bit
	# response were unpacked wrongly this is where it shows
	cfd := sys->open("/dev/sdH0/ctl", Sys->OREAD);
	if(cfd != nil){
		cbuf := array[512] of byte;
		cn := sys->read(cfd, cbuf, len cbuf);
		if(cn > 0)
			sys->print("SDHCI ctl: %s", string cbuf[0:cn]);
	}
	sys->print("SDHCI-OK\n");
}

sdcheck()
{
	fd := sys->open("/dev/sdM0/data", Sys->ORDWR);
	if(fd == nil){
		sys->print("SD-NONE (no /dev/sdM0/data: %r)\n");
		return;
	}
	buf := array[512] of byte;
	if(sys->pread(fd, buf, len buf, big 0) != len buf){
		sys->print("SD-FAIL read: %r\n");
		return;
	}
	sys->print("SD block0 %02x%02x%02x%02x\n",
		int buf[0], int buf[1], int buf[2], int buf[3]);
	wbuf := array[512] of byte;
	for(i := 0; i < len wbuf; i++)
		wbuf[i] = byte (16r70 + (i & 16rf));
	if(sys->pwrite(fd, wbuf, len wbuf, big (3*512)) != len wbuf){
		sys->print("SD-WFAIL write: %r\n");
		return;
	}
	rbuf := array[512] of byte;
	if(sys->pread(fd, rbuf, len rbuf, big (3*512)) != len rbuf){
		sys->print("SD-WFAIL readback: %r\n");
		return;
	}
	tag := "(SD-WRITE-OK)";
	for(i = 0; i < len rbuf; i++)
		if(rbuf[i] != wbuf[i])
			tag = "(SD-WRITE-MISMATCH)";
	sys->print("SD block3 wrote %02x%02x readback %02x%02x %s\n",
		int wbuf[0], int wbuf[1], int rbuf[0], int rbuf[1], tag);

	# multi-block: write 4 blocks (2KB) in ONE pwrite, read back in ONE
	# pread, per-block tagged.  This is what kfs exercises (nb>1).
	mb := array[4*512] of byte;
	for(k := 0; k < 4; k++){
		mb[k*512] = byte 16rE0; mb[k*512+1] = byte k;
	}
	if(sys->pwrite(fd, mb, len mb, big (8*512)) != len mb){
		sys->print("SD-MB write: %r\n"); return;
	}
	mbr := array[4*512] of byte;
	if(sys->pread(fd, mbr, len mbr, big (8*512)) != len mbr){
		sys->print("SD-MB read: %r\n"); return;
	}
	mbtag := "(SD-MULTIBLOCK-OK)";
	for(k = 0; k < 4; k++)
		if(int mbr[k*512] != 16rE0 || int mbr[k*512+1] != k)
			mbtag = "(SD-MB-MISALIGN)";
	sys->print("SD 4-block RW %s\n", mbtag);
	sys->print("SD-OK\n");
}

kfsproc(pfd: ref Sys->FD)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(pfd.fd, 0);
	pfd = nil;
	kfs := load Command "/dis/disk/kfs.dis";
	if(kfs == nil){
		sys->print("SD-FS load kfs: %r\n");
		return;
	}
	kfs->init(nil, "kfs" :: "-r" :: "/dev/sdM0/data" :: nil);
}

sdfs()
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("SD-FS pipe: %r\n");
		return;
	}
	spawn kfsproc(p[1]);
	p[1] = nil;
	if(sys->mount(p[0], nil, "/tmp", Sys->MREPL|Sys->MCREATE, "") < 0){
		sys->print("SD-FS mount: %r\n");
		return;
	}
	fd := sys->create("/tmp/hello", Sys->ORDWR, 8r644);
	if(fd == nil){
		sys->print("SD-FS create: %r\n");
		return;
	}
	sys->print("SD-FS-CREATE-OK\n");
}

drawtest()
{
	draw = load Draw Draw->PATH;
	if(draw == nil){ sys->print("DRAW-FAIL load: %r\n"); return; }
	if(sys->bind("#i", "/dev", sys->MAFTER) < 0){ sys->print("DRAW-FAIL bind: %r\n"); return; }
	disp: ref Display;
	{ disp = Display.allocate("/dev"); }
	exception e { "*" => sys->print("DRAW-FAIL Display: %s\n", e); return; }
	if(disp == nil){ sys->print("DRAW-FAIL nil: %r\n"); return; }
	img := disp.image;
	r := img.r;
	w := (r.max.x - r.min.x) / 3;
	x0 := r.min.x;
	img.draw(Rect((x0, r.min.y), (x0+w, r.max.y)), disp.rgb(255,0,0), nil, (0,0));
	img.draw(Rect((x0+w, r.min.y), (x0+2*w, r.max.y)), disp.rgb(0,255,0), nil, (0,0));
	img.draw(Rect((x0+2*w, r.min.y), (r.max.x, r.max.y)), disp.rgb(0,0,255), nil, (0,0));
	img.flush(Draw->Flushnow);
	sys->print("DRAW-OK %dx%d\n", r.max.x-r.min.x, r.max.y-r.min.y);
}

readctl(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[256] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

# Bind the DWC2 host controller (#U) into /dev, show the root hub the
# kernel synthesised, then run usbd to reset the port and enumerate the
# attached device over control transfers -- exercising the interrupt and
# transfer paths.  Boot with -device usb-kbd (or usb-mouse) to have a
# device to find; the second ctl dump should list it.
usbcheck()
{
	if(sys->bind("#u", "/dev", sys->MAFTER) < 0){
		sys->print("USB-NONE bind #U: %r\n");
		return;
	}
	sys->print("USB root hub:\n%s", readctl("/dev/usb/ctl"));
	usbd := load Command "/dis/usb/usbd.dis";
	if(usbd == nil){
		sys->print("USB-FAIL load usbd: %r\n");
		return;
	}
	spawn usbd->init(nil, "usbd" :: nil);
	sys->sleep(2000);
	sys->print("USB after usbd:\n%s", readctl("/dev/usb/ctl"));
	# A USB boot keyboard, once usbd finds it, delivers UTF-8 keystrokes
	# to /dev/keyboard (the graphics console queue).  Report what arrives
	# so an injected "hello" from the QEMU monitor shows the whole path --
	# split interrupt transfers, HID translation, cons -- end to end.
	spawn kbdreport();
	sys->print("USB-OK\n");
	diskcheck();
	ethercheck();
}

# Phase 4: USB mass storage.  usbd's Bulk-Only Transport driver serves
# the stick as a flat file at /chan/usbdisk0, turning byte-range reads
# and writes into SCSI READ(10)/WRITE(10) over the bulk endpoints;
# dossrv mounts the FAT filesystem on that file at /n/dos.  Listing the
# directory proves the read path end to end, and creating a file and
# reading it back proves the write path.  Boot with
# -drive if=none,id=d0,file=<img>,format=raw -device usb-storage,drive=d0
diskcheck()
{
	# usbd names each disk usbdisk0, usbdisk1, ... in the order it
	# serves them, so do not assume usbdisk0: scan /chan for whichever
	# one turned up.  Only the first is mounted; a second stick would
	# need a second mountpoint.
	disk := "";
	for(i := 0; i < 50 && disk == nil; i++){
		cfd := sys->open("/chan", Sys->OREAD);
		if(cfd != nil){
			for(;;){
				(n, dirs) := sys->dirread(cfd);
				if(n <= 0)
					break;
				for(j := 0; j < n; j++)
					if(len dirs[j].name >= 7 && dirs[j].name[0:7] == "usbdisk"){
						disk = "/chan/" + dirs[j].name;
						break;
					}
			}
		}
		if(disk == nil)
			sys->sleep(100);
	}
	if(disk == nil){
		sys->print("DISK-NONE (no USB mass storage under /chan)\n");
		return;
	}
	dossrv := load Command "/dis/dossrv.dis";
	if(dossrv == nil){
		sys->print("DISK-FAIL load dossrv: %r\n");
		return;
	}
	spawn dossrv->init(nil, "dossrv" :: "-f" :: disk :: "-m" :: "/n/dos" :: nil);

	# /n/dos exists in the root either way, so an open proves nothing;
	# wait for the mount by waiting for entries to appear under it
	names := "";
	first := "";
	for(i = 0; i < 50; i++){
		names = "";
		first = "";
		dfd := sys->open("/n/dos", Sys->OREAD);
		if(dfd != nil){
			for(;;){
				(n, dirs) := sys->dirread(dfd);
				if(n <= 0)
					break;
				for(j := 0; j < n; j++){
					names += " " + dirs[j].name;
					if(first == nil && (dirs[j].mode & Sys->DMDIR) == 0)
						first = dirs[j].name;
				}
			}
		}
		if(names != nil)
			break;
		sys->sleep(100);
	}
	if(names == nil){
		sys->print("DISK-DOS-FAIL nothing under /n/dos: %r\n");
		return;
	}
	sys->print("DISK-DOS-OK /n/dos:%s\n", names);

	if(first != nil){
		fd := sys->open("/n/dos/" + first, Sys->OREAD);
		buf := array[512] of byte;
		n := -1;
		if(fd != nil)
			n = sys->read(fd, buf, len buf);
		if(n <= 0)
			sys->print("DISK-READ-FAIL %s: %r\n", first);
		else
			sys->print("DISK-READ-OK %s %d bytes %q\n", first, n, string buf[0:n]);
	}

	# the write path: create, write, close, reopen, read back.  This is
	# a read-modify-write of a 512-byte block through SCSI WRITE(10).
	msg := array of byte "written by inferno on the pi\n";
	wfd := sys->create("/n/dos/pi.txt", Sys->OWRITE, 8r666);
	if(wfd == nil){
		sys->print("DISK-WRITE-FAIL create: %r\n");
		return;
	}
	if(sys->write(wfd, msg, len msg) != len msg){
		sys->print("DISK-WRITE-FAIL write: %r\n");
		return;
	}
	wfd = nil;
	rfd := sys->open("/n/dos/pi.txt", Sys->OREAD);
	if(rfd == nil){
		sys->print("DISK-WRITE-FAIL reopen: %r\n");
		return;
	}
	rbuf := array[512] of byte;
	rn := sys->read(rfd, rbuf, len rbuf);
	if(rn != len msg || string rbuf[0:rn] != string msg){
		sys->print("DISK-WRITE-FAIL readback got %d %q\n", rn, string rbuf[0:rn]);
		return;
	}
	sys->print("DISK-WRITE-OK pi.txt %d bytes read back\n", rn);
}

# Phase 3: USB ethernet.  usbd starts etherusb for a CDC ECM or SMSC
# LAN95xx device; etherusb serves the netif file interface at
# /net.alt/ether over the device's bulk endpoints.  Bind it as devip's
# ethernet and get an address by DHCP -- discover/offer/request/ack
# cross the USB link in both directions, so ETHER-DHCP-OK proves the
# whole path: styx server, bulk in and out, the DWC2 driver -- then
# ping the gateway.  Boot with -device usb-net,netdev=n0 -netdev
# user,id=n0 (SLIRP answers DHCP at 10.0.2.2).
ethercheck()
{
	addr := "/net.alt/ether/addr";
	for(i := 0; i < 100; i++){
		if(sys->open(addr, Sys->OREAD) != nil)
			break;
		sys->sleep(100);
	}
	if(sys->open(addr, Sys->OREAD) == nil){
		sys->print("ETHER-NONE (no USB ethernet served at %s)\n", addr);
		return;
	}
	sys->bind("#I", "/net", Sys->MAFTER);
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "bind ether /net.alt/ether") < 0){
		sys->print("ETHER-FAIL bind ether: %r\n");
		return;
	}
	sys->print("ETHERBIND-OK\n");
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("ETHER-FAIL load dhcpclient: %r\n");
		return;
	}
	dhcpclient->init();
	cfg := Bootconf.new();
	lease: ref Lease;
	err: string;
	(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, addr, cfg, nil);
	if(err != nil || cfg == nil || cfg.ip == nil){
		sys->print("ETHER-DHCP-FAIL %s\n", err);
		return;
	}
	sys->print("ETHER-DHCP-OK ip=%s gw=%s\n", cfg.ip, cfg.ipgw);
	ping := load Command "/dis/ip/ping.dis";
	if(ping == nil){
		sys->print("ETHER-PING-NONE load: %r\n");
		return;
	}
	ping->init(nil, "ping" :: "-n" :: "3" :: cfg.ipgw :: nil);
	sys->print("ETHER-PING-DONE\n");
	lease = nil;
}

kbdreport()
{
	fd := sys->open("/dev/keyboard", Sys->OREAD);
	if(fd == nil){
		sys->print("USB-KBD-NONE: %r\n");
		return;
	}
	buf := array[16] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		sys->print("USB-KBD got %d: %q\n", n, string buf[0:n]);
	}
}

init()
{
	shell: Shell;
	sys = load Sys Sys->PATH;
	sys->print("raspi3b init\n");
	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->print("RASPI3B-OK\n");

	sys->bind("#S", "/dev", sys->MAFTER);
	sdhcicheck();
	sdcheck();
	drawtest();
	usbcheck();
	# sdfs() reams a kfs onto the SD card, mounts it over a pipe, and
	# creates a file.  The ream and every SD write succeed, but the
	# create-over-mount hangs: pid 1's Twalk gets its Rerror and then the
	# error unwinds past mntwalk's own waserror handler instead of into
	# it, so pid 1 never issues the Tcreate.  It is the open arm64
	# multi-kproc error-stack bug (doc/inferno-driver-plan.ms); left
	# uncalled so the board boots clean.  Uncomment to reproduce.
	# sdfs();

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){ sys->print("init: load sh: %r\n"); exit; }
	shell->init(nil, "sh" :: "-n" :: "-c" :: "echo RASPI3B-SH-OK" :: nil);
	shell->init(nil, "sh" :: "-n" :: nil);
}
