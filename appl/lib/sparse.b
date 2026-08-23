implement Sparse;

include "sys.m";
include "math.m";
	math: Math;
include "sparse.m";

# Sparse has no init(), and adding one would change a published interface, so
# Math is loaded on first use. If it cannot be loaded matvec falls back to the
# Limbo loop, which is what this module did before and is still correct - only
# about ten times slower.
loadmath()
{
	if(math == nil)
		math = load Math Math->PATH;
}

sortints(a: array of int)
{
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i-1;
		while(j >= 0 && a[j] > v){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = v;
	}
}

newfrompattern(n: int, elems: array of array of int): ref CSR
{
	# Which elements touch each node, in CSR form: count, prefix-sum,
	# fill. This is what makes a row's neighbours reachable one row at a
	# time, which is what makes the marker below work.
	#
	# The obvious version keeps a list of neighbours per node and scans it
	# for each candidate. That is O(degree) per insertion with a pointer
	# chase at every step, and for a hex mesh it was two thirds of the
	# whole assembly - about eleven million list traversals at 24x24x24.
	# Nothing here is in C; it is the same work done once instead of
	# degree times.
	ecount := array[n+1] of int;
	for(i0 := 0; i0 <= n; i0++)
		ecount[i0] = 0;
	for(e := 0; e < len elems; e++){
		en := elems[e];
		for(a := 0; a < len en; a++)
			ecount[en[a]+1]++;
	}
	for(i0 = 0; i0 < n; i0++)
		ecount[i0+1] += ecount[i0];
	fill := array[n] of int;
	for(i0 = 0; i0 < n; i0++)
		fill[i0] = ecount[i0];
	nodeelem := array[ecount[n]] of int;
	for(e = 0; e < len elems; e++){
		en := elems[e];
		for(a := 0; a < len en; a++)
			nodeelem[fill[en[a]]++] = e;
	}

	# mark[c] holds the stamp of the row that last claimed column c, so
	# membership is one comparison rather than a scan. Two passes are
	# needed - one to size the rows, one to fill them - and they use
	# different stamps (i, then n+i) so the second pass is not fooled by
	# the first pass's marks. That avoids clearing an n-element array
	# twice per row, which would cost more than the scan it replaced.
	counts := array[n] of int;
	mark := array[n] of int;
	for(i0 = 0; i0 < n; i0++){
		counts[i0] = 0;
		mark[i0] = -1;
	}
	for(i := 0; i < n; i++){
		c := 0;
		for(k := ecount[i]; k < ecount[i+1]; k++){
			en := elems[nodeelem[k]];
			for(b := 0; b < len en; b++)
				if(mark[en[b]] != i){
					mark[en[b]] = i;
					c++;
				}
		}
		counts[i] = c;
	}
	rowptr := array[n+1] of int;
	nnz := 0;
	for(i = 0; i < n; i++){
		rowptr[i] = nnz;
		nnz += counts[i];
	}
	rowptr[n] = nnz;
	colidx := array[nnz] of int;
	val := array[nnz] of real;
	# Explicit, not relying on a fresh array's contents. Dis specifies
	# newa's non-pointer space as *undefined* (doc/dis.ms, "newa,
	# newaz"), so an array[N] of a pointer-free type holds whatever the
	# reused heap block last contained. This tree now compiles with
	# limbo -z (mkfiles/mkdis), which emits the zeroing newaz instead
	# and makes that guarantee hold - but every accumulate-from-zero
	# array in sparse(2)/fem(2) still zeroes itself explicitly, so
	# correctness never depends on a build flag. Do not remove as
	# "redundant".
	for(i = 0; i < nnz; i++)
		val[i] = 0.0;
	for(i = 0; i < n; i++){
		off := rowptr[i];
		c := 0;
		for(k := ecount[i]; k < ecount[i+1]; k++){
			en := elems[nodeelem[k]];
			for(b := 0; b < len en; b++)
				if(mark[en[b]] != n+i){
					mark[en[b]] = n+i;
					colidx[off+c] = en[b];
					c++;
				}
		}
		# Sorted, which get/set/add rely on: find() binary-searches.
		sortints(colidx[off:off+c]);
	}
	return ref CSR(n, rowptr, colidx, val);
}

clear(m: ref CSR)
{
	for(i := 0; i < len m.val; i++)
		m.val[i] = 0.0;
}

# Binary search, not a scan: newfrompattern sorts each row, and assembly calls
# this once per element entry - 64 times per hex element - so the difference is
# the bulk of the scatter.
find(m: ref CSR, row, col: int): int
{
	lo := m.rowptr[row];
	hi := m.rowptr[row+1] - 1;
	while(lo <= hi){
		mid := (lo + hi) / 2;
		c := m.colidx[mid];
		if(c == col)
			return mid;
		if(c < col)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return -1;
}

get(m: ref CSR, row, col: int): real
{
	jj := find(m, row, col);
	if(jj < 0)
		return 0.0;
	return m.val[jj];
}

set(m: ref CSR, row, col: int, value: real)
{
	jj := find(m, row, col);
	if(jj >= 0)
		m.val[jj] = value;
}

add(m: ref CSR, row, col: int, value: real)
{
	jj := find(m, row, col);
	if(jj >= 0)
		m.val[jj] += value;
}

matvec(m: ref CSR, x: array of real): array of real
{
	y := array[m.n] of real;
	loadmath();
	if(math != nil){
		# Same loop in C: 10x faster, and bit-identical because the
		# summation order is unchanged.
		math->spmv(m.rowptr, m.colidx, m.val, x, y);
		return y;
	}
	for(row := 0; row < m.n; row++){
		s := 0.0;
		for(jj := m.rowptr[row]; jj < m.rowptr[row+1]; jj++)
			s += m.val[jj]*x[m.colidx[jj]];
		y[row] = s;
	}
	return y;
}

dirichlet(m: ref CSR, b: array of real, rows: array of int, values: array of real)
{
	disset := array[m.n] of int;
	dvalue := array[m.n] of real;
	# Explicit, not relying on implicit zero-init - see the note in
	# newfrompattern above; disset's false/0 default for every row NOT
	# in rows[] is load-bearing here.
	for(i0 := 0; i0 < m.n; i0++){
		disset[i0] = 0;
		dvalue[i0] = 0.0;
	}
	for(i := 0; i < len rows; i++){
		disset[rows[i]] = 1;
		dvalue[rows[i]] = values[i];
	}
	for(row := 0; row < m.n; row++){
		if(disset[row])
			continue;
		for(jj := m.rowptr[row]; jj < m.rowptr[row+1]; jj++){
			col := m.colidx[jj];
			if(disset[col]){
				b[row] -= m.val[jj]*dvalue[col];
				m.val[jj] = 0.0;
			}
		}
	}
	for(i = 0; i < len rows; i++){
		d := rows[i];
		for(jj := m.rowptr[d]; jj < m.rowptr[d+1]; jj++)
			if(m.colidx[jj] == d)
				m.val[jj] = 1.0;
			else
				m.val[jj] = 0.0;
		b[d] = values[i];
	}
}
