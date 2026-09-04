# Vanadium security model for Inferno — principals, blessings, caveats, patterns.
# Port of concepts from github.com/vanadium/core (v.io/v23/security).
implement V23security;

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;

include "daytime.m";
	daytime: Daytime;

include "v23.m";

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("load keyring: %r");
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return sys->sprint("load daytime: %r");
	return nil;
}

unconstrained(): Caveat
{
	return Caveat("const", "true");
}

expiry(until: int): Caveat
{
	return Caveat("expiry", string until);
}

createprincipal(bits: int, owner: string): (ref Principal, string)
{
	if(bits <= 0)
		bits = 512;
	if(owner == nil)
		owner = "principal";
	sk := kr->genSK("elgamal", owner, bits);
	if(sk == nil)
		return (nil, "genSK failed");
	pk := kr->sktopk(sk);
	p := ref Principal(sk, pk, nil, nil, nil);
	return (p, nil);
}

Principal.publickey(p: self ref Principal): ref Keyring->PK
{
	return p.pk;
}

Principal.blessself(p: self ref Principal, name: string, cavs: list of Caveat): (ref Blessings, string)
{
	if(name == nil || !ext_ok(name))
		return (nil, "invalid blessing name");
	if(cavs == nil)
		cavs = unconstrained() :: nil;
	(cert, err) := makecert(p.sk, p.pk, name, cavs, nil);
	if(cert == nil)
		return (nil, err);
	b := ref Blessings((cert :: nil) :: nil, p.pk);
	return (b, nil);
}

Principal.bless(p: self ref Principal, key: ref Keyring->PK, with: ref Blessings, ext: string, cavs: list of Caveat): (ref Blessings, string)
{
	if(key == nil || with == nil)
		return (nil, "nil key or blessings");
	if(!ext_ok(ext))
		return (nil, "invalid extension");
	if(cavs == nil)
		return (nil, "at least one caveat required (use unconstrained())");
	if(!pk_eq(with.pk, p.pk))
		return (nil, "with.PublicKey does not match principal");
	chains: list of list of ref Certificate = nil;
	for(cl := with.chains; cl != nil; cl = tl cl){
		chain := hd cl;
		parent := chaindigest(chain);
		(cert, err) := makecert(p.sk, key, ext, cavs, parent);
		if(cert == nil)
			return (nil, err);
		# append cert to copy of chain
		nchain := appendcert(chain, cert);
		chains = nchain :: chains;
	}
	# reverse to preserve order
	out: list of list of ref Certificate = nil;
	for(; chains != nil; chains = tl chains)
		out = hd chains :: out;
	return (ref Blessings(out, key), nil);
}

Principal.sign(p: self ref Principal, msg: array of byte): (ref Keyring->Certificate, string)
{
	if(msg == nil)
		return (nil, "nil message");
	# Keyring sign() accepts sha1/md5/md4 only.
	buf := array of byte PurposeSign;
	state := kr->sha1(buf, len buf, nil, nil);
	kr->sha1(msg, len msg, nil, state);
	cert := kr->sign(p.sk, 0, state, "sha1");
	if(cert == nil)
		return (nil, "sign failed");
	return (cert, nil);
}

Principal.setdefault(p: self ref Principal, b: ref Blessings): string
{
	if(b != nil && !pk_eq(b.pk, p.pk))
		return "blessings not bound to this principal";
	p.def = b;
	return nil;
}

Principal.setdefaultnil(p: self ref Principal)
{
	p.def = nil;
}

Principal.store_set(p: self ref Principal, b: ref Blessings, pattern: string): string
{
	if(!pattern_valid(pattern))
		return "invalid pattern";
	if(b != nil && !pk_eq(b.pk, p.pk))
		return "blessings not bound to this principal";
	# replace existing
	nl: list of ref StoreEntry = nil;
	found := 0;
	for(l := p.store; l != nil; l = tl l){
		e := hd l;
		if(e.pattern == pattern){
			nl = ref StoreEntry(pattern, b) :: nl;
			found = 1;
		}else
			nl = e :: nl;
	}
	if(!found)
		nl = ref StoreEntry(pattern, b) :: nl;
	# reverse
	p.store = revstore(nl);
	return nil;
}

