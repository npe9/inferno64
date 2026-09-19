#
# TLS 1.2 client - see doc/ssl-modernization-plan.md.
# Grew out of the PRF (RFC 5246 5); now carries the full client-side
# handshake (ECDHE-RSA over X25519) and AEAD record layer for exactly
# the two cipher suites that plan measured as sufficient for its real
# targets. Include sys.m and keyring.m before this file.
#
# client() verifies the server's certificate chain against the trust
# roots at CAPATH and checks the ServerKeyExchange signature against
# the leaf certificate's key, so an established Session is both
# encrypted and authenticated to the named hostname. What it does NOT
# do: revocation checking (no CRL/OCSP), name constraints, or policy
# processing.
#

TLS12: module
{
	PATH: con "/dis/lib/crypt/tls12.dis";

	init: fn(): string;

	# TLS 1.2's own PRF (RFC 5246 5): HMAC-SHA256 based, unlike the
	# dual MD5+SHA1 PRF SSLv3/TLS1.0 use (module/ssl3.m's own PRF,
	# untouched by this - a different protocol version's construction).
	# Returns n pseudorandom bytes derived from secret+label+seed.
	prf: fn(secret: array of byte, label: string, seed: array of byte, n: int): array of byte;

	# the two cipher suites doc/ssl-modernization-plan.md measured as
	# sufficient for its real targets - the only ones client() offers
	CS_ECDHE_RSA_AES128_GCM_SHA256: con 16rC02F;
	CS_ECDHE_RSA_CHACHA20_POLY1305: con 16rCCA8;

	# the trust roots client() verifies server chains against: a
	# frozen copy of Mozilla's root CA bundle, shipped in the tree
	# (the "frozen bundle, like a real OS distribution" option from
	# doc/ssl-modernization-plan.md's trust-root discussion; update
	# it from https://curl.se/ca/cacert.pem when it goes stale)
	CAPATH: con "/lib/tls/ca-bundle.pem";

	# The same roots as concatenated DER, which is what loadroots
	# reads when it can: a DER certificate is self-delimiting, so the
	# whole bundle is one read and a walk down the tag/length
	# headers, against 1.5 s of bufio and 1.7 s of base64 for the PEM
	# in interpreted Dis.  scripts/mkcabundle.sh makes it from the
	# PEM and scripts/check-cabundle.sh checks the two agree.
	CAPATHDER: con "/lib/tls/ca-bundle.der";

	# parse a PEM certificate bundle into DER certs (path nil = CAPATH).
	# client() calls this itself and caches the result; it is exported
	# so tests can hand doctored root sets to x509->verify_chain_host.
	loadroots: fn(path: string): (list of array of byte, string);

	# An established TLS 1.2 session. Fields are exposed the way every
	# Limbo adt's are; treat everything except cipher/certs and the
	# three methods as internal record-layer state.
	Session: adt
	{
		fd: ref Sys->FD;
		cipher: int;			# negotiated suite, one of the two above
		certs: list of array of byte;	# server chain, DER, in wire order (verified)
		err: string;			# sticky record-layer error, nil while healthy

		# record layer internals: per-direction sequence numbers,
		# AEAD states (gcm or cc set per cipher), fixed IV parts,
		# and buffered decrypted-but-unread application data
		wseq, rseq: big;
		wgcm, rgcm: ref Keyring->AESGCMstate;
		wcc, rcc: ref Keyring->Chachastate;
		wiv, riv: array of byte;
		rbuf: array of byte;
		reof: int;
		ron: int;		# read cipher engaged (server ChangeCipherSpec seen)

		# write n bytes of application data; returns n or -1 (err set)
		write: fn(s: self ref Session, buf: array of byte, n: int): int;
		# read up to n bytes of application data; 0 at clean close, -1 on error (err set)
		read: fn(s: self ref Session, buf: array of byte, n: int): int;
		# send close_notify and stop using the session (fd itself is the caller's)
		close: fn(s: self ref Session);
	};

	# Run a full TLS 1.2 client handshake over fd (an established TCP
	# connection): ClientHello (with SNI naming hostname) through both
	# Finished messages, ECDHE key exchange over X25519 only. suites
	# lists the cipher suites to offer, in preference order (nil =
	# both CS_* above). Returns (session, nil) or (nil, diagnostic).
	# The server's certificate chain is verified against CAPATH's
	# trust roots and must name hostname (x509->verify_chain_host),
	# and the ServerKeyExchange signature is checked against the
	# leaf's key - a failure of either aborts the handshake.
	client: fn(fd: ref Sys->FD, hostname: string, suites: list of int): (ref Session, string);
};
