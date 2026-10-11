implement Usbd;

#
# usbd: the user half of the 9front-shaped USB stack in the kernel
# (os/inferno/port/devusb.c, usbxhci.c).  The kernel drives the host
# controller and exposes /dev/usb/ctl and one epN.M directory per
# endpoint; everything above the wire is done here through control
# transfers on each device's ep0: walking every hub's ports, resetting
# a port when something is plugged in, asking the kernel for a new
# device on it ("newdev"), giving the device its address, reading its
# descriptors, choosing configuration 1, and starting a driver for
# what was found.
#
# What is real: root hubs (USB 2 and USB 3), external hubs behind them,
# boot-protocol HID keyboards and mice, which are what a machine's
# firmware also drives, and HID devices that offer no boot protocol at
# all -- a tablet, most modern keyboards in their native mode -- whose
# report descriptor is parsed to find where the buttons and the axes
# sit in the report.  Keys arrive as UTF-8 on /dev/keyboard, pointer
# motion as "m x y b" on /dev/pointer.  Not done: output and feature
# reports, and report-ID multiplexing beyond skipping the leading id
# byte.  The reference is 9front's nusb/usbd and nusb/kb;
# doc/inferno-ports.ms says what was verified under QEMU.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Usbd: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# a class driver started as a separate program (9front's nusb shape):
# it is given the device's ep0 name and drives it through #U itself
Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};
ETHERUSB: con "/dis/usb/etherusb.dis";
ETHERMNT: con "/net.alt";

# request type bits and standard requests (USB 2.0 chapter 9)
Rh2d: con 0;
Rd2h: con 16r80;
Rstd: con 0;
Rclass: con 16r20;
Rdev: con 0;
Riface: con 1;
Rother: con 3;
Rgetstatus: con 0;
Rclearfeature: con 1;
Rsetfeature: con 3;
Rsetaddress: con 5;
Rgetdesc: con 6;
Rsetconf: con 9;
Rsetidle: con 16r0a;	# HID class
Rsetproto: con 16r0b;
Ddev: con 1;
Dconf: con 2;
Diface: con 4;
Dep: con 5;
Dhid: con 16r21;	# HID class descriptor, follows its interface
Dhidreport: con 16r22;	# the report descriptor it names the length of
Dhub: con 16r29;
Dsshub: con 16r2a;

# hub port features and status bits
Fportenable: con 1;
Fportsuspend: con 2;
Fportreset: con 4;
Fportpower: con 8;
PSpresent: con 16r0001;
PSenable: con 16r0002;
PSsuspend: con 16r0004;
PSslow: con 16r0200;
PShigh: con 16r0400;

Ucdelay: con 50;	# control transfer retry
Uctries: con 4;
Enabledelay: con 100;
Resetdelay: con 50;
#
# SET_ADDRESS recovery: USB 2.0 9.2.6.3 allows the device 2 ms to
# begin answering at its new address.  20 ms rather than 2, because
# this is paid ONCE per device at attach time and the two failures it
# guards against are a stalled enumeration and a port usbd gives up
# on -- both of which cost seconds, not milliseconds.
#
Addressdelay: con 20;
Pollms: con 500;
#
# HOW MANY TIMES A PORT MAY FAIL TO ATTACH BEFORE IT IS DISABLED.
#
# portfail() used to disable the port on the FIRST failure, which is
# why a device that loses its one attempt at boot stays dead until
# somebody unplugs it.  Measured: a mouse on hub port 2 answered
# `endpoint stalled' to GET_DESCRIPTOR and that message appears ONCE in
# 320 lines of ring -- no second attempt was ever made, while ports 1
# and 4 enumerated normally.
#
# Six attempts at Pollms apart is three seconds, which is cheap against
# a device that works on the second go and bounded against one that
# never will.  Bounded rather than endless on purpose: the log ring is
# this board's only post-mortem channel, so a port that cannot attach
# must stop talking about it rather than crowd out everything else.
#
Attachtries: con 6;

Dev: adt {
	name:	string;		# epN.M
	id:	int;		# N: device number, its address once set
	cfd:	ref Sys->FD;	# /dev/usb/epN.M/ctl
	dfd:	ref Sys->FD;	# /dev/usb/epN.M/data
	isusb3:	int;
	vid, did, class:	int;
};

Port: adt {
	sts:	int;
	dev:	ref Dev;
	hub:	ref Hub;	# the hub behind this port, if any
	nfail:	int;	# consecutive failed attach attempts; see portfail
};

Hub: adt {
	dev:	ref Dev;
	nport:	int;
	port:	array of ref Port;
	isroot:	int;
	pwrms:	int;
	failed:	int;
};

hubs: list of ref Hub;
debug := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-d")
			debug++;

	# every entry in /dev/usb but ctl is a root hub the kernel made
	fd := sys->open("/dev/usb", Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "usbd: /dev/usb: %r\n");
		return;
	}
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(d[i].name != "ctl")
				newhub(d[i].name, nil);
	}
	fd = nil;
	if(hubs == nil){
		sys->fprint(sys->fildes(2), "usbd: no hubs\n");
		return;
	}
	sys->print("usbd: %d root hub(s)\n", len hubs);
	work();
}

#
# the enumeration loop: every port of every hub, forever
#
work()
{
	for(;;){
		again := 0;
		for(l := hubs; l != nil && !again; l = tl l){
			h := hd l;
			if(debug)
				sys->print("usbd: walk %s: %d ports, failed %d\n",
					h.dev.name, h.nport, h.failed);
			for(p := 1; p <= h.nport; p++)
				if(enumhub(h, p) < 0){
					again = 1;	# the hub list changed
					break;
				}
		}
		if(!again)
			sys->sleep(Pollms);
	}
}

enumhub(h: ref Hub, p: int): int
{
	if(h.failed)
		return 0;
	sts := portstatus(h, p);
	if(sts == -1){
		hubfail(h);
		return -1;
	}
	pp := h.port[p];
	onhubs := len hubs;
	if(debug)
		sys->print("usbd: %s: poll port %d status %#ux was %#ux (%d hubs)\n",
			h.dev.name, p, sts, pp.sts, len hubs);
	if(!h.dev.isusb3 && (sts & PSsuspend) != 0){
		portfeature(h, p, Fportsuspend, 0);
		sys->sleep(Enabledelay);
		sts = portstatus(h, p);
		if(sts == -1){
			hubfail(h);
			return -1;
		}
	}
	#
	# AN EDGE IS NOT ENOUGH, and that was the whole defect.
	#
	# The first arm fires on a 0->1 transition of PSpresent, which is
	# right for a plug but useless after a FAILED attach: portfail()
	# zeroes pp.sts hoping the next poll re-triggers it, and it does not.
	# Measured -- leaving the port enabled was not sufficient either: one
	# `endpoint stalled (retrying)' in the ring and no second attempt and
	# no `gave up' line, which is one attempt, not six.
	#
	# So the retry is stated rather than inferred from a transition: a
	# port that is PRESENT, has no device, and has budget left is
	# attached again. That needs no edge and no cooperation from
	# whatever state the failed device left the hub in.
	#
	if((pp.sts & PSpresent) == 0 && (sts & PSpresent) != 0){
		if(portattach(h, p) != nil)
			attachdev(pp);
	} else if((sts & PSpresent) != 0 && pp.dev == nil && pp.hub == nil
			&& pp.nfail > 0 && pp.nfail < Attachtries){
		if(portattach(h, p) != nil)
			attachdev(pp);
	} else if((pp.sts & PSpresent) != 0 && (sts & PSpresent) == 0)
		portdetach(h, p);
	pp.sts = sts;
	if(onhubs != len hubs)
		return -1;
	return 0;
}

