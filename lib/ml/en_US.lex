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
# appl was not among the sweep's misses below - the dictionary already had
# an entry - but its answer was espeak's raw, uncorrected guess ("uh-pull",
# rhyming with "pull"), heard in a sentence that used it and corrected here
# to how everyone actually says the top of this tree: like the fruit.
appl	ˈæpəl
dis	dˈɪs
kernel	kˈɜːnəl
limbo	lˈɪmboʊ
namespace	nˈeɪmspeɪs
shell	ʃˈɛl
styx	stˈɪks

# --- appl/cmd and appl/*, swept: every command and directory name in this
# tree, checked against phon(2) by an actual program (wordsweep.b, not kept -
# a one-off list-and-check, not a permanent test) rather than read down the
# list by eye. 270 names in, 60 missing. Two left out here as not worth a
# line: test-only binaries no tutorial is ever going to narrate
# (line3test, progstem_probe), and one compound too specific to be worth
# its own entry (os.purgatorio) - though purgatorio alone is, since Dis's
# own directory names already play the same Dante joke this one does.
#
# Letters, not blended words, for anything that is an acronym with no
# accepted spoken form of its own - cpu, usb, pwd, ml, ndb, mdb and the rest
# of the three-letter Plan9 tool names. Blended real words where usage has
# one - chgrp following chmod/chown's own "ch-" pattern; tclsh as "tickle
# shell", Tcl's own well-known folklore pronunciation, not spelled at all;
# tac as the real word "tack", which is the joke - it is cat spelled
# backwards and reverses cat's output. X2Y names (bit2gif, man2html, raw2iaf)
# read the 2 as "to", the convention it is there to abbreviate.
9660srv	nˈaɪn sˈɪks sˈɪks ˈoʊ sˈɜːv
9export	nˈaɪn ɛkspˈɔːɹt
9srvfs	nˈaɪn sˈɜːv ˈɛf ˈɛs
9win	nˈaɪn wˈɪn
apl	ˈeɪ pˈiː ˈɛl
asm	ˈeɪ ˈɛs ˈɛm
avr	ˈeɪ vˈiː ˈɑːɹ
bit2gif	bˈɪt tə ɡˈɪf
cddb	sˈiː dˈiː dˈiː bˈiː
chgrp	tʃɡɹˈuːp
cmd	sˈiː ˈɛm dˈiː
cmp	sˈiː ˈɛm pˈiː
cpu	sˈiː pˈiː jˈuː
dbfs	dˈiː bˈiː ˈɛf ˈɛs
dbm	dˈiː bˈiː ˈɛm
dd	dˈiː dˈiː
du	dˈiː jˈuː
env	ˈiː ˈɛn vˈiː
fc	ˈɛf sˈiː
fcp	ˈɛf sˈiː pˈiː
fmt	ˈɛf ˈɛm tˈiː
ftpfs	ˈɛf tˈiː pˈiː ˈɛf ˈɛs
gif2bit	ɡˈɪf tə bˈɪt
hd	ˈeɪtʃ dˈiː
lib	lˈɪb
m4	ˈɛm fˈɔːɹ
man2html	mˈæn tə ˌeɪtʃtˌiːˌɛmˈɛl
man2txt	mˈæn tə tˈɛkst
mc	ˈɛm sˈiː
md5sum	ˈɛm dˈiː fˈaɪv sˈʌm
mdb	ˈɛm dˈiː bˈiː
ml	ˈɛm ˈɛl
mpc	ˈɛm pˈiː sˈiː
ndb	ˈɛn dˈiː bˈiː
promptstring	pɹˈɑːmptstɹɪŋ
purgatorio	pˌɜːɡɐtˈɔːɹɪˌoʊ
pwd	pˈiː dˈʌbəl juː dˈiː
raw2iaf	rˈɔː tə ˈaɪ ˈeɪ ˈɛf
rcmd	ˈɑːɹ sˈiː ˈɛm dˈiː
rdp	ˈɑːɹ dˈiː pˈiː
seq	sˈɛk
sha1sum	ˈɛs ˈeɪtʃ ˈeɪ wˈʌn sˈʌm
speakertest	spˈiːkɚ tˈɛst
src	sˈoːɹs
svc	ˈɛs vˈiː sˈiː
tac	tˈæk
tcl	tˈɪkəl
tclsh	tˈɪkəl ʃˈɛl
tcs	tˈiː sˈiː ˈɛs
tkcmd	tˈiː kˈeɪ sˈiː ˈɛm dˈiː
tl	tˈiː ˈɛl
tr	tˈiː ˈɑːɹ
trfs	tˈiː ˈɑːɹ ˈɛf ˈɛs
ttffs	tˈiː tˈiː ˈɛf ˈɛf ˈɛs
unidata	jˈuːnɪdˌeɪɾə
usb	jˈuː ˈɛs bˈiː
wav2iaf	wˈæv tə ˈaɪ ˈeɪ ˈɛf
xd	ˈɛks dˈiː

# --- Unix and Inferno folklore: how these are actually said, not spelled by
# rule. espeak-ng's own guess was the starting point for every line below and
# was wrong for most of them - it tried to pronounce consonant clusters that
# have no vowel (libtk, mkfs), or spelled out letters where usage has settled
# on a blended word instead (chmod as "ch-mod", not "C-H-mod"; fsck as "fisk",
# not spelled at all). Where espeak's answer already matched how people say a
# word - chown, libdraw, libsec, awk - it is used unchanged. Nothing here is
# checked by anyone's ear yet, same caveat as the rest of this file.
awk	ˈɔːk
chmod	tʃmˈɑːd
chown	tʃˈaʊn
fsck	fˈɪsk
ioctl	ˈaɪoʊkəntɹˈoʊl
libdraw	lˈɪbdɹɔː
libmp	lˈɪb ˈɛm pˈiː
libsec	lˈɪbsɛk
libtk	lˈɪb tˈiː kˈeɪ
mk	mˈeɪk
mkdir	mˈeɪkdˌɪɹ
mkfile	mˈeɪkfˈaɪl
mkfs	mˈeɪk ˈɛf ˈɛs
rmdir	ˈɑːɹˈɛmdˌɪɹ

