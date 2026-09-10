implement Regndb;

#
# regndb: present the services registered with registry(4) as an
# attrdb(6) database, so that cs(8) and everything above it can look up
# machines that join and leave the network while the system is running.
#
# A machine joins by writing its description to /mnt/registry/new and
# holding that file descriptor open; it leaves by closing it, or by its
# connection to the registry dropping.  registry(4) already does that
# part.  What was missing was any way for an ndb consumer to see it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
	Enotdir, Enotfound, Ebadarg: import Styxservers;
include "arg.m";

Regndb: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qndb, Qctl: con iota;

Retrytime:	con 2000;	# ms between attempts to re-attach to a lost registry

srv:	ref Styxserver;

regmnt := "/mnt/registry";	# the registry to watch
keyattr := "sys";		# the attribute that turns a service into an ndb entry
chain: list of string;		# static databases named by the generated database= entry
nochain := 0;

# the rendered database, and everything stat(2) must report about it
data:	array of byte;
gen := 0;			# becomes Qid.vers of ndb, so attrdb sees a change
mtime := 0;
nentry := 0;			# services rendered
nskip := 0;			# services with no keyattr
ndrop := 0;			# attribute pairs dropped as unrepresentable
regerr: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		loaderr(String->PATH);
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		loaderr(Daytime->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		loaderr(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		loaderr(Styxservers->PATH);
	styxservers->init(styx);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		loaderr(Arg->PATH);
	arg->init(args);
	arg->setusage("ndb/regndb [-N] [-m regmnt] [-a attr] [-f database]...");
	rchain: list of string;
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	regmnt = arg->earg();
		'a' =>	keyattr = arg->earg();
		'f' =>	rchain = arg->earg() :: rchain;
		'N' =>	nochain = 1;
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	arg = nil;
	if(rchain == nil)
		rchain = "/lib/ndb/local" :: nil;
	for(; rchain != nil; rchain = tl rchain)
		chain = hd rchain :: chain;

	sys->pctl(Sys->FORKNS|Sys->NEWFD, 0::1::2::nil);
	render();

	nudge := chan of int;
	navops := chan of ref Navop;
	spawn navigator(navops);
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navops), big Qroot);
	spawn watcher(nudge);
	spawn serve(tchan, navops, nudge);
}

loaderr(p: string)
{
	error(sys->sprint("can't load %s: %r", p));
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "regndb: %s\n", s);
	raise "fail:error";
}

#
# read registry's event file.  A read of it blocks until the registry
# changes, and coalesces changes, so this loop costs nothing while the
# network is quiet.  It nudges the server rather than rendering here, so
# that only one process ever touches the rendered database.
#
watcher(nudge: chan of int)
{
	for(;;){
		fd := sys->open(regmnt+"/event", Sys->OREAD);
		if(fd != nil){
			buf := array[64] of byte;
			for(;;){
				nudge <-= 1;
				if(sys->read(fd, buf, len buf) <= 0)
					break;
			}
			fd = nil;
		}
		nudge <-= -1;
		sys->sleep(Retrytime);
	}
}

serve(tchan: chan of ref Tmsg, navops: chan of ref Navop, nudge: chan of int)
{
Serve:
	for(;;)alt{
	v := <-nudge =>
		if(v < 0)
			regerr = sys->sprint("registry %s unavailable", regmnt);
		render();
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		err := "";
		pick m := gm {
		Readerror =>
			sys->fprint(sys->fildes(2), "regndb: styx read error: %s\n", m.error);
			break Serve;
		Open =>
			(fid, nil, nil, e) := srv.canopen(m);
			if((err = e) != nil)
				break;
			if((fid.qtype & Sys->QTDIR) == 0 && int fid.path == Qndb)
				fid.data = data;	# a reader sees one whole version
			srv.default(m);
		Read =>
			(fid, e) := srv.canread(m);
			if((err = e) != nil)
				break;
			if(fid.qtype & Sys->QTDIR)
				srv.read(m);
			else
				err = read(m, fid);
		Write =>
			(fid, e) := srv.canwrite(m);
			if((err = e) != nil)
				break;
			if((err = write(m, fid)) == nil)
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		* =>
			srv.default(gm);
		}
		if(err != "")
			srv.reply(ref Rmsg.Error(gm.tag, err));
	}
	navops <-= nil;
}

read(m: ref Tmsg.Read, fid: ref Fid): string
{
	case int fid.path {
	Qndb =>
		if(fid.data == nil)
			fid.data = data;
		srv.reply(styxservers->readbytes(m, fid.data));
	Qctl =>
		srv.reply(styxservers->readstr(m, status()));
	* =>
		return Enotfound;
	}
	return nil;
}

write(m: ref Tmsg.Write, fid: ref Fid): string
{
	if(int fid.path != Qctl)
		return Enotfound;
	(nil, f) := sys->tokenize(string m.data, " \t\n");
	if(f == nil)
		return Ebadarg;
	case hd f {
	"refresh" =>
		render();
	* =>
		return Ebadarg;
	}
	return nil;
}