Principal.forpeer(p: self ref Principal, peer: list of string): ref Blessings
{
	best: ref Blessings = nil;
	bestlen := -1;
	for(l := p.store; l != nil; l = tl l){
		e := hd l;
		if(e.blessings == nil)
			continue;
		if(pattern_match(e.pattern, peer)){
			n := blesslen(e.blessings);
			if(n > bestlen){
				best = e.blessings;
				bestlen = n;
			}
		}
	}
	if(best != nil)
		return best;
	return p.def;
}

Principal.addroot(p: self ref Principal, b: ref Blessings): string
{
	if(b == nil)
		return "nil blessings";
	for(cl := b.chains; cl != nil; cl = tl cl){
		chain := hd cl;
		if(chain == nil)
			continue;
		root := hd chain;
		name := claimedname(chain);
		err := p.addrootkey(root.pk, name);
		if(err != nil)
			return err;
	}
	return nil;
}

Principal.addrootkey(p: self ref Principal, pk: ref Keyring->PK, pattern: string): string
{
	if(pk == nil)
		return "nil key";
	if(!pattern_valid(pattern) && pattern != AllPrincipals)
		# allow root pattern as a blessing name prefix pattern
		if(!ext_ok(pattern) && pattern != AllPrincipals)
			return "invalid root pattern";
	pkstr := kr->pktostr(pk);
	for(l := p.roots; l != nil; l = tl l){
		e := hd l;
		if(e.pkstr == pkstr){
			e.patterns = pattern :: e.patterns;
			return nil;
		}
	}
	p.roots = ref RootEntry(pkstr, pattern :: nil) :: p.roots;
	return nil;
}

blessingnames(b: ref Blessings): list of string
{
	if(b == nil)
		return nil;
	names: list of string = nil;
	for(cl := b.chains; cl != nil; cl = tl cl)
		names = claimedname(hd cl) :: names;
	return revstr(names);
}

verifyblessings(p: ref Principal, b: ref Blessings): (list of string, list of string)
{
	ok: list of string = nil;
	bad: list of string = nil;
	if(b == nil)
		return (nil, nil);
	now := daytime->now();
	for(cl := b.chains; cl != nil; cl = tl cl){
		chain := hd cl;
		name := claimedname(chain);
		err := verifychain(chain, now);
		if(err != nil){
			bad = (name + ": " + err) :: bad;
			continue;
		}
		if(!roottrusted(p, chain, name)){
			bad = (name + ": unrecognized root") :: bad;
			continue;
		}
		ok = name :: ok;
	}
	return (revstr(ok), revstr(bad));
}

authorize(allow: list of string, remote: list of string): string
{
	if(allow == nil)
		return "no allow patterns";
	for(a := allow; a != nil; a = tl a)
		if(pattern_match(hd a, remote))
			return nil;
	return "unauthorized";
}

pattern_valid(pat: string): int
{
	if(pat == nil)
		return 0;
	if(pat == AllPrincipals)
		return 1;
	(pstr, nil) := trim_noext(pat);
	if(pstr == nil)
		return 0;
	if(len pstr > 0 && pstr[len pstr - 1] == ':')
		return 0;
	for(s := pstr; s != nil; ){
		(pre, rest) := splitbless(s);
		if(!ext_ok(pre))
			return 0;
		if(rest == nil)
			break;
		s = rest;
	}
	return 1;
}

pattern_match(pat: string, names: list of string): int
{
	if(pat == nil || !pattern_valid(pat))
		return 0;
	if(pat == AllPrincipals)
		return 1;
	(pstr, glob) := trim_noext(pat);
	if(pstr == nil)
		return 0;
	for(n := names; n != nil; n = tl n){
		b := hd n;
		if(b == pstr)
			return 1;
		if(glob && len b > len pstr && b[0:len pstr] == pstr && b[len pstr] == ':')
			return 1;
	}
	return 0;
}

