implement Sentences;

#
#	sentences: reflow column-wrapped prose into one sentence per line.
#
#	Built because speak(1) reads a line at a time, and a line was the
#	right unit for what it was built to read - ls /dev, /dev/voice/screen
#	announcements, one thing per line. Prose is not that: man2txt wraps
#	a paragraph at a fixed column with no regard for where a sentence
#	ends, so "Paste reads one line at a time from each file (the name"
#	is a whole line on its own, and speaking it as a whole utterance
#	pauses in the middle of a sentence and runs straight through the
#	period at the end of the next one. This undoes that: blank lines
#	still end a paragraph, but everything between them is joined back
#	into running text and then cut at actual sentence ends, so
#
#		man2txt /man/1/paste | sentences | speak
#
#	pauses where a person reading it aloud would.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "draw.m";

Sentences: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

isend(r: int): int
{
	return r == '.' || r == '!' || r == '?';
}

isspace(r: int): int
{
	return r == ' ' || r == '\t';
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && isspace(s[i]))
		i++;
	while(j > i && isspace(s[j-1]))
		j--;
	return s[i:j];
}

# split a paragraph's worth of joined text into sentences: a run of
# '.', '!' or '?' followed by whitespace (or the end of the paragraph)
# ends one. Abbreviations ("e.g.", "Mr.") are not detected - a period
# there ends a sentence early, the same wrong way any simple rule does;
# fixing that needs real abbreviation knowledge, and is not attempted.
splitsentences(stdout: ref Iobuf, para: string)
{
	start := 0;
	i := 0;
	n := len para;
	while(i < n){
		if(isend(para[i])){
			j := i+1;
			while(j < n && isend(para[j]))
				j++;
			if(j >= n || isspace(para[j])){
				s := trim(para[start:j]);
				if(s != "")
					stdout.puts(s + "\n");
				start = j;
				i = j;
				continue;
			}
			i = j;
			continue;
		}
		i++;
	}
	s := trim(para[start:n]);
	if(s != "")
		stdout.puts(s + "\n");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	args = tl args;

	fd: ref Sys->FD;
	if(args != nil){
		fd = sys->open(hd args, Sys->OREAD);
		if(fd == nil){
			sys->fprint(sys->fildes(2), "sentences: cannot open %s: %r\n", hd args);
			raise "fail:open";
		}
	}else
		fd = sys->fildes(0);

	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil){
		sys->fprint(sys->fildes(2), "sentences: cannot open bufio: %r\n");
		raise "fail:bufio";
	}
	stdout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);

	para := "";
	line: string;
	while((line = bio.gets('\n')) != nil){
		if(len line > 0 && line[len line-1] == '\n')
			line = line[0:len line-1];
		t := trim(line);
		if(t == ""){
			if(para != ""){
				splitsentences(stdout, para);
				para = "";
			}
			continue;
		}
		if(para == "")
			para = t;
		else
			para = para + " " + t;
	}
	if(para != "")
		splitsentences(stdout, para);
	stdout.flush();
}
