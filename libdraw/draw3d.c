#include "lib9.h"
#include "draw.h"

/*
 * Client encoders for /dev/draw draw3d letters (see man/3/draw).
 * Floats are IEEE754 binary32, little-endian.
 */

static void
putf32(uchar *p, float f)
{
	u32 u;

	memmove(&u, &f, sizeof u);
	BP32INT(p, (s32)u);
}

int
draw3dprobe(Display *d)
{
	uchar *a;

	if(d == nil)
		return -1;
	a = bufimage(d, 1);
	if(a == nil)
		return -1;
	a[0] = '3';
	if(flushimage(d, 0) < 0)
		return -1;
	return 0;
}

void
draw3dmatrix(Display *d, int which, float m[16])
{
	uchar *a;
	int i;

	if(d == nil || m == nil)
		return;
	a = bufimage(d, 1+1+16*4);
	if(a == nil)
		return;
	a[0] = 'M';
	a[1] = which;
	for(i = 0; i < 16; i++)
		putf32(a+2+i*4, m[i]);
}

void
draw3dviewport(Display *d, float mx, float cx, float my, float cy)
{
	uchar *a;

	if(d == nil)
		return;
	a = bufimage(d, 1+4*4);
	if(a == nil)
		return;
	a[0] = 'w';
	putf32(a+1, mx);
	putf32(a+5, cx);
	putf32(a+9, my);
	putf32(a+13, cy);
}

void
draw3dflags(Display *d, int zenable, int clipbehind)
{
	uchar *a;

	if(d == nil)
		return;
	a = bufimage(d, 1+1);
	if(a == nil)
		return;
	a[0] = 'u';
	a[1] = (zenable ? 1 : 0) | (clipbehind ? 2 : 0);
}

void
draw3dclearz(Image *dst)
{
	uchar *a;

	if(dst == nil || dst->display == nil)
		return;
	a = bufimage(dst->display, 1+4);
	if(a == nil)
		return;
	a[0] = 'z';
	BP32INT(a+1, dst->id);
}

void
draw3dfillpoly3(Image *dst, Image *src, float *xyz, int nvert)
{
	uchar *a;
	int i, m;

	if(dst == nil || src == nil || xyz == nil || nvert < 3)
		return;
	m = 1+4+4+2 + nvert*3*4;
	a = bufimage(dst->display, m);
	if(a == nil)
		return;
	a[0] = 'g';
	BP32INT(a+1, dst->id);
	BP32INT(a+5, src->id);
	BP16INT(a+9, nvert);
	for(i = 0; i < nvert; i++){
		putf32(a+11+i*12, xyz[i*3+0]);
		putf32(a+11+i*12+4, xyz[i*3+1]);
		putf32(a+11+i*12+8, xyz[i*3+2]);
	}
}

void
draw3dline3(Image *dst, Image *src, int thick, float ax, float ay, float az, float bx, float by, float bz)
{
	uchar *a;

	if(dst == nil || src == nil)
		return;
	a = bufimage(dst->display, 1+4+4+4+6*4);
	if(a == nil)
		return;
	a[0] = 'G';
	BP32INT(a+1, dst->id);
	BP32INT(a+5, src->id);
	BP32INT(a+9, thick);
	putf32(a+13, ax);
	putf32(a+17, ay);
	putf32(a+21, az);
	putf32(a+25, bx);
	putf32(a+29, by);
	putf32(a+33, bz);
}

void
draw3dplot3(Image *dst, Image *src, float x, float y, float z)
{
	uchar *a;

	if(dst == nil || src == nil)
		return;
	a = bufimage(dst->display, 1+4+4+3*4);
	if(a == nil)
		return;
	a[0] = 'h';
	BP32INT(a+1, dst->id);
	BP32INT(a+5, src->id);
	putf32(a+9, x);
	putf32(a+13, y);
	putf32(a+17, z);
}

void
draw3dfillpoly3lit(Image *dst, Image *src, float *xyz, int nvert,
	float nx, float ny, float nz, float lit)
{
	uchar *a;
	int i, m;

	if(dst == nil || src == nil || xyz == nil || nvert < 3)
		return;
	m = 1+4+4+2 + 4*4 + nvert*3*4;
	a = bufimage(dst->display, m);
	if(a == nil)
		return;
	a[0] = 'k';
	BP32INT(a+1, dst->id);
	BP32INT(a+5, src->id);
	BP16INT(a+9, nvert);
	putf32(a+11, nx);
	putf32(a+15, ny);
	putf32(a+19, nz);
	putf32(a+23, lit);
	for(i = 0; i < nvert; i++){
		putf32(a+27+i*12, xyz[i*3+0]);
		putf32(a+27+i*12+4, xyz[i*3+1]);
		putf32(a+27+i*12+8, xyz[i*3+2]);
	}
}
