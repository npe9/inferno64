#
# AWS Signature Version 4 request signing (the scheme every current
# AWS API authenticates with). Pure computation - no network - so it
# is testable offline against AWS's own published aws-sig-v4-test-suite
# vectors. Pair it with https(2) to make signed AWS calls entirely in
# this tree, no host tooling. Include sys.m and keyring.m before this.
#

AWSV4: module
{
	PATH: con "/dis/lib/awsv4.dis";

	init: fn(): string;

	# A request to sign. method is "GET"/"PUT"/...; host is the bare
	# host (no scheme); path is the URI path (already percent-encoded
	# where it must be; "/" if empty); query is the raw query string
	# ("a=1&b=2", already encoded, in any order - sign() canonicalizes
	# it). headers are extra headers to include in the signature as
	# (name, value) pairs (host and x-amz-date are added automatically
	# and must not be passed). payload is the request body (nil for an
	# empty body).
	Request: adt
	{
		method: string;
		host: string;
		path: string;
		query: string;
		headers: list of (string, string);
		payload: array of byte;
	};

	# Credentials plus the target region and service (e.g. "us-east-1",
	# "s3"). token is an optional STS session token (nil if none).
	Creds: adt
	{
		access: string;
		secret: string;
		token: string;
		region: string;
		service: string;
	};

	# Sign req at time amzdate (ISO8601 basic UTC, "20150830T123600Z" -
	# caller supplies it, so signing is deterministic and testable;
	# amzdatenow() builds one from the clock). Returns the full list of
	# headers to send: the caller's own, plus Host, X-Amz-Date,
	# X-Amz-Content-Sha256, optionally X-Amz-Security-Token, and the
	# Authorization header carrying the signature. Ready to hand to
	# https(2)'s request().
	sign: fn(c: ref Creds, req: ref Request, amzdate: string): list of (string, string);

	# just the hex signature and the string-to-sign, exposed for
	# testing against published vectors without rebuilding a header set
	signature: fn(c: ref Creds, req: ref Request, amzdate: string): (string, string);

	# ISO8601 basic UTC timestamp from the current clock, for sign()
	amzdatenow: fn(): string;

	# lowercase hex SHA-256 of b (the payload-hash and canonical-hash
	# primitive; exported because callers signing an empty body a lot
	# can cache sha256hex(nil))
	sha256hex: fn(b: array of byte): string;
};