# --- encoding (length-prefixed fields; pk/cert strings contain newlines) ---

encodeblessings(b: ref Blessings): string
{
	if(b == nil)
		return "";
	s := "V23BLESS1\n";
	nch := 0;
	for(cl := b.chains; cl != nil; cl = tl cl)
		nch++;
	s += sys->sprint("%d\n", nch);
	for(cl = b.chains; cl != nil; cl = tl cl){
		chain := hd cl;
		nc := 0;
		for(c := chain; c != nil; c = tl c)
			nc++;
		s += sys->sprint("%d\n", nc);
		for(c = chain; c != nil; c = tl c)
			s += encodecert(hd c);
	}
	return s;
}

decodeblessings(s: string): (ref Blessings, string)
{
	if(s == nil)
		return (nil, "empty");
	pos := 0;
	magic: string;
	(magic, pos) = getline(s, pos);
	if(magic != "V23BLESS1")
		return (nil, "bad magic");
	nchs: string;
	(nchs, pos) = getline(s, pos);
	nch := int nchs;
	chains: list of list of ref Certificate = nil;
	pk: ref Keyring->PK = nil;
	for(i := 0; i < nch; i++){
		ncs: string;
		(ncs, pos) = getline(s, pos);
		nc := int ncs;
		chain: list of ref Certificate = nil;
		for(j := 0; j < nc; j++){
			cert: ref Certificate;
			err: string;
			(cert, pos, err) = decodecert(s, pos);
			if(cert == nil)
				return (nil, err);
			chain = cert :: chain;
		}
		rchain: list of ref Certificate = nil;
		for(; chain != nil; chain = tl chain)
			rchain = hd chain :: rchain;
		if(rchain != nil){
			last := lastcert(rchain);
			if(pk == nil)
				pk = last.pk;
			else if(!pk_eq(pk, last.pk))
				return (nil, "chains disagree on public key");
		}
		chains = rchain :: chains;
	}
	rchains: list of list of ref Certificate = nil;
	for(; chains != nil; chains = tl chains)
		rchains = hd chains :: rchains;
	return (ref Blessings(rchains, pk), nil);
}

encodecert(c: ref Certificate): string
{
	s := "C\n";
	s += putfield(c.extension);
	s += putfield(c.pkstr);
	nc := 0;
	for(l := c.caveats; l != nil; l = tl l)
		nc++;
	s += sys->sprint("%d\n", nc);
	for(l = c.caveats; l != nil; l = tl l){
		cav := hd l;
		s += putfield(cav.id);
		s += putfield(cav.param);
	}
	s += putfield(c.sigstr);
	return s;
}

decodecert(s: string, pos: int): (ref Certificate, int, string)
{
	tag: string;
	(tag, pos) = getline(s, pos);
	if(tag != "C")
		return (nil, pos, "bad cert");
	ext, pkstr, ncs, sigstr: string;
	(ext, pos) = getfield(s, pos);
	(pkstr, pos) = getfield(s, pos);
	pk := kr->strtopk(pkstr);
	if(pk == nil)
		return (nil, pos, "bad pk");
	(ncs, pos) = getline(s, pos);
	nc := int ncs;
	cavs: list of Caveat = nil;
	for(i := 0; i < nc; i++){
		id, param: string;
		(id, pos) = getfield(s, pos);
		(param, pos) = getfield(s, pos);
		cavs = Caveat(id, param) :: cavs;
	}
	rcavs: list of Caveat = nil;
	for(; cavs != nil; cavs = tl cavs)
		rcavs = hd cavs :: rcavs;
	(sigstr, pos) = getfield(s, pos);
	sig := kr->strtocert(sigstr);
	if(sig == nil)
		return (nil, pos, "bad signature");
	return (ref Certificate(ext, pk, pkstr, rcavs, sig, sigstr), pos, nil);
}

