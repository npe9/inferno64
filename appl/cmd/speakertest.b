implement Command;

#
# Tests voice(2), the library that holds a neural voice model open across more
# than one utterance. say(1) is built on this now rather than doing its own
# model-loading and per-utterance wire protocol, so this is also what protects
# say(1) from a regression in either.
#
# Needs the model and a pool big enough for it - see say(1) - so this is not
# part of runtests(1)'s default sweep. Run it the same way:
#
#	speakertest	# under emu -pmain=512m -pheap=512m ...
#
# What can and cannot be tested is the same split as voicetest(1) and
# phontest(1): nothing here can hear, so this does not claim any utterance
# sounds right. It claims what holding the model open is FOR - that a second
# utterance is fast - and what the refactor could have broken silently - that
# feedids(), the raw form say(1)'s id... syntax uses, still agrees with what
# speak() builds for itself.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
include "phon.m";
	phon: Phon;
include "voice.m";
	voice: Voice;
	Speaker: import voice;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	phon = load Phon Phon->PATH;
	voice = load Voice Voice->PATH;
	if(sys == nil || phon == nil || voice == nil){
		print("speakertest: load: %r\n");
		raise "fail:load";
	}
	if((e := voice->init()) != nil){
		print("speakertest: %s\n", e);
		raise "fail:init";
	}
	if((e = phon->init(nil)) != nil){
		print("speakertest: %s\n", e);
		raise "fail:init";
	}

	t0 := sys->millisec();
	(sp, err) := voice->open(nil, "cpu");
	t1 := sys->millisec();
	if(sp == nil){
		print("speakertest: open: %s\n", err);
		raise "fail:open";
	}
	opentime := t1 - t0;

	held(sp, opentime);
	agrees(sp);
	refuses(sp);
	pcm();
	played();

	if(fail)
		raise "fail:test";
	print("  model load %d ms\n", opentime);
	print("PASS\n");
}

#
# The whole point of the library: a second utterance does not reload the
# model. Speed rather than a fixed number, because "fast" only means anything
# relative to the load it is not paying again - on a slower machine both
# numbers move together.
#
held(sp: ref Speaker, opentime: int)
{
	(ph, e) := phon->text("hello");
	if(e != nil){
		bad("hello is not in the lexicon");
		return;
	}
	(pcm1, e1) := sp.speak(ph);
	if(pcm1 == nil){
		bad(sprint("first speak: %s", e1));
		return;
	}
	if(!energetic(pcm1))
		bad("speaking hello produced no signal");

	t0 := sys->millisec();
	(pcm2, e2) := sp.speak(ph);
	t1 := sys->millisec();
	if(pcm2 == nil){
		bad(sprint("second speak: %s", e2));
		return;
	}
	speaktime := t1 - t0;
	if(speaktime * 4 > opentime)
		bad(sprint("a second utterance took %d ms against %d ms to load the " +
			"model - not clearly cheaper, so the model may be reloading",
			speaktime, opentime));
}

# a tenth of the samples carrying real signal - silence is samples too
energetic(pcm: array of real): int
{
	n := 0;
	for(i := 0; i < len pcm; i++)
		if(pcm[i] > 0.03 || pcm[i] < -0.03)
			n++;
	return n * 10 >= len pcm;
}

#
# feedids() is what speak() itself calls, after building the begin/pad/end
# sequence - say(1)'s id... form calls feedids() directly, to show that
# sequence rather than have speak() build it invisibly. If the two ever
# disagree about what sequence that is, either speak() or feedids() changed
# without the other, which is exactly the regression a refactor like this one
# risks.
#
# Not bit-for-bit, though - a VITS voice is stochastic by design (the noise
# scales are what "how variable" in say(1)'s BUGS means), so identical ids fed
# in twice give audibly similar but numerically different samples every time.
# Bit-equality was tried first here and failed on the first sample by 7e-4,
# which is the model working correctly, not a bug in either function. What
# does not vary between draws is roughly how long the answer is and that it
# has energy, so that is what this checks instead.
#
agrees(sp: ref Speaker)
{
	(ph, e) := phon->text("watch");
	if(e != nil){
		bad("watch is not in the lexicon");
		return;
	}
	(a, ea) := sp.speak(ph);
	if(a == nil){
		bad(sprint("speak: %s", ea));
		return;
	}

	ids := array[2 + 2*len ph + 1] of int;
	n := 0;
	ids[n++] = 1;
	ids[n++] = 0;
	for(i := 0; i < len ph; i++){
		k := sp.lookup(ph[i:i+1]);
		if(k < 0){
			bad(sprint("the voice has no symbol %s", ph[i:i+1]));
			return;
		}
		ids[n++] = k;
		ids[n++] = 0;
	}
	ids[n++] = 2;

	(b, eb) := sp.feedids(ids[0:n]);
	if(b == nil){
		bad(sprint("feedids: %s", eb));
		return;
	}
	if(!energetic(b)){
		bad("feedids() on speak()'s own sequence produced no signal");
		return;
	}
	shorter := len a;
	longer := len b;
	if(shorter > longer)
		(shorter, longer) = (longer, shorter);
	if(shorter * 2 < longer)
		bad(sprint("speak() and feedids() on the same input gave %d and %d " +
			"samples - too different to be the same sequence", len a, len b));
}

# A symbol not in the voice must be refused by name, not silently dropped or
# substituted - the same contract lookup() documents.
refuses(sp: ref Speaker)
{
	(pcm, e) := sp.speak("h☃");
	if(pcm != nil)
		bad("a symbol the voice does not have was accepted rather than refused");
	else if(e == nil)
		bad("a symbol the voice does not have gave neither samples nor an error");
}

#
# pcmbytes(): signed 16-bit little-endian, and clamped rather than wrapped -
# a sample past 1.0 must saturate, not overflow into the opposite sign, which
# is what a plain (int)(x*32767) does with no clamp.
#
pcm()
{
	b := voice->pcmbytes(array[] of {0.0, 0.5, -0.5, 2.0, -2.0});
	if(len b != 10){
		bad(sprint("pcmbytes: %d bytes for 5 samples", len b));
		return;
	}
	if(b[0] != byte 0 || b[1] != byte 0)
		bad("pcmbytes: 0.0 did not encode as 0");
	v := int b[6] | (int b[7] << 8);
	if(v >= 32768)
		v -= 65536;
	if(v != 32767)
		bad(sprint("pcmbytes: 2.0 gave %d, not clamped to 32767", v));
	v = int b[8] | (int b[9] << 8);
	if(v >= 32768)
		v -= 65536;
	if(v != -32768)
		bad(sprint("pcmbytes: -2.0 gave %d, not clamped to -32768", v));
}

#
# play(), to a file rather than the device: no audio hardware is needed to
# check that the bytes it writes are the length pcmbytes() says they should
# be. /dev/audio is what say(1) actually uses; this is the part that does not
# need it.
#
played()
{
	out := "/speakertest.pcm";
	pcm := array[] of {0.0, 0.25, -0.25, 0.5, -0.5};
	if((e := voice->play(pcm, 16000, out)) != nil){
		bad(sprint("play: %s", e));
		return;
	}
	fd := sys->open(out, Sys->OREAD);
	if(fd == nil){
		bad(sprint("play wrote nothing readable: %r"));
		return;
	}
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	sys->remove(out);
	if(n != 2*len pcm)
		bad(sprint("play wrote %d bytes for %d samples, want %d", n, len pcm, 2*len pcm));
}
