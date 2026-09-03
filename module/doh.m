#
# DNS over HTTPS (RFC 8484) - resolve names over this tree's own TLS,
# so the system can look up hostnames itself with no /net/cs and no
# host resolver. Built on https(2)/tls12(2). Include sys.m, keyring.m,
# tls12.m and https.m before this.
#
# It bootstraps the way every DoH client must: the resolver's own
# address is known ahead of time (a literal IP), so reaching it needs
# no prior DNS; its certificate is still verified against its real
# hostname. The defaults are Google Public DNS (dns.google at
# 8.8.8.8), which negotiates this tree's TLS scope.
#

DOH: module
{
	PATH: con "/dis/lib/doh.dis";

	init: fn(): string;

	# DNS record types this resolver understands
	Ta: con 1;	# A (IPv4)
	Taaaa: con 28;	# AAAA (IPv6)

	# The resolver endpoint: its DoH url (https://host/dns-query) and
	# a literal ip to dial it at without needing DNS first. The url's
	# host is what the certificate is verified against. Use gdns() for
	# the Google default, or build your own for another provider.
	Resolver: adt
	{
		url: string;
		ip: string;
	};

	# Google Public DNS - dns.google at 8.8.8.8
	gdns: fn(): ref Resolver;

	# Resolve name's A records through r (nil = gdns()); returns the
	# addresses as dotted-decimal strings, or (nil, diagnostic).
	resolve: fn(r: ref Resolver, name: string): (list of string, string);

	# Resolve a given record type (Ta or Taaaa); A gives dotted IPv4,
	# AAAA gives colon-hex IPv6.
	resolvetype: fn(r: ref Resolver, name: string, qtype: int): (list of string, string);

	# the wire-format pieces, exported for offline testing (dohtest(1))
	# against captured real query/response bytes:
	# encode a query message for name+qtype with the given id
	encode: fn(name: string, qtype, id: int): array of byte;
	# decode a response message: returns the addresses for qtype
	# records (dotted IPv4 for Ta, colon-hex IPv6 for Taaaa), or
	# (nil, diagnostic)
	decode: fn(msg: array of byte, qtype: int): (list of string, string);
};
