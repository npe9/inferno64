implement Dynsys;

# See module/dynsys.m's own header comment for the vocabulary this
# library owns and why it is not hoc(2)'s (an equation parser/
# evaluator, nothing more) nor pde(2)'s (grid/field-typed PDE
# problems) nor module/ode.m's (a fixed mass-spring-damper engine,
# unrelated to named equations at all).

# sys.m then draw.m first, unconditionally required before "include
# dynsys.m" - see dynsys.m's own header comment on why (hoc.m's init()/
# run() entries need Draw->Context declared, and dynsys.m includes
# hoc.m itself; draw.m itself needs Sys declared first).
include "sys.m";
include "draw.m";
include "dynsys.m";
	Expr: import Hoc;
	Sym: import Hoc;

newmodel(): ref Model
{
	m := ref Model;
	m.hocmod = load Hoc Hoc->PATH;
	# hoc(2)'s own reset() is the one required call before compile()/
	# compileeqn()/symbol() for a caller (this one) that never calls
	# hoc's init() or run() - see hoc.b's own header comment on reset()
	# for why (it lazily loads bufio/math, which compile() needs, and
	# which init()/run() would otherwise have loaded).
	m.hocmod->reset();
	return m;
}

cmd(m: ref Model, a: array of string): (int, string)
{
	if(len a == 0)
		return (0, nil);
	case a[0] {
	"param" =>
		if(len a != 5)
			return (1, "param: usage: param LABEL DEFAULT MIN MAX");
		m.paramlabels = growstrs(m.paramlabels, a[1]);
		m.parameter = growreals(m.parameter, real a[2]);
		m.minima = growreals(m.minima, real a[3]);
		m.maxima = growreals(m.maxima, real a[4]);
		m.paramsyms = growsyms(m.paramsyms, m.hocmod->symbol(a[1]));
		return (1, nil);
	"maxtime" =>
		if(len a != 2)
			return (1, "maxtime: usage: maxtime NUM");
		m.maxtime = real a[1];
		return (1, nil);
	"state" =>
		if(len a < 3)
			return (1, "state: usage: state NAME EXPR...");
		(e, err) := m.hocmod->compileeqn(joinwords(a, 2));
		if(err != nil)
			return (1, "state "+a[1]+": "+err);
		m.statenames = growstrs(m.statenames, a[1]);
		m.statesyms = growsyms(m.statesyms, m.hocmod->symbol(a[1]));
		m.initexprs = growexprs(m.initexprs, e);
		m.derivexprs = growexprs(m.derivexprs, nil); # filled in by "derivative"
		return (1, nil);
	"derivative" =>
		if(len a < 3)
			return (1, "derivative: usage: derivative NAME EXPR...");
		idx := indexof(m.statenames, a[1]);
		if(idx < 0)
			return (1, "derivative "+a[1]+": no \"state "+a[1]+" ...\" command yet - state must come first");
		(e, err) := m.hocmod->compileeqn(joinwords(a, 2));
		if(err != nil)
			return (1, "derivative "+a[1]+": "+err);
		m.derivexprs[idx] = e;
		return (1, nil);
	"eq" =>
		if(len a < 3)
			return (1, "eq: usage: eq NAME EXPR...");
		(e, err) := m.hocmod->compileeqn(joinwords(a, 2));
		if(err != nil)
			return (1, "eq "+a[1]+": "+err);
		m.eqnames = growstrs(m.eqnames, a[1]);
		m.eqsyms = growsyms(m.eqsyms, m.hocmod->symbol(a[1]));
		m.eqexprs = growexprs(m.eqexprs, e);
		return (1, nil);
	"observable" =>
		if(len a < 3)
			return (1, "observable: usage: observable LABEL EXPR...");
		(e, err) := m.hocmod->compileeqn(joinwords(a, 2));
		if(err != nil)
			return (1, "observable "+a[1]+": "+err);
		m.observablelabels = growstrs(m.observablelabels, a[1]);
		m.obsexprs = growexprs(m.obsexprs, e);
		return (1, nil);
	"point" =>
		# NAME XEXPR , YEXPR - a bare comma, so that neither
		# expression has to be braced to keep the two apart.
		comma := -1;
		for(i := 2; i < len a; i++)
			if(a[i] == ","){
				comma = i;
				break;
			}
		if(len a < 5 || comma < 3 || comma == len a-1)
			return (1, "point: usage: point NAME XEXPR , YEXPR");
		(ex, errx) := m.hocmod->compileeqn(joinwords(a[0:comma], 2));
		if(errx != nil)
			return (1, "point "+a[1]+" x: "+errx);
		(ey, erry) := m.hocmod->compileeqn(joinwords(a, comma+1));
		if(erry != nil)
			return (1, "point "+a[1]+" y: "+erry);
		m.pointnames = growstrs(m.pointnames, a[1]);
		m.pointx = growexprs(m.pointx, ex);
		m.pointy = growexprs(m.pointy, ey);
		return (1, nil);
	}
	return (0, nil);
}

