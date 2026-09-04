#
# Upspin-style content namespace for Inferno: a content-addressed Store, a
# signed Dir of owner-rooted global names, and a KeyServer mapping
# user@domain to a public key. Content is split into content-addressed
# blocks; a name maps to a DirEntry that lists those blocks and is signed
# by the owner. A reader verifies through the KeyServer (name -> owner ->
# key), so integrity does not rest on any key carried inside the entry.
# Concepts follow upspin.io; not wire-compatible with the Go implementation.
#
Upspin: module
{
	PATH:	con "/dis/lib/upspin.dis";

	BLOCKSIZE:	con 1024 * 1024;	# fixed 1 MiB blocks (Upspin's choice)

	PlainPack:	con 0;			# unencrypted (but signed) packing

	# one content-addressed block of a file's content.
	Block: adt {
		sref:	string;			# sha256 hex - the content address
		size:	int;
	};

	# the signed directory record naming a piece of content.
	DirEntry: adt {
		name:		string;		# user@domain/path
		packing:	int;
		size:		big;
		etime:		int;
		writer:		string;		# who signed (user@domain)
		blocks:		list of Block;
		sig:		string;		# keyring certtostr over signedbytes()

		# the exact bytes that are signed and verified: every field that
		# must not change under a valid signature - the name and the
		# ordered block refs above all. sign and verify MUST use this.
		signedbytes:	fn(e: self ref DirEntry): string;
		# full on-disk form: signedbytes() + marker + sig.
		pack:		fn(e: self ref DirEntry): string;
	};

	# content-addressed block store. get rehashes and rejects a mismatch.
	Store: adt {
		root:	string;
		put:	fn(s: self ref Store, data: array of byte): (string, string);
		get:	fn(s: self ref Store, sref: string): (array of byte, string);
	};

	# maps an owner-rooted global name to a DirEntry.
	Dir: adt {
		root:	string;
		put:	fn(d: self ref Dir, e: ref DirEntry): string;
		lookup:	fn(d: self ref Dir, name: string): (ref DirEntry, string);
		glob:	fn(d: self ref Dir, own: string): list of string;
	};

	# maps user@domain to a public key.
	KeyServer: adt {
		root:	string;
		lookup:		fn(k: self ref KeyServer, user: string): (ref Keyring->PK, string);
		register:	fn(k: self ref KeyServer, user: string, pk: ref Keyring->PK): string;
	};

	init:		fn();
	store:		fn(root: string): ref Store;
	dir:		fn(root: string): ref Dir;
	keyserver:	fn(root: string): ref KeyServer;

	# split data into fixed blocks, store them, return the block list;
	# and the inverse (each block hash-verified on the way back).
	putblocks:	fn(s: ref Store, data: array of byte): (list of Block, string);
	getblocks:	fn(s: ref Store, blocks: list of Block): (array of byte, string);

	# sign an entry with sk; verify one through the KeyServer (name ->
	# owner -> key). verifyentry returns nil on success, else why not.
	signentry:	fn(e: ref DirEntry, sk: ref Keyring->SK): string;
	verifyentry:	fn(e: ref DirEntry, ks: ref KeyServer): string;

	# the user@domain part of a name (before the first '/').
	owner:		fn(name: string): string;

	# unpack an on-disk entry produced by DirEntry.pack().
	unpackentry:	fn(s: string): ref DirEntry;
};
