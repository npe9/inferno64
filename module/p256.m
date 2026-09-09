#
# The NIST P-256 curve, which Bluetooth's LE Secure Connections needs
# for its elliptic-curve Diffie-Hellman.
#
# libsec in this tree has no elliptic curve code at all, so this is
# written over IPint, the multi-precision integers the interpreter
# already exposes to Limbo.  Points are affine and every addition
# inverts, which is the slow way and the one that is easiest to be
# sure of; a pairing does one scalar multiplication each way and can
# afford it.
#
P256: module
{
	PATH:	con "/dis/lib/p256.dis";

	init:	fn(): string;

	#
	# The public key for a private one: d times the base point,
	# returned as the two 32 byte coordinates.  The error is
	# non-nil if d is not in 1..n-1.
	#
	base:	fn(d: array of byte): (array of byte, array of byte, string);

	#
	# d times an arbitrary point, which is how the shared secret is
	# reached: each side multiplies the other's public key by its
	# own private key.  The x coordinate is the DHKey.
	#
	mult:	fn(d, x, y: array of byte): (array of byte, array of byte, string);

	# whether a point satisfies the curve equation
	oncurve:	fn(x, y: array of byte): int;

	#
	# Checks that need no memorised vector: the base point is on
	# the curve, n times it is the point at infinity, (n-1) times
	# it is its own negation, and a Diffie-Hellman agreement
	# reaches the same secret from either side.
	#
	selftest:	fn(): string;
};
