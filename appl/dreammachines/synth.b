implement Synth;

# Nelson's Dream Machines chapter on audio and computers isn't just
# about digitising sound - it's about the computer as an instrument in
# its own right, generating music rather than merely reproducing it.
# This tree already has the piece that would otherwise be the hard
# part: appl/lib/tone.b (module/tone.m) opens /dev/audio directly and
# renders real 16-bit PCM sine tones, including a small TempleOS-style
# Play() notation for pitch/duration/rest. What it doesn't have -
# because it's a player, not a composer - is anything to decide WHAT
# to play. That's this file: a small algorithmic composer, walking a
# musical scale one step at a time and rendering the result straight
# into tone.b's own notation, then handing it to tone->play() to
# actually perform.
#
# The walk is deliberately simple and deliberately constrained to a
# scale rather than raw chromatic pitches - every step lands on an
# in-scale degree by construction, which is most of why generative
# melodies built this way tend to sound plausible rather than random:
# small steps (up/down a scale degree) are heavily favoured, a
# same-note repeat and the occasional bigger leap happen too, and the
# whole walk is clamped to a two-octave range so it wanders without
# drifting off into a register nothing above/below can resolve back
# from. Default scale is major pentatonic (C D E G A) - the interval
# choice generative-music sketches lean on precisely because it has no
# strongly dissonant step in it at all, so almost any walk through it
# sounds reasonable; major and natural minor are also available, with
# real accidentals rendered where the scale needs them - always spelled
# as sharps (minor's own third/sixth/seventh in C would conventionally
# be written as flats, but tone.b's grammar treats # and b as
# equivalent pitches and one consistent spelling is simpler than
# getting real key-signature spelling right for no audible difference).
#
# A seeded, reproducible RNG (same idiom as appl/wm/gfxstress.b's own
# rnd()) means the same seed always composes the same tune - useful
# for checking the algorithm did what it was supposed to without
# needing to listen to it to know that much.
#
# usage: synth [nnotes] [seed] [major|minor|penta]

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "tone.m";
	tone: Tone;

Synth: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

seed: int;

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	tone = load Tone Tone->PATH;
	if(tone == nil){
		sys->fprint(sys->fildes(2), "synth: cannot load tone: %r\n");
		raise "fail:load";
	}

	nnotes := 24;
	seedval := 1;
	scalename := "penta";
	argv = tl argv;
	if(argv != nil){
		nnotes = int hd argv;
		argv = tl argv;
	}
	if(argv != nil){
		seedval = int hd argv;
		argv = tl argv;
	}
	if(argv != nil)
		scalename = hd argv;
	if(nnotes <= 0)
		nnotes = 24;

	scaledegrees: array of int;
	case scalename {
	"major" =>	scaledegrees = array[] of {0, 2, 4, 5, 7, 9, 11};
	"minor" =>	scaledegrees = array[] of {0, 2, 3, 5, 7, 8, 10};
	* =>		scaledegrees = array[] of {0, 2, 4, 7, 9};	# major pentatonic
	}

	score := compose(nnotes, seedval, scaledegrees);
	sys->print("%s\n", score);

	e := tone->play(score);
	if(e != nil)
		sys->fprint(sys->fildes(2), "synth: %s\n", e);
}

compose(nnotes: int, seedval: int, scaledegrees: array of int): string
{
	seed = seedval;
	deltas := array[] of {-3, -2, -1, -1, -1, 0, 1, 1, 1, 2, 3};
	durs := array[] of {"q", "q", "q", "e", "e", "h"};
	baseoctave := 4;
	l := len scaledegrees;

	degree := 0;
	s := "";
	for(i := 0; i < nnotes; i++){
		degree += deltas[rnd(len deltas)];
		if(degree < -7)
			degree = -7;
		if(degree > 14)
			degree = 14;

		octshift := floordiv(degree, l);
		idx := floormod(degree, l);
		semitone := scaledegrees[idx];
		abssemitone := octshift*12 + semitone;
		octave := baseoctave + floordiv(abssemitone, 12);
		st := floormod(abssemitone, 12);
		(letter, acc) := notename(st);

		dur := durs[rnd(len durs)];
		if(i > 0)
			s += " ";
		s += string octave + dur + letter + acc;
	}
	return s;
}

notename(st: int): (string, string)
{
	case st {
	0 =>	return ("C", "");
	1 =>	return ("C", "#");
	2 =>	return ("D", "");
	3 =>	return ("D", "#");
	4 =>	return ("E", "");
	5 =>	return ("F", "");
	6 =>	return ("F", "#");
	7 =>	return ("G", "");
	8 =>	return ("G", "#");
	9 =>	return ("A", "");
	10 =>	return ("A", "#");
	11 =>	return ("B", "");
	}
	return ("C", "");
}

floordiv(a, m: int): int
{
	q := a/m;
	if(a%m != 0 && (a < 0) != (m < 0))
		q--;
	return q;
}

floormod(a, m: int): int
{
	r := a%m;
	if(r < 0)
		r += m;
	return r;
}

rnd(n: int): int
{
	seed = seed*1103515245 + 12345;
	if(seed < 0)
		seed = -seed;
	if(n <= 0)
		return 0;
	return seed % n;
}
