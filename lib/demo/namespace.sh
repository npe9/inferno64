# A narrated tutorial on the one idea the rest of Inferno is built out of:
# every process has its own view of the files, and a name can be bound over
# another name.
#
# Same shape as tour.sh - say(1) for the narration, session(2) for the actions.
# It exists to show that a second tutorial is now a thing you write rather than
# a thing you transcribe.

load session
load std

wm/sh &
session wait 1.5

say -t 'every program here has its own view of the files'
session wait 0.4
session type 'ls /'
session key Return
session wait 1.4

say -t 'a name can be bound over another name'
session wait 0.4
session type 'bind /dis /tmp'
session key Return
session wait 0.8
say -t 'and now the same name shows something else'
session wait 0.3
session type 'ls /tmp'
session key Return
session wait 1.6

say -t 'only this window sees that'
session wait 0.5
say -t 'every window can read a file and see a different thing'
session wait 0.6
