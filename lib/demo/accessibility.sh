# A narrated tour of the accessibility stack itself: this system can be
# operated by someone who cannot see the screen, not merely narrated at.
#
# The screen reader is one line - `speak /dev/voice/screen &` - and nothing
# more. Everything it says is voice(3) announcing where the keyboard has
# moved, which libtk and every window manager client write to on their own;
# the reader has no idea what a widget is. This tour turns it on and then
# does the ordinary thing an accessibility demo has to actually do: opens
# windows and moves the keyboard between them, so the same thing a sighted
# person sees happen is heard.
#
# Same shape as tour.sh and namespace.sh - say(1) for the narration,
# session(2) for the actions - with one more voice running underneath:
# speak(1) reading voice(3)'s screen file, concurrently with say(1)'s
# narration rather than instead of it. Both now default to the same
# neural voice(2) model, so the reader and the narrator sound like one
# speaker rather than two - speak(1) falls back to the faster, rougher
# voice(3) formant synthesizer only where it has to. The waits below are
# sized for both to be heard in turn, the same approximate way tour.sh's
# are; neither voice is told to wait for the other.
#
# No quitall at the end, on purpose, matching tour.sh and namespace.sh:
# this hands the session to whoever is listening rather than ending it
# for them - move the keyboard between the two windows and hear them
# announced by name.
#
# A clock or anything else that only takes the pointer is deliberately not
# in this tour: wm only moves the KEYBOARD focus that voice(3) announces,
# and a client that never asks for the keyboard - clock.b calls
# startinput("ptr") and nothing else - is correctly never announced. Two
# shells are used here because a shell is the ordinary case, not because
# anything skips a pointer-only client by accident.

load session
load std
bind -a '#V' /dev

say -t 'this is a tour of the accessibility stack'
session wait 1.0
say -t 'the screen reader is one command'
session wait 0.4
say -t 'speak, slash, dev, slash, voice, slash, screen, and'
session wait 1.2

speak /dev/voice/screen &
session wait 0.3

say -t 'it is listening now'
session wait 0.6
say -t 'the next window will be announced by name as it takes the keyboard'
session wait 1.4

wm/sh &
session wait 2.5

say -t 'a second window'
session wait 0.5
wm/sh &
session wait 2.5

say -t 'both of those were heard by name, without telling the window manager anything new'
session wait 1.8
say -t 'that is the whole idea: a screen reader that already knows everything the window manager and libtk know'
session wait 2.5

say -t 'move between the two windows now, and listen for each one being announced'
