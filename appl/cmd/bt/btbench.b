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
include "bt.m";
	bt: Bt;
	smp: Smp;

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

#
# ah is what recognises a device behind a resolvable private address,
# and it is the one function here whose byte order the controller
# model cannot check -- both are written in the same place from the
# same reading, so a shared mistake would agree with itself.  This
# vector comes from neither: it is bluez unit/test-crypto.c's
# test_sih.  It runs before anything else, because everything the
# private-address part of this bench claims rests on it.
#
Ahkey:	con "cdcc72dd868ccdce22fda121097d7d45";
Ahr:	con "63f569";
Ahwant:	con "DA4819";

checkah(): int
{
	got := smp->ah(bt->unhex(Ahkey), bt->unhex(Ahr));
	if(got == nil || bt->hex(got) != Ahwant){
		sys->print("BT: ah vector FAILED: want %s got %s\n",
			Ahwant, bt->hex(got));
		return 0;
	}
	sys->print("BT: ah vector ok (%s)\n", Ahwant);
	return 1;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	bt = load Bt Bt->PATH;
	if(bt == nil){
		sys->print("BT: cannot load %s: %r\n", Bt->PATH);
		return;
	}
	bt->init();
	smp = load Smp Smp->PATH;
	if(smp == nil){
		sys->print("BT: cannot load %s: %r\n", Smp->PATH);
		return;
	}
	if((se := smp->init(bt, nil, nil)) != nil){
		sys->print("BT: smp init: %s\n", se);
		return;
	}
	if(!checkah())
		return;

	spec := "/dev/eia1";
	keyfile, mode: string;
	if(tl argv != nil)
		spec = hd tl argv;
	if(tl argv != nil && tl tl argv != nil)
		mnt = hd tl tl argv;
	rest := argv;
	for(skip := 0; skip < 3 && rest != nil; skip++)
		rest = tl rest;
	if(rest != nil){
		keyfile = hd rest;
		rest = tl rest;
	}
	if(rest != nil)
		mode = hd rest;

	btfs := load Command "/dis/bt/btfs.dis";
	if(btfs == nil){
		sys->print("BT: cannot load /dis/bt/btfs.dis: %r\n");
		return;
	}
	args := "btfs" :: "-m" :: mnt :: spec :: nil;
	if(keyfile != nil)
		args = "btfs" :: "-m" :: mnt :: "-k" :: keyfile :: spec :: nil;
	btfs->init(nil, args);
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

	if(mode == "rejoin"){
		rejoin();
		return;
	}

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

	#
	# The device now rotates a resolvable private address.  Nothing
	# above needed a bond; this is the part that does.  What is
	# being asserted is that the rotation is invisible in the name
	# space: the same directory, named by the identity address, no
	# new strangers under remote/, and the addr file following the
	# device to wherever it is answering now.
	#
	sys->print("BT: private addresses\n");
	before := len remotes;
	first, last: string;
	for(i := 0; i < 12; i++){
		sys->sleep(500);
		a := trim(readfile(dev + "/addr"));
		if(first == nil)
			first = a;
		last = a;
		if(first != nil && last != first)
			break;
	}
	after := lsdir(mnt + "/0/remote");
	say("BT: identity " + trim(readfile(dev + "/identity")));
	sys->print("BT: addr was %s now %s\n", first, last);
	sys->print("BT: remote/ held %d devices, now %d\n", before, len after);
	ok := 1;
	if(len after != before){
		sys->print("BT: FAILED: a rotating address made a new device\n");
		ok = 0;
	}
	if(last == first){
		sys->print("BT: FAILED: the address never rotated, so nothing was resolved\n");
		ok = 0;
	}
	if(trim(readfile(dev + "/identity")) == "none"){
		sys->print("BT: FAILED: no identity behind the private address\n");
		ok = 0;
	}
	#
	# Resolution is a comparison, and a comparison that always says
	# yes would pass everything above.  The bond btfs wrote out is
	# the same text smp->parse reads, so the same key can be asked
	# directly: it must account for the address the device is
	# answering on, must not account for it once one bit of the key
	# is wrong, and must not account for a public address at all,
	# since a public address is never resolvable.
	#
	bond := smp->parse(hd lines(readfile(mnt + "/0/bonds")));
	live := bt->straddr(last);
	if(bond == nil || bond.irk == nil || live == nil){
		sys->print("BT: FAILED: no bond to check resolution against\n");
		ok = 0;
	} else {
		if(!smp->resolve(bond, Bt->Arandom, live)){
			sys->print("BT: FAILED: the bond does not resolve the address it is advertising from\n");
			ok = 0;
		}
		wrong := smp->parse(hd lines(readfile(mnt + "/0/bonds")));
		if(wrong == nil || wrong.irk == nil){
			sys->print("BT: FAILED: could not read the bond back a second time\n");
			ok = 0;
		} else {
			wrong.irk[0] = wrong.irk[0] ^ byte 1;
			if(smp->resolve(wrong, Bt->Arandom, live)){
				sys->print("BT: FAILED: a wrong key resolved the address, so nothing is being compared\n");
				ok = 0;
			}
		}
		if(smp->resolve(bond, Bt->Apublic, live)){
			sys->print("BT: FAILED: a public address was treated as resolvable\n");
			ok = 0;
		}
		if(ok)
			sys->print("BT: the key resolves it, a wrong key does not, a public address is not resolvable\n");
	}

	if(ok)
		sys->print("BT: resolved every rotation to %s\n", hd remotes);

	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# Meeting a bonded device again, which is the case a key file exists
# for and the one this stack could not do at all until resolution was
# built.  Nothing pairs here: the bond came off disk before anything
# was heard from, so the identity it names has to be recognised in an
# address the device chose after that.  The device advertises from its
# identity address for a few rounds first and then rotates, so both
# paths are covered -- the device already in the table under its
# identity being adopted, and a bond whose device has not been heard
# from getting a directory named by the identity rather than by the
# address of the minute.
#
rejoin()
{
	bl := lines(readfile(mnt + "/0/bonds"));
	if(bl == nil){
		sys->print("BT: FAILED: no bond was loaded from the key file\n");
		return;
	}
	say("BT: bond from file " + hd bl);
	bond := smp->parse(hd bl);
	if(bond == nil || bond.irk == nil){
		sys->print("BT: FAILED: the bond in the key file has no identity key\n");
		return;
	}
	sys->print("BT: rejoin %s\n", bond.addr);

	dev := mnt + "/0/remote/" + bond.addr;
	seen := 0;
	first, last: string;
	for(i := 0; i < 30; i++){
		sys->sleep(500);
		if(!seen){
			for(rl := lsdir(mnt + "/0/remote"); rl != nil; rl = tl rl)
				if(hd rl == bond.addr)
					seen = 1;
			if(!seen)
				continue;
		}
		a := trim(readfile(dev + "/addr"));
		if(a == nil || a[0] == 'c')	# "cannot open"
			continue;
		if(first == nil)
			first = a;
		last = a;
		if(last != first && bt->resolvable(Bt->Arandom, bt->straddr(last)))
			break;
	}
	if(!seen){
		sys->print("BT: FAILED: the bonded device never appeared under its identity\n");
		return;
	}
	remotes := lsdir(mnt + "/0/remote");
	say("BT: identity " + trim(readfile(dev + "/identity")));
	sys->print("BT: addr was %s now %s\n", first, last);
	sys->print("BT: remote/ holds %d devices\n", len remotes);
	ok := 1;
	if(len remotes != 2){
		sys->print("BT: FAILED: a rotating address made a new device\n");
		ok = 0;
	}
	if(last == first){
		sys->print("BT: FAILED: the address never rotated\n");
		ok = 0;
	}
	if(trim(readfile(dev + "/identity")) == "none"){
		sys->print("BT: FAILED: the bond from the key file gave no identity\n");
		ok = 0;
	}
	if(!smp->resolve(bond, Bt->Arandom, bt->straddr(last))){
		sys->print("BT: FAILED: the stored key does not resolve the address\n");
		ok = 0;
	}
	#
	# The control file names a device by whatever the client typed,
	# and a directory is named by addrstr, which writes upper case.
	# Naming the bonded device in lower case must find the device
	# that is already there rather than making a second one that
	# neither the scanner nor the bond would ever match again.
	# disconnect is used because it goes through the same lookup and
	# asks nothing of the controller when the device is not
	# connected.
	#
	mixed: string;
	for(rl := remotes; rl != nil; rl = tl rl)
		if(hasletter(hd rl))
			mixed = hd rl;
	if(mixed == nil)
		sys->print("BT: no device with a letter in its address; lower case not checked\n");
	else {
		writefile(mnt + "/0/ctl", "disconnect " + lower(mixed));
		nn := lsdir(mnt + "/0/remote");
		if(len nn != len remotes){
			sys->print("BT: FAILED: %s in lower case made a second directory (%d, was %d)\n",
				mixed, len nn, len remotes);
			ok = 0;
		} else
			sys->print("BT: %s named in lower case on ctl found the same device\n", mixed);
	}

	if(ok)
		sys->print("BT: rejoined %s from a key file, with no pairing\n", bond.addr);
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

hasletter(s: string): int
{
	for(i := 0; i < len s; i++)
		if((s[i] >= 'A' && s[i] <= 'F') || (s[i] >= 'a' && s[i] <= 'f'))
			return 1;
	return 0;
}

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

