implement Init;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
include "daytime.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;
Init: module { init: fn(); };
Shell: module { init: fn(nil: ref Draw->Context, argv: list of string); };
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# The card's geometry is a number the card reported about itself, and
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
# second.  Both are reads; nothing is written to the card.
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

# Read the SD card exposed by devsd (#S) as SDDEV/data - the controller
# SDHCI (sdemmcbcm.c), which is the path that works on the board.  Normal boot must not modify the firmware card.
sdcheck()
{
	fd := sys->open(SDDEV + "/data", Sys->OREAD);
	if(fd == nil){
		sys->print("SD-NONE (no %s/data: %r)\n", SDDEV);
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

	# the geometry the driver derived from the card's CSD, checked at
	# its only observable edge; both reads, nothing written
	cfd := sys->open(SDDEV + "/ctl", Sys->OREAD);
	cbuf := array[512] of byte;
	cn := 0;
	if(cfd != nil)
		cn = sys->read(cfd, cbuf, len cbuf);
	if(cn <= 0){
		sys->print("SD-CAP-NONE cannot read %s/ctl: %r\n", SDDEV);
		return;
	}
	if(capcheck("SD", fd, string cbuf[0:cn]) == 0)
		return;
	multiblockcheck();
	sys->print("SD-OK\n");
}

#
# Prove a multi-block WRITE puts the right bytes down, before anything
# on this board relies on one.
#
# CMD25 makes the card 27 times faster -- 474 KB/s to 12.8 MB/s,
# measured -- and a read that goes wrong is a wrong answer while a
# write that goes wrong is a damaged card.  So the driver keeps
# multi-block writes off until something checks them, and this is that
# something: the driver's own multiverify, which writes N blocks in ONE
# request, reads them back in one, and compares.
#
# Here, in the SD suite, because it has to run BEFORE kupdate.  Putting
# it in board.cmd did not work: that waits for kupdate to finish with
# the mount, and kupdate is slow precisely because its write side is
# the thing being checked.  A test that cannot run until the bug is
# fixed is no test.
#
# Blocks 2900000 and up, well past data, kfstest and dos on this card.
#
#
# Read the raw device in a loop until told to stop, to give the
# multi-block check something to contend with.
#
hammer(stop: chan of int)
{
	fd := sys->open(SDDEV + "/data", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[8192] of byte;
	off := big 4000000 * big 512;
	for(;;){
		alt {
		<-stop =>
			return;
		* =>
			sys->pread(fd, buf, len buf, off);
			off += big (len buf);
			if(off > big 5000000 * big 512)
				off = big 4000000 * big 512;
		}
	}
}

multiblockcheck()
{
	cfd := sys->open(SDDEV + "/ctl", Sys->OWRITE);
	if(cfd == nil){
		sys->print("SD-MULTIW-NONE cannot open %s/ctl: %r\n", SDDEV);
		return;
	}
	# single-block first, so a failure says which arm broke
	# PIO first, then DMA.  A multi-block read overran the FIFO at
	# 4092 bytes -- eight blocks -- because the card streams
	# continuously once CMD18 starts and a per-word polling loop
	# cannot drain 12MB/s.  DMA is the reason this controller has a
	# DMA path at all, so the pairing is the experiment.
	sys->fprint(cfd, "multi 1");
	sys->fprint(cfd, "multiwrite 0");
	sys->fprint(cfd, "multiverify 2900000 64");
	sys->fprint(cfd, "multi 64");
	sys->fprint(cfd, "multiverify 2900100 64");
	# multi-block WRITES, in PIO: the half that can damage a card
	sys->fprint(cfd, "multiwrite 1");
	sys->fprint(cfd, "multiverify 2900300 64");
	sys->fprint(cfd, "multiverify 2900500 512");
	sys->fprint(cfd, "multiwrite 0");
	#
	# Put the switches back to the DRIVER's defaults, not to some
	# other value.
	#
	# This used to end with "multi 1; multiwrite 0", which is not
	# restoring anything -- it is imposing the old slow settings on
	# every boot and silently undoing the defaults the driver
	# declares.  Worse, while board.cmd was also writing these,
	# two agents were changing shared switches with no
	# synchronisation and a transfer's report could name a
	# configuration it had not run under.  The driver samples them
	# once per transfer now; this just leaves them alone.
	#
	sys->fprint(cfd, "multi 64");
	sys->fprint(cfd, "multiwrite 1");
	sys->fprint(cfd, "dma 0");

	#
	# And the same check with someone else hammering the controller.
	#
	# This is the experiment that was owed and kept not happening,
	# because it lived in board.cmd -- which needs the styx mount,
	# which needs kupdate, which needs the network and the host's
	# server.  A test of the CARD should not depend on any of that.
	# Here it needs nothing but the board.
	#
	# One agent sets the switches (this function, before the spawn);
	# the hammer only reads.  The failure this is looking for was
	# seen once with two agents BOTH writing the driver's globals,
	# which could not be interpreted; this arm can be.
	#
	# the DMA arm BEFORE the concurrent ones, deliberately: it fails,
	# and the question is whether its failure still breaks the next
	# request now that the write waits by the clock
	sys->fprint(cfd, "dma 1");
	sys->fprint(cfd, "multiverify 2900700 64");
	sys->fprint(cfd, "dma 0");

	stop := chan of int;
	spawn hammer(stop);
	sys->fprint(cfd, "multiverify 2920000 256");
	sys->fprint(cfd, "multiverify 2930000 256");
	stop <-= 1;

	#
	# The DMA pairing LAST, because it fails and its failure
	# poisons whatever runs next.
	#
	# It used to sit in the middle, and the transfer after it came
	# back "write 0 of 131072" -- the whole request refused --
	# while the one after that passed.  So a failed DMA transfer
	# leaves the card or the controller in a state the next
	# transfer cannot use, even though the error path now resets
	# the DMA channel, reports, falls back to PIO and sends the
	# CMD12 that ends a multi-block command.  That recovery is
	# still not enough, and it is its own bug: a driver should not
	# be able to break the next request.
	#
	# Running it last keeps the information -- the arm still
	# reports -- without corrupting the arms that matter, which are
	# the ones describing the configuration the board actually
	# ships.
	#

	#
	# AND PUT DMA BACK, because this function left the board running
	# without it.
	#
	# The flag is set to 0 twice above as the control arm of an A/B and
	# was never restored, so every boot ended with the driver in PIO --
	# on a board whose ctl then reads "sdhost dma 0" and whose plan has
	# SD DMA as the first thing that multiplies everything else.  What
	# the same boot prints, five arms of it, is
	#
	#	MULTIVERIFY-OK 64 blocks at 2900000: ... (multi 1 dma 1)
	#	MULTIVERIFY-OK 512 blocks at 2900500: ... (multi 64 dma 1)
	#
	# so DMA works here now: the comment above about the DMA arm failing
	# and poisoning the next request predates the fix for the card's
	# legal 250ms program time, and today that arm passes too.  The
	# driver's own default is 1 and the error path still falls back to 0
	# and says so, so restoring it costs nothing if it ever stops
	# working.
	#
	sys->fprint(cfd, "dma 1");
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

#
# Which controller holds the SD card.
#
# The SoC wires the slot to either the Arasan ("sdM0", sdemmcbcm.c) or
# the BCM2835's own SDHOST ("sdN0", sdhostbcm.c), and GPIO 48-53's alt
# function decides: each driver routes the pins in its own online(),
# so whichever unit is opened FIRST takes the card and the other then
# finds no media.
#
# That is not a preference, it is an exclusion, and mixing the two
# corrupts things.  Opening sdN0 on a board that had already given the
# card to sdM0 made SDHOST re-identify it underneath a mounted
# filesystem, and the Arasan's very next write failed and panicked
# dossrv:
#
#	sdhost: reinit ok
#	emmc: write block 19606 failed: interrupt 0x38100 status 0xf0001
#	dosfs: panic: write
#
# So everything here goes through one name, and changing it is how the
# other controller gets tested -- including /n/dos and kupdate, which
# is the point: a controller that only ever sees scratch reads has not
# been tested.
#
# The default is the Arasan.  Its PIO path works and serves /n/dos and
# kupdate.
#
# SDHOST now reads AND writes: on sdN0 it passes SD-OK, FAT-OK,
# SD-FS-CREATE-OK, FAT-WRITE-OK, FAT-RENAME-OK, FAT-CLOBBER-OK and
# FAT-HELD-OK, so kfs makes a filesystem and dosfs reads, writes and
# renames on it.  It is not the default yet for one reason: a read
# still fails intermittently under the 1.5MB sustained test --
#
#   sdhost: read block 36864 failed: sdhsts 0x0 sdcmd 0x51 sdedm 0x10801
#
# the "data phase never started" abort that the 1ms first-poll delay
# is supposed to prevent, so that delay is not always enough.  The
# Arasan has no such gap, and the card needs a kernel that can boot
# the board back to a shell.
#
# SDHOST (sdN0), not the Arasan (sdM0).
#
# It is the controller a real Pi 3B wants -- the Arasan has the Wi-Fi
# function -- and since the card and the controller were both put on
# four lines it is the one that works: whole-word transfers, a DMA
# path verified in both directions, and the read, write, FAT and
# kupdate suite passing with no failures.  The Arasan's DMA write
# stall is still unexplained and it runs in PIO.
#
# Point this back at sdM0 to work on the Arasan.  Take care committing
# it either way: this line was accidentally committed as sdN0 once,
# from a local edit left in the tree.
SDDEV: con "/dev/sdN0";
KFSPART: con SDDEV + "/kfstest";

# the IP interface's control fd, held so the interface outlives the
# function that made it
ipctl: ref Sys->FD;

# The first FAT partition in the master boot record: (start, sectors),
# or (0, 0).  Everything that carves up this card starts here, because
# the card holds the firmware and the kernel that booted it.
fatpart(): (int, int)
{
	fd := sys->open(SDDEV + "/data", Sys->OREAD);
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

# When DHCP gets no answer, take the address from the card instead:
# /n/dos/ipconfig.txt holds "ip mask gw".  A board that cannot be reached
# cannot be worked on, and a router that will not answer DHCP should not
# be the end of it.
staticip(cfd: ref Sys->FD)
{
	fd := sys->open("/n/dos/ipconfig.txt", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	fd = nil;
	if(n <= 0)
		return;
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 2){
		sys->print("STATIC-FAIL want \"ip mask [gw]\" in ipconfig.txt\n");
		return;
	}
	ip := hd f;
	mask := hd tl f;
	if(sys->fprint(cfd, "add %s %s", ip, mask) < 0){
		sys->print("STATIC-FAIL add %s %s: %r\n", ip, mask);
		return;
	}
	if(nf >= 3){
		gw := hd tl tl f;
		rfd := sys->open("/net/iproute", Sys->ORDWR);
		if(rfd != nil && sys->fprint(rfd, "add 0.0.0.0 0.0.0.0 %s", gw) < 0)
			sys->print("STATIC route %s: %r\n", gw);
	}
	sys->print("STATIC-OK %s %s\n", ip, mask);
}

# What the IP stack sees, printed to the console: with the router
# changed, the question is whether the board's packets leave and whether
# anything comes back, which the driver's own counters cannot answer.
# devip's log carries ip, icmp, udp and tcp; the interface's pktin and
# pktout say whether frames reach it at all.  Bounded, because this is a
# diagnostic and the console is also the shell.
netdebug()
{
	# Opt in: /n/dos/netdebug on the card turns this on.  It prints
	# every few seconds for an hour, which buries the boot's own
	# lines on a console whose scrollback is a hundred lines.
	on := 0;
	for(w := 0; w < 300 && !on; w++){
		if(sys->open("/n/dos/netdebug", Sys->OREAD) != nil)
			on = 1;
		else
			sys->sleep(100);
	}
	if(!on)
		return;

	# as soon as the stack exists, not once it has an address: the
	# interesting case is a DHCP exchange that gets no answer, and
	# waiting for the address it would have brought means logging
	# nothing at all, which is what happened on the first router change.
	# /net/log is one file, not a directory: reading it drains the log
	# and writing it is the control channel.  Asking for /net/log/ctl,
	# which is what a Plan 9 network device would have, got "file does
	# not exist" on every one of 600 tries and logged nothing at all.
	cfd: ref Sys->FD;
	for(i := 0; i < 600; i++){
		cfd = sys->open("/net/log", Sys->ORDWR);
		if(cfd != nil)
			break;
		sys->sleep(100);
	}
	if(cfd == nil){
		sys->print("NETLOG-NONE /net/log: %r\n");
		return;
	}
	# icmp and tcp only.  With udp and ipmsg on, other hosts' broadcast
	# chatter filled the log faster than it could be printed and the
	# reader hit its own limit within seconds of boot, so the one thing
	# being looked for - a ping arriving - never appeared.
	if(sys->fprint(cfd, "set icmp tcp") < 0){
		sys->print("NETLOG-FAIL set: %r\n");
		return;
	}
	spawn netcounters();
	fd := sys->open("/net/log", Sys->OREAD);
	if(fd == nil){
		sys->print("NETLOG-NONE read /net/log: %r\n");
		return;
	}
	buf := array[2048] of byte;
	for(i = 0; i < 20000; i++){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		sys->print("NETLOG %s", string buf[0:n]);
	}
	cfd = nil;
	sys->print("NETLOG-END\n");
}

# Reachability, asked for continuously rather than typed at the console:
# /n/dos/pingtest.txt names an address, and this says every twenty
# seconds whether the board can resolve it and get an answer.  A board
# whose ARP entry for the other end never leaves WAIT looks exactly like
# a board with no network at all, and the difference matters.
pingtest()
{
	# Opt in, with the rest of the network diagnostics: /n/dos/netdebug
	# turns this on as well.  A board that pings something every twenty
	# seconds for an hour and says so is a board whose console cannot
	# be read.
	on := 0;
	for(w := 0; w < 300 && !on; w++){
		if(sys->open("/n/dos/netdebug", Sys->OREAD) != nil)
			on = 1;
		else
			sys->sleep(100);
	}
	if(!on)
		return;

	# the FAT partition is mounted by another process a moment later
	fd: ref Sys->FD;
	for(i := 0; i < 300; i++){
		fd = sys->open("/n/dos/pingtest.txt", Sys->OREAD);
		if(fd != nil)
			break;
		sys->sleep(100);
	}
	if(fd == nil)
		return;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	fd = nil;
	if(n <= 0)
		return;
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 1)
		return;
	addr := hd f;
	for(i = 0; i < 300; i++){
		if(hasaddr())
			break;
		sys->sleep(100);
	}
	ping := load Command "/dis/ip/ping.dis";
	if(ping == nil){
		sys->print("PINGTEST-FAIL load ping: %r\n");
		return;
	}
	for(i = 0; i < 200; i++){
		sys->print("PINGTEST %s\n", addr);
		ping->init(nil, "ping" :: "-n" :: "2" :: addr :: nil);
		arp := sys->open("/net/arp", Sys->OREAD);
		if(arp != nil){
			ab := array[1024] of byte;
			an := sys->read(arp, ab, len ab);
			arp = nil;
			if(an > 0){
				(nil, al) := sys->tokenize(string ab[0:an], "\n");
				for(; al != nil; al = tl al)
					if(len hd al > 0 && stringinstr(hd al, addr))
						sys->print("PINGTEST-ARP %s\n", hd al);
			}
		}
		sys->sleep(20000);
	}
}

# is needle anywhere in s?
stringinstr(s: string, needle: string): int
{
	if(len needle == 0)
		return 1;
	for(i := 0; i + len needle <= len s; i++)
		if(s[i:i+len needle] == needle)
			return 1;
	return 0;
}

# The one check that runs whether or not the diagnostics are asked for.
#
# On the board the IPv4 conversation stopped: frames kept arriving and
# the kernel stopped taking them, which the ethernet server's own
# counters show as "in" climbing while "out" stands still and no read
# outstanding.  When that lasts, say so and make the kernel dump every
# process and the kernel-text addresses on its stack, because the
# process that stopped reading is a kproc and nothing in /prog shows
# it.  Once per boot: the dump is long, and a second one says nothing
# the first did not.
readerwatch()
{
	lastin := -1;
	lastout := -1;
	stuck := 0;
	for(i := 0; i < 20000; i++){
		sys->sleep(5000);
		fd := sys->open("/net.alt/ether/stats", Sys->OREAD);
		if(fd == nil)
			continue;
		b := array[2048] of byte;
		n := sys->read(fd, b, len b);
		fd = nil;
		if(n <= 0)
			continue;
		(nil, lines) := sys->tokenize(string b[0:n], "\n");
		for(; lines != nil; lines = tl lines){
			(nf, f) := sys->tokenize(hd lines, " \t");
			if(nf < 4 || hd f != "conv" || hd tl f != "0")
				continue;
			in := -1; out := -1; waiting := -1;
			for(l := f; l != nil && tl l != nil; l = tl l){
				case hd l {
				"in" =>		in = int hd tl l;
				"out" =>	out = int hd tl l;
				"waiting" =>	waiting = int hd tl l;
				}
			}
			if(in < 0 || out < 0)
				break;
			if(in > lastin && out == lastout && waiting == 0)
				stuck++;
			else
				stuck = 0;
			lastin = in;
			lastout = out;
			if(stuck == 3){
				sys->print("READER-STALL ipv4 in %d out %d, no read outstanding; kernel processes follow\n",
					in, out);
				cfd := sys->open("/dev/sysctl", Sys->OWRITE);
				if(cfd == nil || sys->fprint(cfd, "procdump") < 0)
					sys->print("READER-STALL cannot procdump: %r\n");
				return;
			}
			break;
		}
	}
}

# the interface's own counters, which say whether frames arrive at all
netcounters()
{
	last := "";
	lastarp := "";
	lasticmp := "";
	lasttx := "";
	for(i := 0; i < 1200; i++){
		fd := sys->open("/net/ipifc/0/status", Sys->OREAD);
		if(fd == nil)
			return;
		b := array[512] of byte;
		n := sys->read(fd, b, len b);
		fd = nil;
		if(n <= 0)
			return;
		(nil, f) := sys->tokenize(string b[0:n], " \t\r\n");
		in := ""; out := "";
		for(l := f; l != nil; l = tl l){
			if(hd l == "pktin" && tl l != nil)
				in = hd tl l;
			if(hd l == "pktout" && tl l != nil)
				out = hd tl l;
		}
		now := "pktin " + in + " pktout " + out;
		if(now != last)
			sys->print("NETCOUNT %s\n", now);
		last = now;
		# and what the ethernet server did with the frames the kernel
		# handed it: the two counts either side of the bulk endpoint
		tx := sys->open("/net.alt/ether/stats", Sys->OREAD);
		if(tx != nil){
			tb := array[2048] of byte;
			tn := sys->read(tx, tb, len tb);
			tx = nil;
			ts := "";
			if(tn > 0)
				ts = string tb[0:tn];
			if(ts != lasttx && ts != ""){
				(nil, tls) := sys->tokenize(ts, "\n");
				for(tl2 := tls; tl2 != nil; tl2 = tl tl2)
					sys->print("NETTX %s\n", hd tl2);
			}
			lasttx = ts;
		}
		# What ICMP itself saw: InMsgs counts echo requests that reached
		# the protocol, OutMsgs the replies it handed back to IP.  A ping
		# that is answered in the ARP table but not in ICMP is either not
		# reaching icmpiput or not leaving after it does, and these two
		# numbers say which.
		st := sys->open("/net/icmp/stats", Sys->OREAD);
		if(st != nil){
			sb := array[1024] of byte;
			sn := sys->read(st, sb, len sb);
			st = nil;
			ss := "";
			if(sn > 0){
				(nil, sf) := sys->tokenize(string sb[0:sn], " \t\r\n");
				for(sl := sf; sl != nil && tl sl != nil; sl = tl tl sl)
					if(hd sl == "InMsgs:" || hd sl == "OutMsgs:"
					|| hd sl == "InErrors:" || hd sl == "CsumErrs:"
					|| hd sl == "LenErrs:" || hd sl == "HlenErrs:")
						ss += " " + hd sl + hd tl sl;
			}
			if(ss != lasticmp && ss != "")
				sys->print("NETICMP%s\n", ss);
			lasticmp = ss;
		}
		# Who the board thinks it can reach: an ARP table that stays
		# empty says nothing on this wire ever answered, which is a
		# different failure from packets that leave and are dropped.
		arp := sys->open("/net/arp", Sys->OREAD);
		if(arp != nil){
			ab := array[2048] of byte;
			an := sys->read(arp, ab, len ab);
			arp = nil;
			s := "";
			if(an > 0)
				s = string ab[0:an];
			if(s != lastarp){
				if(s == "")
					sys->print("NETARP empty\n");
				else
					sys->print("NETARP %s", s);
			}
			lastarp = s;
		}
		sys->sleep(3000);
	}
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
#
# A running sum over what was fetched, and the same sum over what
# landed on the card.
#
# Not a checksum anyone should trust against an adversary; it is here
# to catch a write path that drops whole 32KB chunks and says it
# didn't, which is what this board did.  Position matters -- the
# multiply by 31 is what makes two chunks in the wrong order fail --
# and it is arithmetic on an int, so it costs nothing next to the I/O.
#
kusum(sum: int, b: array of byte, n: int): int
{
	for(i := 0; i < n; i++)
		sum = sum * 31 + int b[i];
	return sum;
}
#
# The kernel update used to live here: kuverify() and kupdate(), a
# little over two hundred lines that dialled the host, mounted it,
# read the new kernel in 8KB chunks with a running byte count,
# checksummed what had landed on the card and renamed twice.
#
# It is a shell script now, in board.cmd, run by remotecmd() with the
# host already mounted on /n/remote:
#
#	cp $K /n/dos/kernel8.new
#	cmp $K /n/dos/kernel8.new
#	cp /n/dos/kernel8.new /n/dos/kernel8.img
#	cmp $K /n/dos/kernel8.img
#
# cmp is the checksum, and it compares against the source rather than
# against a number computed from it.  The script's output goes to
# board.out on the host, so a failed update says which line failed and
# says it somewhere that can be read without the board's console --
# which is the part that mattered.  The Limbo version reported only to
# the console, and when the console was lost, or another program was
# printing over it, an update that had stopped was indistinguishable
# from one still running.
#

#
# The card's two big writers, in the order they must not overlap.
#
# 1.9MB of kernel and 1.5MB of test data through one dossrv at the
# same time produced a kernel whose first 208KB were the previous
# kernel's bytes -- measured off the card in a reader, after it
# refused to boot.  One after the other, in one process, is all that
# is needed to stop that.
#
#
# Set when kupdate and fatwrite have finished with /n/remote.
#
# Both they and remotecmd mount the host on the SAME mount point, and
# remotecmd polls every three seconds -- so it was mounting and, worse,
# UNMOUNTING /n/remote underneath a kupdate that was part way through
# fetching 1.9MB.  kupdate simply stopped: no KUPDATE-OK, no failure
# message, nothing, because its fetch was reading through a mount that
# had been taken away.  One convenience quietly disabled the mechanism
# the board is actually updated by.
#
# kupdate runs once per boot, so waiting for it is enough and needs no
# lock: this flag only ever goes from 0 to 1, and only remotecmd reads
# it.
#
#
# Run the 1.5MB FAT write test at boot, or not.
#
# It is a good test -- it is how the card's throughput has been measured
# all along -- but it is also 1.5MB of writing on the boot path, and this
# board's card slowed from 92 KB/s to 35 KB/s and then stopped finishing
# it at all.  A boot that hangs there never starts the command poller,
# which is the only way in, so a failing card takes the whole board with
# it.  Off while the card is suspect; the throughput figure is not worth
# the boot.
#
fatbigok := 0;

kudone := 0;

#
# Set when an interface has been bound into /net AND has an address.
#
# remotecmd takes a PRIVATE namespace with FORKNS and then dials through
# it for the life of the boot.  Taken before ethercheck's
# sys->bind("#I", "/net", ...), that private namespace has no /net in it
# and no later bind can put one there, so every poll fails with "file
# does not exist" until the board is rebooted -- which is exactly what
# the bind's own comment a thousand lines below warns about, for a
# different reason.
#
# That race has always been here and usually won.  It lost on a kernel
# that did a little extra work early in main(), and the result was a
# board with a working card, a working network and a working shell that
# could not be reached by anything and had to be recovered over JTAG.
# Nothing about it looked like a namespace problem.
#
netdone := 0;

kuthenfat()
{
	fatwrite();
	kudone = 1;
}

unmountremote()
{
	sys->unmount(nil, "/n/remote");
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
	#
	# A wstat the server refuses arrives here as an exception, not as
	# -1: renaming onto a name that exists broke this process with
	# "file exists" rather than returning an error to be reported.
	# kupdate renames twice on every kernel update and would have gone
	# the same way.
	#
	r := -1;
	{
		r = sys->wstat(path, d);
	} exception {
	"*" =>
		return -1;
	}
	return r;
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

	#
	# Close it before renaming.  This check used to rename with that
	# read descriptor still open -- which is a fair thing to do and
	# the board says it does not work: the renamed file came back
	# zero bytes long, on a card whose fsck then reported
	# INFERNO2.TXT with a zero length and 512 clusters.  Every rename
	# that works here, including the two kupdate does on every kernel
	# it installs, is of a file nobody is holding.  So the two are
	# separated: this one is the rename that has to work, and the
	# held one below is the one being investigated, reported by its
	# own marker so it cannot be mistaken for this.
	#
	fd = nil;

	# And rename it, which is where FAT32 is easiest to get wrong: the
	# top half of a file's start cluster is kept in the directory
	# entry's reserved area, away from the low half, so a rename that
	# rewrites the entry without it points the new name at the cluster
	# number mod 65536.  On the board that turned a 1.6MB kernel into
	# 279704 bytes and emptied a directory whose clusters then looked
	# free.  Nothing below 65536 clusters can show it, which is why the
	# 4GB card's partition is 512MB.
	# Anything a previous boot left, first: a leftover target used to
	# poison every later boot, because a rename onto an existing name
	# removed the source entry before finding out.
	sys->remove("/n/dos/inferno2.txt");
	(ok, before) := sys->stat(name);
	if(ok < 0){
		sys->print("FAT-RENAME-FAIL stat %s: %r\n", name);
		return;
	}
	if(rename(name, "inferno2.txt") < 0){
		sys->print("FAT-RENAME-FAIL rename: %r\n");
		return;
	}
	(ok2, after) := sys->stat("/n/dos/inferno2.txt");
	if(ok2 < 0){
		sys->print("FAT-RENAME-FAIL stat after rename: %r\n");
		return;
	}
	if(after.length != before.length){
		sys->print("FAT-RENAME-FAIL %bd bytes before, %bd after\n",
			before.length, after.length);
		return;
	}
	rfd := sys->open("/n/dos/inferno2.txt", Sys->OREAD);
	rbuf := array[64] of byte;
	rn := 0;
	if(rfd != nil)
		rn = sys->read(rfd, rbuf, len rbuf);
	rfd = nil;
	if(rn != int after.length || string rbuf[0:rn] != msg){
		sys->print("FAT-RENAME-FAIL the renamed file does not read back\n");
		return;
	}
	sys->print("FAT-RENAME-OK %bd bytes, contents intact across a rename\n",
		after.length);

	# And a rename onto a name that exists must be refused, with the
	# source left whole.  Getting this wrong is not a failed rename,
	# it is a lost file: dossrv removed the old entry and then found
	# it could not make the new one, and said "phase error" while the
	# data went with it.  That is what happened to this board's own
	# kernel, renamed over kernel8.bak on every update.
	fd2 := sys->create(name, Sys->ORDWR, 8r666);
	if(fd2 == nil){
		sys->print("FAT-CLOBBER-FAIL create %s: %r\n", name);
		return;
	}
	b2 := array of byte msg;
	sys->write(fd2, b2, len b2);
	fd2 = nil;
	if(rename("/n/dos/inferno2.txt", "inferno.txt") >= 0){
		sys->print("FAT-CLOBBER-FAIL the rename onto an existing name was allowed\n");
		return;
	}
	(ok3, still) := sys->stat("/n/dos/inferno2.txt");
	if(ok3 < 0){
		sys->print("FAT-CLOBBER-FAIL the source is gone: %r\n");
		return;
	}
	if(still.length != after.length){
		sys->print("FAT-CLOBBER-FAIL the source is %bd bytes, was %bd\n",
			still.length, after.length);
		return;
	}
	sys->print("FAT-CLOBBER-OK refused, and the source is whole\n");
	sys->remove("/n/dos/inferno2.txt");
	fatheld();
	if(fatbigok)
		fatbig();
	else
		sys->print("FAT-BIG-SKIPPED (fatbigok is 0)\n");
}

#
# Rename a file while a descriptor is open on it.
#
# Held open, the same rename that passes above comes back zero bytes
# long on this board, and the host cannot be made to do it: fatstress
# does exactly this against three filesystems under emu and all three
# pass.  So the difference is here, and this is the instrument -- it
# says what the length was before, what it is after, and whether the
# descriptor that was held across the rename still reads what was
# written.
#
fatheld()
{
	name := "/n/dos/held.txt";
	msg := "held open across a rename\n";
	sys->remove("/n/dos/held2.txt");
	fd := sys->create(name, Sys->ORDWR, 8r666);
	if(fd == nil){
		sys->print("FAT-HELD-FAIL create: %r\n");
		return;
	}
	b := array of byte msg;
	if(sys->write(fd, b, len b) != len b){
		sys->print("FAT-HELD-FAIL write: %r\n");
		return;
	}
	fd = nil;
	# the descriptor that stays open across the rename
	held := sys->open(name, Sys->OREAD);
	if(held == nil){
		sys->print("FAT-HELD-FAIL open: %r\n");
		return;
	}
	rb := array[len b] of byte;
	if(sys->read(held, rb, len rb) != len b){
		sys->print("FAT-HELD-FAIL read: %r\n");
		return;
	}
	(ok, before) := sys->stat(name);
	if(ok < 0){
		sys->print("FAT-HELD-FAIL stat: %r\n");
		return;
	}
	if(rename(name, "held2.txt") < 0){
		sys->print("FAT-HELD-FAIL rename: %r\n");
		return;
	}
	(ok2, after) := sys->stat("/n/dos/held2.txt");
	if(ok2 < 0){
		sys->print("FAT-HELD-FAIL stat after: %r\n");
		return;
	}
	if(after.length != before.length){
		sys->print("FAT-HELD-FAIL %bd bytes before, %bd after, held open\n",
			before.length, after.length);
		# and what the held descriptor sees, which says whether the
		# data moved or only the entry's idea of it
		sys->seek(held, big 0, Sys->SEEKSTART);
		hn := sys->read(held, rb, len rb);
		sys->print("FAT-HELD the held descriptor reads %d bytes\n", hn);
		held = nil;
		sys->remove("/n/dos/held2.txt");
		return;
	}
	held = nil;
	sys->print("FAT-HELD-OK %bd bytes across a rename with the file open\n",
		after.length);
	sys->remove("/n/dos/held2.txt");
}

# A big file, because that is the one the board actually writes.
#
# kupdate fetches a kernel -- 1.7MB -- creates it, renames the old one
# aside and renames the new one into place.  The 29-byte check above
# passes on a filesystem where that loses data: the card the Pi boots
# from ended with 478MB of its 504MB allocated while its files came to
# 176MB, and a kernel8.img whose first cluster was right and whose
# later clusters held something else.  So write something of that size,
# read every byte back, and rename it.
Bigfile: con "/n/dos/bigfile.bin";
Bigsize: con 1500*1024;

fatbig()
{
	sys->remove("/n/dos/bigfile2.bin");
	sys->remove(Bigfile);
	fd := sys->create(Bigfile, Sys->ORDWR, 8r666);
	if(fd == nil){
		sys->print("FAT-BIG-FAIL create: %r\n");
		return;
	}
	b := array[4096] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte (i*7+1);
	n := 0;
	# timed, because this is the board's storage speed and nothing
	# here has ever said what it is: 1.5MB through dossrv, the SD
	# driver and the card, which is also what a kernel update costs
	t0 := sys->millisec();
	while(n < Bigsize){
		if(sys->write(fd, b, len b) != len b){
			sys->print("FAT-BIG-FAIL write at %d: %r\n", n);
			return;
		}
		n += len b;
	}
	fd = nil;
	if(fatbigcheck(Bigfile, n, b) < 0)
		return;
	if(rename(Bigfile, "bigfile2.bin") < 0){
		sys->print("FAT-BIG-FAIL rename: %r\n");
		return;
	}
	if(fatbigcheck("/n/dos/bigfile2.bin", n, b) < 0)
		return;
	sys->remove("/n/dos/bigfile2.bin");
	ms := sys->millisec() - t0;
	kbs := 0;
	if(ms > 0)
		kbs = (n/1024)*1000/ms;
	sys->print("FAT-BIG-OK %d bytes written, read back and renamed, %d ms (%d KB/s)\n",
		n, ms, kbs);
}

fatbigcheck(name: string, n: int, b: array of byte): int
{
	(ok, d) := sys->stat(name);
	if(ok < 0){
		sys->print("FAT-BIG-FAIL stat %s: %r\n", name);
		return -1;
	}
	if(int d.length != n){
		sys->print("FAT-BIG-FAIL %s is %bd bytes, wrote %d\n", name, d.length, n);
		return -1;
	}
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil){
		sys->print("FAT-BIG-FAIL open %s: %r\n", name);
		return -1;
	}
	r := array[len b] of byte;
	for(off := 0; off < n; off += len b){
		if(sys->read(fd, r, len r) != len r){
			sys->print("FAT-BIG-FAIL read at %d: %r\n", off);
			return -1;
		}
		for(i := 0; i < len r; i++)
			if(r[i] != b[i]){
				sys->print("FAT-BIG-FAIL %s differs at %d\n", name, off+i);
				return -1;
			}
	}
	return 0;
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
	cfd := sys->open(SDDEV + "/ctl", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "part dos %d %d", start, start+nsec) < 0){
		sys->print("FAT-FAIL part: %r\n");
		return;
	}
	cfd = nil;
	dos := load Command "/dis/dossrv.dis";
	if(dos == nil){
		sys->print("FAT-FAIL load dossrv: %r\n");
		return;
	}
	spawn dos->init(nil, "dossrv" :: "-f" :: SDDEV + "/dos" :: "-m" :: "/n/dos" :: nil);
	for(i := 0; i < 100; i++){
		(ok, d) := sys->stat("/n/dos/kernel8.img");
		if(ok == 0){
			sys->print("FAT-OK /n/dos/kernel8.img is %bd bytes\n", d.length);
			#
			# The update first, and ALONE.
			#
			# It used to run after the checks below, which is
			# fine until one of them is what the new kernel
			# fixes: a kernel that wedges during FAT-BIG never
			# reaches kupdate, so the board cannot replace it
			# and the card has to be carried to another machine.
			# That happened three times.  So it was spawned, to
			# run alongside them, on the reasoning that dossrv
			# serialises what they both touch.
			#
			# It does not serialise it usefully.  fatwrite()
			# writes 1.5MB while kupdate writes 1.9MB, through
			# one dossrv, to two different files, and the
			# kernel that comes out of it is a mixture: 14 of
			# 57 chunks holding the previous kernel's bytes,
			# once; a file differing from its source at byte 42
			# after three consecutive installs, today.  Each
			# time KUPDATE-VERIFY called it identical, because
			# that reads back through the same dossrv and gets
			# what was written rather than what reached the
			# card.
			#
			# Running it first and by itself keeps the reason it
			# was moved -- it still happens before anything that
			# can wedge -- and removes the second writer.
			#
			# But not on this process.  kupdate waits up to five
			# minutes for the IP stack to have an address, and
			# calling it here blocks fatcheck for the whole of
			# that wait, so FAT-BIG never runs at all -- which is
			# exactly what the first attempt at this did.  The
			# pair goes into one spawned process instead: the two
			# writers are serialised with each other, and neither
			# is on the boot's timeline.
			#
			spawn kuthenfat();
			return;
		}
		sys->sleep(100);
	}
	sys->print("FAT-FAIL no /n/dos/kernel8.img: %r\n");
}

# Smallest gap worth handing to kfs: 512 sectors, a quarter of a
# megabyte.  The test writes one file, so this is about kfs having room
# for a superblock and a free list, not about capacity.
Minkfs: con 512;

# Does the gap read as zeros?  Checked in whole sectors, at both ends
# and in the middle rather than all through: this runs on every boot and
# a megabyte of reads through the SD driver is not free.
gapisclear(first, last: int): int
{
	fd := sys->open(SDDEV + "/data", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[512] of byte;
	probes := list of {first, (first+last)/2, last};
	for(; probes != nil; probes = tl probes){
		sec := hd probes;
		if(sys->pread(fd, buf, len buf, big sec * big 512) != len buf)
			return 0;
		for(i := 0; i < len buf; i++)
			if(buf[i] != byte 0)
				return 0;
	}
	return 1;
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
	#
	# Use the gap that is actually there, and prove it is empty first.
	#
	# This asked for sectors 2048 to fstart-1 and refused unless fstart
	# was at least 4096.  That fits the old card, whose filesystem began
	# well up the device, and not the new one, whose filesystem begins
	# at 2048 -- so the range was inverted and the test simply stopped
	# running, reporting "no room below the first partition at 2048" on
	# every boot.  The gap on that card is real, it is just BELOW 2048
	# rather than above it.
	#
	# Sector 0 is the master boot record and is left alone.  kfs is
	# given "-r", which reams what it is handed, so what it is handed
	# had better not be anybody's data: the sectors are read and checked
	# to be zero before the partition is made.  The old code asserted
	# that in a comment -- "unallocated and reads as zeros on this card"
	# -- about one particular card, which is exactly the kind of thing
	# that stops being true when the card is swapped.
	#
	kstart := 1;
	kend := fstart - 1;		# last sector of the gap
	if(kend - kstart + 1 < Minkfs){
		sys->print("SD-FS skipped: gap below the partition at %d is %d sectors, need %d\n",
			fstart, kend - kstart + 1, Minkfs);
		return;
	}
	if(!gapisclear(kstart, kend)){
		sys->print("SD-FS skipped: sectors %d-%d are not empty; not reaming them\n",
			kstart, kend);
		return;
	}
	cfd := sys->open(SDDEV + "/ctl", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "part kfstest %d %d", kstart, kend) < 0){
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

# Is libtk in this kernel, and does it draw?
#
# Loading $Tk answers the first half: the module is built in, not a
# dis file, so a successful load means the config's mod section
# reached tkmodinit() and libtk linked.  That is worth little on its
# own - a module can register and still draw nothing - so the second
# half lays out a real widget and COUNTS THE INK.
#
# Into an image of its own rather than onto the framebuffer, for the
# reason tkofftest(1) gives: what a widget put on the screen cannot be
# read back, while an allocated image can.  RGB24 so that three bytes
# is one pixel here whatever the screen's own channel is.
#
# The count is against white, which the image was filled with, so any
# non-white pixel came from Tk.  A label that laid out but drew
# nothing reports TK-NONE rather than TK-OK, which is the case this
# would otherwise pass straight through.
# How long does this board take to paint a screenful?
#
# This is the number the GPU question turns on.  doc/ui-next-plan.md on
# the inferno-rio branch gates a hardware backend on a repaint costing
# roughly 2ms of DRAWING; on an Apple M-series host a 900x700 fill is
# about 56us, thirty times under, which is why that work stayed on
# memdraw.  A Pi 3 shares one LPDDR2 controller between the ARM and the
# VideoCore, so the same fill is expected to cost far more here - but
# expected is not measured, and nothing had ever measured it.
#
# Two numbers, because the board pays twice for every pixel.  The first
# is memdraw alone, filling an image of its own.  The second is the
# same fill into the screen plus flushmemscreen(), which memmoves the
# dirty rectangle from kernel RAM into the VideoCore's uncached
# framebuffer and cleans the cache over it (screenbcm.c).  The gap
# between them IS the soft->fb copy, which is the first thing worth
# removing if these numbers are large.
#
# UNDER QEMU THESE MEAN NOTHING.  QEMU emulates the CPU and runs the
# memory system at the host's speed, so what this prints there is a
# property of the desktop it is running on.  Read it on silicon.
drawrate()
{
	disp: ref Display;
	{ disp = Display.allocate("/dev"); }
	exception e { "*" => sys->print("DRAWRATE-FAIL Display: %s\n", e); return; }
	if(disp == nil){
		sys->print("DRAWRATE-FAIL nil display: %r\n");
		return;
	}
	scr := disp.image;
	r := scr.r;
	npix := (r.max.x - r.min.x) * (r.max.y - r.min.y);
	off := disp.newimage(r, scr.chans, 0, Draw->White);
	if(off == nil){
		sys->print("DRAWRATE-FAIL newimage: %r\n");
		return;
	}
	col := disp.rgb(40, 80, 160);
	if(col == nil){
		sys->print("DRAWRATE-FAIL rgb: %r\n");
		return;
	}
	# Run until the elapsed time is big enough to divide, rather than a
	# fixed count.  A fixed fifty came back "0 us a fill" - sys->millisec()
	# has millisecond resolution and fifty fills fit inside one tick - and
	# a zero is not a fast number, it is a failed measurement.
	Minms: con 200;

	# warm once, so a first-call cost is not counted as the steady one
	off.draw(r, col, nil, (0,0));

	nd := 0;
	t0 := sys->millisec();
	for(;;){
		off.draw(r, col, nil, (0,0));
		nd++;
		if(sys->millisec() - t0 >= Minms)
			break;
	}
	t1 := sys->millisec();

	ns := 0;
	for(;;){
		scr.draw(r, col, nil, (0,0));
		scr.flush(Draw->Flushnow);
		ns++;
		if(sys->millisec() - t1 >= Minms)
			break;
	}
	t2 := sys->millisec();

	if(nd <= 0 || ns <= 0 || t1 - t0 <= 0 || t2 - t1 <= 0){
		sys->print("DRAWRATE-FAIL nothing measurable (%d,%d fills)\n", nd, ns);
		return;
	}
	drawus := ((t1 - t0) * 1000) / nd;
	scrus := ((t2 - t1) * 1000) / ns;
	sys->print("DRAWRATE-OK %dx%d (%d pixels): memdraw %d us a fill over %d, screen+flush %d us a fill over %d\n",
		r.max.x - r.min.x, r.max.y - r.min.y, npix, drawus, nd, scrus, ns);
	sys->print("DRAWRATE-NOTE meaningless under QEMU; read it on the board\n");
}

# Render a label of the given text into a fresh image and hand back
# its pixels.  A toplevel of its own each time, because reconfiguring
# one and reading it again measures whatever the reconfigure happened
# to repaint, which is not the question.
tklabel(disp: ref Display, txt: string, w, h: int): array of byte
{
	off := disp.newimage(Rect((0,0),(w,h)), draw->RGB24, 0, Draw->White);
	if(off == nil){
		sys->print("TK-FAIL newimage: %r\n");
		return nil;
	}
	top := tk->toplevel(disp, "");
	if(top == nil){
		sys->print("TK-FAIL toplevel: %r\n");
		return nil;
	}
	c := tk->cmd(top, "label .l -text " + tk->quote(txt));
	if(c != nil && len c > 0 && c[0] == '!'){
		sys->print("TK-FAIL label: %s\n", c);
		return nil;
	}
	tk->cmd(top, "pack .l");
	if((c = tk->putimage(top, ". -1", off, nil)) != nil && len c > 0){
		sys->print("TK-FAIL putimage: %s\n", c);
		return nil;
	}
	tk->cmd(top, "update");
	b := array[w*h*3] of byte;
	if(off.readpixels(off.r, b) != len b){
		sys->print("TK-FAIL readpixels: %r\n");
		return nil;
	}
	return b;
}

tktest()
{
	tk = load Tk Tk->PATH;
	if(tk == nil){
		sys->print("TK-FAIL load $Tk: %r\n");
		return;
	}
	disp: ref Display;
	{ disp = Display.allocate("/dev"); }
	exception e { "*" => sys->print("TK-FAIL Display: %s\n", e); return; }
	if(disp == nil){
		sys->print("TK-FAIL nil display: %r\n");
		return;
	}
	W := 160;
	H := 40;

	# Counting pixels that are not the WHITE the image was filled with
	# says only that SOMETHING painted, and a label paints its whole
	# rectangle in its own background before it draws a glyph - that
	# count came back 6400 of 6400 and could not tell a rendered word
	# from a blank fill.  A saturated instrument reads exactly like a
	# working one.
	#
	# So render the same label twice, once with a word in it and once
	# empty, and compare.  Whatever differs is the glyphs.
	a := tklabel(disp, "Inferno", W, H);
	if(a == nil)
		return;
	c := tklabel(disp, "", W, H);
	if(c == nil)
		return;
	fill := 0;
	for(i := 0; i < len a; i += 3)
		if(a[i] != byte 255 || a[i+1] != byte 255 || a[i+2] != byte 255)
			fill++;
	ink := 0;
	for(i = 0; i < len a; i++)
		if(a[i] != c[i])
			ink++;
	if(fill == 0){
		sys->print("TK-NONE $Tk loaded but a label drew nothing at all\n");
		return;
	}
	if(ink == 0){
		sys->print("TK-NONE $Tk laid out a label (%d of %d pixels filled) but its text drew nothing\n",
			fill, W*H);
		return;
	}
	sys->print("TK-OK $Tk is built in; a label filled %d of %d pixels and its text inked %d bytes\n",
		fill, W*H, ink);
}

# has usbd enumerated anything besides the root hub?  Its ctl file has a
# line per endpoint, and ep1.0 is the root hub itself.
usbdevices(): int
{
	(n, f) := sys->tokenize(readctl("/dev/usb/ctl"), "\n");
	n = n;
	for(; f != nil; f = tl f){
		l := hd f;
		if(len l > 3 && l[0:2] == "ep" && l[0:5] != "ep1.0")
			return 1;
	}
	return 0;
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
	# A USB boot keyboard delivers UTF-8 keystrokes to /dev/keyboard.
	# Both checks are spawned: each waits a bounded time for input that
	# only comes if the device is attached, and the boot should not
	# stall for that.
	spawn kbdcheck();
	spawn mousecheck();
	spawn diskcheck();
}

#
# The radio, from the card.
#
# Three things have to arrive from outside the kernel before the BCM43430
# will do anything: the firmware image, its nvram, and the regulatory
# blob.  The kernel cannot read them -- the SDIO bring-up runs in main()
# long before any filesystem -- so they go in through #H from here, off
# the same FAT partition the kernel itself boots from.
#
# The credentials come from there too, and not from this file.  The
# passphrase is the user's, this source is in a git repository, and the
# two must not meet: /n/dos/wifi.cfg holds one line, "ssid passphrase",
# and is written onto the card directly.  A board whose card has no
# wifi.cfg brings up no radio and says so once, which is the right
# behaviour for a kernel that also runs under qemu with no radio at all.
#
# Nothing below is printed that would disclose the passphrase.  It is
# passed to the kernel in a single write and the kernel does not log it
# either.
#
# This is slow -- about 400KB over SDIO, then an association -- so it
# runs in its own process and nothing waits for it.
#
#
# Bluetooth: patch the controller once, then serve it.
#
# The BCM43438's ROM answers HCI Reset and little else; the rest of it
# is a patch file the host downloads over the same UART (btbcm.c in the
# kernel proves the controller answers at all, and stops there, because
# the download needs a filesystem).  The file is on the card, as the
# radio's firmware is, and for the same reason.
#
# ORDER MATTERS, and it is why this is here rather than left to a
# person at the shell.  A patch may only be written to a controller
# that has not been patched, and the only thing on this board that can
# un-patch one is btbcm.c's power cycle at boot -- BT_ON is a line on
# the VideoCore's expander and it survives a warm restart.  So the one
# safe moment to do this is exactly once, just after boot, which is
# here.  Running bt/bcmfw twice by hand is how the controller was
# bricked-until-power-cycled twice during this work.
#
# set when btcheck has finished, however it finished: the radio's
# firmware push must not run at the same time as the controller's
btdone := 0;

btcheck()
{
	#
	# Wait for the card, as wificheck does and for the same reason:
	# this is spawned alongside the SD checks that mount it.
	#
	hcd := "/n/dos/bt43430a.hcd";
	for(w := 0; w < 600; w++){
		if(sys->open(hcd, Sys->OREAD) != nil)
			break;
		sys->sleep(100);
	}
	if(sys->open(hcd, Sys->OREAD) == nil){
		sys->print("BT-NONE (no %s)\n", hcd);
		btdone = 1;
		return;
	}
	bcmfw := load Command "/dis/bt/bcmfw.dis";
	if(bcmfw == nil){
		sys->print("BT-NONE (no bcmfw: %r)\n");
		btdone = 1;
		return;
	}
	spec := "#t/eia0!115200!fc";
	#
	# Each of these is a command module, and a command module's init()
	# is a process body: it exits its caller when it finishes.  So both
	# run in processes of their own, and this one waits on a marker
	# rather than on a return.
	#
	#
	# WAIT for the download, do not guess at it.
	#
	# This slept six seconds between starting bcmfw and starting btfs,
	# and the two speak to the same UART.  On a busy boot the download
	# takes longer than that, so btfs opened the line in the middle of
	# it and both talked at once: measured over eight boots, five
	# served Bluetooth and three did not, and two of the three had no
	# BCMFW-OK at all -- btfs racing a download still in progress.
	#
	# waitgone() on the child's pid is what the rest of this file does
	# for exactly this, and it is not a guess.
	#
	pidch := chan of int;
	spawn cmdproc(bcmfw, "bcmfw" :: spec :: hcd :: nil, pidch);
	waitgone(<-pidch);

	btfs := load Command "/dis/bt/btfs.dis";
	if(btfs == nil){
		sys->print("BT-NONE (no btfs: %r)\n");
		btdone = 1;
		return;
	}
	#
	# And try btfs more than once.
	#
	# The third of those three failures had BCMFW-OK above it and still
	# reported "reset: no answer to command 0x0c03": the controller
	# restarts on the patched firmware as the download ends, and a
	# single HCI Reset aimed at it can arrive while it is still coming
	# back.  Re-running btfs is safe -- the patch is already in, and
	# btfs only resets and talks -- so it is retried rather than left
	# as a boot that quietly has no Bluetooth.
	#
	# NOT EXERCISED.  Eight boots after the wait above was fixed served
	# Bluetooth eight times and none of them printed BT-RETRY, so this
	# path has never actually run.  It compiles and it reads correctly
	# and that is the whole of the confidence in it; the measured fix is
	# the waitgone() above, not this.
	#
	for(a := 0; a < 3; a++){
		sys->sleep(1000);
		spawn btfs->init(nil, "btfs" :: "-m" :: "/n/bt" :: spec :: nil);
		for(i := 0; i < 80; i++){
			if(sys->open("/n/bt/0", Sys->OREAD) != nil){
				sys->print("BT-SERVING /n/bt/0\n");
				btdone = 1;
				return;
			}
			sys->sleep(100);
		}
		sys->print("BT-RETRY btfs attempt %d served nothing\n", a + 1);
	}
	sys->print("BT-FAIL btfs served nothing at /n/bt in 3 attempts\n");
	btdone = 1;
}

wificheck()
{
	#
	# Wait for the card, but only for as long as it might still be
	# coming.
	#
	# This is spawned from the same place as everything else at the end
	# of boot, and /n/dos is mounted by the SD checks running
	# alongside it -- so the first version looked once, found nothing,
	# and printed WIFI-NONE on a board whose card had the firmware on
	# it.  The mount appears within seconds when it appears at all; a
	# minute is generous and a board with no card waits alone.
	#
	cfg := "";
	for(w := 0; w < 600; w++){
		cfg = readctl("/n/dos/wifi.cfg");
		if(cfg != nil)
			break;
		sys->sleep(100);
	}
	if(cfg == nil){
		sys->print("WIFI-NONE (no /n/dos/wifi.cfg)\n");
		return;
	}
	(nt, toks) := sys->tokenize(cfg, " \t\r\n");
	if(nt < 2){
		sys->print("WIFI-NONE (wifi.cfg is not 'ssid passphrase')\n");
		return;
	}
	ssid := hd toks;
	pass := hd tl toks;

	#
	# #H is not in /dev unless something puts it there.  Bind it in the
	# shared namespace rather than opening "#H/wifictl" here, so that
	# the files this uses are the same files a person at the shell can
	# use -- which is what devwifi.c's own description assumes.
	#
	if(sys->bind("#H", "/dev", Sys->MAFTER) < 0){
		sys->print("WIFI-NONE (cannot bind #H: %r)\n");
		return;
	}
	#
	# Not at the same time as the Bluetooth download.
	#
	# Both radios are halves of the same chip and both want their
	# firmware at boot, but they do not compete for the chip -- they
	# compete for the CPU.  This kernel schedules one core, and pushing
	# 400KB into the Wi-Fi side over SDIO starves everything else for
	# seconds at a time; bt/bcmfw, waiting on a UART reply with a five
	# second bound, gave up 106 records into 121.  Run by hand
	# afterwards, on a quiet board, the same download completes every
	# time.  That is a scheduling collision, not a Bluetooth fault, and
	# the fix is to take turns.  Bluetooth goes first because it is
	# 30KB at 115200 and over in a few seconds.
	#
	for(b := 0; b < 900 && !btdone; b++)
		sys->sleep(100);
	if(!btdone)
		sys->print("WIFI-WAITED 90 s for the bluetooth download\n");

	ctl := sys->open("/dev/wifictl", Sys->OWRITE);
	if(ctl == nil){
		sys->print("WIFI-NONE (no /dev/wifictl: %r)\n");
		return;
	}
	if(sys->fprint(ctl, "bringup") < 0){
		sys->print("WIFI-FAIL bringup: %r\n");
		return;
	}
	#
	# Each blob: name the mode, push the bytes, say end.  The order
	# matters -- the firmware has to be running before it will take a
	# regulatory blob, so clm comes after go and enable.
	#
	if(wifiblob(ctl, "fw", "/n/dos/brcmfw.bin") < 0 ||
	   wifiblob(ctl, "nvram", "/n/dos/brcmnv.txt") < 0)
		return;
	#
	# One marker per step.  These writes print nothing of their own on
	# success, so a boot that stopped between them could not be told
	# from one that stopped in the upload before them.
	#
	if(sys->fprint(ctl, "go") < 0){
		sys->print("WIFI-FAIL go: %r\n");
		return;
	}
	sys->print("WIFI-GO\n");
	if(sys->fprint(ctl, "enable") < 0){
		sys->print("WIFI-FAIL enable: %r\n");
		return;
	}
	sys->print("WIFI-ENABLE\n");
	if(wifiblob(ctl, "clm", "/n/dos/brcmclm.bin") < 0)
		return;
	if(sys->fprint(ctl, "init") < 0){
		sys->print("WIFI-FAIL init: %r\n");
		return;
	}
	sys->print("WIFI-FW-OK\n");
	if(sys->fprint(ctl, "join %s %s", ssid, pass) < 0){
		sys->print("WIFI-FAIL join %s: %r\n", ssid);
		return;
	}
	sys->print("WIFI-JOINED %s\n", ssid);

	#
	# Its own IP stack.
	#
	# The wired adapter already owns /net, and both are on the same
	# subnet behind the same router.  Giving the radio a second stack
	# at /net.wifi keeps the two sets of routes from arguing, and means
	# a radio that misbehaves cannot take the wired network -- which is
	# how this board is reached -- down with it.
	#
	if(sys->bind("#I1", "/net.wifi", Sys->MREPL) < 0){
		sys->print("WIFI-FAIL bind #I1: %r\n");
		return;
	}
	# As with the wired interface, the clone fd IS the interface: hold
	# it or devip unbinds the ether the moment this function returns.
	cfd := sys->open("/net.wifi/ipifc/clone", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "bind ether #l0/ether0") < 0){
		sys->print("WIFI-FAIL bind ether: %r\n");
		return;
	}
	ipctls = cfd :: ipctls;
	sys->print("WIFIBIND-OK\n");
	if(dhcpclient == nil){
		dhcpclient = load Dhcpclient Dhcpclient->PATH;
		if(dhcpclient == nil){
			sys->print("WIFI-FAIL load dhcpclient: %r\n");
			return;
		}
		dhcpclient->init();
	}
	cfg2 := Bootconf.new();
	#
	# Say who we are.  A board that takes a lease without a hostname is
	# a bare address in the router's client list, and this one has two
	# interfaces on the same subnet -- so they are named apart, and the
	# radio gets the plain name because it is the interesting one.
	#
	cfg2.puts(Dhcpclient->Ohostname, "inferno-pi");
	lease: ref Lease;
	err: string;
	(cfg2, lease, err) = dhcpclient->dhcp("/net.wifi", cfd,
		"#l0/ether0/addr", cfg2, nil);
	if(err != nil || cfg2 == nil || cfg2.ip == nil){
		sys->print("WIFI-DHCP-FAIL %s\n", err);
		return;
	}
	sys->print("WIFI-DHCP-OK ip=%s gw=%s\n", cfg2.ip, cfg2.ipgw);
	lease = nil;
}

#
# One blob into the radio.  Written in pieces because #H takes whatever
# size it is given and puts it straight into the chip at a running
# offset, and a short write is a firmware image with a hole in it.
#
wifiblob(ctl: ref Sys->FD, mode, path: string): int
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		sys->print("WIFI-FAIL open %s: %r\n", path);
		return -1;
	}
	if(sys->fprint(ctl, "%s", mode) < 0){
		sys->print("WIFI-FAIL %s: %r\n", mode);
		return -1;
	}
	data := sys->open("/dev/wifidata", Sys->OWRITE);
	if(data == nil){
		sys->print("WIFI-FAIL open wifidata: %r\n");
		return -1;
	}
	buf := array[8192] of byte;
	total := 0;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			sys->print("WIFI-FAIL read %s: %r\n", path);
			return -1;
		}
		if(n == 0)
			break;
		if(sys->write(data, buf, n) != n){
			sys->print("WIFI-FAIL write %s at %d: %r\n", path, total);
			return -1;
		}
		total += n;
	}
	data = nil;
	if(sys->fprint(ctl, "end") < 0){
		sys->print("WIFI-FAIL end %s: %r\n", mode);
		return -1;
	}
	sys->print("WIFI-%s %d bytes\n", mode, total);
	return 0;
}

