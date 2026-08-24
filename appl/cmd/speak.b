implement Command;

#
# Read something out.
#
#	ls /dev | speak
#	speak /tmp/notes
#	speak -t 'the disk is full'
#
# say(1) speaks one utterance and exits, having loaded sixty megabytes of model
# to do it. That is right for narration and useless for reading: nothing can be
# piped into it, and a second and a half per line is not reading, it is waiting.
#
# This goes through voice(3), which synthesizes natively and answers in less
# time than it takes to say the words. It reads a line at a time and does not
# start the next until the last has been heard, so a pipe paces itself: `ls /dev
# | speak` reads the list out at speaking speed rather than queueing all of it
# at once and talking over itself.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "phon.m";
	phon: Phon;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Rate:	con 16000;		# voice(3) says so on its ctl file

stderr:	ref Sys->FD;
quiet:	int;
dryrun:	int;
watching: int;		# reading voice(3)'s screen file, so interruptible
vctl:	ref Sys->FD;	# held open to ask how many announcements are waiting

Chunk:	con 3200;	# a tenth of a second at 16kHz, 16-bit, one channel
out:	string;

fatal(s: string)
{
	fprint(stderr, "speak: %s\n", s);
	raise "fail:error";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	phon = load Phon Phon->PATH;
	if(arg == nil || bufio == nil || phon == nil)
		fatal(sprint("load: %r"));

	lexicon := "";
	text := "";
	pitch := 0;
	speed := 0;
	out = "/dev/audio";
	arg->init(argv);
	arg->setusage("speak [-l lexicon] [-p pitch] [-s speed] [-o file] [-q] [-n] [-t text] [file ...]");
	while((o := arg->opt()) != 0)
		case o {
		'l' =>	lexicon = arg->earg();
		'p' =>	pitch = int arg->earg();
		's' =>	speed = int arg->earg();
		'o' =>	out = arg->earg();
		'q' =>	quiet++;
		'n' =>	dryrun++;
		't' =>	text = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();

	if((e := phon->init(lexicon)) != nil)
		fatal(e);
	# Always attempt it - a dry run still has to reach a file that lives on
	# the device - but only insist where the device will actually be used.
	if(sys->bind("#V", "/dev", Sys->MAFTER) < 0 && !dryrun)
		fatal(sprint("bind #V: %r"));

	if(pitch != 0 || speed != 0){
		ctl := sys->open("/dev/voice/ctl", Sys->OWRITE);
		if(ctl == nil)
			fatal(sprint("open /dev/voice/ctl: %r"));
		if(pitch != 0 && sys->fprint(ctl, "pitch %d", pitch) < 0)
			fatal(sprint("pitch: %r"));
		if(speed != 0 && sys->fprint(ctl, "speed %d", speed) < 0)
			fatal(sprint("speed: %r"));
	}

	if(text != ""){
		utter(text);
		return;
	}
	if(argv == nil){
		b := bufio->fopen(sys->fildes(0), Bufio->OREAD);
		if(b == nil)
			fatal(sprint("stdin: %r"));
		readout(b, "stdin");
		return;
	}
	for(; argv != nil; argv = tl argv){
		#
		# Reading the announcements is the case where being interrupted
		# matters: a reader that has to finish the last screen before it
		# can tell you about this one is unusable. Anything else - a
		# file, a pipe - is read to the end, because nothing is going to
		# supersede it.
		#
		if(hd argv == "/dev/voice/screen"){
			watching = 1;
			vctl = sys->open("/dev/voice/ctl", Sys->OREAD);
		}
		b := bufio->open(hd argv, Bufio->OREAD);
		if(b == nil){
			fprint(stderr, "speak: %s: %r\n", hd argv);
			continue;
		}
		readout(b, hd argv);
	}
}

readout(b: ref Iobuf, nil: string)
{
	while((l := b.gets('\n')) != nil){
		if(len l > 0 && l[len l - 1] == '\n')
			l = l[0:len l - 1];
		utter(l);
	}
}

#
# One line. A word that is in neither the lexicon nor the dictionary is
# reported and the rest of the line is still said: refusing the whole line
# because of one unknown word would be the wrong trade here, where the words
# arrive unbidden. That is the opposite of say(1)'s choice, and deliberately -
# there the words are chosen in advance and a refusal is a correction waiting
# to be made.
#
utter(line: string)
{
	if(strip(line) == "")
		return;
	line = readable(line);
	if(strip(line) == "")
		return;
	(ph, err) := phon->text(line);
	if(err != nil){
		ph = besteffort(line);
		if(!quiet)
			fprint(stderr, "speak: %s: not in the lexicon\n", err);
		if(ph == "")
			return;
	}

	# -n is how the reading of a line gets looked at without listening to it
	if(dryrun){
		print("%s\n", ph);
		return;
	}

	fd := sys->open("/dev/voice/phonemes", Sys->OWRITE);
	if(fd == nil)
		fatal(sprint("open /dev/voice/phonemes: %r"));
	b := array of byte ph;
	if(sys->write(fd, b, len b) != len b)
		fatal(sprint("write phonemes: %r"));
	fd = nil;

	pfd := sys->open("/dev/voice/pcm", Sys->OREAD);
	if(pfd == nil)
		fatal(sprint("open /dev/voice/pcm: %r"));
	pcm := array[4*1024*1024] of byte;
	n := sys->readn(pfd, pcm, len pcm);
	if(n <= 0)
		return;
	play(pcm[0:n]);
}

#
# What a line has to become before it can be looked up.
#
# The first thing this was given to read was `ls /dev`, and it said nothing at
# all: every line is a path, "/dev/cons" is one token with no spaces in it, and
# no dictionary has an entry for "devcons". Silence, from a screen reader,
# reading the most ordinary output there is.
#
# So the separators that hold identifiers together - slash, dot, dash,
# underscore - become spaces, which turns a path into the words it is made of.
# And digits become their names, because "4" is not a word and an error code or
# a byte count is exactly the thing being read out.
#
# This is a reading policy and it lives here rather than in phon(2): say(1)
# narrates text somebody wrote, where "4" should be a mistake to fix, not a
# guess to make.
#
digits := array[] of {
	"zero", "one", "two", "three", "four",
	"five", "six", "seven", "eight", "nine"
};

readable(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'/' or '.' or '-' or '_' or '=' or ':' or ',' or
		'(' or ')' or '[' or ']' or '{' or '}' or
		'<' or '>' or '|' or '&' or ';' or '*' or '#' or '$' or '\'' =>
			r += " ";
		'0' to '9' =>
			r += " " + digits[c - '0'] + " ";
		* =>
			if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
			   c == ' ' || c == '\t')
				r[len r] = c;
			else
				r += " ";
		}
	}
	return r;
}