#
# a device appeared on port p: reset the port, have the kernel make
# a device for it, address and configure it
#
portattach(h: ref Hub, p: int): ref Dev
{
	d := h.dev;
	pp := h.port[p];
	sp: string;
	step(h, p, "enable delay");
	sys->sleep(Enabledelay);
	if(d.isusb3){
		sts := portstatus(h, p);
		if(sts == -1 || (sts & PSenable) == 0)
			return portfail(h, p, nil, "not enabled");
		sp = "super";
	} else {
		step(h, p, "port reset");
		if(portfeature(h, p, Fportreset, 1) < 0)
			return portfail(h, p, nil, "reset");
		sys->sleep(Resetdelay);
		sts := portstatus(h, p);
		#
		# NO SetFeature(PORT_ENABLE) HERE.  USB 2.0 defines
		# PORT_ENABLE for ClearFeature only; SetFeature of it is not a
		# defined hub request, and a compliant hub STALLS it on every
		# port.  This code sent it and then reported "%r", so the
		# failure line below read "endpoint stalled" no matter what the
		# port had actually done -- a stall manufactured by the
		# diagnostic itself.  I then read that line as evidence that
		# the hub was refusing to talk about port 2.
		#
		# What a port legitimately needs after a reset is
		# reset-recovery time, so the retry is another read after
		# another wait, which is also what makes the retry meaningful.
		#
		if(sts == -1 || (sts & PSenable) == 0){
			sys->sleep(Resetdelay);
			sts = portstatus(h, p);
		}
		if(sts == -1 || (sts & PSenable) == 0)
			#
			# THE STATUS WORD GOES IN THE MESSAGE.  Without it
			# there is no distinguishing a port with nothing on it
			# (sts 0) from one that reset and came back disabled
			# (PSpresent set, PSenable clear) from a hub that will
			# not answer about the port at all (sts -1), and those
			# three have different causes.
			#
			return portfail(h, p, nil, sys->sprint(
				"not enabled after reset (status %#ux)", sts));
		sp = "full";
		if(sts & PSslow)
			sp = "low";
		if(sts & PShigh)
			sp = "high";
	}
	step(h, p, "newdev");
	if(devctl(d, sys->sprint("newdev %s %d", sp, p)) < 0)
		return portfail(h, p, nil, "newdev");
	# the next read of the hub's ctl names the new endpoint
	sys->seek(d.cfd, big 0, Sys->SEEKSTART);
	buf := array[64] of byte;
	n := sys->read(d.cfd, buf, len buf);
	if(n <= 0)
		return portfail(h, p, nil, "newdev name");
	name := string buf[0:n];
	nd := opendev(name);
	if(nd == nil)
		return portfail(h, p, nil, "opendev " + name);
	nd.isusb3 = d.isusb3;
	if(opendevdata(nd) < 0)
		return portfail(h, p, nd, "open data");
	step(h, p, "set address");
	if(usbcmd(nd, Rh2d|Rstd|Rdev, Rsetaddress, nd.id, 0, nil, 0) < 0)
		return portfail(h, p, nd, "set address");
	if(devctl(nd, "address") < 0)
		return portfail(h, p, nd, "address");
	#
	# THE SET_ADDRESS RECOVERY INTERVAL, which this code did not have.
	#
	# USB 2.0 9.2.6.3: after the status stage of SET_ADDRESS a device
	# may take up to 2 ms to respond at its new address, and the host
	# must not talk to it during that time.  usbd went straight from
	# `devctl address' to reading the device descriptor, so the FIRST
	# transaction at the new address was issued with no interval at all.
	#
	# Why it is suspected here: on the Pi 3B a full-speed device behind
	# the onboard hub's transaction translator completes SET_ADDRESS and
	# then stalls the device descriptor, measured 6 attach attempts
	# running -- exactly 2 successful split transfers each (the SETUP
	# and its zero-length status stage) and then 4 stalls on the next
	# SETUP.  The thing that distinguishes the transfer that works from
	# the one that fails is that it is the first one at the new address.
	#
	# The high-speed devices on the same hub survive the omission, which
	# is consistent rather than contradictory: they are not behind the
	# TT, so their turnaround is an order of magnitude shorter.
	#
	sys->sleep(Addressdelay);
	# maxpkt of ep0 from the first 8 bytes of the device descriptor;
	# this kernel only takes "maxpkt" while the data file is closed
	mp := 512;
	if(!nd.isusb3){
		step(h, p, "device descriptor");
		(r, dd) := usbin(nd, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 8);
		if(r < 8)
			#
			# THE DETECTED SPEED GOES IN THE MESSAGE, because it
			# decides ep0's packet size and a failure here could
			# not previously be told apart from a wrong one.
			# devusb.c:550 gives low speed maxpkt 8, super 512 and
			# everything else 64, from the `newdev %s' above -- so
			# a device misdetected as full when it is low gets a
			# 64-byte control transfer and stalls, which looks
			# exactly like this. sp was computed thirty lines up
			# and printed only on SUCCESS.
			#
			return portfail(h, p, nd,
				sys->sprint("device descriptor (%s speed)", sp));
		mp = int dd[7];
	}
	nd.dfd = nil;
	devctl(nd, sys->sprint("maxpkt %d", mp));
	if(opendevdata(nd) < 0)
		return portfail(h, p, nd, "reopen data");
	step(h, p, "full descriptor");
	(r, dd) := usbin(nd, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 18);
	if(r < 18)
		return portfail(h, p, nd,
			sys->sprint("full device descriptor (%s speed, maxpkt %d)", sp, mp));
	nd.class = int dd[4];
	nd.vid = int dd[8] | int dd[9]<<8;
	nd.did = int dd[10] | int dd[11]<<8;
	step(h, p, "set configuration");
	if(usbcmd(nd, Rh2d|Rstd|Rdev, Rsetconf, 1, 0, nil, 0) < 0)
		return portfail(h, p, nd, "set configuration");
	sys->print("usbd: %s: port %d: %s %s vid %4.4ux did %4.4ux class %d\n",
		d.name, p, sp, nd.name, nd.vid, nd.did, nd.class);
	pp.dev = nd;
	pp.nfail = 0;		# a success spends the retry budget
	return nd;
}

# with -d, name each step of an attach: the one that hangs is the last printed
step(h: ref Hub, p: int, what: string)
{
	if(debug)
		sys->print("usbd: %s: port %d: %s\n", h.dev.name, p, what);
}