ethercheck()
{
	#
	# Sixty seconds, not ten.  This waits for usbd to enumerate the
	# hub and the NIC behind it and for etherusb to serve its
	# directory, and on a boot where the SD checks and kfs are
	# running at the same time that took longer than ten: the board
	# printed ETHER-NONE while etherusb was up and talking to the
	# chip, and with no /net bound the whole boot had no network --
	# no kupdate, and no way to reach the board but the console.
	# There is nothing to lose by waiting: this runs in its own
	# process, and a board with no adapter waits alone.
	#
	etherone("ether", "ETHER", 600, nil, nil, nil);

	# A second adapter, if there is one.  usbd names the first netif
	# directory "ether" and the rest "ether1", "ether2", so a board
	# with two USB ethernets has two directories to bind.  The wait is
	# short because the first call already waited out enumeration.
	# Nothing is printed when there is no second one.
	if(sys->open("/net.alt/ether1/addr", Sys->OREAD) != nil)
		etherone("ether1", "ETHER2", 20, "10.0.3.15", "255.255.255.0", "10.0.3.2");
}

# the IP interfaces' control fds, held so each interface outlives the
# function that made it
ipctls: list of ref Sys->FD;

etherone(ifname, tag: string, tries: int, ip, mask, gw: string)
{
	dir := "/net.alt/" + ifname;
	addr := dir + "/addr";
	#
	# Wait long, but only for an adapter that exists.
	#
	# Ten seconds was too short: the board printed ETHER-NONE and
	# etherusb started serving immediately afterwards, and with no
	# /net bound that whole boot had no network.  A flat minute is too
	# long the other way -- on a machine with no USB ethernet at all,
	# which is every QEMU raspi3b boot, it is a minute of silence, and
	# the marker suite stops six seconds after the last thing printed.
	#
	# So ask usbd what is attached.  Its ctl file names every endpoint
	# it has enumerated, and a machine with nothing but the root hub
	# has nothing to wait for.  A board with the LAN9514 behind its hub
	# has ep2.0 and ep3.0 there within a second or two, long before
	# etherusb is serving.
	#
	#
	# No deadline, because every deadline tried here has been wrong.
	# Ten seconds: the board printed ETHER-NONE and etherusb served
	# immediately after.  Sixty: the same thing again, with etherusb
	# printing "link up" early and taking longer than a minute to
	# serve.  The board is not slow in a way that can be guessed at.
	#
	# What can be asked is whether there is an adapter at all, and
	# usbd's ctl file answers that in a second or two -- so wait as
	# long as the hardware is there, and give up at once when it is
	# not.  This runs in its own process; nothing waits on it.
	# Progress every ten seconds so a console shows the difference
	# between waiting and wedged.
	#
	for(i := 0; ; i++){
		if(sys->open(addr, Sys->OREAD) != nil)
			break;
		if(i >= 100 && !usbdevices()){
			sys->print("%s-NONE (no USB device to serve ethernet)\n", tag);
			return;
		}
		if(i > 0 && i % 100 == 0)
			sys->print("%s-WAIT %d s for %s\n", tag, i/10, addr);
		sys->sleep(100);
	}
	if(sys->open(addr, Sys->OREAD) == nil){
		sys->print("%s-NONE (no USB ethernet served at %s after %d ms)\n",
			tag, addr, tries*100);
		return;
	}
	if(i > 0)
		sys->print("%s-WAITED %d ms for %s\n", tag, i*100, addr);
	sys->bind("#I", "/net", Sys->MAFTER);
	# The fd returned by opening the clone file IS the interface: when the
	# last reference to it goes, devip unbinds the ether and the address
	# with it.  Holding it in a module variable keeps the interface for
	# the life of init - without that the board answered pings while this
	# function ran and went silent the moment it returned, and anything
	# dialling later got "file does not exist".
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "bind ether %s", dir) < 0){
		sys->print("%s-FAIL bind ether: %r\n", tag);
		return;
	}
	ipctls = cfd :: ipctls;
	if(ipctl == nil)
		ipctl = cfd;
	sys->print("%sBIND-OK\n", tag);
	if(ip != nil){
		if(sys->fprint(cfd, "add %s %s", ip, mask) < 0){
			sys->print("%s-ADDR-FAIL add %s: %r\n", tag, ip);
			return;
		}
		sys->print("%s-ADDR-OK ip=%s gw=%s\n", tag, ip, gw);
		netdone = 1;
		pingcheck(tag, gw);
		return;
	}
	# Load and initialise once, not once per interface.  Limbo's load
	# of a path already loaded gives back the same instance, module
	# data and all, so a second init() on behalf of a second adapter
	# resets globals the first interface's state still points into.
	if(dhcpclient == nil){
		dhcpclient = load Dhcpclient Dhcpclient->PATH;
		if(dhcpclient == nil){
			sys->print("%s-FAIL load dhcpclient: %r\n", tag);
			return;
		}
		dhcpclient->init();
	}
	cfg := Bootconf.new();
	cfg.puts(Dhcpclient->Ohostname, "inferno-pi-eth");
	lease: ref Lease;
	err: string;
	(cfg, lease, err) = dhcpclient->dhcp("/net", cfd, addr, cfg, nil);
	if(err != nil || cfg == nil || cfg.ip == nil){
		sys->print("%s-DHCP-FAIL %s\n", tag, err);
		if(ifname == "ether")
			staticip(cfd);
		return;
	}
	sys->print("%s-DHCP-OK ip=%s gw=%s\n", tag, cfg.ip, cfg.ipgw);
	netdone = 1;
	# the clock first, and in its own process: everything after this
	# line used to depend on ping(8) returning, and it does not always
	spawn timecheck(cfg.ipgw);
	pingcheck(tag, cfg.ipgw);
	lease = nil;
}

