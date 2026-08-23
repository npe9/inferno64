implement Command;

#
# Tests amr(2), which had none.
#
# The checks are chosen from what the module claims rather than from what is
# convenient to drive, because the easy things to drive - refine one block,
# look at the block count - exercise almost none of it. What is actually hard
# in block AMR is the part that spans levels: the 2:1 balance the whole design
# rests on, the ghost exchange that balance exists to bound, and whether
# refining and coarsening lose anything.
#
# Several checks use a uniform field on purpose. Prolongation, restriction and
# a diffusion stencil are all exact on a constant, whatever the level
# structure, so any cross-level mistake shows up as a cell that is no longer
# that constant - and shows up at the cell, not as a plausible-looking field
# that happens to be wrong.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "math.m";
	math: Math;
include "amr.m";
	amr: Amr;
	Forest, Block: import amr;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

close(a, b, tol: real): int
{
	d := a - b;
	if(d < 0.0)
		d = -d;
	return d <= tol;
}

# The deepest leaf anywhere under b.
maxleaf(b: ref Block): int
{
	if(b.active)
		return b.level;
	m := b.level;
	for(i := 0; i < len b.children; i++){
		l := maxleaf(b.children[i]);
		if(l > m)
			m = l;
	}
	return m;
}

# The block covering virtual coordinate (ni,nj,nk) at the given level: descend
# from the root that contains it, stopping early if a leaf is reached. Child
# order matches refine()'s, dz*4+dy*2+dx.
findblock(f: ref Forest, level, ni, nj, nk: int): ref Block
{
	ri := ni >> level;
	rj := nj >> level;
	rk := nk >> level;
	if(ri < 0 || ri >= f.nx0 || rj < 0 || rj >= f.ny0 || rk < 0 || rk >= f.nz0)
		return nil;
	b := f.roots[rk*f.ny0*f.nx0 + rj*f.nx0 + ri];
	for(l := 0; l < level; l++){
		if(b.active)
			return b;
		sh := level-1-l;
		dx := (ni >> sh) & 1;
		dy := (nj >> sh) & 1;
		dz := (nk >> sh) & 1;
		b = b.children[dz*4 + dy*2 + dx];
	}
	return b;
}

# No two face-adjacent leaves may differ by more than one level. This is what
# bounds exchange() to a same-level, one-coarser, or up-to-four-finer
# neighbour per face; if it does not hold, exchange is reading something it
# was never designed to read, and the result is wrong rather than an error.
balance(f: ref Forest, what: string)
{
	blocks := amr->activeblocks(f);
	worst := 0;
	nbad := 0;
	for(i := 0; i < len blocks; i++){
		b := blocks[i];
		for(d := 0; d < 6; d++){
			ni := b.bi; nj := b.bj; nk := b.bk;
			case d {
			0 => ni--;
			1 => ni++;
			2 => nj--;
			3 => nj++;
			4 => nk--;
			5 => nk++;
			}
			nb := findblock(f, b.level, ni, nj, nk);
			if(nb == nil)
				continue;		# domain boundary
			diff: int;
			if(nb.active)
				diff = nb.level - b.level;
			else
				diff = maxleaf(nb) - b.level;
			if(diff < 0)
				diff = -diff;
			if(diff > worst)
				worst = diff;
			if(diff > 1)
				nbad++;
		}
	}
	if(nbad != 0)
		bad(sprint("%s: %d face pairs differ by more than one level (worst %d)",
			what, nbad, worst));
	else
		print("  %-28s balanced, %d leaves, worst face difference %d\n",
			what, len blocks, worst);
}

# Every interior cell equals v, in every active block.
uniform(f: ref Forest, v: real, what: string): int
{
	blocks := amr->activeblocks(f);
	bs := f.blocksize;
	for(i := 0; i < len blocks; i++)
		for(z := 0; z < bs; z++)
			for(y := 0; y < bs; y++)
				for(x := 0; x < bs; x++){
					g := amr->get(blocks[i], bs, x, y, z);
					if(!close(g, v, 1e-12)){
						bad(sprint("%s: block %d cell (%d,%d,%d) is %g, expected %g",
							what, i, x, y, z, g, v));
						return 0;
					}
				}
	return 1;
}

# Refinement flags anything whose centre is inside a ball. Module-level state
# because Criterion is a bare function reference.
ccx, ccy, ccz, crad: real;

