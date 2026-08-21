# A CSP-style modular synthesizer: each voice, filter, oscillator, and
# envelope is its own process, wired together over typed channels
# (Sample pulls a block of samples on demand; Control sends a
# parameter change) instead of a monolithic audio callback - Limbo's
# concurrency used as the actual synthesis architecture, not just
# plumbing around one.
#
# Ported from Caerwyn Jones's Inferno lab 62 ("software synth csp
# style"), https://github.com/caerwynj/inferno-lab/tree/master/62 -
# adapted for this tree's audio device conventions (see sequencer.b),
# otherwise the original design and DSP unchanged.
Sequencer: module
{
	PATH: con "/dis/lib/sequencer.dis";
	CFREQ, CKEYON, CKEYOFF, CATTACK, CDECAY, CSUSTAIN,
	CRELEASE, CDELAY, CVOICE, CMIX, CHIGH, CLOW,
	CPOLE, CZERO, CRADIUS, CTUNE: con iota;

	BLOCK : con 4490;

	Inst: adt {
		c: Sample;
		ctl: Control;

		mk: fn(insts: Source, f: Instrument): ref Inst;
	};

	Source: type array of ref Inst;
	Sample: type chan of (array of real, chan of array of real);
	Control: type chan of (int, real);
	Instrument: type ref fn(s: Source, c: Sample, ctl: Control);

	init: fn(nil: ref Draw->Context, argv: list of string);
	modinit: fn();

	# Plays a SKINI-format score (NoteOn/NoteOff lines, as in
	# STK's own score notation - "NoteOn dt voice midinote velocity" /
	# "NoteOff dt voice") through inst, until either the file ends or
	# "stop" arrives on ctl.
	play: fn(file: string, ctl: chan of string, inst: ref Inst);

	# A session wraps one master Inst (the same graph init()'s own
	# standalone player builds - four fm voices, mixed, delayed) with
	# a small command language, the same shape tk(2)'s widget cmd and
	# krylov(2)'s own Solver.cmd already use: one verb-plus-args
	# string per call, string result. This is the layer a caller who
	# just wants "play a note" or "play a score" actually wants -
	# Control's raw (int,real) pairs and the CFREQ/CKEYON/... constants
	# stay an internal wiring detail between voices, never exposed
	# here, the same way krylov(2) never crosses pde(2)'s own interface.
	#
	#   noteon voice midinote     - voice in 0..3
	#   noteoff voice
	#   play file                 - plays a SKINI score in the background;
	#                                a session only ever has one playing
	#                                at a time - starting a second while
	#                                one is running is an error, not a
	#                                silent queue or interrupt
	#   stop                      - stops a "play" in progress; a no-op,
	#                                not an error, if nothing is playing
	Session: adt {
		inst:	ref Inst;
		playctl: chan of string;
		playing: int;

		cmd: fn(s: self ref Session, arg: string): string;
	};

	newsession: fn(): ref Session;

	fm: fn(s: Source, c: Sample, ctl: Control);
	master: fn(s: Source, c: Sample, ctl: Control);
	poly: fn(s: Source, c: Sample, ctl: Control);
	lfo: fn(s: Source, c: Sample, ctl: Control);
	delay: fn(s: Source, c: Sample, ctl: Control);
	onepole: fn(s: Source, c: Sample, ctl: Control);
	onezero: fn(s: Source, c: Sample, ctl: Control);
	twopole: fn(s: Source, c: Sample, ctl: Control);
	twozero: fn(s: Source, c: Sample, ctl: Control);
	mixer: fn(s: Source, c: Sample, ctl: Control);
	waveloop: fn(s: Source, c: Sample, ctl: Control);
	adsr: fn(s: Source, c: Sample, ctl: Control);

	sinewave: fn(): array of real;
	halfwave: fn(): array of real;
	sineblnk: fn(): array of real;
	fwavblnk: fn(): array of real;
	noise: fn(): array of real;
	impuls: fn(n: int): array of real;

	norm2raw: fn(v: array of real): array of byte;
};
