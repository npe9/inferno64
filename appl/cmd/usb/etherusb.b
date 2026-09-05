implement Etherusb;

#
# USB ethernet: serve the netif (#l-style) file interface devip's
# ethermedium binds to, backed -- eventually -- by a USB ethernet
# device's bulk endpoints.  This first stage serves the interface with a
# canned MAC and proves the medium binds from Limbo: ethermedium.c reaches
# an ethernet device purely by path (namec/chandial on clone/addr/N/data),
# so a Limbo styx server that speaks the netif protocol can BE devip's
# ethernet, getting ARP, IPv6 ND and multicast-MAC mapping from the kernel.
#
# The netif protocol (os/inferno/port/netif.c, os/inferno/ip/chandial.c):
#  - open <path>/clone -> allocates a conversation, the fid now IS that
#    conversation's ctl; reading it returns the conversation number.
#  - write "connect <ethertype>" to the ctl to filter the conversation.
#  - open <path>/N/data -> the frames of that type (full ethernet frames).
#  - read <path>/addr -> the MAC address as hex text.
#
# Stage 1 (this file): interface + self-mount + bind, no USB yet.  Data
# reads block (no frames arrive), data writes (outgoing frames from the IP
# stack -- an ARP once an address is added) are reported, proving TX.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Fid, Enotfound, Eopen, Ebadfid: import styxservers;

	nametree: Nametree;
	Tree: import nametree;

Etherusb: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# qid paths.  The served tree is mounted at an existing directory, but
# chandial's dial-string parser rejects a single-component path (the '/'
# must not be at position 0), so the ethernet interface itself is one
# level down: root -> "ether" dir -> clone/addr/N.  bind is
# "ether <mnt>/ether".  conversation n occupies three consecutive paths
# from Cbase + n*3 (dir, ctl, data).
Qroot, Qether, Qclone, Qaddr: con big iota;
Cbase: con big 16;

Conn: adt {
	n:	int;
	etype:	int;		# ethertype filter, -1 == unset
	promisc: int;
	reads:	list of ref Tmsg.Read;	# deferred data reads
};

conns: array of ref Conn;
nconn := 0;
mac := array[6] of byte;
srv: ref Styxserver;
tree: ref Tree;
debug := 0;

badmod(p: string)
{
	sys->fprint(sys->fildes(2), "etherusb: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

dir(name: string, perm: int, qid: big): Sys->Dir
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

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil) badmod(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) badmod(Styxservers->PATH);
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil) badmod(Nametree->PATH);
	nametree->init();

	mnt := "/n/eth";
	argv = tl argv;
	if(argv != nil){ mnt = hd argv; argv = tl argv; }

	# canned MAC for stage 1 (locally-administered)
	mac[0]=byte 16r02; mac[1]=byte 16r00; mac[2]=byte 16r00;
	mac[3]=byte 16r11; mac[4]=byte 16r22; mac[5]=byte 16r33;

	conns = array[16] of ref Conn;

	navop: chan of ref Styxservers->Navop;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("etherusb: pipe: %r\n");
		return;
	}
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(p[0], nav, Qroot);

	tree.create(Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(Qroot, dir("ether", Sys->DMDIR|8r555, Qether));
	tree.create(Qether, dir("clone", 8r666, Qclone));
	tree.create(Qether, dir("addr", 8r444, Qaddr));

	# spawn the server loop BEFORE mounting: mount performs the 9P
	# handshake against our styx server, so the loop that answers it must
	# already be running or mount deadlocks.
	spawn server(tchan);

	if(sys->mount(p[1], nil, mnt, Sys->MREPL, "") < 0){
		sys->print("etherusb: mount %s: %r\n", mnt);
		return;
	}
	p[1] = nil;
	sys->print("ETHERUSB serving %s\n", mnt);

	bindtest(mnt);

	# keep the process alive so the server proc and etherread4 keep running
	c := chan of int;
	<-c;
}

