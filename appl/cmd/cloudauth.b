implement Cloudauth;

#
# cloudauth(1) -- take this machine's identity from the provider.
#
# doc/inferno-cloud-modern.ms item 7: authentication between two
# instances, "with a secret fetched from the metadata service or from
# object storage, so that two machines that have never met can agree on
# who they are".
#
# What they agree on is a certificate.  Inferno's authentication is
# mutual and certificate-based: each side holds an Authinfo signed by a
# common signer, exchanges it, and verifies the other against the
# signer's public key that its own certificate carries.  Neither side
# needs to have met the other, and neither needs to reach an
# authentication server at the time they talk -- which matters here,
# because an instance that has just booted may be the only one running.
#
# So the bootstrap is the whole problem, and the provider already
# solves it: an instance is created with metadata only it can read, and
# the metadata service answers on a link-local address with no
# credential of its own.  That is where the certificate comes from.
#
#	gcloud compute instances create NAME \
#		--metadata-from-file inferno-cert=alice.cert
#	# then, on the instance
#	cloudauth -m inferno-cert
#
# The certificate is not a secret in the sense a password is -- it
# carries a private key, so it is exactly as secret as one -- and
# putting it in instance metadata means the provider's access control
# is what protects it.  That is the same trust the instance already
# places in the provider to boot the right image, and it is stated here
# rather than assumed: see the man page.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "httpclient.m";
	httpclient: Httpclient;
	Hdr: import httpclient;
include "arg.m";

Cloudauth: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

MDBASE:	con "http://169.254.169.254/computeMetadata/v1/instance/attributes/";
MDHDR:	con "Metadata-Flavor";
MDVAL:	con "Google";

stderr: ref Sys->FD;
verbose := 0;

usage()
{
	sys->fprint(stderr, "usage: cloudauth [-v] [-k keyfile] "
		+ "(-m attribute | -u url | -f file)\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		fail(sys->sprint("cannot load %s: %r", Keyring->PATH));
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));

	keyfile, attr, url, file: string;
	arg->init(argv);
	arg->setusage("cloudauth [-v] [-k keyfile] (-m attribute | -u url | -f file)");
	while((c := arg->opt()) != 0){
		case c {
		'v' =>	verbose++;
		'k' =>	keyfile = arg->earg();
		'm' =>	attr = arg->earg();
		'u' =>	url = arg->earg();
		'f' =>	file = arg->earg();
		* =>	arg->usage();
		}
	}
	if(arg->argv() != nil)
		usage();
	arg = nil;
	n := 0;
	if(attr != nil) n++;
	if(url != nil) n++;
	if(file != nil) n++;
	if(n != 1)
		usage();

	if(keyfile == nil)
		keyfile = "/usr/" + user() + "/keyring/default";

	data: array of byte;
	err: string;
	if(file != nil)
		(data, err) = readfile(file);
	else {
		httpclient = load Httpclient Httpclient->PATH;
		if(httpclient == nil)
			fail(sys->sprint("cannot load %s: %r", Httpclient->PATH));
		if((e := httpclient->init()) != nil)
			fail("httpclient: " + e);
		hdrs: list of Hdr;
		if(attr != nil){
			url = MDBASE + attr;
			# The metadata service answers only if this header is
			# present.  That is the provider's defence against a
			# program on the instance being tricked into fetching
			# it by something that can set a URL but not a header.
			hdrs = Hdr(MDHDR, MDVAL) :: nil;
		}
		if(verbose)
			sys->fprint(stderr, "cloudauth: fetching %s\n", url);
		(resp, rerr) := httpclient->get(url, hdrs);
		if(rerr != nil)
			fail("fetch: " + rerr);
		if(resp.code != 200)
			fail(sys->sprint("fetch: http %d %s", resp.code, resp.reason));
		data = resp.body;
	}
	if(err != nil)
		fail(err);
	if(len data == 0)
		fail("empty certificate");

	# Validated before it is installed.  A 404 page, an error document
	# or a truncated fetch is still bytes, and writing it over the
	# machine's identity would replace a working certificate with a
	# broken one and only fail later, at the next mount, a long way
	# from the cause.  So it is written beside the target, read back
	# through the same parser authentication will use, and only then
	# put in place.
	tmp := keyfile + ".new";
	if(writefile(tmp, data) < 0)
		fail(sys->sprint("cannot write %s: %r", tmp));
	ai := keyring->readauthinfo(tmp);
	if(ai == nil){
		sys->remove(tmp);
		fail("what was fetched is not a certificate");
	}
	if(writefile(keyfile, data) < 0){
		sys->remove(tmp);
		fail(sys->sprint("cannot write %s: %r", keyfile));
	}
	sys->remove(tmp);
	if(verbose)
		sys->fprint(stderr, "cloudauth: %s installed, owner %q signer %q\n",
			keyfile, ai.mypk.owner, ai.spk.owner);
	sys->print("cloudauth: identity installed in %s\n", keyfile);
}

readfile(f: string): (array of byte, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", f));
	b := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("read %s: %r", f));
		if(n == 0)
			break;
		nb := array[len b + n] of byte;
		nb[0:] = b;
		nb[len b:] = buf[0:n];
		b = nb;
	}
	return (b, nil);
}

writefile(f: string, data: array of byte): int
{
	# 0600: this file carries a private key.
	fd := sys->create(f, Sys->OWRITE, 8r600);
	if(fd == nil)
		return -1;
	if(sys->write(fd, data, len data) != len data)
		return -1;
	return 0;
}

user(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "inferno";
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "inferno";
	return string b[0:n];
}

fail(s: string)
{
	sys->fprint(stderr, "cloudauth: %s\n", s);
	raise "fail:" + s;
}