#
# The letters, as they are named when a word is spelled out.
#
# From espeak-ng, like the dictionary, so they are in the voice's own symbols
# and as trustworthy as everything else here - except A, where espeak read the
# spelling "ay" as the word that rhymes with eye. The dictionary's own entry
# for "a" is the letter and is used instead.
#
letters := array[] of {
	"ˈeɪ", "bˈiː", "sˈiː", "dˈiː", "ˈiː", "ˈɛf", "dʒˈiː", "ˈeɪtʃ",
	"ˈaɪ", "dʒˈeɪ", "kˈeɪ", "ˈɛl", "ˈɛm", "ˈɛn", "ˈoʊ", "pˈiː",
	"kjˈuː", "ˈɑːɹ", "ˈɛs", "tˈiː", "jˈuː", "vˈiː", "dˈʌbəl juː",
	"ˈɛks", "wˈaɪ", "zˈiː"
};

#
# Say what can be said, and for the rest fall back rather than going silent.
#
# Skipping an unknown word was the first answer and it is not good enough:
# "consctl" and "hoststdin" are most of what there is to read on this system,
# and a reader that omits them is telling you the wrong thing about your own
# machine. So an unknown word is tried two more ways before being given up on.
#
# It is spelled out, letter by letter, which is what a screen reader does with
# a string it cannot pronounce and is exactly right: it conveys the token with
# no invention at all.
#
# Splitting it into words that run together was tried first and removed. It is
# the obvious idea - "hoststdin" ought to come apart into host, std, in - and
# what it actually produced was "hosts td in", because the longest prefix that
# is a word is "hosts" and "td" is in the dictionary too. Both readings have
# three pieces, so counting them does not choose between them, and the wrong
# one sounds exactly as confident as the right one. Spelling cannot be wrong.
#
besteffort(line: string): string
{
	said := "";
	for(l := words(line); l != nil; l = tl l){
		w := hd l;
		(ph, err) := phon->text(w);
		if(err != nil)
			ph = spell(w);
		if(ph == "")
			ph = spell(w);
		if(ph == "")
			continue;
		if(said != "")
			said += " ";
		said += ph;
	}
	return said;
}

