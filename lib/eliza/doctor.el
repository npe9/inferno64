# A DOCTOR-style script for wm/eliza - Weizenbaum's own name for the
# psychotherapist persona ELIZA is best remembered running. Not a
# transcription of the 1966 original (no complete copy of that script
# survives publicly); built from the documented technique instead: rank
# whichever keywords are present, decompose the highest-ranked one
# against a handful of patterns, and reflect the matched pieces back
# with pronouns swapped rather than answering anything.

GREETING Hello. I am Eliza. How are you feeling today?

DEFAULT Please tell me more about that.
DEFAULT Go on.
DEFAULT I see. Can you elaborate?
DEFAULT Why do you say that?
DEFAULT How does that make you feel?
DEFAULT What does that suggest to you?

PRE dont do not
PRE cant can not
PRE wont will not
PRE im i am
PRE ive i have
PRE id i would
PRE youre you are
PRE youve you have
PRE whats what is
PRE hows how is

POST am are
POST are am
POST was were
POST were was
POST i you
POST me you
POST my your
POST mine yours
POST myself yourself
POST you i
POST your my
POST yours mine
POST yourself myself

KEY sorry 6
DECOMP *
REASSEMBLE Please do not apologize.
REASSEMBLE Apologies are not necessary.
REASSEMBLE I have told you that apologies are not required.

KEY remember 5
DECOMP * you remember *
REASSEMBLE Do you often think of (2) ?
REASSEMBLE Does thinking of (2) bring anything else to mind ?
DECOMP * i remember *
REASSEMBLE Why do you remember (2) just now ?
REASSEMBLE What in the present situation reminds you of (2) ?
REASSEMBLE What else do you remember ?

KEY dream 4
DECOMP *
REASSEMBLE What does that dream suggest to you ?
REASSEMBLE Do you dream often ?
REASSEMBLE What persons appear in your dreams ?

KEY computer 4
DECOMP *
REASSEMBLE Do computers worry you ?
REASSEMBLE Why do you mention computers ?
REASSEMBLE What do you think machines have to do with your problem ?

KEY mother 4
DECOMP *
REASSEMBLE Tell me more about your mother.
REASSEMBLE What was your relationship with your mother like ?
REASSEMBLE How do you feel about your mother ?

KEY father 4
DECOMP *
REASSEMBLE Tell me more about your father.
REASSEMBLE How did your father make you feel ?
REASSEMBLE Your father seems important to you.

KEY alike 3
DECOMP *
REASSEMBLE In what way ?
REASSEMBLE What resemblance do you see ?

KEY always 3
DECOMP *
REASSEMBLE Can you think of a specific example ?
REASSEMBLE When ?
REASSEMBLE What incident are you thinking of ?

KEY because 3
DECOMP *
REASSEMBLE Is that the real reason ?
REASSEMBLE Do not any other reasons come to mind ?

KEY feel 3
DECOMP * i feel *
REASSEMBLE Tell me more about feeling (2) .
REASSEMBLE Do you often feel (2) ?
REASSEMBLE What makes you feel (2) ?

KEY am 2
DECOMP * i am *
REASSEMBLE Did you come to me because you are (2) ?
REASSEMBLE How long have you been (2) ?
REASSEMBLE Do you believe it is normal to be (2) ?

KEY are 2
DECOMP * you are *
REASSEMBLE What makes you think I am (2) ?
REASSEMBLE Does it please you to believe I am (2) ?

KEY yes 1
DECOMP *
REASSEMBLE You seem quite positive.
REASSEMBLE I see. And how does that make you feel ?

KEY no 1
DECOMP *
REASSEMBLE Are you saying no just to be negative ?
REASSEMBLE Why not ?
REASSEMBLE Are you sure ?

KEY my 1
DECOMP * my *
REASSEMBLE Your (2) ?
REASSEMBLE Tell me more about your (2) .
REASSEMBLE Why do you say your (2) ?
