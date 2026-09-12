# thermo - gases, thermodynamic processes, power cycles and heat exchange
#
# SIGN CONVENTION, which is the thing to get straight before anything
# else: heat added TO the system is positive, and work done BY the
# system is positive.  So the first law reads
#
#	du = q - w
#
# and an engine that takes heat in and does work has both positive.
# The other convention exists, mostly in chemistry, and every number
# here would change sign under it.
#
# UNITS ARE SI AND ABSOLUTE.  Temperature is in kelvin, never celsius -
# a ratio of temperatures is meaningless otherwise, and every efficiency
# here is a ratio of temperatures.  Pressure is in pascals, volume is
# specific (per kilogram), energy is per kilogram.
#
# The gas is ideal unless a function says otherwise, and with constant
# specific heats.  That is the model a first course works in and it is
# wrong in the ways the man page lists.

Thermo: module
{
	PATH: con "/dis/lib/thermo.dis";

	init:	fn();

	RUNIV: con 8314.462618;		# J/(kmol K), the universal gas constant

	Gas: adt {
		name:	string;
		mw:	real;		# kg/kmol
		r:	real;		# J/(kg K), specific
		cp, cv:	real;		# J/(kg K)

		gamma:	fn(g: self ref Gas): real;
	};

	# Build a gas from any two of the three independent numbers; the
	# third follows from cp - cv = R, which is a relation and not a
	# definition, so giving all three would let a caller state an
	# impossible gas.
	fromcp:	fn(name: string, mw, cp: real): (ref Gas, string);
	fromgamma: fn(name: string, mw, gamma: real): (ref Gas, string);
	air:	fn(): ref Gas;

	# A state.  Two properties fix it for an ideal gas, and these
	# construct the third.
	State: adt {
		p, v, t: real;		# Pa, m^3/kg, K
		u, h, s: real;		# J/kg, J/kg, J/(kg K)
	};
	statepv: fn(g: ref Gas, p, v: real): (ref State, string);
	statept: fn(g: ref Gas, p, t: real): (ref State, string);
	statevt: fn(g: ref Gas, v, t: real): (ref State, string);

	# What a process does between two states: the work done by the gas
	# and the heat added to it.  The two are related by the first law
	# and each is computed from the process, not from the other, so
	# that the first law is something the test can check rather than
	# something the code assumes.
	Change: adt {
		work, heat: real;	# J/kg
		du, ds:	real;
		b:	ref State;	# where it ended up
	};
	isothermal: fn(g: ref Gas, a: ref State, p2: real): (ref Change, string);
	isobaric: fn(g: ref Gas, a: ref State, t2: real): (ref Change, string);
	isochoric: fn(g: ref Gas, a: ref State, t2: real): (ref Change, string);
	isentropic: fn(g: ref Gas, a: ref State, p2: real): (ref Change, string);
	# n = 1 is isothermal, n = gamma is isentropic, n = 0 is isobaric,
	# and n infinite is isochoric; the general case is here and the
	# named ones above are what a reader looks for.
	polytropic: fn(g: ref Gas, a: ref State, p2, n: real): (ref Change, string);

	# Power cycles, by their compression or pressure ratios.  Each
	# returns the thermal efficiency and the work and heat around the
	# cycle, so that a caller can check the first law rather than
	# taking the efficiency on trust.
	Cycle: adt {
		efficiency: real;
		wnet, qin, qout: real;	# J/kg
		states:	array of ref State;
		names:	array of string;
	};
	carnot:	fn(g: ref Gas, tc, th, p1, p2: real): (ref Cycle, string);
	otto:	fn(g: ref Gas, ratio, t1, p1, qin: real): (ref Cycle, string);
	diesel:	fn(g: ref Gas, ratio, cutoff, t1, p1: real): (ref Cycle, string);
	brayton: fn(g: ref Gas, ratio, t1, p1, t3: real): (ref Cycle, string);

	# A real gas, for the one thing an ideal gas cannot do at all:
	# have a critical point and condense.  p = RT/(v-b) - a/v^2.
	VdW: adt {
		a, b:	real;
		r:	real;

		pressure: fn(w: self ref VdW, v, t: real): real;
		# where the isotherm has its inflection, which is the
		# critical point and is exact: 8a/27Rb, a/27b^2, 3b
		critical: fn(w: self ref VdW): (real, real, real);
		# the compressibility factor pv/RT, which is 1 for an ideal
		# gas and is how far from ideal a real one is
		z:	fn(w: self ref VdW, v, t: real): real;
	};
	vanderwaals: fn(r, tc, pc: real): ref VdW;

	# Heat transfer.  A fin's efficiency is tanh(mL)/(mL), which goes
	# to one for a short fat fin and to zero for a long thin one.
	finefficiency: fn(h, k, thick, length: real): (real, string);

	# A heat exchanger, two ways.  The log mean temperature difference
	# is what a designer uses when both outlet temperatures are known;
	# the effectiveness-NTU relation is what they use when they are
	# not.  Both must give the same duty, and heattest(1) checks that
	# they do.
	PARALLEL, COUNTER: con iota;
	lmtd:	fn(arrangement: int, thi, tho, tci, tco: real): (real, string);
	# effectiveness of an exchanger of a given NTU and capacity ratio
	effectiveness: fn(arrangement: int, ntu, cr: real): (real, string);
};
