Gpu: module
{
	PATH: con "/dis/lib/gpu.dis";

	# An execution-target axis, independent of mesh(2)'s geometry
	# vocabulary and krylov(2)'s algorithm vocabulary: which of those
	# two a solve uses is a property of the equation; where the matvec
	# actually runs is a property of the machine, and this module is
	# the one place that distinction lives. Backend is configured by
	# a small command language, the same tk(2)/krylov(2) shape - one
	# verb-plus-args string per cmd() call, string result - reused for
	# device selection instead of widgets or solver parameters:
	#   device cpu|gpu       - where matvec runs (default cpu)
	#   precision f32|f64    - real tradeoff, not decoration: a GPU's
	#                          own throughput advantage is largest at
	#                          f32, at the cost of needing a looser CG/
	#                          GMRES tolerance to match (default f64)
	#   resident on|off      - keep an uploaded matrix's GPU buffers
	#                          alive across calls (default on) - the
	#                          whole reason to offload a Krylov solve
	#                          at all: matvec runs every iteration
	#                          against the SAME matrix, so paying the
	#                          upload cost once and only exchanging
	#                          the vector each call is what makes this
	#                          worth doing, not a one-shot convenience
	Backend: adt {
		device:		string;
		precision:	string;
		resident:	int;

		# Set by apply() itself - nil if its last call ran exactly as
		# configured; otherwise what it silently had to do instead
		# (e.g. "backend: device gpu requested but unavailable, using
		# cpu"). Read-only, the same convention Krylov->Solver's own
		# converged/residual/iterations use: set by a call, read
		# straight off the adt afterward, never poked directly.
		lasterror:	string;

		cmd:	fn(b: self ref Backend, arg: string): string;

		# Builds a Krylov->Apply for m, backed by whichever device b
		# is currently configured for. Never silently substitutes cpu
		# for a requested-but-unavailable gpu without saying so - see
		# lasterror above.
		apply:	fn(b: self ref Backend, m: ref Sparse->CSR): Krylov->Apply;
	};

	new:		fn(): ref Backend;

	# True only if a real GPU device is actually reachable right now -
	# a check, not a promise; there is no native GPU device wired into
	# this build yet (see gpu(2)'s own SOURCE section), so this always
	# returns false today. device gpu still works when it does -
	# apply() just falls back to cpu, observably, until a real backend
	# exists underneath this same interface.
	available:	fn(): int;
};
