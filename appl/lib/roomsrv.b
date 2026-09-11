implement Roomsrv;

#
# The Styx side of a spire(1) room, so that writing a room is writing
# what it stocks and what it will do, and not writing a file server.
#
# Everything here is the four files and the protocol around them.  The
# room itself answers two channels.  See roomsrv(2).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "roomsrv.m";

Qdir, Qname, Qwares, Qctl, Qstatus: con iota;

init(): string
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil)
		return sys->sprint("cannot load %s: %r", Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		return sys->sprint("cannot load %s: %r", Styxservers->PATH);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		return sys->sprint("cannot load %s: %r", Nametree->PATH);
	styx->init();
	styxservers->init(styx);
	nametree->init();
	return nil;
}

room(name: string): ref Room
{
	return ref Room(name, chan of (string, chan of string),
		chan of chan of string, chan of int);
}

# A program that can be run as a file server.
Prog: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

mountprog(prog: string, argv: list of string, mntpt: string, flags: int): string
{
	m := load Prog prog;
	if(m == nil)
		return sys->sprint("cannot load %s: %r", prog);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("cannot make a pipe: %r");
	sync := chan of int;
	spawn runprog(m, p[1], argv, sync);
	<-sync;
	# The server end belongs to the server now.  Holding a copy here
	# would keep the pipe open after an unmount and the server would
	# never see the connection go.
	p[1] = nil;
	if(sys->mount(p[0], nil, mntpt, flags, nil) < 0)
		return sys->sprint("cannot mount %s on %s: %r", prog, mntpt);
	# And our copy of the client end, for the same reason: while
	# anything holds it the server's read never reaches end of file and
	# its process outlives every unmount.
	p[0] = nil;
	return nil;
}

runprog(m: Prog, fd: ref Sys->FD, argv: list of string, sync: chan of int)
{
	# NEWFD and not FORKFD.  FORKFD copies the whole table, which still
	# holds the CLIENT end of the pipe this server is about to be given
	# the other end of - so the server itself kept the connection open,
	# its read never reached end of file, and the process outlived every
	# unmount.  mntgen and both rooms were still in ps after the game
	# had exited, and emu would not exit either.  NEWFD closes
	# everything not named, which is exactly what is wanted here.
	#
	# A namespace of its own too, taken now, before the caller mounts
	# what this is about to serve: the server can still read its own
	# files, and holds no reference to the mount of itself.
	sys->pctl(Sys->NEWFD | Sys->FORKNS, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	sys->dup(fd.fd, 1);
	sync <-= 1;
	m->init(nil, argv);
}

# int "abc" is 0 in Limbo, so a price that is not a number would become
# a free ware and nobody would be told.  camber(1)'s track parser learnt
# this the same way.
number(w: string): (int, int)
{
	if(len w == 0)
		return (0, 0);
	v := 0;
	for(i := 0; i < len w; i++){
		if(w[i] < '0' || w[i] > '9')
			return (0, 0);
		v = v*10 + (w[i] - '0');
	}
	return (v, 1);
}

stock(path: string): (string, array of ref Ware, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length <= big 0 || d.length > big (256*1024))
		return (nil, nil, "unreasonable stock file: " + path);
	b := array[int d.length] of byte;
	if(sys->readn(fd, b, len b) != len b)
		return (nil, nil, sys->sprint("cannot read %s: %r", path));
	name := "a room";
	out := array[16] of ref Ware;
	n := 0;
	body := 0;
	ln := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		ln++;
		l := hd lines;
		if(len l > 0 && l[0] == ';')
			continue;
		(nw, w) := sys->tokenize(l, " \t");
		if(nw == 0)
			continue;
		where := sys->sprint("%s:%d: ", path, ln);
		if(hd w == "%"){
			body = 1;
			continue;
		}
		if(!body){
			if(hd w != "name")
				return (nil, nil, where + "no such setting: " + hd w);
			name = join(tl w);
			continue;
		}
		if(nw < 3)
			return (nil, nil, where + "a ware is KEY PRICE TEXT...");
		(price, pok) := number(hd tl w);
		if(!pok)
			return (nil, nil, where + "not a price: " + hd tl w);
		if(n >= len out){
			a := array[2 * len out] of ref Ware;
			a[0:] = out[0:n];
			out = a;
		}
		out[n++] = ref Ware(hd w, price, join(tl tl w), 0);
	}
	return (name, out[0:n], nil);
}

join(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

wares(w: array of ref Ware): string
{
	s := "";
	for(i := 0; i < len w; i++){
		if(w[i].gone)
			continue;
		s += sys->sprint("%s %d %s\n", w[i].key, w[i].price, w[i].text);
	}
	return s;
}

ware(w: array of ref Ware, key: string): ref Ware
{
	for(i := 0; i < len w; i++)
		if(w[i].key == key)
			return w[i];
	return nil;
}

dirent(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "inferno";
	d.gid = "inferno";
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

serve(fd: ref Sys->FD, r: ref Room)
{
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dirent(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, dirent("name", 8r444, Qname));
	tree.create(big Qdir, dirent("wares", 8r444, Qwares));
	tree.create(big Qdir, dirent("ctl", 8r222, Qctl));
	tree.create(big Qdir, dirent("status", 8r444, Qstatus));

	(tc, srv) := Styxserver.new(fd, Navigator.new(treeop), big Qdir);
	status := "";
	while((tmsg := <-tc) != nil){
		pick tm := tmsg {
		Readerror =>
			break;
		Open =>
			srv.open(tm);
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);
			Qname =>
				srv.reply(styxservers->readstr(tm, r.name + "\n"));
			Qwares =>
				# The room is asked every time rather than at
				# start-up: what it stocks may depend on what
				# has already been bought.
				wc := chan of string;
				r.wares <-= wc;
				srv.reply(styxservers->readstr(tm, <-wc));
			Qstatus =>
				srv.reply(styxservers->readstr(tm, status + "\n"));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "no such file"));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			if(int c.path != Qctl){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
				continue;
			}
			cmd := string tm.data;
			while(len cmd > 0 && cmd[len cmd - 1] == '\n')
				cmd = cmd[0:len cmd - 1];
			rc := chan of string;
			r.ctl <-= (cmd, rc);
			ans := <-rc;
			# A refusal is an error on the write, not a line in
			# status: a caller that ignores the error and reads
			# status would otherwise read the last thing that
			# worked and believe it.
			if(len ans > 0 && ans[0] == '!'){
				srv.reply(ref Rmsg.Error(tm.tag, ans[1:]));
				continue;
			}
			status = ans;
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Clunk =>
			srv.clunk(tm);
		* =>
			srv.default(tmsg);
		}
	}
	tree.quit();
	# Tell the room, if it is listening.  A room that is not - one that
	# serves and nothing else - is not held up by this.
	alt{
	r.done <-= 1 =>
		;
	* =>
		;
	}
}
