implement Etherusb;

#
# USB ethernet: a Limbo driver in the shape of 9front's nusb/ether.
# It serves the netif (#l-style) file interface devip's ethermedium
# binds to, backed by a USB ethernet device's bulk endpoints reached
# through #U.  ethermedium.c reaches an ethernet device purely by path
# (namec/chandial on clone/addr/N/data), so this styx server IS devip's
# ethernet, getting ARP, IPv6 ND and multicast-MAC mapping from the
# kernel.  A kernel devether card cannot take this role: it is probed at
# boot, before usbd has enumerated any USB NIC.
#
# The netif protocol (os/inferno/port/netif.c, os/inferno/ip/chandial.c):
#  - open <path>/clone -> allocates a conversation, the fid now IS that
#    conversation's ctl; reading it returns the conversation number.
#  - write "connect <ethertype>" to the ctl to filter the conversation
#    (ethermedium dials "...!0x800", "...!0x86DD" and "...!0x806").
#  - open <path>/N/data -> the frames of that type (full ethernet frames).
#  - read <path>/addr -> the MAC address as hex text.
#
# Two devices are driven:
#  - CDC Ethernet Control Model (class 2, subclass 6), the class QEMU's
#    -device usb-net offers in its second configuration.  One frame per
#    bulk transfer; a frame that is a multiple of maxpkt is terminated
#    by a zero-length packet.  This is the QEMU-verified path.
#  - SMSC LAN95xx (the Pi 3B's onboard LAN9514, vid 0424 did ec00):
#    vendor register access over ep0, 4-byte rx status words and 8-byte
#    tx command words around each frame, register init after 9front's
#    smsc.c.  This said "QEMU does not model the chip ... NOT
#    emulator-verified", and that stopped being true: tools/qemu-patches
#    0003 is this tree's own usb-lan9514 model, and the board suite's
#    raspi3b-usb and raspi4-usb configurations take a DHCP lease through
#    this path on every run (ETHER-DHCP-OK, 10.0.2.15).  It is the path
#    the suite exercises; the ECM path above is the one QEMU's own
#    usb-net offers.
#
# usbd starts this program with the device's ep0 name (epN.0) once it
# has enumerated and configured the device; usbd closes its own ep0
# data file first, since the kernel allows one open of an endpoint.
#
#	etherusb [-d] [-m mnt] [-a mac] epN.0
#
# Without a device it serves a canned MAC (the Stage 1 bind test).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Fid, Enotfound, Eopen, Ebadfid: import styxservers;

	nametree: Nametree;
	Tree: import nametree;

Etherusb: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# qid paths.  The served tree is mounted at an existing directory, but
# chandial's dial-string parser rejects a single-component path (the '/'
# must not be at position 0), so the ethernet interface itself is one
# level down: root -> the interface dir -> clone/addr/N.  bind is
# "ether <mnt>/<ifname>", where <ifname> is "ether" unless -i names
# another.  conversation n occupies three consecutive paths
# from Cbase + n*3 (dir, ctl, data).
Qroot, Qether, Qclone, Qaddr, Qstats: con big iota;
Cbase: con big 16;

# Frames held per conversation when nobody is reading.  This is a
# staleness bound, not a buffer size: the reader here drains at tens of
# frames a second, so sixty-four frames is seconds of queueing delay,
# and a reply delivered seconds late is indistinguishable from one that
# never came - the Pi answered every echo request it was sent and was
# still reported unreachable.  Eight frames is a fifth of a second at
# the measured drain rate, and what does not fit is dropped oldest
# first.
Nqueue: con 8;
Ntx: con 32;		# frames queued for the transmit process

Conn: adt {
	n:	int;
	etype:	int;		# ethertype filter: 0 none yet, <0 all
	promisc: int;
	reads:	list of ref Tmsg.Read;	# deferred data reads
	frames:	list of array of byte;	# queued frames, newest first
	ready:	list of array of byte;	# reversed: oldest first, taken from here
	nframes: int;
	nin:	int;			# frames matched to this conversation
	tlast:	int;			# when this conversation was last replied to
	tgap:	int;			# summed millisecond gaps between reads
	ngap:	int;			# how many gaps that is
	nout:	int;			# frames handed to a reader
	ndrop:	int;			# frames dropped, queue full and no reader
};

conns: array of ref Conn;
nconn := 0;
mac := array[6] of byte;
srv: ref Styxserver;
tree: ref Tree;
debug := 0;		# raised by -d
txc: chan of array of byte;
promisc := 0;
ndrop := 0;

# Where a frame that never reached the wire was lost.  The kernel counts
# what it hands the medium (ipifc pktout); these count what this server
# did with it, so a packet that leaves the IP stack and is never seen by
# the other end can be placed on one side of the bulk endpoint or the
# other.
ntx := 0;		# frames handed to transmit()
nqueued := 0;		# frames accepted onto the transmit channel
nwrit := 0;		# bulk writes that wrote the whole frame
nwerr := 0;		# bulk writes that did not
nrx := 0;		# frames delivered from the device
lasterr := "";		# what the last failed write said
ndump4 := 0;		# IPv4 frames dumped on the way out
ndump6 := 0;		# ARP frames dumped, for comparison

# The head of a frame as it is handed to the endpoint: destination and
# source mac, ethertype, and the start of what follows.  A frame the
# other end never sees is either not written or written wrong, and the
# second of those is only visible here.
#
# Under -d only.  These ran on every boot while the board's network was
# being found out, and they are noise now that it works: a console with
# frame dumps scrolling past it is one nothing else can be read on.
txdump(what: string, f: array of byte)
{
	s := "";
	n := len f;
	if(n > 50)
		n = 50;
	for(i := 0; i < n; i++)
		s += sys->sprint("%02x", int f[i]);
	sys->print("TXDUMP %s %d %s\n", what, len f, s);
}

# USB request type bits, standard requests and descriptor types
Rh2d: con 0;
Rd2h: con 16r80;
Rstd: con 0;
Rclass: con 16r20;
Rvendor: con 16r40;
Rdev: con 0;
Riface: con 1;
Rgetdesc: con 6;
Rsetconf: con 9;
Rsetiface: con 11;
Ddev: con 1;
Dconf: con 2;
Dstring: con 3;
Diface: con 4;
Dep: con 5;
Dcs: con 16r24;		# class-specific (CDC functional descriptors)
Ucdelay: con 50;
Uctries: con 4;

