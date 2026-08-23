implement Command;

#
# Tests sparse(2) against reference implementations written here.
#
# Every part of this module has a fast version and an obvious one, and the
# obvious one is the specification: the pattern builder uses a marker array
# instead of scanning a list of neighbours, find() binary-searches instead of
# scanning a row, and matvec calls math(2)'s spmv instead of looping in Limbo.
# Each is several times faster and each could be subtly wrong in a way that
# still produces a plausible matrix.
#
# So the reference versions live here and the outputs are compared exactly.
# The element patterns are random, because a structured mesh visits nodes in an
# order that hides an ordering mistake: with a regular grid the neighbours of a
# node arrive nearly sorted already.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "math.m";
	math: Math;
include "sparse.m";
	sparse: Sparse;
	CSR: import sparse;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

fail := 0;
seed := 12345;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

# Reproducible, so a failure can be looked at again.
rand(n: int): int
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return (seed >> 7) % n;
}

inlist(l: list of int, x: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
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

# What newfrompattern used to be: a list of neighbours per node, scanned for
# each candidate. Slow and plainly correct, which is what a reference is for.
refpattern(n: int, elems: array of array of int): (array of int, array of int)
{
	neigh := array[n] of list of int;
	counts := array[n] of int;
	for(i := 0; i < n; i++){
		counts[i] = 0;
		neigh[i] = nil;
	}
	for(e := 0; e < len elems; e++){
		en := elems[e];
		for(a := 0; a < len en; a++)
			for(b := 0; b < len en; b++)
				if(!inlist(neigh[en[a]], en[b])){
					neigh[en[a]] = en[b] :: neigh[en[a]];
					counts[en[a]]++;
				}
	}
	rowptr := array[n+1] of int;
	nnz := 0;
	for(i = 0; i < n; i++){
		rowptr[i] = nnz;
		nnz += counts[i];
	}
	rowptr[n] = nnz;
	colidx := array[nnz] of int;
	for(i = 0; i < n; i++){
		row := array[counts[i]] of int;
		j := 0;
		for(l := neigh[i]; l != nil; l = tl l)
			row[j++] = hd l;
		sortints(row);
		for(j = 0; j < len row; j++)
			colidx[rowptr[i]+j] = row[j];
	}
	return (rowptr, colidx);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	sparse = load Sparse Sparse->PATH;
	if(sparse == nil || math == nil){
		print("sparsetest: load: %r\n");
		raise "fail:load";
	}

	n := 300;
	ne := 400;
	nper := 8;			# hex8, what fem(2) assembles
	elems := array[ne] of array of int;
	for(e := 0; e < ne; e++){
		en := array[nper] of int;
		# A cluster of nearby nodes, so rows have realistic degree,
		# but not a grid: the order neighbours arrive in is arbitrary.
		base := rand(n);
		for(a := 0; a < nper; a++)
			en[a] = (base + rand(40)) % n;
		elems[e] = en;
	}

	j := 0;			# Limbo scopes a for-init to the whole function
	m := sparse->newfrompattern(n, elems);
	(wantrow, wantcol) := refpattern(n, elems);

	if(len m.rowptr != len wantrow)
		bad(sprint("rowptr has %d entries, expected %d", len m.rowptr, len wantrow));
	else for(i := 0; i < len wantrow; i++)
		if(m.rowptr[i] != wantrow[i]){
			bad(sprint("rowptr[%d] = %d, expected %d", i, m.rowptr[i], wantrow[i]));
			break;
		}
	if(len m.colidx != len wantcol)
		bad(sprint("%d nonzeros, expected %d", len m.colidx, len wantcol));
	else for(i = 0; i < len wantcol; i++)
		if(m.colidx[i] != wantcol[i]){
			bad(sprint("colidx[%d] = %d, expected %d", i, m.colidx[i], wantcol[i]));
			break;
		}
	if(fail)
		raise "fail:test";

	# Each row sorted and free of duplicates. find() binary-searches, so
	# an unsorted row would silently fail to find entries that are there -
	# and the matrix would look merely wrong, not broken.
	for(i = 0; i < n; i++)
		for(j = m.rowptr[i]+1; j < m.rowptr[i+1]; j++)
			if(m.colidx[j] <= m.colidx[j-1]){
				bad(sprint("row %d is not sorted at %d: %d after %d",
					i, j, m.colidx[j], m.colidx[j-1]));
				break;
			}
	if(fail)
		raise "fail:test";

	# Everything the pattern says is there must be findable, and nothing
	# else may be. That is what actually exercises the binary search.
	sparse->clear(m);
	for(i = 0; i < n; i++)
		for(j = m.rowptr[i]; j < m.rowptr[i+1]; j++)
			sparse->add(m, i, m.colidx[j], real (i+1) + 0.5*real j);
	nbad := 0;
	for(i = 0; i < n; i++)
		for(j = m.rowptr[i]; j < m.rowptr[i+1]; j++)
			if(sparse->get(m, i, m.colidx[j]) != real (i+1) + 0.5*real j)
				nbad++;
	if(nbad != 0)
		bad(sprint("%d entries did not read back what was added", nbad));

	# A column not in the pattern must read as zero and absorb writes
	# without disturbing anything.
	miss := 0;
	for(i = 0; i < n; i++){
		c := (m.colidx[m.rowptr[i]] + 137) % n;
		present := 0;
		for(j = m.rowptr[i]; j < m.rowptr[i+1]; j++)
			if(m.colidx[j] == c)
				present = 1;
		if(!present){
			if(sparse->get(m, i, c) != 0.0)
				miss++;
			sparse->set(m, i, c, 99.0);
			if(sparse->get(m, i, c) != 0.0)
				miss++;
		}
	}
	if(miss != 0)
		bad(sprint("%d absent entries did not behave as zero", miss));

	# matvec against a dense reference. This is math(2)'s spmv underneath,
	# so it also checks that the C builtin agrees with the row loop.
	x := array[n] of real;
	for(i = 0; i < n; i++)
		x[i] = 1.0 + real (i % 11) / 7.0;
	y := sparse->matvec(m, x);
	worst := 0.0;
	for(i = 0; i < n; i++){
		s := 0.0;
		for(j = m.rowptr[i]; j < m.rowptr[i+1]; j++)
			s += m.val[j]*x[m.colidx[j]];
		d := y[i] - s;
		if(d < 0.0)
			d = -d;
		if(s != 0.0)
			d /= math->fabs(s);
		if(d > worst)
			worst = d;
	}
	# Not exact equality: the C loop contracts the multiply and add into a
	# fused one, which rounds differently. A couple of units in the last
	# place is expected; anything larger is not rounding.
	if(worst > 1e-14)
		bad(sprint("matvec differs from the row loop by %g relative", worst));

	if(fail)
		raise "fail:test";
	print("  %d nodes, %d elements, %d nonzeros\n", n, ne, len m.colidx);
	print("  pattern matches the reference exactly; matvec agrees to %g\n", worst);
	print("PASS\n");
}
