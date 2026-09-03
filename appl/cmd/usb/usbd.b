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
# and boot-protocol HID keyboards and mice, which are what a machine's
# firmware also drives.  Keys arrive as UTF-8 on /dev/keyboard, mouse
# motion as "m x y b" on /dev/pointer.  Not done: report-descriptor
# parsing (so a device that only speaks the HID report protocol, such
# as a tablet, is configured and then ignored), mass storage, and any
# other class.  The reference is 9front's nusb/usbd and nusb/kb;
# doc/inferno-ports.ms says what was verified under QEMU.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Usbd: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

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
Pollms: con 500;

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
	if(!h.dev.isusb3 && (sts & PSsuspend) != 0){
		portfeature(h, p, Fportsuspend, 0);
		sys->sleep(Enabledelay);
		sts = portstatus(h, p);
		if(sts == -1){
			hubfail(h);
			return -1;
		}
	}
	if((pp.sts & PSpresent) == 0 && (sts & PSpresent) != 0){
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
	sys->sleep(Enabledelay);
	if(d.isusb3){
		sts := portstatus(h, p);
		if(sts == -1 || (sts & PSenable) == 0)
			return portfail(h, p, nil, "not enabled");
		sp = "super";
	} else {
		if(portfeature(h, p, Fportreset, 1) < 0)
			return portfail(h, p, nil, "reset");
		sys->sleep(Resetdelay);
		sts := portstatus(h, p);
		if(sts == -1 || (sts & PSenable) == 0){
			portfeature(h, p, Fportenable, 1);
			sts = portstatus(h, p);
			if(sts == -1 || (sts & PSenable) == 0)
				return portfail(h, p, nil, "not enabled after reset");
		}
		sp = "full";
		if(sts & PSslow)
			sp = "low";
		if(sts & PShigh)
			sp = "high";
	}
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
	if(usbcmd(nd, Rh2d|Rstd|Rdev, Rsetaddress, nd.id, 0, nil, 0) < 0)
		return portfail(h, p, nd, "set address");
	if(devctl(nd, "address") < 0)
		return portfail(h, p, nd, "address");
	# maxpkt of ep0 from the first 8 bytes of the device descriptor;
	# this kernel only takes "maxpkt" while the data file is closed
	mp := 512;
	if(!nd.isusb3){
		(r, dd) := usbin(nd, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 8);
		if(r < 8)
			return portfail(h, p, nd, "device descriptor");
		mp = int dd[7];
	}
	nd.dfd = nil;
	devctl(nd, sys->sprint("maxpkt %d", mp));
	if(opendevdata(nd) < 0)
		return portfail(h, p, nd, "reopen data");
	(r, dd) := usbin(nd, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 18);
	if(r < 18)
		return portfail(h, p, nd, "full device descriptor");
	nd.class = int dd[4];
	nd.vid = int dd[8] | int dd[9]<<8;
	nd.did = int dd[10] | int dd[11]<<8;
	if(usbcmd(nd, Rh2d|Rstd|Rdev, Rsetconf, 1, 0, nil, 0) < 0)
		return portfail(h, p, nd, "set configuration");
	sys->print("usbd: %s: port %d: %s %s vid %4.4ux did %4.4ux class %d\n",
		d.name, p, sp, nd.name, nd.vid, nd.did, nd.class);
	pp.dev = nd;
	return nd;
}

portfail(h: ref Hub, p: int, nd: ref Dev, why: string): ref Dev
{
	sys->fprint(sys->fildes(2), "usbd: %s: port %d: %s: %r\n", h.dev.name, p, why);
	h.port[p].sts = 0;
	if(!h.dev.isusb3)
		portfeature(h, p, Fportenable, 0);
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
	# walk the interface and endpoint descriptors
	iface := -1;
	proto := 0;
	i := 0;
	while(i + 1 < r){
		l := int cd[i];
		t := int cd[i+1];
		if(l < 2)
			break;
		case t {
		Diface =>
			if(i + 8 <= r && int cd[i+5] == 3 && int cd[i+6] == 1){
				iface = int cd[i+2];
				proto = int cd[i+7];	# 1 keyboard, 2 mouse
			} else
				iface = -1;
		Dep =>
			if(iface >= 0 && i + 7 <= r){
				addr := int cd[i+2];
				attr := int cd[i+3];
				maxpkt := int cd[i+4] | int cd[i+5]<<8;
				ival := int cd[i+6];
				if((addr & 16r80) != 0 && (attr & 3) == 3){
					hidstart(d, iface, proto, addr & 16r0f, maxpkt, ival);
					return;
				}
			}
		}
		i += l;
	}
	sys->print("usbd: %s: no boot-protocol HID interface, left configured\n", d.name);
}

#
# boot-protocol keyboard (proto 1) or mouse (proto 2): put the
# interface in boot protocol, make the interrupt endpoint and read it
#
hidstart(d: ref Dev, iface, proto, epn, maxpkt, ival: int)
{
	usbcmd(d, Rh2d|Rclass|Riface, Rsetidle, 0, iface, nil, 0);
	if(usbcmd(d, Rh2d|Rclass|Riface, Rsetproto, 0, iface, nil, 0) < 0){
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
	* =>
		sys->print("usbd: %s: HID protocol %d ignored\n", d.name, proto);
	}
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
# hubs
#
newhub(name: string, d: ref Dev): ref Hub
{
	h := ref Hub;
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
	# the kernel wants the port count before the hub's data file is open
	if(devctl(h.dev, sys->sprint("hub %d", h.nport)) < 0)
		sys->fprint(sys->fildes(2), "usbd: %s: hub: %r\n", h.dev.name);
	if(h.dev.dfd == nil && opendevdata(h.dev) < 0){
		sys->fprint(sys->fildes(2), "usbd: %s: open data: %r\n", h.dev.name);
		return nil;
	}
	h.port = array[h.nport+1] of ref Port;
	for(i := 0; i <= h.nport; i++)
		h.port[i] = ref Port(0, nil, nil);
	if(!h.isroot){
		for(i = 1; i <= h.nport; i++)
			portfeature(h, i, Fportpower, 1);
		sys->sleep(h.pwrms);
	}
	hubs = h :: hubs;
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
	d := ref Dev;
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
