implement Cloudfs;

#
# The provider's metadata service, served as a file tree.
#
# Every cloud SDK's first act is a GET to a link-local address for the
# instance's identity and a credential.  On Compute Engine that is
# http://169.254.169.254/computeMetadata/v1/..., answered only if the
# request carries "Metadata-Flavor: Google", and the reply to
# .../service-accounts/default/token is the bearer token that every
# authenticated call to a Google API needs.
#
# Mounted, that becomes "cat /cloud/token" and "cat /cloud/zone", with
# no library to link and nothing provider-specific compiled into the
# program that uses it.  It is the smallest piece of the argument in
# doc/inferno-cloud-modern.ms that can be built and checked: the control
# plane as a namespace rather than an SDK.
#
# Each read is a fresh fetch, made when the file is opened.  Tokens
# expire, so a cached one is a bug waiting for an hour to pass.
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
	Styxserver, Navigator, readbytes: import styxservers;
	Enotfound, Eperm: import Styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "httpclient.m";
	http: Httpclient;
	Hdr: import http;

Cloudfs: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot: con big 0;

File: adt {
	name:	string;
	path:	string;		# appended to the metadata base url
};

# Compute Engine's names.  Another provider is another table and the
# same program; nothing below this line knows it is talking to Google.
files := array[] of {
	File("id",		"computeMetadata/v1/instance/id"),
	File("name",		"computeMetadata/v1/instance/name"),
	File("hostname",	"computeMetadata/v1/instance/hostname"),
	File("zone",		"computeMetadata/v1/instance/zone"),
	File("machine-type",	"computeMetadata/v1/instance/machine-type"),
	File("project",		"computeMetadata/v1/project/project-id"),
	File("ip",		"computeMetadata/v1/instance/network-interfaces/0/ip"),
	File("token",		"computeMetadata/v1/instance/service-accounts/default/token"),
};

base := "http://169.254.169.254/";
mdhdr := "Metadata-Flavor: Google";
tree: ref Tree;
fetched: array of array of byte;	# by fid, filled at open

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
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
	http = load Httpclient Httpclient->PATH;
	if(http == nil)
		fail(sys->sprint("cannot load %s: %r", Httpclient->PATH));
	if((e := http->init()) != nil)
		fail(e);

	arg->init(argv);
	arg->setusage("cloudfs [-a baseurl] [-H 'name: value']");
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	base = arg->earg();
			if(len base > 0 && base[len base - 1] != '/')
				base[len base] = '/';
		'H' =>	mdhdr = arg->earg();
		* =>	arg->usage();
		}

	navop: chan of ref Styxservers->Navop;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);
	(tchan, srv) := Styxserver.new(sys->fildes(0), nav, Qroot);

	tree.create(Qroot, dir(".", Sys->DMDIR | 8r555, Qroot));
	for(i := 0; i < len files; i++)
		tree.create(Qroot, dir(files[i].name, 8r444, big (i + 1)));

	fetched = array[64] of array of byte;

	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		pick m := gm {
		Open =>
			f := srv.getfid(m.fid);
			if(f == nil || f.path == Qroot){
				srv.default(gm);
				continue;
			}
			i := int f.path - 1;
			if(i < 0 || i >= len files){
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				continue;
			}
			(data, err) := fetch(files[i].path);
			if(err != nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				continue;
			}
			if(m.fid >= len fetched){
				nf := array[m.fid * 2 + 1] of array of byte;
				nf[0:] = fetched;
				fetched = nf;
			}
			fetched[m.fid] = data;
			srv.default(gm);
		Read =>
			f := srv.getfid(m.fid);
			if(f == nil || f.path == Qroot || m.fid >= len fetched
			|| fetched[m.fid] == nil){
				srv.default(gm);
				continue;
			}
			srv.reply(styxservers->readbytes(m, fetched[m.fid]));
		Clunk =>
			if(m.fid < len fetched)
				fetched[m.fid] = nil;
			srv.default(gm);
		* =>
			srv.default(gm);
		}
	}
}

fetch(path: string): (array of byte, string)
{
	hdrs: list of Hdr;
	for(i := 0; i < len mdhdr; i++)
		if(mdhdr[i] == ':'){
			v := mdhdr[i+1:];
			while(len v > 0 && v[0] == ' ')
				v = v[1:];
			hdrs = Hdr(mdhdr[0:i], v) :: nil;
			break;
		}
	(r, err) := http->get(base + path, hdrs);
	if(err != nil)
		return (nil, err);
	if(r.code != 200)
		return (nil, sys->sprint("metadata: http %d %s", r.code, r.reason));
	return (r.body, nil);
}

dir(name: string, perm: int, path: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "cloud";
	d.gid = "cloud";
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
	sys->fprint(sys->fildes(2), "cloudfs: %s\n", s);
	raise "fail:" + s;
}
