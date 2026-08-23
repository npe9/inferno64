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
