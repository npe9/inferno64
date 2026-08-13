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
};
