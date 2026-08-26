implement Urlencodetest;

# Regression test for urlencode(1) - see urlencode.b's own header
# comment for the translation decisions this exercises.
#
# THE ORACLE: unlike every other file in this backlog, no prebuilt
# binary of urlencode exists on this host (checked, not assumed - only
# 9front carries the source at all, plan9port has neither). This test
# BUILDS the real oracle itself, every run, from the actual 9front
# source (`/Users/npe/src/plan9front/sys/src/cmd/urlencode.c`) via a
# single `clang -arch x86_64` invocation against plan9port's own
# prebuilt `libc`/`libbio` (x86_64-only on this host, hence the
# explicit `-arch`), run through the same #C host-command device as
# every other oracle here - not a stand-in implementation, the ACTUAL
# translated source, compiled fresh. If the build ever fails (a
# missing compiler, a moved checkout), this test fails loudly with the
# compiler's own error text rather than silently skipping the
# comparison.
#
# Piping stdin into the oracle uses the same winfd=nil pattern dc.b's
# own test suite established (see inferno-rio-cmd-device-oracle) -
# dropping the last reference to the write-side `data` file forces an
# immediate close, delivering real EOF to the oracle's stdin.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Urlencodetest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Urlencode: module
{
	PATH:	con "/p9/dis/urlencode.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string, input: array of byte): array of byte;
};

urlmod: Urlencode;
stderr: ref FD;
npass, nfail: int;
oraclebin: string;

fail(s: string)
{
	sys->fprint(stderr, "urlencodetest: %s\n", s);
	raise "fail:urlencodetest";
}

check(name: string, got, want: array of byte)
{
	ok := len got == len want;
	if(ok)
		for(i := 0; i < len got; i++)
			if(got[i] != want[i]){
				ok = 0;
				break;
			}
	if(ok)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n",
			name, string want, string got);
	}
}

# --- #C host-command device: same pattern as dctest.b's own runoracle ---

ensurecmd()
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
}

runhost(cmd: string, stdintext: array of byte): (array of byte, int)
{
	ensurecmd();
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		fail("cannot open /cmd/clone: no host command device");
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		fail("cannot read /cmd/clone");
	convdir := "/cmd/"+string buf[0:n];

	waitfd := sys->open(convdir+"/wait", Sys->OREAD);
	rc := sys->fprint(cfd, "exec %s", cmd);

	if(stdintext != nil){
		winfd := sys->open(convdir+"/data", Sys->OWRITE);
		if(winfd != nil && len stdintext > 0)
			sys->write(winfd, stdintext, len stdintext);
		winfd = nil;	# force close -> real EOF, see header comment
	}

	fromcmd := sys->open(convdir+"/data", Sys->OREAD);
	errcmd := sys->open(convdir+"/stderr", Sys->OREAD);
	outbuf: array of byte;
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		old := outbuf;
		outbuf = array[len old + rn] of byte;
		outbuf[0:] = old;
		outbuf[len old:] = rb[0:rn];
	}
	if(errcmd != nil){
		en := sys->read(errcmd, rb, len rb);
		if(en > 0){
			old := outbuf;
			outbuf = array[len old + en] of byte;
			outbuf[0:] = old;
			outbuf[len old:] = rb[0:en];
		}
	}
	status := 0;
	if(waitfd != nil){
		sb := array[1024] of byte;
		wn := sys->read(waitfd, sb, len sb);
		# man/3/cmd: the wait line's last (quoted) field is the exit
		# status, empty for success - confirmed directly (not
		# assumed) by probing both a clean and a failing host
		# command: success ends "...0 ''", failure ends "...0
		# 'exit: 1'". Checking the last two characters are both "'"
		# distinguishes an EMPTY quoted field from a non-empty one.
		s := string sb[0:wn];
		if(len s < 2 || s[len s-1] != '\'' || s[len s-2] != '\'')
			status = -1;
	}
	if(rc < 0)
		status = -1;
	return (outbuf, status);
}

