implement Upspin;

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
include "upspin.m";

SIGMARK: con "==UPSPINSIG==\n";

init()
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
}

store(root: string): ref Store
{
	return ref Store(root);
}

dir(root: string): ref Dir
{
	return ref Dir(root);
}

keyserver(root: string): ref KeyServer
{
	return ref KeyServer(root);
}

owner(name: string): string
{
	for(i := 0; i < len name; i++)
		if(name[i] == '/')
			return name[0:i];
	return name;
}

# ------------------------------------------------------------ Store

Store.put(s: self ref Store, data: array of byte): (string, string)
{
	sref := sha256hex(data);
	if(ensuredirp(s.root) != nil)
		return ("", "cannot create store " + s.root);
	path := s.root + "/" + sref;
	if(!exists(path)){
		e := writefile(path, data);
		if(e != nil)
			return ("", e);
	}
	return (sref, nil);
}

# get REHASHES the block and rejects a mismatch: the content-addressing
# guarantee lives in this check, not in the file name.
Store.get(s: self ref Store, sref: string): (array of byte, string)
{
	data := readfile(s.root + "/" + sref);
	if(data == nil)
		return (nil, "missing block " + sref);
	if(sha256hex(data) != sref)
		return (nil, "block " + sref + " fails its content hash");
	return (data, nil);
}

putblocks(s: ref Store, data: array of byte): (list of Block, string)
{
	rblocks: list of Block;
	off := 0;
	if(len data == 0){
		# a single empty block, so even empty content has an entry
		(r, e) := s.put(data[0:0]);
		if(e != nil)
			return (nil, e);
		return (Block(r, 0) :: nil, nil);
	}
	while(off < len data){
		n := len data - off;
		if(n > BLOCKSIZE)
			n = BLOCKSIZE;
		(r, e) := s.put(data[off:off + n]);
		if(e != nil)
			return (nil, e);
		rblocks = Block(r, n) :: rblocks;
		off += n;
	}
	blocks: list of Block;
	for(; rblocks != nil; rblocks = tl rblocks)
		blocks = hd rblocks :: blocks;
	return (blocks, nil);
}

getblocks(s: ref Store, blocks: list of Block): (array of byte, string)
{
	total := 0;
	for(l := blocks; l != nil; l = tl l)
		total += (hd l).size;
	out := array[total] of byte;
	off := 0;
	for(l = blocks; l != nil; l = tl l){
		b := hd l;
		(data, e) := s.get(b.sref);
		if(e != nil)
			return (nil, e);
		if(len data != b.size)
			return (nil, "block " + b.sref + " wrong size");
		out[off:] = data;
		off += len data;
	}
	return (out, nil);
}

# ------------------------------------------------------------ DirEntry

# canonical signed form: name, packing, size, time, writer, then the
# block count and each "ref size" in order. Newline-delimited; names and
# refs contain no newlines. This is the ONE serializer sign and verify use.
DirEntry.signedbytes(e: self ref DirEntry): string
{
	nb := 0;
	for(l := e.blocks; l != nil; l = tl l)
		nb++;
	s := e.name + "\n" +
		string e.packing + "\n" +
		string e.size + "\n" +
		string e.etime + "\n" +
		e.writer + "\n" +
		string nb + "\n";
	for(l = e.blocks; l != nil; l = tl l){
		b := hd l;
		s += b.sref + " " + string b.size + "\n";
	}
	return s;
}

DirEntry.pack(e: self ref DirEntry): string
{
	return e.signedbytes() + SIGMARK + e.sig;
}

unpackentry(s: string): ref DirEntry
{
	idx := indexof(s, SIGMARK);
	if(idx < 0)
		return nil;
	canon := s[0:idx];
	sig := s[idx + len SIGMARK:];
	(nil, lines) := sys->tokenize(canon, "\n");
	# tokenize drops empty fields; require the fixed leading fields.
	if(lgth(lines) < 6)
		return nil;
	name := nth(lines, 0);
	packing := int nth(lines, 1);
	size := big nth(lines, 2);
	etime := int nth(lines, 3);
	writer := nth(lines, 4);
	nb := int nth(lines, 5);
	rblocks: list of Block;
	for(i := 0; i < nb; i++){
		ln := nth(lines, 6 + i);
		(n, f) := sys->tokenize(ln, " ");
		if(n != 2)
			return nil;
		rblocks = Block(hd f, int hd tl f) :: rblocks;
	}
	blocks: list of Block;
	for(; rblocks != nil; rblocks = tl rblocks)
		blocks = hd rblocks :: blocks;
	return ref DirEntry(name, packing, size, etime, writer, blocks, sig);
}

# ------------------------------------------------------------ Dir

Dir.put(d: self ref Dir, e: ref DirEntry): string
{
	(p, err) := entrypath(d.root, e.name);
	if(err != nil)
		return err;
	if((de := ensuredirp(dirname(p))) != nil)
		return de;
	return writefile(p, array of byte e.pack());
}

