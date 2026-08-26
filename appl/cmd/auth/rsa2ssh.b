implement Rsa2ssh;

# A structural Limbo translation of Plan 9's real auth/rsa2ssh -
# sys/src/cmd/auth/rsa2ssh.c in the 9front tree (56 lines) plus the
# shared put4()/putn()/putmp2() helpers from the same directory's
# rsa2any.c. Converts a Plan 9 "key proto=rsa ek=... n=..." line (the
# format auth/rsagen already emits - see appl/cmd/auth/rsagen.b, this
# tree's own sibling) into the "ssh-rsa <base64> <comment>" line an
# OpenSSH authorized_keys file expects.
#
# Lives in appl/cmd/auth, not p9/cmd, unlike the rest of this backlog's
# Plan 9 C-source translations: this command's whole job is producing/
# consuming the SAME key-attribute-line format this tree's OWN
# keyring/factotum ecosystem already uses (rsagen.b's own output,
# getpk.b's own input) - it is not a host-userspace filter with no
# Inferno-specific tie-in the way ascii/urlencode/dc are. rsagen.b
# already lives here using module/crypt.m + module/ipints.m (not
# module/keyring.m's own separate, opaque SK/PK, whose "key and system
# parameters are hidden" comment rules it out for a command that has
# to pull ek/n back OUT of a key numerically) - this file matches that
# existing sibling's module choice for consistency, not keyring.m.
#
# getrsakey() (rsa2any.c) is not itself translated as a general-purpose
# multi-command library function the way it is in C (auth/dsa2ssh
# shares it there) - just its one real behavior this file needs: read
# a "key ..." line (from a file argument or stdin), require proto=rsa,
# pull ek/n out as hex. The real _parseattr() this function calls
# supports single-quoted values with embedded spaces (Plan 9's general
# attribute-string quoting convention) - not reproduced here, since
# every field getrsakey() itself ever reads (proto/ek/n/size/!dk/!p/
# !q/!kp/!kq/!c2) is always a plain hex or decimal token with no spaces
# or quotes in every key line this tree's own tools ever produce; a
# plain space-tokenizer (sys->tokenize) is sufficient and matches
# actual usage exactly, a narrower but understood scope decision in
# the same spirit as this backlog's other documented simplifications.
#
# put4()/putmp2() are the SSH wire-format helpers from rsa2any.c:
# put4() writes a 4-byte big-endian length; putmp2() writes an SSH
# "mpint" (4-byte length, then the value's minimal big-endian magnitude
# bytes, with an extra leading zero byte prepended whenever the value's
# bit count is an exact multiple of 8 - otherwise the top bit of the
# first byte could read as a sign bit in a signed-mpint context; a
# value of zero is the 4-byte length 0 with no data). Translated using
# IPint.bits() (mpsignif) and IPint.iptobebytes() (mptobe) directly,
# which give the same minimal-magnitude encoding rsa2any.c's own
# putmp2() computes on top of raw mptobe() output - the same native
# call the C macro ultimately reaches, checked in libinterp/ipint.c.
#
# Base64: this tree's appl/lib/encoding/base64.b is the plain RFC 4648
# alphabet with '=' padding, confirmed by reading its own table -
# exactly what "ssh-rsa AAAA..." needs (NOT IPint.iptob64(), which is
# Plan 9's own distinct mpint-b64 convention, unrelated to this).
#
# Tested against plan9port's real rsa2ssh binary (installed on this
# host) as a live oracle via #C, run on the same "key ..." line this
# file's own rsagen.b sibling would produce.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;
include "encoding.m";
	encoding: Encoding;
include "arg.m";
	arg: Arg;

Rsa2ssh: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: argv is the flag+operand list with NO
	# leading program name (matching every other file in this
	# backlog's own run() convention) - a dummy name is prepended
	# internally to satisfy arg.m's own init(), which (like C's
	# ARGBEGIN) expects argv[0] to be the program name. keyline is
	# the "key ..." line's content (with or without a trailing
	# newline; either is accepted, matching stripping the file's own
	# real newline would do). Returns the "ssh-rsa ..." output line;
	# a usage/format error raises "fail:rsa2ssh".
	run:	fn(argv: list of string, keyline: string): string;
};

stderr: ref FD;

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(ipints == nil)
		ipints = load IPints IPints->PATH;
	if(encoding == nil)
		encoding = load Encoding Encoding->BASE64PATH;
	if(arg == nil)
		arg = load Arg Arg->PATH;
}

