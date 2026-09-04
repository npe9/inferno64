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
# separates the signer public key from the certificate in a .sig file.
# Both keyring strings are multi-line base64, so a marker that never
# occurs in that alphabet is needed to split them.
SIGMARK: con "==PKGCERT==\n";

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
	"genkey" =>	cmdgenkey(args);
	"sign" =>	cmdsign(args);
	"verify" =>	cmdverify(args);
	"publish" =>	cmdpublish(args);
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
	pin := "";			# -k pkfile: required signer public key
	repo := "";			# -r repodir: resolve a name here
	while(args != nil && len hd args > 0 && (hd args)[0] == '-'){
		f := hd args;
		args = tl args;
		if(args == nil)
			usage();
		case f {
		"-k" =>	pin = hd args;
		"-r" =>	repo = hd args;
		* =>	usage();
		}
		args = tl args;
	}
	if(args == nil)
		usage();
	arg := hd args;

	# arg is either an archive file (install it directly) or a repository
	# name like "util/pkgdemo" resolved to a version under the repository
	# (-r, else /pkg or $PKGPATH). Name resolution IS the naming layer:
	# the repository is a directory tree walked by name.
	tarpath: string;
	if(exists(arg)){
		tarpath = arg;
	}else{
		base := repo;
		if(base == "")
			base = pkgpath();
		(tp, rerr) := resolvename(base, arg);
		if(rerr != nil)
			fail(rerr);
		tarpath = tp;
		sys->print("resolved %s -> %s\n", arg, tarpath);
	}

	# signature check (M2). A detached tarpath.sig authenticates the
	# archive's content. With -k the signature is required and its signer
	# must match the pinned key; without -k an unsigned package installs
	# with a warning, a signed one is still verified.
	sigpath := tarpath + ".sig";
	if(exists(sigpath)){
		(owner, pkstr, verr) := verifytar(tarpath, sigpath);
		if(verr != nil)
			fail("signature: " + verr);
		if(pin != "" && pkstr != readstr(pin))
			fail("signer key does not match -k " + pin);
		sys->print("signature ok, signed by %s\n", owner);
	}else{
		if(pin != "")
			fail("no signature (" + sigpath + ") but -k requires one");
		sys->fprint(stderr, "pkg: warning: installing unsigned package %s\n", tarpath);
	}

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

cmdgenkey(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	owner := hd args;
	skfile := hd tl args;
	bits := 1024;
	if(tl tl args != nil)
		bits = int hd tl tl args;
	sk := kr->genSK("rsa", owner, bits);
	if(sk == nil)
		fail("genSK failed");
	e := writefile(skfile, array of byte kr->sktostr(sk));
	if(e != nil)
		fail(e);
	e = writefile(skfile + ".pk", array of byte kr->pktostr(kr->sktopk(sk)));
	if(e != nil)
		fail(e);
	sys->print("wrote secret key %s and public key %s.pk for %s\n", skfile, skfile, owner);
}

cmdsign(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	tarpath := hd args;
	skfile := hd tl args;
	sk := kr->strtosk(readstr(skfile));
	if(sk == nil)
		fail("cannot read secret key " + skfile);
	(state, derr) := digeststate(tarpath);
	if(derr != nil)
		fail(derr);
	cert := kr->sign(sk, 0, state, "sha1");
	if(cert == nil)
		fail("sign failed");
	pk := kr->sktopk(sk);
	sig := kr->pktostr(pk) + SIGMARK + kr->certtostr(cert);
	e := writefile(tarpath + ".sig", array of byte sig);
	if(e != nil)
		fail(e);
	sys->print("signed %s -> %s.sig by %s\n", tarpath, tarpath, pk.owner);
}

cmdverify(args: list of string)
{
	pin := "";
	if(args != nil && hd args == "-k"){
		args = tl args;
		if(args == nil)
			usage();
		pin = hd args;
		args = tl args;
	}
	if(args == nil)
		usage();
	tarpath := hd args;
	(owner, pkstr, verr) := verifytar(tarpath, tarpath + ".sig");
	if(verr != nil)
		fail("signature: " + verr);
	if(pin != "" && pkstr != readstr(pin))
		fail("signer key does not match -k " + pin);
	sys->print("%s: signature ok, signed by %s\n", tarpath, owner);
}

# a sha1 DigestState with the whole tar streamed in but NOT finalized -
# the exact state kr->sign and kr->verify both expect (the keyring
# Certificate path signs sha1 digests, as auth/signer.b etc. do; the
# sha256 content address in install/info is a separate concern). sign and
# verify must build this identically or verification cannot succeed.
digeststate(path: string): (ref Keyring->DigestState, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", path));
	state: ref Keyring->DigestState;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("read %s: %r", path));
		if(n == 0)
			break;
		state = kr->sha1(buf, n, nil, state);
	}
	return (state, nil);
}

