implement TLS12;

include "tls12.m";

# tls12.b - TLS 1.2 building blocks. See doc/ssl-modernization-plan.md
# for the overall plan and why this exists (module/ssl3.m is SSLv3-
# only and cannot reach a modern HTTPS host).
#
# prf() is RFC 5246 5's own construction:
#
#	PRF(secret, label, seed) = P_SHA256(secret, label + seed)
#
#	P_hash(secret, seed) = HMAC_hash(secret, A(1) + seed) +
#	                        HMAC_hash(secret, A(2) + seed) + ...
#	A(0) = seed
#	A(i) = HMAC_hash(secret, A(i-1))
#
# unlike SSLv3/TLS1.0's own PRF (a direct MD5+SHA1 mix, no HMAC
# construction at all - module/ssl3.m's own, untouched by this).

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "tls12: load sys module failed";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "tls12: load keyring module failed";
	return nil;
}

prf(secret: array of byte, label: string, seed: array of byte, n: int): array of byte
{
	labelbytes := array of byte label;
	a0 := array[len labelbytes + len seed] of byte;
	a0[0:] = labelbytes;
	a0[len labelbytes:] = seed;

	dlen := Keyring->SHA256dlen;

	# A(1) = HMAC(secret, A(0))
	a := array[dlen] of byte;
	kr->hmac_sha256(a0, len a0, secret, a, nil);

	out := array[n] of byte;
	got := 0;
	digest := array[dlen] of byte;
	while(got < n){
		# this iteration's output block: HMAC(secret, A(i) + A(0))
		buf := array[len a + len a0] of byte;
		buf[0:] = a;
		buf[len a:] = a0;
		kr->hmac_sha256(buf, len buf, secret, digest, nil);

		take := dlen;
		if(got+take > n)
			take = n-got;
		out[got:] = digest[0:take];
		got += take;

		# A(i+1) = HMAC(secret, A(i))
		nexta := array[dlen] of byte;
		kr->hmac_sha256(a, len a, secret, nexta, nil);
		a = nexta;
	}
	return out;
}
