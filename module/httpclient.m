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
};