spell(w: string): string
{
	said := "";
	for(i := 0; i < len w; i++){
		c := w[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c < 'a' || c > 'z')
			continue;
		if(said != "")
			said += " ";
		said += letters[c - 'a'];
	}
	return said;
}

words(s: string): list of string
{
	l: list of string;
	i := len s;
	e := i;
	while(i > 0){
		i--;
		if(s[i] == ' ' || s[i] == '\t'){
			if(e > i+1)
				l = s[i+1:e] :: l;
			e = i;
		}
	}
	if(e > 0)
		l = s[0:e] :: l;
	return l;
}

#
# How many announcements are waiting that a person's own action produced.
# Asked between chunks of audio, so it must not block, which is why it reads
# ctl and not the screen file.
#
# Output does not interrupt output. If it did, anything printing faster than it
# can be read would never be read at all - every line cut off by the next.
#
waiting(): int
{
	b := array[256] of byte;

	if(vctl == nil)
		return 0;
	n := sys->pread(vctl, b, len b, big 0);
	if(n <= 0)
		return 0;
	s := string b[0:n];
	for(i := 0; i < len s; i++){
		if(i != 0 && s[i-1] != '\n')
			continue;
		if(i+7 <= len s && s[i:i+7] == "urgent "){
			j := i+7;
			v := 0;
			while(j < len s && s[j] >= '0' && s[j] <= '9')
				v = v*10 + int s[j++] - '0';
			return v;
		}
		if(0 && i+8 <= len s && s[i:i+8] == "waiting "){
			j := i+8;
			v := 0;
			while(j < len s && s[j] >= '0' && s[j] <= '9')
				v = v*10 + int s[j++] - '0';
			return v;
		}
	}
	return 0;
}

play(b: array of byte)
{
	if(out == "/dev/audio"){
		cfd := sys->open("/dev/audioctl", Sys->OWRITE);
		if(cfd == nil)
			fatal(sprint("open /dev/audioctl: %r"));
		if(sys->fprint(cfd, "rate %d", Rate) < 0 ||
		   sys->fprint(cfd, "chans 1") < 0 ||
		   sys->fprint(cfd, "bits 16") < 0)
			fatal(sprint("set the audio format: %r"));
	}
	af := sys->create(out, Sys->OWRITE, 8r666);
	if(af == nil)
		af = sys->open(out, Sys->OWRITE);
	if(af == nil)
		fatal(sprint("%s: %r", out));

	#
	# A chunk at a time, so there is somewhere to notice that what is being
	# said has been overtaken. Writing the whole utterance would block until
	# it had all been queued and then, on close, until it had all been
	# heard, and by then it is too late to not say it.
	#
	for(o := 0; o < len b; o += Chunk){
		e := o + Chunk;
		if(e > len b)
			e = len b;
		if(sys->write(af, b[o:e], e-o) != e-o)
			fatal(sprint("write %s: %r", out));
		if(watching && waiting() > 0){
			#
			# The person has done something, so what is being said
			# is out of date. Throw away what has been written and
			# not yet heard: closing would otherwise wait for it,
			# which is the whole problem.
			#
			if(out == "/dev/audio"){
				cfd := sys->open("/dev/audioctl", Sys->OWRITE);
				if(cfd != nil)
					sys->fprint(cfd, "flush");
			}
			if(!quiet)
				fprint(stderr, "speak: interrupted\n");
			return;
		}
	}
	# closing /dev/audio is what waits for the sound to finish, so this
	# returns when the line has been heard and the next one can start
	af = nil;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}
