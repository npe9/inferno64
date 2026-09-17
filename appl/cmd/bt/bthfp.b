implement Bthfp;

#
# bthfp: a telephone as files.
#
# It finds a device offering the hands free audio gateway service --
# which is what a phone offers -- opens the RFCOMM channel its service
# record names, does the service level connection, and then serves
#
#	/n/bthfp/status		the indicators, one per line
#	/n/bthfp/event		the next thing that changed
#	/n/bthfp/ctl		dial, answer, hangup, or a raw AT command
#
# So a program places a call by writing "dial 12345" to a file and
# learns that it was answered by reading another, which is the whole
# of what a hands free unit does apart from the sound.
#
# There is no sound.  A call's audio goes over a synchronous
# connection, which needs the controller to carry it and, over USB,
# isochronous endpoints, and none of that is verified in this tree.
# This can see a call, place one, answer one and hang up, and cannot
# hear or be heard, and says so when it starts rather than leaving it
# to be discovered by holding a silent phone.
#
# Everything Bluetooth is reached through btfs's files, as in bthid,
# btpan and bta2dp: what this opens is the RFCOMM file btfs made.
#
# On 9front this is one C program serving the same three files.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop, Fid: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "bt.m";
	bt: Bt;
	hfp: Hfp;

Bthfp: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qstatus, Qevent, Qctl: con big iota;

srv:	ref Styxserver;
tree:	ref Tree;
sess:	ref Hfp->Sess;
mnt	:= "/n/bthfp";
btmnt	:= "/net/bt";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	arg := load Arg Arg->PATH;
	bt = load Bt Bt->PATH;
	hfp = load Hfp Hfp->PATH;
	if(styx == nil || styxservers == nil || nametree == nil
	|| arg == nil || bt == nil || hfp == nil){
		sys->fprint(sys->fildes(2), "bthfp: cannot load the stack: %r\n");
		return;
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();
	bt->init();
	if((ie := hfp->init(bt)) != nil){
		sys->fprint(sys->fildes(2), "bthfp: %s\n", ie);
		return;
	}

	arg->init(argv);
	arg->setusage("bt/bthfp [-m mountpoint] [-b btmountpoint] [device]");
	while((c := arg->opt()) != 0)
		case c {
		'm' =>	mnt = arg->arg();
		'b' =>	btmnt = arg->arg();
		* =>	arg->usage();
		}
	a := arg->argv();
	dev := "";
	if(a != nil)
		dev = hd a;
	if(dev == "")
		dev = findag();
	if(dev == ""){
		sys->fprint(sys->fildes(2),
			"bthfp: no connected device offers an audio gateway\n");
		return;
	}
	ch := agchannel(dev);
	if(ch <= 0){
		sys->fprint(sys->fildes(2),
			"bthfp: %s: the gateway's record names no channel\n", dev);
		return;
	}
	sys->print("bthfp: %s channel %d\n", dev, ch);

	if((e := writefile(dev + "/ctl", "rfcomm " + string ch)) != nil){
		sys->fprint(sys->fildes(2), "bthfp: the port: %s\n", e);
		return;
	}
	f := dev + "/rfcomm/" + string ch + "/data";
	fd := sys->open(f, Sys->ORDWR);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "bthfp: %s: %r\n", f);
		return;
	}
	sess = hfp->start(fd);
	if((e = hfp->slc(sess)) != nil){
		sys->fprint(sys->fildes(2), "bthfp: %s\n", e);
		return;
	}
	sys->print("bthfp: %s\n", statustext());
	sys->fprint(sys->fildes(2),
		"bthfp: the call control is here and the audio is not: nothing carries a synchronous connection\n");

	navop: chan of ref Navop;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->fprint(sys->fildes(2), "bthfp: pipe: %r\n");
		return;
	}
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], nav, Qroot);
	srv.replychan = chan of ref Rmsg;
	spawn replier(srv.replychan);
	tree.create(Qroot, mkdir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(Qroot, mkdir("status", 8r444, Qstatus));
	tree.create(Qroot, mkdir("event", 8r444, Qevent));
	tree.create(Qroot, mkdir("ctl", 8r666, Qctl));

	spawn server(tchan);
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, "") < 0){
		sys->fprint(sys->fildes(2), "bthfp: mount %s: %r\n", mnt);
		return;
	}
	sys->print("bthfp: serving %s\n", mnt);
	#
	# and stay: the reader hfp started is what keeps the indicators
	# current, and the file server is what answers.
	#
	done := chan of int;
	<-done;
}