#
# Ask the network what the time is.
#
# This board has no clock.  There is no battery-backed RTC on a Pi and
# nothing here ever asked anyone, so every boot started at the epoch and
# every file the board wrote was stamped 1 January 1980 -- which is
# what the card says about the kernels this board installed on itself.
#
# The gateway first, because a home router almost always answers NTP and
# it is the one address the board is certain it can reach; then two
# public servers by address, since there is no resolver here.  Each is
# given one go: sntp(8) sets the clock and says so, and a board whose
# network cannot reach any of them says that instead of guessing.
#
#
# The connection server, which is what turns a service name into a port.
#
# dial(2) asks /net/cs and falls back to passing the address through
# unchanged when there is none, so on a board without cs "udp!gw!ntp"
# reached the IP device with "ntp" where a port number goes and was
# refused -- "non-numeric port number", which reads like a network
# failure and is a missing name service.  cs answers it out of
# /lib/ndb, where common has udp=ntp port=123, so the kernel carries
# those three files and cs itself.
#
csstart(): int
{
	(have, nil) := sys->stat("/net/cs");
	if(have == 0)
		return 1;
	cs := load Command "/dis/ndb/cs.dis";
	if(cs == nil){
		sys->print("CS-NONE load cs: %r\n");
		return 0;
	}
	spawn cs->init(nil, "cs" :: nil);
	for(i := 0; i < 100; i++){
		(ok, nil) := sys->stat("/net/cs");
		if(ok == 0){
			sys->print("CS-OK /net/cs answers service names\n");
			return 1;
		}
		sys->sleep(100);
	}
	sys->print("CS-NONE /net/cs never appeared\n");
	return 0;
}