portfail(h: ref Hub, p: int, nd: ref Dev, why: string): ref Dev
{
	pp := h.port[p];
	pp.nfail++;
	#
	# DO NOT DISABLE THE PORT ON THE FIRST FAILURE.
	#
	# This disabled it immediately, and that is what made one bad attach
	# permanent: enumhub() re-attaches on the EDGE
	#
	#	(pp.sts & PSpresent) == 0 && (sts & PSpresent) != 0
	#
	# and pp.sts is zeroed below, so a still-connected device should
	# re-trigger on the next poll -- except that a disabled port stops
	# reporting the device, so the edge never comes.  A mouse that
	# stalled GET_DESCRIPTOR at boot was therefore dead until somebody
	# unplugged it, with ONE line in the ring to say so.
	#
	# Leaving the port enabled for Attachtries polls lets the loop try
	# again by itself.  That is not a fix for whatever the device is
	# unhappy about -- it is the difference between one attempt and
	# several, and a device that stalls every time will still fail.
	#
	pp.sts = 0;
	if(pp.nfail >= Attachtries){
		if(!h.dev.isusb3)
			portfeature(h, p, Fportenable, 0);
		sys->fprint(sys->fildes(2),
			"usbd: %s: port %d: %s: %r (gave up after %d attempts)\n",
			h.dev.name, p, why, pp.nfail);
	} else if(pp.nfail == 1)
		#
		# The first failure is reported and the ones between are not.
		# Six copies of one line would crowd the ring, which is the
		# only post-mortem channel here, and the interesting events
		# are the FIRST failure and the decision to stop.
		#
		sys->fprint(sys->fildes(2), "usbd: %s: port %d: %s: %r (retrying)\n",
			h.dev.name, p, why);
	if(nd != nil){
		devctl(nd, "detach");
		closedev(nd);
	}
	return nil;
}

portdetach(h: ref Hub, p: int)
{
	pp := h.port[p];
	sys->print("usbd: %s: port %d: detached\n", h.dev.name, p);
	if(pp.hub != nil){
		closehub(pp.hub);
		pp.hub = nil;
	}
	if(pp.dev != nil){
		devctl(pp.dev, "detach");
		closedev(pp.dev);
		pp.dev = nil;
	}
	pp.sts = 0;
	#
	# A REPLUG CLEARS THE BUDGET, which is what makes the bound safe to
	# have: a port disabled after Attachtries is revived by the thing a
	# person would do anyway, rather than needing a reboot.
	#
	pp.nfail = 0;
}

#
# a configured device: a hub gets enumerated, a boot-protocol
# keyboard or mouse gets a reader; anything else is left as it is
#
attachdev(pp: ref Port)
{
	d := pp.dev;
	if(d.class == 9){
		pp.hub = newhub(nil, d);
		return;
	}
	(r, cd) := usbin(d, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8, 0, 9);
	if(r < 9)
		return;
	total := int cd[2] | int cd[3]<<8;
	if(total > 512)
		total = 512;
	(r, cd) = usbin(d, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8, 0, total);
	if(r < 9)
		return;
	# walk the interface and endpoint descriptors, tracking the kind
	# of the current interface and collecting its endpoints
	iface := -1;		# HID interface number, else -1
	proto := 0;		# 1 keyboard, 2 mouse, Preport for no boot
	replen := 0;		# its report descriptor's length, from Dhid
	ums := 0;		# in a Bulk-Only mass-storage interface
	bin := -1;		# its bulk in endpoint number
	bout := -1;		# its bulk out endpoint number
	binmax := 0;		# and their wMaxPacketSize, which a new
	boutmax := 0;		# endpoint does not get by itself
	i := 0;
	while(i + 1 < r){
		l := int cd[i];
		t := int cd[i+1];
		if(l < 2)
			break;
		case t {
		Diface =>
			iface = -1;
			replen = 0;
			ums = 0;
			if(i + 8 <= r && int cd[i+5] == 3 && int cd[i+6] == 1){
				iface = int cd[i+2];
				proto = int cd[i+7];
			} else if(i + 8 <= r && int cd[i+5] == 3){
				# HID class with no boot subclass: the
				# report descriptor is the only thing
				# that says what its reports contain.
				iface = int cd[i+2];
				proto = Preport;
			} else if(i + 8 <= r && int cd[i+5] == 8 && int cd[i+7] == 16r50){
				# class 8 mass storage, protocol 0x50 Bulk-Only
				ums = 1;
			}
		Dhid =>
			# the class descriptor that follows the interface.
			# bNumDescriptors at [i+5], then pairs of (type,
			# length); the first is the report descriptor.
			if(iface >= 0 && i + 9 <= r && int cd[i+6] == Dhidreport)
				replen = int cd[i+7] | int cd[i+8]<<8;
		Dep =>
			if(i + 7 > r)
				;
			else {
				addr := int cd[i+2];
				attr := int cd[i+3];
				maxpkt := int cd[i+4] | int cd[i+5]<<8;
				ival := int cd[i+6];
				if(iface >= 0 && (addr & 16r80) != 0 && (attr & 3) == 3){
					hidstart(d, iface, proto, replen, addr & 16r0f, maxpkt, ival);
					return;
				}
				if(ums && (attr & 3) == 2){
					if(addr & 16r80){
						bin = addr & 16r0f;
						binmax = maxpkt;
					}else{
						bout = addr & 16r0f;
						boutmax = maxpkt;
					}
				}
			}
		}
		i += l;
	}
	if(bin >= 0 && bout >= 0){
		diskstart(d, bin, bout, binmax, boutmax);
		return;
	}
	if(etherprobe(d)){
		etherstart(d);
		return;
	}
	sys->print("usbd: %s: no HID, mass-storage or ethernet interface, left configured\n", d.name);
}

#
# USB ethernet: a CDC Ethernet Control Model interface (class 2,
# subclass 6) in any configuration -- QEMU's usb-net offers RNDIS in
# its first configuration and ECM in its second -- or the SMSC
# LAN95xx family (vendor class) the Pi's onboard LAN9514 belongs to.
# The driver itself is etherusb, a separate program that speaks the
# netif file protocol so devip can bind it as the machine's ethernet;
# usbd only recognises the device and hands it ep0.
#
etherprobe(d: ref Dev): int
{
	if(d.vid == 16r0424)
		case d.did {
		16rec00 or 16r9500 or 16r9505 or 16r9e00 or 16r9e01 or
		16r9900 or 16r9901 or 16r9904 or 16r9905 or 16r9906 or
		16r9907 or 16r9908 or 16r9909 or 16r9530 or 16r9730 or
		16r9e08 or 16r9e09 =>
			return 1;
		}
	(r, dd) := usbin(d, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 18);
	if(r < 18)
		return 0;
	nconf := int dd[17];
	for(c := 0; c < nconf; c++){
		(r, cd) := usbin(d, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8 | c, 0, 9);
		if(r < 9)
			continue;
		total := int cd[2] | int cd[3]<<8;
		if(total > 512)
			total = 512;
		(r, cd) = usbin(d, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8 | c, 0, total);
		if(r < 9)
			continue;
		i := 0;
		while(i + 1 < r){
			l := int cd[i];
			t := int cd[i+1];
			if(l < 2)
				break;
			if(t == Diface && i + 8 <= r && int cd[i+5] == 2 && int cd[i+6] == 6)
				return 1;
			i += l;
		}
	}
	return 0;
}

