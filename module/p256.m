#
# NIST P-256 (secp256r1 / prime256v1) elliptic-curve operations:
# ECDSA signature verification and ECDH key agreement, for the TLS
# stack's ECDHE-ECDSA path (tls12(2)). Pure IPint arithmetic - no
# native code. Include keyring.m before this.
#
# Points on the wire are the TLS/SEC1 uncompressed encoding:
# 0x04 || X(32) || Y(32), 65 bytes. All scalar/coordinate byte arrays
# are big-endian, 32 bytes.
#

P256: module
{
	PATH: con "/dis/lib/crypt/p256.dis";

	init: fn(): string;

	# Verify an ECDSA-with-SHA-256 signature. hash is the 32-byte
	# message digest; r and s are the signature integers (big-endian,
	# any length up to 32 bytes); pub is the signer's public key as a
	# 65-byte uncompressed point. Returns 1 if valid, 0 otherwise
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
