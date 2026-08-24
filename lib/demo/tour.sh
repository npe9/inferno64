# A narrated tour of Inferno: it speaks, and it drives itself.
#
# Every action below is session(2) - the same verbs a recording decodes
# into - so this file is both the demo and an example of what a recorded
# session looks like when it is written down. Every line of narration is
# say(1) through ml(3), on the voice's own phoneme symbols.

load session

say -p 'ðɪs ɪz ɪnfˈɜːnoʊ'	# this is inferno
session wait 0.4
say -p 'ˈɛvɹiθˌɪŋ ɪz ɐ fˈaɪl'	# everything is a file
session wait 0.3
say -p 'ˈiːvən ðə wˈɪndoʊ sˈɪstəm'	# even the window system
session wait 0.5
say -p 'wˈɑːtʃ'	# watch
session wait 0.6

session type 'ls /dev'
session key Return
session wait 1.6

say -p 'ænd ðɪs sˈɛʃən ɪz bˌiːɪŋ ɹɪkˈoːɹdɪd'	# and this session is being recorded
session wait 0.4
session type 'echo hello'
session key Return
session wait 1.2