# verify tarpath against its .sig. Returns (signer owner, signer pk
# string, error). error non-nil means the signature is absent, malformed,
# or does not match the archive's current bytes.
verifytar(tarpath, sigpath: string): (string, string, string)
{
	sigb := readfile(sigpath);
	if(sigb == nil)
		return ("", "", "no signature file " + sigpath);
	sig := string sigb;
	idx := indexof(sig, SIGMARK);
	if(idx < 0)
		return ("", "", "malformed signature file");
	pkstr := sig[0:idx];
	certstr := sig[idx + len SIGMARK:];
	pk := kr->strtopk(pkstr);
	cert := kr->strtocert(certstr);
	if(pk == nil || cert == nil)
		return ("", "", "malformed key or certificate");
	(state, derr) := digeststate(tarpath);
	if(derr != nil)
		return ("", "", derr);
	if(kr->verify(pk, cert, state) == 0)
		return ("", "", "signature does not verify (archive tampered or wrong key)");
	return (pk.owner, trim(pkstr), nil);
}

# pkg publish repo pkg.tar - place an archive into a repository at
# repo/<name>/<version>.tar (+ .sig), the layout resolvename walks. This
# is the local form of the write side (doc/package-management.md #7); the
# remote DirServer publish is a later milestone.
cmdpublish(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	repo := hd args;
	pkgtar := hd tl args;
	m := manifestfromtar(pkgtar);
	if(m == nil)
		fail("no pkg/manifest in " + pkgtar);
	name := m.get("name");
	ver := m.get("version");
	if(name == "" || ver == "")
		fail("manifest is missing name or version");
	dir := repo + "/" + name;
	ensuredirp(dir);
	dst := dir + "/" + ver + ".tar";
	e := copyfile(pkgtar, dst);
	if(e != nil)
		fail(e);
	if(exists(pkgtar + ".sig")){
		e = copyfile(pkgtar + ".sig", dst + ".sig");
		if(e != nil)
			fail(e);
	}
	sys->print("published %s %s to %s\n", name, ver, dst);
}

# the default repository search root, overridable by $PKGPATH. A user
# binds a served repository (or a local one) at /pkg and then installs by
# name; -r overrides for a one-off.
pkgpath(): string
{
	e := readstr("/env/PKGPATH");
	if(e == "")
		return "/pkg";
	return e;
}

# resolve a repository name (e.g. "util/pkgdemo") to a version archive
# under base. Picks the lexically-greatest <version>.tar; that is the
# ordering, not semantic-version comparison (a later refinement).
resolvename(base, name: string): (string, string)
{
	dir := base + "/" + name;
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("no package %s under %s", name, base));
	best := "";
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(hassuffix(d[i].name, ".tar") && d[i].name > best)
				best = d[i].name;
	}
	if(best == "")
		return ("", "no versions of " + name + " under " + base);
	return (dir + "/" + best, nil);
}

# read a package's manifest by peeking inside the tar (temporary mount).
manifestfromtar(tarpath: string): ref Manifest
{
	ensuredir(PKGROOT);
	tmp := PKGROOT + "/.peek";
	sys->unmount(nil, tmp);
	ensuredir(tmp);
	mounttar(tarpath, tmp);
	m := readmanifest(tmp + "/pkg/manifest");
	sys->unmount(nil, tmp);
	sys->remove(tmp);
	return m;
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

readstr(path: string): string
{
	data := readfile(path);
	if(data == nil)
		return "";
	return trim(string data);
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

indexof(s, sub: string): int
{
	n := len s;
	m := len sub;
	for(i := 0; i <= n - m; i++)
		if(s[i:i + m] == sub)
			return i;
	return -1;
}

writefile(path: string, data: array of byte): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	if(sys->write(fd, data, len data) != len data)
		return sys->sprint("write %s: %r", path);
	return nil;
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

# mkdir -p: create every missing component of path (absolute or relative).
ensuredirp(path: string)
{
	(nil, elems) := sys->tokenize(path, "/");
	abs := len path > 0 && path[0] == '/';
	cur := "";
	for(; elems != nil; elems = tl elems){
		if(cur == "")
			cur = ("/" + hd elems)[abs == 0:];	# no leading / if relative
		else
			cur += "/" + hd elems;
		ensuredir(cur);
	}
}

copyfile(src, dst: string): string
{
	data := readfile(src);
	if(data == nil)
		return "cannot read " + src;
	return writefile(dst, data);
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

usage()
{
	sys->fprint(stderr, "usage: pkg pack stagedir out.tar\n");
	sys->fprint(stderr, "       pkg genkey owner skfile\n");
	sys->fprint(stderr, "       pkg sign pkg.tar skfile\n");
	sys->fprint(stderr, "       pkg verify [-k pkfile] pkg.tar\n");
	sys->fprint(stderr, "       pkg publish repo pkg.tar\n");
	sys->fprint(stderr, "       pkg install [-k pkfile] [-r repo] pkg.tar|name\n");
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
