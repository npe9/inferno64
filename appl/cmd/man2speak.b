implement Man2speak;

#
#	man2speak: a man page as text, with its structure kept instead of
#	discarded, for sentences(1)/speak(1) to read aloud.
#
#	man2txt(1) already parses the real troff (parseman(2), module/man.m)
#	and already knows which text is a .SH/.SS heading (Text.heading) -
#	it just throws that away when it flattens everything to plain
#	lines. Reading that same output through sentences(1) mashes a
#	heading straight into the paragraph that follows it, because
#	nothing in plain text tells sentences a heading is not just a short
#	first sentence: "NAME paste - merge corresponding lines of several
#	files" comes out as one run, not two.
#
#	This is man2txt's own parser, its own output, with one change: a
#	heading gets its own paragraph - a blank line before it and after
#	it - so
#
#		man2speak /man/1/paste | sentences | speak
#
#	reads the heading as its own utterance and the body as the
#	sentences it actually is, instead of one one welded to the other.
#	Nothing here understands troff tables (.TS/.TE) or equations
#	(.EQ/.EN) - parseman doesn't parse them either, and no man page in
#	this tree uses them; only some doc/*.ms papers do, a different
#	problem this does not attempt.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "man.m";

Man2speak: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

W: adt {
	textwidth: fn(w: self ref W, text: Parseman->Text): int;
};

output: ref Iobuf;
wasblank := 1;		# true at the start, so a leading heading gets no
			# spurious blank line before it

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->print("cannot load Bufio module: %r\n");
		raise "fail:init";
	}

	output = bufio->fopen(sys->fildes(1), Sys->OWRITE);

	parser := load Parseman Parseman->PATH;
	parser->init();

	argv = tl argv;
	for(; argv != nil; argv = tl argv){
		fname := hd argv;
		fd := sys->open(fname, Sys->OREAD);
		if(fd == nil){
			sys->print("cannot open %s: %r\n", fname);
			continue;
		}
		m := Parseman->Metrics(65, 1, 1, 1, 1, 5, 2);

		datachan := chan of list of (int, Parseman->Text);
		w: ref W;
		spawn parser->parseman(fd, m, 1, w, datachan);
		for(;;){
			line := <-datachan;
			if(line == nil)
				break;
			setline(line);
		}
		output.flush();
	}
	output.close();
}

W.textwidth(nil: self ref W, text: Parseman->Text): int
{
	return len text.text;
}

setline(line: list of (int, Parseman->Text))
{
	isheading := 0;
	text := "";
	offset := 0;
	for(l := line; l != nil; l = tl l){
		(indent, txt) := hd l;
		if(txt.heading != 0)
			isheading = 1;
		while(offset < indent){
			text += " ";
			offset++;
		}
		text += txt.text;
		offset += len txt.text;
	}
	text = trim(text);

	if(text == "" && !isheading){
		if(!wasblank)
			output.puts("\n");
		wasblank = 1;
		return;
	}

	if(isheading){
		if(!wasblank)
			output.puts("\n");
		output.puts(text + "\n\n");
		wasblank = 1;
		return;
	}

	output.puts(text + "\n");
	wasblank = 0;
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