status(): string
{
	e := regerr;
	if(e == nil)
		e = "none";
	return sys->sprint("registry %s\nattr %s\ngeneration %d\nentries %d\nskipped %d\ndropped %d\nerror %s\n",
		regmnt, keyattr, gen, nentry, nskip, ndrop, e);
}

#
# read the whole of one file.  The registry's index is regenerated on
# each open, so it must be read in one pass.
#
readall(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	b := array[0] of byte;
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		t := array[len b + n] of byte;
		t[0:] = b;
		t[len b:] = buf[0:n];
		b = t;
	}
	if(n < 0)
		return (nil, sys->sprint("%r"));
	return (b, nil);
}

#
# a value is representable in attrdb(6) if it can be written as a word,
# quoted if need be.  A newline cannot: attrdb splits an entry into
# lines before it looks at quoting.
#
representable(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return 0;
	return 1;
}

needquote(s: string): int
{
	if(s == nil)
		return 1;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c <= ' ' || c == '#' || c == '=' || c == '\'' || c == '"')
			return 1;
	}
	return 0;
}

quote(s: string): string
{
	if(!needquote(s))
		return s;
	t := "'";
	for(i := 0; i < len s; i++){
		if(s[i] == '\'')
			t[len t] = '\'';
		t[len t] = s[i];
	}
	t[len t] = '\'';
	return t;
}

pair(attr, val: string): string
{
	return quote(attr) + "=" + quote(val);
}

#
# turn the registry's index into an attrdb(6) database.  Each index line
# is  svcname attr value attr value ...  with sh(1) quoting.  A service
# that carries keyattr becomes an ndb entry keyed on it; one that does
# not is skipped, because rendering, say, a Grid service as a host entry
# would corrupt lookups.
#
render()
{
	(b, err) := readall(regmnt+"/index");
	regerr = err;
	nentry = nskip = ndrop = 0;
	s := "";
	if(err == nil){
		(nil, lines) := sys->tokenize(string b, "\n");
		for(; lines != nil; lines = tl lines){
			toks := str->unquoted(hd lines);
			if(toks == nil)
				continue;
			svcname := hd toks;
			key: string;
			body := "";
			for(t := tl toks; t != nil && tl t != nil; t = tl tl t){
				attr := hd t;
				val := hd tl t;
				if(!representable(attr) || !representable(val)){
					ndrop++;
					continue;
				}
				if(attr == keyattr && key == nil){
					key = val;
					continue;
				}
				#
				# regsvc is this program's name for the
				# registry's service name; a registration
				# that carries one of its own would put two
				# regsvc pairs on the same line, and a
				# lookup would take whichever came first.
				#
				if(attr == "regsvc"){
					ndrop++;
					continue;
				}
				body += " " + pair(attr, val);
			}
			if(key == nil || !representable(svcname)){
				nskip++;
				continue;
			}
			s += pair(keyattr, key) + "\n";
			s += "\t" + pair("regsvc", svcname) + body + "\n\n";
			nentry++;
		}
	}
	mtime = daytime->now();
	gen++;
	hdr := sys->sprint("# generated by ndb/regndb from %s at %s\n", regmnt, daytime->text(daytime->local(mtime)));
	hdr += sys->sprint("# generation %d, %d entries, %d services skipped, %d pairs dropped\n",
		gen, nentry, nskip, ndrop);
	if(err != nil)
		hdr += sys->sprint("# %s\n", err);
	if(!nochain && chain != nil){
		hdr += "database=\n";
		for(c := chain; c != nil; c = tl c)
			hdr += "\tfile=" + quote(hd c) + "\n";
		hdr += "\n";
	}
	data = array of byte (hdr + s);
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		path := int m.path;
		pick n := m {
		Stat =>
			n.reply <-= dirgen(int n.path);
		Walk =>
			if(path != Qroot){
				if(n.name != ".."){
					n.reply <-= (nil, Enotdir);
					continue;
				}
				path = Qroot;
			}else
				case n.name {
				".." =>	;
				"ndb" =>	path = Qndb;
				"ctl" =>	path = Qctl;
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
			n.reply <-= dirgen(path);
		Readdir =>
			if(path != Qroot){
				n.reply <-= (nil, Enotdir);
				break;
			}
			d := array[] of {Qndb, Qctl};
			for(i := n.offset; i < len d; i++)
				n.reply <-= dirgen(d[i]);
			n.reply <-= (nil, nil);
		}
	}
}

dirgen(path: int): (ref Sys->Dir, string)
{
	d := ref sys->zerodir;
	d.qid.path = big path;
	d.uid = d.gid = "network";
	d.dtype = 'r';
	d.atime = d.mtime = mtime;
	case path {
	Qroot =>
		d.name = ".";
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR|8r555;
	Qndb =>
		d.name = "ndb";
		d.qid.vers = gen;
		d.mode = 8r444;
		d.length = big len data;
	Qctl =>
		d.name = "ctl";
		d.qid.vers = gen;
		d.mode = 8r664;
	* =>
		return (nil, Enotfound);
	}
	return (d, nil);
}
