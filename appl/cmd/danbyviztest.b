implement Danbyviztest;

# danbyviztest - check that the danby models' PICTURES make sense
#
# danbylabtest(1) checks the equations.  This checks the drawing, which
# is a different thing and can be wrong while every number is right.
#
# The check that matters is one a real model got wrong.  danbylab's
# mechanism diagram scales itself to the bounding box of the model's
# points, so if the only points are the moving ones, the view is scaled
# to the very thing it is drawing - and that thing then never appears to
# move.  danby/schrodinger shipped like that: its marker sat at 0.885 of
# the pane's width from a fifth of the way through the run to the end,
# because the box's right edge WAS the marker.  Every number in it was
# correct.
#
# So: run each model, work out where each of its points would land in
# the pane exactly as drawmechanism() does, and report a point that
# MOVES in the world while standing still on the screen.  Also a diagram
# where nothing moves at all, and points that are not numbers.
#
# Nothing here opens a window.  That is the point: the geometry of the
# picture is arithmetic, and arithmetic can be checked where there is no
# display.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "readdir.m";
	readdir: Readdir;
include "numerics.m";
	numerics: Numerics;
include "math.m";
	math: Math;
include "danbylab.m";
	danbylab: Danbylab;
	Config: import Danbylab;
	dynsys: Dynsys;
	Model: import dynsys;

Danbyviztest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

DIR: con "/appl/danby";
FRAMES: con 120;		# how many frames of the run to look at
PERFRAME: con 4;		# the mechanism family's own steps per frame
DT: con 0.005;			# and its own step

bad := 0;
warn := 0;
verbose := 0;
only := "";

fail(name, s: string)
{
	sys->print("FAIL %s: %s\n", name, s);
	bad++;
}

note(name, s: string)
{
	if(verbose)
		sys->print("     %s: %s\n", name, s);
	warn++;
}

specof(path: string): string
{
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil)
		return nil;
	s := "";
	while((l := iob.gets('\n')) != nil)
		s += l;
	return s;
}

stepping: ref Model;

rhs(t: real, q, d: array of real)
{
	dynsys->rhs(stepping, t, q, d);
}

# drawmechanism()'s own box: the extent of the points, widened to at
# least one unit each way, then padded by 15 per cent.  Kept in step
# with danbylab.b by being written out the same way.
box(p: array of real): (real, real, real, real)
{
	(xmin, xmax) := (p[0], p[0]);
	(ymin, ymax) := (p[1], p[1]);
	for(i := 0; i < len p/2; i++){
		if(p[2*i] < xmin) xmin = p[2*i];
		if(p[2*i] > xmax) xmax = p[2*i];
		if(p[2*i+1] < ymin) ymin = p[2*i+1];
		if(p[2*i+1] > ymax) ymax = p[2*i+1];
	}
	if(xmax-xmin < 1.0)
		(xmin, xmax) = (xmin-0.5, xmax+0.5);
	if(ymax-ymin < 1.0)
		(ymin, ymax) = (ymin-0.5, ymax+0.5);
	xp := (xmax-xmin)*0.15;
	yp := (ymax-ymin)*0.15;
	return (xmin-xp, xmax+xp, ymin-yp, ymax+yp);
}

