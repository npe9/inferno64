Tone: module
{
	PATH:	con "/dis/lib/tone.dis";

	Rate:	con 22050;	# samples/sec, matches audio(3) default

	init:	fn(): string;
	# PC-speaker style: freq in Hz (0 = silence/off). duration_ms <= 0 plays until stop.
	snd:	fn(freq: int);
	beep:	fn(freq, duration_ms: int);
	stop:	fn();
	# TempleOS-ish Play() subset: digits set octave (4-6),
	# durations w/h/q/e/s/t (whole..thirty-second), dotted duration '.',
	# notes A-G, #/b accidentals, rests R.
	# Example: "6hEqDC5B6CDhE"
	play:	fn(score: string): string;

	# --- past the PC speaker ---
	#
	# TempleOS drove a one-bit square wave through the timer chip, so a
	# note there is a frequency and nothing else.  Inferno writes 16-bit
	# stereo PCM to audio(3) and is not obliged to pretend otherwise.
	# What that buys, and what the calls below expose:
	#
	#   a timbre  - each voice is a harmonic series rendered once into a
	#               wavetable at setvoice() time, so a note costs a table
	#               lookup per sample rather than a sin() per harmonic
	#   a shape   - every note has an attack, a decay to its sustain
	#               level and a release, so notes start and stop instead
	#               of being switched on and off
	#   more than one note at a time - playparts() renders several scores
	#               together and mixes them, which a square wave cannot
	#               do at all
	#
	# The old calls keep working and now sound like the current voice.

	# voicenames: the built-in voices, in a fixed order.
	voicenames:	fn(): list of string;

	# setvoice: choose one by name; nil, or an error naming what is
	# available.  Rebuilds the wavetable, so call it between notes.
	setvoice:	fn(name: string): string;

	# playparts: play several scores at once, one per part, all starting
	# together.  Each part uses the same syntax as play().  This is the
	# call that makes a chord or a bass line possible.
	playparts:	fn(parts: array of string): string;

	# tempo: quarter-note length in milliseconds, for play() and
	# playparts().  500 (120bpm) unless set.
	settempo:	fn(quarter_ms: int);

	# --- one voice, several things wanting it ---
	#
	# beep() returns at once and the next one replaces what is
	# sounding, which is fine for a program making one noise at a time
	# and wrong for anything with events in it: a footstep issued a
	# frame after an explosion cuts the explosion off.
	#
	# sfx() is an arbiter rather than a mixer, because there is nothing
	# here to mix with.  An effect states a priority and how long it
	# lasts; one of lower priority asked for while a louder one is
	# still sounding is dropped, and one of equal or higher priority
	# takes over.  sfxtick() must be called regularly - once a frame,
	# for a program that has frames - or a finished effect goes on
	# holding the voice.
	sfx:		fn(pri, freq, ms: int);
	sfxtick:	fn();
};