# Drive the ipifc bind, the actual de-risk: if chandial's
# clone/connect/data dance is served correctly by our styx server, the
# bind returns without error and the kernel spawns etherread4.
bindtest(mnt: string)
{
	if(sys->bind("#I", "/net", Sys->MAFTER) < 0){
		sys->print("ETHERUSB-FAIL bind #I: %r\n");
		return;
	}
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("ETHERUSB-FAIL ipifc clone: %r\n");
		return;
	}
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0){
		sys->print("ETHERUSB-FAIL ipifc read: %r\n");
		return;
	}
	ifc := string buf[0:n];
	for(i := 0; i < len ifc && ifc[i] == ' '; i++) ;
	ifc = ifc[i:];
	ethpath := mnt + "/ether";
	if(sys->fprint(cfd, "bind ether %s", ethpath) < 0){
		sys->print("ETHERUSB-FAIL bind ether: %r\n");
		return;
	}
	sys->print("ETHERBIND-OK ifc %s bound ether %s\n", ifc, ethpath);
	if(sys->fprint(cfd, "add 10.0.0.2 255.255.255.0") < 0){
		sys->print("ETHERUSB add: %r\n");
		return;
	}
	sys->print("ETHERADD-OK (watch for an ARP frame on TX)\n");
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

# is qid path p a conversation ctl / data file?  returns (connno, kind)
# kind: 0 dir, 1 ctl, 2 data, -1 not a conversation path
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
			# allocate a conversation; the fid becomes its ctl
			n := nconn++;
			conns[n] = ref Conn(n, -1, 0, nil);
			cdir := Cbase + big(n*3);
			tree.create(Qether, dir(string n, Sys->DMDIR|8r555, cdir));
			tree.create(cdir, dir("ctl", 8r666, cdir+big 1));
			tree.create(cdir, dir("data", 8r666, cdir+big 2));
			cq := Sys->Qid(cdir+big 1, 0, Sys->QTFILE);
			fid.open(m.mode, cq);
			srv.reply(ref Rmsg.Open(m.tag, cq, srv.msize-styx->IOHDRSZ));
			return nil;
		}
		srv.open(m);			# normal open (addr, data, dir) replies
		return nil;
	Read =>
		(fid, err) := srv.canread(m);
		if(fid == nil)
			return err;
		(cn, kind) := convof(fid.path);
		if(fid.path == Qaddr){
			s := "";
			for(i := 0; i < 6; i++)
				s += sys->sprint("%2.2ux", int mac[i]);
			srv.reply(styxservers->readstr(m, s));
			return nil;
		}
		if(kind == 1){			# ctl read -> conversation number
			srv.reply(styxservers->readstr(m, string cn + "\n"));
			return nil;
		}
		if(kind == 2){			# data read -> defer until a frame arrives
			conns[cn].reads = m :: conns[cn].reads;
			return nil;		# no reply now (blocks, as ether reads do)
		}
		srv.read(m);			# directories via the navigator
		return nil;
	Write =>
		(fid, err) := srv.canwrite(m);
		if(fid == nil)
			return err;
		(cn, kind) := convof(fid.path);
		if(kind == 1){			# ctl: connect/promiscuous/nonblocking/...
			ctl(cn, string m.data);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
			return nil;
		}
		if(kind == 2){			# data: a frame to transmit
			transmit(cn, m.data);
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
	(nil, flds) := sys->tokenize(s, " \t\n");
	if(flds == nil)
		return;
	cmd := hd flds;
	case cmd {
	"connect" =>
		if(tl flds != nil)
			conns[cn].etype = int hd tl flds;
	"promiscuous" =>
		conns[cn].promisc = 1;
	* =>
		;			# nonblocking, bridge, headersonly, addmulti, ... accepted
	}
	if(debug)
		sys->print("etherusb: conn %d ctl %q\n", cn, s);
}

transmit(cn: int, frame: array of byte)
{
	# Stage 1: report the outgoing frame instead of sending it.  An ARP
	# request (ethertype 0x0806 at bytes 12-13) here proves the whole
	# TX path from the IP stack through the bound medium to us.
	t := 0;
	if(len frame >= 14)
		t = (int frame[12] << 8) | int frame[13];
	sys->print("ETHERTX conn %d %d bytes type %#4.4x\n", cn, len frame, t);
}
