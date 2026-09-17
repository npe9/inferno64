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
# Read the SD card exposed by devsd (#S) as /dev/sdM0/data - the BCM2835
# SDHOST native-SD path.  Normal boot must not modify the firmware card.
sdcheck()
{
	fd := sys->open("/dev/sdM0/data", Sys->OREAD);
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
	sys->print("SD-READ-OK\n");

	# A multi-block transfer, checked by its last block.  Read 64 sectors
	# ending at the FAT boot sector of the first partition (16384 on this
	# card) in one call: if the run arrives in order, the last 512 bytes
	# are that boot sector, which names itself.  Typing this at the shell
	# is not an option while another session's libinterp debug output
	# interleaves with the console echo and corrupts the command line.
	nblk := 64;
	big1 := array[nblk*512] of byte;
	off := big (16385 - nblk) * big 512;
	n := sys->pread(fd, big1, len big1, off);
	if(n != len big1){
		sys->print("SD-MULTI-FAIL %d of %d: %r\n", n, len big1);
		return;
	}
	# the same block on its own: the run is in order if its tail matches
	one := array[512] of byte;
	if(sys->pread(fd, one, len one, big 16384 * big 512) != len one){
		sys->print("SD-MULTI-FAIL single read of the last block: %r\n");
		return;
	}
	last := big1[(nblk-1)*512:];
	for(i := 0; i < 512; i++)
		if(last[i] != one[i]){
			sys->print("SD-MULTI-FAIL byte %d of the last block: %02x not %02x\n",
				i, int last[i], int one[i]);
			return;
		}
	sys->print("SD-MULTI-OK %d bytes, last block matches it read alone (%02x%02x%02x%02x)\n",
		n, int one[0], int one[1], int one[2], int one[3]);
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
	# Never the whole device: "-r" reams what it is given, and this card
	# holds the firmware and the kernel that booted it.  KFSPART covers
	# the gap between the master boot record and the first partition,
	# which is unallocated and reads as zeros on this card.
	kfs->init(nil, "kfs" :: "-r" :: KFSPART :: nil);
}

KFSPART: con "/dev/sdM0/kfstest";

# the IP interface's control fd, held so the interface outlives the
# function that made it
ipctl: ref Sys->FD;

# The first FAT partition in the master boot record: (start, sectors),
# or (0, 0).  Everything that carves up this card starts here, because
# the card holds the firmware and the kernel that booted it.
fatpart(): (int, int)
{
	fd := sys->open("/dev/sdM0/data", Sys->OREAD);
	if(fd == nil)
		return (0, 0);
	mbr := array[512] of byte;
	if(sys->pread(fd, mbr, len mbr, big 0) != len mbr)
		return (0, 0);
	if(int mbr[510] != 16r55 || int mbr[511] != 16raa)
		return (0, 0);
	for(i := 0; i < 4; i++){
		e := 446 + i*16;
		t := int mbr[e+4];
		if(t != 16r01 && t != 16r04 && t != 16r06 && t != 16r0b
		&& t != 16r0c && t != 16r0e)
			continue;
		start := int mbr[e+8] | (int mbr[e+9]<<8) | (int mbr[e+10]<<16) |
			(int mbr[e+11]<<24);
		nsec := int mbr[e+12] | (int mbr[e+13]<<8) | (int mbr[e+14]<<16) |
			(int mbr[e+15]<<24);
		return (start, nsec);
	}
	return (0, 0);
}

