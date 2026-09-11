implement Frame;

# Plane frames and trusses by the direct stiffness method.  See frame.m
# for the notation and for the two decisions a reader has to know about:
# the units are the caller's, and a rotation with no bending stiffness
# attached to it is held rather than left to make the matrix singular.

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "math.m";
	math: Math;
include "linalg.m";
	la: LinAlg;
include "frame.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	math = load Math Math->PATH;
	la = load LinAlg LinAlg->PATH;
}

Struct.node(s: self ref Struct, name: string): int
{
	for(i := 0; i < len s.nodes; i++)
		if(s.nodes[i].name == name)
			return i;
	return -1;
}

Struct.dof(s: self ref Struct, node, which: int): int
{
	s = nil;
	return 3*node + which;
}

Struct.displacement(s: self ref Struct, name: string, which: int): real
{
	i := s.node(name);
	if(i < 0 || s.u == nil)
		return 0.0;
	return s.u[3*i + which];
}

Struct.reactionat(s: self ref Struct, name: string, which: int): real
{
	i := s.node(name);
	if(i < 0 || s.reaction == nil)
		return 0.0;
	return s.reaction[3*i + which];
}

parse(spec: string): (ref Struct, string)
{
	s := ref Struct;
	nodes: list of ref Node;
	nn := 0;
	mems: list of ref Member;
	nm := 0;
	# supports and loads name nodes, and may do so before the node
	# line if the writer prefers; they are applied after everything is
	# read
	sups: list of (string, int, int);	# name, which dof, lineno
	lods: list of (string, int, real, int);	# name, dof, value, lineno
	lineno := 0;
	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		lineno++;
		(nw, w) := sys->tokenize(line, " \t\r");
		if(nw == 0 || (hd w)[0] == '#')
			continue;
		a := array[nw] of string;
		for(i := 0; w != nil; (w, i) = (tl w, i+1))
			a[i] = hd w;
		case a[0] {
		"node" =>
			if(nw != 4)
				return (nil, sys->sprint("line %d: node is a name and two coordinates", lineno));
			n := ref Node;
			n.name = a[1];
			n.x = real a[2];
			n.y = real a[3];
			for(l := nodes; l != nil; l = tl l)
				if((hd l).name == n.name)
					return (nil, sys->sprint("line %d: there is already a node called %s", lineno, n.name));
			nodes = n :: nodes;
			nn++;
		"bar" or "beam" =>
			m := ref Member;
			if(a[0] == "bar"){
				if(nw != 5)
					return (nil, sys->sprint("line %d: bar is two nodes, E and the area", lineno));
				m.kind = BAR;
				m.inertia = 0.0;
			} else {
				if(nw != 6)
					return (nil, sys->sprint("line %d: beam is two nodes, E, the area and the second moment", lineno));
				m.kind = BEAM;
				m.inertia = real a[5];
				if(m.inertia <= 0.0)
					return (nil, sys->sprint("line %d: a beam with no second moment of area does not bend; write bar if that is what is meant", lineno));
			}
			m.e = real a[3];
			m.area = real a[4];
			if(m.e <= 0.0 || m.area <= 0.0)
				return (nil, sys->sprint("line %d: E and the area must be positive", lineno));
			m.udl = 0.0;
			# the node indices are filled in later, once every node
			# line has been read
			m.a = -1;
			m.b = -1;
			mems = m :: mems;
			nm++;
			sups = (a[1], -1, lineno) :: sups;	# placeholder, see below
			sups = (a[2], -2, lineno) :: sups;
		"fix" =>
			if(nw != 2)
				return (nil, sys->sprint("line %d: fix is a node", lineno));
			sups = (a[1], DX, lineno) :: (a[1], DY, lineno) :: (a[1], DR, lineno) :: sups;
		"pin" =>
			if(nw != 2)
				return (nil, sys->sprint("line %d: pin is a node", lineno));
			sups = (a[1], DX, lineno) :: (a[1], DY, lineno) :: sups;
		"roller" =>
			if(nw != 3 || (a[2] != "x" && a[2] != "y"))
				return (nil, sys->sprint("line %d: roller is a node and x or y", lineno));
			d := DX;
			if(a[2] == "y")
				d = DY;
			sups = (a[1], d, lineno) :: sups;
		"force" =>
			if(nw != 4)
				return (nil, sys->sprint("line %d: force is a node and two components", lineno));
			lods = (a[1], DX, real a[2+0], lineno) :: lods;
			lods = (a[1], DY, real a[3], lineno) :: lods;
		"moment" =>
			if(nw != 3)
				return (nil, sys->sprint("line %d: moment is a node and a value", lineno));
			lods = (a[1], DR, real a[2], lineno) :: lods;
		"udl" =>
			if(nw != 2 && nw != 4)
				return (nil, sys->sprint("line %d: udl is the load on the member just declared", lineno));
			if(mems == nil)
				return (nil, sys->sprint("line %d: udl before any member", lineno));
			(hd mems).udl = real a[1];
		* =>
			return (nil, sys->sprint("line %d: no such thing as a %s", lineno, a[0]));
		}
	}
	if(nn == 0)
		return (nil, "the structure has no nodes");
	if(nm == 0)
		return (nil, "the structure has no members");
	s.nodes = array[nn] of ref Node;
	i := nn;
	for(l := nodes; l != nil; l = tl l)
		s.nodes[--i] = hd l;
	s.members = array[nm] of ref Member;
	i = nm;
	for(ml := mems; ml != nil; ml = tl ml)
		s.members[--i] = hd ml;

	# now that the nodes exist, resolve the names.  The member ends
	# were pushed onto the support list as placeholders in order, so
	# walk them off it in the same order.
	mi := nm;
	rest2: list of (string, int, int);
	for(sl := sups; sl != nil; sl = tl sl){
		(name, which, ln) := hd sl;
		if(which >= 0){
			rest2 = (name, which, ln) :: rest2;
			continue;
		}
		k := s.node(name);
		if(k < 0)
			return (nil, sys->sprint("line %d: there is no node called %s", ln, name));
		if(which == -2)
			s.members[--mi].b = k;
		else
			s.members[mi].a = k;
	}
	for(k := 0; k < nm; k++){
		m := s.members[k];
		if(m.a == m.b)
			return (nil, sys->sprint("member %d runs from a node to itself", k+1));
		(dx, dy) := (s.nodes[m.b].x - s.nodes[m.a].x, s.nodes[m.b].y - s.nodes[m.a].y);
		m.length = math->sqrt(dx*dx + dy*dy);
		if(m.length == 0.0)
			return (nil, sys->sprint("member %d has no length: its two nodes are in the same place", k+1));
		m.c = dx/m.length;
		m.s = dy/m.length;
	}

	nd := 3*nn;
	s.restrained = array[nd] of int;
	s.applied = array[nd] of real;
	for(k = 0; k < nd; k++){
		s.restrained[k] = 0;
		s.applied[k] = 0.0;
	}
	for(sl = rest2; sl != nil; sl = tl sl){
		(name, which, ln) := hd sl;
		k = s.node(name);
		if(k < 0)
			return (nil, sys->sprint("line %d: there is no node called %s", ln, name));
		s.restrained[3*k + which] = 1;
	}
	for(ll := lods; ll != nil; ll = tl ll){
		(name, which, v, ln) := hd ll;
		k = s.node(name);
		if(k < 0)
			return (nil, sys->sprint("line %d: there is no node called %s", ln, name));
		s.applied[3*k + which] += v;
	}
	return (s, nil);
}