# CDC ECM
CDCETHER: con 16r0f;	# ethernet networking functional descriptor
CDCSETFILTER: con 16r43;
FILTERPROMISC: con 1;
FILTERALLMULTI: con 2;
FILTERDIRECTED: con 4;
FILTERBROADCAST: con 8;

Dev: adt {
	name:	string;		# epN.M
	id:	int;
	cfd:	ref Sys->FD;	# /dev/usb/epN.M/ctl
	dfd:	ref Sys->FD;	# /dev/usb/epN.M/data
	vid, did: int;
};

Kcanned, Kecm, Ksmsc: con iota;
kind := Kcanned;
dev: ref Dev;
bin, bout: ref Dev;		# bulk in / out endpoints
inmaxpkt := 64;
outmaxpkt := 64;
ctliface := 0;			# ECM control interface number

badmod(p: string)
{
	sys->fprint(sys->fildes(2), "etherusb: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

dir(name: string, perm: int, qid: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "network";
	d.qid.path = qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	return d;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil) badmod(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) badmod(Styxservers->PATH);
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil) badmod(Nametree->PATH);
	nametree->init();

	mnt := "/net.alt";
	# The name of the netif directory this instance serves.  It is an
	# argument because a machine can have more than one USB ethernet:
	# two instances both serving "ether" under the same mount point can
	# never both be reached, whatever the mount flag.  usbd names the
	# first one "ether" and numbers the rest.
	ifname := "ether";
	devname: string;
	macarg: string;
	for(argv = tl argv; argv != nil; argv = tl argv){
		a := hd argv;
		if(a == "-d")
			debug++;
		else if(a == "-m" && tl argv != nil){
			argv = tl argv;
			mnt = hd argv;
		} else if(a == "-i" && tl argv != nil){
			argv = tl argv;
			ifname = hd argv;
		} else if(a == "-a" && tl argv != nil){
			argv = tl argv;
			macarg = hd argv;
		} else
			devname = a;
	}

	# canned MAC (locally-administered) until a device supplies one
	mac[0]=byte 16r02; mac[1]=byte 16r00; mac[2]=byte 16r00;
	mac[3]=byte 16r11; mac[4]=byte 16r22; mac[5]=byte 16r33;
	if(macarg != nil && parsemac(macarg, mac) < 0){
		sys->print("etherusb: bad mac %s\n", macarg);
		return;
	}

	if(devname != nil){
		#
		# Timed, because this is where the boot goes.  The Pi has
		# taken between 8.7 and 95.2 seconds to reach the line
		# below, and the init check that waits for it has now been
		# given the wrong deadline twice on the strength of a
		# guess.  There is no sleep in here: it is all control
		# transfers to the chip's registers, so the number is a
		# measurement of the host controller's control path on
		# this silicon, and it belongs on the console rather than
		# in somebody's head.
		#
		t0 := sys->millisec();
		err := devsetup(devname, macarg != nil);
		if(err != nil){
			sys->print("ETHERUSB-FAIL %s: %s\n", devname, err);
			return;
		}
		ms := sys->millisec()-t0;
		per := 0;
		if(nctl > 0)
			per = ms/nctl;
		sys->print("ETHERUSB-SETUP %d ms for %s, %d control transfers, %d ms each\n",
			ms, devname, nctl, per);
	}

	conns = array[16] of ref Conn;

	navop: chan of ref Styxservers->Navop;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("etherusb: pipe: %r\n");
		return;
	}
	tchan: chan of ref Tmsg;
	# Inferno pipes are directional by endpoint: p[0] reads data written
	# through p[1].  The Styx server therefore owns p[1], while mount()
	# uses p[0] as its client endpoint.
	(tchan, srv) = Styxserver.new(p[1], nav, Qroot);

	tree.create(Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(Qroot, dir(ifname, Sys->DMDIR|8r555, Qether));
	tree.create(Qether, dir("clone", 8r666, Qclone));
	tree.create(Qether, dir("addr", 8r444, Qaddr));
	tree.create(Qether, dir("stats", 8r444, Qstats));

	rxc := chan of array of byte;
	txc = chan[Ntx] of array of byte;
	# Start the 9P server before workers that can block in the HCD or
	# on the receive channel; the mount handshake must have a responder
	# even if the device presents receive data immediately.
	spawn server(tchan, rxc);
	if(dev != nil){
		spawn rxproc(rxc);
		spawn txproc();
	}

	# spawn the server loop BEFORE mounting: mount performs the 9P
	# handshake against our styx server, so the loop that answers it must
	# already be running or mount deadlocks.
	#
	# This mount was disabled on the Pi because the board wedged entering
	# the syscall.  That was before the kernel's SP-alignment fault was
	# found (a process whose kernel stack came back 8-byte aligned from
	# malloc faulted endlessly the first time it used it), which is the
	# shape of fault that stops a process dead in a syscall, so it is
	# tried again rather than assumed.  mountproc does it in its own
	# process: if it does wedge, the server and the board keep running.
	spawn mountproc(p[0], mnt);
	p[0] = nil;
	p[1] = nil;
	sys->print("ETHERUSB serving %s/%s mac %s %s\n", mnt, ifname, macstr(), kindname());

	# keep the process alive so the server and transfer procs keep running
	c := chan of int;
	<-c;
}

mountproc(fd: ref Sys->FD, mnt: string)
{
	# MAFTER, not MREPL.  MREPL was right while one adapter was the
	# most a board could have; with two, the second instance's mount
	# replaced the first and the first became unreachable while its
	# procs went on running.  A union keeps both directories visible,
	# which is only useful because they now have different names.
	if(sys->mount(fd, nil, mnt, Sys->MAFTER|Sys->MCREATE, nil) < 0)
		sys->print("etherusb: mount %s: %r\n", mnt);
}

kindname(): string
{
	case kind {
	Kecm =>		return "(CDC ECM " + dev.name + ")";
	Ksmsc =>	return "(SMSC LAN95xx " + dev.name + ")";
	}
	return "(no device, canned)";
}

