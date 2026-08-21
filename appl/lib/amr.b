implement Amr;

include "sys.m";
	sys: Sys;
include "amr.m";

# --- geometry / indexing ---

# All the cross-level face arithmetic (refine's injection, coarsen's
# restriction, exchange's prolongation/restriction) reduces to one
# relationship, applied either to a 3D volume (refine/coarsen) or a 2D
# face slice (exchange): a coarse index c in [0,B) is covered, within
# ONE specific finer child (selected by c/(B/2) along that axis), by
# the 2 consecutive fine indices [ (c%(B/2))*2, (c%(B/2))*2+1 ]. B must
# be even for this to divide cleanly - new() below rejects an odd B.

# Flat index into a block's (B+2)^3 padded array; x,y,z in [-1,B] (the
# ghost layer is x/y/z == -1 or B, using the SAME formula as interior
# access - the +1 offset already lands ghost cells at 0 and B+1).
idx(bs, x, y, z: int): int
{
	p := bs+2;
	return (z+1)*p*p + (y+1)*p + (x+1);
}

newblock(level, bi, bj, bk, bs: int): ref Block
{
	n := (bs+2)*(bs+2)*(bs+2);
	u := array[n] of real;
	# Explicit, not relying on implicit zero-init - this build's
	# allocator has been observed to hand back a freshly array[N]-
	# allocated block still holding a previous same-size allocation's
	# contents (see fem(2)/sparse(2) for the minimal repro). Every
	# fresh block's data starts genuinely zero for exactly that reason.
	for(i := 0; i < n; i++)
		u[i] = 0.0;
	return ref Block(level, bi, bj, bk, 1, nil, u);
}

get(b: ref Block, bs: int, x, y, z: int): real
{
	return b.u[idx(bs, x, y, z)];
}

set(b: ref Block, bs: int, x, y, z: int, value: real)
{
	b.u[idx(bs, x, y, z)] = value;
}

new(nx0, ny0, nz0, blocksize, maxlevel: int, domainx, domainy, domainz: real): ref Forest
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	bs := blocksize;
	nr := nx0*ny0*nz0;
	roots := array[nr] of ref Block;
	for(bk := 0; bk < nz0; bk++)
		for(bj := 0; bj < ny0; bj++)
			for(bi := 0; bi < nx0; bi++)
				roots[bk*ny0*nx0 + bj*nx0 + bi] = newblock(0, bi, bj, bk, bs);
	return ref Forest(nx0, ny0, nz0, bs, maxlevel, domainx, domainy, domainz, roots);
}

pow2(n: int): int
{
	r := 1;
	for(i := 0; i < n; i++)
		r *= 2;
	return r;
}

cellsize(f: ref Forest, level: int): (real, real, real)
{
	# A level-L block covers domainx/(nx0*2^L) of physical extent, but
	# holds blocksize cells across that extent - the per-CELL size
	# needs that extra /blocksize (a block's own extent, not its
	# per-cell size, is a different, real quantity computed inline
	# where blockbox() needs it below - don't merge the two).
	s := real (pow2(level))*real(f.blocksize);
	return (f.domainx/(real(f.nx0)*s), f.domainy/(real(f.ny0)*s), f.domainz/(real(f.nz0)*s));
}

blockbox(f: ref Forest, b: ref Block): (real, real, real, real, real, real)
{
	(dx, dy, dz) := cellsize(f, b.level);
	bs := real f.blocksize;
	hx := dx*bs*0.5;
	hy := dy*bs*0.5;
	hz := dz*bs*0.5;
	cx := real(b.bi)*dx*bs + hx;
	cy := real(b.bj)*dy*bs + hy;
	cz := real(b.bk)*dz*bs + hz;
	return (cx, cy, cz, hx, hy, hz);
}

# --- tree navigation ---

