#
# A voice model, held open.
#
# say(1) loaded sixty megabytes of model, spoke one utterance and exited, which
# costs between one and two seconds whatever is being said. That is invisible in
# a narrated demo with pauses in it and hopeless for anything interactive: a
# system that speaks what you type cannot spend a second and a half deciding to.
#
# So the model is opened once and kept. A Speaker is an ml(3) instance with the
# voice already loaded and its symbol table already read; speaking is then a
# feed, a run and a read.
#
Voice: module
{
	PATH:	con "/dis/lib/voice.dis";

	MODEL:	con "/lib/ml/voices/en_US-lessac-low.onnx";
	RATE:	con 16000;		# what this voice was trained at

	Speaker: adt {
		dir:	string;		# the ml(3) instance directory
		ctl:	ref Sys->FD;	# held open: closing it frees the instance
		rate:	int;

		# the voice's own symbol table, sorted, read once at open
		sym:	array of string;
		id:	array of int;

		# Phonemes in, samples out, between -1 and 1. The arranging the
		# model wants - begin, pad between every symbol, end - happens
		# here, because it is identical for every utterance.
		speak:	fn(s: self ref Speaker, phonemes: string): (array of real, string);

		# One symbol to its number, or -1.
		lookup:	fn(s: self ref Speaker, sym: string): int;

		# The model's own wire, with no arranging: whatever ids are given
		# go straight in. speak() builds its sequence and calls this;
		# it is exposed for the one caller that wants the model's raw
		# input untouched - say(1)'s id... form, which exists to show
		# what speak() would otherwise do invisibly.
		feedids: fn(s: self ref Speaker, ids: array of int): (array of real, string);
	};

	init:	fn(): string;

	# Load a model and keep it. units is ml(3)'s, "cpu" if nil - see say(1)
	# for why the accelerator is not the default.
	open:	fn(model, units: string): (ref Speaker, string);

	# Samples to a file, or to /dev/audio - which is told the format first,
	# because it infers nothing from what is written to it. Returns nil, or
	# what went wrong.
	play:	fn(pcm: array of real, rate: int, out: string): string;

	# Samples as the signed 16-bit little-endian the audio device takes.
	pcmbytes: fn(pcm: array of real): array of byte;
};
