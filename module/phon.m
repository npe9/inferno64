#
# English words, in the sounds a voice model was trained on.
#
# say(1) takes phonemes rather than text, and that is the right split: turning
# spelling into sounds is a separate job with its own failure mode, and doing
# it badly inside the synthesizer would make a working synthesizer look broken.
# This is that job.
#
# It is a lookup and nothing else. There are no letter-to-sound rules here, on
# purpose: English spelling does not reduce to rules, a rule set that is right
# four times in five gives a narrator that is wrong every fifth word, and
# nothing in this system can hear that it happened. A word that is not in the
# lexicon is an error naming the word, which someone can fix by adding a line.
# Guessing would be the only alternative and it is a worse one.
#
Phon: module
{
	PATH:	con "/dis/lib/phon.dis";

	# The hand-written lexicon, read into memory. Small, and it WINS over the
	# dictionary: espeak gives "a" as the letter, ˈeɪ, where an article is
	# almost always meant.
	LEX:	con "/lib/ml/en_US.lex";

	# The generated dictionary - a quarter of a million words, sorted, and
	# binary-searched on disk rather than read in. It costs no memory and no
	# load time, which is what makes it usable on a small machine and what
	# makes a lookup fast enough to read a screen with.
	DICT:	con "/lib/ml/en_US.dict";

	# Read the hand-written lexicon and open the dictionary. Returns nil, or
	# why it could not. A missing dictionary is not an error - the lexicon
	# alone still works, and says so through dictwords().
	init:	fn(path: string): string;

	# One word, already stripped of punctuation and case. Returns the
	# sounds, or nil and the word that is not known.
	word:	fn(w: string): (string, string);

	# A line of English. Punctuation the voice knows is kept, because it is
	# part of how a line is said and not decoration; anything else is
	# dropped. Returns the sounds, or nil and the first word not known.
	text:	fn(s: string): (string, string);

	# Every word in the hand-written lexicon, sorted. For a test that wants
	# to check the symbols without knowing what is in the file.
	words:	fn(): list of string;

	# How many words the dictionary holds, or 0 if there is none. Only so a
	# test can tell "no dictionary" from "a dictionary that finds nothing".
	dictwords: fn(): int;
};
