implement Init;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
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

kuverify(name: string, want: int, sum: int): int
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil){
		sys->print("KUPDATE-VERIFY cannot reopen %s: %r\n", name);
		return -1;
	}
	buf := array[8192] of byte;
	got := 0;
	back := 0;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			sys->print("KUPDATE-VERIFY read %s: %r\n", name);
			return -1;
		}
		if(n == 0)
			break;
		back = kusum(back, buf, n);
		got += n;
	}
	if(got != want){
		sys->print("KUPDATE-VERIFY %s is %d bytes, wrote %d\n", name, got, want);
		return -1;
	}
	if(back != sum){
		sys->print("KUPDATE-VERIFY %s reads back differently (%#x against %#x)\n",
			name, back, sum);
		return -1;
	}
	sys->print("KUPDATE-VERIFY %d bytes read back identical\n", got);
	return 0;
}

kupdate()
{
	#
	# Wait for the card to be mounted before deciding there is
	# nothing to do.
	#
	# This is spawned before the FAT checks, deliberately, so that a
	# kernel update does not queue behind two minutes of them -- and
	# that put it ahead of the mount as well.  It read a file that
	# was not there yet and returned saying nothing, which is
	# indistinguishable from a board that was never asked to update:
	# one boot fetched a new kernel and the next, with the same card
	# and the same file on it, silently did not.  The only symptom is
	# an absence, which is the worst kind to chase.
	#
	# Sixty seconds, because the mount is behind sdcheck() and the
	# card is slow, and a board with no kupdate.txt at all waits that
	# long once and then says nothing, as before.
	#
	cfg: ref Sys->FD;
	for(w := 0; w < 60; w++){
		if((cfg = sys->open("/n/dos/kupdate.txt", Sys->OREAD)) != nil)
			break;
		sys->sleep(1000);
	}
	if(cfg == nil){
		#
		# Say so.  This used to return in silence, on the
		# reasoning that a board with no kupdate.txt should not
		# nag -- and that silence then cost most of a day.  The
		# board booted, printed nothing about updating, and
		# looked exactly like a board whose kupdate had hung,
		# which is a completely different fault with a
		# completely different cause.  A single line is cheaper
		# than telling those two apart from outside.
		#
		sys->print("KUPDATE-NONE cannot open /n/dos/kupdate.txt: %r\n");
		return;
	}
	b := array[256] of byte;
	n := sys->read(cfg, b, len b);
	cfg = nil;
	if(n <= 0){
		sys->print("KUPDATE-FAIL empty kupdate.txt\n");
		return;
	}
	# "net!addr!port [net!addr!port ...] /path": every field but the last
	# is somewhere to try.  A router changed under this board once and the
	# single address it had been given stopped existing, which cost a card
	# swap to correct - the one thing this whole mechanism exists to avoid.
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 2){
		sys->print("KUPDATE-FAIL want \"net!addr!port /path\" in kupdate.txt\n");
		return;
	}
	# built back to front and then reversed, so they are tried in the
	# order they are written: the first address in the file is the one
	# the board should be talking to now.
	rev: list of string;
	path := "";
	for(l := f; l != nil; l = tl l){
		if(tl l == nil)
			path = hd l;
		else
			rev = hd l :: rev;
	}
	addrs: list of string;
	for(l = rev; l != nil; l = tl l)
		addrs = hd l :: addrs;
	# Wait for the IP stack to exist and to have an address.  This runs
	# from a process spawned while the network is still coming up, and
	# dialling before /net is bound fails with "file does not exist",
	# which reads like a missing server rather than a missing namespace.
	# and wait for one.  Thirty seconds was not enough: the interface
	# has taken more than a minute to appear, and a kernel update that
	# gives up before the network exists is a board that cannot be
	# updated at all that boot.  Five minutes, in a process nothing
	# waits on.
	for(i := 0; i < 3000; i++){
		if(hasaddr())
			break;
		sys->sleep(100);
	}
	ok := -1;
	c: Sys->Connection;
	addr := "";
	for(l = addrs; l != nil; l = tl l){
		addr = hd l;
		(ok, c) = sys->dial(addr, nil);
		if(ok >= 0)
			break;
		sys->print("KUPDATE dial %s: %r\n", addr);
	}
	if(ok < 0){
		sys->print("KUPDATE-FAIL nowhere to fetch from\n");
		return;
	}
	if(sys->mount(c.dfd, nil, "/n/remote", Sys->MREPL, "") < 0){
		sys->print("KUPDATE-FAIL mount %s: %r\n", addr);
		return;
	}
	#
	# and take the mount down on every way out from here.  The board
	# fetched a kernel over a link that hung up mid-read -- "read
	# /os/inferno/raspi3b/kernel8.img: Hangup" -- and this returned
	# with the dead mount still on /n/remote.  A mount whose far end
	# is gone is not a file that fails, it is one that waits.
	#
	src := sys->open("/n/remote" + path, Sys->OREAD);
	if(src == nil){
		sys->print("KUPDATE-FAIL open %s: %r\n", path);
		unmountremote();
		return;
	}
	dst := sys->create("/n/dos/kernel8.new", Sys->OWRITE, 8r666);
	if(dst == nil){
		sys->print("KUPDATE-FAIL create kernel8.new: %r\n");
		unmountremote();
		return;
	}
	buf := array[8192] of byte;
	total := 0;
	sum := 0;
	for(;;){
		n = sys->read(src, buf, len buf);
		if(n < 0){
			sys->print("KUPDATE-FAIL read %s: %r\n", path);
			src = nil;
			dst = nil;
			unmountremote();
			return;
		}
		if(n == 0)
			break;
		if(sys->write(dst, buf[0:n], n) != n){
			sys->print("KUPDATE-FAIL write kernel8.new: %r\n");
			src = nil;
			dst = nil;
			unmountremote();
			return;
		}
		sum = kusum(sum, buf, n);
		total += n;
	}
	src = nil;
	dst = nil;
	unmountremote();
	if(total == 0){
		sys->print("KUPDATE-FAIL %s is empty\n", path);
		return;
	}
	sys->print("KUPDATE fetched %d bytes\n", total);
	#
	# Read back what was written before installing it.
	#
	# Every write above was checked and every one of them said it had
	# written what it was given, and the kernel that went onto the
	# card was still wrong: 14 of its 57 32KB chunks, the first 448KB
	# and one more, held the previous kernel's bytes instead.  The
	# board then did not boot and the card had to come out, which is
	# the one thing this whole mechanism exists to avoid.
	#
	# So the write's return value is not the evidence.  The file is.
	# This costs one more pass over 1.8MB through the same slow path
	# -- tens of seconds -- and it turns a board that does not boot
	# into a line that says why, with the working kernel still
	# installed.  That trade is not close.
	#
	if((n = kuverify("/n/dos/kernel8.new", total, sum)) < 0){
		sys->print("KUPDATE-FAIL what was written is not what was fetched; the old kernel is untouched\n");
		sys->remove("/n/dos/kernel8.new");
		return;
	}
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

