implement Bttransport;

#
# The USB HCI transport.  A USB Bluetooth controller is a standard
# thing: interface 0 carries HCI commands as class control requests
# on endpoint zero, HCI events on an interrupt IN endpoint and ACL
# data on a pair of bulk endpoints; interface 1 carries SCO audio on
# isochronous endpoints, which this does not use.  The device says so
# itself -- class 16re0 (wireless), subclass 1 (RF), protocol 1
# (Bluetooth) -- so nothing here is per-vendor.
#
# The kernel's part is only what devusb (os/inferno/port/devusb.c)
# already does: it drives the host controller and gives a program a
# ctl and a data file per endpoint.  usbd (appl/cmd/usb/usbd.b) has
# by then addressed the device and chosen its configuration; this
# reads the descriptors again for itself, because which endpoint
# numbers a controller uses is the device's to say, and asks the
# kernel for the endpoints it needs.
#
# Verified: not.  There is no USB Bluetooth controller on the bench
# and no emulated one -- QEMU dropped its Bluetooth devices years
# ago -- so this is written and compiled against the same devusb the
# HID and mass-storage paths are verified against, and it has never
# moved a packet.  Said plainly here and in btfs(4) rather than
# implied to work.
#
# On 9front this is one C program under nusb: the same descriptors,
# the same three endpoints, the same /dev/usb files.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;

Usbdir:	con "/dev/usb";

# request types and requests (USB 2.0 chapter 9)
Rh2d:		con 0;
Rd2h:		con 16r80;
Rstd:		con 0;
Rclass:		con 16r20;
Rdev:		con 0;
Rgetdesc:	con 6;
Ddev:		con 1;
Dconf:		con 2;

# what a Bluetooth controller says it is
Clwireless:	con 16re0;
Subrf:		con 1;
Protobt:	con 1;

# endpoint transfer types, as devusb's ctl takes them
Tbulk:		con 2;
Tintr:		con 3;

Pkt: adt {
	ptype:	int;
	p:	array of byte;
	err:	string;
};

devid:	int;
devname:	string;
ctlfd:	ref Sys->FD;	# ep0 ctl
cmdfd:	ref Sys->FD;	# ep0 data: control transfers
evtfd:	ref Sys->FD;	# interrupt IN: HCI events
aclinfd:	ref Sys->FD;	# bulk IN: ACL up
aclout:	ref Sys->FD;	# bulk OUT: ACL down
pkts:	chan of ref Pkt;
running:	int;

init(b: Bt, spec: string): string
{
	sys = load Sys Sys->PATH;
	bt = b;

	name := spec;
	if(name == nil){
		(nm, e) := findcontroller();
		if(nm == nil)
			return e;
		name = nm;
	}
	devname = name;
	devid = int name[2:];

	ctlfd = sys->open(Usbdir + "/" + name + "/ctl", Sys->ORDWR);
	if(ctlfd == nil)
		return sys->sprint("open %s/%s/ctl: %r", Usbdir, name);
	cmdfd = sys->open(Usbdir + "/" + name + "/data", Sys->ORDWR);
	if(cmdfd == nil)
		return sys->sprint("open %s/%s/data: %r", Usbdir, name);

	(evtep, evtmax, evtival, inep, inmax, outep, outmax, e2) := endpoints();
	if(e2 != nil)
		return e2;

	if((e := newep(evtep, Tintr, "r", evtmax, evtival)) != nil)
		return e;
	if((e = newep(inep, Tbulk, "r", inmax, 0)) != nil)
		return e;
	if((e = newep(outep, Tbulk, "w", outmax, 0)) != nil)
		return e;

	evtfd = sys->open(sys->sprint("%s/ep%d.%d/data", Usbdir, devid, evtep), Sys->OREAD);
	if(evtfd == nil)
		return sys->sprint("open event endpoint: %r");
	aclinfd = sys->open(sys->sprint("%s/ep%d.%d/data", Usbdir, devid, inep), Sys->OREAD);
	if(aclinfd == nil)
		return sys->sprint("open ACL in endpoint: %r");
	aclout = sys->open(sys->sprint("%s/ep%d.%d/data", Usbdir, devid, outep), Sys->OWRITE);
	if(aclout == nil)
		return sys->sprint("open ACL out endpoint: %r");

	pkts = chan of ref Pkt;
	running = 1;
	spawn evtreader(evtmax);
	spawn aclreader(inmax);
	return nil;
}

