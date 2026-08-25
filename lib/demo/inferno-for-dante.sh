# A companion to lib/demo/unix-for-poets.sh, built around the question it
# left open: what would the Inferno-native version of that talk actually
# be? Plan 9 never had an awk - a deliberate choice, not a gap - and this
# tree, until unix-for-poets.sh, matched that exactly: small tools
# (tr/sort/uniq/grep/sed) for the pipeline case, Limbo for anything more.
# That demo still leaned on those small tools, all of them transliterated
# from Plan 9's own. This one uses NONE of them - no tr, sort, uniq, grep,
# sed, paste, rev, comm, wc anywhere below - only what is actually native
# to this shell and this language:
#
#   - sh(2)'s own loadable `regex` module (man/1/sh-regex): `match` and
#     `${re g/v/m/mg/s/sg ...}` are grep and sed, as shell builtins, no
#     process spawned per line.
#   - `getlines` (man/1/sh-std), the shell's own line-at-a-time loop -
#     the native replacement for piping through a filter.
#   - `load expr` (man/1/sh-expr) for the arithmetic none of the above
#     needed until a line count did.
#   - wordfreq(1), one new small Limbo program, for the one thing that
#     genuinely needs a real program rather than a shell one-liner:
#     tokenizing, counting and sorting a whole corpus. It is the
#     tokenize | sort | uniq -c | sort -nr pipeline as a single tool -
#     "the Limbo program instead of the awk one-liner," written for real
#     rather than just claimed.
#
# The corpus is the obvious one: Dante's Inferno, Longfellow's 1867
# translation (public domain, Project Gutenberg), at
# lib/demo/dante-inferno.txt. Worth saying plainly, since the talk almost
# claims otherwise: Longfellow kept Dante's three-line stanzas but not his
# rhyme - he translated line by line for the meaning, and did not go
# looking for English rhymes to match terza rima's. The tercet STRUCTURE
# below is real; a rhyme scheme in this particular English is not, and
# this script says so rather than pretending otherwise.
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
say -t 'plan nine never had an awk either, on purpose: small tools for the pipeline case, a real language for anything more'
session wait 1.6
say -t 'this is what that actually looks like: the shells own pattern matching, and one small limbo program'
session wait 1.8

session type 'load std; load expr; n := 0; < /lib/demo/dante-inferno.txt getlines {n = ${expr $n 1 +}}; echo $n lines'
session key Return
session wait 1.8
say -t 'that count came from the shells own loop, nothing piped through w c'
session wait 1.8

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

say -t 'now grep, without grep: load the regex module, and match tests a line directly'
session wait 1.0
session type 'load regex; < /lib/demo/dante-inferno.txt getlines {if {match Beatrice $line} {echo $line}}'
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

say -t 'last one: the first three tercets, and each lines last word'
session wait 1.0
session type 'load expr; n := 0; < /lib/demo/dante-inferno.txt getlines {n = ${expr $n 1 +}; tail := ${re m ''[A-Za-z]+[^A-Za-z]*$'' $line}; last := ${re sg ''[^A-Za-z]+$'' '''' $tail}; echo $n : $last; if {~ $n 9} {raise break}}'
session key Return
session wait 2.8
say -t 'life, dark, lost: dantes own terza rima linked those in italian, but longfellow was not chasing rhyme'
session wait 2.4
say -t 'the three line shape survived the translation. the rhyme did not, and this talk is not going to pretend it did'
session wait 2.4

say -t 'that is the inferno answer to unix for poets: the shells own regex and getlines instead of grep and sed, and one real program instead of an invented mini language for counting'
session wait 2.8
say -t 'no awk was written for this, and none was missing either'
