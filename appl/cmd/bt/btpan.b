implement Btpan;

#
# btpan: a Bluetooth personal area network as an ethernet interface.
#
# A BNEP link carries whole ethernet frames, and devip's ether medium
# reaches an ethernet purely by path -- clone, addr, and a numbered
# conversation with ctl and data under it.  So a Limbo file server
# that speaks that protocol can be devip's ethernet, and the IP stack
# above it gets ARP, neighbour discovery and multicast mapping without
# knowing that the wire is a radio.  appl/cmd/usb/etherusb.b proved
# that binding works from Limbo; this is the same interface with a
# Bluetooth link under it instead of a canned address.
#
# The MAC is not invented.  A BNEP link's ethernet addresses are the
# two BD_ADDRs, so the interface's address is the controller's own and
# the peer's is the device's -- which is why a compressed BNEP packet
# can leave both out and still be a frame.
#
# The device is found the way anything Classic is found: an inquiry,
# then its service records, then the L2CAP channel a record names.
#
# On 9front this is one C program serving the same names.
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
	bnep: Bnep;
	Link: import bnep;

Btpan: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

#
# The served tree.  The interface is one level down from the mount
# point because chandial's dial string parser will not take a single
# component path, which is the same reason etherusb does it.
#
Qroot, Qether, Qclone, Qaddr: con big iota;
Cbase:	con big 16;

Conn: adt {
	n:	int;
	etype:	int;		# the ethertype this conversation wants, or -1
	promisc: int;
	reads:	list of ref Tmsg.Read;
};

conns:	array of ref Conn;
nconn	:= 0;
mac:	array of byte;
srv:	ref Styxserver;
tree:	ref Tree;
link:	ref Link;
lock:	chan of int;
mnt	:= "/n/btpan";
btmnt	:= "/net/bt";
verbose	:= 0;

# the PSM BNEP is always on, written the way btfs(4) wants it
Psmtext:	con "000f";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil)
		fail(sys->sprint("cannot load %s: %r", Styx->PATH));
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		fail(sys->sprint("cannot load %s: %r", Styxservers->PATH));
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		fail(sys->sprint("cannot load %s: %r", Nametree->PATH));
	nametree->init();
	arg := load Arg Arg->PATH;
	bt = load Bt Bt->PATH;
	bnep = load Bnep Bnep->PATH;
	if(arg == nil || bt == nil || bnep == nil)
		fail(sys->sprint("cannot load the stack: %r"));
	bt->init();
	#
	# and nothing else of it.  Everything Bluetooth is reached
	# through btfs's files: the link is btfs's, the channel is
	# btfs's, and what this opens is the file btfs made for it.
	#
	if((e := bnep->init(bt)) != nil)
		fail("bnep: " + e);

	arg->init(argv);
	arg->setusage("bt/btpan [-v] [-m mountpoint] [-b btmountpoint] [device]");
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose = 1;
		'm' =>	mnt = arg->arg();
		'b' =>	btmnt = arg->arg();
		* =>	arg->usage();
		}
	a := arg->argv();
	dev := "";
	if(a != nil)
		dev = hd a;
	if(dev == "")
		dev = findnap();
	if(dev == ""){
		sys->fprint(sys->fildes(2),
			"btpan: no connected device offers a network\n");
		return;
	}
	sys->print("btpan: %s\n", dev);

	#
	# The two addresses this ethernet is between.  They are read out
	# of the name space rather than made up, which is the whole
	# reason a BNEP frame may leave them out.
	#
	# In the order they are written, not the order a BD_ADDR goes on
	# an HCI wire.  An ethernet address is transmitted most
	# significant byte first and every ethernet thing above expects
	# that, so unhex and not straddr: straddr turns the text round
	# for the controller, and here it must not be turned round at
	# all.
	#
	mac = bt->unhex(trim(readfile(dev + "/addr")));
	local := bt->unhex(trim(readfile(radioof(dev) + "/addr")));
	if(len mac != Bt->Baddrlen || len local != Bt->Baddrlen){
		sys->fprint(sys->fildes(2), "btpan: %s has no address\n", dev);
		return;
	}
	#
	# and which way round they go: this side's controller is this
	# interface's own address, and the device's is the peer's.
	#
	peer := mac;
	mac = local;

	if((oe := writefile(dev + "/ctl", "l2cap " + Psmtext)) != nil){
		sys->fprint(sys->fildes(2), "btpan: the network channel: %s\n", oe);
		return;
	}
	#
	# btpan is the user and the peer is the access point.  A device
	# that will not be one says so in the setup response, which is
	# what makes asking better than assuming.
	#
	cf := dev + "/l2cap/" + Psmtext;
	fd := sys->open(cf, Sys->ORDWR);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "btpan: %s: %r\n", cf);
		return;
	}
	(l, se) := bnep->start(fd, mac, peer, Bnep->Unap, Bnep->Upanu);
	if(se != nil){
		sys->fprint(sys->fildes(2), "btpan: %s\n", se);
		return;
	}
	link = l;
	sys->print("btpan: a network to %s\n", bt->addrstr(peer));

	lock = chan[1] of int;
	lock <-= 1;
	conns = array[16] of ref Conn;

	navop: chan of ref Navop;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fail(sys->sprint("pipe: %r"));
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], nav, Qroot);
	srv.replychan = chan of ref Rmsg;
	spawn replier(srv.replychan);

	tree.create(Qroot, mkdir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(Qroot, mkdir("ether", Sys->DMDIR|8r555, Qether));
	tree.create(Qether, mkdir("clone", 8r666, Qclone));
	tree.create(Qether, mkdir("addr", 8r444, Qaddr));

	# the server has to be answering before the mount, because the
	# mount is a 9P conversation with it
	spawn server(tchan);
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, "") < 0)
		fail(sys->sprint("mount %s: %r", mnt));
	sys->print("btpan: serving %s\n", mnt);

	spawn reader();
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

