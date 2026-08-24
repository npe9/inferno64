implement Command;

#
# Speak, through ml(3) - via voice(2), which is where the model-loading and
# per-utterance protocol actually live now. This is the front end: argument
# parsing, phon(2) for English, and playing what comes back.
#
# The voice is a VITS model - phoneme numbers in, a waveform out, with no
# vocoder or formant synthesis in between. That is the whole reason for
# putting it behind ml(3) rather than building a synthesizer: the interesting
# part is a trained network, and the device already runs those.
#
# It takes phoneme ids rather than text. Turning text into phonemes is a
# different job with a different failure mode - English spelling - and doing
# it badly here would make a working synthesizer look broken. A front end
# belongs on top of this, not inside it.
#
# It runs on the processor, not the neural engine, and that is deliberate:
# above about forty phonemes onnxruntime's CoreML provider faults inside
# Apple's BNNS convolution and takes the model server with it. That was
# measured outside Inferno entirely - the same five utterances through a
# fifteen-line driver, three of five dead on CoreML and five of five good on
# the processor - so it is not this system's bug to fix. -u all asks for the
# accelerator anyway, and short utterances do work there.
#
#	say -t 'hello'			# English, through the lexicon in phon(2)
#	say -p "h@l'oU"			# the same thing, in the voice's own symbols
#	say 1 0 20 0 59 0 24 0 120 0 27 0 100 0 2
#	say -t 'hello' -t 'goodbye'	# one model load, two utterances
#
# -t is the front end that belongs on top rather than inside: phon(2) looks
# each word up in a lexicon and refuses a word it does not have, naming it,
# rather than guessing at English spelling. -p is still there for a sound the
# lexicon cannot spell. Either can be given more than once, and in any order
# relative to the other - each repeat is another utterance, spoken in the
# order given, through the same model load. That is the whole reason
# voice(2) holds the model open rather than say(1) loading it once for
# itself: a script with several lines to say should not pay for the model
# again for each one.
#
# The model wants its ids interleaved with the pad symbol and wrapped in
# begin and end, which is the sequence in the third example above - that is
# the one form with no front end at all, for seeing the model's raw input
# rather than trusting speak() to build it correctly.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "arg.m";
include "phon.m";
	phon: Phon;
include "voice.m";
	voice: Voice;
	Speaker: import voice;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

fatal(s: string)
{
	fprint(sys->fildes(2), "say: %s\n", s);
	raise "fail:error";
}

# one utterance as given on the command line, in the order given
Utter: adt
{
	iseng:	int;		# text through phon(2), or phonemes already
	s:	string;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	voice = load Voice Voice->PATH;
	if(arg == nil || voice == nil)
		fatal(sprint("load: %r"));
	if((e := voice->init()) != nil)
		fatal(e);

	model := "";
	units := "cpu";
	out := "/dev/audio";
	showinfo := 0;
	lexicon := "";
	dryrun := 0;
	utters: list of ref Utter;
	arg->init(argv);
	arg->setusage("say [-v voice] [-u units] [-o file] [-i] [-n] [-l lexicon] " +
		"-t text | -p phonemes | id...");
	while((o := arg->opt()) != 0)
		case o {
		'u' =>	units = arg->earg();
		'v' =>	model = arg->earg();
		'o' =>	out = arg->earg();
		'i' =>	showinfo++;
		'p' =>	utters = ref Utter(0, arg->earg()) :: utters;
		't' =>	utters = ref Utter(1, arg->earg()) :: utters;
		'n' =>	dryrun++;
		'l' =>	lexicon = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	utters = rev(utters);

	if(utters == nil && argv == nil)
		arg->usage();

	if(utters != nil)
		for(needphon := utters; needphon != nil; needphon = tl needphon)
			if((hd needphon).iseng){
				phon = load Phon Phon->PATH;
				if(phon == nil)
					fatal(sprint("load phon: %r"));
				if((pe := phon->init(lexicon)) != nil)
					fatal(pe);
				break;
			}

	# -n stops here: the sounds are what a tutorial author wants to see,
	# and printing them costs nothing next to loading sixty megabytes of
	# model. The raw id... form has no sounds to print - it already is
	# the model's own numbers - so -n says nothing for it.
	if(dryrun){
		for(dl := utters; dl != nil; dl = tl dl){
			u := hd dl;
			ph := u.s;
			if(u.iseng){
				(p, err) := phon->text(u.s);
				if(err != nil)
					fatal(sprint("%s is not in the lexicon; add it to %s",
						err, lexname(lexicon)));
				ph = p;
			}
			print("%s\n", ph);
		}
		return;
	}

	(sp, err) := voice->open(model, units);
	if(sp == nil)
		fatal(err);

	if(showinfo){
		ifd := sys->open(sp.dir + "/info", Sys->OREAD);
		ib := array[8192] of byte;
		n: int;
		if(ifd != nil && (n = sys->read(ifd, ib, len ib)) > 0)
			print("%s", string ib[0:n]);
	}

	if(utters == nil){
		# the lowest-level form: ids typed by hand, wrapped in nothing
		ids := array[len argv] of int;
		for(i := 0; argv != nil; (i, argv) = (i+1, tl argv))
			ids[i] = int hd argv;
		(pcm, ie) := sp.feedids(ids);
		if(pcm == nil)
			fatal(ie);
		report(pcm);
		if((ie = voice->play(pcm, Voice->RATE, out)) != nil)
			fatal(ie);
		return;
	}

	for(sl := utters; sl != nil; sl = tl sl){
		u := hd sl;
		ph := u.s;
		if(u.iseng){
			(p, perr) := phon->text(u.s);
			if(perr != nil)
				fatal(sprint("%s is not in the lexicon; add it to %s",
					perr, lexname(lexicon)));
			ph = p;
		}
		(pcm, se) := sp.speak(ph);
		if(pcm == nil)
			fatal(se);
		report(pcm);
		if((se = voice->play(pcm, Voice->RATE, out)) != nil)
			fatal(se);
	}
}

report(pcm: array of real)
{
	print("say: %d samples, %g seconds at %d Hz\n",
		len pcm, real len pcm / real Voice->RATE, Voice->RATE);
}

lexname(lexicon: string): string
{
	if(lexicon == "")
		return Phon->LEX;
	return lexicon;
}

rev(l: list of ref Utter): list of ref Utter
{
	r: list of ref Utter;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
