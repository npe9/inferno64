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

	# Four blocks in one request, which the driver now sends as a
	# single CMD25/CMD18 with auto-CMD12 rather than four CMD24/CMD17
	# pairs.  Each block is stamped with its own index, so a
	# multi-block transfer that streams the right bytes to the wrong
	# offsets -- the characteristic way a block count or an
	# auto-stop gets it wrong -- shows up as a misalignment rather
	# than as correct-looking data.  Blocks 12-15, clear of block 5
	# above and of the SD path's 8-11.
	mb := array[4*512] of byte;
	for(i = 0; i < len mb; i++)
		mb[i] = byte (16rC0 + (i & 16rf));
	for(k := 0; k < 4; k++)
		mb[k*512+1] = byte k;
	if(sys->pwrite(fd, mb, len mb, big (12*512)) != len mb){
		sys->print("SDHCI-MB write: %r\n");
		return;
	}
	mbr := array[4*512] of byte;
	if(sys->pread(fd, mbr, len mbr, big (12*512)) != len mbr){
		sys->print("SDHCI-MB read: %r\n");
		return;
	}
	mbtag := "(SDHCI-MULTIBLOCK-OK)";
	for(k = 0; k < 4; k++)
		if(int mbr[k*512] != 16rC0 || int mbr[k*512+1] != k)
			mbtag = "(SDHCI-MB-MISALIGN)";
	sys->print("SDHCI 4-block RW %s\n", mbtag);
	# the geometry devsd derived from the CSD -- if the 136-bit
	# response were unpacked wrongly this is where it shows
	cfd := sys->open("/dev/sdH0/ctl", Sys->OREAD);
	cbuf := array[512] of byte;
	cn := 0;
	if(cfd != nil)
		cn = sys->read(cfd, cbuf, len cbuf);
	if(cn <= 0){
		sys->print("SDHCI-CAP-NONE cannot read /dev/sdH0/ctl: %r\n");
		return;
	}
	sys->print("SDHCI ctl: %s", string cbuf[0:cn]);
	# not reaching SDHCI-OK is the point: an unconfirmed capacity
	# must not be hidden inside a pass two lines later
	if(capcheck("SDHCI", fd, string cbuf[0:cn]) == 0)
		return;
	sys->print("SDHCI-OK\n");
}

# The geometry above is a number the card reported about itself, and
# printing it is not the same as testing it.  A CSD unpacked wrongly,
# or a model whose CSD disagrees with the image behind it, gives a
# capacity that looks entirely plausible until something writes near
# the end of the card and the data goes nowhere -- which is silent.
#
# So make the claim falsifiable at its only observable edge: the last
# sector the card says it has must read, and the sector after it must
# not.  Both halves matter.  A capacity that is too large passes the
# first only if the backing store is really that big; a capacity that
# is too small, or a devsd that does not range-check at all, fails the
# second.
#
# Both controllers get this, and that is the other half of its value.
# sdhostbcm.c and sdhcibcm.c unpack the same card's 136-bit CSD
# independently, so if the two report different capacities for one
# card, one of them is unpacking it wrongly and the boot says so.
capcheck(tag: string, fd: ref Sys->FD, ctl: string): int
{
	nsec := big 0;
	(nil, lines) := sys->tokenize(ctl, "\n");
	for(; lines != nil; lines = tl lines){
		(nt, toks) := sys->tokenize(hd lines, " \t");
		if(nt >= 2 && hd toks == "geometry")
			nsec = big (hd tl toks);
	}
	if(nsec <= big 0){
		sys->print("%s-CAP-NONE the ctl file reports no geometry\n", tag);
		return 0;
	}
	b := array[512] of byte;
	if(sys->pread(fd, b, len b, (nsec-big 1)*big 512) != len b){
		sys->print("%s-CAP-FAIL sector %bd, the last the card claims, does not read: %r\n", tag, nsec-big 1);
		return 0;
	}
	if(sys->pread(fd, b, len b, nsec*big 512) == len b){
		sys->print("%s-CAP-FAIL a read at sector %bd, one past the claimed end, succeeded\n", tag, nsec);
		return 0;
	}
	sys->print("%s-CAP-OK sector %bd reads and %bd does not; the claimed capacity is the real one\n", tag, nsec-big 1, nsec);
	return 1;
}

