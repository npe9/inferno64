implement Bthid;

#
# HID over GATT: a Bluetooth keyboard or mouse turned into keystrokes
# on /dev/keyboard and motion on /dev/pointer.
#
# Everything it needs is already files.  btfs(4) has walked the
# device's database into /net/bt/N/remote/ADDR/gatt, so a HID device
# is a directory named 1812 with the characteristics in it; a
# subscription is opening the .notify file beside one; and a report is
# a read from that file.  There is no Bluetooth left in this program
# at all, which is the point of serving the stack as a name space.
#
# The boot protocol first: the eight byte keyboard report and the
# three byte mouse report, which are the same on every device that
# claims to speak it and are what a machine's own firmware drives.
# Writing 0 to the Protocol Mode characteristic is what asks for it.
#
# A device with no Protocol Mode characteristic, or with no boot
# reports behind it, speaks only the report protocol, and then the
# layout has to be read off the device: the Report Map characteristic
# is a HID report descriptor, and each Report characteristic has a
# Report Reference descriptor beside it saying which report id it
# carries.  Nothing else says which of two Report characteristics is
# the keyboard and which the mouse -- they have the same UUID -- so
# the map is not an optimisation here, it is the only way to tell.
#
# The translations are hidboot(2) and hidreport(2), both shared with
# usbd, because the reports above the transport are identical.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "hidboot.m";
	hidboot: Hidboot;
include "hidreport.m";
	hidreport: Hidreport;
	Report: import hidreport;

Bthid: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# HID over GATT, the characteristics that matter
Uhid:		con "1812";
Uprotocol:	con "2a4e";	# protocol mode: 0 boot, 1 report
Ubootkbd:	con "2a22";	# boot keyboard input report
Ubootmouse:	con "2a33";	# boot mouse input report
Umap:		con "2a4b";	# report map
Uref:		con "2908";	# report reference, one per report
Tinput:		con 1;		# what a report reference calls an input

mnt := "/net/bt";
kbdfile := "/dev/keyboard";
ptrfile := "/dev/pointer";
verbose := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	hidboot = load Hidboot Hidboot->PATH;
	if(hidboot == nil){
		sys->fprint(sys->fildes(2), "bthid: cannot load %s: %r\n", Hidboot->PATH);
		return;
	}
	hidboot->init();
	hidreport = load Hidreport Hidreport->PATH;
	if(hidreport == nil){
		sys->fprint(sys->fildes(2), "bthid: cannot load %s: %r\n", Hidreport->PATH);
		return;
	}
	hidreport->init();

	arg->init(argv);
	arg->setusage("bthid [-v] [-m mountpoint] [-k keyfile] [-p pointerfile] [device]");
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose = 1;
		'm' =>	mnt = arg->arg();
		'k' =>	kbdfile = arg->arg();
		'p' =>	ptrfile = arg->arg();
		* =>	arg->usage();
		}
	a := arg->argv();
	dev := "";
	if(a != nil)
		dev = hd a;

	if(dev == "")
		dev = findhid();
	if(dev == ""){
		sys->fprint(sys->fildes(2), "bthid: no connected device has a %s service\n", Uhid);
		return;
	}
	sys->print("bthid: %s\n", dev);

	svc := dev + "/gatt/" + Uhid + "/";

	#
	# The boot protocol, if there is one to have.  Whether there is
	# is a question about the boot reports and not about Protocol
	# Mode: a device that has no boot report has no boot protocol to
	# select, and writing 0 to its Protocol Mode would put it in a
	# mode it cannot report in.  So the reports are looked for
	# first, and the write only follows finding one.
	#
	n := 0;
	kbd := exists(svc + Ubootkbd + ".notify");
	ptr := exists(svc + Ubootmouse + ".notify");
	if((kbd || ptr) && writefile(svc + Uprotocol, "\0") == nil){
		if(kbd){
			spawn keyboard(svc + Ubootkbd + ".notify", nil);
			n++;
		}
		if(ptr){
			spawn mouse(svc + Ubootmouse + ".notify", nil);
			n++;
		}
		sys->print("bthid: boot protocol, %d reports\n", n);
	}
	if(n == 0)
		n = reports(svc);
	if(n == 0){
		sys->fprint(sys->fildes(2),
			"bthid: %s has no report this can read\n", dev);
		return;
	}
	#
	# and stay, because the readers are the program.  They end when
	# the link does.
	#
	for(;;)
		sys->sleep(60000);
}

#
# the first connected device with a HID service on it.  A machine with
# two keyboards runs two of these, named.
#
findhid(): string
{
	for(cl := lsdir(mnt); cl != nil; cl = tl cl){
		rd := mnt + "/" + hd cl + "/remote";
		for(dl := lsdir(rd); dl != nil; dl = tl dl){
			d := rd + "/" + hd dl;
			if(exists(d + "/gatt/" + Uhid))
				return d;
		}
	}
	return "";
}

