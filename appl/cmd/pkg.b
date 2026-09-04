implement Command;

# pkg(1) - a namespace-native package manager (milestone 1: local
# format + install-by-mount). A package is a tar containing pkg/manifest
# (ndb-style attr/value lines) plus dis/, man/, lib/ trees. "Installing"
# is not a copy into a shared tree: the tar is mounted read-only with
# tarfs(4) at /mnt/pkg/<content-sha256> and its dis/ (and man/) are bound
# into the namespace, so a package's commands resolve by bare name. That
# makes install per-namespace, unprivileged and reversible (remove =
# unbind + unmount), and names each install by the content hash of its
# tar. See doc/pkg-roadmap.md; signing, a /pkg naming service and search
# are later milestones.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Command: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

PKGROOT: con "/mnt/pkg";
IDLEN: con 16;			# short content id (hex chars) used as mountpoint

stderr: ref Sys->FD;

Manifest: adt {
	pairs:	list of (string, string);
	get:	fn(m: self ref Manifest, attr: string): string;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		fail(sys->sprint("load keyring: %r"));

	argv = tl argv;
	if(argv == nil)
		usage();
	cmd := hd argv;
	args := tl argv;
	case cmd {
	"pack" =>	cmdpack(args);
	"info" =>	cmdinfo(args);
	"install" =>	cmdinstall(args);
	"list" =>	cmdlist(args);
	"remove" or "uninstall" =>	cmdremove(args);
	* =>		usage();
	}
}

cmdpack(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	stagedir := hd args;
	outfile := hd tl args;
	if(!exists(stagedir + "/pkg/manifest"))
		fail("staging dir has no pkg/manifest");
	subs: list of string;
	for(s := "lib" :: "man" :: "dis" :: "pkg" :: nil; s != nil; s = tl s)
		if(exists(stagedir + "/" + hd s))
			subs = hd s :: subs;
	sync := chan of string;
	spawn packproc(stagedir, outfile, subs, sync);
	e := <-sync;
	if(e != nil)
		fail(e);
	(id, err) := sha256file(outfile);
	if(err != nil)
		fail(err);
	sys->print("packed %s (%s)\n", outfile, id[0:IDLEN]);
}

# runs puttar with stdout redirected to outfile and cwd = stagedir, in a
# private fd table and namespace so the redirection/chdir do not leak.
packproc(stagedir, outfile: string, subs: list of string, sync: chan of string)
{
	sys->pctl(Sys->FORKNS | Sys->FORKFD, nil);
	ofd := sys->create(outfile, Sys->OWRITE, 8r644);
	if(ofd == nil){
		sync <-= sys->sprint("create %s: %r", outfile);
		exit;
	}
	sys->dup(ofd.fd, 1);
	ofd = nil;
	if(sys->chdir(stagedir) < 0){
		sync <-= sys->sprint("chdir %s: %r", stagedir);
		exit;
	}
	puttar := load Command "/dis/puttar.dis";
	if(puttar == nil){
		sync <-= "load puttar";
		exit;
	}
	puttar->init(nil, "puttar" :: subs);
	sync <-= nil;
}

cmdinfo(args: list of string)
{
	if(args == nil)
		usage();
	tarpath := hd args;
	(full, err) := sha256file(tarpath);
	if(err != nil)
		fail(err);
	ensuredir(PKGROOT);
	tmp := PKGROOT + "/.info";
	ensuredir(tmp);
	mounttar(tarpath, tmp);
	data := readfile(tmp + "/pkg/manifest");
	sys->unmount(nil, tmp);
	sys->remove(tmp);
	if(data == nil)
		fail("no pkg/manifest in package");
	sys->print("content-sha256 %s\n", full);
	sys->print("%s", string data);
}

cmdinstall(args: list of string)
{
	if(args == nil)
		usage();
	tarpath := hd args;
	(id, err) := sha256file(tarpath);
	if(err != nil)
		fail(err);
	id = id[0:IDLEN];
	ensuredir(PKGROOT);
	mnt := PKGROOT + "/" + id;
	if(!exists(mnt + "/pkg/manifest")){
		ensuredir(mnt);
		mounttar(tarpath, mnt);
	}
	m := readmanifest(mnt + "/pkg/manifest");
	if(m == nil)
		fail("no pkg/manifest in package");
	bindif(mnt + "/dis", "/dis");
	bindif(mnt + "/man", "/man");
	sys->print("installed %s %s (%s)\n", m.get("name"), m.get("version"), id);
}

