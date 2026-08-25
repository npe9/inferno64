# A narrated run through Kenneth Church's "Unix for Poets" (AT&T Bell Labs) -
# the classic tutorial that treats a body of running text as data and reads
# it with the small tools that were already lying around: tr, sort, uniq,
# grep, sed. The corpus is his own: the Book of Genesis, King James Version,
# public domain, fetched from Project Gutenberg's plain-text edition and
# reflowed to one verse per line at lib/demo/genesis.txt.
#
# Same shape as tour.sh, namespace.sh and accessibility.sh - say(1) for the
# narration, session(2) for the actions, typed into a real wm/sh window
# rather than run invisibly, so what is heard is also what is seen landing
# in the window and scrolling past.
#
# tr, sort, uniq, grep, sed, wc, comm and tail already existed in this tree.
# rev and paste did not - the tutorial's rhyming sort and bigram exercises
# need them - so both were written for this (see man/1/rev, man/1/paste),
# and uniq gained the -c this tutorial's most famous line depends on
# (man/1/uniq). None of this tree's tools take GNU-style long options or
# combined flags beyond what their own man pages document; check those
# before changing a line below.
#
# What this does NOT reproduce: this tree has no awk, and roughly the back
# half of the talk - field selection, associative arrays, the KWIC and
# concordance programs - is built entirely on awk. Writing an awk of its own
# was judged a separate, much larger project than demoing the actions of
# this one, so those exercises are simply not attempted here. Everything
# through the bigram exercise, which is most of what the talk is remembered
# for, is run for real below, on the real text, through this tree's own
# tools - not paraphrased.
#
# Quoting note: this is rc-style quoting, not the outer shell's - only
# single quotes are special, and a literal single quote inside a quoted
# word is written as a doubled pair (''). Every session type below that
# needs an embedded quote (tr's '\012', sed's 's/.../.../' scripts) is
# built that way, as one quoted word, not by switching to double quotes,
# which this shell does not treat as quoting at all.

load session
load std

wm/sh &
session wait 1.5

say -t 'unix for poets, a tutorial by kenneth church at bell labs'
session wait 0.4
say -t 'the same idea it always was: treat text as data, and read it with small tools'
session wait 0.6
say -t 'the text is genesis, the same corpus his own tutorial used'
session wait 1.6

say -t 'twelve hundred verses'
session wait 0.3
session type 'wc -l /lib/demo/genesis.txt'
session key Return
session wait 1.6

say -t 'tr turns it into one word per line'
session wait 0.4
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt | sed -e 5q'
session key Return
session wait 2.2

say -t 'the first line is empty, because every verse starts with a chapter and verse number, and a number is not a letter'
session wait 2.2

say -t 'now count them: tokenize, sort, count, sort again by count'
session wait 0.6
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt | sort | uniq -c | sort -nr | sed -e 5q'
session key Return
session wait 2.6

say -t 'and, the, of, and then capital A n d, a different word to this pipeline than lowercase and'
session wait 2.4
say -t 'that is the first lesson: a computer counts characters, not words, unless you tell it what a word is'
session wait 2.4

say -t 'the same words, in dictionary order instead of by count'
session wait 0.5
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt | sort | uniq | sed -e 5q'
session key Return
session wait 2.4

say -t 'now a favorite trick from the talk: sorting by the end of a word instead of the start'
session wait 0.5
say -t 'reverse every word, sort, reverse back'
session wait 1.0
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt | sort | uniq | rev | sort | rev | sed -e 5q'
session key Return
session wait 2.4

say -t 'grep finds words by pattern: everything ending in i n g'
session wait 0.5
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt | sort | uniq | grep ''ing$'' | sed -e 5q'
session key Return
session wait 2.2

say -t 'sed edits a stream as it goes past'
session wait 0.5
session type 'sed -e ''s/God/Elohim/g'' /lib/demo/genesis.txt | sed -e 1q'
session key Return
session wait 2.2

say -t 'and sed can stop a stream on a pattern, not just a line count'
session wait 0.5
session type 'sed -e ''/Noah/q'' /lib/demo/genesis.txt | wc -l'
session key Return
session wait 2.0
say -t 'that many verses pass before noah is even named'
session wait 1.8

say -t 'last one: bigrams, which word follows which'
session wait 0.6
say -t 'paste the word list against itself, shifted by one line'
session wait 1.4
session type 'tr -cs A-Za-z ''\012'' < /lib/demo/genesis.txt > /tmp/uop-words'
session key Return
session wait 1.2
session type 'tail +2 /tmp/uop-words > /tmp/uop-next'
session key Return
session wait 1.2
session type 'paste /tmp/uop-words /tmp/uop-next | sort | uniq -c | sort -nr | sed -e 5q'
session key Return
session wait 2.6

say -t 'of the, in the, and he, and the, said unto'
session wait 2.0
say -t 'said unto is not an accident of english, it is how genesis actually talks'
session wait 2.2

say -t 'that is unix for poets: tokenize, sort, count, and look at what comes out'
session wait 1.8
say -t 'this tree has no awk yet, so the field selection and the concordance program from the second half of the talk are not run here'
session wait 2.4
say -t 'everything above this line ran on the real text, through real commands, not paraphrased'