macstr(): string
{
	s := "";
	for(i := 0; i < 6; i++)
		s += sys->sprint("%2.2ux", int mac[i]);
	return s;
}

parsemac(s: string, m: array of byte): int
{
	n := 0;
	v := 0;
	nd := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else if(c == ':' || c == '-')
			continue;
		else
			return -1;
		v = v<<4 | d;
		if(++nd == 2){
			if(n >= 6)
				return -1;
			m[n++] = byte v;
			v = 0;
			nd = 0;
		}
	}
	if(n != 6 || nd != 0)
		return -1;
	return 0;
}

#
# the device: open ep0, identify it, bring it up, make the bulk endpoints
#
devsetup(name: string, havemac: int): string
{
	dev = opendev(name);
	if(dev == nil)
		return sys->sprint("open %s: %r", name);
	if(opendevdata(dev) < 0)
		return sys->sprint("open %s data: %r", name);
	(r, dd) := usbin(dev, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 18);
	if(r < 18)
		return "device descriptor";
	dev.vid = int dd[8] | int dd[9]<<8;
	dev.did = int dd[10] | int dd[11]<<8;
	nconf := int dd[17];
	if(dev.vid == 16r0424)
		return smscsetup(havemac);
	return ecmsetup(nconf);
}

# walk a configuration descriptor's interfaces/endpoints.  Returns, for
# the ECM case: (confval, ctl iface, imac string index, data iface, data
# alt, bulk in ep, in maxpkt, bulk out ep, out maxpkt), with -1 for what
# was not found.  For a vendor device the bulk endpoints of the first
# interface are what matter.
Cfg: adt {
	confval: int;
	ctliface: int;
	imac:	int;
	dataiface: int;
	altn:	int;
	inep, inmax: int;
	outep, outmax: int;
	intrep: int;
};

readconf(c: int): (ref Cfg, array of byte)
{
	(r, cd) := usbin(dev, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8 | c, 0, 9);
	if(r < 9)
		return (nil, nil);
	total := int cd[2] | int cd[3]<<8;
	if(total > 1024)
		total = 1024;
	(r, cd) = usbin(dev, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8 | c, 0, total);
	if(r < 9)
		return (nil, nil);
	cf := ref Cfg(int cd[5], -1, -1, -1, -1, -1, 0, -1, 0, -1);
	iface := -1;
	altn := 0;
	class := 0;
	sub := 0;
	i := 0;
	while(i + 1 < r){
		l := int cd[i];
		t := int cd[i+1];
		if(l < 2)
			break;
		case t {
		Diface =>
			if(i + 9 > r)
				break;
			iface = int cd[i+2];
			altn = int cd[i+3];
			class = int cd[i+5];
			sub = int cd[i+6];
			if(class == 2 && sub == 6)
				cf.ctliface = iface;
		Dcs =>
			if(class == 2 && sub == 6 && l >= 13 && int cd[i+2] == CDCETHER)
				cf.imac = int cd[i+3];
		Dep =>
			if(i + 7 > r)
				break;
			addr := int cd[i+2];
			attr := int cd[i+3];
			maxpkt := int cd[i+4] | int cd[i+5]<<8;
			isdata := class == 10 || class == 16rff;
			if(isdata && (attr & 3) == 2){
				# a data interface alt with both bulk endpoints
				# wins; ECM's alt 0 has none
				if(cf.dataiface != iface || cf.altn != altn){
					cf.dataiface = iface;
					cf.altn = altn;
					cf.inep = cf.outep = -1;
				}
				if(addr & 16r80){
					cf.inep = addr & 16r0f;
					cf.inmax = maxpkt;
				} else {
					cf.outep = addr & 16r0f;
					cf.outmax = maxpkt;
				}
			} else if((attr & 3) == 3 && (addr & 16r80))
				cf.intrep = addr & 16r0f;
		}
		i += l;
	}
	return (cf, cd);
}

#
# CDC Ethernet Control Model
#
ecmsetup(nconf: int): string
{
	cf: ref Cfg;
	for(c := 0; c < nconf; c++){
		(cf, nil) = readconf(c);
		if(cf != nil && cf.ctliface >= 0 && cf.inep >= 0 && cf.outep >= 0)
			break;
		cf = nil;
	}
	if(cf == nil)
		return "no CDC ECM configuration with bulk endpoints";
	kind = Kecm;
	ctliface = cf.ctliface;
	if(usbcmd(dev, Rh2d|Rstd|Rdev, Rsetconf, cf.confval, 0, nil, 0) < 0)
		return sys->sprint("set configuration %d: %r", cf.confval);
	# ECM's data interface has an alternate setting with the endpoints
	if(usbcmd(dev, Rh2d|Rstd|Riface, Rsetiface, cf.altn, cf.dataiface, nil, 0) < 0)
		return sys->sprint("set interface %d alt %d: %r", cf.dataiface, cf.altn);
	# the MAC is a string descriptor of 12 hex digits (UTF-16LE)
	if(cf.imac > 0){
		(r, sd) := usbin(dev, Rd2h|Rstd|Rdev, Rgetdesc, Dstring<<8 | cf.imac, 16r0409, 64);
		if(r < 2 + 24)
			return "MAC string descriptor";
		s := "";
		for(i := 2; i + 1 < int sd[0] && i + 1 < r; i += 2)
			s[len s] = int sd[i];
		if(parsemac(s, mac) < 0)
			return "bad MAC string " + s;
	}
	if(openeps(cf) < 0)
		return sys->sprint("endpoints: %r");
	ecmfilter();
	return nil;
}

# SetEthernetPacketFilter (ECM 6.2.4).  QEMU's usb-net does not
# implement it (it stalls the request and delivers everything anyway),
# so a failure here is reported, not fatal; a real ECM device wants it.
ecmfilter()
{
	f := FILTERDIRECTED|FILTERBROADCAST|FILTERALLMULTI;
	if(promisc)
		f |= FILTERPROMISC;
	if(cmdreq(dev, Rh2d|Rclass|Riface, CDCSETFILTER, f, ctliface, nil, 0) < 0)
		sys->print("etherusb: %s: set packet filter %#x: %r (ignored)\n", dev.name, f);
}

