Httpclient: module
{
	PATH:	con "/dis/lib/httpclient.dis";

	# One request header or response header.
	Hdr: adt {
		name:	string;		# canonical case is not assumed; see Resp.hdr
		val:	string;
	};

	Resp: adt {
		code:	int;			# 200, 404, ...
		reason:	string;
		hdrs:	list of Hdr;
		body:	array of byte;

		# header lookup, case-insensitive as RFC 9110 requires
		hdr:	fn(r: self ref Resp, name: string): string;
	};

	init:		fn(): string;
	get:		fn(url: string, hdrs: list of Hdr): (ref Resp, string);
	post:		fn(url: string, hdrs: list of Hdr, body: array of byte): (ref Resp, string);
	request:	fn(method: string, url: string, hdrs: list of Hdr,
				body: array of byte): (ref Resp, string);

	# As request, but dial addr (a dial(2) string such as
	# "tcp!10.0.0.1!443") instead of resolving the url's host.  The
	# host from the url is still what is sent as Host:, named in SNI
	# and required of the certificate, so this connects to one place
	# and authenticates another -- curl spells it --connect-to.  It
	# exists because /net/cs resolves no names under hosted emu, so
	# without it nothing here can be tested against a real server.
	requestat:	fn(method: string, url: string, addr: string,
				hdrs: list of Hdr, body: array of byte): (ref Resp, string);
};