# The element stiffness in its own directions: axial along it, bending
# across it.  Order is (u1, v1, r1, u2, v2, r2).
localk(m: ref Member): array of array of real
{
	k := array[6] of array of real;
	for(i := 0; i < 6; i++){
		k[i] = array[6] of real;
		for(j := 0; j < 6; j++)
			k[i][j] = 0.0;
	}
	l := m.length;
	ea := m.e*m.area/l;
	k[0][0] = k[3][3] = ea;
	k[0][3] = k[3][0] = -ea;
	if(m.kind == BEAM){
		ei := m.e*m.inertia;
		(l2, l3) := (l*l, l*l*l);
		k[1][1] = k[4][4] = 12.0*ei/l3;
		k[1][4] = k[4][1] = -12.0*ei/l3;
		k[1][2] = k[2][1] = 6.0*ei/l2;
		k[1][5] = k[5][1] = 6.0*ei/l2;
		k[2][4] = k[4][2] = -6.0*ei/l2;
		k[4][5] = k[5][4] = -6.0*ei/l2;
		k[2][2] = k[5][5] = 4.0*ei/l;
		k[2][5] = k[5][2] = 2.0*ei/l;
	}
	return k;
}

# The load a uniformly distributed load puts on the two ends, in the
# member's own directions.  The CONSISTENT form, from integrating the
# element's own shape functions against the load - not half the load at
# each end, which gets the reactions right and the deflection wrong.
localload(m: ref Member): array of real
{
	f := array[6] of real;
	for(i := 0; i < 6; i++)
		f[i] = 0.0;
	if(m.udl == 0.0)
		return f;
	(w, l) := (m.udl, m.length);
	f[1] = f[4] = w*l/2.0;
	if(m.kind == BEAM){
		f[2] = w*l*l/12.0;
		f[5] = -w*l*l/12.0;
	}
	return f;
}