# A splat diffused for a while, and how much mass was lost doing it.
drift(f: ref Forest, what: string): real
{
	amr->clear(f, 0.0);
	amr->splat(f, 0.5, 0.5, 0.5, 0.12, 1.0);
	m0 := amr->totalmass(f);
	if(m0 <= 0.0){
		bad(sprint("%s: splat put no mass in the forest (%g)", what, m0));
		return 0.0;
	}
	for(s := 0; s < 20; s++)
		amr->sweep(f, 0.05, 0.0005);
	m1 := amr->totalmass(f);
	d := math->fabs(m1-m0)/math->fabs(m0);
	print("  %-28s %d leaves, mass drift %g\n", what, len amr->activeblocks(f), d);
	return d;
}

inball(cx, cy, cz, nil, nil, nil: real): int
{
	dx := cx-ccx; dy := cy-ccy; dz := cz-ccz;
	return dx*dx + dy*dy + dz*dz <= crad*crad;
}

# Everything, so a forest refines uniformly to maxlevel.
everywhere(nil, nil, nil, nil, nil, nil: real): int
{
	return 1;
}

# Only the left half: the right half must coarsen away while the left stays
# at maxlevel, which is what puts coarsening next to deep refinement.
lefthalf(cx, nil, nil, nil, nil, nil: real): int
{
	return cx < 0.5;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	amr = load Amr Amr->PATH;
	if(amr == nil || math == nil){
		print("amrtest: load: %r\n");
		raise "fail:load";
	}

	bs := 4;
	f := amr->new(3, 3, 3, bs, 3, 1.0, 1.0, 1.0);
	if(f == nil){
		print("amrtest: new returned nil\n");
		raise "fail:new";
	}
	if(len amr->activeblocks(f) != 27)
		bad(sprint("%d leaves at level 0, expected 27", len amr->activeblocks(f)));

	# Cell size halves with each level, on every axis.
	(dx0, nil, nil) := amr->cellsize(f, 0);
	(dx1, nil, nil) := amr->cellsize(f, 1);
	(dx2, nil, nil) := amr->cellsize(f, 2);
	if(!close(dx0, 1.0/(3.0*real bs), 1e-15))
		bad(sprint("level 0 cell size %g, expected %g", dx0, 1.0/(3.0*real bs)));
	if(!close(dx1, dx0/2.0, 1e-15) || !close(dx2, dx0/4.0, 1e-15))
		bad(sprint("cell size does not halve: %g %g %g", dx0, dx1, dx2));

	# refine then coarsen must return exactly what was there. Injection
	# then volume-average is the identity on any field, not just a smooth
	# one, so this is checked with values that differ in every cell -
	# a uniform field would pass against a coarsen that simply copied one
	# child.
	r := f.roots[13];
	v := 0.0;
	for(z := 0; z < bs; z++)
		for(y := 0; y < bs; y++)
			for(x := 0; x < bs; x++){
				amr->set(r, bs, x, y, z, v);
				v += 1.5;
			}
	before := array[bs*bs*bs] of real;
	i := 0;
	for(z = 0; z < bs; z++)
		for(y = 0; y < bs; y++)
			for(x = 0; x < bs; x++)
				before[i++] = amr->get(r, bs, x, y, z);
	m0 := amr->totalmass(f);
	amr->refine(f, r);
	if(r.active)
		bad("a refined block is still active");
	if(len r.children != 8)
		bad(sprint("%d children after refine, expected 8", len r.children));
	if(len amr->activeblocks(f) != 27+7)
		bad(sprint("%d leaves after one refine, expected 34",
			len amr->activeblocks(f)));
	m1 := amr->totalmass(f);
	if(!close(m0, m1, 1e-12*(1.0+math->fabs(m0))))
		bad(sprint("refine changed the mass: %g -> %g", m0, m1));
	amr->coarsen(f, r);
	if(!r.active)
		bad("a coarsened block is not active again");
	m2 := amr->totalmass(f);
	if(!close(m0, m2, 1e-12*(1.0+math->fabs(m0))))
		bad(sprint("refine/coarsen changed the mass: %g -> %g", m0, m2));
	worst := 0.0;
	i = 0;
	for(z = 0; z < bs; z++)
		for(y = 0; y < bs; y++)
			for(x = 0; x < bs; x++){
				d := amr->get(r, bs, x, y, z) - before[i++];
				if(d < 0.0)
					d = -d;
				if(d > worst)
					worst = d;
			}
	if(worst > 1e-12)
		bad(sprint("refine then coarsen changed a cell by %g", worst));
	else
		print("  %-28s exact to %g, mass preserved\n", "refine/coarsen round trip", worst);

	# Adapt against a ball, then check the balance the design rests on.
	# Checked after every pass, not only at the end: a pass that breaks
	# balance and a later one that happens to restore it are not the same
	# as never breaking it.
	amr->clear(f, 2.5);
	ccx = 0.5; ccy = 0.5; ccz = 0.5; crad = 0.18;
	balance(f, "level 0");
	for(pass := 0; pass < 3; pass++){
		amr->adapt(f, inball);
		balance(f, sprint("after adapt pass %d", pass+1));
	}
	nleaf := len amr->activeblocks(f);
	if(nleaf <= 27)
		bad(sprint("adapt refined nothing: still %d leaves", nleaf));

	# A constant survives an exchange across every kind of level jump the
	# balanced forest contains, and survives a diffusion step, because the
	# Laplacian of a constant is zero. Both are exact statements, so any
	# cross-level mistake is a cell that is no longer 2.5.
	amr->exchange(f);
	if(uniform(f, 2.5, "exchange of a constant"))
		print("  %-28s constant preserved across %d leaves\n",
			"cross-level exchange", nleaf);
	amr->sweep(f, 0.05, 0.001);
	if(uniform(f, 2.5, "diffusion of a constant"))
		print("  %-28s constant preserved\n", "diffusion of a constant");

	# Mass under a real, non-constant evolution.
	#
	# Split in two, because the two cases have completely different
	# expectations and lumping them together would make the tight one
	# useless. With no coarse/fine interface anywhere, diffusion under the
	# zero-Neumann boundary exchange() applies is conservative and the mass
	# must not move at all - that is a real invariant, and a stencil or
	# boundary mistake breaks it. Across an interface the module documents
	# its prolongation as not flux-conservative, so mass does move; that
	# figure is measured and only loosely bounded, to catch a change of
	# behaviour rather than because any particular value is right.
	uni := amr->new(3, 3, 3, bs, 3, 1.0, 1.0, 1.0);
	d0 := drift(uni, "uniform level 0");
	if(d0 > 1e-12)
		bad(sprint("mass is not conserved on a uniform forest: %g", d0));

	uni1 := amr->new(3, 3, 3, bs, 3, 1.0, 1.0, 1.0);
	for(i2 := 0; i2 < len uni1.roots; i2++)
		amr->refine(uni1, uni1.roots[i2]);
	d1 := drift(uni1, "uniform level 1");
	if(d1 > 1e-12)
		bad(sprint("mass is not conserved when every block is refined: %g", d1));

	d2 := drift(f, "adapted, with interfaces");
	if(d2 <= 1e-6)
		bad(sprint("no interface drift at all (%g) - either the forest has no "+
			"coarse/fine interface or totalmass is not measuring mass", d2));
	if(d2 > 0.15)
		bad(sprint("interface mass drift %g is far larger than the 0.052 "+
			"measured when this was written", d2));

	# Coarsening must respect balance too.
	#
	# amr(2) used to say that coarsening never rechecks cross-neighbour
	# balance, and called that a scope limit. It is not one any more:
	# coarsenlevel() asks needsbalance() before collapsing a block, and
	# that guard is load-bearing. Removing it leaves 272 face pairs
	# differing by two levels on the forest below, so this drives the
	# coarsening path deliberately rather than leaving it to whatever a
	# refinement test happens to touch.
	#
	# Refine everything to maxlevel, then want only the left half: the
	# right half coarsens, pass by pass, alongside a left half that stays
	# deep - which is the arrangement that breaks if coarsening does not
	# look at its neighbours.
	cf := amr->new(4, 4, 4, 4, 2, 1.0, 1.0, 1.0);
	for(p := 0; p < 2; p++)
		amr->adapt(cf, everywhere);
	balance(cf, "uniform at maxlevel");
	for(p = 0; p < 3; p++){
		amr->adapt(cf, lefthalf);
		balance(cf, sprint("after coarsening pass %d", p+1));
	}
	if(len amr->activeblocks(cf) >= 4096)
		bad("nothing coarsened, so the coarsening path was not tested");

	if(fail)
		raise "fail:test";
	print("PASS\n");
}