cmdlist(nil: list of string)
{
	fd := sys->open(PKGROOT, Sys->OREAD);
	if(fd == nil)
		return;			# nothing installed
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			id := dirs[i].name;
			if(len id > 0 && id[0] == '.')
				continue;
			m := readmanifest(PKGROOT + "/" + id + "/pkg/manifest");
			if(m != nil)
				sys->print("%-20s %-10s %s\n", m.get("name"), m.get("version"), id);
		}
	}
}

cmdremove(args: list of string)
{
	if(args == nil)
		usage();
	name := hd args;
	fd := sys->open(PKGROOT, Sys->OREAD);
	if(fd == nil)
		fail("no packages installed");
	ids: list of string;
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			ids = dirs[i].name :: ids;
	}
	found := 0;
	for(; ids != nil; ids = tl ids){
		id := hd ids;
		if(len id > 0 && id[0] == '.')
			continue;
		mnt := PKGROOT + "/" + id;
		m := readmanifest(mnt + "/pkg/manifest");
		if(m != nil && m.get("name") == name){
			sys->unmount(mnt + "/dis", "/dis");
			sys->unmount(mnt + "/man", "/man");
			sys->unmount(nil, mnt);
			sys->remove(mnt);
			sys->print("removed %s (%s)\n", name, id);
			found = 1;
		}
	}
	if(!found)
		fail("no installed package named " + name);
}

# spawn tarfs to serve tarpath at mnt and wait until the mount is live.
mounttar(tarpath, mnt: string)
{
	tarfs := load Command "/dis/tarfs.dis";
	if(tarfs == nil)
		fail("load tarfs");
	spawn tarfs->init(nil, "tarfs" :: tarpath :: mnt :: nil);
	for(i := 0; i < 200; i++){
		if(exists(mnt + "/pkg/manifest") || exists(mnt + "/dis"))
			return;
		sys->sleep(10);
	}
	fail("tarfs mount " + mnt + " did not become ready");
}

# bind src after the current contents of dst, but only if src exists
# (man/ and lib/ are optional in a package).
bindif(src, dst: string)
{
	if(!exists(src))
		return;
	if(sys->bind(src, dst, Sys->MAFTER) < 0)
		fail(sys->sprint("bind %s %s: %r", src, dst));
}

readmanifest(path: string): ref Manifest
{
	data := readfile(path);
	if(data == nil)
		return nil;
	return manifestparse(data);
}

# one package's attributes: "attr value" per line, # comments and blank
# lines ignored. attr is the first whitespace-delimited token; the value
# is the rest of the line. This is the ndb/registry(4) attribute shape,
# so the same manifest drives a registry query index later.
manifestparse(data: array of byte): ref Manifest
{
	rp: list of (string, string);
	(nil, lines) := sys->tokenize(string data, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		i := 0;
		while(i < len line && (line[i] == ' ' || line[i] == '\t'))
			i++;
		line = line[i:];
		if(line == "" || line[0] == '#')
			continue;
		j := 0;
		while(j < len line && line[j] != ' ' && line[j] != '\t')
			j++;
		attr := line[0:j];
		while(j < len line && (line[j] == ' ' || line[j] == '\t'))
			j++;
		rp = (attr, line[j:]) :: rp;
	}
	pairs: list of (string, string);
	for(; rp != nil; rp = tl rp)
		pairs = hd rp :: pairs;
	return ref Manifest(pairs);
}

Manifest.get(m: self ref Manifest, attr: string): string
{
	for(l := m.pairs; l != nil; l = tl l){
		(a, v) := hd l;
		if(a == attr)
			return v;
	}
	return "";
}

sha256file(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("open %s: %r", path));
	state: ref Keyring->DigestState;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return ("", sys->sprint("read %s: %r", path));
		if(n == 0)
			break;
		state = kr->sha256(buf, n, nil, state);
	}
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, dig, state);
	return (hex(dig), nil);
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	return out;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

ensuredir(path: string)
{
	if(exists(path))
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r777);
	if(fd == nil)
		fail(sys->sprint("create %s: %r", path));
}

usage()
{
	sys->fprint(stderr, "usage: pkg pack stagedir out.tar\n");
	sys->fprint(stderr, "       pkg install pkg.tar\n");
	sys->fprint(stderr, "       pkg info pkg.tar\n");
	sys->fprint(stderr, "       pkg list\n");
	sys->fprint(stderr, "       pkg remove name\n");
	raise "fail:usage";
}

fail(m: string)
{
	sys->fprint(stderr, "pkg: %s\n", m);
	raise "fail:" + m;
}
