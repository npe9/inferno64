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
	arg->setusage("speak [-l lexicon] [-p pitch] [-s speed] [-o file] [-q] [-t text] [file ...]");
	while((o := arg->opt()) != 0)
		case o {
		'l' =>	lexicon = arg->earg();
		'p' =>	pitch = int arg->earg();
		's' =>	speed = int arg->earg();
		'o' =>	out = arg->earg();
		'q' =>	quiet++;
		't' =>	text = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();

	if((e := phon->init(lexicon)) != nil)
		fatal(e);
	if(sys->bind("#V", "/dev", Sys->MAFTER) < 0)
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
# Say the words that are known and skip the ones that are not, rather than
# saying nothing. A screen reader that goes silent on an unfamiliar word has
# failed at the one thing it is for.
#
besteffort(line: string): string
{
	said := "";
	for(l := words(line); l != nil; l = tl l){
		(ph, err) := phon->text(hd l);
		if(err != nil)
			continue;
		if(said != "")
			said += " ";
		said += ph;
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
	if(sys->write(af, b, len b) != len b)
		fatal(sprint("write %s: %r", out));
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
