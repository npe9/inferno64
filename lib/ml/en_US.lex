# A pronunciation lexicon for say(1), in the symbols the voice was trained on.
#
# say(1) takes phonemes, not text, and deliberately: turning English spelling
# into sounds is a different job with a different failure mode, and doing it
# badly inside the synthesizer would make a working synthesizer look broken.
# This is that job, done the only way that can be checked - by looking the word
# up. A word that is not here is an error naming the word, never a guess.
#
# The symbols are espeak's IPA, which is what this voice's phoneme_id_map
# holds; phontest(1) checks every symbol in this file against that map, so a
# typo here is caught rather than synthesized. Note the script g: the voice
# knows U+0261 and not ASCII g, and nothing but that check would have caught it.
#
# WHAT IS AND IS NOT VERIFIED. Fifteen of these words came from strings that
# were already in lib/demo/tour.sh and had been heard: this, is, inferno,
# everything, a, file, even, the, window, system, watch, and, session, being,
# recorded. phontest(1) reproduces those five phrases exactly, so those entries
# and the way words are joined are pinned by a test. Every other entry was
# transcribed by analogy with them and NOTHING HERE VERIFIES HOW IT SOUNDS.
# If a word comes out wrong, it is wrong in this file, and this file is where
# to fix it.
#
# Stress: ˈ before the stressed syllable, ˌ for a secondary stress.

# --- the fifteen that are pinned by tour.sh ---------------------------------
a	ɐ
and	ænd
being	bˌiːɪŋ
even	ˈiːvən
everything	ˈɛvɹiθˌɪŋ
file	fˈaɪl
inferno	ɪnfˈɜːnoʊ
is	ɪz
recorded	ɹɪkˈoːɹdɪd
session	sˈɛʃən
system	sˈɪstəm
the	ðə
this	ðɪs
watch	wˈɑːtʃ
window	wˈɪndoʊ

# --- function words ---------------------------------------------------------
about	ɐbˈaʊt
again	ɐɡˈɛn
all	ˈɔːl
also	ˈɔːlsoʊ
an	ɐn
any	ˈɛni
are	ɑːɹ
as	æz
at	æt
back	bˈæk
be	biː
but	bˈʌt
by	bˈaɪ
can	kæn
each	ˈiːtʃ
every	ˈɛvɹi
for	fɔːɹ
from	fɹʌm
here	hˈɪɹ
how	hˈaʊ
if	ˈɪf
in	ɪn
into	ˈɪntuː
it	ɪt
its	ɪts
itself	ɪtsˈɛlf
just	dʒˈʌst
like	lˈaɪk
more	mˈɔːɹ
no	nˈoʊ
not	nˈɑːt
now	nˈaʊ
of	ʌv
on	ˈɑːn
one	wˈʌn
only	ˈoʊnli
or	ɔːɹ
out	ˈaʊt
over	ˈoʊvɚ
same	sˈeɪm
so	sˈoʊ
some	sˈʌm
than	ðˈæn
that	ðˈæt
them	ðˈɛm
then	ðˈɛn
there	ðɛɹ
these	ðiːz
they	ðeɪ
three	θɹˈiː
to	tuː
two	tˈuː
up	ˈʌp
very	vˈɛɹi
was	wʌz
way	wˈeɪ
we	wiː
what	wˈʌt
when	wˈɛn
which	wˈɪtʃ
why	wˈaɪ
will	wɪl
with	wɪð
you	juː
your	jʊɹ

# --- this system's own words ------------------------------------------------
dis	dˈɪs
kernel	kˈɜːnəl
limbo	lˈɪmboʊ
namespace	nˈeɪmspeɪs
shell	ʃˈɛl
styx	stˈɪks

# --- what a tutorial talks about --------------------------------------------
anything	ˈɛniθˌɪŋ
command	kəmˈænd
commands	kəmˈændz
demo	dˈɛmoʊ
device	dɪvˈaɪs
devices	dɪvˈaɪsɪz
directory	daɪɹˈɛktɚɹi
drive	dɹˈaɪv
drives	dɹˈaɪvz
driving	dɹˈaɪvɪŋ
example	ɪɡzˈæmpəl
files	fˈaɪlz
first	fˈɜːst
hello	həlˈoʊ
keyboard	kˈiːbɔːɹd
last	lˈæst
list	lˈɪst
look	lˈʊk
machine	məʃˈiːn
memory	mˈɛmɚɹi
middle	mˈɪdəl
mouse	mˈaʊs
name	nˈeɪm
names	nˈeɪmz
network	nˈɛtwɜːk
next	nˈɛkst
nothing	nˈʌθɪŋ
open	ˈoʊpən
played	plˈeɪd
process	pɹˈɑːsɛs
processes	pɹˈɑːsɛsɪz
program	pɹˈoʊɡɹæm
programs	pɹˈoʊɡɹæmz
read	ɹˈiːd
record	ɹɪkˈɔːɹd
recording	ɹɪkˈɔːɹdɪŋ
replay	ɹˈiːpleɪ
run	ɹˈʌn
running	ɹˈʌnɪŋ
runs	ɹˈʌnz
screen	skɹˈiːn
script	skɹˈɪpt
scripts	skɹˈɪpts
sessions	sˈɛʃənz
show	ʃˈoʊ
shows	ʃˈoʊz
see	sˈiː
something	sˈʌmθˌɪŋ
sound	sˈaʊnd
speak	spˈiːk
start	stˈɑːɹt
stop	stˈɑːp
take	tˈeɪk
thing	θˈɪŋ
time	tˈaɪm
tutorial	tuːtˈoːɹiəl
type	tˈaɪp
typed	tˈaɪpt
voice	vˈɔɪs
world	wˈɜːld
write	ɹˈaɪt
written	ɹˈɪtən
