Sparse: module
{
	PATH: con "/dis/lib/sparse.dis";

	# Compressed sparse row, square n x n. The symbolic pattern
	# (rowptr/colidx) is built once from the mesh connectivity and
	# reused every assembly - a real FE/sparse code never rebuilds the
	# pattern per solve, only refills the numeric values - which is
	# also what makes this a genuine sparse matrix rather than
	# krylov(2)'s matrix-free operator: fem(2) assembles real values
	# into real storage here, and krylov(2)'s Apply for it is just
	# this matrix's own matvec, not a stencil closure.
	CSR: adt {
		n:	int;
		rowptr:	array of int;	# len n+1
		colidx:	array of int;	# len nnz; each row's slice sorted by column
		val:	array of real;	# len nnz
	};

	# Builds the pattern from a per-element list of the global node
	# ids it touches (femesh(2)'s elemnodes(g,e), e.g.) - every pair of
	# nodes sharing an element becomes a nonzero, including the
	# diagonal.
	newfrompattern:	fn(n: int, elems: array of array of int): ref CSR;

	clear:	fn(m: ref CSR);				# zero all values, keep pattern
	get:	fn(m: ref CSR, row, col: int): real;	# 0.0 if (row,col) isn't in the pattern
	set:	fn(m: ref CSR, row, col: int, value: real);
	add:	fn(m: ref CSR, row, col: int, value: real);	# val[row,col] += value

	matvec:	fn(m: ref CSR, x: array of real): array of real;

	# Symmetric Dirichlet elimination: for each (rows[i], values[i]),
	# fixes x[rows[i]] = values[i] by zeroing that row and column of m
	# (folding each column's contribution into b) and setting the
	# diagonal to 1 and b[rows[i]] to values[i] - keeps m symmetric
	# positive definite (unlike just overwriting the row, which drops
	# symmetry and cg(2)'s convergence guarantee with it).
	dirichlet:	fn(m: ref CSR, b: array of real, rows: array of int, values: array of real);
};