# Each ethernet gets its own directory under ETHERMNT.  The first is
# "ether", because that is the name every board's init and every
# recorded marker already uses; the rest are "ether1", "ether2" and so
# on.  Before this, a machine with two USB ethernets started two
# etherusb instances that both served "ether" and both mounted MREPL
# over the same point: the second won, the first went on running with
# nothing able to reach it, and the board had one interface no matter
# how many adapters were plugged in.
nether := 0;

etherstart(d: ref Dev)
{
	eth := load Command ETHERUSB;
	if(eth == nil){
		sys->fprint(sys->fildes(2), "usbd: %s: load %s: %r\n", d.name, ETHERUSB);
		return;
	}
	ifname := "ether";
	if(nether > 0)
		ifname = "ether" + string nether;
	nether++;
	# the driver reopens ep0's data file for its own control transfers;
	# the kernel allows one open of an endpoint, so let go of ours
	d.dfd = nil;
	sys->print("usbd: %s: ethernet, starting etherusb as %s\n", d.name, ifname);
	spawn eth->init(nil, "etherusb" :: "-m" :: ETHERMNT ::
		"-i" :: ifname :: d.name :: nil);
}

#
# boot-protocol keyboard (proto 1) or mouse (proto 2): put the
# interface in boot protocol, make the interrupt endpoint and read it.
# proto Preport is a HID interface that offers no boot protocol: it
# stays in report protocol and its report descriptor is parsed instead.
#
hidstart(d: ref Dev, iface, proto, replen, epn, maxpkt, ival: int)
{
	rep: ref Hidrep;

	usbcmd(d, Rh2d|Rclass|Riface, Rsetidle, 0, iface, nil, 0);
	if(proto == Preport){
		rep = hidparse(d, iface, replen);
		if(rep == nil)
			return;
	} else if(usbcmd(d, Rh2d|Rclass|Riface, Rsetproto, 0, iface, nil, 0) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: set boot protocol: %r\n", d.name);
		return;
	}
	# the type is the USB standard number (3 = interrupt), as 9front's
	# usbd sends it; the kernel's own names are "control", "iso",
	# "bulk", "interrupt", and anything else parses as control
	if(devctl(d, sys->sprint("new %d 3 r", epn)) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: new endpoint %d: %r\n", d.name, epn);
		return;
	}
	ep := opendev(sys->sprint("ep%d.%d", d.id, epn));
	if(ep == nil)
		return;
	devctl(ep, sys->sprint("maxpkt %d", maxpkt));
	if(ival > 0)
		devctl(ep, sys->sprint("pollival %d", ival));
	if(debug)
		devctl(ep, "debug 2");
	ep.dfd = sys->open("/dev/usb/" + ep.name + "/data", Sys->OREAD);
	if(ep.dfd == nil){
		sys->fprint(sys->fildes(2), "usbd: %s: open data: %r\n", ep.name);
		return;
	}
	case proto {
	1 =>
		sys->print("usbd: %s: boot keyboard on %s\n", d.name, ep.name);
		spawn kbdreader(d, ep);
	2 =>
		sys->print("usbd: %s: boot mouse on %s\n", d.name, ep.name);
		spawn mousereader(d, ep);
	Preport =>
		spawn hidreader(d, ep, rep);
	* =>
		sys->print("usbd: %s: HID protocol %d ignored\n", d.name, proto);
	}
}

#
# HID report descriptors.  A device with no boot protocol says nothing
# about its reports except through this descriptor, which is a byte
# stream of items: a one-byte prefix (tag<<4 | type<<2 | size, where
# size 3 means four bytes) and that many data bytes.  Global items
# (usage page, logical minimum and maximum, report size and count,
# report id) persist until changed; local items (usage, usage minimum
# and maximum) are cleared after every main item; a main Input item
# turns the current globals and locals into report_count fields of
# report_size bits each, laid end to end from the current bit offset.
#
# Two rules are easy to get wrong and both are load-bearing here.  The
# bit offset advances for every Input item including a constant one --
# QEMU's tablet puts three bits of padding between its five button bits
# and its 16-bit X, and skipping that reads X three bits early.  And the
# nth field of a multi-count Input takes the nth local usage, which is
# how "Usage (X), Usage (Y), Report Count (2), Input" names two
# different axes in one item.
#
Preport: con 16r10;	# a proto value no HID protocol byte can hold

Hidfld: adt {
	page:	int;		# usage page this field belongs to
	usage:	int;		# its usage within that page
	off:	int;		# bit offset into the report
	size:	int;		# width in bits
	lmin:	int;		# logical minimum and maximum, which say
	lmax:	int;		# both the range and whether it is signed
	rel:	int;		# Input item's Relative bit
};

Hidrep: adt {
	id:	int;		# report id, or 0 if the device uses none
	nbit:	int;		# total bits of the report
	f:	list of ref Hidfld;
	xf:	ref Hidfld;	# generic desktop X, Y and Wheel, if any
	yf:	ref Hidfld;
	wf:	ref Hidfld;
	btn:	list of ref Hidfld;	# button page fields, in order
};

# The generic desktop page and the usages this reads from it.
Updesktop: con 1;
Upbutton: con 9;
Ugx: con 16r30;
Ugy: con 16r31;
Ugwheel: con 16r38;

hidparse(d: ref Dev, iface, replen: int): ref Hidrep
{
	if(replen <= 0 || replen > 4096){
		sys->print("usbd: %s: HID report descriptor length %d, not parsed\n",
			d.name, replen);
		return nil;
	}
	# recipient is the interface, and wIndex is the interface number:
	# unlike the device-level fetches around it
	(n, rd) := usbin(d, Rd2h|Rstd|Riface, Rgetdesc, Dhidreport<<8, iface, replen);
	if(n < 2){
		sys->fprint(sys->fildes(2), "usbd: %s: get report descriptor: %r\n", d.name);
		return nil;
	}
	if(debug){
		s := "";
		for(i := 0; i < n; i++)
			s += sys->sprint(" %.2ux", int rd[i]);
		sys->print("usbd: %s: report descriptor%s\n", d.name, s);
	}

	rep := ref Hidrep(0, 0, nil, nil, nil, nil, nil);
	page := 0;
	lmin := 0;
	lmax := 0;
	rsize := 0;
	rcount := 0;
	usages: list of int;		# local usages, in the order given
	umin := -1;
	umax := -1;
	i := 0;
	while(i < n){
		b := int rd[i++];
		sz := b & 3;
		if(sz == 3)
			sz = 4;
		if(i + sz > n)
			break;
		v := 0;
		for(k := 0; k < sz; k++)
			v |= int rd[i+k] << (8*k);
		i += sz;
		case b & 16rfc {
		16r84 =>				# Report ID (global)
			rep.id = v;
		16r04 =>				# Usage Page (global)
			page = v;
		16r14 =>				# Logical Minimum (global)
			lmin = sext32(v, sz);
		16r24 =>				# Logical Maximum (global)
			lmax = sext32(v, sz);
		16r74 =>				# Report Size (global)
			rsize = v;
		16r94 =>				# Report Count (global)
			rcount = v;
		16r08 =>				# Usage (local)
			usages = v :: usages;
		16r18 =>				# Usage Minimum (local)
			umin = v;
		16r28 =>				# Usage Maximum (local)
			umax = v;
		16r80 =>				# Input (main)
			ul := rev(usages);
			if(ul == nil && umin >= 0 && umax >= umin)
				for(u := umax; u >= umin; u--)
					ul = u :: ul;
			for(k = 0; k < rcount; k++){
				usage := 0;
				if(ul != nil){
					usage = hd ul;
					# the last usage repeats: a
					# descriptor may name fewer
					# usages than it has fields
					if(tl ul != nil)
						ul = tl ul;
				}
				# (v&1) is the Constant bit: padding, no
				# usage, but its bits are still there
				if((v & 1) == 0)
					rep.f = ref Hidfld(page, usage, rep.nbit,
						rsize, lmin, lmax, (v>>2) & 1) :: rep.f;
				rep.nbit += rsize;
			}
			usages = nil; umin = -1; umax = -1;
		16ra0 or 16rc0 =>			# Collection, End
			usages = nil; umin = -1; umax = -1;
		16r90 or 16rb0 =>			# Output, Feature (main)
			# not read here, but their locals are cleared
			# and they occupy no input-report bits
			usages = nil; umin = -1; umax = -1;
		* =>
			;			# every other item kind
		}
	}
	rep.f = rev2(rep.f);
	for(fl := rep.f; fl != nil; fl = tl fl){
		f := hd fl;
		if(f.page == Updesktop){
			case f.usage {
			Ugx => if(rep.xf == nil) rep.xf = f;
			Ugy => if(rep.yf == nil) rep.yf = f;
			Ugwheel => if(rep.wf == nil) rep.wf = f;
			}
		} else if(f.page == Upbutton && f.usage > 0)
			rep.btn = f :: rep.btn;
	}
	rep.btn = rev2(rep.btn);
	if(rep.xf == nil || rep.yf == nil){
		sys->print("usbd: %s: HID report has no X/Y, %d bits, left configured\n",
			d.name, rep.nbit);
		return nil;
	}
	return rep;
}