# buildoracle: compile the REAL 9front source, once per test run,
# caching the resulting path for the rest of this run (see this file's
# own header comment).
buildoracle(): string
{
	if(oraclebin != nil)
		return oraclebin;
	out := "/tmp/urlencode-oracle-inferno-rio-test";
	# NOTE: `out` is a HOST path, built and read entirely through #C -
	# man/3/cmd is explicit that a host command "runs in the host
	# operating system's own file name space", NOT Inferno's, so this
	# file never exists anywhere sys->stat()/sys->remove() (which
	# only ever see INFERNO's own namespace) could check it - confirmed
	# directly: a first version of this function used sys->stat() to
	# verify the build succeeded and always reported "no binary" even
	# though the real host build had genuinely succeeded (checked by
	# hand: the file was really there, on the host, the whole time).
	# The #C `wait` file's own exit-status field (see runhost()'s own
	# comment) is the only reliable success/failure signal here.
	cmd := "clang -arch x86_64 "+
		"-I/Users/npe/src/plan9port/include "+
		"-o "+out+" "+
		"/Users/npe/src/plan9front/sys/src/cmd/urlencode.c "+
		"-L/Users/npe/src/plan9port/lib -lbio -l9";
	(errtext, status) := runhost(cmd, nil);
	if(status != 0)
		fail("cannot build oracle: "+string errtext);
	oraclebin = out;
	return oraclebin;
}

runoracle(args: string, input: array of byte): array of byte
{
	bin := buildoracle();
	(out, nil) := runhost(bin+" "+args, input);
	return out;
}

checkoracle(name, args: string, argv: list of string, input: array of byte)
{
	got := urlmod->run(argv, input);
	want := runoracle(args, input);
	check(name, got, want);
}

# --- test cases ---

t1encodebasic()
{
	checkoracle("t1hello", "", nil, array of byte "hello world");
	checkoracle("t1percent", "", nil, array of byte "100% done!");
	checkoracle("t1safeset", "", nil, array of byte "special: /$-_@.!*'(),");
	checkoracle("t1empty", "", nil, array of byte "");
}

t2decodebasic()
{
	checkoracle("t2plus", "-d", list of {"-d"}, array of byte "hello+world%0A");
	checkoracle("t2percent", "-d", list of {"-d"}, array of byte "a%2Bb");
	checkoracle("t2roundtrip", "-d", list of {"-d"}, array of byte "100%25+done%21");
}

t3malformed()
{
	# a decode failure on the SECOND hex digit: emits the literal
	# '%' and the valid first digit, reprocesses the bad second
	# character on its own (see urlencode.b's own header comment).
	checkoracle("t3badsecond", "-d", list of {"-d"}, array of byte "%3z");
	# a decode failure on the FIRST hex digit: only '%' is literal.
	checkoracle("t3badfirst", "-d", list of {"-d"}, array of byte "%zz");
	checkoracle("t3trailingpercent", "-d", list of {"-d"}, array of byte "abc%");
	checkoracle("t3trailingpercentdigit", "-d", list of {"-d"}, array of byte "abc%3");
}

t4highbytes()
{
	# a byte >127, encoded then decoded, must round-trip exactly -
	# the array-of-byte-not-string design this file's header comment
	# documents.
	hi := array[3] of byte;
	hi[0] = byte 'a';
	hi[1] = byte 16rFF;
	hi[2] = byte 'b';
	enc := urlmod->run(nil, hi);
	dec := urlmod->run(list of {"-d"}, enc);
	check("t4highbytes", dec, hi);
	# also confirm against the real oracle for the encode half
	wantenc := runoracle("", hi);
	check("t4highbytesoracle", enc, wantenc);
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	urlmod = load Urlencode Urlencode->PATH;
	if(urlmod == nil)
		fail("cannot load "+Urlencode->PATH);

	t1encodebasic();
	t2decodebasic();
	t3malformed();
	t4highbytes();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:urlencodetest";
}