# Phase 7: /dev/random, now fed by the BCM2835 hardware RNG rather
# than the tick-seeded LCG randomvirtarm64.c falls back to.  Printing
# the bytes is the only check worth making from here: they must differ
# from one boot to the next, which the LCG's boot-seeded sequence did
# not reliably do.
rngcheck()
{
	fd := sys->open("/dev/random", Sys->OREAD);
	if(fd == nil){
		sys->print("RANDOM-NONE: %r\n");
		return;
	}
	buf := array[16] of byte;
	if(sys->read(fd, buf, len buf) != len buf){
		sys->print("RANDOM-FAIL read: %r\n");
		return;
	}
	s := "";
	zero := 1;
	for(i := 0; i < len buf; i++){
		s += sys->sprint("%02x", int buf[i]);
		if(buf[i] != byte 0)
			zero = 0;
	}
	if(zero){
		sys->print("RANDOM-FAIL all zero\n");
		return;
	}
	sys->print("RANDOM-OK %s\n", s);
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
	# the geometry this controller derived from the same card's CSD;
	# it has to agree with the one SDHCI reported above
	cfd := sys->open("/dev/sdM0/ctl", Sys->OREAD);
	cbuf := array[512] of byte;
	cn := 0;
	if(cfd != nil)
		cn = sys->read(cfd, cbuf, len cbuf);
	if(cn <= 0){
		sys->print("SD-CAP-NONE cannot read /dev/sdM0/ctl: %r\n");
		return;
	}
	sys->print("SD ctl: %s", string cbuf[0:cn]);
	if(capcheck("SD", fd, string cbuf[0:cn]) == 0)
		return;
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
	kfs->init(nil, "kfs" :: "-r" :: "/dev/sdM0/fs" :: nil);
}

# Where the kfs test filesystem goes.  Sector 256 is clear of every
# block the controller checks above touch (0, 5, 8-11, 12-15), and
# 8192 sectors is 4MB, which is plenty to ream and create a file in.
Fsstart: con 256;
Fssecs: con 8192;

sdfs()
{
	# Ream a bounded partition rather than the whole card.
	#
	# "kfs -r" writes every block of whatever it is given, and it was
	# given /dev/sdM0/data -- the whole card.  So the cost of this
	# check was proportional to the card: a second on the 16MB test
	# image, seven minutes on the 4GB one used to reach CSD v2, and
	# on a real Pi with a real card, longer than anyone would wait.
	# It also destroyed the entire card at every boot rather than a
	# corner of it, which is a great deal to ask of a machine whose
	# card might have something on it.
	#
	# A fixed 4MB partition costs the same whatever card is fitted.
	cfd := sys->open("/dev/sdM0/ctl", Sys->ORDWR);
	if(cfd == nil){
		sys->print("SD-FS ctl: %r\n");
		return;
	}
	if(sys->fprint(cfd, "part fs %d %d", Fsstart, Fsstart+Fssecs) < 0){
		sys->print("SD-FS part: %r\n");
		return;
	}
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
	spawn kbdcheck();
	sys->print("USB-OK\n");
	# Spawned, not called: the check waits a bounded time for events
	# that only arrive if a mouse is attached, and a boot with none
	# should not stall for that window.  The marker appears when the
	# check resolves, which may be after later ones.
	spawn mousecheck();
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
	etherone("ether", "ETHER", 100, nil, nil, nil);

	# A second adapter, if there is one.  usbd names the first netif
	# directory "ether" and the rest "ether1", "ether2", so a board
	# with two USB ethernets now has two directories to bind rather
	# than two instances fighting over one name.  The wait is short
	# because the first call already waited out enumeration: either
	# the second etherusb is up by now or there is no second adapter.
	#
	# Nothing is printed when there is no second one.  A -NONE here
	# would appear on every board in the suite that has one adapter or
	# none, which is five of them, and would say only that a device
	# nobody plugged in is not present.
	if(sys->open("/net.alt/ether1/addr", Sys->OREAD) != nil)
		etherone("ether1", "ETHER2", 20, "10.0.3.15", "255.255.255.0", "10.0.3.2");
}

