#
#  Vanadium Core port — secure RPC, blessings, and naming for Inferno/Limbo.
#  Concepts follow https://github.com/vanadium/core (v.io/v23).
#  This Limbo encoding is Inferno-native (not wire-compatible with Go VOM).
#

V23security: module
{
	PATH:	con "/dis/lib/v23/security.dis";

	ChainSeparator:	con ":";
	AllPrincipals:	con "...";
	NoExtension:	con "$";

	# Signature purposes (type-attack prevention), as in v23/security.
	PurposeBless:	con "B1";
	PurposeSign:	con "S1";
	PurposeDischarge:	con "D1";

	Caveat: adt
	{
		id:	string;		# "const" | "expiry"
		param:	string;		# "true"/"false" or epoch seconds
	};

	# One certificate in a blessing chain.
	Certificate: adt
	{
		extension:	string;
		pk:		ref Keyring->PK;	# subject
		pkstr:		string;		# exact pktostr used when signing (canonical for digests)
		caveats:	list of Caveat;
		sig:		ref Keyring->Certificate;	# Keyring signature over content
		sigstr:		string;		# exact certtostr used on the wire
	};

	# Cryptographically proven blessing names bound to a public key.
	Blessings: adt
	{
		chains:	list of list of ref Certificate;
		pk:	ref Keyring->PK;
	};

	StoreEntry: adt
	{
		pattern:	string;
		blessings:	ref Blessings;
	};

	RootEntry: adt
	{
		pkstr:	string;
		patterns:	list of string;
	};

	Principal: adt
	{
		sk:	ref Keyring->SK;
		pk:	ref Keyring->PK;
		store:	list of ref StoreEntry;	# peer pattern -> blessings
		def:	ref Blessings;		# default blessings when serving
		roots:	list of ref RootEntry;

		publickey:	fn(p: self ref Principal): ref Keyring->PK;
		blessself:	fn(p: self ref Principal, name: string, cavs: list of Caveat): (ref Blessings, string);
		bless:	fn(p: self ref Principal, key: ref Keyring->PK, with: ref Blessings, ext: string, cavs: list of Caveat): (ref Blessings, string);
		sign:	fn(p: self ref Principal, msg: array of byte): (ref Keyring->Certificate, string);
		setdefault:	fn(p: self ref Principal, b: ref Blessings): string;
		setdefaultnil:	fn(p: self ref Principal);
		store_set:	fn(p: self ref Principal, b: ref Blessings, pattern: string): string;
		forpeer:	fn(p: self ref Principal, peer: list of string): ref Blessings;
		addroot:	fn(p: self ref Principal, b: ref Blessings): string;
		addrootkey:	fn(p: self ref Principal, pk: ref Keyring->PK, pattern: string): string;
	};

	init:	fn(): string;

	createprincipal:	fn(bits: int, owner: string): (ref Principal, string);
	unconstrained:	fn(): Caveat;
	expiry:		fn(until: int): Caveat;	# until = daytime->now() epoch secs

	blessingnames:	fn(b: ref Blessings): list of string;
	encodeblessings:	fn(b: ref Blessings): string;
	decodeblessings:	fn(s: string): (ref Blessings, string);
	verifyblessings:	fn(p: ref Principal, b: ref Blessings): (list of string, list of string);
		# -> (recognized names, rejected "name: reason")

	pattern_valid:	fn(pat: string): int;
	pattern_match:	fn(pat: string, names: list of string): int;

	# ACL: allow if any remote name matches any pattern in `allow`.
	authorize:	fn(allow: list of string, remote: list of string): string;
};

V23rpc: module
{
	PATH:	con "/dis/lib/v23/rpc.dis";

	# Application receives requests on `reqc` and replies on r.reply.
	Request: adt
	{
		method:	string;
		arg:	string;
		remote:	list of string;	# recognized caller blessing names
		reply:	chan of (string, string);	# (result, error)
	};

	Client: adt
	{
		principal:	ref V23security->Principal;
		fd:		ref Sys->FD;
		remote:		list of string;	# server blessing names after handshake
	};

	init:	fn(): string;

	# Announce and accept forever; each connection is served in a spawned thread.
	# allow: blessing patterns authorized to call; reqc receives Requests.
	serve:	fn(addr: string, p: ref V23security->Principal, allow: list of string, reqc: chan of ref Request): string;
	serveconn:	fn(fd: ref Sys->FD, p: ref V23security->Principal, allow: list of string, reqc: chan of ref Request): string;

	dial:	fn(addr: string, p: ref V23security->Principal): (ref Client, string);
	call:	fn(c: ref Client, method: string, arg: string): (string, string);
	close:	fn(c: ref Client);
};
