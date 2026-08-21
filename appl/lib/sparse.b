implement Sparse;

include "sys.m";
include "sparse.m";

inlist(l: list of int, x: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}

listtoarray(l: list of int): array of int
{
	n := 0;
	for(p := l; p != nil; p = tl p)
		n++;
	a := array[n] of int;
	i := n-1;
	for(p = l; p != nil; p = tl p){
		a[i] = hd p;
		i--;
	}
	return a;
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
	neigh := array[n] of list of int;
	counts := array[n] of int;
	# Explicit, not relying on a fresh array's contents - see the note
	# below on val. Only counts[] is actually exposed: Dis leaves
	# non-*pointer* space undefined, so an int array is at risk while
	# neigh[] (list of int, a pointer type) does get nil-initialised by
	# initmem either way. A stale nonzero counts[] entry corrupts nnz
	# and, downstream, colidx/val's own array sizes - which is how this
	# first showed up, as a "negative array size" crash rather than a
	# wrong number. neigh[] is cleared alongside it for symmetry.
	for(i0 := 0; i0 < n; i0++){
		counts[i0] = 0;
		neigh[i0] = nil;
	}
	for(e := 0; e < len elems; e++){
		en := elems[e];
		for(a := 0; a < len en; a++){
			na := en[a];
			for(b := 0; b < len en; b++){
				nb := en[b];
				if(!inlist(neigh[na], nb)){
					neigh[na] = nb :: neigh[na];
					counts[na]++;
				}
			}
		}
	}
	rowptr := array[n+1] of int;
	nnz := 0;
	for(i := 0; i < n; i++){
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
		row := listtoarray(neigh[i]);
		sortints(row);
		off := rowptr[i];
		for(j := 0; j < len row; j++)
			colidx[off+j] = row[j];
	}
	return ref CSR(n, rowptr, colidx, val);
}

clear(m: ref CSR)
{
	for(i := 0; i < len m.val; i++)
		m.val[i] = 0.0;
}

find(m: ref CSR, row, col: int): int
{
	for(jj := m.rowptr[row]; jj < m.rowptr[row+1]; jj++)
		if(m.colidx[jj] == col)
			return jj;
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