#
# the first device under /dev/usb whose descriptor says Bluetooth
#
findcontroller(): (string, string)
{
	fd := sys->open(Usbdir, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", Usbdir));
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			nm := d[i].name;
			if(nm == "ctl" || len nm < 4 || nm[0:2] != "ep")
				continue;
			# only a device's own endpoint zero
			if(len nm < 3 || nm[len nm - 2:] != ".0")
				continue;
			if(isbt(nm))
				return (nm, nil);
		}
	}
	return (nil, "no USB Bluetooth controller under " + Usbdir);
}

isbt(nm: string): int
{
	dfd := sys->open(Usbdir + "/" + nm + "/data", Sys->ORDWR);
	if(dfd == nil)
		return 0;
	(r, dd) := ctlin(dfd, Rd2h|Rstd|Rdev, Rgetdesc, Ddev<<8, 0, 18);
	if(r < 18)
		return 0;
	return int dd[4] == Clwireless && int dd[5] == Subrf && int dd[6] == Protobt;
}

#
# walk the configuration descriptor for interface 0's endpoints: an
# interrupt IN for events and a bulk pair for ACL data
#
endpoints(): (int, int, int, int, int, int, int, string)
{
	(r, cd) := ctlin(cmdfd, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8, 0, 9);
	if(r < 9)
		return (0,0,0,0,0,0,0, "cannot read the configuration descriptor");
	total := bt->get16(cd, 2);
	if(total > 1024)
		total = 1024;
	(r, cd) = ctlin(cmdfd, Rd2h|Rstd|Rdev, Rgetdesc, Dconf<<8, 0, total);
	if(r < 9)
		return (0,0,0,0,0,0,0, "cannot read the whole configuration descriptor");

	iface := -1;
	evtep := -1; evtmax := 16; evtival := 1;
	inep := -1; inmax := 64;
	outep := -1; outmax := 64;
	i := 0;
	while(i + 1 < r){
		l := int cd[i];
		t := int cd[i+1];
		if(l < 2)
			break;
		case t {
		4 =>	# interface
			if(i + 9 <= r)
				iface = int cd[i+2];
		5 =>	# endpoint
			if(iface == 0 && i + 7 <= r){
				addr := int cd[i+2];
				attr := int cd[i+3] & 3;
				maxpkt := bt->get16(cd, i+4);
				ival := int cd[i+6];
				if(attr == Tintr && (addr & 16r80) != 0 && evtep < 0){
					evtep = addr & 16r0f;
					evtmax = maxpkt;
					evtival = ival;
				} else if(attr == Tbulk && (addr & 16r80) != 0 && inep < 0){
					inep = addr & 16r0f;
					inmax = maxpkt;
				} else if(attr == Tbulk && (addr & 16r80) == 0 && outep < 0){
					outep = addr & 16r0f;
					outmax = maxpkt;
				}
			}
		}
		i += l;
	}
	if(evtep < 0 || inep < 0 || outep < 0)
		return (0,0,0,0,0,0,0, "the device has no HCI event and ACL endpoints");
	return (evtep, evtmax, evtival, inep, inmax, outep, outmax, nil);
}