check(m: ref Model): string
{
	if(m.maxtime <= 0.0)
		return "spec has no maxtime command";
	if(len m.statenames == 0)
		return "spec has no state commands";
	for(i := 0; i < len m.statenames; i++)
		if(m.derivexprs[i] == nil)
			return "state "+m.statenames[i]+": no matching derivative command";
	return nil;
}

bindparams(m: ref Model)
{
	for(i := 0; i < len m.paramsyms; i++)
		m.paramsyms[i].val = m.parameter[i];
}

initialstate(m: ref Model): array of real
{
	bindparams(m);
	n := len m.statenames;
	r := array[n] of real;
	for(i := 0; i < n; i++)
		r[i] = m.hocmod->eval(m.initexprs[i]);
	return r;
}

rhs(m: ref Model, nil: real, values, derivative: array of real)
{
	bindparams(m);
	n := len m.statenames;
	i: int;
	for(i = 0; i < n; i++)
		m.statesyms[i].val = values[i];
	for(i = 0; i < len m.eqexprs; i++)
		m.eqsyms[i].val = m.hocmod->eval(m.eqexprs[i]);
	for(i = 0; i < n; i++)
		derivative[i] = m.hocmod->eval(m.derivexprs[i]);
}

observables(m: ref Model, values: array of real): array of real
{
	bindstate(m, values);
	r := array[len m.obsexprs] of real;
	for(i := 0; i < len m.obsexprs; i++)
		r[i] = m.hocmod->eval(m.obsexprs[i]);
	return r;
}

points(m: ref Model, values: array of real): array of real
{
	bindstate(m, values);
	r := array[2*len m.pointx] of real;
	for(i := 0; i < len m.pointx; i++){
		r[2*i] = m.hocmod->eval(m.pointx[i]);
		r[2*i+1] = m.hocmod->eval(m.pointy[i]);
	}
	return r;
}

# --- small helpers ---

# bindstate: params, then state, then every eq in declaration order -
# the common prologue of rhs(), observables() and points().
bindstate(m: ref Model, values: array of real)
{
	bindparams(m);
	i: int;
	for(i = 0; i < len m.statenames; i++)
		m.statesyms[i].val = values[i];
	for(i = 0; i < len m.eqexprs; i++)
		m.eqsyms[i].val = m.hocmod->eval(m.eqexprs[i]);
}

joinwords(a: array of string, from: int): string
{
	s := "";
	for(i := from; i < len a; i++){
		if(i > from)
			s += " ";
		s += a[i];
	}
	return s;
}

indexof(a: array of string, name: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == name)
			return i;
	return -1;
}

# growstrs/growreals/growexprs/growsyms: grow an array by exactly one
# element. Limbo arrays are fixed-size, so this is the one place that
# pays for "the running table is always exactly as long as the script
# has run so far" - a copy per command, not per redraw or per step.
growstrs(a: array of string, s: string): array of string
{
	n := len a;
	r := array[n+1] of string;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = s;
	return r;
}

growreals(a: array of real, v: real): array of real
{
	n := len a;
	r := array[n+1] of real;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = v;
	return r;
}

growexprs(a: array of ref Expr, e: ref Expr): array of ref Expr
{
	n := len a;
	r := array[n+1] of ref Expr;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = e;
	return r;
}

growsyms(a: array of ref Sym, s: ref Sym): array of ref Sym
{
	n := len a;
	r := array[n+1] of ref Sym;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = s;
	return r;
}
