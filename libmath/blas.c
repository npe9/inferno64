#include "lib9.h"
#include "mathi.h"

double
dot(int n, double *x, double *y)
{
	double	sum = 0;
	if (n <= 0) 
		return 0;
	while (n--) {
		sum += *x++ * *y++;
	}
	return sum;
}


/*
 * y = a*x + b*y, the one BLAS-1 operation this file was missing and the one a
 * Krylov solve does most: CG alone does three per iteration.
 *
 * axpby rather than plain axpy because CG needs both shapes - "y += a*x" for
 * the solution and residual updates, and "y = x + b*y" for the search
 * direction p = r + beta*p, which a y-accumulating axpy cannot express without
 * destroying r.
 *
 * The two special cases are not micro-optimisation: with a or b known to be 1
 * the loop is a plain FMA over two arrays, which the compiler vectorises,
 * whereas the general form is not. One branch per call, none per element.
 *
 * Indexed loops rather than the pointer-walking style used above, because they
 * vectorise and the pointer form does not - the compiler cannot prove the
 * walks are independent.
 */
void
axpby(int n, double a, double *x, double b, double *y)
{
	int i;

	if(n <= 0)
		return;
	if(b == 1.0){
		for(i = 0; i < n; i++)
			y[i] += a*x[i];
		return;
	}
	if(a == 1.0){
		for(i = 0; i < n; i++)
			y[i] = x[i] + b*y[i];
		return;
	}
	for(i = 0; i < n; i++)
		y[i] = a*x[i] + b*y[i];
}


/*
 * y = the five-point Laplacian of x on an nx by ny grid.
 *
 * This is what an implicit PDE solve spends its time in: pde(2)'s operator is
 * applied once per Krylov iteration and was 78 to 82 per cent of a solve when
 * it was a Limbo loop.
 *
 * Boundary conditions match pde(2)'s own, by value: 0 clamps to the edge, 1
 * wraps, 2 reads zero outside. They are handled by walking the border
 * separately rather than by testing every cell, so the interior loop - which is
 * all of it, for any grid worth solving on - has no branches in it at all.
 *
 * Divides by dx*dx rather than multiplying by a precomputed reciprocal, which
 * is slower and is what the Limbo version this replaces did: matching its
 * arithmetic keeps the two comparable to within the compiler's contraction of
 * a multiply and an add, rather than by a further rounding of its own.
 *
 * x and y must not be the same array.
 */
static double
lapget(double *x, int nx, int ny, int bc, int ix, int iy)
{
	if(bc == 1){			/* periodic */
		ix = (ix % nx + nx) % nx;
		iy = (iy % ny + ny) % ny;
	}else if(ix < 0 || ix >= nx || iy < 0 || iy >= ny){
		if(bc == 2)		/* zero outside */
			return 0.0;
		if(ix < 0) ix = 0;	/* clamp */
		if(ix >= nx) ix = nx-1;
		if(iy < 0) iy = 0;
		if(iy >= ny) iy = ny-1;
	}
	return x[iy*nx + ix];
}

static void
lapcell(double *x, double *y, int nx, int ny, double dx, double dy, int bc, int ix, int iy)
{
	double c;

	c = lapget(x, nx, ny, bc, ix, iy);
	y[iy*nx + ix] =
		(lapget(x,nx,ny,bc,ix-1,iy) - 2.0*c + lapget(x,nx,ny,bc,ix+1,iy))/(dx*dx)
	      + (lapget(x,nx,ny,bc,ix,iy-1) - 2.0*c + lapget(x,nx,ny,bc,ix,iy+1))/(dy*dy);
}

void
lap5(int nx, int ny, double dx, double dy, int bc, double *x, double *y)
{
	int ix, iy;
	double c, *row;

	if(nx <= 0 || ny <= 0)
		return;

	for(iy = 1; iy < ny-1; iy++){
		row = x + iy*nx;
		for(ix = 1; ix < nx-1; ix++){
			c = row[ix];
			y[iy*nx + ix] =
				(row[ix-1] - 2.0*c + row[ix+1])/(dx*dx)
			      + (row[ix-nx] - 2.0*c + row[ix+nx])/(dy*dy);
		}
	}

	/* the border, walked once rather than tested for everywhere */
	for(ix = 0; ix < nx; ix++){
		lapcell(x, y, nx, ny, dx, dy, bc, ix, 0);
		if(ny > 1)
			lapcell(x, y, nx, ny, dx, dy, bc, ix, ny-1);
	}
	for(iy = 1; iy < ny-1; iy++){
		lapcell(x, y, nx, ny, dx, dy, bc, 0, iy);
		if(nx > 1)
			lapcell(x, y, nx, ny, dx, dy, bc, nx-1, iy);
	}
}


int
iamax(int n, double *x)
{
	int	i, m;
	double	xm, a;
	if (n <= 0) 
		return 0;
	m = 0;
	xm = fabs(*x);
	for (i = 1; i < n; i++) {
		a = fabs(*++x);
		if (xm < a) {
			m = i;
			xm = a;
		}
	}
	return m;
}


double
norm1(int n, double *x)
{
	double	sum = 0;
	if (n <= 0) 
		return 0;
	while (n--) {
		sum += fabs(*x);
		x++;
	}
	return sum;
}


double
norm2(int n, double *x)
{
	double	sum = 0;
	if (n <= 0) 
		return 0;
	while (n--) {
		sum += *x * *x;
		x++;
	}
	return sqrt(sum);
}
