# A narrated tour of Inferno: it speaks, and it drives itself.
#
# Every action below is session(2) - the same verbs a recording decodes into -
# so this file is both the demo and an example of what a recorded session looks
# like when it is written down. Every line of narration is say(1) through
# ml(3), and the words go through the lexicon in phon(2): a word that is not
# there stops the tour and names itself, rather than being guessed at.
#
# This used to be written in the voice's phoneme symbols, with the English in a
# comment beside each line. That is why there was one tour and not several.

load session
load std

# A window for the typing to land in. session(1)'s keystrokes go to
# /dev/keyboard, which reaches whichever window has the focus - so there has to
# BE one. Without this the tour typed into nothing, which is why it was
# committed as a tour that could not yet run.
wm/sh &
session wait 1.5

say -t 'this is inferno'
session wait 0.4
say -t 'everything is a file'
session wait 0.3
say -t 'even the window system'
session wait 0.5

say -t 'here are the devices'
session wait 0.3
session type 'ls /dev'
session key Return
session wait 1.6

say -t 'they are files, so you can read them'
session wait 0.4
session type 'cat /dev/time'
session key Return
session wait 1.4

say -t 'and this session is being recorded'
session wait 0.4
say -t 'a script is driving the shell'
session wait 0.4
session type 'echo hello'
session key Return
session wait 1.2

say -t 'you can stop it in the middle and take over'
session wait 0.6
