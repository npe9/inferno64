implement Btbench;

#
# btbench: drive the whole Bluetooth stack through its files and say
# what happened.  It starts btfs(4) on the transport it is given, then
# reads the controller, scans, lists what answered, connects to the
# first device, walks its GATT database, reads a characteristic,
# takes notifications, pairs, and disconnects -- every step an open,
# a read or a write, because that is the only interface the stack
# has.
#
# The same program is the bench everywhere: under emu on the build
# host against a controller model over TCP, and inside the native
# kernels through their own init (os/inferno/init/pc64btinit.b over a
# uart, os/inferno/init/virtbtinit.b over TCP).  What changes between
# them is one argument.
#
#	btbench /dev/eia1!115200!fc
#	btbench tcp!10.0.2.2!5555
#
# See btfs(4) and doc/inferno-ports.ms.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Btbench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

mnt := "/net/bt";

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("cannot open: %r");
	buf := array[8192] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

writefile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open: %r");
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

show(path: string)
{
	say(sys->sprint("BT: %s: %s", path, trim(readfile(path))));
}

#
# say a line in short pieces.  riscv64 virt loses everything after
# about 128 characters of a single print and does not come back, so a
# long line takes the console with it: the program runs on (the
# controller model still sees the commands) and nothing more is ever
# printed.  Splitting the line sidesteps that; see
# doc/inferno-ports.ms.
#
Saylen:	con 72;

say(s: string)
{
	while(len s > Saylen){
		sys->print("%s", s[0:Saylen]);
		s = s[Saylen:];
	}
	sys->print("%s\n", s);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	spec := "/dev/eia1";
	if(tl argv != nil)
		spec = hd tl argv;
	if(tl argv != nil && tl tl argv != nil)
		mnt = hd tl tl argv;

	btfs := load Command "/dis/bt/btfs.dis";
	if(btfs == nil){
		sys->print("BT: cannot load /dis/bt/btfs.dis: %r\n");
		return;
	}
	btfs->init(nil, "btfs" :: "-m" :: mnt :: spec :: nil);
	sys->sleep(500);

	show(mnt + "/0/addr");
	show(mnt + "/0/version");
	show(mnt + "/0/state");

	sys->print("BT: scan on\n");
	if((e := writefile(mnt + "/0/ctl", "scan on")) != nil)
		sys->print("BT: scan on: %s\n", e);
	sys->sleep(2000);
	show(mnt + "/0/scan");
	show(mnt + "/0/state");

	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: no devices found\n");
		return;
	}
	for(l := remotes; l != nil; l = tl l){
		d := mnt + "/0/remote/" + hd l;
		sys->print("BT: found %s name %s rssi %s type %s\n", hd l,
			trim(readfile(d + "/name")), trim(readfile(d + "/rssi")),
			trim(readfile(d + "/type")));
	}
	# scanning deliberately stays on through the connection and the
	# discovery after it.  btfs is then in nametree from two
	# processes at once -- the scanner making device nodes, the
	# connection making a whole gatt subtree -- and nametree's Tree
	# has one reply channel for both.  Turning scanning off here
	# first, which is the obvious thing to do, serialises them and
	# tests nothing.
	dev := mnt + "/0/remote/" + hd remotes;
	sys->print("BT: connect %s\n", hd remotes);
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: connect: %s\n", e);
		return;
	}
	show(dev + "/state");

	# the whole GATT database, as directories and files
	for(sl := lsdir(dev + "/gatt"); sl != nil; sl = tl sl){
		svc := dev + "/gatt/" + hd sl;
		sys->print("BT: service %s\n", hd sl);
		for(cl := lsdir(svc); cl != nil; cl = tl cl)
			sys->print("BT:   %s\n", hd cl);
	}

	sys->print("BT: device name = %s\n", trim(readfile(dev + "/gatt/1800/2a00")));
	b := readfile(dev + "/gatt/180f/2a19");
	if(len b > 0)
		sys->print("BT: battery = %d%%\n", int b[0]);
	else
		sys->print("BT: battery: %s\n", b);

	# notifications: opening the stream subscribes, each read is the
	# next one, closing it unsubscribes
	sys->print("BT: subscribing to 2a19\n");
	nfd := sys->open(dev + "/gatt/180f/2a19.notify", Sys->OREAD);
	if(nfd == nil)
		sys->print("BT: notify: %r\n");
	else {
		buf := array[64] of byte;
		for(i := 0; i < 3; i++){
			n := sys->read(nfd, buf, len buf);
			if(n <= 0){
				sys->print("BT: notify read: %r\n");
				break;
			}
			sys->print("BT: notification %d: battery = %d%%\n", i, int buf[0]);
		}
		nfd = nil;
	}

	sys->print("BT: pair\n");
	if((e = writefile(dev + "/ctl", "pair")) != nil)
		sys->print("BT: pair: %s\n", e);
	else {
		show(dev + "/state");
		for(bl := lines(readfile(mnt + "/0/bonds")); bl != nil; bl = tl bl)
			say("BT: bond " + hd bl);
	}

	sys->print("BT: disconnect\n");
	if((e = writefile(dev + "/ctl", "disconnect")) != nil)
		sys->print("BT: disconnect: %s\n", e);
	sys->sleep(500);
	show(dev + "/state");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

lines(s: string): list of string
{
	l: list of string;
	while(s != nil){
		i := 0;
		while(i < len s && s[i] != '\n')
			i++;
		if(i > 0)
			l = s[0:i] :: l;
		if(i >= len s)
			break;
		s = s[i+1:];
	}
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