#
# SMSC LAN95xx, after 9front's nusb/ether/smsc.c (and Linux smsc95xx).
# Registers are read and written with vendor requests A1/A0 on ep0, a
# 4-byte little-endian value, the register address in wIndex.
#
Idrev: con 16r00;
Intsts: con 16r08;
Txcfg: con 16r10;
Hwcfg: con 16r14;
Pmctrl: con 16r20;
Afccfg: con 16r2C;
E2pcmd: con 16r30;
E2pdata: con 16r34;
Burstcap: con 16r38;
Intepctl: con 16r68;
Bulkdelay: con 16r6C;
Maccr: con 16r100;
Addrh: con 16r104;
Addrl: con 16r108;
Hashh: con 16r10C;
Hashl: con 16r110;
MIIaddr: con 16r114;
MIIdata: con 16r118;
Flow: con 16r11C;
Vlan1: con 16r120;
Coecr: con 16r130;

Bir: con 1<<12;		# Hwcfg: bulk in empty response
Rxdoff: con 3<<9;	# Hwcfg: rx data offset
Mef: con 1<<5;		# Hwcfg: multiple ethernet frames per transfer
Lrst: con 1<<3;		# Hwcfg: lite reset
Bce: con 1<<1;		# Hwcfg: burst cap enable
Phyrst: con 1<<4;	# Pmctrl
E2pbusy: con 1<<31;	# E2pcmd
E2ptimeout: con 1<<10;
E2pread: con 0;
Mcpas: con 1<<19;	# Maccr: multicast pass
Prms: con 1<<18;	# Maccr: promiscuous
Hpfilt: con 1<<13;	# Maccr: hash perfect filter
Txen: con 1<<3;
Rxen: con 1<<2;
Txon: con 1<<2;		# Txcfg
Txcoe: con 1<<16;	# Coecr
Rxcoe: con 1<<0;
MIIwrite: con 1<<1;
MIIbusy: con 1<<0;
Phyint: con 1<<15;	# Intepctl
PHYinternal: con 1;
Afcdefault: con 16rF830A1;
Hsburst: con 37;	# Burstcap in 512-byte high-speed packets
Fsburst: con 129;	# in 64-byte full-speed packets
Defbulkdly: con 16r2000;
Ethp8021q: con 16r8100;
MACoffset: con 1;	# EEPROM byte offset of the MAC
Rxerror: con 16r8000;	# rx status word
Txfirst: con 16r2000;	# tx command word A
Txlast: con 16r1000;
Resettime: con 1000;
E2pbusytime: con 1000;
# PHY (MII) registers
Bmcr: con 0;
Bmsr: con 1;
Bmsrlink: con 1<<2;			# link is up (latching low)
Anar: con 4;
Bmcrreset: con 1<<15;
Bmcranenable: con 1<<12;
Bmcrrestart: con 1<<9;
Anardefault: con 16r0DE1;	# 10/100 half/full, pause, 802.3 selector
Phyintsrc: con 29;
Phyintmask: con 30;
Anegcomp: con 1<<6;
Linkdown: con 1<<4;

# how many control transfers the set-up costs, and how long they take:
# ETHERUSB-SETUP is measured in seconds and a control transfer should be
# a millisecond, so the count is what says which of those two numbers is
# surprising
nctl := 0;

wr(reg, val: int): int
{
	nctl++;
	b := array[4] of byte;
	b[0] = byte val; b[1] = byte (val>>8); b[2] = byte (val>>16); b[3] = byte (val>>24);
	if(usbcmd(dev, Rh2d|Rvendor|Rdev, 16rA0, 0, reg, b, 4) < 0){
		sys->print("etherusb: smsc write reg %#x: %r\n", reg);
		return -1;
	}
	return 0;
}

rr(reg: int): int
{
	nctl++;
	(n, b) := usbin(dev, Rd2h|Rvendor|Rdev, 16rA1, 0, reg, 4);
	if(n < 4){
		sys->print("etherusb: smsc read reg %#x: %r\n", reg);
		return -1;
	}
	return int b[0] | int b[1]<<8 | int b[2]<<16 | int b[3]<<24;
}

miird(idx: int): int
{
	wr(MIIaddr, PHYinternal<<11 | idx<<6);
	for(i := 0; i < 100 && (rr(MIIaddr) & MIIbusy); i++)
		;
	return rr(MIIdata);
}

miiwr(idx, val: int)
{
	wr(MIIdata, val);
	wr(MIIaddr, PHYinternal<<11 | idx<<6 | MIIwrite);
	for(i := 0; i < 100 && (rr(MIIaddr) & MIIbusy); i++)
		;
}

eepromr(off: int, buf: array of byte): int
{
	for(i := 0; i < E2pbusytime; i++)
		if((rr(E2pcmd) & E2pbusy) == 0)
			break;
	if(i == E2pbusytime)
		return -1;
	for(i = 0; i < len buf; i++){
		wr(E2pcmd, E2pbusy|E2pread|(off+i));
		v := 0;
		for(j := 0; j < E2pbusytime; j++){
			v = rr(E2pcmd) & (E2pbusy|E2ptimeout);
			if(v != E2pbusy)
				break;
		}
		if(v & E2ptimeout)
			return -1;
		buf[i] = byte rr(E2pdata);
	}
	return 0;
}

# wait for a self-clearing reset bit
doreset(reg, bit: int): int
{
	if(wr(reg, bit) < 0)
		return -1;
	for(i := 0; i < Resettime/10; i++){
		if((rr(reg) & bit) == 0)
			return 0;
		sys->sleep(10);
	}
	return -1;
}

phyinit()
{
	miiwr(Bmcr, Bmcrreset);
	for(i := 0; i < Resettime/10; i++){
		if((miird(Bmcr) & Bmcrreset) == 0)
			break;
		sys->sleep(10);
	}
	miiwr(Anar, Anardefault);
	miird(Phyintsrc);			# clear pending
	miiwr(Phyintmask, Anegcomp|Linkdown);
	miiwr(Bmcr, miird(Bmcr)|Bmcranenable|Bmcrrestart);
	# Say whether the cable is in.  A receive on a link that is down
	# never completes, and the only symptom otherwise is the host
	# controller's wait expiring twenty seconds later, which reads like
	# a driver fault rather than an unplugged socket.
	for(i = 0; i < Resettime/10; i++){
		if(miird(Bmsr) & Bmsrlink)
			break;
		sys->sleep(10);
	}
	status := miird(Bmsr);
	if(status & Bmsrlink)
		sys->print("etherusb: link up (bmsr %#4.4ux)\n", status);
	else
		sys->print("etherusb: LINK DOWN (bmsr %#4.4ux): nothing will be received\n",
			status);
}

