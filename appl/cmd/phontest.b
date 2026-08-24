implement Command;

#
# Tests phon(2), the lexicon say(1) reads to turn English into sounds.
#
# The hard part of testing a pronunciation lexicon is that nothing in this
# system can hear it. A wrong entry produces a word that is said wrong, and
# every structural check still passes. So this does not claim to test that the
# lexicon sounds right - it cannot - and says so in BUGS. What it does test is
# the two things that can be established:
#
# The five phrases in lib/demo/tour.sh were written by hand in the voice's own
# symbols and had been listened to before any of this existed. Phonemising the
# English of those phrases must give back exactly those strings. That pins the
# fifteen words they use AND the way words are joined, which is the part a
# change to this library would break silently.
#
# And every symbol of every entry must be one the voice was trained on. That
# catches the whole class of typo the file is prone to - notably the script g,
# U+0261, which is what the voice knows; an ASCII g looks identical in most
# fonts and is not in the model at all.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "json.m";
	json: JSON;
	JValue: import json;
include "phon.m";
	phon: Phon;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Voice:	con "/lib/ml/voices/en_US-lessac-low.onnx.json";
Tour:	con "/lib/demo/tour.sh";

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	phon = load Phon Phon->PATH;
	if(bufio == nil || json == nil || phon == nil){
		print("phontest: load: %r\n");
		raise "fail:load";
	}
	json->init(bufio);

	if((e := phon->init(nil)) != nil){
		print("phontest: %s\n", e);
		raise "fail:lexicon";
	}

	pinned();
	symbols();
	refuses();
	shape();
	covers(Tour);

	if(fail)
		raise "fail:test";
	n := 0;
	for(l := phon->words(); l != nil; l = tl l)
		n++;
	print("  %d words in the lexicon, every symbol known to the voice\n", n);
	print("PASS\n");
}

#
# The five phrases from lib/demo/tour.sh, which were hand-written in the
# voice's symbols and heard before phon(2) existed. These are the only entries
# in the lexicon that anything has ever verified by ear.
#
pinned()
{
	cases := array[] of {
		("this is inferno", "ðɪs ɪz ɪnfˈɜːnoʊ"),
		("everything is a file", "ˈɛvɹiθˌɪŋ ɪz ɐ fˈaɪl"),
		("even the window system", "ˈiːvən ðə wˈɪndoʊ sˈɪstəm"),
		("watch", "wˈɑːtʃ"),
		("and this session is being recorded",
			"ænd ðɪs sˈɛʃən ɪz bˌiːɪŋ ɹɪkˈoːɹdɪd"),
	};
	for(i := 0; i < len cases; i++){
		(eng, want) := cases[i];
		(got, err) := phon->text(eng);
		if(err != nil)
			bad(sprint("%#q: %s is not in the lexicon", eng, err));
		else if(got != want)
			bad(sprint("%#q\n        gave %s\n        want %s", eng, got, want));
	}
}

#
# Every symbol of every entry has to be one the model was trained on. A symbol
# it does not know cannot be turned into an id at all, so this is the check
# that turns a typo into a test failure instead of an error at synthesis - or
# worse, a silently dropped sound.
#
symbols()
{
	b := bufio->open(Voice, Bufio->OREAD);
	if(b == nil){
		bad(sprint("%s: %r", Voice));
		return;
	}
	(v, err) := json->readjson(b);
	if(v == nil){
		bad(sprint("%s: %s", Voice, err));
		return;
	}
	m := v.get("phoneme_id_map");
	if(m == nil){
		bad(Voice + " has no phoneme_id_map");
		return;
	}
	nbad := 0;
	for(l := phon->words(); l != nil; l = tl l){
		w := hd l;
		(ipa, e) := phon->word(w);
		if(e != nil){
			bad(sprint("%s is listed by words() but word() does not have it", w));
			continue;
		}
		for(i := 0; i < len ipa; i++){
			if(m.get(ipa[i:i+1]) == nil){
				if(nbad++ < 8)
					bad(sprint("%s: the voice has no symbol %s",
						w, ipa[i:i+1]));
			}
		}
	}
	if(nbad >= 8)
		bad(sprint("... and %d more unknown symbols", nbad - 8));
}

#
# A word that is not there must be refused by name. This is the whole design -
# the alternative is guessing, and a guess is wrong silently - so it gets a
# test rather than being left to the comment that claims it.
#
refuses()
{
	(ipa, err) := phon->text("this is a zzzqx");
	if(err == nil)
		bad(sprint("a word that is not in the lexicon gave %#q instead of an error", ipa));
	else if(err != "zzzqx")
		bad(sprint("the error named %#q rather than the word that is missing", err));

	# and it must be the FIRST missing word, so an author fixes them in order
	(nil, err2) := phon->text("zzzqx and qqxxz");
	if(err2 != "zzzqx")
		bad(sprint("with two words missing the error named %#q, not the first", err2));
}

#
# Every word the tour narrates has to be in the lexicon.
#
# Without this the tour still fails on a missing word - say(1) refuses it by
# name - but it fails part way through, after some of the narration has already
# been spoken, which is a poor way to find out. Checking the script here means a
# tutorial is known to be sayable before anyone runs it.
#
covers(path: string)
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil){
		bad(sprint("%s: %r", path));
		return;
	}
	n := 0;
	while((l := b.gets('\n')) != nil){
		if(len l > 0 && l[len l - 1] == '\n')
			l = l[0:len l - 1];
		# say -t 'some words'
		if(len l < 8 || l[0:8] != "say -t '")
			continue;
		e := len l - 1;
		while(e > 8 && l[e] != '\'')
			e--;
		if(e <= 8)
			continue;
		n++;
		(nil, err) := phon->text(l[8:e]);
		if(err != nil)
			bad(sprint("%s narrates %#q, which is not in the lexicon", path, err));
	}
	b = nil;
	if(n == 0)
		bad(sprint("%s has no narration lines; this check tested nothing", path));
}

#
# Case, punctuation and spacing. Punctuation the voice knows is kept because it
# is how a line is paced; anything else in a word is dropped rather than sent
# to a model that has never seen it.
#
shape()
{
	(a, ea) := phon->text("Watch");
	(b, eb) := phon->text("watch");
	if(ea != nil || eb != nil)
		bad("watch is not in the lexicon");
	else if(a != b)
		bad(sprint("case changed the sounds: %#q against %#q", a, b));

	(c, ec) := phon->text("watch, watch.");
	if(ec != nil)
		bad(sprint("punctuation made %s unknown", ec));
	else if(c != "wˈɑːtʃ, wˈɑːtʃ.")
		bad(sprint("punctuation is not kept: %#q", c));

	# extra spacing must not reach the sounds
	(d, ed) := phon->text("   watch    watch   ");
	if(ed != nil || d != "wˈɑːtʃ wˈɑːtʃ")
		bad(sprint("spacing reached the sounds: %#q", d));
}