# Fetch a kernel over the network and install it on the partition the
# firmware reads, so a new build reaches the board without its card being
# carried to another machine.  /n/dos/kupdate.txt on that same partition
# says where from: "net!addr!port /path/to/kernel8.img".  The far end is
# a Styx server - this system's own file protocol, so the remote tree is
# simply mounted and the file read, with no second protocol to speak and
# no client to write: on the other machine,
#	styxlisten -A 'tcp!*!6666' export /
# The current kernel is kept as kernel8.bak before the new one takes its
# name, so a bad build costs one card swap rather than the board.
kupdate()
{
	cfg := sys->open("/n/dos/kupdate.txt", Sys->OREAD);
	if(cfg == nil)
		return;			# nothing asked for; say nothing
	b := array[256] of byte;
	n := sys->read(cfg, b, len b);
	cfg = nil;
	if(n <= 0){
		sys->print("KUPDATE-FAIL empty kupdate.txt\n");
		return;
	}
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 2){
		sys->print("KUPDATE-FAIL want \"net!addr!port /path\" in kupdate.txt\n");
		return;
	}
	addr := hd f;
	path := hd tl f;
	# Wait for the IP stack to exist and to have an address.  This runs
	# from a process spawned while the network is still coming up, and
	# dialling before /net is bound fails with "file does not exist",
	# which reads like a missing server rather than a missing namespace.
	for(i := 0; i < 300; i++){
		if(hasaddr())
			break;
		sys->sleep(100);
	}
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0){
		sys->print("KUPDATE-FAIL dial %s: %r\n", addr);
		return;
	}
	if(sys->mount(c.dfd, nil, "/n/remote", Sys->MREPL, "") < 0){
		sys->print("KUPDATE-FAIL mount %s: %r\n", addr);
		return;
	}
	src := sys->open("/n/remote" + path, Sys->OREAD);
	if(src == nil){
		sys->print("KUPDATE-FAIL open %s: %r\n", path);
		return;
	}
	dst := sys->create("/n/dos/kernel8.new", Sys->OWRITE, 8r666);
	if(dst == nil){
		sys->print("KUPDATE-FAIL create kernel8.new: %r\n");
		return;
	}
	buf := array[8192] of byte;
	total := 0;
	for(;;){
		n = sys->read(src, buf, len buf);
		if(n < 0){
			sys->print("KUPDATE-FAIL read %s: %r\n", path);
			return;
		}
		if(n == 0)
			break;
		if(sys->write(dst, buf[0:n], n) != n){
			sys->print("KUPDATE-FAIL write kernel8.new: %r\n");
			return;
		}
		total += n;
	}
	src = nil;
	dst = nil;
	if(total == 0){
		sys->print("KUPDATE-FAIL %s is empty\n", path);
		return;
	}
	sys->print("KUPDATE fetched %d bytes\n", total);
	sys->remove("/n/dos/kernel8.bak");
	if(rename("/n/dos/kernel8.img", "kernel8.bak") < 0){
		sys->print("KUPDATE-FAIL keep the old kernel: %r\n");
		return;
	}
	if(rename("/n/dos/kernel8.new", "kernel8.img") < 0){
		sys->print("KUPDATE-FAIL install the new kernel: %r\n");
		return;
	}
	sys->print("KUPDATE-OK %d bytes installed; the old kernel is kernel8.bak\n",
		total);
}

# does the IP stack have an address yet?
hasaddr(): int
{
	fd := sys->open("/net/ipifc/0/status", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 0;
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	for(; f != nil; f = tl f){
		s := hd f;
		# an address line starts with a dotted quad that is not 0.0.0.0
		if(len s >= 7 && s[0] >= '1' && s[0] <= '9')
			for(i := 0; i < len s; i++)
				if(s[i] == '.')
					return 1;
	}
	nf = nf;
	return 0;
}

rename(path: string, newname: string): int
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return -1;
	d.name = newname;
	return sys->wstat(path, d);
}

# Write to the partition the firmware reads, which is the point of
# mounting it: a board that can write here can replace its own kernel.
# A new small file only - never a write over kernel8.img, which is what
# the machine boots from.
fatwrite()
{
	name := "/n/dos/inferno.txt";
	msg := "written by inferno on the pi\n";
	fd := sys->create(name, Sys->ORDWR, 8r666);
	if(fd == nil){
		sys->print("FAT-WRITE-FAIL create: %r\n");
		return;
	}
	b := array of byte msg;
	if(sys->write(fd, b, len b) != len b){
		sys->print("FAT-WRITE-FAIL write: %r\n");
		return;
	}
	fd = nil;
	fd = sys->open(name, Sys->OREAD);
	if(fd == nil){
		sys->print("FAT-WRITE-FAIL reopen: %r\n");
		return;
	}
	rb := array[len b] of byte;
	n := sys->read(fd, rb, len rb);
	if(n != len b || string rb != msg){
		sys->print("FAT-WRITE-FAIL read back %d of %d\n", n, len b);
		return;
	}
	sys->print("FAT-WRITE-OK %s holds %d bytes\n", name, n);
}

