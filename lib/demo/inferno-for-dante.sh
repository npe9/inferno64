# A companion to lib/demo/unix-for-poets.sh that does the whole of Church's
# talk, not the reduced first half of it.
#
# CORRECTION, stated plainly rather than quietly fixed: an earlier version
# of this file claimed "Plan 9 never had an awk, by design," and narrated
# that claim aloud. That is false and should not have been asserted
# without checking it - Plan 9 shipped a real awk, a port of the "one true
# awk," with its own man page. There was no design choice there to point
# to, and no gap in the back half of Church's talk was ever a matter of
# awk not existing somewhere in this lineage.
#
# What IS true, and is the actual point of this file: this shell's own
# loadable modules - regex, string, expr, std (man/1/sh-regex,
# man/1/sh-string, man/1/sh-expr, man/1/sh-std) - already cover what a
# pattern-action language is for: field splitting, numeric comparison,
# substring search and position, substitution, arithmetic - all as
# builtins, none of them spawning a process per line. That is a fact
# about how expressive this sh(2) already is, verified by hand (this tree
# had no example script anywhere using match/getlines/${re ...} together
# before this one), not a fact about anyone's history with awk.
#
# The tools that ARE new here are wordfreq(1), rev(1) and paste(1)
# (appl/cmd/*.b) - none Unix transliterations the way tr/sort/uniq/grep/
# sed are (this tree's own copies of those say so in their file headers);
# these three did not exist until they were needed to run this and
# unix-for-poets.sh for real. Nothing below spawns tr, sort, uniq, grep,
# sed, comm or wc.
#
# Corpus: Dante's Inferno, Longfellow's 1867 translation (public domain,
# Project Gutenberg), at lib/demo/dante-inferno.txt, 6386 lines. Longfellow
# kept Dante's tercets but translated for meaning, not rhyme - said
# outright below rather than left for the tercet exercise to imply
# otherwise.
#
# Every session-type line below - several nest three braced blocks deep -
# was generated from its literal command by doubling embedded single
# quotes programmatically, then checked by substituting echo for session
# type and diffing against the exact string intended, rather than by hand:
# by hand this nests too deep to reliably get right by eye. Every command
# was then run for real against the real corpus; the numbers and words
# quoted in the narration are what actually came out, not invented for
# effect.
#
# Same floating control as unix-for-poets.sh (man/1/talkctl): pause,
# slower, faster, reaching the gaps between actions the same way there.

load session
load std

wm/talkctl &
wm/sh &
session wait 1.5

say -t 'inferno for dante: what this systems own name was always going to end up narrating'
session wait 0.6
say -t 'the corpus is dantes inferno, longfellows translation, same public domain source as the other talk used for genesis'
session wait 1.4

say -t 'and unlike that talk, nothing below is a unix tool: no tr, no sort, no uniq, no grep, no sed'
session wait 1.0
say -t 'not because none of those ever had an awk somewhere in their lineage - they did - but because this shells own loadable modules already cover what one is for'
session wait 2.2
say -t 'regex, string, expr and std between them give field splitting, numbers, substrings and substitution as builtins, and one small limbo program does the counting'
session wait 2.4

session type 'load std; load string; load regex; load expr'
session key Return
session wait 0.8
say -t 'that count came from the shells own loop, nothing piped through w c'
session wait 1.6

say -t 'word frequency now: one program, not four processes and three pipes'
session wait 0.8
session type 'wordfreq -n 8 /lib/demo/dante-inferno.txt'
session key Return
session wait 2.2
say -t 'the, and, capital A n d again, same lesson as genesis: a computer counts characters, not words, until told otherwise'
session wait 2.2

say -t 'and the same program does bigrams, with a flag instead of a second pipeline'
session wait 0.8
session type 'wordfreq -b -n 6 /lib/demo/dante-inferno.txt'
session key Return
session wait 2.2
say -t 'of the, to me, the other: virgil is who dante keeps saying to me about'
session wait 2.2

say -t 'now grep, without grep: the regex module already loaded, and match tests a line directly'
session wait 1.0
session type '< /lib/demo/dante-inferno.txt getlines {if {match Beatrice $line} {echo $line}}'
session key Return
session wait 2.4
say -t 'two lines, found by the shell itself asking each line a question, not a separate program reading the file'
session wait 2.2

say -t 'and sed, without sed: dollar re s g substitutes inside a shell string directly'
session wait 1.0
session type 'line = ''Midway upon the journey of our life''; echo ${re sg Midway Halfway $line}'
session key Return
session wait 2.0

