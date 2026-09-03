implement Command;

# awsv4test(1) - test awsv4(2)'s AWS Signature Version 4 signing
# against authoritative vectors, offline (no network, no AWS account).
#
# Vector 1 is AWS's own aws-sig-v4-test-suite "get-vanilla" case - the
# canonical published example, whose expected signature is documented
# by AWS and reproduced independently by botocore (both agree on
# 5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31;
# this test was written against that agreement, not a single source).
# Vector 2 adds a query string (out of order, to exercise the
# canonical-query sort and percent-encoding) and a non-empty payload,
# with the expected signature computed from the same spec by a
# separate implementation.
#
# Also checks the pieces the signature is built from - the empty-body
# SHA-256, a known SHA-256, and the canonical-request hash of vector 1
# - so a failure points at which stage broke, not just "the signature
# is wrong".
#
# Negative controls (run by editing this file, per the repo's evidence
# discipline; documented in BUGS): flipping one byte of the secret, or
# of amzdate, or of the payload must change the signature.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "awsv4.m";
	awsv4: AWSV4;
	Creds, Request: import awsv4;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
failures := 0;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	awsv4 = load AWSV4 AWSV4->PATH;
	if(awsv4 == nil){
		sys->fprint(stderr, "awsv4test: cannot load %s: %r\n", AWSV4->PATH);
		raise "fail:load";
	}
	if((err := awsv4->init()) != nil){
		sys->fprint(stderr, "awsv4test: %s\n", err);
		raise "fail:init";
	}

	# building blocks first
	check("empty sha256",
		awsv4->sha256hex(nil),
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
	check("sha256(\"hello world\")",
		awsv4->sha256hex(array of byte "hello world"),
		"b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");

	# vector 1: aws-sig-v4-test-suite get-vanilla
	c1 := ref Creds("AKIDEXAMPLE",
		"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", nil,
		"us-east-1", "service");
	r1 := ref Request("GET", "example.amazonaws.com", "/", "", nil, nil);
	(sig1, sts1) := awsv4->signature(c1, r1, "20150830T123600Z");
	# the string-to-sign's last line is the canonical-request hash
	check("v1 canonical-request hash", lastline(sts1),
		"bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63");
	check("v1 signature", sig1,
		"5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");

	# the full sign() must place that signature in a well-formed
	# Authorization header alongside the mandatory signed headers
	hdrs := awsv4->sign(c1, r1, "20150830T123600Z");
	auth := hdrget(hdrs, "Authorization");
	want1 := "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31";
	# get-vanilla signs only host;x-amz-date - x-amz-content-sha256 is
	# added by our sign() and would change SignedHeaders, so this
	# vector uses signature() for the exact published comparison and
	# checks sign() only produces SOME valid Authorization header
	if(auth == nil)
		fail("v1 sign(): no Authorization header produced");
	else if(!prefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request", auth))
		fail("v1 sign(): Authorization credential/scope wrong: "+auth);
	else
		sys->print("v1 sign() Authorization header: PASS\n");
	want1 = want1;	# retained for reference

	# vector 2: query string (out of order) + payload, service s3
	c2 := ref Creds("AKIDEXAMPLE",
		"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", nil,
		"us-east-1", "s3");
	# pass the query deliberately out of canonical order and requiring
	# encoding, to exercise canonquery(): "X-Amz-Foo=bar&a=1" must
	# canonicalize to "X-Amz-Foo=bar&a=1" (X < a by encoded byte)
	r2 := ref Request("GET", "examplebucket.s3.amazonaws.com",
		"/my/path", "a=1&X-Amz-Foo=bar",
		nil, array of byte "hello world");
	(sig2, nil) := awsv4->signature(c2, r2, "20240101T000000Z");
	check("v2 signature (query + payload)", sig2,
		"75f9c39c31aaa7226bbd3a744003afb5960415045ea15d4625f2f2f951de5414");

	if(failures){
		sys->fprint(stderr, "awsv4test: %d FAILURE(S)\n", failures);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

check(name, got, want: string)
{
	if(got != want)
		fail(sys->sprint("%s: got %s want %s", name, got, want));
	else
		sys->print("%s: PASS\n", name);
}

fail(msg: string)
{
	sys->fprint(stderr, "FAIL: %s\n", msg);
	failures++;
}

lastline(s: string): string
{
	last := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			last = i+1;
	return s[last:];
}

hdrget(hs: list of (string, string), name: string): string
{
	for(; hs != nil; hs = tl hs){
		(n, v) := hd hs;
		if(n == name)
			return v;
	}
	return nil;
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}
