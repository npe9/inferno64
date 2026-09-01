#
# TLS 1.2 building blocks - see doc/ssl-modernization-plan.md.
# Starts with the PRF (RFC 5246 5); more primitives land here as the
# plan progresses (record protection, the handshake state machine).
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
};
