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

	case mode {
	"rejoin" =>
		rejoin();
		return;
	"stall" or "late" or "early" or "orphan" or "orphanlive" or "badprepare" =>
		conntest(mode);
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

	#
	# A long write: a value that will not fit in one ATT request, so
	# it has to be queued in pieces and committed.  Reading it back
	# uses the Read Blob loop, so the two long paths check each
	# other -- and the value is not a repeated byte, because a
	# length that came out right with the pieces in the wrong order
	# would still look right if it were.
	#
	longw := mnt + "/0/remote/" + hd remotes + "/gatt/fff0/fff1";
	want := "";
	for(k := 0; k < 200; k++)
		want[len want] = 'a' + (k % 26);
	sys->print("BT: long write %d bytes\n", len want);
	if((e = writefile(longw, want)) != nil)
		sys->print("BT: FAILED: long write: %s\n", e);
	else {
		got := readfile(longw);
		if(got != want){
			sys->print("BT: FAILED: read back %d bytes of %d\n", len got, len want);
			if(len got > 40)
				sys->print("BT: got %s...\n", got[0:40]);
			else
				sys->print("BT: got %s\n", got);
		} else
			sys->print("BT: long write read back whole, %d bytes\n", len got);
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
# What happens to a connection attempt the controller does not answer
# in time, and to the completion that turns up afterwards.  Three
# shapes, one per mode, all of them driven by the controller model
# holding something back rather than by anything here pretending:
#
#	stall	the attempt is never answered, the cancel succeeds, and
#		the completion the specification promises after a
#		successful cancel says Unknown Connection Identifier.
#		The connect must fail, the device must not claim to be
#		connected, and -- the point -- the *next* connect must
#		work, which it will not if the refusal was left lying in
#		the channel for it to pick up.
#	late	the connection comes up just as the attempt gives up, so
#		the cancel is refused and the completion is real.  The
#		connect must succeed: it is the connection that was
#		asked for, only late, and throwing it away would leave
#		it up on the controller with nothing owning it.
#	early	the completion arrives before the command status, which
#		is a controller doing something it may not do and is the
#		only way from outside to put the answer in front of the
#		waiter before it waits.  The connect must work.
#	orphan	the controller owes a completion, does not send it while
#		anyone is waiting, and sends a refusal long afterwards.
#		The next connect must not be handed it.  Same assertions
#		as stall: the first fails, the second works.
#	orphanlive
#		the same, except what turns up late is a connection, on
#		a handle of its own.  The controller is now holding a
#		link this side gave up on.  Discarding it silently would
#		leave it up for ever with a Cstate nothing removes, so
#		the controller's connection count must come back to one
#		-- the new link and not the abandoned one.
#
conntest(mode: string)
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	sys->print("BT: %s connect %s\n", mode, hd remotes);
	e := writefile(dev + "/ctl", "connect");
	if(mode == "badprepare"){
		badprepare(dev, e);
		return;
	}
	st := trim(readfile(dev + "/state"));
	ok := 1;
	case mode {
	"stall" or "orphan" or "orphanlive" =>
		if(mode == "orphan" || mode == "orphanlive"){
			#
			# the refusal is deliberately sent late; wait
			# until it has been, so the next connect is made
			# with it already sitting in the channel rather
			# than racing it.
			#
			sys->print("BT: waiting for what the controller sends late\n");
			sys->sleep(8000);
		}
		if(e == nil){
			sys->print("BT: FAILED: an unanswered attempt reported success\n");
			ok = 0;
		} else
			sys->print("BT: connect said: %s\n", e);
		if(len st >= 9 && st[0:9] == "connected"){
			sys->print("BT: FAILED: state says %s after a failed connect\n", st);
			ok = 0;
		}
		sys->print("BT: connect again\n");
		if((e = writefile(dev + "/ctl", "connect")) != nil){
			sys->print("BT: FAILED: the next connect failed too: %s\n", e);
			ok = 0;
		} else {
			st = trim(readfile(dev + "/state"));
			if(!(len st >= 9 && st[0:9] == "connected")){
				sys->print("BT: FAILED: state says %s\n", st);
				ok = 0;
			} else
				sys->print("BT: connected after the cancelled attempt: %s\n", st);
		}
	* =>
		if(e != nil){
			sys->print("BT: FAILED: connect: %s\n", e);
			ok = 0;
		} else if(!(len st >= 9 && st[0:9] == "connected")){
			sys->print("BT: FAILED: state says %s\n", st);
			ok = 0;
		} else
			sys->print("BT: connected: %s\n", st);
	}
	if(ok && mode == "orphanlive"){
		#
		# the abandoned link has to have been closed, not merely
		# ignored: the controller's count is the only place that
		# shows it, since nothing above ever knew the handle.
		#
		sys->sleep(1000);
		cs := trim(readfile(mnt + "/0/state"));
		if(!hasword(cs, "connections 1")){
			sys->print("BT: FAILED: %s\n", cs);
			sys->print("BT: FAILED: the abandoned link was not closed\n");
			ok = 0;
		} else
			sys->print("BT: the abandoned link was closed: %s\n", cs);
	}
	if(ok){
		#
		# and the link works, not merely exists: a characteristic
		# read is a round trip through L2CAP and ATT.
		#
		v := trim(readfile(dev + "/gatt/1800/2a00"));
		if(v != "inferno-bench"){
			sys->print("BT: FAILED: the link does not carry ATT: %s\n", v);
			ok = 0;
		} else
			sys->print("BT: the link carries ATT: name = %s\n", v);
	}
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# A server whose Prepare Write response does not echo what was sent.
# The write has to fail rather than go on to Execute, and the value on
# the device has to be left as it was: a client that ignores the echo
# commits whatever the server queued instead, which is the one place in
# ATT where not reading the answer writes wrong bytes to the device
# rather than merely losing them.
#
badprepare(dev: string, e: string)
{
	if(e != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	f := dev + "/gatt/fff0/fff1";
	before := readfile(f);
	want := "";
	for(k := 0; k < 200; k++)
		want[len want] = 'a' + (k % 26);
	ok := 1;
	if((e = writefile(f, want)) == nil){
		sys->print("BT: FAILED: a corrupted echo was accepted\n");
		ok = 0;
	} else
		sys->print("BT: long write refused: %s\n", e);
	after := readfile(f);
	if(after != before){
		sys->print("BT: FAILED: the value changed anyway, %d bytes\n", len after);
		ok = 0;
	} else if(ok)
		sys->print("BT: the value is untouched and the queue was cancelled\n");
	writefile(dev + "/ctl", "disconnect");
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

hasword(s, w: string): int
{
	for(i := 0; i + len w <= len s; i++)
		if(s[i:i+len w] == w)
			return 1;
	return 0;
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