putfield(s: string): string
{
	# length in characters, then newline, then payload, then newline.
	# Concatenate payload (do not pass through sprint) so '%' in key material is safe.
	return sys->sprint("%d\n", len s) + s + "\n";
}

getfield(s: string, pos: int): (string, int)
{
	lens: string;
	(lens, pos) = getline(s, pos);
	n := int lens;
	if(n < 0 || pos + n > len s)
		return (nil, pos);
	field := s[pos:pos+n];
	pos += n;
	if(pos < len s && s[pos] == '\n')
		pos++;
	return (field, pos);
}

getline(s: string, pos: int): (string, int)
{
	if(pos >= len s)
		return (nil, pos);
	i := pos;
	while(i < len s && s[i] != '\n')
		i++;
	line := s[pos:i];
	if(i < len s)
		i++;
	return (line, i);
}

# --- internals ---

makecert(sk: ref Keyring->SK, subj: ref Keyring->PK, ext: string, cavs: list of Caveat, parent: array of byte): (ref Certificate, string)
{
	pkstr := kr->pktostr(subj);
	c := ref Certificate(ext, subj, pkstr, cavs, nil, nil);
	dig := contentdigest(c, parent);
	state := kr->sha1(dig, len dig, nil, nil);
	sig := kr->sign(sk, 0, state, "sha1");
	if(sig == nil)
		return (nil, "sign certificate failed");
	c.sig = sig;
	c.sigstr = kr->certtostr(sig);
	return (c, nil);
}

contentdigest(c: ref Certificate, parent: array of byte): array of byte
{
	# purpose || extension || pkstr || caveats || parent
	state := kr->sha1(array of byte PurposeBless, len PurposeBless, nil, nil);
	eb := array of byte c.extension;
	kr->sha1(eb, len eb, nil, state);
	pkb := array of byte c.pkstr;
	kr->sha1(pkb, len pkb, nil, state);
	for(l := c.caveats; l != nil; l = tl l){
		cav := hd l;
		ab := array of byte (cav.id + "=" + cav.param);
		kr->sha1(ab, len ab, nil, state);
	}
	if(parent != nil)
		kr->sha1(parent, len parent, nil, state);
	dig := array[Keyring->SHA1dlen] of byte;
	kr->sha1(nil, 0, dig, state);
	return dig;
}

chaindigest(chain: list of ref Certificate): array of byte
{
	# digest of full chain for linking next cert
	state: ref Keyring->DigestState = nil;
	for(c := chain; c != nil; c = tl c){
		cert := hd c;
		eb := array of byte cert.extension;
		if(state == nil)
			state = kr->sha1(eb, len eb, nil, nil);
		else
			kr->sha1(eb, len eb, nil, state);
		pkb := array of byte cert.pkstr;
		kr->sha1(pkb, len pkb, nil, state);
		sb := array of byte cert.sigstr;
		kr->sha1(sb, len sb, nil, state);
	}
	dig := array[Keyring->SHA1dlen] of byte;
	kr->sha1(nil, 0, dig, state);
	return dig;
}

verifychain(chain: list of ref Certificate, now: int): string
{
	if(chain == nil)
		return "empty chain";
	# Root is self-signed; each subsequent cert is signed by the previous subject key.
	# Parent digest links the chain (Vanadium chainedDigests, simplified).
	prefix: list of ref Certificate = nil;
	for(c := chain; c != nil; c = tl c){
		cert := hd c;
		parent: array of byte = nil;
		issuer: ref Keyring->PK;
		if(prefix == nil)
			issuer = cert.pk;
		else{
			parent = chaindigest(prefix);
			issuer = lastcert(prefix).pk;
		}
		dig := contentdigest(cert, parent);
		state := kr->sha1(dig, len dig, nil, nil);
		if(kr->verify(issuer, cert.sig, state) == 0)
			return "bad signature on " + cert.extension;
		err := checkcaveats(cert.caveats, now);
		if(err != nil)
			return err;
		prefix = appendcert(prefix, cert);
	}
	return nil;
}