# One USB ethernet: wait for etherusb to serve it, bind it into devip
# as its own interface, take an address by DHCP and ping the gateway.
# The DHCP exchange crosses the USB link in both directions, so the
# -DHCP-OK marker proves the whole path -- styx server, bulk in and
# out, the DWC2 driver.  tag names the marker family so a second
# adapter reports separately from the first.
# ip nil means take an address by DHCP; an ip means configure it
# statically.  The second interface has to be static: devip here is one
# stack, the first interface's DHCP proc holds udp!*!68 for the life of
# its lease so it can renew, and a second announce on the same stack
# comes back "address in use".  One stack, one DHCP client.  A static
# address on its own subnet still puts every packet through the second
# adapter's bulk endpoints, which is what there is to prove.
etherone(ifname, tag: string, tries: int, ip, mask, gw: string)
{
	dir := "/net.alt/" + ifname;
	addr := dir + "/addr";
	for(i := 0; i < tries; i++){
		if(sys->open(addr, Sys->OREAD) != nil)
			break;
		sys->sleep(100);
	}
	if(sys->open(addr, Sys->OREAD) == nil){
		sys->print("%s-NONE (no USB ethernet served at %s)\n", tag, addr);
		return;
	}
	sys->bind("#I", "/net", Sys->MAFTER);
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "bind ether %s", dir) < 0){
		sys->print("%s-FAIL bind ether: %r\n", tag);
		return;
	}
	sys->print("%sBIND-OK\n", tag);
	if(ip != nil){
		if(sys->fprint(cfd, "add %s %s", ip, mask) < 0){
			sys->print("%s-ADDR-FAIL add %s: %r\n", tag, ip);
			return;
		}
		sys->print("%s-ADDR-OK ip=%s gw=%s\n", tag, ip, gw);
		pingcheck(tag, gw);
		return;
	}
	# Load and initialise once, not once per interface.  Limbo's load
	# of a path already loaded gives back the same instance, module
	# data and all, so a second init() on behalf of a second adapter
	# resets globals the first interface's state still points into.
	# That is what faulted here: with two adapters bound, the second
	# call panicked the interpreter at OP(movp) reading a nil slot,
	# "module Dhcpclient PC 0x3d051d8 inst 927".
	if(dhcpclient == nil){
		dhcpclient = load Dhcpclient Dhcpclient->PATH;
		if(dhcpclient == nil){
			sys->print("%s-FAIL load dhcpclient: %r\n", tag);
			return;
		}
		dhcpclient->init();
	}
	cfg := Bootconf.new();
	lease: ref Lease;
	err: string;
	(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, addr, cfg, nil);
	if(err != nil || cfg == nil || cfg.ip == nil){
		sys->print("%s-DHCP-FAIL %s\n", tag, err);
		return;
	}
	sys->print("%s-DHCP-OK ip=%s gw=%s\n", tag, cfg.ip, cfg.ipgw);
	pingcheck(tag, cfg.ipgw);
	lease = nil;
}

pingcheck(tag, gw: string)
{
	ping := load Command "/dis/ip/ping.dis";
	if(ping == nil){
		sys->print("%s-PING-NONE load: %r\n", tag);
		return;
	}
	ping->init(nil, "ping" :: "-n" :: "3" :: gw :: nil);
	sys->print("%s-PING-DONE\n", tag);
}

# Phase 2's other half: a boot-protocol USB mouse, through usbd's HID
# decode, to #m/pointer.
#
# Two things are asserted, and the second is the one worth having.
# Motion proves the path carries data at all.  The buttons prove
# usbd.b's HID-to-devpointer remap, which is bit-shuffling that until
# now had never once executed -- there was no /dev/pointer for the
# reader to open.  HID reports left in bit 0, right in bit 1 and
# middle in bit 2; devpointer wants 1, 4 and 2.  Right and middle are
# therefore transposed, and a motion-only test cannot see it.  So both
# are injected and both are checked: right must arrive as 4 and middle
# as 2, which fails if the shuffle is dropped or reversed.
#
# The tablet is checked by the same reader, in the same window.  Two
# readers would not do: devpointer has one event queue for the whole
# machine (ptrq in os/inferno/port/devpointer.c), so a second reader
# consumes events the first was waiting for and makes both checks
# flaky.  Two windows in series would not do either: a board with
# neither device attached would then wait out two timeouts instead of
# one, which is four of the six Pi configurations paying fifty seconds
# for nothing.  So one loop watches for both conditions and reports
# both markers.
#
# Movement is asserted as growth between consecutive events, not as a
# coordinate.  The first event a fresh reader sees is the cursor's own
# starting position -- 320 240, the middle of the screen -- delivered
# whether or not any mouse exists, and not anything a mouse did.  It is
# the baseline and is not counted: counting it made a board with no
# mouse attached report FAIL, on the strength of an event the pointer
# device produces by itself.
#
# USB-MOUSE-NONE means no events arrived within the window, which is
# what an invocation with no -device usb-mouse should say and is not a
# failure.  It cannot distinguish that from a mouse that enumerated
# and then said nothing at all; a mouse that speaks and is decoded
# wrongly gives USB-MOUSE-FAIL.
mousecheck()
{
	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil){
		sys->print("USB-MOUSE-NONE /dev/pointer: %r\n");
		return;
	}
	# The point the tablet is sent to, scaled the way usbd scales it.
	# drawtest() has already bound #i and loaded Draw; if it could
	# not, 640x480 is this board's framebuffer (ScrX/ScrY in
	# os/inferno/raspi3b/screenbcm.c) and is what usbd falls back to
	# as well, so the two ends still agree.
	scrw := 640;
	scrh := 480;
	if(draw != nil){
		disp: ref Display;
		{ disp = Display.allocate("/dev"); }
		exception { "*" => disp = nil; }
		if(disp != nil && disp.image != nil){
			dr := disp.image.r;
			scrw = dr.max.x - dr.min.x;
			scrh = dr.max.y - dr.min.y;
		}
	}
	wantx := 3*(scrw-1)/4;
	wanty := (scrh-1)/4;

	evc := chan of string;
	tmo := chan of int;
	spawn mousereadproc(fd, evc);
	spawn mousetimer(tmo, 25000);

	prevx := -1;
	moved := 0;
	buttons := 0;
	nev := 0;
	tabhit := 0;
	bestx := -1;
	besty := -1;