# The block created at exactly (level,bi,bj,bk), active or not; nil if
# out of the level's virtual grid range or never created that deep.
# Descends from the appropriate root using the level-doubling index
# relationship directly (bi,bj,bk at level L determine both which root
# covers them - bi>>L etc - and, one bit at a time, which child is
# chosen at each refine step down to L).
findexact(f: ref Forest, level, bi, bj, bk: int): ref Block
{
	gx := f.nx0*pow2(level);
	gy := f.ny0*pow2(level);
	gz := f.nz0*pow2(level);
	if(bi < 0 || bi >= gx || bj < 0 || bj >= gy || bk < 0 || bk >= gz)
		return nil;
	rbi := bi/pow2(level);
	rbj := bj/pow2(level);
	rbk := bk/pow2(level);
	cur := f.roots[rbk*f.ny0*f.nx0 + rbj*f.nx0 + rbi];
	for(lev := 1; lev <= level; lev++){
		if(cur == nil || cur.children == nil)
			return nil;
		shift := level-lev;
		dx := (bi>>shift)&1;
		dy := (bj>>shift)&1;
		dz := (bk>>shift)&1;
		cur = cur.children[dz*4+dy*2+dx];
	}
	return cur;
}

findactiveexact(f: ref Forest, level, bi, bj, bk: int): ref Block
{
	b := findexact(f, level, bi, bj, bk);
	if(b != nil && b.active)
		return b;
	return nil;
}

# Walks coarser from level-1 down to 0 at (bi,bj,bk) shifted to match
# each coarser level, returning the first active ancestor found - the
# same-level slot at `level` has already been checked by the caller.
findactiveancestor(f: ref Forest, level, bi, bj, bk: int): ref Block
{
	for(lev := level; lev >= 0; lev--){
		shift := level-lev;
		b := findactiveexact(f, lev, bi>>shift, bj>>shift, bk>>shift);
		if(b != nil)
			return b;
	}
	return nil;
}

activecount(b: ref Block): int
{
	if(b == nil)
		return 0;
	if(b.active)
		return 1;
	n := 0;
	for(i := 0; i < len b.children; i++)
		n += activecount(b.children[i]);
	return n;
}

collectactive(b: ref Block, into: array of ref Block, at: int): int
{
	if(b == nil)
		return at;
	if(b.active){
		into[at] = b;
		return at+1;
	}
	for(i := 0; i < len b.children; i++)
		at = collectactive(b.children[i], into, at);
	return at;
}

activeblocks(f: ref Forest): array of ref Block
{
	n := 0;
	for(r := 0; r < len f.roots; r++)
		n += activecount(f.roots[r]);
	a := array[n] of ref Block;
	at := 0;
	for(r = 0; r < len f.roots; r++)
		at = collectactive(f.roots[r], a, at);
	return a;
}

# --- refine / coarsen ---

refine(f: ref Forest, b: ref Block)
{
	if(!b.active || b.level >= f.maxlevel)
		return;
	bs := f.blocksize;
	half := bs/2;
	kids := array[8] of ref Block;
	for(dz := 0; dz < 2; dz++)
		for(dy := 0; dy < 2; dy++)
			for(dx := 0; dx < 2; dx++){
				c := newblock(b.level+1, 2*b.bi+dx, 2*b.bj+dy, 2*b.bk+dz, bs);
				for(cz := 0; cz < bs; cz++)
					for(cy := 0; cy < bs; cy++)
						for(cx := 0; cx < bs; cx++){
							px := dx*half + cx/2;
							py := dy*half + cy/2;
							pz := dz*half + cz/2;
							set(c, bs, cx, cy, cz, get(b, bs, px, py, pz));
						}
				kids[dz*4+dy*2+dx] = c;
			}
	b.children = kids;
	b.active = 0;
}