#
# The report protocol.  Read the map, then find every Report
# characteristic that has a Report Reference descriptor beside it, and
# put the two together: the descriptor says which report id the
# characteristic carries, the map says what is in a report of that id.
#
# The descriptors are what is walked rather than the characteristics,
# because a Report characteristic without one says nothing about
# itself and there is nothing to be done with it.
#
reports(svc: string): int
{
	(map, me) := readbytes(svc + Umap);
	if(me != nil){
		sys->fprint(sys->fildes(2), "bthid: %s: %s\n", svc + Umap, me);
		return 0;
	}
	(rl, pe) := hidreport->parse(map);
	if(pe != nil)
		sys->fprint(sys->fildes(2),
			"bthid: %s: %s; using what was understood before it\n",
			svc + Umap, pe);
	if(rl == nil)
		return 0;

	n := 0;
	for(fl := lsdir(svc); fl != nil; fl = tl fl){
		name := hd fl;
		if(len name < len Uref + 1
		|| name[len name - len Uref - 1:] != "." + Uref)
			continue;
		ch := name[0:len name - len Uref - 1];
		if(!exists(svc + ch + ".notify"))
			continue;
		(v, e) := readbytes(svc + name);
		if(e != nil || len v < 2)
			continue;
		id := int v[0];
		if(int v[1] != Tinput)
			continue;		# an output or a feature report
		r := hidreport->report(rl, id, Hidreport->Input);
		if(r == nil){
			sys->fprint(sys->fildes(2),
				"bthid: %s says report %d and the map does not describe one\n",
				ch, id);
			continue;
		}
		if(hidreport->kbd(r)){
			sys->print("bthid: report protocol, %s is keyboard report %d\n",
				ch, id);
			spawn keyboard(svc + ch + ".notify", r);
			n++;
		} else if(hidreport->ptr(r)){
			sys->print("bthid: report protocol, %s is pointer report %d\n",
				ch, id);
			spawn mouse(svc + ch + ".notify", r);
			n++;
		} else if(verbose)
			sys->print("bthid: report %d is neither a keyboard nor a pointer\n", id);
	}
	return n;
}

#
# One reader for both protocols.  r is the layout the report map gave,
# or nil for the boot protocol, whose layout is fixed and needs no map
# -- which is the whole reason the boot protocol exists.
#
keyboard(f: string, r: ref Report)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "bthid: %s: %r\n", f);
		return;
	}
	kfd := sys->open(kbdfile, Sys->OWRITE);
	if(kfd == nil){
		sys->fprint(sys->fildes(2), "bthid: %s: %r\n", kbdfile);
		return;
	}
	#
	# A boot report is the whole state of the keyboard, not an
	# event: the keys that are down, in no particular order.  What
	# is new is what was not down before, so the previous report has
	# to be kept -- a report read as events would repeat every held
	# key at whatever rate the device sends.
	#
	prev := array[0] of int;
	rep := array[64] of byte;
	for(;;){
		n := sys->read(fd, rep, len rep);
		if(n < 0){
			sys->fprint(sys->fildes(2), "bthid: keyboard gone: %r\n");
			return;
		}
		mod: int;
		cur: array of int;
		if(r == nil){
			if(n < 8)
				continue;	# not a boot report
			mod = int rep[0];
			cur = hidboot->keysof(rep[0:n]);
		} else {
			if(n * 8 < r.bits)
				continue;	# short for what the map said
			(mod, cur) = hidreport->keys(r, rep[0:n]);
		}
		for(i := 0; i < len cur; i++){
			if(hidboot->held(prev, cur[i]))
				continue;
			s := hidboot->keysym(cur[i], mod);
			if(s == nil)
				continue;
			if(verbose)
				sys->print("bthid: key %d mod %#2.2ux -> %q\n", cur[i], mod, s);
			sys->fprint(kfd, "%s", s);
		}
		prev = cur;
	}
}

mouse(f: string, r: ref Report)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "bthid: %s: %r\n", f);
		return;
	}
	mfd := sys->open(ptrfile, Sys->OWRITE);
	if(mfd == nil){
		sys->fprint(sys->fildes(2), "bthid: %s: %r\n", ptrfile);
		return;
	}
	#
	# The report is movement since the last one; /dev/pointer wants
	# a position.  So the position is kept here, and kept off the
	# top and left edges, exactly as usbd does.
	#
	x := 0;
	y := 0;
	rep := array[64] of byte;
	for(;;){
		n := sys->read(fd, rep, len rep);
		if(n < 0){
			sys->fprint(sys->fildes(2), "bthid: mouse gone: %r\n");
			return;
		}
		dx, dy, b: int;
		if(r == nil){
			if(n < 3)
				continue;
			(dx, dy, b) = hidboot->mouse(rep[0:n]);
		} else {
			if(n * 8 < r.bits)
				continue;
			(dx, dy, b, nil) = hidreport->mouse(r, rep[0:n]);
		}
		x += dx;
		y += dy;
		if(x < 0)
			x = 0;
		if(y < 0)
			y = 0;
		if(verbose)
			sys->print("bthid: pointer %d %d %d\n", x, y, b);
		sys->fprint(mfd, "m %d %d %d", x, y, b);
	}
}

exists(p: string): int
{
	(ok, nil) := sys->stat(p);
	return ok >= 0;
}

readbytes(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	v := array[0] of byte;
	buf := array[512] of byte;
	for(;;){
		#
		# A file, not a stream: read from where the last one
		# stopped, because btfs answers a characteristic read
		# with the whole value and the offset is what says how
		# much of it has been taken.
		#
		# A read shorter than the buffer is the end of it, and
		# stopping there matters: btfs has no cached value, so
		# every read of one of these files is another round trip
		# to the device, and reading again only to be told there
		# is nothing left doubles the cost of every value.
		#
		n := sys->pread(fd, buf, len buf, big len v);
		if(n <= 0)
			break;
		nv := array[len v + n] of byte;
		nv[0:] = v;
		nv[len v:] = buf[0:n];
		v = nv;
		if(n < len buf)
			break;
	}
	if(len v == 0)
		return (nil, "empty");
	return (v, nil);
}

writefile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

lsdir(path: string): list of string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = d[i].name :: l;
	}
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
