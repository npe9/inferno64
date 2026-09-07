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
# What is real is the boot protocol: the eight byte keyboard report
# and the three byte mouse report, which are the same on every device
# that claims to speak it and are what a machine's own firmware
# drives.  Writing 0 to the Protocol Mode characteristic is what asks
# for it.  Not done: the report protocol, which means parsing the
# report map -- a device that will not do boot protocol is found and
# then left alone, exactly as usbd(1) leaves one.
#
# The translation is hidboot(2), shared with usbd, because the reports
# above the transport are identical.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "hidboot.m";
	hidboot: Hidboot;

Bthid: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# HID over GATT, the characteristics that matter
Uhid:		con "1812";
Uprotocol:	con "2a4e";	# protocol mode: 0 boot, 1 report
Ubootkbd:	con "2a22";	# boot keyboard input report
Ubootmouse:	con "2a33";	# boot mouse input report

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

	#
	# Ask for the boot protocol.  A device that has none of this
	# characteristic is one that only speaks the report protocol,
	# and there is nothing here that can read it.
	#
	if((e := writefile(dev + "/gatt/" + Uhid + "/" + Uprotocol, "\0")) != nil){
		sys->fprint(sys->fildes(2),
			"bthid: cannot select the boot protocol: %s\n", e);
		return;
	}

	n := 0;
	if(exists(dev + "/gatt/" + Uhid + "/" + Ubootkbd + ".notify")){
		spawn keyboard(dev);
		n++;
	}
	if(exists(dev + "/gatt/" + Uhid + "/" + Ubootmouse + ".notify")){
		spawn mouse(dev);
		n++;
	}
	if(n == 0){
		sys->fprint(sys->fildes(2),
			"bthid: %s has neither boot report, so nothing to read\n", dev);
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

keyboard(dev: string)
{
	f := dev + "/gatt/" + Uhid + "/" + Ubootkbd + ".notify";
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
		if(n < 8)
			continue;	# not a boot report
		mod := int rep[0];
		cur := hidboot->keysof(rep[0:n]);
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

mouse(dev: string)
{
	f := dev + "/gatt/" + Uhid + "/" + Ubootmouse + ".notify";
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
		if(n < 3)
			continue;
		(dx, dy, b) := hidboot->mouse(rep[0:n]);
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
