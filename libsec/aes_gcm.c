/*
 * AES-GCM (NIST SP 800-38D). Ported from 9front's
 * sys/src/libsec/port/aes_gcm.c - see doc/ssl-modernization-plan.md.
 *
 * Two deliberate departures from the source being ported, both called
 * out at the point they happen below:
 *
 *   - `ulong` (32 bits on Plan 9, but this tree's own `unsigned long`
 *     on a 64-bit host - see doc/'s own "Plan 9 long is 32 bits" note)
 *     is replaced throughout with the fixed-width `u32int`/`s32int`
 *     this tree's other ported libsec code already uses (aes.c's own
 *     AESstate.ekey is u32int, not ulong).
 *
 *   - ghash1() uses gfmul() directly on every call, instead of the
 *     16*256*4-word precomputed multiplication table the source
 *     builds via prepareM(). This is not a rewrite: the source itself
 *     contains this exact code path already, disabled behind
 *     `if(0){ gfmul(...); return; }` immediately above the table
 *     lookup it normally uses - correctness-identical, deliberately
 *     slower per block, in exchange for not carrying a 64KB table per
 *     connection this tree has no bulk-throughput need for (a TLS
 *     client doing a handful of records, not a busy server). The
 *     table can be added later behind the same setupAESGCMstate/
 *     aesgcm_encrypt/aesgcm_decrypt API if it's ever worth it.
 */
#include "os.h"
#include <libsec.h>

static void
load128(uchar b[16], u32int W[4])
{
	W[0] = (u32int)b[15] | (u32int)b[14]<<8 | (u32int)b[13]<<16 | (u32int)b[12]<<24;
	W[1] = (u32int)b[11] | (u32int)b[10]<<8 | (u32int)b[ 9]<<16 | (u32int)b[ 8]<<24;
	W[2] = (u32int)b[ 7] | (u32int)b[ 6]<<8 | (u32int)b[ 5]<<16 | (u32int)b[ 4]<<24;
	W[3] = (u32int)b[ 3] | (u32int)b[ 2]<<8 | (u32int)b[ 1]<<16 | (u32int)b[ 0]<<24;
}

static void
store128(u32int W[4], uchar b[16])
{
	b[15] = W[0], b[14] = W[0]>>8, b[13] = W[0]>>16, b[12] = W[0]>>24;
	b[11] = W[1], b[10] = W[1]>>8, b[ 9] = W[1]>>16, b[ 8] = W[1]>>24;
	b[ 7] = W[2], b[ 6] = W[2]>>8, b[ 5] = W[2]>>16, b[ 4] = W[2]>>24;
	b[ 3] = W[3], b[ 2] = W[3]>>8, b[ 1] = W[3]>>16, b[ 0] = W[3]>>24;
}

static void
gfmul(u32int X[4], u32int Y[4], u32int Z[4])
{
	s32int m;
	int i;

	Z[0] = Z[1] = Z[2] = Z[3] = 0;
	for(i=127; i>=0; i--){
		m = ((s32int)Y[i>>5] << (31-(i&31))) >> 31;
		Z[0] ^= X[0] & m;
		Z[1] ^= X[1] & m;
		Z[2] ^= X[2] & m;
		Z[3] ^= X[3] & m;
		m = ((s32int)X[0]<<31) >> 31;
		X[0] = X[0]>>1 | X[1]<<31;
		X[1] = X[1]>>1 | X[2]<<31;
		X[2] = X[2]>>1 | X[3]<<31;
		X[3] = X[3]>>1 ^ (0xE1000000 & m);
	}
}

/* X ^= Y (folding the running hash state into the new block), then
 * Y = X*H over GF(2^128) - the source's own table-free path, made
 * live here; see the file header comment. */
static void
ghash1(AESGCMstate *s, u32int X[4], u32int Y[4])
{
	X[0] ^= Y[0], X[1] ^= Y[1], X[2] ^= Y[2], X[3] ^= Y[3];
	gfmul(X, s->ghashH, Y);
}