# the MAC: the chip's EEPROM if there is one and it is programmed,
# else the board's address from the firmware (/env/ethaddr, which the
# Pi 3B kernel sets from the VideoCore mailbox), else what -a gave
smscmac(havemac: int): string
{
	ea := array[6] of byte;
	if(eepromr(MACoffset, ea) == 0){
		blank := 1;
		for(i := 0; i < 6; i++)
			if(ea[i] != byte 16rff && ea[i] != byte 0)
				blank = 0;
		if(!blank){
			mac[0:] = ea;
			return nil;
		}
	}
	if(havemac)
		return nil;
	fd := sys->open("/env/ethaddr", Sys->OREAD);
	if(fd != nil){
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0 && parsemac(string buf[0:n], mac) == 0)
			return nil;
	}
	return "no MAC: EEPROM blank, no /env/ethaddr, no -a";
}

smscsetup(havemac: int): string
{
	kind = Ksmsc;
	(cf, nil) := readconf(0);
	if(cf == nil || cf.inep < 0 || cf.outep < 0)
		return "no bulk endpoints in configuration 1";
	id := rr(Idrev);
	if(id < 0)
		return "cannot read ID_REV";
	sys->print("etherusb: smsc id_rev %#8.8ux\n", id);
	if(doreset(Hwcfg, Lrst) < 0)
		return "lite reset timed out";
	if(doreset(Pmctrl, Phyrst) < 0)
		return "PHY reset timed out";
	err := smscmac(havemac);
	if(err != nil)
		return err;
	wr(Addrl, int mac[0] | int mac[1]<<8 | int mac[2]<<16 | int mac[3]<<24);
	wr(Addrh, int mac[4] | int mac[5]<<8);
	# burst mode: several frames per bulk-in transfer, each 4-aligned,
	# no rx data offset (the frame follows its status word directly)
	wr(Hwcfg, (rr(Hwcfg) & ~Rxdoff) | Bir | Mef | Bce);
	if(cf.inmax >= 512)
		wr(Burstcap, Hsburst);
	else
		wr(Burstcap, Fsburst);
	wr(Bulkdelay, Defbulkdly);
	wr(Intsts, ~0);
	wr(Afccfg, Afcdefault);
	wr(Vlan1, Ethp8021q);
	wr(Coecr, rr(Coecr) & ~(Txcoe|Rxcoe));	# no checksum offload
	wr(Hashh, 0);
	wr(Hashl, 0);
	wr(Maccr, rr(Maccr) & ~(Mcpas|Prms|Hpfilt));
	phyinit();
	wr(Intepctl, rr(Intepctl) | Phyint);
	wr(Maccr, rr(Maccr) | Txen | Rxen);
	wr(Txcfg, Txon);
	if(openeps(cf) < 0)
		return sys->sprint("endpoints: %r");
	return nil;
}

smscpromisc(on: int)
{
	v := rr(Maccr);
	if(on)
		v |= Prms | Mcpas;
	else
		v &= ~(Prms | Mcpas);
	wr(Maccr, v);
}

#
# the bulk endpoints, made on ep0's ctl and opened as their own files
#
# devusb keys endpoints by number, so an IN and an OUT endpoint that
# share a number (QEMU's usb-net: EP2 in and EP2 out) are one "rw"
# endpoint whose data file is read and written; the HCD serialises the
# two directions separately.
openeps(cf: ref Cfg): int
{
	inmaxpkt = cf.inmax;
	outmaxpkt = cf.outmax;
	if(cf.inep == cf.outep){
		if(devctl(dev, sys->sprint("new %d bulk rw", cf.inep)) < 0)
			return -1;
		bin = opendev(sys->sprint("ep%d.%d", dev.id, cf.inep));
		if(bin == nil)
			return -1;
		bout = bin;
		if(devctl(bin, sys->sprint("maxpkt %d", inmaxpkt)) < 0)
			return -1;
		if(debug)
			devctl(bin, "debug 2");
		bin.dfd = sys->open("/dev/usb/" + bin.name + "/data", Sys->ORDWR);
		if(bin.dfd == nil)
			return -1;
		sys->print("etherusb: %s: bulk in/out %s (%d)\n", dev.name, bin.name, inmaxpkt);
		return 0;
	}
	if(devctl(dev, sys->sprint("new %d bulk r", cf.inep)) < 0)
		return -1;
	if(devctl(dev, sys->sprint("new %d bulk w", cf.outep)) < 0)
		return -1;
	bin = opendev(sys->sprint("ep%d.%d", dev.id, cf.inep));
	bout = opendev(sys->sprint("ep%d.%d", dev.id, cf.outep));
	if(bin == nil || bout == nil)
		return -1;
	if(devctl(bin, sys->sprint("maxpkt %d", inmaxpkt)) < 0)
		return -1;
	if(devctl(bout, sys->sprint("maxpkt %d", outmaxpkt)) < 0)
		return -1;
	if(debug){
		devctl(bin, "debug 2");
		devctl(bout, "debug 2");
	}
	bin.dfd = sys->open("/dev/usb/" + bin.name + "/data", Sys->OREAD);
	bout.dfd = sys->open("/dev/usb/" + bout.name + "/data", Sys->OWRITE);
	if(bin.dfd == nil || bout.dfd == nil)
		return -1;
	sys->print("etherusb: %s: bulk in %s (%d) out %s (%d)\n",
		dev.name, bin.name, inmaxpkt, bout.name, outmaxpkt);
	return 0;
}

