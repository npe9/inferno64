#
# AES-CMAC, RFC 4493.  A message authentication code built out of a
# block cipher, and the one Bluetooth's LE Secure Connections uses
# underneath f4, f5, f6 and g2.
#
# It is here and not in appl/lib/bt because it is not Bluetooth: it is
# a general construction over AES, and libsec in this tree has neither
# it nor the elliptic curve arithmetic Secure Connections also wants.
#
Cmac: module
{
	PATH:	con "/dis/lib/cmac.dis";

	init:	fn(): string;

	# the 16 byte tag for a message of any length, the empty one
	# included
	aescmac:	fn(key, msg: array of byte): array of byte;

	# RFC 4493's own four vectors, checked against this code; nil
	# if they all agree, otherwise which one did not
	selftest:	fn(): string;
};