#
# Start the resolver and prove it resolved something.
#
# ndb/cs answers the translations in /lib/ndb -- that is what CS-OK
# says, and it is why "udp!gw!ntp" works -- but a name it has never
# heard of has to be asked of somebody, and cs asks by opening
# /net/dns.  Nothing served that file, so every name on this board was
# a number or an error.
#
# No configuration is needed and that is worth knowing: dns recurses
# from the root servers itself (rootservers() in dns.b carries
# a.root-servers.net at 198.41.0.4), so it needs no forwarder, no
# writable /lib/ndb and nothing from DHCP.  It is slower than asking
# the router would be, and it is the version that cannot be wrong about
# a router that does not answer.
#
# The check is a name this board did not look up and cannot have
# cached, resolved to an address, and it prints what it got: a resolver
# that starts and answers nothing is the failure this is here to catch,
# and "DNS-OK" on its own would not have caught it.
#
dnsstart()
{
	(have, nil) := sys->stat("/net/dns");
	if(have == 0){
		sys->print("DNS-OK /net/dns already served\n");
		return;
	}
	dns := load Command "/dis/ndb/dns.dis";
	if(dns == nil){
		sys->print("DNS-NONE load dns: %r\n");
		return;
	}
	spawn dns->init(nil, "dns" :: nil);
	for(i := 0; i < 100; i++){
		(ok, nil) := sys->stat("/net/dns");
		if(ok == 0)
			break;
		sys->sleep(100);
	}
	(ok2, nil) := sys->stat("/net/dns");
	if(ok2 < 0){
		sys->print("DNS-NONE /net/dns never appeared\n");
		return;
	}
	spawn dnscheck();
}