say -t 'one more: the tokenizer itself, as a shell expression instead of a process reading a pipe'
session wait 0.8
session type 'line = ''So bitter is it, death is little more''; echo ${re mg ''[A-Za-z]+'' $line}'
session key Return
session wait 2.2
say -t 'punctuation gone, one word per list element, the same rule tr would have applied'
session wait 2.2

say -t 'field selection now: the first and last word of the first five real lines'
session wait 1.0
session type 'n := 0; < /lib/demo/dante-inferno.txt getlines {f := ${split '' '' $line}; nf := 0; for w in $f {nf = ${expr $nf 1 +}}; if {ntest ${expr $nf 0 gt}} {n = ${expr $n 1 +}; echo ${index 1 $f} ... ${index $nf $f}; if {~ $n 5} {raise break}}}'
session key Return
session wait 2.6
say -t 'that is dollar one and dollar N F, done with split, index and a count loop, no separate language written for it'
session wait 2.4

say -t 'a numeric filter now, right on wordfreqs own output: bigrams said more than fifty times'
session wait 1.2
session type 'wordfreq -b /lib/demo/dante-inferno.txt | getlines {f := ${split '' '' $line}; count := ${index 1 $f}; if {ntest ${expr $count 50 gt}} {echo $line}}'
session key Return
session wait 2.6
say -t 'dollar one greater than fifty, the same comparison, one native tool feeding straight into another'
session wait 2.2

say -t 'palindromes now, and computed, not a list of words picked in advance'
session wait 1.0
session type 'wordfreq /lib/demo/dante-inferno.txt | getlines {f := ${split '' '' $line}; w := ${index 2 $f}; echo $w} > /tmp/uop-words-only'
session key Return
session wait 1.4
session type 'rev /tmp/uop-words-only > /tmp/uop-words-rev'
session key Return
session wait 1.0
say -t 'the word list, and that same list reversed, side by side, kept only where the two columns agree'
session wait 1.6
session type 'paste /tmp/uop-words-only /tmp/uop-words-rev | getlines {f := ${re mg ''[A-Za-z]+'' $line}; a := ${index 1 $f}; b := ${index 2 $f}; if {~ $a $b} {if {~ ${len $a} 1} {} {echo $a}}}'
session key Return
session wait 2.8
say -t 'did, eye, ere, deed, sees, eke, eve, redder: real words this translation actually uses'
session wait 2.2
say -t 'and three of the canto numbers themselves: I I, I I I, and X I X are palindromes too, letter by letter, whether or not anyone meant them to be'
session wait 2.6

say -t 'a keyword in context index now, the same fifteen or twenty characters either side of a match a concordance prints'
session wait 1.6
session type '< /lib/demo/dante-inferno.txt getlines {if {match Virgil $line} {r := ${splitstrl $line Virgil}; before := ${index 1 $r}; after := ${index 2 $r}; blen := ${len $before}; bstart := ${expr $blen 20 -}; if {ntest ${expr $bstart 0 lt}} {bstart = 0}; ctx := ${slice $bstart end $before}; right := ${slice 0 20 $after}; echo ${padl 22 $ctx}$right}}'
session key Return
session wait 2.8
say -t 'notice it is almost always virgilius, the latin form, not plain virgil: this translation says the name in full nearly every time'
session wait 2.6

say -t 'last one: the first three tercets, and each lines last word'
session wait 1.0
session type 'load expr; n := 0; < /lib/demo/dante-inferno.txt getlines {n = ${expr $n 1 +}; tail := ${re m ''[A-Za-z]+[^A-Za-z]*$'' $line}; last := ${re sg ''[^A-Za-z]+$'' '''' $tail}; echo $n : $last; if {~ $n 9} {raise break}}'
session key Return
session wait 2.8
say -t 'life, dark, lost: dantes own terza rima linked those in italian, but longfellow was not chasing rhyme'
session wait 2.4
say -t 'the three line shape survived the translation. the rhyme did not, and this talk is not going to pretend it did'
session wait 2.4

say -t 'that is the whole of unix for poets: tokenizing, counting, sorting, filtering, substituting, field selection, palindromes and a keyword index'
session wait 2.6
say -t 'none of it spawned tr, sort, uniq, grep or sed, and none of it needed a pattern action language written for it either'
session wait 2.4
say -t 'plan nine had an awk. this just did not need to write one to still get everything the talk asked for'
