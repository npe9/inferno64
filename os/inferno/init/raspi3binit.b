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

# Read the SD card exposed by devsd (#S) as /dev/sdM0/data - the Arasan
# SDHCI (sdemmcbcm.c), which is the path that works on the board.  Normal boot must not modify the firmware card.
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

	# the geometry the driver derived from the card's CSD, checked at
	# its only observable edge; both reads, nothing written
	cfd := sys->open("/dev/sdM0/ctl", Sys->OREAD);
	cbuf := array[512] of byte;
	cn := 0;
	if(cfd != nil)
		cn = sys->read(cfd, cbuf, len cbuf);
	if(cn <= 0){
		sys->print("SD-CAP-NONE cannot read /dev/sdM0/ctl: %r\n");
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
	for(i := 0; i < 300; i++){
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
	fatbig();
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
	sys->print("FAT-BIG-OK %d bytes written, read back and renamed\n", n);
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
	cfd := sys->open("/dev/sdM0/ctl", Sys->ORDWR);
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
	etherone("ether", "ETHER", 100, nil, nil, nil);

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
