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
include "hidreport.m";
	hidreport: Hidreport;
	Report: import hidreport;
include "bt.m";
include "cmac.m";
	cmac: Cmac;
include "p256.m";
	p256: P256;
	bt: Bt;
	smp: Smp;

Btbench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

mnt := "/net/bt";

# where btkeyfs(4) goes when a phase asks for it, and the file it
# keeps its store in
Keymnt:	con "/mnt/btkeys";
keysfile: string;

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
	if(rest != nil){
		mode = hd rest;
		rest = tl rest;
	}
	# a second controller, for the phase that needs two
	spec2: string;
	if(rest != nil)
		spec2 = hd rest;

	btfs := load Command "/dis/bt/btfs.dis";
	if(btfs == nil){
		sys->print("BT: cannot load /dis/bt/btfs.dis: %r\n");
		return;
	}
	# a list grows at the head, so this is built from the last
	# argument backwards and comes out in order
	args := spec :: nil;
	if(spec2 != nil)
		args = spec :: spec2 :: nil;
	#
	# A mode named h5-something runs that phase over the three wire
	# transport instead of H4.  Nothing above the transport changes,
	# which is the point, so the phase itself is the same one.
	#
	if(len mode > 3 && mode[0:3] == "h5-"){
		args = "-5" :: args;
		mode = mode[3:];
	}
	#
	# And keyfs-something runs it with the bonds in btkeyfs(4)
	# rather than in a file btfs writes.  Same phase, same
	# assertions: what changes is where the key went and where it
	# came back from, and the point of running the whole phase over
	# it is that nothing else may change.
	#
	keyfs := 0;
	if(len mode > 6 && mode[0:6] == "keyfs-"){
		keyfs = 1;
		mode = mode[6:];
	}
	if(mode == "forget" || mode == "sweeprace")
		args = "-a" :: "6" :: args;
	if(keyfs && keyfile != nil){
		kf := load Command "/dis/bt/btkeyfs.dis";
		if(kf == nil){
			sys->print("BT: cannot load /dis/bt/btkeyfs.dis: %r\n");
			return;
		}
		keysfile = keyfile;
		kf->init(nil, "btkeyfs" :: "-m" :: Keymnt :: "-f" :: keyfile :: nil);
		sys->sleep(500);
		args = "-K" :: Keymnt :: args;
	} else if(keyfile != nil)
		args = "-k" :: keyfile :: args;
	#
	# the key service on its own, with no controller in it at all:
	# what a bond means to it, what forgetting one means, and that
	# both survive being written down.
	#
	if(mode == "keys"){
		keysphase();
		return;
	}
	args = "btfs" :: "-m" :: mnt :: args;
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
		;
	"stalefid" =>
		stalefid();
		return;
	"changed" =>
		changed();
		return;
	"sco" =>
		scophase();
		return;
	"forget" =>
		forget();
		return;
	"sweeprace" =>
		sweeprace();
		return;
	"params" =>
		paramphase();
		return;
	"included" =>
		included();
		return;
	"crypto" =>
		cryptophase();
		return;
	"btvirtperiph" =>
		btvirtperiph();
		return;
	"coc" or "cocstingy" =>
		cocphase(mode);
		return;
	"two" =>
		twophase();
		return;
	"peripheral" =>
		peripheral();
		return;
	"server" =>
		server();
		return;
	"paired" =>
		paired();
		return;
	#
	# the same phase either way: what the device sends and what has
	# to come out of it are the same, and everything that differs is
	# inside bthid.  A boot protocol device says which report is the
	# keyboard by which characteristic it is; a report protocol one
	# says it only in its report map.
	#
	"classic" =>
		classic();
		return;
	"chid" or "chidnodesc" =>
		chidphase(mode);
		return;
	"pan" or "pannotnap" =>
		panphase(mode);
		return;
	"served" =>
		servedphase();
		return;
	"a2dp" or "a2dpnarrow" or "a2dprefuse" =>
		a2dpphase(mode);
		return;
	"hfp" or "hfpnoslc" =>
		hfpphase(mode);
		return;
	"brconnect" or "brfail" or "brincoming" =>
		brlink(mode);
		return;
	"brl2cap" or "brrefuse" =>
		brchan(mode);
		return;
	"sdp" or "sdpnone" =>
		sdpphase(mode);
		return;
	"rfcomm" or "rfrefuse" =>
		rfphase(mode);
		return;
	"ssp" or "sspbonded" or "sspfail" =>
		sspphase(mode);
		return;
	"hid" =>
		hid();
		return;
	"hidreport" =>
		if(!checkmap())
			return;
		hid();
		return;
	"cocrefuse" =>
		cocrefuse();
		return;
	"cocoverrun" or "cocbig" =>
		cocbad(mode);
		return;
	}
	case mode {
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

	#
	# A pairing that failed used to print its reason and let the
	# phase carry on to a pass.  This phase is named for pairing;
	# it asserts it now.  That gap hid a real failure for a while:
	# Secure Connections against BlueZ was answering the DHKey
	# check with reason 0x0b and the run still said BTVIRT PASS.
	#
	#
	# Against BlueZ this asks for numeric comparison, so the six
	# digits appear in the device's confirm file and the pairing
	# waits.  A person is what that file is for; the bench answers
	# it from a process, which is the one thing a person would not
	# do and is the only way to test it without one.
	#
	if(mode == "btvirt"){
		spawn confirmer(dev);
		sys->print("BT: pair\n");
		if((e = writefile(dev + "/ctl", "pair confirm")) != nil)
			sys->print("BT: FAILED: pair: %s\n", e);
		else {
			show(dev + "/state");
			for(bl0 := lines(readfile(mnt + "/0/bonds")); bl0 != nil; bl0 = tl bl0)
				say("BT: bond " + hd bl0);
		}
	} else {
	sys->print("BT: pair\n");
	if((e = writefile(dev + "/ctl", "pair")) != nil)
		sys->print("BT: FAILED: pair: %s\n", e);
	else {
		show(dev + "/state");
		for(bl := lines(readfile(mnt + "/0/bonds")); bl != nil; bl = tl bl)
			say("BT: bond " + hd bl);
	}
	}

	#
	# The credit-based channel goes on the link that is already up.
	# Reconnecting for it does not work against this peer: bthost
	# stops advertising when it is connected and does not start
	# again, so the second connection attempt finds nothing to
	# connect to.  That is the peer's business and not something to
	# work around in the stack.
	#
	if(mode == "btvirt")
		btvirtcoc(dev);

	sys->print("BT: disconnect\n");
	if((e = writefile(dev + "/ctl", "disconnect")) != nil)
		sys->print("BT: disconnect: %s\n", e);
	sys->sleep(500);
	show(dev + "/state");

	#
	# Against BlueZ there is nothing after this.  btvirt's peer
	# advertises from a public address and does not rotate, so the
	# section below would assert something this peer has never
	# claimed to do, and a phase that fails for that reason says
	# nothing about either side.  Everything above it -- discovery,
	# a read, notifications, a long write and its read back, and
	# pairing -- has just been done against a controller, a link
	# layer, a host and a GATT server that this tree did not write.
	#
	if(mode == "btvirt"){
		btvirtclassic();
		sys->print("BT: done\n");
		return;
	}
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
# A service that includes another.  The included one here is a
# secondary service, which by definition does not appear in primary
# service discovery -- so a client that ignores include declarations
# cannot reach its characteristics at all.  That is what makes this
# lost attributes rather than a lost cross reference.
#
included()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	svcs := lsdir(dev + "/gatt");
	got := 0;
	for(l := svcs; l != nil; l = tl l)
		if(hd l == "fffa")
			got = 1;
	if(!got){
		sys->print("BT: FAILED: the secondary service was not reached\n");
		ok = 0;
	} else
		sys->print("BT: the secondary service is there among %d\n", len svcs);
	#
	# the relationship, not only the service
	#
	inc := trim(readfile(dev + "/gatt/fff2/included"));
	if(!hasword(inc, "fffa")){
		sys->print("BT: FAILED: fff2/included reads %s\n", inc);
		ok = 0;
	} else
		sys->print("BT: fff2 includes: %s\n", inc);
	#
	# and its characteristic reads, which is the attribute that
	# would otherwise be unreachable
	#
	v := trim(readfile(dev + "/gatt/fffa/fffb"));
	if(v != "only reachable through the include"){
		sys->print("BT: FAILED: fffa/fffb reads %s\n", v);
		ok = 0;
	} else
		sys->print("BT: fffa/fffb reads: %s\n", v);
	#
	# a service that includes nothing has no such file, so the file
	# says something rather than being there for every service
	#
	if((fd := sys->open(dev + "/gatt/1800/included", Sys->OREAD)) != nil){
		sys->print("BT: FAILED: 1800 has an included file and includes nothing\n");
		ok = 0;
	} else
		sys->print("BT: a service that includes nothing has no included file\n");
	fd = nil;
	if(ok)
		sys->print("BT: includes followed\n");
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# Connection parameters.  A peripheral cannot change them; it asks the
# central, and a central that says yes has undertaken to perform the
# update.  Saying yes and doing nothing is worse than saying no,
# because the peripheral then believes the link is running at what it
# asked for.
#
# The model asks twice: once for something a controller will take and
# once for a supervision timeout far too short for the latency it
# wants, which is the rule that keeps a link from dropping every time
# the peripheral exercises that latency.  The first must be accepted
# and must change the link; the second must be refused.  Then this
# side asks for something of its own, which is the half that did not
# exist at all.
#
paramphase()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	first := trim(readfile(dev + "/state"));
	sys->print("BT: at first: %s\n", first);
	ok := 1;
	#
	# the peripheral asks.  What is watched is the link, not the
	# answer: the answer is in the controller's log and the link is
	# what the peripheral will believe.
	#
	#
	# the latency, not the interval: the link already starts at
	# interval 40, so watching that would pass without anything
	# having happened -- which it did, the first time this was
	# written.
	#
	want := "latency 4";
	changed := 0;
	st: string;
	for(i := 0; i < 24 && !changed; i++){
		sys->sleep(500);
		st = trim(readfile(dev + "/state"));
		if(hasword(st, want))
			changed = 1;
	}
	if(!changed){
		sys->print("BT: FAILED: %s\n", st);
		sys->print("BT: FAILED: the link never took the parameters the peer asked for\n");
		ok = 0;
	} else
		sys->print("BT: the peer asked and the link changed: %s\n", st);
	#
	# and the second request, which is out of range, must leave it
	# alone
	#
	sys->sleep(4000);
	after := trim(readfile(dev + "/state"));
	if(after != st){
		sys->print("BT: FAILED: an impossible request changed the link: %s\n", after);
		ok = 0;
	} else
		sys->print("BT: the impossible one left it alone\n");
	#
	# now this side asks
	#
	if((e = writefile(dev + "/ctl", "params 24 24 0 200")) != nil){
		sys->print("BT: FAILED: params: %s\n", e);
		ok = 0;
	} else {
		mine := 0;
		for(j := 0; j < 20 && !mine; j++){
			sys->sleep(500);
			st = trim(readfile(dev + "/state"));
			if(hasword(st, "interval 24"))
				mine = 1;
		}
		if(!mine){
			sys->print("BT: FAILED: %s\n", st);
			sys->print("BT: FAILED: the link did not take what this side asked for\n");
			ok = 0;
		} else
			sys->print("BT: this side asked and the link changed: %s\n", st);
	}
	#
	# a request no controller would take must be refused here rather
	# than sent
	#
	if((e = writefile(dev + "/ctl", "params 24 24 400 10")) == nil){
		sys->print("BT: FAILED: an impossible request was sent anyway\n");
		ok = 0;
	} else
		sys->print("BT: refused before it was sent: %s\n", e);
	#
	# the peer's third request is the boundary itself: a timeout
	# exactly (1 + latency) times the interval, which the
	# specification refuses and an implementation that tests for
	# "shorter than" rather than "not longer than" accepts.  It
	# arrives while this waits, and it must leave the link alone.
	#
	settled := trim(readfile(dev + "/state"));
	sys->sleep(5000);
	last := trim(readfile(dev + "/state"));
	if(last != settled){
		sys->print("BT: FAILED: the boundary request changed the link: %s\n", last);
		ok = 0;
	} else
		sys->print("BT: the boundary request left it alone\n");
	if(ok){
		v := trim(readfile(dev + "/gatt/1800/2a00"));
		if(v != "inferno-bench"){
			sys->print("BT: FAILED: the link stopped working: %s\n", v);
			ok = 0;
		} else
			sys->print("BT: the link still works: %s\n", v);
	}
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# The sweep and a connection in flight.  A device is chosen for
# forgetting without its own lock, because waiting for that lock under
# devlock would stop the scanner for as long as a connection attempt
# takes.  So it can be chosen while a connection is being made to it
# and no advertisement has arrived for longer than the ageout -- and
# the connection can then succeed.  Forgetting it at that point would
# take a live device out of the name space.
#
# The model stops advertising and lets the connection complete only
# after the guest has given up waiting for it, which is the longest
# that window can be.  btfs is started with -a 6, so the sweep is
# certain to have chosen the device before the connection lands.
#
sweeprace()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := "060504030201";
	sys->print("BT: connecting while everything goes quiet\n");
	e := writefile(mnt + "/0/remote/" + dev + "/ctl", "connect");
	if(e != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	after := lsdir(mnt + "/0/remote");
	found := 0;
	for(l := after; l != nil; l = tl l)
		if(hd l == dev)
			found = 1;
	if(!found){
		sys->print("BT: FAILED: the device was forgotten while connecting to it\n");
		ok = 0;
	} else
		sys->print("BT: it survived the sweep: %s\n",
			trim(readfile(mnt + "/0/remote/" + dev + "/state")));
	if(ok){
		v := trim(readfile(mnt + "/0/remote/" + dev + "/gatt/1800/2a00"));
		if(v != "inferno-bench"){
			sys->print("BT: FAILED: it reads %s\n", v);
			ok = 0;
		} else
			sys->print("BT: and works: %s\n", v);
	}
	writefile(mnt + "/0/remote/" + dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# A device that stops answering leaves the name space; one that keeps
# answering does not.  Without that, a scan in a room with a hundred
# devices in it fills /net/bt/0/remote and nothing ever comes back out.
#
# btfs is started here with a short -a, because the default is five
# minutes and a bench that waited that out would be a bench nobody
# runs.  The number is the only thing that changes.
#
forget()
{
	before := lsdir(mnt + "/0/remote");
	sys->print("BT: heard from %d devices\n", len before);
	if(len before != 2){
		sys->print("BT: FAILED: wanted 2 to start with\n");
		sys->print("BT: done\n");
		return;
	}
	quiet := "345678ABCDEF";		# nothing keeps this one
	kept := "060504030201";		# this one is connected to
	say("BT: " + quiet + ": " + trim(readfile(mnt + "/0/remote/" + quiet + "/state")));
	#
	# everything stops advertising shortly.  What is left afterwards
	# is left for a reason other than having been heard from: this
	# one is connected, and a connected device is plainly there
	# whatever its last advertisement says.
	#
	if((e := writefile(mnt + "/0/remote/" + kept + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: connected to %s\n", kept);

	after: list of string;
	found := 1;
	for(i := 0; i < 40 && found; i++){
		sys->sleep(500);
		after = lsdir(mnt + "/0/remote");
		found = 0;
		for(l := after; l != nil; l = tl l)
			if(hd l == quiet)
				found = 1;
	}
	ok := 1;
	if(found){
		sys->print("BT: FAILED: the device that went quiet is still there\n");
		ok = 0;
	} else
		sys->print("BT: the device that went quiet was forgotten\n");
	still := 0;
	for(l := after; l != nil; l = tl l)
		if(hd l == kept)
			still = 1;
	if(!still){
		sys->print("BT: FAILED: the connected device was forgotten too\n");
		ok = 0;
	} else
		sys->print("BT: the connected one stayed: %s\n",
			trim(readfile(mnt + "/0/remote/" + kept + "/state")));
	#
	# and it is still usable, so what stayed is the device and not
	# just its name
	#
	v := trim(readfile(mnt + "/0/remote/" + kept + "/gatt/1800/2a00"));
	if(v != "inferno-bench"){
		sys->print("BT: FAILED: the connected device reads %s\n", v);
		ok = 0;
	} else
		sys->print("BT: and still works: %s\n", v);
	if(ok)
		sys->print("BT: remote/ went from %d to %d\n", len before, len after);
	#
	# and with scanning off nothing is arriving, so age says nothing
	# about what is there and nothing more may be forgotten -- the
	# rule most likely to be noticed if it were wrong, since it is
	# the one where a user turns scanning off, walks away, and comes
	# back to an empty directory.
	#
	# Scanning goes off before the link does, on purpose: a device
	# that has stopped advertising and is then disconnected is
	# eligible the moment it is, and that is correct.  What is being
	# asserted here is that scanning off stops the sweep, not that a
	# disconnected device is kept.
	#
	writefile(mnt + "/0/ctl", "scan off");
	sys->sleep(500);
	writefile(mnt + "/0/remote/" + kept + "/ctl", "disconnect");
	held := lsdir(mnt + "/0/remote");
	sys->sleep(9000);
	quiet2 := lsdir(mnt + "/0/remote");
	if(len quiet2 != len held){
		sys->print("BT: FAILED: %d devices were forgotten with scanning off\n",
			len held - len quiet2);
		ok = 0;
	} else
		sys->print("BT: with scanning off, %d stayed past the ageout\n", len held);
	sys->print("BT: done\n");
}

#
# A controller that sends SCO packets to a host that never asked for a
# voice channel.  There is no audio here and nothing above the
# transport wants them, so they are dropped -- but counted and said
# out loud, because a silent drop cannot be told apart from a
# transport that lost them.  What matters as much is that a packet
# type nothing handles does not put the H4 parser out of step: the
# link has to keep working afterwards.
#
scophase()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	n := 0;
	st: string;
	for(i := 0; i < 20 && n < 3; i++){
		sys->sleep(500);
		st = trim(readfile(mnt + "/0/state"));
		n = counted(st);
	}
	ok := 1;
	if(n != 3){
		sys->print("BT: FAILED: %s\n", st);
		sys->print("BT: FAILED: 3 SCO packets were sent, %d counted\n", n);
		ok = 0;
	} else
		sys->print("BT: %d SCO packets arrived and were counted: %s\n", n, st);
	#
	# and the link still carries ATT, so the parser kept its place
	# in the stream through packets it had no case for.
	#
	v := trim(readfile(dev + "/gatt/1800/2a00"));
	if(v != "inferno-bench"){
		sys->print("BT: FAILED: the link is out of step: %s\n", v);
		ok = 0;
	} else
		sys->print("BT: the link still carries ATT: %s\n", v);
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# the scodropped field of the controller's state line, or 0 if it has
# none, which is what a controller that has never sent one shows
#
counted(s: string): int
{
	w := "scodropped ";
	for(i := 0; i + len w <= len s; i++){
		if(s[i:i+len w] != w)
			continue;
		if(i > 0 && s[i-1] != ' ')
			continue;
		v := 0;
		for(j := i + len w; j < len s && s[j] >= '0' && s[j] <= '9'; j++)
			v = v*10 + (s[j] - '0');
		return v;
	}
	return 0;
}

#
# A device that rearranges its database while it is connected, and
# says so.  The name space has to follow: the service that appeared
# must be there, without a disconnection, and its characteristic must
# read.  A client that believed the copy it walked first would never
# see it -- which is what this stack did until it subscribed to
# Service Changed.
#
changed()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	before := lsdir(dev + "/gatt");
	sys->print("BT: services at first: %d\n", len before);
	for(l := before; l != nil; l = tl l)
		if(hd l == "fff5"){
			sys->print("BT: FAILED: the later service was there all along\n");
			sys->print("BT: done\n");
			return;
		}
	#
	# a notification stream held across the rediscovery.  It is
	# documented to go away with the rest of the tree, and what
	# matters is that it fails rather than hangs -- a hang and a
	# documented loss look the same to a client that never returns.
	#
	nfd := sys->open(dev + "/gatt/180f/2a19.notify", Sys->OREAD);
	nbuf := array[64] of byte;
	if(nfd == nil)
		sys->print("BT: FAILED: cannot open the notify stream: %r\n");
	else if(sys->read(nfd, nbuf, len nbuf) <= 0)
		sys->print("BT: FAILED: the notify stream gave nothing\n");
	else
		sys->print("BT: subscribed before the change\n");

	#
	# nothing here asks for anything: the device indicates, btfs
	# walks the database again, and the name space changes under a
	# link that was never dropped.  Twice, so what is seen is that
	# the answer to one indication settles rather than feeding the
	# next.
	#
	found := 0;
	after: list of string;
	for(i := 0; i < 40 && !found; i++){
		sys->sleep(500);
		after = lsdir(dev + "/gatt");
		got := 0;
		for(l = after; l != nil; l = tl l)
			if(hd l == "fff5" || hd l == "fff7")
				got++;
		if(got == 2)
			found = 1;
	}
	ok := 1;
	if(nfd != nil){
		if(sys->read(nfd, nbuf, len nbuf) > 0){
			sys->print("BT: FAILED: the notify stream outlived the rediscovery\n");
			ok = 0;
		} else
			sys->print("BT: the notify stream ended, as btfs(4) says: %r\n");
		nfd = nil;
	}
	if(!found){
		sys->print("BT: FAILED: both services that appeared were not noticed\n");
		ok = 0;
	} else {
		sys->print("BT: services now: %d, including fff5 and fff7\n", len after);
		st := trim(readfile(dev + "/state"));
		if(!(len st >= 9 && st[0:9] == "connected")){
			sys->print("BT: FAILED: the link went away: %s\n", st);
			ok = 0;
		} else
			sys->print("BT: on the same link: %s\n", st);
		v := trim(readfile(dev + "/gatt/fff5/fff6"));
		if(v != "the service that arrived later"){
			sys->print("BT: FAILED: the first new characteristic reads %s\n", v);
			ok = 0;
		} else
			sys->print("BT: the first new characteristic reads: %s\n", v);
		v = trim(readfile(dev + "/gatt/fff7/fff8"));
		if(v != "and one more after that"){
			sys->print("BT: FAILED: the second new characteristic reads %s\n", v);
			ok = 0;
		} else
			sys->print("BT: the second new characteristic reads: %s\n", v);
	}
	if(ok){
		#
		# and what was there before still works, so what was
		# proved is that the tree was walked again rather than
		# replaced by whatever arrived last.
		#
		v := trim(readfile(dev + "/gatt/1800/2a00"));
		if(v != "inferno-bench"){
			sys->print("BT: FAILED: the old characteristic reads %s\n", v);
			ok = 0;
		} else
			sys->print("BT: the old characteristic still reads: %s\n", v);
	}
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# A file kept open across a disconnect and a reconnect.  The
# characteristic it named is gone -- the whole gatt tree is torn down
# when the link closes and built again from scratch -- so reading the
# old fid has to fail.  While the node table kept the entry after the
# tree had dropped it, the read went through the old characteristic's
# handle on the new session instead, which is a wrong answer rather
# than a missing one.
#
stalefid()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	f := dev + "/gatt/1800/2a00";
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		sys->print("BT: FAILED: cannot open %s: %r\n", f);
		sys->print("BT: done\n");
		return;
	}
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0){
		sys->print("BT: FAILED: the first read failed: %r\n");
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: open and read: %s\n", string buf[0:n]);

	writefile(dev + "/ctl", "disconnect");
	sys->sleep(1000);
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: reconnect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: reconnected, the tree was built again\n");

	ok := 1;
	n = sys->read(fd, buf, len buf);
	if(n > 0){
		sys->print("BT: FAILED: the stale fid read %d bytes: %s\n",
			n, string buf[0:n]);
		ok = 0;
	} else
		sys->print("BT: the stale fid reads nothing: %r\n");
	fd = nil;
	#
	# and the new file is there and works, so what was proved above
	# is that the old name went away rather than that the whole tree
	# did.
	#
	v := trim(readfile(f));
	if(v != "inferno-bench"){
		sys->print("BT: FAILED: the new file reads %s\n", v);
		ok = 0;
	} else
		sys->print("BT: the new file reads %s\n", v);
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
#
# The report descriptor parser against a descriptor that is not this
# bench's: the boot keyboard descriptor out of appendix B of the HID
# specification, which every boot protocol keyboard sends.  What it
# describes is the boot layout, and the boot layout is known
# independently -- eight modifier bits, a reserved byte, six key codes,
# and five LED bits going the other way -- so a parser that agrees with
# it is a parser that agrees with something written down somewhere
# else.  It also has no report ids in it, and an input and an output
# report both numbered 0, neither of which the bench's own device has.
#
bootkbdmap(): array of byte
{
	return array[] of {
	byte 16r05, byte 16r01,		# Usage Page (Generic Desktop)
	byte 16r09, byte 16r06,		# Usage (Keyboard)
	byte 16ra1, byte 16r01,		# Collection (Application)
	byte 16r05, byte 16r07,		#   Usage Page (Key Codes)
	byte 16r19, byte 16re0,		#   Usage Minimum (224)
	byte 16r29, byte 16re7,		#   Usage Maximum (231)
	byte 16r15, byte 16r00,		#   Logical Minimum (0)
	byte 16r25, byte 16r01,		#   Logical Maximum (1)
	byte 16r75, byte 16r01,		#   Report Size (1)
	byte 16r95, byte 16r08,		#   Report Count (8)
	byte 16r81, byte 16r02,		#   Input (Data, Variable, Absolute)
	byte 16r95, byte 16r01,		#   Report Count (1)
	byte 16r75, byte 16r08,		#   Report Size (8)
	byte 16r81, byte 16r01,		#   Input (Constant)
	byte 16r95, byte 16r05,		#   Report Count (5)
	byte 16r75, byte 16r01,		#   Report Size (1)
	byte 16r05, byte 16r08,		#   Usage Page (LEDs)
	byte 16r19, byte 16r01,		#   Usage Minimum (1)
	byte 16r29, byte 16r05,		#   Usage Maximum (5)
	byte 16r91, byte 16r02,		#   Output (Data, Variable, Absolute)
	byte 16r95, byte 16r01,		#   Report Count (1)
	byte 16r75, byte 16r03,		#   Report Size (3)
	byte 16r91, byte 16r01,		#   Output (Constant)
	byte 16r95, byte 16r06,		#   Report Count (6)
	byte 16r75, byte 16r08,		#   Report Size (8)
	byte 16r15, byte 16r00,		#   Logical Minimum (0)
	byte 16r25, byte 16r65,		#   Logical Maximum (101)
	byte 16r05, byte 16r07,		#   Usage Page (Key Codes)
	byte 16r19, byte 16r00,		#   Usage Minimum (0)
	byte 16r29, byte 16r65,		#   Usage Maximum (101)
	byte 16r81, byte 16r00,		#   Input (Data, Array)
	byte 16rc0,			# End Collection
	};
}

checkmap(): int
{
	hidreport = load Hidreport Hidreport->PATH;
	if(hidreport == nil){
		sys->print("BT: FAILED: cannot load %s: %r\n", Hidreport->PATH);
		sys->print("BT: done\n");
		return 0;
	}
	hidreport->init();
	(rl, e) := hidreport->parse(bootkbdmap());
	if(e != nil){
		sys->print("BT: FAILED: the boot keyboard descriptor: %s\n", e);
		sys->print("BT: done\n");
		return 0;
	}
	ok := 1;
	ir := hidreport->report(rl, 0, Hidreport->Input);
	orep := hidreport->report(rl, 0, Hidreport->Output);
	if(ir == nil || orep == nil){
		sys->print("BT: FAILED: the descriptor has %d reports, wanted an input and an output\n",
			len rl);
		sys->print("BT: done\n");
		return 0;
	}
	# eight modifier bits, a reserved byte, six key codes
	if(ir.bits != 64){
		sys->print("BT: FAILED: the boot keyboard report is %d bits, wanted 64\n", ir.bits);
		ok = 0;
	}
	if(orep.bits != 8){
		sys->print("BT: FAILED: the LED report is %d bits, wanted 8\n", orep.bits);
		ok = 0;
	}
	m := ir.find(Hidreport->Pkeyboard, 16re0);
	if(m == nil || m.off != 0 || m.size != 1 || m.count != 8){
		sys->print("BT: FAILED: the modifiers are not eight bits at the start\n");
		ok = 0;
	}
	k := ir.find(Hidreport->Pkeyboard, 4);		# the usage code for a
	if(k == nil || k.off != 16 || k.size != 8 || k.count != 6){
		sys->print("BT: FAILED: the key codes are not six bytes at byte two\n");
		ok = 0;
	}
	l := orep.find(16r08, 1);			# Num Lock, on the LED page
	if(l == nil || l.off != 0 || l.size != 1 || l.count != 5){
		sys->print("BT: FAILED: the LEDs are not five bits at the start\n");
		ok = 0;
	}
	#
	# and read a report with it: left shift and the code for a, which
	# is what the phase below sends and what the boot protocol says
	# means a capital A
	#
	rep := array[] of {byte 16r02, byte 0, byte 4, byte 0, byte 0, byte 0, byte 0, byte 0};
	(mod, keys) := hidreport->keys(ir, rep);
	if(mod != 16r02 || len keys != 1 || keys[0] != 4){
		sys->print("BT: FAILED: a boot report read through the map gives mod %#ux and %d keys\n",
			mod, len keys);
		ok = 0;
	}
	if(!ok){
		sys->print("BT: done\n");
		return 0;
	}
	sys->print("BT: the boot keyboard descriptor parses to the boot layout\n");
	return 1;
}

#
# A Classic inquiry.  Nothing LE runs in this phase: no scan is
# started, so everything that turns up in remote/ got there by
# answering an inquiry, which is what makes counting them an
# assertion.
#
# The two devices are deliberately different.  One sends an extended
# inquiry response with its name in it, so the name is there without
# asking; the other sends the plain result with RSSI and has to be
# paged for its name.  Both shapes are real and a stack that handles
# only the first finds half a room.
#
Ckbd:	con "665544332211";
Chead:	con "CCBBAA998877";

classic()
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: inquiry on\n");
	#
	# An inquiry ends by itself.  Wait for the controller to say so
	# rather than for a fixed time: the state file is where that
	# shows, and a phase that slept instead would pass on a stack
	# that never noticed the end.
	#
	done := 0;
	for(i := 0; i < 40 && !done; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			done = 1;
	}
	if(!done){
		sys->print("BT: FAILED: the inquiry never ended\n");
		sys->print("BT: done\n");
		return;
	}
	show(mnt + "/0/state");

	#
	# The LE devices the startup above found are in this directory
	# too, so the count that means anything is how many of them read
	# as Classic: two, and only the two that answered the inquiry.
	#
	ok := 1;
	remotes := lsdir(mnt + "/0/remote");
	nc := 0;
	for(l := remotes; l != nil; l = tl l){
		t := trim(readfile(mnt + "/0/remote/" + hd l + "/type"));
		sys->print("BT: %s type %s\n", hd l, t);
		if(len t >= 7 && t[0:7] == "classic")
			nc++;
	}
	sys->print("BT: remote/ holds %d devices, %d of them Classic\n",
		len remotes, nc);
	if(nc != 2){
		sys->print("BT: FAILED: an inquiry that heard two devices left %d\n", nc);
		ok = 0;
	}
	ok = ok & check(Ckbd, "classic class 2c0104", "classic-keyboard");
	ok = ok & check(Chead, "classic class 200404", "classic-headset");
	if(ok)
		sys->print("BT: an inquiry found two Classic devices and both names\n");

	#
	# And the cancel.  An inquiry that is left alone finishes by
	# itself, so without starting one in order to stop it nothing
	# here would ever send an Inquiry Cancel; the controller has to
	# be told, and it is the only thing that ends an inquiry early.
	#
	if((e = writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: a second inquiry: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->sleep(300);
	if((e = writefile(mnt + "/0/ctl", "inquiry off")) != nil){
		sys->print("BT: FAILED: inquiry off: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->sleep(500);
	if(!hasstr(readfile(mnt + "/0/state"), "inquiry off"))
		sys->print("BT: FAILED: state still says an inquiry is running\n");
	else
		sys->print("BT: an inquiry was cancelled before it ended\n");
	sys->print("BT: done\n");
}

#
# A BR/EDR link: opened, looked at, and taken down.  Nothing runs over
# it -- L2CAP signalling is a different CID on Classic and there is
# none of it here yet -- so what this asserts is the link itself: that
# it comes up, that the name space says what it is, that it goes away
# when it is told to, and that a page that fails fails.
#
brlink(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	(ok0, nil) := sys->stat(dev);
	if(ok0 < 0){
		sys->print("BT: FAILED: the inquiry did not find %s\n", Chead);
		sys->print("BT: done\n");
		return;
	}

	if(mode == "brincoming"){
		#
		# the peer pages this side.  Nothing here asks for
		# anything: what is asserted is that the link arrived,
		# that it is the peer's and not this side's, and that
		# the name space says so.
		#
		st := "";
		for(i = 0; i < 40; i++){
			sys->sleep(500);
			st = trim(readfile(dev + "/state"));
			if(hasstr(st, "connected"))
				break;
		}
		if(!hasstr(st, "connected") || !hasstr(st, "peripheral")){
			sys->print("BT: FAILED: the peer's link reads %q\n", st);
			sys->print("BT: done\n");
			return;
		}
		sys->print("BT: a peer paged this side: %s\n", st);
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}

	if(mode == "brfail"){
		#
		# the page fails once.  The connect has to fail with it,
		# and the one after it has to work -- a failed attempt
		# that poisons the next one is the bug this shape of
		# test is for.
		#
		if((e = writefile(dev + "/ctl", "connect")) == nil){
			sys->print("BT: FAILED: a page that timed out reported success\n");
			sys->print("BT: done\n");
			return;
		}
		sys->print("BT: the page failed: %s\n", e);
	}
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	st := trim(readfile(dev + "/state"));
	ok := 1;
	if(!hasstr(st, "connected") || !hasstr(st, "central")
	|| !hasstr(st, "br/edr")){
		sys->print("BT: FAILED: the link reads %q\n", st);
		ok = 0;
	} else
		sys->print("BT: %s\n", st);
	if((e = writefile(dev + "/ctl", "disconnect")) != nil){
		sys->print("BT: FAILED: disconnect: %s\n", e);
		ok = 0;
	}
	sys->sleep(500);
	st = trim(readfile(dev + "/state"));
	if(!hasstr(st, "disconnected")){
		sys->print("BT: FAILED: after a disconnect the link reads %q\n", st);
		ok = 0;
	}
	if(ok)
		sys->print("BT: a BR/EDR link, opened and taken down\n");
	sys->print("BT: done\n");
}

#
# A BR/EDR L2CAP channel: basic mode, no credits, one frame one SDU.
# The peer echoes, so what goes down comes back, and the file it comes
# back through is the same one an LE credit-based channel uses -- one
# adt, one pair of files, two very different protocols underneath.
#
Brpsm:	con "1001";

brchan(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	e = writefile(dev + "/ctl", "l2cap " + Brpsm);
	if(mode == "brrefuse"){
		#
		# the peer's own reason has to reach whoever asked, not
		# be flattened into "cannot connect"
		#
		if(e == nil)
			sys->print("BT: FAILED: a refused channel reported success\n");
		else if(!hasstr(e, "PSM not supported"))
			sys->print("BT: FAILED: the refusal reads %q\n", e);
		else
			sys->print("BT: the peer refused the channel: %s\n", e);
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(e != nil){
		sys->print("BT: FAILED: l2cap %s: %s\n", Brpsm, e);
		sys->print("BT: done\n");
		return;
	}
	f := dev + "/l2cap/" + Brpsm;
	ok := 1;
	show(dev + "/state");
	#
	# One write is one SDU and one read is that SDU whole, which is
	# what the file promises on either kind of link.
	#
	want := "a frame on a basic mode channel";
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->print("BT: FAILED: opening the channel: %r\n");
		ok = 0;
	} else if(sys->write(fd, array of byte want, len want) != len want){
		sys->print("BT: FAILED: writing the channel: %r\n");
		ok = 0;
	} else {
		#
		# One read is the next SDU whole and a read with nothing
		# to read waits, so this is time-bounded: a channel that
		# never answers must fail the phase rather than hang it.
		#
		(n, b, re) := sdu(fd, 10000);
		if(re != nil || n <= 0){
			sys->print("BT: FAILED: reading the channel: %s\n", re);
			ok = 0;
		} else if(string b != want){
			sys->print("BT: FAILED: wrote %q and read back %q\n", want, string b);
			ok = 0;
		} else
			sys->print("BT: wrote %d bytes and read them back whole\n", len want);
	}
	fd = nil;
	if((e = writefile(dev + "/ctl", "unl2cap " + Brpsm)) != nil){
		sys->print("BT: FAILED: unl2cap: %s\n", e);
		ok = 0;
	}
	if(ok)
		sys->print("BT: a BR/EDR L2CAP channel, opened and used and closed\n");
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

#
# Service discovery.  A Classic device says what it can do by
# answering an SDP search, and btfs asks as soon as the link is up, so
# by the time connect returns the records are files.
#
sdpphase(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	recs := lsdir(dev + "/sdp");
	sys->print("BT: sdp holds %d records\n", len recs);
	if(mode == "sdpnone"){
		#
		# a device with nothing in the browse group has no sdp
		# directory at all, rather than an empty one that would
		# read as a device that answered with nothing
		#
		if(len recs != 0)
			sys->print("BT: FAILED: a device with no records has %d\n", len recs);
		else
			sys->print("BT: a device with no records has no sdp directory\n");
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	if(len recs != 2){
		sys->print("BT: FAILED: wanted two records\n");
		ok = 0;
	}
	for(rl := recs; rl != nil; rl = tl rl)
		sys->print("BT: record %s\n%s", hd rl, readfile(dev + "/sdp/" + hd rl));
	#
	# What a record is for: the channel number RFCOMM would be
	# opened on, which is in the protocol descriptor list and
	# nowhere else.
	#
	one := readfile(dev + "/sdp/00010000");
	if(!hasstr(one, "class 1101\n") || !hasstr(one, "name Serial Port")
	|| !hasstr(one, "proto rfcomm 1")){
		sys->print("BT: FAILED: the serial port record reads %q\n", one);
		ok = 0;
	}
	two := readfile(dev + "/sdp/00010001");
	if(!hasstr(two, "proto rfcomm 2") || !hasstr(two, "class 1108\n")){
		sys->print("BT: FAILED: the headset record reads %q\n", two);
		ok = 0;
	}
	if(ok)
		sys->print("BT: two service records, with the channel numbers out of them\n");
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

#
# A serial port over RFCOMM, on the channel number an SDP record gave.
#
# Before any of that, the frame check sequence against numbers written
# down outside this tree: SABM on DLCI 0 is 03 3F 01 1C and UA is
# 03 73 01 D7 in every description of RFCOMM there is, and a stack
# that computes those two right has the polynomial, the starting
# value and the complement right.  Everything else in the framing
# rests on it.
#
rfphase(mode: string)
{
	rf := load Rfcomm Rfcomm->PATH;
	if(rf == nil){
		sys->print("BT: FAILED: cannot load %s: %r\n", Rfcomm->PATH);
		sys->print("BT: done\n");
		return;
	}
	if((e := rf->init(bt, nil)) != nil){
		sys->print("BT: FAILED: rfcomm init: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sabm := array[] of {byte 16r03, byte 16r3f, byte 16r01};
	ua := array[] of {byte 16r03, byte 16r73, byte 16r01};
	if(rf->fcs(sabm) != 16r1c || rf->fcs(ua) != 16rd7){
		sys->print("BT: FAILED: the frame check sequence gives %#2.2ux and %#2.2ux, wanted 1c and d7\n",
			rf->fcs(sabm), rf->fcs(ua));
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: the frame check sequence matches the published frames\n");

	if((e = writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	e = writefile(dev + "/ctl", "rfcomm 1");
	if(mode == "rfrefuse"){
		if(e == nil)
			sys->print("BT: FAILED: a refused data link reported success\n");
		else
			sys->print("BT: the peer refused the data link: %s\n", e);
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(e != nil){
		sys->print("BT: FAILED: rfcomm 1: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	f := dev + "/rfcomm/1/data";
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->print("BT: FAILED: opening %s: %r\n", f);
		sys->print("BT: done\n");
		return;
	}
	#
	# The peer echoes in upper case, so what comes back cannot be
	# the write arriving by some other route.
	#
	want := "hello over a serial port";
	if(sys->write(fd, array of byte want, len want) != len want){
		sys->print("BT: FAILED: writing the port: %r\n");
		ok = 0;
	} else {
		#
		# A serial line is a stream: what comes back may arrive
		# in as many pieces as the frame size the peer agreed to
		# needs, so this reads until it has the whole of it
		# rather than assuming one read is one write.
		#
		got := "";
		for(i = 0; i < 20 && len got < len want; i++){
			(n, b, re) := sdu(fd, 10000);
			if(re != nil || n <= 0){
				sys->print("BT: FAILED: reading the port: %s\n", re);
				ok = 0;
				break;
			}
			got += string b[0:n];
		}
		if(ok){
			if(got != upper(want)){
				sys->print("BT: FAILED: wrote %q and read %q\n", want, got);
				ok = 0;
			} else
				sys->print("BT: %q came back as %q\n", want, got);
		}
	}
	fd = nil;
	if((e = writefile(dev + "/ctl", "unrfcomm 1")) != nil){
		sys->print("BT: FAILED: unrfcomm: %s\n", e);
		ok = 0;
	}
	if(ok)
		sys->print("BT: a serial port over RFCOMM, opened and used and closed\n");
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

upper(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'a' && c <= 'z')
			c += 'A' - 'a';
		r[len r] = c;
	}
	return r;
}

#
# Pairing a BR/EDR link.  It is not SMP with different bytes: the
# controller runs it and asks the host questions on the way, so what
# there is to assert from inside the guest is that the link came up
# encrypted and that a key was written down.  What the controller was
# asked and told is asserted on the model's side.
#
sspphase(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	#
	# sspbonded is the same phase with the key already in the store
	# btfs was started on, so the controller asks for one and is
	# given it.  Nothing here has to arrange that: the key file is
	# what carries it, which is the whole reason to write one down.
	#
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	e = writefile(dev + "/ctl", "pair");
	if(mode == "sspfail"){
		if(e == nil)
			sys->print("BT: FAILED: a failed pairing reported success\n");
		else
			sys->print("BT: the pairing failed: %s\n", e);
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(e != nil){
		sys->print("BT: FAILED: pair: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	st := "";
	for(i = 0; i < 20; i++){
		st = trim(readfile(dev + "/state"));
		if(hasstr(st, "encrypted"))
			break;
		sys->sleep(250);
	}
	if(!hasstr(st, "encrypted")){
		sys->print("BT: FAILED: after pairing the link reads %q\n", st);
		ok = 0;
	} else
		sys->print("BT: %s\n", st);
	#
	# and the key: a pairing that agreed one and did not write it
	# down is a device that pairs again every time.
	#
	bonds := readfile(mnt + "/0/bonds");
	if(!hasstr(bonds, "lk 101112131415161718191A1B1C1D1E1F")){
		sys->print("BT: FAILED: the bonds read %q\n", bonds);
		ok = 0;
	} else
		sys->print("BT: the link key was written down\n");
	if(ok)
		sys->print("BT: a BR/EDR link paired and encrypted\n");
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

#
# The same keyboard and mouse over Bluetooth Classic.  The device is
# found with an inquiry, its report descriptor comes out of its
# service record rather than out of a characteristic, and its reports
# arrive on an L2CAP channel with a byte of HIDP header in front --
# and what has to come out the other end is what came out on LE.
#
chidphase(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	recs := lsdir(dev + "/sdp");
	if(len recs != 1){
		sys->print("BT: FAILED: the device offered %d service records\n", len recs);
		sys->print("BT: done\n");
		return;
	}
	rec := readfile(dev + "/sdp/" + hd recs);
	if(!hasstr(rec, "class 1124")){
		sys->print("BT: FAILED: the record is not a HID one: %q\n", rec);
		sys->print("BT: done\n");
		return;
	}
	if(mode == "chidnodesc"){
		#
		# a HID record with no report descriptor in it.  There
		# is nothing to parse and nothing to read, and a host
		# that carried on would be reading reports whose layout
		# it invented.
		#
		if(hasstr(rec, "hiddesc "))
			sys->print("BT: FAILED: a record with no descriptor has one\n");
		else
			sys->print("BT: the record carries no report descriptor\n");
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(!hasstr(rec, "hiddesc ")){
		sys->print("BT: FAILED: the HID record carries no report descriptor\n");
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: a Classic HID record, with a report descriptor in it\n");
	hidcheck(dev);
}

#
# A Bluetooth link as an ethernet.  btpan finds the access point in
# the device's service records, opens the BNEP channel, agrees the
# setup, and then serves the same clone/addr/N/data interface devip's
# ether medium binds to -- so what this phase does is what the IP
# stack would do: take a conversation, ask for an ethertype, write a
# frame and read one.
#
Panmnt:	con "/n/btpan";

panphase(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	pan := load Command "/dis/bt/btpan.dis";
	if(pan == nil){
		sys->print("BT: FAILED: cannot load /dis/bt/btpan.dis: %r\n");
		sys->print("BT: done\n");
		return;
	}
	spawn pan->init(nil, "btpan" :: "-b" :: mnt :: "-m" :: Panmnt :: dev :: nil);
	ok := 0;
	for(i = 0; i < 40 && !ok; i++){
		sys->sleep(500);
		(st, nil) := sys->stat(Panmnt + "/ether/clone");
		ok = st >= 0;
	}
	if(mode == "pannotnap"){
		#
		# the peer will not be an access point and said so.  A
		# host that ignored the answer would serve an interface
		# onto a link that has agreed to nothing.
		#
		if(ok)
			sys->print("BT: FAILED: a refused network was served anyway\n");
		else
			sys->print("BT: a peer that refused the network left no interface\n");
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(!ok){
		sys->print("BT: FAILED: no ethernet interface appeared\n");
		sys->print("BT: done\n");
		return;
	}
	#
	# the interface's own address, which is the controller's: a PAN
	# invents no MAC, it uses the two BD_ADDRs the link already has.
	#
	a := trim(readfile(Panmnt + "/ether/addr"));
	sys->print("BT: the interface's address is %s\n", a);
	if(a != "001122334455"){
		sys->print("BT: FAILED: wanted the controller's own address\n");
		sys->print("BT: done\n");
		return;
	}
	#
	# and a conversation, the way the IP stack takes one: open
	# clone, which is then the conversation's ctl, say which
	# ethertype, and read and write its data.
	#
	cfd := sys->open(Panmnt + "/ether/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("BT: FAILED: opening clone: %r\n");
		sys->print("BT: done\n");
		return;
	}
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0){
		sys->print("BT: FAILED: reading the conversation number: %r\n");
		sys->print("BT: done\n");
		return;
	}
	cn := trim(string buf[0:n]);
	sys->print("BT: conversation %s\n", cn);
	if(sys->fprint(cfd, "connect %d", 16r0806) < 0){
		sys->print("BT: FAILED: connect: %r\n");
		sys->print("BT: done\n");
		return;
	}
	dfd := sys->open(Panmnt + "/ether/" + cn + "/data", Sys->ORDWR);
	if(dfd == nil){
		sys->print("BT: FAILED: opening data: %r\n");
		sys->print("BT: done\n");
		return;
	}
	#
	# An ARP request, which is the first thing a real PAN carries,
	# and it is a real one: broadcast, with the twenty eight bytes
	# ARP is, asking who has 169.254.1.2.
	#
	# It used to be a frame whose ethertype said ARP and whose
	# payload was a counted-up byte pattern, which the far end
	# handed back with its addresses swapped.  Both halves of this
	# bench were happy with that and Wireshark was not: it read the
	# capture and called the packet malformed.  What that phase
	# proved was that twelve bytes could be swapped, which a
	# loopback anywhere along the path would also do.
	#
	# What comes back now is a reply, built by the far end out of
	# the fields of the request.  This side's own write cannot
	# return as one.
	#
	# In the order an ethernet address is written, which is not the
	# order a BD_ADDR goes on an HCI wire: unhex and not straddr.
	#
	me := bt->unhex("001122334455");
	peer := bt->unhex("CCBBAA998877");
	mine := array[] of {byte 169, byte 254, byte 1, byte 1};
	his := array[] of {byte 169, byte 254, byte 1, byte 2};
	f := array[42] of byte;
	f[0:] = bt->unhex("FFFFFFFFFFFF");	# a request is broadcast
	f[6:] = me;
	f[12] = byte 16r08; f[13] = byte 16r06;	# arp
	f[14] = byte 0; f[15] = byte 1;		# over ethernet
	f[16] = byte 16r08; f[17] = byte 0;	# for ip
	f[18] = byte 6; f[19] = byte 4;		# address sizes
	f[20] = byte 0; f[21] = byte 1;		# a request
	f[22:] = me;
	f[28:] = mine;
	f[32:] = array[6] of {* => byte 0};	# unknown, which is the question
	f[38:] = his;
	if(sys->write(dfd, f, len f) != len f){
		sys->print("BT: FAILED: writing a frame: %r\n");
		sys->print("BT: done\n");
		return;
	}
	(rn, rb, re) := sdu(dfd, 10000);
	if(re != nil || rn <= 0){
		sys->print("BT: FAILED: reading a frame: %s\n", re);
		sys->print("BT: done\n");
		return;
	}
	g := rb[0:rn];
	if(rn != len f){
		sys->print("BT: FAILED: sent %d bytes and got %d back\n", len f, rn);
		sys->print("BT: done\n");
		return;
	}
	if(bt->hex(g[0:6]) != "001122334455"
	|| bt->hex(g[6:12]) != "CCBBAA998877"){
		sys->print("BT: FAILED: the frame came back addressed %s to %s\n",
			bt->hex(g[6:12]), bt->hex(g[0:6]));
		sys->print("BT: done\n");
		return;
	}
	#
	# and it is a reply, from the address that was asked about.
	# An echo of the request would still be a request, and would
	# still carry this side's own hardware address as the sender.
	#
	if(int g[20] != 0 || int g[21] != 2){
		sys->print("BT: FAILED: wanted an arp reply, got operation %d\n",
			(int g[20] << 8) | int g[21]);
		sys->print("BT: done\n");
		return;
	}
	if(bt->hex(g[22:28]) != bt->hex(peer) || bt->hex(g[28:32]) != bt->hex(his)){
		sys->print("BT: FAILED: %s answered for %s\n",
			bt->hex(g[22:28]), bt->hex(g[28:32]));
		sys->print("BT: done\n");
		return;
	}
	if(bt->hex(g[32:38]) != bt->hex(me) || bt->hex(g[38:42]) != bt->hex(mine)){
		sys->print("BT: FAILED: the reply is addressed to %s\n",
			bt->hex(g[32:38]));
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: 169.254.1.2 is at %s, which the far end had to build\n",
		bt->hex(g[22:28]));
	sys->print("BT: a Bluetooth link as an ethernet\n");
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

#
# The other way round.  Every other Classic phase has this side asking
# a device for something; here a peer pages this side and asks it what
# it offers, reads the record it gets back, opens the serial port that
# record names, and writes a line down it.
#
# Nothing inside the guest shows most of that, so what this asserts is
# the offer being made and the model's account of what it found.
#
servedphase()
{
	if((e := writefile(mnt + "/0/ctl", "serial 5")) != nil){
		sys->print("BT: FAILED: serial 5: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: offering a serial port on channel 5\n");
	#
	# and again, which must be refused: two owners of one channel
	# is a port whichever of them happens to read
	#
	if(writefile(mnt + "/0/ctl", "serial 5") == nil)
		sys->print("BT: FAILED: the same channel was offered twice\n");
	else
		sys->print("BT: and the same channel cannot be offered twice\n");
	#
	# An inquiry, which is what makes the peer notice this side is
	# there; everything after it is the peer's doing.  The offer
	# above is made first on purpose: a record published after a
	# peer has already asked is a record it will not see.
	#
	if((e = writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i0 := 0; i0 < 40; i0++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	st := "";
	for(i := 0; i < 60; i++){
		sys->sleep(500);
		st = trim(readfile(dev + "/state"));
		if(hasstr(st, "connected"))
			break;
	}
	if(!hasstr(st, "connected")){
		sys->print("BT: FAILED: the peer never paged: %q\n", st);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: %s\n", st);
	sys->sleep(6000);
	sys->print("BT: a peer found what this side offers and opened it\n");
	sys->print("BT: done\n");
}

#
# An audio stream to a sink.  What is tested is the signalling and the
# media channel: find the sink, ask what it will take, pick a
# configuration out of that, configure it, open the second channel to
# the same PSM, start the stream, and send something down it.
#
# What is not tested is the audio, because there is none: A2DP is
# AVDTP plus SBC and there is no SBC on either side of this bench.
# What goes down the media channel is bytes and what the sink does is
# count them.
#
a2dpphase(nil: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	#
	# What goes down the stream is SBC: frames of silence, built
	# for whatever configuration was agreed, by avdtp->sbcsilence.
	#
	# It used to be six hundred counted-up bytes, sent down a
	# channel that had just agreed to SBC, with a comment saying
	# that nothing here pretended they were audio.  They were not
	# audio and they were not SBC either, and the ethertype was
	# not the only place in this bench where a frame said one
	# thing and carried another.  Wireshark read the capture and
	# called them malformed; neither end of this bench had minded.
	#
	# They are still not audio.  A frame of silence is a real SBC
	# frame with real sample bits that happen to be zero, and what
	# is missing is an encoder, which is written down as missing.
	#
	a2 := load Command "/dis/bt/bta2dp.dis";
	if(a2 == nil){
		sys->print("BT: FAILED: cannot load /dis/bt/bta2dp.dis: %r\n");
		sys->print("BT: done\n");
		return;
	}
	#
	# bta2dp says what it agreed and what it sent, and those lines
	# are what the run asserts on: the phase cannot read another
	# program's output, and what matters here is what was chosen
	# rather than that something was.
	#
	a2->init(nil, "bta2dp" :: "-b" :: mnt :: "-d" :: dev :: "-s" :: "5" :: nil);
	sys->sleep(1000);
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

#
# A telephone as files.  bthfp finds the gateway in the device's
# service records, opens the RFCOMM channel the record names, does the
# service level connection, and serves the indicators; the phase then
# reads them, waits for the call the gateway makes, answers it, and
# watches the call indicator move.
#
# There is no audio in any of it, and that is the point of what is
# left out: a call can be seen, placed, answered and ended, and not
# heard.
#
Hfpmnt:	con "/n/bthfp";

hfpphase(mode: string)
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	dev := mnt + "/0/remote/" + Chead;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	hf := load Command "/dis/bt/bthfp.dis";
	if(hf == nil){
		sys->print("BT: FAILED: cannot load /dis/bt/bthfp.dis: %r\n");
		sys->print("BT: done\n");
		return;
	}
	spawn hf->init(nil, "bthfp" :: "-b" :: mnt :: "-m" :: Hfpmnt :: dev :: nil);
	up := 0;
	for(i = 0; i < 40 && !up; i++){
		sys->sleep(500);
		(st, nil) := sys->stat(Hfpmnt + "/status");
		up = st >= 0;
	}
	if(mode == "hfpnoslc"){
		#
		# a gateway that will not say what its indicators are.
		# A unit that carried on would be reading numbers whose
		# meaning it invented.
		#
		if(up)
			sys->print("BT: FAILED: a refused handshake served an interface anyway\n");
		else
			sys->print("BT: a gateway that would not say left no interface\n");
		writefile(dev + "/ctl", "disconnect");
		sys->print("BT: done\n");
		return;
	}
	if(!up){
		sys->print("BT: FAILED: no telephone appeared\n");
		sys->print("BT: done\n");
		return;
	}
	#
	# the indicators, in the gateway's own order.  This gateway
	# reports call first and service second, which is not the usual
	# order: a unit that assumed one would have them swapped.
	#
	st := readfile(Hfpmnt + "/status");
	sys->print("BT: the telephone says\n%s", st);
	ok := 1;
	if(!hasstr(st, "call 0") || !hasstr(st, "service 1")
	|| !hasstr(st, "battchg 4")){
		sys->print("BT: FAILED: the indicators read %q\n", st);
		ok = 0;
	}
	#
	# it rings, which arrives on its own and not in answer to
	# anything
	#
	efd := sys->open(Hfpmnt + "/event", Sys->OREAD);
	if(efd == nil){
		sys->print("BT: FAILED: opening event: %r\n");
		sys->print("BT: done\n");
		return;
	}
	(n, b, re) := sdu(efd, 10000);
	if(re != nil || n <= 0){
		sys->print("BT: FAILED: waiting for the telephone: %s\n", re);
		ok = 0;
	} else {
		ev := trim(string b[0:n]);
		sys->print("BT: the telephone says %q\n", ev);
		if(ev != "RING"){
			sys->print("BT: FAILED: wanted RING\n");
			ok = 0;
		}
	}
	#
	# and answering it moves the call indicator, which is what a
	# hands free unit watches rather than the answer to its own
	# command
	#
	if((e = writefile(Hfpmnt + "/ctl", "answer")) != nil){
		sys->print("BT: FAILED: answer: %s\n", e);
		ok = 0;
	}
	(n, b, re) = sdu(efd, 10000);
	if(re != nil || n <= 0){
		sys->print("BT: FAILED: nothing came of answering: %s\n", re);
		ok = 0;
	} else {
		ev := trim(string b[0:n]);
		sys->print("BT: the telephone says %q\n", ev);
		if(ev != "call 1"){
			sys->print("BT: FAILED: wanted the call indicator to move\n");
			ok = 0;
		}
	}
	st = readfile(Hfpmnt + "/status");
	if(!hasstr(st, "call 1")){
		sys->print("BT: FAILED: after answering the status reads %q\n", st);
		ok = 0;
	}
	if(ok)
		sys->print("BT: a telephone answered, out of the name space\n");
	efd = nil;
	writefile(dev + "/ctl", "disconnect");
	sys->print("BT: done\n");
}

check(dir, want, name: string): int
{
	d := mnt + "/0/remote/" + dir;
	t := trim(readfile(d + "/type"));
	if(t != want){
		sys->print("BT: FAILED: %s type reads %q, wanted %q\n", dir, t, want);
		return 0;
	}
	#
	# The name may still be on its way: one of these is paged for,
	# and a page takes as long as it takes.
	#
	n := "";
	for(i := 0; i < 20 && n != name; i++){
		n = trim(readfile(d + "/name"));
		if(n != name)
			sys->sleep(500);
	}
	if(n != name){
		sys->print("BT: FAILED: %s name reads %q, wanted %q\n", dir, n, name);
		return 0;
	}
	return 1;
}

#
# btkeyfs(4) by itself.  Nothing here is a radio: it is the store, and
# what is checked is that a bond written to it comes back, that the
# same peer on two controllers is two bonds, that writing one again
# replaces rather than doubles it, and that forgetting names a peer on
# a controller and not just a peer.
#
Ka:	con "060504030201 random ltk 000102030405060708090A0B0C0D0E0F ediv 4660 rand 0001020304050607 irk 101112131415161718191A1B1C1D1E1F csrk 202122232425262728292A2B2C2D2E2F on 001122334455";
Kb:	con "060504030201 random ltk FFEEDDCCBBAA99887766554433221100 ediv 1 rand 0706050403020100 irk 101112131415161718191A1B1C1D1E1F csrk 202122232425262728292A2B2C2D2E2F on 001122334466";

keysphase()
{
	ctl := Keymnt + "/ctl";
	bonds := Keymnt + "/bonds";
	ok := 1;

	if((e := writefile(ctl, "bond " + Ka)) != nil){
		sys->print("BT: FAILED: writing a bond: %s\n", e);
		return;
	}
	if((e = writefile(ctl, "bond " + Kb)) != nil){
		sys->print("BT: FAILED: writing a second bond: %s\n", e);
		return;
	}
	if((n := len lines(readfile(bonds))) != 2){
		sys->print("BT: FAILED: the same peer on two controllers reads as %d bonds, wanted 2\n", n);
		ok = 0;
	}
	#
	# again, unchanged.  A store that appended would now hold four,
	# and every one of them would be offered to the same radio.
	#
	writefile(ctl, "bond " + Ka);
	if((n = len lines(readfile(bonds))) != 2){
		sys->print("BT: FAILED: writing a bond twice made %d of them\n", n);
		ok = 0;
	}
	#
	# a bond that says nothing a key does is not a bond, and taking
	# it would be a peer that looks paired and cannot encrypt
	#
	if(writefile(ctl, "bond 060504030201 public") == nil){
		sys->print("BT: FAILED: a line with no key was taken as a bond\n");
		ok = 0;
	}
	if(writefile(ctl, "eat 060504030201") == nil){
		sys->print("BT: FAILED: an unknown control message was accepted\n");
		ok = 0;
	}
	#
	# forgetting on one controller is not forgetting on the other
	#
	if((e = writefile(ctl, "forget 060504030201 on 001122334455")) != nil){
		sys->print("BT: FAILED: forget: %s\n", e);
		ok = 0;
	}
	l := lines(readfile(bonds));
	if(len l != 1 || hd l != Kb){
		sys->print("BT: FAILED: after forgetting one, the store holds %d bonds\n", len l);
		for(; l != nil; l = tl l)
			sys->print("BT:   %s\n", hd l);
		ok = 0;
	}
	if(writefile(ctl, "forget 001122334455") == nil){
		sys->print("BT: FAILED: forgetting a peer that is not there succeeded\n");
		ok = 0;
	}
	#
	# and what is on disk is what was served: a store that answered
	# from memory and never wrote would lose everything on restart,
	# and nothing above here could tell
	#
	f := lines(readfile(keysfile));
	if(len f != 1 || hd f != Kb){
		sys->print("BT: FAILED: the store's file holds %d bonds, wanted the one left\n", len f);
		ok = 0;
	}
	if(writefile(ctl, "forget 060504030201") != nil || len lines(readfile(bonds)) != 0){
		sys->print("BT: FAILED: forgetting without naming a controller left something\n");
		ok = 0;
	}
	if(ok)
		sys->print("BT: the key service keeps a bond per peer per controller, and writes it down\n");
	sys->print("BT: done\n");
}

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
	for(i := 0; i + len w <= len s; i++){
		if(s[i:i+len w] != w)
			continue;
		# a whole word: "connections 1" must not match
		# "connections 10"
		if(i > 0 && s[i-1] != ' ')
			continue;
		if(i + len w < len s && s[i + len w] != ' ')
			continue;
		return 1;
	}
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


#
# LE credit-based channels.  Everything above this in the bench moves
# a handful of bytes through an attribute; this is the path that moves
# a block of them, and the only one that is flow controlled.
#
# The pattern written is a counted one, not a repeated one: a
# reassembly that put the segments back in the wrong order, or lost
# one and slid the rest along, produces something that is still 512
# bytes long and still looks like the pattern.  Comparing byte for
# byte against what was sent is what catches that.
#
Cocsize:	con 512;

pattern(n: int): array of byte
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte ((i * 7 + (i / 251) * 31) & 16rff);
	return a;
}

samebytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

cocdev(): string
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil)
		return nil;
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		return nil;
	}
	return dev;
}

cocphase(mode: string)
{
	dev := cocdev();
	if(dev == nil){
		sys->print("BT: FAILED: nothing to connect to\n");
		sys->print("BT: done\n");
		return;
	}
	ok := 1;
	if((e := writefile(dev + "/ctl", "l2cap 0080")) != nil){
		sys->print("BT: FAILED: l2cap 0080: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	st := trim(readfile(dev + "/state"));
	if(!hasword(st, "psm") || !hasword(st, "0x0080")){
		sys->print("BT: FAILED: state does not name the channel: %s\n", st);
		ok = 0;
	} else
		sys->print("BT: state: %s\n", st);

	#
	# the file is the channel: one write is one SDU and one read is
	# the next one whole
	#
	f := dev + "/l2cap/0080";
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->print("BT: FAILED: cannot open %s: %r\n", f);
		sys->print("BT: done\n");
		return;
	}
	out := pattern(Cocsize);
	if(sys->write(fd, out, len out) != len out){
		sys->print("BT: FAILED: writing %d bytes: %r\n", len out);
		ok = 0;
	} else
		sys->print("BT: wrote an SDU of %d bytes\n", len out);
	(n, back, re) := sdu(fd, 15000);
	if(n < 0 && re == nil){
		sys->print("BT: FAILED: the SDU never came back\n");
		ok = 0;
	} else if(n < 0){
		sys->print("BT: FAILED: reading it back: %s\n", re);
		ok = 0;
	} else if(!samebytes(back, out)){
		sys->print("BT: FAILED: %d bytes back and they are not what went out\n", n);
		ok = 0;
	} else
		sys->print("BT: read back %d bytes, the same ones\n", n);

	#
	# a second SDU on the same channel, so the credits given back
	# for the first are the ones that carry the second
	#
	out2 := pattern(200);
	if(sys->write(fd, out2, len out2) != len out2){
		sys->print("BT: FAILED: second write: %r\n");
		ok = 0;
	}
	(n, back, re) = sdu(fd, 15000);
	if(n < 0 || !samebytes(back, out2)){
		sys->print("BT: FAILED: the second SDU came back wrong\n");
		ok = 0;
	} else
		sys->print("BT: a second SDU of %d bytes went and came back\n", n);
	fd = nil;

	if((ue := writefile(dev + "/ctl", "unl2cap 0080")) != nil){
		sys->print("BT: FAILED: unl2cap: %s\n", ue);
		ok = 0;
	}
	if((fd2 := sys->open(f, Sys->OREAD)) != nil){
		sys->print("BT: FAILED: the file is still there after unl2cap\n");
		ok = 0;
	} else
		sys->print("BT: the channel closed and its file went with it\n");
	fd2 = nil;
	st = trim(readfile(dev + "/state"));
	if(hasword(st, "psm")){
		sys->print("BT: FAILED: state still names a channel: %s\n", st);
		ok = 0;
	}
	if(ok)
		sys->print("BT: %s: an SDU went out segmented and came back whole\n", mode);
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# A PSM nobody answers on.  The peer's own reason has to come back to
# whoever asked; a stack that reports "cannot connect" has thrown away
# the one piece of information the peer sent.
#
cocrefuse()
{
	dev := cocdev();
	if(dev == nil){
		sys->print("BT: FAILED: nothing to connect to\n");
		sys->print("BT: done\n");
		return;
	}
	e := writefile(dev + "/ctl", "l2cap 00ff");
	if(e == nil)
		sys->print("BT: FAILED: a PSM nobody answers on opened anyway\n");
	else if(!hasword(e, "PSM"))
		sys->print("BT: FAILED: refused, but as: %s\n", e);
	else
		sys->print("BT: refused, in the peer's words: %s\n", e);
	if((fd := sys->open(dev + "/l2cap/00ff", Sys->OREAD)) != nil)
		sys->print("BT: FAILED: a refused channel left a file behind\n");
	fd = nil;
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# The peer breaks the rules: a segment it had no credit for, or an SDU
# longer than the MTU this side asked for.  Either is a protocol
# violation and the channel has to go down and say why.  Absorbing it
# is the failure being tested for -- a receiver that takes a segment
# it did not pay for has no bound on its buffers at all.
#
cocbad(mode: string)
{
	want := "credit";
	if(mode == "cocbig")
		want = "MTU";
	ok := 1;
	dev := cocdev();
	if(dev == nil){
		sys->print("BT: FAILED: nothing to connect to\n");
		sys->print("BT: done\n");
		return;
	}
	if((e := writefile(dev + "/ctl", "l2cap 0080")) != nil){
		sys->print("BT: FAILED: l2cap 0080: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	f := dev + "/l2cap/0080";
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->print("BT: FAILED: cannot open %s: %r\n", f);
		sys->print("BT: done\n");
		return;
	}
	out := pattern(64);
	sys->write(fd, out, len out);
	#
	# Nothing is read for a moment on purpose.  A credit goes back to
	# the peer when a reader takes the SDU that spent it, so a reader
	# running beside the peer's burst hands back the very credits the
	# burst is meant to exhaust, and whether the last segment is paid
	# for or not comes down to timing.  Letting the burst finish
	# first makes the overrun the certainty it is supposed to be.
	#
	sys->sleep(3000);
	#
	# Everything the peer sent while it still had credit is
	# legitimate and arrives; the channel goes down on what follows
	# it.  So this reads until it fails rather than a fixed number
	# of times -- the number the peer sent is the number of credits
	# this side granted, which is not written down here.
	#
	#
	# The reads are done in a separate process and waited for with a
	# timer, because a channel that has not noticed the violation
	# does not fail the read -- it blocks on a reassembly that will
	# never finish.  Waiting for ever turns a wrong answer into a
	# hung bench, which says the same thing far less clearly and
	# four minutes later.
	#
	why := "";
	got := 0;
	for(i := 0; i < 200; i++){
		(n, nil, re) := sdu(fd, 10000);
		if(n < 0 && re == nil){
			sys->print("BT: %s: a read waited ten seconds and neither returned data nor failed\n", mode);
			break;
		}
		if(n < 0){
			why = re;
			break;
		}
		got++;
	}
	sys->print("BT: %d SDUs arrived before the channel went down: %s\n", got, why);
	if(why == ""){
		sys->print("BT: FAILED: %s: the channel never went down\n", mode);
		ok = 0;
	} else if(!hasword(why, want)){
		sys->print("BT: FAILED: %s: it went down as %q, wanted %q in it\n",
			mode, why, want);
		ok = 0;
	}
	#
	# The file is the channel, so a channel L2CAP took down must
	# take its file with it.  A file left behind whose every read
	# fails for ever is not an open channel, and btfs(4) says a file
	# here is one.
	#
	if((fd2 := sys->open(f, Sys->ORDWR)) != nil){
		sys->print("BT: FAILED: %s: the dead channel left its file behind\n", mode);
		ok = 0;
	} else
		sys->print("BT: %s: the channel went and took its file\n", mode);
	fd2 = nil;
	st := trim(readfile(dev + "/state"));
	if(hasword(st, "psm")){
		sys->print("BT: FAILED: %s: state still names it: %s\n", mode, st);
		ok = 0;
	} else
		sys->print("BT: %s: state no longer names it\n", mode);
	if(ok)
		sys->print("BT: %s: the channel went down for the right reason\n", mode);
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}


#
# One read, in its own process, so the bench can put a timer beside
# it.  A channel that has not noticed what it should have noticed does
# not fail the read -- it blocks on something that will never arrive
# -- and waiting for ever turns a wrong answer into a hung bench,
# which says the same thing far less clearly and four minutes later.
#
# The three answers are apart: bytes, a failure with a reason, and
# nothing at all.
#
onesdu(fd: ref Sys->FD, c: chan of (int, array of byte, string))
{
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0){
		c <-= (-1, nil, sys->sprint("%r"));
		return;
	}
	c <-= (n, buf[0:n], nil);
}

sdu(fd: ref Sys->FD, ms: int): (int, array of byte, string)
{
	#
	# Both buffered by one.  Whichever of the two loses the race
	# still has its answer to put down, and an unbuffered channel
	# would leave it blocked on a send nobody will ever take -- a
	# process leaked per read, which over a phase that reads two
	# hundred times is a hundred processes sitting in the scheduler
	# for no reason.  hci.b says the same thing about its command
	# timer; this is the same mistake in a new place.
	#
	c := chan[1] of (int, array of byte, string);
	spawn onesdu(fd, c);
	tc := chan[1] of int;
	spawn tick(ms, tc);
	alt {
	(n, b, e) := <-c =>
		return (n, b, e);
	<-tc =>
		return (-1, nil, nil);
	}
}

tick(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

#
# Two controllers in one btfs.  /net/bt/0 used to have the 0 written
# into it, so this is the phase that says the number came from
# somewhere.
#
# What it is really testing is not that two directories appear -- that
# would pass however much the two radios shared.  It is that a bond
# belongs to the radio it was made on.  Both models present the same
# peripheral rotating the same resolvable private address; the key
# file says the bond was made on the first radio's address, and the
# second radio has a different one.  So the first must resolve the
# device to its identity and the second must not, and a stack with one
# shared bond list passes on the first radio and fails here.
#
Sensorid:	con "060504030201";

twophase()
{
	ok := 1;
	a0 := trim(readfile(mnt + "/0/addr"));
	a1 := trim(readfile(mnt + "/1/addr"));
	if(a0 == "" || a1 == ""){
		sys->print("BT: FAILED: two controllers were asked for and %q, %q came back\n", a0, a1);
		sys->print("BT: done\n");
		return;
	}
	if(a0 == a1){
		sys->print("BT: FAILED: both radios report %s\n", a0);
		ok = 0;
	} else
		sys->print("BT: two radios: %s and %s\n", a0, a1);

	#
	# scanning is the radio's own state, not the program's
	#
	if(trim(readfile(mnt + "/1/scan")) != "off"){
		sys->print("BT: FAILED: scanning one radio turned the other on\n");
		ok = 0;
	} else
		sys->print("BT: the second radio is not scanning because the first is\n");

	b0 := lines(readfile(mnt + "/0/bonds"));
	b1 := lines(readfile(mnt + "/1/bonds"));
	if(b0 == nil){
		sys->print("BT: FAILED: the first radio loaded no bond from the key file\n");
		ok = 0;
	} else
		sys->print("BT: the first radio's bond: %s\n", hd b0);
	if(b1 != nil){
		sys->print("BT: FAILED: the bond made on one radio was given to the other: %s\n", hd b1);
		ok = 0;
	} else
		sys->print("BT: the second radio has no bond, which is whose it is not\n");

	if((e := writefile(mnt + "/1/ctl", "scan on")) != nil)
		sys->print("BT: scan on 1: %s\n", e);
	sys->sleep(4000);

	#
	# Both radios have heard the sensor's identity address plainly:
	# it advertises from it for the first few rounds and only then
	# starts rotating.  So the directory being there proves nothing,
	# and what it resolved to is the whole question.  The radio with
	# the bond folds every rotation back onto the one directory; the
	# radio without one gains a new stranger every round.
	#
	r0 := lsdir(mnt + "/0/remote");
	r1 := lsdir(mnt + "/1/remote");
	sys->print("BT: radio 0 sees %d devices, radio 1 sees %d\n", len r0, len r1);
	if(!listed(r0, Sensorid)){
		sys->print("BT: FAILED: the radio with the bond did not resolve the sensor\n");
		ok = 0;
	}
	i0 := trim(readfile(mnt + "/0/remote/" + Sensorid + "/identity"));
	if(!hasword(i0, "resolved")){
		sys->print("BT: FAILED: radio 0's sensor identity reads %q\n", i0);
		ok = 0;
	} else
		sys->print("BT: radio 0: %s\n", i0);
	i1 := trim(readfile(mnt + "/1/remote/" + Sensorid + "/identity"));
	if(i1 != "none"){
		sys->print("BT: FAILED: radio 1 has no bond and its sensor identity reads %q\n", i1);
		ok = 0;
	} else
		sys->print("BT: radio 1: the sensor has no identity there, which is right\n");
	if(len r1 <= len r0){
		sys->print("BT: FAILED: the radio with no bond did not gain a directory per rotation: %d against %d\n",
			len r1, len r0);
		ok = 0;
	} else
		sys->print("BT: radio 1 gained %d strangers where radio 0 kept %d devices\n",
			len r1, len r0);

	#
	# and the link is the radio's: connecting on the second one
	# works and says so in that radio's own state
	#
	dev := mnt + "/1/remote/345678ABCDEF";
	if((ce := writefile(mnt + "/1/ctl", "connect 345678ABCDEF")) != nil){
		sys->print("BT: FAILED: connect on the second radio: %s\n", ce);
		ok = 0;
	} else {
		st := trim(readfile(dev + "/state"));
		if(!hasword(st, "connected")){
			sys->print("BT: FAILED: second radio's device state: %s\n", st);
			ok = 0;
		} else
			sys->print("BT: connected through the second radio: %s\n", st);
		s0 := trim(readfile(mnt + "/0/state"));
		if(!hasword(s0, "connections") || hasword(s0, "connections 1")){
			sys->print("BT: FAILED: the first radio counts the second's link: %s\n", s0);
			ok = 0;
		} else
			sys->print("BT: the first radio's state is its own: %s\n", s0);
		writefile(dev + "/ctl", "disconnect");
	}

	if(ok)
		sys->print("BT: two controllers, each with its own devices and its own bonds\n");
	writefile(mnt + "/0/ctl", "scan off");
	writefile(mnt + "/1/ctl", "scan off");
	sys->print("BT: done\n");
}

listed(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

#
# The other half of Bluetooth: being found, and being connected to.
# Everything above this in the bench has the stack opening links; this
# is the stack advertising and a peer opening one to it.
#
# What is not here is anything above L2CAP on that link.  There is no
# GATT server yet, so a peer that goes on to ask for attributes gets
# no answer.  The phase says what is real -- the advertisement, the
# link, the direction it was opened from -- and does not pretend the
# rest.
#
Peerin:	con "0000DEADBEEF";

peripheral()
{
	ok := 1;
	if((e := writefile(mnt + "/0/ctl", "advname inferno-bt")) != nil){
		sys->print("BT: FAILED: advname: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	if((ae := writefile(mnt + "/0/ctl", "advertise on")) != nil){
		sys->print("BT: FAILED: advertise on: %s\n", ae);
		sys->print("BT: done\n");
		return;
	}
	st := trim(readfile(mnt + "/0/state"));
	#
	# "advertise on" and not merely "on": scanning is on too, and a
	# test that matched either word would pass with advertising off.
	#
	if(!hasstr(st, "advertise on")){
		sys->print("BT: FAILED: state does not say it is advertising: %s\n", st);
		ok = 0;
	} else
		sys->print("BT: %s\n", st);

	#
	# the peer connects.  It takes a couple of seconds to decide,
	# and then holds the link for a few more.
	#
	dev := mnt + "/0/remote/" + Peerin;
	got := 0;
	for(i := 0; i < 20 && !got; i++){
		sys->sleep(500);
		s := trim(readfile(dev + "/state"));
		if(hasword(s, "connected"))
			got = 1;
	}
	if(!got){
		sys->print("BT: FAILED: nothing connected to us\n");
		ok = 0;
	} else {
		s := trim(readfile(dev + "/state"));
		if(!hasword(s, "peripheral")){
			sys->print("BT: FAILED: connected, but not as the peripheral: %s\n", s);
			ok = 0;
		} else
			sys->print("BT: a peer opened a link to us: %s\n", s);
		#
		# and it is this side's controller that says so, not a
		# guess: the link is in the count of connections
		#
		cs := trim(readfile(mnt + "/0/state"));
		if(!hasword(cs, "connections") || hasword(cs, "connections 0")){
			sys->print("BT: FAILED: the controller counts no connection: %s\n", cs);
			ok = 0;
		}
	}

	#
	# the peer closes it, and the name space follows
	#
	gone := 0;
	for(j := 0; j < 30 && !gone; j++){
		sys->sleep(500);
		s := trim(readfile(dev + "/state"));
		if(hasword(s, "disconnected:"))
			gone = 1;
	}
	if(!gone){
		sys->print("BT: FAILED: the peer closed the link and the tree did not notice: %s\n",
			trim(readfile(dev + "/state")));
		ok = 0;
	} else
		sys->print("BT: the peer closed it: %s\n", trim(readfile(dev + "/state")));

	if((oe := writefile(mnt + "/0/ctl", "advertise off")) != nil){
		sys->print("BT: FAILED: advertise off: %s\n", oe);
		ok = 0;
	}
	st = trim(readfile(mnt + "/0/state"));
	if(!hasstr(st, "advertise off")){
		sys->print("BT: FAILED: still advertising: %s\n", st);
		ok = 0;
	}
	if(ok)
		sys->print("BT: advertised, was found, and was connected to\n");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}


hasstr(s, w: string): int
{
	for(i := 0; i + len w <= len s; i++)
		if(s[i:i+len w] == w)
			return 1;
	return 0;
}

#
# The GATT server, driven by this stack's own GATT client.
#
# The controller model is a wire for this phase and nothing else: the
# guest opens a link out to it, it opens a link in to the guest, and
# every L2CAP frame on one comes out on the other.  So what walks the
# database this side serves is gatt.b -- the client twenty other
# phases already trust -- and not a second implementation written in
# Python from the same reading of the specification as the first.  Two
# implementations written in one place can share a mistake and agree
# with each other; a wire cannot.
#
# The two links are two devices in the name space, on the same
# controller: the one this side dialled, and the one that arrived.
#
Svcuuid:	con "180f";		# battery service
Chruuid:	con "2a19";		# battery level
Longuuid:	con "2a29";		# manufacturer name, long enough to blob
Latesvc:	con "181a";		# environmental sensing, added later
Latechr:	con "2a6e";		# temperature

server()
{
	ok := 1;
	#
	# the database, before anything connects: handles are given out
	# as attributes are added and a peer that connected first would
	# hold a stale picture of it
	#
	cmds := list of {
		"service " + Svcuuid,
		"characteristic " + Svcuuid + " " + Chruuid + " rn",
		"characteristic " + Svcuuid + " " + Longuuid + " rw",
	};
	for(cl := cmds; cl != nil; cl = tl cl)
		if((e := writefile(mnt + "/0/ctl", hd cl)) != nil){
			sys->print("BT: FAILED: %s: %s\n", hd cl, e);
			sys->print("BT: done\n");
			return;
		}
	#
	# the values a peer will read.  The second is longer than the
	# 23 byte default MTU on purpose, so reading it back has to go
	# through Read Blob and not only Read.
	#
	if((ve := writefile(mnt + "/0/gatt/" + Svcuuid + "/" + Chruuid, "77")) != nil){
		sys->print("BT: FAILED: setting %s: %s\n", Chruuid, ve);
		sys->print("BT: done\n");
		return;
	}
	#
	# Longer than the ATT MTU on purpose, and by enough: the MTU is
	# negotiated up to 247, so a value of a few dozen bytes fits in
	# one Read and never reaches Read Blob at all.  The content
	# varies along its length, so a blob that came back from the
	# wrong offset is a value that does not compare equal rather
	# than one that happens to.
	#
	long := "";
	for(k := 0; k < 40; k++)
		long += sys->sprint("%d-inferno-peripheral ", k);
	if((le := writefile(mnt + "/0/gatt/" + Svcuuid + "/" + Longuuid, long)) != nil){
		sys->print("BT: FAILED: setting %s: %s\n", Longuuid, le);
		sys->print("BT: done\n");
		return;
	}

	if((ne := writefile(mnt + "/0/ctl", "advname inferno-bt")) != nil){
		sys->print("BT: FAILED: advname: %s\n", ne);
		sys->print("BT: done\n");
		return;
	}
	if((ae := writefile(mnt + "/0/ctl", "advertise on")) != nil){
		sys->print("BT: FAILED: advertise on: %s\n", ae);
		sys->print("BT: done\n");
		return;
	}

	#
	# wait for the peer's link, then dial back out to it.  The wire
	# joins the two, so what this side dials is its own server.
	#
	inn := mnt + "/0/remote/" + Peerin;
	got := 0;
	for(i := 0; i < 20 && !got; i++){
		sys->sleep(500);
		if(hasword(trim(readfile(inn + "/state")), "connected"))
			got = 1;
	}
	if(!got){
		sys->print("BT: FAILED: nothing connected to us\n");
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: the peer is here: %s\n", trim(readfile(inn + "/state")));

	remotes := lsdir(mnt + "/0/remote");
	out := "";
	for(rl := remotes; rl != nil; rl = tl rl)
		if(hd rl != Peerin)
			out = hd rl;
	if(out == ""){
		sys->print("BT: FAILED: nothing to dial out to\n");
		sys->print("BT: done\n");
		return;
	}
	dev := mnt + "/0/remote/" + out;
	if((ce := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect %s: %s\n", out, ce);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: dialled %s, which the wire joins to our own server\n", out);

	#
	# and now the client's view of the server, walked by gatt.b
	#
	svcs := lsdir(dev + "/gatt");
	found := 0;
	for(sl := svcs; sl != nil; sl = tl sl)
		if(hd sl == Svcuuid)
			found = 1;
	if(!found){
		sys->print("BT: FAILED: the client did not discover %s among %d services\n",
			Svcuuid, len svcs);
		ok = 0;
	} else
		sys->print("BT: the client discovered %s\n", Svcuuid);

	v := trim(readfile(dev + "/gatt/" + Svcuuid + "/" + Chruuid));
	if(v != "77"){
		sys->print("BT: FAILED: %s reads %q, wanted 77\n", Chruuid, v);
		ok = 0;
	} else
		sys->print("BT: %s reads %s, out of our own name space\n", Chruuid, v);

	#
	# the long one, which does not fit in one Read and comes back
	# through Read Blob
	#
	lv := trim(readfile(dev + "/gatt/" + Svcuuid + "/" + Longuuid));
	if(lv != long){
		sys->print("BT: FAILED: the long value reads %q\n", lv);
		ok = 0;
	} else
		sys->print("BT: the %d byte value came back whole, through Read Blob\n", len lv);

	#
	# and a handle nobody has: the server has to say so rather than
	# answer with whatever is nearest
	#
	if((fd := sys->open(dev + "/gatt/" + Svcuuid + "/2a00", Sys->OREAD)) != nil){
		sys->print("BT: FAILED: a characteristic nobody serves is there\n");
		ok = 0;
	}
	fd = nil;

	#
	# a peer writing.  What it wrote is what the file on this side
	# reads afterwards -- the same value seen from the two ends.
	#
	wrote := "written by the peer";
	if((we := writefile(dev + "/gatt/" + Svcuuid + "/" + Longuuid, wrote)) != nil){
		sys->print("BT: FAILED: the client could not write it: %s\n", we);
		ok = 0;
	} else {
		back := trim(readfile(mnt + "/0/gatt/" + Svcuuid + "/" + Longuuid));
		if(back != wrote){
			sys->print("BT: FAILED: the peer wrote %q and our file reads %q\n",
				wrote, back);
			ok = 0;
		} else
			sys->print("BT: the peer wrote it and our own file reads: %s\n", back);
	}
	#
	# A characteristic a peer may not write.  What this shows is
	# only that the tree does not offer the write -- btfs gives a
	# read-only characteristic mode 0444, so it never leaves the
	# guest.  That the *server* refuses one is a different claim and
	# a well behaved client cannot make it; scripts/btbench.sh
	# checks it by having the model write such an attribute itself
	# and looking at what came back.
	#
	if((re := writefile(dev + "/gatt/" + Svcuuid + "/" + Chruuid, "no")) == nil){
		sys->print("BT: FAILED: a read-only characteristic took a write\n");
		ok = 0;
	} else
		sys->print("BT: the tree does not offer the write: %s\n", re);

	#
	# and notifications: the client subscribes, this side sets the
	# value, and it arrives.  Both halves are this stack's own, so
	# what is being tested is that they agree over a wire.
	#
	nfd := sys->open(dev + "/gatt/" + Svcuuid + "/" + Chruuid + ".notify", Sys->OREAD);
	if(nfd == nil){
		sys->print("BT: FAILED: cannot subscribe: %r\n");
		ok = 0;
	} else {
		sys->sleep(500);
		writefile(mnt + "/0/gatt/" + Svcuuid + "/" + Chruuid, "88");
		(n2, nv, nerr) := sdu(nfd, 10000);
		if(n2 < 0 && nerr == nil){
			sys->print("BT: FAILED: no notification arrived\n");
			ok = 0;
		} else if(n2 < 0){
			sys->print("BT: FAILED: the notification stream failed: %s\n", nerr);
			ok = 0;
		} else if(string nv != "88"){
			sys->print("BT: FAILED: the notification carried %q\n", string nv);
			ok = 0;
		} else
			sys->print("BT: the client was notified: %s\n", string nv);
	}
	nfd = nil;

	#
	# And the database grows under the connected peer.  Handles are
	# never given out twice, so what the client already holds stays
	# right; what it has not seen it is told about by the Service
	# Changed indication, and it walks the database again.  Both
	# halves of that are this stack's own, joined by the wire.
	#
	if((se := writefile(mnt + "/0/ctl", "service " + Latesvc)) != nil){
		sys->print("BT: FAILED: adding a service under a live link: %s\n", se);
		ok = 0;
	} else {
		writefile(mnt + "/0/ctl", "characteristic " + Latesvc + " " + Latechr + " r");
		writefile(mnt + "/0/gatt/" + Latesvc + "/" + Latechr, "late");
		#
		# Wait for the characteristic and not for its service
		# directory.  The service and the characteristic are two
		# additions and each announces itself, so the client
		# rediscovers twice; after the first the directory is
		# there and empty, and a test that stopped at the
		# directory would read the file in the gap between them
		# and call it a failure.
		#
		grew := 0;
		lval := "";
		for(g := 0; g < 40 && !grew; g++){
			sys->sleep(500);
			lval = trim(readfile(dev + "/gatt/" + Latesvc + "/" + Latechr));
			if(lval == "late")
				grew = 1;
		}
		if(!grew){
			sys->print("BT: FAILED: the service added later never reached the client: %s\n",
				lval);
			ok = 0;
		} else
			sys->print("BT: the database grew and the client followed: %s reads %s\n",
				Latechr, lval);
	}

	if(ok)
		sys->print("BT: our own client walked our own server\n");
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "advertise off");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}


# the long term key out of a line of /net/bt/N/bonds
keyof(s: string): string
{
	(nil, f) := sys->tokenize(s, " \t");
	for(; f != nil; f = tl f){
		if(hd f != "ltk")
			continue;
		if(tl f == nil)
			break;
		return hd tl f;
	}
	return "";
}

#
# A peer pairing with us: the responder half of SMP, which nothing
# else in this bench reaches.
#
# The loopback cannot test this, and the reason is worth stating.  The
# two addresses go into the confirm value, in the order initiator then
# responder, so both ends have to agree on which two addresses are on
# the link.  A wire joining two links that the controller reported
# with different peer addresses cannot satisfy that: our initiator
# computes over one pair and our responder over another, and the
# confirm legitimately does not match.  So this phase is a single
# link, with the model as the peer and as the controller in between.
#
paired()
{
	ok := 1;
	if((ne := writefile(mnt + "/0/ctl", "advname inferno-bt")) != nil){
		sys->print("BT: FAILED: advname: %s\n", ne);
		sys->print("BT: done\n");
		return;
	}
	if((ae := writefile(mnt + "/0/ctl", "advertise on")) != nil){
		sys->print("BT: FAILED: advertise on: %s\n", ae);
		sys->print("BT: done\n");
		return;
	}
	dev := mnt + "/0/remote/" + Peerin;
	#
	# the peer connects and then pairs.  What says it worked is the
	# link becoming encrypted, which the controller only allows when
	# the key this side handed it is the key the peer derived.
	#
	enc := 0;
	for(i := 0; i < 40 && !enc; i++){
		sys->sleep(500);
		if(hasword(trim(readfile(dev + "/state")), "encrypted"))
			enc = 1;
	}
	if(!enc){
		sys->print("BT: FAILED: the link never became encrypted: %s\n",
			trim(readfile(dev + "/state")));
		ok = 0;
	} else
		sys->print("BT: the peer paired with us: %s\n", trim(readfile(dev + "/state")));

	#
	# and the bond it produced, which names the peer, this
	# controller, and the key this side chose and gave it
	#
	bl := lines(readfile(mnt + "/0/bonds"));
	found := "";
	for(; bl != nil; bl = tl bl)
		if(hasstr(hd bl, Peerin))
			found = hd bl;
	if(found == ""){
		sys->print("BT: FAILED: pairing left no bond\n");
		ok = 0;
	} else if(keyof(found) == ""){
		sys->print("BT: FAILED: the bond has no key: %s\n", found);
		ok = 0;
	} else
		sys->print("BT: the bond: %s\n", found);

	#
	# And the peer comes back.  It closes the link, opens it again,
	# and starts encryption naming the key this side distributed;
	# nothing pairs a second time.  That the key was found is the
	# controller's to say -- the guest only sees a link that came up
	# encrypted -- so scripts/btbench.sh reads the controller's log
	# for it.  What this side can see is that it happened without
	# another bond appearing.
	#
	before := len lines(readfile(mnt + "/0/bonds"));
	again := 0;
	for(i = 0; i < 40 && !again; i++){
		sys->sleep(500);
		if(hasword(trim(readfile(dev + "/state")), "encrypted")
		&& !hasword(trim(readfile(dev + "/state")), "handle 65"))
			again = 1;
	}
	if(!again){
		sys->print("BT: FAILED: the peer did not come back encrypted: %s\n",
			trim(readfile(dev + "/state")));
		ok = 0;
	} else {
		after := len lines(readfile(mnt + "/0/bonds"));
		if(after != before){
			sys->print("BT: FAILED: coming back made %d bonds where there were %d\n",
				after, before);
			ok = 0;
		} else
			sys->print("BT: it came back on the bond it had: %s\n",
				trim(readfile(dev + "/state")));
	}

	if(ok)
		sys->print("BT: a peer paired with us and the link is encrypted\n");
	writefile(mnt + "/0/ctl", "advertise off");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

#
# HID over GATT: a Bluetooth keyboard and mouse turned into
# keystrokes and motion.  bthid does the work and has no Bluetooth in
# it at all -- the device is a directory, a subscription is an open,
# and a report is a read -- so what this phase shows is that the name
# space is enough to drive a device class.
#
# The keys and the pointer go to files rather than to /dev/keyboard
# and /dev/pointer, which is what the -k and -p flags are for: the
# real devices are the default and are what a machine uses, and a
# bench that wrote to them could not read back what it wrote.
#
hid()
{
	remotes := lsdir(mnt + "/0/remote");
	if(remotes == nil){
		sys->print("BT: FAILED: nothing was advertising\n");
		sys->print("BT: done\n");
		return;
	}
	dev := mnt + "/0/remote/" + hd remotes;
	if((e := writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	svcs := lsdir(dev + "/gatt");
	got := 0;
	for(sl := svcs; sl != nil; sl = tl sl)
		if(hd sl == "1812")
			got = 1;
	if(!got){
		sys->print("BT: FAILED: no HID service among %d\n", len svcs);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: the device has a HID service\n");
	hidcheck(dev);
}

#
# What bthid must produce, whichever transport it came over.  It is
# one function because that is the claim: the same keystrokes and the
# same movement out of the same two libraries, with only the pipe
# underneath different.
#
hidcheck(dev: string)
{
	ok := 1;
	kf := "/tmp/bthid.keys";
	pf := "/tmp/bthid.pointer";
	create(kf);
	create(pf);
	bthid := load Command "/dis/bt/bthid.dis";
	if(bthid == nil){
		sys->print("BT: FAILED: cannot load /dis/bt/bthid.dis: %r\n");
		sys->print("BT: done\n");
		return;
	}
	spawn bthid->init(nil, "bthid" :: "-m" :: mnt :: "-k" :: kf :: "-p" :: pf :: nil);

	#
	# the device types bth and a shifted a, and then moves.  Wait
	# for the keys rather than for a fixed time: the device sends
	# when it is ready and the reader has to have got there first.
	#
	#
	# Longer than it looks like it needs: the report protocol has
	# the map and the report references to read before anything is
	# subscribed to, and every one of those is a round trip.  A
	# phase that fails because a loaded machine was slow says
	# nothing about the stack.
	#
	keys := "";
	for(i := 0; i < 100 && keys != "bthA"; i++){
		sys->sleep(500);
		keys = readfile(kf);
	}
	if(keys != "bthA"){
		sys->print("BT: FAILED: the keyboard produced %q, wanted \"bthA\"\n", keys);
		ok = 0;
	} else
		sys->print("BT: the keyboard typed %s, shift and all\n", keys);

	#
	# and the pointer: two reports of movement, which have to add up
	# to a position.  5+3 across and 7+2 down, with the left button
	# down for the first and up for the second.
	#
	pt := "";
	for(i = 0; i < 20 && !hasstr(pt, "m 8 9 0"); i++){
		sys->sleep(500);
		pt = readfile(pf);
	}
	if(!hasstr(pt, "m 5 7 1")){
		sys->print("BT: FAILED: the first pointer report is missing from %q\n", pt);
		ok = 0;
	} else if(!hasstr(pt, "m 8 9 0")){
		sys->print("BT: FAILED: the movement did not add up: %q\n", pt);
		ok = 0;
	} else
		sys->print("BT: the pointer moved and the button was read: %s\n", pt);

	if(ok)
		sys->print("BT: a Bluetooth keyboard and mouse, out of the name space\n");
	writefile(dev + "/ctl", "disconnect");
	writefile(mnt + "/0/ctl", "scan off");
	sys->print("BT: done\n");
}

create(p: string)
{
	fd := sys->create(p, Sys->OWRITE, 8r666);
	fd = nil;
}

#
# The Classic half of the BlueZ phase.
#
# Everything above this was LE.  BlueZ's emulated controllers all go
# in one list and an inquiry walks it, so the same peer answers an
# inquiry as well, and bthost has an L2CAP server and an RFCOMM
# server in it.  That is the part of this stack most worth pointing at
# someone else's implementation: RFCOMM is TS 07.10 with a Bluetooth
# adaptation layer, written here out of the specification, and its
# frame check sequence, its multiplexer start-up and its credits are
# all places where two readers can differ and both be self-consistent.
#
# The peer is found by inquiry rather than named, because its address
# is btvirt's to choose and not this bench's.
#
Bvpsm:	con "1001";
Bvchan:	con "1";

btvirtclassic()
{
	if((e := writefile(mnt + "/0/ctl", "inquiry on")) != nil){
		sys->print("BT: FAILED: inquiry on: %s\n", e);
		return;
	}
	for(i := 0; i < 40; i++){
		sys->sleep(500);
		if(hasstr(readfile(mnt + "/0/state"), "inquiry off"))
			break;
	}
	addr := "";
	for(l := lsdir(mnt + "/0/remote"); l != nil; l = tl l)
		if(hasstr(readfile(mnt + "/0/remote/" + hd l + "/type"), "classic"))
			addr = hd l;
	if(addr == ""){
		sys->print("BT: FAILED: the inquiry found no Classic device\n");
		return;
	}
	sys->print("BT: inquiry found %s\n", addr);
	dev := mnt + "/0/remote/" + addr;
	if((e = writefile(dev + "/ctl", "connect")) != nil){
		sys->print("BT: FAILED: connect: %s\n", e);
		return;
	}
	sys->print("BT: paged %s\n", addr);

	#
	# An L2CAP channel in basic mode, and then a serial port over
	# RFCOMM on the same link.  Both answer in upper case rather
	# than echoing, so what comes back has to have been read by the
	# far end: a loopback anywhere along the path would return the
	# same bytes and fail this.
	#
	if((e = writefile(dev + "/ctl", "l2cap " + Bvpsm)) != nil)
		sys->print("BT: FAILED: l2cap %s: %s\n", Bvpsm, e);
	else
		bvsay(dev + "/l2cap/" + Bvpsm, "a frame to bluez", "l2cap");

	if((e = writefile(dev + "/ctl", "rfcomm " + Bvchan)) != nil)
		sys->print("BT: FAILED: rfcomm %s: %s\n", Bvchan, e);
	else
		bvsay(dev + "/rfcomm/" + Bvchan + "/data",
			"a serial port to bluez", "rfcomm");

	#
	# And secure simple pairing, against BlueZ's.  bthost answers
	# the IO capability request with No Input No Output, so this is
	# Just Works, and it replies to the link key request negatively,
	# so it pairs afresh rather than remembering.  What is asserted
	# is that the link encrypts and that a link key was written
	# down: a pairing that agreed one and did not keep it is a
	# device that pairs again every time.  The key itself is
	# whatever BlueZ generated and is not this bench's to predict,
	# unlike the model's, which is fixed.
	#
	if((e = writefile(dev + "/ctl", "pair")) != nil){
		sys->print("BT: FAILED: pair: %s\n", e);
		writefile(dev + "/ctl", "disconnect");
		return;
	}
	st := "";
	for(i = 0; i < 20; i++){
		st = trim(readfile(dev + "/state"));
		if(hasstr(st, "encrypted"))
			break;
		sys->sleep(250);
	}
	if(!hasstr(st, "encrypted"))
		sys->print("BT: FAILED: after pairing the link reads %q\n", st);
	else
		sys->print("BT: ssp: %s\n", st);
	bonds := readfile(mnt + "/0/bonds");
	if(!hasstr(bonds, "lk "))
		sys->print("BT: FAILED: no link key was written down: %q\n", bonds);
	else
		sys->print("BT: ssp: a link key was kept\n");

	writefile(dev + "/ctl", "disconnect");
}

#
# Write a line, read the answer, and require it to be the same text in
# upper case.
#
bvsay(f, what, name: string)
{
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->print("BT: FAILED: opening %s: %r\n", f);
		return;
	}
	b := array of byte what;
	if(sys->write(fd, b, len b) != len b){
		sys->print("BT: FAILED: writing %s: %r\n", name);
		return;
	}
	(n, rb, re) := sdu(fd, 10000);
	if(re != nil || n <= 0){
		sys->print("BT: FAILED: reading %s: %s\n", name, re);
		return;
	}
	got := string rb[0:n];
	want := "";
	for(i := 0; i < len what; i++){
		c := what[i];
		if(c >= 'a' && c <= 'z')
			c = c - 'a' + 'A';
		want[len want] = c;
	}
	if(got != want){
		sys->print("BT: FAILED: %s answered %q, wanted %q\n",
			name, got, want);
		return;
	}
	sys->print("BT: %s: %q came back %q\n", name, what, got);
}

#
# An LE credit-based channel to BlueZ.
#
# The peer serves it with an MPS of 48 and grants one credit at a
# time, so an SDU of 150 bytes is four PDUs and three waits going out:
# what is asserted is the segmentation, the two byte SDU length that
# goes on the first PDU and not on the rest, and that this side does
# not send before the credit arrives.  The peer reassembles it and
# answers in upper case, so it was read and not echoed.
#
# 150 and not 200, and the reason is the peer's.  bthost_send_cid
# prepends the SDU header and sends the whole thing as one L2CAP PDU:
# it does not segment to the MPS the other side asked for, and it
# keeps no account of the credits it has been given.  This side
# offered an MPS of 188 in the connection request, BlueZ answered
# acknowledging it, and then sent 202 bytes in one PDU, which this
# side refused -- rightly.  At 150 the answer is 152 bytes and fits,
# so the direction that is worth testing, this stack segmenting
# against a peer that grants one credit at a time, is still tested,
# and the peer is not asked to do the thing it cannot.
#
Bvcoc:	con "0080";

btvirtcoc(dev: string)
{
	if((e := writefile(dev + "/ctl", "l2cap " + Bvcoc)) != nil){
		sys->print("BT: FAILED: l2cap %s: %s\n", Bvcoc, e);
		writefile(dev + "/ctl", "disconnect");
		return;
	}
	what := "";
	while(len what < 150)
		what[len what] = 'a' + (len what % 26);
	bvsay(dev + "/l2cap/" + Bvcoc, what, "credit channel");
}

#
# The two pieces of cryptography LE Secure Connections needs, checked
# against what can check them.
#
# AES-CMAC is RFC 4493 and has four published vectors, and they cover
# both halves of the construction: two of the four messages divide
# into whole blocks and two have to be padded, which is the
# distinction the two subkeys exist to make.
#
# P-256 has no vector here on purpose.  What is checked instead are
# properties the curve must have -- the base point is on it, n times
# the base point is the point at infinity, (n-1) times it is its own
# negation -- and a Diffie-Hellman that has to agree from both sides.
# A constant with a digit wrong fails those.  Agreement with another
# implementation is checked against openssl, by hand, and is written
# up in doc/bluetooth-plan.ms rather than run from here, because the
# bench does not get to depend on openssl being installed.
#
cryptophase()
{
	cmac = load Cmac Cmac->PATH;
	if(cmac == nil){
		sys->print("BT: FAILED: cannot load %s: %r\n", Cmac->PATH);
		sys->print("BT: done\n");
		return;
	}
	if((e := cmac->init()) != nil){
		sys->print("BT: FAILED: cmac init: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	if((e = cmac->selftest()) != nil)
		sys->print("BT: FAILED: aes-cmac: %s\n", e);
	else
		sys->print("BT: aes-cmac agrees with all four RFC 4493 vectors\n");

	p256 = load P256 P256->PATH;
	if(p256 == nil){
		sys->print("BT: FAILED: cannot load %s: %r\n", P256->PATH);
		sys->print("BT: done\n");
		return;
	}
	if((e = p256->init()) != nil){
		sys->print("BT: FAILED: p256 init: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	t0 := sys->millisec();
	if((e = p256->selftest()) != nil)
		sys->print("BT: FAILED: p-256: %s\n", e);
	else
		sys->print("BT: p-256: on the curve, nG infinite, (n-1)G negated, agreement matches (%d ms)\n",
			sys->millisec() - t0);
	sys->print("BT: done\n");
}

#
# Watch the confirm file and answer it.
#
# What it prints is the number, because the number is the thing worth
# seeing: two devices showing different digits is what a person is
# there to catch, and a bench that answered without reporting what it
# answered would be testing that yes can be written to a file.
#
confirmer(dev: string)
{
	for(i := 0; i < 100; i++){
		q := trim(readfile(dev + "/confirm"));
		if(q != nil){
			sys->print("BT: the pairing asks: %s\n", q);
			if((e := writefile(dev + "/confirm", "yes")) != nil)
				sys->print("BT: FAILED: answering the confirm: %s\n", e);
			return;
		}
		sys->sleep(100);
	}
	sys->print("BT: FAILED: the pairing never asked anything\n");
}

#
# The other way round against BlueZ: this side advertises and BlueZ
# connects to it and asks to pair, so what is being tested is the
# responder rather than the initiator.
#
# bthost adds the Secure Connections bit to whatever it was told to
# ask for, so what arrives is a modern initiator, which is the case
# this stack used to refuse outright.
#
btvirtperiph()
{
	if((e := writefile(mnt + "/0/ctl", "advname inferno-bt")) != nil){
		sys->print("BT: FAILED: advname: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	if((e = writefile(mnt + "/0/ctl", "advertise on")) != nil){
		sys->print("BT: FAILED: advertise on: %s\n", e);
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: advertising, waiting to be paired with\n");

	dev := "";
	for(i := 0; i < 60 && dev == ""; i++){
		sys->sleep(500);
		for(l := lsdir(mnt + "/0/remote"); l != nil; l = tl l){
			d := mnt + "/0/remote/" + hd l;
			if(hasword(trim(readfile(d + "/state")), "connected"))
				dev = d;
		}
	}
	if(dev == ""){
		sys->print("BT: FAILED: nothing connected to us\n");
		sys->print("BT: done\n");
		return;
	}
	sys->print("BT: %s connected to us\n", dev);

	#
	# The pairing is the peer's to start and this side's to answer,
	# so what is waited for is the link becoming encrypted and a
	# bond appearing -- neither of which this side asked for.
	#
	enc := 0;
	for(i = 0; i < 60 && !enc; i++){
		sys->sleep(500);
		enc = hasword(trim(readfile(dev + "/state")), "encrypted");
	}
	if(!enc){
		sys->print("BT: FAILED: the peer never encrypted the link\n");
		sys->print("BT: done\n");
		return;
	}
	show(dev + "/state");
	#
	# The bond is written after the pairing returns, which is after
	# the link reads encrypted: the state file is set by the
	# controller's event and the bond by the code that was waiting
	# for it.  Checking straight away catches the gap between them
	# rather than anything about the pairing.
	#
	bonds: list of string;
	for(i = 0; i < 40 && bonds == nil; i++){
		sys->sleep(250);
		bonds = lines(readfile(mnt + "/0/bonds"));
	}
	if(bonds == nil)
		sys->print("BT: FAILED: encrypted but no bond was kept\n");
	for(bl := bonds; bl != nil; bl = tl bl)
		say("BT: bond " + hd bl);
	sys->print("BT: done\n");
}