#
# receive: one process reads the bulk-in endpoint forever and hands
# whole frames to the server loop, which owns the conversations
#
#
# Transfers and frames, counted separately in each direction.
#
# The cost of a round trip on this board scales with the number of
# Ethernet frames in it -- 6.4ms for one, about 4.6ms for each one after
# -- and the question that decides where to look is how many frames ride
# in one USB transfer.  Receive packs them: Burstcap is 37 512-byte
# packets, so one read can carry 18.9KB.  Transmit writes one frame per
# transfer.  These count it rather than assuming it; read them from
# /net.alt/ether/stats before and after a known workload.
#
rxreads := 0;		# bulk-in transfers that returned data
rxframes := 0;		# ethernet frames pulled out of them
txwrites := 0;		# bulk-out transfers issued
txframes := 0;		# ethernet frames handed to them

rxproc(rxc: chan of array of byte)
{
	nbuf := 2048;
	if(kind == Ksmsc){
		if(inmaxpkt >= 512)
			nbuf = Hsburst*512;
		else
			nbuf = Fsburst*64;
	}
	buf := array[nbuf] of byte;
	nzero := 0;
	for(;;){
		n := sys->read(bin.dfd, buf, len buf);
		if(n < 0){
			sys->print("etherusb: %s: receive stopped: %r\n", dev.name);
			return;
		}
		if(n == 0){
			# Nothing to read.  On the SMSC chip that is normal and
			# expected: smscsetup sets Hwcfg's Bir, which asks the
			# chip to answer an empty receive FIFO with a zero
			# length packet instead of holding the transfer off, so
			# an idle link reads 0 continuously.  On anything else a
			# zero read means a stalled or halted endpoint and is
			# worth saying so once.  Either way, sleep rather than
			# spin.
			if(kind != Ksmsc && nzero++ < 3)
				sys->print("etherusb: %s: empty read\n", bin.name);
			sys->sleep(10);
			continue;
		}
		nzero = 0;
		rxreads++;
		if(kind == Ksmsc)
			smscrx(buf[0:n], rxc);
		else if(n >= 14){
			f := array[n] of byte;
			f[0:] = buf[0:n];
			rxc <-= f;
		}
	}
}

# a burst: [4-byte status][frame incl. FCS][pad to 4]...  The status
# word's bits 16-29 are the frame length including its 4-byte FCS.
smscrx(b: array of byte, rxc: chan of array of byte)
{
	while(len b >= 4){
		sts := int b[0] | int b[1]<<8 | int b[2]<<16 | int b[3]<<24;
		n := (sts>>16) & 16r3fff;
		b = b[4:];
		if(n < 4 || n > len b)
			break;
		if((sts & Rxerror) == 0 && n - 4 >= 14){
			f := array[n-4] of byte;	# strip the FCS
			f[0:] = b[0:n-4];
			rxframes++;
			rxc <-= f;
		}
		n = (n + 3) & ~3;
		if(n > len b)
			break;
		b = b[n:];
	}
}

#
# transmit: frames queued by the server loop go out on the bulk-out
# endpoint, one transfer each, with the zero-length packet a frame
# that is an exact multiple of maxpkt needs to be delimited
#
txproc()
{
	zlp := array[0] of byte;
	for(;;){
		f := <-txc;
		txframes++;
		frame0 := f;
		n := len f;
		if(kind == Ksmsc){
			t := array[8+n] of byte;
			a := n | Txfirst | Txlast;
			t[0] = byte a; t[1] = byte (a>>8); t[2] = byte (a>>16); t[3] = byte (a>>24);
			t[4] = byte n; t[5] = byte (n>>8); t[6] = byte (n>>16); t[7] = byte (n>>24);
			t[8:] = f;
			f = t;
		} else if(n < 60){
			# minimum ethernet frame; ECM devices do not pad
			t := array[60] of { * => byte 0 };
			t[0:] = f;
			f = t;
		}
		t := 0;
		if(len frame0 >= 14)
			t = (int frame0[12] << 8) | int frame0[13];
		if(debug){
			if(t == 16r800 && ndump4++ < 4)
				txdump("ip", f);
			else if(t == 16r806 && ndump6++ < 2)
				txdump("arp", f);
		}
		if(debug)
			sys->print("etherusb: tx write %d\n", len f);
		txwrites++;
		if(sys->write(bout.dfd, f, len f) != len f){
			nwerr++;
			lasterr = sys->sprint("%r");
			sys->print("etherusb: %s: transmit: %r\n", dev.name);
			continue;
		}
		nwrit++;
		if(debug)
			sys->print("etherusb: tx done %d\n", len f);
		#
		# ONLY when the frame is an exact multiple of maxpkt.
		#
		# This was written without braces:
		#
		#	if(len f % outmaxpkt == 0)
		#		txwrites++;
		#		sys->write(bout.dfd, zlp, 0);
		#
		# and Limbo's if takes one statement, so the counter was the
		# whole body and the zero-length packet went out after EVERY
		# frame.  The indentation said otherwise and so does the
		# comment at the top of this function, which is why it read
		# as correct for so long.
		#
		# A bulk-out transfer is about four milliseconds on this
		# board, and the counters say transmit is one frame per
		# transfer, so this was doubling the cost of the whole
		# transmit path to no purpose: a ZLP is only needed to
		# delimit a transfer the device would otherwise wait for more
		# of, which is exactly the exact-multiple case.
		#
		if(len f % outmaxpkt == 0){
			txwrites++;
			sys->write(bout.dfd, zlp, 0);
		}
	}
}

#
# the styx server: conversations, deferred reads, and frame delivery
#
server(tchan: chan of ref Tmsg, rxc: chan of array of byte)
{
	for(;;) alt {
	gm := <-tchan =>
		if(gm == nil){
			tree.quit();
			exit;
		}
		e := handle(gm);
		if(e != nil)
			srv.reply(ref Rmsg.Error(gm.tag, e));
	f := <-rxc =>
		deliver(f);
	}
}

# is qid path p a conversation ctl / data file?  returns (connno, kind)
# kind: 0 dir, 1 ctl, 2 data, -1 not a conversation path
convof(p: big): (int, int)
{
	if(p < Cbase)
		return (-1, -1);
	off := int (p - Cbase);
	return (off / 3, off % 3);
}

