implement Tonetest;

# tonetest - check that tone(2) actually synthesises what it claims.
#
# "It made a noise" is not evidence.  This binds ordinary files over
# /dev/audio and /dev/audioctl, plays through the real code path, and
# then looks at the samples tone(2) wrote: whether a note has an attack
# and a release rather than being switched on and off, whether a voice
# has harmonics above its fundamental, and whether two parts played
# together really contain both notes.  A Goertzel filter measures the
# energy at one frequency, which is all that is needed to answer the
# last two.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "tone.m";
	tone: Tone;

Tonetest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Dir:	con "/tmp/tonetest";
Cap:	con "/tmp/tonetest/audio";
Capctl:	con "/tmp/tonetest/audioctl";

bad := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	bad++;
}

note(s: string)
{
	if(verbose)
		sys->print("     %s\n", s);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	tone = load Tone Tone->PATH;
	if(math == nil || tone == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	# Plain files standing in for the audio device, bound over /dev as a
	# directory so this works whether or not the host has one: MBEFORE,
	# so these names win where a real #A is already there.
	sys->create(Dir, Sys->OREAD, Sys->DMDIR|8r777);
	for(f := 0; f < 2; f++){
		name := Cap;
		if(f == 1)
			name = Capctl;
		fd := sys->create(name, Sys->OWRITE, 8r666);
		if(fd == nil){
			sys->print("FAIL create %s: %r\n", name);
			raise "fail:create";
		}
	}
	if(sys->bind(Dir, "/dev", Sys->MBEFORE) < 0){
		sys->print("FAIL bind %s over /dev: %r\n", Dir);
		raise "fail:bind";
	}
	if((e := tone->init()) != nil){
		sys->print("FAIL tone->init: %s\n", e);
		raise "fail:init";
	}
	tone->settempo(400);

	# --- a note has a shape ---
	# "string" ramps in over 90ms and out over its release; a beeper's
	# note is full amplitude at the first sample and gone at the last.
	tone->setvoice("string");
	sine := capture("5qC");
	if(len sine < 1000){
		fail("string 5qC produced no samples");
	}else{
		head := rms(sine, 0, 200);
		mid := rms(sine, len sine/2 - 500, len sine/2 + 500);
		tail := rms(sine, len sine-200, len sine);
		note(sys->sprint("string attack rms %.4f, middle %.4f, release %.4f",
			head, mid, tail));
		if(head >= mid*0.5)
			fail(sys->sprint("string has no attack: first 200 samples rms %.4f against %.4f in the middle", head, mid));
		if(tail >= mid*0.5)
			fail(sys->sprint("string has no release: last 200 samples rms %.4f against %.4f in the middle", tail, mid));
	}

	# --- a voice has a timbre ---
	# C5 is 523.25Hz.  A pure sine has nothing at twice that; the organ
	# and the reed do.
	f0 := 523.25;
	tone->setvoice("sine");
	s1 := capture("5qC");
	tone->setvoice("organ");
	s2 := capture("5qC");
	if(len s1 < 1000 || len s2 < 1000){
		fail("no samples for the timbre comparison");
	}else{
		r1 := ratio(s1, f0);
		r2 := ratio(s2, f0);
		note(sys->sprint("second harmonic over fundamental: sine %.5f, organ %.5f", r1, r2));
		if(r1 > 0.02)
			fail(sys->sprint("the sine voice has a second harmonic at %.4f of its fundamental", r1));
		if(r2 < 0.10)
			fail(sys->sprint("the organ voice has no second harmonic: %.4f of its fundamental", r2));
	}

	# --- two notes at once ---
	# a perfect fifth: C5 and G5.  One part has one of them, both parts
	# have both, which is the thing a one-bit square wave cannot do.
	g0 := 783.99;
	tone->setvoice("flute");
	one := capture("5qC");
	both := capturep(array[] of {"5qC", "5qG"});
	if(len one < 1000 || len both < 1000){
		fail("no samples for the polyphony comparison");
	}else{
		oneg := goertzel(one, g0)/goertzel(one, f0);
		bothg := goertzel(both, g0)/goertzel(both, f0);
		note(sys->sprint("G over C: one part %.5f, two parts %.5f", oneg, bothg));
		if(oneg > 0.05)
			fail(sys->sprint("a single C already has %.4f of a G in it", oneg));
		if(bothg < 0.3)
			fail(sys->sprint("two parts have only %.4f of a G against the C", bothg));
	}

	if(bad == 0)
		sys->print("OK   tone(2): notes have a shape, voices have harmonics, parts mix\n");
	else {
		sys->print("%d failures\n", bad);
		raise "fail:tonetest";
	}
}

# capture: play one score and return the samples it wrote, as -1..1
capture(score: string): array of real
{
	return grab(array[] of {score}, 1);
}

capturep(parts: array of string): array of real
{
	return grab(parts, 0);
}

grab(parts: array of string, one: int): array of real
{
	before := filesize(Cap);
	e: string;
	if(one)
		e = tone->play(parts[0]);
	else
		e = tone->playparts(parts);
	if(e != nil){
		fail("play: "+e);
		return nil;
	}
	after := filesize(Cap);
	n := int (after-before);
	if(n <= 0)
		return nil;
	fd := sys->open(Cap, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[n] of byte;
	if(sys->pread(fd, buf, len buf, before) != len buf)
		return nil;
	# 16-bit little-endian stereo; take the left channel
	ns := len buf / 4;
	r := array[ns] of real;
	for(i := 0; i < ns; i++){
		v := int buf[4*i] | (int buf[4*i+1] << 8);
		if(v >= 16r8000)
			v -= 16r10000;
		r[i] = real v / 32768.0;
	}
	return r;
}

filesize(name: string): big
{
	(ok, d) := sys->stat(name);
	if(ok < 0)
		return big 0;
	return d.length;
}

rms(s: array of real, from, upto: int): real
{
	if(from < 0)
		from = 0;
	if(upto > len s)
		upto = len s;
	if(upto <= from)
		return 0.0;
	t := 0.0;
	for(i := from; i < upto; i++)
		t += s[i]*s[i];
	return math->sqrt(t / real(upto-from));
}

# goertzel: the energy at one frequency, over the middle half of the
# samples so that the attack and release do not colour it.
goertzel(s: array of real, freq: real): real
{
	from := len s/4;
	upto := len s - len s/4;
	n := upto-from;
	if(n <= 0)
		return 0.0;
	w := 2.0 * Math->Pi * freq / real Tone->Rate;
	c := 2.0 * math->cos(w);
	q1 := 0.0;
	q2 := 0.0;
	for(i := from; i < upto; i++){
		q0 := c*q1 - q2 + s[i];
		q2 = q1;
		q1 = q0;
	}
	p := q1*q1 + q2*q2 - c*q1*q2;
	if(p < 0.0)
		p = 0.0;
	return math->sqrt(p) / real n;
}

ratio(s: array of real, f0: real): real
{
	base := goertzel(s, f0);
	if(base <= 0.0)
		return 0.0;
	return goertzel(s, 2.0*f0) / base;
}
