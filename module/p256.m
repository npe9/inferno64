#
# NIST elliptic-curve operations for the TLS stack's ECDHE-ECDSA path
# (tls12(2)): ECDSA signature verification and ECDH key agreement.
# Pure IPint arithmetic - no native code. Include keyring.m before
# this.
#
# ECDH is P-256 only (the key-exchange curve this client offers).
# ecdsa_verify handles BOTH P-256 and P-384, chosen by the public
# key's size - real certificate chains routinely put a P-256 leaf
# under a P-384 intermediate, so chain verification needs both.
#
# Points are the TLS/SEC1 uncompressed encoding 0x04 || X || Y (65
# bytes for P-256, 97 for P-384); scalars and coordinates are
# big-endian.
#

P256: module
{
	PATH: con "/dis/lib/crypt/p256.dis";

	init: fn(): string;

	# Verify an ECDSA signature. hash is the message digest (its size
	# selects the SHA variant implicitly - the caller hashes); r and s
	# are the signature integers (big-endian); pub is the signer's
	# public key as an uncompressed point, whose size (65 or 97)
	# selects P-256 or P-384. Returns 1 if valid, 0 otherwise
	# (including a malformed or off-curve public key).
	ecdsa_verify: fn(hash, r, s, pub: array of byte): int;

	# Generate an ephemeral ECDH keypair. Returns (private scalar
	# 32 bytes, public point 65 bytes uncompressed), or (nil, nil) on
	# failure.
	ecdh_new: fn(): (array of byte, array of byte);

	# ECDH shared secret: our private scalar and the peer's 65-byte
	# uncompressed public point, giving the 32-byte big-endian
	# x-coordinate of priv*peer. Returns nil if the peer point is not
	# a valid curve point (point validation is done - required for
	# ECDHE security).
	ecdh_shared: fn(priv, peerpub: array of byte): array of byte;

	# validate that a 65-byte uncompressed point is on the curve (and
	# not the point at infinity). Exposed for testing.
	oncurve: fn(pub: array of byte): int;
};