#
# The first connected Classic device with a network access point or an
# ad hoc group in its service records.  A device offering neither has
# nothing here to talk to.
#
findnap(): string
{
	for(cl := lsdir(btmnt); cl != nil; cl = tl cl){
		rd := btmnt + "/" + hd cl + "/remote";
		for(dl := lsdir(rd); dl != nil; dl = tl dl){
			d := rd + "/" + hd dl;
			for(rl := lsdir(d + "/sdp"); rl != nil; rl = tl rl){
				s := readfile(d + "/sdp/" + hd rl);
				if(hasline(s, "class " + Bnep->Unap)
				|| hasline(s, "class " + Bnep->Ugn))
					return d;
			}
		}
	}
	return "";
}

# /net/bt/0/remote/ADDR -> /net/bt/0
radioof(dev: string): string
{
	for(i := len dev - 1; i > 0; i--)
		if(dev[i] == '/'){
			for(j := i - 1; j > 0; j--)
				if(dev[j] == '/')
					return dev[0:j];
			break;
		}
	return dev;
}

server(tchan: chan of ref Tmsg)
{
	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		e := handle(gm);
		if(e != nil)
			srv.reply(ref Rmsg.Error(gm.tag, e));
	}
}

# which conversation a qid belongs to: (number, 0 dir, 1 ctl, 2 data)
convof(p: big): (int, int)
{
	if(p < Cbase)
		return (-1, -1);
	off := int (p - Cbase);
	return (off / 3, off % 3);
}