# The FAT partition the firmware boots from, found in the master boot
# record rather than assumed: its start and length decide what the SD
# device's ctl file is told, and dossrv then serves it.  Reaching it
# matters beyond curiosity - kernel8.img lives there, so a board that can
# write this partition can replace its own kernel instead of having its
# card carried to another machine.
fatcheck()
{
	(start, nsec) := fatpart();
	if(nsec == 0){
		sys->print("FAT-NONE (no FAT partition in the table)\n");
		return;
	}
	sys->print("FAT partition at %d, %d sectors\n", start, nsec);
	cfd := sys->open("/dev/sdM0/ctl", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "part dos %d %d", start, start+nsec) < 0){
		sys->print("FAT-FAIL part: %r\n");
		return;
	}
	cfd = nil;
	# /n is in the kernel's read-only root and has no subdirectories, so
	# there is nothing to mount onto: mntgen serves /n and makes each
	# name appear as it is used.
	mg := load Command "/dis/mntgen.dis";
	if(mg == nil){
		sys->print("FAT-FAIL load mntgen: %r\n");
		return;
	}
	spawn mg->init(nil, "mntgen" :: "/n" :: nil);
	sys->sleep(200);
	dos := load Command "/dis/dossrv.dis";
	if(dos == nil){
		sys->print("FAT-FAIL load dossrv: %r\n");
		return;
	}
	spawn dos->init(nil, "dossrv" :: "-f" :: "/dev/sdM0/dos" :: "-m" :: "/n/dos" :: nil);
	for(i := 0; i < 100; i++){
		(ok, d) := sys->stat("/n/dos/kernel8.img");
		if(ok == 0){
			sys->print("FAT-OK /n/dos/kernel8.img is %bd bytes\n", d.length);
			fatwrite();
			kupdate();
			return;
		}
		sys->sleep(100);
	}
	sys->print("FAT-FAIL no /n/dos/kernel8.img: %r\n");
}

sdfs()
{
	p := array[2] of ref Sys->FD;

	# The scratch partition is the gap between the master boot record and
	# the first real partition, whose start comes from the table rather
	# than from memory of this particular card: on an image whose
	# filesystem begins at 2048 a hardcoded gap would ream the filesystem
	# itself, which is exactly what it did once here.
	(fstart, nsec) := fatpart();
	if(nsec == 0){
		sys->print("SD-FS skipped: no partition table to find a gap in\n");
		return;
	}
	if(fstart < 2048+2048){
		sys->print("SD-FS skipped: no room below the first partition at %d\n",
			fstart);
		return;
	}
	cfd := sys->open("/dev/sdM0/ctl", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "part kfstest 2048 %d", fstart-1) < 0){
		sys->print("SD-FS part: %r\n");
		return;
	}
	cfd = nil;
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
	# usbd enumerates whatever is attached and starts a driver for it: on
	# this board the onboard hub and, behind it, the LAN9514 ethernet,
	# which etherusb then serves at /net.alt/ether.  It runs in its own
	# process and shares this namespace, so the mount it makes is the one
	# ethercheck below looks for.
	usbd := load Command "/dis/usb/usbd.dis";
	if(usbd == nil){
		sys->print("USB-NONE load usbd: %r\n");
		return;
	}
	spawn usbd->init(nil, "usbd" :: nil);
	sys->print("USB-OK\n");
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
	# The fd returned by opening the clone file IS the interface: when the
	# last reference to it goes, devip unbinds the ether and the address
	# with it.  Holding it in a module variable keeps the interface for
	# the life of init - without that the board answered pings while this
	# function ran and went silent the moment it returned, and anything
	# dialling later got "file does not exist".
	cfd := ipctl = sys->open("/net/ipifc/clone", Sys->ORDWR);
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
	sdcheck();
	drawtest();
	usbcheck();
	# in its own process: the shell must not wait behind a DHCP lease and
	# three pings, which take seconds and can be answered by nothing at all
	spawn ethercheck();
	# A kfs in the card's unallocated gap, mounted over a pipe, with a
	# file created in it.  The create used to hang here - pid 1's Twalk
	# got its Rerror and the error unwound past mntwalk's own waserror
	# handler, so the Tcreate was never sent - and that was blamed on an
	# arm64 multi-kproc error-stack bug.  The mount it needs works now
	# that kernel stacks are aligned, so the create is worth trying
	# again; it runs in its own process either way, so a hang there
	# leaves the board usable.
	spawn sdfs();
	spawn fatcheck();

	shell = load Shell "/dis/sh.dis";
	if(shell == nil){ sys->print("init: load sh: %r\n"); exit; }
	# osinit's inherited descriptors are not guaranteed to be the serial
	# console on the Pi firmware path.  Give the interactive shell an
	# explicit console on all three standard descriptors.
	cons := sys->open("/dev/cons", Sys->ORDWR);
	if(cons != nil){
		sys->dup(cons.fd, 0);
		sys->dup(cons.fd, 1);
		sys->dup(cons.fd, 2);
	}
	sys->print("RASPI3B-SH-OK\n");
	shell->init(nil, "sh" :: "-i" :: "-n" :: nil);
}