static void
ghashn(AESGCMstate *s, uchar *dat, u32int len, u32int Y[4])
{
	uchar tmp[16];
	u32int X[4];

	while(len >= 16){
		load128(dat, X);
		ghash1(s, X, Y);
		dat += 16, len -= 16;
	}
	if(len > 0){
		memmove(tmp, dat, len);
		memset(tmp+len, 0, 16-len);
		load128(tmp, X);
		ghash1(s, X, Y);
	}
}

static u32int
aesxctr1(AESstate *s, uchar ctr[AESbsize], uchar *dat, u32int len)
{
	uchar tmp[AESbsize];
	u32int i;

	aes_encrypt(s->ekey, s->rounds, ctr, tmp);
	if(len > AESbsize)
		len = AESbsize;
	for(i=0; i<len; i++)
		dat[i] ^= tmp[i];
	return len;
}

static void
aesxctrn(AESstate *s, uchar *dat, u32int len)
{
	uchar ctr[AESbsize];
	int i;

	memmove(ctr, s->ivec, AESbsize);
	while(len > 0){
		for(i=AESbsize-1; i>=AESbsize-4; i--)
			if(++ctr[i] != 0)
				break;

		if(aesxctr1(s, ctr, dat, len) < AESbsize)
			break;
		dat += AESbsize;
		len -= AESbsize;
	}
}

void
aesgcm_setiv(AESGCMstate *s, uchar *iv, int ivlen)
{
	if(ivlen == 96/8){
		memmove(s->aes.ivec, iv, ivlen);
		memset(s->aes.ivec+ivlen, 0, AESbsize-ivlen);
		s->aes.ivec[AESbsize-1] = 1;
	} else {
		u32int L[4], Y[4] = {0, 0, 0, 0};

		ghashn(s, iv, ivlen, Y);
		L[0] = ivlen << 3;
		L[1] = ivlen >> 29;
		L[2] = L[3] = 0;
		ghash1(s, L, Y);
		store128(Y, s->aes.ivec);
	}
}

void
setupAESGCMstate(AESGCMstate *s, uchar *key, int keylen, uchar *iv, int ivlen)
{
	setupAESstate(&s->aes, key, keylen, nil);

	memset(s->aes.ivec, 0, AESbsize);
	aes_encrypt(s->aes.ekey, s->aes.rounds, s->aes.ivec, s->aes.ivec);
	load128(s->aes.ivec, s->ghashH);
	memset(s->aes.ivec, 0, AESbsize);

	if(iv != nil && ivlen > 0)
		aesgcm_setiv(s, iv, ivlen);
}

void
aesgcm_encrypt(uchar *dat, u32int ndat, uchar *aad, u32int naad, uchar tag[16], AESGCMstate *s)
{
	u32int L[4], Y[4] = {0, 0, 0, 0};

	ghashn(s, aad, naad, Y);
	aesxctrn(&s->aes, dat, ndat);
	ghashn(s, dat, ndat, Y);
	L[0] = ndat << 3;
	L[1] = ndat >> 29;
	L[2] = naad << 3;
	L[3] = naad >> 29;
	ghash1(s, L, Y);
	store128(Y, tag);
	aesxctr1(&s->aes, s->aes.ivec, tag, 16);
}

int
aesgcm_decrypt(uchar *dat, u32int ndat, uchar *aad, u32int naad, uchar tag[16], AESGCMstate *s)
{
	u32int L[4], Y[4] = {0, 0, 0, 0};
	uchar tmp[16];

	ghashn(s, aad, naad, Y);
	ghashn(s, dat, ndat, Y);
	L[0] = ndat << 3;
	L[1] = ndat >> 29;
	L[2] = naad << 3;
	L[3] = naad >> 29;
	ghash1(s, L, Y);
	store128(Y, tmp);
	aesxctr1(&s->aes, s->aes.ivec, tmp, 16);
	if(tsmemcmp(tag, tmp, 16) != 0)
		return -1;
	aesxctrn(&s->aes, dat, ndat);
	return 0;
}