handle(gm: ref Tmsg): string
{
	pick m := gm {
	Open =>
		(fid, nil, nil, err) := srv.canopen(m);
		if(fid == nil)
			return err;
		if(fid.path == Qclone){
			# a conversation, and this fid becomes its ctl
			<-lock;
			n := nconn++;
			conns[n] = ref Conn(n, -1, 0, nil);
			lock <-= 1;
			cdir := Cbase + big (n*3);
			tree.create(Qether, mkdir(string n, Sys->DMDIR|8r555, cdir));
			tree.create(cdir, mkdir("ctl", 8r666, cdir+big 1));
			tree.create(cdir, mkdir("data", 8r666, cdir+big 2));
			cq := Sys->Qid(cdir+big 1, 0, Sys->QTFILE);
			fid.open(m.mode, cq);
			srv.reply(ref Rmsg.Open(m.tag, cq, srv.msize-styx->IOHDRSZ));
			return nil;
		}
		srv.open(m);
		return nil;
	Read =>
		(fid, err) := srv.canread(m);
		if(fid == nil)
			return err;
		(cn, kind) := convof(fid.path);
		if(fid.path == Qaddr){
			s := "";
			for(i := 0; i < len mac; i++)
				s += sys->sprint("%2.2ux", int mac[i]);
			srv.reply(styxservers->readstr(m, s));
			return nil;
		}
		if(kind == 1){
			srv.reply(styxservers->readstr(m, string cn + "\n"));
			return nil;
		}
		if(kind == 2){
			#
			# A frame read waits for a frame, as an ethernet
			# read does.  The request is put down here and
			# answered by the reader below.
			#
			<-lock;
			if(cn < nconn && conns[cn] != nil)
				conns[cn].reads = m :: conns[cn].reads;
			lock <-= 1;
			return nil;
		}
		srv.read(m);
		return nil;
	Write =>
		(fid, err) := srv.canwrite(m);
		if(fid == nil)
			return err;
		(cn, kind) := convof(fid.path);
		if(kind == 1){
			ctl(cn, string m.data);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
			return nil;
		}
		if(kind == 2){
			if((e := bnep->send(link, m.data)) != nil)
				return e;
			if(verbose)
				sys->print("btpan: %d bytes out\n", len m.data);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
			return nil;
		}
		return "cannot write here";
	* =>
		srv.default(gm);
	}
	return nil;
}

ctl(cn: int, s: string)
{
	(nil, f) := sys->tokenize(s, " \t\n");
	if(f == nil)
		return;
	<-lock;
	if(cn >= 0 && cn < nconn && conns[cn] != nil){
		case hd f {
		"connect" =>
			#
			# which ethertype this conversation wants.  It is
			# what makes one conversation ARP and another IP,
			# and a server that ignored it would hand every
			# frame to everybody.
			#
			if(tl f != nil)
				conns[cn].etype = int hd tl f;
		"promiscuous" =>
			conns[cn].promisc = 1;
		* =>
			;	# nonblocking, bridge, headersonly, addmulti
		}
	}
	lock <-= 1;
}

#
# Frames in, handed to whoever asked for that ethertype.  A frame
# nobody wants is dropped, which is what a wire does.
#
reader()
{
	for(;;){
		(f, e) := bnep->recv(link);
		if(e != nil){
			sys->fprint(sys->fildes(2), "btpan: the network is gone: %s\n", e);
			return;
		}
		if(len f < 14)
			continue;
		ty := (int f[12] << 8) | int f[13];
		if(verbose)
			sys->print("btpan: %d bytes in, type %#4.4ux\n", len f, ty);
		deliver(ty, f);
	}
}

deliver(ty: int, f: array of byte)
{
	<-lock;
	for(i := 0; i < nconn; i++){
		c := conns[i];
		if(c == nil || c.reads == nil)
			continue;
		if(!c.promisc && c.etype != ty && c.etype != -1)
			continue;
		m := hd c.reads;
		c.reads = tl c.reads;
		b := f;
		if(len b > m.count)
			b = b[0:m.count];
		srv.reply(ref Rmsg.Read(m.tag, b));
	}
	lock <-= 1;
}

mkdir(name: string, perm: int, qid: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "network";
	d.qid.path = qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	return d;
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

trim(s: string): string
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "btpan: %s\n", s);
	raise "fail:" + s;
}