Dir.lookup(d: self ref Dir, name: string): (ref DirEntry, string)
{
	(p, err) := entrypath(d.root, name);
	if(err != nil)
		return (nil, err);
	data := readfile(p);
	if(data == nil)
		return (nil, "no entry for " + name);
	e := unpackentry(string data);
	if(e == nil)
		return (nil, "corrupt entry for " + name);
	return (e, nil);
}

Dir.glob(d: self ref Dir, own: string): list of string
{
	if(!validowner(own))
		return nil;
	return globwalk(d.root + "/" + own, own);
}

globwalk(dir, prefix: string): list of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	res: list of string;
	for(;;){
		(n, ds) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			nm := ds[i].name;
			if(len nm > 0 && nm[0] == '.' && !hassuffix(nm, ".entry"))
				continue;
			if(ds[i].mode & Sys->DMDIR){
				for(sub := globwalk(dir + "/" + nm, prefix + "/" + nm); sub != nil; sub = tl sub)
					res = hd sub :: res;
			}else if(hassuffix(nm, ".entry"))
				res = prefix + "/" + nm[0:len nm - len ".entry"] :: res;
		}
	}
	return res;
}

# map a name to a Dir file, rejecting any component that would escape the
# owner's subtree. A global name is NOT a filesystem path.
entrypath(root, name: string): (string, string)
{
	own := owner(name);
	if(!validowner(own))
		return ("", "bad owner in name " + name);
	if(len name <= len own + 1 || name[len own] != '/')
		return ("", "name has no path: " + name);
	path := name[len own + 1:];
	(nil, comps) := sys->tokenize(path, "/");
	if(comps == nil)
		return ("", "empty path in " + name);
	for(l := comps; l != nil; l = tl l){
		c := hd l;
		if(c == "" || c == "." || c == "..")
			return ("", "illegal path component in " + name);
	}
	return (root + "/" + own + "/" + path + ".entry", nil);
}

validowner(own: string): int
{
	if(own == "")
		return 0;
	at := 0;
	for(i := 0; i < len own; i++){
		c := own[i];
		if(c == '/' || c == '\n')
			return 0;
		if(c == '@')
			at = 1;
	}
	return at;			# require a user@domain shape
}

# ------------------------------------------------------------ KeyServer

KeyServer.lookup(k: self ref KeyServer, user: string): (ref Keyring->PK, string)
{
	if(!validowner(user))
		return (nil, "bad user " + user);
	data := readfile(k.root + "/" + user);
	if(data == nil)
		return (nil, "no key registered for " + user);
	pk := kr->strtopk(string data);
	if(pk == nil)
		return (nil, "corrupt key for " + user);
	return (pk, nil);
}

KeyServer.register(k: self ref KeyServer, user: string, pk: ref Keyring->PK): string
{
	if(!validowner(user))
		return "bad user " + user;
	if((e := ensuredirp(k.root)) != nil)
		return e;
	return writefile(k.root + "/" + user, array of byte kr->pktostr(pk));
}

# ------------------------------------------------------------ sign/verify

signentry(e: ref DirEntry, sk: ref Keyring->SK): string
{
	st := sha1state(array of byte e.signedbytes());
	cert := kr->sign(sk, 0, st, "sha1");
	if(cert == nil)
		return "sign failed";
	e.sig = kr->certtostr(cert);
	return nil;
}

# verify through the KeyServer: derive the owner from the NAME, look up
# that owner's key, and check the signature over signedbytes(). A key
# carried in the entry is never trusted.
verifyentry(e: ref DirEntry, ks: ref KeyServer): string
{
	own := owner(e.name);
	(pk, err) := ks.lookup(own);
	if(err != nil)
		return err;
	cert := kr->strtocert(e.sig);
	if(cert == nil)
		return "malformed signature";
	st := sha1state(array of byte e.signedbytes());
	if(kr->verify(pk, cert, st) == 0)
		return "signature does not verify for owner " + own;
	return nil;
}

# ------------------------------------------------------------ helpers

sha256hex(data: array of byte): string
{
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(data, len data, dig, nil);
	return hex(dig);
}

sha1state(data: array of byte): ref Keyring->DigestState
{
	return kr->sha1(data, len data, nil, nil);
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
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

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

dirname(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[0:i];
	return ".";
}

lgth(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

nth(l: list of string, i: int): string
{
	for(; i > 0 && l != nil; i--)
		l = tl l;
	if(l == nil)
		return "";
	return hd l;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

ensuredirp(path: string): string
{
	(nil, elems) := sys->tokenize(path, "/");
	abs := len path > 0 && path[0] == '/';
	cur := "";
	for(; elems != nil; elems = tl elems){
		if(cur == "")
			cur = ("/" + hd elems)[abs == 0:];
		else
			cur += "/" + hd elems;
		if(!exists(cur)){
			fd := sys->create(cur, Sys->OREAD, Sys->DMDIR | 8r777);
			if(fd == nil)
				return sys->sprint("create %s: %r", cur);
		}
	}
	return nil;
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

writefile(path: string, data: array of byte): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	if(sys->write(fd, data, len data) != len data)
		return sys->sprint("write %s: %r", path);
	return nil;
}