loop:
	for(;;) alt {
	ev := <-evc =>
		(nf, flds) := sys->tokenize(ev, " \t\n");
		if(nf < 4)
			continue;
		flds = tl flds;			# drop the leading "m"
		x := int hd flds;
		y := int hd tl flds;
		b := int hd tl tl flds;
		if(prevx < 0){
			# The first event is the cursor's own starting
			# position, delivered whether or not any mouse
			# exists.  It is the baseline, not evidence.
			prevx = x;
			continue;
		}
		nev++;
		if(x > prevx)
			moved = 1;
		prevx = x;
		buttons |= b;
		# the tablet's own condition, on the same events: the
		# nearest point seen is kept so a decode that is wrong
		# by a scale factor can be named rather than merely
		# missed
		if(bestx < 0 || iabs(x-wantx)+iabs(y-wanty) < iabs(bestx-wantx)+iabs(besty-wanty)){
			bestx = x;
			besty = y;
		}
		if(iabs(x-wantx) <= 4 && iabs(y-wanty) <= 4)
			tabhit = 1;
		if(moved && (buttons & 4) != 0 && (buttons & 2) != 0 && tabhit)
			break loop;
	<-tmo =>
		break loop;
	}

	tabletreport(nev, tabhit, wantx, wanty, scrw, scrh, bestx, besty);

	if(nev == 0){
		sys->print("USB-MOUSE-NONE no pointer events (no mouse attached?)\n");
		return;
	}
	if(!moved){
		sys->print("USB-MOUSE-FAIL %d events, none moved x\n", nev);
		return;
	}
	if(buttons == 0){
		sys->print("USB-MOUSE-FAIL %d events, motion but no button\n", nev);
		return;
	}
	# Right must land on 4 and middle on 2.  Either missing means
	# usbd's HID-to-devpointer shuffle is wrong in one direction.
	if((buttons & 4) == 0 || (buttons & 2) == 0){
		sys->print("USB-MOUSE-FAIL button bits %d, wanted right (4) and middle (2); usbd's HID remap disagrees with devpointer\n", buttons);
		return;
	}
	sys->print("USB-MOUSE-OK %d events, motion and buttons %d through usbd's HID decode to #m/pointer\n", nev, buttons);
}

# The tablet's half of the HID path, reported from the same reader.  A
# usb-tablet offers no boot protocol, so nothing in usbd's fixed-offset
# mouse decode can read it: it is the device the report-descriptor
# parser exists for, and before that parser it was enumerated,
# configured and then ignored.
#
# What this asserts is absolute positioning, which is the thing a
# relative decode cannot fake.  The hand on the monitor sends the
# pointer to three quarters along x and one quarter down y in the
# tablet's own 0..32767 logical units; usbd scales those onto the
# screen, so the event that arrives has to name that point.  The boot
# mouse's relative events interleave with these -- it sweeps x by +8
# and never touches y, so it can drift through the x this wants but
# never through the pair.
#
# USB-TABLET-NONE is the right answer for an invocation with no tablet,
# exactly as USB-MOUSE-NONE is for one with no mouse.
tabletreport(nev, hit, wantx, wanty, scrw, scrh, bestx, besty: int)
{
	if(nev == 0){
		sys->print("USB-TABLET-NONE no pointer events (no tablet attached?)\n");
		return;
	}
	if(!hit){
		sys->print("USB-TABLET-FAIL %d events, wanted %d %d on %dx%d, nearest %d %d\n",
			nev, wantx, wanty, scrw, scrh, bestx, besty);
		return;
	}
	sys->print("USB-TABLET-OK absolute %d %d on %dx%d through usbd's HID report-descriptor decode\n",
		wantx, wanty, scrw, scrh);
}