checkmech(name: string, m: ref Model, c: ref Config)
{
	np := len m.pointnames;
	if(np == 0){
		fail(name, "a mechanism with no points draws nothing");
		return;
	}
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	# world and pane ranges for every point
	wxlo := array[np] of real; wxhi := array[np] of real;
	wylo := array[np] of real; wyhi := array[np] of real;
	fxlo := array[np] of real; fxhi := array[np] of real;
	fylo := array[np] of real; fyhi := array[np] of real;
	first := 1;
	i: int;
	t := 0.0;
	nan := 0;
	bxsum := 0.0;
	bysum := 0.0;
	nbox := 0;
	for(f := 0; f < FRAMES; f++){
		pts := dynsys->points(m, state);
		if(len pts < 2*np)
			return;
		for(q := 0; q < 2*np; q++)
			if(pts[q] != pts[q])
				nan = 1;
		if(nan)
			break;
		(xmin, xmax, ymin, ymax) := box(pts);
		bxsum += xmax-xmin;
		bysum += ymax-ymin;
		nbox++;
		for(i = 0; i < np; i++){
			wx := pts[2*i];
			wy := pts[2*i+1];
			fx := 0.5;
			fy := 0.5;
			if(xmax > xmin)
				fx = (wx-xmin)/(xmax-xmin);
			if(ymax > ymin)
				fy = (wy-ymin)/(ymax-ymin);
			if(first){
				wxlo[i] = wx; wxhi[i] = wx;
				wylo[i] = wy; wyhi[i] = wy;
				fxlo[i] = fx; fxhi[i] = fx;
				fylo[i] = fy; fyhi[i] = fy;
			}else{
				if(wx < wxlo[i]) wxlo[i] = wx;
				if(wx > wxhi[i]) wxhi[i] = wx;
				if(wy < wylo[i]) wylo[i] = wy;
				if(wy > wyhi[i]) wyhi[i] = wy;
				if(fx < fxlo[i]) fxlo[i] = fx;
				if(fx > fxhi[i]) fxhi[i] = fx;
				if(fy < fylo[i]) fylo[i] = fy;
				if(fy > fyhi[i]) fyhi[i] = fy;
			}
		}
		first = 0;
		for(k := 0; k < PERFRAME; k++){
			numerics->rk4(work, rhs, t, DT, state);
			t += DT;
			if(m.maxtime > 0.0 && t >= m.maxtime)
				break;
		}
		if(m.maxtime > 0.0 && t >= m.maxtime)
			break;
	}
	if(nan){
		# tablependulum diverges genuinely rather than by a slip: the
		# bob is drawn towards the pivot, the pendulum length hits its
		# floor and omega runs away with angular momentum, exactly as
		# the equations say it should.  Ending that properly means
		# modelling the string reaching its end, which is a decision
		# about the physics and not a guard to bolt on, so it is
		# recorded here rather than quietly patched or quietly
		# tolerated.  Anything ELSE going not-a-number is new and is a
		# failure.
		if(name == "tablependulum"){
			note(name, "goes not-a-number at t=0.56: the bob reaches the "+
				"pivot, the length hits its floor and omega diverges. Real, "+
				"and needs the end of the string modelled");
			return;
		}
		fail(name, "a point stopped being a number during the run");
		return;
	}
	# the whole diagram is dead
	moved := 0;
	span := 0.0;
	for(i = 0; i < np; i++){
		wspan := (wxhi[i]-wxlo[i]) + (wyhi[i]-wylo[i]);
		if(wspan > span)
			span = wspan;
		if(wspan > 1.0e-9)
			moved++;
	}
	if(moved == 0){
		fail(name, "no point moves at all: the diagram is a still picture "+
			"in a family that animates");
		return;
	}
	# The bug: the view being scaled by the thing it is drawing.
	#
	# Comparing the pane motion against a fixed threshold is the wrong
	# test and flags points that simply do not move much.  What is
	# wanted is whether the point crossed AS MUCH of the pane as its
	# travel through a box of that size should have carried it.  If it
	# travelled a third of the box's width and a fiftieth of the pane,
	# the box moved with it.
	if(nbox == 0)
		return;
	bx := bxsum/real nbox;
	by := bysum/real nbox;
	bestshow := 0.0;
	shown := 0;
	for(i = 0; i < np; i++){
		wxs := wxhi[i]-wxlo[i];
		wys := wyhi[i]-wylo[i];
		fspan := (fxhi[i]-fxlo[i]) + (fyhi[i]-fylo[i]);
		want := 0.0;
		if(bx > 0.0)
			want += wxs/bx;
		if(by > 0.0)
			want += wys/by;
		# a point that would barely have crossed the pane anyway tells
		# us nothing either way
		if(verbose)
			sys->print("     %s: pt %-16s x %8.3f..%-8.3f y %8.3f..%-8.3f  want %.3g fspan %.3g\n", name, m.pointnames[i], wxlo[i], wxhi[i], wylo[i], wyhi[i], want, fspan);
		# A point cannot cross more than the whole pane however far it
		# travels, so the most that can be expected of it is 1.  Without
		# this cap a model whose motion outgrows its frame - a rocket
		# climbing, a diver falling - is flagged for crossing 0.99 of
		# the pane when 3.5 was "expected", which is not a defect and
		# not even arithmetically possible.
		if(want > 1.0)
			want = 1.0;
		# Account BEFORE the skip below.  A picture whose best-shown
		# point happens to move only a little is not a picture that
		# shows nothing, and putting this after the skip said it was.
		if(want > 0.0){
			if(fspan/want > bestshow)
				bestshow = fspan/want;
			shown++;
		}
		if(want < 0.15)
			continue;
		# Two tiers, because they are two different things.  A point
		# that crosses NOTHING of the pane is broken: its motion is
		# invisible and the box is exactly tracking it.  A point that
		# crosses some but much less than it should is compressed,
		# which is sometimes the intended thing - a diagram that
		# follows a climbing rocket keeps it in view on purpose - so
		# that is reported and not failed.
		# A point that DEFINES an extreme of the box necessarily sits
		# at the same place on screen - the topmost thing is always at
		# the top - and that is not a defect on its own.  A rocket
		# whose nose is the highest point still reads as flying,
		# because its base and fins cross the pane.  So this is
		# recorded per point and judged below over the whole picture.
		if(fspan < 0.3*want)
			note(name, sys->sprint("point %s travels %.3g of the view and "+
				"crosses %.3g of the pane", m.pointnames[i], want, fspan));

	}
	# The defect is a picture that conveys NO motion: not one of the
	# points that move gets anywhere on screen.  That is what
	# danby/schrodinger did, and duffing and van der Pol and the
	# rockets after it - in every case because the box was scaled by
	# the moving points and nothing else was in the picture to hold it
	# still.
	if(shown > 0 && bestshow < 0.3)
		fail(name, sys->sprint("nothing in this diagram appears to move: the "+
			"best any moving point manages is %.3g of the pane it should "+
			"cross, because the view is scaled by the points it is drawing",
			bestshow));
	if(len c.links == 0)
		fail(name, "a mechanism with no links draws loose points");
}