rev(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

rev2(l: list of ref Hidfld): list of ref Hidfld
{
	r: list of ref Hidfld;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

sext32(v, sz: int): int
{
	case sz {
	1 => if(v & 16r80) return v - 16r100;
	2 => if(v & 16r8000) return v - 16r10000;
	}
	return v;
}

# pull one field out of a report, sign-extending if its logical
# minimum says the value can be negative
hidfield(rep: array of byte, n: int, f: ref Hidfld): int
{
	v := 0;
	for(k := 0; k < f.size; k++){
		bit := f.off + k;
		if(bit >= n*8)
			return 0;
		if(int rep[bit/8] & (1 << (bit%8)))
			v |= 1 << k;
	}
	if(f.lmin < 0 && f.size > 0 && f.size < 32 && (v & (1 << (f.size-1))))
		v -= 1 << f.size;
	return v;
}

# The screen the absolute axes are scaled onto.  Reading /dev/draw/new
# returns twelve 11-column fields; 4 and 5 are the screen image's
# r.min, 6 and 7 its r.max.  A board with no #i bound scales onto a
# default instead: a tablet reporting motion at the wrong scale is
# still a decoded tablet, and a reader that never starts proves
# nothing.
screensize(): (int, int)
{
	fd := sys->open("/dev/draw/new", Sys->ORDWR);
	if(fd == nil)
		return (640, 480);
	buf := array[144] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 12*12)
		return (640, 480);
	(nf, flds) := sys->tokenize(string buf[0:n], " \t\n");
	if(nf < 8)
		return (640, 480);
	f := flds;
	for(k := 0; k < 6; k++)
		f = tl f;
	w := int hd f;
	h := int hd tl f;
	if(w <= 0 || h <= 0)
		return (640, 480);
	return (w, h);
}

hidreader(d: ref Dev, ep: ref Dev, rep: ref Hidrep)
{
	mfd := sys->open("/dev/pointer", Sys->OWRITE);
	if(mfd == nil){
		sys->fprint(sys->fildes(2), "usbd: /dev/pointer: %r\n");
		return;
	}
	(scrw, scrh) := screensize();
	nbtn := 0;
	for(bl := rep.btn; bl != nil; bl = tl bl)
		nbtn++;
	sys->print("usbd: %s: HID report pointer on %s: %d-bit report, x %s at %d+%d, y at %d+%d, %d buttons, screen %dx%d\n",
		d.name, ep.name, rep.nbit,
		relname(rep.xf.rel), rep.xf.off, rep.xf.size,
		rep.yf.off, rep.yf.size, nbtn, scrw, scrh);

	nb := (rep.nbit + 7) / 8;
	if(rep.id != 0)
		nb++;
	if(nb < 1)
		nb = 1;
	buf := array[nb] of byte;
	x := scrw/2;
	y := scrh/2;
	for(;;){
		n := sys->read(ep.dfd, buf, len buf);
		if(n < 0){
			sys->fprint(sys->fildes(2), "usbd: %s: HID device gone: %r\n", d.name);
			return;
		}
		body := buf;
		nbody := n;
		if(rep.id != 0){
			# a device that numbers its reports puts the id
			# in the first byte; anything else is another
			# report and not this one
			if(n < 1 || int buf[0] != rep.id)
				continue;
			body = buf[1:];
			nbody = n - 1;
		}
		if(nbody <= 0)
			continue;
		xv := hidfield(body, nbody, rep.xf);
		yv := hidfield(body, nbody, rep.yf);
		if(rep.xf.rel)
			x += xv;
		else
			x = scale(xv, rep.xf, scrw);
		if(rep.yf.rel)
			y += yv;
		else
			y = scale(yv, rep.yf, scrh);
		if(x < 0)
			x = 0;
		if(y < 0)
			y = 0;
		if(x >= scrw)
			x = scrw - 1;
		if(y >= scrh)
			y = scrh - 1;
		# HID button 1 is left, 2 right, 3 middle; devpointer
		# wants 1, 4, 2 -- the same shuffle mousereader does,
		# here driven by the descriptor rather than by fixed
		# bit positions
		b := 0;
		i := 0;
		for(b2 := rep.btn; b2 != nil; b2 = tl b2){
			if(hidfield(body, nbody, hd b2) != 0)
				case i {
				0 => b |= 1;
				1 => b |= 4;
				2 => b |= 2;
				}
			i++;
		}
		sys->fprint(mfd, "m %d %d %d", x, y, b);
	}
}

relname(rel: int): string
{
	if(rel)
		return "relative";
	return "absolute";
}

scale(v: int, f: ref Hidfld, n: int): int
{
	span := f.lmax - f.lmin;
	if(span <= 0)
		return v;
	if(v < f.lmin)
		v = f.lmin;
	if(v > f.lmax)
		v = f.lmax;
	return (v - f.lmin) * (n - 1) / span;
}

# HID usage ids 4..56 of the boot keyboard, US layout, plain and shifted
keys := array[] of {
	"abcdefghijklmnopqrstuvwxyz1234567890\n\b\t -=[]\\#;'`,./",
	"ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n\b\t _+{}|~:\"~<>?",
};

kbdreader(d: ref Dev, ep: ref Dev)
{
	kfd := sys->open("/dev/keyboard", Sys->OWRITE);
	if(kfd == nil){
		sys->fprint(sys->fildes(2), "usbd: /dev/keyboard: %r\n");
		return;
	}
	prev := array[6] of { * => 0 };
	rep := array[8] of byte;
	nshort := 0;
	for(;;){
		n := sys->read(ep.dfd, rep, len rep);
		if(n < 0){
			sys->fprint(sys->fildes(2), "usbd: %s: keyboard gone: %r\n", d.name);
			return;
		}
		if(n < 8){
			# a short report: say so a few times, then just wait
			if(nshort++ < 3)
				sys->print("usbd: %s: short keyboard report, %d bytes\n", ep.name, n);
			sys->sleep(100);
			continue;
		}
		if(debug && nshort < 3)
			sys->print("usbd: %s: report %.2ux %.2ux %.2ux\n", ep.name, int rep[0], int rep[1], int rep[2]);
		mod := int rep[0];
		cur := array[6] of int;
		for(i := 0; i < 6; i++)
			cur[i] = int rep[2+i];
		for(i = 0; i < 6; i++){
			k := cur[i];
			if(k == 0)
				continue;
			down := 1;
			for(j := 0; j < 6; j++)
				if(prev[j] == k)
					down = 0;
			if(!down)
				continue;
			s := keysym(k, mod);
			if(s != nil)
				sys->fprint(kfd, "%s", s);
		}
		prev = cur;
	}
}

keysym(k, mod: int): string
{
	shift := (mod & 16r22) != 0;
	ctl := (mod & 16r11) != 0;
	if(k >= 4 && k <= 56){
		c := keys[shift][k-4];
		if(ctl && c >= 'a' && c <= 'z')
			c -= 'a' - 1;
		if(ctl && c >= 'A' && c <= 'Z')
			c -= 'A' - 1;
		return sys->sprint("%c", c);
	}
	if(k == 76)
		return sys->sprint("%c", 16r7f);	# delete forward
	return nil;		# caps lock, function and arrow keys: not mapped yet
}

mousereader(d: ref Dev, ep: ref Dev)
{
	mfd := sys->open("/dev/pointer", Sys->OWRITE);
	if(mfd == nil){
		sys->fprint(sys->fildes(2), "usbd: /dev/pointer: %r\n");
		return;
	}
	x := 0;
	y := 0;
	rep := array[8] of byte;
	for(;;){
		n := sys->read(ep.dfd, rep, len rep);
		if(n < 0){
			sys->fprint(sys->fildes(2), "usbd: %s: mouse gone: %r\n", d.name);
			return;
		}
		if(n < 3)
			continue;
		hb := int rep[0];
		x += sext(int rep[1]);
		y += sext(int rep[2]);
		if(x < 0)
			x = 0;
		if(y < 0)
			y = 0;
		# HID: bit 0 left, bit 1 right, bit 2 middle; devpointer: 1, 4, 2
		b := (hb & 1) | ((hb & 2) << 1) | ((hb & 4) >> 1);
		sys->fprint(mfd, "m %d %d %d", x, y, b);
	}
}

sext(v: int): int
{
	if(v & 16r80)
		return v - 256;
	return v;
}

#
# USB mass storage, Bulk-Only Transport (class 8, protocol 0x50),
# after 9front's nusb/disk.  Two bulk endpoints carry a 31-byte
# command wrapper, the data, and a 13-byte status wrapper; the command
# is a SCSI CDB.  This drives inquiry, read capacity and read(10), and
# for now reads block 0 and reports the geometry and the FAT boot
# signature, the same check virtio-blk gets.  The mountable file
# server is the next step.
#
Bstate: adt {
	inep:	ref Dev;	# bulk in
	outep:	ref Dev;	# bulk out
	tag:	int;
	nblocks:	int;
	bsize:	int;
};

diskstart(d: ref Dev, bin, bout, binmax, boutmax: int)
{
	b := ref Bstate(nil, nil, 0, 0, 512);
	if(devctl(d, sys->sprint("new %d 2 r", bin)) < 0 ||
	   devctl(d, sys->sprint("new %d 2 w", bout)) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: mass-storage endpoints: %r\n", d.name);
		return;
	}
	b.inep = opendev(sys->sprint("ep%d.%d", d.id, bin));
	b.outep = opendev(sys->sprint("ep%d.%d", d.id, bout));
	if(b.inep == nil || b.outep == nil)
		return;
	# a new endpoint starts at devusb's default maxpkt of 8 (devusb.c
	# ep->maxpkt = 8); leaving it there splits the 31-byte command
	# wrapper and the device answers "Bad CBW size" and stalls.  Give
	# each endpoint the wMaxPacketSize its descriptor declared.
	if(binmax > 0 && devctl(b.inep, sys->sprint("maxpkt %d", binmax)) < 0 ||
	   boutmax > 0 && devctl(b.outep, sys->sprint("maxpkt %d", boutmax)) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: mass-storage maxpkt: %r\n", d.name);
		return;
	}
	b.inep.dfd = sys->open("/dev/usb/" + b.inep.name + "/data", Sys->OREAD);
	b.outep.dfd = sys->open("/dev/usb/" + b.outep.name + "/data", Sys->OWRITE);
	if(b.inep.dfd == nil || b.outep.dfd == nil){
		sys->fprint(sys->fildes(2), "usbd: %s: mass-storage data files: %r\n", d.name);
		return;
	}

	# a device may report "not ready" until spun up; poll briefly
	for(i := 0; i < 10; i++){
		if(scsi(b, array[] of {byte 0, byte 0, byte 0, byte 0, byte 0, byte 0}, nil, 0) >= 0)
			break;
		sys->sleep(100);
	}

	inq := array[36] of byte;
	if(scsi(b, array[] of {byte 16r12, byte 0, byte 0, byte 0, byte 36, byte 0}, inq, 36) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: inquiry: %r\n", d.name);
		return;
	}
	vendor := string inq[8:36];

	cap := array[8] of byte;
	if(scsi(b, array[] of {byte 16r25, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0}, cap, 8) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: read capacity: %r\n", d.name);
		return;
	}
	lastlba := (int cap[0]<<24) | (int cap[1]<<16) | (int cap[2]<<8) | int cap[3];
	b.bsize = (int cap[4]<<24) | (int cap[5]<<16) | (int cap[6]<<8) | int cap[7];
	b.nblocks = lastlba + 1;
	sys->print("usbd: %s: disk \"%s\" %d blocks x %d bytes\n", d.name, vendor, b.nblocks, b.bsize);

	sec := array[b.bsize] of byte;
	if(readblock(b, 0, sec) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: read block 0: %r\n", d.name);
		return;
	}
	if(b.bsize >= 512 && int sec[510] == 16r55 && int sec[511] == 16raa)
		sys->print("usbd: %s: DISK-BLK-OK (FAT/MBR signature)\n", d.name);
	else
		sys->print("usbd: %s: block 0 read, no boot signature\n", d.name);

	# export as a flat file dossrv can mount.  #s (srv) must be bound
	# somewhere; bind it at /chan (idempotent) and serve there.
	sys->bind("#s", "/chan", Sys->MBEFORE|Sys->MCREATE);
	name := "usbdisk" + string ndisk;
	ndisk++;
	fio := sys->file2chan("/chan", name);
	if(fio == nil){
		sys->fprint(sys->fildes(2), "usbd: %s: file2chan: %r\n", d.name);
		return;
	}
	sys->print("usbd: %s: /chan/%s (%d blocks)\n", d.name, name, b.nblocks);
	spawn diskserve(b, fio);
}

ndisk := 0;

# READ(10) of one block into buf
readblock(b: ref Bstate, lba: int, buf: array of byte): int
{
	cdb := array[10] of { * => byte 0 };
	cdb[0] = byte 16r28;
	cdb[2] = byte (lba>>24);
	cdb[3] = byte (lba>>16);
	cdb[4] = byte (lba>>8);
	cdb[5] = byte lba;
	cdb[7] = byte 0;
	cdb[8] = byte 1;		# one block
	return scsi(b, cdb, buf, b.bsize);
}

# one SCSI command over Bulk-Only Transport.  iswrite drives the data
# phase direction; returns bytes transferred or -1.
scsi(b: ref Bstate, cdb: array of byte, data: array of byte, datalen: int): int
{
	return scsidir(b, cdb, data, datalen, 0);
}

scsidir(b: ref Bstate, cdb: array of byte, data: array of byte, datalen, iswrite: int): int
{
	cbw := array[31] of { * => byte 0 };
	cbw[0] = byte 'U'; cbw[1] = byte 'S'; cbw[2] = byte 'B'; cbw[3] = byte 'C';
	b.tag++;
	cbw[4] = byte b.tag; cbw[5] = byte (b.tag>>8);
	cbw[6] = byte (b.tag>>16); cbw[7] = byte (b.tag>>24);
	cbw[8] = byte datalen; cbw[9] = byte (datalen>>8);
	cbw[10] = byte (datalen>>16); cbw[11] = byte (datalen>>24);
	if(iswrite)
		cbw[12] = byte 0;	# data out
	else
		cbw[12] = byte 16r80;	# data in
	cbw[13] = byte 0;		# lun 0
	cbw[14] = byte len cdb;
	cbw[15:] = cdb;
	if(sys->write(b.outep.dfd, cbw, 31) != 31)
		return -1;
	if(datalen > 0 && data != nil){
		if(iswrite){
			if(sys->write(b.outep.dfd, data, datalen) != datalen)
				return -1;
		}else{
			n := sys->read(b.inep.dfd, data, datalen);
			if(n < 0)
				return -1;
		}
	}
	csw := array[13] of byte;
	n := sys->read(b.inep.dfd, csw, 13);
	if(n != 13 || int csw[0] != 'U' || int csw[1] != 'S' || int csw[2] != 'B' || int csw[3] != 'S')
		return -1;
	if(int csw[12] != 0)		# status: 0 = ok
		return -1;
	return datalen;
}

# READ(10)/WRITE(10) of nb blocks at lba
rwblocks(b: ref Bstate, lba, nb: int, buf: array of byte, iswrite: int): int
{
	cdb := array[10] of { * => byte 0 };
	if(iswrite)
		cdb[0] = byte 16r2a;
	else
		cdb[0] = byte 16r28;
	cdb[2] = byte (lba>>24);
	cdb[3] = byte (lba>>16);
	cdb[4] = byte (lba>>8);
	cdb[5] = byte lba;
	cdb[7] = byte (nb>>8);
	cdb[8] = byte nb;
	return scsidir(b, cdb, buf, nb*b.bsize, iswrite);
}

MAXIO: con 64*1024;		# cap one transfer; loop for more

# Serve the disk as a flat file for dossrv: a read/write at a byte
# offset becomes whole-block SCSI, with a read-modify-write on the
# unaligned edges.  file2chan gives one request at a time, so the SCSI
# commands are naturally serialised.
diskserve(b: ref Bstate, fio: ref Sys->FileIO)
{
	for(;;) alt {
	(off, count, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		(data, err) := diskread(b, off, count);
		rc <-= (data, err);
	(off, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		(n, err) := diskwrite(b, off, data);
		wc <-= (n, err);
	}
}

diskread(b: ref Bstate, off: big, count: int): (array of byte, string)
{
	tot := big b.nblocks * big b.bsize;
	if(off >= tot)
		return (array[0] of byte, nil);
	if(off + big count > tot)
		count = int (tot - off);
	out := array[count] of byte;
	done := 0;
	while(done < count){
		o := off + big done;
		lba := int (o / big b.bsize);
		skip := int (o % big b.bsize);
		want := count - done;
		if(want > MAXIO)
			want = MAXIO;
		nb := (skip + want + b.bsize - 1) / b.bsize;
		blk := array[nb*b.bsize] of byte;
		if(rwblocks(b, lba, nb, blk, 0) < 0)
			return (nil, "usb disk read error");
		n := nb*b.bsize - skip;
		if(n > want)
			n = want;
		out[done:] = blk[skip:skip+n];
		done += n;
	}
	return (out, nil);
}

diskwrite(b: ref Bstate, off: big, data: array of byte): (int, string)
{
	count := len data;
	tot := big b.nblocks * big b.bsize;
	if(off + big count > tot)
		return (0, "write past end of disk");
	done := 0;
	while(done < count){
		o := off + big done;
		lba := int (o / big b.bsize);
		skip := int (o % big b.bsize);
		want := count - done;
		if(want > MAXIO)
			want = MAXIO;
		nb := (skip + want + b.bsize - 1) / b.bsize;
		blk := array[nb*b.bsize] of byte;
		# read-modify-write when the edges are not block aligned
		if(skip != 0 || (skip + want) % b.bsize != 0)
			if(rwblocks(b, lba, nb, blk, 0) < 0)
				return (done, "usb disk rmw read error");
		n := nb*b.bsize - skip;
		if(n > want)
			n = want;
		blk[skip:] = data[done:done+n];
		if(rwblocks(b, lba, nb, blk, 1) < 0)
			return (done, "usb disk write error");
		done += n;
	}
	return (done, nil);
}

#
# hubs
#
newhub(name: string, d: ref Dev): ref Hub
{
	# Every field named, rather than "ref Hub" and four assignments:
	# a bare ref to an adt leaves the words that hold no pointer
	# uninitialised, and failed is the one nothing here ever writes.
	# It decides at the top of enumhub() whether this hub is polled
	# at all, so a boot where that word happened to hold something
	# other than zero left the hub in the list, printed with its
	# right port count, and never scanned -- no device found, and no
	# message, because the only thing that sets failed is the one
	# thing that reports it.  Every board this had ever run on gave
	# it zero; the arm64 board's heap did not.
	h := ref Hub(nil, 0, nil, 0, 0, 0);
	h.isroot = d == nil;
	if(h.isroot){
		h.dev = opendev(name);
		if(h.dev == nil)
			return nil;
		configroothub(h);
	} else {
		h.dev = d;
		if(confighub(h) < 0){
			devctl(d, "detach");
			return nil;
		}
	}
	# the kernel wants the port count before the hub's data file is open.
	# confighub above read the hub descriptor over ep0's data file, which
	# an enumerated device leaves open; close it so "hub" is not refused
	# for a busy endpoint (it is reopened just below).
	h.dev.dfd = nil;
	if(devctl(h.dev, sys->sprint("hub %d", h.nport)) < 0)
		sys->fprint(sys->fildes(2), "usbd: %s: hub: %r\n", h.dev.name);
	if(h.dev.dfd == nil && opendevdata(h.dev) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: open data: %r\n", h.dev.name);
		return nil;
	}
	h.port = array[h.nport+1] of ref Port;
	for(i := 0; i <= h.nport; i++)
		h.port[i] = ref Port(0, nil, nil, 0);
	if(!h.isroot){
		for(i = 1; i <= h.nport; i++)
			if(portfeature(h, i, Fportpower, 1) < 0)
				sys->fprint(sys->fildes(2),
					"usbd: %s: port %d: power: %r\n", h.dev.name, i);
		sys->sleep(h.pwrms);
		# Say what each port reports once it is powered.  A device that
		# was already attached when usbd started is found by the first
		# scan seeing it present, so a hub that reports nothing present
		# is the whole of the failure and worth showing.
		#
		# EVERY PORT IS REPORTED, not just the ones that fail, and not
		# only under -d.  Twelve failures on one port read as twelve
		# measurements until I counted the ports and found that the
		# ports which worked had only ever carried high-speed devices.
		# A line per port at hub-add is the control: it says which
		# ports have something on them and at what speed, so a later
		# failure can be attributed to the port or to the device
		# instead of to whichever was being looked for.
		#
		for(i = 1; i <= h.nport; i++){
			sts := portstatus(h, i);
			sys->print("usbd: %s: port %d status %#ux%s\n",
				h.dev.name, i, sts, portdecode(sts));
		}
		#
		# THIS TABLE IS A SNAPSHOT, NOT A CENSUS, and it is measured:
		# on the Pi 3B ports 4 and 5 both printed "(empty)" here and
		# then attached high-speed devices seconds later (a Teensy and
		# a flash drive).  The reading is taken straight after
		# Fportpower and pwrms, before the hub has finished detecting
		# what is on each port, so
		#
		#	"present" here IS evidence a device is attached;
		#	"empty" here is NOT evidence that none is.
		#
		# QEMU goes the other way and reports every port present and
		# unreset.  Either way the line states the hub's claim at this
		# instant and nothing more.  Said once, here, rather than per
		# port -- and said at all because this table was presented as
		# a port-by-port control before anyone checked it against what
		# later enumerated.
		#
	}
	hubs = h :: hubs;
	if(debug)
		sys->print("usbd: %s: added to the hub list, %d now\n", h.dev.name, len hubs);
	kind := "";
	if(h.isroot)
		kind = " (root)";
	sys->print("usbd: hub %s: %d ports%s\n", h.dev.name, h.nport, kind);
	return h;
}

# the kernel describes a root hub in its ctl file: "... roothub ports N ..."
configroothub(h: ref Hub)
{
	h.nport = 2;
	sys->seek(h.dev.cfd, big 0, Sys->SEEKSTART);
	buf := array[1024] of byte;
	n := sys->read(h.dev.cfd, buf, len buf);
	if(n <= 0)
		return;
	s := string buf[0:n];
	h.dev.isusb3 = contains(s, "speed super");
	(nil, rest) := splitat(s, "ports ");
	if(rest != nil)
		h.nport = int rest;
}

# an external hub: its class descriptor gives the port count
confighub(h: ref Hub): int
{
	dt := Dhub;
	if(h.dev.isusb3)
		dt = Dsshub;
	(r, hdesc) := usbin(h.dev, Rd2h|Rclass|Rdev, Rgetdesc, dt<<8, 0, 64);
	if(r < 7)
		return -1;
	h.nport = int hdesc[2];
	h.pwrms = int hdesc[5] * 2;
	if(h.pwrms < 100)
		h.pwrms = 100;
	return 0;
}

hubfail(h: ref Hub)
{
	if(h.failed)
		return;
	h.failed = 1;
	sys->fprint(sys->fildes(2), "usbd: hub %s failed\n", h.dev.name);
}

closehub(h: ref Hub)
{
	for(p := 1; p <= h.nport; p++)
		portdetach(h, p);
	l: list of ref Hub;
	for(; hubs != nil; hubs = tl hubs)
		if(hd hubs != h)
			l = hd hubs :: l;
	hubs = l;
}

portfeature(h: ref Hub, port, f, on: int): int
{
	cmd := Rclearfeature;
	if(on)
		cmd = Rsetfeature;
	return usbcmd(h.dev, Rh2d|Rclass|Rother, cmd, f, port, nil, 0);
}

# the bits that decide whether a port is worth attaching to, spelled out:
# a bare hex word is hard to compare across a log by eye, and comparing
# ports across a log is the whole point of printing them.
portdecode(w: int): string
{
	if(w == -1)
		return " (the hub would not answer)";
	#
	# THE LOW HALF IS wPortStatus AND THE HIGH HALF IS wPortChange,
	# and portstatus() returns all four bytes as one int.  Decoding the
	# whole word treats a change bit as a status bit: QEMU's hub reports
	# 0x00010101 before a reset -- status 0x0101 (present, powered) with
	# C_PORT_CONNECTION set -- and reading 32 bits put a stray 0x10000
	# into the same test.  It happened not to collide with a bit this
	# decode names, which is the sort of luck that stops holding when
	# somebody adds PSslow's neighbour.
	#
	chg := (w >> 16) & 16rffff;
	sts := w & 16rffff;
	if((sts & PSpresent) == 0){
		if(chg != 0)
			return sys->sprint(" (empty, change %#ux)", chg);
		return " (empty)";
	}
	s := " present";
	if(sts & PSenable)
		s += " enabled";
	else
		s += " DISABLED";
	if(sts & PSsuspend)
		s += " suspended";
	#
	# NEITHER SPEED BIT SET MEANS FULL SPEED -- there is no "full" bit.
	# Spelling it out is the point: a full- or low-speed device is the
	# one that needs a split transaction through the hub's transaction
	# translator, so which of the three a port reports is the first
	# thing worth knowing about a port that misbehaves.
	#
	if(sts & PSslow)
		s += " low-speed (needs split)";
	else if(sts & PShigh)
		s += " high-speed (no split)";
	else
		s += " full-speed (needs split)";
	if(chg != 0)
		s += sys->sprint(" change %#ux", chg);
	return " (" + s[1:] + ")";
}

portstatus(h: ref Hub, p: int): int
{
	(r, b) := usbin(h.dev, Rd2h|Rclass|Rother, Rgetstatus, 0, p, 4);
	if(r < 4)
		return -1;
	return int b[0] | int b[1]<<8 | int b[2]<<16 | int b[3]<<24;
}

#
# devices and control transfers
#
opendev(name: string): ref Dev
{
	d := ref Dev("", 0, nil, nil, 0, 0, 0, 0);
	d.name = name;
	d.id = int name[2:];	# "epN.M"
	d.cfd = sys->open("/dev/usb/" + name + "/ctl", Sys->ORDWR);
	if(d.cfd == nil){
		sys->fprint(sys->fildes(2), "usbd: %s: ctl: %r\n", name);
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

closedev(d: ref Dev)
{
	d.cfd = nil;
	d.dfd = nil;
}

devctl(d: ref Dev, s: string): int
{
	if(debug)
		sys->print("usbd: %s: ctl %s\n", d.name, s);
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

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

splitat(s, t: string): (string, string)
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return (s[0:i], s[i+len t:]);
	return (s, nil);
}