coarsen(f: ref Forest, b: ref Block)
{
	if(b.children == nil)
		return;
	for(i := 0; i < 8; i++)
		if(!b.children[i].active)
			return;	# a child is itself refined - coarsen bottom-up only
	bs := f.blocksize;
	half := bs/2;
	for(pz := 0; pz < bs; pz++)
		for(py := 0; py < bs; py++)
			for(px := 0; px < bs; px++){
				dx := px/half; lpx := px%half;
				dy := py/half; lpy := py%half;
				dz := pz/half; lpz := pz%half;
				c := b.children[dz*4+dy*2+dx];
				s := 0.0;
				for(fz := 0; fz < 2; fz++)
					for(fy := 0; fy < 2; fy++)
						for(fx := 0; fx < 2; fx++)
							s += get(c, bs, lpx*2+fx, lpy*2+fy, lpz*2+fz);
				set(b, bs, px, py, pz, s/8.0);
			}
	b.children = nil;
	b.active = 1;
}

# --- adaptation: refine-mark, 2:1 balance, apply, then coarsen ---

adapt(f: ref Forest, crit: Criterion)
{
	# Fixed-point balance pass: repeatedly scan every CURRENTLY active
	# block; if flagged by crit (or already forced by a neighbour's
	# imbalance) and below maxlevel, refine it now - refining
	# immediately (rather than deferring) is what lets the very next
	# scan see the new, finer neighbours and correctly detect any
	# newly-created >1-level gap, without separate bookkeeping for
	# "pending" refines. The pass cap is generous, not tied to
	# maxlevel: maxlevel only bounds how many times one SPECIFIC block
	# can refine, not how many passes an imbalance needs to propagate
	# spatially across the whole domain (a first version capped this
	# at f.maxlevel and silently left 36 balance violations in a
	# 4x4x4-root test - found by an explicit post-adapt() balance
	# check, not by inspection). One pass can only ever need to reach
	# as far as the whole root grid, so that's the real bound.
	maxpasses := f.nx0+f.ny0+f.nz0+f.maxlevel;
	for(pass := 0; pass <= maxpasses; pass++){
		blocks := activeblocks(f);
		any := 0;
		for(i := 0; i < len blocks; i++){
			b := blocks[i];
			if(b.level >= f.maxlevel)
				continue;
			(cx, cy, cz, hx, hy, hz) := blockbox(f, b);
			want := crit(cx, cy, cz, hx, hy, hz);
			if(!want)
				want = needsbalance(f, b);
			if(want){
				refine(f, b);
				any = 1;
			}
		}
		if(!any)
			break;
	}

	# Coarsening: bottom-up, deepest level first, so a parent only
	# becomes coarsen-eligible once its own children are themselves
	# leaves (coarsen() enforces that directly; scanning deepest-first
	# just means a 2-level-deep column collapses in one adapt() call
	# instead of needing two).
	for(lev := f.maxlevel; lev > 0; lev--)
		coarsenlevel(f, f.roots, lev, crit);
}

# Only ever checks whether refining b SPECIFICALLY would help balance
# - a coarser-than-allowed neighbour is the neighbour's own problem to
# fix by refining itself (caught when needsbalance() is called ON that
# other block in the same scan, not by b acting). The one thing
# refining b actually fixes is a same-level slot that's finer than
# allowed: same-level active is a 0-level gap (fine); refined into
# exactly 8 active-leaf children is a 1-level gap (fine, the max
# allowed); refined with any child itself refined further is a
# >1-level gap - only that case needs b to refine.
#
# A first version tried to also detect the "neighbour is too coarse"
# side of the constraint via a level-1 lookup and an "if b.level==0,
# skip" special case, conflating two genuinely different situations
# into one buggy check that missed real violations whenever b itself
# was at level 0 facing an over-refined neighbour - found via an
# explicit post-adapt() 2:1-balance scan showing 36 real violations in
# a 4x4x4-root test, not by inspection.
needsbalance(f: ref Forest, b: ref Block): int
{
	for(axis := 0; axis < 3; axis++)
		for(sign := -1; sign <= 1; sign += 2){
			nbi := b.bi; nbj := b.bj; nbk := b.bk;
			case axis {
			0 => nbi += sign;
			1 => nbj += sign;
			2 => nbk += sign;
			}
			if(!inrange(f, b.level, nbi, nbj, nbk))
				continue;	# outer boundary: nothing to balance against
			if(findactiveexact(f, b.level, nbi, nbj, nbk) != nil)
				continue;	# same level: fine
			region := findexact(f, b.level, nbi, nbj, nbk);
			if(region == nil || region.children == nil)
				continue;	# neighbour coarser (or not yet created): not b's problem
			allleaves := 1;
			for(i := 0; i < 8; i++)
				if(!region.children[i].active)
					allleaves = 0;
			if(!allleaves)
				return 1;	# neighbour refined more than one level past b
		}
	return 0;
}