#
# The translation a program actually asks for.
#
# DNS-OK says the resolver resolves.  It does not say that ndb/cs can
# reach it, and for a whole boot it could not: cs had forked its
# namespace before /net/dns existed, so every name it was asked for
# came back "unknown host" while DNS-OK printed beside it.  That is two
# checks that are each true and a board on which "ip/ping google.com"
# does not work.
#
# So ask cs, the way dial(2) does -- write "tcp!name!port", read back
# the clone file and the translated address -- and require an address
# that is not the name.  This is the last link, and nothing above it
# tests it.
#
csnamecheck()
{
	name := "example.com";
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil){
		sys->print("CS-NAME-FAIL open /net/cs: %r\n");
		return;
	}
	q := array of byte ("tcp!" + name + "!80");
	if(sys->write(fd, q, len q) != len q){
		sys->print("CS-NAME-FAIL cs cannot translate %s: %r\n", name);
		return;
	}
	sys->seek(fd, big 0, 0);
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0){
		sys->print("CS-NAME-FAIL no answer for %s: %r\n", name);
		return;
	}
	# "/net/tcp/clone 1.2.3.4!80"
	(nf, f) := sys->tokenize(string b[0:n], " \t\n");
	if(nf < 2){
		sys->print("CS-NAME-FAIL cs answered %q\n", string b[0:n]);
		return;
	}
	addr := hd tl f;
	for(i := 0; i < len addr; i++)
		if(addr[i] == '!'){
			addr = addr[0:i];
			break;
		}
	if(addr == name){
		sys->print("CS-NAME-FAIL %s came back untranslated\n", name);
		return;
	}
	sys->print("CS-NAME-OK cs translates %s to %s\n", name, addr);
}

dnscheck()
{
	#
	# Not a.root-servers.net, which was the first thing tried here and
	# which cannot fail: dns.b's rootservers() carries that name and
	# its address as the hint it starts every recursion from, so the
	# check was reading the answer out of the program.  It printed
	# DNS-OK 198.41.0.4 under QEMU and would have printed it with no
	# network at all.
	#
	# example.com is reserved for exactly this, its address is not in
	# this tree, and reaching it needs the whole path: a query to a
	# root server, a referral to the .com servers, another query, and
	# an answer -- four round trips over the board's own UDP stack.
	#
	name := "example.com";
	fd := sys->open("/net/dns", Sys->ORDWR);
	if(fd == nil){
		sys->print("DNS-FAIL open /net/dns: %r\n");
		return;
	}
	q := array of byte (name + " ip");
	if(sys->write(fd, q, len q) != len q){
		sys->print("DNS-FAIL ask for %s: %r\n", name);
		return;
	}
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0){
		sys->print("DNS-FAIL %s has no answer: %r\n", name);
		return;
	}
	ans := string b[0:n];
	# "name ip 1.2.3.4"; the address is the last field
	(nf, f) := sys->tokenize(ans, " \t\n");
	if(nf < 3){
		sys->print("DNS-FAIL %s answered %q\n", name, ans);
		return;
	}
	addr := "";
	for(l := f; l != nil; l = tl l)
		addr = hd l;
	if(addr == "198.41.0.4"){
		sys->print("DNS-FAIL %s came back as the root hint; nothing was resolved\n", name);
		return;
	}
	sys->print("DNS-OK %s is %s\n", name, addr);
}

timecheck(gw: string)
{
	#
	# The resolver first, and the order is the whole of it.
	#
	# ndb/cs mounts /net/cs into its caller's namespace and then
	# forks its own with pctl(NEWPGRP) -- a copy, taken at that
	# moment.  Anything mounted into /net afterwards is not in the
	# copy, so a cs started before ndb/dns cannot see /net/dns for as
	# long as it runs, and every name it is asked for comes back
	# "unknown host".
	#
	# That is what it did, and the error printed was not that one.
	# dial() tries /net and then /net.alt; this board binds the
	# ethernet device at /net.alt, which has no cs at all, so the
	# second attempt took nettrans's "no connection server, don't
	# translate" path and handed the literal name to the kernel --
	# and dial keeps the second error unless it mentions "translate"
	# or "does not exist".  So "ip/ping google.com" reported "bad ip
	# address syntax" from a network that was never the problem, and
	# the real failure was discarded.
	#
	dnsstart();
	csstart();
	spawn csnamecheck();
	sntp := load Command "/dis/ip/sntp.dis";
	if(sntp == nil){
		sys->print("TIME-NONE load sntp: %r\n");
		return;
	}
	#
	# The gateway, and then whatever /n/dos/ntp.txt names.
	#
	# Only the gateway by default, and deliberately: a home router
	# almost always answers NTP and it is the one address the board is
	# certain it can reach, while a public server by address turns this
	# marker into a question about the machine running the emulator.
	# Under QEMU the gateway is slirp's own address, which answers
	# nothing, so the emulator says TIME-NONE every time and says it
	# for a reason.
	#
	servers := gw :: ntpservers();
	for(; servers != nil; servers = tl servers){
		srv := hd servers;
		#
		# Watch the clock, not sntp's return: it ends by killing
		# its own process group, so what it returns is not
		# something to wait for.  But it does say when it has
		# stopped, and waiting out a fixed fifteen seconds after
		# that wasted three seconds a server and cost the marker
		# suite the TIME-NONE at the end of the run.
		#
		donec := chan[1] of int;
		spawn sntpproc(sntp, srv, donec);
		done := 0;
		for(i := 0; i < 150 && !done; i++){
			# 2001, comfortably past anything a board without a
			# clock would have made up, and past the epoch it
			# starts at
			if(tod() > 1000000000){
				sys->print("TIME-OK %s from %s\n", daytime(), srv);
				return;
			}
			alt {
			<-donec =>
				done = 1;
			* =>
				;
			}
			sys->sleep(100);
		}
		# once more: it may have set the clock as it exited
		if(tod() > 1000000000){
			sys->print("TIME-OK %s from %s\n", daytime(), srv);
			return;
		}
	}
	sys->print("TIME-NONE no NTP answer from the gateway or the servers tried\n");
}

#
# sntp in a process group of its own.
#
# It finishes by writing "killgrp" to its own control file, which is
# the right thing for a command and fatal for a caller that spawned it:
# without the NEWPGRP below that kill lands on init's group and takes
# the board's shell with it.
#
sntpproc(sntp: Command, srv: string, donec: chan of int)
{
	sys->pctl(Sys->NEWPGRP, nil);
	sys->print("TIME-TRY udp!%s!ntp\n", srv);
	{
		sntp->init(nil, "sntp" :: "udp!" + srv + "!ntp" :: nil);
	} exception e {
	"*" =>
		# and say which: a caught exception printed as nothing is
		# how this looked like "no answer" for three boots while
		# sntp was in fact not getting as far as asking
		sys->print("TIME-TRY %s ended: %s\n", srv, e);
		donec <-= 1;
		return;
	}
	donec <-= 1;
}

