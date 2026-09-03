implement Command;

# cryptovec(1) - a thin driver that reads hex-encoded inputs, one per
# line, from standard input, applies a named cryptographic primitive
# from keyring(2), and writes the hex-encoded result, one per line, to
# standard output. It exists so a host-side harness can feed the SAME
# inputs to this tree's crypto and to a formal Cryptol specification and
# diff the two outputs (tests/cryptolverify.sh). It computes nothing
# itself beyond hex framing - the crypto is keyring's.
#
# Input line formats, by primitive:
#   sha256 | sha512   <hex message>
#   chacha20          <64B key><12B nonce><4B counter LE><hex plaintext>
#   poly1305          <32B key><hex message>

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		fail(sys->sprint("load keyring: %r"));

	argv = tl argv;
	if(argv == nil || tl argv == nil)
		fail("usage: cryptovec primitive inputfile");
	prim := hd argv;
	infile := hd tl argv;

	# read the whole input file (host-piped stdin is intercepted by
	# emu's console, so a real file is what the harness feeds us)
	fd := sys->open(infile, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("open %s: %r", infile));
	buf := array[65536] of byte;
	acc := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		acc += string buf[0:n];
	}
	(nil, lines) := sys->tokenize(acc, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(line == "")
			continue;
		sys->print("%s\n", hexs(apply(prim, unhex(line))));
	}
}

apply(prim: string, inp: array of byte): array of byte
{
	case prim {
	"sha256" =>
		d := array[kr->SHA256dlen] of byte;
		kr->sha256(inp, len inp, d, nil);
		return d;
	"sha512" =>
		d := array[kr->SHA512dlen] of byte;
		kr->sha512(inp, len inp, d, nil);
		return d;
	"chacha20" =>
		# <32B key><12B nonce><4B counter LE><plaintext>
		key := inp[0:32];
		nonce := inp[32:44];
		ctr := (int inp[44]) | (int inp[45] << 8) | (int inp[46] << 16) | (int inp[47] << 24);
		pt := inp[48:];
		st := kr->ccpolysetup(key, nonce);
		kr->chacha_setblock(st, ctr);
		out := array[len pt] of byte;
		out[0:] = pt;
		kr->chacha_encrypt(st, out, len out);
		return out;
	"poly1305" =>
		# <32B key><message>
		key := inp[0:32];
		msg := inp[32:];
		return kr->poly1305(msg, len msg, key);
	* =>
		fail("unknown primitive " + prim);
	}
	return nil;
}

fail(m: string)
{
	sys->fprint(stderr, "cryptovec: %s\n", m);
	raise "fail:error";
}

unhex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hx(s[2*i]) << 4) | hx(s[2*i+1]));
	return a;
}

hx(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

hexs(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}