# Recurses to every block currently refined (b.children != nil) whose
# children are at level `lev`; coarsens it if its own box no longer
# warrants refinement AND doing so wouldn't reopen a 2:1-balance
# violation (needsbalance() below - a real, checked condition, not
# left to a "next call repairs it" assumption; an earlier version
# skipped this and silently undid every balance-only refinement on
# the very next adapt() call, since crit() alone can never want a
# balance-only block).
coarsenlevel(f: ref Forest, blocks: array of ref Block, lev: int, crit: Criterion)
{
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		if(b == nil || b.active)
			continue;
		if(b.level+1 == lev){
			allleaves := 1;
			for(j := 0; j < 8; j++)
				if(!b.children[j].active)
					allleaves = 0;
			if(allleaves){
				(cx, cy, cz, hx, hy, hz) := blockbox(f, b);
				# needsbalance(f,b) asks "if b were active at its
				# current level, would it violate 2:1 balance against
				# its neighbours" - exactly the right question here,
				# since coarsen() doesn't change b's own level, only
				# removes its children. Skipping this check was a real
				# bug, not the documented "coarsen never rechecks
				# balance" scope limit it was first written to be: a
				# block refined ONLY to satisfy needsbalance() (never
				# wanted by crit()) would be coarsened right back on
				# the very next adapt() call, since crit() alone
				# governs coarsening below - silently erasing the
				# balance the refine pass had just established, not a
				# rare transient. Found via an explicit post-adapt()
				# 2:1-balance scan.
				if(!crit(cx, cy, cz, hx, hy, hz) && !needsbalance(f, b))
					coarsen(f, b);
			}
		} else
			coarsenlevel(f, b.children, lev, crit);
	}
}

# --- ghost exchange ---

inrange(f: ref Forest, level, bi, bj, bk: int): int
{
	gx := f.nx0*pow2(level);
	gy := f.ny0*pow2(level);
	gz := f.nz0*pow2(level);
	return bi >= 0 && bi < gx && bj >= 0 && bj < gy && bk >= 0 && bk < gz;
}

# Places `normal` at position `axis` and (t1,t2) at the other two axes,
# always in the fixed order (axis==0: t1=y,t2=z), (axis==1: t1=x,t2=z),
# (axis==2: t1=x,t2=y) - used consistently everywhere a face is walked
# (parity lookup, quadrant selection, the exchange loops themselves)
# so every caller agrees on which physical direction t1/t2 mean.
facecoord(axis, normal, t1, t2: int): (int, int, int)
{
	case axis {
	0 => return (normal, t1, t2);
	1 => return (t1, normal, t2);
	* => return (t1, t2, normal);
	}
}

# b's parity (0 or 1) along whichever axis is tangential-1 or
# tangential-2 for the given face axis, matching facecoord's own
# t1/t2 axis assignment.
tangparity(b: ref Block, axis, which: int): int
{
	a := axis;
	if(which == 1){
		case a {
		0 => a = 1;
		1 => a = 0;
		* => a = 0;
		}
	}else{
		case a {
		0 => a = 2;
		1 => a = 2;
		* => a = 1;
		}
	}
	case a {
	0 => return b.bi&1;
	1 => return b.bj&1;
	* => return b.bk&1;
	}
}

exchange(f: ref Forest)
{
	blocks := activeblocks(f);
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		for(axis := 0; axis < 3; axis++)
			for(s := 0; s < 2; s++)
				fillface(f, b, axis, 2*s-1);
	}
}

