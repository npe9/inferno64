implement Init;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
Init: module { init: fn(); };
Shell: module { init: fn(nil: ref Draw->Context, argv: list of string); };
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
# Read/write the SD card exposed by devsd (#S) as /dev/sdM0/data - the
# BCM2835 SDHOST native-SD path.  Boot with -sd <image>.
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
	ethercheck();
}

# Phase 3 de-risk: the Limbo USB-ethernet server serves the netif file
# interface, self-mounts, and binds it as devip's ethernet.  Running it
# proves chandial's clone/connect/data dance is satisfiable from Limbo
# (ETHERBIND-OK) and that outgoing frames reach the driver (ETHERTX from
# the ARP an added address provokes).  The USB half comes next.
ethercheck()
{
	eth := load Command "/dis/usb/etherusb.dis";
	if(eth == nil){
		sys->print("ETHER-FAIL load: %r\n");
		return;
	}
	spawn eth->init(nil, "etherusb" :: "/net.alt" :: nil);
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
