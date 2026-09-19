implement Zerofs;

#
# A file server, in Limbo, serving one file of zeros.
#
# It exists to make styxbench(1)'s comparison a fair one.  That tool
# times a Styx round trip against a bare TCP exchange, and its first
# version answered the TCP half with a Limbo program and the Styx half
# with the kernel -- exportfs reading /dev/zero, in C.  The ratio it
# produced measured which language the server was written in: Styx came
# out cheaper than the transport it runs on, which cannot be so.
#
# With this on the Styx side both halves pay Dis interpretation, and
# what is left between them is the protocol, which is the thing the
# measurement is for.  Serving zeros rather than anything real is
# deliberate: a read costs the server nothing but the Styx exchange.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, readbytes: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Zerofs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot: con big 0;
Qzero: con big 1;

init(nil: ref Draw->Context, nil: list of string)
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

	navop: chan of ref Styxservers->Navop;
	tree: ref Tree;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);
	(tchan, srv) := Styxserver.new(sys->fildes(0), nav, Qroot);
	tree.create(Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(Qroot, dir("zero", 8r444, Qzero));

	zeros := array[8192] of byte;
	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		pick m := gm {
		Read =>
			f := srv.getfid(m.fid);
			if(f == nil || f.path != Qzero){
				srv.default(gm);
				continue;
			}
			n := m.count;
			if(n > len zeros)
				n = len zeros;
			srv.reply(ref Rmsg.Read(m.tag, zeros[0:n]));
		* =>
			srv.default(gm);
		}
	}
}

dir(name: string, perm: int, path: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "zero";
	d.gid = "zero";
	d.qid.path = path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "zerofs: %s\n", s);
	raise "fail:" + s;
}