# global = T' * local.  T takes a global vector into the member's own
# directions; it is a rotation on the two translations and nothing on
# the rotation.
transform(m: ref Member): array of array of real
{
	t := array[6] of array of real;
	for(i := 0; i < 6; i++){
		t[i] = array[6] of real;
		for(j := 0; j < 6; j++)
			t[i][j] = 0.0;
	}
	(c, s) := (m.c, m.s);
	t[0][0] = c;  t[0][1] = s;
	t[1][0] = -s; t[1][1] = c;
	t[2][2] = 1.0;
	t[3][3] = c;  t[3][4] = s;
	t[4][3] = -s; t[4][4] = c;
	t[5][5] = 1.0;
	return t;
}

solve(s: ref Struct): string
{
	if(la == nil)
		return "linalg is not loaded";
	nd := 3*len s.nodes;
	# the whole stiffness matrix, in the column-major order linalg(2)
	# wants
	k := array[nd*nd] of real;
	for(i := 0; i < nd*nd; i++)
		k[i] = 0.0;
	f := array[nd] of real;
	for(i = 0; i < nd; i++)
		f[i] = s.applied[i];
	for(e := 0; e < len s.members; e++){
		m := s.members[e];
		kl := localk(m);
		t := transform(m);
		# kg = T' kl T
		kg := array[6] of array of real;
		for(i = 0; i < 6; i++){
			kg[i] = array[6] of real;
			for(j := 0; j < 6; j++){
				v := 0.0;
				for(p := 0; p < 6; p++)
					for(q := 0; q < 6; q++)
						v += t[p][i]*kl[p][q]*t[q][j];
				kg[i][j] = v;
			}
		}
		map := array[] of {3*m.a, 3*m.a+1, 3*m.a+2, 3*m.b, 3*m.b+1, 3*m.b+2};
		for(i = 0; i < 6; i++)
			for(j := 0; j < 6; j++)
				k[map[i] + nd*map[j]] += kg[i][j];
		# and the distributed load, turned into forces on the ends
		fl := localload(m);
		for(i = 0; i < 6; i++){
			v := 0.0;
			for(p := 0; p < 6; p++)
				v += t[p][i]*fl[p];
			f[map[i]] += v;
		}
	}
	# A rotation with nothing to resist it - a joint where only bars
	# meet - is held at zero.  A TRANSLATION with nothing to resist it
	# is a mechanism and is refused, since holding it would be
	# inventing a support the structure does not have.
	held := 0;
	for(i = 0; i < nd; i++){
		if(s.restrained[i] || k[i + nd*i] != 0.0)
			continue;
		if(i%3 == DR && f[i] == 0.0){
			s.restrained[i] = 1;
			held++;
			continue;
		}
		return sys->sprint("node %s can move %s without stretching anything: "+
			"the structure is a mechanism, not a structure",
			s.nodes[i/3].name, dofname(i%3));
	}
	s.heldrot = held;
	# take out the held degrees of freedom
	idx := array[nd] of int;
	nf := 0;
	for(i = 0; i < nd; i++)
		if(s.restrained[i])
			idx[i] = -1;
		else
			idx[i] = nf++;
	if(nf == 0)
		return "every degree of freedom is held: there is nothing to solve";
	kr := array[nf*nf] of real;
	for(i = 0; i < nf*nf; i++)
		kr[i] = 0.0;
	fr := array[nf] of real;
	for(i = 0; i < nd; i++){
		if(idx[i] < 0)
			continue;
		fr[idx[i]] = f[i];
		for(j := 0; j < nd; j++)
			if(idx[j] >= 0)
				kr[idx[i] + nf*idx[j]] = k[i + nd*j];
	}
	ipvt := array[nf] of int;
	if(la->dgefa(kr, nf, nf, ipvt) != 0)
		return "the structure is a mechanism: some part of it moves without "+
			"stretching anything, so there is no single answer";
	la->dgesl(kr, nf, nf, ipvt, fr, 0);
	s.u = array[nd] of real;
	for(i = 0; i < nd; i++)
		if(idx[i] < 0)
			s.u[i] = 0.0;
		else
			s.u[i] = fr[idx[i]];
	# the reactions are what the held degrees of freedom had to supply
	s.reaction = array[nd] of real;
	for(i = 0; i < nd; i++){
		s.reaction[i] = 0.0;
		if(!s.restrained[i])
			continue;
		v := 0.0;
		for(j := 0; j < nd; j++)
			v += k[i + nd*j]*s.u[j];
		s.reaction[i] = v - f[i];
	}
	return nil;
}