fail(msg: string)
{
	if(stderr == nil)
		stderr = sys->fildes(2);
	sys->fprint(stderr, "rsa2ssh: %s\n", msg);
	raise "fail:rsa2ssh";
}

put4(n: int): array of byte
{
	return array[] of {
		byte ((n>>24)&16rFF), byte ((n>>16)&16rFF),
		byte ((n>>8)&16rFF), byte (n&16rFF),
	};
}

catbytes(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

putstr(s: string): array of byte
{
	b := array of byte s;
	return catbytes(put4(len b), b);
}

# putmp2: an SSH-wire-format mpint - see this file's own header
# comment for the leading-zero rule this reproduces from rsa2any.c.
putmp2(v: ref IPint): array of byte
{
	if(v.cmp(IPint.inttoip(0)) == 0)
		return put4(0);
	bits := v.bits();
	mag := v.iptobebytes();
	if(bits % 8 == 0)
		mag = catbytes(array[] of {byte 16r00}, mag);
	return catbytes(put4(len mag), mag);
}

# findattr: the one real behavior this file needs out of _parseattr -
# see the header comment for the documented space-tokenizing scope.
findattr(toks: list of string, name: string): string
{
	pfx := name+"=";
	for(l := toks; l != nil; l = tl l){
		t := hd l;
		if(len t >= len pfx && t[0:len pfx] == pfx)
			return t[len pfx:];
	}
	return nil;
}

convert(keyline: string, comment: string): string
{
	line := keyline;
	if(len line > 0 && line[len line-1] == '\n')
		line = line[0:len line-1];
	if(len line < 4 || line[0:4] != "key ")
		fail("bad key format");

	(nil, toks) := sys->tokenize(line[4:], " ");

	proto := findattr(toks, "proto");
	if(proto == nil)
		fail("no proto");
	if(proto != "rsa")
		fail("proto not rsa");

	eks := findattr(toks, "ek");
	if(eks == nil)
		fail("no ek");
	ek := IPint.strtoip(eks, 16);
	if(ek == nil)
		fail("bad ek");

	ns := findattr(toks, "n");
	if(ns == nil)
		fail("no n");
	n := IPint.strtoip(ns, 16);
	if(n == nil)
		fail("bad n");

	blob := putstr("ssh-rsa");
	blob = catbytes(blob, putmp2(ek));
	blob = catbytes(blob, putmp2(n));

	return "ssh-rsa "+encoding->enc(blob)+" "+comment+"\n";
}

# doflags: shared by run() and init(). argv[0] must already be a
# program name (arg.m's own init() consumes it as such, matching real
# argv/ARGBEGIN convention - the same convention rsagen.b's own init()
# relies on by passing its argv straight to arg->init() unmodified).
# '-c comment' sets the comment, '-2' is the source's own backwards-
# compatibility no-op (9front's rsa2ssh dropped the old dual-format
# -2/plain output split plan9port's copy still has; only the ssh-rsa
# format remains, and -2 is accepted and ignored rather than removed,
# matching 9front exactly - see this file's own header comment).
doflags(argv: list of string): (string, list of string)
{
	arg->init(argv);
	arg->setusage("auth/rsa2ssh [-c comment] [file]");
	comment := "";
	while((o := arg->opt()) != 0)
		case o {
		'c' =>
			comment = arg->earg();
		'2' =>
			;
		* =>
			arg->usage();
		}
	return (comment, arg->argv());
}

run(argv: list of string, keyline: string): string
{
	loadmods();
	(comment, rest) := doflags("rsa2ssh" :: argv);
	if(rest != nil)
		fail("usage: auth/rsa2ssh [-c comment] [file]");
	return convert(keyline, comment);
}

init(ctxt: ref Context, argv: list of string)
{
	loadmods();
	stderr = sys->fildes(2);
	(comment, rest) := doflags(argv);
	if(len rest > 1)
		arg->usage();
	fname := "/fd/0";
	if(rest != nil)
		fname = hd rest;

	iob := bufio->open(fname, Bufio->OREAD);
	if(iob == nil)
		fail("open "+fname+": no such file or directory");
	line := iob.gets('\n');
	if(line == nil)
		fail("read "+fname+": unexpected eof");

	s := convert(line, comment);
	a := array of byte s;
	if(sys->write(sys->fildes(1), a, len a) != len a)
		fail("write: error");
}