handle(gm: ref Tmsg): string
{
	pick m := gm {
	Open =>
		(fid, nil, nil, err) := srv.canopen(m);
		if(fid == nil)
			return err;
		if(fid.path == Qclone){
			# allocate a conversation; the fid becomes its ctl
			n := nconn++;
			if(n >= len conns){
				nc := array[2*len conns] of ref Conn;
				nc[0:] = conns;
				conns = nc;
			}
			conns[n] = ref Conn(n, 0, 0, nil, nil, nil, 0, 0, 0, 0, 0, 0, 0);
			cdir := Cbase + big(n*3);
			tree.create(Qether, dir(string n, Sys->DMDIR|8r555, cdir));
			tree.create(cdir, dir("ctl", 8r666, cdir+big 1));
			tree.create(cdir, dir("data", 8r666, cdir+big 2));
			cq := Sys->Qid(cdir+big 1, 0, Sys->QTFILE);
			fid.open(m.mode, cq);
			srv.reply(ref Rmsg.Open(m.tag, cq, srv.msize-styx->IOHDRSZ));
			return nil;
		}
		srv.open(m);			# normal open (addr, data, dir) replies
		return nil;
	Read =>
		(fid, err) := srv.canread(m);
		if(fid == nil)
			return err;
		(cn, fk) := convof(fid.path);
		if(fid.path == Qaddr){
			srv.reply(styxservers->readstr(m, macstr()));
			return nil;
		}
		if(fid.path == Qstats){
			rg := 0;
			if(rxn > 0)
				rg = rxgap / rxn;
			ss := sys->sprint(
				"ntx %d\nnqueued %d\nnwrit %d\nnwerr %d\nndrop %d\nnrx %d rxgap %d\nlasterr %s\n",
				ntx, nqueued, nwrit, nwerr, ndrop, nrx, rg, lasterr);
			#
			# The numbers phase 2 of doc/raspi3b-net-plan.ms asks
			# for: how many ethernet frames ride in one USB
			# transfer, each way.  Sample before and after a known
			# workload and divide; nothing is timed here, because
			# anything timed in this path moves what it measures.
			#
			ss += sys->sprint("usb rxreads %d rxframes %d txwrites %d txframes %d\n",
				rxreads, rxframes, txwrites, txframes);
			for(i := 0; i < nconn; i++){
				c := conns[i];
				np := 0;
				for(rl := c.reads; rl != nil; rl = tl rl)
					np++;
				g := 0;
				if(c.ngap > 0)
					g = c.tgap / c.ngap;
				ss += sys->sprint("conv %d etype %#x in %d out %d drop %d held %d waiting %d gap %d\n",
					i, c.etype, c.nin, c.nout, c.ndrop, c.nframes, np, g);
			}
			srv.reply(styxservers->readstr(m, ss));
			return nil;
		}
		if(fk == 1){			# ctl read -> conversation number
			srv.reply(styxservers->readstr(m, string cn + "\n"));
			return nil;
		}
		if(fk == 2){			# data read: a queued frame, else wait
			c := conns[cn];
			# how long the kernel took to come back for the next
			# frame: the receive ceiling is either this gap or the
			# work this server does between frames, and the two are
			# told apart by measuring one of them
			t := sys->millisec();
			if(c.tlast != 0){
				c.tgap += t - c.tlast;
				c.ngap++;
			}
			c.tlast = t;
			if(c.nframes > 0){
				f := oldest(c);
				srv.reply(ref Rmsg.Read(m.tag, f[0:min(m.count, len f)]));
			} else
				c.reads = m :: c.reads;
			return nil;
		}
		srv.read(m);			# directories via the navigator
		return nil;
	Write =>
		(fid, err) := srv.canwrite(m);
		if(fid == nil)
			return err;
		(cn, fk) := convof(fid.path);
		if(fk == 1){			# ctl: connect/promiscuous/nonblocking/...
			e := ctl(cn, string m.data);
			if(e != nil)
				return e;
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
			return nil;
		}
		if(fk == 2){			# data: a frame to transmit
			transmit(cn, m.data);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
			return nil;
		}
		return "cannot write here";
	Flush =>
		# a flushed read must not be answered later
		for(i := 0; i < nconn; i++){
			c := conns[i];
			l: list of ref Tmsg.Read;
			for(; c.reads != nil; c.reads = tl c.reads)
				if((hd c.reads).tag != m.oldtag)
					l = hd c.reads :: l;
			c.reads = l;
		}
		srv.default(gm);
	Clunk =>
		fid := srv.getfid(m.fid);
		if(fid != nil){
			(cn, fk) := convof(fid.path);
			if(fk == 2 && cn < nconn)
				conns[cn].reads = nil;
		}
		srv.default(gm);
	* =>
		srv.default(gm);
	}
	return nil;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

# Frames arrive newest-first on one list and are taken oldest-first from
# another, which is filled by reversing the first when it runs out: each
# frame is moved once, so a read costs the same whatever the queue holds.
# Reversing the whole queue on every read cost O(n) per frame, and since
# that work is on the path that drains the queue, a queue that grew made
# the server slower and so grew further: at sixty-four deep the kernel
# came back for a frame every 177ms, at eight deep every 62ms.
oldest(c: ref Conn): array of byte
{
	if(c.ready == nil){
		for(l := c.frames; l != nil; l = tl l)
			c.ready = hd l :: c.ready;
		c.frames = nil;
	}
	f := hd c.ready;
	c.ready = tl c.ready;
	c.nframes--;
	return f;
}

# an ethertype as chandial/ethermedium write it: "0x800", "0x86DD",
# "0x806", or decimal; -1 means every frame
etype(s: string): int
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')){
		v := 0;
		for(i := 2; i < len s; i++){
			c := s[i];
			if(c >= '0' && c <= '9')
				v = v*16 + c - '0';
			else if(c >= 'a' && c <= 'f')
				v = v*16 + c - 'a' + 10;
			else if(c >= 'A' && c <= 'F')
				v = v*16 + c - 'A' + 10;
			else
				break;
		}
		return v;
	}
	return int s;
}