replier(c: chan of ref Rmsg)
{
	for(;;){
		m := <-c;
		if(m == nil)
			return;
		srv.replydirect(m);
	}
}

server(tchan: chan of ref Tmsg)
{
	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		pick m := gm {
		Read =>
			(fid, err) := srv.canread(m);
			if(fid == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				continue;
			}
			case int fid.path {
			int Qstatus =>
				srv.reply(styxservers->readstr(m, statustext()));
			int Qevent =>
				#
				# a stream: each read is the next thing
				# that changed, and a read with nothing to
				# read waits.  Its own process, because it
				# waits.
				#
				spawn event(m);
			int Qctl =>
				srv.reply(styxservers->readstr(m, ""));
			* =>
				srv.read(m);
			}
		Write =>
			(fid, err) := srv.canwrite(m);
			if(fid == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				continue;
			}
			if(fid.path != Qctl){
				srv.reply(ref Rmsg.Error(m.tag, "cannot write here"));
				continue;
			}
			spawn ctl(m);
		* =>
			srv.default(gm);
		}
	}
}

#
# A stream, not a file: each read is the next thing that changed,
# whole, and the offset means nothing.  readstr() would apply it, so
# the second read of a five byte first event would return everything
# after the fifth byte of the second one -- which is how "call 1"
# arrived as "1".  btfs's notification files say the same thing about
# the same mistake.
#
event(m: ref Tmsg.Read)
{
	e := <-sess.events + "\n";
	b := array of byte e;
	if(len b > m.count)
		b = b[0:m.count];
	srv.reply(ref Rmsg.Read(m.tag, b));
}

#
# The indicators, and what the gateway said it could do.  A program
# reads this to find out whether there is a call, whether there is
# service, and how much battery the phone has left.
#
statustext(): string
{
	s := sys->sprint("features %#x\n", sess.agfeatures);
	for(l := sess.values; l != nil; l = tl l){
		(n, v) := hd l;
		s += sys->sprint("%s %d\n", n, v);
	}
	return s;
}

ctl(m: ref Tmsg.Write)
{
	(nil, f) := sys->tokenize(string m.data, " \t\n");
	e: string;
	if(f == nil)
		e = "usage: dial number | answer | hangup | at command";
	else
		case hd f {
		"dial" =>
			if(tl f == nil)
				e = "usage: dial number";
			else
				e = hfp->dial(sess, hd tl f);
		"answer" =>
			e = hfp->answer(sess);
		"hangup" =>
			e = hfp->hangup(sess);
		"at" =>
			#
			# whatever the caller wants to say, for the
			# things this does not have a verb for.  The
			# answer goes nowhere: what came of it shows in
			# the indicators, which is where a hands free
			# unit looks anyway.
			#
			if(tl f == nil)
				e = "usage: at command";
			else {
				(nil, ae) := hfp->command(sess, hd tl f);
				e = ae;
			}
		* =>
			e = "unknown control message";
		}
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

#
# the first connected device offering an audio gateway, and the RFCOMM
# channel its record names
#
findag(): string
{
	for(cl := lsdir(btmnt); cl != nil; cl = tl cl){
		rd := btmnt + "/" + hd cl + "/remote";
		for(dl := lsdir(rd); dl != nil; dl = tl dl){
			d := rd + "/" + hd dl;
			if(agrec(d) != "")
				return d;
		}
	}
	return "";
}

agrec(dev: string): string
{
	for(rl := lsdir(dev + "/sdp"); rl != nil; rl = tl rl){
		s := readfile(dev + "/sdp/" + hd rl);
		if(hasline(s, "class " + Hfp->Uag)
		|| hasline(s, "class " + Hfp->Uhsag))
			return s;
	}
	return "";
}

agchannel(dev: string): int
{
	r := agrec(dev);
	v := lineval(r, "proto rfcomm ");
	if(v == "")
		return 0;
	return int v;
}

lineval(s, key: string): string
{
	for(i := 0; i < len s; ){
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		if(len key <= j - i && s[i:i+len key] == key)
			return s[i+len key:j];
		i = j + 1;
	}
	return "";
}

hasline(s, want: string): int
{
	for(i := 0; i < len s; ){
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		if(len want <= j - i && s[i:i+len want] == want)
			return 1;
		i = j + 1;
	}
	return 0;
}

mkdir(name: string, perm: int, qid: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "bt";
	d.qid.path = qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	return d;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[4096] of byte;
	for(;;){
		n := sys->pread(fd, buf, len buf, big len array of byte s);
		if(n <= 0)
			break;
		s += string buf[0:n];
		if(n < len buf)
			break;
	}
	return s;
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