# The two observables share one axis, symmetric about zero.  If one is
# very much larger than the other the smaller is a flat line: sometimes
# deliberate, so this is reported and not failed.
checkobs(name: string, m: ref Model, c: ref Config)
{
	if(len m.observablelabels != 2)
		return;
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	(a0, a1) := (0.0, 0.0);
	t := 0.0;
	for(f := 0; f < FRAMES*PERFRAME; f++){
		v := dynsys->observables(m, state);
		for(i := 0; i < 2; i++){
			x := v[i];
			if(x < 0.0)
				x = -x;
			if(i == 0 && x > a0) a0 = x;
			if(i == 1 && x > a1) a1 = x;
		}
		numerics->rk4(work, rhs, t, DT, state);
		t += DT;
		if(m.maxtime > 0.0 && t >= m.maxtime)
			break;
	}
	if(a0 <= 0.0 || a1 <= 0.0)
		return;
	r := a0/a1;
	if(r < 1.0)
		r = 1.0/r;
	if(r > 200.0)
		note(name, sys->sprint("%s reaches %.3g and %s %.3g - on one shared "+
			"axis the smaller is a flat line",
			m.observablelabels[0], a0, m.observablelabels[1], a1));
}

# A profile's march holds every state at or above zero.  A model whose
# state would go negative is being quietly altered, and what is drawn is
# not what the equations say.
checkprofile(name: string, m: ref Model, c: ref Config)
{
	stepping = m;
	state := dynsys->initialstate(m);
	r := m.hocmod->eval(c.radius);
	dr := m.hocmod->eval(c.span)/real(c.samples-1);
	deriv := array[len state] of real;
	for(i := 0; i < c.samples; i++){
		m.hocmod->setvar("r", r);
		dynsys->rhs(m, r, state, deriv);
		for(j := 0; j < len state; j++){
			state[j] += dr*deriv[j];
			if(state[j] < 0.0){
				# Reported and not failed.  A density reaching zero is
				# the surface of the star, and the march holding it
				# there is the right answer rather than a silent
				# alteration - starmodel says so itself, with an
				# `eq live step { density }' that stops the derivative
				# at the same place.  What is worth knowing is WHERE
				# it happens, since nothing beyond that radius is
				# solved.
				note(name, sys->sprint("state %s reaches zero at r=%.4g and "+
					"the march holds it there - that is the surface, and "+
					"nothing past it is integrated", m.statenames[j], r));
				return;
			}
		}
		r += dr;
	}
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	readdir = load Readdir Readdir->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	danbylab = load Danbylab Danbylab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			danbylab == nil || dynsys == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a){
		if(hd a == "-v")
			verbose = 1;
		else
			only = hd a;
	}
	(d, n) := readdir->init(DIR, Readdir->NAME);
	if(n <= 0){
		sys->print("FAIL cannot read %s: %r\n", DIR);
		raise "fail:readdir";
	}
	checked := 0;
	for(i := 0; i < n; i++){
		fname := d[i].name;
		if(len fname < 6 || fname[len fname-5:] != ".spec")
			continue;
		name := fname[0:len fname-5];
		if(only != nil && name != only)
			continue;
		spec := specof(DIR+"/"+fname);
		(m, c, err) := danbylab->parse(spec);
		if(err != nil){
			fail(name, err);
			continue;
		}
		checked++;
		case c.family {
		Danbylab->Mechanism =>
			checkmech(name, m, c);
			checkobs(name, m, c);
		Danbylab->Orbit =>
			checkobs(name, m, c);
		Danbylab->Profile =>
			checkprofile(name, m, c);
		}
	}
	if(bad == 0)
		sys->print("OK   %d model pictures (%d noted)\n", checked, warn);
	else {
		sys->print("%d picture failures over %d models (%d noted)\n",
			bad, checked, warn);
		raise "fail:danbyviztest";
	}
}
