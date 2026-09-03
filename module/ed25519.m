# ed25519(2) - Ed25519 (RFC 8032) signature VERIFICATION, in pure
# Limbo on keyring(2)'s IPint. Neither this tree nor 9front's libsec
# implements Ed25519, so this is a from-scratch port of the twisted
# Edwards curve edwards25519, in the same style as p256(2): field
# arithmetic on IPint, extended homogeneous point coordinates, and
# point decompression. Only verification is provided (no signing) -
# enough for ssh(2) to accept ssh-ed25519 host keys.

Ed25519: module
{
	PATH:	con "/dis/lib/crypt/ed25519.dis";

	init:	fn(): string;

	# verify a PureEdDSA signature sig (64 bytes: R || S) over msg
	# under the 32-byte public key pub. Returns 1 if valid, 0 if not
	# (including malformed inputs).
	verify:	fn(pub, msg, sig: array of byte): int;
};