#
# The card's two big writers, in the order they must not overlap.
#
# 1.9MB of kernel and 1.5MB of test data through one dossrv at the
# same time produced a kernel whose first 208KB were the previous
# kernel's bytes -- measured off the card in a reader, after it
# refused to boot.  One after the other, in one process, is all that
# is needed to stop that.
#
kuthenfat()
{
	kupdate();
	fatwrite();
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
	fatbig();
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
	cfd := sys->open(SDDEV + "/ctl", Sys->ORDWR);
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
	usbcheck();
	# in its own process: the shell must not wait behind a DHCP lease and
	# three pings, which take seconds and can be answered by nothing at all
	spawn ethercheck();
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

remotecmd()
{
	last := "-";
	seq := 0;

	# Let the boot's own work finish first; this is a convenience,
	# and it must never be what makes a boot fail.  Sixty seconds
	# also keeps it clear of kupdate, which uses the same mount
	# point and takes it down on its way out.
	sys->sleep(60000);
	addrs := remoteaddrs();
	if(addrs == nil)
		return;			# no kupdate.txt: nothing to talk to
	for(;;){
		sys->sleep(3000);
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
		{
			sh->init(nil, "sh" :: "-c" :: cmd :: nil);
		}exception e{
		"*" =>
			sys->print("RCMD-EXCEPTION %s\n", e);
		}
		sys->print("RCMD-END %d\n", seq);
	}
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
	if(cfg == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(cfg, b, len b);
	cfg = nil;
	if(n <= 0)
		return nil;
	(nf, f) := sys->tokenize(string b[0:n], " \t\r\n");
	if(nf < 2)
		return nil;
	rev: list of string;
	for(l := f; l != nil; l = tl l)
		if(tl l != nil)			# the last field is the path
			rev = hd l :: rev;
	addrs: list of string;
	for(l = rev; l != nil; l = tl l)
		addrs = hd l :: addrs;
	return addrs;
}

readcmdfile(addrs: list of string): string
{
	ok := -1;
	c: Sys->Connection;
	for(l := addrs; l != nil; l = tl l){
		(ok, c) = sys->dial(hd l, nil);
		if(ok >= 0)
			break;
	}
	if(ok < 0)
		return nil;
	if(sys->mount(c.dfd, nil, "/n/remote", Sys->MREPL, "") < 0)
		return nil;
	fd := sys->open(Cmdfile, Sys->OREAD);
	if(fd == nil){
		unmountremote();
		return nil;
	}
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	fd = nil;
	unmountremote();
	if(n <= 0)
		return nil;
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
