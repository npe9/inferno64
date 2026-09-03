implement QR;
QR: module {
	qr: fn(a, b, c, d: int): int;
};
# one ChaCha20 quarter-round step, returning a mix (pure int arithmetic)
qr(a, b, c, d: int): int
{
	a += b;
	d ^= a;
	d = (d << 16) | ((d >> 16) & 16rffff);
	c += d;
	b ^= c;
	return a ^ b ^ c ^ d;
}