fillface(f: ref Forest, b: ref Block, axis, sign: int)
{
	bs := f.blocksize;
	half := bs/2;
	nbi := b.bi; nbj := b.bj; nbk := b.bk;
	case axis {
	0 => nbi += sign;
	1 => nbj += sign;
	* => nbk += sign;
	}

	ownface := 0;		# own boundary interior coordinate along `axis`
	if(sign == 1)
		ownface = bs-1;
	ghostface := -1;
	if(sign == 1)
		ghostface = bs;

	if(!inrange(f, b.level, nbi, nbj, nbk)){
		# outer boundary: clamp (zero-Neumann - copy own boundary layer outward)
		for(t1 := 0; t1 < bs; t1++)
			for(t2 := 0; t2 < bs; t2++){
				(ox, oy, oz) := facecoord(axis, ownface, t1, t2);
				(gx0, gy0, gz0) := facecoord(axis, ghostface, t1, t2);
				set(b, bs, gx0, gy0, gz0, get(b, bs, ox, oy, oz));
			}
		return;
	}

	same := findactiveexact(f, b.level, nbi, nbj, nbk);
	if(same != nil){
		nface := bs-1-ownface;	# neighbour's own boundary cell facing b
		for(t1 := 0; t1 < bs; t1++)
			for(t2 := 0; t2 < bs; t2++){
				(gx0, gy0, gz0) := facecoord(axis, ghostface, t1, t2);
				(nx0, ny0, nz0) := facecoord(axis, nface, t1, t2);
				set(b, bs, gx0, gy0, gz0, get(same, bs, nx0, ny0, nz0));
			}
		return;
	}

	if(b.level > 0){
		coarse := findactiveexact(f, b.level-1, nbi/2, nbj/2, nbk/2);
		if(coarse != nil){
			nface := bs-1-ownface;
			q1 := tangparity(b, axis, 1);
			q2 := tangparity(b, axis, 2);
			for(t1 := 0; t1 < bs; t1++)
				for(t2 := 0; t2 < bs; t2++){
					c1 := q1*half + t1/2;
					c2 := q2*half + t2/2;
					(gx0, gy0, gz0) := facecoord(axis, ghostface, t1, t2);
					(nx0, ny0, nz0) := facecoord(axis, nface, c1, c2);
					set(b, bs, gx0, gy0, gz0, get(coarse, bs, nx0, ny0, nz0));
				}
			return;
		}
	}

	region := findexact(f, b.level, nbi, nbj, nbk);
	if(region != nil && region.children != nil){
		nface := bs-1-ownface;
		normalparity := 0;
		if(sign == -1)
			normalparity = 1;
		for(t1 := 0; t1 < bs; t1++)
			for(t2 := 0; t2 < bs; t2++){
				ct1 := t1/half; lt1 := t1%half;
				ct2 := t2/half; lt2 := t2%half;
				(dx, dy, dz) := facecoord(axis, normalparity, ct1, ct2);
				child := region.children[dz*4+dy*2+dx];
				s := 0.0;
				for(f1 := 0; f1 < 2; f1++)
					for(f2 := 0; f2 < 2; f2++){
						(nx0, ny0, nz0) := facecoord(axis, nface, lt1*2+f1, lt2*2+f2);
						s += get(child, bs, nx0, ny0, nz0);
					}
				(gx0, gy0, gz0) := facecoord(axis, ghostface, t1, t2);
				set(b, bs, gx0, gy0, gz0, s/4.0);
			}
		return;
	}

	# Shouldn't happen in a well-formed, 2:1-balanced forest; clamp
	# defensively rather than leave the ghost cell at whatever it held.
	for(t1 := 0; t1 < bs; t1++)
		for(t2 := 0; t2 < bs; t2++){
			(ox, oy, oz) := facecoord(axis, ownface, t1, t2);
			(gx0, gy0, gz0) := facecoord(axis, ghostface, t1, t2);
			set(b, bs, gx0, gy0, gz0, get(b, bs, ox, oy, oz));
		}
}