ctl(cn: int, s: string): string
{
	(nil, flds) := sys->tokenize(s, " \t\n");
	if(flds == nil)
		return nil;
	cmd := hd flds;
	c := conns[cn];
	case cmd {
	"connect" =>
		if(tl flds == nil)
			return "bad connect";
		t := etype(hd tl flds);
		if(t > 0)
			for(i := 0; i < nconn; i++)
				if(i != cn && conns[i].etype == t)
					return "type in use";
		c.etype = t;
	"promiscuous" =>
		if(!c.promisc){
			c.promisc = 1;
			if(promisc++ == 0)
				setpromisc(1);
		}
	* =>
		;			# nonblocking, bridge, headersonly, addmulti, ... accepted
	}
	if(debug)
		sys->print("etherusb: conn %d ctl %q\n", cn, s);
	return nil;
}

setpromisc(on: int)
{
	case kind {
	Kecm =>		ecmfilter();
	Ksmsc =>	smscpromisc(on);
	}
}

transmit(cn: int, frame: array of byte)
{
	if(len frame < 14)
		return;
	if(debug){
		t := (int frame[12] << 8) | int frame[13];
		sys->print("etherusb: tx conn %d %d bytes type %#4.4x\n", cn, len frame, t);
	}
	if(dev == nil){
		# no device (the Stage 1 bind test): report the frame instead
		t := (int frame[12] << 8) | int frame[13];
		sys->print("ETHERTX conn %d %d bytes type %#4.4x\n", cn, len frame, t);
		return;
	}
	ntx++;
	f := array[len frame] of byte;
	f[0:] = frame;
	alt {
	txc <-= f =>
		nqueued++;
	* =>
		ndrop++;		# transmit queue full: drop, as a NIC would
	}
}

# a received frame goes to every conversation whose type matches (or
# that asked for all), answering a waiting read or queueing it
nrxdump := 0;
rxgap := 0;		# summed milliseconds between frames leaving the endpoint
rxn := 0;
rxlast := 0;

deliver(f: array of byte)
{
	nrx++;
	# how long the frame before this one took to come off the endpoint:
	# the receive ceiling is either here, in the driver and the device,
	# or above, in the kernel coming back for the next frame
	now := sys->millisec();
	if(rxlast != 0){
		rxgap += now - rxlast;
		rxn++;
	}
	rxlast = now;
	t := (int f[12] << 8) | int f[13];
	# every ARP frame that reaches this server, so a reply the other end
	# swears it sent can be placed on one side of the endpoint or the
	# other
	if(debug && t == 16r806 && nrxdump++ < 8)
		txdump("rxarp", f);
	if(debug)
		sys->print("etherusb: rx %d bytes type %#4.4x\n", len f, t);
	for(i := 0; i < nconn; i++){
		c := conns[i];
		# netif: type 0 (not yet connected) receives nothing, a
		# negative type receives everything
		if(c.etype != t && c.etype >= 0)
			continue;
		c.nin++;
		if(c.reads != nil){
			# oldest read first
			l: list of ref Tmsg.Read;
			for(; tl c.reads != nil; c.reads = tl c.reads)
				l = hd c.reads :: l;
			m := hd c.reads;
			c.reads = nil;
			for(; l != nil; l = tl l)
				c.reads = hd l :: c.reads;
			c.nout++;
			srv.reply(ref Rmsg.Read(m.tag, f[0:min(m.count, len f)]));
		} else if(c.nframes < Nqueue){
			c.frames = f :: c.frames;
			c.nframes++;
		} else {
			# The queue is full because the reader is behind, and the
			# frame that matters most is the newest: an ARP reply
			# thrown away behind a queue of stale broadcasts leaves
			# the interface unable to resolve anything, which is how
			# the Pi came to answer ARP and reach nothing.  Drop the
			# oldest instead and keep what just arrived.
			oldest(c);
			c.frames = f :: c.frames;
			c.nframes++;
			c.ndrop++;
			ndrop++;
		}
	}
}

#
# devices and control transfers, as usbd does them
#
opendev(name: string): ref Dev
{
	d := ref Dev("", 0, nil, nil, 0, 0);	# every field: a bare ref keeps residue
	d.name = name;
	d.id = int name[2:];	# "epN.M"
	d.cfd = sys->open("/dev/usb/" + name + "/ctl", Sys->ORDWR);
	if(d.cfd == nil){
		sys->fprint(sys->fildes(2), "etherusb: %s: ctl: %r\n", name);
		return nil;
	}
	return d;
}

opendevdata(d: ref Dev): int
{
	d.dfd = sys->open("/dev/usb/" + d.name + "/data", Sys->ORDWR);
	if(d.dfd == nil)
		return -1;
	return 0;
}

devctl(d: ref Dev, s: string): int
{
	if(debug)
		sys->print("etherusb: %s: ctl %s\n", d.name, s);
	if(sys->fprint(d.cfd, "%s", s) < 0)
		return -1;
	return 0;
}

# a control transfer with no data phase, or with data to the device
usbcmd(d: ref Dev, rtype, req, value, index: int, data: array of byte, count: int): int
{
	r := -1;
	for(i := 0; i < Uctries; i++){
		r = cmdreq(d, rtype, req, value, index, data, count);
		if(r >= 0)
			break;
		sys->sleep(Ucdelay);
	}
	return r;
}

# a control transfer that reads count bytes back from the device
usbin(d: ref Dev, rtype, req, value, index, count: int): (int, array of byte)
{
	buf := array[count] of byte;
	for(i := 0; i < Uctries; i++){
		if(cmdreq(d, rtype, req, value, index, nil, count) < 0){
			sys->sleep(Ucdelay);
			continue;
		}
		n := sys->read(d.dfd, buf, count);
		if(n > 0)
			return (n, buf);
		sys->sleep(Ucdelay);
	}
	return (-1, nil);
}

cmdreq(d: ref Dev, rtype, req, value, index: int, data: array of byte, count: int): int
{
	nd := 0;
	if(data != nil)
		nd = len data;
	w := array[8+nd] of byte;
	w[0] = byte rtype;
	w[1] = byte req;
	w[2] = byte value;
	w[3] = byte (value>>8);
	w[4] = byte index;
	w[5] = byte (index>>8);
	w[6] = byte count;
	w[7] = byte (count>>8);
	if(nd > 0)
		w[8:] = data;
	if(sys->write(d.dfd, w, len w) != len w)
		return -1;
	return nd;
}
