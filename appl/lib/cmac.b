implement Cmac;

#
# AES-CMAC, RFC 4493.
#
# The subkeys come from encrypting a block of zeroes and shifting the
# result left, twice, each shift conditionally exclusive-ored with the
# constant for a 128 bit block.  The message is then CBC-MACed with
# the last block exclusive-ored with one subkey or the other: the
# first if the message divides into whole blocks, the second if it had
# to be padded.  That distinction is the whole point of the
# construction -- without it a message and the same message with the
# padding written out by hand would have the same tag.
#
# The cipher underneath is Crypt's AES in CBC mode with a zero
# initialisation vector, one block at a time, which is ECB for that
# one block: the same thing smp.b's e() does, for the same reason.
#

include "sys.m";
	sys: Sys;
include "ipints.m";
include "keyring.m";
include "crypt.m";
	crypt: Crypt;

Cmac: module
{
	PATH:	con "/dis/lib/cmac.dis";
	init:	fn(): string;
	aescmac:	fn(key, msg: array of byte): array of byte;
	selftest:	fn(): string;
};

Rb:	con byte 16r87;	# the constant for a 128 bit block

init(): string
{
	sys = load Sys Sys->PATH;
	crypt = load Crypt Crypt->PATH;
	if(crypt == nil)
		return sys->sprint("cannot load %s: %r", Crypt->PATH);
	return nil;
}

#
# One block through AES.  aessetup with no initialisation vector and
# one block of CBC is ECB for that block.
#
ecb(key, blk: array of byte): array of byte
{
	b := array[16] of byte;
	b[0:] = blk[0:16];
	st := crypt->aessetup(key, nil);
	crypt->aescbc(st, b, 16, Crypt->Encrypt);
	return b;
}

#
# Left by one bit, and if the bit that fell off the top was set, the
# constant goes in at the bottom.
#
sub1(b: array of byte): array of byte
{
	r := array[16] of byte;
	carry := 0;
	for(i := 15; i >= 0; i--){
		v := ((int b[i] << 1) & 16rff) | carry;
		carry = (int b[i] >> 7) & 1;
		r[i] = byte v;
	}
	if((int b[0] & 16r80) != 0)
		r[15] ^= Rb;
	return r;
}

xorinto(d, s: array of byte)
{
	for(i := 0; i < len d; i++)
		d[i] ^= s[i];
}

aescmac(key, msg: array of byte): array of byte
{
	zero := array[16] of {* => byte 0};
	k1 := sub1(ecb(key, zero));
	k2 := sub1(k1);

	n := len msg;
	#
	# How many whole blocks are CBC-MACed before the last one, and
	# whether the last one is padded.  An empty message is one
	# padded block and no whole ones, which is the case that a
	# division would get wrong.
	#
	nb := (n + 15) / 16;
	padded := 1;
	if(nb > 0 && n % 16 == 0)
		padded = 0;
	if(nb == 0)
		nb = 1;

	last := array[16] of {* => byte 0};
	off := (nb - 1) * 16;
	if(padded){
		k := n - off;
		if(k > 0)
			last[0:] = msg[off:off+k];
		last[k] = byte 16r80;
		xorinto(last, k2);
	} else {
		last[0:] = msg[off:off+16];
		xorinto(last, k1);
	}

	x := array[16] of {* => byte 0};
	for(i := 0; i < nb - 1; i++){
		xorinto(x, msg[i*16:i*16+16]);
		x = ecb(key, x);
	}
	xorinto(x, last);
	return ecb(key, x);
}

#
# RFC 4493's four vectors, all under the same key.  They are here
# rather than in a test program because a message authentication code
# that is wrong is wrong silently: nothing it is used for would fail
# in a way that pointed at it.
#
selftest(): string
{
	key := unhex("2b7e151628aed2a6abf7158809cf4f3c");
	msg := unhex("6bc1bee22e409f96e93d7e117393172a"
		+ "ae2d8a571e03ac9c9eb76fac45af8e51"
		+ "30c81c46a35ce411e5fbc1191a0a52ef"
		+ "f69f2445df4f9b17ad2b417be66c3710");
	want := array[] of {
		"bb1d6929e95937287fa37d129b756746",
		"070a16b46b4d4144f79bdd9dd04a287c",
		"dfa66747de9ae63030ca32611497c827",
		"51f0bebf7e3b9d92fc49741779363cfe",
	};
	lens := array[] of {0, 16, 40, 64};
	for(i := 0; i < len want; i++){
		got := hex(aescmac(key, msg[0:lens[i]]));
		if(got != want[i])
			return sys->sprint("rfc 4493 vector %d (%d bytes): %s, wanted %s",
				i + 1, lens[i], got, want[i]);
	}
	return nil;
}

hexdig:	con "0123456789abcdef";

hex(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++){
		s[len s] = hexdig[(int b[i] >> 4) & 16rf];
		s[len s] = hexdig[int b[i] & 16rf];
	}
	return s;
}

unhex(s: string): array of byte
{
	b := array[len s / 2] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte ((digit(s[2*i]) << 4) | digit(s[2*i+1]));
	return b;
}

digit(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}