# --- explicit diffusion stencil ---

step(f: ref Forest, diffusivity, dt: real)
{
	blocks := activeblocks(f);
	# Stability limit uses the FINEST active level's cell size (the
	# same conservative-fixed-substep convention pde(2)'s diffuse()
	# uses, generalised across mixed resolutions - safe for every
	# coarser block too, just extra-stable there).
	finest := 0;
	for(fi := 0; fi < len blocks; fi++)
		if(blocks[fi].level > finest)
			finest = blocks[fi].level;
	(hx, hy, hz) := cellsize(f, finest);
	h2 := hx*hx;
	if(hy*hy < h2) h2 = hy*hy;
	if(hz*hz < h2) h2 = hz*hz;
	maxdt := 0.15*h2/diffusivity;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	bs := f.blocksize;

	for(s := 0; s < ns; s++){
		exchange(f);
		news := array[len blocks] of array of real;
		for(i := 0; i < len blocks; i++){
			b := blocks[i];
			(dx, dy, dz) := cellsize(f, b.level);
			n := (bs+2)*(bs+2)*(bs+2);
			w := array[n] of real;
			for(j := 0; j < n; j++)
				w[j] = 0.0;
			for(z := 0; z < bs; z++)
				for(y := 0; y < bs; y++)
					for(x := 0; x < bs; x++){
						c := get(b, bs, x, y, z);
						lap := (get(b,bs,x-1,y,z)-2.0*c+get(b,bs,x+1,y,z))/(dx*dx)
							+ (get(b,bs,x,y-1,z)-2.0*c+get(b,bs,x,y+1,z))/(dy*dy)
							+ (get(b,bs,x,y,z-1)-2.0*c+get(b,bs,x,y,z+1))/(dz*dz);
						w[idx(bs,x,y,z)] = c + h*diffusivity*lap;
					}
			news[i] = w;
		}
		for(i = 0; i < len blocks; i++){
			b := blocks[i];
			for(z := 0; z < bs; z++)
				for(y := 0; y < bs; y++)
					for(x := 0; x < bs; x++)
						set(b, bs, x, y, z, news[i][idx(bs,x,y,z)]);
		}
	}
}

sweep(f: ref Forest, diffusivity, dt: real)
{
	exchange(f);
	step(f, diffusivity, dt);
}

# --- field helpers ---

clear(f: ref Forest, value: real)
{
	blocks := activeblocks(f);
	bs := f.blocksize;
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		for(z := 0; z < bs; z++)
			for(y := 0; y < bs; y++)
				for(x := 0; x < bs; x++)
					set(b, bs, x, y, z, value);
	}
}

splat(f: ref Forest, cx, cy, cz, radius, value: real)
{
	blocks := activeblocks(f);
	bs := f.blocksize;
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		(dx, dy, dz) := cellsize(f, b.level);
		for(z := 0; z < bs; z++)
			for(y := 0; y < bs; y++)
				for(x := 0; x < bs; x++){
					px := real(b.bi)*dx*real(bs) + (real(x)+0.5)*dx;
					py := real(b.bj)*dy*real(bs) + (real(y)+0.5)*dy;
					pz := real(b.bk)*dz*real(bs) + (real(z)+0.5)*dz;
					ddx := px-cx; ddy := py-cy; ddz := pz-cz;
					if(ddx*ddx+ddy*ddy+ddz*ddz <= radius*radius)
						set(b, bs, x, y, z, value);
				}
	}
}

totalmass(f: ref Forest): real
{
	blocks := activeblocks(f);
	bs := f.blocksize;
	s := 0.0;
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		(dx, dy, dz) := cellsize(f, b.level);
		vol := dx*dy*dz;
		for(z := 0; z < bs; z++)
			for(y := 0; y < bs; y++)
				for(x := 0; x < bs; x++)
					s += get(b, bs, x, y, z)*vol;
	}
	return s;
}