checkcaveats(cavs: list of Caveat, now: int): string
{
	for(l := cavs; l != nil; l = tl l){
		cav := hd l;
		case cav.id {
		"const" =>
			if(cav.param != "true")
				return "const caveat failed";
		"expiry" =>
			until := int cav.param;
			if(now > until)
				return "expired";
		* =>
			return "unknown caveat " + cav.id;
		}
	}
	return nil;
}

roottrusted(p: ref Principal, chain: list of ref Certificate, name: string): int
{
	if(chain == nil)
		return 0;
	root := hd chain;
	pkstr := kr->pktostr(root.pk);
	for(l := p.roots; l != nil; l = tl l){
		e := hd l;
		if(e.pkstr != pkstr)
			continue;
		for(pl := e.patterns; pl != nil; pl = tl pl){
			pat := hd pl;
			if(pat == AllPrincipals || pat == name || pattern_match(pat, name :: nil))
				return 1;
			# root registered under the root blessing name matches extensions
			if(pattern_match(pat, name :: nil) || name == pat || prefixname(pat, name))
				return 1;
		}
	}
	return 0;
}

prefixname(pat, name: string): int
{
	# pat "alice" matches "alice:friend"
	if(pat == name)
		return 1;
	if(len name > len pat && name[0:len pat] == pat && name[len pat] == ':')
		return 1;
	return 0;
}

claimedname(chain: list of ref Certificate): string
{
	s := "";
	for(c := chain; c != nil; c = tl c){
		if(s != nil)
			s += ChainSeparator;
		s += (hd c).extension;
	}
	return s;
}

ext_ok(ext: string): int
{
	if(ext == nil)
		return 0;
	if(ext[0] == ':' || ext[len ext - 1] == ':')
		return 0;
	if(ext == NoExtension)
		return 0;
	# forbidden substrings
	for(i := 0; i < len ext; i++){
		case ext[i] {
		',' or '(' or ')' or '<' or '>' or '/' =>
			return 0;
		}
	}
	# no "::"
	for(i = 0; i < len ext - 1; i++)
		if(ext[i] == ':' && ext[i+1] == ':')
			return 0;
	return 1;
}

trim_noext(pattern: string): (string, int)
{
	# returns (pattern without :$, glob?)
	if(pattern == NoExtension)
		return ("", 0);
	suf := ChainSeparator + NoExtension;
	if(len pattern >= len suf && pattern[len pattern - len suf:] == suf)
		return (pattern[0:len pattern - len suf], 0);
	return (pattern, 1);
}

splitbless(in: string): (string, string)
{
	for(i := 0; i < len in; i++)
		if(in[i] == ':')
			return (in[0:i], in[i+1:]);
	return (in, nil);
}

pk_eq(a, b: ref Keyring->PK): int
{
	if(a == nil || b == nil)
		return a == b;
	return kr->pktostr(a) == kr->pktostr(b);
}

appendcert(chain: list of ref Certificate, c: ref Certificate): list of ref Certificate
{
	# return chain || c
	if(chain == nil)
		return c :: nil;
	return hd chain :: appendcert(tl chain, c);
}

lastcert(chain: list of ref Certificate): ref Certificate
{
	if(chain == nil)
		return nil;
	if(tl chain == nil)
		return hd chain;
	return lastcert(tl chain);
}

blesslen(b: ref Blessings): int
{
	n := 0;
	for(cl := b.chains; cl != nil; cl = tl cl)
		n++;
	return n;
}

revstore(l: list of ref StoreEntry): list of ref StoreEntry
{
	r: list of ref StoreEntry = nil;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revstr(l: list of string): list of string
{
	r: list of string = nil;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