iabs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}

mousereadproc(fd: ref Sys->FD, evc: chan of string)
{
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		evc <-= string buf[0:n];
	}
}

mousetimer(tmo: chan of int, ms: int)
{
	sys->sleep(ms);
	tmo <-= 1;
}

# The keyboard's half of the HID path, and the mirror of mousecheck().
#
# This used to print one line per character for as long as the board
# ran, which is a report and not a check: a reader had to decide for
# themselves whether what arrived was right, and nothing in a log said
# either way.  The comment above the call has always named the word to
# send -- "an injected hello from the QEMU monitor" -- so that is the
# word, and the check waits for it.
#
# USB-KBD-NONE is the right answer for an invocation with no keyboard
# attached, exactly as USB-MOUSE-NONE is.  A keyboard that enumerated
# and delivered something other than what was typed gives -FAIL, which
# is the case the old report could not distinguish from success.
Kbdword: con "hello";

kbdcheck()
{
	fd := sys->open("/dev/keyboard", Sys->OREAD);
	if(fd == nil){
		sys->print("USB-KBD-NONE /dev/keyboard: %r\n");
		return;
	}
	evc := chan of string;
	tmo := chan of int;
	spawn mousereadproc(fd, evc);
	# Twenty seconds against the mouse check's twenty-five, and the
	# difference is deliberate.  Both are spawned together and both
	# report -NONE by timing out, so on a board with neither device
	# attached the two markers would race, and the harness has to
	# know which one is last.  This one goes first.
	spawn mousetimer(tmo, 20000);

	# Everything that arrives is accumulated and the word is looked
	# for anywhere in it, because the harness sends it once a second
	# and the check cannot know which burst it caught the start of.
	# That does mean a keyboard delivering the right letters in the
	# wrong order could, across enough repeats, spell the word by
	# accident.  The marker prints what actually arrived, so a log
	# says which happened.
	got := "";
loop:
	for(;;) alt {
	s := <-evc =>
		got += s;
		if(kbdsaw(got, Kbdword))
			break loop;
	<-tmo =>
		break loop;
	}

	if(got == nil){
		sys->print("USB-KBD-NONE no keystrokes (no keyboard attached?)\n");
		return;
	}
	if(!kbdsaw(got, Kbdword)){
		sys->print("USB-KBD-FAIL %d chars %q, wanted %q\n",
			len got, got, Kbdword);
		return;
	}
	sys->print("USB-KBD-OK %d chars, %q through usbd's HID decode to /dev/keyboard\n",
		len got, Kbdword);
}

kbdsaw(s: string, want: string): int
{
	n := len want;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == want)
			return 1;
	return 0;
}

init()
{
	shell: Shell;
	sys = load Sys Sys->PATH;
	sys->print("raspi3b init\n");
	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	# #m is the pointer device.  Without this bind /dev/pointer does
	# not exist, and usbd's mouse reader -- which is already written
	# and already finds the mouse -- dies on its first open with
	# "usbd: /dev/pointer: file does not exist".  That is the whole
	# of what was missing: the enumeration, the HID decode and the
	# devpointer end were all in place and unreachable.
	sys->bind("#m", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->print("RASPI3B-OK\n");

	rngcheck();
	sys->bind("#S", "/dev", sys->MAFTER);
	sdhcicheck();
	sdcheck();
	drawtest();
	usbcheck();
	# sdfs() reams a kfs onto the SD card, mounts it over a pipe, and
	# creates a file through the mount.  It works, and it was always
	# working: what used to look like a hang here was the console
	# output queue never being drained, so SD-FS-CREATE-OK was written
	# and never emitted.  See the uart fix in os/inferno/port/devuart.c
	# and doc/raspi3b-completion-plan.ms.
	sdfs();

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){ sys->print("init: load sh: %r\n"); exit; }
	shell->init(nil, "sh" :: "-n" :: "-c" :: "echo RASPI3B-SH-OK" :: nil);
	shell->init(nil, "sh" :: "-n" :: nil);
}