dofname(d: int): string
{
	case d {
	DX =>	return "sideways";
	DY =>	return "up and down";
	}
	return "in rotation";
}

memberforces(s: ref Struct, i: int): ref Forces
{
	if(s.u == nil || i < 0 || i >= len s.members)
		return nil;
	m := s.members[i];
	t := transform(m);
	map := array[] of {3*m.a, 3*m.a+1, 3*m.a+2, 3*m.b, 3*m.b+1, 3*m.b+2};
	ul := array[6] of real;
	for(p := 0; p < 6; p++){
		v := 0.0;
		for(q := 0; q < 6; q++)
			v += t[p][q]*s.u[map[q]];
		ul[p] = v;
	}
	kl := localk(m);
	fl := array[6] of real;
	ll := localload(m);
	for(p = 0; p < 6; p++){
		v := 0.0;
		for(q := 0; q < 6; q++)
			v += kl[p][q]*ul[q];
		fl[p] = v - ll[p];
	}
	f := ref Forces;
	# tension is positive, and the force at the far end is the one
	# pulling the member: f[3] is along the member at end b
	f.axial = fl[3];
	f.shear1 = fl[1];
	f.moment1 = fl[2];
	f.shear2 = fl[4];
	f.moment2 = fl[5];
	return f;
}

# Everything must balance.  The moments are taken about the origin,
# which is as good a point as any and is not any special point of the
# structure.
equilibrium(s: ref Struct): (real, real, real)
{
	if(s.u == nil)
		return (0.0, 0.0, 0.0);
	(fx, fy, mo) := (0.0, 0.0, 0.0);
	for(i := 0; i < len s.nodes; i++){
		n := s.nodes[i];
		(px, py) := (s.applied[3*i+DX] + s.reaction[3*i+DX],
			     s.applied[3*i+DY] + s.reaction[3*i+DY]);
		fx += px;
		fy += py;
		mo += n.x*py - n.y*px;
		mo += s.applied[3*i+DR] + s.reaction[3*i+DR];
	}
	# a distributed load acts along the member, not at a node
	for(e := 0; e < len s.members; e++){
		m := s.members[e];
		if(m.udl == 0.0)
			continue;
		# its resultant, across the member, at the middle
		tot := m.udl*m.length;
		(gx, gy) := (-m.s*tot, m.c*tot);
		(mx, my) := (0.5*(s.nodes[m.a].x + s.nodes[m.b].x),
			     0.5*(s.nodes[m.a].y + s.nodes[m.b].y));
		fx += gx;
		fy += gy;
		mo += mx*gy - my*gx;
	}
	return (fx, fy, mo);
}