newep(n, ttype: int, mode: string, maxpkt, ival: int): string
{
	if(sys->fprint(ctlfd, "new %d %d %s", n, ttype, mode) < 0)
		return sys->sprint("new endpoint %d: %r", n);
	efd := sys->open(sys->sprint("%s/ep%d.%d/ctl", Usbdir, devid, n), Sys->ORDWR);
	if(efd == nil)
		return sys->sprint("open endpoint %d ctl: %r", n);
	if(maxpkt > 0)
		sys->fprint(efd, "maxpkt %d", maxpkt);
	if(ival > 0)
		sys->fprint(efd, "pollival %d", ival);
	return nil;
}

#
# HCI events arrive on the interrupt endpoint.  A transfer is at most
# a packet long, so an event longer than that comes in pieces; the
# event's own parameter length says where it ends.
#
evtreader(maxpkt: int)
{
	if(maxpkt < 16)
		maxpkt = 16;
	acc := array[0] of byte;
	b := array[maxpkt] of byte;
	while(running){
		n := sys->read(evtfd, b, len b);
		if(n <= 0){
			pkts <-= ref Pkt(0, nil, sys->sprint("event endpoint: %r"));
			return;
		}
		acc = append(acc, b[0:n]);
		for(;;){
			if(len acc < 2)
				break;
			plen := int acc[1];
			if(len acc < 2 + plen)
				break;
			p := array[2+plen] of byte;
			p[0:] = acc[0:2+plen];
			acc = acc[2+plen:];
			pkts <-= ref Pkt(Bt->Hcievt, p, nil);
		}
	}
}

aclreader(maxpkt: int)
{
	if(maxpkt < 64)
		maxpkt = 64;
	acc := array[0] of byte;
	b := array[maxpkt] of byte;
	while(running){
		n := sys->read(aclinfd, b, len b);
		if(n <= 0){
			pkts <-= ref Pkt(0, nil, sys->sprint("ACL endpoint: %r"));
			return;
		}
		acc = append(acc, b[0:n]);
		for(;;){
			if(len acc < 4)
				break;
			dlen := bt->get16(acc, 2);
			if(len acc < 4 + dlen)
				break;
			p := array[4+dlen] of byte;
			p[0:] = acc[0:4+dlen];
			acc = acc[4+dlen:];
			pkts <-= ref Pkt(Bt->Hciacl, p, nil);
		}
	}
}

append(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

read(): (int, array of byte, string)
{
	p := <-pkts;
	return (p.ptype, p.p, p.err);
}

#
# an HCI command is a class request to the device on endpoint zero;
# ACL data goes out the bulk endpoint as it stands
#
write(ptype: int, p: array of byte): string
{
	case ptype {
	Bt->Hcicmd =>
		w := array[8 + len p] of byte;
		w[0] = byte (Rh2d|Rclass|Rdev);
		w[1] = byte 0;
		bt->put16(w, 2, 0);
		bt->put16(w, 4, 0);
		bt->put16(w, 6, len p);
		w[8:] = p;
		if(sys->write(cmdfd, w, len w) != len w)
			return sys->sprint("HCI command: %r");
		return nil;
	Bt->Hciacl =>
		if(sys->write(aclout, p, len p) != len p)
			return sys->sprint("ACL write: %r");
		return nil;
	}
	return "this transport does not carry that packet type";
}

#
# a control transfer that reads count bytes back, as usbd(8) does it:
# the setup packet is written to the data file and the answer read
# from it
#
ctlin(fd: ref Sys->FD, rtype, req, value, index, count: int): (int, array of byte)
{
	w := array[8] of byte;
	w[0] = byte rtype;
	w[1] = byte req;
	bt->put16(w, 2, value);
	bt->put16(w, 4, index);
	bt->put16(w, 6, count);
	if(sys->write(fd, w, len w) != len w)
		return (-1, nil);
	b := array[count] of byte;
	n := sys->read(fd, b, count);
	if(n <= 0)
		return (-1, nil);
	return (n, b);
}

close()
{
	running = 0;
	evtfd = aclinfd = aclout = cmdfd = nil;
	if(ctlfd != nil)
		sys->fprint(ctlfd, "detach");
	ctlfd = nil;
}