# extra servers, one per line, from the card
ntpservers(): list of string
{
	#
	# Wait for the card to be mounted.  This runs the moment DHCP
	# finishes and the FAT partition is mounted by another process a
	# little later, so the first attempt read no file at all and the
	# board fell back on a gateway that does not answer NTP -- while
	# the same sntp, typed at the shell a minute later, got the time
	# from the server named in that file.
	#
	for(i := 0; i < 300; i++){
		(ok, nil) := sys->stat("/n/dos/kernel8.img");
		if(ok == 0)
			break;
		sys->sleep(100);
	}
	fd := sys->open("/n/dos/ntp.txt", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	nf = nf;
	rev: list of string;
	for(; f != nil; f = tl f)
		rev = hd f :: rev;
	l: list of string;
	for(; rev != nil; rev = tl rev)
		l = hd rev :: l;
	return l;
}

#
# Seconds since 1970, and the date, both straight from daytime(2).
#
# This parsed /dev/time here instead, and got it wrong twice in
# opposite directions: first dividing seconds by a million, which
# reported TIME-NONE from a board whose clock had just been set, and
# then -- once the kernel was fixed to return microseconds, which is
# what cons(3) says it is -- not dividing at all, which dated the board
# to the year 56716824.  The library has done this correctly all along;
# there was never a reason to do it here.
#
tod(): int
{
	dt := load Daytime Daytime->PATH;
	if(dt == nil)
		return 0;
	return dt->now();
}

daytime(): string
{
	dt := load Daytime Daytime->PATH;
	if(dt == nil)
		return "(no daytime module)";
	return dt->text(dt->local(tod()));
}

pingcheck(tag, gw: string)
{
	ping := load Command "/dis/ip/ping.dis";
	if(ping == nil){
		sys->print("%s-PING-NONE load: %r\n", tag);
		return;
	}
	#
	# And catch what it raises.  ping(8) exits with an error when it
	# loses a message, and the first one to a gateway is answered
	# only after an ARP, which on this board took 471 milliseconds --
	# long enough to count as lost.  That exception unwound through
	# the caller and skipped everything after it, which is how the
	# board stopped setting its clock the moment its round trips
	# started being measured properly.
	#
	{
		ping->init(nil, "ping" :: "-n" :: "3" :: gw :: nil);
	} exception e {
	"*" =>
		sys->print("%s-PING-DONE (%s)\n", tag, e);
		return;
	}
	sys->print("%s-PING-DONE\n", tag);
}

# Phase 4: USB mass storage.  usbd's Bulk-Only Transport driver serves
# the stick as a flat file at /chan/usbdisk0, turning byte-range reads
# and writes into SCSI READ(10)/WRITE(10) over the bulk endpoints;
# dossrv mounts the FAT filesystem on that file at /n/usb.  Listing the
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
	spawn dossrv->init(nil, "dossrv" :: "-f" :: disk :: "-m" :: "/n/usb" :: nil);

	# /n/usb exists in the root either way, so an open proves nothing;
	# wait for the mount by waiting for entries to appear under it
	names := "";
	first := "";
	for(i = 0; i < 50; i++){
		names = "";
		first = "";
		dfd := sys->open("/n/usb", Sys->OREAD);
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
		sys->print("DISK-DOS-FAIL nothing under /n/usb: %r\n");
		return;
	}
	sys->print("DISK-DOS-OK /n/usb:%s\n", names);

	if(first != nil){
		fd := sys->open("/n/usb/" + first, Sys->OREAD);
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
	wfd := sys->create("/n/usb/pi.txt", Sys->OWRITE, 8r666);
	if(wfd == nil){
		sys->print("DISK-WRITE-FAIL create: %r\n");
		return;
	}
	if(sys->write(wfd, msg, len msg) != len msg){
		sys->print("DISK-WRITE-FAIL write: %r\n");
		return;
	}
	wfd = nil;
	rfd := sys->open("/n/usb/pi.txt", Sys->OREAD);
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

#
# Does a process woken by the clock run while a Limbo loop is running?
#
# This is the whole of what the scheduler work changes, asked directly,
# with nothing but the board.  Before it, nothing in this kernel ever
# took the processor away from a running process: hzsched() and
# accounttime() were compiled into every kernel here and called by
# none, so the processor changed hands only when a process blocked of
# its own accord.  A Limbo program that makes no system call held it
# until it made one, and a process the clock woke waited exactly that
# long.
#
# So: sleep 50ms ten times and record the overshoot, then start a loop
# that never makes a system call and do it again.  The difference is
# the answer.  Measuring the loaded figure alone would not be: a 50ms
# sleep overshoots on an idle board too, by the tick granularity (10ms
# here), by the emulator when this runs under one, and by the host's
# own scheduler underneath that.  None of those is this kernel's doing
# and all of them are in both figures, so the idle run calibrates them
# away.
#
# The loop must not make a system call, or it is not the thing being
# tested -- a system call releases the interpreter and hands the
# processor over by the path that always worked.  A bare arithmetic
# loop in Limbo is exactly the case that used to be unpreemptible.
#
schedhog(pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	n := 0;
	for(;;)
		n++;
}

schedsleeps(n: int, ms: int): array of int
{
	a := array[n] of int;
	for(i := 0; i < n; i++){
		t0 := sys->millisec();
		sys->sleep(ms);
		d := sys->millisec() - t0 - ms;
		if(d < 0)
			d = 0;
		a[i] = d;
	}
	return a;
}

#
# Sorted, because the median is what says whether the scheduler works
# and the worst is what says what else is going on.  Ten samples, so
# an insertion sort is the whole of it.
#
schedsort(a: array of int)
{
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i - 1;
		while(j >= 0 && a[j] > v){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = v;
	}
}

schedlat()
{
	Nsleep: con 10;
	Ms: con 50;

	sysctl := sys->open("/dev/sysctl", Sys->OWRITE);
	idle := schedsleeps(Nsleep, Ms);

	pidc := chan[1] of int;
	if(sysctl != nil)
		sys->fprint(sysctl, "ilock on");
	spawn schedhog(pidc);
	hog := <-pidc;
	busy := schedsleeps(Nsleep, Ms);
	fd := sys->open("/prog/" + string hog + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
	fd = nil;
	# the interrupt-masked window over exactly this interval, then off
	# again: it costs two counter reads on every ilock in the kernel
	if(sysctl != nil){
		sys->fprint(sysctl, "ilock");
		sys->fprint(sysctl, "ilock off");
		sys->fprint(sysctl, "sched");
	}

	schedsort(idle);
	schedsort(busy);
	im := idle[Nsleep/2];
	lm := busy[Nsleep/2];

	#
	# The median is the verdict and the worst is in the line beside
	# it, because they answer different questions and hiding either
	# one would be the point of the check going missing.  The median
	# says whether a process the clock wakes gets the processor while
	# a Limbo loop is running: before this kernel had a scheduler
	# clock at all it did not, and the overshoot was however long the
	# loop took to reach its next system call.  The worst says what
	# else was happening -- on this board it is one wait of about 670
	# milliseconds on the first sleep after a second interpreter
	# process appears, which is not explained yet and is written down
	# in doc/raspi3b-completion-plan.ms rather than averaged away.
	#
	# Three ticks, because the sleep itself rounds to a tick and so
	# does millisec(), and one more for the yield.
	#
	if(lm - im > 30)
		sys->print("SCHED-LAT-FAIL %dms sleeps overshoot by %d ms against a Limbo loop and %d without (worst %d and %d)\n",
			Ms, lm, im, busy[Nsleep-1], idle[Nsleep-1]);
	else
		sys->print("SCHED-LAT-OK %dms sleeps overshoot by %d ms against a Limbo loop and %d without (worst %d and %d)\n",
			Ms, lm, im, busy[Nsleep-1], idle[Nsleep-1]);
}

init()
{
	shell: Shell;
	sys = load Sys Sys->PATH;
	sys->print("raspi3b init\n");
	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	# #m is the pointer device; without it usbd's mouse reader dies on
	# its first open of /dev/pointer.
	sys->bind("#m", "/dev", sys->MAFTER);
	# #t is the uarts.  The console has one of them; the other is the
	# board's Bluetooth radio, which is an H4 controller on a serial
	# line and reachable only as a file: btfs wants /dev/eia0 and its
	# ctl file beside it.
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->print("RASPI3B-OK\n");

	# No mntgen.  /n/dos, /n/usb and /n/remote are directories in the
	# kernel's root, so there is nothing for it to make.  It was started
	# here, and in fatcheck() before that, as mg->init(): but mntgen
	# serves Styx on its standard input and is meant to be run as
	# "mount {mntgen} /n".  Called directly, it mounted nothing and read
	# the console as Styx: the first line typed at the shell lost its
	# first word to it, mntgen exited on the malformed message, and the
	# shell ran the rest -- "echo hi > /tmp/x" became "sh: hi: file does
	# not exist" and an empty /tmp/x.
	# Before the storage and network checks start, because it is a
	# timing measurement and the point of it is a Limbo loop against
	# an otherwise quiet board -- SD and USB running underneath would
	# be measuring them as well.
	schedlat();
	rngcheck();
	sys->bind("#S", "/dev", sys->MAFTER);
	sdcheck();
	drawtest();
	tktest();
	drawrate();
	usbcheck();
	# in its own process: the shell must not wait behind a DHCP lease and
	# three pings, which take seconds and can be answered by nothing at all
	spawn ethercheck();
	# The radio, if the card carries firmware and credentials for one.
	spawn wificheck();
	# and the Bluetooth half of the same chip
	spawn btcheck();
	spawn readerwatch();
	spawn netdebug();
	spawn pingtest();
	# A kfs in the card's unallocated gap, mounted over a pipe, with a
	# file created in it.  The create used to hang here - pid 1's Twalk
	# got its Rerror and the error unwound past mntwalk's own waserror
	# handler, so the Tcreate was never sent - and that was blamed on an
	# arm64 multi-kproc error-stack bug.  The mount it needs works now
	# that kernel stacks are aligned, so the create is worth trying
	# again; it runs in its own process either way, so a hang there
	# leaves the board usable.
	#
	# Both of these and the ethernet run at once, and they compete for
	# the one thing they cannot share.  This kernel's SD driver is
	# polled, so the 1.5MB write below holds the CPU, and USB
	# enumeration is a Dis program waiting on completion interrupts.
	# Timed inside the driver, a single control transfer with no
	# retries at all -- one loop, no NAKs, no Nyets -- took 20, 58 and
	# 93 milliseconds while the card was busy and 8 microseconds when
	# it was not.  That is the whole of the 10-to-149-second spread in
	# ETHERUSB-SETUP: not the USB driver, not the chip, the CPU.
	#
	# Making the card wait for the ethernet was tried and is not the
	# answer: it moved the contention rather than removing it, and the
	# boot that came out of it died in the kernel with "double sleep",
	# which the ordering before it does not.  What removes it is DMA
	# for the SD controller, which doc/raspi3b-completion-plan.ms has
	# as its own piece of work.
	#
	spawn sdfs();
	spawn fatcheck();
	spawn efscheck();

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
	spawn remotecmd();
	shell->init(nil, "sh" :: "-i" :: "-n" :: nil);
}

#
# Take commands from the host, because the board cannot always be typed
# at.
#
# The mini UART's receive path died on this desk and the board looked
# hung for an afternoon.  It was not: the registers said so -- LSR 0x60,
# STAT 0x34e, receive FIFO empty, identical before and after forty
# characters were typed, with GPIO14 and GPIO15 both in ALT5 and
# transmit working throughout.  A board that boots perfectly and cannot
# be spoken to is indistinguishable from a crashed one, and every
# instrument this port has is on the OUTPUT side.
#
# So the input comes the other way.  The styx mount to the host is
# already there for kupdate; write os/inferno/raspi3b/board.cmd in the
# worktree and the board runs it and prints the output between markers.
# Nothing is typed, and it works over a console that is deaf.
#
# The file's CONTENTS are the key, not its mtime: a rebuild rewrites
# mtimes all over the tree, and an mtime-driven loop would re-run the
# last command for ever.
#
Cmdfile: con "/n/remote/os/inferno/raspi3b/board.cmd";
Outfile: con "/n/remote/os/inferno/raspi3b/board.out";

#
# Say when the one remote channel has stopped working.
#
# Every giving-up path below -- no kupdate.txt, dial refused, mount
# refused, board.cmd unreadable, a short read -- used to return nil, and
# the caller cannot tell nil from "board.cmd has not changed".  So a
# poller that was failing every fifteen seconds was indistinguishable
# from a poller with nothing to do, and the console said nothing either
# way.  That is how it looked when a kernel came up with the card and
# the network both working and the board nonetheless unreachable: the
# only way back in was JTAG.
#
# Print on the FIRST failure and then every twentieth -- five minutes --
# so a long outage is legible in a hardcopy taken an hour later without
# burying the boot log, which is the other thing a deaf board is read
# through.  Print once more on recovery, so the log shows an end as well
# as a beginning.
#
rcmdfails := 0;

rcmdfail(why: string)
{
	rcmdfails++;
	if(rcmdfails == 1 || rcmdfails % 20 == 0)
		sys->print("RCMD-DOWN %d: %s\n", rcmdfails, why);
}

rcmdup()
{
	if(rcmdfails > 0)
		sys->print("RCMD-UP after %d failed polls\n", rcmdfails);
	rcmdfails = 0;
}

remotecmd()
{
	last := "-";
	seq := 0;

	# Let the boot's own work finish first; this is a convenience,
	# and it must never be what makes a boot fail.  Sixty seconds
	# also keeps it clear of kupdate, which uses the same mount
	# point and takes it down on its way out.
	#
	# A private set of file descriptors before anything is
	# redirected.
	#
	# The command's output is sent to a file on the host, which
	# means dup()ing over descriptors 1 and 2 -- and spawn shares
	# the descriptor group, so without this the whole board's
	# console output would follow it there and the console would go
	# quiet for good reason and look like the several bad reasons it
	# has gone quiet before.  NEWFD, not FORKFD.
	#
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	#
	# Wait for fatwrite to be done with the card, not for a kernel
	# update: the kernel update IS a board.cmd script now, so waiting
	# for it here would be waiting for this loop.
	#
	# That gate used to be a ten-minute wait on kupdate(), a hundred
	# and eighty lines of Limbo that dialled the host, mounted it,
	# read 1.9MB in chunks with its own progress counter, checksummed
	# what it had written and renamed twice.  Every one of those
	# steps printed only to the console, so when it stopped -- and it
	# stopped on a dead mount, on a FIFO error under dossrv, and on
	# nothing at all -- there was no way to see where.  Worse, while
	# it held /n/remote nothing else could run, so the one channel
	# that reports off the board was shut for as long as the thing
	# most likely to hang was running.
	#
	# What it did is "mount the host and copy a file", and sh already
	# does that in a line, with cp and cmp saying plainly whether it
	# worked, on a connection this loop has already made and into an
	# output file on the host.
	#
	# Not just kudone: the namespace taken below must already contain
	# /net, and the bind that puts it there is ethercheck's.  Bounded,
	# so a board with no ethernet still reaches the code that says why
	# it is unreachable rather than waiting in silence.
	#
	# btdone for the same reason, one layer further out.  btfs mounts
	# its file system at /n/bt, and a namespace forked before that
	# mount does not have it and never will -- so every command sent
	# to this poller saw "/n/bt/0: file does not exist" on a board
	# whose Bluetooth was up and serving.  A snapshot is only as good
	# as its timing, which is the second time that has cost something
	# here.
	for(w := 0; w < 180; w++){
		if(kudone && netdone && btdone)
			break;
		sys->sleep(1000);
	}
	if(!netdone)
		sys->print("RCMD-NONET no interface after 180 s; dialling anyway\n");
	if(!btdone)
		sys->print("RCMD-NOBT bluetooth not up after 180 s; going on\n");
	#
	# A PRIVATE namespace, from here on.
	#
	# This loop mounts the host on /n/remote, reads board.cmd,
	# unmounts, and does it again fifteen seconds later -- and it was
	# doing all of that in the namespace everything else shares.  So
	# a mount made by hand at the console
	#
	#	mount -A tcp!host!6666 /n/remote
	#
	# lasted until the next poll and then vanished, repeatedly, which
	# is baffling from the other end: the mount succeeds, the files
	# are there, and moments later they are not.
	#
	# FORKNS here and not at the top of this function: the copy is
	# taken now, after the wait above, so that /n/dos -- mounted by
	# fatcheck, which is what kudone is waiting for -- is in it and
	# board.cmd scripts can still reach the card.  Taken at entry the
	# snapshot would predate that mount and every script would lose
	# the card.
	#
	# The shell runremote spawns shares this namespace and so still
	# sees /n/remote and /n/dos; the console does not see either of
	# this loop's mounts, which is the point.
	#
	sys->pctl(Sys->FORKNS, nil);
	addrs := remoteaddrs();
	if(addrs == nil){
		# remoteaddrs has already said which step failed.
		sys->print("RCMD-OFF no host address: this board is JTAG-only now\n");
		return;
	}
	sys->print("RCMD-ON polling %s every 5s\n", hd addrs);
	#
	# Fifteen seconds, not three.
	#
	# Each pass is a full dial, mount, read and unmount, and at three
	# seconds that is enough load to keep the host's server busy all
	# the time: a new connection to it took 4 to 7 seconds to be
	# answered, which a five-second health check on the host read as
	# "the server has wedged".  Hours went into chasing a wedge that
	# was this poll.  A convenience should not be the heaviest thing
	# talking to the server it depends on.
	#
	for(;;){
		sys->sleep(5000);
		cmd := readcmdfile(addrs);
		if(cmd == nil || cmd == last)
			continue;
		last = cmd;
		seq++;
		sys->print("RCMD-BEGIN %d %s\n", seq, cmd);
		sh := load Shell "/dis/sh.dis";
		if(sh == nil){
			sys->print("RCMD-FAIL load sh: %r\n");
			continue;
		}
		runremote(sh, cmd, seq, addrs);
		sys->print("RCMD-END %d\n", seq);
	}
}

#
# Run one command with its output going to the HOST, not the console.
#
# The console on this rig is the least reliable thing about it: the
# USB-serial adapter wedges, and the screen session has died three
# times in a day.  A board that can be given work but whose answers
# only come out of a console is no better off than one that cannot be
# given work at all, so the answers go back the way the question came
# -- board.out beside board.cmd in the worktree.
#
# The console still gets the markers, which is why the redirection is
# put back before returning: a boot log that shows RCMD-BEGIN and
# RCMD-END with the body written elsewhere is still readable, and if
# the mount fails the output simply stays on the console.
#
runremote(sh: Shell, cmd: string, seq: int, addrs: list of string)
{
	# sys->dup returns a descriptor NUMBER; wrap it in a ref FD so
	# the saved copies are closed when this returns rather than
	# leaked once per command.
	save1 := sys->fildes(sys->dup(1, -1));
	save2 := sys->fildes(sys->dup(2, -1));
	out: ref Sys->FD;
	#
	# Unmount on EVERY way out, including the one where the mount
	# worked and the create did not.
	#
	# The first version only unmounted inside "if(out != nil)", so a
	# failed create left /n/remote mounted; the next pass mounted
	# again over it, and the mounts piled up until the loop stopped
	# making progress.  One command ran and then nothing ever did.
	# This is the same shape of mistake kupdate's comments warn
	# about, made again two hundred lines away.
	#
	mounted := remoteheld;
	if(!mounted)
		mounted = mountremote(addrs);
	madeout := 0;
	if(mounted){
		out = sys->create(Outfile, Sys->OWRITE, 8r666);
		if(out == nil)
			sys->print("RCMD-NOOUT create %s: %r\n", Outfile);
		else
			madeout = 1;
	}
	if(out != nil){
		sys->fprint(out, "RCMD %d: %s\n", seq, cmd);
		sys->dup(out.fd, 1);
		sys->dup(out.fd, 2);
	}
	#
	# In a CHILD, because sh->init() does not come back.
	#
	# sh.b's init(), given -c and not interactive, ends its work with
	#
	#	if (status != nil)
	#		raise "fail:" + status;
	#	exit;
	#
	# and `exit` terminates the process that called init -- this one.
	# So running a board.cmd script in-process killed remotecmd every
	# time the script SUCCEEDED, silently and with no exception to
	# catch.  The console said so on four boots in a row and it was
	# read as a hang: RCMD-BEGIN 1 always, RCMD-END never, and
	# board.cmd working exactly once per boot.  A process count told
	# the difference in the end -- five Init processes before the
	# script, three after -- because a process that is blocked is
	# still there and this one was gone.
	#
	# The child shares this process's file descriptor group, so it
	# inherits the redirection to board.out set up above, and its
	# namespace, so the script sees /n/remote.  Waiting for it to go
	# is the only thing left to do.
	#
	pidch := chan of int;
	spawn shellproc(sh, cmd, pidch);
	waitgone(<-pidch);
	if(out != nil){
		out = nil;
		sys->dup(save1.fd, 1);
		sys->dup(save2.fd, 2);
	}
	#
	# The mount stays.  It is dropped only when the create on it
	# failed, which is the signal that the far end has gone.
	#
	# Note what this must NOT test: "out" is set to nil a few lines
	# above, to close the file, so a condition on it here is always
	# true and the mount would be dropped after every command -- which
	# is what the first version of this did, quietly giving back most
	# of what holding the mount was for.  madeout records whether the
	# create worked, before out is cleared.
	#
	if(mounted && !madeout)
		dropremote();
}

#
# Dial and mount, leaving the mount up for the caller to use and take
# down.  readcmdfile() does its own because it unmounts immediately.
#
remotemounted(addrs: list of string): int
{
	ok := -1;
	c: Sys->Connection;
	for(l := addrs; l != nil; l = tl l){
		(ok, c) = sys->dial(hd l, nil);
		if(ok >= 0)
			break;
	}
	if(ok < 0)
		return 0;
	#
	# NOT cached, and the reason is measurement rather than taste.
	#
	# devmnt carries 9front's read-ahead -- Mntrah, eight rpcs in
	# flight -- reached only through cread(), which needs CCACHE on the
	# channel, which needs MCACHE here.  Turning it on looked like a
	# 1.42x win: 3.914s to 2.758s for a 1.9MB read, three readings each
	# way and only 3.5% apart.
	#
	# It does not survive repetition.  The same no-MCACHE kernel, one
	# freshly booted board, three consecutive reads: 3.173, 2.759 and
	# 4.904 seconds.  A 78% spread inside ONE arm, which is wider than
	# the effect being claimed, so those tight triplets were luck and
	# not precision.  Separately, an aged board measures 3.83s with
	# MCACHE on -- no better than no-MCACHE fresh -- and there is no
	# aged measurement from before the change to compare against.
	#
	# SETTLED, with the ten readings per arm this comment asked for.
	# mount(1) grew a -M flag for Sys->MCACHE, so both arms run against
	# one running kernel, ten interleaved pairs, unmounting between so
	# each starts cold.  Deltas in seconds for the same 400KB read:
	#
	#	plain  1.07 1.08 1.10 1.13 1.15 1.16 1.18 1.34 1.38 1.55
	#	cached 1.09 1.14 1.14 1.16 1.16 1.19 1.25 1.26 1.47 2.28
	#
	# Medians 1.154 and 1.178: the cache is two percent SLOWER, with a
	# worse tail.  There is no gain to weigh against the change in
	# semantics, so it stays off -- and the first pair measured, taken
	# alone, showed 1.24x IN ITS FAVOUR, which is exactly the trap the
	# paragraphs above describe.
	#
	# Why there is nothing to win: read-ahead deepens the pipeline, and
	# the pipeline is not what is full.  Measured separately, the send
	# queue holds one 8KB request and TCP's window is twenty times
	# that; the cost is the far end's turnaround, which more requests
	# in flight cannot shorten.
	#
	# The original reasoning, kept because it is the right reasoning:
	# an unproven gain is not worth a change in caching
	# semantics on the path the board is driven through.  To establish
	# it properly would take ten or more readings per arm, arms
	# interleaved, each preceded by a reboot, with the distribution
	# reported rather than a median of three.
	#
	if(sys->mount(c.dfd, nil, "/n/remote", Sys->MREPL, "") < 0)
		return 0;
	return 1;
}

#
# The mount is taken down after every read.  kupdate does the same and
# for the same reason: a mount whose far end has gone stays in the
# namespace and every later open blocks on it, which is precisely the
# failure this whole mechanism is here to route around -- the host's
# styx server was once up for three days, still accepting connections
# and never answering a Tversion, and every process that touched
# /n/remote went to sleep behind it.
#
#
# The addresses kupdate.txt names, read once.
#
# Once, because this runs every three seconds and /n/dos is a FAT
# filesystem served by a dossrv that the rest of the board is also
# using; re-reading a config file on it forever to learn something
# that cannot change is a good way to turn a convenience into a
# source of load.
#
remoteaddrs(): list of string
{
	cfg := sys->open("/n/dos/kupdate.txt", Sys->OREAD);
	if(cfg == nil){
		sys->print("RCMD-NOADDR open /n/dos/kupdate.txt: %r\n");
		return nil;
	}
	b := array[256] of byte;
	n := sys->read(cfg, b, len b);
	cfg = nil;
	if(n <= 0){
		sys->print("RCMD-NOADDR read /n/dos/kupdate.txt: %r\n");
		return nil;
	}
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 2){
		sys->print("RCMD-NOADDR /n/dos/kupdate.txt has %d fields, need 2\n", nf);
		return nil;
	}
	rev: list of string;
	for(l := f; l != nil; l = tl l)
		if(tl l != nil)			# the last field is the path
			rev = hd l :: rev;
	addrs: list of string;
	for(l = rev; l != nil; l = tl l)
		addrs = hd l :: addrs;
	return addrs;
}

#
# efs on the card: the partition above the firmware's FAT.
#
# doc/efs-format.ms and man/4/efs describe the filesystem; this is the
# only place it meets real hardware.  Everything either of those claims
# was established under emu on a host against an image file, and an image
# file is not a card: it does not take 250ms to program a block, it does
# not lie about its capacity, and it does not lose a write and return
# success.
#
# The layout is the space the firmware does not use.  The FAT32
# partition's start and length come from the partition table, not from
# memory of this particular card -- the rule sdfs() learned when a
# hardcoded gap reamed a filesystem.  efs gets everything above it bar a
# tail for the crash test, which needs a filesystem it is allowed to ruin.
#
Efsmin:		con 16384;	# sectors: 8MB, enough to be a filesystem
Efscrashsec:	con 262144;	# sectors: 128MB at the top of the card

#
# A partition.  Making one writes nothing to the card.
#
# The zero check used to be here, and that was wrong in the direction
# that matters: it refused to make the partition when the sectors were
# not empty, so a card that already HELD a filesystem -- the normal case,
# and the only one that matters after the first boot -- could not have it
# mounted.  One run made an efs and every run after it reported
# "sectors 147456-8126463 are not empty; not reaming them" and stopped,
# with nothing reaming and nothing mounted.
#
# The check belongs on the REAM, where something is actually overwritten,
# and it is there now.
#
efspart(name: string, first, last: int): int
{
	if(last - first + 1 < Efsmin){
		sys->print("EFS-SKIP %s would be %d sectors, need %d\n",
			name, last - first + 1, Efsmin);
		return 0;
	}
	#
	# devsd's "part" takes an EXCLUSIVE end, so last + 1.
	#
	# fatcheck() has written "part dos start start+nsec" since it was
	# written, which is the same convention; this passed the last sector
	# instead and made every partition one sector short.  Nothing noticed
	# until a filesystem used all of one: mkefs sized itself from the
	# range it had asked for and its last block, the spare superblock,
	# fell outside the partition --
	#
	#	mkefs: write block 997375 at 4085248000: file does not exist
	#
	# -- which on the real card is a filesystem that mounts from
	# superblock 0 and has no fallback, i.e. exactly the thing the two
	# superblocks exist to prevent, arrived at by an off-by-one in a
	# partition table.  Found under QEMU on a 4GB card.
	#
	cfd := sys->open(SDDEV + "/ctl", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "part %s %d %d", name, first, last + 1) < 0){
		sys->print("EFS-SKIP part %s: %r\n", name);
		return 0;
	}
	return 1;
}

#
# Run one efs program and take its verdict from whether it RAISED.
#
# Not from what it printed.  The first version of this captured the
# child's output through a pipe -- dup the write end onto 1 and 2, read
# to EOF, grep -- and it hung on the first try and printed nothing at
# all: a spawned process shares its parent's descriptor table, so the dup
# replaced the CALLER's standard output too, and when the child exited
# the shared entries still held the write end because the parent was
# alive.  EOF never came.  Giving the child its own table fixed that
# half and the read still never ended.
#
# The programs already say what happened in the way Limbo says things.
# mkefs calls fail(), which raises; efsck raises fail:dirty or
# fail:unmountable and RETURNS when the filesystem is clean.  So the
# verdict is "did init() come back", which needs no pipe, no dup and no
# string matching -- and the child's own output still reaches the console,
# so whatever it complained about is there to read.
#
# Verified under emu with three negative controls: a clean image gives 1;
# efsck on /dis/sh.dis, on an absent file, and on an image whose two
# superblocks were overwritten all give 0.
#
efsdone(what: string, argv: list of string): int
{
	m := load Command "/dis/disk/" + what + ".dis";
	if(m == nil){
		sys->print("EFS-SKIP load %s: %r\n", what);
		return 0;
	}
	donech := chan of int;
	spawn efsdoneproc(m, argv, donech);
	return <-donech;
}

efsdoneproc(m: Command, argv: list of string, donech: chan of int)
{
	{
		m->init(nil, argv);
		donech <-= 1;
	}exception e{
	"*" =>
		sys->print("EFS-EXCEPTION %s\n", e);
		donech <-= 0;
	}
}

#
# Mount the partition at "where", with the server left running.
#
# The verdict comes from efs's own init(): it raises when the device will
# not mount and RETURNS, leaving the server behind, when it will.  So this
# is efsdone() like everything else here, and the server outlives it.
#
# It used to spawn the server and then poll sys->stat(where + "/.") for
# ten seconds, which is a check that cannot fail: /n/efs exists in the
# kernel's own root, so it stats whether or not anything is mounted on it.
# Run under QEMU against a card with no filesystem on it, that printed
#
#	efs: /dev/sdN0/efs: neither superblock is good
#	EFS-OK mounted
#	EFS-FAIL create: permission denied
#
# -- EFS-OK for a filesystem that was not there, with the server's own
# refusal three lines above it.  On the board, with no console, the marker
# would have been the only thing anybody saw.
#
efsmount(part: string, where: string): int
{
	return efsdone("efs", "efs" :: "-f" :: SDDEV + "/" + part ::
		where :: nil);
}

#
# What a filesystem has to do, on the card, at boot.
#
# The markers are separate on purpose: a filesystem that mounts and
# cannot write is a different failure from one that writes and cannot
# rename, and rename is where dossrv failed on this board and what
# kupdate does to the kernel on every update.
#
efswork(): int
{
	fd := sys->create("/n/efs/boot.txt", Sys->ORDWR, 8r644);
	if(fd == nil){
		sys->print("EFS-FAIL create: %r\n");
		return 0;
	}
	msg := array of byte "written by the board\n";
	if(sys->write(fd, msg, len msg) != len msg){
		sys->print("EFS-FAIL write: %r\n");
		return 0;
	}
	fd = nil;
	fd = sys->open("/n/efs/boot.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("EFS-FAIL reopen: %r\n");
		return 0;
	}
	buf := array[len msg] of byte;
	if(sys->read(fd, buf, len buf) != len buf || string buf != string msg){
		sys->print("EFS-FAIL what came back is not what went in\n");
		return 0;
	}
	fd = nil;
	sys->print("EFS-WRITE-OK %d bytes back byte for byte\n", len msg);

	#
	# Rename, onto a name that existed a moment ago.  That second half
	# is the one this board needs: kupdate renames the new kernel over
	# the old one, and dossrv's rename silently degraded to a copy.
	#
	sys->remove("/n/efs/old.txt");	# absent on the first boot; fine
	d := sys->nulldir;
	d.name = "old.txt";
	if(sys->wstat("/n/efs/boot.txt", d) < 0){
		sys->print("EFS-FAIL rename: %r\n");
		return 0;
	}
	(rok, dir) := sys->stat("/n/efs/old.txt");
	if(rok < 0 || dir.length != big len msg){
		sys->print("EFS-FAIL the renamed file is absent or the wrong length\n");
		return 0;
	}
	sys->print("EFS-RENAME-OK\n");
	return 1;
}

#
# The crash test, on the card rather than on an image.
#
# tests/efs-crash.sh does this sixty times on the host; here it is once,
# on real media, because what an image cannot reproduce is a card that
# takes its own time to program a block.  "efs -F 12" refuses every write
# after the twelfth -- the same injection the host harness drives -- and
# then the filesystem must mount and efsck must be silent.
#
# On its own partition.  A crash test sharing a filesystem with anything
# worth keeping is not a test, it is an accident.
#
efscrashtest(part: string): int
{
	dev := SDDEV + "/" + part;
	if(!efsdone("mkefs", "mkefs" :: "-n" :: "16384" :: dev :: nil)){
		sys->print("EFS-CRASH-FAIL mkefs did not finish\n");
		return 0;
	}
	if(!efsdone("efs", "efs" :: "-F" :: "12" :: "-f" :: dev ::
			"/n/efscrash" :: nil)){
		sys->print("EFS-CRASH-FAIL the injecting server would not mount\n");
		return 0;
	}
	#
	# Write until the injection stops it.  These writes are EXPECTED to
	# fail; what is under test is what the card holds afterwards.
	#
	for(i := 0; i < 8; i++){
		cfd := sys->create(sys->sprint("/n/efscrash/f%d", i),
			Sys->ORDWR, 8r644);
		if(cfd == nil)
			break;
		b := array[4096] of {* => byte i};
		if(sys->write(cfd, b, len b) != len b)
			break;
	}
	#
	# Drop the crashed server and verify in a process that never saw it.
	#
	sys->unmount(nil, "/n/efscrash");
	if(!efsdone("efsck", "efsck" :: dev :: nil)){
		sys->print("EFS-CRASH-FAIL efsck would not call it clean\n");
		return 0;
	}
	return 1;
}

#
# efs in files on the FAT, for a card with no room above it.
#
# Reamed once, when /n/dos/efsream is there and the file is not: a FAT has
# no sparse files, so mkefs writing its last block allocates every cluster
# up to it, and 64MB through dossrv at this board's measured 370KB/s is
# about three minutes.  Once.  Every boot after that is two block reads.
#
Efsfileblk:	con 16384;	# 64MB
Efscrashblk:	con 1024;	# 4MB, and it is meant to be ruined
efsonfat()
{
	img := "/n/dos/efs.img";
	if(sys->open(img, Sys->OREAD) == nil){
		if(sys->open("/n/dos/efsream", Sys->OREAD) == nil){
			sys->print("EFS-SKIP no %s, and no /n/dos/efsream to say make one\n", img);
			return;
		}
		sys->print("EFS-REAM making %s, %d blocks; this takes minutes\n",
			img, Efsfileblk);
		if(!efsdone("mkefs", "mkefs" :: "-n" :: string Efsfileblk ::
				img :: nil)){
			sys->print("EFS-FAIL mkefs did not finish\n");
			return;
		}
	}
	if(!efsdone("efs", "efs" :: "-f" :: img :: "/n/efs" :: nil))
		return;
	sys->print("EFS-OK mounted %s\n", img);
	if(!efswork())
		return;
	#
	# And the crash test, on a file of its own.
	#
	cimg := "/n/dos/efscrash.img";
	if(sys->open(cimg, Sys->OREAD) == nil &&
	    !efsdone("mkefs", "mkefs" :: "-n" :: string Efscrashblk :: cimg :: nil)){
		sys->print("EFS-CRASH-FAIL mkefs did not finish\n");
		return;
	}
	if(!efsdone("efs", "efs" :: "-F" :: "12" :: "-f" :: cimg ::
			"/n/efscrash" :: nil)){
		sys->print("EFS-CRASH-FAIL the injecting server would not mount\n");
		return;
	}
	for(i := 0; i < 8; i++){
		cfd := sys->create(sys->sprint("/n/efscrash/f%d", i),
			Sys->ORDWR, 8r644);
		if(cfd == nil)
			break;
		b := array[4096] of {* => byte i};
		if(sys->write(cfd, b, len b) != len b)
			break;
	}
	sys->unmount(nil, "/n/efscrash");
	if(!efsdone("efsck", "efsck" :: cimg :: nil)){
		sys->print("EFS-CRASH-FAIL efsck would not call it clean\n");
		return;
	}
	sys->print("EFS-CRASH-OK the card held the last committed state\n");
}

#
# Phase: efs on the card.
#
# /n/dos/efsream on the FAT partition is the opt-in for making a NEW
# filesystem.  Without it this mounts what is already there and says so
# if there is nothing -- because a filesystem that reams itself at boot
# is a test and not storage, which is the whole reason mkefs is a
# separate program.
#
efscheck()
{
	#
	# Behind the FAT mount, not beside it.  /n/dos holds the opt-in
	# flag, and three processes on the SD driver at boot is how the
	# contention that costs this board its ethernet timing gets worse.
	#
	# Waiting for a FILE, not for the directory.  /n/dos exists in the
	# kernel's own root, so stat("/n/dos/.") succeeds the instant the
	# board boots whether dossrv has mounted or not -- and this waited
	# on exactly that, went straight on, found no /n/dos/efsream because
	# nothing was mounted yet, and reported EFS-SKIP with the opt-in file
	# sitting on the card.  kernel8.img is what fatcheck() waits for and
	# it cannot exist unless the FAT is really there.
	#
	# That is twice in this one function: the mount check below had the
	# same shape and printed EFS-OK for a filesystem the server had just
	# refused.  On this board /n/<anything> always stats; only something
	# INSIDE it proves a mount.
	#
	for(i := 0; i < 40; i++){
		(ok, nil) := sys->stat("/n/dos/kernel8.img");
		if(ok >= 0)
			break;
		sys->sleep(500);
	}
	(fstart, nsec) := fatpart();
	if(nsec == 0){
		sys->print("EFS-SKIP no partition table to place a filesystem after\n");
		return;
	}
	cfd := sys->open(SDDEV + "/ctl", Sys->OREAD);
	if(cfd == nil){
		sys->print("EFS-SKIP cannot open %s/ctl: %r\n", SDDEV);
		return;
	}
	cb := array[2048] of byte;
	n := sys->read(cfd, cb, len cb);
	if(n <= 0){
		sys->print("EFS-SKIP cannot read %s/ctl: %r\n", SDDEV);
		return;
	}
	cards := 0;
	(nil, lines) := sys->tokenize(string cb[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nt, toks) := sys->tokenize(hd lines, " \t");
		if(nt >= 2 && hd toks == "geometry")
			cards = int hd tl toks;
	}
	if(cards <= 0){
		sys->print("EFS-SKIP the ctl file reports no geometry\n");
		return;
	}
	#
	# Above the FAT, 4KB aligned so one efs block is one run of eight
	# sectors rather than two halves of two.
	#
	estart := (fstart + nsec + 7) & ~7;
	#
	# Room for the crash partition only if there is room for both, and
	# the check has to be made BEFORE the subtraction rather than left
	# to efspart to notice.
	#
	# Written as "cards - 1 - Efscrashsec" it went negative on a 16MB
	# card, where the firmware's FAT reaches the end and there is nothing
	# above it: efspart refused, which is the right outcome, but it
	# refused with "efs would be -262144 sectors, need 16384", which
	# describes nothing.  Found by running the board's boot under QEMU,
	# on a card an eighth the size of the real one -- a size this
	# arithmetic had never been given.
	#
	crash := Efscrashsec;
	avail := cards - estart;
	if(avail < Efsmin){
		#
		# No room above the FAT, so efs lives in FILES on it.
		#
		# This card is one FAT32 partition from sector 2048 to the
		# end -- the table says 2048..62357503 and the BPB's
		# totsec32 says 62355456, so the filesystem uses all of it
		# and there is no space above it or unused inside it.
		# doc/raspi3b-completion-plan.ms had asked for "sectors
		# 1064960 upward", which was a wrong reading of this card:
		# there is nothing there.
		#
		# A file is a weaker home than a partition and the marker
		# says so.  What it still tests is the format and the server
		# against real media and a real SD driver, at a real card's
		# timings; what it cannot test is raw partition access, which
		# is what the QEMU arm covers.
		#
		sys->print("EFS-NOROOM %d sectors above the FAT at %d; using files on it instead\n",
			avail, fstart + nsec);
		efsonfat();
		return;
	}
	if(avail < Efsmin + crash){
		sys->print("EFS-NOCRASH %d sectors above the FAT is not room for a filesystem and a %d-sector crash partition; the crash test is skipped\n",
			avail, crash);
		crash = 0;
	}
	cend := cards - 1 - crash;
	if(!efspart("efs", estart, cend))
		return;
	if(crash > 0 && !efspart("efscrash", cend + 1, cards - 1))
		return;
	sys->print("EFS-PART sectors %d..%d", estart, cend);
	if(crash > 0)
		sys->print(", crash partition %d..%d", cend + 1, cards - 1);
	sys->print("\n");

	#
	# Ream only when the operator asked AND the sectors are empty.
	#
	# Both halves are load-bearing and together they make repeated boots
	# idempotent, which is what a board that reboots all day needs: the
	# first boot after the file is put on the card finds zeros and makes
	# the filesystem, and every boot after that finds the filesystem it
	# made and mounts it, so the opt-in file can be left where it is.
	#
	# The zero check is the same rule as the kfs gap: mkefs writes, and
	# what it writes over had better be nobody's.  gapisclear() probes
	# three sectors rather than all of them, which is what it can afford
	# on every boot -- a check on the arithmetic, not a guarantee about
	# 30GB.
	#
	if(sys->open("/n/dos/efsream", Sys->OREAD) != nil){
		if(!gapisclear(estart, cend))
			sys->print("EFS-NOREAM sectors %d-%d are not empty; mounting what is there rather than reaming it\n",
				estart, cend);
		else{
			nb := (cend - estart + 1) / 8;
			sys->print("EFS-REAM /n/dos/efsream is present and the range is empty; %d blocks\n", nb);
			if(!efsdone("mkefs", "mkefs" :: "-n" :: string nb ::
					SDDEV + "/efs" :: nil)){
				sys->print("EFS-FAIL mkefs did not finish\n");
				return;
			}
		}
	}
	if(!efsmount("efs", "/n/efs"))
		return;
	sys->print("EFS-OK mounted\n");
	if(!efswork())
		return;
	if(crash > 0 && efscrashtest("efscrash"))
		sys->print("EFS-CRASH-OK the card held the last committed state\n");
}

#
# Run one board.cmd script.  Spawned, never called: see runremote.
#
#
# Run a command module in a child and report its pid, so the caller can
# wait for it with waitgone().  A command module's init() ends in exit,
# which terminates the process that called it, so it cannot simply be
# called and returned from -- the child is the whole point.
#
cmdproc(m: Command, argv: list of string, pidch: chan of int)
{
	pidch <-= sys->pctl(0, nil);
	{
		m->init(nil, argv);
	}exception e{
	"*" =>
		sys->print("BT-EXCEPTION %s\n", e);
	}
}

shellproc(sh: Shell, cmd: string, pidch: chan of int)
{
	pidch <-= sys->pctl(0, nil);
	{
		sh->init(nil, "sh" :: "-c" :: cmd :: nil);
	}exception e{
	"*" =>
		sys->print("RCMD-EXCEPTION %s\n", e);
	}
}

#
# Wait for a process to be gone.
#
# There is no wait for a plain spawned process the way there is for a
# command, and the one thing that is certainly true of a process that
# called exit is that /prog stops listing it.  A pid could in principle
# be reused inside the polling interval and this would then wait for
# the wrong process; at one board.cmd every fifteen seconds that is not
# a risk worth more code than this.
#
waitgone(pid: int)
{
	path := "/prog/" + string pid + "/status";
	for(;;){
		(ok, nil) := sys->stat(path);
		if(ok < 0)
			return;
		sys->sleep(200);
	}
}

#
# The mount is HELD between polls, and that is what lets the poll be
# frequent.
#
# This used to dial, mount, read, and unmount on every pass, which is a
# whole TCP connection and Styx session for one 1KB read -- and it is why
# the interval had to be fifteen seconds: at three, the comment below
# records, a new connection to the host took four to seven seconds to be
# answered and a health check read the server as wedged.  The load was
# the mounting, not the reading.  Held, a pass is one open and one read
# on a session that already exists, so it costs less at five seconds than
# the old one did at fifteen, and a command comes back three times
# sooner.
#
# Every failure drops the mount so the next pass dials afresh: that is
# the old behaviour, kept as the fallback, and it is what makes this safe
# against a host that restarts underneath us.
#
remoteheld := 0;

mountremote(addrs: list of string): int
{
	ok := -1;
	c: Sys->Connection;
	for(l := addrs; l != nil; l = tl l){
		(ok, c) = sys->dial(hd l, nil);
		if(ok >= 0)
			break;
	}
	if(ok < 0){
		rcmdfail(sys->sprint("dial %s: %r", hd addrs));
		return 0;
	}
	if(sys->mount(c.dfd, nil, "/n/remote", Sys->MREPL, "") < 0){
		rcmdfail(sys->sprint("mount /n/remote: %r"));
		return 0;
	}
	remoteheld = 1;
	return 1;
}

dropremote()
{
	if(remoteheld){
		unmountremote();
		remoteheld = 0;
	}
}

readcmdfile(addrs: list of string): string
{
	b := array[1024] of byte;
	n := 0;
	#
	# Twice: once on the mount we are holding, and if that fails, once
	# more on a fresh one.  A held mount whose far end went away fails
	# at the open, which is exactly the signal to dial again.
	#
	for(try := 0; try < 2; try++){
		if(!remoteheld && !mountremote(addrs))
			return nil;
		fd := sys->open(Cmdfile, Sys->OREAD);
		if(fd == nil){
			dropremote();
			if(try > 0)
				rcmdfail(sys->sprint("open %s: %r", Cmdfile));
			continue;
		}
		n = sys->read(fd, b, len b);
		fd = nil;
		if(n <= 0){
			dropremote();
			if(try > 0)
				rcmdfail(sys->sprint("read %s: %r", Cmdfile));
			continue;
		}
		break;
	}
	if(n <= 0)
		return nil;
	rcmdup();
	s := string b[0:n];
	# trim trailing newlines so a file rewritten identically but for
	# whitespace does not count as a new command
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' ||
	    s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	if(len s == 0)
		return nil;
	return s;
}
