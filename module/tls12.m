#
# TLS 1.2 client - see doc/ssl-modernization-plan.md.
# Grew out of the PRF (RFC 5246 5); now carries the full client-side
# handshake (ECDHE-RSA over X25519) and AEAD record layer for exactly
# the two cipher suites that plan measured as sufficient for its real
# targets. Include sys.m and keyring.m before this file.
#
# WARNING: client() READS the server's certificate chain but does NOT
# verify it (doc/ssl-modernization-plan.md's own open gap). A Session
# is encrypted but NOT authenticated - do not present it as a secure
# connection until chain verification lands.
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

	# An established TLS 1.2 session. Fields are exposed the way every
	# Limbo adt's are; treat everything except cipher/certs and the
	# three methods as internal record-layer state.
	Session: adt
	{
		fd: ref Sys->FD;
		cipher: int;			# negotiated suite, one of the two above
		certs: list of array of byte;	# server chain, DER, in wire order - NOT VERIFIED
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
	# Repeat: the certificate chain is parsed, surfaced in
	# Session.certs, and NOT verified.
	client: fn(fd: ref Sys->FD, hostname: string, suites: list of int): (ref Session, string);
};