# --- two-letter commands: read as letters, the way nobody reads "ls" as a
# word. Also fd, ctl, ip, tcp, fp - the acronyms phon(2)'s own man page
# names as needing this.
cd	sˌiːdˈiː
cp	sˌiːpˈiː
ctl	sˌiːtˌiːˈɛl
fd	ˌɛfdˈiː
fp	ˌɛfpˈiː
ip	ˌaɪpˈiː
ln	ˌɛlˈɛn
ls	ˌɛlˈɛs
mv	ˌɛmvˈiː
ps	pˌiːˈɛs
rm	ˌɑːɹˈɛm
sh	ˌɛsˈeɪtʃ
tcp	tˌiːsˌiːpˈiː
wc	dˌʌbəljˌuːsˈiː
wm	dˌʌbəljˌuːˈɛm

# --- computer science: broader folklore, not specific to this system or to
# Unix. Same method as the section above - espeak-ng's own guess for the
# whole batch first, kept where it already matches how people say the word
# (linux, cache, daemon, deque, trie, gnu, boolean, ascii, gui, yaml, nginx -
# nginx's own project explains "engine x", which is exactly what espeak
# guessed unprompted), overridden by hand only where it did not.
#
# Three kinds of wrong, worth naming because they recur: spelling out
# letters where usage settled on a blended word (json as "jay-ee-ess-oh-en"
# corrected to "Jason", its own creator's stated pronunciation); the reverse,
# guessing a blended word where usage spells it (nosql blended into one
# invented word, corrected to "no-sequel"); and a consonant cluster with no
# vowel to carry it, which is not a pronunciation at all (argv, argc, stdin/
# stdout/stderr all end or run through one and needed a letter or a word
# spliced in to make them sayable at all).
#
# gif keeps the hard g despite its creator's own stated preference for
# "jif" - not a correction, a choice: usage decides a folklore pronunciation
# and the hard g is what most people actually say. char is genuinely split
# between "char" (this) and "care" among C programmers; there is no settled
# answer to defer to, so this is a choice too, not a fact.
acme	ˈækmi
api	ˌeɪpˌiːˈaɪ
argc	ˈɑːɹɡ sˈiː
argv	ˈɑːɹɡ vˈiː
ascii	ˈæski
boolean	bˈuːliən
cache	kˈæʃ
char	tʃˈɑːɹ
cli	sˌiːˌɛlˈaɪ
cron	kɹˈɑːn
css	sˌiːˌɛsˈɛs
daemon	dˈiːmən
deque	dˈɛk
dns	dˌiːˌɛnˈɛs
emacs	ˈiːmæks
ftp	ˌɛftˌiːpˈiː
gif	ɡˈɪf
gnu	ɡənˈuː
gui	ɡˈuːi
html	ˌeɪtʃtˌiːˌɛmˈɛl
http	ˌeɪtʃtˌiːtˌiːpˈiː
https	ˌeɪtʃtˌiːtˈiːpˌiːˈɛs
json	dʒˈeɪsən
jwt	dʒˈɑːt
kubernetes	kˌuːbɚnˈɛɾiːz
linux	lˈɪnʌks
malloc	mˈælɑːk
mutex	mjˈuːɾɛks
nan	nˈæn
nginx	ˈɛndʒɪn ˌɛks
nosql	nˈoʊsˈiːkwəl
oauth	ˈoʊʌθ
printf	pɹˈɪnt ˈɛf
rc	ˌɑːɹsˈiː
regex	ɹˈɛdʒɛks
rest	ɹˈɛst
soap	sˈoʊp
sql	sˈiːkwəl
ssh	ˌɛsˌɛsˈeɪtʃ
stderr	ˌɛstˌiːdˌiːˈɛɹ
stdin	ˌɛstˌiːdˌiːˈɪn
stdout	ˌɛstˌiːdˌiːˈaʊt
syscall	sˈɪskɔːl
toml	tˈɑːməl
trie	tɹˈaɪ
unicode	jˈuːnɪkˌoʊd
url	jˌuːˈɑːɹˈɛl
utf8	jˌuːtˌiːˈɛf ˈeɪt
uuid	jˌuːjˌuːˌaɪdˈiː
venti	vˈɛnti
vim	vˈɪm
xml	ˌɛksˌɛmˈɛl
yaml	jˈæməl

# --- what a tutorial talks about --------------------------------------------
anything	ˈɛniθˌɪŋ
command	kəmˈænd
commands	kəmˈændz
demo	dˈɛmoʊ
device	dɪvˈaɪs
devices	dɪvˈaɪsɪz
directory	daɪɹˈɛktɚɹi
don't	dˈoʊnt
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

# --- added for lib/demo/namespace.sh -----------------------------------------
another	ɐnˈʌðɚ
bound	bˈaʊnd
different	dˈɪfɹənt
else	ˈɛls
has	hˈæz
own	ˈoʊn
sees	sˈiːz
view	vjˈuː

# --- added for lib/demo/unix-for-poets.sh ------------------------------------
bigrams	bˈaɪɡɹæmz
line	lˈaɪn
lowercase	lˈoʊɚkˌeɪs
talks	tˈɔːks
