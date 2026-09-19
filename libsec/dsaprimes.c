#include "os.h"
#include <mp.h>
#include <libsec.h>

// NIST algorithm for generating DSA primes
// Menezes et al (1997) Handbook of Applied Cryptography, p.151
// q is a 160-bit prime;  p is a 1024-bit prime;  q divides p-1

// arithmetic on unsigned ints mod 2**160, represented
//    as 20-byte, little-endian uchar array

static void
Hrand(uchar *s)
{
	u32int r;
	int i;

	/*
	 * s is the 20-byte array this file's header comment describes.
	 * This wrote five ulongs into it, which is exactly 20 bytes
	 * where ulong is 32 bits and 40 where it is 64 -- a twenty-byte
	 * overrun of a stack array on every 64-bit host, before any of
	 * it is read.  On macOS that is an abort, so DSAprimes() and
	 * therefore keyring->dhparams() could not be called at all.
	 *
	 * Four bytes at a time, counted, and assembled little-endian
	 * because that is what the comment above says these twenty
	 * bytes are.  fastrand() returns a ulong; its low 32 bits are
	 * what is wanted whatever the width.
	 */
	for(i = 0; i < SHA1dlen; i += 4){
		r = (u32int)fastrand();
		s[i] = r;
		s[i+1] = r >> 8;
		s[i+2] = r >> 16;
		s[i+3] = r >> 24;
	}
}

static void
Hincr(uchar *s)
{
	int i;
	for(i=0; i<20; i++)
		if(++s[i]!=0)
			break;
}

// this can run for quite a while;  be patient
void
DSAprimes(mpint *q, mpint *p, uchar seed[SHA1dlen])
{
	int i, j, k, n = 6, b = 63;
	uchar s[SHA1dlen], Hs[SHA1dlen], Hs1[SHA1dlen], sj[SHA1dlen], sjk[SHA1dlen];
	mpint *two1023, *mb, *Vk, *W, *X, *q2;

	two1023 = mpnew(1024);
	mpleft(mpone, 1023, two1023);
	mb = mpnew(0);
	mpleft(mpone, b, mb);
	W = mpnew(1024);
	Vk = mpnew(1024);
	X = mpnew(0);
	q2 = mpnew(0);
forever:
	do{
		Hrand(s);
		memcpy(sj, s, 20);
		sha1(s, 20, Hs, 0);
		Hincr(sj);
		sha1(sj, 20, Hs1, 0);
		for(i=0; i<20; i++)
			Hs[i] ^= Hs1[i];
		Hs[0] |= 1;
		Hs[19] |= 0x80;
		letomp(Hs, 20, q);
	}while(!probably_prime(q, 18));
	if(seed != nil)	// allow skeptics to confirm computation
		memmove(seed, s, SHA1dlen);
	i = 0;
	j = 2;
	Hincr(sj);
	mpleft(q, 1, q2);
	while(i<4096){
		memcpy(sjk, sj, 20);
		for(k=0; k <= n; k++){
			sha1(sjk, 20, Hs, 0);
			letomp(Hs, 20, Vk);
			if(k == n)
				mpmod(Vk, mb, Vk);
			mpleft(Vk, 160*k, Vk);
			mpadd(W, Vk, W);
			Hincr(sjk);
		}
		mpadd(W, two1023, X);
		mpmod(X, q2, W);
		mpsub(W, mpone, W);
		mpsub(X, W, p);
		if(mpcmp(p, two1023)>=0 && probably_prime(p, 5))
			goto done;
		i += 1;
		j += n+1;
		for(k=0; k<n+1; k++)
			Hincr(sj);
	}
	goto forever;
done:
	mpfree(q2);
	mpfree(X);
	mpfree(Vk);
	mpfree(W);
	mpfree(mb);
	mpfree(two1023);
}
